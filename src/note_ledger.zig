//! The clip notes a track is sounding (audio thread): each with the id its
//! note-on carried, so its note-off carries the same one, and with where
//! it starts and ends, so an edit under the playhead can't strand it. A
//! note moved, retuned, shortened behind the playhead or deleted (or its
//! clip moved, trimmed, muted or deleted) ends at once; one that only
//! moved in the snapshot's list keeps its id. Nothing allocates.

const std = @import("std");
const snap_mod = @import("snapshot.zig");

/// Notes one track can sound at once; past it, new ones don't start.
pub const CAP = 256;

comptime {
    // Where a note was found fits `Entry.si` and `Entry.ci`.
    std.debug.assert(snap_mod.MAX_NOTES_PER_TRACK <= std.math.maxInt(u16) + 1);
    std.debug.assert(snap_mod.MAX_CLIPS_PER_TRACK <= std.math.maxInt(u8) + 1);
}
/// Clip note ids cycle below this; the arp's start here (arp.ID_BASE),
/// and held keys are -1.
pub const ID_LIMIT: i32 = 1 << 24;

pub const Entry = struct {
    /// Song beats: where the note starts (with the pitch, what finds it
    /// again in an edited snapshot) and where it ends now.
    on: f64,
    off: f64,
    id: i32,
    /// Where it was last found: its clip, and its index in the snapshot.
    si: u16,
    ci: u8,
    pitch: u8,
    vel: u8,
};

/// A note-off due this block: at sample `at`, for the note at snapshot
/// index `si` (the order the sequencer's note-offs keep). `found`: the note
/// is still there, at `si` (its expression runs up to its end).
pub const End = struct { si: u16, at: u32, id: i32, pitch: u8, found: bool };

pub const Ledger = struct {
    items: [CAP]Entry = undefined,
    n: usize = 0,
    next_id: i32 = 0,

    pub fn clear(self: *Ledger) void {
        self.n = 0;
    }

    /// Clear, and ids from 0 again (a render from the top gives the same).
    pub fn reset(self: *Ledger) void {
        self.n = 0;
        self.next_id = 0;
    }

    pub fn sounding(self: *const Ledger) []const Entry {
        return self.items[0..self.n];
    }

    pub fn newId(self: *Ledger) i32 {
        const id = self.next_id;
        self.next_id = if (id + 1 >= ID_LIMIT) 0 else id + 1;
        return id;
    }

    /// Record a note that started; false (and nothing recorded) when full.
    pub fn add(self: *Ledger, e: Entry) bool {
        if (self.n == CAP) return false;
        self.items[self.n] = e;
        self.n += 1;
        return true;
    }

    /// Whether `id` was given out after `mark` (an earlier `next_id`).
    pub fn newSince(self: *const Ledger, mark: i32, id: i32) bool {
        return @mod(id - mark, ID_LIMIT) < @mod(self.next_id - mark, ID_LIMIT);
    }

    /// The id of the sounding note at snapshot index `si`, if it sounds.
    pub fn idOf(self: *const Ledger, si: u32) ?i32 {
        for (self.items[0..self.n]) |e| if (e.si == si) return e.id;
        return null;
    }

    /// The notes to end this block, written to `ends` sorted by snapshot
    /// index, and forgotten. Each is looked up in `snap` first (an edit may
    /// have moved it in the list, changed its end, or taken it away):
    ///   - gone, or its end moved behind `beat_start`: at once;
    ///   - `jumped` (a seek, a loop wrap, a stop): at once, unless `chase`
    ///     finds it sounding at `beat_start` with `chase_min` samples left,
    ///     as a chased note would start (`keep`);
    ///   - ending in (beat_start, beat_end]: where it ends.
    pub fn due(
        self: *Ledger,
        snap: *const snap_mod.TrackSnapshot,
        beat_start: f64,
        beat_end: f64,
        samples_per_beat: f64,
        frames: u32,
        jumped: bool,
        chase: bool,
        chase_min: f64,
        ends: *[CAP]End,
    ) usize {
        var k: usize = 0;
        var i: usize = 0;
        while (i < self.n) {
            const e = &self.items[i];
            var at: ?u32 = null;
            const found = locate(e, snap);
            if (!found) {
                at = 0;
            } else {
                const keep = chase and e.on < beat_start and e.off > beat_start and
                    (e.off - beat_start) * samples_per_beat >= chase_min;
                if (jumped and !keep) at = 0 else if (e.off <= beat_start) at = 0 else if (e.off <= beat_end) at = offsetIn(e.off - beat_start, samples_per_beat, frames);
            }
            if (at) |fo| {
                // Sorted by snapshot index as it goes (a handful at most).
                var j = k;
                while (j > 0 and ends[j - 1].si > e.si) : (j -= 1) ends[j] = ends[j - 1];
                ends[j] = .{ .si = e.si, .at = fo, .id = e.id, .pitch = e.pitch, .found = found };
                k += 1;
                self.items[i] = self.items[self.n - 1];
                self.n -= 1;
            } else i += 1;
        }
        return k;
    }
};

/// Same rounding as the sequencer's offsets (engine.blockOffset).
fn offsetIn(beats: f64, samples_per_beat: f64, frames: u32) u32 {
    const raw = beats * samples_per_beat;
    var fo: u32 = 0;
    if (raw > 0) fo = @intFromFloat(@round(raw));
    return @min(fo, frames - 1);
}

/// Point `e` at its note in `snap` and refresh where it ends; false when
/// the note is gone. Where it last was is checked first (no edit: the same
/// place), then the whole snapshot (an edit moved it in the list).
fn locate(e: *Entry, snap: *const snap_mod.TrackSnapshot) bool {
    if (e.ci < snap.clip_count) {
        const clip = snap.clips[e.ci];
        if (e.si >= clip.notes_start and e.si - clip.notes_start < clip.notes_count and
            refresh(e, clip, snap.notes[e.si])) return true;
    }
    for (snap.clips[0..snap.clip_count], 0..) |clip, ci| {
        for (snap.notes[clip.notes_start..][0..clip.notes_count], clip.notes_start..) |note, si| {
            if (!refresh(e, clip, note)) continue;
            e.ci = @intCast(ci);
            e.si = @intCast(si);
            return true;
        }
    }
    return false;
}

/// Whether `note` in `clip` is the note `e` started (same pitch, same
/// start) and still plays; if so, `e` takes its end, as the sequencer
/// computes it (trimmed to the clip).
fn refresh(e: *Entry, clip: snap_mod.ClipHeader, note: snap_mod.NoteSnap) bool {
    if (note.pitch != e.pitch) return false;
    const on = clip.start_beat + note.start_beat;
    if (on != e.on or note.start_beat >= clip.length_beats) return false;
    const off = @min(on + note.length_beats, clip.start_beat + clip.length_beats);
    if (off <= on) return false;
    e.off = off;
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn oneClip(notes: []const [3]f64) snap_mod.TrackSnapshot {
    var s = snap_mod.TrackSnapshot{};
    s.clips[0] = .{ .start_beat = 0, .length_beats = 16, .notes_start = 0, .notes_count = @intCast(notes.len) };
    s.clip_count = 1;
    for (notes, 0..) |n, i| s.notes[i] = .{ .start_beat = n[0], .length_beats = n[1], .pitch = @intFromFloat(n[2]), .velocity = 100 };
    s.note_count = @intCast(notes.len);
    return s;
}

test "ledger: a note keeps its id when an edit moves it in the list, and ends where it now ends" {
    var l = Ledger{};
    // Started as index 1, after a 36 at index 0.
    try testing.expect(l.add(.{ .on = 1, .off = 3, .id = l.newId(), .si = 1, .ci = 0, .pitch = 48, .vel = 100 }));
    var ends: [CAP]End = undefined;
    // The first note goes: the 48 is index 0 now, and was lengthened.
    const b = oneClip(&.{.{ 1, 3, 48 }});
    try testing.expectEqual(@as(usize, 0), l.due(&b, 2, 2.5, 100, 50, false, false, 0, &ends));
    try testing.expectEqual(@as(u16, 0), l.items[0].si);
    try testing.expectEqual(@as(f64, 4), l.items[0].off);
    try testing.expectEqual(@as(usize, 1), l.due(&b, 3.75, 4.25, 100, 50, false, false, 0, &ends));
    try testing.expectEqual(@as(i32, 0), ends[0].id);
    try testing.expectEqual(@as(u32, 25), ends[0].at);
    try testing.expectEqual(@as(usize, 0), l.n);
}

test "ledger: deleted, retuned, moved or shortened-behind notes end at once; a jump ends all but what chase keeps" {
    var ends: [CAP]End = undefined;
    const base = oneClip(&.{ .{ 1, 4, 48 }, .{ 1, 4, 52 }, .{ 1, 4, 55 }, .{ 1, 4, 60 } });
    var l = Ledger{};
    for (base.notes[0..4], 0..) |n, i| _ = l.add(.{ .on = 1, .off = 5, .id = @intCast(i), .si = @intCast(i), .ci = 0, .pitch = n.pitch, .vel = 100 });
    // 48 deleted, 52 retuned to 53, 55 moved to 1.5, 60 shortened to end at 1.5.
    const edited = oneClip(&.{ .{ 1, 4, 53 }, .{ 1.5, 4, 55 }, .{ 1, 0.5, 60 } });
    try testing.expectEqual(@as(usize, 4), l.due(&edited, 2, 2.5, 100, 50, false, false, 0, &ends));
    var ids: u32 = 0;
    for (ends[0..4], 0..) |e, i| {
        try testing.expectEqual(@as(u32, 0), e.at);
        if (i > 0) try testing.expect(ends[i - 1].si <= e.si);
        ids |= @as(u32, 1) << @intCast(e.id);
    }
    try testing.expectEqual(@as(u32, 0b1111), ids);
    try testing.expectEqual(@as(usize, 0), l.n);

    // A jump: the note under the new position carries on, the other ends.
    var m = Ledger{};
    const two = oneClip(&.{ .{ 0, 8, 40 }, .{ 2, 1, 41 } });
    _ = m.add(.{ .on = 0, .off = 8, .id = 0, .si = 0, .ci = 0, .pitch = 40, .vel = 100 });
    _ = m.add(.{ .on = 2, .off = 3, .id = 1, .si = 1, .ci = 0, .pitch = 41, .vel = 100 });
    try testing.expectEqual(@as(usize, 1), m.due(&two, 6, 6.5, 100, 50, true, true, 100, &ends));
    try testing.expectEqual(@as(i32, 1), ends[0].id);
    try testing.expectEqual(@as(usize, 1), m.n);
    // A stop (no chase): everything ends.
    try testing.expectEqual(@as(usize, 1), m.due(&two, 6.5, 6.5, 100, 50, true, false, 240, &ends));
    try testing.expectEqual(@as(usize, 0), m.n);
}

test "ledger: ids cycle below the arp's" {
    var l = Ledger{ .next_id = ID_LIMIT - 1 };
    try testing.expectEqual(ID_LIMIT - 1, l.newId());
    try testing.expectEqual(@as(i32, 0), l.newId());
}
