//! Clip + Note data model. Clips are either MIDI-like *note* clips (a list
//! of notes fed to the track's instrument) or *audio* clips (a reference
//! into the host AudioPool, mixed directly into the track on the audio
//! thread). Heap-allocated — both the clip list on a track and the note
//! list on a clip grow dynamically.
//!
//! All data here is UI-thread-owned. The audio thread reads a frozen
//! snapshot (see snapshot.zig) — never these structs directly.

const std = @import("std");
const automation = @import("automation.zig");
const warp = @import("warp.zig");

pub const MAX_NAME = 32;

/// Whether a clip carries note data (driving the track instrument) or
/// references decoded audio in the pool (mixed in directly).
pub const ClipKind = enum(u8) { note, audio };

/// An audio clip's reference into the host AudioPool plus its clip-local
/// playback parameters.
///
/// The clip plays a *window* of the source — `[start_sec, start_sec+dur_sec)`
/// in source seconds — at native rate (no time-stretch). The window is the
/// bpm-independent source of truth; the clip's `length_beats` is *derived*
/// from it at the current tempo (`dur_sec * bpm / 60`), so changing the
/// project tempo rescales the clip against the bar grid and splitting carves
/// the window in two. A *warped* clip (docs/29) instead maps its own
/// beats to source seconds through `Clip.warp_markers`: its length is in
/// beats and it follows the tempo; the window fields are unused then.
pub const AudioRef = struct {
    /// Index into the document's AudioPool. Stable for the doc lifetime.
    source: u32 = 0,
    /// Linear playback gain applied on the audio thread.
    gain: f32 = 1.0,
    /// Offset into the source (seconds) where this clip starts reading.
    start_sec: f64 = 0,
    /// Length of the played window in source seconds (tempo-independent).
    dur_sec: f64 = 0,
    /// Linear fade-in / fade-out lengths, in source seconds (0 = none).
    fade_in_sec: f64 = 0,
    fade_out_sec: f64 = 0,
    /// Plays the window end to start. The window stays the source region
    /// `[start_sec, start_sec+dur_sec)`; fades and gain stay in clip time.
    reversed: bool = false,
    /// Warped (docs/29 §The model): content beats through the markers.
    warp: bool = false,
    mode: warp.Mode = .tape,
    /// The content beat at the clip's start (the trimmed-off head).
    offset_beats: f64 = 0,
    /// BEATS (docs/29 §BEATS): where it slices, what fills a gap, and how
    /// much of each slice sounds before it fades (100: all of it).
    preserve: warp.Preserve = .hits,
    gap: warp.Gap = .cut,
    decay: u8 = 100,
    /// Pitch apart from time (docs/29 §The algorithms), in every mode but
    /// TAPE: semitones and cents.
    transpose: i8 = 0,
    fine: i8 = 0,
    /// VOICE's grain in ms (10–80), SMEAR's window (stretch.SMEAR_SIZES
    /// index: 0.34, 0.68, 1.37, 2.73 s).
    grain_ms: u8 = 40,
    smear_size: u8 = 1,

    pub fn pitch(self: AudioRef) f64 {
        if (self.mode == .tape) return 1;
        return std.math.pow(f64, 2, (@as(f64, @floatFromInt(self.transpose)) + @as(f64, @floatFromInt(self.fine)) / 100) / 12);
    }
};

pub const Note = struct {
    /// MIDI note number (0..127).
    pitch: u8,
    /// Start time within the clip, in beats.
    start_beat: f64,
    /// Length in beats.
    length_beats: f64,
    /// MIDI velocity (0..127).
    velocity: u8 = 100,
    /// Transient UI flag — not persisted, not consumed by the engine.
    selected: bool = false,
    /// Pitch expression (docs/22 §Note expression): up to MAX_BEND points,
    /// beats from the note's start, values in semitones from `pitch`.
    /// Inline so a Note stays a plain value that copies with clipboards.
    bend: [MAX_BEND]automation.Point = undefined,
    bend_n: u8 = 0,
    /// Pressure, slide and gain curves (ExprDim order).
    dims: [EXPR_DIMS]Curve = [_]Curve{.{}} ** EXPR_DIMS,

    pub fn dim(self: *Note, d: ExprDim) *Curve {
        return &self.dims[@intFromEnum(d)];
    }

    pub fn dimConst(self: *const Note, d: ExprDim) *const Curve {
        return &self.dims[@intFromEnum(d)];
    }

    /// Whether the note carries any expression at all.
    pub fn hasExpression(self: *const Note) bool {
        if (self.bend_n > 0) return true;
        for (self.dims) |cv| if (cv.n > 0) return true;
        return false;
    }

    pub fn bendPoints(self: *const Note) []const automation.Point {
        return self.bend[0..self.bend_n];
    }

    pub fn bendSlice(self: *Note) []automation.Point {
        return self.bend[0..self.bend_n];
    }

    /// Semitones from `pitch` at `beat` into the note (0 without a bend).
    pub fn bendAt(self: *const Note, beat: f64) f32 {
        if (self.bend_n == 0) return 0;
        return automation.eval(self.bendPoints(), beat);
    }

    /// Add a bend point, keeping order. False when full.
    pub fn addBend(self: *Note, p: automation.Point) bool {
        if (self.bend_n >= MAX_BEND) return false;
        var q = p;
        q.value = std.math.clamp(q.value, -MAX_BEND_SEMIS, MAX_BEND_SEMIS);
        const at = if (automation.segmentIndex(self.bendPoints(), q.beat)) |i| i + 1 else 0;
        var i: usize = self.bend_n;
        while (i > at) : (i -= 1) self.bend[i] = self.bend[i - 1];
        self.bend[at] = q;
        self.bend_n += 1;
        return true;
    }

    pub fn removeBend(self: *Note, i: usize) void {
        if (i >= self.bend_n) return;
        var j = i;
        while (j + 1 < self.bend_n) : (j += 1) self.bend[j] = self.bend[j + 1];
        self.bend_n -= 1;
    }

    pub fn clearBend(self: *Note) void {
        self.bend_n = 0;
    }
};

pub const MAX_BEND = 8;

/// Per-note expression beyond pitch (docs/22): pressure and slide 0..1,
/// gain in dB.
pub const ExprDim = enum(u8) { pressure, slide, gain };
pub const EXPR_DIMS = 3;

pub const DimRange = struct { lo: f32, hi: f32, rest: f32 };

pub fn dimRange(d: ExprDim) DimRange {
    return switch (d) {
        .pressure => .{ .lo = 0, .hi = 1, .rest = 0.5 },
        .slide => .{ .lo = 0, .hi = 1, .rest = 0 },
        .gain => .{ .lo = -48, .hi = 12, .rest = 0 },
    };
}

/// One expression curve: up to MAX_BEND points, beats from the note's
/// start, inline so notes stay plain values.
pub const Curve = struct {
    pts: [MAX_BEND]automation.Point = undefined,
    n: u8 = 0,

    pub fn points(self: *const Curve) []const automation.Point {
        return self.pts[0..self.n];
    }

    pub fn slice(self: *Curve) []automation.Point {
        return self.pts[0..self.n];
    }

    /// The curve at `beat`, or `rest` without points.
    pub fn at(self: *const Curve, beat: f64, rest: f32) f32 {
        if (self.n == 0) return rest;
        return automation.eval(self.points(), beat);
    }

    /// Add a point in order, clamped to [lo, hi]. False when full.
    pub fn add(self: *Curve, p: automation.Point, lo: f32, hi: f32) bool {
        if (self.n >= MAX_BEND) return false;
        var q = p;
        q.value = std.math.clamp(q.value, lo, hi);
        const at_i = if (automation.segmentIndex(self.points(), q.beat)) |i| i + 1 else 0;
        var i: usize = self.n;
        while (i > at_i) : (i -= 1) self.pts[i] = self.pts[i - 1];
        self.pts[at_i] = q;
        self.n += 1;
        return true;
    }
};
/// Bend range, fixed (docs/22): enough to fold a wide chord onto one note.
pub const MAX_BEND_SEMIS: f32 = 48;

/// The next clip id (`Clip.uid`). UI thread.
pub var next_uid: u32 = 1;

/// A clip with id `uid` exists: later fresh ids stay above it.
pub fn claimUid(uid: u32) void {
    if (uid >= next_uid) next_uid = uid + 1;
}

/// How a bounced clip was made (docs/27 §Provenance): the clips it was
/// rendered from, by id, how, and a fingerprint of everything the render
/// depended on (recipe.zig). Fresh while the fingerprint still matches.
pub const Recipe = struct {
    pub const MAX_SOURCES = 32;
    sources: [MAX_SOURCES]u32 = undefined,
    source_count: u8 = 0,
    /// bounce_dialog.Tap.
    tap: u8 = 1,
    tail_auto: bool = true,
    tail_sec: f32 = 2,
    hash: u64 = 0,
    /// The fingerprint no longer matches (transient; recipe.zig checks).
    stale: bool = false,

    pub fn ids(self: *const Recipe) []const u32 {
        return self.sources[0..self.source_count];
    }
};

pub const Clip = struct {
    /// Start time on the track timeline, in beats.
    start_beat: f64,
    /// Length of the clip in beats.
    length_beats: f64,
    /// Display name (null-terminated within name_buf[0..name_len]).
    name_buf: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    /// Transient UI flag — not persisted, not consumed by the engine.
    selected: bool = false,
    /// Muted: kept on the timeline, drawn dimmed, but not played: no notes,
    /// no audio, no clip lanes (docs/27 §The new track and the originals).
    muted: bool = false,
    /// note vs audio. `notes` is meaningful only for `.note`; `audio`
    /// only for `.audio`.
    kind: ClipKind = .note,
    audio: AudioRef = .{},
    notes: std.ArrayList(Note) = .empty,
    /// Clip automation lanes (docs/22): beats from the clip's start; they
    /// move and copy with the clip and override the track's lane for the
    /// same target while the clip plays.
    lanes: std.ArrayList(automation.Lane) = .empty,
    /// A warped audio clip's map (docs/29): source seconds pinned to
    /// content beats, strictly increasing, two or more.
    warp_markers: std.ArrayList(warp.Marker) = .empty,
    /// Stable id: kept by save, load and undo, fresh for a copy. A bounce's
    /// recipe finds its sources by it.
    uid: u32 = 0,
    /// A bounced clip's recipe (docs/27 §Provenance).
    recipe: ?Recipe = null,

    pub fn init(display_name: []const u8, start_beat: f64, length_beats: f64) Clip {
        var c = Clip{
            .start_beat = start_beat,
            .length_beats = length_beats,
            .uid = next_uid,
        };
        next_uid += 1;
        const n = @min(display_name.len, MAX_NAME);
        @memcpy(c.name_buf[0..n], display_name[0..n]);
        c.name_len = @intCast(n);
        return c;
    }

    /// An audio clip referencing pool `source`. Length is the caller's
    /// responsibility (typically the source duration at project tempo).
    pub fn initAudio(display_name: []const u8, start_beat: f64, length_beats: f64, source: u32) Clip {
        var c = Clip.init(display_name, start_beat, length_beats);
        c.kind = .audio;
        c.audio = .{ .source = source };
        return c;
    }

    pub fn isAudio(self: *const Clip) bool {
        return self.kind == .audio;
    }

    pub fn deinit(self: *Clip, alloc: std.mem.Allocator) void {
        self.notes.deinit(alloc);
        self.warp_markers.deinit(alloc);
        for (self.lanes.items) |*l| l.deinit(alloc);
        self.lanes.deinit(alloc);
    }

    pub fn clone(self: *const Clip, alloc: std.mem.Allocator) !Clip {
        var c = Clip.init(self.name(), self.start_beat, self.length_beats);
        c.selected = self.selected;
        c.muted = self.muted;
        c.recipe = self.recipe;
        c.kind = self.kind;
        c.audio = self.audio;
        errdefer c.deinit(alloc);
        try c.notes.appendSlice(alloc, self.notes.items);
        try c.warp_markers.appendSlice(alloc, self.warp_markers.items);
        for (self.lanes.items) |*l| {
            var lc = try l.clone(alloc);
            c.lanes.append(alloc, lc) catch |err| {
                lc.deinit(alloc);
                return err;
            };
        }
        return c;
    }

    pub fn findLane(self: *Clip, target: automation.Target) ?*automation.Lane {
        for (self.lanes.items) |*l| if (l.target.eql(target)) return l;
        return null;
    }

    pub fn laneFor(self: *Clip, alloc: std.mem.Allocator, target: automation.Target, stepped: bool) !*automation.Lane {
        if (self.findLane(target)) |l| return l;
        try self.lanes.append(alloc, .{ .target = target, .stepped = stepped });
        return &self.lanes.items[self.lanes.items.len - 1];
    }

    pub fn removeLane(self: *Clip, alloc: std.mem.Allocator, i: usize) void {
        if (i >= self.lanes.items.len) return;
        self.lanes.items[i].deinit(alloc);
        _ = self.lanes.orderedRemove(i);
    }

    /// Split the clip's lanes at clip-relative beat `at` into `right`
    /// (whose beats restart at 0). Both halves get a point at the cut with
    /// the curve's value there, so each keeps playing what it played.
    pub fn splitLanes(self: *Clip, alloc: std.mem.Allocator, right: *Clip, at: f64) !void {
        for (self.lanes.items) |*l| {
            if (l.points.items.len == 0) continue;
            const v = l.value(at).?;
            var r = automation.Lane{ .target = l.target, .stepped = l.stepped };
            errdefer r.deinit(alloc);
            const shape_at = if (automation.segmentIndex(l.points.items, at)) |i| l.points.items[i].shape else .linear;
            try r.points.append(alloc, .{ .beat = 0, .value = v, .shape = shape_at });
            var w: usize = 0;
            for (l.points.items) |pt| {
                if (pt.beat > at) {
                    var q = pt;
                    q.beat -= at;
                    try r.points.append(alloc, q);
                } else {
                    l.points.items[w] = pt;
                    w += 1;
                }
            }
            l.points.items.len = w;
            _ = try l.insert(alloc, .{ .beat = at, .value = v });
            try right.lanes.append(alloc, r);
        }
    }

    pub fn name(self: *const Clip) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Clip, display_name: []const u8) void {
        @memset(&self.name_buf, 0);
        const n = @min(display_name.len, MAX_NAME);
        @memcpy(self.name_buf[0..n], display_name[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn endBeat(self: *const Clip) f64 {
        return self.start_beat + self.length_beats;
    }

    pub fn addNote(self: *Clip, alloc: std.mem.Allocator, note: Note) !void {
        try self.notes.append(alloc, note);
    }

    /// Delete the first note matching the predicate (returns true if
    /// one was removed).
    pub fn removeNoteAt(self: *Clip, idx: usize) void {
        _ = self.notes.orderedRemove(idx);
    }

    pub fn deselectAll(self: *Clip) void {
        for (self.notes.items) |*n| n.selected = false;
    }

    pub fn selectedCount(self: *const Clip) usize {
        var n: usize = 0;
        for (self.notes.items) |note| {
            if (note.selected) n += 1;
        }
        return n;
    }

    pub fn removeSelected(self: *Clip) void {
        var i: usize = 0;
        while (i < self.notes.items.len) {
            if (self.notes.items[i].selected) {
                _ = self.notes.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

pub const ClipRef = struct {
    track: u32,
    clip: u32,
};
