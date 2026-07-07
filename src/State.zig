//! Ghostty plugin state — owns the embedded terminal and its PTY. The host injects only the
//! allocator and `*Host` (read via `sdk.allocator()` / `sdk.host()`), so this is a plain struct
//! the plugin holds as a module-level singleton.
//!
//! M3b: the `Pty` reader thread calls `feed()` with shell output; it writes into `terminal`
//! under `mutex` (the renderer also locks `mutex` around its snapshot) and wakes the GUI via
//! `scheduleRepaint()`. Everything is created lazily on first draw of the tab.
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("sdk");
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");

const State = @This();

/// The embedded terminal, created lazily on first draw (sized to the panel). Null until then.
terminal: ?Terminal = null,
/// The shell PTY + reader thread feeding `terminal`. Null until first draw.
pty: ?Pty = null,
/// Guards concurrent access to `terminal` between the reader thread (`feed`) and the renderer.
/// Critical sections are tiny (a `vt_write` chunk; a render snapshot), so a brief spin is fine.
mutex: std.atomic.Mutex = .unlocked,
/// Terminal widget screen rect + id from the latest `drawTerminal` (for late click-to-focus).
input_rect: ?dvui.Rect.Physical = null,
input_widget_id: dvui.Id = .zero,
/// Set by the PTY reader when new bytes arrive; cleared after each successful paint.
dirty: std.atomic.Value(bool) = .init(false),
/// Drives the bottom-panel scrollbar; synced from libghostty-vt each frame (`.given` vertical size).
scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .none },
/// When true, the user has not scrolled up (or scrolled back to the bottom); output stays pinned.
user_pinned_to_bottom: bool = true,
/// Coalesce cross-thread GUI wakes to one SDL event per paint cycle.
repaint_pending: std.atomic.Value(bool) = .init(false),
/// Monospace cell height (logical points), refreshed each frame for scroll sync.
cell_h: f32 = 0,
/// Bottom-panel content height in logical points (matches the scroll area viewport).
panel_viewport_h: f32 = 0,
/// Wheel/track scroll accumulated by the scroll area this frame (set in deinit).
user_scroll_delta: dvui.Point = .{},
/// Last synced libghostty-vt scrollbar row counts (skip redundant scroll work).
last_sb_offset: u64 = 0,
last_sb_total: u64 = 0,
last_sb_len: u64 = 0,

pub fn scrollInfoRows(self: *const State) i64 {
    if (self.cell_h <= 0) return 0;
    return @intFromFloat(@round(self.scroll_info.offset(.vertical) / self.cell_h));
}

pub fn scrollbarChanged(self: *const State, sb: Terminal.Scrollbar) bool {
    return sb.offset != self.last_sb_offset or sb.total != self.last_sb_total or sb.len != self.last_sb_len;
}

pub fn noteScrollbar(self: *State, sb: Terminal.Scrollbar) void {
    self.last_sb_offset = sb.offset;
    self.last_sb_total = sb.total;
    self.last_sb_len = sb.len;
}

/// Push libghostty-vt scrollbar geometry into `ScrollInfo` (pixel units).
/// `viewport_h` must match the scroll area content height so offset clamping matches DVUI.
pub fn syncScrollInfoFromTerminal(self: *State, term: *Terminal, viewport_h: f32) void {
    if (self.cell_h <= 0 or viewport_h <= 0) return;
    const sb = term.scrollbar();
    self.scroll_info.virtual_size.h = @as(f32, @floatFromInt(sb.total)) * self.cell_h;
    const offset_px = @as(f32, @floatFromInt(sb.offset)) * self.cell_h;
    const max_offset = @max(0, self.scroll_info.virtual_size.h - viewport_h);
    self.scroll_info.scrollToOffset(.vertical, @min(offset_px, max_offset));
}

/// Pin the libghostty-vt viewport and DVUI scroll bar to the bottom.
pub fn pinToBottom(self: *State, term: *Terminal, viewport_h: f32) void {
    term.scrollViewportBottom();
    self.user_pinned_to_bottom = true;
    self.syncScrollInfoFromTerminal(term, viewport_h);
}

/// Acquire `mutex` (spin — sections are short).
pub fn lock(self: *State) void {
    while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn unlock(self: *State) void {
    self.mutex.unlock();
}

pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
    _ = gpa;
    // Stop the reader thread first so nothing touches `terminal` after we free it.
    if (self.pty) |*p| p.deinit();
    self.pty = null;
    if (self.terminal) |*t| t.deinit();
    self.terminal = null;
}

/// Wake the host GUI from the PTY reader thread via the shell `Host.refresh` API.
pub fn scheduleRepaint(self: *State) void {
    if (self.repaint_pending.swap(true, .acq_rel)) return;
    sdk.refresh();
}

/// `Pty.OnData` callback — runs on the reader thread. Feed bytes into the terminal under the
/// lock, then wake the GUI so the next frame re-snapshots and paints them.
pub fn feed(ctx: *anyopaque, bytes: []const u8) void {
    const self: *State = @ptrCast(@alignCast(ctx));
    {
        self.lock();
        defer self.unlock();
        if (self.terminal) |*t| {
            const follow = Terminal.shouldFollowOutput(self.user_pinned_to_bottom, t);
            t.write(bytes);
            if (follow) {
                t.scrollViewportBottom();
                self.user_pinned_to_bottom = true;
            }
        }
    }
    self.dirty.store(true, .release);
    self.scheduleRepaint();
}
