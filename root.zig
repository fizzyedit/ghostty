//! Fizzy plugin dylib entry — the canonical third-party `root.zig`.
//!
//! `sdk.dylib.exportEntry` emits the required C symbols, wired to `src/plugin.zig`'s
//! `register` and `manifest`. The host-injected allocator and `*Host` live in the SDK
//! (`sdk.allocator()` / `sdk.host()`), so there is no storage file to write. You should
//! never need to edit this file. See fizzy `docs/PLUGINS.md` §2.
const sdk = @import("sdk");

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
