//! Immediate-mode widget primitives. 1px bevels, no AA. Drag state
//! is tracked in a single module-scope "active drag" slot — good
//! enough because only one widget can be actively dragged at a time.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const fonts = @import("fonts.zig");
const icons_mod = @import("icons.zig");

pub const Icon = icons_mod.Icon;

pub fn drawIcon(icon: Icon, x: f32, y: f32, size: f32, color: c.rl.Color) void {
    icons_mod.draw(icon, x, y, size, color);
}

pub fn measureIcon(icon: Icon, size: f32) f32 {
    return icons_mod.measure(icon, size);
}

// ── Deferred tooltip ─────────────────────────────────────────────────

const TOOLTIP_DELAY: f64 = 0.45;
var tooltip_text: ?[*:0]const u8 = null;
var tooltip_x: f32 = 0;
var tooltip_y: f32 = 0;
var tooltip_key: u64 = 0;
var tooltip_hover_key: u64 = 0;
var tooltip_hover_since: f64 = 0;
var requested_cursor: c_int = c.rl.MOUSE_CURSOR_DEFAULT;
var requested_cursor_priority: u8 = 0;
var context_key: u64 = 0;
var context_x: f32 = 0;
var context_y: f32 = 0;
// Set when a menu opens this frame, so the opening click isn't also treated
// as an outside-click that immediately closes it (button dropdowns open
// below the cursor, not at it).
var menu_just_opened: bool = false;
// The opening click must not select: a clamped menu can land under the
// cursor, and releasing the opening press would instantly pick a row.
// The menu arms once that press is released; before that, a release only
// selects if the cursor clearly dragged away from the opening point
// (deliberate press-drag-release selection still works).
var menu_armed: bool = true;
var menu_open_mx: f32 = 0;
var menu_open_my: f32 = 0;
const MAX_CONTEXT_ITEMS: usize = 40;
pub const MAX_MENU_DEPTH: usize = 4;
// Per-level registered items/rects for the deferred draw (children overlay
// parents) and the outside-click test next frame.
var menu_lvl_items: [MAX_MENU_DEPTH][MAX_CONTEXT_ITEMS]MenuItem = undefined;
var menu_lvl_len: [MAX_MENU_DEPTH]usize = [_]usize{0} ** MAX_MENU_DEPTH;
var menu_lvl_rect: [MAX_MENU_DEPTH]c.rl.Rectangle = undefined;
var menu_lvl_count: usize = 0;
var menu_prev_rects: [MAX_MENU_DEPTH]c.rl.Rectangle = undefined;
var menu_prev_count: usize = 0;
// Expansion path: which item (id + row index) is expanded at each level.
var menu_path_id: [MAX_MENU_DEPTH]u32 = undefined;
var menu_path_idx: [MAX_MENU_DEPTH]usize = undefined;
var menu_expand_depth: usize = 0;
var context_draw_active: bool = false;

pub const EditCommand = enum {
    none,
    copy,
    cut,
    paste,
    duplicate,
    delete,
    select_all,
    clear_selection,
    loop_selection,
    loop_arrangement,
    clear_loop,
    file_open,
    file_save,
    file_save_as,
    render_audio,
    split_at_playhead,
    quantize,
    humanize,
    snap_to_scale,
    rename,
    import_audio,
};

pub const MenuItem = struct {
    label: [*:0]const u8 = "",
    command: EditCommand = .none,
    id: u32 = 0,
    enabled: bool = true,
    separator: bool = false,
    /// Hovering expands a child menu (drawn with a right-aligned arrow);
    /// the caller supplies the child's items via menuSubTick.
    submenu: bool = false,
    /// Right-aligned dim shortcut hint; derived from `command` when null.
    shortcut: ?[*:0]const u8 = null,
};

/// Keybind hints shown right-aligned in menus, derived from the command.
/// Uses the Apple keyboard glyphs (⌘ ⇧ ⌥ ⌃ ⌫ ↩) — loaded into the UI font
/// atlas in fonts.zig.
fn commandShortcut(cmd: EditCommand) ?[*:0]const u8 {
    return switch (cmd) {
        .copy => "\u{2318}C",
        .cut => "\u{2318}X",
        .paste => "\u{2318}V",
        .select_all => "\u{2318}A",
        .duplicate => "D",
        .delete => "\u{232B}",
        .rename => "\u{21A9}",
        .file_save => "\u{2318}S",
        .file_save_as => "\u{2318}\u{21E7}S",
        .file_open => "\u{2318}O",
        .render_audio => "\u{2318}R",
        else => null,
    };
}

pub fn beginFrame(m: Mouse) void {
    tooltip_text = null;
    requested_cursor = c.rl.MOUSE_CURSOR_DEFAULT;
    requested_cursor_priority = 0;
    menu_prev_count = menu_lvl_count;
    @memcpy(menu_prev_rects[0..menu_lvl_count], menu_lvl_rect[0..menu_lvl_count]);
    menu_lvl_count = 0;
    @memset(menu_lvl_len[0..], 0);
    context_draw_active = false;
    frame_mouse = m;
}

pub fn requestCursor(cursor: c_int, priority: u8) void {
    if (priority >= requested_cursor_priority) {
        requested_cursor = cursor;
        requested_cursor_priority = priority;
    }
}

pub fn applyCursor() void {
    c.rl.SetMouseCursor(requested_cursor);
}

pub fn tooltip(r: c.rl.Rectangle, text: [*:0]const u8, m: Mouse) void {
    if (!contains(r, m.x, m.y) or hasActiveDrag()) return;
    const key = keyFromIds(0x7001_71F5_0000_0001, rectKey(r, 0), @intFromPtr(text));
    const now = c.rl.GetTime();
    if (tooltip_hover_key != key) {
        tooltip_hover_key = key;
        tooltip_hover_since = now;
    }
    if (now - tooltip_hover_since < TOOLTIP_DELAY) return;
    tooltip_text = text;
    tooltip_x = m.x;
    tooltip_y = m.y;
    tooltip_key = key;
}

pub fn drawTooltip(sw: f32, sh: f32) void {
    const text = tooltip_text orelse return;
    _ = tooltip_key;
    const pad_x = theme.size(6);
    const pad_y = theme.fine(4);
    const size = theme.fsTiny();
    const tw = measureTextF(text, size);
    const w = tw + pad_x * 2;
    const h = size + pad_y * 2;
    var x = tooltip_x + theme.size(12);
    var y = tooltip_y + theme.size(14);
    if (x + w > sw - 2) x = sw - w - 2;
    if (y + h > sh - 2) y = tooltip_y - h - theme.size(8);
    const r = rect(@max(2, x), @max(2, y), w, h);
    c.rl.DrawRectangleRec(r, theme.slab_edge);
    c.rl.DrawRectangleRec(rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2), theme.pane_alt);
    drawLabelF(text, r.x + pad_x, r.y + pad_y - 1, size, theme.text_fg);
}

// ── Context menu ────────────────────────────────────────────────────

pub fn openContextMenu(key: u64, r: c.rl.Rectangle, m: Mouse) bool {
    if (!m.right_pressed or !contains(r, m.x, m.y)) return false;
    context_key = key;
    context_x = m.x;
    context_y = m.y;
    menu_just_opened = true; // the opening right-click is not an outside click
    menu_armed = false;
    menu_open_mx = m.x;
    menu_open_my = m.y;
    menu_expand_depth = 0;
    cancelDrag();
    return true;
}

pub fn closeContextMenu() void {
    context_key = 0;
}

/// Open a menu (same beveled deferred renderer as context menus) at an
/// explicit point — for left-click button dropdowns, not right-click.
pub fn openMenuAt(key: u64, x: f32, y: f32) void {
    context_key = key;
    context_x = x;
    context_y = y;
    menu_just_opened = true;
    menu_armed = false;
    menu_open_mx = @floatFromInt(c.rl.GetMouseX());
    menu_open_my = @floatFromInt(c.rl.GetMouseY());
    menu_expand_depth = 0;
    cancelDrag();
}

pub fn menuOpen(key: u64) bool {
    return context_key == key;
}

pub fn menuActive() bool {
    return context_key != 0;
}

// The real pointer for this frame, captured before panes run. An open menu is
// modal for the mouse: panes are passed a neutralized mouse, while the menu
// keeps handling input off this raw copy.
var frame_mouse: Mouse = undefined;

pub fn neutralMouse() Mouse {
    return .{ .x = -100000, .y = -100000, .left_pressed = false, .left_down = false, .left_released = false, .right_pressed = false, .double_clicked = false, .wheel_x = 0, .wheel_y = 0 };
}

// Shared menu input core, one call per visible level. Level 0 anchors at
// the open point; deeper levels anchor beside their parent's expanded row.
// Hovering a `submenu` item expands it; hovering a plain item collapses
// deeper levels. Returns the clicked item index. An open menu is modal.
fn menuLevelTick(key: u64, level: usize, items: []const MenuItem) ?usize {
    if (context_key != key) return null;
    if (level >= MAX_MENU_DEPTH) return null;
    if (level > menu_expand_depth) return null;

    const draw_len = @min(items.len, MAX_CONTEXT_ITEMS);
    @memcpy(menu_lvl_items[level][0..draw_len], items[0..draw_len]);
    menu_lvl_len[level] = draw_len;
    menu_lvl_count = @max(menu_lvl_count, level + 1);
    context_draw_active = true;

    const row_h = contextMenuRowH();
    const r = menuLevelRect(level, items);
    menu_lvl_rect[level] = r;

    var hovered: ?usize = null;
    var clicked: ?usize = null;
    for (items, 0..) |item, i| {
        const row = rect(r.x + 1, r.y + 1 + @as(f32, @floatFromInt(i)) * row_h, r.width - 2, row_h);
        if (item.separator) continue;
        if (!contains(row, frame_mouse.x, frame_mouse.y)) continue;
        hovered = i;
        if (item.enabled and frame_mouse.left_released) clicked = i;
    }

    // Hover steering: expand submenus, collapse stale children.
    if (hovered) |hi| {
        const item = items[hi];
        if (item.submenu and item.enabled) {
            const already = menu_expand_depth > level and menu_path_idx[level] == hi;
            if (!already) {
                menu_path_id[level] = item.id;
                menu_path_idx[level] = hi;
                menu_expand_depth = level + 1;
            }
        } else if (menu_expand_depth > level) {
            menu_expand_depth = level;
        }
    }

    const dragged = @abs(frame_mouse.x - menu_open_mx) + @abs(frame_mouse.y - menu_open_my) > 8;
    if (clicked) |ci| {
        if (items[ci].submenu) {
            // clicking a submenu row just expands it (hover already did)
        } else if (menu_armed or dragged) {
            closeContextMenu();
            return ci;
        }
    }
    if (!menu_armed and !frame_mouse.left_down) menu_armed = true;

    if (level == 0) {
        if (menu_just_opened) {
            menu_just_opened = false;
        } else if (frame_mouse.left_pressed or frame_mouse.right_pressed) {
            var inside = false;
            for (menu_prev_rects[0..menu_prev_count]) |pr| {
                if (contains(pr, frame_mouse.x, frame_mouse.y)) inside = true;
            }
            if (!inside) closeContextMenu();
        }
    }
    return null;
}

pub fn contextMenu(key: u64, items: []const MenuItem, m: Mouse) EditCommand {
    _ = m; // modal — uses the raw frame mouse.
    if (menuLevelTick(key, 0, items)) |i| return items[i].command;
    return .none;
}

/// Like contextMenu but for arbitrary lists — returns the clicked item's `id`.
pub fn menuPickId(key: u64, items: []const MenuItem, m: Mouse) ?u32 {
    _ = m;
    if (menuLevelTick(key, 0, items)) |i| return items[i].id;
    return null;
}

/// The id of the item currently expanded at `level`, if any — the caller
/// uses it to build the child level's items for menuSubTick.
pub fn menuSubOpen(key: u64, level: usize) ?u32 {
    if (context_key != key) return null;
    if (menu_expand_depth <= level) return null;
    return menu_path_id[level];
}

/// Register + tick the child menu at `level` (1-based below the root).
pub fn menuSubTick(key: u64, level: usize, items: []const MenuItem, m: Mouse) ?u32 {
    _ = m;
    if (menuLevelTick(key, level, items)) |i| return items[i].id;
    return null;
}

pub fn drawContextMenu() void {
    if (!context_draw_active) return;
    const row_h = contextMenuRowH();
    const pad_x = theme.size(6);
    const mx: f32 = @floatFromInt(c.rl.GetMouseX());
    const my: f32 = @floatFromInt(c.rl.GetMouseY());

    var level: usize = 0;
    while (level < menu_lvl_count) : (level += 1) {
        const items = menu_lvl_items[level][0..menu_lvl_len[level]];
        if (items.len == 0) continue;
        const r = menu_lvl_rect[level];

        // Hard 1px outer edge, then a raised beveled body — floating chrome.
        c.rl.DrawRectangleRec(r, theme.slab_edge);
        bevelRaised(rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2), theme.slab_fill, theme.slab_hi, theme.slab_lo);
        for (items, 0..) |item, i| {
            const row = rect(r.x + 1, r.y + 1 + @as(f32, @floatFromInt(i)) * row_h, r.width - 2, row_h);
            if (item.separator) {
                const y = row.y + row.height / 2;
                c.rl.DrawRectangle(@intFromFloat(row.x + pad_x), @intFromFloat(y), @intFromFloat(row.width - pad_x * 2), 1, theme.slab_lo);
                c.rl.DrawRectangle(@intFromFloat(row.x + pad_x), @intFromFloat(y + 1), @intFromFloat(row.width - pad_x * 2), 1, theme.slab_hi);
                continue;
            }
            const expanded = item.submenu and menu_expand_depth > level and menu_path_idx[level] == i;
            const hover = (contains(row, mx, my) or expanded) and item.enabled;
            if (hover) c.rl.DrawRectangleRec(rect(row.x + 2, row.y, row.width - 4, row.height), theme.accent_hi);
            const col = if (!item.enabled) theme.text_mute else if (hover) theme.bg else theme.text_fg;
            drawLabelF(item.label, row.x + pad_x, row.y + (row.height - theme.fsBody()) / 2 - 1, theme.fsBody(), col);
            if (item.submenu) {
                const acol = if (hover) theme.bg else theme.text_dim;
                drawLabelF(">", row.x + row.width - pad_x - measureTextF(">", theme.fsBody()), row.y + (row.height - theme.fsBody()) / 2 - 1, theme.fsBody(), acol);
            } else if (item.shortcut orelse commandShortcut(item.command)) |hint| {
                const hs = theme.fsTiny();
                const hcol = if (hover) theme.bg else theme.text_mute;
                drawLabelF(hint, row.x + row.width - pad_x - measureTextF(hint, hs), row.y + (row.height - hs) / 2 - 1, hs, hcol);
            }
        }
    }
}

fn contextMenuRowH() f32 {
    return theme.size(18);
}

fn menuLevelRect(level: usize, items: []const MenuItem) c.rl.Rectangle {
    const row_h = contextMenuRowH();
    const w = contextMenuWidth(items, theme.size(6));
    const h = row_h * @as(f32, @floatFromInt(items.len)) + 2;
    const sw: f32 = @floatFromInt(c.rl.GetScreenWidth());
    const sh: f32 = @floatFromInt(c.rl.GetScreenHeight());
    if (level == 0) {
        const x = @min(context_x, sw - w - 2);
        const y = @min(context_y, sh - h - 2);
        return rect(@max(2, x), @max(2, y), w, h);
    }
    const parent = menu_lvl_rect[level - 1];
    const row_y = parent.y + 1 + @as(f32, @floatFromInt(menu_path_idx[level - 1])) * row_h;
    var x = parent.x + parent.width - 2;
    if (x + w > sw - 2) x = @max(2, parent.x - w + 2); // flip left when cramped
    const y = @min(row_y, sh - h - 2);
    return rect(@max(2, x), @max(2, y), w, h);
}

fn contextMenuWidth(items: []const MenuItem, pad_x: f32) f32 {
    var w: f32 = theme.size(96);
    for (items) |item| {
        var extra: f32 = 0;
        if (item.submenu) {
            extra = measureTextF(">", theme.fsBody()) + pad_x;
        } else if (item.shortcut orelse commandShortcut(item.command)) |hint| {
            extra = measureTextF(hint, theme.fsTiny()) + pad_x;
        }
        w = @max(w, measureTextF(item.label, theme.fsBody()) + pad_x * 2 + extra);
    }
    return w;
}

// ── Mouse snapshot (built once per frame) ────────────────────────────

pub const Mouse = struct {
    x: f32,
    y: f32,
    left_pressed: bool,
    left_down: bool,
    left_released: bool,
    right_pressed: bool,
    double_clicked: bool,
    /// Horizontal wheel delta — from trackpad 2-finger swipe or
    /// tilt-wheels. Positive = physical swipe right.
    wheel_x: f32,
    /// Vertical wheel delta. Positive = physical swipe up.
    wheel_y: f32,

    pub fn sample() Mouse {
        const mx: f32 = @floatFromInt(c.rl.GetMouseX());
        const my: f32 = @floatFromInt(c.rl.GetMouseY());
        const pressed = c.rl.IsMouseButtonPressed(c.rl.MOUSE_BUTTON_LEFT);

        // Double-click detection — module-scope state tracks the last
        // press time & position.
        var dbl = false;
        if (pressed) {
            const now = c.rl.GetTime();
            const dx = mx - last_click_x;
            const dy = my - last_click_y;
            if (now - last_click_time < DBL_CLICK_TIME and
                @abs(dx) < DBL_CLICK_DIST and @abs(dy) < DBL_CLICK_DIST)
            {
                dbl = true;
                last_click_time = 0; // prevent chaining into a triple
            } else {
                last_click_time = now;
            }
            last_click_x = mx;
            last_click_y = my;
        }

        const wv = c.rl.GetMouseWheelMoveV();

        return .{
            .x = mx,
            .y = my,
            .left_pressed = pressed,
            .left_down = c.rl.IsMouseButtonDown(c.rl.MOUSE_BUTTON_LEFT),
            .left_released = c.rl.IsMouseButtonReleased(c.rl.MOUSE_BUTTON_LEFT),
            .right_pressed = c.rl.IsMouseButtonPressed(c.rl.MOUSE_BUTTON_RIGHT),
            .double_clicked = dbl,
            .wheel_x = wv.x,
            .wheel_y = wv.y,
        };
    }
};

const DBL_CLICK_TIME: f64 = 0.35;
const DBL_CLICK_DIST: f32 = 4;
var last_click_time: f64 = 0;
var last_click_x: f32 = 0;
var last_click_y: f32 = 0;

// ── Drag state (module-scope; single active drag at a time) ─────────

var active_drag_key: u64 = 0;
var drag_start_val: f32 = 0;
var drag_start_y: f32 = 0;
var knob_drag_last_y: f32 = 0;

pub fn hasActiveDrag() bool {
    return active_drag_key != 0;
}

pub fn cancelDrag() void {
    active_drag_key = 0;
}

/// Try to claim exclusive drag ownership for `key`. Returns true if
/// the drag can start (nothing else is dragging).
pub fn tryStartDrag(key: u64) bool {
    if (active_drag_key != 0) return false;
    active_drag_key = key;
    return true;
}

pub fn isDraggingKey(key: u64) bool {
    return active_drag_key == key;
}

/// A numeric readout edited like a knob: vertical drag (up = increase) and
/// scroll wheel. Returns the (possibly changed) value, clamped to [lo,hi].
/// `per_px` = units per pixel dragged; `scroll_step` = units per wheel notch.
pub fn dragValueV(r: c.rl.Rectangle, salt: u64, value: f32, lo: f32, hi: f32, per_px: f32, scroll_step: f32, m: Mouse) f32 {
    const k = rectKey(r, salt);
    var v = value;
    if (active_drag_key == k) {
        if (!m.left_down) {
            active_drag_key = 0;
        } else {
            v = std.math.clamp(drag_start_val + (drag_start_y - m.y) * per_px, lo, hi);
        }
    } else if (active_drag_key == 0 and m.left_pressed and contains(r, m.x, m.y)) {
        active_drag_key = k;
        drag_start_val = value;
        drag_start_y = m.y;
    } else if (active_drag_key == 0 and contains(r, m.x, m.y) and m.wheel_y != 0) {
        v = std.math.clamp(value + m.wheel_y * scroll_step, lo, hi);
    }
    if ((active_drag_key == k or (active_drag_key == 0 and contains(r, m.x, m.y)))) {
        requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);
    }
    return v;
}

pub fn rectKeyOf(r: c.rl.Rectangle, salt: u64) u64 {
    return rectKey(r, salt);
}

pub fn keyFromIds(salt: u64, a: u64, b: u64) u64 {
    var h = salt;
    h ^= a;
    h = h *% 0x9E3779B97F4A7C15;
    h ^= b;
    h = h *% 0x9E3779B97F4A7C15;
    return if (h == 0) 1 else h;
}

fn rectKey(r: c.rl.Rectangle, salt: u64) u64 {
    var h = salt;
    h ^= @as(u64, @bitCast(@as(i64, @intFromFloat(r.x * 16))));
    h = h *% 0x9E3779B97F4A7C15;
    h ^= @as(u64, @bitCast(@as(i64, @intFromFloat(r.y * 16))));
    h = h *% 0x9E3779B97F4A7C15;
    h ^= @as(u64, @bitCast(@as(i64, @intFromFloat(r.width * 16))));
    h = h *% 0x9E3779B97F4A7C15;
    h ^= @as(u64, @bitCast(@as(i64, @intFromFloat(r.height * 16))));
    return if (h == 0) 1 else h;
}

// ── Rect helpers ─────────────────────────────────────────────────────

pub fn contains(r: c.rl.Rectangle, x: f32, y: f32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height;
}

pub fn rect(x: f32, y: f32, w: f32, h: f32) c.rl.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

// ── Bevels ───────────────────────────────────────────────────────────

pub fn bevelRaised(r: c.rl.Rectangle, fill: c.rl.Color, hi: c.rl.Color, lo: c.rl.Color) void {
    c.rl.DrawRectangleRec(r, fill);
    const x: c_int = @intFromFloat(r.x);
    const y: c_int = @intFromFloat(r.y);
    const w: c_int = @intFromFloat(r.width);
    const h: c_int = @intFromFloat(r.height);
    c.rl.DrawRectangle(x, y, w, 1, hi);
    c.rl.DrawRectangle(x, y, 1, h, hi);
    c.rl.DrawRectangle(x, y + h - 1, w, 1, lo);
    c.rl.DrawRectangle(x + w - 1, y, 1, h, lo);
}

pub fn bevelSunken(r: c.rl.Rectangle, fill: c.rl.Color, hi: c.rl.Color, lo: c.rl.Color) void {
    bevelRaised(r, fill, lo, hi);
}

pub fn panelFrame(r: c.rl.Rectangle) void {
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    c.rl.DrawRectangleLinesEx(r, 1, theme.slab_edge);
}

// ── Text ─────────────────────────────────────────────────────────────

pub fn drawLabel(text: [*:0]const u8, x: c_int, y: c_int, size: c_int, color: c.rl.Color) void {
    fonts.drawUI(text, @floatFromInt(x), @floatFromInt(y), @floatFromInt(size), color);
}

pub fn drawLabelF(text: [*:0]const u8, x: f32, y: f32, size: f32, color: c.rl.Color) void {
    fonts.drawUI(text, x, y, size, color);
}

pub fn drawMono(text: [*:0]const u8, x: f32, y: f32, size: f32, color: c.rl.Color) void {
    fonts.drawMono(text, x, y, size, color);
}

pub fn measureText(text: [*:0]const u8, size: c_int) c_int {
    return @intFromFloat(fonts.measureUI(text, @floatFromInt(size)));
}

pub fn measureTextF(text: [*:0]const u8, size: f32) f32 {
    return fonts.measureUI(text, size);
}

// ── Arrow / triangle toggle button ───────────────────────────────────
//
// Tiny square button with a filled triangle pointing in one direction.
// Click to toggle; returns true on click.

pub const ArrowDir = enum { left, right, up, down };

pub fn arrowButton(r: c.rl.Rectangle, dir: ArrowDir, m: Mouse) bool {
    const hover = contains(r, m.x, m.y) and !hasActiveDrag();
    const pressed = hover and m.left_down;
    const clicked = hover and m.left_released;
    const fill = if (pressed) theme.slab_lo else if (hover) theme.slab_hi else theme.slab_fill;
    bevelRaised(r, fill, theme.slab_hi, theme.slab_lo);

    const cx = r.x + r.width / 2;
    const cy = r.y + r.height / 2;
    const s = @min(r.width, r.height) / 2 - 3;
    var p1: c.rl.Vector2 = undefined;
    var p2: c.rl.Vector2 = undefined;
    var p3: c.rl.Vector2 = undefined;
    switch (dir) {
        .left => {
            p1 = .{ .x = cx + s / 2, .y = cy - s };
            p2 = .{ .x = cx + s / 2, .y = cy + s };
            p3 = .{ .x = cx - s / 2, .y = cy };
        },
        .right => {
            p1 = .{ .x = cx - s / 2, .y = cy - s };
            p2 = .{ .x = cx + s / 2, .y = cy };
            p3 = .{ .x = cx - s / 2, .y = cy + s };
        },
        .up => {
            p1 = .{ .x = cx - s, .y = cy + s / 2 };
            p2 = .{ .x = cx, .y = cy - s / 2 };
            p3 = .{ .x = cx + s, .y = cy + s / 2 };
        },
        .down => {
            p1 = .{ .x = cx - s, .y = cy - s / 2 };
            p2 = .{ .x = cx + s, .y = cy - s / 2 };
            p3 = .{ .x = cx, .y = cy + s / 2 };
        },
    }
    c.rl.DrawTriangle(p1, p2, p3, theme.text_fg);
    return clicked;
}

// ── Pane header ──────────────────────────────────────────────────────
//
// Title bar + up to two trailing buttons, each with its own bevel,
// laid out side-by-side (no nested bevels). OpenTTD-style packed.
//
// Buttons, in order from the right edge inward:
//   • close (optional, rendered only when has_close)
//   • minimize/restore (always)
//
// Button position stays fixed across expanded/collapsed states — only
// the minimize icon swaps between `minus` (expanded, click to collapse)
// and `plus` (collapsed, click to restore).

pub const HeaderOpts = struct {
    title: [*:0]const u8,
    collapsed: bool = false,
    has_close: bool = false,
    /// Optional tool button on the left of the title bar (e.g. a
    /// pencil for "draw mode" on the clip editor). `left_tool_active`
    /// controls whether it renders in its active-accent fill.
    left_tool: ?Icon = null,
    left_tool_active: bool = false,
};

pub const HeaderResult = struct {
    minimize: bool = false,
    close: bool = false,
    left_tool: bool = false,
    title_rect: ?c.rl.Rectangle = null,
};

pub fn paneHeader(
    r: c.rl.Rectangle,
    opts: HeaderOpts,
    m: Mouse,
) HeaderResult {
    const btn_sz = r.height;
    const gap: f32 = 0;

    // Left-side tool (optional).
    var left_x = r.x;
    var left_tool_clicked = false;
    if (opts.left_tool) |icon| {
        const lr = rect(left_x, r.y, btn_sz, r.height);
        const active_fill: ?c.rl.Color = if (opts.left_tool_active) theme.accent_hi else null;
        left_tool_clicked = iconButton(lr, icon, active_fill, m);
        tooltip(lr, if (opts.left_tool_active) "Select tool" else "Draw tool", m);
        left_x += btn_sz + gap;
    }

    var right_x = r.x + r.width;
    var close_clicked = false;
    if (opts.has_close) {
        right_x -= btn_sz;
        const close_rect = rect(right_x, r.y, btn_sz, r.height);
        close_clicked = iconButton(close_rect, .x, null, m);
        tooltip(close_rect, "Close panel", m);
        right_x -= gap;
    }

    right_x -= btn_sz;
    const min_rect = rect(right_x, r.y, btn_sz, r.height);
    const min_icon: Icon = if (opts.collapsed) .plus else .minus;
    const min_clicked = iconButton(min_rect, min_icon, null, m);
    tooltip(min_rect, if (opts.collapsed) "Expand panel" else "Collapse panel", m);
    right_x -= gap;

    // Title bar fills between left tool and right buttons.
    const title_w = right_x - left_x;
    var title_rect_out: ?c.rl.Rectangle = null;
    if (title_w > 0) {
        const title_rect = rect(left_x, r.y, title_w, r.height);
        title_rect_out = title_rect;
        bevelRaised(title_rect, theme.slab_fill, theme.slab_hi, theme.slab_lo);
        drawLabelF(opts.title, title_rect.x + theme.size(6), title_rect.y + (title_rect.height - theme.fsTiny()) / 2 - 1, theme.fsTiny(), theme.text_fg);
    }

    return .{ .minimize = min_clicked, .close = close_clicked, .left_tool = left_tool_clicked, .title_rect = title_rect_out };
}

// ── Button ───────────────────────────────────────────────────────────

pub fn button(r: c.rl.Rectangle, label: [*:0]const u8, m: Mouse) bool {
    return buttonColored(r, label, null, m);
}

pub fn buttonTip(r: c.rl.Rectangle, label: [*:0]const u8, tip: [*:0]const u8, m: Mouse) bool {
    const clicked = button(r, label, m);
    tooltip(r, tip, m);
    return clicked;
}

pub fn iconButton(r: c.rl.Rectangle, icon: Icon, active_fill: ?c.rl.Color, m: Mouse) bool {
    const hover = contains(r, m.x, m.y) and !hasActiveDrag();
    const pressed = hover and m.left_down;
    const clicked = hover and m.left_released;
    const base_fill = active_fill orelse theme.slab_fill;
    const fill = if (pressed) theme.slab_lo else if (hover) theme.slab_hi else base_fill;
    bevelRaised(r, fill, theme.slab_hi, theme.slab_lo);

    const icon_size = @min(r.width, r.height) - 4;
    const w = measureIcon(icon, icon_size);
    const ix = r.x + (r.width - w) / 2;
    const iy = r.y + (r.height - icon_size) / 2 - 1;
    drawIcon(icon, ix, iy, icon_size, theme.text_fg);
    return clicked;
}

pub fn iconButtonTip(r: c.rl.Rectangle, icon: Icon, active_fill: ?c.rl.Color, tip: [*:0]const u8, m: Mouse) bool {
    const clicked = iconButton(r, icon, active_fill, m);
    tooltip(r, tip, m);
    return clicked;
}

pub fn buttonColored(r: c.rl.Rectangle, label: [*:0]const u8, active_fill: ?c.rl.Color, m: Mouse) bool {
    const hover = contains(r, m.x, m.y) and !hasActiveDrag();
    const pressed = hover and m.left_down;
    const clicked = hover and m.left_released;
    const base_fill = active_fill orelse theme.slab_fill;
    const fill = if (pressed) theme.slab_lo else if (hover) theme.slab_hi else base_fill;
    bevelRaised(r, fill, theme.slab_hi, theme.slab_lo);
    const size = theme.fsBody();
    const tw = measureTextF(label, size);
    const tx = r.x + (r.width - tw) / 2;
    const ty = r.y + (r.height - size) / 2 - 1;
    drawLabelF(label, tx, ty, size, theme.text_fg);
    return clicked;
}

// ── Machine switches ─────────────────────────────────────────────────

pub fn toggleCell(r: c.rl.Rectangle, label: [*:0]const u8, on: *bool, m: Mouse) bool {
    const hover = contains(r, m.x, m.y) and !hasActiveDrag();
    const pressed = hover and m.left_down;
    const clicked = hover and m.left_released;
    if (clicked) on.* = !on.*;

    const fill = if (pressed) theme.slab_lo else if (on.*) theme.slab_hi else if (hover) theme.slab_fill else theme.pane_alt;
    bevelRaised(r, fill, theme.slab_hi, theme.slab_lo);

    const led_r = rect(r.x + 4, r.y + (r.height - 6) / 2, 6, 6);
    led(led_r, on.*, theme.accent_hi);
    const text_col = if (on.* or hover) theme.text_fg else theme.text_dim;
    drawLabelF(label, r.x + 14, r.y + (r.height - theme.fsBody()) / 2 - 1, theme.fsBody(), text_col);
    return clicked;
}

pub fn switch3(
    r: c.rl.Rectangle,
    label: [*:0]const u8,
    opt0: [*:0]const u8,
    opt1: [*:0]const u8,
    opt2: [*:0]const u8,
    value: *u8,
    m: Mouse,
) bool {
    var changed = false;
    const label_h = theme.fsTiny() + 2;
    const label_col = if (contains(r, m.x, m.y)) theme.text_fg else theme.text_dim;
    drawLabelF(label, r.x, r.y, theme.fsTiny(), label_col);

    const box = rect(r.x, r.y + label_h, r.width, r.height - label_h);
    bevelRaised(box, theme.slab_fill, theme.slab_hi, theme.slab_lo);
    const opts = [_][*:0]const u8{ opt0, opt1, opt2 };
    const cell_w = box.width / 3.0;

    for (opts, 0..) |opt, i| {
        const fi: f32 = @floatFromInt(i);
        const cell = rect(box.x + fi * cell_w, box.y, cell_w, box.height);
        const active = value.* == i;
        const hover = contains(cell, m.x, m.y) and !hasActiveDrag();
        if (hover and m.left_released) {
            value.* = @intCast(i);
            changed = true;
        }
        const fill = if (active) theme.slab_hi else if (hover) theme.slab_fill else theme.pane_alt;
        c.rl.DrawRectangleRec(rect(cell.x + 1, cell.y + 1, cell.width - 2, cell.height - 2), fill);
        if (i > 0) c.rl.DrawRectangle(@intFromFloat(cell.x), @intFromFloat(cell.y + 1), 1, @intFromFloat(cell.height - 2), theme.slab_edge);
        const size = theme.fsTiny();
        const tw = measureTextF(opt, size);
        drawLabelF(opt, cell.x + (cell.width - tw) / 2, cell.y + (cell.height - size) / 2 - 1, size, if (active) theme.text_fg else theme.text_dim);
    }
    return changed;
}

pub fn switch3Vertical(
    r: c.rl.Rectangle,
    label: [*:0]const u8,
    opt0: [*:0]const u8,
    opt1: [*:0]const u8,
    opt2: [*:0]const u8,
    value: *u8,
    m: Mouse,
) bool {
    var changed = false;
    const label_h = theme.fsTiny() + 2;
    const label_col = if (contains(r, m.x, m.y)) theme.text_fg else theme.text_dim;
    drawLabelF(label, r.x, r.y, theme.fsTiny(), label_col);

    const box = rect(r.x, r.y + label_h, r.width, r.height - label_h);
    bevelRaised(box, theme.slab_fill, theme.slab_hi, theme.slab_lo);
    const opts = [_][*:0]const u8{ opt0, opt1, opt2 };
    const cell_h = box.height / 3.0;

    for (opts, 0..) |opt, i| {
        const fi: f32 = @floatFromInt(i);
        const cell = rect(box.x, box.y + fi * cell_h, box.width, cell_h);
        const active = value.* == i;
        const hover = contains(cell, m.x, m.y) and !hasActiveDrag();
        if (hover and m.left_released) {
            value.* = @intCast(i);
            changed = true;
        }
        const fill = if (active) theme.slab_hi else if (hover) theme.slab_fill else theme.pane_alt;
        c.rl.DrawRectangleRec(rect(cell.x + 1, cell.y + 1, cell.width - 2, cell.height - 2), fill);
        if (i > 0) c.rl.DrawRectangle(@intFromFloat(cell.x + 1), @intFromFloat(cell.y), @intFromFloat(cell.width - 2), 1, theme.slab_edge);
        const size = theme.fsTiny();
        const tw = measureTextF(opt, size);
        drawLabelF(opt, cell.x + (cell.width - tw) / 2, cell.y + (cell.height - size) / 2 - 1, size, if (active) theme.text_fg else theme.text_dim);
    }
    return changed;
}

// ── Strip: a beveled module box (mono1 style) ─────────────────────────
//
// One raised bevel panel for a whole module, with the title at top-left.
// Returns the body rect (below the title band) for laying out controls.
pub fn strip(r: c.rl.Rectangle, title: [*:0]const u8) c.rl.Rectangle {
    bevelRaised(r, theme.slab_fill, theme.slab_hi, theme.slab_lo);
    drawLabelF(title, r.x + theme.size(4), r.y + theme.size(3), theme.fsTiny(), theme.text_dim);
    const header_h = theme.fsTiny() + theme.size(6);
    return rect(r.x, r.y + header_h, r.width, r.height - header_h);
}

// ── Vertical N-option selector (octave / waveform) ────────────────────
//
// Generalizes switch3Vertical to any number of options. `value` is the
// selected index. Returns true when changed.
pub fn switchV(r: c.rl.Rectangle, label: [*:0]const u8, options: []const [*:0]const u8, value: *u8, m: Mouse) bool {
    if (options.len == 0) return false;
    var changed = false;
    const label_h = theme.fsTiny() + 2;
    const label_col = if (contains(r, m.x, m.y)) theme.text_fg else theme.text_dim;
    drawLabelF(label, r.x, r.y, theme.fsTiny(), label_col);

    const box = rect(r.x, r.y + label_h, r.width, r.height - label_h);
    bevelRaised(box, theme.slab_fill, theme.slab_hi, theme.slab_lo);
    const cell_h = box.height / @as(f32, @floatFromInt(options.len));
    for (options, 0..) |opt, i| {
        const fi: f32 = @floatFromInt(i);
        const cell = rect(box.x, box.y + fi * cell_h, box.width, cell_h);
        const active = value.* == i;
        const hover = contains(cell, m.x, m.y) and !hasActiveDrag();
        if (hover and m.left_released) {
            value.* = @intCast(i);
            changed = true;
        }
        const fill = if (active) theme.slab_hi else if (hover) theme.slab_fill else theme.pane_alt;
        c.rl.DrawRectangleRec(rect(cell.x + 1, cell.y + 1, cell.width - 2, cell.height - 2), fill);
        if (i > 0) c.rl.DrawRectangle(@intFromFloat(cell.x + 1), @intFromFloat(cell.y), @intFromFloat(cell.width - 2), 1, theme.slab_edge);
        const size = theme.fsTiny();
        const tw = measureTextF(opt, size);
        drawLabelF(opt, cell.x + (cell.width - tw) / 2, cell.y + (cell.height - size) / 2 - 1, size, if (active) theme.text_fg else theme.text_dim);
    }
    return changed;
}

// ── Knob ─────────────────────────────────────────────────────────────
//
// `r` is the full cell rect. The knob circle is capped at KNOB_MAX_R so
// it stays small in tall cells; the label/value are drawn flush against
// the circle rather than at the extremes of the rect.
//
// Arc sweep: 225° (7 o'clock) → -45° (5 o'clock) CCW via 12 o'clock.
//
// Angle conventions:
//   KNOB_A_*   — CCW radians (cos/sin, screen y-down), for the notch line
//   KNOB_DEG_* — raylib CW degrees (0=East, +CW),      for DrawRing

const KNOB_MAX_R_BASE: f32 = 14.0; // cap so knobs stay compact in tall cells
const KNOB_A_MIN: f32 = std.math.pi * 1.25; // 7 o'clock
const KNOB_A_MAX: f32 = -std.math.pi * 0.25; // 5 o'clock
const KNOB_DEG_START: f32 = 135.0;
const KNOB_DEG_RANGE: f32 = 270.0;

pub fn knob(r: c.rl.Rectangle, label: [*:0]const u8, val: *f32, m: Mouse) bool {
    return knobEx(r, label, val, m, null);
}

/// Knob with an optional real-value readout (Hz, seconds, …) supplied by
/// the caller; null falls back to the 0..1 norm. Shift while dragging
/// switches to fine adjustment (10x slower).
pub fn knobEx(r: c.rl.Rectangle, label: [*:0]const u8, val: *f32, m: Mouse, display: ?[*:0]const u8) bool {
    const k = rectKey(r, 0x4b4e4f4200000001);
    var changed = false;
    const dragging = active_drag_key == k;

    if (dragging) {
        if (!m.left_down) {
            active_drag_key = 0;
        } else {
            // Per-frame delta (not drag-start anchored) so toggling Shift
            // mid-drag rescales without a value jump.
            const fine = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
            const sens: f32 = if (fine) 1500.0 else 150.0;
            const dy = knob_drag_last_y - m.y;
            knob_drag_last_y = m.y;
            const nv = std.math.clamp(val.* + dy / sens, 0.0, 1.0);
            if (nv != val.*) {
                val.* = nv;
                changed = true;
            }
        }
    } else if (active_drag_key == 0 and m.left_pressed and contains(r, m.x, m.y)) {
        active_drag_key = k;
        drag_start_val = val.*;
        drag_start_y = m.y;
        knob_drag_last_y = m.y;
    }

    const hot = dragging or (active_drag_key == 0 and contains(r, m.x, m.y));

    // Radius: honour the cell geometry but never exceed KNOB_MAX_R.
    const label_h = theme.fsTiny() + 1;
    const value_h = theme.fsTiny() + 1;
    const radius = @max(
        @min(theme.fine(KNOB_MAX_R_BASE), r.width / 2.0 - 3.0, (r.height - label_h - value_h) / 2.0 - 2.0),
        2.0,
    );

    // Circle centre: vertically pack [label · circle · value] as a block.
    const cx = r.x + r.width / 2.0;
    const block_h = label_h + radius * 2.0 + 4.0 + value_h;
    const block_y = r.y + (r.height - block_h) / 2.0;
    const cy = block_y + label_h + radius + 2.0;

    // ── Label — flush above the circle ───────────────────────────
    const label_col = if (hot) theme.text_fg else theme.text_dim;
    const label_size = theme.fsTiny();
    const tw = measureTextF(label, label_size);
    drawLabelF(label, cx - tw / 2.0, block_y, label_size, label_col);

    // ── Knob body ────────────────────────────────────────────────
    const bg = if (dragging) theme.slab_lo else theme.pane_bg;
    c.rl.DrawCircle(@intFromFloat(cx), @intFromFloat(cy), radius + 2, theme.slab_edge);
    c.rl.DrawCircle(@intFromFloat(cx), @intFromFloat(cy), radius + 1, bg);

    const t = val.*;
    const center = c.rl.Vector2{ .x = cx, .y = cy };
    const inner_r = radius - 3.0;
    const outer_r = radius - 1.0;
    const SEG: c_int = 36;
    c.rl.DrawRing(center, inner_r, outer_r, KNOB_DEG_START, KNOB_DEG_START + KNOB_DEG_RANGE, SEG, theme.slab_hi);
    if (t > 0.001) {
        c.rl.DrawRing(center, inner_r, outer_r, KNOB_DEG_START, KNOB_DEG_START + t * KNOB_DEG_RANGE, SEG, theme.accent_hi);
    }

    // Notch: 5 px yellow tick on the arc at the current position.
    const cur_angle = KNOB_A_MIN + (KNOB_A_MAX - KNOB_A_MIN) * t;
    const notch_outer = radius;
    const notch_inner = radius - 5.0;
    c.rl.DrawLineEx(
        .{ .x = cx + @cos(cur_angle) * notch_inner, .y = cy - @sin(cur_angle) * notch_inner },
        .{ .x = cx + @cos(cur_angle) * notch_outer, .y = cy - @sin(cur_angle) * notch_outer },
        2.0,
        theme.accent_hi,
    );

    // ── Value — flush below the circle ───────────────────────────
    const value_y = cy + radius + 2.0;
    var vbuf: [12:0]u8 = undefined;
    const vs: [*:0]const u8 = display orelse blk: {
        const s = std.fmt.bufPrintZ(&vbuf, "{d:.2}", .{t}) catch "?";
        break :blk s.ptr;
    };
    const vw = measureTextF(vs, label_size);
    const val_col = if (dragging) theme.accent_hi else theme.text_mute;
    drawLabelF(vs, cx - vw / 2.0, value_y, label_size, val_col);

    return changed;
}

// ── Stepped knob (rotary switch) ──────────────────────────────────────
//
// A knob that snaps to N discrete detents (e.g. octave 32/16/8/4). `value`
// is the selected index. Tick marks show each detent; the readout is the
// option label. Vertical drag snaps between detents.
pub fn knobStepped(r: c.rl.Rectangle, label: [*:0]const u8, options: []const [*:0]const u8, value: *u8, m: Mouse) bool {
    if (options.len == 0) return false;
    const count = options.len;
    const maxidx: f32 = if (count > 1) @floatFromInt(count - 1) else 1.0;
    const k = rectKey(r, 0x4b4e4f4253544550);
    var changed = false;
    const dragging = active_drag_key == k;

    if (dragging) {
        if (!m.left_down) {
            active_drag_key = 0;
        } else {
            const dy = drag_start_y - m.y;
            const t = std.math.clamp(drag_start_val + dy / 120.0, 0.0, 1.0);
            const ni: u8 = @intFromFloat(@round(t * maxidx));
            if (ni != value.*) {
                value.* = ni;
                changed = true;
            }
        }
    } else if (active_drag_key == 0 and m.left_pressed and contains(r, m.x, m.y)) {
        active_drag_key = k;
        drag_start_val = @as(f32, @floatFromInt(value.*)) / maxidx;
        drag_start_y = m.y;
    }

    const hot = dragging or (active_drag_key == 0 and contains(r, m.x, m.y));
    const label_h = theme.fsTiny() + 1;
    const value_h = theme.fsTiny() + 1;
    const radius = @max(
        @min(theme.fine(KNOB_MAX_R_BASE), r.width / 2.0 - 3.0, (r.height - label_h - value_h) / 2.0 - 2.0),
        2.0,
    );
    const cx = r.x + r.width / 2.0;
    const block_h = label_h + radius * 2.0 + 4.0 + value_h;
    const block_y = r.y + (r.height - block_h) / 2.0;
    const cy = block_y + label_h + radius + 2.0;

    const label_col = if (hot) theme.text_fg else theme.text_dim;
    const label_size = theme.fsTiny();
    const tw = measureTextF(label, label_size);
    drawLabelF(label, cx - tw / 2.0, block_y, label_size, label_col);

    const bg = if (dragging) theme.slab_lo else theme.pane_bg;
    c.rl.DrawCircle(@intFromFloat(cx), @intFromFloat(cy), radius + 2, theme.slab_edge);
    c.rl.DrawCircle(@intFromFloat(cx), @intFromFloat(cy), radius + 1, bg);

    const center = c.rl.Vector2{ .x = cx, .y = cy };
    const inner_r = radius - 3.0;
    const outer_r = radius - 1.0;
    const SEG: c_int = 36;
    c.rl.DrawRing(center, inner_r, outer_r, KNOB_DEG_START, KNOB_DEG_START + KNOB_DEG_RANGE, SEG, theme.slab_hi);

    // Detent ticks: one per option, the selected one highlighted.
    var s: usize = 0;
    while (s < count) : (s += 1) {
        const ts = @as(f32, @floatFromInt(s)) / maxidx;
        const a = KNOB_A_MIN + (KNOB_A_MAX - KNOB_A_MIN) * ts;
        const sel = s == value.*;
        const col = if (sel) theme.accent_hi else theme.text_mute;
        const ti = if (sel) radius - 6.0 else radius - 4.0;
        c.rl.DrawLineEx(
            .{ .x = cx + @cos(a) * ti, .y = cy - @sin(a) * ti },
            .{ .x = cx + @cos(a) * radius, .y = cy - @sin(a) * radius },
            2.0,
            col,
        );
    }

    const value_y = cy + radius + 2.0;
    const vs = options[value.*];
    const vw = measureTextF(vs, label_size);
    const val_col = if (dragging) theme.accent_hi else theme.text_mute;
    drawLabelF(vs, cx - vw / 2.0, value_y, label_size, val_col);

    return changed;
}

// ── Display field ────────────────────────────────────────────────────
//
// Raised outer bevel + sunken inner bevel. Returns the inner content
// rect so the caller can draw text / LEDs / sub-widgets inside it.

pub fn displayField(r: c.rl.Rectangle) c.rl.Rectangle {
    bevelRaised(r, theme.slab_fill, theme.slab_hi, theme.slab_lo);
    const inset = rect(r.x + 2, r.y + 2, r.width - 4, r.height - 4);
    bevelSunken(inset, theme.pane_bg, theme.slab_hi, theme.slab_lo);
    return rect(inset.x + 1, inset.y + 1, inset.width - 2, inset.height - 2);
}

// ── LED ──────────────────────────────────────────────────────────────
//
// Small rectangular LED — bright fill + 1 px dark border. Dim when
// off, bright in the given color when on.

pub fn led(r: c.rl.Rectangle, on: bool, color: c.rl.Color) void {
    const fill = if (on) color else theme.slab_lo;
    c.rl.DrawRectangleRec(r, fill);
    c.rl.DrawRectangleLinesEx(r, 1, theme.slab_edge);
    if (on) {
        // tiny bright 1 px highlight in the top-left corner
        c.rl.DrawRectangle(@intFromFloat(r.x + 1), @intFromFloat(r.y + 1), 1, 1, theme.text_fg);
    }
}

// ── Horizontal fader ─────────────────────────────────────────────────

pub fn hFader(r: c.rl.Rectangle, val: *f32, m: Mouse) bool {
    const k = rectKey(r, 0x4846_4144_4552_0001); // "HFADER" salt
    var changed = false;

    if (active_drag_key == k) {
        if (!m.left_down) {
            active_drag_key = 0;
        } else {
            const nv = std.math.clamp((m.x - r.x) / r.width, 0.0, 1.0);
            if (nv != val.*) {
                val.* = nv;
                changed = true;
            }
        }
    } else if (active_drag_key == 0 and m.left_pressed and contains(r, m.x, m.y)) {
        active_drag_key = k;
        // Jump to click position on press.
        val.* = std.math.clamp((m.x - r.x) / r.width, 0.0, 1.0);
        changed = true;
    }

    bevelSunken(r, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    const inner = rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2);
    const fill_w = inner.width * std.math.clamp(val.*, 0.0, 1.0);
    if (fill_w > 0) {
        c.rl.DrawRectangle(
            @intFromFloat(inner.x),
            @intFromFloat(inner.y),
            @intFromFloat(fill_w),
            @intFromFloat(inner.height),
            theme.slab_hi,
        );
    }
    return changed;
}

// ── Pan bar ──────────────────────────────────────────────────────────
//
// Center-detented horizontal control: `val` is −1 (hard left) .. +1 (hard
// right), 0 center. A fill grows from the centre toward the handle so the
// pan amount and side read at a glance. Double-click recenters. Returns
// true when the value changed.

pub fn panBar(r: c.rl.Rectangle, val: *f32, m: Mouse) bool {
    const k = rectKey(r, 0x5041_4e42_4152_0001); // "PANBAR" salt
    var changed = false;

    if (active_drag_key == k) {
        if (!m.left_down) {
            active_drag_key = 0;
        } else {
            const nv = std.math.clamp((m.x - r.x) / r.width * 2.0 - 1.0, -1.0, 1.0);
            if (nv != val.*) {
                val.* = nv;
                changed = true;
            }
        }
    } else if (active_drag_key == 0 and m.left_pressed and contains(r, m.x, m.y)) {
        if (m.double_clicked) {
            if (val.* != 0) {
                val.* = 0;
                changed = true;
            }
        } else {
            active_drag_key = k;
            val.* = std.math.clamp((m.x - r.x) / r.width * 2.0 - 1.0, -1.0, 1.0);
            changed = true;
        }
    }

    bevelSunken(r, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    const inner = rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2);
    const cx = inner.x + inner.width * 0.5;
    // Center detent tick.
    c.rl.DrawRectangle(@intFromFloat(cx), @intFromFloat(inner.y), 1, @intFromFloat(inner.height), theme.slab_lo);
    const p = std.math.clamp(val.*, -1.0, 1.0);
    const handle_x = cx + p * (inner.width * 0.5);
    // Fill from center to handle.
    const x0 = @min(cx, handle_x);
    const w = @abs(handle_x - cx);
    if (w >= 1) c.rl.DrawRectangle(@intFromFloat(x0), @intFromFloat(inner.y), @intFromFloat(w), @intFromFloat(inner.height), theme.slab_hi);
    // Handle tick.
    c.rl.DrawRectangle(@intFromFloat(handle_x - 0.5), @intFromFloat(inner.y), 1, @intFromFloat(inner.height), theme.text_dim);
    return changed;
}

// ── Meter ────────────────────────────────────────────────────────────

pub fn meter(r: c.rl.Rectangle, peak: f32) void {
    bevelSunken(r, theme.slab_edge, theme.slab_hi, theme.slab_lo);
    const inner = rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2);

    const clamped = std.math.clamp(peak, 0.0, 1.0);
    const fill_h = inner.height * clamped;
    if (fill_h <= 0) return;

    const green_top = inner.height * 0.6;
    const yellow_top = inner.height * 0.85;

    if (fill_h <= green_top) {
        c.rl.DrawRectangle(
            @intFromFloat(inner.x),
            @intFromFloat(inner.y + inner.height - fill_h),
            @intFromFloat(inner.width),
            @intFromFloat(fill_h),
            theme.accent_play,
        );
        return;
    }

    // green band
    c.rl.DrawRectangle(
        @intFromFloat(inner.x),
        @intFromFloat(inner.y + inner.height - green_top),
        @intFromFloat(inner.width),
        @intFromFloat(green_top),
        theme.accent_play,
    );

    if (fill_h <= yellow_top) {
        c.rl.DrawRectangle(
            @intFromFloat(inner.x),
            @intFromFloat(inner.y + inner.height - fill_h),
            @intFromFloat(inner.width),
            @intFromFloat(fill_h - green_top),
            theme.accent_hi,
        );
        return;
    }

    // yellow band
    c.rl.DrawRectangle(
        @intFromFloat(inner.x),
        @intFromFloat(inner.y + inner.height - yellow_top),
        @intFromFloat(inner.width),
        @intFromFloat(yellow_top - green_top),
        theme.accent_hi,
    );
    // red above
    c.rl.DrawRectangle(
        @intFromFloat(inner.x),
        @intFromFloat(inner.y + inner.height - fill_h),
        @intFromFloat(inner.width),
        @intFromFloat(fill_h - yellow_top),
        theme.accent_rec,
    );
}
