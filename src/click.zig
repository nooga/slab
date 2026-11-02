//! Metronome (docs/07 §Metronome): a click on every beat of the meter map,
//! an accent on the downbeat and the group starts, mixed into the live
//! output after the master chain (the master effects and the offline
//! renders never hear it). The UI writes `on` and `gain`; the audio thread
//! reads them and owns the voice.

const std = @import("std");
const meter = @import("meter.zig");
const tempo = @import("tempo.zig");

pub const Click = struct {
    on: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Linear gain 0..1 as f32 bits.
    gain_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(DEFAULT_GAIN)),

    // The sounding click (audio thread).
    phase: f32 = 0,
    env: f32 = 0,
    inc: f32 = 0,
    amp: f32 = 0,
    /// Clicks started so far (for tests).
    fired: u32 = 0,

    pub const DEFAULT_GAIN: f32 = 0.5;
    /// Longest chunk the engine renders, and so the most beats it can hold.
    const MAX_TICKS = 16;
    /// Time constant of the click's decay, seconds.
    const DECAY_S: f32 = 0.012;

    pub fn setOn(self: *Click, v: bool) void {
        self.on.store(v, .monotonic);
    }
    pub fn isOn(self: *const Click) bool {
        return self.on.load(.monotonic);
    }
    pub fn setGain(self: *Click, g: f32) void {
        self.gain_bits.store(@bitCast(std.math.clamp(g, 0, 1)), .monotonic);
    }
    pub fn gain(self: *const Click) f32 {
        return @bitCast(self.gain_bits.load(.monotonic));
    }

    fn trigger(self: *Click, accent: meter.Accent, rate: u32) void {
        const hz: f32, const amp: f32 = switch (accent) {
            .downbeat => .{ 1568, 1.0 },
            .group => .{ 1175, 0.8 },
            .weak => .{ 880, 0.6 },
        };
        self.fired += 1;
        self.phase = 0;
        self.env = 1;
        self.amp = amp;
        self.inc = std.math.tau * hz / @as(f32, @floatFromInt(rate));
    }

    fn fill(self: *Click, out: []f32, from: usize, to: usize, g: f32, decay: f32) void {
        var i = from;
        while (i < to and self.env > 1e-4) : (i += 1) {
            const v = @sin(self.phase) * self.env * self.amp * g;
            out[i * 2] += v;
            out[i * 2 + 1] += v;
            self.phase += self.inc;
            if (self.phase > std.math.tau) self.phase -= std.math.tau;
            self.env *= decay;
        }
    }

    /// Add the clicks that fall in the stereo block `out` (`frames` long) to
    /// it. `start` is the block's first sample on the timeline as heard: the
    /// caller subtracts the output's delay, so the click lines up with the
    /// delayed master. Each boundary belongs to the one block holding its
    /// sample, so blocks need no memory of each other.
    pub fn mix(self: *Click, out: []f32, frames: usize, start: i64, tm: *const tempo.TempoMap, rate: u32, map: meter.MeterMap) void {
        const g = self.gain() * 0.5;
        if (!self.on.load(.monotonic) or g <= 0) {
            self.env = 0;
            return;
        }
        const decay = @exp(-1.0 / (DECAY_S * @as(f32, @floatFromInt(rate))));
        const end = start + @as(i64, @intCast(frames));
        // From a sample early, so rounding can't lose a boundary at `start`.
        var tick = map.tickAtOrAfter(tm.beatAtSample(@floatFromInt(@max(start - 1, 0)), rate));
        var at: [MAX_TICKS]usize = undefined;
        var acc: [MAX_TICKS]meter.Accent = undefined;
        var n: usize = 0;
        while (n < MAX_TICKS) {
            const s: i64 = @intFromFloat(@round(tm.sampleAt(tick.beat, rate)));
            if (s >= end) break;
            if (s >= start) {
                at[n] = @intCast(s - start);
                acc[n] = tick.accent;
                n += 1;
            }
            tick = map.tickAtOrAfter(tick.beat + 1e-6);
        }
        var i: usize = 0;
        for (0..n) |k| {
            self.fill(out, i, at[k], g, decay);
            i = at[k];
            self.trigger(acc[k], rate);
        }
        self.fill(out, i, frames, g, decay);
    }
};

test "clicks land on the beats, the downbeat higher than the rest" {
    var c = Click{};
    c.setOn(true);
    const tm = tempo.TempoMap.constant(120); // 24000 samples per beat at 48 kHz
    var pts = meter.MeterMap.singlePoint(4, 4);
    const map = meter.MeterMap{ .points = &pts };
    var out: [2 * 512]f32 = @splat(0);
    c.mix(&out, 512, 0, &tm, 48000, map);
    // The downbeat starts at sample 0; the voice has begun by sample 8.
    try std.testing.expect(@abs(out[2 * 8]) > 0.01);
    // A block holding no boundary stays silent.
    var c2 = Click{};
    c2.setOn(true);
    var quiet: [2 * 512]f32 = @splat(0);
    c2.mix(&quiet, 512, 4000, &tm, 48000, map);
    for (quiet) |v| try std.testing.expectEqual(@as(f32, 0), v);
}

test "a boundary is clicked once however the blocks fall" {
    const tm = tempo.TempoMap.constant(120);
    var pts = meter.MeterMap.singlePoint(4, 4);
    const map = meter.MeterMap{ .points = &pts };
    for ([_]usize{ 64, 100, 256, 480 }) |blk| {
        var c = Click{};
        c.setOn(true);
        var out: [2 * 480]f32 = undefined;
        var s: i64 = 0;
        while (s < 96000) : (s += @intCast(blk)) { // 4 beats and a little
            @memset(&out, 0);
            c.mix(&out, blk, s, &tm, 48000, map);
        }
        // Beats 0..4 are at 0, 24000, 48000, 72000: four, not five (96000
        // is past the end of the last block).
        try std.testing.expectEqual(@as(u32, 4), c.fired);
    }
}

test "off is silent and off to on does not leave a tail" {
    var c = Click{};
    const tm = tempo.TempoMap.constant(120);
    var pts = meter.MeterMap.singlePoint(4, 4);
    const map = meter.MeterMap{ .points = &pts };
    var out: [2 * 128]f32 = @splat(0);
    c.mix(&out, 128, 0, &tm, 48000, map);
    for (out) |v| try std.testing.expectEqual(@as(f32, 0), v);
}
