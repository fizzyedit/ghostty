//! A pseudoterminal running the user's shell, or a program another plugin asked for, with a
//! background reader thread.
//!
//! Unix (macOS/Linux): `forkpty` + reader thread (`Pty_unix.zig`).
//! Windows: ConPTY + PowerShell (`Pty_windows.zig`).
const builtin = @import("builtin");

const backend = if (builtin.target.os.tag == .windows)
    @import("Pty_windows.zig")
else
    @import("Pty_unix.zig");

pub const supported = backend.supported;
pub const OnData = backend.OnData;
pub const OnExit = backend.OnExit;
pub const Pty = backend.Pty;

pub const Env = struct { name: []const u8, value: []const u8 };

/// A program to run in the terminal instead of the user's shell.
pub const Command = struct {
    /// `argv[0]` is found on the child's `PATH` (`env` included) unless it names a path.
    argv: []const []const u8,
    /// Over the app's own environment, with `TERM=xterm-256color` unless this sets it.
    env: []const Env = &.{},
};
