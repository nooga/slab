//! Clip + Note data model. Clips are either MIDI-like *note* clips (a list
//! of notes fed to the track's instrument) or *audio* clips (a reference
//! into the host AudioPool, mixed directly into the track on the audio
//! thread). Heap-allocated — both the clip list on a track and the note
//! list on a clip grow dynamically.
//!
//! All data here is UI-thread-owned. The audio thread reads a frozen
//! snapshot (see snapshot.zig) — never these structs directly.

const std = @import("std");

pub const MAX_NAME = 32;

/// Whether a clip carries note data (driving the track instrument) or
/// references decoded audio in the pool (mixed in directly).
pub const ClipKind = enum(u8) { note, audio };

/// An audio clip's reference into the host AudioPool plus its clip-local
/// playback parameters. Speed/warp and a trim window land in Phase D; for
/// now an audio clip plays its source from the top at native rate.
pub const AudioRef = struct {
    /// Index into the document's AudioPool. Stable for the doc lifetime.
    source: u32 = 0,
    /// Linear playback gain applied on the audio thread.
    gain: f32 = 1.0,
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
    }

    pub fn clone(self: *const Clip, alloc: std.mem.Allocator) !Clip {
        var c = Clip.init(self.name(), self.start_beat, self.length_beats);
        c.selected = self.selected;
        c.kind = self.kind;
        c.audio = self.audio;
        errdefer c.deinit(alloc);
        try c.notes.appendSlice(alloc, self.notes.items);
        return c;
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
