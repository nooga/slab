//! Frozen clip/note data published by the UI thread and consumed
//! read-only by the audio thread.
//!
//! Double-buffer invariant: the UI writes to the *non-published* slot,
//! then flips the atomic index with Release ordering. The audio thread
//! reads the *published* slot with Acquire ordering and holds the pointer
//! for the duration of one renderChunk call — never across a UI publish
//! cycle. Two buffers (not three) is sufficient because miniaudio's
//! callback fires at ~1.3ms intervals while the UI publishes at ~60Hz,
//! giving the audio thread well over one block of headroom.

const automation = @import("automation.zig");
const warp = @import("warp.zig");
const stretch = @import("stretch.zig");

pub const MAX_CLIPS_PER_TRACK: usize = 64;
pub const MAX_LANES_PER_TRACK: usize = 128; // track + clip lanes
pub const MAX_AUTO_POINTS_PER_TRACK: usize = 8192;
pub const MAX_NOTES_PER_TRACK: usize = 2048;
pub const MAX_AUDIO_CLIPS_PER_TRACK: usize = 64;

pub const MAX_EXPR_POINTS_PER_TRACK: usize = 4096;
pub const MAX_WARP_POINTS_PER_TRACK: usize = 2048;

pub const NoteSnap = struct {
    start_beat: f64,
    length_beats: f64,
    pitch: u8,
    velocity: u8,
    /// Pitch bend points in `expr_points` (beats from the note's start,
    /// semitones), docs/22 §Note expression.
    expr_count: u8 = 0,
    expr_start: u32 = 0,
    /// Pressure, slide, gain curves, laid out in `expr_points` after the
    /// pitch points: dim i starts at dim_start + the counts before it.
    dim_count: [3]u8 = .{ 0, 0, 0 },
    dim_start: u32 = 0,

    pub fn hasExpression(self: NoteSnap) bool {
        return self.expr_count > 0 or self.dim_count[0] > 0 or self.dim_count[1] > 0 or self.dim_count[2] > 0;
    }

    pub fn dimPoints(self: NoteSnap, snap: *const TrackSnapshot, d: usize) []const automation.Point {
        var start = self.dim_start;
        for (self.dim_count[0..d]) |cnt| start += cnt;
        return snap.expr_points[start..][0..self.dim_count[d]];
    }
};

pub const ClipHeader = struct {
    start_beat: f64,
    length_beats: f64,
    notes_start: u32,
    notes_count: u32,
};

/// A placed audio clip, frozen for the audio thread. `data`/`len` point at
/// the pool source's decoded f64 mono buffer — valid because pool sources
/// are never freed mid-session. `data` is null when the source went
/// missing (skipped on playback).
pub const AudioClipSnap = struct {
    start_beat: f64,
    length_beats: f64,
    data: ?[*]const f64 = null,
    /// The right channel of a stereo source (`data` is then the left);
    /// null plays `data` on both sides.
    data_r: ?[*]const f64 = null,
    len: u32 = 0,
    source_rate: f64 = 0,
    /// First source sample this clip reads (= start_sec * source_rate).
    start_sample: f64 = 0,
    /// Played window length and fade lengths, in source samples.
    dur_samples: f64 = 0,
    fade_in_samples: f64 = 0,
    fade_out_samples: f64 = 0,
    gain: f32 = 1.0,
    /// Read the window from its end back to its start.
    reversed: bool = false,
    /// Warped (docs/29): content beats through `warp_points[warp_start..]`
    /// instead of the window; `reversed` then reads the source mirrored.
    warped: bool = false,
    mode: warp.Mode = .tape,
    offset_beats: f64 = 0,
    /// The track's tempo ratio (docs/28 §Polymeter and polytempo).
    rate: f64 = 1,
    warp_start: u32 = 0,
    warp_count: u32 = 0,
    /// BEATS: the source's transients in seconds (the pool's, read-only
    /// once found; null while they're being found), and its settings.
    onsets: ?[*]const f64 = null,
    onset_count: u32 = 0,
    preserve: warp.Preserve = .hits,
    gap: warp.Gap = .cut,
    decay: f32 = 1,
    /// TRANSPOSE and FINE as a ratio; the clip's id, for its stretcher.
    pitch: f64 = 1,
    uid: u32 = 0,
    grain_ms: u8 = 40,
    smear_size: u8 = 1,
};

/// A lane resolved for the audio thread: the target machine slot and its
/// control index, and a window into `auto_points` (knob space).
/// Clip lanes (docs/22 §Precedence) carry their clip's span and time their
/// points from its start; a track lane has `clip_len < 0`.
pub const LaneSnap = struct {
    kind: automation.TargetKind,
    fx_uid: u16 = 0,
    control: u16 = 0,
    points_start: u32,
    points_count: u32,
    clip_start: f64 = 0,
    clip_len: f64 = -1,
    /// A clip lane on a track with a tempo ratio: its beats run at it.
    rate: f64 = 1,

    pub fn isClip(self: LaneSnap) bool {
        return self.clip_len >= 0;
    }

    /// Whether the lane speaks at song beat `beat`, and the beat on its
    /// own time axis.
    pub fn localBeat(self: LaneSnap, beat: f64) ?f64 {
        if (!self.isClip()) return beat;
        if (beat < self.clip_start or beat >= self.clip_start + self.clip_len) return null;
        return (beat - self.clip_start) * self.rate;
    }
};

/// What a machine sees of its track's lanes (`MachineCtx.automation`).
/// `cursors` is the track's audio-thread-owned per-lane segment cursor.
pub const AutoView = struct {
    snap: *const TrackSnapshot,
    cursors: *[MAX_LANES_PER_TRACK]u32,
    kind: automation.TargetKind,
    fx_uid: u16 = 0,

    /// Whether any lane targets this machine (the machine then renders in
    /// sub-blocks so each chunk gets fresh values).
    pub fn any(self: *const AutoView) bool {
        for (self.snap.lanes[0..self.snap.lane_count]) |l| {
            if (self.matches(l)) return true;
        }
        return false;
    }

    pub fn matches(self: *const AutoView, l: LaneSnap) bool {
        return l.kind == self.kind and (self.kind != .fx or l.fx_uid == self.fx_uid);
    }

    pub fn points(self: *const AutoView, l: LaneSnap) []const automation.Point {
        return self.snap.auto_points[l.points_start..][0..l.points_count];
    }
};

/// A track's own time (docs/28 §Polymeter and polytempo): a meter of its
/// own (num 0: the song's), and a tempo ratio p:q, its beats running p/q
/// as fast as the song's from each clip's start.
pub const TrackTime = struct {
    num: u8 = 0,
    den: u8 = 4,
    p: u8 = 1,
    q: u8 = 1,

    pub fn rate(t: TrackTime) f64 {
        return @as(f64, @floatFromInt(t.p)) / @as(f64, @floatFromInt(@max(1, t.q)));
    }

    pub fn hasMeter(t: TrackTime) bool {
        return t.num > 0;
    }

    pub fn isDefault(t: TrackTime) bool {
        return t.num == 0 and t.p == t.q;
    }

    pub fn eql(a: TrackTime, b: TrackTime) bool {
        return a.num == b.num and a.den == b.den and a.p == b.p and a.q == b.q;
    }
};

/// A frozen track's audio (docs/28 §Freeze): its instrument and inserts
/// rendered from the song's start, played instead of them.
pub const FrozenSnap = struct {
    data: [*]const f64,
    /// The right channel; null plays `data` on both sides.
    data_r: ?[*]const f64 = null,
    len: u32,
    /// Source samples per engine sample.
    step: f64 = 1,
};

pub const TrackSnapshot = struct {
    frozen: ?FrozenSnap = null,
    /// The track's own meter and tempo ratio (docs/28 §Polymeter and
    /// polytempo), for what its machines see.
    time: TrackTime = .{},
    clips: [MAX_CLIPS_PER_TRACK]ClipHeader = undefined,
    clip_count: u32 = 0,
    notes: [MAX_NOTES_PER_TRACK]NoteSnap = undefined,
    note_count: u32 = 0,
    audio_clips: [MAX_AUDIO_CLIPS_PER_TRACK]AudioClipSnap = undefined,
    audio_clip_count: u32 = 0,
    lanes: [MAX_LANES_PER_TRACK]LaneSnap = undefined,
    lane_count: u32 = 0,
    auto_points: [MAX_AUTO_POINTS_PER_TRACK]automation.Point = undefined,
    auto_point_count: u32 = 0,
    expr_points: [MAX_EXPR_POINTS_PER_TRACK]automation.Point = undefined,
    expr_point_count: u32 = 0,
    warp_points: [MAX_WARP_POINTS_PER_TRACK]warp.Marker = undefined,
    warp_point_count: u32 = 0,
    /// The track's stretchers (MIX), when it has warped clips that need
    /// them; the audio thread reuses them, the track owns them.
    stretch: ?*stretch.Bank = null,

    /// Track volume or pan at `beat`, or null when no lane speaks. Lanes
    /// are published track lanes first, then clip lanes by clip start, so
    /// the last one that applies wins (docs/22 §Precedence).
    pub fn faderValue(self: *const TrackSnapshot, kind: automation.TargetKind, beat: f64, cursors: *[MAX_LANES_PER_TRACK]u32) ?f32 {
        var out: ?f32 = null;
        for (self.lanes[0..self.lane_count], 0..) |l, i| {
            if (l.kind != kind) continue;
            const lb = l.localBeat(beat) orelse continue;
            out = automation.evalCursor(self.auto_points[l.points_start..][0..l.points_count], lb, &cursors[i]);
        }
        return out;
    }
};
