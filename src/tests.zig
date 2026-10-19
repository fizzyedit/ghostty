//! The tests that need no window: `zig build test`.
const builtin = @import("builtin");

test {
    _ = @import("launch.zig");
    if (builtin.target.os.tag != .windows) _ = @import("Pty_unix.zig");
}
