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

pub const Pty = struct {
    hpc: ?w.HANDLE = null,
    in_write: ?w.HANDLE = null,
    out_read: ?w.HANDLE = null,
    process: ?w.HANDLE = null,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    ctx: *anyopaque = undefined,
    on_data: OnData = undefined,

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

    pub fn open(ctx: *anyopaque, on_data: OnData, cols: u16, rows: u16) !Pty {
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

        // CreateProcessW may scribble on the command line; give it a mutable copy.
        var cmdline = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe").*;
        var pi: w.PROCESS.INFORMATION = undefined;
        if (w.kernel32.CreateProcessW(
            null,
            @ptrCast(&cmdline),
            null,
            null,
            .FALSE,
            .{ .extended_startupinfo_present = true },
            null,
            null,
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
    }

    fn readLoop(self: *Pty) void {
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
