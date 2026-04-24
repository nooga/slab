//! Audio engine: gathers clip notes per block, dispatches to each
//! track's machine with a MachineCtx (channel-planar audio out, sorted
//! note_in), sums to master, writes interleaved stereo to the device.
//! No allocation on the audio thread.

const std = @import("std");
const audio = @import("audio.zig");
const machine = @import("machine.zig");
const Transport = @import("transport.zig").Transport;
const Track = @import("track.zig").Track;
const snap_mod = @import("snapshot.zig");

pub const MAX_BLOCK = audio.BLOCK_FRAMES * 4;
pub const MAX_EVENTS_PER_TRACK = 128;

pub const Engine = struct {
    transport: *Transport,
    tracks: []Track,
    was_playing: bool = false,

    pub fn renderCallback(ctx: *anyopaque, out: [*]f32, frames: u32) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        self.render(out, frames);
    }

    fn render(self: *Engine, out: [*]f32, frames: u32) void {
        const n: usize = frames;
        const total = n * audio.CHANNELS;
        var out_slice = out[0..total];
        @memset(out_slice, 0);

        const playing = self.transport.isPlaying();
        if (!playing) {
            if (self.was_playing) {
                // play → stop transition: drop all sustained notes.
                for (self.tracks) |*t| {
                    t.machine.reset(t.machine.state);
                    t.setMeter(0, 0);
                }
                self.was_playing = false;
            } else {
                for (self.tracks) |*t| t.setMeter(0, 0);
            }
            return;
        }
        self.was_playing = true;

        // Chunk the callback block down to MAX_BLOCK if needed.
        var done: usize = 0;
        while (done < n) {
            const chunk = @min(MAX_BLOCK, n - done);
            self.renderChunk(
                out_slice[done * audio.CHANNELS ..][0 .. chunk * audio.CHANNELS],
                @intCast(chunk),
                self.transport.samples() + done,
            );
            done += chunk;
        }

        self.transport.advance(frames);
    }

    fn renderChunk(self: *Engine, out: []f32, frames: u32, block_start: u64) void {
        // Planar L/R scratch buffers — the machine ABI is
        // channel-planar. For our Zig machines we also hand L/R
        // slices directly to render(), so we don't have to thread
        // the full audio_out port table yet.
        var l_buf: [MAX_BLOCK]f32 = undefined;
        var r_buf: [MAX_BLOCK]f32 = undefined;

        var any_solo = false;
        for (self.tracks) |*t| {
            if (t.solo.load(.monotonic)) {
                any_solo = true;
                break;
            }
        }

        const sr = self.transport.sample_rate;
        const bpm = self.transport.bpm();
        const spb = self.transport.samplesPerBeat();
        const beat_start = self.transport.samplesToBeats(block_start);
        const beat_end = self.transport.samplesToBeats(block_start + frames);

        var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

        for (self.tracks) |*t| {
            const muted = t.mute.load(.monotonic) or (any_solo and !t.solo.load(.monotonic));
            if (muted) {
                t.setMeter(0, 0);
                continue;
            }

            const l = l_buf[0..frames];
            const r = r_buf[0..frames];
            @memset(l, 0);
            @memset(r, 0);

            // Load the snapshot pointer once per track per block.
            // See snapshot.zig for the double-buffer invariant.
            const snap = t.currentSnapshot();
            const n_events = gatherEvents(snap, beat_start, beat_end, spb, frames, &events);

            const ctx = machine.MachineCtx{
                .sample_rate = @floatFromInt(sr),
                .block_size = frames,
                .block_start = block_start,
                .tempo_bpm = @floatCast(bpm),
                .ppq_position = beat_start,
                .transport_state = .playing,
                .note_in = if (n_events > 0) @ptrCast(&events[0]) else null,
                .note_in_count = @intCast(n_events),
            };

            t.machine.render(t.machine.state, &ctx, l, r);

            const v = t.volume();
            var peak_l: f32 = 0;
            var peak_r: f32 = 0;
            var i: usize = 0;
            while (i < frames) : (i += 1) {
                const sl = l[i] * v;
                const sr2 = r[i] * v;
                out[i * 2] += sl;
                out[i * 2 + 1] += sr2;
                const al = @abs(sl);
                const ar = @abs(sr2);
                if (al > peak_l) peak_l = al;
                if (ar > peak_r) peak_r = ar;
            }
            t.setMeter(peak_l, peak_r);
        }
    }
};

fn gatherEvents(
    snap: *const snap_mod.TrackSnapshot,
    beat_start: f64,
    beat_end: f64,
    samples_per_beat: f64,
    frames: u32,
    out: *[MAX_EVENTS_PER_TRACK]machine.NoteEvent,
) usize {
    var count: usize = 0;

    for (snap.clips[0..snap.clip_count]) |clip| {
        const clip_end = clip.start_beat + clip.length_beats;
        if (clip_end <= beat_start) continue;
        if (clip.start_beat >= beat_end) continue;

        const note_slice = snap.notes[clip.notes_start..][0..clip.notes_count];
        for (note_slice) |note| {
            const abs_on = clip.start_beat + note.start_beat;
            const abs_off_raw = abs_on + note.length_beats;
            const abs_off = @min(abs_off_raw, clip_end);

            if (abs_on >= beat_start and abs_on < beat_end) {
                if (count < MAX_EVENTS_PER_TRACK) {
                    const raw_fo: f64 = (abs_on - beat_start) * samples_per_beat;
                    var fo: u32 = 0;
                    if (raw_fo > 0) fo = @intFromFloat(@round(raw_fo));
                    if (fo >= frames) fo = frames - 1;
                    out[count] = .{
                        .sample_offset = fo,
                        .kind = .note_on,
                        .channel = 0,
                        .note_id = -1,
                        .pitch = @floatFromInt(note.pitch),
                        .velocity = @as(f32, @floatFromInt(note.velocity)) / 127.0,
                    };
                    count += 1;
                }
            }
            if (abs_off > beat_start and abs_off <= beat_end) {
                if (count < MAX_EVENTS_PER_TRACK) {
                    const raw_fo: f64 = (abs_off - beat_start) * samples_per_beat;
                    var fo: u32 = 0;
                    if (raw_fo > 0) fo = @intFromFloat(@round(raw_fo));
                    if (fo >= frames) fo = frames - 1;
                    out[count] = .{
                        .sample_offset = fo,
                        .kind = .note_off,
                        .channel = 0,
                        .note_id = -1,
                        .pitch = @floatFromInt(note.pitch),
                        .velocity = 0,
                    };
                    count += 1;
                }
            }
        }
    }

    // Sort ascending by sample_offset.
    std.mem.sort(machine.NoteEvent, out[0..count], {}, struct {
        fn lt(_: void, a: machine.NoteEvent, b: machine.NoteEvent) bool {
            return a.sample_offset < b.sample_offset;
        }
    }.lt);
    return count;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeSnap(clips: []const struct {
    start: f64,
    len: f64,
    notes: []const struct { start: f64, len: f64, pitch: u8 },
}) snap_mod.TrackSnapshot {
    var s = snap_mod.TrackSnapshot{};
    for (clips) |c| {
        const ci = s.clip_count;
        s.clips[ci] = .{
            .start_beat = c.start,
            .length_beats = c.len,
            .notes_start = s.note_count,
            .notes_count = @intCast(c.notes.len),
        };
        s.clip_count += 1;
        for (c.notes) |n| {
            s.notes[s.note_count] = .{
                .start_beat = n.start,
                .length_beats = n.len,
                .pitch = n.pitch,
                .velocity = 100,
            };
            s.note_count += 1;
        }
    }
    return s;
}

test "gatherEvents: note-on and note-off in same block" {
    const spb = 48.0; // samples per beat (arbitrary)
    const frames: u32 = 96;
    // One clip [0..4], one note [0..1].
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{.{ .start = 0, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [0..2): expect note-on at beat 0 (offset 0).
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, &events);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(events[0].kind == .note_on);
    try testing.expectEqual(@as(f32, 60), events[0].pitch);
    try testing.expectEqual(@as(u32, 0), events[0].sample_offset);
}

test "gatherEvents: note-off fires when note ends" {
    const spb = 48.0;
    const frames: u32 = 96;
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{.{ .start = 0, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [1..3): note-off at beat 1 = sample offset 0.
    const n = gatherEvents(&snap, 1.0, 3.0, spb, frames, &events);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(events[0].kind == .note_off);
    try testing.expectEqual(@as(u32, 0), events[0].sample_offset);
}

test "gatherEvents: note outside block produces no events" {
    const spb = 48.0;
    const frames: u32 = 96;
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{.{ .start = 3, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [0..2): note starts at beat 3 — no events.
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, &events);
    try testing.expectEqual(@as(usize, 0), n);
}

test "gatherEvents: clip entirely before block is skipped" {
    const spb = 48.0;
    const frames: u32 = 96;
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 2,
        .notes = &.{.{ .start = 0, .len = 1, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block covers beats [4..6): clip ends at beat 2 — no events.
    const n = gatherEvents(&snap, 4.0, 6.0, spb, frames, &events);
    try testing.expectEqual(@as(usize, 0), n);
}

test "gatherEvents: events are sorted by sample_offset" {
    const spb = 48.0;
    const frames: u32 = 192;
    // Two notes starting at beats 1 and 0 (out of order in the note list).
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 4,
        .notes = &.{
            .{ .start = 1, .len = 0.5, .pitch = 62 },
            .{ .start = 0, .len = 0.5, .pitch = 60 },
        },
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block [0..4): both note-ons fire. Sorted: pitch 60 (offset 0) < pitch 62 (offset 48).
    const n = gatherEvents(&snap, 0, 4.0, spb, frames, &events);
    try testing.expect(n >= 2);
    try testing.expect(events[0].sample_offset <= events[1].sample_offset);
}

test "gatherEvents: note clamped to clip end" {
    const spb = 48.0;
    const frames: u32 = 96;
    // Clip ends at beat 1; note extends past it to beat 2.
    const snap = makeSnap(&.{.{
        .start = 0,
        .len = 1,
        .notes = &.{.{ .start = 0, .len = 2, .pitch = 60 }},
    }});
    var events: [MAX_EVENTS_PER_TRACK]machine.NoteEvent = undefined;

    // Block [0..2): note-on at 0, note-off clamped to clip end at beat 1.
    const n = gatherEvents(&snap, 0, 2.0, spb, frames, &events);
    try testing.expectEqual(@as(usize, 2), n);
    // After sort: note-on (offset 0) < note-off (offset 48).
    try testing.expect(events[0].kind == .note_on);
    try testing.expect(events[1].kind == .note_off);
    try testing.expectEqual(@as(u32, 48), events[1].sample_offset);
}
