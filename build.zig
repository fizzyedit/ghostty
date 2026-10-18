//! Standalone build for the ghostty plugin — the canonical third-party shape.
//! `zig build` produces `ghostty.<dylib|dll|so>`. Install with
//! `--prefix <plugins-dir>` so the host finds `ghostty.dylib`.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });

    // libghostty-vt: VT parser + terminal state machine. Built with Zig 0.15.x in
    // fizzyedit/ghostty_vt and consumed here as a normal package dependency (see
    // build.zig.zon). Pick the static lib for the current target.
    const ghostty_vt = b.dependency("ghostty_vt", .{});
    const ghostty_vt_lib = switch (target.result.os.tag) {
        .macos => "lib/macos-universal/libghostty-vt.a",
        .windows => switch (target.result.cpu.arch) {
            .aarch64 => "lib/windows-aarch64/ghostty-vt-static.lib",
            else => "lib/windows-x86_64/ghostty-vt-static.lib",
        },
        .linux => switch (target.result.cpu.arch) {
            .aarch64 => "lib/linux-aarch64/libghostty-vt.a",
            else => "lib/linux-x86_64/libghostty-vt.a",
        },
        else => @panic("unsupported target for ghostty_vt"),
    };
    plugin.module.addIncludePath(ghostty_vt.path("include"));
    // libghostty-vt's header, translated once into a module of its own (`c`): Zig 0.17 removed
    // `@cImport`. `GHOSTTY_STATIC` makes `GHOSTTY_API` a no-op, right for the static lib.
    const vt_h = b.addTranslateC(.{
        .root_source_file = ghostty_vt.path("include/ghostty/vt.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vt_h.addIncludePath(ghostty_vt.path("include"));
    vt_h.defineCMacro("GHOSTTY_STATIC", "1");
    plugin.module.addImport("c", vt_h.createModule());
    plugin.module.addObjectFile(ghostty_vt.path(ghostty_vt_lib));
    plugin.module.link_libc = true;

    fizzy.plugin.install(b, plugin.lib, .{});
}
