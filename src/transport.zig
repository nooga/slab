//! Minimal audio-clock-authoritative transport. Sample counter advances
//! on the audio thread; UI reads it with relaxed atomics. Tempo is a map
//! (docs/28 §Tempo map): the conversions here read the UI's live copy;
//! the engine reads `tempo.audio`.

const std = @import("std");
const tempo_mod = @import("tempo.zig");
const handoff = @import("handoff.zig");

pub const Loop = struct {
    enabled: bool = false,
    start_milli: u64 = 0,
    end_milli: u64 = 16_000,
    pub fn startBeats(self: Loop) f64 {
        return @as(f64, @floatFromInt(self.start_milli)) / 1000.0;
    }
    pub fn endBeats(self: Loop) f64 {
        return @as(f64, @floatFromInt(self.end_milli)) / 1000.0;
    }
};

pub const Transport = struct {
    sample_rate: u32 = 48_000,
    playing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Monotonic sample counter; only advanced by the audio thread.
    sample_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tempo: tempo_mod.TempoState = .{},
    // UI targets; audio reads only its coherently adopted loop version.
    loop_audio: Loop = .{},
    loop_versions: handoff.Latest(Loop) = .init(.{}),
    loop_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Loop bounds in beats × 1000.
    loop_start_milli: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    loop_end_milli: std.atomic.Value(u64) = std.atomic.Value(u64).init(16_000),

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

    pub fn samples(self: *const Transport) u64 {
        return self.sample_pos.load(.monotonic);
    }

    /// UI thread: the live tempo map.
    pub fn map(self: *const Transport) *const tempo_mod.TempoMap {
        return &self.tempo.live;
    }

    /// The tempo at the playhead.
    pub fn bpm(self: *const Transport) f32 {
        return @floatCast(self.map().bpmAt(self.beats()));
    }

    /// The tempo the song starts at.
    pub fn baseBpm(self: *const Transport) f32 {
        return @floatCast(self.map().base());
    }

    /// Set the tempo of the segment under the playhead (with one point,
    /// the song's). A ramp's end follows the next point.
    pub fn setBpm(self: *Transport, v: f32) void {
        const i = self.map().segment(self.beats());
        self.setBpmAt(i, v);
    }

    /// Set point `i`'s tempo.
    pub fn setBpmAt(self: *Transport, i: usize, v: f32) void {
        const m = self.tempo.edit();
        if (i < m.len) m.points[i].bpm = tempo_mod.clampBpm(v);
        self.tempo.publish();
    }

    pub fn beats(self: *const Transport) f64 {
        return self.samplesToBeats(self.samples());
    }

    pub fn samplesToBeats(self: *const Transport, s: u64) f64 {
        return self.map().beatAtSample(@floatFromInt(s), self.sample_rate);
    }

    pub fn beatsToSamples(self: *const Transport, b: f64) u64 {
        const clamped = if (b < 0) 0 else b;
        return @intFromFloat(self.map().sampleAt(clamped, self.sample_rate));
    }

    /// Seconds from `beat` for `seconds`, in beats (an audio clip's
    /// length where it sits).
    pub fn secondsToBeats(self: *const Transport, beat: f64, seconds: f64) f64 {
        return self.map().beatAfter(beat, seconds) - beat;
    }

    /// Beats from `beat`, in seconds.
    pub fn beatsToSeconds(self: *const Transport, beat: f64, len: f64) f64 {
        const m = self.map();
        return m.secondsAt(beat + len) - m.secondsAt(beat);
    }

    pub fn loopEnabled(self: *const Transport) bool {
        return self.loop_enabled.load(.monotonic);
    }

    pub fn setLoopEnabled(self: *Transport, enabled: bool) void {
        self.loop_enabled.store(enabled, .monotonic);
        self.publishLoop();
    }

    pub fn toggleLoop(self: *Transport) void {
        self.setLoopEnabled(!self.loopEnabled());
    }

    pub fn loopStartBeats(self: *const Transport) f64 {
        return @as(f64, @floatFromInt(self.loop_start_milli.load(.monotonic))) / 1000.0;
    }

    pub fn loopEndBeats(self: *const Transport) f64 {
        return @as(f64, @floatFromInt(self.loop_end_milli.load(.monotonic))) / 1000.0;
    }

    pub fn setLoopBeats(self: *Transport, start: f64, end: f64) void {
        const s = if (start < 0) 0 else start;
        const e = if (end <= s + 0.25) s + 0.25 else end;
        self.loop_start_milli.store(@intFromFloat(s * 1000.0), .monotonic);
        self.loop_end_milli.store(@intFromFloat(e * 1000.0), .monotonic);
        self.loop_enabled.store(true, .monotonic);
        self.publishLoop();
        const cur_b = self.beats();
        if (cur_b < s or cur_b >= e) self.seekToBeats(s);
    }

    pub fn clearLoop(self: *Transport) void {
        self.setLoopEnabled(false);
    }

    fn publishLoop(self: *Transport) void {
        self.loop_versions.write().* = .{
            .enabled = self.loop_enabled.load(.monotonic),
            .start_milli = self.loop_start_milli.load(.monotonic),
            .end_milli = self.loop_end_milli.load(.monotonic),
        };
        self.loop_versions.publish();
    }

    /// Rendering thread, before using either bound. UI target stores do
    /// not affect this version until a whole loop edit is published.
    pub fn adoptLoop(self: *Transport) void {
        if (self.loop_versions.adopt()) self.loop_audio = self.loop_versions.current().*;
    }

    pub fn rewind(self: *Transport) void {
        self.sample_pos.store(0, .monotonic);
    }

    pub fn seekToSample(self: *Transport, s: u64) void {
        self.sample_pos.store(s, .monotonic);
    }

    pub fn seekToBeats(self: *Transport, b: f64) void {
        self.sample_pos.store(self.beatsToSamples(b), .monotonic);
    }
};

test "realtime: loop enable and both bounds adopt as one version" {
    var t = Transport{};
    t.setLoopBeats(1, 2);
    t.adoptLoop();
    try std.testing.expect(t.loop_audio.enabled);
    try std.testing.expectEqual(@as(f64, 1), t.loop_audio.startBeats());
    try std.testing.expectEqual(@as(f64, 2), t.loop_audio.endBeats());
    // Producer is interrupted between target stores: audio retains its
    // complete old range, rather than wrapping through mismatched bounds.
    t.loop_start_milli.store(15000, .monotonic);
    t.adoptLoop();
    try std.testing.expectEqual(@as(f64, 1), t.loop_audio.startBeats());
    try std.testing.expectEqual(@as(f64, 2), t.loop_audio.endBeats());
    t.loop_end_milli.store(18000, .monotonic);
    t.publishLoop();
    t.adoptLoop();
    try std.testing.expectEqual(@as(f64, 15), t.loop_audio.startBeats());
    try std.testing.expectEqual(@as(f64, 18), t.loop_audio.endBeats());
    t.clearLoop();
    try std.testing.expect(t.loop_audio.enabled);
    t.adoptLoop();
    try std.testing.expect(!t.loop_audio.enabled);
}
