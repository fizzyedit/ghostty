//! C bindings for libghostty-vt (from the ghostty_vt package dependency). The include path
//! and static archive are wired in `build.zig`. `GHOSTTY_STATIC` makes the `GHOSTTY_API`
//! visibility/import-export attributes a no-op, which is correct when linking the static lib.
pub const c = @cImport({
    @cDefine("GHOSTTY_STATIC", "1");
    @cInclude("ghostty/vt.h");
});
