//! Track: one audio path hosting an instrument plus a small fixed insert
//! chain. Volume/mute/solo are UI-owned atomics consumed by the engine on
//! the audio thread.

const std = @import("std");
const c = @import("c.zig");
const machine = @import("machine.zig");
const clip_mod = @import("clip.zig");
const snap_mod = @import("snapshot.zig");
const audio_pool_mod = @import("audio_pool.zig");
const automation = @import("automation.zig");

pub const MAX_NAME = 32;

/// One slot in a track's insert chain: the effect machine, its registry
/// index (for persistence/forward-compat), and a per-effect bypass flag.
/// `bypass` is a plain atomic the audio thread reads each block; chain
/// mutations (add/remove/move/replace) happen with the device stopped, so
/// the backing `ArrayList` only reallocs while the engine is idle.
pub const Effect = struct {
    mach: machine.Machine,
    idx: ?u8 = null,
    /// Stable per-track id that automation lanes address (docs/22 §Targets):
    /// it survives reordering the chain.
    uid: u16 = 0,
    bypass: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Block peaks the engine writes after each render and the bay's I/O
    /// meters read: in L, in R, out L, out R, as f32 bits.
    io_peak: [4]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** 4,

    pub fn setIo(self: *Effect, in: [2]f32, out: [2]f32) void {
        const v = [4]f32{ in[0], in[1], out[0], out[1] };
        for (&self.io_peak, v) |*a, x| a.store(@bitCast(x), .monotonic);
    }

    pub fn io(self: *const Effect) struct { in: [2]f32, out: [2]f32 } {
        var v: [4]f32 = undefined;
        for (&v, &self.io_peak) |*x, *a| x.* = @bitCast(a.load(.monotonic));
        return .{ .in = .{ v[0], v[1] }, .out = .{ v[2], v[3] } };
    }
};

/// What role a Track plays in the signal graph. Audio tracks have an
/// instrument + clips and sum into the master. `ret` (return) and
/// `master` are buses: silent instrument, effects-only chain, no clips.
/// `ret` is defined now for persistence/forward-compat; unused until the
/// returns+sends phase.
pub const Kind = enum(u8) { audio, ret, master };

pub const Track = struct {
    name_buf: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    kind: Kind = .audio,
    color: c.rl.Color,
    machine: machine.Machine,
    /// Registry index for persistence. Null means the silent placeholder.
    machine_idx: ?u8 = null,
    /// Insert chain — UI-thread-owned, heap-backed, unbounded. The audio
    /// thread reads `effects.items` fresh each block; all mutations run
    /// with the device stopped (see main.zig), so a realloc never races a
    /// render.
    effects: std.ArrayList(Effect) = .empty,

    /// Clip list — UI-thread-owned. Audio thread reads via snapshot only.
    clips: std.ArrayList(clip_mod.Clip) = .empty,

    /// Track automation lanes (docs/22) — UI-thread-owned, published to the
    /// audio thread through the snapshot.
    lanes: std.ArrayList(automation.Lane) = .empty,
    /// Arrangement: lanes shown under the track row.
    lanes_shown: bool = false,
    next_fx_uid: u16 = 1,
    /// Audio-thread-owned per-lane segment cursors (automation.evalCursor).
    auto_cursors: [snap_mod.MAX_LANES_PER_TRACK]u32 = [_]u32{0} ** snap_mod.MAX_LANES_PER_TRACK,
    /// Manual overrides of automated volume/pan (docs/22 §Manual changes):
    /// 0 none, 1 held (touch), 2 sticky until the transport starts.
    vol_override: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    pan_override: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Double-buffered clip/note snapshot for lock-free audio access.
    /// UI writes to the non-published slot then flips snap_published.
    snap: [2]*snap_mod.TrackSnapshot,
    snap_published: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 0..1 linear gain, bit-cast for atomic.
    volume_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0.8))),
    /// -1 (hard left) .. +1 (hard right), 0 center. Bit-cast for atomic.
    pan_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0.0))),
    mute: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    solo: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Record-arm. UI-owned; the recorder records into the armed audio
    /// track. Not persisted (a transient performance state).
    armed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Meter levels written by engine, read by UI. Peak per channel,
    /// decaying toward zero each UI frame.
    meter_l: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    meter_r: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Instrument enable. When false the engine skips the instrument
    /// render and feeds silence into the effect chain. UI-owned, read by
    /// the audio thread — a plain atomic flip, no chain mutation.
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Bumped by the engine on any block that dispatches a note-on to the
    /// instrument. The UI reads the sequence to drive the note-activity
    /// LED — no timestamps on the audio thread.
    note_pulse: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(alloc: std.mem.Allocator, track_name: []const u8, color: c.rl.Color, mach: machine.Machine) !Track {
        const s0 = try alloc.create(snap_mod.TrackSnapshot);
        errdefer alloc.destroy(s0);
        const s1 = try alloc.create(snap_mod.TrackSnapshot);
        s0.* = .{};
        s1.* = .{};

        var t = Track{
            .color = color,
            .machine = mach,
            .snap = .{ s0, s1 },
        };
        const n = @min(track_name.len, MAX_NAME);
        @memcpy(t.name_buf[0..n], track_name[0..n]);
        t.name_len = @intCast(n);
        return t;
    }

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        if (self.machine.deinit) |deinit_fn| {
            deinit_fn(self.machine.state, alloc);
        }
        for (self.effects.items) |*fx| {
            if (fx.mach.deinit) |deinit_fn| {
                deinit_fn(fx.mach.state, alloc);
            }
        }
        self.effects.deinit(alloc);
        for (self.clips.items) |*clip| clip.deinit(alloc);
        self.clips.deinit(alloc);
        for (self.lanes.items) |*lane| lane.deinit(alloc);
        self.lanes.deinit(alloc);
        alloc.destroy(self.snap[0]);
        alloc.destroy(self.snap[1]);
    }

    pub fn replaceMachine(self: *Track, alloc: std.mem.Allocator, mach: machine.Machine) void {
        if (self.machine.deinit) |deinit_fn| {
            deinit_fn(self.machine.state, alloc);
        }
        self.machine = mach;
    }

    pub fn addEffect(self: *Track, alloc: std.mem.Allocator, mach: machine.Machine, idx: u8) !void {
        try self.effects.append(alloc, .{ .mach = mach, .idx = idx, .uid = self.next_fx_uid });
        self.next_fx_uid +%= 1;
    }

    pub fn effectByUid(self: *const Track, uid: u16) ?*Effect {
        for (self.effects.items) |*fx| if (fx.uid == uid) return fx;
        return null;
    }

    /// The lane driving `target`, if the track has one.
    pub fn findLane(self: *Track, target: automation.Target) ?*automation.Lane {
        for (self.lanes.items) |*l| if (l.target.eql(target)) return l;
        return null;
    }

    /// The lane driving `target`, created empty if missing.
    pub fn laneFor(self: *Track, alloc: std.mem.Allocator, target: automation.Target, stepped: bool) !*automation.Lane {
        if (self.findLane(target)) |l| return l;
        try self.lanes.append(alloc, .{ .target = target, .stepped = stepped });
        return &self.lanes.items[self.lanes.items.len - 1];
    }

    pub fn removeLane(self: *Track, alloc: std.mem.Allocator, i: usize) void {
        if (i >= self.lanes.items.len) return;
        self.lanes.items[i].deinit(alloc);
        _ = self.lanes.orderedRemove(i);
    }

    /// The machine a control target lives on, if it still exists.
    pub fn targetMachine(self: *const Track, target: automation.Target) ?*const machine.Machine {
        return switch (target.kind) {
            .volume, .pan => null,
            .inst => &self.machine,
            .fx => if (self.effectByUid(target.fx_uid)) |fx| &fx.mach else null,
        };
    }

    /// Remove effect `i`, deinit it, and shift the tail down. Caller must
    /// hold the audio thread (stop the device) — this mutates the chain
    /// the engine reads.
    pub fn removeEffect(self: *Track, alloc: std.mem.Allocator, i: usize) void {
        if (i >= self.effects.items.len) return;
        if (self.effects.items[i].mach.deinit) |deinit_fn| deinit_fn(self.effects.items[i].mach.state, alloc);
        _ = self.effects.orderedRemove(i);
    }

    /// Move effect `from` to position `to`, preserving the order of the
    /// rest. Per-effect bypass travels with the element. Audio-stopped.
    pub fn moveEffect(self: *Track, from: usize, to: usize) void {
        const n = self.effects.items.len;
        if (from >= n or to >= n or from == to) return;
        const e = self.effects.orderedRemove(from);
        // orderedRemove shifts the tail down; clamp the insert index.
        self.effects.insertAssumeCapacity(@min(to, self.effects.items.len), e);
    }

    /// Swap effect `i`'s machine for a new one, deinit the old, keeping the
    /// slot's position and bypass state. Audio-stopped.
    pub fn replaceEffect(self: *Track, alloc: std.mem.Allocator, i: usize, mach: machine.Machine, idx: u8) void {
        if (i >= self.effects.items.len) return;
        const slot = &self.effects.items[i];
        if (slot.mach.deinit) |deinit_fn| deinit_fn(slot.mach.state, alloc);
        slot.mach = mach;
        slot.idx = idx;
    }

    pub fn isArmed(self: *const Track) bool {
        return self.armed.load(.monotonic);
    }

    pub fn setArmed(self: *Track, on: bool) void {
        self.armed.store(on, .monotonic);
    }

    pub fn toggleArmed(self: *Track) void {
        self.armed.store(!self.armed.load(.monotonic), .monotonic);
    }

    pub fn isEnabled(self: *const Track) bool {
        return self.enabled.load(.monotonic);
    }

    pub fn setEnabled(self: *Track, on: bool) void {
        self.enabled.store(on, .monotonic);
    }

    pub fn toggleEnabled(self: *Track) void {
        self.enabled.store(!self.enabled.load(.monotonic), .monotonic);
    }

    pub fn effectCount(self: *const Track) usize {
        return self.effects.items.len;
    }

    pub fn effectBypassed(self: *const Track, i: usize) bool {
        if (i >= self.effects.items.len) return false;
        return self.effects.items[i].bypass.load(.monotonic);
    }

    pub fn toggleEffectBypass(self: *Track, i: usize) void {
        if (i >= self.effects.items.len) return;
        const e = &self.effects.items[i];
        e.bypass.store(!e.bypass.load(.monotonic), .monotonic);
    }

    /// Audio thread: signal that a note-on hit the instrument this block.
    pub fn pulseNote(self: *Track) void {
        _ = self.note_pulse.fetchAdd(1, .release);
    }

    pub fn noteSeq(self: *const Track) u32 {
        return self.note_pulse.load(.acquire);
    }

    pub fn addClip(self: *Track, alloc: std.mem.Allocator, clip: clip_mod.Clip) !void {
        try self.clips.append(alloc, clip);
    }

    pub fn name(self: *const Track) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Track, track_name: []const u8) void {
        @memset(&self.name_buf, 0);
        const n = @min(track_name.len, MAX_NAME);
        @memcpy(self.name_buf[0..n], track_name[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn volume(self: *const Track) f32 {
        return @bitCast(self.volume_bits.load(.monotonic));
    }

    pub fn setVolume(self: *Track, v: f32) void {
        const clamped = std.math.clamp(v, 0.0, 1.25);
        self.volume_bits.store(@bitCast(clamped), .monotonic);
    }

    pub fn pan(self: *const Track) f32 {
        return @bitCast(self.pan_bits.load(.monotonic));
    }

    pub fn setPan(self: *Track, p: f32) void {
        const clamped = std.math.clamp(p, -1.0, 1.0);
        self.pan_bits.store(@bitCast(clamped), .monotonic);
    }

    /// Equal-power pan gains (gl, gr) for the current pan position. Center
    /// (0) is −3 dB on each side; hard left/right is unity on one side, zero
    /// on the other.
    pub fn panGains(self: *const Track) struct { l: f32, r: f32 } {
        const angle = (self.pan() + 1.0) * (std.math.pi / 4.0); // 0..π/2
        return .{ .l = @cos(angle), .r = @sin(angle) };
    }

    /// Balance law for the master bus: unity at centre, turning one side
    /// down linearly. (The equal-power pan law above is -3 dB at centre,
    /// right for placing a mono source, wrong for a stereo master.)
    pub fn balanceGains(self: *const Track) struct { l: f32, r: f32 } {
        const p = self.pan();
        return .{ .l = @min(1.0, 1.0 - p), .r = @min(1.0, 1.0 + p) };
    }

    pub fn setMeter(self: *Track, l: f32, r: f32) void {
        self.meter_l.store(@bitCast(l), .monotonic);
        self.meter_r.store(@bitCast(r), .monotonic);
    }

    pub fn meter(self: *const Track) struct { l: f32, r: f32 } {
        return .{
            .l = @bitCast(self.meter_l.load(.monotonic)),
            .r = @bitCast(self.meter_r.load(.monotonic)),
        };
    }

    /// Called by the UI thread once per frame (after all mutations) to
    /// publish a frozen snapshot for the audio thread. Writes to the
    /// non-published slot, then flips the atomic index with Release ordering.
    pub fn publishSnapshot(self: *Track, pool: *const audio_pool_mod.AudioPool) void {
        const published = self.snap_published.load(.monotonic);
        const write_idx: u32 = 1 - published;
        const dst = self.snap[write_idx];

        dst.clip_count = 0;
        dst.note_count = 0;
        dst.audio_clip_count = 0;
        dst.expr_point_count = 0;
        self.publishLanes(dst);

        for (self.clips.items) |*clip| {
            if (clip.isAudio()) {
                if (dst.audio_clip_count >= snap_mod.MAX_AUDIO_CLIPS_PER_TRACK) {
                    std.debug.assert(false); // bump MAX_AUDIO_CLIPS_PER_TRACK
                    continue;
                }
                var snap = snap_mod.AudioClipSnap{
                    .start_beat = clip.start_beat,
                    .length_beats = clip.length_beats,
                    .gain = clip.audio.gain,
                };
                if (pool.get(clip.audio.source)) |src| {
                    const rate = src.sample.sample_rate;
                    snap.data = src.sample.data.ptr;
                    snap.len = @intCast(src.sample.data.len);
                    snap.source_rate = rate;
                    snap.start_sample = clip.audio.start_sec * rate;
                    snap.dur_samples = clip.audio.dur_sec * rate;
                    snap.fade_in_samples = clip.audio.fade_in_sec * rate;
                    snap.fade_out_samples = clip.audio.fade_out_sec * rate;
                }
                dst.audio_clips[dst.audio_clip_count] = snap;
                dst.audio_clip_count += 1;
                continue;
            }
            if (dst.clip_count >= snap_mod.MAX_CLIPS_PER_TRACK) {
                std.debug.assert(false); // bump MAX_CLIPS_PER_TRACK
                break;
            }
            const notes_start = dst.note_count;
            var notes_added: u32 = 0;
            for (clip.notes.items) |note| {
                if (dst.note_count >= snap_mod.MAX_NOTES_PER_TRACK) {
                    std.debug.assert(false); // bump MAX_NOTES_PER_TRACK
                    break;
                }
                dst.notes[dst.note_count] = .{
                    .start_beat = note.start_beat,
                    .length_beats = note.length_beats,
                    .pitch = note.pitch,
                    .velocity = note.velocity,
                };
                if (note.bend_n > 0 and dst.expr_point_count + note.bend_n <= snap_mod.MAX_EXPR_POINTS_PER_TRACK) {
                    dst.notes[dst.note_count].expr_start = dst.expr_point_count;
                    dst.notes[dst.note_count].expr_count = note.bend_n;
                    @memcpy(dst.expr_points[dst.expr_point_count..][0..note.bend_n], note.bendPoints());
                    dst.expr_point_count += note.bend_n;
                }
                dst.note_count += 1;
                notes_added += 1;
            }
            dst.clips[dst.clip_count] = .{
                .start_beat = clip.start_beat,
                .length_beats = clip.length_beats,
                .notes_start = notes_start,
                .notes_count = notes_added,
            };
            dst.clip_count += 1;
        }

        self.snap_published.store(write_idx, .release);
    }

    /// Resolve lanes to (slot, control index) and copy their points: track
    /// lanes, then clip lanes ordered by clip start, so the audio thread's
    /// "last lane that applies wins" is the precedence of docs/22. Lanes
    /// that are empty or whose control no longer exists are left out.
    fn publishLanes(self: *const Track, dst: *snap_mod.TrackSnapshot) void {
        dst.lane_count = 0;
        dst.auto_point_count = 0;
        for (self.lanes.items) |*lane| self.publishLane(dst, lane, null);
        // Note clips holding lanes, by start (stable: equal starts keep
        // their list order).
        var order: [snap_mod.MAX_CLIPS_PER_TRACK]u16 = undefined;
        var n: usize = 0;
        for (self.clips.items, 0..) |*clip, ci| {
            if (clip.isAudio() or clip.lanes.items.len == 0 or n >= order.len) continue;
            order[n] = @intCast(ci);
            n += 1;
        }
        std.sort.insertion(u16, order[0..n], self, struct {
            fn lt(t: *const Track, a: u16, b: u16) bool {
                return t.clips.items[a].start_beat < t.clips.items[b].start_beat;
            }
        }.lt);
        for (order[0..n]) |ci| {
            const clip = &self.clips.items[ci];
            for (clip.lanes.items) |*lane| self.publishLane(dst, lane, clip);
        }
    }

    fn publishLane(self: *const Track, dst: *snap_mod.TrackSnapshot, lane: *const automation.Lane, clip: ?*const clip_mod.Clip) void {
        const pts = lane.points.items;
        if (pts.len == 0) return;
        if (dst.lane_count >= snap_mod.MAX_LANES_PER_TRACK) return;
        if (dst.auto_point_count + pts.len > snap_mod.MAX_AUTO_POINTS_PER_TRACK) return;
        var ls = snap_mod.LaneSnap{
            .kind = lane.target.kind,
            .fx_uid = lane.target.fx_uid,
            .points_start = dst.auto_point_count,
            .points_count = @intCast(pts.len),
        };
        if (clip) |cl| {
            ls.clip_start = cl.start_beat;
            ls.clip_len = cl.length_beats;
        }
        if (self.targetMachine(lane.target)) |m| {
            const ci = m.controlIndex(lane.target.param()) orelse return;
            ls.control = @intCast(ci);
        } else if (lane.target.kind == .inst or lane.target.kind == .fx) return;
        @memcpy(dst.auto_points[dst.auto_point_count..][0..pts.len], pts);
        dst.auto_point_count += @intCast(pts.len);
        dst.lanes[dst.lane_count] = ls;
        dst.lane_count += 1;
    }

    /// The automated value (knob space) of `target` at song beat `beat`,
    /// by the audio thread's precedence: a clip lane while its clip plays
    /// (the later-starting clip on overlap), else the track lane. Null
    /// when no lane speaks there.
    pub fn autoValue(self: *Track, target: automation.Target, beat: f64) ?f32 {
        var best: ?f32 = null;
        var best_start: f64 = -std.math.inf(f64);
        for (self.clips.items) |*clip| {
            if (clip.isAudio() or clip.lanes.items.len == 0) continue;
            if (beat < clip.start_beat or beat >= clip.endBeat()) continue;
            if (clip.start_beat < best_start) continue;
            const l = clip.findLane(target) orelse continue;
            const v = l.value(beat - clip.start_beat) orelse continue;
            best = v;
            best_start = clip.start_beat;
        }
        if (best) |v| return v;
        if (self.findLane(target)) |l| return l.value(beat);
        return null;
    }

    /// Whether any lane (track or clip) with points drives `target`.
    pub fn isAutomated(self: *Track, target: automation.Target) bool {
        if (self.findLane(target)) |l| if (l.points.items.len > 0) return true;
        for (self.clips.items) |*clip| {
            if (clip.findLane(target)) |l| if (l.points.items.len > 0) return true;
        }
        return false;
    }

    /// Volume in effect at `beat` for the UI (the audio thread ramps the
    /// same lane per block): the lane unless overridden, else the fader.
    pub fn volumeAt(self: *Track, beat: f64) f32 {
        if (self.vol_override.load(.monotonic) == 0) {
            if (self.autoValue(automation.Target.volume(), beat)) |k| return k * 1.25;
        }
        return self.volume();
    }

    pub fn panAt(self: *Track, beat: f64) f32 {
        if (self.pan_override.load(.monotonic) == 0) {
            if (self.autoValue(automation.Target.pan(), beat)) |k| return k * 2 - 1;
        }
        return self.pan();
    }

    /// Called by the audio thread. Returns a pointer to the currently
    /// published snapshot. Load the pointer once per block and hold it
    /// for the block's duration — never call this inside inner loops.
    pub fn currentSnapshot(self: *const Track) *const snap_mod.TrackSnapshot {
        const idx = self.snap_published.load(.acquire);
        return self.snap[idx];
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "publishSnapshot round-trip" {
    const alloc = testing.allocator;
    const machine_mod = @import("machine.zig");
    var t = try Track.init(alloc, "test", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, machine_mod.Machine{
        .name = "test",
        .state = undefined,
        .render = struct {
            fn f(_: *anyopaque, _: *const machine_mod.MachineCtx, _: []f32, _: []f32) void {}
        }.f,
        .draw_panel = struct {
            fn f(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    });
    defer t.deinit(alloc);

    var clip = clip_mod.Clip.init("A", 2.0, 4.0);
    try clip.addNote(alloc, .{ .pitch = 60, .start_beat = 0.5, .length_beats = 1.0, .velocity = 80 });
    try t.addClip(alloc, clip);
    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    t.publishSnapshot(&pool);

    const s = t.currentSnapshot();
    try testing.expectEqual(@as(u32, 1), s.clip_count);
    try testing.expectEqual(@as(f64, 2.0), s.clips[0].start_beat);
    try testing.expectEqual(@as(f64, 4.0), s.clips[0].length_beats);
    try testing.expectEqual(@as(u32, 1), s.clips[0].notes_count);
    try testing.expectEqual(@as(u32, 1), s.note_count);
    try testing.expectEqual(@as(u8, 60), s.notes[0].pitch);
    try testing.expectEqual(@as(u8, 80), s.notes[0].velocity);
    try testing.expectApproxEqAbs(@as(f64, 0.5), s.notes[0].start_beat, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), s.notes[0].length_beats, 1e-12);
}

fn testMachine() machine.Machine {
    return machine.Machine{
        .name = "fx",
        .state = undefined,
        .render = struct {
            fn f(_: *anyopaque, _: *const machine.MachineCtx, _: []f32, _: []f32) void {}
        }.f,
        .draw_panel = struct {
            fn f(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };
}

test "removeEffect shifts chain and bypass travels with the slot" {
    const alloc = testing.allocator;
    var t = try Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, testMachine());
    defer t.deinit(alloc);

    // Build an unbounded chain past the old fixed 16-slot cap.
    var i: u8 = 0;
    while (i < 20) : (i += 1) try t.addEffect(alloc, testMachine(), i);
    try testing.expectEqual(@as(usize, 20), t.effectCount());

    // Bypass a few effects, including one past the old 16-bit mask range.
    t.toggleEffectBypass(0);
    t.toggleEffectBypass(5);
    t.toggleEffectBypass(18);
    try testing.expect(t.effectBypassed(0));
    try testing.expect(t.effectBypassed(5));
    try testing.expect(t.effectBypassed(18));

    // Removing the last effect is fine; nothing shifts into the freed slot.
    t.removeEffect(alloc, 19);
    try testing.expectEqual(@as(usize, 19), t.effectCount());
    try testing.expect(t.effectBypassed(18));

    // Removing a middle effect shifts higher bypass flags down by one.
    t.removeEffect(alloc, 0); // bypass at 5 moves to index 4
    try testing.expect(!t.effectBypassed(0));
    try testing.expect(t.effectBypassed(4));
    try testing.expectEqual(@as(usize, 18), t.effectCount());

    // Out-of-range removal is a no-op.
    const before = t.effectCount();
    t.removeEffect(alloc, 999);
    try testing.expectEqual(before, t.effectCount());
}

test "moveEffect reorders and bypass follows the moved slot" {
    const alloc = testing.allocator;
    var t = try Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, testMachine());
    defer t.deinit(alloc);

    var i: u8 = 0;
    while (i < 4) : (i += 1) try t.addEffect(alloc, testMachine(), i);
    t.toggleEffectBypass(0); // bypass the head effect

    // Move the bypassed head to the tail; its bypass flag travels with it.
    t.moveEffect(0, 3);
    try testing.expectEqual(@as(?u8, 1), t.effects.items[0].idx);
    try testing.expectEqual(@as(?u8, 0), t.effects.items[3].idx);
    try testing.expect(!t.effectBypassed(0));
    try testing.expect(t.effectBypassed(3));
}

test "clip lanes override the track lane while their clip plays, later start wins" {
    const alloc = testing.allocator;
    var t = try Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, testMachine());
    defer t.deinit(alloc);
    const vol = automation.Target.volume();
    const tl = try t.laneFor(alloc, vol, false);
    _ = try tl.insert(alloc, .{ .beat = 0, .value = 0.1 });

    // Clip A [4, 12) holds 0.5; clip B [8, 16) ramps 0.2 → 0.6 over its span.
    var a = clip_mod.Clip.init("A", 4, 8);
    _ = try (try a.laneFor(alloc, vol, false)).insert(alloc, .{ .beat = 0, .value = 0.5 });
    var b = clip_mod.Clip.init("B", 8, 8);
    const bl = try b.laneFor(alloc, vol, false);
    _ = try bl.insert(alloc, .{ .beat = 0, .value = 0.2 });
    _ = try bl.insert(alloc, .{ .beat = 8, .value = 0.6 });
    // Listed B first: precedence goes by start, not list order.
    try t.addClip(alloc, b);
    try t.addClip(alloc, a);

    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    t.publishSnapshot(&pool);
    const snap = t.currentSnapshot();
    try testing.expectEqual(@as(u32, 3), snap.lane_count);

    const cases = [_]struct { beat: f64, want: f32 }{
        .{ .beat = 2, .want = 0.1 }, // track lane
        .{ .beat = 6, .want = 0.5 }, // clip A
        .{ .beat = 10, .want = 0.3 }, // B started later: it wins
        .{ .beat = 14, .want = 0.5 },
        .{ .beat = 20, .want = 0.1 }, // back to the track
    };
    for (cases) |cs| {
        const audio_v = snap.faderValue(.volume, cs.beat, &t.auto_cursors).?;
        try testing.expectApproxEqAbs(cs.want, audio_v, 1e-6);
        try testing.expectApproxEqAbs(cs.want, t.autoValue(vol, cs.beat).?, 1e-6);
    }
    try testing.expect(t.isAutomated(automation.Target.pan()) == false);
}

test "splitting a clip's lanes keeps both halves playing the same curve" {
    const alloc = testing.allocator;
    var left = clip_mod.Clip.init("A", 0, 8);
    defer left.deinit(alloc);
    const l = try left.laneFor(alloc, automation.Target.volume(), false);
    _ = try l.insert(alloc, .{ .beat = 0, .value = 0 });
    _ = try l.insert(alloc, .{ .beat = 8, .value = 0.8 });
    var right = clip_mod.Clip.init("A", 3, 5);
    defer right.deinit(alloc);
    try left.splitLanes(alloc, &right, 3);
    const lv = left.lanes.items[0].value(2.5).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), lv, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), left.lanes.items[0].value(3).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.3), right.lanes.items[0].value(0).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), right.lanes.items[0].value(2).?, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), right.lanes.items[0].value(5).?, 1e-6);
}
