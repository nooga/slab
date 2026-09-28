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
/// the window in two. Speed/warp lands in a later phase.
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
    /// note vs audio. `notes` is meaningful only for `.note`; `audio`
    /// only for `.audio`.
    kind: ClipKind = .note,
    audio: AudioRef = .{},
    notes: std.ArrayList(Note) = .empty,
    /// Clip automation lanes (docs/22): beats from the clip's start; they
    /// move and copy with the clip and override the track's lane for the
    /// same target while the clip plays.
    lanes: std.ArrayList(automation.Lane) = .empty,

    pub fn init(display_name: []const u8, start_beat: f64, length_beats: f64) Clip {
        var c = Clip{
            .start_beat = start_beat,
            .length_beats = length_beats,
        };
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
        for (self.lanes.items) |*l| l.deinit(alloc);
        self.lanes.deinit(alloc);
    }

    pub fn clone(self: *const Clip, alloc: std.mem.Allocator) !Clip {
        var c = Clip.init(self.name(), self.start_beat, self.length_beats);
        c.selected = self.selected;
        c.kind = self.kind;
        c.audio = self.audio;
        errdefer c.deinit(alloc);
        try c.notes.appendSlice(alloc, self.notes.items);
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
