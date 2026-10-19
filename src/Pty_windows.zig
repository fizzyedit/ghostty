//! Windows PTY backend (ConPTY): `CreatePseudoConsole` + PowerShell + reader thread.
//!
//! Requires Windows 10 1809+ — the static kernel32 import of `CreatePseudoConsole`
//! means the plugin DLL will not load on older Windows.
//!
//! NOTE: needs ghostty_vt built without SIMD on Windows (see that repo's
//! release.yml `-Dsimd=false`) — the SIMD path pulls in simdutf (C++), which
//! demands the MSVC C++ runtime and won't link against this mingw-flavored
//! build. Bump build.zig.zon's ghostty_vt pin once that fix is published.
const std = @import("std");
const w = std.os.windows;

pub const supported = true;

pub const OnData = *const fn (ctx: *anyopaque, bytes: []const u8) void;
/// The program exited with `code`. Called from the waiter thread.
pub const OnExit = *const fn (ctx: *anyopaque, code: i32) void;

const Env = @import("Pty.zig").Env;
/// A program to run instead of PowerShell. `argv[0]` is found on `PATH` with `PATHEXT`, as a
/// shell would (an `npx.cmd`, say); a batch file runs through `cmd.exe`, which reads its command
/// line by rules of its own, so an argument it would take as syntax is refused, not escaped.
const Command = @import("Pty.zig").Command;

pub const Pty = struct {
    hpc: ?w.HANDLE = null,
    in_write: ?w.HANDLE = null,
    out_read: ?w.HANDLE = null,
    process: ?w.HANDLE = null,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    ctx: *anyopaque = undefined,
    on_data: OnData = undefined,
    /// Called once the program has exited. Set before `startReader`.
    on_exit: ?OnExit = null,
    /// Waits on the program, for `on_exit`: ConPTY keeps its output pipe open past the exit.
    waiter: ?std.Thread = null,
    /// The reader has reached the end of the output (rarely before `ClosePseudoConsole`).
    drained: std.atomic.Value(bool) = .init(false),

    const STARTUPINFOEXW = extern struct {
        StartupInfo: w.STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };

    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: w.DWORD = 0x00020016;
    const HRESULT = i32; // dropped from std.os.windows in Zig 0.16

    // Zig 0.16 std only ships CreateProcessW; the rest are declared here (the
    // same pattern Pty_unix.zig uses for forkpty/ioctl).
    extern "kernel32" fn CreatePipe(hReadPipe: *w.HANDLE, hWritePipe: *w.HANDLE, lpPipeAttributes: ?*w.SECURITY_ATTRIBUTES, nSize: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn ReadFile(hFile: w.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: w.DWORD, lpNumberOfBytesRead: ?*w.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn WriteFile(hFile: w.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: w.DWORD, lpNumberOfBytesWritten: ?*w.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn TerminateProcess(hProcess: w.HANDLE, uExitCode: c_uint) callconv(.winapi) w.BOOL;
    extern "kernel32" fn CreatePseudoConsole(size: w.COORD, hInput: w.HANDLE, hOutput: w.HANDLE, dwFlags: w.DWORD, phPC: *w.HANDLE) callconv(.winapi) HRESULT;
    extern "kernel32" fn ResizePseudoConsole(hPC: w.HANDLE, size: w.COORD) callconv(.winapi) HRESULT;
    extern "kernel32" fn ClosePseudoConsole(hPC: w.HANDLE) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: w.DWORD, dwFlags: w.DWORD, lpSize: *usize) callconv(.winapi) w.BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: w.DWORD, Attribute: usize, lpValue: ?*anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) w.BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]u16;
    extern "kernel32" fn FreeEnvironmentStringsW(penv: [*:0]u16) callconv(.winapi) w.BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: w.HANDLE, dwMilliseconds: w.DWORD) callconv(.winapi) w.DWORD;
    extern "kernel32" fn GetExitCodeProcess(hProcess: w.HANDLE, lpExitCode: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) w.DWORD;
    extern "kernel32" fn Sleep(dwMilliseconds: w.DWORD) callconv(.winapi) void;
    const INFINITE: w.DWORD = 0xFFFFFFFF;
    const INVALID_FILE_ATTRIBUTES: w.DWORD = 0xFFFFFFFF;

    pub fn open(ctx: *anyopaque, on_data: OnData, cols: u16, rows: u16, cwd: ?[]const u8, command: ?Command) !Pty {
        var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (command) |c| if (c.argv.len == 0) return error.NoCommand;
        // CreateProcessW may scribble on the command line; give it a mutable copy.
        const cmdline = try std.unicode.utf8ToUtf16LeAllocZ(arena, if (command) |c| try commandLine(arena, c) else "powershell.exe");
        const env_block: ?[]u16 = if (command) |c| try environment(arena, c.env) else null;

        // Pipe pair: we write keystrokes into in_write; ConPTY reads in_read.
        var in_read: w.HANDLE = undefined;
        var in_write: w.HANDLE = undefined;
        if (CreatePipe(&in_read, &in_write, null, 0) == .FALSE) return error.ConptyFailed;
        errdefer w.CloseHandle(in_write);

        // Pipe pair: ConPTY writes VT output into out_write; our reader drains out_read.
        var out_read: w.HANDLE = undefined;
        var out_write: w.HANDLE = undefined;
        if (CreatePipe(&out_read, &out_write, null, 0) == .FALSE) {
            w.CloseHandle(in_read);
            return error.ConptyFailed;
        }
        errdefer w.CloseHandle(out_read);

        const size = w.COORD{
            .X = @intCast(@max(cols, 1)),
            .Y = @intCast(@max(rows, 1)),
        };
        var hpc: w.HANDLE = undefined;
        const hr = CreatePseudoConsole(size, in_read, out_write, 0, &hpc);
        // ConPTY duplicated its ends of both pipes; ours can go regardless of outcome.
        w.CloseHandle(in_read);
        w.CloseHandle(out_write);
        if (hr < 0) return error.ConptyFailed;
        errdefer ClosePseudoConsole(hpc);

        // Attribute list holding the pseudoconsole handle for CreateProcessW.
        var attr_buf: [128]u8 align(@alignOf(usize)) = undefined;
        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        if (attr_size > attr_buf.len) return error.ConptyFailed;
        if (InitializeProcThreadAttributeList(&attr_buf, 1, 0, &attr_size) == .FALSE) return error.ConptyFailed;
        defer DeleteProcThreadAttributeList(&attr_buf);
        if (UpdateProcThreadAttribute(&attr_buf, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(w.HANDLE), null, null) == .FALSE)
            return error.ConptyFailed;

        var siex = STARTUPINFOEXW{
            .StartupInfo = std.mem.zeroes(w.STARTUPINFOW),
            .lpAttributeList = &attr_buf,
        };
        siex.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);

        var cwd_buf: [std.fs.max_path_bytes]u16 = undefined;
        const cwd_w: ?[:0]const u16 = if (cwd) |c| blk: {
            const len = std.unicode.utf8ToUtf16Le(cwd_buf[0 .. cwd_buf.len - 1], c) catch break :blk null;
            cwd_buf[len] = 0;
            break :blk cwd_buf[0..len :0];
        } else null;

        var pi: w.PROCESS.INFORMATION = undefined;
        if (w.kernel32.CreateProcessW(
            null,
            cmdline.ptr,
            null,
            null,
            .FALSE,
            .{ .extended_startupinfo_present = true, .create_unicode_environment = env_block != null },
            if (env_block) |e| @ptrCast(e.ptr) else null,
            if (cwd_w) |c| c.ptr else null,
            &siex.StartupInfo,
            &pi,
        ) == .FALSE) return error.SpawnFailed;
        w.CloseHandle(pi.hThread);

        return .{
            .hpc = hpc,
            .in_write = in_write,
            .out_read = out_read,
            .process = pi.hProcess,
            .ctx = ctx,
            .on_data = on_data,
        };
    }

    pub fn startReader(self: *Pty) !void {
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        if (self.on_exit != null) self.waiter = try std.Thread.spawn(.{}, waitLoop, .{self});
    }

    fn waitLoop(self: *Pty) void {
        const p = self.process orelse return;
        _ = WaitForSingleObject(p, INFINITE);
        if (self.stop.load(.acquire)) return;
        var code: w.DWORD = 0;
        if (GetExitCodeProcess(p, &code) == .FALSE) return;
        // Give the reader a moment for what the program wrote last, so the exit reads after it.
        var waited: u32 = 0;
        while (!self.drained.load(.acquire) and waited < 250) : (waited += 10) Sleep(10);
        if (self.on_exit) |f| f(self.ctx, @bitCast(code));
    }

    /// The command line for `cmd`: its program found on `PATH`, and its arguments quoted as the
    /// C runtime reads them; a batch file through `cmd.exe /d /c`.
    fn commandLine(arena: std.mem.Allocator, cmd: Command) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const wr = &out.writer;
        const path_value = for (cmd.env) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, "PATH")) break e.value;
        } else getenv(arena, "PATH");
        const program = try find(arena, cmd.argv[0], path_value);
        const batch = std.ascii.endsWithIgnoreCase(program, ".cmd") or std.ascii.endsWithIgnoreCase(program, ".bat");
        if (batch) {
            // cmd.exe expands %VAR% and takes & | < > ^ ( ) as syntax, inside quotes or not as
            // the quotes fall; no escaping holds for every argument, so those are refused.
            for (cmd.argv) |arg| if (std.mem.indexOfAny(u8, arg, "%&|<>^()!\"\r\n") != null) return error.UnsafeBatchArgument;
            try wr.writeAll("cmd.exe /d /c \"");
        }
        try quote(wr, program);
        for (cmd.argv[1..]) |arg| {
            try wr.writeByte(' ');
            try quote(wr, arg);
        }
        if (batch) try wr.writeByte('"');
        return out.written();
    }

    /// `name` on `path_value` with each of `PATHEXT`'s extensions, as cmd.exe finds a program;
    /// `name` itself when it names a path or is not found (CreateProcessW then says so).
    fn find(arena: std.mem.Allocator, name: []const u8, path_value: ?[]const u8) ![]const u8 {
        if (std.mem.indexOfAny(u8, name, "\\/:") != null) return name;
        const exts = getenv(arena, "PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
        var dirs = std.mem.splitScalar(u8, path_value orelse return name, ';');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            var it = std.mem.splitScalar(u8, exts, ';');
            while (it.next()) |ext| {
                if (ext.len == 0) continue;
                const candidate = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ dir, name, ext });
                const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, candidate);
                if (GetFileAttributesW(wide.ptr) != INVALID_FILE_ATTRIBUTES) return candidate;
            }
        }
        return name;
    }

    fn getenv(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
        const block = GetEnvironmentStringsW() orelse return null;
        defer _ = FreeEnvironmentStringsW(block);
        var p: [*:0]const u16 = block;
        while (p[0] != 0) {
            const entry = std.mem.span(p);
            p += entry.len + 1;
            const eq = std.mem.indexOfScalarPos(u16, entry, 1, '=') orelse continue;
            const key = std.unicode.utf16LeToUtf8Alloc(arena, entry[0..eq]) catch continue;
            if (!std.ascii.eqlIgnoreCase(key, name)) continue;
            return std.unicode.utf16LeToUtf8Alloc(arena, entry[eq + 1 ..]) catch null;
        }
        return null;
    }

    fn quote(wr: *std.Io.Writer, arg: []const u8) !void {
        if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null) return wr.writeAll(arg);
        try wr.writeByte('"');
        var backslashes: usize = 0;
        for (arg) |ch| {
            if (ch == '\\') {
                backslashes += 1;
                continue;
            }
            const n = if (ch == '"') backslashes * 2 + 1 else backslashes;
            try wr.splatByteAll('\\', n);
            backslashes = 0;
            try wr.writeByte(ch);
        }
        try wr.splatByteAll('\\', backslashes * 2);
        try wr.writeByte('"');
    }

    /// The app's environment with `TERM` set, under `overrides`, as the double-null-terminated
    /// UTF-16 block `CreateProcessW` takes. Names compare without case, as Windows does.
    fn environment(arena: std.mem.Allocator, overrides: []const Env) ![]u16 {
        var out: std.ArrayListUnmanaged(u16) = .empty;
        if (GetEnvironmentStringsW()) |block| {
            defer _ = FreeEnvironmentStringsW(block);
            var p: [*:0]const u16 = block;
            while (p[0] != 0) {
                const entry = std.mem.span(p);
                p += entry.len + 1;
                const eq = std.mem.indexOfScalarPos(u16, entry, 1, '=') orelse continue;
                const name = try std.unicode.utf16LeToUtf8Alloc(arena, entry[0..eq]);
                if (overridden(overrides, name) or std.ascii.eqlIgnoreCase(name, "TERM")) continue;
                try out.appendSlice(arena, entry);
                try out.append(arena, 0);
            }
        }
        if (!overridden(overrides, "TERM")) {
            try out.appendSlice(arena, std.unicode.utf8ToUtf16LeStringLiteral("TERM=xterm-256color"));
            try out.append(arena, 0);
        }
        for (overrides) |e| {
            const line = try std.fmt.allocPrint(arena, "{s}={s}", .{ e.name, e.value });
            try out.appendSlice(arena, try std.unicode.utf8ToUtf16LeAlloc(arena, line));
            try out.append(arena, 0);
        }
        try out.append(arena, 0);
        return out.items;
    }

    fn overridden(overrides: []const Env, name: []const u8) bool {
        for (overrides) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return true;
        return false;
    }

    fn readLoop(self: *Pty) void {
        defer self.drained.store(true, .release);
        const out_read = self.out_read orelse return;
        var buf: [4096]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            var n: w.DWORD = 0;
            if (ReadFile(out_read, &buf, buf.len, &n, null) == .FALSE) break;
            if (n == 0) break;
            self.on_data(self.ctx, buf[0..n]);
        }
    }

    pub fn deinit(self: *Pty) void {
        self.stop.store(true, .release);
        if (self.process) |p| _ = TerminateProcess(p, 0);
        // Closing the pseudoconsole makes conhost drop its end of the output
        // pipe, unblocking the reader's ReadFile; the reader keeps draining
        // until then (joining before closing out_read avoids the known ConPTY
        // close-hang on a full pipe).
        if (self.hpc) |h| ClosePseudoConsole(h);
        self.hpc = null;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.waiter) |t| {
            t.join();
            self.waiter = null;
        }
        if (self.out_read) |h| w.CloseHandle(h);
        self.out_read = null;
        if (self.in_write) |h| w.CloseHandle(h);
        self.in_write = null;
        if (self.process) |p| w.CloseHandle(p);
        self.process = null;
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        const in_write = self.in_write orelse return;
        var rest = bytes;
        while (rest.len > 0) {
            var n: w.DWORD = 0;
            if (WriteFile(in_write, rest.ptr, @intCast(rest.len), &n, null) == .FALSE) return;
            if (n == 0) return;
            rest = rest[n..];
        }
    }

    pub fn setSize(self: *Pty, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) void {
        _ = cell_w_px;
        _ = cell_h_px;
        const hpc = self.hpc orelse return;
        const size = w.COORD{
            .X = @intCast(@max(cols, 1)),
            .Y = @intCast(@max(rows, 1)),
        };
        _ = ResizePseudoConsole(hpc, size);
    }
};
