//! Standalone build for the ghostty plugin — the canonical third-party shape.
//! `zig build` produces `ghostty.<dylib|dll|so>`. Install with
//! `--prefix <plugins-dir>` so the host finds `ghostty.dylib`.
const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = fizzy.plugin.create(b, .{
        .name = "ghostty",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });

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
    lib.root_module.addIncludePath(ghostty_vt.path("include"));
    lib.root_module.addObjectFile(ghostty_vt.path(ghostty_vt_lib));
    lib.root_module.link_libc = true;

    fizzy.plugin.install(b, lib, .{});
}
