//! Ghostty terminal plugin — contributes a bottom-panel tab ("Ghostty") that embeds a
//! libghostty-vt terminal beside pixi's "Sprites" tab. The shell shows a tab strip
//! automatically when more than one plugin contributes a bottom view, so this is purely
//! additive — no shell or pixi changes.
//!
//! It also offers `terminal.run` (`src/launch.zig`): another plugin runs a program in a pane of
//! its own here and hears its exit code, without either importing the other (`src/Run.zig`).
//!
//! This is a "shell"/utility plugin: it owns no documents, so it implements none of the
//! document vtable hooks (only `deinit`). See fizzy `docs/PLUGINS.md`.
const sdk = @import("fizzy_sdk");
const std = @import("std");
const dvui = @import("dvui");
const State = @import("src/State.zig");
const render = @import("src/render.zig");
const input = @import("src/input.zig");
const launch = @import("src/launch.zig");
const Run = @import("src/Run.zig");

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

fn paint(_: ?*anyopaque, subject: sdk.Host.Painter.Subject) bool {
    if (subject != .plugin_logo) return false;
    // `expand = .ratio` fits the logo to whatever rect the host reserved (see `Host.PluginIcon`):
    // 32px on a plugin-store card, a much smaller row glyph in the settings tree.
    // `min_size_content` is only the size asked for when the host leaves it to us.
    _ = dvui.image(@src(), .{ .source = icon_source, .shrink = .ratio }, .{
        .expand = .ratio,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 32, .h = 32 },
    });
    return true;
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
/// The `terminal.run` panes, open until the person closes them.
var runs: std.ArrayListUnmanaged(*Run) = .empty;
var next_run: u32 = 0;

/// Entry point the host calls once at startup (static) or after dlopen (dynamic). Wire state,
/// register the plugin, then add the bottom-panel Ghostty tab.
pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
    try host.registerPainter(.{ .owner = &plugin, .draw = paint });
    try host.registerSurface(.{
        .id = bottom_terminal,
        .owner = &plugin,
        .title = "Ghostty",
        .keywords = sdk.keywords.ide.panel,
        .ctx = &plugin_state,
        .draw = drawSurface,
        // Stay visible even with no active document, like pixi's Sprites tab.
        .persistent = true,
    });
    try host.registerCommand(.{
        .id = launch.command_id,
        .owner = &plugin,
        .title = "Terminal: Run a Program",
        // Another plugin's call (`launch.Request`), not something a person runs by hand.
        .visibility = .internal,
        .runWith = runCommand,
    });
}

/// `terminal.run`: open a pane running the request's program, and show it.
fn runCommand(_: *anyopaque, c: *sdk.Command.Call) anyerror!void {
    const req = launch.parse(c.arena, c.args) catch |err| {
        c.bad_args = true;
        return c.fail("expected {s}'s arguments (title, argv, env, cwd, done, tag): {t}", .{ launch.command_id, err });
    };
    const gpa = sdk.allocator();
    const host = sdk.host();
    try runs.ensureUnusedCapacity(gpa, 1);
    const id = try std.fmt.allocPrint(gpa, "ghostty.run.{d}", .{next_run});
    const run = Run.create(gpa, req, id) catch |err| {
        gpa.free(id);
        return c.fail("could not open a terminal for {s}: {t}", .{ req.argv[0], err });
    };
    errdefer run.destroy(gpa);
    try host.registerSurface(.{
        .id = run.id,
        .owner = &plugin,
        .title = run.title,
        .keywords = sdk.keywords.ide.panel,
        .ctx = run,
        .draw = Run.draw,
        .persistent = true,
    });
    if (!host.revealSurface(run.id)) {
        host.unregisterSurface(run.id);
        return c.fail("this app has no place to show a terminal", .{});
    }
    run.begin() catch |err| {
        host.unregisterSurface(run.id);
        return c.fail("could not start {s}: {t}", .{ req.argv[0], err });
    };
    next_run += 1;
    runs.appendAssumeCapacity(run);
}

fn drawSurface(ctx: ?*anyopaque) anyerror!dvui.App.Result {
    try render.drawTerminal(ctx);
    return .ok;
}

/// Stable `*Plugin` accessor (part of the conventional plugin surface).
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn deinit(_: *anyopaque) void {
    const gpa = sdk.allocator();
    for (runs.items) |run| {
        // A program still running is hung up on; its caller hears so, if it is still loaded.
        run.tell(Run.hung_up);
        sdk.host().unregisterSurface(run.id);
        run.destroy(gpa);
    }
    runs.deinit(gpa);
    plugin_state.deinit(gpa);
}

fn endFrame(_: *anyopaque) void {
    const host = sdk.host();
    var i: usize = 0;
    while (i < runs.items.len) {
        const run = runs.items[i];
        run.poll();
        if (!run.closing) {
            i += 1;
            continue;
        }
        run.tell(Run.hung_up);
        host.unregisterSurface(run.id);
        _ = runs.orderedRemove(i);
        run.destroy(sdk.allocator());
    }

    // Focus handling only for the terminal that is the panel's chosen surface.
    const chosen = host.selectionFor(sdk.keywords.ide.panel) orelse return;
    if (std.mem.eql(u8, chosen, bottom_terminal)) return input.handleLateFocus(&plugin_state);
    for (runs.items) |run| if (std.mem.eql(u8, chosen, run.id)) return input.handleLateFocus(&run.state);
}
