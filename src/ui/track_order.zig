//! Display order of the tracks (docs/23 §Arrangement), shared by the
//! arrangement and the mixer. A bus that some track outputs into is a
//! group: it is drawn above its members, at the place of its first
//! member, with the members after it (nested groups inside). Buses fed
//! only by sends are returns and come last, in index order. Members of a
//! folded group are hidden. Display order follows index order, so a
//! reorder (`moved`) renumbers the tracks.

const std = @import("std");
const routing = @import("../routing.zig");
const Track = @import("../track.zig").Track;

const MAX = routing.MAX_TRACKS;
const NONE = routing.NONE;

pub const Row = struct {
    ti: u8,
    /// Nesting: 0 at the top level, 1 inside a group, …
    depth: u8,
};

pub const Order = struct {
    /// Shown rows in display order: the main section, then the returns.
    rows: [MAX]Row = undefined,
    n: usize = 0,
    /// Rows before the RETURNS divider.
    main_n: usize = 0,
    /// Per track index: shown (not inside a folded group).
    shown: [MAX]bool = @splat(false),
    is_group: [MAX]bool = @splat(false),
    /// The group a track or group sits in, or NONE.
    parent: [MAX]u8 = @splat(NONE),
    depth: [MAX]u8 = @splat(0),
    /// Audio tracks' 1-based numbers in display order, folded ones
    /// included (0 for buses).
    number: [MAX]u8 = @splat(0),
    audio_count: usize = 0,

    pub fn of(tracks: []const Track) Order {
        return build(tracks, true);
    }

    /// Every track, folded groups' members too.
    pub fn ofAll(tracks: []const Track) Order {
        return build(tracks, false);
    }

    fn build(tracks: []const Track, folds: bool) Order {
        var o: Order = .{};
        const n = @min(tracks.len, MAX);
        for (tracks[0..n]) |*t| {
            if (t.output < n and tracks[t.output].isBus()) o.is_group[t.output] = true;
        }
        var in_tree: [MAX]bool = @splat(false);
        for (tracks[0..n], 0..) |*t, i| in_tree[i] = !t.isBus() or o.is_group[i];
        for (tracks[0..n], 0..) |*t, i| {
            if (in_tree[i] and t.output < n and o.is_group[t.output]) o.parent[i] = t.output;
        }
        // A subtree sits where its lowest index would: key = min index.
        var key: [MAX]u8 = undefined;
        for (0..n) |i| key[i] = @intCast(i);
        for (0..n) |i| {
            if (!in_tree[i]) continue;
            var a = o.parent[i];
            var guard: usize = 0;
            while (a != NONE and guard < MAX) : (guard += 1) {
                key[a] = @min(key[a], @as(u8, @intCast(i)));
                a = o.parent[a];
            }
        }
        var num: u8 = 0;
        o.emit(tracks[0..n], &in_tree, &key, NONE, 0, false, folds, &num);
        o.main_n = o.n;
        o.audio_count = num;
        for (tracks[0..n], 0..) |*t, i| {
            if (!t.isBus() or in_tree[i]) continue;
            o.rows[o.n] = .{ .ti = @intCast(i), .depth = 0 };
            o.n += 1;
            o.shown[i] = true;
        }
        return o;
    }

    /// Emit `parent`'s children (the top level for NONE) in key order,
    /// each followed by its own children.
    fn emit(o: *Order, tracks: []const Track, in_tree: *const [MAX]bool, key: *const [MAX]u8, parent: u8, depth: u8, hidden: bool, folds: bool, num: *u8) void {
        for (0..tracks.len) |k| {
            for (tracks, 0..) |*t, i| {
                if (!in_tree[i] or o.parent[i] != parent or key[i] != k) continue;
                o.depth[i] = depth;
                if (!t.isBus()) {
                    num.* += 1;
                    o.number[i] = num.*;
                }
                if (!hidden) {
                    o.rows[o.n] = .{ .ti = @intCast(i), .depth = depth };
                    o.n += 1;
                    o.shown[i] = true;
                }
                if (o.is_group[i] and depth + 1 < MAX) o.emit(tracks, in_tree, key, @intCast(i), depth + 1, hidden or (folds and t.folded), folds, num);
            }
        }
    }

    pub fn hasReturns(o: *const Order) bool {
        return o.n > o.main_n;
    }

    pub fn main(o: *const Order) []const Row {
        return o.rows[0..o.main_n];
    }

    pub fn returns(o: *const Order) []const Row {
        return o.rows[o.main_n..o.n];
    }

    /// The rows of `set` in a section (the returns, or the main rows) that
    /// sit in no other row of it, in display order, into `out`: a group's
    /// stands for everything inside it. Their count.
    pub fn roots(o: *const Order, set: *const [MAX]bool, in_returns: bool, out: *[MAX]u8) usize {
        var n: usize = 0;
        for (o.rows[0..o.n], 0..) |row, k| {
            if ((k >= o.main_n) != in_returns or !set[row.ti]) continue;
            var a = o.parent[row.ti];
            var covered = false;
            while (a != NONE) : (a = o.parent[a]) covered = covered or set[a];
            if (covered) continue;
            out[n] = row.ti;
            n += 1;
        }
        return n;
    }

    /// Whether `ti` is `group` or sits inside it at any depth.
    pub fn within(o: *const Order, ti: usize, group: usize) bool {
        var a: u8 = @intCast(ti);
        var guard: usize = 0;
        while (a != NONE and guard < MAX) : (guard += 1) {
            if (a == group) return true;
            a = o.parent[a];
        }
        return false;
    }
};

/// Where a drag drops (docs/23 §Arrangement): into `parent` (a group, or
/// NONE for the top level), before its child `before` (NONE: at its end).
/// In the returns section only returns move, and only at the top level.
pub const Drop = struct {
    parent: u8 = NONE,
    before: u8 = NONE,
    returns: bool = false,
};

/// A drop beside a shown row, with how deep it lands (for the drop
/// line's indent) and the row boundary it's drawn at.
pub const DropAt = struct {
    drop: Drop,
    depth: u8,
    /// The line sits above row `gap` of `Order.of` (n: below the last).
    gap: usize,
};

/// The drop beside shown row `k` of `o` (an `Order.of`): before it, or
/// after it, which for an open group with members is into it, first.
pub fn dropAt(o: *const Order, k: usize, after: bool) DropAt {
    const returns = k >= o.main_n;
    const hi = if (returns) o.n else o.main_n;
    const ti = o.rows[k].ti;
    if (!after) return .{ .drop = .{ .parent = o.parent[ti], .before = ti, .returns = returns }, .depth = o.depth[ti], .gap = k };
    const next: ?u8 = if (k + 1 < hi) o.rows[k + 1].ti else null;
    if (next) |nx| if (o.parent[nx] == ti) {
        return .{ .drop = .{ .parent = ti, .before = nx }, .depth = o.depth[ti] + 1, .gap = k + 1 };
    };
    const before: u8 = if (next) |nx| (if (o.parent[nx] == o.parent[ti]) nx else NONE) else NONE;
    return .{ .drop = .{ .parent = o.parent[ti], .before = before, .returns = returns }, .depth = o.depth[ti], .gap = k + 1 };
}

/// The end of a section, at the top level.
pub fn dropEnd(o: *const Order, returns: bool) DropAt {
    return .{ .drop = .{ .returns = returns }, .depth = 0, .gap = if (returns) o.n else o.main_n };
}

/// A reorder: renumber the tracks to `order` (position k holds the old
/// index of the track that goes there) after setting `output` (per old
/// index: a group's old index, NONE for the master, or KEEP).
pub const Move = struct {
    order: [MAX]u8,
    output: [MAX]u8,
};

pub const KEEP: u8 = 0xfe;

/// Move the rows in `set` (of the drop's section; a group carries
/// everything inside it) to `drop`. A row that lands in another group is
/// routed into it, or to the master at the top level; a group left empty
/// is a group no more and joins the returns. The new order is the new
/// display order, so nothing else moves on screen. Null when nothing would
/// change, the drop is inside a moved group, or a reroute would close a
/// loop.
pub fn moveSet(tracks: []const Track, set: *const [MAX]bool, drop: Drop) ?Move {
    const o = Order.ofAll(tracks);
    const n = @min(tracks.len, MAX);
    if (drop.returns and drop.parent != NONE) return null;
    // The moved rows' roots in display order, and everything they carry.
    var roots: [MAX]u8 = undefined;
    const nr = o.roots(set, drop.returns, &roots);
    var moving: [MAX]bool = @splat(false);
    if (nr == 0) return null;
    for (o.rows[0..o.n]) |row| {
        for (roots[0..nr]) |r| if (o.within(row.ti, r)) {
            moving[row.ti] = true;
        };
    }
    if (drop.parent != NONE and (drop.parent >= n or moving[drop.parent] or !o.is_group[drop.parent])) return null;

    var out: Move = .{ .order = undefined, .output = @splat(KEEP) };
    var nodes: [MAX]routing.Node = undefined;
    for (tracks[0..n], 0..) |*t, i| nodes[i] = t.routingNode();
    const graph = routing.Routing.build(nodes[0..n]);
    var changed = false;
    for (roots[0..nr]) |r| {
        if (drop.returns or o.parent[r] == drop.parent) continue;
        if (drop.parent != NONE and graph.wouldCycle(r, drop.parent)) return null;
        out.output[r] = drop.parent;
        changed = true;
    }
    // Groups left with no members.
    var empty: [MAX]bool = @splat(false);
    for (0..n) |g| {
        if (!o.is_group[g]) continue;
        var members = false;
        for (tracks[0..n], 0..) |*t, i| {
            const dest = if (out.output[i] == KEEP) t.output else out.output[i];
            members = members or dest == g;
        }
        empty[g] = !members;
    }

    var w = Walk{ .o = &o, .roots = roots[0..nr], .moving = &moving, .empty = &empty, .drop = drop, .seq = &out.order };
    w.emit(NONE);
    for (0..n) |g| if (empty[g]) w.push(@intCast(g));
    // The returns, in display order; the moved ones at the drop.
    for (o.returns()) |row| {
        if (drop.returns and row.ti == drop.before) for (roots[0..nr]) |r| w.push(r);
        if (!(drop.returns and moving[row.ti])) w.push(row.ti);
    }
    if (drop.returns and (drop.before == NONE or !o.shown[drop.before] or moving[drop.before])) {
        for (roots[0..nr]) |r| if (!w.has(r)) w.push(r);
    }
    if (w.n != o.n) return null;
    for (out.order[0..o.n], o.rows[0..o.n]) |a, row| changed = changed or a != row.ti;
    return if (changed) out else null;
}

/// The new main-section order, depth first.
const Walk = struct {
    o: *const Order,
    roots: []const u8,
    moving: *const [MAX]bool,
    empty: *const [MAX]bool,
    drop: Drop,
    seq: *[MAX]u8,
    n: usize = 0,

    fn push(w: *Walk, ti: u8) void {
        w.seq[w.n] = ti;
        w.n += 1;
    }

    fn has(w: *const Walk, ti: u8) bool {
        return std.mem.indexOfScalar(u8, w.seq[0..w.n], ti) != null;
    }

    fn isRoot(w: *const Walk, ti: u8) bool {
        return std.mem.indexOfScalar(u8, w.roots, ti) != null;
    }

    /// `ti` and, for a group, its children.
    fn row(w: *Walk, ti: u8) void {
        if (w.empty[ti]) return; // joins the returns
        w.push(ti);
        if (w.o.is_group[ti] and !w.empty[ti]) w.emit(ti);
    }

    /// `parent`'s children in their order, the roots dropped among them.
    fn emit(w: *Walk, parent: u8) void {
        const here = !w.drop.returns and w.drop.parent == parent;
        var placed = false;
        for (w.o.main()) |r| {
            if (w.o.parent[r.ti] != parent or w.empty[r.ti]) continue;
            if (here and !placed and r.ti == w.drop.before) {
                for (w.roots) |x| w.row(x);
                placed = true;
            }
            if (w.isRoot(r.ti) and !w.drop.returns) continue;
            w.row(r.ti);
        }
        if (here and !placed) for (w.roots) |x| w.row(x);
    }
};

const testing = std.testing;
const machine_mod = @import("../machine.zig");

fn testTrack(name: []const u8, bus: bool) !Track {
    var t = try Track.init(testing.allocator, name, .{ .r = 0, .g = 0, .b = 0, .a = 255 }, machine_mod.Machine{
        .name = "test",
        .state = undefined,
        .render = struct {
            fn f(_: *anyopaque, _: *const machine_mod.MachineCtx, _: []f32, _: []f32) void {}
        }.f,
        .draw_panel = struct {
            fn f(_: *anyopaque, _: *@import("core.zig").Ui, _: @import("geom.zig").Rect) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    });
    if (bus) t.kind = .bus;
    return t;
}

test "groups sit above their members at the first member's place; returns come last" {
    // 0 A, 1 B→5, 2 C, 3 D→5, 4 RET (return), 5 GRP→6, 6 OUTER (group)
    var ts: [7]Track = undefined;
    const names = [_][]const u8{ "A", "B", "C", "D", "RET", "GRP", "OUTER" };
    for (&ts, 0..) |*t, i| t.* = try testTrack(names[i], i >= 4);
    defer for (&ts) |*t| t.deinit(testing.allocator);
    ts[1].output = 5;
    ts[3].output = 5;
    ts[5].output = 6;
    try ts[0].addSend(4, false, 1);

    var o = Order.of(&ts);
    const want = [_]u8{ 0, 6, 5, 1, 3, 2, 4 };
    try testing.expectEqual(want.len, o.n);
    for (want, 0..) |ti, k| try testing.expectEqual(ti, o.rows[k].ti);
    try testing.expectEqual(@as(usize, 6), o.main_n);
    try testing.expectEqual(@as(u8, 2), o.depth[1]);
    try testing.expectEqual(@as(u8, 1), o.number[0]);
    try testing.expectEqual(@as(u8, 2), o.number[1]);
    try testing.expectEqual(@as(u8, 3), o.number[3]);
    try testing.expectEqual(@as(u8, 4), o.number[2]);
    try testing.expect(o.within(1, 6));
    try testing.expect(!o.within(2, 5));

    // Folding the outer group hides everything inside it; numbers hold.
    ts[6].folded = true;
    o = Order.of(&ts);
    try testing.expectEqual(@as(usize, 4), o.n);
    try testing.expect(!o.shown[5] and !o.shown[1] and !o.shown[3]);
    try testing.expect(o.shown[6] and o.shown[2]);
    try testing.expectEqual(@as(u8, 4), o.number[2]);
}

fn seqOf(m: ?Move, len: usize) ![]const u8 {
    const mv = m orelse return error.NoMove;
    const S = struct {
        var buf: [MAX]u8 = undefined;
    };
    @memcpy(S.buf[0..len], mv.order[0..len]);
    return S.buf[0..len];
}

fn only(comptime tis: []const u8) [MAX]bool {
    var set: [MAX]bool = @splat(false);
    for (tis) |ti| set[ti] = true;
    return set;
}

test "moveSet: tracks and groups, across groups, several at once" {
    // 0 A, 1 B→4, 2 C→4, 3 D, 4 GRP (group), 5 RET (return)
    var ts: [6]Track = undefined;
    const names = [_][]const u8{ "A", "B", "C", "D", "GRP", "RET" };
    for (&ts, 0..) |*t, i| t.* = try testTrack(names[i], i >= 4);
    defer for (&ts) |*t| t.deinit(testing.allocator);
    ts[1].output = 4;
    ts[2].output = 4;
    try ts[0].addSend(5, false, 1);
    // Shown: A, GRP, B, C, D | RET.
    const o = Order.of(&ts);
    try testing.expectEqualSlices(u8, &.{ 0, 4, 1, 2, 3, 5 }, blk: {
        var v: [6]u8 = undefined;
        for (o.rows[0..o.n], 0..) |r, k| v[k] = r.ti;
        break :blk &v;
    });
    // D above A.
    try testing.expectEqualSlices(u8, &.{ 3, 0, 4, 1, 2, 5 }, try seqOf(moveSet(&ts, &only(&.{3}), .{ .before = 0 }), 6));
    // The group, members and all, at the end.
    try testing.expectEqualSlices(u8, &.{ 0, 3, 4, 1, 2, 5 }, try seqOf(moveSet(&ts, &only(&.{4}), .{}), 6));
    // C above B, inside the group; no reroute.
    const cb = moveSet(&ts, &only(&.{2}), .{ .parent = 4, .before = 1 }).?;
    try testing.expectEqualSlices(u8, &.{ 0, 4, 2, 1, 3, 5 }, cb.order[0..6]);
    try testing.expectEqual(KEEP, cb.output[2]);
    // D into the group, at its end: routed into it.
    const dg = moveSet(&ts, &only(&.{3}), .{ .parent = 4 }).?;
    try testing.expectEqualSlices(u8, &.{ 0, 4, 1, 2, 3, 5 }, dg.order[0..6]);
    try testing.expectEqual(@as(u8, 4), dg.output[3]);
    try testing.expectEqual(KEEP, dg.output[1]);
    // B out of the group, above A: to the master.
    const bo = moveSet(&ts, &only(&.{1}), .{ .before = 0 }).?;
    try testing.expectEqualSlices(u8, &.{ 1, 0, 4, 2, 3, 5 }, bo.order[0..6]);
    try testing.expectEqual(NONE, bo.output[1]);
    // A and D together into the group, before C.
    const ad = moveSet(&ts, &only(&.{ 0, 3 }), .{ .parent = 4, .before = 2 }).?;
    try testing.expectEqualSlices(u8, &.{ 4, 1, 0, 3, 2, 5 }, ad.order[0..6]);
    try testing.expectEqual(@as(u8, 4), ad.output[0]);
    try testing.expectEqual(@as(u8, 4), ad.output[3]);
    // B and C both out: the group is left empty and joins the returns.
    const bc = moveSet(&ts, &only(&.{ 1, 2 }), .{}).?;
    try testing.expectEqualSlices(u8, &.{ 0, 3, 1, 2, 4, 5 }, bc.order[0..6]);
    // Into the returns, into itself, or onto its own place: no.
    try testing.expect(moveSet(&ts, &only(&.{3}), .{ .returns = true }) == null);
    try testing.expect(moveSet(&ts, &only(&.{4}), .{ .parent = 4 }) == null);
    try testing.expect(moveSet(&ts, &only(&.{0}), .{ .before = 4 }) == null);
}

test "moveSet: a reroute that would loop is refused" {
    // 0 A→1, 1 G1 (group), 2 B→3, 3 G2 (group); G2 sends into G1's… no:
    // G1 sends to G2, so G2 can't go into G1.
    var ts: [4]Track = undefined;
    const names = [_][]const u8{ "A", "G1", "B", "G2" };
    for (&ts, 0..) |*t, i| t.* = try testTrack(names[i], i == 1 or i == 3);
    defer for (&ts) |*t| t.deinit(testing.allocator);
    ts[0].output = 1;
    ts[2].output = 3;
    try ts[1].addSend(3, false, 1);
    try testing.expect(moveSet(&ts, &only(&.{3}), .{ .parent = 1 }) == null);
    // The other way round is fine.
    try testing.expect(moveSet(&ts, &only(&.{1}), .{ .parent = 3 }) != null);
}
