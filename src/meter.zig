//! Meter (time signature) as a view over the beat axis. See
//! docs/07-transport.md (Meter map). Meter is NOT a clock: the atomic
//! musical unit stays the quarter-note beat (the transport maps
//! beats<->samples). Meter only groups quarter-beats into bars — it
//! answers "where is the downbeat", never "how fast". Nothing here runs
//! on the audio thread and nothing allocates: a `MeterMap` is a borrowed
//! slice of points plus pure functions over it.
//!
//! A bar of N/D spans `N * (4/D)` quarter-beats: 4/4 = 4, 7/8 = 3.5,
//! 13/16 = 3.25. Meter changes happen at bar boundaries, so the map is
//! keyed by bar index, not by sample or beat.

const std = @import("std");

/// Ticks per quarter note for the sub-beat field of `BarPos` (standard
/// MIDI PPQN). A meter-beat of length `4/D` quarter-notes therefore holds
/// `(4/D) * PPQN` ticks.
pub const PPQN: u32 = 960;

/// One entry in a meter map. Applies from `start_bar` until the next
/// point's `start_bar` (or forever, if it is the last point).
pub const MeterPoint = struct {
    start_bar: u32,
    numerator: u8,
    denominator: u8, // power of two: 2, 4, 8, 16
    /// Additive grouping (7/8 as {2,2,3}); empty means even subdivision
    /// by the denominator. Drives accents and in-bar grid emphasis only —
    /// it has no effect on bar length or any function in this module.
    groups: []const u8 = &.{},

    /// Quarter-beats spanned by one bar of this meter.
    pub fn barLenBeats(self: MeterPoint) f64 {
        const n: f64 = @floatFromInt(self.numerator);
        const d: f64 = @floatFromInt(self.denominator);
        return n * 4.0 / d;
    }

    /// Quarter-beats per meter-beat (one unit of the denominator).
    pub fn unitBeats(self: MeterPoint) f64 {
        const d: f64 = @floatFromInt(self.denominator);
        return 4.0 / d;
    }
};

/// Musical position derived from a quarter-beat. `beat` and `tick` are in
/// the meter's own units: `beat` counts denominator units within the bar
/// (0-based), `tick` is the PPQN-scaled offset into that meter-beat.
pub const BarPos = struct {
    bar: u32, // 0-based bar index
    beat: u32, // 0-based meter-beat within the bar (denominator units)
    tick: u32, // 0..(unitBeats * PPQN); sub-beat offset
};

/// A borrowed, sorted list of meter points. `points[0].start_bar` must be
/// 0 and the list must be strictly increasing in `start_bar`. The map
/// owns no memory; the caller keeps `points` alive.
pub const MeterMap = struct {
    points: []const MeterPoint,

    /// A constant meter over the whole timeline, backed by a one-element
    /// array the caller stores. Usage: `var p = MeterMap.singlePoint(4,4);
    /// const m = MeterMap{ .points = &p };`
    pub fn singlePoint(numerator: u8, denominator: u8) [1]MeterPoint {
        return .{.{ .start_bar = 0, .numerator = numerator, .denominator = denominator }};
    }

    /// The point governing `bar`: the last point with `start_bar <= bar`.
    pub fn segmentForBar(self: MeterMap, bar: u32) MeterPoint {
        std.debug.assert(self.points.len > 0);
        var seg = self.points[0];
        for (self.points) |p| {
            if (p.start_bar <= bar) seg = p else break;
        }
        return seg;
    }

    /// Quarter-beats in the given bar.
    pub fn barLenBeats(self: MeterMap, bar: u32) f64 {
        return self.segmentForBar(bar).barLenBeats();
    }

    /// Quarter-beat at which `bar` begins. O(points): accumulates the
    /// length of each segment that ends at or before `bar`.
    pub fn barStartBeat(self: MeterMap, bar: u32) f64 {
        std.debug.assert(self.points.len > 0);
        var acc: f64 = 0;
        var i: usize = 0;
        while (i < self.points.len) : (i += 1) {
            const p = self.points[i];
            const seg_len = p.barLenBeats();
            const next_start: u32 = if (i + 1 < self.points.len)
                self.points[i + 1].start_bar
            else
                bar; // last segment is open-ended; clamp to target
            const hi = @min(next_start, bar);
            if (hi > p.start_bar) {
                acc += @as(f64, @floatFromInt(hi - p.start_bar)) * seg_len;
            }
            if (next_start >= bar) break;
        }
        return acc;
    }

    /// Bar context for a quarter-beat, in one walk. This is what the
    /// engine fills into `MachineCtx` per block: the bar index, the
    /// quarter-beat where that bar starts, and the bar's length. A
    /// machine derives normalized bar phase as
    /// `(ppq_position - bar_start_beat) / bar_len_beats`.
    pub const BarInfo = struct {
        bar: u32,
        bar_start_beat: f64,
        bar_len_beats: f64,
    };

    pub fn barInfoAtBeat(self: MeterMap, beat_q_in: f64) BarInfo {
        std.debug.assert(self.points.len > 0);
        const beat_q = if (beat_q_in < 0) 0 else beat_q_in;

        var acc_beat: f64 = 0;
        var i: usize = 0;
        while (i < self.points.len) : (i += 1) {
            const p = self.points[i];
            const seg_len = p.barLenBeats();
            const is_last = i + 1 >= self.points.len;

            if (!is_last) {
                const seg_bars = self.points[i + 1].start_bar - p.start_bar;
                const seg_total = @as(f64, @floatFromInt(seg_bars)) * seg_len;
                if (beat_q >= acc_beat + seg_total) {
                    acc_beat += seg_total;
                    continue;
                }
            }

            const into = beat_q - acc_beat;
            const bars_into = std.math.floor(into / seg_len);
            return .{
                .bar = p.start_bar + @as(u32, @intFromFloat(bars_into)),
                .bar_start_beat = acc_beat + bars_into * seg_len,
                .bar_len_beats = seg_len,
            };
        }
        unreachable;
    }

    /// Map a quarter-beat (from project start) to a musical position.
    /// Negative input clamps to 0.
    pub fn beatToBarPos(self: MeterMap, beat_q_in: f64) BarPos {
        std.debug.assert(self.points.len > 0);
        const beat_q = if (beat_q_in < 0) 0 else beat_q_in;

        var acc_beat: f64 = 0;
        var i: usize = 0;
        while (i < self.points.len) : (i += 1) {
            const p = self.points[i];
            const seg_len = p.barLenBeats();
            const is_last = i + 1 >= self.points.len;

            if (!is_last) {
                const seg_bars = self.points[i + 1].start_bar - p.start_bar;
                const seg_total = @as(f64, @floatFromInt(seg_bars)) * seg_len;
                if (beat_q >= acc_beat + seg_total) {
                    acc_beat += seg_total;
                    continue;
                }
            }

            // beat falls within this (possibly open-ended) segment.
            const into = beat_q - acc_beat;
            const bars_into = std.math.floor(into / seg_len);
            const bar = p.start_bar + @as(u32, @intFromFloat(bars_into));
            const q_in = into - bars_into * seg_len;

            const unit = p.unitBeats();
            const beat_idx = std.math.floor(q_in / unit);
            const rem_q = q_in - beat_idx * unit;
            const tick = std.math.round(rem_q * @as(f64, @floatFromInt(PPQN)));

            return .{
                .bar = bar,
                .beat = @intFromFloat(beat_idx),
                .tick = @intFromFloat(tick),
            };
        }
        unreachable; // last segment is open-ended, always matches
    }
};

/// Max meter-change points a document can hold. Hand-authored maps need
/// a handful; per-bar generators (a later slice) are the reason for the
/// headroom.
pub const MAX_POINTS: usize = 256;

/// Document-owned, bounded backing store for a meter map. Defaults to a
/// constant 4/4. The runtime owns one of these (serialized via
/// document.zig); the engine reads `map()` on the audio thread. Mutating
/// it while audio plays is not yet guarded — the next-bar-boundary swap
/// (docs/07 §runtime-change) is a separate slice.
pub const MeterStore = struct {
    buf: [MAX_POINTS]MeterPoint =
        [_]MeterPoint{.{ .start_bar = 0, .numerator = 4, .denominator = 4 }} ** MAX_POINTS,
    len: usize = 1,

    pub fn map(self: *const MeterStore) MeterMap {
        return .{ .points = self.buf[0..self.len] };
    }

    /// Reset to a constant 4/4.
    pub fn reset(self: *MeterStore) void {
        self.buf[0] = .{ .start_bar = 0, .numerator = 4, .denominator = 4 };
        self.len = 1;
    }

    pub fn clear(self: *MeterStore) void {
        self.len = 0;
    }

    /// Append a point; ignored past capacity. Caller keeps points sorted
    /// and strictly increasing in start_bar.
    pub fn append(self: *MeterStore, p: MeterPoint) void {
        if (self.len >= MAX_POINTS) return;
        self.buf[self.len] = p;
        self.len += 1;
    }
};

/// Runtime meter state with a safe edit→play handoff. The UI/generator
/// thread edits `live`; the audio thread reads a private `audio_copy` and
/// only refreshes it at a bar boundary (docs/07 §runtime-change), so a
/// meter change never re-lays bars under a moving playhead mid-bar.
///
/// Concurrency: a seqlock guards `live`. `stage()` brackets a full
/// rewrite (odd→write→even, Release) and marks `dirty`. `adoptIfPending()`
/// runs on the audio thread at a boundary: it snapshots `live` under the
/// seqlock and commits to `audio_copy` only if no write straddled the
/// copy — a torn read keeps the old copy and stays dirty for next time.
/// `commitImmediate()` is the non-realtime path (project load, edits while
/// stopped) and assumes no concurrent render.
///
/// NOTE: `MeterPoint.groups` is copied by slice header only; until the
/// generator slice owns group storage, staged points must use empty
/// groups (or storage that outlives the state).
pub const MeterState = struct {
    live: MeterStore = .{},
    audio_copy: MeterStore = .{},
    seq: std.atomic.Value(u32) = .init(0),
    dirty: std.atomic.Value(bool) = .init(false),

    /// Audio thread: the map to use this block.
    pub fn map(self: *const MeterState) MeterMap {
        return self.audio_copy.map();
    }

    /// UI thread: the authoritative (possibly not-yet-adopted) map, for
    /// drawing and editing.
    pub fn liveMap(self: *const MeterState) MeterMap {
        return self.live.map();
    }

    /// UI thread: direct access to the live store for building a map
    /// in place (project load). Pair with `commitImmediate`.
    pub fn liveStore(self: *MeterState) *MeterStore {
        return &self.live;
    }

    /// UI/generator thread: replace the live map and mark it for adoption
    /// at the next bar boundary.
    pub fn stage(self: *MeterState, points: []const MeterPoint) void {
        _ = self.seq.fetchAdd(1, .release); // -> odd: write in progress
        self.live.clear();
        for (points) |p| self.live.append(p);
        if (self.live.len == 0) self.live.reset();
        _ = self.seq.fetchAdd(1, .release); // -> even: stable
        self.dirty.store(true, .release);
    }

    /// Audio thread: adopt a pending edit, only safe to call at a bar
    /// boundary (or when not rendering). No-op when nothing is pending.
    pub fn adoptIfPending(self: *MeterState) void {
        if (!self.dirty.load(.acquire)) return;
        const s1 = self.seq.load(.acquire);
        if (s1 & 1 != 0) return; // writer mid-update; try next boundary
        var tmp: MeterStore = undefined;
        const n = self.live.len;
        var i: usize = 0;
        while (i < n and i < MAX_POINTS) : (i += 1) tmp.buf[i] = self.live.buf[i];
        if (self.seq.load(.acquire) != s1) return; // torn; keep old copy
        // Validated — publish into the audio copy.
        i = 0;
        while (i < n) : (i += 1) self.audio_copy.buf[i] = tmp.buf[i];
        self.audio_copy.len = n;
        self.dirty.store(false, .release);
    }

    /// UI thread: edit one live point's numerator/denominator in place
    /// (seqlock-bracketed) and mark it pending for adoption at the next
    /// bar boundary. No-op if `index` is out of range.
    pub fn editMeterAt(self: *MeterState, index: usize, numerator: u8, denominator: u8) void {
        _ = self.seq.fetchAdd(1, .release); // -> odd
        if (index < self.live.len) {
            self.live.buf[index].numerator = numerator;
            self.live.buf[index].denominator = denominator;
        }
        _ = self.seq.fetchAdd(1, .release); // -> even
        self.dirty.store(true, .release);
    }

    /// Non-realtime: force the audio copy to match live immediately.
    /// Caller guarantees no concurrent render (load / stopped).
    pub fn commitImmediate(self: *MeterState) void {
        var i: usize = 0;
        while (i < self.live.len) : (i += 1) self.audio_copy.buf[i] = self.live.buf[i];
        self.audio_copy.len = self.live.len;
        self.dirty.store(false, .release);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "4/4 bar length and bar starts" {
    var pts = MeterMap.singlePoint(4, 4);
    const m = MeterMap{ .points = &pts };
    try testing.expectEqual(@as(f64, 4.0), m.barLenBeats(0));
    try testing.expectEqual(@as(f64, 0.0), m.barStartBeat(0));
    try testing.expectEqual(@as(f64, 12.0), m.barStartBeat(3));
}

test "7/8 bar spans 3.5 quarter-beats" {
    var pts = MeterMap.singlePoint(7, 8);
    const m = MeterMap{ .points = &pts };
    try testing.expectEqual(@as(f64, 3.5), m.barLenBeats(0));
    try testing.expectEqual(@as(f64, 7.0), m.barStartBeat(2));
}

test "5/16 bar spans 1.25 quarter-beats" {
    var pts = MeterMap.singlePoint(5, 16);
    const m = MeterMap{ .points = &pts };
    try testing.expectEqual(@as(f64, 1.25), m.barLenBeats(0));
}

test "beatToBarPos in 4/4: bar, beat, tick" {
    var pts = MeterMap.singlePoint(4, 4);
    const m = MeterMap{ .points = &pts };

    try testing.expectEqual(BarPos{ .bar = 0, .beat = 0, .tick = 0 }, m.beatToBarPos(0.0));
    try testing.expectEqual(BarPos{ .bar = 3, .beat = 1, .tick = 0 }, m.beatToBarPos(13.0));
    // Quarter-beat 0.25 → quarter of the way into beat 0 → 240 ticks.
    try testing.expectEqual(BarPos{ .bar = 0, .beat = 0, .tick = 240 }, m.beatToBarPos(0.25));
    // Negative clamps to origin.
    try testing.expectEqual(BarPos{ .bar = 0, .beat = 0, .tick = 0 }, m.beatToBarPos(-5.0));
}

test "beatToBarPos in 7/8: eighth-note beats" {
    var pts = MeterMap.singlePoint(7, 8);
    const m = MeterMap{ .points = &pts };
    // One bar = 3.5 quarter-beats = 7 eighth-notes.
    try testing.expectEqual(BarPos{ .bar = 0, .beat = 0, .tick = 0 }, m.beatToBarPos(0.0));
    try testing.expectEqual(BarPos{ .bar = 0, .beat = 1, .tick = 0 }, m.beatToBarPos(0.5));
    try testing.expectEqual(BarPos{ .bar = 1, .beat = 0, .tick = 0 }, m.beatToBarPos(3.5));
    try testing.expectEqual(BarPos{ .bar = 1, .beat = 1, .tick = 0 }, m.beatToBarPos(4.0));
}

test "variable meter: 4/4 then 7/8 prefix-sum and seek" {
    const pts = [_]MeterPoint{
        .{ .start_bar = 0, .numerator = 4, .denominator = 4 },
        .{ .start_bar = 4, .numerator = 7, .denominator = 8 },
    };
    const m = MeterMap{ .points = &pts };

    // Bars 0..3 are 4 beats each → bar 4 starts at 16.0.
    try testing.expectEqual(@as(f64, 16.0), m.barStartBeat(4));
    // Bar 5 starts one 7/8 bar (3.5) later.
    try testing.expectEqual(@as(f64, 19.5), m.barStartBeat(5));

    // First beat of the first 7/8 bar.
    try testing.expectEqual(BarPos{ .bar = 4, .beat = 0, .tick = 0 }, m.beatToBarPos(16.0));
    // Last eighth of bar 4 (3.0 q into the bar = 6th eighth, 0-based 6).
    try testing.expectEqual(BarPos{ .bar = 4, .beat = 6, .tick = 0 }, m.beatToBarPos(19.0));
    // Downbeat of bar 5.
    try testing.expectEqual(BarPos{ .bar = 5, .beat = 0, .tick = 0 }, m.beatToBarPos(19.5));
}

test "barInfoAtBeat reports bar, start, and length" {
    const pts = [_]MeterPoint{
        .{ .start_bar = 0, .numerator = 4, .denominator = 4 },
        .{ .start_bar = 4, .numerator = 7, .denominator = 8 },
    };
    const m = MeterMap{ .points = &pts };

    // Mid bar 2 (4/4): starts at 8.0, length 4.0.
    const a = m.barInfoAtBeat(9.5);
    try testing.expectEqual(@as(u32, 2), a.bar);
    try testing.expectEqual(@as(f64, 8.0), a.bar_start_beat);
    try testing.expectEqual(@as(f64, 4.0), a.bar_len_beats);

    // Mid the first 7/8 bar: bar 4 starts at 16.0, length 3.5.
    const b = m.barInfoAtBeat(17.0);
    try testing.expectEqual(@as(u32, 4), b.bar);
    try testing.expectEqual(@as(f64, 16.0), b.bar_start_beat);
    try testing.expectEqual(@as(f64, 3.5), b.bar_len_beats);
}

test "MeterState: stage is not visible to audio until adopted" {
    var st: MeterState = .{};
    // Default audio map is 4/4.
    try testing.expectEqual(@as(f64, 4.0), st.map().barLenBeats(0));

    // Stage a 7/8 map. The audio map must NOT change yet.
    st.stage(&.{.{ .start_bar = 0, .numerator = 7, .denominator = 8 }});
    try testing.expectEqual(@as(f64, 4.0), st.map().barLenBeats(0));
    // The live (authoritative) map reflects the edit immediately.
    try testing.expectEqual(@as(f64, 3.5), st.liveMap().barLenBeats(0));

    // Adopt (as the engine does at a bar boundary) — now audio sees it.
    st.adoptIfPending();
    try testing.expectEqual(@as(f64, 3.5), st.map().barLenBeats(0));

    // Idempotent: a second adopt with nothing pending is a no-op.
    st.adoptIfPending();
    try testing.expectEqual(@as(f64, 3.5), st.map().barLenBeats(0));
}

test "MeterState: editMeterAt changes a point, visible after adopt" {
    var st: MeterState = .{};
    st.editMeterAt(0, 5, 8); // 5/8
    // Authoritative map reflects it; audio map waits for adopt.
    try testing.expectEqual(@as(f64, 2.5), st.liveMap().barLenBeats(0));
    try testing.expectEqual(@as(f64, 4.0), st.map().barLenBeats(0));
    st.adoptIfPending();
    try testing.expectEqual(@as(f64, 2.5), st.map().barLenBeats(0));
}

test "MeterState: commitImmediate adopts without a boundary" {
    var st: MeterState = .{};
    st.stage(&.{
        .{ .start_bar = 0, .numerator = 5, .denominator = 4 },
        .{ .start_bar = 2, .numerator = 3, .denominator = 4 },
    });
    st.commitImmediate();
    const m = st.map();
    try testing.expectEqual(@as(f64, 5.0), m.barLenBeats(0));
    try testing.expectEqual(@as(f64, 3.0), m.barLenBeats(2));
}

test "segmentForBar picks the governing point" {
    const pts = [_]MeterPoint{
        .{ .start_bar = 0, .numerator = 4, .denominator = 4 },
        .{ .start_bar = 4, .numerator = 7, .denominator = 8 },
        .{ .start_bar = 8, .numerator = 5, .denominator = 4 },
    };
    const m = MeterMap{ .points = &pts };
    try testing.expectEqual(@as(u8, 4), m.segmentForBar(0).numerator);
    try testing.expectEqual(@as(u8, 4), m.segmentForBar(3).numerator);
    try testing.expectEqual(@as(u8, 7), m.segmentForBar(4).numerator);
    try testing.expectEqual(@as(u8, 7), m.segmentForBar(7).numerator);
    try testing.expectEqual(@as(u8, 5), m.segmentForBar(8).numerator);
    try testing.expectEqual(@as(u8, 5), m.segmentForBar(100).numerator);
}
