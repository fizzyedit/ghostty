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
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn _exit(code: c_int) noreturn;

    const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
        .linux => 0x5414,
        else => 0x80087467, // macOS / BSD
    };

    pub fn open(ctx: *anyopaque, on_data: OnData, cols: u16, rows: u16) !Pty {
        _ = setenv("TERM", "xterm-256color", 1);

        var ws = Winsize{ .ws_row = rows, .ws_col = cols };
        var amaster: c_int = -1;
        const pid = forkpty(&amaster, null, null, &ws);
        if (pid < 0) return error.ForkptyFailed;

        if (pid == 0) {
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
        _ = std.c.write(self.master, bytes.ptr, bytes.len);
    }

    pub fn setSize(self: *Pty, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) void {
        if (self.master < 0) return;
        const xpixel: u16 = @intCast(@min(@as(u32, cols) * cell_w_px, std.math.maxInt(u16)));
        const ypixel: u16 = @intCast(@min(@as(u32, rows) * cell_h_px, std.math.maxInt(u16)));
        var ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = xpixel, .ws_ypixel = ypixel };
        _ = ioctl(self.master, TIOCSWINSZ, &ws);
    }
};
