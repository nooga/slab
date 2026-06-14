//! Track: one audio path hosting an instrument plus a small fixed insert
//! chain. Volume/mute/solo are UI-owned atomics consumed by the engine on
//! the audio thread.

const std = @import("std");
const c = @import("c.zig");
const machine = @import("machine.zig");
const clip_mod = @import("clip.zig");
const snap_mod = @import("snapshot.zig");
const audio_pool_mod = @import("audio_pool.zig");

pub const MAX_NAME = 32;
pub const MAX_EFFECTS = 16;

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
    /// 1 = mono. Larger values wrap the assigned machine in a host-side
    /// poly allocator with this many independent instances.
    poly_voices: u8 = 1,
    effects: [MAX_EFFECTS]machine.Machine = undefined,
    effect_count: u8 = 0,
    effect_idx: [MAX_EFFECTS]?u8 = [_]?u8{null} ** MAX_EFFECTS,

    /// Clip list — UI-thread-owned. Audio thread reads via snapshot only.
    clips: std.ArrayList(clip_mod.Clip) = .empty,

    /// Double-buffered clip/note snapshot for lock-free audio access.
    /// UI writes to the non-published slot then flips snap_published.
    snap: [2]*snap_mod.TrackSnapshot,
    snap_published: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// 0..1 linear gain, bit-cast for atomic.
    volume_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0.8))),
    mute: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    solo: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Meter levels written by engine, read by UI. Peak per channel,
    /// decaying toward zero each UI frame.
    meter_l: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    meter_r: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Instrument enable. When false the engine skips the instrument
    /// render and feeds silence into the effect chain. UI-owned, read by
    /// the audio thread — a plain atomic flip, no chain mutation.
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Per-effect bypass bitmask — bit i set = effect i is bypassed
    /// (passed through untouched). UI-owned, read by the audio thread.
    effect_bypass: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
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
        for (self.effects[0..self.effect_count]) |*fx| {
            if (fx.deinit) |deinit_fn| {
                deinit_fn(fx.state, alloc);
            }
        }
        for (self.clips.items) |*clip| clip.deinit(alloc);
        self.clips.deinit(alloc);
        alloc.destroy(self.snap[0]);
        alloc.destroy(self.snap[1]);
    }

    pub fn replaceMachine(self: *Track, alloc: std.mem.Allocator, mach: machine.Machine) void {
        if (self.machine.deinit) |deinit_fn| {
            deinit_fn(self.machine.state, alloc);
        }
        self.machine = mach;
    }

    pub fn addEffect(self: *Track, mach: machine.Machine, idx: u8) !void {
        if (self.effect_count >= MAX_EFFECTS) return error.EffectChainFull;
        self.effects[self.effect_count] = mach;
        self.effect_idx[self.effect_count] = idx;
        self.effect_count += 1;
    }

    /// Remove effect `i`, deinit it, shift the tail down, and slide the
    /// bypass bitmask to match. Caller must hold the audio thread (stop
    /// the device) — this mutates the chain the engine reads.
    pub fn removeEffect(self: *Track, alloc: std.mem.Allocator, i: usize) void {
        if (i >= self.effect_count) return;
        if (self.effects[i].deinit) |deinit_fn| deinit_fn(self.effects[i].state, alloc);
        var j = i;
        while (j + 1 < self.effect_count) : (j += 1) {
            self.effects[j] = self.effects[j + 1];
            self.effect_idx[j] = self.effect_idx[j + 1];
        }
        self.effect_count -= 1;
        self.effect_idx[self.effect_count] = null;
        // Rebuild the bypass mask: drop bit i, shift higher bits down.
        const old = self.effect_bypass.load(.monotonic);
        const low_mask: u16 = (@as(u16, 1) << @intCast(i)) - 1;
        const low = old & low_mask;
        // No bits above index 15 exist; guard the shift so i==15 can't trap.
        const high: u16 = if (i + 1 < 16) (old >> @intCast(i + 1)) << @intCast(i) else 0;
        self.effect_bypass.store(low | high, .monotonic);
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

    pub fn effectBypassed(self: *const Track, i: usize) bool {
        if (i >= 16) return false;
        return (self.effect_bypass.load(.monotonic) & (@as(u16, 1) << @intCast(i))) != 0;
    }

    pub fn toggleEffectBypass(self: *Track, i: usize) void {
        if (i >= 16) return;
        const bit = @as(u16, 1) << @intCast(i);
        self.effect_bypass.store(self.effect_bypass.load(.monotonic) ^ bit, .monotonic);
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
            fn f(_: *anyopaque, _: @import("c.zig").rl.Rectangle, _: @import("ui/widgets.zig").Mouse) void {}
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
            fn f(_: *anyopaque, _: c.rl.Rectangle, _: @import("ui/widgets.zig").Mouse) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };
}

test "removeEffect shifts chain and bypass mask" {
    const alloc = testing.allocator;
    var t = try Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, testMachine());
    defer t.deinit(alloc);

    // Fill the whole chain so the i==15 edge is exercised.
    var i: u8 = 0;
    while (i < MAX_EFFECTS) : (i += 1) try t.addEffect(testMachine(), i);
    try testing.expectEqual(@as(u8, MAX_EFFECTS), t.effect_count);

    // Bypass a few effects across the range, including the last bit.
    t.toggleEffectBypass(0);
    t.toggleEffectBypass(5);
    t.toggleEffectBypass(15);
    try testing.expect(t.effectBypassed(0));
    try testing.expect(t.effectBypassed(5));
    try testing.expect(t.effectBypassed(15));

    // Removing the last effect must not trap on the shift, and clears bit 15.
    t.removeEffect(alloc, 15);
    try testing.expectEqual(@as(u8, MAX_EFFECTS - 1), t.effect_count);
    try testing.expect(t.effectBypassed(0));
    try testing.expect(t.effectBypassed(5));
    try testing.expect(!t.effectBypassed(14)); // nothing shifted into the freed slot

    // Removing a middle effect shifts higher bypass bits down by one.
    t.removeEffect(alloc, 0); // drop bit 0; bit 5 moves to index 4
    try testing.expect(!t.effectBypassed(0));
    try testing.expect(t.effectBypassed(4));
    try testing.expectEqual(@as(u8, MAX_EFFECTS - 2), t.effect_count);

    // Out-of-range removal is a no-op.
    const before = t.effect_count;
    t.removeEffect(alloc, 999);
    try testing.expectEqual(before, t.effect_count);
}
