//! Unix PTY backend (`forkpty`). Used on macOS and Linux.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = true;

pub const OnData = *const fn (ctx: *anyopaque, bytes: []const u8) void;

pub const Pty = struct {
    master: c_int = -1,
    child: c_int = -1,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    ctx: *anyopaque = undefined,
    on_data: OnData = undefined,

    const Winsize = extern struct {
        ws_row: u16 = 0,
        ws_col: u16 = 0,
        ws_xpixel: u16 = 0,
        ws_ypixel: u16 = 0,
    };

    extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn chdir(path: [*:0]const u8) c_int;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn _exit(code: c_int) noreturn;

    const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
        .linux => 0x5414,
        else => 0x80087467, // macOS / BSD
    };

    /// `cwd` — the shell opens here instead of wherever the app itself was launched from (its
    /// own bundle directory for a packaged `.app`), matching VSCode's integrated terminal
    /// (opens in the current workspace root). Null (no project open yet) or too long for
    /// `cwd_buf` falls back to whatever cwd the app process itself has.
    pub fn open(ctx: *anyopaque, on_data: OnData, cols: u16, rows: u16, cwd: ?[]const u8) !Pty {
        var ws = Winsize{ .ws_row = rows, .ws_col = cols };
        var amaster: c_int = -1;

        // Built *before* the fork: nothing between fork() and exec() in the child may
        // allocate (see the sibling comment on `setenv`), and the stack this buffer lives on
        // is copy-on-write duplicated into the child by fork() itself, so it's already there —
        // no cross-fork pointer hazard.
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_z: ?[:0]const u8 = if (cwd) |c| blk: {
            if (c.len >= cwd_buf.len) break :blk null;
            @memcpy(cwd_buf[0..c.len], c);
            cwd_buf[c.len] = 0;
            break :blk cwd_buf[0..c.len :0];
        } else null;

        const pid = forkpty(&amaster, null, null, &ws);
        if (pid < 0) return error.ForkptyFailed;

        if (pid == 0) {
            // Child-only: `setenv` here would otherwise mutate the whole host editor
            // process's environment, since `open` runs on the GUI thread before fork.
            _ = setenv("TERM", "xterm-256color", 1);
            // Best-effort: a failed chdir (deleted folder, etc.) just leaves the shell in
            // whatever cwd it inherited rather than aborting the launch.
            if (cwd_z) |c| _ = chdir(c.ptr);
            const shell: [*:0]const u8 = std.c.getenv("SHELL") orelse "/bin/zsh";
            const argv = [_:null]?[*:0]const u8{shell};
            _ = execvp(shell, &argv);
            _exit(127);
        }

        return .{ .master = amaster, .child = pid, .ctx = ctx, .on_data = on_data };
    }

    pub fn startReader(self: *Pty) !void {
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
    }

    fn readLoop(self: *Pty) void {
        var buf: [4096]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            const n = std.posix.read(self.master, &buf) catch break;
            if (n == 0) break;
            self.on_data(self.ctx, buf[0..n]);
        }
    }

    pub fn deinit(self: *Pty) void {
        self.stop.store(true, .release);
        if (self.child > 0) std.posix.kill(self.child, std.posix.SIG.HUP) catch {};
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.master >= 0) {
            _ = std.c.close(self.master);
            self.master = -1;
        }
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                break; // real error (e.g. EPIPE on child exit) — drop the rest
            }
            off += @intCast(n);
        }
    }

    pub fn setSize(self: *Pty, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) void {
        if (self.master < 0) return;
        const xpixel: u16 = @intCast(@min(@as(u32, cols) * cell_w_px, std.math.maxInt(u16)));
        const ypixel: u16 = @intCast(@min(@as(u32, rows) * cell_h_px, std.math.maxInt(u16)));
        var ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = xpixel, .ws_ypixel = ypixel };
        _ = ioctl(self.master, TIOCSWINSZ, &ws);
    }
};
