//! A bounce you can thaw (docs/27 §Provenance). A bounced clip keeps the
//! ids of the clips it was rendered from, how (tap, tail), and a
//! fingerprint of everything the render heard: each source track's
//! instrument, settings, inserts and lanes (fader, pan and sends when the
//! tap printed them), the code its machines run, the source clips
//! themselves, the buses +SENDS printed, and the tempo. Renders are
//! deterministic, so a matching fingerprint means a re-bounce would make
//! the same clip; a changed one marks the clip stale.

const std = @import("std");
const clip_mod = @import("clip.zig");
const track_mod = @import("track.zig");
const transport_mod = @import("transport.zig");
const document = @import("document.zig");
const build_options = @import("build_options");

pub const Tap = enum(u8) { instr = 0, fx = 1, fader = 2, sends = 3 };

pub const Found = struct { track: usize, clip: usize };

/// The clip with id `uid`.
pub fn find(tracks: []const track_mod.Track, uid: u32) ?Found {
    for (tracks, 0..) |*t, ti| for (t.clips.items, 0..) |*cl, ci| {
        if (cl.uid == uid) return .{ .track = ti, .clip = ci };
    };
    return null;
}

/// The tracks holding the recipe's sources; null when one is gone.
pub fn sourceTracks(tracks: []const track_mod.Track, r: *const clip_mod.Recipe) ?u32 {
    var set: u32 = 0;
    for (r.ids()) |id| {
        const f = find(tracks, id) orelse return null;
        set |= @as(u32, 1) << @intCast(f.track);
    }
    return set;
}

/// The recipe's fingerprint as the project stands; null when a source
/// clip is gone.
pub fn fingerprint(alloc: std.mem.Allocator, tracks: []const track_mod.Track, transport: *const transport_mod.Transport, r: *const clip_mod.Recipe) !?u64 {
    const set = sourceTracks(tracks, r) orelse return null;
    const tap: Tap = @enumFromInt(@min(r.tap, 3));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var h = std.hash.Wyhash.init(0);
    var head: [96]u8 = undefined;
    h.update(std.fmt.bufPrint(&head, "slab {s} tap {d} tail {d} bpm {d}", .{
        build_options.version, r.tap, if (r.tail_auto) -1 else r.tail_sec, transport.bpm(),
    }) catch "");
    var buses: u32 = 0;
    for (tracks, 0..) |*t, ti| if (set & (@as(u32, 1) << @intCast(ti)) != 0) {
        try hashTrack(alloc, &out, &h, t, tap != .instr and tap != .fx, tap == .sends);
        if (tap == .sends) for (t.sends[0..t.send_count]) |s| {
            buses |= @as(u32, 1) << @intCast(s.bus);
        };
    };
    for (tracks, 0..) |*t, ti| if (buses & (@as(u32, 1) << @intCast(ti)) != 0) {
        try hashTrack(alloc, &out, &h, t, true, false);
    };
    for (r.ids()) |id| {
        const f = find(tracks, id).?;
        out.clearRetainingCapacity();
        var c = tracks[f.track].clips.items[f.clip];
        // Where it sits counts; whether it's muted or selected doesn't.
        c.muted = false;
        try document.appendClip(alloc, &out, &tracks[f.track], &c, .{ .identity = false });
        h.update(out.items);
    }
    return h.final();
}

fn hashTrack(alloc: std.mem.Allocator, out: *std.ArrayList(u8), h: *std.hash.Wyhash, t: *const track_mod.Track, fader: bool, sends: bool) !void {
    out.clearRetainingCapacity();
    try document.appendRenderSettings(alloc, out, t, fader, sends);
    h.update(out.items);
    var codes: [17]u64 = undefined;
    var n: usize = 0;
    if (t.machine.code_hash) |f| {
        codes[n] = f(t.machine.state);
        n += 1;
    }
    for (t.effects.items) |*fx| if (fx.mach.code_hash) |f| {
        if (n == codes.len) break;
        codes[n] = f(fx.mach.state);
        n += 1;
    };
    h.update(std.mem.sliceAsBytes(codes[0..n]));
}

/// Mark each recipe clip stale or fresh. UI thread.
pub fn checkAll(alloc: std.mem.Allocator, tracks: []track_mod.Track, transport: *const transport_mod.Transport) void {
    for (tracks) |*t| for (t.clips.items) |*cl| {
        if (cl.recipe == null) continue;
        const r = &cl.recipe.?;
        const now = fingerprint(alloc, tracks, transport, r) catch continue;
        r.stale = if (now) |fp| fp != r.hash else false;
    };
}
