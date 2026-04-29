//! Project save/load.
//!
//! The format is deliberately line-oriented text while the document
//! model is still changing.  It is also the undo snapshot format.

const std = @import("std");
const c = @import("c.zig");
const track_mod = @import("track.zig");
const clip_mod = @import("clip.zig");
const registry_mod = @import("machine_registry.zig");
const transport_mod = @import("transport.zig");
const machine_mod = @import("machine.zig");

extern fn close(fd: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn fstat(fd: c_int, sb: *std.c.Stat) c_int;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

pub const SAVE_PATH = "slab-project.slab";

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_RDONLY);
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);

    var st: std.c.Stat = undefined;
    if (fstat(fd, &st) != 0) return error.StatFailed;
    const sz: usize = @intCast(st.size);
    const buf = try alloc.alloc(u8, sz);
    errdefer alloc.free(buf);

    var done: usize = 0;
    while (done < sz) {
        const n = std.posix.read(@intCast(fd), buf[done..]) catch return error.ReadFailed;
        if (n == 0) break;
        done += n;
    }
    if (done != sz) return error.ReadFailed;
    return buf;
}

pub fn writeFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);

    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.write(fd, data[done..].ptr, data.len - done);
        if (n <= 0) return error.WriteFailed;
        done += @intCast(n);
    }
}

pub fn serialize(alloc: std.mem.Allocator, tracks: []const track_mod.Track, transport: *const transport_mod.Transport) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "SLAB1\n");
    try appendFmt(alloc, &out, "LOOP\t{d}\t{d:.6}\t{d:.6}\t{d:.3}\n", .{
        @intFromBool(transport.loopEnabled()),
        transport.loopStartBeats(),
        transport.loopEndBeats(),
        transport.bpm(),
    });
    try appendFmt(alloc, &out, "TRACKS\t{d}\n", .{tracks.len});

    for (tracks) |*t| {
        const machine_idx: i32 = if (t.machine_idx) |idx| @intCast(idx) else -1;
        try appendFmt(alloc, &out, "TRACK\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.6}\t{d}\t{d}\t{d}\t{d}\n", .{
            t.name(),
            machine_idx,
            t.color.r,
            t.color.g,
            t.color.b,
            t.volume(),
            @intFromBool(t.mute.load(.monotonic)),
            @intFromBool(t.solo.load(.monotonic)),
            t.clips.items.len,
            t.poly_voices,
        });
        for (t.clips.items) |*clip| {
            try appendFmt(alloc, &out, "CLIP\t{s}\t{d:.6}\t{d:.6}\t{d}\n", .{
                clip.name(),
                clip.start_beat,
                clip.length_beats,
                clip.notes.items.len,
            });
            for (clip.notes.items) |note| {
                try appendFmt(alloc, &out, "NOTE\t{d}\t{d:.6}\t{d:.6}\t{d}\n", .{
                    note.pitch,
                    note.start_beat,
                    note.length_beats,
                    note.velocity,
                });
            }
        }
    }

    return try out.toOwnedSlice(alloc);
}

pub fn apply(
    alloc: std.mem.Allocator,
    data: []const u8,
    reg: *registry_mod.Registry,
    tracks_buf: []track_mod.Track,
    track_count: *usize,
    transport: *transport_mod.Transport,
    silent_machine: machine_mod.Machine,
) !void {
    var parser = Parser.init(data);
    const magic = parser.next() orelse return error.InvalidProject;
    if (!std.mem.eql(u8, trim(magic), "SLAB1")) return error.InvalidProject;

    const loop_line = parser.next() orelse return error.InvalidProject;
    try parseLoop(loop_line, transport);

    const track_count_line = parser.next() orelse return error.InvalidProject;
    const requested_tracks = try parseCountLine(track_count_line, "TRACKS");
    if (requested_tracks > tracks_buf.len) return error.TooManyTracks;

    for (tracks_buf[0..track_count.*]) |*t| t.deinit(alloc);
    track_count.* = 0;
    errdefer {
        for (tracks_buf[0..track_count.*]) |*t| t.deinit(alloc);
        track_count.* = 0;
    }

    var ti: usize = 0;
    while (ti < requested_tracks) : (ti += 1) {
        const track_line = parser.next() orelse return error.InvalidProject;
        var fields = split(track_line);
        if (!std.mem.eql(u8, nextField(&fields) orelse "", "TRACK")) return error.InvalidProject;
        const name = nextField(&fields) orelse return error.InvalidProject;
        const machine_idx_raw = try parseI32(nextField(&fields) orelse return error.InvalidProject);
        const r = try parseU8(nextField(&fields) orelse return error.InvalidProject);
        const g = try parseU8(nextField(&fields) orelse return error.InvalidProject);
        const b = try parseU8(nextField(&fields) orelse return error.InvalidProject);
        const volume = try parseF32(nextField(&fields) orelse return error.InvalidProject);
        const mute = try parseBool(nextField(&fields) orelse return error.InvalidProject);
        const solo = try parseBool(nextField(&fields) orelse return error.InvalidProject);
        const clip_count = try parseUsize(nextField(&fields) orelse return error.InvalidProject);
        const poly_voices = normalizePolyVoices(if (nextField(&fields)) |raw| try parseU8(raw) else 1);

        var mach = silent_machine;
        var machine_idx: ?u8 = null;
        if (machine_idx_raw >= 0) {
            const idx: usize = @intCast(machine_idx_raw);
            if (idx < reg.count) {
                mach = try reg.instantiateWithPolyphony(idx, poly_voices);
                machine_idx = @intCast(idx);
            }
        }

        var t = try track_mod.Track.init(alloc, name, .{ .r = r, .g = g, .b = b, .a = 255 }, mach);
        errdefer t.deinit(alloc);
        t.machine_idx = machine_idx;
        t.poly_voices = poly_voices;
        t.setVolume(volume);
        t.mute.store(mute, .monotonic);
        t.solo.store(solo, .monotonic);

        var ci: usize = 0;
        while (ci < clip_count) : (ci += 1) {
            const clip_line = parser.next() orelse return error.InvalidProject;
            var clip_fields = split(clip_line);
            if (!std.mem.eql(u8, nextField(&clip_fields) orelse "", "CLIP")) return error.InvalidProject;
            const clip_name = nextField(&clip_fields) orelse return error.InvalidProject;
            const start = try parseF64(nextField(&clip_fields) orelse return error.InvalidProject);
            const len = try parseF64(nextField(&clip_fields) orelse return error.InvalidProject);
            const note_count = try parseUsize(nextField(&clip_fields) orelse return error.InvalidProject);
            var clip = clip_mod.Clip.init(clip_name, start, len);
            errdefer clip.deinit(alloc);

            var ni: usize = 0;
            while (ni < note_count) : (ni += 1) {
                const note_line = parser.next() orelse return error.InvalidProject;
                var note_fields = split(note_line);
                if (!std.mem.eql(u8, nextField(&note_fields) orelse "", "NOTE")) return error.InvalidProject;
                try clip.addNote(alloc, .{
                    .pitch = try parseU8(nextField(&note_fields) orelse return error.InvalidProject),
                    .start_beat = try parseF64(nextField(&note_fields) orelse return error.InvalidProject),
                    .length_beats = try parseF64(nextField(&note_fields) orelse return error.InvalidProject),
                    .velocity = try parseU8(nextField(&note_fields) orelse return error.InvalidProject),
                });
            }
            try t.addClip(alloc, clip);
        }

        tracks_buf[ti] = t;
        track_count.* += 1;
    }
}

fn appendFmt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

const Parser = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    fn init(data: []const u8) Parser {
        return .{ .it = std.mem.splitScalar(u8, data, '\n') };
    }

    fn next(self: *Parser) ?[]const u8 {
        while (self.it.next()) |line| {
            const t = trim(line);
            if (t.len == 0) continue;
            return t;
        }
        return null;
    }
};

fn split(line: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, line, '\t');
}

fn nextField(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    return if (it.next()) |f| trim(f) else null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n");
}

fn parseLoop(line: []const u8, transport: *transport_mod.Transport) !void {
    var fields = split(line);
    if (!std.mem.eql(u8, nextField(&fields) orelse "", "LOOP")) return error.InvalidProject;
    const enabled = try parseBool(nextField(&fields) orelse return error.InvalidProject);
    const start = try parseF64(nextField(&fields) orelse return error.InvalidProject);
    const end = try parseF64(nextField(&fields) orelse return error.InvalidProject);
    const bpm = try parseF32(nextField(&fields) orelse return error.InvalidProject);
    transport.setBpm(bpm);
    transport.setLoopBeats(start, end);
    transport.setLoopEnabled(enabled);
}

fn parseCountLine(line: []const u8, tag: []const u8) !usize {
    var fields = split(line);
    if (!std.mem.eql(u8, nextField(&fields) orelse "", tag)) return error.InvalidProject;
    return parseUsize(nextField(&fields) orelse return error.InvalidProject);
}

fn parseBool(s: []const u8) !bool {
    const v = try parseUsize(s);
    return v != 0;
}

fn parseUsize(s: []const u8) !usize {
    return std.fmt.parseInt(usize, s, 10);
}

fn parseI32(s: []const u8) !i32 {
    return std.fmt.parseInt(i32, s, 10);
}

fn parseU8(s: []const u8) !u8 {
    return std.fmt.parseInt(u8, s, 10);
}

fn normalizePolyVoices(v: u8) u8 {
    if (v >= 16) return 16;
    if (v >= 8) return 8;
    if (v >= 4) return 4;
    return 1;
}

fn parseF32(s: []const u8) !f32 {
    return std.fmt.parseFloat(f32, s);
}

fn parseF64(s: []const u8) !f64 {
    return std.fmt.parseFloat(f64, s);
}

fn testRender(_: *anyopaque, _: *const machine_mod.MachineCtx, l: []f32, r: []f32) void {
    @memset(l, 0);
    @memset(r, 0);
}

fn testReset(_: *anyopaque) void {}
fn testDraw(_: *anyopaque, _: c.rl.Rectangle, _: @import("ui/widgets.zig").Mouse) void {}

var test_machine_state: u8 = 0;
const test_machine = machine_mod.Machine{
    .name = "(test)",
    .state = &test_machine_state,
    .render = testRender,
    .draw_panel = testDraw,
    .reset = testReset,
};

test "project snapshot round-trips tracks clips notes and loop" {
    const alloc = std.testing.allocator;

    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;
    transport.setBpm(132.5);
    transport.setLoopBeats(1.0, 9.0);

    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "Track 1", .{ .r = 10, .g = 20, .b = 30, .a = 255 }, test_machine),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    tracks[0].setVolume(0.625);
    tracks[0].mute.store(true, .monotonic);
    var clip = clip_mod.Clip.init("Clip A", 2.0, 4.0);
    try clip.addNote(alloc, .{ .pitch = 64, .start_beat = 0.5, .length_beats = 1.25, .velocity = 91 });
    try tracks[0].addClip(alloc, clip);

    const bytes = try serialize(alloc, tracks[0..], &transport);
    defer alloc.free(bytes);

    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    var loaded_transport: transport_mod.Transport = .{};
    loaded_transport.sample_rate = 48_000;
    var loaded_buf: [2]track_mod.Track = undefined;
    var loaded_count: usize = 0;
    try apply(alloc, bytes, &reg, loaded_buf[0..], &loaded_count, &loaded_transport, test_machine);
    defer for (loaded_buf[0..loaded_count]) |*t| t.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), loaded_count);
    try std.testing.expectEqualStrings("Track 1", loaded_buf[0].name());
    try std.testing.expectEqual(@as(u8, 10), loaded_buf[0].color.r);
    try std.testing.expectEqual(true, loaded_buf[0].mute.load(.monotonic));
    try std.testing.expectApproxEqAbs(@as(f32, 0.625), loaded_buf[0].volume(), 0.0001);
    try std.testing.expectEqual(@as(usize, 1), loaded_buf[0].clips.items.len);
    try std.testing.expectEqualStrings("Clip A", loaded_buf[0].clips.items[0].name());
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), loaded_buf[0].clips.items[0].start_beat, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), loaded_buf[0].clips.items[0].notes.items.len);
    try std.testing.expectEqual(@as(u8, 64), loaded_buf[0].clips.items[0].notes.items[0].pitch);
    try std.testing.expectEqual(@as(u8, 91), loaded_buf[0].clips.items[0].notes.items[0].velocity);
    try std.testing.expectEqual(true, loaded_transport.loopEnabled());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), loaded_transport.loopStartBeats(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), loaded_transport.loopEndBeats(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 132.5), loaded_transport.bpm(), 0.001);
}
