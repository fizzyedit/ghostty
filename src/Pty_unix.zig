//! Unix PTY backend (`forkpty`). Used on macOS and Linux.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = true;

pub const OnData = *const fn (ctx: *anyopaque, bytes: []const u8) void;
/// The program exited with `code` (128 + the signal when a signal ended it). Reader thread.
pub const OnExit = *const fn (ctx: *anyopaque, code: i32) void;

const Env = @import("Pty.zig").Env;
const Command = @import("Pty.zig").Command;

pub const Pty = struct {
    master: c_int = -1,
    child: c_int = -1,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    ctx: *anyopaque = undefined,
    on_data: OnData = undefined,
    /// Called once the program has exited and its output is drained. Set before `startReader`.
    on_exit: ?OnExit = null,
    /// Waits on the program (`waitLoop`).
    waiter: ?std.Thread = null,
    /// The reader has reached the end of the terminal's output.
    drained: std.atomic.Value(bool) = .init(false),
    /// Guards `reaped` against a signal racing the reap: after it, the pid may be another's.
    reap_lock: std.atomic.Mutex = .unlocked,
    reaped: bool = false,

    const Winsize = extern struct {
        ws_row: u16 = 0,
        ws_col: u16 = 0,
        ws_xpixel: u16 = 0,
        ws_ypixel: u16 = 0,
    };

    extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
    extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn chdir(path: [*:0]const u8) c_int;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn waitid(idtype: c_int, id: c_uint, infop: *anyopaque, options: c_int) c_int;
    const P_PID: c_int = 1;
    const WEXITED: c_int = 4;
    const WNOWAIT: c_int = if (builtin.target.os.tag == .linux) 0x01000000 else 0x20;

    const TIOCSWINSZ: c_ulong = switch (builtin.target.os.tag) {
        .linux => 0x5414,
        else => 0x80087467, // macOS / BSD
    };

    /// `cwd` — the shell opens here instead of wherever the app itself was launched from (its
    /// own bundle directory for a packaged `.app`), matching VSCode's integrated terminal
    /// (opens in the current workspace root). Null (no project open yet) falls back to
    /// whatever cwd the app process itself has. `command` null runs the user's `$SHELL`.
    pub fn open(ctx: *anyopaque, on_data: OnData, cols: u16, rows: u16, cwd: ?[]const u8, command: ?Command) !Pty {
        // Everything the child needs is built *before* the fork: nothing between fork() and
        // exec() in the child may allocate (another thread may hold the allocator's lock), and
        // the parent's memory is copy-on-write duplicated into the child, so it is already there.
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const shell: []const u8 = if (std.c.getenv("SHELL")) |s| std.mem.span(s) else "/bin/zsh";
        const cmd: Command = command orelse .{ .argv = &.{shell} };
        if (cmd.argv.len == 0) return error.NoCommand;

        const envp = try environment(arena, cmd.env);
        const path = try resolve(arena, cmd.argv[0], lookup(envp, "PATH"));
        const argv = try arena.allocSentinel(?[*:0]const u8, cmd.argv.len, null);
        for (cmd.argv, argv) |a, *out| out.* = try arena.dupeSentinel(u8, a, 0);
        const cwd_z: ?[:0]const u8 = if (cwd) |c| if (c.len > 0) try arena.dupeSentinel(u8, c, 0) else null else null;

        var ws = Winsize{ .ws_row = rows, .ws_col = cols };
        var amaster: c_int = -1;
        const pid = forkpty(&amaster, null, null, &ws);
        if (pid < 0) return error.ForkptyFailed;

        if (pid == 0) {
            // Best-effort: a failed chdir (deleted folder, etc.) just leaves the program in
            // whatever cwd it inherited rather than aborting the launch.
            if (cwd_z) |c| _ = chdir(c.ptr);
            _ = execve(path, argv.ptr, envp.ptr);
            _exit(127);
        }

        return .{ .master = amaster, .child = pid, .ctx = ctx, .on_data = on_data };
    }

    /// `KEY=VALUE` lines for the child: the app's own environment with `TERM` set, under
    /// `overrides`, which win over both.
    fn environment(arena: std.mem.Allocator, overrides: []const Env) ![:null]?[*:0]const u8 {
        var out: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        var it: [*:null]const ?[*:0]const u8 = @ptrCast(appEnviron());
        while (it[0]) |line| : (it += 1) {
            const entry = std.mem.span(line);
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            const name = entry[0..eq];
            if (std.mem.eql(u8, name, "TERM") or named(overrides, name)) continue;
            try out.append(arena, line);
        }
        if (!named(overrides, "TERM")) try out.append(arena, "TERM=xterm-256color");
        for (overrides) |e| try out.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ e.name, e.value }, 0));
        return out.toOwnedSliceSentinel(arena, null);
    }

    fn named(list: []const Env, name: []const u8) bool {
        for (list) |e| if (std.mem.eql(u8, e.name, name)) return true;
        return false;
    }

    fn lookup(envp: [:null]?[*:0]const u8, name: []const u8) ?[]const u8 {
        for (envp) |line| {
            const entry = std.mem.span(line.?);
            if (entry.len > name.len and entry[name.len] == '=' and std.mem.startsWith(u8, entry, name))
                return entry[name.len + 1 ..];
        }
        return null;
    }

    /// `name` as `execvp` would find it, on the child's `PATH`: done here because `execvp`
    /// searches the parent's.
    fn resolve(arena: std.mem.Allocator, name: []const u8, path_value: ?[]const u8) ![:0]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) return arena.dupeSentinel(u8, name, 0);
        var dirs = std.mem.splitScalar(u8, path_value orelse "/usr/bin:/bin", ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0);
            if (std.c.access(candidate.ptr, std.c.X_OK) == 0) return candidate;
        }
        // Not found: exec fails in the child and the program exits 127, as a shell's would.
        return arena.dupeSentinel(u8, name, 0);
    }

    fn appEnviron() [*:null]?[*:0]u8 {
        // A dylib on macOS has no `environ` of its own to link against; the C runtime hands it out.
        if (comptime builtin.target.os.tag.isDarwin()) return _NSGetEnviron().*;
        return std.c.environ;
    }
    extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

    pub fn startReader(self: *Pty) !void {
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        self.waiter = try std.Thread.spawn(.{}, waitLoop, .{self});
    }

    fn readLoop(self: *Pty) void {
        defer self.drained.store(true, .release);
        var buf: [4096]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            const n = std.posix.read(self.master, &buf) catch break;
            if (n == 0) break;
            self.on_data(self.ctx, buf[0..n]);
        }
    }

    /// Waits for the program itself, not for the terminal to close: a helper it left behind
    /// holding the terminal (a browser opener, a node worker) must not hide its exit.
    fn waitLoop(self: *Pty) void {
        // Wait for the exit without reaping, so the pid stays the program's (a zombie) until
        // `reap` takes it under the lock `signal` checks: a hangup never reaches a stranger.
        var info: [256]u8 align(16) = undefined;
        while (waitid(P_PID, @intCast(self.child), &info, WEXITED | WNOWAIT) != 0) {
            if (std.c._errno().* != @backingInt(std.c.E.INTR)) break;
        }
        const code = self.reap() orelse return;
        if (self.stop.load(.acquire)) return;
        // Let the reader take what the program wrote last, so the exit reads after it. A helper
        // holding the terminal open costs only this wait.
        var waited: u32 = 0;
        while (!self.drained.load(.acquire) and waited < drain_ms) : (waited += 10) sleepMs(10);
        if (self.on_exit) |f| f(self.ctx, code);
    }

    const drain_ms = 250;

    /// Reap the program: its exit code, or null when it was not ours to wait for.
    fn reap(self: *Pty) ?i32 {
        while (!self.reap_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.reap_lock.unlock();
        var status: c_int = 0;
        while (true) {
            const r = waitpid(self.child, &status, 0);
            if (r == self.child) break;
            if (r < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return null;
        }
        self.reaped = true;
        return exitCode(status);
    }

    /// Signal the program and whatever it started in its terminal (its process group: `forkpty`
    /// made it a session leader). Never once it has been reaped.
    fn signal(self: *Pty, sig: std.posix.SIG) bool {
        while (!self.reap_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.reap_lock.unlock();
        if (self.reaped or self.child <= 0) return false;
        std.posix.kill(-self.child, sig) catch {};
        return true;
    }

    fn sleepMs(ms: u32) void {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }

    /// A `waitpid` status as a shell reports it: the exit code, or 128 + the signal.
    pub fn exitCode(status: c_int) i32 {
        const s: u32 = @bitCast(status);
        if (s & 0x7f == 0) return @intCast((s >> 8) & 0xff);
        return 128 + @as(i32, @intCast(s & 0x7f));
    }

    /// Hang up on the program, and kill it if it is still there a moment later: closing a pane
    /// or quitting never waits on a program that ignores the hangup.
    pub fn deinit(self: *Pty) void {
        self.stop.store(true, .release);
        if (self.signal(.HUP)) {
            var waited: u32 = 0;
            while (waited < 200 and !self.isReaped()) : (waited += 10) sleepMs(10);
            _ = self.signal(.KILL);
        }
        if (self.waiter) |t| {
            t.join();
            self.waiter = null;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.master >= 0) {
            _ = std.c.close(self.master);
            self.master = -1;
        }
    }

    fn isReaped(self: *Pty) bool {
        while (!self.reap_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.reap_lock.unlock();
        return self.reaped;
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
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

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

const Captured = struct {
    mutex: std.atomic.Mutex = .unlocked,
    out: [4096]u8 = undefined,
    len: usize = 0,
    code: std.atomic.Value(i32) = .init(std.math.minInt(i32)),

    fn onData(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Captured = @ptrCast(@alignCast(ctx));
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        const n = @min(bytes.len, self.out.len - self.len);
        @memcpy(self.out[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    fn onExit(ctx: *anyopaque, code: i32) void {
        const self: *Captured = @ptrCast(@alignCast(ctx));
        self.code.store(code, .release);
    }

    fn wait(self: *Captured) !i32 {
        var tries: usize = 0;
        while (tries < 500) : (tries += 1) {
            const code = self.code.load(.acquire);
            if (code != std.math.minInt(i32)) return code;
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
        return error.Timeout;
    }
};

test "a command runs with its arguments, environment and folder, and its exit code comes back" {
    var cap: Captured = .{};
    var pty = try Pty.open(&cap, Captured.onData, 80, 24, "/", .{
        // `sh` found on PATH, as a request's bare program name is.
        .argv = &.{ "sh", "-c", "printf '%s|%s|%s|' \"$1\" \"$FIZZY_RUN_TEST\" \"$(pwd)\"; exit 3", "sh", "one arg" },
        .env = &.{.{ .name = "FIZZY_RUN_TEST", .value = "set" }},
    });
    pty.on_exit = Captured.onExit;
    try pty.startReader();
    defer pty.deinit();

    try testing.expectEqual(@as(i32, 3), try cap.wait());
    // The exit is reported only once the output is drained.
    try testing.expect(std.mem.indexOf(u8, cap.out[0..cap.len], "one arg|set|/|") != null);
}

test "a program killed by a signal exits as a shell reports it; one not found exits 127" {
    var cap: Captured = .{};
    var pty = try Pty.open(&cap, Captured.onData, 80, 24, null, .{ .argv = &.{ "sh", "-c", "kill -TERM $$" } });
    pty.on_exit = Captured.onExit;
    try pty.startReader();
    defer pty.deinit();
    try testing.expectEqual(@as(i32, 128 + 15), try cap.wait());

    var missing: Captured = .{};
    var pty2 = try Pty.open(&missing, Captured.onData, 80, 24, null, .{ .argv = &.{"fizzy-no-such-program"} });
    pty2.on_exit = Captured.onExit;
    try pty2.startReader();
    defer pty2.deinit();
    try testing.expectEqual(@as(i32, 127), try missing.wait());
}

test "a program's exit is heard though a helper it left keeps the terminal open" {
    var cap: Captured = .{};
    var pty = try Pty.open(&cap, Captured.onData, 80, 24, null, .{ .argv = &.{ "sh", "-c", "sleep 30 & exit 4" } });
    pty.on_exit = Captured.onExit;
    try pty.startReader();
    try testing.expectEqual(@as(i32, 4), try cap.wait());
    // Closing kills the helper with the program's process group, so this returns.
    pty.deinit();
}

test "closing never waits on a program that ignores the hangup" {
    var cap: Captured = .{};
    var pty = try Pty.open(&cap, Captured.onData, 80, 24, null, .{ .argv = &.{ "sh", "-c", "trap '' HUP; echo ready; sleep 30" } });
    pty.on_exit = Captured.onExit;
    try pty.startReader();
    var tries: usize = 0;
    while (std.mem.indexOf(u8, cap.out[0..cap.len], "ready") == null and tries < 300) : (tries += 1) Pty.sleepMs(10);
    pty.deinit();
}
