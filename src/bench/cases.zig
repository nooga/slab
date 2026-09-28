//! Bench cases: stimulus + what to analyze.
//!
//! v1 ships default suites chosen by machine kind (melodic voice, drum
//! voice, effect) so every machine gets goldens without per-machine
//! authoring. Per-machine `bench.fy` cases come with the manifest DSL
//! (docs/17 Track C).

const std = @import("std");

pub const Event = struct {
    t: f64, // seconds
    on: bool,
    pitch: f32, // MIDI note
    vel: f32 = 0.8,
};

pub const Input = enum { none, impulse, sine, sweep, ladder, burst, saw, curve, step, drums, file };

pub const Focus = enum {
    /// Per-note table: pitch, cents error, level, nonharmonic energy.
    notes,
    /// One held note: envelope shape + steady-state spectrum.
    held,
    /// Drum hits: per-hit level, decay, brightness.
    hits,
    /// Effect impulse: magnitude response + decay.
    impulse,
    /// Effect sine: gain, THD, nonharmonic energy.
    sine,
    /// Effect sweep: spectrogram shows harmonics and aliasing.
    sweep,
    /// Effect level ladder: static transfer curve (in dB -> out dB).
    ladder,
    /// Effect noise burst: envelope/tail behavior.
    burst,
    /// Dynamics: fine static curve, gain per step (docs/24 §Test plan).
    curve,
    /// Dynamics: gain step response, attack and release time constants.
    step,
    /// Dynamics: a synthetic kit loop, gain reduction per hit and crest.
    drums,
    /// Dynamics on real material (`--input=FILE`): GR distribution, level
    /// spread, transients, pumping (docs/24 §Test plan).
    file,
};

pub const Case = struct {
    name: []const u8,
    seconds: f64,
    focus: Focus,
    input: Input = .none,
    input_hz: f64 = 1000,
    input_db: f64 = -6,
    events: []const Event = &.{},
    /// Steady-state analysis window, seconds.
    win: [2]f64 = .{ 0.5, 1.0 },
};

pub const ladder_steps = [_]f64{ -42, -30, -18, -12, -6, 0 };
pub const ladder_step_s = 0.5;

fn noteTrain(comptime notes: []const f32, comptime vels: []const f32, spacing: f64, len: f64) [notes.len * 2]Event {
    var ev: [notes.len * 2]Event = undefined;
    for (notes, 0..) |p, i| {
        const t = @as(f64, @floatFromInt(i)) * spacing;
        const v = if (vels.len == 0) 0.8 else vels[i];
        ev[2 * i] = .{ .t = t, .on = true, .pitch = p, .vel = v };
        ev[2 * i + 1] = .{ .t = t + len, .on = false, .pitch = p };
    }
    return ev;
}

const notes_ev = noteTrain(&.{ 36, 48, 60, 72 }, &.{}, 0.75, 0.5);
const vel_ev = noteTrain(&.{ 48, 48, 48, 48 }, &.{ 0.25, 0.5, 0.75, 1.0 }, 0.75, 0.5);
const held_ev = [_]Event{ .{ .t = 0, .on = true, .pitch = 48 }, .{ .t = 2.0, .on = false, .pitch = 48 } };
const high_ev = [_]Event{ .{ .t = 0, .on = true, .pitch = 84 }, .{ .t = 1.5, .on = false, .pitch = 84 } };
const chord_ev = [_]Event{
    .{ .t = 0, .on = true, .pitch = 48 },   .{ .t = 0, .on = true, .pitch = 52 },
    .{ .t = 0, .on = true, .pitch = 55 },   .{ .t = 0, .on = true, .pitch = 59 },
    .{ .t = 2.0, .on = false, .pitch = 48 }, .{ .t = 2.0, .on = false, .pitch = 52 },
    .{ .t = 2.0, .on = false, .pitch = 55 }, .{ .t = 2.0, .on = false, .pitch = 59 },
};

pub const voice_suite = [_]Case{
    .{ .name = "notes", .seconds = 3.25, .focus = .notes, .events = &notes_ev },
    .{ .name = "velocity", .seconds = 3.25, .focus = .notes, .events = &vel_ev },
    .{ .name = "held", .seconds = 3.5, .focus = .held, .events = &held_ev, .win = .{ 1.0, 2.0 } },
    .{ .name = "high", .seconds = 2.0, .focus = .held, .events = &high_ev, .win = .{ 0.5, 1.5 } },
};

pub const poly_extra = [_]Case{
    .{ .name = "chord", .seconds = 3.5, .focus = .held, .events = &chord_ev, .win = .{ 1.0, 2.0 } },
};

pub const effect_suite = [_]Case{
    .{ .name = "impulse", .seconds = 3.0, .focus = .impulse, .input = .impulse },
    .{ .name = "sine", .seconds = 2.0, .focus = .sine, .input = .sine, .input_hz = 1000, .input_db = -6, .win = .{ 0.5, 1.5 } },
    .{ .name = "sweep", .seconds = 4.5, .focus = .sweep, .input = .sweep, .input_db = -12 },
    .{ .name = "ladder", .seconds = 3.0, .focus = .ladder, .input = .ladder, .input_hz = 200 },
    .{ .name = "burst", .seconds = 2.0, .focus = .burst, .input = .burst, .input_db = -12 },
};

/// Dynamics cases (docs/24 §Test plan), for compressors: run after the
/// effect suite for the machines `bench_main` lists as dynamics. Gain is
/// measured as out/in over 1 ms windows with the machine's own MIX, so no
/// meter reading is needed. `lowsine` reuses the sine focus at 50 Hz.
pub const dynamics_suite = [_]Case{
    .{ .name = "curve", .seconds = curve_steps * curve_step_s, .focus = .curve, .input = .curve },
    .{ .name = "step", .seconds = 2.5, .focus = .step, .input = .step },
    .{ .name = "lowsine", .seconds = 2.0, .focus = .sine, .input = .sine, .input_hz = 50, .input_db = -6, .win = .{ 0.5, 1.5 } },
    .{ .name = "drums", .seconds = drums_bars * 4 * 60.0 / drums_bpm + 0.5, .focus = .drums, .input = .drums },
};

/// Curve: 1 kHz from -48 to 0 dBFS in 3 dB steps.
pub const curve_lo_db = -48.0;
pub const curve_step_db = 3.0;
pub const curve_steps = 17;
pub const curve_step_s = 0.25;

/// Step: 1 kHz at step_lo, up to step_hi at step_up_s, back at step_down_s.
pub const step_lo_db = -40.0;
pub const step_hi_db = -10.0;
pub const step_up_s = 0.5;
pub const step_down_s = 1.0;

/// Drums: kick on 1 and 3 (and the "and" of 3), snare on 2 and 4, hats on
/// eighths, 110 bpm, peak -6 dBFS; deterministic.
pub const drums_bpm = 110.0;
pub const drums_bars = 4;
pub const DrumHit = struct { t: f64, kind: enum { kick, snare, hat } };

pub fn drumHits(store: []DrumHit) []DrumHit {
    const beat = 60.0 / drums_bpm;
    var n: usize = 0;
    for (0..drums_bars) |bar| {
        const b0 = @as(f64, @floatFromInt(bar * 4)) * beat;
        for (0..8) |e| {
            const t = b0 + @as(f64, @floatFromInt(e)) * beat / 2;
            if (n < store.len and (e == 0 or e == 4 or e == 5)) {
                store[n] = .{ .t = t, .kind = .kick };
                n += 1;
            }
            if (n < store.len and (e == 2 or e == 6)) {
                store[n] = .{ .t = t, .kind = .snare };
                n += 1;
            }
            if (n < store.len) {
                store[n] = .{ .t = t, .kind = .hat };
                n += 1;
            }
        }
    }
    return store[0..n];
}

/// Drum hits: one per pitch, 0.5 s apart. Built at runtime from the
/// machine's note labels, so it lives in caller-provided storage.
pub fn drumCase(pitches: []const f32, store: []Event) Case {
    const n = @min(pitches.len, store.len / 2);
    for (pitches[0..n], 0..) |p, i| {
        const t = @as(f64, @floatFromInt(i)) * 0.5;
        store[2 * i] = .{ .t = t, .on = true, .pitch = p, .vel = 0.9 };
        store[2 * i + 1] = .{ .t = t + 0.1, .on = false, .pitch = p };
    }
    return .{
        .name = "hits",
        .seconds = @as(f64, @floatFromInt(n)) * 0.5 + 0.5,
        .focus = .hits,
        .events = store[0 .. 2 * n],
    };
}

/// Input impulse sits 10 ms in so the sheet shows the pre-roll.
pub const impulse_at_s = 0.01;
pub const burst_at_s = 0.1;
pub const burst_len_s = 0.1;

pub fn dbToAmp(db: f64) f64 {
    return std.math.pow(f64, 10.0, db / 20.0);
}

/// Fill `buf` with the case's input signal (mono; fed to both channels).
pub fn genInput(case: Case, sr: f64, buf: []f32) void {
    @memset(buf, 0);
    const amp = dbToAmp(case.input_db);
    const n = buf.len;
    switch (case.input) {
        .none => {},
        .impulse => buf[@intFromFloat(impulse_at_s * sr)] = 1.0,
        .sine => {
            const end: usize = @min(n, @as(usize, @intFromFloat(1.5 * sr)));
            for (buf[0..end], 0..) |*v, i| v.* = @floatCast(amp * @sin(2 * std.math.pi * case.input_hz * @as(f64, @floatFromInt(i)) / sr));
        },
        .sweep => {
            // Exponential sine sweep 20 Hz -> 20 kHz over 4 s.
            const dur = 4.0;
            const f0 = 20.0;
            const f1 = 20000.0;
            const k = @log(f1 / f0);
            const end: usize = @min(n, @as(usize, @intFromFloat(dur * sr)));
            for (buf[0..end], 0..) |*v, i| {
                const t = @as(f64, @floatFromInt(i)) / sr;
                const ph = 2 * std.math.pi * f0 * dur / k * (@exp(t / dur * k) - 1);
                v.* = @floatCast(amp * @sin(ph));
            }
        },
        .ladder => {
            const step: usize = @intFromFloat(ladder_step_s * sr);
            for (ladder_steps, 0..) |db, s| {
                const a = dbToAmp(db);
                for (0..step) |j| {
                    const i = s * step + j;
                    if (i >= n) break;
                    buf[i] = @floatCast(a * @sin(2 * std.math.pi * case.input_hz * @as(f64, @floatFromInt(i)) / sr));
                }
            }
        },
        .burst => {
            var rng = std.Random.DefaultPrng.init(0x5eed);
            const a0: usize = @intFromFloat(burst_at_s * sr);
            const a1: usize = @min(n, a0 + @as(usize, @intFromFloat(burst_len_s * sr)));
            for (buf[a0..a1]) |*v| v.* = @floatCast(amp * (rng.random().float(f64) * 2 - 1));
        },
        .curve => {
            const step: usize = @intFromFloat(curve_step_s * sr);
            for (0..curve_steps) |k| {
                const a = dbToAmp(curve_lo_db + curve_step_db * @as(f64, @floatFromInt(k)));
                for (0..step) |j| {
                    const i = k * step + j;
                    if (i >= n) break;
                    buf[i] = @floatCast(a * @sin(2 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / sr));
                }
            }
        },
        .step => {
            const up: usize = @intFromFloat(step_up_s * sr);
            const down: usize = @intFromFloat(step_down_s * sr);
            for (buf, 0..) |*v, i| {
                const a = dbToAmp(if (i >= up and i < down) step_hi_db else step_lo_db);
                v.* = @floatCast(a * @sin(2 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / sr));
            }
        },
        .drums => {
            var store: [128]DrumHit = undefined;
            var rng = std.Random.DefaultPrng.init(0xd205);
            for (drumHits(&store)) |hit| {
                const start: usize = @intFromFloat(hit.t * sr);
                const len: usize = @intFromFloat(0.5 * sr);
                var ph: f64 = 0;
                var hp: f64 = 0;
                var prev: f64 = 0;
                for (0..len) |j| {
                    const i = start + j;
                    if (i >= n) break;
                    const t = @as(f64, @floatFromInt(j)) / sr;
                    const noise = rng.random().float(f64) * 2 - 1;
                    const v: f64 = switch (hit.kind) {
                        // Sine sweep 150 -> 45 Hz, 0.25 s decay, a click on top.
                        .kick => blk: {
                            ph += (45.0 + 105.0 * @exp(-t / 0.03)) / sr;
                            break :blk @sin(2 * std.math.pi * ph) * @exp(-t / 0.25) + noise * 0.3 * @exp(-t / 0.002);
                        },
                        // 190 Hz body plus noise, 0.12 s decay.
                        .snare => blk: {
                            ph += 190.0 / sr;
                            break :blk (0.5 * @sin(2 * std.math.pi * ph) * @exp(-t / 0.06) + 0.6 * noise * @exp(-t / 0.12));
                        },
                        // High-passed noise, 25 ms.
                        .hat => blk: {
                            hp = 0.6 * (hp + noise - prev);
                            prev = noise;
                            break :blk 0.25 * hp * @exp(-t / 0.025);
                        },
                    };
                    buf[i] += @floatCast(v);
                }
            }
            var peak: f32 = 0;
            for (buf) |v| peak = @max(peak, @abs(v));
            if (peak > 0) {
                const g: f32 = @floatCast(dbToAmp(-6) / peak);
                for (buf) |*v| v.* *= g;
            }
        },
        .file => {}, // filled by the caller from --input
        .saw => {
            var ph: f64 = 0;
            for (buf) |*v| {
                v.* = @floatCast(amp * (2 * ph - 1));
                ph += case.input_hz / sr;
                ph -= @floor(ph);
            }
        },
    }
}

pub fn noteName(buf: []u8, midi: f32) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const m: i32 = @intFromFloat(@round(midi));
    const oct = @divFloor(m, 12) - 1;
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[@intCast(@mod(m, 12))], oct }) catch "?";
}
