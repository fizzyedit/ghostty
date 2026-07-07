//! Terminal rendering — the `BottomView.draw` callback the shell invokes each frame.
//!
//! M3a: create a libghostty-vt terminal, feed it a static test string, and paint the grid via
//! the render-state API: per-cell background rect + monospace grapheme + cursor block. No PTY or
//! threads yet — this verifies the whole Terminal→render-state→dvui pipeline. M3b swaps the
//! static feed for a live `forkpty` shell + read thread; M5 makes the grid track the panel size.
const std = @import("std");
const ghostty = @import("../ghostty.zig");
const dvui = ghostty.dvui;
const State = ghostty.State;
const Terminal = @import("Terminal.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");

/// `BottomView.draw`: `fn(ctx: ?*anyopaque) anyerror!void`. `ctx` is the plugin's `*State`.
pub fn drawTerminal(ctx: ?*anyopaque) anyerror!void {
    const state: *State = @ptrCast(@alignCast(ctx orelse return));

    state.repaint_pending.store(false, .release);

    const font = dvui.Font.theme(.mono);
    const cell_w = font.textSize("M").w; // monospace advance (logical points)
    const cell_h = font.lineHeight();
    state.cell_h = cell_h;

    // Top-level box fills the bottom-panel content area (same layout as before scroll area).
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();

    const outer_rs = outer.data().rectScale();
    if (outer_rs.r.w <= 0 or outer_rs.r.h <= 0 or outer_rs.s <= 0) return;
    state.panel_viewport_h = outer_rs.r.h / outer_rs.s;

    const grid = gridSizeFromPanel(outer_rs, cell_w, cell_h);

    // Lazily create the terminal + shell PTY, sized to fit the panel.
    if (state.terminal == null) {
        state.terminal = try Terminal.init(grid.cols, grid.rows);
        state.pty = try Pty.open(state, State.feed, grid.cols, grid.rows);
        state.pty.?.setSize(grid.cols, grid.rows, grid.cell_w_px, grid.cell_h_px);
        try state.pty.?.startReader();
    }
    const term = &state.terminal.?;

    state.lock();
    if (term.cols != grid.cols or term.rows != grid.rows) {
        term.resize(grid.cols, grid.rows, grid.cell_w_px, grid.cell_h_px);
        if (state.pty) |*p| p.setSize(grid.cols, grid.rows, grid.cell_w_px, grid.cell_h_px);
    }
    term.update();
    state.scroll_info.virtual_size.h = @as(f32, @floatFromInt(term.scrollbar().total)) * cell_h;
    state.unlock();

    var scroll_area = dvui.scrollArea(@src(), .{
        .scroll_info = &state.scroll_info,
        .vertical_bar = .auto_overlay,
        .horizontal_bar = .hide,
        .user_scroll = &state.user_scroll_delta,
        // Keep the terminal grid fixed on screen; only the scrollbar / wheel move the viewport.
        .frame_viewport = .{ .x = 0, .y = 0 },
    }, .{
        .expand = .both,
        .background = false,
        .style = .content,
    });

    var term_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .min_size_content = .{ .w = @as(f32, @floatFromInt(term.cols)) * cell_w, .h = @as(f32, @floatFromInt(term.rows)) * cell_h },
    });

    const rs = term_box.data().rectScale();
    if (rs.r.w <= 0 or rs.r.h <= 0 or rs.s <= 0) {
        term_box.deinit();
        scroll_area.deinit();
        return;
    }

    state.input_rect = rs.r;
    state.input_widget_id = term_box.data().id;

    input.handle(state, term_box.data());

    const theme = dvui.themeGet();
    const default_fg = theme.color(.window, .text);
    const default_bg = theme.color(.window, .fill);

    // Narrow to term_box's own bounds (a subset of scroll_area's viewport) for the cell
    // rendering below. Deliberately not saved/restored via `defer` here: this runs nested
    // inside scroll_area's own clip, which `scroll_area.deinit()` below already pops back
    // to the true outer ambient. A `defer`-based restore would fire *after* that (defers
    // run at actual function exit, not textual position), clobbering the correct wide
    // clip with this stale narrow snapshot.
    _ = dvui.clip(rs.r);

    const cw_phys = cell_w * rs.s;
    const ch_phys = cell_h * rs.s;

    term.beginRows();
    var row: u16 = 0;
    while (term.nextRow()) : (row += 1) {
        var col: u16 = 0;
        while (term.nextCell()) : (col += 1) {
            var buf: [32]u8 = undefined;
            const cell = term.cell(&buf);
            const cell_rect = cellRect(rs.r, col, row, cw_phys, ch_phys);

            var fg = if (cell.fg) |f| rgb(f) else default_fg;
            var bg: ?dvui.Color = if (cell.bg) |b| rgb(b) else null;
            if (cell.style.faint) fg = fg.opacity(0.55);
            if (cell.style.inverse) {
                const new_bg = fg;
                fg = bg orelse default_bg;
                bg = new_bg;
            }

            if (bg) |b| cell_rect.fill(.{}, .{ .color = b });

            if (cell.text.len > 0) {
                // Swallow render errors per-cell (e.g. a glyph the embedded font can't
                // shape) rather than `try`-ing out of the whole frame: an early return
                // here would skip the `term_box`/`scroll_area` deinit calls below, which
                // leaves the scroll area's clip narrowing (pushed in its own `init()`)
                // stuck for the rest of the frame and corrupts whatever sibling pane
                // draws next.
                dvui.renderText(.{
                    .font = font,
                    .text = cell.text,
                    .rs = .{ .r = cell_rect, .s = rs.s },
                    .color = fg,
                }) catch {};
                if (cell.style.bold) dvui.renderText(.{
                    .font = font,
                    .text = cell.text,
                    .rs = .{ .r = cell_rect, .s = rs.s },
                    .p = .{ .x = cell_rect.x + @max(0.6, rs.s * 0.6), .y = cell_rect.y },
                    .color = fg,
                }) catch {};
            }

            const line_h = @max(1, rs.s);
            if (cell.style.underline) hLine(cell_rect, cell_rect.y + cell_rect.h - line_h, line_h, fg);
            if (cell.style.strikethrough) hLine(cell_rect, cell_rect.y + cell_rect.h * 0.5, line_h, fg);
        }
    }

    if (term.cursor()) |cur| {
        const cur_rect = cellRect(rs.r, cur.x, cur.y, cw_phys, ch_phys);
        cur_rect.fill(.{}, .{ .color = default_fg.opacity(0.6) });
    }

    term_box.deinit();
    scroll_area.deinit();

    state.lock();
    syncScrollAfterFrame(state, term);
    state.unlock();

    // Painted the snapshot taken above; clear unless the PTY wrote again during this draw.
    _ = state.dirty.swap(false, .acq_rel);
}

fn syncScrollAfterFrame(state: *State, term: *Terminal) void {
    const viewport_h = state.panel_viewport_h;
    const sb = term.scrollbar();
    const sb_changed = state.scrollbarChanged(sb);
    const user_scrolled = state.user_scroll_delta.y != 0;

    if (user_scrolled) {
        applyUserScrollToTerminal(state, term, viewport_h);
    } else if (Terminal.shouldFollowOutput(state.user_pinned_to_bottom, term)) {
        if (sb_changed or state.dirty.load(.unordered) or !term.isAtBottom()) {
            state.pinToBottom(term, viewport_h);
        } else if (scrollInfoDrifted(state, sb, viewport_h)) {
            state.syncScrollInfoFromTerminal(term, viewport_h);
        }
    } else if (sb_changed or scrollInfoDrifted(state, sb, viewport_h)) {
        state.syncScrollInfoFromTerminal(term, viewport_h);
    }

    state.noteScrollbar(sb);
}

fn scrollInfoDrifted(state: *State, sb: Terminal.Scrollbar, viewport_h: f32) bool {
    if (state.cell_h <= 0 or viewport_h <= 0) return false;
    const virtual_h = @as(f32, @floatFromInt(sb.total)) * state.cell_h;
    if (@abs(state.scroll_info.virtual_size.h - virtual_h) > 0.5) return true;
    const offset_px = @as(f32, @floatFromInt(sb.offset)) * state.cell_h;
    const max_offset = @max(0, virtual_h - viewport_h);
    const clamped = @min(offset_px, max_offset);
    return @abs(state.scroll_info.offset(.vertical) - clamped) > 0.5;
}

const GridSize = struct {
    cols: u16,
    rows: u16,
    cell_w_px: u32,
    cell_h_px: u32,
};

fn gridSizeFromPanel(rs: dvui.RectScale, cell_w: f32, cell_h: f32) GridSize {
    const avail_w = rs.r.w / rs.s;
    const avail_h = rs.r.h / rs.s;
    const cols_f: f32 = @max(1, @floor(avail_w / cell_w));
    const rows_f: f32 = @max(1, @floor(avail_h / cell_h));
    return .{
        .cols = @intFromFloat(@min(cols_f, @as(f32, @floatFromInt(std.math.maxInt(u16))))),
        .rows = @intFromFloat(@min(rows_f, @as(f32, @floatFromInt(std.math.maxInt(u16))))),
        .cell_w_px = @intFromFloat(@max(1, @round(cell_w * rs.s))),
        .cell_h_px = @intFromFloat(@max(1, @round(cell_h * rs.s))),
    };
}

/// Apply DVUI scroll position (wheel, track, thumb) to the libghostty-vt viewport.
fn applyUserScrollToTerminal(state: *State, term: *Terminal, viewport_h: f32) void {
    const desired_rows = state.scrollInfoRows();

    const sb = term.scrollbar();
    const max_rows: i64 = @intCast(Terminal.maxScrollOffsetRows(sb));
    const current_rows: i64 = @intCast(sb.offset);
    const delta: i32 = @intCast(desired_rows - current_rows);
    if (delta == 0) {
        if (term.isAtBottom()) state.user_pinned_to_bottom = true;
        return;
    }

    if (desired_rows < max_rows) state.user_pinned_to_bottom = false;

    term.scrollViewportDelta(delta);
    if (term.isAtBottom()) state.user_pinned_to_bottom = true;
    state.syncScrollInfoFromTerminal(term, viewport_h);
    state.dirty.store(true, .release);
}

fn hLine(cell_rect: dvui.Rect.Physical, y: f32, h: f32, color: dvui.Color) void {
    const bar = dvui.Rect.Physical{ .x = cell_rect.x, .y = y, .w = cell_rect.w, .h = h };
    bar.fill(.{}, .{ .color = color });
}

fn cellRect(base: dvui.Rect.Physical, col: u16, row: u16, cw: f32, ch: f32) dvui.Rect.Physical {
    return .{
        .x = base.x + @as(f32, @floatFromInt(col)) * cw,
        .y = base.y + @as(f32, @floatFromInt(row)) * ch,
        .w = cw,
        .h = ch,
    };
}

fn rgb(color: Terminal.Rgb) dvui.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b };
}
