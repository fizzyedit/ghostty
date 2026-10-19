//! `terminal.run`: the seam another plugin calls to run a program in a terminal the person types
//! into (the chat's sign-in, `claude /login`), and the call back when it exits. Plugins meet only
//! at the host's commands, so this is the contract written down on this side; the chat writes the
//! same shape (`auth.TerminalRun`, `auth.Exited` in fizzyedit/chat's `src/auth.zig`). Std-only,
//! so its tests run without a window.
const std = @import("std");

/// The command's id: a seam named for what it does, not for this plugin, so any terminal plugin
/// can offer it.
pub const command_id = "terminal.run";

/// One variable over the app's environment (the PTY's own type, so a request passes straight through).
pub const Env = @import("Pty.zig").Env;

/// `terminal.run`'s arguments: run `argv` in `cwd` (empty: the project folder), over the app's
/// environment plus `env`, in a pane titled `title`; when it exits, call command `done` with
/// `Exited{ .tag = tag, .code = … }`.
pub const Request = struct {
    title: []const u8,
    argv: []const []const u8,
    env: []const Env = &.{},
    cwd: []const u8 = "",
    done: []const u8,
    tag: u64 = 0,
};

/// What `done` is called with.
pub const Exited = struct { tag: u64 = 0, code: i32 };

/// The arguments, in `arena`. Fields this plugin does not know yet are left alone, so a caller
/// can add one without breaking an older terminal.
pub fn parse(arena: std.mem.Allocator, zon: []const u8) !Request {
    const src = try arena.dupeSentinel(u8, std.mem.trim(u8, zon, " \t\r\n"), 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const req = try std.zon.parse.fromSlice(Request, .{
        .gpa = arena,
        .arena = arena,
        .source = src,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    });
    if (req.argv.len == 0 or req.argv[0].len == 0) return error.NoProgram;
    if (req.done.len == 0) return error.NoDoneCommand;
    return req;
}

/// `Exited` as `done`'s arguments.
pub fn write(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(value, .{ .whitespace = false, .emit_default_optional_fields = false }, &out.writer);
    return out.written();
}

/// The environment the program gets over the app's: the login shell's `PATH` first (a fizzy
/// started from the Dock has only the system's, and the program, `npx` say, is on the person's),
/// then the request's own, which win.
pub fn environment(arena: std.mem.Allocator, req: Request, login_path: ?[]const u8) ![]const Env {
    var out: std.ArrayListUnmanaged(Env) = .empty;
    const own_path = for (req.env) |e| {
        if (std.mem.eql(u8, e.name, "PATH")) break true;
    } else false;
    if (login_path) |p| if (!own_path) try out.append(arena, .{ .name = "PATH", .value = p });
    try out.appendSlice(arena, req.env);
    return out.items;
}

const testing = std.testing;

test "the request reads as the chat writes it, and a later field is ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sent: Request = .{
        .title = "Sign in: Claude",
        .argv = &.{ "claude", "/login" },
        .env = &.{.{ .name = "LOGIN_MODE", .value = "interactive" }},
        .cwd = "/tmp",
        .done = "agent.terminal_done",
        .tag = 7,
    };
    const req = try parse(a, try write(a, sent));
    try testing.expectEqualStrings("Sign in: Claude", req.title);
    try testing.expectEqual(@as(usize, 2), req.argv.len);
    try testing.expectEqualStrings("/login", req.argv[1]);
    try testing.expectEqualStrings("LOGIN_MODE", req.env[0].name);
    try testing.expectEqualStrings("interactive", req.env[0].value);
    try testing.expectEqualStrings("agent.terminal_done", req.done);
    try testing.expectEqual(@as(u64, 7), req.tag);

    const newer = try parse(a, ".{ .title = \"t\", .argv = .{\"sh\"}, .done = \"x.done\", .shell = true }");
    try testing.expectEqualStrings("", newer.cwd);
    try testing.expectEqual(@as(usize, 0), newer.env.len);

    try testing.expectError(error.NoProgram, parse(a, ".{ .title = \"t\", .argv = .{}, .done = \"x.done\" }"));
    try testing.expectError(error.NoDoneCommand, parse(a, ".{ .title = \"t\", .argv = .{\"sh\"}, .done = \"\" }"));
}

test "the exit goes back as the chat reads it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zon = try write(a, Exited{ .tag = 7, .code = -1 });
    const src = try a.dupeSentinel(u8, zon, 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const back = try std.zon.parse.fromSlice(Exited, .{ .gpa = a, .arena = a, .source = src, .diagnostics = &diag });
    try testing.expectEqual(@as(u64, 7), back.tag);
    try testing.expectEqual(@as(i32, -1), back.code);
}

test "the login PATH goes under the request's environment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var req: Request = .{ .title = "", .argv = &.{"x"}, .done = "d", .env = &.{.{ .name = "A", .value = "1" }} };
    const env = try environment(a, req, "/opt/bin:/usr/bin");
    try testing.expectEqualStrings("PATH", env[0].name);
    try testing.expectEqualStrings("A", env[1].name);
    req.env = &.{.{ .name = "PATH", .value = "/mine" }};
    const own = try environment(a, req, "/opt/bin");
    try testing.expectEqual(@as(usize, 1), own.len);
    try testing.expectEqualStrings("/mine", own[0].value);
}
