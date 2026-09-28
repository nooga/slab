//! Automation curves (docs/22). One curve type for track lanes, clip lanes
//! and note expression: sorted points, each shaping the segment after it.
//! `eval` is pure and shared by the audio thread and the UI, so what a
//! control shows and what the audio hears never disagree.

const std = @import("std");

pub const Shape = enum(u8) { hold, linear, curve };

/// A breakpoint. `shape`/`tension` describe the segment to the next point.
/// `value` is in knob space: a control's 0..1 norm (or a stepped control's
/// raw index), track volume as volume/1.25, pan as (pan+1)/2.
pub const Point = struct {
    beat: f64,
    value: f32,
    shape: Shape = .linear,
    tension: f32 = 0,
    /// UI-only: point selection in the lane editor.
    selected: bool = false,
};

pub const MAX_TENSION: f32 = 1;

/// Power-curve exponent for a tension τ ∈ [-1, 1]: 2^(−4τ), 1/16..16.
pub fn curveK(tension: f32) f32 {
    return std.math.exp2(-4 * std.math.clamp(tension, -MAX_TENSION, MAX_TENSION));
}

/// Fraction of the way from v0 to v1 at `u` (0..1) through a segment.
pub fn shapeAt(shape: Shape, tension: f32, u: f32) f32 {
    return switch (shape) {
        .hold => 0,
        .linear => u,
        .curve => std.math.pow(f32, std.math.clamp(u, 0, 1), curveK(tension)),
    };
}

/// Tension that puts a segment's midpoint `m` (0..1, fraction of the way
/// from v0 to v1) where the pointer is: solves 0.5^k = m.
pub fn tensionForMidpoint(m: f32) f32 {
    const mm = std.math.clamp(m, 0.001, 0.999);
    const k = @log(mm) / @log(@as(f32, 0.5));
    return std.math.clamp(-std.math.log2(k) / 4, -MAX_TENSION, MAX_TENSION);
}

/// Index of the last point with beat <= `beat`, or null before the first.
/// Among same-beat points (an instant jump) this is the later one, so the
/// curve leaves a jump from its second value.
pub fn segmentIndex(points: []const Point, beat: f64) ?usize {
    var lo: usize = 0;
    var hi: usize = points.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (points[mid].beat <= beat) lo = mid + 1 else hi = mid;
    }
    return if (lo == 0) null else lo - 1;
}

fn evalAt(points: []const Point, idx: ?usize, beat: f64) f32 {
    const i = idx orelse return points[0].value;
    if (i + 1 >= points.len) return points[i].value;
    const p0 = points[i];
    const p1 = points[i + 1];
    const span = p1.beat - p0.beat;
    if (span <= 0) return p1.value;
    const u: f32 = @floatCast(std.math.clamp((beat - p0.beat) / span, 0, 1));
    if (p0.shape == .hold) return p0.value;
    return p0.value + (p1.value - p0.value) * shapeAt(p0.shape, p0.tension, u);
}

/// The curve's value at `beat`. Holds the first value before the first
/// point and the last after the last. `points` must be sorted and non-empty.
pub fn eval(points: []const Point, beat: f64) f32 {
    std.debug.assert(points.len > 0);
    return evalAt(points, segmentIndex(points, beat), beat);
}

/// `eval` with a per-lane cursor: playback moves forward a segment at a
/// time, so most calls cost a comparison. Any jump (seek, loop wrap, new
/// points) falls back to the binary search. Audio-thread safe.
pub fn evalCursor(points: []const Point, beat: f64, cursor: *u32) f32 {
    std.debug.assert(points.len > 0);
    var c: usize = cursor.*;
    const fits = struct {
        fn f(p: []const Point, i: usize, b: f64) bool {
            return p[i].beat <= b and (i + 1 >= p.len or p[i + 1].beat > b);
        }
    }.f;
    var idx: ?usize = null;
    if (c < points.len and fits(points, c, beat)) {
        idx = c;
    } else if (c + 1 < points.len and fits(points, c + 1, beat)) {
        idx = c + 1;
    } else {
        idx = segmentIndex(points, beat);
    }
    c = idx orelse 0;
    cursor.* = @intCast(c);
    return evalAt(points, idx, beat);
}

// ── Targets and lanes (UI-thread document data) ──────────────────────

pub const MAX_PARAM_ID = 24;

pub const TargetKind = enum(u8) { volume, pan, inst, fx };

/// What a lane drives. Effects are addressed by their instance uid (stable
/// under reordering); machine controls by param id (stable under machine
/// swaps and manifest reloads — a lane whose id is missing goes quiet).
pub const Target = struct {
    kind: TargetKind,
    fx_uid: u16 = 0,
    param_buf: [MAX_PARAM_ID]u8 = [_]u8{0} ** MAX_PARAM_ID,
    param_len: u8 = 0,

    pub fn volume() Target {
        return .{ .kind = .volume };
    }

    pub fn pan() Target {
        return .{ .kind = .pan };
    }

    pub fn control(kind: TargetKind, fx_uid: u16, id: []const u8) Target {
        var t = Target{ .kind = kind, .fx_uid = fx_uid };
        const n = @min(id.len, MAX_PARAM_ID);
        @memcpy(t.param_buf[0..n], id[0..n]);
        t.param_len = @intCast(n);
        return t;
    }

    pub fn param(self: *const Target) []const u8 {
        return self.param_buf[0..self.param_len];
    }

    pub fn eql(a: Target, b: Target) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .volume, .pan => true,
            .inst => std.mem.eql(u8, a.param(), b.param()),
            .fx => a.fx_uid == b.fx_uid and std.mem.eql(u8, a.param(), b.param()),
        };
    }
};

pub const Lane = struct {
    target: Target,
    points: std.ArrayList(Point) = .empty,
    /// Stepped targets (switches, int ranges) only take `hold` segments.
    stepped: bool = false,

    pub fn deinit(self: *Lane, alloc: std.mem.Allocator) void {
        self.points.deinit(alloc);
    }

    pub fn clone(self: *const Lane, alloc: std.mem.Allocator) !Lane {
        var out = self.*;
        out.points = .empty;
        try out.points.appendSlice(alloc, self.points.items);
        return out;
    }

    /// Insert keeping the list sorted; a point at an existing beat goes
    /// after the points already there. Returns its index.
    pub fn insert(self: *Lane, alloc: std.mem.Allocator, p: Point) !usize {
        var q = p;
        if (self.stepped) {
            q.shape = .hold;
            q.value = @round(q.value);
        }
        const at = if (segmentIndex(self.points.items, q.beat)) |i| i + 1 else 0;
        try self.points.insert(alloc, at, q);
        return at;
    }

    pub fn value(self: *const Lane, beat: f64) ?f32 {
        if (self.points.items.len == 0) return null;
        return eval(self.points.items, beat);
    }

    pub fn selectedCount(self: *const Lane) usize {
        var n: usize = 0;
        for (self.points.items) |p| n += @intFromBool(p.selected);
        return n;
    }

    pub fn deselectAll(self: *Lane) void {
        for (self.points.items) |*p| p.selected = false;
    }

    pub fn removeSelected(self: *Lane) void {
        var w: usize = 0;
        for (self.points.items) |p| {
            if (p.selected) continue;
            self.points.items[w] = p;
            w += 1;
        }
        self.points.items.len = w;
    }

    /// Restore sort order after moving points (stable, so same-beat pairs
    /// keep their order).
    pub fn sort(self: *Lane) void {
        std.sort.insertion(Point, self.points.items, {}, struct {
            fn lt(_: void, a: Point, b: Point) bool {
                return a.beat < b.beat;
            }
        }.lt);
    }
};

// ── Thinning (freehand draw, recording) ──────────────────────────────

/// Ramer–Douglas–Peucker over (x, y) samples in pixel space: marks the
/// points to keep in `keep` (same length). Iterative with a bounded stack.
pub fn thin(xs: []const f32, ys: []const f32, tolerance: f32, keep: []bool) void {
    const n = xs.len;
    @memset(keep, false);
    if (n == 0) return;
    keep[0] = true;
    keep[n - 1] = true;
    var stack: [64][2]usize = undefined;
    var sp: usize = 0;
    stack[sp] = .{ 0, n - 1 };
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const a, const b = stack[sp];
        if (b <= a + 1) continue;
        const dx = xs[b] - xs[a];
        const dy = ys[b] - ys[a];
        const len = @max(@sqrt(dx * dx + dy * dy), 1e-6);
        var worst: usize = a;
        var worst_d: f32 = 0;
        for (a + 1..b) |i| {
            const d = @abs(dy * (xs[i] - xs[a]) - dx * (ys[i] - ys[a])) / len;
            if (d > worst_d) {
                worst_d = d;
                worst = i;
            }
        }
        if (worst_d <= tolerance) continue;
        keep[worst] = true;
        if (sp + 2 > stack.len) {
            // Out of stack: keep everything in the span rather than drop detail.
            for (a..b) |i| keep[i] = true;
            continue;
        }
        stack[sp] = .{ a, worst };
        stack[sp + 1] = .{ worst, b };
        sp += 2;
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "eval holds outside the points and interpolates linearly" {
    const pts = [_]Point{ .{ .beat = 4, .value = 0.2 }, .{ .beat = 8, .value = 0.6 } };
    try testing.expectEqual(@as(f32, 0.2), eval(&pts, 0));
    try testing.expectEqual(@as(f32, 0.2), eval(&pts, 4));
    try testing.expectApproxEqAbs(@as(f32, 0.4), eval(&pts, 6), 1e-6);
    try testing.expectEqual(@as(f32, 0.6), eval(&pts, 8));
    try testing.expectEqual(@as(f32, 0.6), eval(&pts, 100));
}

test "same-beat points jump and leave from the later value" {
    const pts = [_]Point{
        .{ .beat = 0, .value = 0 },
        .{ .beat = 4, .value = 1 },
        .{ .beat = 4, .value = 0.5 },
        .{ .beat = 8, .value = 0.5 },
    };
    try testing.expectApproxEqAbs(@as(f32, 0.999), eval(&pts, 3.996), 1e-3);
    try testing.expectEqual(@as(f32, 0.5), eval(&pts, 4));
    try testing.expectEqual(@as(f32, 0.5), eval(&pts, 6));
}

test "hold steps at the next point" {
    const pts = [_]Point{ .{ .beat = 0, .value = 0.1, .shape = .hold }, .{ .beat = 2, .value = 0.9 } };
    try testing.expectEqual(@as(f32, 0.1), eval(&pts, 1.999));
    try testing.expectEqual(@as(f32, 0.9), eval(&pts, 2));
}

test "curve tension bends without overshoot and mirrors" {
    const up = [_]Point{ .{ .beat = 0, .value = 0, .shape = .curve, .tension = 0.5 }, .{ .beat = 1, .value = 1 } };
    const down = [_]Point{ .{ .beat = 0, .value = 0, .shape = .curve, .tension = -0.5 }, .{ .beat = 1, .value = 1 } };
    // Fast start: past the midpoint by halfway; slow start: short of it.
    try testing.expect(eval(&up, 0.5) > 0.7);
    try testing.expect(eval(&down, 0.5) < 0.3);
    // u^k and u^(1/k) mirror across the diagonal: f(g(x)) = x.
    const x: f32 = 0.3;
    const y = eval(&down, x);
    try testing.expectApproxEqAbs(x, eval(&up, y), 1e-4);
    var b: f64 = 0;
    while (b <= 1) : (b += 0.01) {
        const v = eval(&up, b);
        try testing.expect(v >= 0 and v <= 1);
    }
}

test "tensionForMidpoint round-trips through the curve" {
    for ([_]f32{ 0.1, 0.25, 0.5, 0.75, 0.9 }) |m| {
        const t = tensionForMidpoint(m);
        try testing.expectApproxEqAbs(m, shapeAt(.curve, t, 0.5), 1e-3);
    }
    try testing.expectEqual(MAX_TENSION, tensionForMidpoint(0.999));
}

test "evalCursor matches eval across forward play and seeks" {
    const pts = [_]Point{
        .{ .beat = 0, .value = 0 },
        .{ .beat = 1, .value = 1, .shape = .curve, .tension = 0.3 },
        .{ .beat = 3, .value = 0.2, .shape = .hold },
        .{ .beat = 5, .value = 0.7 },
    };
    var cur: u32 = 0;
    var b: f64 = -1;
    while (b < 7) : (b += 0.013) try testing.expectEqual(eval(&pts, b), evalCursor(&pts, b, &cur));
    for ([_]f64{ 4.2, 0.5, 6, 0, 2.9 }) |s| try testing.expectEqual(eval(&pts, s), evalCursor(&pts, s, &cur));
}

test "Lane.insert keeps order and puts same-beat points after" {
    const alloc = testing.allocator;
    var lane = Lane{ .target = Target.volume() };
    defer lane.deinit(alloc);
    _ = try lane.insert(alloc, .{ .beat = 4, .value = 0.5 });
    _ = try lane.insert(alloc, .{ .beat = 0, .value = 0.1 });
    const i = try lane.insert(alloc, .{ .beat = 4, .value = 0.9 });
    try testing.expectEqual(@as(usize, 2), i);
    try testing.expectEqual(@as(f32, 0.9), lane.value(4).?);
    try testing.expectEqual(@as(f32, 0.1), lane.value(-3).?);
}

test "stepped lanes force hold and integer values" {
    const alloc = testing.allocator;
    var lane = Lane{ .target = Target.control(.inst, 0, "wave"), .stepped = true };
    defer lane.deinit(alloc);
    _ = try lane.insert(alloc, .{ .beat = 0, .value = 1.4 });
    _ = try lane.insert(alloc, .{ .beat = 2, .value = 2.6 });
    try testing.expectEqual(Shape.hold, lane.points.items[0].shape);
    try testing.expectEqual(@as(f32, 1), lane.value(1.9).?);
    try testing.expectEqual(@as(f32, 3), lane.value(2).?);
}

test "Target.eql compares by kind, uid and param" {
    try testing.expect(Target.volume().eql(Target.volume()));
    try testing.expect(!Target.volume().eql(Target.pan()));
    try testing.expect(Target.control(.inst, 0, "cut").eql(Target.control(.inst, 9, "cut")));
    try testing.expect(!Target.control(.fx, 1, "cut").eql(Target.control(.fx, 2, "cut")));
}

test "thin keeps the corners of a polyline" {
    const xs = [_]f32{ 0, 1, 2, 3, 4, 5, 6 };
    const ys = [_]f32{ 0, 0.01, 0, 5, 10, 10.02, 10 };
    var keep: [7]bool = undefined;
    thin(&xs, &ys, 0.5, &keep);
    try testing.expect(keep[0] and keep[6]);
    try testing.expect(keep[2] and keep[4]);
    try testing.expect(!keep[1] and !keep[5]);
}
