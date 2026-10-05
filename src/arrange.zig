//! Arranging by section (docs/28 §Arranging by section): duplicate,
//! delete or move a stretch of the song with everything in it — clips (cut
//! where they cross its edges), track automation, tempo and meter changes,
//! locators and sections — and the song after it moving up or down to
//! make room. Three operations make the rest: take a copy of a span
//! (`Piece`), remove a span, put a piece in at a beat.
//!
//! At every cut each curve (a lane, the tempo map) gets a point holding
//! its value there, so what plays on either side doesn't change; where two
//! stretches meet the curve steps from one to the other. A span that
//! starts and ends on downbeats moves the meter map by whole bars with it;
//! one off the bar (a pickup) leaves the meter map as it is. UI thread.

const std = @import("std");
const track_mod = @import("track.zig");
const clip_mod = @import("clip.zig");
const automation = @import("automation.zig");
const tempo_mod = @import("tempo.zig");
const meter_mod = @import("meter.zig");
const markers_mod = @import("markers.zig");
const routing = @import("routing.zig");

const Track = track_mod.Track;
const Clip = clip_mod.Clip;
const EPS: f64 = 1e-6;

/// What an edit works on.
pub const Song = struct {
    alloc: std.mem.Allocator,
    tracks: []Track,
    tempo: *tempo_mod.TempoState,
    meter: *meter_mod.MeterState,
    markers: *markers_mod.Markers,
    /// Where the song ends without an END marker (the last clip).
    song_end: f64,
};

// ── Clips ──────────────────────────────────────────────────────────────

/// Cut clip `ci` of `t` at song beat `beat`, if it crosses it: the left
/// part stays, the right is appended to the track. Notes crossing the cut
/// end there; lanes and audio windows split so each part plays what it
/// played.
pub fn splitClip(alloc: std.mem.Allocator, t: *Track, ci: usize, beat: f64, tmap: *const tempo_mod.TempoMap) !bool {
    const clip = &t.clips.items[ci];
    const local = beat - clip.start_beat;
    if (local <= EPS or local >= clip.length_beats - EPS) return false;
    if (clip.isAudio()) {
        const split_sec = tmap.secondsAt(beat) - tmap.secondsAt(clip.start_beat);
        var right = Clip.initAudio(clip.name(), beat, clip.start_beat + clip.length_beats - beat, clip.audio.source);
        right.selected = clip.selected;
        right.muted = clip.muted;
        right.audio.gain = clip.audio.gain;
        right.audio.reversed = clip.audio.reversed;
        right.audio.dur_sec = @max(0.0, clip.audio.dur_sec - split_sec);
        right.audio.fade_out_sec = clip.audio.fade_out_sec;
        if (clip.audio.reversed) {
            right.audio.start_sec = clip.audio.start_sec;
            clip.audio.start_sec += right.audio.dur_sec;
        } else right.audio.start_sec = clip.audio.start_sec + split_sec;
        clip.audio.dur_sec = split_sec;
        clip.audio.fade_out_sec = 0;
        clip.length_beats = local;
        try t.addClip(alloc, right);
        return true;
    }
    var right = Clip.init(clip.name(), beat, clip.start_beat + clip.length_beats - beat);
    errdefer right.deinit(alloc);
    right.selected = clip.selected;
    right.muted = clip.muted;
    var ni: usize = 0;
    while (ni < clip.notes.items.len) {
        var note = clip.notes.items[ni];
        if (note.start_beat >= local) {
            _ = clip.notes.orderedRemove(ni);
            note.start_beat -= local;
            try right.addNote(alloc, note);
        } else {
            if (note.start_beat + note.length_beats > local) clip.notes.items[ni].length_beats = local - note.start_beat;
            ni += 1;
        }
    }
    try clip.splitLanes(alloc, &right, local);
    clip.length_beats = local;
    try t.addClip(alloc, right);
    return true;
}

/// Cut every clip crossing `beat`.
pub fn splitAll(s: *const Song, beat: f64) !void {
    for (s.tracks) |*t| {
        const n = t.clips.items.len;
        for (0..n) |ci| _ = try splitClip(s.alloc, t, ci, beat, &s.tempo.live);
    }
}

// ── Curves ─────────────────────────────────────────────────────────────

/// A lane's point at `beat` with the curve's value there and the shape
/// of the segment it's in, so the curve goes on as it was.
fn lanePin(points: []const automation.Point, beat: f64) automation.Point {
    const shape: automation.Shape = if (automation.segmentIndex(points, beat)) |i| points[i].shape else .linear;
    const tension: f32 = if (automation.segmentIndex(points, beat)) |i| points[i].tension else 0;
    return .{ .beat = beat, .value = automation.eval(points, beat), .shape = shape, .tension = tension };
}

/// The tempo map's point at `beat`, ramping on if the segment there does.
fn tempoPin(m: *const tempo_mod.TempoMap, beat: f64) tempo_mod.TempoPoint {
    const i = m.segment(beat);
    return .{ .beat = beat, .bpm = m.bpmAt(beat), .ramp = m.points[i].ramp and i + 1 < m.len };
}

fn meterPin(m: meter_mod.MeterMap, bar: u32) meter_mod.MeterPoint {
    var p = m.segmentForBar(bar);
    p.start_bar = bar;
    return p;
}

/// Drop tempo points that change nothing: a step to the tempo already
/// playing, or a zero-length segment nothing ramps into.
fn tidyTempo(m: *tempo_mod.TempoMap) void {
    var w: usize = 1;
    var i: usize = 1;
    while (i < m.len) : (i += 1) {
        const p = m.points[i];
        const prev = m.points[w - 1];
        const same_beat_next = i + 1 < m.len and @abs(m.points[i + 1].beat - p.beat) < EPS;
        const ramped_into = prev.ramp;
        if (!ramped_into and !p.ramp and p.bpm == prev.bpm) continue;
        if (same_beat_next and !ramped_into) continue;
        m.points[w] = p;
        w += 1;
    }
    m.len = w;
    m.points[0].beat = 0;
    m.rebuild();
}

fn sameMeter(a: meter_mod.MeterPoint, b: meter_mod.MeterPoint) bool {
    return a.numerator == b.numerator and a.denominator == b.denominator and a.groups.eql(b.groups);
}

/// Drop meter points that change nothing, and all but the last at a bar.
fn tidyMeter(pts: []meter_mod.MeterPoint) usize {
    var w: usize = 0;
    for (pts, 0..) |p, i| {
        if (i + 1 < pts.len and pts[i + 1].start_bar == p.start_bar) continue;
        if (w > 0 and sameMeter(pts[w - 1], p)) continue;
        pts[w] = p;
        w += 1;
    }
    if (w > 0) pts[0].start_bar = 0;
    return w;
}

// ── A piece of the song ────────────────────────────────────────────────

const LanePiece = struct { lane: usize, points: std.ArrayList(automation.Point) = .empty };

/// A copy of a span, its beats and bars counted from its start.
pub const Piece = struct {
    len: f64,
    bars: u32,
    /// It starts and ends on downbeats: its meter changes come with it.
    whole_bars: bool = true,
    clips: [routing.MAX_TRACKS]std.ArrayList(Clip) = @splat(.empty),
    lanes: [routing.MAX_TRACKS]std.ArrayList(LanePiece) = @splat(.empty),
    /// From its start's tempo to its end's, ramps and all.
    tempo: std.ArrayList(tempo_mod.TempoPoint) = .empty,
    /// The meter at its first bar, then its changes.
    meter: std.ArrayList(meter_mod.MeterPoint) = .empty,
    locators: std.ArrayList(markers_mod.Locator) = .empty,
    sections: std.ArrayList(markers_mod.Section) = .empty,

    pub fn deinit(p: *Piece, alloc: std.mem.Allocator) void {
        for (&p.clips) |*cs| {
            for (cs.items) |*c| c.deinit(alloc);
            cs.deinit(alloc);
        }
        for (&p.lanes) |*ls| {
            for (ls.items) |*l| l.points.deinit(alloc);
            ls.deinit(alloc);
        }
        p.tempo.deinit(alloc);
        p.meter.deinit(alloc);
        p.locators.deinit(alloc);
        p.sections.deinit(alloc);
    }
};

fn barOf(s: *const Song, beat: f64) u32 {
    return s.meter.liveMap().beatToBarPos(beat).bar;
}

/// `beat` is a downbeat.
fn onBar(s: *const Song, beat: f64) bool {
    const mm = s.meter.liveMap();
    return @abs(mm.barStartBeat(mm.beatToBarPos(beat).bar) - beat) < EPS;
}

/// A copy of [a, b): a and b are downbeats. Clips crossing the edges are
/// cut there first.
pub fn take(s: *const Song, a: f64, b: f64) !Piece {
    const alloc = s.alloc;
    try splitAll(s, a);
    try splitAll(s, b);
    const mm = s.meter.liveMap();
    const bar_a = barOf(s, a);
    const bar_b = barOf(s, b);
    var p = Piece{ .len = b - a, .bars = bar_b - bar_a, .whole_bars = onBar(s, a) and onBar(s, b) };
    errdefer p.deinit(alloc);
    for (s.tracks, 0..) |*t, ti| {
        for (t.clips.items) |*c| {
            if (c.start_beat < a - EPS or c.start_beat >= b - EPS) continue;
            var cc = try c.clone(alloc);
            cc.start_beat -= a;
            cc.selected = false;
            try p.clips[ti].append(alloc, cc);
        }
        for (t.lanes.items, 0..) |*l, li| {
            if (l.points.items.len == 0) continue;
            var lp = LanePiece{ .lane = li };
            try lp.points.append(alloc, lanePin(l.points.items, a));
            for (l.points.items) |pt| if (pt.beat > a and pt.beat < b) {
                var q = pt;
                q.beat -= a;
                try lp.points.append(alloc, q);
            };
            var end = lanePin(l.points.items, b);
            end.beat = b - a;
            // The value it reaches at b, from the left.
            end.value = automation.eval(l.points.items, b - EPS);
            try lp.points.append(alloc, end);
            try p.lanes[ti].append(alloc, lp);
        }
    }
    const tm = &s.tempo.live;
    var t0 = tempoPin(tm, a);
    t0.beat = 0;
    try p.tempo.append(alloc, t0);
    for (tm.slice()) |q| if (q.beat > a + EPS and q.beat < b - EPS) {
        var r = q;
        r.beat -= a;
        try p.tempo.append(alloc, r);
    };
    try p.tempo.append(alloc, .{ .beat = b - a, .bpm = tm.bpmAt(b - EPS) });
    if (p.whole_bars) {
        var m0 = meterPin(mm, bar_a);
        m0.start_bar = 0;
        try p.meter.append(alloc, m0);
        for (mm.points) |q| if (q.start_bar > bar_a and q.start_bar < bar_b) {
            var r = q;
            r.start_bar -= bar_a;
            try p.meter.append(alloc, r);
        };
    }
    for (s.markers.locatorSlice()) |l| if (l.beat >= a - EPS and l.beat < b - EPS) {
        var r = l;
        r.beat -= a;
        try p.locators.append(alloc, r);
    };
    for (s.markers.sectionSlice()) |sec| if (sec.beat >= a - EPS and sec.beat < b - EPS) {
        var r = sec;
        r.beat -= a;
        try p.sections.append(alloc, r);
    };
    return p;
}

/// Remove [a, b) (downbeats) and close the gap.
pub fn remove(s: *const Song, a: f64, b: f64) !void {
    const alloc = s.alloc;
    const len = b - a;
    try splitAll(s, a);
    try splitAll(s, b);
    const bar_a = barOf(s, a);
    const bar_b = barOf(s, b);
    const nb = bar_b - bar_a;
    const whole_bars = onBar(s, a) and onBar(s, b);
    for (s.tracks) |*t| {
        var ci: usize = 0;
        while (ci < t.clips.items.len) {
            const c = &t.clips.items[ci];
            if (c.start_beat >= a - EPS and c.start_beat < b - EPS) {
                var dead = t.clips.orderedRemove(ci);
                dead.deinit(alloc);
                continue;
            }
            if (c.start_beat >= b - EPS) c.start_beat -= len;
            ci += 1;
        }
        for (t.lanes.items) |*l| {
            if (l.points.items.len == 0) continue;
            const pa = lanePin(l.points.items, a);
            var pb = lanePin(l.points.items, b);
            var out: std.ArrayList(automation.Point) = .empty;
            errdefer out.deinit(alloc);
            for (l.points.items) |pt| if (pt.beat < a) try out.append(alloc, pt);
            try out.append(alloc, pa);
            pb.beat = a;
            try out.append(alloc, pb);
            for (l.points.items) |pt| if (pt.beat > b) {
                var q = pt;
                q.beat -= len;
                try out.append(alloc, q);
            };
            l.points.deinit(alloc);
            l.points = out;
        }
    }
    // Tempo: what played before a ramps to where it did; after it, what
    // played from b.
    {
        const tm = &s.tempo.live;
        var m = tempo_mod.TempoMap{};
        var n: usize = 0;
        for (tm.slice()) |q| if (q.beat < a - EPS and n < tempo_mod.MAX_POINTS) {
            m.points[n] = q;
            n += 1;
        };
        if (a > EPS and n < tempo_mod.MAX_POINTS) {
            m.points[n] = tempoPin(tm, a);
            m.points[n].ramp = false;
            n += 1;
        }
        if (n < tempo_mod.MAX_POINTS) {
            m.points[n] = tempoPin(tm, b);
            m.points[n].beat = a;
            n += 1;
        }
        for (tm.slice()) |q| if (q.beat > b + EPS and n < tempo_mod.MAX_POINTS) {
            m.points[n] = q;
            m.points[n].beat -= len;
            n += 1;
        };
        m.len = n;
        tidyTempo(&m);
        s.tempo.set(&m);
    }
    // Off the bar the meter map stays: the bars after re-lay over what moved.
    if (whole_bars) {
        const mm = s.meter.liveMap();
        var pts: [meter_mod.MAX_POINTS]meter_mod.MeterPoint = undefined;
        var n: usize = 0;
        for (mm.points) |q| if (q.start_bar < bar_a and n < pts.len) {
            pts[n] = q;
            n += 1;
        };
        pts[n] = meterPin(mm, bar_b);
        pts[n].start_bar = bar_a;
        n += 1;
        for (mm.points) |q| if (q.start_bar > bar_b and n < pts.len) {
            pts[n] = q;
            pts[n].start_bar -= nb;
            n += 1;
        };
        s.meter.stage(pts[0..tidyMeter(pts[0..n])]);
    }
    const mk = s.markers;
    var k = mk.locator_n;
    while (k > 0) {
        k -= 1;
        const l = &mk.locators[k];
        if (l.beat >= a - EPS and l.beat < b - EPS) mk.remove(.locator, k) else if (l.beat >= b - EPS) l.beat -= len;
    }
    k = mk.section_n;
    while (k > 0) {
        k -= 1;
        const sec = &mk.sections[k];
        if (sec.beat >= a - EPS and sec.beat < b - EPS) mk.remove(.section, k) else if (sec.beat >= b - EPS) sec.beat -= len;
    }
    if (mk.end) |*e| if (e.* >= b - EPS) {
        e.* -= len;
    };
}

/// Open a gap of the piece's length at downbeat `at` and put it there.
pub fn put(s: *const Song, at: f64, p: *const Piece) !void {
    const alloc = s.alloc;
    const len = p.len;
    try splitAll(s, at);
    const bar_at = barOf(s, at);
    for (s.tracks, 0..) |*t, ti| {
        for (t.clips.items) |*c| if (c.start_beat >= at - EPS) {
            c.start_beat += len;
        };
        for (p.clips[ti].items) |*c| {
            var cc = try c.clone(alloc);
            cc.start_beat += at;
            t.addClip(alloc, cc) catch |err| {
                cc.deinit(alloc);
                return err;
            };
        }
        for (t.lanes.items, 0..) |*l, li| {
            const piece: ?*const LanePiece = for (p.lanes[ti].items) |*lp| {
                if (lp.lane == li) break lp;
            } else null;
            if (l.points.items.len == 0 and piece == null) continue;
            var out: std.ArrayList(automation.Point) = .empty;
            errdefer out.deinit(alloc);
            const has = l.points.items.len > 0;
            for (l.points.items) |pt| if (pt.beat < at) try out.append(alloc, pt);
            if (has) try out.append(alloc, lanePin(l.points.items, at));
            if (piece) |lp| for (lp.points.items) |pt| {
                var q = pt;
                q.beat += at;
                try out.append(alloc, q);
            };
            if (has) {
                var r = lanePin(l.points.items, at);
                r.beat = at + len;
                try out.append(alloc, r);
            }
            for (l.points.items) |pt| if (pt.beat > at) {
                var q = pt;
                q.beat += len;
                try out.append(alloc, q);
            };
            l.points.deinit(alloc);
            l.points = out;
        }
    }
    {
        const tm = &s.tempo.live;
        var m = tempo_mod.TempoMap{};
        var n: usize = 0;
        const room = tempo_mod.MAX_POINTS;
        for (tm.slice()) |q| if (q.beat < at - EPS and n < room) {
            m.points[n] = q;
            n += 1;
        };
        if (at > EPS and n < room) {
            m.points[n] = tempoPin(tm, at);
            m.points[n].ramp = false;
            n += 1;
        }
        for (p.tempo.items) |q| if (n < room) {
            m.points[n] = q;
            m.points[n].beat += at;
            n += 1;
        };
        if (n < room) {
            m.points[n] = tempoPin(tm, at);
            m.points[n].beat = at + len;
            n += 1;
        }
        for (tm.slice()) |q| if (q.beat > at + EPS and n < room) {
            m.points[n] = q;
            m.points[n].beat += len;
            n += 1;
        };
        m.len = n;
        tidyTempo(&m);
        s.tempo.set(&m);
    }
    if (p.whole_bars and onBar(s, at)) {
        const mm = s.meter.liveMap();
        var pts: [meter_mod.MAX_POINTS]meter_mod.MeterPoint = undefined;
        var n: usize = 0;
        for (mm.points) |q| if (q.start_bar < bar_at and n < pts.len) {
            pts[n] = q;
            n += 1;
        };
        for (p.meter.items) |q| if (n < pts.len) {
            pts[n] = q;
            pts[n].start_bar += bar_at;
            n += 1;
        };
        if (n < pts.len) {
            pts[n] = meterPin(mm, bar_at);
            pts[n].start_bar = bar_at + p.bars;
            n += 1;
        }
        for (mm.points) |q| if (q.start_bar > bar_at and n < pts.len) {
            pts[n] = q;
            pts[n].start_bar += p.bars;
            n += 1;
        };
        s.meter.stage(pts[0..tidyMeter(pts[0..n])]);
    }
    const mk = s.markers;
    for (mk.locators[0..mk.locator_n]) |*l| if (l.beat >= at - EPS) {
        l.beat += len;
    };
    for (mk.sections[0..mk.section_n]) |*sec| if (sec.beat >= at - EPS) {
        sec.beat += len;
    };
    if (mk.end) |*e| if (e.* >= at - EPS) {
        e.* += len;
    };
    for (p.locators.items) |l| if (mk.addLocator(l.beat + at, l.name.get())) |_| {} else break;
    for (p.sections.items) |sec| {
        const i = mk.addSection(sec.beat + at, sec.name.get()) orelse break;
        mk.sections[i].color = sec.color;
        mk.sections[i].groove = sec.groove;
    }
}

// ── By section ─────────────────────────────────────────────────────────

/// Section `i`'s span: its start to the next's, or END; without END, to
/// the last clip rounded up to a downbeat.
pub fn span(s: *const Song, i: usize) [2]f64 {
    const mk = s.markers;
    const a = mk.sections[i].beat;
    const e = mk.sectionEnd(i, s.song_end);
    if (i + 1 < mk.section_n or mk.end != null) return .{ a, @max(e, a + EPS) };
    const mm = s.meter.liveMap();
    const pos = mm.beatToBarPos(e);
    const at = mm.barStartBeat(pos.bar);
    const b = if (e - at < EPS) at else mm.barStartBeat(pos.bar + 1);
    return .{ a, @max(b, a + EPS) };
}

/// A copy of section `i` and all in it, right after it.
pub fn duplicate(s: *const Song, i: usize) !void {
    const sp = span(s, i);
    var p = try take(s, sp[0], sp[1]);
    defer p.deinit(s.alloc);
    try put(s, sp[1], &p);
}

/// Section `i` and all in it gone, the song after it moved up.
pub fn delete(s: *const Song, i: usize) !void {
    const sp = span(s, i);
    try remove(s, sp[0], sp[1]);
}

/// Section `i` swapped with the one before it.
pub fn moveEarlier(s: *const Song, i: usize) !void {
    if (i == 0 or i >= s.markers.section_n) return;
    const sp = span(s, i);
    const to = s.markers.sections[i - 1].beat;
    var p = try take(s, sp[0], sp[1]);
    defer p.deinit(s.alloc);
    try remove(s, sp[0], sp[1]);
    try put(s, to, &p);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    tracks: [1]Track,
    tempo: tempo_mod.TempoState = .{},
    meter: meter_mod.MeterState = .{},
    markers: markers_mod.Markers = .{},

    fn init(f: *Fixture, alloc: std.mem.Allocator) !void {
        f.* = .{ .tracks = .{try Track.init(alloc, "T", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, track_mod.testMachine())} };
        f.meter.liveStore().reset();
        f.meter.commitImmediate();
        // A, B, C: four bars each, a clip across A and B, a note per bar.
        _ = f.markers.addSection(0, "A");
        _ = f.markers.addSection(16, "B");
        _ = f.markers.addSection(32, "C");
        f.markers.end = 48;
        var c = Clip.init("x", 0, 32);
        for (0..8) |k| try c.addNote(alloc, .{ .pitch = @intCast(60 + k), .start_beat = @floatFromInt(k * 4), .length_beats = 1 });
        try f.tracks[0].addClip(alloc, c);
        var l = try f.tracks[0].laneFor(alloc, automation.Target.volume(), false);
        _ = try l.insert(alloc, .{ .beat = 0, .value = 0 });
        _ = try l.insert(alloc, .{ .beat = 48, .value = 1 });
        // 140 BPM in C.
        _ = f.tempo.edit().put(32, 140);
        f.tempo.publish();
    }

    fn song(f: *Fixture, alloc: std.mem.Allocator) Song {
        return .{ .alloc = alloc, .tracks = &f.tracks, .tempo = &f.tempo, .meter = &f.meter, .markers = &f.markers, .song_end = 48 };
    }

    fn deinit(f: *Fixture, alloc: std.mem.Allocator) void {
        for (&f.tracks) |*t| t.deinit(alloc);
    }

    /// Every note's song beat and pitch, in order.
    fn notes(f: *Fixture, out: *[32][2]f64) usize {
        var n: usize = 0;
        for (f.tracks[0].clips.items) |*c| for (c.notes.items) |nt| {
            out[n] = .{ c.start_beat + nt.start_beat, @floatFromInt(nt.pitch) };
            n += 1;
        };
        std.mem.sort([2]f64, out[0..n], {}, struct {
            fn lt(_: void, x: [2]f64, y: [2]f64) bool {
                return x[0] < y[0];
            }
        }.lt);
        return n;
    }
};

test "delete a section: its notes, bars, meter and tempo go, the rest moves up" {
    const alloc = testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    // B in 7/8: four bars, beats 16..30; C from 30 at 140.
    f.meter.insertChange(4, 7, 8);
    f.meter.insertChange(8, 4, 4);
    f.meter.commitImmediate();
    f.markers.sections[2].beat = 30;
    f.markers.end = 46;
    {
        const m = f.tempo.edit();
        m.points[1].beat = 30;
        f.tempo.publish();
    }
    const s = f.song(alloc);
    try testing.expectEqual(@as(f64, 30), span(&s, 1)[1]);
    try delete(&s, 1);
    try testing.expectEqual(@as(usize, 2), f.markers.section_n);
    try testing.expectEqualStrings("C", f.markers.sections[1].name.get());
    try testing.expectEqual(@as(f64, 16), f.markers.sections[1].beat);
    try testing.expectEqual(@as(?f64, 32), f.markers.end);
    // B's notes (16, 20, 24, 28) are gone; A's stay.
    var ns: [32][2]f64 = undefined;
    const n = f.notes(&ns);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(f64, 12), ns[3][0]);
    // The 7/8 went with it; C plays at 140 from where it now starts.
    try testing.expectEqual(@as(usize, 1), f.meter.liveMap().points.len);
    try testing.expectEqual(@as(f64, 120), f.tempo.live.bpmAt(15));
    try testing.expectEqual(@as(f64, 140), f.tempo.live.bpmAt(16));
    // The volume lane steps from where A ended to where C began.
    const vol = f.tracks[0].lanes.items[0].points.items;
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 48.0), automation.eval(vol, 16 - EPS), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 30.0 / 48.0), automation.eval(vol, 16), 1e-4);
}

test "duplicate a section: a copy of it all right after it" {
    const alloc = testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    const s = f.song(alloc);
    try duplicate(&s, 0);
    try testing.expectEqual(@as(usize, 4), f.markers.section_n);
    try testing.expectEqualStrings("A", f.markers.sections[1].name.get());
    try testing.expectEqual(@as(f64, 16), f.markers.sections[1].beat);
    try testing.expectEqual(@as(f64, 32), f.markers.sections[2].beat);
    try testing.expectEqual(@as(?f64, 64), f.markers.end);
    var ns: [32][2]f64 = undefined;
    const n = f.notes(&ns);
    try testing.expectEqual(@as(usize, 12), n);
    // A's four notes, then again, then B's.
    for (0..4) |k| {
        try testing.expectEqual(ns[k][1], ns[k + 4][1]);
        try testing.expectEqual(ns[k][0] + 16, ns[k + 4][0]);
    }
    try testing.expectEqual(@as(f64, 32), ns[8][0]);
    // The tempo change moved with C; the volume ramp holds across.
    try testing.expectEqual(@as(f64, 120), f.tempo.live.bpmAt(47));
    try testing.expectEqual(@as(f64, 140), f.tempo.live.bpmAt(48));
    const vol = f.tracks[0].lanes.items[0].points.items;
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), automation.eval(vol, 16 - EPS), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), automation.eval(vol, 16), 1e-6);
}

test "move a section earlier: two sections swap, notes and meter with them" {
    const alloc = testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    f.meter.insertChange(8, 3, 4);
    f.meter.commitImmediate();
    // C is 3/4 now: four bars = 12 beats (32..44).
    f.markers.end = 44;
    const s = f.song(alloc);
    try moveEarlier(&s, 2);
    try testing.expectEqualStrings("C", f.markers.sections[1].name.get());
    try testing.expectEqual(@as(f64, 16), f.markers.sections[1].beat);
    try testing.expectEqualStrings("B", f.markers.sections[2].name.get());
    try testing.expectEqual(@as(f64, 28), f.markers.sections[2].beat);
    const pts = f.meter.liveMap().points;
    // 3/4 for C, 4/4 again for B, and past the song the 3/4 that played
    // after C before.
    try testing.expectEqual(@as(usize, 4), pts.len);
    try testing.expectEqual(@as(u32, 4), pts[1].start_bar);
    try testing.expectEqual(@as(u8, 3), pts[1].numerator);
    try testing.expectEqual(@as(u32, 8), pts[2].start_bar);
    try testing.expectEqual(@as(u8, 4), pts[2].numerator);
    try testing.expectEqual(@as(u32, 12), pts[3].start_bar);
    try testing.expectEqual(@as(f64, 140), f.tempo.live.bpmAt(20));
    try testing.expectEqual(@as(f64, 120), f.tempo.live.bpmAt(30));
    // B's notes (16..28) now from 28.
    var ns: [32][2]f64 = undefined;
    const n = f.notes(&ns);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqual(@as(f64, 28), ns[4][0]);
    try testing.expectEqual(@as(f64, 64), ns[4][1]);
    try testing.expectEqual(@as(?f64, 44), f.markers.end);
}

test "a pickup section (off the bar) moves its content to the beat and leaves the meter map be" {
    const alloc = testing.allocator;
    var f: Fixture = undefined;
    try f.init(alloc);
    defer f.deinit(alloc);
    f.meter.insertChange(12, 3, 4);
    f.meter.commitImmediate();
    // B starts two beats early: 14..32.
    f.markers.sections[1].beat = 14;
    const s = f.song(alloc);
    try testing.expectEqual([2]f64{ 14, 32 }, span(&s, 1));
    try duplicate(&s, 1);
    // B's notes (16..28) again 18 beats later; C and its tempo after them.
    var ns: [32][2]f64 = undefined;
    const n = f.notes(&ns);
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqual(@as(f64, 34), ns[8][0]);
    try testing.expectEqual(@as(f64, 64), ns[8][1]);
    try testing.expectEqual(@as(f64, 32), f.markers.sections[2].beat);
    try testing.expectEqual(@as(f64, 50), f.markers.sections[3].beat);
    try testing.expectEqual(@as(f64, 120), f.tempo.live.bpmAt(49));
    try testing.expectEqual(@as(f64, 140), f.tempo.live.bpmAt(50));
    // The meter map is as it was.
    const pts = f.meter.liveMap().points;
    try testing.expectEqual(@as(usize, 2), pts.len);
    try testing.expectEqual(@as(u32, 12), pts[1].start_bar);
}
