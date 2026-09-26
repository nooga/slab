//! Pointer input for the working-surface panes (arrangement, piano roll,
//! audio editor) whose interaction is written against float rects and
//! explicit drag keys rather than Ui widgets. Everything here derives from
//! the Ui's input: the pointer comes from `Ui.raw_in` (the host hands the
//! panes `neutral()` while a menu, dialog or Ui widget owns it), one pane
//! drag is live at a time, and cursor requests are forwarded to the Ui so
//! there is a single cursor per frame.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");

/// The panes' view of the pointer this frame.
pub const Mouse = struct {
    x: f32,
    y: f32,
    left_pressed: bool,
    left_down: bool,
    left_released: bool,
    right_pressed: bool,
    double_clicked: bool,
    /// Horizontal wheel delta (trackpad swipe or tilt wheel); positive =
    /// swipe right.
    wheel_x: f32,
    /// Vertical wheel delta; positive = swipe up.
    wheel_y: f32,

    pub fn fromInput(in: *const core.Input) Mouse {
        return .{
            .x = in.mx,
            .y = in.my,
            .left_pressed = in.pressed,
            .left_down = in.down,
            .left_released = in.released,
            .right_pressed = in.right_pressed,
            .double_clicked = in.double,
            .wheel_x = in.wheel_x,
            .wheel_y = in.wheel_y,
        };
    }
};

/// A mouse that hovers and clicks nothing.
pub fn neutral() Mouse {
    return .{ .x = -1e6, .y = -1e6, .left_pressed = false, .left_down = false, .left_released = false, .right_pressed = false, .double_clicked = false, .wheel_x = 0, .wheel_y = 0 };
}

// ── Drag ownership ───────────────────────────────────────────────────

var drag_key: u64 = 0;

pub fn hasActiveDrag() bool {
    return drag_key != 0;
}

pub fn cancelDrag() void {
    drag_key = 0;
}

/// Claim the (single) pane drag for `key`; false if another is live.
pub fn tryStartDrag(key: u64) bool {
    if (drag_key != 0) return false;
    drag_key = key;
    return true;
}

pub fn isDraggingKey(key: u64) bool {
    return drag_key == key;
}

/// A stable key from a salt and two ids (drag keys, per-object state).
pub fn keyFromIds(salt: u64, a: u64, b: u64) u64 {
    var h = salt;
    h ^= a;
    h = h *% 0x9E3779B97F4A7C15;
    h ^= b;
    h = h *% 0x9E3779B97F4A7C15;
    return if (h == 0) 1 else h;
}

// ── Cursor ───────────────────────────────────────────────────────────

var cursor: c_int = c.rl.MOUSE_CURSOR_DEFAULT;
var cursor_prio: u8 = 0;

pub fn beginFrame() void {
    cursor = c.rl.MOUSE_CURSOR_DEFAULT;
    cursor_prio = 0;
}

/// Ask for a cursor this frame; the highest priority wins.
pub fn requestCursor(cur: c_int, prio: u8) void {
    if (prio >= cursor_prio) {
        cursor = cur;
        cursor_prio = prio;
    }
}

/// Hand this frame's pane cursor to the Ui (before `Ui.endFrame`).
pub fn applyCursor(ui: *core.Ui) void {
    if (cursor_prio > 0) ui.requestCursor(cursor, cursor_prio);
}

// ── Float rects ──────────────────────────────────────────────────────

pub const FRect = c.rl.Rectangle;

pub fn rect(x: f32, y: f32, w: f32, h: f32) FRect {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

pub fn contains(r: FRect, x: f32, y: f32) bool {
    return x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
}
