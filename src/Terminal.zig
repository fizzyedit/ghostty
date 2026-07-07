//! Thin wrapper around a libghostty-vt terminal + its render-state snapshot objects.
//!
//! Owns the C handles and their lifecycle. The renderer (`render.zig`) drives `update()` once
//! per frame and then walks rows/cells via the iteration helpers below. In M3b a mutex (held by
//! the PTY read thread during `write`) will guard `update`/`write` for thread safety; the
//! handles themselves live here.
const std = @import("std");
const ghostty = @import("../ghostty.zig");
const c = ghostty.c;

const Terminal = @This();

pub const Rgb = c.GhosttyColorRgb;

term: c.GhosttyTerminal = null,
state: c.GhosttyRenderState = null,
rows_iter: c.GhosttyRenderStateRowIterator = null,
cells: c.GhosttyRenderStateRowCells = null,
key_encoder: c.GhosttyKeyEncoder = null,
key_event: c.GhosttyKeyEvent = null,
cols: u16,
rows: u16,

pub fn init(cols: u16, rows: u16) !Terminal {
    var self: Terminal = .{ .cols = cols, .rows = rows };

    const opts = c.GhosttyTerminalOptions{ .cols = cols, .rows = rows, .max_scrollback = 10_000 };
    if (c.ghostty_terminal_new(null, &self.term, opts) != c.GHOSTTY_SUCCESS) return error.GhosttyTerminalInit;
    errdefer c.ghostty_terminal_free(self.term);

    if (c.ghostty_render_state_new(null, &self.state) != c.GHOSTTY_SUCCESS) return error.GhosttyRenderStateInit;
    errdefer c.ghostty_render_state_free(self.state);

    if (c.ghostty_render_state_row_iterator_new(null, &self.rows_iter) != c.GHOSTTY_SUCCESS) return error.GhosttyRowIterInit;
    errdefer c.ghostty_render_state_row_iterator_free(self.rows_iter);

    if (c.ghostty_render_state_row_cells_new(null, &self.cells) != c.GHOSTTY_SUCCESS) return error.GhosttyCellsInit;

    // Input: a key encoder (synced from terminal modes per keypress) + a reusable key event.
    if (c.ghostty_key_encoder_new(null, &self.key_encoder) != c.GHOSTTY_SUCCESS) return error.GhosttyKeyEncoderInit;
    errdefer c.ghostty_key_encoder_free(self.key_encoder);
    if (c.ghostty_key_event_new(null, &self.key_event) != c.GHOSTTY_SUCCESS) return error.GhosttyKeyEventInit;

    return self;
}

pub fn deinit(self: *Terminal) void {
    if (self.key_event != null) c.ghostty_key_event_free(self.key_event);
    if (self.key_encoder != null) c.ghostty_key_encoder_free(self.key_encoder);
    if (self.cells != null) c.ghostty_render_state_row_cells_free(self.cells);
    if (self.rows_iter != null) c.ghostty_render_state_row_iterator_free(self.rows_iter);
    if (self.state != null) c.ghostty_render_state_free(self.state);
    if (self.term != null) c.ghostty_terminal_free(self.term);
    self.* = undefined;
}

/// Feed VT bytes (PTY output) into the parser.
pub fn write(self: *Terminal, bytes: []const u8) void {
    c.ghostty_terminal_vt_write(self.term, bytes.ptr, bytes.len);
}

/// Encode a key press into terminal input bytes (written into `out`). Syncs the encoder from
/// the terminal's current modes first (DECCKM, Kitty keyboard flags, etc.), so call this under
/// the same lock that guards the terminal. `key` is a GhosttyKey, `unshifted_cp` the base
/// codepoint (0 for non-text keys), `mods` a GhosttyMods bitmask.
pub fn encodeKey(self: *Terminal, key: c_int, unshifted_cp: u32, mods: c.GhosttyMods, utf8: []const u8, out: []u8) []const u8 {
    c.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.term);
    c.ghostty_key_event_set_action(self.key_event, c.GHOSTTY_KEY_ACTION_PRESS);
    c.ghostty_key_event_set_key(self.key_event, @intCast(key));
    c.ghostty_key_event_set_mods(self.key_event, mods);
    c.ghostty_key_event_set_unshifted_codepoint(self.key_event, unshifted_cp);
    c.ghostty_key_event_set_utf8(self.key_event, utf8.ptr, utf8.len);

    var written: usize = 0;
    if (c.ghostty_key_encoder_encode(self.key_encoder, self.key_event, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return out[0..0];
    return out[0..written];
}

pub const Scrollbar = c.GhosttyTerminalScrollbar;

/// Scrollbar geometry for the terminal viewport (row counts).
pub fn scrollbar(self: *Terminal) Scrollbar {
    var sb: Scrollbar = undefined;
    _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
    return sb;
}

/// Row offset of the bottom of the scrollable range (inclusive).
pub fn maxScrollOffsetRows(sb: Scrollbar) u64 {
    if (sb.total <= sb.len) return 0;
    return sb.total - sb.len;
}

/// True when the viewport is pinned to live output (never scrolled up, or scrolled back to bottom).
pub fn isAtBottom(self: *Terminal) bool {
    if (self.viewportActive()) return true;
    const sb = self.scrollbar();
    if (sb.total <= sb.len) return true;
    return sb.offset >= maxScrollOffsetRows(sb);
}

/// Whether new output and input should keep the viewport at the bottom.
pub fn shouldFollowOutput(user_pinned_to_bottom: bool, term: *Terminal) bool {
    return user_pinned_to_bottom or isAtBottom(term);
}

/// True when libghostty-vt reports the viewport follows live shell output.
pub fn viewportActive(self: *Terminal) bool {
    var active: bool = false;
    _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active);
    return active;
}

pub fn scrollViewportDelta(self: *Terminal, delta: i32) void {
    const behavior: c.GhosttyTerminalScrollViewport = .{
        .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA,
        .value = .{ .delta = delta },
    };
    c.ghostty_terminal_scroll_viewport(self.term, behavior);
}

pub fn scrollViewportBottom(self: *Terminal) void {
    const behavior: c.GhosttyTerminalScrollViewport = .{
        .tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
        .value = .{ ._padding = .{ 0, 0 } },
    };
    c.ghostty_terminal_scroll_viewport(self.term, behavior);
}

pub fn resize(self: *Terminal, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) void {
    _ = c.ghostty_terminal_resize(self.term, cols, rows, cell_w_px, cell_h_px);
    self.cols = cols;
    self.rows = rows;
}

/// Snapshot the live terminal into the render state. Read-only access to the render state is
/// valid until the next `update`.
pub fn update(self: *Terminal) void {
    _ = c.ghostty_render_state_update(self.state, self.term);
}

pub const Colors = c.GhosttyRenderStateColors;
pub fn colors(self: *Terminal) Colors {
    var out: Colors = undefined;
    out.size = @sizeOf(Colors);
    _ = c.ghostty_render_state_colors_get(self.state, &out);
    return out;
}

pub const Cursor = struct { x: u16, y: u16 };
/// The cursor position if it is both visible (by mode) and within the viewport, else null.
pub fn cursor(self: *Terminal) ?Cursor {
    var has_value: bool = false;
    _ = c.ghostty_render_state_get(self.state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &has_value);
    if (!has_value) return null;

    var visible: bool = false;
    _ = c.ghostty_render_state_get(self.state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible);
    if (!visible) return null;

    var x: u16 = 0;
    var y: u16 = 0;
    _ = c.ghostty_render_state_get(self.state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x);
    _ = c.ghostty_render_state_get(self.state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y);
    return .{ .x = x, .y = y };
}

/// Begin a fresh row walk over the current snapshot. Call before `nextRow`.
pub fn beginRows(self: *Terminal) void {
    _ = c.ghostty_render_state_get(self.state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.rows_iter));
}

/// Advance to the next row, loading its cells. Returns false at the end.
pub fn nextRow(self: *Terminal) bool {
    if (!c.ghostty_render_state_row_iterator_next(self.rows_iter)) return false;
    _ = c.ghostty_render_state_row_get(self.rows_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.cells));
    return true;
}

/// Advance to the next cell in the current row. Returns false at the end of the row.
pub fn nextCell(self: *Terminal) bool {
    return c.ghostty_render_state_row_cells_next(self.cells);
}

/// Visual attributes of a cell that the renderer applies itself.
pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    inverse: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    /// UTF-8 grapheme bytes (sub-slice of the caller's buffer). Empty for a blank cell.
    text: []const u8,
    /// Resolved colors, or null to mean "use the terminal default".
    fg: ?Rgb,
    bg: ?Rgb,
    style: Style,
};

/// Read the current cell's text, resolved colors, and style. `text_buf` receives the UTF-8
/// grapheme.
pub fn cell(self: *Terminal, text_buf: []u8) Cell {
    var fg: ?Rgb = null;
    var bg: ?Rgb = null;

    var fg_rgb: Rgb = undefined;
    if (c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg_rgb) == c.GHOSTTY_SUCCESS) fg = fg_rgb;

    var bg_rgb: Rgb = undefined;
    if (c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg_rgb) == c.GHOSTTY_SUCCESS) bg = bg_rgb;

    // Only materialize the full style for cells that actually carry styling.
    var style: Style = .{};
    var has_styling: bool = false;
    _ = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &has_styling);
    if (has_styling) {
        var s: c.GhosttyStyle = undefined;
        s.size = @sizeOf(c.GhosttyStyle);
        if (c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &s) == c.GHOSTTY_SUCCESS) {
            style = .{
                .bold = s.bold,
                .italic = s.italic,
                .faint = s.faint,
                .inverse = s.inverse,
                .underline = s.underline != 0,
                .strikethrough = s.strikethrough,
            };
        }
    }

    var buffer = c.GhosttyBuffer{ .ptr = text_buf.ptr, .cap = text_buf.len, .len = 0 };
    _ = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);

    return .{ .text = text_buf[0..buffer.len], .fg = fg, .bg = bg, .style = style };
}
