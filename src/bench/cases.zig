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

pub const Input = enum { none, impulse, sine, sweep, ladder, burst, saw };

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
