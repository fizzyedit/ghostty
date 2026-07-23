//! Ghostty terminal plugin — contributes a single bottom-panel tab ("Ghostty") that embeds
//! a libghostty-vt terminal beside pixi's "Sprites" tab. The shell shows a tab strip
//! automatically when more than one plugin contributes a bottom view, so this is purely
//! additive — no shell or pixi changes.
//!
//! This is a "shell"/utility plugin: it owns no documents, so it implements none of the
//! document vtable hooks (only `deinit`). See fizzy `docs/PLUGINS.md`.
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const State = @import("src/State.zig");
const render = @import("src/render.zig");
const input = @import("src/input.zig");

/// Injected at build time from `plugin.zig.zon` — required by fizzy's generated dylib root,
/// which reaches its own copy of this plugin's identity through this export rather than
/// importing `fizzy_plugin_options` itself (see fizzy's `docs/PLUGINS.md` §2.5).
pub const plugin_options = @import("fizzy_plugin_options");

/// Stable, plugin-namespaced contribution id.
const bottom_terminal = "ghostty.terminal";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_options.id,
    .display_name = plugin_options.name,
};

const icon_png = @embedFile("ICON.png");
const icon_source: dvui.ImageSource = .{ .imageFile = .{
    .bytes = icon_png,
    .name = "ICON.png",
    .invalidation = .ptr,
} };

fn drawPluginIcon(_: ?*anyopaque) void {
    _ = dvui.image(@src(), .{ .source = icon_source, .shrink = .ratio }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 32, .h = 32 },
    });
}

/// Only the hooks this plugin needs; every other vtable field stays `null`.
const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    .endFrame = endFrame,
};

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}

/// The plugin's own singleton state — a variable it owns. The SDK holds gpa/host.
var plugin_state: State = .{};

/// Entry point the host calls once at startup (static) or after dlopen (dynamic). Wire state,
/// register the plugin, then add the bottom-panel Ghostty tab.
pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
    try host.registerPluginIcon(.{ .owner = &plugin, .draw = drawPluginIcon });
    try host.registerBottomView(.{
        .id = bottom_terminal,
        .owner = &plugin,
        .title = "Ghostty",
        .ctx = &plugin_state,
        .draw = render.drawTerminal,
        // Stay visible even with no active document, like pixi's Sprites tab.
        .persistent = true,
    });
}

/// Stable `*Plugin` accessor (part of the conventional plugin surface).
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn deinit(_: *anyopaque) void {
    plugin_state.deinit(sdk.allocator());
}

fn endFrame(_: *anyopaque) void {
    if (!sdk.host().isActiveBottomView(bottom_terminal)) return;
    input.handleLateFocus(&plugin_state);
}
