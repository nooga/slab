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

    /// Rows `ti` spans in `rows`: its own and, for a group, everything
    /// inside it (they follow it).
    fn span(o: *const Order, ti: u8) struct { at: usize, len: usize } {
        var at: usize = 0;
        while (at < o.n and o.rows[at].ti != ti) at += 1;
        var end = at + 1;
        while (end < o.n and end != o.main_n and o.within(o.rows[end].ti, ti)) end += 1;
        return .{ .at = at, .len = end - at };
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

/// A new track order (docs/23 §Arrangement): `ti`, with everything inside
/// it, moved to just before `target`, or just after it and everything
/// inside it, among `ti`'s siblings: the same group, or the same section at
/// the top level. Position k holds the track index that goes there;
/// renumbering the tracks to it keeps every other row where it was, since
/// display order follows index order. Null when `target` isn't a sibling
/// (a move out of a group would reroute it) or nothing would move.
pub fn moved(tracks: []const Track, ti: u8, target: u8, after: bool) ?[MAX]u8 {
    const o = Order.ofAll(tracks);
    const n = @min(tracks.len, MAX);
    if (ti >= n or target >= n or ti == target) return null;
    if (o.parent[ti] != o.parent[target]) return null;
    const src = o.span(ti);
    const dst = o.span(target);
    // The same section: the main rows, or the returns.
    if ((src.at < o.main_n) != (dst.at < o.main_n)) return null;
    var rest: [MAX]u8 = undefined;
    var m: usize = 0;
    for (o.rows[0..o.n], 0..) |row, k| {
        if (k >= src.at and k < src.at + src.len) continue;
        rest[m] = row.ti;
        m += 1;
    }
    // Where the target's rows start in what's left.
    var t_at = dst.at;
    if (dst.at > src.at) t_at -= src.len;
    const ins = if (after) t_at + dst.len else t_at;
    var out: [MAX]u8 = undefined;
    @memcpy(out[0..ins], rest[0..ins]);
    for (0..src.len) |k| out[ins + k] = o.rows[src.at + k].ti;
    @memcpy(out[ins + src.len .. o.n], rest[ins..m]);
    var same = true;
    for (out[0..o.n], o.rows[0..o.n]) |a, row| same = same and a == row.ti;
    if (same) return null;
    return out;
}

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

test "moved: a track, a whole group, and nothing out of its group" {
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
    try testing.expectEqualSlices(u8, &.{ 3, 0, 4, 1, 2, 5 }, moved(&ts, 3, 0, false).?[0..6]);
    // The group, members and all, below D.
    try testing.expectEqualSlices(u8, &.{ 0, 3, 4, 1, 2, 5 }, moved(&ts, 4, 3, true).?[0..6]);
    // C above B, inside the group.
    try testing.expectEqualSlices(u8, &.{ 0, 4, 2, 1, 3, 5 }, moved(&ts, 2, 1, false).?[0..6]);
    // Out of the group, into the returns, or onto itself: no.
    try testing.expect(moved(&ts, 1, 3, false) == null);
    try testing.expect(moved(&ts, 3, 5, false) == null);
    try testing.expect(moved(&ts, 0, 4, false) == null); // already just above it
}
