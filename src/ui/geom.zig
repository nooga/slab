//! Integer logical-pixel geometry (docs/06 §Pixel grid). UI code never
//! sees fractional rects; the renderer owns the logical → device scale.

const std = @import("std");

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn xywh(x: i32, y: i32, w: i32, h: i32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }

    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }

    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }

    pub fn empty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }

    pub fn inset(r: Rect, n: i32) Rect {
        return .{ .x = r.x + n, .y = r.y + n, .w = @max(0, r.w - 2 * n), .h = @max(0, r.h - 2 * n) };
    }

    pub fn insetXY(r: Rect, nx: i32, ny: i32) Rect {
        return .{ .x = r.x + nx, .y = r.y + ny, .w = @max(0, r.w - 2 * nx), .h = @max(0, r.h - 2 * ny) };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    /// Centre a w×h box inside r (rounded down, so results stay on whole pixels).
    pub fn center(r: Rect, w: i32, h: i32) Rect {
        return .{ .x = r.x + @divFloor(r.w - w, 2), .y = r.y + @divFloor(r.h - h, 2), .w = w, .h = h };
    }

    // ── RectCut: take a slice off one side, shrinking r ──────────────

    pub fn cutTop(r: *Rect, h: i32) Rect {
        const n = std.math.clamp(h, 0, r.h);
        const out = Rect{ .x = r.x, .y = r.y, .w = r.w, .h = n };
        r.y += n;
        r.h -= n;
        return out;
    }

    pub fn cutBottom(r: *Rect, h: i32) Rect {
        const n = std.math.clamp(h, 0, r.h);
        r.h -= n;
        return .{ .x = r.x, .y = r.y + r.h, .w = r.w, .h = n };
    }

    pub fn cutLeft(r: *Rect, w: i32) Rect {
        const n = std.math.clamp(w, 0, r.w);
        const out = Rect{ .x = r.x, .y = r.y, .w = n, .h = r.h };
        r.x += n;
        r.w -= n;
        return out;
    }

    pub fn cutRight(r: *Rect, w: i32) Rect {
        const n = std.math.clamp(w, 0, r.w);
        r.w -= n;
        return .{ .x = r.x + r.w, .y = r.y, .w = n, .h = r.h };
    }

    // Non-mutating variants: the slice only, r unchanged.

    pub fn takeTop(r: Rect, h: i32) Rect {
        var t = r;
        return t.cutTop(h);
    }

    pub fn takeLeft(r: Rect, w: i32) Rect {
        var t = r;
        return t.cutLeft(w);
    }

    /// Cell (col,row) of an even cols×rows grid. Remainder pixels go to
    /// the last column/row so cells tile r exactly.
    pub fn cell(r: Rect, cols: i32, rows: i32, col: i32, row: i32) Rect {
        const cw = @divFloor(r.w, cols);
        const ch = @divFloor(r.h, rows);
        const x = r.x + col * cw;
        const y = r.y + row * ch;
        const w = if (col == cols - 1) r.right() - x else cw;
        const h = if (row == rows - 1) r.bottom() - y else ch;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
};

test "cuts tile the source rect" {
    var r = Rect.xywh(0, 0, 100, 40);
    const top = r.cutTop(16);
    const left = r.cutLeft(30);
    const right = r.cutRight(10);
    try std.testing.expectEqual(Rect.xywh(0, 0, 100, 16), top);
    try std.testing.expectEqual(Rect.xywh(0, 16, 30, 24), left);
    try std.testing.expectEqual(Rect.xywh(90, 16, 10, 24), right);
    try std.testing.expectEqual(Rect.xywh(30, 16, 60, 24), r);
}

test "grid cells cover the rect with no gaps" {
    const r = Rect.xywh(3, 5, 101, 50);
    var sum: i32 = 0;
    for (0..3) |c| sum += r.cell(3, 1, @intCast(c), 0).w;
    try std.testing.expectEqual(@as(i32, 101), sum);
    try std.testing.expectEqual(r.right(), r.cell(3, 2, 2, 1).right());
}
