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

// ── Cursor (legacy panes) ────────────────────────────────────────────

var requested_cursor: c_int = c.rl.MOUSE_CURSOR_DEFAULT;
var requested_cursor_priority: u8 = 0;

pub fn beginFrame() void {
    requested_cursor = c.rl.MOUSE_CURSOR_DEFAULT;
    requested_cursor_priority = 0;
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

/// A mouse that hovers and clicks nothing: what the legacy panes see while
/// the pointer belongs to a menu, a modal or a new-Ui widget.
pub fn neutralMouse() Mouse {
    return .{ .x = -100000, .y = -100000, .left_pressed = false, .left_down = false, .left_released = false, .right_pressed = false, .double_clicked = false, .wheel_x = 0, .wheel_y = 0 };
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

// ── Button ───────────────────────────────────────────────────────────

pub fn button(r: c.rl.Rectangle, label: [*:0]const u8, m: Mouse) bool {
    return buttonColored(r, label, null, m);
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
