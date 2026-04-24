//! Minimal audio-clock-authoritative transport. Sample counter advances
//! on the audio thread; UI reads it with relaxed atomics. BPM is stored
//! as bpm*1000 in a u32 so it can sit in an atomic (Zig atomics only
//! support integer types; bit-casting f32 into u32 works too but the
//! milli-BPM form is easier for UI display).

const std = @import("std");

pub const Transport = struct {
    sample_rate: u32 = 48_000,
    playing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Monotonic sample counter; only advanced by the audio thread.
    sample_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// BPM × 1000.
    bpm_milli: std.atomic.Value(u32) = std.atomic.Value(u32).init(120_000),

    pub fn play(self: *Transport) void {
        self.playing.store(true, .release);
    }

    pub fn stop(self: *Transport) void {
        self.playing.store(false, .release);
    }

    pub fn toggle(self: *Transport) void {
        const cur = self.playing.load(.acquire);
        self.playing.store(!cur, .release);
    }

    pub fn isPlaying(self: *const Transport) bool {
        return self.playing.load(.acquire);
    }

    /// Audio-thread only.
    pub fn advance(self: *Transport, frames: u32) void {
        _ = self.sample_pos.fetchAdd(frames, .monotonic);
    }

    pub fn samples(self: *const Transport) u64 {
        return self.sample_pos.load(.monotonic);
    }

    pub fn bpm(self: *const Transport) f32 {
        return @as(f32, @floatFromInt(self.bpm_milli.load(.monotonic))) / 1000.0;
    }

    pub fn setBpm(self: *Transport, v: f32) void {
        const clamped = std.math.clamp(v, 20.0, 400.0);
        self.bpm_milli.store(@intFromFloat(clamped * 1000.0), .monotonic);
    }

    pub fn beats(self: *const Transport) f64 {
        return self.samplesToBeats(self.samples());
    }

    pub fn samplesToBeats(self: *const Transport, s: u64) f64 {
        const sp: f64 = @floatFromInt(s);
        const b: f64 = @as(f64, @floatFromInt(self.bpm_milli.load(.monotonic))) / 1000.0;
        const sr: f64 = @floatFromInt(self.sample_rate);
        return sp * b / (60.0 * sr);
    }

    /// Samples per beat at the current BPM.
    pub fn samplesPerBeat(self: *const Transport) f64 {
        const b: f64 = @as(f64, @floatFromInt(self.bpm_milli.load(.monotonic))) / 1000.0;
        const sr: f64 = @floatFromInt(self.sample_rate);
        return 60.0 * sr / b;
    }

    pub fn rewind(self: *Transport) void {
        self.sample_pos.store(0, .monotonic);
    }

    pub fn seekToSample(self: *Transport, s: u64) void {
        self.sample_pos.store(s, .monotonic);
    }

    pub fn seekToBeats(self: *Transport, b: f64) void {
        const clamped = if (b < 0) 0 else b;
        const s = clamped * self.samplesPerBeat();
        self.sample_pos.store(@intFromFloat(s), .monotonic);
    }
};
