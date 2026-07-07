//! Input bridge: dvui keyboard/mouse events → libghostty-vt encoders → PTY.
//!
//! Printable keys go through the ghostty key encoder (dvui `.text` events are unreliable in
//! plugin dylibs — SDL text input is tied to `TextEntryWidget`, not generic focus). IME /
//! composed input still arrives as `.text` when the platform sends it.
const std = @import("std");
const ghostty = @import("../ghostty.zig");
const dvui = ghostty.dvui;
const c = ghostty.c;
const State = ghostty.State;
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");

/// Process keyboard/mouse events during `drawTerminal` (widget is live here).
pub fn handle(state: *State, wd: *dvui.WidgetData) void {
    dvui.tabIndexSet(wd.id, null, wd.rectScale().r);

    const term = if (state.terminal) |*t| t else return;
    const pty = if (state.pty) |*p| p else return;

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;
        processEvent(state, wd, term, pty, e);
    }
}

/// Click-to-focus after the full frame is drawn. The center canvas (drawn after the bottom
/// panel) can swallow or mishandle the `.focus` mouse event; reclaim focus when the click
/// landed in our saved screen rect.
pub fn handleLateFocus(state: *State) void {
    const rect = state.input_rect orelse return;
    const wd_id = state.input_widget_id;
    if (wd_id == .zero) return;

    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .focus or !me.button.pointer()) continue;
        if (!rect.contains(me.p)) continue;
        e.handled = true;
        dvui.focusWidget(wd_id, null, e.num);
    }
}

fn processEvent(state: *State, wd: *dvui.WidgetData, term: *Terminal, pty: *Pty, e: *dvui.Event) void {
    switch (e.evt) {
        .mouse => |me| {
            if (me.action == .focus and me.button.pointer()) {
                e.handle(@src(), wd);
                dvui.focusWidget(wd.id, null, e.num);
            }
        },
        .text => |te| switch (te.action) {
            .value => |v| {
                const txt = std.mem.sliceTo(v.txt, 0);
                const is_ctrl = txt.len == 1 and txt[0] < 0x20;
                if (txt.len > 0 and !is_ctrl) {
                    pinViewportOnInput(state, term);
                    pty.write(txt);
                }
                e.handle(@src(), wd);
            },
            .selection => {},
        },
        .key => |ke| {
            if (ke.action != .down and ke.action != .repeat) return;
            const m = mapKey(ke.code) orelse return;

            var utf8_buf: [4]u8 = undefined;
            const utf8 = typedUtf8(m, ke.mod, &utf8_buf);

            var buf: [64]u8 = undefined;
            state.lock();
            pinViewportOnInputLocked(state, term);
            const bytes = term.encodeKey(m.key, m.cp, mapMods(ke.mod), utf8, &buf);
            state.unlock();
            if (bytes.len > 0) {
                pty.write(bytes);
                e.handle(@src(), wd);
            }
        },
        else => {},
    }
}

/// Typing always jumps back to the live prompt (standard terminal behavior).
fn pinViewportOnInput(state: *State, term: *Terminal) void {
    state.lock();
    defer state.unlock();
    pinViewportOnInputLocked(state, term);
}

fn pinViewportOnInputLocked(state: *State, term: *Terminal) void {
    state.pinToBottom(term, state.panel_viewport_h);
}

fn mapMods(mod: dvui.enums.Mod) c.GhosttyMods {
    var m: c_int = 0;
    if (mod.shift()) m |= c.GHOSTTY_MODS_SHIFT;
    if (mod.control()) m |= c.GHOSTTY_MODS_CTRL;
    if (mod.alt()) m |= c.GHOSTTY_MODS_ALT;
    if (mod.command()) m |= c.GHOSTTY_MODS_SUPER;
    return @intCast(m);
}

const Mapped = struct {
    key: c_int,
    cp: u32,
};

fn mapKey(code: dvui.enums.Key) ?Mapped {
    const Key = dvui.enums.Key;
    const ci = @intFromEnum(code);

    if (ci >= @intFromEnum(Key.a) and ci <= @intFromEnum(Key.z)) {
        const off: c_int = @intCast(ci - @intFromEnum(Key.a));
        return .{ .key = c.GHOSTTY_KEY_A + off, .cp = @intCast('a' + off) };
    }
    if (ci >= @intFromEnum(Key.zero) and ci <= @intFromEnum(Key.nine)) {
        const off: c_int = @intCast(ci - @intFromEnum(Key.zero));
        return .{ .key = c.GHOSTTY_KEY_DIGIT_0 + off, .cp = @intCast('0' + off) };
    }
    if (ci >= @intFromEnum(Key.f1) and ci <= @intFromEnum(Key.f12)) {
        const off: c_int = @intCast(ci - @intFromEnum(Key.f1));
        return .{ .key = c.GHOSTTY_KEY_F1 + off, .cp = 0 };
    }

    return switch (code) {
        .enter, .kp_enter => .{ .key = c.GHOSTTY_KEY_ENTER, .cp = 0 },
        .tab => .{ .key = c.GHOSTTY_KEY_TAB, .cp = 0 },
        .backspace => .{ .key = c.GHOSTTY_KEY_BACKSPACE, .cp = 0 },
        .escape => .{ .key = c.GHOSTTY_KEY_ESCAPE, .cp = 0 },
        .up => .{ .key = c.GHOSTTY_KEY_ARROW_UP, .cp = 0 },
        .down => .{ .key = c.GHOSTTY_KEY_ARROW_DOWN, .cp = 0 },
        .left => .{ .key = c.GHOSTTY_KEY_ARROW_LEFT, .cp = 0 },
        .right => .{ .key = c.GHOSTTY_KEY_ARROW_RIGHT, .cp = 0 },
        .home => .{ .key = c.GHOSTTY_KEY_HOME, .cp = 0 },
        .end => .{ .key = c.GHOSTTY_KEY_END, .cp = 0 },
        .page_up => .{ .key = c.GHOSTTY_KEY_PAGE_UP, .cp = 0 },
        .page_down => .{ .key = c.GHOSTTY_KEY_PAGE_DOWN, .cp = 0 },
        .insert => .{ .key = c.GHOSTTY_KEY_INSERT, .cp = 0 },
        .delete => .{ .key = c.GHOSTTY_KEY_DELETE, .cp = 0 },

        .space => .{ .key = c.GHOSTTY_KEY_SPACE, .cp = ' ' },
        .minus => .{ .key = c.GHOSTTY_KEY_MINUS, .cp = '-' },
        .equal => .{ .key = c.GHOSTTY_KEY_EQUAL, .cp = '=' },
        .left_bracket => .{ .key = c.GHOSTTY_KEY_BRACKET_LEFT, .cp = '[' },
        .right_bracket => .{ .key = c.GHOSTTY_KEY_BRACKET_RIGHT, .cp = ']' },
        .backslash => .{ .key = c.GHOSTTY_KEY_BACKSLASH, .cp = '\\' },
        .semicolon => .{ .key = c.GHOSTTY_KEY_SEMICOLON, .cp = ';' },
        .apostrophe => .{ .key = c.GHOSTTY_KEY_QUOTE, .cp = '\'' },
        .comma => .{ .key = c.GHOSTTY_KEY_COMMA, .cp = ',' },
        .period => .{ .key = c.GHOSTTY_KEY_PERIOD, .cp = '.' },
        .slash => .{ .key = c.GHOSTTY_KEY_SLASH, .cp = '/' },
        .grave => .{ .key = c.GHOSTTY_KEY_BACKQUOTE, .cp = '`' },

        else => null,
    };
}

/// UTF-8 for the typed character (US QWERTY shift pairs). Used as `ghostty_key_event_set_utf8`.
fn typedUtf8(m: Mapped, mod: dvui.enums.Mod, buf: *[4]u8) []const u8 {
    if (m.cp == 0) return "";

    var cp: u32 = m.cp;
    if (mod.shift()) {
        if (cp >= 'a' and cp <= 'z') {
            cp -= 32;
        } else if (shiftedCp(m.key)) |shifted| {
            cp = shifted;
        }
    }

    const len = std.unicode.utf8Encode(@intCast(cp), buf) catch return "";
    return buf[0..len];
}

fn shiftedCp(key: c_int) ?u32 {
    return switch (key) {
        c.GHOSTTY_KEY_BACKQUOTE => '~',
        c.GHOSTTY_KEY_MINUS => '_',
        c.GHOSTTY_KEY_EQUAL => '+',
        c.GHOSTTY_KEY_BRACKET_LEFT => '{',
        c.GHOSTTY_KEY_BRACKET_RIGHT => '}',
        c.GHOSTTY_KEY_BACKSLASH => '|',
        c.GHOSTTY_KEY_SEMICOLON => ':',
        c.GHOSTTY_KEY_QUOTE => '"',
        c.GHOSTTY_KEY_COMMA => '<',
        c.GHOSTTY_KEY_PERIOD => '>',
        c.GHOSTTY_KEY_SLASH => '?',
        c.GHOSTTY_KEY_DIGIT_1 => '!',
        c.GHOSTTY_KEY_DIGIT_2 => '@',
        c.GHOSTTY_KEY_DIGIT_3 => '#',
        c.GHOSTTY_KEY_DIGIT_4 => '$',
        c.GHOSTTY_KEY_DIGIT_5 => '%',
        c.GHOSTTY_KEY_DIGIT_6 => '^',
        c.GHOSTTY_KEY_DIGIT_7 => '&',
        c.GHOSTTY_KEY_DIGIT_8 => '*',
        c.GHOSTTY_KEY_DIGIT_9 => '(',
        c.GHOSTTY_KEY_DIGIT_0 => ')',
        else => null,
    };
}
