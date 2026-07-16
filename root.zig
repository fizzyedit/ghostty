//! Fizzy plugin dylib entry — the canonical third-party `root.zig`.
//!
//! `sdk.dylib.exportEntry` emits the required C symbols, wired to `src/plugin.zig`'s
//! `register` and `manifest`. The host-injected allocator and `*Host` live in the SDK
//! (`sdk.allocator()` / `sdk.host()`), so there is no storage file to write. See fizzy
//! `docs/PLUGINS.md` §2.
//!
//! `std_options` routes every `std.log`/`dvui.log` call in this dylib to the shell's Output
//! panel under the "ghostty" tab — see `sdk.dylib.stdOptions`'s doc comment.
const std = @import("std");
const sdk = @import("sdk");

pub const std_options: std.Options = sdk.dylib.stdOptions(@import("src/plugin.zig"));

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
