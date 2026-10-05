//! Extract (docs/30): what an audio clip's source plays, placed on the
//! song — a moment of the source to the song's beats through the clip's
//! warp, or through the tempo map from where it starts when unwarped.

const std = @import("std");
const clip_mod = @import("clip.zig");
const tempo_mod = @import("tempo.zig");
const warp = @import("warp.zig");
const pitch = @import("pitch.zig");

/// Where second `sec` of a clip's source plays, in song beats from the
/// clip's start. `rate` is its track's tempo ratio (docs/28 §Polytempo):
/// a warped clip's content runs at it.
pub fn songBeat(clip: *const clip_mod.Clip, rate: f64, tmap: *const tempo_mod.TempoMap, sec: f64) f64 {
    if (clip.audio.warp and warp.valid(clip.warp_markers.items)) {
        const b = warp.Map.init(clip.warp_markers.items).beatAt(sec);
        return (b - clip.audio.offset_beats) / rate;
    }
    const t0 = tmap.secondsAt(clip.start_beat);
    return tmap.beatAt(t0 + sec - clip.audio.start_sec) - clip.start_beat;
}

/// Which second of the source plays `rel` song beats into the clip: the
/// inverse of `songBeat`.
pub fn sourceSec(clip: *const clip_mod.Clip, rate: f64, tmap: *const tempo_mod.TempoMap, rel: f64) f64 {
    if (clip.audio.warp and warp.valid(clip.warp_markers.items)) {
        return warp.Map.init(clip.warp_markers.items).secAt(rel * rate + clip.audio.offset_beats);
    }
    return clip.audio.start_sec + tmap.secondsAt(clip.start_beat + rel) - tmap.secondsAt(clip.start_beat);
}

/// The notes that play inside `clip` into `out`, a pattern at the clip's
/// place and length; cut at its edges. How many went in.
pub fn placeNotes(alloc: std.mem.Allocator, clip: *const clip_mod.Clip, rate: f64, tmap: *const tempo_mod.TempoMap, notes: []const pitch.Note, out: *clip_mod.Clip) !usize {
    var n: usize = 0;
    for (notes) |nt| {
        const s = @max(0, songBeat(clip, rate, tmap, nt.sec));
        const e = @min(clip.length_beats, songBeat(clip, rate, tmap, nt.end));
        if (e - s < 1.0 / 64.0) continue;
        try out.addNote(alloc, .{ .pitch = nt.pitch, .start_beat = s, .length_beats = e - s, .velocity = nt.velocity });
        n += 1;
    }
    return n;
}

/// The middle pitch of a pattern's notes (a bass's is under C3).
pub fn medianPitch(notes: []const clip_mod.Note) u8 {
    if (notes.len == 0) return 60;
    var hist = [_]u32{0} ** 128;
    for (notes) |nt| hist[nt.pitch] += 1;
    var seen: usize = 0;
    for (hist, 0..) |h, p| {
        seen += h;
        if (seen * 2 >= notes.len) return @intCast(p);
    }
    return 60;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "songBeat: through a warped clip's markers, at the track's ratio" {
    const alloc = testing.allocator;
    var c = clip_mod.Clip.initAudio("t", 8, 6, 0);
    defer c.deinit(alloc);
    c.audio.warp = true;
    c.audio.offset_beats = 1;
    try c.warp_markers.appendSlice(alloc, &.{ .{ .sec = 0, .beat = 0 }, .{ .sec = 2, .beat = 4 } });
    const m = tempo_mod.TempoMap.constant(120);
    try testing.expectApproxEqAbs(@as(f64, 1), songBeat(&c, 1, &m, 1.0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), songBeat(&c, 2, &m, 1.0), 1e-9);
}

test "sourceSec: undoes songBeat, warped or not" {
    const alloc = testing.allocator;
    var c = clip_mod.Clip.initAudio("t", 8, 6, 0);
    defer c.deinit(alloc);
    c.audio.start_sec = 0.3;
    var m = tempo_mod.TempoMap.constant(120);
    _ = m.put(10, 90);
    m.rebuild();
    for ([_]f64{ 0, 1.5, 4.25 }) |rel| try testing.expectApproxEqAbs(rel, songBeat(&c, 1.5, &m, sourceSec(&c, 1.5, &m, rel)), 1e-9);
    c.audio.warp = true;
    c.audio.offset_beats = 1;
    try c.warp_markers.appendSlice(alloc, &.{ .{ .sec = 0, .beat = 0 }, .{ .sec = 2, .beat = 4 }, .{ .sec = 3, .beat = 9 } });
    for ([_]f64{ 0, 1.5, 4.25 }) |rel| try testing.expectApproxEqAbs(rel, songBeat(&c, 1.5, &m, sourceSec(&c, 1.5, &m, rel)), 1e-9);
}

test "songBeat: an unwarped clip from its window's start, through the tempo map" {
    const alloc = testing.allocator;
    var c = clip_mod.Clip.initAudio("t", 4, 8, 0);
    defer c.deinit(alloc);
    c.audio.start_sec = 0.5;
    const m = tempo_mod.TempoMap.constant(120);
    try testing.expectApproxEqAbs(@as(f64, 1), songBeat(&c, 1, &m, 1.0), 1e-9);
}

test "placeNotes: cut at the clip's edges, slivers left out" {
    const alloc = testing.allocator;
    var c = clip_mod.Clip.initAudio("t", 0, 4, 0);
    defer c.deinit(alloc);
    const m = tempo_mod.TempoMap.constant(120);
    var out = clip_mod.Clip.init("n", 0, 4);
    defer out.deinit(alloc);
    const ns = [_]pitch.Note{
        .{ .sec = 0.25, .end = 0.75, .pitch = 60, .velocity = 90 },
        .{ .sec = 1.75, .end = 2.5, .pitch = 62, .velocity = 90 },
        .{ .sec = 2.0, .end = 2.5, .pitch = 64, .velocity = 90 },
    };
    try testing.expectEqual(@as(usize, 2), try placeNotes(alloc, &c, 1, &m, &ns, &out));
    try testing.expectApproxEqAbs(@as(f64, 0.5), out.notes.items[0].start_beat, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), out.notes.items[0].length_beats, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out.notes.items[1].length_beats, 1e-9);
}
