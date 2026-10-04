//! The tempo map (docs/28 §Tempo map): beats → seconds. Points at beats,
//! each holding its tempo until the next (a step) or gliding linearly in
//! beats to the next point's tempo (a ramp). `secs` caches when each
//! point starts, so a conversion is one segment lookup and a closed-form
//! formula. Plain inline data: the audio thread keeps a copy.
//!
//! `TempoState` hands edits from the UI to the audio thread the way
//! `meter.MeterState` does, but adopted at the next block: the engine
//! rebases its sample counter on adoption so the playhead keeps its beat.

const std = @import("std");

pub const MIN_BPM: f64 = 20;
pub const MAX_BPM: f64 = 400;
pub const MAX_POINTS: usize = 256;

pub const TempoPoint = struct {
    /// Where the point takes effect, in quarter beats; the first is at 0.
    beat: f64,
    bpm: f64,
    /// Glide linearly (in beats) to the next point's tempo.
    ramp: bool = false,
};

pub fn clampBpm(v: f64) f64 {
    return std.math.clamp(v, MIN_BPM, MAX_BPM);
}

pub const TempoMap = struct {
    points: [MAX_POINTS]TempoPoint = undefined,
    /// Seconds from beat 0 to each point.
    secs: [MAX_POINTS]f64 = undefined,
    len: usize = 0,

    pub fn constant(bpm: f64) TempoMap {
        var m: TempoMap = .{};
        m.points[0] = .{ .beat = 0, .bpm = clampBpm(bpm) };
        m.secs[0] = 0;
        m.len = 1;
        return m;
    }

    pub fn slice(self: *const TempoMap) []const TempoPoint {
        return self.points[0..self.len];
    }

    /// The tempo the song starts at.
    pub fn base(self: *const TempoMap) f64 {
        return self.points[0].bpm;
    }

    /// Recompute the start times; call after any edit.
    pub fn rebuild(self: *TempoMap) void {
        if (self.len == 0) {
            self.* = constant(120);
            return;
        }
        self.points[0].beat = 0;
        self.secs[0] = 0;
        var i: usize = 1;
        while (i < self.len) : (i += 1) {
            self.secs[i] = self.secs[i - 1] + self.segSeconds(i - 1, self.points[i].beat);
        }
    }

    /// The segment holding `beat` (the last point at or before it).
    pub fn segment(self: *const TempoMap, beat: f64) usize {
        var lo: usize = 0;
        var hi: usize = self.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.points[mid].beat <= beat) lo = mid else hi = mid;
        }
        return lo;
    }

    fn segmentAtSeconds(self: *const TempoMap, t: f64) usize {
        var lo: usize = 0;
        var hi: usize = self.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.secs[mid] <= t) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Tempo change per beat over segment `i` (0 for a step).
    fn slope(self: *const TempoMap, i: usize) f64 {
        const p = self.points[i];
        if (!p.ramp or i + 1 >= self.len) return 0;
        const q = self.points[i + 1];
        const db = q.beat - p.beat;
        if (db <= 0) return 0;
        return (q.bpm - p.bpm) / db;
    }

    /// Seconds from point `i` to `beat` inside its segment.
    fn segSeconds(self: *const TempoMap, i: usize, beat: f64) f64 {
        const p = self.points[i];
        const db = beat - p.beat;
        const k = self.slope(i);
        if (@abs(k) < 1e-9) return db * 60.0 / p.bpm;
        return 60.0 / k * @log((p.bpm + k * db) / p.bpm);
    }

    pub fn bpmAt(self: *const TempoMap, beat: f64) f64 {
        const i = self.segment(beat);
        const p = self.points[i];
        const k = self.slope(i);
        if (k == 0) return p.bpm;
        return p.bpm + k * @max(0, beat - p.beat);
    }

    /// Seconds from beat 0 (negative beats run at the first tempo).
    pub fn secondsAt(self: *const TempoMap, beat: f64) f64 {
        if (beat <= 0) return beat * 60.0 / self.points[0].bpm;
        const i = self.segment(beat);
        return self.secs[i] + self.segSeconds(i, beat);
    }

    pub fn beatAt(self: *const TempoMap, t: f64) f64 {
        if (t <= 0) return t * self.points[0].bpm / 60.0;
        const i = self.segmentAtSeconds(t);
        const p = self.points[i];
        const dt = t - self.secs[i];
        const k = self.slope(i);
        if (@abs(k) < 1e-9) return p.beat + dt * p.bpm / 60.0;
        return p.beat + p.bpm * (@exp(k * dt / 60.0) - 1.0) / k;
    }

    pub fn sampleAt(self: *const TempoMap, beat: f64, rate: u32) f64 {
        return self.secondsAt(beat) * @as(f64, @floatFromInt(rate));
    }

    pub fn beatAtSample(self: *const TempoMap, s: f64, rate: u32) f64 {
        return self.beatAt(s / @as(f64, @floatFromInt(rate)));
    }

    /// The first point strictly after `beat`, as a sample position: where
    /// the engine ends a block. Null past the last point.
    pub fn nextChangeSample(self: *const TempoMap, beat: f64, rate: u32) ?f64 {
        const i = self.segment(beat);
        var j = i + 1;
        while (j < self.len) : (j += 1) {
            if (self.points[j].beat > beat) return self.secs[j] * @as(f64, @floatFromInt(rate));
        }
        return null;
    }

    /// The beat a stretch of `seconds` starting at `beat` ends on.
    pub fn beatAfter(self: *const TempoMap, beat: f64, seconds: f64) f64 {
        return self.beatAt(self.secondsAt(beat) + seconds);
    }

    // ── Editing (the caller rebuilds through TempoState) ──

    /// Index of the point at `beat` (within a tick), if any.
    pub fn find(self: *const TempoMap, beat: f64) ?usize {
        for (self.points[0..self.len], 0..) |p, i| if (@abs(p.beat - beat) < 1e-6) return i;
        return null;
    }

    /// Insert a change at `beat`, or set the tempo of the one there.
    /// Returns its index; null when the map is full.
    pub fn put(self: *TempoMap, beat_in: f64, bpm: f64) ?usize {
        const beat = @max(0, beat_in);
        if (self.find(beat)) |i| {
            self.points[i].bpm = clampBpm(bpm);
            return i;
        }
        if (self.len >= MAX_POINTS) return null;
        var i = self.len;
        while (i > 0 and self.points[i - 1].beat > beat) : (i -= 1) {
            self.points[i] = self.points[i - 1];
        }
        self.points[i] = .{ .beat = beat, .bpm = clampBpm(bpm) };
        self.len += 1;
        return i;
    }

    /// Remove the change at index `i` (the first point stays).
    pub fn remove(self: *TempoMap, i: usize) void {
        if (i == 0 or i >= self.len) return;
        var j = i;
        while (j + 1 < self.len) : (j += 1) self.points[j] = self.points[j + 1];
        self.len -= 1;
    }

    pub fn eql(a: *const TempoMap, b: *const TempoMap) bool {
        if (a.len != b.len) return false;
        for (a.slice(), b.slice()) |p, q| {
            if (p.beat != q.beat or p.bpm != q.bpm or p.ramp != q.ramp) return false;
        }
        return true;
    }
};

/// The UI edits `live` (under the seqlock, through `edit`/`publish`); the
/// audio thread reads `audio` and adopts a pending edit at a block start.
pub const TempoState = struct {
    live: TempoMap = TempoMap.constant(120),
    audio: TempoMap = TempoMap.constant(120),
    seq: std.atomic.Value(u32) = .init(0),
    dirty: std.atomic.Value(bool) = .init(false),

    /// UI thread: open the live map for an edit. Pair with `publish`.
    pub fn edit(self: *TempoState) *TempoMap {
        _ = self.seq.fetchAdd(1, .release); // odd: writing
        return &self.live;
    }

    /// UI thread: close an edit; the audio thread adopts it next block.
    pub fn publish(self: *TempoState) void {
        self.live.rebuild();
        _ = self.seq.fetchAdd(1, .release); // even: stable
        self.dirty.store(true, .release);
    }

    /// UI thread: replace the map.
    pub fn set(self: *TempoState, m: *const TempoMap) void {
        const l = self.edit();
        l.* = m.*;
        self.publish();
    }

    pub fn pending(self: *const TempoState) bool {
        return self.dirty.load(.acquire);
    }

    /// Audio thread: adopt a pending edit. False when nothing changed or
    /// the copy was torn by a concurrent edit (it stays pending).
    pub fn adopt(self: *TempoState) bool {
        if (!self.dirty.swap(false, .acq_rel)) return false;
        const s1 = self.seq.load(.acquire);
        if (s1 & 1 == 0) {
            const n = self.live.len;
            var tmp: TempoMap = undefined;
            @memcpy(tmp.points[0..n], self.live.points[0..n]);
            @memcpy(tmp.secs[0..n], self.live.secs[0..n]);
            if (self.seq.load(.acquire) == s1 and n > 0) {
                @memcpy(self.audio.points[0..n], tmp.points[0..n]);
                @memcpy(self.audio.secs[0..n], tmp.secs[0..n]);
                self.audio.len = n;
                return true;
            }
        }
        self.dirty.store(true, .release);
        return false;
    }

    /// Non-realtime (load, offline render, tests): the audio copy matches
    /// live now. The caller guarantees no concurrent render.
    pub fn commitImmediate(self: *TempoState) void {
        self.live.rebuild();
        self.audio = self.live;
        self.dirty.store(false, .release);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "a constant tempo is a straight line" {
    const m = TempoMap.constant(120);
    try testing.expectApproxEqAbs(@as(f64, 2), m.secondsAt(4), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), m.beatAt(2), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 96000), m.sampleAt(4, 48000), 1e-9);
    try testing.expect(m.nextChangeSample(0, 48000) == null);
}

test "steps add up and invert" {
    var m = TempoMap.constant(120);
    _ = m.put(8, 60);
    _ = m.put(4, 240);
    m.rebuild();
    try testing.expectEqual(@as(usize, 3), m.len);
    // 4 beats at 120 = 2 s, 4 at 240 = 1 s, then 60.
    try testing.expectApproxEqAbs(@as(f64, 3), m.secondsAt(8), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5), m.secondsAt(10), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 240), m.bpmAt(5), 1e-12);
    for ([_]f64{ 0, 1.5, 4, 6.25, 8, 13 }) |b| {
        try testing.expectApproxEqAbs(b, m.beatAt(m.secondsAt(b)), 1e-9);
    }
    try testing.expectApproxEqAbs(@as(f64, 2 * 48000), m.nextChangeSample(1, 48000).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 3 * 48000), m.nextChangeSample(4, 48000).?, 1e-6);
}

test "a ramp integrates its tempo" {
    var m = TempoMap.constant(60);
    m.points[0].ramp = true;
    _ = m.put(8, 180);
    m.rebuild();
    try testing.expectApproxEqAbs(@as(f64, 120), m.bpmAt(4), 1e-12);
    // Numerically integrate 60/bpm over the ramp.
    var t: f64 = 0;
    const n = 100_000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const b = (@as(f64, @floatFromInt(i)) + 0.5) * 8.0 / n;
        t += 60.0 / m.bpmAt(b) * 8.0 / n;
    }
    try testing.expectApproxEqAbs(t, m.secondsAt(8), 1e-6);
    for ([_]f64{ 0.5, 3, 7.9, 8, 12 }) |b| {
        try testing.expectApproxEqAbs(b, m.beatAt(m.secondsAt(b)), 1e-9);
    }
    // After the ramp the tempo holds.
    try testing.expectApproxEqAbs(@as(f64, 180), m.bpmAt(20), 1e-12);
}

test "put replaces, remove keeps the first point" {
    var m = TempoMap.constant(100);
    _ = m.put(4, 130);
    _ = m.put(4, 140);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqual(@as(f64, 140), m.points[1].bpm);
    m.remove(0);
    try testing.expectEqual(@as(usize, 2), m.len);
    m.remove(1);
    try testing.expectEqual(@as(usize, 1), m.len);
    _ = m.put(0, 1000);
    try testing.expectEqual(MAX_BPM, m.points[0].bpm);
}

test "the audio copy adopts a published edit" {
    var st: TempoState = .{};
    _ = st.edit().put(4, 60);
    st.publish();
    try testing.expectEqual(@as(usize, 1), st.audio.len);
    try testing.expect(st.adopt());
    try testing.expectEqual(@as(usize, 2), st.audio.len);
    try testing.expectApproxEqAbs(@as(f64, 2), st.audio.secs[1], 1e-12);
    try testing.expect(!st.adopt());
}
