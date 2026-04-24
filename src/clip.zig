//! Clip + Note data model. MIDI-like note clips for now; audio clips
//! will be a separate variant later. Heap-allocated — both the clip
//! list on a track and the note list on a clip grow dynamically.
//!
//! All data here is UI-thread-owned. When we later feed notes to the
//! audio thread, we'll publish a frozen snapshot — for now the engine
//! ignores clips entirely.

const std = @import("std");

pub const MAX_NAME = 32;

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

    pub fn deinit(self: *Clip, alloc: std.mem.Allocator) void {
        self.notes.deinit(alloc);
    }

    pub fn name(self: *const Clip) []const u8 {
        return self.name_buf[0..self.name_len];
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
