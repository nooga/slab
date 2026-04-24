//! Track: one audio path hosting a single machine (for now — insert
//! chain later). Volume/mute/solo are UI-owned atomics consumed by
//! the engine on the audio thread.

const std = @import("std");
const c = @import("c.zig");
const machine = @import("machine.zig");
const clip_mod = @import("clip.zig");
const snap_mod = @import("snapshot.zig");

pub const MAX_NAME = 32;

pub const Track = struct {
    name_buf: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    color: c.rl.Color,
    machine: machine.Machine,
    /// Registry index for persistence. Null means the silent placeholder.
    machine_idx: ?u8 = null,

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

    pub fn addClip(self: *Track, alloc: std.mem.Allocator, clip: clip_mod.Clip) !void {
        try self.clips.append(alloc, clip);
    }

    pub fn name(self: *const Track) []const u8 {
        return self.name_buf[0..self.name_len];
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
    pub fn publishSnapshot(self: *Track) void {
        const published = self.snap_published.load(.monotonic);
        const write_idx: u32 = 1 - published;
        const dst = self.snap[write_idx];

        dst.clip_count = 0;
        dst.note_count = 0;

        for (self.clips.items) |*clip| {
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
        .state = undefined,
        .render = struct {
            fn f(_: *anyopaque, _: *const machine_mod.MachineCtx, _: []f32, _: []f32) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    });
    defer t.deinit(alloc);

    var clip = clip_mod.Clip.init("A", 2.0, 4.0);
    try clip.addNote(alloc, .{ .pitch = 60, .start_beat = 0.5, .length_beats = 1.0, .velocity = 80 });
    try t.addClip(alloc, clip);
    t.publishSnapshot();

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
