//! Ghostty plugin root module **and** intra-plugin import hub — the conventional `<name>.zig`.
//!
//! - The shell resolves `@import("ghostty")` to this file when compiled into the app statically;
//!   `ghostty.plugin` is its entry.
//! - Files under `src/` import it as `../ghostty.zig` for shared deps (`sdk`/`dvui`) and types.
//!
//! It must sit at the plugin root (a Zig module can't import above its root file's directory).
pub const sdk = @import("sdk");
pub const dvui = @import("dvui");

pub const plugin = @import("src/plugin.zig");
pub const State = @import("src/State.zig");
pub const render = @import("src/render.zig");

/// libghostty-vt C API (from the ghostty_vt package dependency).
pub const c = @import("src/c.zig").c;
