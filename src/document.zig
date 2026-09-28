//! Project save/load.
//!
//! The format is deliberately line-oriented text while the document
//! model is still changing.  It is also the undo snapshot format.

const std = @import("std");
const c = @import("c.zig");
const track_mod = @import("track.zig");
const routing = @import("routing.zig");
const clip_mod = @import("clip.zig");
const registry_mod = @import("machine_registry.zig");
const transport_mod = @import("transport.zig");
const machine_mod = @import("machine.zig");
const audio_pool_mod = @import("audio_pool.zig");
const meter_mod = @import("meter.zig");
const automation = @import("automation.zig");

extern fn close(fd: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn fstat(fd: c_int, sb: *std.c.Stat) c_int;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

pub const SAVE_PATH = "slab-project.slab";

/// The process-wide audio pool, registered once at startup. serialize()
/// resolves an audio clip's source index → file path through it; apply()
/// resolves a saved path → pool index (loading on demand). It is a host
/// singleton (one per process), so it is registered here rather than
/// threaded through every serialize/apply call site. Tests set it directly.
var active_pool: ?*audio_pool_mod.AudioPool = null;

pub fn setPool(pool: *audio_pool_mod.AudioPool) void {
    active_pool = pool;
}

pub fn activePool() ?*audio_pool_mod.AudioPool {
    return active_pool;
}

/// Process-wide registry, registered once at startup (like `active_pool`).
/// serialize() maps a track's machine index → stable machine id through it.
/// Threading it through every serialize call site (undo snapshots fire from
/// many edit handlers) would be noise, so it's a host singleton.
var active_reg: ?*const registry_mod.Registry = null;

pub fn setRegistry(reg: *const registry_mod.Registry) void {
    active_reg = reg;
}

/// Process-wide master bus, registered once at startup. It lives outside the
/// audio-track array, so (like the pool/registry) it's a host singleton that
/// serialize/apply read rather than a threaded parameter.
var active_master: ?*track_mod.Track = null;

pub fn setMaster(m: *track_mod.Track) void {
    active_master = m;
}

/// Process-wide meter store, registered once at startup (like the master
/// bus). serialize()/apply() read and repopulate it rather than threading
/// it through every call site. See docs/07 §meter-map.
var active_meter: ?*meter_mod.MeterState = null;

pub fn setMeterState(m: *meter_mod.MeterState) void {
    active_meter = m;
}

fn machineId(idx: u8) []const u8 {
    const reg = active_reg orelse return "";
    if (idx >= reg.count) return "";
    return reg.entries[idx].idSlice();
}

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_RDONLY);
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);

    var st: std.c.Stat = undefined;
    if (fstat(fd, &st) != 0) return error.StatFailed;
    const sz: usize = @intCast(st.size);
    const buf = try alloc.alloc(u8, sz);
    errdefer alloc.free(buf);

    var done: usize = 0;
    while (done < sz) {
        const n = std.posix.read(@intCast(fd), buf[done..]) catch return error.ReadFailed;
        if (n == 0) break;
        done += n;
    }
    if (done != sz) return error.ReadFailed;
    return buf;
}

pub fn writeFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);

    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data[done..].ptr, data.len - done);
        if (n <= 0) return error.WriteFailed;
        done += @intCast(n);
    }
}

/// Serialize the document (and undo snapshots) to JSON. Machine indices map
/// to stable machine ids via the registered registry (`setRegistry`) so
/// projects survive registry reordering; settings embed inline via
/// `write_params_json`.
pub fn serialize(
    alloc: std.mem.Allocator,
    tracks: []const track_mod.Track,
    transport: *const transport_mod.Transport,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"schema\":1,\"transport\":{\"bpm\":");
    try appendFmt(alloc, &out, "{d}", .{transport.bpm()});
    try appendFmt(alloc, &out, ",\"loop\":{{\"on\":{s},\"start\":{d},\"end\":{d}}}}}", .{
        boolStr(transport.loopEnabled()), transport.loopStartBeats(), transport.loopEndBeats(),
    });

    // Meter map (docs/07 §meter-map). Groups are not serialized yet —
    // they arrive with the generator slice.
    if (active_meter) |st| {
        try out.appendSlice(alloc, ",\"meter\":[");
        for (st.liveMap().points, 0..) |p, i| {
            if (i > 0) try out.append(alloc, ',');
            try appendFmt(alloc, &out, "{{\"bar\":{d},\"num\":{d},\"den\":{d}}}", .{
                p.start_bar, p.numerator, p.denominator,
            });
        }
        try out.append(alloc, ']');
    }

    try out.appendSlice(alloc, ",\"tracks\":[");
    for (tracks, 0..) |*t, ti| {
        if (ti > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"name\":");
        try appendJsonString(alloc, &out, t.name());
        try appendFmt(alloc, &out, ",\"color\":[{d},{d},{d}]", .{ t.color.r, t.color.g, t.color.b });
        try appendFmt(alloc, &out, ",\"volume\":{d},\"pan\":{d},\"mute\":{s},\"solo\":{s}", .{
            t.volume(), t.pan(), boolStr(t.mute.load(.monotonic)), boolStr(t.solo.load(.monotonic)),
        });
        try appendRouting(alloc, &out, t);

        // Instrument: stable id + inline settings, or null.
        try out.appendSlice(alloc, ",\"instrument\":");
        if (t.machine_idx) |idx| {
            try out.appendSlice(alloc, "{\"machine\":");
            try appendJsonString(alloc, &out, machineId(idx));
            try out.appendSlice(alloc, ",\"params\":");
            try appendParams(alloc, &out, t.machine);
            try appendAssets(alloc, &out, t.machine);
            try appendZones(alloc, &out, t.machine);
            if (t.machine.write_state_json) |f| {
                try out.appendSlice(alloc, ",\"state\":");
                try f(t.machine.state, &out, alloc);
            }
            try out.append(alloc, '}');
        } else try out.appendSlice(alloc, "null");

        // Effect chain.
        try out.appendSlice(alloc, ",\"effects\":");
        try appendEffects(alloc, &out, t);

        // Automation lanes (docs/22 §Project format).
        try appendLanes(alloc, &out, t);
        if (t.lanes_shown) try out.appendSlice(alloc, ",\"show_automation\":true");
        if (t.folded and t.isBus()) try out.appendSlice(alloc, ",\"folded\":true");

        // Clips.
        try out.appendSlice(alloc, ",\"clips\":[");
        for (t.clips.items, 0..) |*clip, ci| {
            if (ci > 0) try out.append(alloc, ',');
            if (clip.isAudio()) {
                const src_path = if (active_pool) |p|
                    (if (p.get(clip.audio.source)) |s| s.path() else "")
                else
                    "";
                try out.appendSlice(alloc, "{\"type\":\"audio\",\"name\":");
                try appendJsonString(alloc, &out, clip.name());
                try appendFmt(alloc, &out, ",\"start\":{d},\"len\":{d},\"gain\":{d},\"start_sec\":{d},\"dur_sec\":{d},\"fade_in\":{d},\"fade_out\":{d},", .{
                    clip.start_beat, clip.length_beats, clip.audio.gain,
                    clip.audio.start_sec, clip.audio.dur_sec, clip.audio.fade_in_sec, clip.audio.fade_out_sec,
                });
                if (clip.audio.reversed) try out.appendSlice(alloc, "\"reversed\":true,");
                try out.appendSlice(alloc, "\"source\":");
                try appendJsonString(alloc, &out, src_path);
                try out.append(alloc, '}');
                continue;
            }
            try out.appendSlice(alloc, "{\"type\":\"note\",\"name\":");
            try appendJsonString(alloc, &out, clip.name());
            try appendFmt(alloc, &out, ",\"start\":{d},\"len\":{d},\"notes\":[", .{ clip.start_beat, clip.length_beats });
            for (clip.notes.items, 0..) |note, ni| {
                if (ni > 0) try out.append(alloc, ',');
                try appendFmt(alloc, &out, "{{\"pitch\":{d},\"start\":{d},\"len\":{d},\"vel\":{d}", .{
                    note.pitch, note.start_beat, note.length_beats, note.velocity,
                });
                if (note.hasExpression()) {
                    try out.appendSlice(alloc, ",\"expr\":{");
                    var first_dim = true;
                    if (note.bend_n > 0) {
                        try out.appendSlice(alloc, "\"pitch\":");
                        try appendPoints(alloc, &out, note.bendPoints());
                        first_dim = false;
                    }
                    for (note.dims, 0..) |cv, d| {
                        if (cv.n == 0) continue;
                        if (!first_dim) try out.append(alloc, ',');
                        first_dim = false;
                        try appendFmt(alloc, &out, "\"{s}\":", .{@tagName(@as(clip_mod.ExprDim, @enumFromInt(d)))});
                        try appendPoints(alloc, &out, cv.points());
                    }
                    try out.append(alloc, '}');
                }
                try out.append(alloc, '}');
            }
            try out.append(alloc, ']');
            try appendLaneList(alloc, &out, t, clip.lanes.items);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]}");
    }
    try out.append(alloc, ']');

    // Master bus — volume + effect chain (no instrument, no clips).
    if (active_master) |m| {
        try appendFmt(alloc, &out, ",\"master\":{{\"volume\":{d},\"pan\":{d},\"effects\":", .{ m.volume(), m.pan() });
        try appendEffects(alloc, &out, m);
        try out.append(alloc, '}');
    }
    try out.append(alloc, '}');

    return try out.toOwnedSlice(alloc);
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

// `,"kind":"bus"`, `,"output":N`, `,"sends":[…]` (docs/23 §Project format),
// each only when it isn't the default.
fn appendRouting(alloc: std.mem.Allocator, out: *std.ArrayList(u8), t: *const track_mod.Track) !void {
    if (t.kind == .bus) try out.appendSlice(alloc, ",\"kind\":\"bus\"");
    if (t.output != routing.NONE) try appendFmt(alloc, out, ",\"output\":{d}", .{t.output});
    if (t.send_count == 0) return;
    try out.appendSlice(alloc, ",\"sends\":[");
    for (t.sends[0..t.send_count], 0..) |*snd, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendFmt(alloc, out, "{{\"to\":{d},\"level\":{d},\"pre\":{s}}}", .{ snd.bus, snd.level(), boolStr(snd.pre) });
    }
    try out.append(alloc, ']');
}

fn appendEffects(alloc: std.mem.Allocator, out: *std.ArrayList(u8), t: *const track_mod.Track) !void {
    try out.append(alloc, '[');
    for (t.effects.items, 0..) |*fx, ei| {
        if (ei > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"machine\":");
        try appendJsonString(alloc, out, if (fx.idx) |fi| machineId(fi) else "");
        try appendFmt(alloc, out, ",\"bypass\":{s},\"params\":", .{boolStr(t.effectBypassed(ei))});
        try appendParams(alloc, out, fx.mach);
        if (fx.key != routing.NONE) try appendFmt(alloc, out, ",\"key\":{d}", .{fx.key});
        try out.append(alloc, '}');
    }
    try out.append(alloc, ']');
}

/// A lane's target as the file names it: `volume`, `pan`, `inst:<id>`,
/// `fx<N>:<id>` (N = the effect's chain position now). Null when the
/// target no longer resolves.
fn laneTargetName(buf: []u8, t: *const track_mod.Track, target: automation.Target) ?[]const u8 {
    return switch (target.kind) {
        .volume => "volume",
        .pan => "pan",
        .inst => std.fmt.bufPrint(buf, "inst:{s}", .{target.param()}) catch null,
        .fx => blk: {
            for (t.effects.items, 0..) |*fx, i| {
                if (fx.uid == target.fx_uid) break :blk std.fmt.bufPrint(buf, "fx{d}:{s}", .{ i, target.param() }) catch null;
            }
            break :blk null;
        },
    };
}

/// Knob-space lane value → real units (fader gain, pan, control value).
fn laneValueOut(t: *const track_mod.Track, target: automation.Target, knob: f32) ?f64 {
    return switch (target.kind) {
        .volume => @as(f64, knob) * 1.25,
        .pan => @as(f64, knob) * 2 - 1,
        .inst, .fx => blk: {
            const m = t.targetMachine(target) orelse break :blk null;
            const i = m.controlIndex(target.param()) orelse break :blk null;
            const f = m.control_value orelse break :blk null;
            break :blk f(m.state, i, knob);
        },
    };
}

/// `,"automation":[…]` for `lanes` (a track's or a clip's), converting
/// values through the track's machines. Nothing when no lane is written.
fn appendLanes(alloc: std.mem.Allocator, out: *std.ArrayList(u8), t: *const track_mod.Track) !void {
    try appendLaneList(alloc, out, t, t.lanes.items);
}

fn appendLaneList(alloc: std.mem.Allocator, out: *std.ArrayList(u8), t: *const track_mod.Track, lanes: []const automation.Lane) !void {
    var first = true;
    for (lanes) |*lane| {
        if (lane.points.items.len == 0) continue;
        var nb: [64]u8 = undefined;
        const name = laneTargetName(&nb, t, lane.target) orelse continue;
        // Unconvertible (the control is gone): nothing honest to write.
        if (laneValueOut(t, lane.target, lane.points.items[0].value) == null) continue;
        try out.appendSlice(alloc, if (first) ",\"automation\":[" else ",");
        first = false;
        try out.appendSlice(alloc, "{\"target\":");
        try appendJsonString(alloc, out, name);
        try out.appendSlice(alloc, ",\"points\":[");
        for (lane.points.items, 0..) |pt, pi| {
            if (pi > 0) try out.append(alloc, ',');
            const v = laneValueOut(t, lane.target, pt.value).?;
            if (pt.shape == .linear and pt.tension == 0) {
                try appendFmt(alloc, out, "[{d},{d}]", .{ pt.beat, v });
            } else {
                try appendFmt(alloc, out, "[{d},{d},\"{s}\",{d}]", .{ pt.beat, v, @tagName(pt.shape), pt.tension });
            }
        }
        try out.appendSlice(alloc, "]}");
    }
    if (!first) try out.append(alloc, ']');
}

/// Parse a file target name into a Target on `t` (effects must already be
/// restored). Null for unknown forms or effect positions.
fn parseLaneTarget(t: *const track_mod.Track, name: []const u8) ?automation.Target {
    if (std.mem.eql(u8, name, "volume")) return automation.Target.volume();
    if (std.mem.eql(u8, name, "pan")) return automation.Target.pan();
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return null;
    const head = name[0..colon];
    const id = name[colon + 1 ..];
    if (std.mem.eql(u8, head, "inst")) return automation.Target.control(.inst, 0, id);
    if (head.len > 2 and std.mem.startsWith(u8, head, "fx")) {
        const n = std.fmt.parseInt(usize, head[2..], 10) catch return null;
        if (n >= t.effects.items.len) return null;
        return automation.Target.control(.fx, t.effects.items[n].uid, id);
    }
    return null;
}

fn applyLanes(alloc: std.mem.Allocator, t: *track_mod.Track, av: std.json.Value) !void {
    try applyLaneList(alloc, t, &t.lanes, av);
}

/// Parse lanes into `into` (a track's or a clip's list), converting values
/// through `t`'s machines.
fn applyLaneList(alloc: std.mem.Allocator, t: *track_mod.Track, into: *std.ArrayList(automation.Lane), av: std.json.Value) !void {
    if (av != .array) return;
    for (av.array.items) |lv| {
        if (lv != .object) continue;
        const name = strOf(objGet(lv.object, "target")) orelse continue;
        const target = parseLaneTarget(t, name) orelse continue;
        var dup = false;
        for (into.items) |*l| if (l.target.eql(target)) {
            dup = true;
        };
        if (dup) continue;
        // Machine lanes convert through the control; unknown ids drop.
        var ci: ?usize = null;
        var stepped = false;
        const mach = t.targetMachine(target);
        if (mach) |m| {
            ci = m.controlIndex(target.param()) orelse continue;
            if (m.control_knob == null) continue;
            if (m.control_info) |f| stepped = f(m.state, ci.?).stepped;
        } else if (target.kind == .inst or target.kind == .fx) continue;
        const pv = objGet(lv.object, "points") orelse continue;
        if (pv != .array) continue;
        var lane = automation.Lane{ .target = target, .stepped = stepped };
        errdefer lane.deinit(alloc);
        for (pv.array.items) |ptv| {
            if (ptv != .array or ptv.array.items.len < 2) continue;
            const a = ptv.array.items;
            const value = asF64(a[1]);
            const knob: f32 = switch (target.kind) {
                .volume => @floatCast(std.math.clamp(value / 1.25, 0, 1)),
                .pan => @floatCast(std.math.clamp((value + 1) / 2, 0, 1)),
                .inst, .fx => mach.?.control_knob.?(mach.?.state, ci.?, value),
            };
            var pt = automation.Point{ .beat = @max(0, asF64(a[0])), .value = knob };
            if (a.len >= 3) if (strOf(a[2])) |sh| {
                pt.shape = std.meta.stringToEnum(automation.Shape, sh) orelse .linear;
            };
            if (a.len >= 4) pt.tension = @floatCast(std.math.clamp(asF64(a[3]), -1, 1));
            _ = try lane.insert(alloc, pt);
        }
        if (lane.points.items.len == 0) {
            lane.deinit(alloc);
            continue;
        }
        try into.append(alloc, lane);
    }
}

/// A point list as the file writes it, values as they are (note
/// expression is already in its units: semitones).
fn appendPoints(alloc: std.mem.Allocator, out: *std.ArrayList(u8), pts: []const automation.Point) !void {
    try out.append(alloc, '[');
    for (pts, 0..) |pt, pi| {
        if (pi > 0) try out.append(alloc, ',');
        if (pt.shape == .linear and pt.tension == 0) {
            try appendFmt(alloc, out, "[{d},{d}]", .{ pt.beat, pt.value });
        } else {
            try appendFmt(alloc, out, "[{d},{d},\"{s}\",{d}]", .{ pt.beat, pt.value, @tagName(pt.shape), pt.tension });
        }
    }
    try out.append(alloc, ']');
}

/// One file point `[beat, value(, shape, tension)]`, value as written.
fn parsePoint(v: std.json.Value) ?automation.Point {
    if (v != .array or v.array.items.len < 2) return null;
    const a = v.array.items;
    var pt = automation.Point{ .beat = @max(0, asF64(a[0])), .value = @floatCast(asF64(a[1])) };
    if (a.len >= 3) if (strOf(a[2])) |sh| {
        pt.shape = std.meta.stringToEnum(automation.Shape, sh) orelse .linear;
    };
    if (a.len >= 4) pt.tension = @floatCast(std.math.clamp(asF64(a[3]), -1, 1));
    return pt;
}

fn appendParams(alloc: std.mem.Allocator, out: *std.ArrayList(u8), mach: machine_mod.Machine) !void {
    if (mach.write_params_json) |f| {
        try f(mach.state, out, alloc);
    } else try out.appendSlice(alloc, "{}");
}

pub fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch < 0x20) {
            var b: [8]u8 = undefined;
            try out.appendSlice(alloc, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{ch}) catch "");
        } else try out.append(alloc, ch),
    };
    try out.append(alloc, '"');
}

pub fn apply(
    alloc: std.mem.Allocator,
    data: []const u8,
    reg: *registry_mod.Registry,
    tracks_buf: []track_mod.Track,
    track_count: *usize,
    transport: *transport_mod.Transport,
    silent_machine: machine_mod.Machine,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return error.InvalidProject;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProject;
    const root = parsed.value.object;

    if (objGet(root, "transport")) |tv| if (tv == .object) {
        const to = tv.object;
        if (objGet(to, "bpm")) |b| transport.setBpm(@floatCast(asF64(b)));
        if (objGet(to, "loop")) |lv| if (lv == .object) {
            const lo = lv.object;
            const st = if (objGet(lo, "start")) |x| asF64(x) else 0;
            const en = if (objGet(lo, "end")) |x| asF64(x) else 0;
            transport.setLoopBeats(st, en);
            transport.setLoopEnabled(if (objGet(lo, "on")) |x| asBool(x) else false);
        };
    };

    // Meter map: repopulate the store, or fall back to 4/4 for projects
    // saved before meter support. First point is forced to start_bar 0.
    if (active_meter) |st| {
        const ms = st.liveStore();
        ms.clear();
        if (objGet(root, "meter")) |mv| if (mv == .array) {
            for (mv.array.items) |pv| {
                if (pv != .object) continue;
                const po = pv.object;
                ms.append(.{
                    .start_bar = if (ms.len == 0) 0 else @intFromFloat(asF64(objGet(po, "bar") orelse continue)),
                    .numerator = @intFromFloat(asF64(objGet(po, "num") orelse continue)),
                    .denominator = @intFromFloat(asF64(objGet(po, "den") orelse continue)),
                });
            }
        };
        if (ms.len == 0) ms.reset();
        st.commitImmediate();
    }

    for (tracks_buf[0..track_count.*]) |*t| t.deinit(alloc);
    track_count.* = 0;
    errdefer {
        for (tracks_buf[0..track_count.*]) |*t| t.deinit(alloc);
        track_count.* = 0;
    }

    const tracks_v = objGet(root, "tracks") orelse return;
    if (tracks_v != .array) return error.InvalidProject;
    if (tracks_v.array.items.len > tracks_buf.len) return error.TooManyTracks;

    for (tracks_v.array.items) |trk_v| {
        if (trk_v != .object) return error.InvalidProject;
        tracks_buf[track_count.*] = try parseTrack(alloc, reg, trk_v.object, silent_machine);
        track_count.* += 1;
    }
    sanitizeRouting(tracks_buf[0..track_count.*]);

    // Master bus — volume + effect chain into the registered master.
    if (active_master) |m| if (objGet(root, "master")) |mv| if (mv == .object) {
        const mo = mv.object;
        if (objGet(mo, "volume")) |x| m.setVolume(@floatCast(asF64(x)));
        if (objGet(mo, "pan")) |x| m.setPan(@floatCast(asF64(x)));
        for (m.effects.items) |*fx| if (fx.mach.deinit) |d| d(fx.mach.state, alloc);
        m.effects.clearRetainingCapacity();
        if (objGet(mo, "effects")) |ev| try applyEffects(alloc, reg, m, ev);
    };
}

/// One track from its project object: machines instantiated, settings,
/// routing (unchecked: `sanitizeRouting` runs over the whole project),
/// automation and clips restored.
fn parseTrack(alloc: std.mem.Allocator, reg: *registry_mod.Registry, to: std.json.ObjectMap, silent_machine: machine_mod.Machine) !track_mod.Track {
    const name = strOf(objGet(to, "name")) orelse "";
    var color = c.rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (objGet(to, "color")) |cv| if (cv == .array and cv.array.items.len >= 3) {
        color.r = asU8(cv.array.items[0]);
        color.g = asU8(cv.array.items[1]);
        color.b = asU8(cv.array.items[2]);
    };
    const volume: f32 = @floatCast(if (objGet(to, "volume")) |x| asF64(x) else 0.8);
    const pan_v: f32 = @floatCast(if (objGet(to, "pan")) |x| asF64(x) else 0.0);
    const mute = if (objGet(to, "mute")) |x| asBool(x) else false;
    const solo = if (objGet(to, "solo")) |x| asBool(x) else false;

    // Instrument — resolve by stable id, instantiate, restore settings.
    var mach = silent_machine;
    var machine_idx: ?u8 = null;
    if (objGet(to, "instrument")) |iv| if (iv == .object) {
        if (strOf(objGet(iv.object, "machine"))) |mid| {
            if (reg.findById(mid)) |idx| {
                mach = try reg.instantiate(idx);
                machine_idx = @intCast(idx);
                if (objGet(iv.object, "params")) |pv| applyParams(mach, pv);
                if (objGet(iv.object, "assets")) |av| applyAssets(mach, av);
                if (objGet(iv.object, "zones")) |zv| if (mach.apply_zones_json) |f| f(mach.state, zv);
                if (objGet(iv.object, "state")) |sv| if (mach.apply_state_json) |f| f(mach.state, sv);
            }
        }
    };

    var t = try track_mod.Track.init(alloc, name, color, mach);
    errdefer t.deinit(alloc);
    t.machine_idx = machine_idx;
    t.setVolume(volume);
    t.setPan(pan_v);
    t.mute.store(mute, .monotonic);
    t.solo.store(solo, .monotonic);
    if (strOf(objGet(to, "kind"))) |k| if (std.mem.eql(u8, k, "bus")) {
        t.kind = .bus;
    };
    if (objGet(to, "output")) |x| t.output = asTrackRef(x);
    if (objGet(to, "sends")) |sv| if (sv == .array) for (sv.array.items) |snd| {
        if (snd != .object) continue;
        const bus = asTrackRef(objGet(snd.object, "to") orelse continue);
        const lvl: f32 = @floatCast(if (objGet(snd.object, "level")) |x| asF64(x) else 1.0);
        const pre = if (objGet(snd.object, "pre")) |x| asBool(x) else false;
        t.addSend(bus, pre, lvl) catch break;
    };

    // Effect chain — instantiate by id, restore params + bypass.
    if (objGet(to, "effects")) |ev| try applyEffects(alloc, reg, &t, ev);

    if (objGet(to, "automation")) |av| try applyLanes(alloc, &t, av);
    if (objGet(to, "show_automation")) |x| t.lanes_shown = asBool(x);

    // Clips.
    if (objGet(to, "clips")) |cv| if (cv == .array) {
        for (cv.array.items) |clv| {
            if (clv != .object) continue;
            try applyClip(alloc, &t, clv.object);
        }
    };
    if (objGet(to, "folded")) |x| t.folded = asBool(x);
    return t;
}

/// A copy of `tracks[ti]` with fresh machines, made by writing the
/// project out and reading that one track back. Its routing references
/// are the original's, unchecked.
pub fn cloneTrack(
    alloc: std.mem.Allocator,
    tracks: []track_mod.Track,
    ti: usize,
    transport: *const transport_mod.Transport,
    reg: *registry_mod.Registry,
    silent_machine: machine_mod.Machine,
) !track_mod.Track {
    const data = try serialize(alloc, tracks, transport);
    defer alloc.free(data);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return error.InvalidProject;
    defer parsed.deinit();
    const tracks_v = objGet(parsed.value.object, "tracks") orelse return error.InvalidProject;
    if (tracks_v != .array or ti >= tracks_v.array.items.len or tracks_v.array.items[ti] != .object) return error.InvalidProject;
    return parseTrack(alloc, reg, tracks_v.array.items[ti].object, silent_machine);
}

// Restore an effect chain (instantiate by id, restore params + bypass) onto a
// track. Shared by audio tracks and the master bus.
fn applyEffects(alloc: std.mem.Allocator, reg: *registry_mod.Registry, t: *track_mod.Track, ev: std.json.Value) !void {
    if (ev != .array) return;
    for (ev.array.items) |fxv| {
        if (fxv != .object) continue;
        const fo = fxv.object;
        const mid = strOf(objGet(fo, "machine")) orelse continue;
        const idx = reg.findById(mid) orelse continue;
        const fxmach = reg.instantiate(idx) catch continue;
        fxmach.reset(fxmach.state);
        try t.addEffect(alloc, fxmach, @intCast(idx));
        if (objGet(fo, "params")) |pv| applyParams(fxmach, pv);
        if (objGet(fo, "bypass")) |bv| if (asBool(bv)) t.toggleEffectBypass(t.effects.items.len - 1);
        if (objGet(fo, "key")) |kv| t.effects.items[t.effects.items.len - 1].key = asTrackRef(kv);
    }
}

/// A track index from the file, or routing.NONE when it isn't one.
fn asTrackRef(v: std.json.Value) u8 {
    const f = asF64(v);
    if (!(f >= 0 and f < routing.MAX_TRACKS)) return routing.NONE;
    return @intFromFloat(f);
}

/// Drop routing a file can't mean (docs/23 §Project format): outputs and
/// sends to anything but another bus, duplicate sends, keys from a missing
/// track or the track itself, and anything closing a cycle. Edges are added
/// back in track order, so the first of two conflicting ones wins.
fn sanitizeRouting(tracks: []track_mod.Track) void {
    var nodes: [routing.MAX_TRACKS]routing.Node = undefined;
    const n = tracks.len;
    for (tracks, 0..) |*t, i| nodes[i] = .{ .is_bus = t.isBus() };
    for (tracks, 0..) |*t, i| {
        const self_idx: u8 = @intCast(i);
        if (t.output != routing.NONE) {
            if (isBusRef(tracks, t.output, i) and !routing.Routing.build(nodes[0..n]).wouldCycle(self_idx, t.output)) {
                nodes[i].output = t.output;
            } else {
                std.log.warn("project: track {d} output {d} dropped", .{ i, t.output });
                t.output = routing.NONE;
            }
        }
        var k: usize = 0;
        while (k < t.send_count) {
            const bus = t.sends[k].bus;
            const dup = for (t.sends[0..k]) |s| {
                if (s.bus == bus) break true;
            } else false;
            if (!dup and isBusRef(tracks, bus, i) and !routing.Routing.build(nodes[0..n]).wouldCycle(self_idx, bus)) {
                nodes[i].sends[nodes[i].send_count] = .{ .bus = bus, .pre = t.sends[k].pre };
                nodes[i].send_count += 1;
                k += 1;
            } else {
                std.log.warn("project: track {d} send to {d} dropped", .{ i, bus });
                t.removeSend(k);
            }
        }
        for (t.effects.items) |*fx| {
            if (fx.key == routing.NONE) continue;
            if (fx.key < n and fx.key != i and nodes[i].key_count < routing.MAX_KEYS and
                !routing.Routing.build(nodes[0..n]).wouldCycle(fx.key, self_idx))
            {
                nodes[i].keys[nodes[i].key_count] = .{ .fx_uid = fx.uid, .src = fx.key };
                nodes[i].key_count += 1;
            } else {
                std.log.warn("project: track {d} key from {d} dropped", .{ i, fx.key });
                fx.key = routing.NONE;
            }
        }
    }
}

fn isBusRef(tracks: []const track_mod.Track, target: u8, self_idx: usize) bool {
    return target < tracks.len and target != self_idx and tracks[target].isBus();
}

// ── JSON value helpers ───────────────────────────────────────────────

fn objGet(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return obj.get(key);
}

fn asF64(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .bool => |b| if (b) 1 else 0,
        else => 0,
    };
}

fn asU8(v: std.json.Value) u8 {
    const f = asF64(v);
    if (f <= 0) return 0;
    if (f >= 255) return 255;
    return @intFromFloat(f);
}

fn asBool(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => false,
    };
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

// `,"assets":{...}` when the machine has loaded files (a sampler's keymap).
fn appendAssets(alloc: std.mem.Allocator, out: *std.ArrayList(u8), mach: machine_mod.Machine) !void {
    const f = mach.write_assets_json orelse return;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try f(mach.state, &body, alloc);
    if (body.items.len == 0) return;
    try out.appendSlice(alloc, ",\"assets\":");
    try out.appendSlice(alloc, body.items);
}

// `,"zones":{...}` when a sampler has per-zone edits.
fn appendZones(alloc: std.mem.Allocator, out: *std.ArrayList(u8), mach: machine_mod.Machine) !void {
    const f = mach.write_zones_json orelse return;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try f(mach.state, &body, alloc);
    if (body.items.len == 0) return;
    try out.appendSlice(alloc, ",\"zones\":");
    try out.appendSlice(alloc, body.items);
}

// A missing file keeps the machine's default, like a missing clip source.
fn applyAssets(mach: machine_mod.Machine, assets: std.json.Value) void {
    if (assets != .object) return;
    const load = mach.load_asset orelse return;
    var it = assets.object.iterator();
    while (it.next()) |kv| if (strOf(kv.value_ptr.*)) |path| {
        _ = load(mach.state, kv.key_ptr.*, path);
    };
}

fn applyParams(mach: machine_mod.Machine, params: std.json.Value) void {
    if (params != .object) return;
    const set = mach.set_param orelse return;
    var it = params.object.iterator();
    while (it.next()) |kv| set(mach.state, kv.key_ptr.*, asF64(kv.value_ptr.*));
}

fn applyClip(alloc: std.mem.Allocator, t: *track_mod.Track, co: std.json.ObjectMap) !void {
    const ctype = strOf(objGet(co, "type")) orelse "note";
    const name = strOf(objGet(co, "name")) orelse "";
    const start = if (objGet(co, "start")) |x| asF64(x) else 0;
    const len = if (objGet(co, "len")) |x| asF64(x) else 0;

    if (std.mem.eql(u8, ctype, "audio")) {
        const src_path = strOf(objGet(co, "source")) orelse "";
        // A missing/failed source still keeps the clip (plays silent) so the
        // document round-trips losslessly.
        const source: u32 = if (src_path.len > 0)
            (if (active_pool) |p| (p.loadFile(src_path) catch 0) else 0)
        else
            0;
        var aclip = clip_mod.Clip.initAudio(name, start, len, source);
        aclip.audio.gain = @floatCast(if (objGet(co, "gain")) |x| asF64(x) else 1.0);
        aclip.audio.start_sec = if (objGet(co, "start_sec")) |x| asF64(x) else 0;
        aclip.audio.dur_sec = if (objGet(co, "dur_sec")) |x| asF64(x) else 0;
        aclip.audio.fade_in_sec = if (objGet(co, "fade_in")) |x| asF64(x) else 0;
        aclip.audio.fade_out_sec = if (objGet(co, "fade_out")) |x| asF64(x) else 0;
        aclip.audio.reversed = if (objGet(co, "reversed")) |x| x == .bool and x.bool else false;
        try t.addClip(alloc, aclip);
        return;
    }

    var clip = clip_mod.Clip.init(name, start, len);
    errdefer clip.deinit(alloc);
    if (objGet(co, "notes")) |nv| if (nv == .array) {
        for (nv.array.items) |note_v| {
            if (note_v != .object) continue;
            const no = note_v.object;
            var note = clip_mod.Note{
                .pitch = asU8(objGet(no, "pitch") orelse continue),
                .start_beat = if (objGet(no, "start")) |x| asF64(x) else 0,
                .length_beats = if (objGet(no, "len")) |x| asF64(x) else 0,
                .velocity = asU8(objGet(no, "vel") orelse continue),
            };
            if (objGet(no, "expr")) |ev| if (ev == .object) {
                if (objGet(ev.object, "pitch")) |pv| if (pv == .array) {
                    for (pv.array.items) |ptv| {
                        const pt = parsePoint(ptv) orelse continue;
                        _ = note.addBend(pt);
                    }
                };
                inline for (std.meta.fields(clip_mod.ExprDim)) |fd| {
                    const d: clip_mod.ExprDim = @enumFromInt(fd.value);
                    const rg = clip_mod.dimRange(d);
                    if (objGet(ev.object, fd.name)) |pv| if (pv == .array) {
                        for (pv.array.items) |ptv| {
                            const pt = parsePoint(ptv) orelse continue;
                            _ = note.dim(d).add(pt, rg.lo, rg.hi);
                        }
                    };
                }
            };
            try clip.addNote(alloc, note);
        }
    };
    if (objGet(co, "automation")) |av| try applyLaneList(alloc, t, &clip.lanes, av);
    try t.addClip(alloc, clip);
}


fn appendFmt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

fn testRender(_: *anyopaque, _: *const machine_mod.MachineCtx, l: []f32, r: []f32) void {
    @memset(l, 0);
    @memset(r, 0);
}

fn testReset(_: *anyopaque) void {}
fn testDraw(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}

var test_machine_state: u8 = 0;
const test_machine = machine_mod.Machine{
    .name = "(test)",
    .state = &test_machine_state,
    .render = testRender,
    .draw_panel = testDraw,
    .reset = testReset,
};

test "project snapshot round-trips tracks clips notes and loop" {
    const alloc = std.testing.allocator;

    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;
    transport.setBpm(132.5);
    transport.setLoopBeats(1.0, 9.0);

    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "Track 1", .{ .r = 10, .g = 20, .b = 30, .a = 255 }, test_machine),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    tracks[0].setVolume(0.625);
    tracks[0].mute.store(true, .monotonic);
    var clip = clip_mod.Clip.init("Clip A", 2.0, 4.0);
    try clip.addNote(alloc, .{ .pitch = 64, .start_beat = 0.5, .length_beats = 1.25, .velocity = 91 });
    try tracks[0].addClip(alloc, clip);

    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    setPool(&pool);
    defer active_pool = null;

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);

    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    var loaded_transport: transport_mod.Transport = .{};
    loaded_transport.sample_rate = 48_000;
    var loaded_buf: [2]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    try apply(alloc, bytes, &reg, loaded_buf[0..], &loaded_count, &loaded_transport, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), loaded_count);
    try std.testing.expectEqualStrings("Track 1", loaded_buf[0].name());
    try std.testing.expectEqual(@as(u8, 10), loaded_buf[0].color.r);
    try std.testing.expectEqual(true, loaded_buf[0].mute.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.625), loaded_buf[0].volume(), 0.0001);
    try std.testing.expectEqual(@as(usize, 1), loaded_buf[0].clips.items.len);
    try std.testing.expectEqualStrings("Clip A", loaded_buf[0].clips.items[0].name());
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), loaded_buf[0].clips.items[0].start_beat, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), loaded_buf[0].clips.items[0].notes.items.len);
    try std.testing.expectEqual(@as(u8, 64), loaded_buf[0].clips.items[0].notes.items[0].pitch);
    try std.testing.expectEqual(@as(u8, 91), loaded_buf[0].clips.items[0].notes.items[0].velocity);
    try std.testing.expectEqual(true, loaded_transport.loopEnabled());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), loaded_transport.loopStartBeats(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), loaded_transport.loopEndBeats(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 132.5), loaded_transport.bpm(), 0.001);
}

test "JSON project round-trips a sampler's loaded keymap path" {
    const alloc = std.testing.allocator;
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    try reg.loadFyMachine("machines/sampler/sampler.fy");
    setRegistry(&reg);
    defer active_reg = null;
    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    setPool(&pool);
    defer active_pool = null;
    var master = try track_mod.Track.init(alloc, "Master", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, test_machine);
    master.kind = .master;
    defer master.deinit(alloc);
    setMaster(&master);
    defer active_master = null;
    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;

    const idx = reg.findById("sampler").?;
    const inst = try reg.instantiate(idx);
    // The bundled folder, loaded as a kit: a path other than the default.
    try std.testing.expect(inst.load_asset.?(inst.state, "smp", "machines/sampler/assets"));
    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "Kit", .{ .r = 1, .g = 2, .b = 3, .a = 255 }, inst),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    tracks[0].machine_idx = @intCast(idx);

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"assets\":{\"smp\":\"machines/sampler/assets\"}") != null);

    var loaded_buf: [1]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    var lt: transport_mod.Transport = .{};
    lt.sample_rate = 48_000;
    try apply(alloc, bytes, &reg, loaded_buf[0..], &loaded_count, &lt, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try loaded_buf[0].machine.write_assets_json.?(loaded_buf[0].machine.state, &got, alloc);
    try std.testing.expectEqualStrings("{\"smp\":\"machines/sampler/assets\"}", got.items);
}

test "JSON project round-trips instrument-by-id, settings, and effect chain" {
    const alloc = std.testing.allocator;
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    try reg.loadFyMachine("machines/ms20/ms20.fy");
    try reg.loadFyMachine("machines/delay2/delay2.fy");
    setRegistry(&reg);
    defer active_reg = null;
    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    setPool(&pool);
    defer active_pool = null;

    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;

    const ms20_idx = reg.findById("ms20").?;
    const inst = try reg.instantiate(ms20_idx);
    inst.set_param.?(inst.state, "cutoff", 250.0);
    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "Lead", .{ .r = 1, .g = 2, .b = 3, .a = 255 }, inst),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    tracks[0].machine_idx = @intCast(ms20_idx);
    const delay_idx = reg.findById("delay2").?;
    const fx = try reg.instantiate(delay_idx);
    fx.reset(fx.state);
    try tracks[0].addEffect(alloc, fx, @intCast(delay_idx));
    tracks[0].toggleEffectBypass(0); // bypassed

    // Capture the source instrument's settings for an exact comparison.
    var src_params: std.ArrayList(u8) = .empty;
    defer src_params.deinit(alloc);
    try inst.write_params_json.?(inst.state, &src_params, alloc);

    // Master bus — non-default volume + a bypassed effect.
    var master = try track_mod.Track.init(alloc, "Master", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, test_machine);
    master.kind = .master;
    defer master.deinit(alloc);
    setMaster(&master);
    defer active_master = null;
    master.setVolume(0.5);
    const mfx = try reg.instantiate(delay_idx);
    mfx.reset(mfx.state);
    try master.addEffect(alloc, mfx, @intCast(delay_idx));
    master.toggleEffectBypass(0);

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);

    var loaded_buf: [1]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    var lt: transport_mod.Transport = .{};
    lt.sample_rate = 48_000;
    try apply(alloc, bytes, &reg, loaded_buf[0..], &loaded_count, &lt, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), loaded_count);
    const lt0 = &loaded_buf[0];
    // Instrument resolved by stable id (not index).
    try std.testing.expectEqual(@as(?u8, @intCast(ms20_idx)), lt0.machine_idx);
    // Effect chain restored, with bypass.
    try std.testing.expectEqual(@as(usize, 1), lt0.effects.items.len);
    try std.testing.expect(lt0.effectBypassed(0));
    // Instrument settings round-tripped exactly (same dump on both sides).
    var ld_params: std.ArrayList(u8) = .empty;
    defer ld_params.deinit(alloc);
    try lt0.machine.write_params_json.?(lt0.machine.state, &ld_params, alloc);
    try std.testing.expectEqualStrings(src_params.items, ld_params.items);
    try std.testing.expect(std.mem.indexOf(u8, ld_params.items, "\"cutoff\":") != null);

    // Master bus restored in place (volume + bypassed effect).
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), master.volume(), 0.0001);
    try std.testing.expectEqual(@as(usize, 1), master.effects.items.len);
    try std.testing.expect(master.effectBypassed(0));
}

test "automation lanes round-trip in real units, effects by chain position" {
    const alloc = std.testing.allocator;
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    try reg.loadFyMachine("machines/ms20/ms20.fy");
    try reg.loadFyMachine("machines/delay2/delay2.fy");
    setRegistry(&reg);
    defer active_reg = null;
    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    setPool(&pool);
    defer active_pool = null;
    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;

    const ms20_idx = reg.findById("ms20").?;
    const inst = try reg.instantiate(ms20_idx);
    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "Lead", .{ .r = 1, .g = 2, .b = 3, .a = 255 }, inst),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    const t0 = &tracks[0];
    t0.machine_idx = @intCast(ms20_idx);
    const delay_idx = reg.findById("delay2").?;
    // Two effects so the lane's target isn't simply the first.
    for (0..2) |_| {
        const fx = try reg.instantiate(delay_idx);
        fx.reset(fx.state);
        try t0.addEffect(alloc, fx, @intCast(delay_idx));
    }
    const fx_mach = &t0.effects.items[1].mach;
    const fx_param = fx_mach.control_info.?(fx_mach.state, 0).id;

    const cut = try t0.laneFor(alloc, automation.Target.control(.inst, 0, "cutoff"), false);
    _ = try cut.insert(alloc, .{ .beat = 0, .value = 0.25 });
    _ = try cut.insert(alloc, .{ .beat = 16, .value = 0.75, .shape = .curve, .tension = 0.5 });
    _ = try cut.insert(alloc, .{ .beat = 32, .value = 0.5, .shape = .hold });
    const vol = try t0.laneFor(alloc, automation.Target.volume(), false);
    _ = try vol.insert(alloc, .{ .beat = 4, .value = 0.4 });
    const fxl = try t0.laneFor(alloc, automation.Target.control(.fx, t0.effects.items[1].uid, fx_param), false);
    _ = try fxl.insert(alloc, .{ .beat = 8, .value = 0.6 });
    // A clip lane, timed from its clip.
    var clip = clip_mod.Clip.init("A", 8, 8);
    _ = try (try clip.laneFor(alloc, automation.Target.control(.inst, 0, "cutoff"), false)).insert(alloc, .{ .beat = 2, .value = 0.3 });
    // A note with a pitch bend (semitones, beats from the note's start).
    var bent = clip_mod.Note{ .pitch = 60, .start_beat = 0, .length_beats = 4, .velocity = 90 };
    _ = bent.addBend(.{ .beat = 1, .value = 0 });
    _ = bent.addBend(.{ .beat = 3.5, .value = -7, .shape = .curve, .tension = -0.4 });
    _ = bent.dim(.gain).add(.{ .beat = 2, .value = -12 }, -48, 12);
    try clip.addNote(alloc, bent);
    try t0.addClip(alloc, clip);
    // Lanes aimed at nothing are dropped on save.
    const gone = try t0.laneFor(alloc, automation.Target.control(.inst, 0, "no-such-knob"), false);
    _ = try gone.insert(alloc, .{ .beat = 0, .value = 0.5 });
    t0.lanes_shown = true;

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"target\":\"fx1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"curve\",0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "no-such-knob") == null);

    var loaded_buf: [1]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    var lt: transport_mod.Transport = .{};
    lt.sample_rate = 48_000;
    try apply(alloc, bytes, &reg, loaded_buf[0..], &loaded_count, &lt, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);
    const l0 = &loaded_buf[0];
    try std.testing.expect(l0.lanes_shown);
    try std.testing.expectEqual(@as(usize, 3), l0.lanes.items.len);

    const lcut = l0.findLane(automation.Target.control(.inst, 0, "cutoff")).?;
    try std.testing.expectEqual(@as(usize, 3), lcut.points.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), lcut.points.items[1].value, 1e-5);
    try std.testing.expectEqual(automation.Shape.curve, lcut.points.items[1].shape);
    try std.testing.expectEqual(@as(f32, 0.5), lcut.points.items[1].tension);
    try std.testing.expectEqual(automation.Shape.hold, lcut.points.items[2].shape);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), l0.findLane(automation.Target.volume()).?.points.items[0].value, 1e-6);
    const lfx = l0.findLane(automation.Target.control(.fx, l0.effects.items[1].uid, fx_param)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), lfx.points.items[0].value, 1e-5);
    const lclip = l0.clips.items[0].findLane(automation.Target.control(.inst, 0, "cutoff")).?;
    try std.testing.expectEqual(@as(f64, 2), lclip.points.items[0].beat);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), lclip.points.items[0].value, 1e-5);
    const ln = l0.clips.items[0].notes.items[0];
    try std.testing.expectEqual(@as(u8, 2), ln.bend_n);
    try std.testing.expectEqual(@as(f32, -7), ln.bend[1].value);
    try std.testing.expectEqual(automation.Shape.curve, ln.bend[1].shape);
    try std.testing.expectEqual(@as(f32, -0.4), ln.bend[1].tension);
    try std.testing.expectEqual(@as(f32, -12), ln.dimConst(.gain).points()[0].value);
    try std.testing.expectEqual(@as(u8, 0), ln.dimConst(.pressure).n);
}

test "audio clips round-trip through the pool by path" {
    const alloc = std.testing.allocator;

    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;
    transport.setBpm(120);

    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "Audio", .{ .r = 1, .g = 2, .b = 3, .a = 255 }, test_machine),
    };
    defer for (&tracks) |*t| t.deinit(alloc);

    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    setPool(&pool);
    defer active_pool = null;
    const src = try pool.loadFile("machines/sampler/assets/default.wav");

    var aclip = clip_mod.Clip.initAudio("Loop", 3.0, 2.5, src);
    aclip.audio.gain = 0.5;
    aclip.audio.start_sec = 0.25;
    aclip.audio.dur_sec = 1.5;
    aclip.audio.fade_in_sec = 0.1;
    aclip.audio.fade_out_sec = 0.2;
    aclip.audio.reversed = true;
    try tracks[0].addClip(alloc, aclip);

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);

    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    var loaded_transport: transport_mod.Transport = .{};
    loaded_transport.sample_rate = 48_000;
    var loaded_buf: [2]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    try apply(alloc, bytes, &reg, loaded_buf[0..], &loaded_count, &loaded_transport, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);

    // Path-dedup means no second load happened.
    try std.testing.expectEqual(@as(usize, 1), pool.count());
    try std.testing.expectEqual(@as(usize, 1), loaded_buf[0].clips.items.len);
    const got = &loaded_buf[0].clips.items[0];
    try std.testing.expect(got.isAudio());
    try std.testing.expectEqualStrings("Loop", got.name());
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), got.start_beat, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), got.length_beats, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), got.audio.gain, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), got.audio.start_sec, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), got.audio.dur_sec, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), got.audio.fade_in_sec, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), got.audio.fade_out_sec, 1e-4);
    try std.testing.expect(got.audio.reversed);
    try std.testing.expectEqual(src, got.audio.source);
}

test "meter map round-trips through serialize/apply" {
    const alloc = std.testing.allocator;

    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;

    // Source state: 4/4 then 7/8 at bar 4.
    var src_state: meter_mod.MeterState = .{};
    {
        const ls = src_state.liveStore();
        ls.clear();
        ls.append(.{ .start_bar = 0, .numerator = 4, .denominator = 4 });
        ls.append(.{ .start_bar = 4, .numerator = 7, .denominator = 8 });
    }
    setMeterState(&src_state);
    defer active_meter = null;

    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    setPool(&pool);
    defer active_pool = null;

    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "T", .{ .r = 1, .g = 2, .b = 3, .a = 255 }, test_machine),
    };
    defer for (&tracks) |*t| t.deinit(alloc);

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);

    // Load into a fresh state.
    var dst_state: meter_mod.MeterState = .{};
    setMeterState(&dst_state);

    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    var lt: transport_mod.Transport = .{};
    lt.sample_rate = 48_000;
    var loaded_buf: [2]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    try apply(alloc, bytes, &reg, loaded_buf[0..], &loaded_count, &lt, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);

    // Adopted immediately on load — both the live and audio maps match.
    const pts = dst_state.map().points;
    try std.testing.expectEqual(@as(usize, 2), pts.len);
    try std.testing.expectEqual(@as(u32, 0), pts[0].start_bar);
    try std.testing.expectEqual(@as(u8, 4), pts[0].numerator);
    try std.testing.expectEqual(@as(u8, 4), pts[0].denominator);
    try std.testing.expectEqual(@as(u32, 4), pts[1].start_bar);
    try std.testing.expectEqual(@as(u8, 7), pts[1].numerator);
    try std.testing.expectEqual(@as(u8, 8), pts[1].denominator);
}

test "project without meter falls back to 4/4" {
    const alloc = std.testing.allocator;

    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    var lt: transport_mod.Transport = .{};
    lt.sample_rate = 48_000;

    var state: meter_mod.MeterState = .{};
    state.liveStore().clear(); // emptied — apply must restore 4/4 when JSON has no meter
    setMeterState(&state);
    defer active_meter = null;

    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    setPool(&pool);
    defer active_pool = null;

    const json = "{\"schema\":1,\"transport\":{\"bpm\":120},\"tracks\":[]}";
    var loaded_buf: [1]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    try apply(alloc, json, &reg, loaded_buf[0..], &loaded_count, &lt, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);

    const pts = state.map().points;
    try std.testing.expectEqual(@as(usize, 1), pts.len);
    try std.testing.expectEqual(@as(u8, 4), pts[0].numerator);
    try std.testing.expectEqual(@as(u8, 4), pts[0].denominator);
}

test "routing round-trips: buses, outputs, sends, keys" {
    const alloc = std.testing.allocator;
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    try reg.loadFyMachine("machines/comp2/comp2.fy");
    setRegistry(&reg);
    defer active_reg = null;
    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;
    const col = c.rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "kick", col, test_machine),
        try track_mod.Track.init(alloc, "bass", col, test_machine),
        try track_mod.Track.init(alloc, "drums", col, test_machine),
        try track_mod.Track.init(alloc, "verb", col, test_machine),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    tracks[2].kind = .bus;
    tracks[3].kind = .bus;
    tracks[0].output = 2;
    try tracks[0].addSend(3, true, 0.25);
    try tracks[2].addSend(3, false, 1.5);
    const comp_idx = reg.findById("comp2").?;
    const comp = try reg.instantiate(comp_idx);
    try tracks[1].addEffect(alloc, comp, @intCast(comp_idx));
    tracks[1].effects.items[0].key = 0;

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);
    var loaded: [4]track_mod.Track = undefined;
    var count: usize = 0;
    var lt: transport_mod.Transport = .{};
    try apply(alloc, bytes, &reg, loaded[0..], &count, &lt, test_machine);
    defer for (loaded[0..count]) |*t| t.deinit(alloc);

    try std.testing.expectEqual(track_mod.Kind.audio, loaded[0].kind);
    try std.testing.expectEqual(track_mod.Kind.bus, loaded[2].kind);
    try std.testing.expectEqual(@as(u8, 2), loaded[0].output);
    try std.testing.expectEqual(routing.NONE, loaded[1].output);
    try std.testing.expectEqual(@as(u8, 1), loaded[0].send_count);
    try std.testing.expectEqual(@as(u8, 3), loaded[0].sends[0].bus);
    try std.testing.expect(loaded[0].sends[0].pre);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), loaded[0].sends[0].level(), 1e-6);
    try std.testing.expect(!loaded[2].sends[0].pre);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), loaded[2].sends[0].level(), 1e-6);
    try std.testing.expectEqual(@as(u8, 0), loaded[1].effects.items[0].key);
}

test "routing a file can't mean is dropped on load" {
    const alloc = std.testing.allocator;
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    setRegistry(&reg);
    defer active_reg = null;
    // 0 sends to 1 (not a bus) and twice to 2; bus 2 → bus 3 → bus 2 loops.
    const json =
        \\{"schema":1,"tracks":[
        \\ {"name":"a","output":0,"sends":[{"to":1},{"to":2},{"to":2}]},
        \\ {"name":"b","output":9},
        \\ {"name":"g1","kind":"bus","output":3},
        \\ {"name":"g2","kind":"bus","output":2}]}
    ;
    var loaded: [4]track_mod.Track = undefined;
    var count: usize = 0;
    var lt: transport_mod.Transport = .{};
    try apply(alloc, json, &reg, loaded[0..], &count, &lt, test_machine);
    defer for (loaded[0..count]) |*t| t.deinit(alloc);
    try std.testing.expectEqual(routing.NONE, loaded[0].output); // itself, not a bus
    try std.testing.expectEqual(@as(u8, 1), loaded[0].send_count);
    try std.testing.expectEqual(@as(u8, 2), loaded[0].sends[0].bus);
    try std.testing.expectEqual(routing.NONE, loaded[1].output);
    try std.testing.expectEqual(@as(u8, 3), loaded[2].output); // first edge wins
    try std.testing.expectEqual(routing.NONE, loaded[3].output); // would close the loop
}
