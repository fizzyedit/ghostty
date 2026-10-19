//! One `terminal.run`: a program another plugin asked for (the chat's `claude /login`), in a
//! pane of its own beside the shell, which the person types into. When the program exits, the
//! caller's `done` command hears the code, and the pane stays with the exit shown until the
//! person closes it, so what the program said last can still be read.
//!
//! Lives on the GUI thread except where marked: the program is found on the login shell's
//! `PATH` off it (that resolution can take seconds the first time), and the PTY reader reports
//! the exit from its own thread. `poll` (each `endFrame`) carries both out.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const State = @import("State.zig");
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");
const launch = @import("launch.zig");
const render = @import("render.zig");

const Run = @This();

/// The terminal and its PTY, drawn as the shell's are. `pty` is null until the program starts.
state: State = .{},
/// The surface id, `ghostty.run.<n>`, and its title.
id: []u8,
title: []u8,
/// The request, kept in `arena` until the program has started.
arena: std.heap.ArenaAllocator,
request: launch.Request,
/// Off the GUI thread: the login shell's `PATH` (`core.shell_env`), then `resolved` set.
resolver: ?std.Thread = null,
login_path: ?[]const u8 = null,
resolved: std.atomic.Value(bool) = .init(false),
/// Reader thread: the exit code, once the program has gone.
code: std.atomic.Value(i32) = .init(running),
/// `done` has been told (`tell`).
reported: bool = false,
/// The person closed the pane: `poll`'s caller takes it away.
closing: bool = false,

const running = std.math.minInt(i32);
/// What `done` hears when the program could not be started at all, as a shell says it.
const not_started = 127;

/// A pane named `id` (taken) for `req`. The program runs once `begin` has found its `PATH`.
pub fn create(gpa: std.mem.Allocator, req: launch.Request, id: []u8) !*Run {
    const self = try gpa.create(Run);
    errdefer gpa.destroy(self);
    self.* = .{ .id = id, .title = &.{}, .arena = .init(gpa), .request = undefined };
    errdefer self.arena.deinit();
    const a = self.arena.allocator();
    // The caller's strings live in its arena, gone after the call.
    const env = try a.alloc(launch.Env, req.env.len);
    for (req.env, env) |e, *out| out.* = .{ .name = try a.dupe(u8, e.name), .value = try a.dupe(u8, e.value) };
    const argv = try a.alloc([]const u8, req.argv.len);
    for (req.argv, argv) |arg, *out| out.* = try a.dupe(u8, arg);
    self.request = .{
        .title = "",
        .argv = argv,
        .env = env,
        .cwd = try a.dupe(u8, req.cwd),
        .done = try a.dupe(u8, req.done),
        .tag = req.tag,
    };
    self.title = try gpa.dupe(u8, if (req.title.len > 0) req.title else req.argv[0]);
    errdefer gpa.free(self.title);
    // Drawn before the program starts; `poll` gives the PTY whatever size the pane made it.
    self.state.terminal = try Terminal.init(80, 24);
    return self;
}

/// Start looking for the program, once its pane has a place: until then nothing has started
/// that `destroy` would wait on.
pub fn begin(self: *Run) !void {
    self.resolver = try std.Thread.spawn(.{}, resolve, .{self});
}

fn resolve(self: *Run) void {
    self.login_path = sdk.core.shell_env.path(std.heap.page_allocator, dvui.io);
    self.resolved.store(true, .release);
    sdk.refresh();
}

/// GUI thread, each frame: start the program once its `PATH` is known, and report its exit.
pub fn poll(self: *Run) void {
    if (self.state.pty == null and self.code.load(.acquire) == running and self.resolved.load(.acquire)) self.start();
    const code = self.code.load(.acquire);
    if (code == running or self.reported) return;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\r\n\x1b[2m[exited with code {d}]\x1b[0m\r\n\x1b[?25l", .{code}) catch "";
    if (self.state.terminal != null) State.feed(&self.state, line);
    self.tell(code);
}

/// What `done` hears when the pane goes before the program does (closed, or the plugin
/// unloaded): it was hung up on, as a terminal's close does.
pub const hung_up = 128 + 1;

/// Call the caller's `done` with the exit, once. Unless it has gone (its plugin unloaded first).
pub fn tell(self: *Run, code: i32) void {
    if (self.reported) return;
    self.reported = true;
    const host = sdk.host();
    if (!host.hasCommand(self.request.done)) return;
    const arena = host.arena();
    const args = launch.write(arena, launch.Exited{ .tag = self.request.tag, .code = code }) catch return;
    switch (host.callCommand(self.request.done, args, arena)) {
        .ok => {},
        else => |o| dvui.log.warn("ghostty: {s} refused the exit of {s}: {any}", .{ self.request.done, self.title, o }),
    }
}

fn start(self: *Run) void {
    const a = self.arena.allocator();
    const env = launch.environment(a, self.request, self.login_path) catch &.{};
    const cwd: ?[]const u8 = if (self.request.cwd.len > 0) self.request.cwd else sdk.host().folder() orelse render.defaultCwd();
    const term = &self.state.terminal.?;
    self.state.lock();
    const cols = term.cols;
    const rows = term.rows;
    self.state.unlock();

    self.state.pty = Pty.Pty.open(&self.state, State.feed, cols, rows, cwd, .{ .argv = self.request.argv, .env = env }) catch |err| {
        var buf: [256]u8 = undefined;
        State.feed(&self.state, std.fmt.bufPrint(&buf, "Could not start {s}: {t}\r\n", .{ self.request.argv[0], err }) catch "");
        self.code.store(not_started, .release);
        return;
    };
    self.state.pty.?.on_exit = exited;
    self.state.pty.?.startReader() catch |err| {
        dvui.log.warn("ghostty: no reader for {s}: {t}", .{ self.title, err });
        self.state.pty.?.deinit();
        self.state.pty = null;
        self.code.store(not_started, .release);
    };
}

/// Reader thread: the program exited.
fn exited(ctx: *anyopaque, code: i32) void {
    const state: *State = @ptrCast(@alignCast(ctx));
    const self: *Run = @fieldParentPtr("state", state);
    self.code.store(code, .release);
    sdk.refresh();
}

/// The pane: a bar with what runs, how it ended, and a Close; then the terminal.
pub fn draw(ctx: ?*anyopaque) anyerror!dvui.App.Result {
    const self: *Run = @ptrCast(@alignCast(ctx orelse return .ok));
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4) });
        defer bar.deinit();
        const code = self.code.load(.acquire);
        if (code == running)
            dvui.label(@src(), "{s}", .{self.title}, .{ .gravity_y = 0.5 })
        else
            dvui.label(@src(), "{s} — exited with code {d}", .{ self.title, code }, .{ .gravity_y = 0.5 });
        // Closing a running program hangs up on it, and its caller hears so.
        if (dvui.button(@src(), "Close", .{}, .{ .gravity_x = 1, .gravity_y = 0.5 })) self.closing = true;
    }
    try render.drawTerminal(&self.state);
    return .ok;
}

pub fn destroy(self: *Run, gpa: std.mem.Allocator) void {
    if (self.resolver) |t| t.join();
    self.state.deinit(gpa);
    self.arena.deinit();
    gpa.free(self.title);
    gpa.free(self.id);
    gpa.destroy(self);
}
