//! Groove (docs/28 §Groove): notes stay where they were written and play
//! where the groove puts them. A groove is a short cycle of steps, each
//! with how far it moves (a fraction of a step), how its velocity scales
//! and how much seeded random timing it gets. Between steps the move is
//! interpolated, so the warp is monotonic: notes never swap places.
//!
//! A cycle is a fixed number of beats, or `.group`: the meter's groups
//! (7/8 as 2+2+3), each played with the groove's cell for a group of two
//! units or of three (a four is two twos).
//!
//! Applied where a track publishes its notes to the audio thread
//! (Track.publishSnapshot), so playback, export and bounce hear the same
//! thing and the audio thread does nothing new. UI-thread data.

const std = @import("std");
const meter_mod = @import("meter.zig");
const tempo_mod = @import("tempo.zig");
const markers_mod = @import("markers.zig");
const Text = @import("export_settings.zig").Text;

pub const Name = Text(32);
pub const MAX_STEPS: usize = 32;
/// The pool: the built-ins, then the project's own.
pub const MAX_GROOVES: usize = 48;
/// A track's or a section's pick, before the pool's indexes: follow the
/// song (a track) or the section before (a section), or play straight.
pub const PICK_FOLLOW: u8 = 0;
pub const PICK_NONE: u8 = 1;
pub const PICK_POOL: u8 = 2;
/// The most a note can move, beats: how far the engine looks past a
/// clip's edges for one (a step's half plus SHIFT).
pub const MAX_MOVE_BEATS: f64 = 2;

pub const Cell = struct {
    steps: u8 = 2,
    /// Fraction of a step, −0.5..+0.5.
    shift: [MAX_STEPS]f32 = @splat(0),
    /// Velocity scale, 0..2.
    vel: [MAX_STEPS]f32 = @splat(1),
    /// ± fraction of a step of random timing.
    rand: [MAX_STEPS]f32 = @splat(0),
};

pub const Groove = struct {
    name: Name = .{},
    /// Beats per cycle; 0: the meter's groups, `sub` steps per unit.
    cycle: f32 = 0.5,
    sub: u8 = 1,
    /// [0] the cycle (or a group of two units); [1] a group of three.
    cells: [2]Cell = .{ .{}, .{} },

    pub fn isGroup(g: *const Groove) bool {
        return g.cycle <= 0;
    }
};

/// MPC-style swing: `pct` 50 (straight) to 75 on `step` beats (0.25 is
/// 1/16): the off-step lands at pct of the pair.
pub fn swing(name: []const u8, pct: f32, step: f32) Groove {
    var g = Groove{ .name = Name.init(name), .cycle = step * 2 };
    g.cells[0].steps = 2;
    g.cells[0].shift[1] = pct / 50 - 1;
    return g;
}

fn cell(steps: u8, shift: []const f32, vel: []const f32, rand: []const f32) Cell {
    var c = Cell{ .steps = steps };
    @memcpy(c.shift[0..shift.len], shift);
    @memcpy(c.vel[0..vel.len], vel);
    @memcpy(c.rand[0..rand.len], rand);
    return c;
}

pub const BUILTIN = blk: {
    const b = [_]Groove{
        swing("MPC 54 1/16", 54, 0.25),
        swing("MPC 58 1/16", 58, 0.25),
        swing("MPC 62 1/16", 62, 0.25),
        swing("MPC 66 1/16", 66, 0.25),
        swing("MPC 71 1/16", 71, 0.25),
        swing("MPC 58 1/8", 58, 0.5),
        swing("MPC 66 1/8", 66, 0.5),
        swing("TRIPLET 1/8", 200.0 / 3.0, 0.5),
        swing("TRIPLET 1/16", 200.0 / 3.0, 0.25),
        // Sixteenths, the second and fourth late, the fourth leaning in.
        .{ .name = Name.init("SAMBA 1/16"), .cycle = 1, .cells = .{ cell(4, &.{ 0, 0.12, 0.02, 0.1 }, &.{ 1, 0.75, 0.85, 1.1 }, &.{}), .{} } },
        // The backbeat a hair behind: 2 and 4 late, by a twentieth.
        .{ .name = Name.init("LAID BACK 2+4"), .cycle = 4, .cells = .{ cell(4, &.{ 0, 0.05, 0, 0.05 }, &.{}, &.{}), .{} } },
        // Played, not programmed: a little random on every sixteenth,
        // downbeats steadier.
        .{ .name = Name.init("LOOSE 1/16"), .cycle = 1, .cells = .{ cell(4, &.{}, &.{ 1, 0.9, 0.95, 0.9 }, &.{ 0.04, 0.08, 0.06, 0.08 }), .{} } },
        // Odd meters by their groups: each group's first unit leans in,
        // a three's last comes early (the aksak long-short).
        .{ .name = Name.init("AKSAK"), .cycle = 0, .sub = 1, .cells = .{
            cell(2, &.{ 0, 0 }, &.{ 1.15, 0.85 }, &.{}),
            cell(3, &.{ 0, 0, -0.08 }, &.{ 1.15, 0.8, 0.9 }, &.{}),
        } },
        // Sixteenths swung inside each group of eighths.
        .{ .name = Name.init("GROUP SWING 58"), .cycle = 0, .sub = 2, .cells = .{
            cell(4, &.{ 0, 0.16, 0, 0.16 }, &.{ 1.1, 0.85, 0.95, 0.85 }, &.{}),
            cell(6, &.{ 0, 0.16, 0, 0.16, 0, 0.16 }, &.{ 1.1, 0.85, 0.95, 0.85, 0.95, 0.85 }, &.{}),
        } },
    };
    break :blk b;
};

pub const Pool = struct {
    grooves: [MAX_GROOVES]Groove = undefined,
    count: usize = 0,

    pub fn init() Pool {
        var p = Pool{};
        p.reset();
        return p;
    }

    /// The built-ins only.
    pub fn reset(p: *Pool) void {
        for (BUILTIN, 0..) |g, i| p.grooves[i] = g;
        p.count = BUILTIN.len;
    }

    pub fn slice(p: *const Pool) []const Groove {
        return p.grooves[0..p.count];
    }

    pub fn isBuiltin(i: usize) bool {
        return i < BUILTIN.len;
    }

    pub fn find(p: *const Pool, name: []const u8) ?usize {
        for (p.slice(), 0..) |*g, i| if (std.ascii.eqlIgnoreCase(g.name.get(), name)) return i;
        return null;
    }

    /// Add (or replace one by its name, if it isn't a built-in). Null
    /// when full.
    pub fn put(p: *Pool, g: Groove) ?usize {
        if (p.find(g.name.get())) |i| {
            if (isBuiltin(i)) return i;
            p.grooves[i] = g;
            return i;
        }
        if (p.count >= MAX_GROOVES) return null;
        p.grooves[p.count] = g;
        p.count += 1;
        return p.count - 1;
    }

    /// A pick (FOLLOW, NONE, pool) by a groove's name; "" is FOLLOW.
    pub fn pickOf(p: *const Pool, name: []const u8) u8 {
        if (name.len == 0) return PICK_FOLLOW;
        if (std.ascii.eqlIgnoreCase(name, "NONE")) return PICK_NONE;
        return if (p.find(name)) |i| @intCast(PICK_POOL + i) else PICK_FOLLOW;
    }

    pub fn pickName(p: *const Pool, pick: u8) []const u8 {
        if (pick == PICK_FOLLOW) return "";
        if (pick == PICK_NONE) return "NONE";
        const i = pick - PICK_POOL;
        return if (i < p.count) p.grooves[i].name.get() else "";
    }
};

/// The song's groove settings and what playing one needs, set by main
/// (and by headless renders) and read where tracks publish their notes.
pub const Context = struct {
    pool: *Pool,
    /// The song's groove: NONE or a pool pick.
    song: u8 = PICK_NONE,
    /// Random timing's seed, saved with the project.
    seed: u64 = 0x5eed,
    markers: ?*const markers_mod.Markers = null,
    tempo: ?*const tempo_mod.TempoMap = null,
    meter: ?meter_mod.MeterMap = null,
};

pub var active: ?*Context = null;

/// A track's groove (docs/28 §Who uses which): which (FOLLOW the song and
/// its sections, NONE, or a pool groove), how much, and a push or drag.
pub const TrackGroove = struct {
    pick: u8 = PICK_FOLLOW,
    amount: f32 = 1,
    shift_ms: f32 = 0,

    pub fn isDefault(t: TrackGroove) bool {
        return t.pick == PICK_FOLLOW and t.amount == 1 and t.shift_ms == 0;
    }
};

/// The groove a track plays at `beat`: its own, or (FOLLOW) the groove of
/// the section there, of the sections before it, else the song's. Null:
/// straight.
pub fn resolve(cx: *const Context, tg: TrackGroove, beat: f64) ?*const Groove {
    var pick = tg.pick;
    if (pick == PICK_FOLLOW) {
        pick = cx.song;
        if (cx.markers) |mk| {
            var k = mk.section_n;
            while (k > 0) {
                k -= 1;
                const s = mk.sections[k];
                if (s.beat > beat + 1e-9) continue;
                if (s.groove != PICK_FOLLOW) {
                    pick = s.groove;
                    break;
                }
            }
        }
    }
    if (pick < PICK_POOL) return null;
    const i = pick - PICK_POOL;
    return if (i < cx.pool.count) &cx.pool.grooves[i] else null;
}

/// Where a cycle starts, how long it is, and its cell.
const Span = struct { start: f64, len: f64, cell: *const Cell };

fn spanAt(g: *const Groove, beat: f64, meter: ?meter_mod.MeterMap) Span {
    if (!g.isGroup() or meter == null) {
        const len: f64 = if (g.isGroup()) 2 else g.cycle;
        return .{ .start = @floor(beat / len) * len, .len = len, .cell = &g.cells[0] };
    }
    const mm = meter.?;
    const info = mm.barInfoAtBeat(beat);
    const seg = mm.segmentForBar(info.bar);
    const unit = seg.unitBeats();
    var buf: [meter_mod.MAX_GROUPS]u8 = undefined;
    const groups = seg.groupsInto(&buf);
    var at = info.bar_start_beat;
    var last = Span{ .start = at, .len = unit * 2, .cell = &g.cells[0] };
    for (groups) |gs| {
        // A group of four or more: twos, a three last when it's odd.
        var left: u8 = gs;
        while (left > 0) {
            const n: u8 = if (left == 3 or left == 1) left else 2;
            left -= n;
            const len = unit * @as(f64, @floatFromInt(n));
            last = .{ .start = at, .len = len, .cell = &g.cells[if (n == 3) 1 else 0] };
            if (beat < at + len) return last;
            at += len;
        }
    }
    return last;
}

/// Where a note written at `beat` plays, at `amount`.
pub fn warp(g: *const Groove, amount: f32, beat: f64, meter: ?meter_mod.MeterMap) f64 {
    const sp = spanAt(g, beat, meter);
    const c = sp.cell;
    const steps: f64 = @floatFromInt(@max(1, c.steps));
    const step = sp.len / steps;
    const pos = (beat - sp.start) / step;
    const k: usize = @intFromFloat(std.math.clamp(@floor(pos), 0, steps - 1));
    const frac = pos - @as(f64, @floatFromInt(k));
    const a: f64 = amount;
    const a0 = @as(f64, @floatFromInt(k)) + a * c.shift[k];
    const a1 = @as(f64, @floatFromInt(k + 1)) + a * (if (k + 1 < c.steps) c.shift[k + 1] else c.shift[0]);
    return sp.start + step * (a0 + frac * (a1 - a0));
}

/// The step anchors of the cycle holding `beat`, into `out` (a groove's
/// warp is linear between them), and where the next cycle starts.
pub fn anchorsAt(g: *const Groove, beat: f64, meter: ?meter_mod.MeterMap, out: []f64) struct { n: usize, next: f64 } {
    const sp = spanAt(g, beat, meter);
    const steps: usize = @max(1, sp.cell.steps);
    const step = sp.len / @as(f64, @floatFromInt(steps));
    const n = @min(steps, out.len);
    for (out[0..n], 0..) |*v, k| v.* = sp.start + step * @as(f64, @floatFromInt(k));
    return .{ .n = n, .next = sp.start + @max(sp.len, 1.0 / 64.0) };
}

/// Whether a track can play any groove: its own, or the song's or a
/// section's when it follows them.
pub fn anyFor(cx: *const Context, tg: TrackGroove) bool {
    if (tg.amount <= 0) return false;
    if (tg.pick == PICK_NONE) return false;
    if (tg.pick >= PICK_POOL) return true;
    if (cx.song >= PICK_POOL) return true;
    if (cx.markers) |mk| for (mk.sections[0..mk.section_n]) |s| if (s.groove >= PICK_POOL) return true;
    return false;
}

/// The nearest step to `beat`: its velocity scale and random spread
/// (beats), at `amount`.
pub fn stepAt(g: *const Groove, amount: f32, beat: f64, meter: ?meter_mod.MeterMap) struct { vel: f32, rand: f64 } {
    const sp = spanAt(g, beat, meter);
    const c = sp.cell;
    const steps: f64 = @floatFromInt(@max(1, c.steps));
    const step = sp.len / steps;
    const k: usize = @as(usize, @intFromFloat(@max(0, @round((beat - sp.start) / step)))) % @max(1, c.steps);
    return .{ .vel = 1 + (c.vel[k] - 1) * amount, .rand = c.rand[k] * step * amount };
}

/// −1..1 from a note's identity and the seed: the same every play.
pub fn noise(seed: u64, beat: f64, pitch: u8) f64 {
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&beat));
    h.update(&.{pitch});
    const x = h.final();
    return @as(f64, @floatFromInt(x >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53)) * 2 - 1;
}

pub const Played = struct { on: f64, off: f64, velocity: u8 };

/// A note written at `on`..`off` (song beats), as `tg` plays it.
pub fn play(cx: *const Context, tg: TrackGroove, on: f64, off: f64, pitch: u8, velocity: u8) Played {
    var out = Played{ .on = on, .off = off, .velocity = velocity };
    if (resolve(cx, tg, on)) |g| {
        const st = stepAt(g, tg.amount, on, cx.meter);
        const r = st.rand * noise(cx.seed, on, pitch);
        out.on = warp(g, tg.amount, on, cx.meter) + r;
        out.off = warp(g, tg.amount, off, cx.meter) + r;
        const v = @round(@as(f32, @floatFromInt(velocity)) * st.vel);
        out.velocity = @intFromFloat(std.math.clamp(v, 1, 127));
    }
    if (tg.shift_ms != 0) {
        const bpm = if (cx.tempo) |t| t.bpmAt(on) else 120;
        const d = @as(f64, tg.shift_ms) / 1000 * bpm / 60;
        out.on += d;
        out.off += d;
    }
    out.off = @max(out.off, out.on + 1.0 / 64.0);
    return out;
}

/// SHIFT in beats at `beat` (an audio clip moves by it).
pub fn shiftBeats(cx: *const Context, tg: TrackGroove, beat: f64) f64 {
    if (tg.shift_ms == 0) return 0;
    const bpm = if (cx.tempo) |t| t.bpmAt(beat) else 120;
    return @as(f64, tg.shift_ms) / 1000 * bpm / 60;
}

/// A groove taken from played notes (docs/28 §Editing): `starts` and
/// `velocities` in song beats, on a grid of `step` beats, a cycle of
/// `steps`. Each step's shift is the notes' average distance from it, and
/// its velocity their average over the whole average. Steps no note
/// played stay straight.
pub fn extract(name: []const u8, starts: []const f64, velocities: []const u8, step: f64, steps: u8) Groove {
    var g = Groove{ .name = Name.init(name), .cycle = @floatCast(step * @as(f64, @floatFromInt(steps))) };
    g.cells[0].steps = steps;
    var sum: [MAX_STEPS]f64 = @splat(0);
    var vel: [MAX_STEPS]f64 = @splat(0);
    var n: [MAX_STEPS]u32 = @splat(0);
    var all: f64 = 0;
    for (starts, velocities) |b, v| {
        const k_abs = @round(b / step);
        const off = (b - k_abs * step) / step;
        const k: usize = @as(usize, @intFromFloat(@mod(k_abs, @as(f64, @floatFromInt(steps)))));
        sum[k] += off;
        vel[k] += @floatFromInt(v);
        n[k] += 1;
        all += @floatFromInt(v);
    }
    const mean = if (starts.len > 0) all / @as(f64, @floatFromInt(starts.len)) else 1;
    for (0..steps) |k| if (n[k] > 0) {
        const cnt: f64 = @floatFromInt(n[k]);
        g.cells[0].shift[k] = @floatCast(std.math.clamp(sum[k] / cnt, -0.5, 0.5));
        g.cells[0].vel[k] = @floatCast(std.math.clamp(vel[k] / cnt / mean, 0, 2));
    };
    return g;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "MPC swing moves the off-sixteenth and nothing else" {
    const g = swing("t", 58, 0.25);
    try testing.expectApproxEqAbs(@as(f64, 0), warp(&g, 1, 0, null), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.29), warp(&g, 1, 0.25, null), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.5), warp(&g, 1, 0.5, null), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3.79), warp(&g, 1, 3.75, null), 1e-6);
    // Half the amount, half the swing; none, straight.
    try testing.expectApproxEqAbs(@as(f64, 0.27), warp(&g, 0.5, 0.25, null), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.25), warp(&g, 0, 0.25, null), 1e-12);
}

test "the warp is monotonic: notes never swap" {
    for (&BUILTIN) |*g| {
        var prev: f64 = -1;
        var b: f64 = 0;
        while (b < 8) : (b += 1.0 / 96.0) {
            const w = warp(g, 1, b, null);
            try testing.expect(w > prev);
            prev = w;
        }
    }
}

test "group grooves follow the meter's groups" {
    const pts = [_]meter_mod.MeterPoint{.{ .start_bar = 0, .numerator = 7, .denominator = 8, .groups = meter_mod.Groups.of(&.{ 2, 2, 3 }) }};
    const mm = meter_mod.MeterMap{ .points = &pts };
    const g = BUILTIN[12]; // AKSAK
    try testing.expectEqualStrings("AKSAK", g.name.get());
    // The 3-group starts at 2 beats (4 eighths): its last eighth (3.0)
    // comes early by 0.08 of an eighth.
    try testing.expectApproxEqAbs(@as(f64, 3.0 - 0.04), warp(&g, 1, 3.0, mm), 1e-9);
    // The 2-groups' notes don't move; their first unit is accented.
    try testing.expectApproxEqAbs(@as(f64, 1.5), warp(&g, 1, 1.5, mm), 1e-9);
    try testing.expectApproxEqAbs(@as(f32, 1.15), stepAt(&g, 1, 1.0, mm).vel, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.85), stepAt(&g, 1, 1.5, mm).vel, 1e-6);
}

test "a track follows its section's groove, else the song's; random repeats" {
    var pool = Pool.init();
    var mk: markers_mod.Markers = .{};
    _ = mk.addSection(0, "A");
    _ = mk.addSection(8, "B");
    mk.sections[1].groove = PICK_NONE;
    const cx = Context{ .pool = &pool, .song = PICK_POOL + 1, .markers = &mk };
    try testing.expectEqualStrings("MPC 58 1/16", resolve(&cx, .{}, 2).?.name.get());
    try testing.expect(resolve(&cx, .{}, 9) == null);
    try testing.expectEqualStrings("MPC 71 1/16", resolve(&cx, .{ .pick = PICK_POOL + 4 }, 9).?.name.get());
    const a = play(&cx, .{}, 0.25, 0.5, 60, 100);
    try testing.expectApproxEqAbs(@as(f64, 0.29), a.on, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.5), a.off, 1e-6);
    try testing.expectEqual(noise(1, 2.5, 60), noise(1, 2.5, 60));
    try testing.expect(noise(1, 2.5, 60) != noise(2, 2.5, 60));
    // SHIFT: 10 ms at 120 BPM is 0.02 beats.
    const s = play(&cx, .{ .pick = PICK_NONE, .shift_ms = 10 }, 1, 2, 60, 100);
    try testing.expectApproxEqAbs(@as(f64, 1.02), s.on, 1e-9);
}

test "extract finds a swing in played notes" {
    const starts = [_]f64{ 0, 0.29, 0.5, 0.79, 1.0, 1.29 };
    const vels = [_]u8{ 100, 60, 100, 60, 100, 60 };
    const g = extract("mine", &starts, &vels, 0.25, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.16), g.cells[0].shift[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), g.cells[0].shift[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.25), g.cells[0].vel[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 0.29), warp(&g, 1, 0.25, null), 1e-6);
}
