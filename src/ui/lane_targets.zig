//! Automation lane targets for the working surfaces (docs/22): a lane's
//! legend, range and value formatting, and the target picker menu
//! (VOLUME, PAN, then machine ▸ module ▸ control) shared by the
//! arrangement's track lanes and the clip editor's envelope strip.

const std = @import("std");
const menu = @import("menu.zig");
const automation = @import("../automation.zig");
const track_mod = @import("../track.zig");
const machine_mod = @import("../machine.zig");

const Track = track_mod.Track;
const Rect = @import("core.zig").Rect;

pub const LaneFmt = struct {
    mach: ?*const machine_mod.Machine,
    ci: usize = 0,
    kind: automation.TargetKind,
};

pub fn formatLane(ctx: *const anyopaque, knob: f32, buf: []u8) []const u8 {
    const f: *const LaneFmt = @ptrCast(@alignCast(ctx));
    switch (f.kind) {
        .volume => {
            const g = knob * 1.25;
            if (g <= 1e-4) return "-INF DB";
            return std.fmt.bufPrint(buf, "{d:.1} DB", .{20 * std.math.log10(g)}) catch "?";
        },
        .pan => {
            const p = knob * 2 - 1;
            if (@abs(p) < 0.005) return "C";
            return std.fmt.bufPrint(buf, "{s} {d:.0}", .{ if (p < 0) "L" else "R", @abs(p) * 100 }) catch "?";
        },
        .inst, .fx => {
            const m = f.mach orelse return "?";
            const fc = m.format_control orelse return "?";
            return fc(m.state, f.ci, knob, buf);
        },
    }
}

/// A lane's legend, value range and formatter context.
pub const LaneInfo = struct {
    name: []const u8,
    lo: f32 = 0,
    hi: f32 = 1,
    fmt: LaneFmt,
};

pub fn laneInfo(buf: []u8, t: *const Track, lane: *const automation.Lane) LaneInfo {
    return switch (lane.target.kind) {
        .volume => .{ .name = "VOLUME", .fmt = .{ .mach = null, .kind = .volume } },
        .pan => .{ .name = "PAN", .fmt = .{ .mach = null, .kind = .pan } },
        .inst, .fx => blk: {
            const m = t.targetMachine(lane.target) orelse break :blk .{
                .name = std.fmt.bufPrint(buf, "{s} (GONE)", .{lane.target.param()}) catch "?",
                .fmt = .{ .mach = null, .kind = lane.target.kind },
            };
            const ci = m.controlIndex(lane.target.param()) orelse break :blk .{
                .name = std.fmt.bufPrint(buf, "{s} (GONE)", .{lane.target.param()}) catch "?",
                .fmt = .{ .mach = null, .kind = lane.target.kind },
            };
            const info = m.control_info.?(m.state, ci);
            const prefix: []const u8 = if (lane.target.kind == .fx) m.name else "";
            const name = std.fmt.bufPrint(buf, "{s}{s}{s} {s}", .{ prefix, if (prefix.len > 0) " " else "", info.module, info.label }) catch info.label;
            break :blk .{
                .name = name,
                .lo = if (info.stepped) info.lo else 0,
                .hi = if (info.stepped) @max(info.hi, info.lo + 1) else 1,
                .fmt = .{ .mach = m, .ci = ci, .kind = lane.target.kind },
            };
        },
    };
}


// ── Picker ───────────────────────────────────────────────────────────

pub const Pick = struct {
    target: automation.Target,
    stepped: bool,
};

pub const Picked = union(enum) {
    target: Pick,
    /// The optional "Remove lane" row.
    remove,
};

pub const TickOpts = struct {
    /// Lanes that already exist: their targets are marked with a dot.
    lanes: []const automation.Lane = &.{},
    /// Offer a "Remove lane" row at the top.
    remove: bool = false,
};

const T_REMOVE: u32 = 3;
const T_VOLUME: u32 = 1;
const T_PAN: u32 = 2;
const T_INST: u32 = 10;
const T_FX: u32 = 20; // + effect index
const T_MODULE: u32 = 1000; // + module index
const T_CONTROL: u32 = 100_000; // + control index

pub fn open(key: u64, r: Rect) void {
    menu.openBelow(key, r);
}

fn has(lanes: []const automation.Lane, target: automation.Target) bool {
    for (lanes) |*l| if (l.target.eql(target)) return true;
    return false;
}

/// "• label" for targets that already have a lane.
fn mark(buf: []u8, on: bool, label: []const u8) []const u8 {
    if (!on) return label;
    return std.fmt.bufPrint(buf, "\u{2022} {s}", .{label}) catch label;
}

/// Run the picker for track `t` this frame. Returns what was picked.
pub fn tick(key: u64, t: *Track, o: TickOpts) ?Picked {
    if (!menu.isOpen(key)) return null;
    var items: [26]menu.Item = undefined;
    var bufs: [26][48]u8 = undefined;
    var n: usize = 0;
    if (o.remove) {
        items[n] = .{ .label = "Remove lane", .id = T_REMOVE };
        n += 1;
        items[n] = .{ .separator = true };
        n += 1;
    }
    items[n] = .{ .label = mark(&bufs[n], has(o.lanes, automation.Target.volume()), "Volume"), .id = T_VOLUME };
    n += 1;
    items[n] = .{ .label = mark(&bufs[n], has(o.lanes, automation.Target.pan()), "Pan"), .id = T_PAN };
    n += 1;
    if (t.machine.controlCount() > 0) {
        items[n] = .{ .separator = true };
        n += 1;
        items[n] = .{ .label = t.machine.name, .id = T_INST, .submenu = true };
        n += 1;
    }
    for (t.effects.items, 0..) |*fx, i| {
        if (n >= items.len) break;
        if (fx.mach.controlCount() == 0) continue;
        items[n] = .{ .label = fx.mach.name, .id = T_FX + @as(u32, @intCast(i)), .submenu = true };
        n += 1;
    }
    if (menu.pick(key, items[0..n])) |id| switch (id) {
        T_REMOVE => return .remove,
        T_VOLUME => return .{ .target = .{ .target = automation.Target.volume(), .stepped = false } },
        T_PAN => return .{ .target = .{ .target = automation.Target.pan(), .stepped = false } },
        else => {},
    };
    // Machine ▸ module ▸ control.
    const mid = menu.subOpen(key, 0) orelse return null;
    const kind: automation.TargetKind = if (mid == T_INST) .inst else .fx;
    const fx_i: usize = if (mid >= T_FX and mid < T_MODULE) mid - T_FX else 0;
    const mm: *const machine_mod.Machine = if (kind == .inst) &t.machine else if (fx_i < t.effects.items.len) &t.effects.items[fx_i].mach else return null;
    const info_fn = mm.control_info orelse return null;
    const uid: u16 = if (kind == .fx) t.effects.items[fx_i].uid else 0;
    var mods: [40][]const u8 = undefined;
    var mod_n: usize = 0;
    for (0..mm.controlCount()) |ci| {
        const md = info_fn(mm.state, ci).module;
        var seen = false;
        for (mods[0..mod_n]) |x| if (std.mem.eql(u8, x, md)) {
            seen = true;
        };
        if (!seen and mod_n < mods.len) {
            mods[mod_n] = md;
            mod_n += 1;
        }
    }
    var mitems: [40]menu.Item = undefined;
    for (mods[0..mod_n], 0..) |md, i| mitems[i] = .{ .label = if (md.len > 0) md else "MAIN", .id = T_MODULE + @as(u32, @intCast(i)), .submenu = true };
    _ = menu.subPick(key, 1, mitems[0..mod_n]);
    const modid = menu.subOpen(key, 1) orelse return null;
    if (modid < T_MODULE or modid - T_MODULE >= mod_n) return null;
    const md = mods[modid - T_MODULE];
    var citems: [40]menu.Item = undefined;
    var cbufs: [40][48]u8 = undefined;
    var cn: usize = 0;
    for (0..mm.controlCount()) |ci| {
        const info = info_fn(mm.state, ci);
        if (!std.mem.eql(u8, info.module, md) or cn >= citems.len) continue;
        const on = has(o.lanes, automation.Target.control(kind, uid, info.id));
        citems[cn] = .{ .label = mark(&cbufs[cn], on, info.label), .id = T_CONTROL + @as(u32, @intCast(ci)) };
        cn += 1;
    }
    const cid = menu.subPick(key, 2, citems[0..cn]) orelse return null;
    const info = info_fn(mm.state, cid - T_CONTROL);
    return .{ .target = .{ .target = automation.Target.control(kind, uid, info.id), .stepped = info.stepped } };
}

/// Point `lane` at a new target; a stepped target turns its points into
/// integer holds.
pub fn retarget(lane: *automation.Lane, pick: Pick) void {
    lane.target = pick.target;
    lane.stepped = pick.stepped;
    if (pick.stepped) for (lane.points.items) |*pt| {
        pt.shape = .hold;
        pt.value = @round(pt.value);
    };
}
