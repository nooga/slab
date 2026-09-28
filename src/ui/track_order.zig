//! Display order of the tracks (docs/23 §Arrangement), shared by the
//! arrangement and the mixer. A bus that some track outputs into is a
//! group: it is drawn above its members, at the place of its first
//! member, with the members after it (nested groups inside). Buses fed
//! only by sends are returns and come last, in index order. Members of a
//! folded group are hidden. Indices never move; only where a row goes.

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
        o.emit(tracks[0..n], &in_tree, &key, NONE, 0, false, &num);
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
    fn emit(o: *Order, tracks: []const Track, in_tree: *const [MAX]bool, key: *const [MAX]u8, parent: u8, depth: u8, hidden: bool, num: *u8) void {
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
                if (o.is_group[i] and depth + 1 < MAX) o.emit(tracks, in_tree, key, @intCast(i), depth + 1, hidden or t.folded, num);
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
