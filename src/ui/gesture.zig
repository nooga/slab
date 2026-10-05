//! The pointer grammar every timeline shares (docs/31 §Pointer): the
//! modifiers, the edge zones of an object, the drag threshold and the one
//! box select. Pure where it can be, so the rules are tested once.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const pane = @import("pane_input.zig");
const bridge = @import("bridge.zig");

const Ui = core.Ui;
const FRect = pane.FRect;

/// A press becomes a drag once the pointer has moved this far.
pub const DRAG_THRESHOLD: f32 = 3;

// ── Modifiers ────────────────────────────────────────────────────────

pub const Mods = struct {
    /// ⌘, or Ctrl (the app treats them alike).
    cmd: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub fn mods() Mods {
    const k = c.rl.IsKeyDown;
    return .{
        .cmd = k(c.rl.KEY_LEFT_SUPER) or k(c.rl.KEY_RIGHT_SUPER) or k(c.rl.KEY_LEFT_CONTROL) or k(c.rl.KEY_RIGHT_CONTROL),
        .shift = k(c.rl.KEY_LEFT_SHIFT) or k(c.rl.KEY_RIGHT_SHIFT),
        .alt = k(c.rl.KEY_LEFT_ALT) or k(c.rl.KEY_RIGHT_ALT),
    };
}

/// ⌥ frees every gesture (and the nudge keys) from the grid.
pub fn snapBypassed() bool {
    return mods().alt;
}

// ── Edges ────────────────────────────────────────────────────────────

pub const Part = enum { body, left, right };

/// How far an edge zone reaches inside an object `w` px wide: at most
/// 6 px, at most a quarter of it, so the middle half is always body.
pub fn edgeIn(w: f32) f32 {
    return @min(6, w / 4);
}
/// And outside it, so a sliver of an object can still be resized.
pub const EDGE_OUT: f32 = 2;

/// Which part of the span [x0, x1) the pointer `x` is on, or null when it
/// misses (the edge zones reach EDGE_OUT past the span).
pub fn partAt(x0: f32, x1: f32, x: f32) ?Part {
    const w = @max(0, x1 - x0);
    const in = edgeIn(w);
    if (x < x0 - EDGE_OUT or x >= x1 + EDGE_OUT) return null;
    if (x < x0 or x < x0 + in) return .left;
    if (x >= x1 or x >= x1 - in) return .right;
    return .body;
}

/// `partAt` for a rect, vertically strict.
pub fn rectPart(r: FRect, x: f32, y: f32) ?Part {
    if (y < r.y or y >= r.y + r.height) return null;
    return partAt(r.x, r.x + r.width, x);
}

pub fn edgeCursor(p: Part) c_int {
    return if (p == .body) c.rl.MOUSE_CURSOR_POINTING_HAND else c.rl.MOUSE_CURSOR_RESIZE_EW;
}

// ── Rects ────────────────────────────────────────────────────────────

pub fn normalized(x0: f32, y0: f32, x1: f32, y1: f32) FRect {
    return .{ .x = @min(x0, x1), .y = @min(y0, y1), .width = @abs(x1 - x0), .height = @abs(y1 - y0) };
}

/// Touching counts: a box that reaches an object's edge selects it.
pub fn overlaps(a: FRect, b: FRect) bool {
    return !(a.x + a.width < b.x or b.x + b.width < a.x or
        a.y + a.height < b.y or b.y + b.height < a.y);
}

// ── Box select ───────────────────────────────────────────────────────

/// The one box select: the caller clears the selection on press unless ⇧
/// (`add`), draws it while it runs, and on release selects what the
/// rect `finish` reports touches.
pub const Box = struct {
    active: bool = false,
    x0: f32 = 0,
    y0: f32 = 0,
    add: bool = false,
    key: u64 = 0,

    pub fn begin(b: *Box, key: u64, m: pane.Mouse, add: bool) bool {
        if (!pane.tryStartDrag(key)) return false;
        b.* = .{ .active = true, .x0 = m.x, .y0 = m.y, .add = add, .key = key };
        return true;
    }

    pub fn moved(b: *const Box, m: pane.Mouse) bool {
        return @abs(m.x - b.x0) >= DRAG_THRESHOLD or @abs(m.y - b.y0) >= DRAG_THRESHOLD;
    }

    pub fn rect(b: *const Box, m: pane.Mouse) FRect {
        return normalized(b.x0, b.y0, m.x, m.y);
    }

    pub const End = union(enum) {
        /// Still held, or no box running.
        none,
        /// Released within DRAG_THRESHOLD.
        click,
        /// Released after a drag: select what this touches.
        rect: FRect,
    };

    /// Run every frame while a box may be live; reports the release.
    pub fn finish(b: *Box, m: pane.Mouse) End {
        if (!b.active) return .none;
        if (!pane.isDraggingKey(b.key)) {
            b.active = false;
            return .none;
        }
        if (m.left_down) return .none;
        b.active = false;
        pane.cancelDrag();
        return if (b.moved(m)) .{ .rect = b.rect(m) } else .click;
    }

    pub fn cancel(b: *Box) void {
        if (b.active and pane.isDraggingKey(b.key)) pane.cancelDrag();
        b.active = false;
    }

    /// The rubber band, clipped by the caller.
    pub fn draw(b: *const Box, ui: *Ui, m: pane.Mouse) void {
        if (!b.active or !b.moved(m)) return;
        const r = bridge.fromRl(b.rect(m));
        ui.rect(r, style.accent.alpha(30));
        ui.bevel(r, style.accent, style.accent);
    }
};

const testing = std.testing;

test "edge zones: at most 6 px in, the middle half always body" {
    // A wide object: 6 px zones.
    try testing.expectEqual(Part.left, partAt(100, 200, 100).?);
    try testing.expectEqual(Part.left, partAt(100, 200, 105.9).?);
    try testing.expectEqual(Part.body, partAt(100, 200, 106).?);
    try testing.expectEqual(Part.body, partAt(100, 200, 193.9).?);
    try testing.expectEqual(Part.right, partAt(100, 200, 194).?);
    // 2 px outside still grabs the edge; further misses.
    try testing.expectEqual(Part.left, partAt(100, 200, 98.5).?);
    try testing.expectEqual(Part.right, partAt(100, 200, 201.5).?);
    try testing.expect(partAt(100, 200, 97.9) == null);
    try testing.expect(partAt(100, 200, 202) == null);
    // A 12 px note: 3 px zones, 6 px of body.
    try testing.expectEqual(Part.body, partAt(0, 12, 3).?);
    try testing.expectEqual(Part.body, partAt(0, 12, 8.9).?);
    try testing.expectEqual(Part.right, partAt(0, 12, 9).?);
    // A 2 px sliver: half a px each side inside, the rest outside.
    try testing.expectEqual(Part.body, partAt(0, 2, 1).?);
    try testing.expectEqual(Part.left, partAt(0, 2, -1).?);
    try testing.expectEqual(Part.right, partAt(0, 2, 3).?);
}

test "boxes touch inclusively" {
    const a = FRect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try testing.expect(overlaps(a, .{ .x = 10, .y = 10, .width = 5, .height = 5 }));
    try testing.expect(!overlaps(a, .{ .x = 10.5, .y = 0, .width = 5, .height = 5 }));
    const n = normalized(10, 20, 4, 2);
    try testing.expectEqual(@as(f32, 4), n.x);
    try testing.expectEqual(@as(f32, 18), n.height);
}
