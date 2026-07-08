//! A pseudoterminal running the user's shell, with a background reader thread.
//!
//! Unix (macOS/Linux): `forkpty` + reader thread (`Pty_unix.zig`).
//! Windows: ConPTY + PowerShell (`Pty_windows.zig`).
const builtin = @import("builtin");

const backend = if (builtin.os.tag == .windows)
    @import("Pty_windows.zig")
else
    @import("Pty_unix.zig");

pub const supported = backend.supported;
pub const OnData = backend.OnData;
pub const Pty = backend.Pty;
