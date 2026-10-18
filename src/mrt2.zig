//! Render with MRT2 (docs/42): a pattern clip's notes played by Magenta
//! RealTime 2 into an audio clip. The model runs in `mrt_render`, a child
//! process the MRT2 pack builds (tools/mrt2), so MLX and TFLite stay out of
//! slab's build and process. This file writes the clip as a MIDI file,
//! starts the renderer and follows it; main places the WAV it writes.
//! Everything here runs on the UI thread.

const std = @import("std");
const storage = @import("storage.zig");
const clip_mod = @import("clip.zig");
const tempo_mod = @import("tempo.zig");

/// Seconds rendered past the clip's end, for the release and the room.
pub const TAIL_SEC: f64 = 2.0;
pub const MODEL = "mrt2_small";

const BIN = "bin/mrt_render";
const MODEL_FILE = "models/" ++ MODEL ++ "/" ++ MODEL ++ ".mlxfn";

/// The pack's renderer and model are installed.
pub fn present() bool {
    var lb: [storage.MAX_PATH]u8 = undefined;
    const lib = storage.library(&lb);
    var pb: [storage.MAX_PATH:0]u8 = undefined;
    for ([_][]const u8{ BIN, MODEL_FILE }) |rel| {
        const p = std.fmt.bufPrintZ(&pb, "{s}/mrt2/{s}", .{ lib, rel }) catch return false;
        if (access(p.ptr, 0) != 0) return false;
    }
    return true;
}

/// Seconds `clip` plays for, from its start, by the tempo map.
pub fn clipSeconds(clip: *const clip_mod.Clip, map: *const tempo_mod.TempoMap) f64 {
    return map.secondsAt(clip.start_beat + clip.length_beats) - map.secondsAt(clip.start_beat);
}

/// `clip`'s notes as a Standard MIDI File, timed from the clip's start by
/// `map`. One tick is a millisecond (1000 ticks a quarter at 60 BPM), so
/// the song's tempo changes are already in the ticks. Notes are cut at the
/// clip's end; the track's polytempo and groove don't apply (docs/42 §Timing).
pub fn midiFile(alloc: std.mem.Allocator, clip: *const clip_mod.Clip, map: *const tempo_mod.TempoMap) ![]u8 {
    const Ev = struct { tick: u32, on: bool, pitch: u8 };
    var evs: std.ArrayList(Ev) = .empty;
    defer evs.deinit(alloc);
    const t0 = map.secondsAt(clip.start_beat);
    const ms = struct {
        fn at(m: *const tempo_mod.TempoMap, t: f64, beat: f64) u32 {
            return @intFromFloat(@max(0, @round((m.secondsAt(beat) - t) * 1000)));
        }
    }.at;
    for (clip.notes.items) |n| {
        if (n.start_beat >= clip.length_beats or n.pitch > 127) continue;
        const end = @min(n.start_beat + n.length_beats, clip.length_beats);
        const on = ms(map, t0, clip.start_beat + n.start_beat);
        const off = @max(on + 1, ms(map, t0, clip.start_beat + end));
        try evs.append(alloc, .{ .tick = on, .on = true, .pitch = n.pitch });
        try evs.append(alloc, .{ .tick = off, .on = false, .pitch = n.pitch });
    }
    // Offs before ons at a tick, so a repeated pitch sounds again.
    std.mem.sort(Ev, evs.items, {}, struct {
        fn lt(_: void, a: Ev, b: Ev) bool {
            return if (a.tick != b.tick) a.tick < b.tick else !a.on and b.on;
        }
    }.lt);

    var trk: std.ArrayList(u8) = .empty;
    defer trk.deinit(alloc);
    try trk.appendSlice(alloc, &.{ 0x00, 0xff, 0x51, 0x03, 0x0f, 0x42, 0x40 }); // 1,000,000 µs a quarter
    var last: u32 = 0;
    for (evs.items) |e| {
        try vlq(alloc, &trk, e.tick - last);
        last = e.tick;
        // A fixed velocity: the model hears which notes are held, not how hard.
        try trk.appendSlice(alloc, &.{ if (e.on) 0x90 else 0x80, e.pitch, if (e.on) 100 else 0 });
    }
    try trk.appendSlice(alloc, &.{ 0x00, 0xff, 0x2f, 0x00 });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &.{ 'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 0, 0, 1, 0x03, 0xe8 });
    try out.appendSlice(alloc, "MTrk");
    try out.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(trk.items.len))));
    try out.appendSlice(alloc, trk.items);
    return out.toOwnedSlice(alloc);
}

fn vlq(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var buf: [5]u8 = undefined;
    var i: usize = buf.len - 1;
    var x = v;
    buf[i] = @intCast(x & 0x7f);
    while (x > 0x7f) {
        x >>= 7;
        i -= 1;
        buf[i] = @intCast((x & 0x7f) | 0x80);
    }
    try out.appendSlice(alloc, buf[i..]);
}

pub const Settings = struct {
    prompt: []const u8,
    seed: u32,
};

/// One render at a time: the clip it came from (by uid, as tracks may move
/// while it runs), the renderer's process, and where its WAV goes.
pub const Job = struct {
    active: bool = false,
    running: bool = false,
    ok: bool = false,
    cancelled: bool = false,
    pid: c_int = 0,
    uid: u32 = 0,
    seed: u32 = 0,
    wav: [storage.MAX_PATH]u8 = undefined,
    wav_len: usize = 0,
    log: [storage.MAX_PATH]u8 = undefined,
    log_len: usize = 0,
    line: [96]u8 = undefined,
    line_len: usize = 0,

    pub fn wavPath(self: *const Job) []const u8 {
        return self.wav[0..self.wav_len];
    }

    /// The renderer's last line: its progress, or why it stopped.
    pub fn lastLine(self: *const Job) []const u8 {
        return self.line[0..self.line_len];
    }

    /// Write `clip` as MIDI and start rendering it. Returns why it can't.
    pub fn start(self: *Job, alloc: std.mem.Allocator, clip: *const clip_mod.Clip, map: *const tempo_mod.TempoMap, s: Settings) ?[]const u8 {
        if (self.running) return "A RENDER IS ALREADY RUNNING";
        if (!present()) return "NEEDS THE MRT2 PACK (BROWSER, PACKS)";
        if (clip.isAudio() or clip.notes.items.len == 0) return "THE CLIP HAS NO NOTES";
        self.* = .{ .uid = clip.uid, .seed = s.seed };

        var hb: [storage.MAX_PATH]u8 = undefined;
        const home = storage.home(&hb);
        var cb: [storage.MAX_PATH]u8 = undefined;
        const cache = std.fmt.bufPrint(&cb, "{s}/Cache/mrt2", .{home}) catch return "NO HOME FOLDER";
        storage.makeParents(cache);
        // Clip uids restart in each slab process: the pid keeps two windows apart.
        const own_pid = getpid();
        const log = std.fmt.bufPrint(&self.log, "{s}/render-{d}.log", .{ cache, own_pid }) catch return "NO HOME FOLDER";
        self.log_len = log.len;
        var mb: [storage.MAX_PATH]u8 = undefined;
        const mid = std.fmt.bufPrint(&mb, "{s}/{d}-{d}.mid", .{ cache, clip.uid, own_pid }) catch return "PATH TOO LONG";

        var db: [storage.MAX_PATH]u8 = undefined;
        const dir = storage.recordingsDir(&db);
        if (dir.len == 0) return "NO AUDIO FOLDER";
        storage.makeParents(dir);
        var sb: [40]u8 = undefined;
        var stem_b: [64]u8 = undefined;
        const stem = std.fmt.bufPrint(&stem_b, "{s}-mrt2-seed{d}", .{ storage.slug(&sb, clip.name()), s.seed }) catch "mrt2";
        const wav = storage.freshPath(&self.wav, dir, stem, ".wav");
        if (wav.len == 0) return "NO FREE FILE NAME";
        self.wav_len = wav.len;

        const bytes = midiFile(alloc, clip, map) catch return "COULDN'T WRITE THE NOTES";
        defer alloc.free(bytes);
        if (!writeAll(mid, bytes)) return "COULDN'T WRITE THE NOTES";

        var lb: [storage.MAX_PATH]u8 = undefined;
        const lib = storage.library(&lb);
        var strs: [16][storage.MAX_PATH:0]u8 = undefined;
        var argv: [17:null]?[*:0]const u8 = @splat(null);
        var n: usize = 0;
        var fb: [storage.MAX_PATH]u8 = undefined;
        var secs_b: [32]u8 = undefined;
        var seed_b: [16]u8 = undefined;
        const args = [_][]const u8{
            std.fmt.bufPrint(&fb, "{s}/mrt2/" ++ BIN, .{lib}) catch return "PATH TOO LONG",
            "", // model, below
            "", // resources, below
            "-o",
            wav,
            "--midi",
            mid,
            "--seconds",
            std.fmt.bufPrint(&secs_b, "{d:.3}", .{clipSeconds(clip, map) + TAIL_SEC}) catch "8",
            "--prompt",
            s.prompt,
            "--seed",
            std.fmt.bufPrint(&seed_b, "{d}", .{s.seed}) catch "0",
        };
        var modb: [storage.MAX_PATH]u8 = undefined;
        var resb: [storage.MAX_PATH]u8 = undefined;
        for (args, 0..) |a, i| {
            argv[n] = z(&strs[n], switch (i) {
                1 => std.fmt.bufPrint(&modb, "{s}/mrt2/" ++ MODEL_FILE, .{lib}) catch return "PATH TOO LONG",
                2 => std.fmt.bufPrint(&resb, "{s}/mrt2/resources", .{lib}) catch return "PATH TOO LONG",
                else => a,
            });
            n += 1;
        }

        var fa: SpawnActions = null;
        if (posix_spawn_file_actions_init(&fa) != 0) return "COULDN'T START THE RENDERER";
        defer _ = posix_spawn_file_actions_destroy(&fa);
        var log_z: [storage.MAX_PATH:0]u8 = undefined;
        _ = posix_spawn_file_actions_addopen(&fa, 1, z(&log_z, log), O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        _ = posix_spawn_file_actions_adddup2(&fa, 1, 2);
        var pid: c_int = 0;
        if (posix_spawn(&pid, argv[0].?, &fa, null, &argv, environ) != 0) return "COULDN'T START THE RENDERER";
        self.pid = pid;
        self.active = true;
        self.running = true;
        return null;
    }

    /// True once the renderer has exited (then `ok` says how).
    pub fn poll(self: *Job) bool {
        if (!self.running) return false;
        self.readLastLine();
        var status: c_int = 0;
        const r = waitpid(self.pid, &status, WNOHANG);
        if (r == 0) return false;
        self.running = false;
        self.ok = r == self.pid and (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
        self.readLastLine();
        return true;
    }

    pub fn cancel(self: *Job) void {
        if (!self.running) return;
        self.cancelled = true;
        _ = kill(self.pid, SIGTERM);
    }

    /// Quitting mid-render: don't leave the renderer running.
    pub fn abandon(self: *Job) void {
        if (!self.running) return;
        _ = kill(self.pid, SIGTERM);
        var status: c_int = 0;
        _ = waitpid(self.pid, &status, 0);
        self.running = false;
    }

    fn readLastLine(self: *Job) void {
        var zb: [storage.MAX_PATH:0]u8 = undefined;
        const fd = open(z(&zb, self.log[0..self.log_len]), 0);
        if (fd < 0) return;
        defer _ = close(fd);
        const end = lseek(fd, 0, SEEK_END);
        if (end <= 0) return;
        var buf: [1024]u8 = undefined;
        _ = lseek(fd, @max(0, end - @as(i64, buf.len)), SEEK_SET);
        const got = read(fd, &buf, buf.len);
        if (got <= 0) return;
        var it = std.mem.splitBackwardsAny(u8, buf[0..@intCast(got)], "\r\n");
        while (it.next()) |l| {
            const t = std.mem.trim(u8, l, " \t");
            if (t.len == 0) continue;
            // The end of a long line: its summary sits after the file's path.
            const len = @min(t.len, self.line.len);
            @memcpy(self.line[0..len], t[t.len - len ..]);
            self.line_len = len;
            return;
        }
    }
};

fn writeAll(path: []const u8, bytes: []const u8) bool {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    const fd = open(z(&zb, path), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return false;
    defer _ = close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const w = write(fd, bytes[off..].ptr, bytes.len - off);
        if (w <= 0) return false;
        off += @intCast(w);
    }
    return true;
}

fn z(buf: *[storage.MAX_PATH:0]u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf;
}

// ── POSIX ────────────────────────────────────────────────────────────

const SpawnActions = ?*anyopaque;
extern fn posix_spawn(pid: *c_int, path: [*:0]const u8, fa: ?*const SpawnActions, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn posix_spawn_file_actions_init(fa: *SpawnActions) c_int;
extern fn posix_spawn_file_actions_destroy(fa: *SpawnActions) c_int;
extern fn posix_spawn_file_actions_addopen(fa: *SpawnActions, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: u16) c_int;
extern fn posix_spawn_file_actions_adddup2(fa: *SpawnActions, fd: c_int, newfd: c_int) c_int;
extern fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn getpid() c_int;
extern var environ: [*:null]?[*:0]const u8;
extern fn access(path: [*:0]const u8, mode: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern fn close(fd: c_int) c_int;

const WNOHANG: c_int = 1;
const SIGTERM: c_int = 15;
const O_WRONLY: c_int = 0x1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

// ── Tests ────────────────────────────────────────────────────────────

test "midiFile times notes from the clip's start through the tempo map" {
    const t = std.testing;
    const map = tempo_mod.TempoMap.constant(120);
    var clip = clip_mod.Clip.init("riff", 4, 2); // starts at 2 s
    defer clip.deinit(t.allocator);
    try clip.notes.append(t.allocator, .{ .pitch = 60, .start_beat = 0, .length_beats = 1 });
    try clip.notes.append(t.allocator, .{ .pitch = 64, .start_beat = 1.5, .length_beats = 4 }); // cut at the end
    try clip.notes.append(t.allocator, .{ .pitch = 67, .start_beat = 3, .length_beats = 1 }); // past the end
    const bytes = try midiFile(t.allocator, &clip, &map);
    defer t.allocator.free(bytes);
    try t.expectEqualSlices(u8, "MThd", bytes[0..4]);
    try t.expectEqual(@as(u16, 1000), std.mem.readInt(u16, bytes[12..14], .big));
    // C on at 0, C off at 500 ms, E on at 750 ms, E off at the clip's end (1000 ms).
    const body = bytes[22..];
    const want = [_]u8{
        0x00, 0xff, 0x51, 0x03, 0x0f, 0x42, 0x40,
        0x00, 0x90, 60,   100,
        0x83, 0x74, 0x80, 60, 0, // 500
        0x81, 0x7a, 0x90, 64, 100, // +250
        0x81, 0x7a, 0x80, 64,   0, // +250
        0x00, 0xff, 0x2f, 0x00,
    };
    try t.expectEqualSlices(u8, &want, body);
    try t.expectApproxEqAbs(@as(f64, 1.0), clipSeconds(&clip, &map), 1e-9);
}

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn usleep(us: c_uint) c_int;
extern fn unlink(path: [*:0]const u8) c_int;

// Runs the real renderer: only with SLAB_MRT2_TEST=1 and the pack installed
// (SLAB_LIBRARY or SLAB_HOME pointing at it). Takes a few seconds.
test "Job renders a clip through the installed pack" {
    const t = std.testing;
    if (getenv("SLAB_MRT2_TEST") == null or !present()) return error.SkipZigTest;
    const map = tempo_mod.TempoMap.constant(120);
    var clip = clip_mod.Clip.init("job test", 0, 4);
    defer clip.deinit(t.allocator);
    for ([_]u8{ 57, 60, 64, 69 }, 0..) |p, i|
        try clip.notes.append(t.allocator, .{ .pitch = p, .start_beat = @floatFromInt(i), .length_beats = 1 });
    var job: Job = .{};
    if (job.start(t.allocator, &clip, &map, .{ .prompt = "solo grand piano", .seed = 1 })) |why| {
        std.debug.print("start: {s}\n", .{why});
        return error.StartFailed;
    }
    while (!job.poll()) _ = usleep(100_000);
    if (!job.ok) std.debug.print("renderer: {s}\n", .{job.lastLine()});
    try t.expect(job.ok);
    // The renderer's summary: the clip (4 beats at 120 BPM, 2 s) plus the 2 s tail.
    try t.expect(std.mem.indexOf(u8, job.lastLine(), "4.00 s") != null);
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    const wav = z(&zb, job.wavPath());
    const fd = open(wav, 0);
    try t.expect(fd >= 0);
    // 4 s, 48 kHz stereo float32, plus the header.
    const size = lseek(fd, 0, SEEK_END);
    _ = close(fd);
    try t.expectEqual(@as(i64, 44 + 4 * 48000 * 2 * 4), size);
    _ = unlink(wav);
}
