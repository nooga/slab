//! Routing graph (docs/23): where each track's signal goes after its
//! insert chain (output, sends) and which tracks key which effects. The
//! UI thread builds a `Routing` from the tracks after any routing edit and
//! the engine publishes it double-buffered; the audio thread only reads it.
//! Pure data and bit-mask graph walks, no allocation.

const std = @import("std");

pub const MAX_TRACKS: usize = 32;
pub const MAX_SENDS: usize = 8;
/// Keyed effects per track.
pub const MAX_KEYS: usize = 8;
/// No track: an output to the master, an unset key.
pub const NONE: u8 = 0xff;

const Mask = u32;
comptime {
    std.debug.assert(MAX_TRACKS <= @bitSizeOf(Mask));
}

pub const SendSlot = struct { bus: u8, pre: bool = false };
pub const KeySlot = struct { fx_uid: u16, src: u8 };

/// One track as the graph sees it.
pub const Node = struct {
    is_bus: bool = false,
    /// A bus's index, or NONE for the master.
    output: u8 = NONE,
    sends: [MAX_SENDS]SendSlot = undefined,
    send_count: u8 = 0,
    keys: [MAX_KEYS]KeySlot = undefined,
    key_count: u8 = 0,

    pub fn sendSlots(self: *const Node) []const SendSlot {
        return self.sends[0..self.send_count];
    }

    pub fn keySlots(self: *const Node) []const KeySlot {
        return self.keys[0..self.key_count];
    }

    /// The track keying effect `fx_uid`, if any.
    pub fn keyFor(self: *const Node, fx_uid: u16) ?u8 {
        for (self.keySlots()) |k| if (k.fx_uid == fx_uid) return k.src;
        return null;
    }
};

pub const Routing = struct {
    count: u8 = 0,
    /// Render order: every node after all it depends on.
    order: [MAX_TRACKS]u8 = undefined,
    nodes: [MAX_TRACKS]Node = undefined,
    /// Audio edges (outputs and sends): `audio_succ[i]` has bit j when i's
    /// signal is summed into bus j.
    audio_succ: [MAX_TRACKS]Mask = @splat(0),
    /// Key edges: `key_succ[i]` has bit j when i keys an effect on j.
    key_succ: [MAX_TRACKS]Mask = @splat(0),

    /// The graph over `nodes`, with references that aren't valid dropped:
    /// outputs and sends to a non-bus, a missing track or the node itself,
    /// keys from a missing track or the node itself. A cycle left in the
    /// input (the UI refuses them, `wouldCycle`) renders its members after
    /// the rest, in index order.
    pub fn build(nodes_in: []const Node) Routing {
        std.debug.assert(nodes_in.len <= MAX_TRACKS);
        var r = Routing{ .count = @intCast(nodes_in.len) };
        const n = nodes_in.len;
        for (nodes_in, 0..) |src, i| {
            var nd = src;
            if (!validBus(nodes_in, nd.output, i)) nd.output = NONE;
            var sc: u8 = 0;
            for (src.sendSlots()) |s| {
                if (!validBus(nodes_in, s.bus, i)) continue;
                nd.sends[sc] = s;
                sc += 1;
            }
            nd.send_count = sc;
            var kc: u8 = 0;
            for (src.keySlots()) |k| {
                if (k.src >= n or k.src == i) continue;
                nd.keys[kc] = k;
                kc += 1;
            }
            nd.key_count = kc;
            r.nodes[i] = nd;
        }
        for (r.nodes[0..n], 0..) |*nd, i| {
            if (nd.output != NONE) r.audio_succ[i] |= bit(nd.output);
            for (nd.sendSlots()) |s| r.audio_succ[i] |= bit(s.bus);
            for (nd.keySlots()) |k| r.key_succ[k.src] |= bit(@intCast(i));
        }
        r.sort();
        return r;
    }

    /// Kahn's sort over audio and key edges, lowest index first among the
    /// ready, so an unrouted project renders in track order.
    fn sort(self: *Routing) void {
        const n = self.count;
        var indeg: [MAX_TRACKS]u8 = @splat(0);
        for (0..n) |i| {
            var m = self.audio_succ[i] | self.key_succ[i];
            while (m != 0) : (m &= m - 1) indeg[@ctz(m)] += 1;
        }
        var done: Mask = 0;
        var k: usize = 0;
        while (k < n) {
            var pick: ?usize = null;
            for (0..n) |i| if (done & bit(@intCast(i)) == 0 and indeg[i] == 0) {
                pick = i;
                break;
            };
            const i = pick orelse break; // a cycle: the rest go below
            done |= bit(@intCast(i));
            self.order[k] = @intCast(i);
            k += 1;
            var m = self.audio_succ[i] | self.key_succ[i];
            while (m != 0) : (m &= m - 1) indeg[@ctz(m)] -= 1;
        }
        for (0..n) |i| if (done & bit(@intCast(i)) == 0) {
            self.order[k] = @intCast(i);
            k += 1;
        };
    }

    pub fn renderOrder(self: *const Routing) []const u8 {
        return self.order[0..self.count];
    }

    /// Whether adding an edge `from` → `to` (from's signal or key reaching
    /// to) would close a loop: true when `to` already reaches `from`.
    pub fn wouldCycle(self: *const Routing, from: u8, to: u8) bool {
        if (from == to) return true;
        return self.reach(bit(to), true) & bit(from) != 0;
    }

    /// Everything reachable from `start` (inclusive) along audio edges, and
    /// key edges too when `keys`.
    fn reach(self: *const Routing, start: Mask, keys: bool) Mask {
        var seen = start;
        var frontier = start;
        while (frontier != 0) {
            var next: Mask = 0;
            var m = frontier;
            while (m != 0) : (m &= m - 1) {
                const i = @ctz(m);
                next |= self.audio_succ[i];
                if (keys) next |= self.key_succ[i];
            }
            frontier = next & ~seen;
            seen |= next;
        }
        return seen;
    }

    /// Everything that reaches `start` (inclusive) along audio edges.
    fn reachBack(self: *const Routing, start: Mask) Mask {
        var seen = start;
        var changed = true;
        while (changed) {
            changed = false;
            for (0..self.count) |i| {
                const b = bit(@intCast(i));
                if (seen & b == 0 and self.audio_succ[i] & seen != 0) {
                    seen |= b;
                    changed = true;
                }
            }
        }
        return seen;
    }

    /// Who is heard (docs/23 §Semantics): unmuted, and when anything is
    /// soloed, soloed or downstream of a soloed node or upstream of a
    /// soloed bus, along outputs and sends.
    pub fn audible(self: *const Routing, muted: Mask, soloed: Mask) Mask {
        const all: Mask = if (self.count == MAX_TRACKS) ~@as(Mask, 0) else (@as(Mask, 1) << @intCast(self.count)) - 1;
        var on = all & ~muted;
        if (soloed != 0) {
            var buses: Mask = 0;
            for (0..self.count) |i| if (self.nodes[i].is_bus) {
                buses |= bit(@intCast(i));
            };
            on &= self.reach(soloed, false) | self.reachBack(soloed & buses);
        }
        return on;
    }

    /// Who renders: the audible, plus anything keying something that
    /// renders (a muted ghost-kick still ducks).
    pub fn rendered(self: *const Routing, audible_set: Mask) Mask {
        var out = audible_set;
        const order = self.renderOrder();
        var k = order.len;
        while (k > 0) {
            k -= 1;
            const i = order[k];
            if (self.key_succ[i] & out != 0) out |= bit(i);
        }
        return out;
    }
};

fn validBus(nodes: []const Node, target: u8, self_idx: usize) bool {
    return target != NONE and target < nodes.len and target != self_idx and nodes[target].is_bus;
}

pub fn bit(i: u8) Mask {
    return @as(Mask, 1) << @intCast(i);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn busNode() Node {
    return .{ .is_bus = true };
}

fn sendTo(nd: *Node, bus: u8, pre: bool) void {
    nd.sends[nd.send_count] = .{ .bus = bus, .pre = pre };
    nd.send_count += 1;
}

fn keyFrom(nd: *Node, fx_uid: u16, src: u8) void {
    nd.keys[nd.key_count] = .{ .fx_uid = fx_uid, .src = src };
    nd.key_count += 1;
}

test "unrouted tracks render in index order" {
    const nodes = [_]Node{ .{}, .{}, .{} };
    const r = Routing.build(&nodes);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, r.renderOrder());
}

test "buses render after everything that feeds them" {
    // 0: bus (group) fed by 2's output; 1: return fed by 2's send; 2: track.
    var nodes = [_]Node{ busNode(), busNode(), .{ .output = 0 } };
    sendTo(&nodes[2], 1, false);
    const r = Routing.build(&nodes);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 1 }, r.renderOrder());
}

test "a key source renders before the keyed track" {
    // 1 (bass) has an effect keyed by 2 (kick).
    var nodes = [_]Node{ .{}, .{}, .{} };
    keyFrom(&nodes[1], 5, 2);
    const r = Routing.build(&nodes);
    try testing.expectEqualSlices(u8, &.{ 0, 2, 1 }, r.renderOrder());
    try testing.expectEqual(@as(?u8, 2), r.nodes[1].keyFor(5));
    try testing.expectEqual(@as(?u8, null), r.nodes[1].keyFor(6));
}

test "invalid references are dropped" {
    var nodes = [_]Node{ .{ .output = 1 }, .{ .output = 7 }, busNode() };
    sendTo(&nodes[0], 0, false); // to a non-bus (itself)
    sendTo(&nodes[0], 2, true);
    keyFrom(&nodes[1], 1, 9);
    nodes[2].output = 2; // bus into itself
    const r = Routing.build(&nodes);
    try testing.expectEqual(NONE, r.nodes[0].output); // 1 is not a bus
    try testing.expectEqual(NONE, r.nodes[1].output);
    try testing.expectEqual(NONE, r.nodes[2].output);
    try testing.expectEqual(@as(u8, 1), r.nodes[0].send_count);
    try testing.expectEqual(@as(u8, 2), r.nodes[0].sends[0].bus);
    try testing.expectEqual(@as(u8, 0), r.nodes[1].key_count);
}

test "wouldCycle sees loops through outputs, sends and keys" {
    // 0 → bus 1 → bus 2
    var nodes = [_]Node{ .{ .output = 1 }, .{ .is_bus = true, .output = 2 }, busNode(), .{} };
    const r = Routing.build(&nodes);
    try testing.expect(r.wouldCycle(2, 1)); // bus 2 into bus 1
    try testing.expect(r.wouldCycle(1, 1));
    try testing.expect(!r.wouldCycle(3, 1));
    try testing.expect(!r.wouldCycle(0, 2));
    // 3 keys 0; then 0 keying 3 would loop.
    keyFrom(&nodes[0], 1, 3);
    const r2 = Routing.build(&nodes);
    try testing.expect(r2.wouldCycle(0, 3));
    try testing.expect(r2.wouldCycle(2, 3)); // 3 → 0 → 1 → 2
}

test "a cycle in the input still renders every node once" {
    var nodes = [_]Node{ .{ .is_bus = true, .output = 1 }, .{ .is_bus = true, .output = 0 }, .{} };
    const r = Routing.build(&nodes);
    var seen: Mask = 0;
    for (r.renderOrder()) |i| seen |= bit(i);
    try testing.expectEqual(@as(Mask, 0b111), seen);
    try testing.expectEqual(@as(u8, 2), r.order[0]);
}

test "solo keeps what a soloed node feeds and what feeds a soloed bus" {
    // 0 snare → out 3 (group), send 2 (verb); 1 bass → master; 2 verb bus → master; 3 group bus.
    var nodes = [_]Node{ .{ .output = 3 }, .{}, busNode(), busNode() };
    sendTo(&nodes[0], 2, false);
    const r = Routing.build(&nodes);
    try testing.expectEqual(@as(Mask, 0b1111), r.audible(0, 0));
    try testing.expectEqual(@as(Mask, 0b1101), r.audible(0, bit(0))); // snare + verb + group
    try testing.expectEqual(@as(Mask, 0b0101), r.audible(0, bit(2))); // verb + its source
    try testing.expectEqual(@as(Mask, 0b1100), r.audible(bit(0) | bit(1), 0));
}

test "a muted key source still renders" {
    var nodes = [_]Node{ .{}, .{} };
    keyFrom(&nodes[1], 1, 0); // kick 0 keys bass 1
    const r = Routing.build(&nodes);
    const on = r.audible(bit(0), 0);
    try testing.expectEqual(@as(Mask, 0b10), on);
    try testing.expectEqual(@as(Mask, 0b11), r.rendered(on));
    // Nothing renders for a key whose reader is silent.
    try testing.expectEqual(@as(Mask, 0), r.rendered(0));
}
