//! Group a run of a track's devices into a rack, and back (docs/42 §UI,
//! "Group into a rack"). The run's machines are copied into the rack's
//! first lane through their saved form, and every automation lane that
//! drove them (the track's and its clips') moves one step down the rack,
//! so grouping loses nothing (§Automation inside a rack). Ungrouping a
//! one-lane rack with no mappings does the reverse.
//!
//! Positions in a track's chain: 0 is the instrument, n the n-th effect.

const std = @import("std");
const machine = @import("machine.zig");
const automation = @import("automation.zig");
const track_mod = @import("track.zig");
const registry_mod = @import("machine_registry.zig");
const rack_mod = @import("machines/rack.zig");

const Track = track_mod.Track;
const Registry = registry_mod.Registry;
const Rack = rack_mod.Rack;

pub const Error = error{ NothingToGroup, NotARack, RackNotSimple, PathTooDeep, NoRackMachine } || anyerror;

/// What grouping moved where: the lanes' targets that named a moved
/// machine, the one they name now, and the step down the rack in front of
/// their path.
const Move = struct {
    kind: automation.TargetKind,
    fx_uid: u16,
    to_kind: automation.TargetKind,
    to_fx_uid: u16,
    step: automation.Step,
};

fn retarget(t: *Track, alloc: std.mem.Allocator, moves: []const Move) void {
    retargetList(&t.lanes, alloc, moves);
    for (t.clips.items) |*clip| retargetList(&clip.lanes, alloc, moves);
}

/// Each lane whose target names a moved machine names its new place; one
/// that would go past MAX_PATH is dropped (it would drive nothing).
fn retargetList(lanes: *std.ArrayList(automation.Lane), alloc: std.mem.Allocator, moves: []const Move) void {
    var i: usize = 0;
    while (i < lanes.items.len) {
        const lane = &lanes.items[i];
        const tg = &lane.target;
        const mv = for (moves) |m| {
            if (m.kind == tg.kind and (tg.kind != .fx or m.fx_uid == tg.fx_uid)) break m;
        } else {
            i += 1;
            continue;
        };
        if (tg.path.len >= automation.MAX_PATH) {
            lane.deinit(alloc);
            _ = lanes.orderedRemove(i);
            continue;
        }
        var path = automation.Path{};
        path = path.plus(mv.step);
        for (tg.path.slice()) |st| path = path.plus(st);
        tg.kind = mv.to_kind;
        tg.fx_uid = mv.to_fx_uid;
        tg.path = path;
        i += 1;
    }
}

pub const Grouped = struct {
    /// Sidechain keys don't reach a rack lane's inserts yet (docs/42 §Model):
    /// a moved insert that had one lost it.
    dropped_keys: bool = false,
};

/// Group positions `first`..`last` of `t`'s chain into a new rack: an
/// instrument Rack when the run starts at the instrument, an FX Rack in the
/// run's place otherwise.
pub fn group(alloc: std.mem.Allocator, reg: *Registry, t: *Track, first: usize, last: usize) Error!Grouped {
    const has_inst = !t.isBus() and t.machine_idx != null;
    const with_inst = first == 0;
    if (with_inst and !has_inst) return error.NothingToGroup;
    if (last < first or last > t.effects.items.len or (!with_inst and first == 0)) return error.NothingToGroup;
    const rack_idx = reg.findById(if (with_inst) "rack" else "fxrack") orelse return error.NoRackMachine;
    const m = try reg.instantiatePrepared(rack_idx);
    var installed = false;
    errdefer if (!installed) if (m.deinit) |d| d(m.state, alloc);
    m.reset(m.state);
    const rk: *Rack = @ptrCast(@alignCast(m.state));

    var moves: [rack_mod.MAX_LANE_EFFECTS + 1]Move = undefined;
    var nm: usize = 0;
    const lane = if (with_inst) blk: {
        const l = try rk.addLane(t.machine_idx.?);
        try rk.copySettings(t.machine, l.instrument, t.machine_idx.?);
        break :blk l;
    } else blk: {
        const l = try rk.addLane(null);
        break :blk l;
    };
    // Track positions first..last → effects (first or 1)-1 .. last-1.
    const fx_lo: usize = if (with_inst) 0 else first - 1;
    const fx_hi: usize = last; // exclusive
    if (fx_hi - fx_lo > rack_mod.MAX_LANE_EFFECTS) return error.NothingToGroup;
    var out = Grouped{};
    for (t.effects.items[fx_lo..fx_hi]) |*fx| {
        const idx = fx.idx orelse continue;
        try rk.addEffect(0, idx);
        const nf = &lane.effects.items[lane.effects.items.len - 1];
        try rk.copySettings(fx.mach, nf.mach, idx);
        if (fx.bypass.load(.monotonic)) nf.bypass.store(true, .monotonic);
        if (fx.key != @import("routing.zig").NONE) out.dropped_keys = true;
        moves[nm] = .{ .kind = .fx, .fx_uid = fx.uid, .to_kind = .fx, .to_fx_uid = 0, .step = .{ .lane = lane.uid, .slot = nf.uid } };
        nm += 1;
    }
    lane.chain.publish(lane.instrument, lane.effects.items);
    // Lanes inside a rack get its first inserted machine's name.
    if (!with_inst) if (lane.effects.items.len > 0) {
        if (fx_lo < t.effects.items.len) if (t.effects.items[fx_lo].idx) |i| lane.setLabel(reg.entries[i].nameSlice());
    };

    // Install: the rack takes the run's place.
    if (with_inst) {
        try t.replaceMachine(alloc, m);
        installed = true;
        t.machine_idx = @intCast(rack_idx);
        moves[nm] = .{ .kind = .inst, .fx_uid = 0, .to_kind = .inst, .to_fx_uid = 0, .step = .{ .lane = lane.uid, .slot = 0 } };
        nm += 1;
        for (moves[0 .. nm - 1]) |*mv| mv.to_kind = .inst;
        var j = fx_hi;
        while (j > fx_lo) : (j -= 1) try t.removeEffect(alloc, j - 1);
    } else {
        var j = fx_hi;
        while (j > fx_lo) : (j -= 1) try t.removeEffect(alloc, j - 1);
        try t.addEffect(alloc, m, @intCast(rack_idx));
        installed = true;
        t.moveEffect(t.effects.items.len - 1, fx_lo);
        const uid = t.effects.items[fx_lo].uid;
        for (moves[0..nm]) |*mv| mv.to_fx_uid = uid;
    }
    retarget(t, alloc, moves[0..nm]);
    return out;
}

/// The rack at position `pos`, if it is one.
pub fn rackAt(t: *Track, pos: usize) ?*Rack {
    const m: *machine.Machine = if (pos == 0) &t.machine else if (pos - 1 < t.effects.items.len) &t.effects.items[pos - 1].mach else return null;
    if (m.child == null) return null;
    return @ptrCast(@alignCast(m.state));
}

/// Put the one lane of the rack at `pos` back on the track in its place.
pub fn ungroup(alloc: std.mem.Allocator, reg: *Registry, t: *Track, pos: usize) Error!void {
    const rk = rackAt(t, pos) orelse return error.NotARack;
    if (rk.count != 1 or rk.map_count != 0) return error.RackNotSimple;
    const lane = &rk.lanes[0];
    const lane_uid = lane.uid;
    const with_inst = pos == 0;
    const rack_fx_uid: u16 = if (with_inst) 0 else t.effects.items[pos - 1].uid;

    // New machines first: the rack stays until they are all made.
    var made: [rack_mod.MAX_LANE_EFFECTS]struct { mach: machine.Machine, idx: u8, bypass: bool, slot: u16 } = undefined;
    var n: usize = 0;
    errdefer for (made[0..n]) |x| if (x.mach.deinit) |d| d(x.mach.state, alloc);
    var inst: ?machine.Machine = null;
    errdefer if (inst) |im| if (im.deinit) |d| d(im.state, alloc);
    if (with_inst) {
        const ri = lane.reg_idx orelse return error.RackNotSimple;
        const im = try reg.instantiatePrepared(ri);
        im.reset(im.state);
        inst = im;
        try rk.copySettings(lane.instrument, im, ri);
    }
    for (lane.effects.items) |*fx| {
        const idx = fx.idx orelse continue;
        const fm = try reg.instantiatePrepared(idx);
        fm.reset(fm.state);
        made[n] = .{ .mach = fm, .idx = idx, .bypass = fx.bypass.load(.monotonic), .slot = fx.uid };
        n += 1;
        try rk.copySettings(fx.mach, fm, idx);
    }

    // Lanes: the rack's own (its macros) go; the lane's machines' come out.
    const rack_kind: automation.TargetKind = if (with_inst) .inst else .fx;
    dropRackLanes(t, alloc, rack_kind, rack_fx_uid);

    var at: usize = if (with_inst) 0 else pos - 1;
    var inst_ri: ?u8 = null;
    if (with_inst) {
        inst_ri = lane.reg_idx;
        const im = inst.?;
        inst = null;
        try t.replaceMachine(alloc, im);
        t.machine_idx = inst_ri;
        unpath(t, .inst, 0, lane_uid, 0, .inst, 0);
    } else {
        try t.removeEffect(alloc, pos - 1);
    }
    const count = n;
    n = 0;
    for (made[0..count]) |x| {
        try t.addEffect(alloc, x.mach, x.idx);
        t.moveEffect(t.effects.items.len - 1, at);
        const new_uid = t.effects.items[at].uid;
        if (x.bypass) {
            t.effects.items[at].bypass.store(true, .monotonic);
        }
        unpath(t, rack_kind, rack_fx_uid, lane_uid, x.slot, .fx, new_uid);
        at += 1;
    }
    if (count > 0) t.chain.publish(t.machine, t.effects.items);
}

/// Drop lanes that drive the rack's own controls (no path under it).
fn dropRackLanes(t: *Track, alloc: std.mem.Allocator, kind: automation.TargetKind, fx_uid: u16) void {
    dropRackLanesIn(&t.lanes, alloc, kind, fx_uid);
    for (t.clips.items) |*clip| dropRackLanesIn(&clip.lanes, alloc, kind, fx_uid);
}

fn dropRackLanesIn(lanes: *std.ArrayList(automation.Lane), alloc: std.mem.Allocator, kind: automation.TargetKind, fx_uid: u16) void {
    var i: usize = 0;
    while (i < lanes.items.len) {
        const tg = lanes.items[i].target;
        if (tg.kind == kind and (kind != .fx or tg.fx_uid == fx_uid) and tg.path.len == 0) {
            lanes.items[i].deinit(alloc);
            _ = lanes.orderedRemove(i);
        } else i += 1;
    }
}

/// Lanes under the rack (kind, fx_uid) whose first step is (lane, slot)
/// now name (to_kind, to_fx_uid), one step shorter.
fn unpath(t: *Track, kind: automation.TargetKind, fx_uid: u16, lane: u8, slot: u16, to_kind: automation.TargetKind, to_fx_uid: u16) void {
    unpathIn(t.lanes.items, kind, fx_uid, lane, slot, to_kind, to_fx_uid);
    for (t.clips.items) |*clip| unpathIn(clip.lanes.items, kind, fx_uid, lane, slot, to_kind, to_fx_uid);
}

fn unpathIn(lanes: []automation.Lane, kind: automation.TargetKind, fx_uid: u16, lane: u8, slot: u16, to_kind: automation.TargetKind, to_fx_uid: u16) void {
    for (lanes) |*l| {
        const tg = &l.target;
        if (tg.kind != kind or (kind == .fx and tg.fx_uid != fx_uid) or tg.path.len == 0) continue;
        const s0 = tg.path.steps[0];
        if (s0.lane != lane or s0.slot != slot) continue;
        var path = automation.Path{};
        for (tg.path.slice()[1..]) |s| path = path.plus(s);
        tg.kind = to_kind;
        tg.fx_uid = to_fx_uid;
        tg.path = path;
    }
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn testRender(_: *anyopaque, _: *const machine.MachineCtx, l: []f32, r: []f32) void {
    @memset(l, 0);
    @memset(r, 0);
}
fn testReset(_: *anyopaque) void {}
fn testDraw(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
var test_state: u8 = 0;
const silent = machine.Machine{ .name = "none", .state = &test_state, .render = testRender, .reset = testReset, .draw_panel = testDraw };

fn paramsOf(alloc: std.mem.Allocator, m: machine.Machine) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try m.write_params_json.?(m.state, &out, alloc);
    return out.toOwnedSlice(alloc);
}

test "group: an instrument and its first insert go into a rack lane with their settings and automation, and come back" {
    const alloc = testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();
    try reg.loadFyMachine("machines/ms20/ms20.fy");
    try reg.loadFyMachine("machines/sat2/sat2.fy");
    try reg.loadFyMachine("machines/delay2/delay2.fy");
    try reg.loadNative();

    const ms20 = reg.findById("ms20").?;
    const inst = try reg.instantiatePrepared(ms20);
    inst.reset(inst.state);
    var t = try Track.init(alloc, "Lead", .{ .r = 1, .g = 2, .b = 3, .a = 255 }, inst);
    defer t.deinit(alloc);
    t.machine_idx = @intCast(ms20);
    for ([_][]const u8{ "sat2", "delay2" }) |id| {
        const idx = reg.findById(id).?;
        const fx = try reg.instantiatePrepared(idx);
        fx.reset(fx.state);
        try t.addEffect(alloc, fx, @intCast(idx));
    }
    // Settings off their defaults, to see them carried.
    inst.set_param.?(inst.state, "cutoff", 900);
    const sat = &t.effects.items[0];
    sat.mach.set_param.?(sat.mach.state, "sat-drive", 21);
    sat.bypass.store(true, .monotonic);
    const inst_params = try paramsOf(alloc, inst);
    defer alloc.free(inst_params);
    const sat_params = try paramsOf(alloc, sat.mach);
    defer alloc.free(sat_params);
    const delay_uid = t.effects.items[1].uid;

    const cut = try t.laneFor(alloc, automation.Target.control(.inst, 0, "cutoff"), false);
    _ = try cut.insert(alloc, .{ .beat = 0, .value = 0.3 });
    const drv = try t.laneFor(alloc, automation.Target.control(.fx, sat.uid, "sat-drive"), false);
    _ = try drv.insert(alloc, .{ .beat = 0, .value = 0.6 });
    const dly = try t.laneFor(alloc, automation.Target.control(.fx, delay_uid, "delay-mix"), false);
    _ = try dly.insert(alloc, .{ .beat = 0, .value = 0.2 });

    _ = try group(alloc, &reg, &t, 0, 1);
    try testing.expectEqual(reg.findById("rack").?, t.machine_idx.?);
    try testing.expectEqual(@as(usize, 1), t.effects.items.len);
    try testing.expectEqual(delay_uid, t.effects.items[0].uid);
    const rk = rackAt(&t, 0).?;
    try testing.expectEqual(@as(usize, 1), rk.count);
    const lane = &rk.lanes[0];
    try testing.expectEqual(@as(usize, 1), lane.effects.items.len);
    const got_inst = try paramsOf(alloc, lane.instrument);
    defer alloc.free(got_inst);
    try testing.expectEqualStrings(inst_params, got_inst);
    const got_sat = try paramsOf(alloc, lane.effects.items[0].mach);
    defer alloc.free(got_sat);
    try testing.expectEqualStrings(sat_params, got_sat);
    try testing.expect(lane.effects.items[0].bypass.load(.monotonic));
    // The lanes went down the rack; the delay's stayed.
    const c0 = t.lanes.items[0].target;
    try testing.expectEqual(automation.TargetKind.inst, c0.kind);
    try testing.expectEqual(@as(u8, 1), c0.path.len);
    try testing.expectEqual(@as(u16, 0), c0.path.steps[0].slot);
    try testing.expectEqual(lane.instrument.state, t.targetMachine(c0).?.state);
    const d0 = t.lanes.items[1].target;
    try testing.expectEqual(automation.TargetKind.inst, d0.kind);
    try testing.expectEqual(lane.effects.items[0].mach.state, t.targetMachine(d0).?.state);
    try testing.expectEqual(automation.TargetKind.fx, t.lanes.items[2].target.kind);
    try testing.expectEqual(@as(u8, 0), t.lanes.items[2].target.path.len);

    // A lane on the rack's own macro goes away with it.
    _ = try (try t.laneFor(alloc, automation.Target.control(.inst, 0, "rk-m1"), false)).insert(alloc, .{ .beat = 0, .value = 1 });
    try ungroup(alloc, &reg, &t, 0);
    try testing.expectEqual(ms20, t.machine_idx.?);
    try testing.expectEqual(@as(usize, 2), t.effects.items.len);
    const back_inst = try paramsOf(alloc, t.machine);
    defer alloc.free(back_inst);
    try testing.expectEqualStrings(inst_params, back_inst);
    try testing.expect(t.effects.items[0].bypass.load(.monotonic));
    try testing.expectEqual(@as(usize, 3), t.lanes.items.len);
    for (t.lanes.items) |*l| {
        try testing.expectEqual(@as(u8, 0), l.target.path.len);
        try testing.expect(t.targetMachine(l.target) != null);
    }
    try testing.expectEqual(t.effects.items[0].uid, t.lanes.items[1].target.fx_uid);
}

test "group: a run of effects becomes an FX Rack in its place" {
    const alloc = testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();
    try reg.loadFyMachine("machines/sat2/sat2.fy");
    try reg.loadFyMachine("machines/delay2/delay2.fy");
    try reg.loadNative();
    var t = try Track.init(alloc, "Bus", .{ .r = 1, .g = 2, .b = 3, .a = 255 }, silent);
    defer t.deinit(alloc);
    for ([_][]const u8{ "delay2", "sat2", "sat2", "delay2" }) |id| {
        const idx = reg.findById(id).?;
        const fx = try reg.instantiatePrepared(idx);
        fx.reset(fx.state);
        try t.addEffect(alloc, fx, @intCast(idx));
    }
    const mid = t.effects.items[2].uid;
    _ = try (try t.laneFor(alloc, automation.Target.control(.fx, mid, "sat-drive"), false)).insert(alloc, .{ .beat = 0, .value = 0.5 });
    _ = try group(alloc, &reg, &t, 2, 3);
    try testing.expectEqual(@as(usize, 3), t.effects.items.len);
    try testing.expectEqual(reg.findById("fxrack").?, t.effects.items[1].idx.?);
    const rk = rackAt(&t, 2).?;
    try testing.expectEqual(@as(usize, 2), rk.lanes[0].effects.items.len);
    const tg = t.lanes.items[0].target;
    try testing.expectEqual(t.effects.items[1].uid, tg.fx_uid);
    try testing.expectEqual(rk.lanes[0].effects.items[1].mach.state, t.targetMachine(tg).?.state);

    try ungroup(alloc, &reg, &t, 2);
    try testing.expectEqual(@as(usize, 4), t.effects.items.len);
    const back = t.lanes.items[0].target;
    try testing.expectEqual(@as(u8, 0), back.path.len);
    try testing.expectEqual(t.effects.items[2].uid, back.fx_uid);
}
