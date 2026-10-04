//! Export a range of the project (docs/27 §Export): the mix and/or stems,
//! all from one offline render. The stems are the engine's capture of each
//! track's tap while the mix renders; every file of an export has the same
//! length, so they line up in any DAW. Runs on whatever thread calls it
//! (the app's worker, or the command line), with the device stopped.

const std = @import("std");
const engine_mod = @import("engine.zig");
const track_mod = @import("track.zig");
const routing = @import("routing.zig");
const storage = @import("storage.zig");
const export_mod = @import("export.zig");
const loudness = @import("loudness.zig");
const resample = @import("resample.zig");

pub const Stems = enum { none, tracks, buses, all };

/// One gain for every file of an export (docs/27 §Normalize): none, the
/// mix's true peak to `target` dBTP, or its integrated loudness to
/// `target` LUFS, lowered if that would push the true peak past `ceiling`.
pub const Normalize = enum { off, peak, loudness };

pub const Options = struct {
    /// Where the mix goes; null writes no mix.
    mix_path: ?[]const u8 = null,
    stems: Stems = .none,
    stem_tap: engine_mod.CaptureTap = .post,
    /// Stems go to `<stem_dir>/<name><ext>`, `name` from `stem_name` with
    /// {project}, {nn} (the stem's number) and {track}.
    stem_dir: []const u8 = "",
    stem_name: []const u8 = "{project}-{nn}-{track}",
    project: []const u8 = "",
    /// The range, samples; the transport stops at `end` and the tail
    /// rings out past it.
    start: u64 = 0,
    end: u64 = 0,
    /// AUTO: up to `tail_frames`, ending once everything is quiet.
    tail_auto: bool = false,
    tail_frames: usize = 0,
    format: export_mod.Format = .{},
    normalize: Normalize = .off,
    target: f64 = -14,
    ceiling: f64 = -1,
    /// LOOP-WRAP (docs/27 §Range): the tail is added back onto the start
    /// and every file is exactly the range long, so it loops seamlessly.
    loop_wrap: bool = false,
};

/// Fold everything past `range` frames back onto the start, round and
/// round; the result is the first `range` frames of `x`.
fn wrap(x: []f32, range: usize) []f32 {
    const n = x.len / 2;
    var i = range;
    while (i < n) : (i += 1) {
        const k = i % range;
        x[k * 2] += x[i * 2];
        x[k * 2 + 1] += x[i * 2 + 1];
    }
    return x[0 .. @min(n, range) * 2];
}

fn convert(alloc: std.mem.Allocator, x: []const f32, from: u32, to: u32, looped: bool) ![]f32 {
    return if (looped) resample.loop(alloc, x, from, to) else resample.stereo(alloc, x, from, to);
}

pub const StemLevel = struct {
    name_buf: [track_mod.MAX_NAME]u8 = undefined,
    name_len: usize = 0,
    lufs: f64 = -70,

    pub fn name(self: *const StemLevel) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Report = struct {
    files: usize = 0,
    /// Each file's length.
    frames: usize = 0,
    sample_rate: u32 = 0,
    /// The mix's, as written (after the gain).
    peak: f32 = 0,
    rms: f64 = 0,
    over: usize = 0,
    loudness: loudness.Stats = .{},
    /// What Normalize applied, dB.
    gain_db: f64 = 0,
    /// Each stem's integrated loudness, as written.
    stems: [routing.MAX_TRACKS]StemLevel = undefined,
    stem_count: usize = 0,
};

/// The tracks `opts.stems` takes: tracks that sound (audible, with clips
/// that play) and/or buses that are audible.
pub fn stemSet(tracks: []track_mod.Track, stems: Stems) u32 {
    if (stems == .none) return 0;
    var nodes: [routing.MAX_TRACKS]routing.Node = undefined;
    var muted: u32 = 0;
    var soloed: u32 = 0;
    for (tracks, 0..) |*t, i| {
        nodes[i] = t.routingNode();
        if (t.mute.load(.monotonic)) muted |= routing.bit(@intCast(i));
        if (t.solo.load(.monotonic)) soloed |= routing.bit(@intCast(i));
    }
    const graph = routing.Routing.build(nodes[0..tracks.len]);
    const heard = graph.audible(muted, soloed);
    var set: u32 = 0;
    for (tracks, 0..) |*t, i| {
        if (heard & routing.bit(@intCast(i)) == 0) continue;
        const want = if (t.isBus()) stems != .tracks else stems != .buses and hasPlayingClips(t);
        if (want) set |= routing.bit(@intCast(i));
    }
    return set;
}

fn hasPlayingClips(t: *const track_mod.Track) bool {
    for (t.clips.items) |*cl| if (!cl.muted) return true;
    return false;
}

/// Render and write. `progress` counts output frames of the most
/// `opts.end - opts.start + opts.tail_frames`. error.Cancelled when
/// `cancel` stopped it.
pub fn run(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    tracks: []track_mod.Track,
    opts: Options,
    progress: ?*std.atomic.Value(usize),
    cancel: ?*std.atomic.Value(bool),
) !Report {
    if (opts.end <= opts.start) return error.EmptyRange;
    const range: usize = @intCast(opts.end - opts.start);
    const total = range + opts.tail_frames;
    const set = stemSet(tracks, opts.stems);
    if (opts.mix_path == null and set == 0) return error.NothingToExport;

    var cap = engine_mod.Capture{
        .min_frames = range,
        .hold = if (opts.tail_auto) opts.format.sample_rate / 2 else 0,
        .watch_master = opts.mix_path != null,
    };
    defer for (&cap.l, &cap.r) |l, r| {
        if (l.len > 0) alloc.free(l);
        if (r.len > 0) alloc.free(r);
    };
    for (0..tracks.len) |ti| if (set & routing.bit(@intCast(ti)) != 0) {
        cap.tap[ti] = opts.stem_tap;
        cap.l[ti] = try alloc.alloc(f32, total + engine_mod.PDC_MAX);
        cap.r[ti] = try alloc.alloc(f32, total + engine_mod.PDC_MAX);
        @memset(cap.l[ti], 0);
        @memset(cap.r[ti], 0);
    };
    const mix: []f32 = if (opts.mix_path != null) try alloc.alloc(f32, total * 2) else &.{};
    defer if (mix.len > 0) alloc.free(mix);
    @memset(mix, 0);

    engine.capture = &cap;
    engine.offline_stop = opts.end;
    engine.renderOffline(mix, total, opts.start, progress, cancel);
    engine.capture = null;
    if (cancel) |c| if (c.load(.monotonic)) return error.Cancelled;

    // One length for every file: the range and what still sounds past it.
    const out_frames = @min(total, cap.rendered -| engine.master_latency.load(.monotonic));
    var len: usize = if (opts.tail_auto) range else total;
    if (opts.tail_auto) {
        if (mix.len > 0) len = @max(len, cap.master_loud_end);
        for (0..tracks.len) |ti| if (cap.tap[ti] != .none) {
            len = @max(len, cap.loud_end[ti] -| cap.lat[ti]);
        };
    }
    len = @min(len, if (mix.len > 0) out_frames else total);

    // The engine's rate, and the file's (resampled when they differ).
    const rate = engine.transport.sample_rate;
    const out_rate = opts.format.sample_rate;
    const file_len = if (opts.loop_wrap) range else len;
    var report = Report{ .frames = (file_len * out_rate + rate - 1) / rate, .sample_rate = out_rate };
    var gain: f32 = 1;
    if (opts.mix_path) |path| {
        const src = if (opts.loop_wrap) wrap(mix[0 .. len * 2], range) else mix[0 .. len * 2];
        const m = try convert(alloc, src, rate, out_rate, opts.loop_wrap);
        defer alloc.free(m);
        const before = try loudness.measure(alloc, m, out_rate);
        report.gain_db = switch (opts.normalize) {
            .off => 0,
            .peak => opts.target - before.true_peak,
            .loudness => if (before.integrated <= -70) 0 else @min(opts.target - before.integrated, opts.ceiling - before.true_peak),
        };
        gain = @floatCast(std.math.pow(f64, 10, report.gain_db / 20));
        if (gain != 1) for (m) |*v| {
            v.* *= gain;
        };
        report.loudness = before;
        report.loudness.integrated += if (before.integrated > -70) report.gain_db else 0;
        report.loudness.short_term_max += report.gain_db;
        report.loudness.sample_peak += report.gain_db;
        report.loudness.true_peak += report.gain_db;
        var sq: f64 = 0;
        for (m) |v| {
            report.peak = @max(report.peak, @abs(v));
            sq += @as(f64, v) * v;
            if (@abs(v) >= 0.999) report.over += 1;
        }
        report.rms = if (m.len > 0) @sqrt(sq / @as(f64, @floatFromInt(m.len))) else 0;
        try write(alloc, path, m, opts.format);
        report.files += 1;
    }
    if (set != 0) {
        storage.makeParents(opts.stem_dir);
        const buf = try alloc.alloc(f32, len * 2);
        defer alloc.free(buf);
        var nn: usize = 0;
        for (tracks, 0..) |*t, ti| {
            if (cap.tap[ti] == .none) continue;
            nn += 1;
            const lat = cap.lat[ti];
            @memset(buf, 0);
            const avail = @min(len, cap.l[ti].len -| lat);
            for (0..avail) |i| {
                buf[i * 2] = cap.l[ti][lat + i] * gain;
                buf[i * 2 + 1] = cap.r[ti][lat + i] * gain;
            }
            var lv = &report.stems[report.stem_count];
            lv.name_len = @min(t.name().len, lv.name_buf.len);
            @memcpy(lv.name_buf[0..lv.name_len], t.name()[0..lv.name_len]);
            const out = try convert(alloc, if (opts.loop_wrap) wrap(buf, range) else buf, rate, out_rate, opts.loop_wrap);
            defer alloc.free(out);
            lv.lufs = (try loudness.measure(alloc, out, out_rate)).integrated;
            report.stem_count += 1;
            var name_buf: [256]u8 = undefined;
            const name = export_mod.fillName(&name_buf, opts.stem_name, .{ .project = opts.project, .nn = nn, .track = t.name() });
            var path_buf: [storage.MAX_PATH]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ opts.stem_dir, name, opts.format.container.ext() });
            var sf = opts.format;
            var title_buf: [256]u8 = undefined;
            sf.title = std.fmt.bufPrint(&title_buf, "{s} - {s}", .{ opts.format.title, t.name() }) catch t.name();
            try write(alloc, path, out, sf);
            report.files += 1;
        }
    }
    return report;
}

fn write(alloc: std.mem.Allocator, path: []const u8, samples: []const f32, f: export_mod.Format) !void {
    try export_mod.writeFile(alloc, path, samples, f);
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn dcMachine(level: *f32) @import("machine.zig").Machine {
    const machine = @import("machine.zig");
    return .{
        .name = "dc",
        .state = level,
        .render = struct {
            fn f(st: *anyopaque, _: *const machine.MachineCtx, l: []f32, r: []f32) void {
                const v: *f32 = @ptrCast(@alignCast(st));
                @memset(l, v.*);
                @memset(r, v.*);
            }
        }.f,
        .draw_panel = struct {
            fn f(_: *anyopaque, _: *@import("ui/core.zig").Ui, _: @import("ui/geom.zig").Rect) void {}
        }.f,
        .reset = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };
}

test "run: the mix and a stem per playing track, every file one length" {
    const alloc = testing.allocator;
    const wav = @import("wav.zig");
    const clip_mod = @import("clip.zig");
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var a: f32 = 0.25;
    var b: f32 = 0.5;
    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "A", col, dcMachine(&a)),
        try track_mod.Track.init(alloc, "B", col, dcMachine(&b)),
        try track_mod.Track.init(alloc, "Empty", col, dcMachine(&b)),
    };
    defer for (&tracks) |*t| t.deinit(alloc);
    for (&tracks) |*t| t.setVolume(1.0);
    try tracks[0].addClip(alloc, clip_mod.Clip.init("a", 0, 1));
    try tracks[1].addClip(alloc, clip_mod.Clip.init("b", 0, 1));
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    for (&tracks) |*t| t.publishSnapshot(&pool);
    try testing.expectEqual(@as(u32, 0b011), stemSet(&tracks, .tracks));
    try testing.expectEqual(@as(u32, 0), stemSet(&tracks, .buses));

    var transport = @import("transport.zig").Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(engine_mod.Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [storage.MAX_PATH]u8 = undefined;
    var db: [storage.MAX_PATH]u8 = undefined;
    const dir = storage.absolute(&db, try std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    var mb: [storage.MAX_PATH]u8 = undefined;
    const mix_path = try std.fmt.bufPrint(&mb, "{s}/song.wav", .{dir});
    var sb: [storage.MAX_PATH]u8 = undefined;
    const stem_dir = try std.fmt.bufPrint(&sb, "{s}/song stems", .{dir});
    const r = try run(alloc, eng, &tracks, .{
        .mix_path = mix_path,
        .stems = .tracks,
        .stem_dir = stem_dir,
        .project = "song",
        .end = 4800,
        .tail_frames = 2400,
        .format = .{ .bits = .float32 },
    }, null, null);
    try testing.expectEqual(@as(usize, 3), r.files);
    try testing.expectEqual(@as(usize, 7200), r.frames);

    const c = @cos(@as(f64, std.math.pi / 4.0));
    var mix = try wav.loadStereo(alloc, mix_path);
    defer mix.deinit(alloc);
    try testing.expectEqual(@as(usize, 7200), mix.data.len);
    try testing.expectApproxEqAbs(1.25 * c, mix.data[100], 1e-6); // all three play in the mix
    var pb: [storage.MAX_PATH]u8 = undefined;
    var stem = try wav.loadStereo(alloc, try std.fmt.bufPrint(&pb, "{s}/song-02-B.wav", .{stem_dir}));
    defer stem.deinit(alloc);
    try testing.expectEqual(@as(usize, 7200), stem.data.len);
    try testing.expectApproxEqAbs(0.5 * c, stem.right[100], 1e-6);
}

/// A 1 kHz sine at 0.1, for loudness.
const TestSine = struct {
    phase: f64 = 0,

    fn render(st: *anyopaque, _: *const @import("machine.zig").MachineCtx, l: []f32, r: []f32) void {
        const me: *TestSine = @ptrCast(@alignCast(st));
        for (l, r) |*a, *b| {
            const v: f32 = @floatCast(0.1 * @sin(me.phase));
            me.phase += 2 * std.math.pi * 1000.0 / 48_000.0;
            a.* = v;
            b.* = v;
        }
    }

    fn reset(st: *anyopaque) void {
        const me: *TestSine = @ptrCast(@alignCast(st));
        me.phase = 0;
    }

    fn mach(self: *TestSine) @import("machine.zig").Machine {
        var m = dcMachine(undefined);
        m.name = "sine";
        m.state = self;
        m.render = render;
        m.reset = reset;
        return m;
    }
};

test "run: LOUDNESS normalize takes the mix to its target and the stems by the same gain" {
    const alloc = testing.allocator;
    const wav = @import("wav.zig");
    const clip_mod = @import("clip.zig");
    const col = @import("c.zig").rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var sine = TestSine{};
    var tracks = [_]track_mod.Track{try track_mod.Track.init(alloc, "Tone", col, sine.mach())};
    defer tracks[0].deinit(alloc);
    tracks[0].setVolume(1.0);
    try tracks[0].addClip(alloc, clip_mod.Clip.init("t", 0, 20));
    var pool = @import("audio_pool.zig").AudioPool.init(alloc);
    defer pool.deinit();
    tracks[0].publishSnapshot(&pool);
    var transport = @import("transport.zig").Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(engine_mod.Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = &tracks };
    eng.publishRouting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [storage.MAX_PATH]u8 = undefined;
    var db: [storage.MAX_PATH]u8 = undefined;
    const dir = storage.absolute(&db, try std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    var mb: [storage.MAX_PATH]u8 = undefined;
    const mix_path = try std.fmt.bufPrint(&mb, "{s}/n.wav", .{dir});
    var sb: [storage.MAX_PATH]u8 = undefined;
    const stem_dir = try std.fmt.bufPrint(&sb, "{s}/stems", .{dir});
    // The tone, centre-panned: -20 dBFS -3 dB on each side, about -23 LUFS.
    const r = try run(alloc, eng, &tracks, .{
        .mix_path = mix_path,
        .stems = .tracks,
        .stem_dir = stem_dir,
        .project = "n",
        .end = 48_000 * 10,
        .format = .{ .bits = .float32 },
        .normalize = .loudness,
        .target = -16,
    }, null, null);
    try testing.expectApproxEqAbs(@as(f64, -16), r.loudness.integrated, 0.05);
    try testing.expect(r.gain_db > 6 and r.gain_db < 8);
    try testing.expectEqual(@as(usize, 1), r.stem_count);
    try testing.expectApproxEqAbs(@as(f64, -16), r.stems[0].lufs, 0.05);
    var mix = try wav.loadStereo(alloc, mix_path);
    defer mix.deinit(alloc);
    const want: f64 = 0.1 * @cos(std.math.pi / 4.0) * std.math.pow(f64, 10, r.gain_db / 20);
    var peak: f64 = 0;
    for (mix.data) |v| peak = @max(peak, @abs(v));
    try testing.expectApproxEqAbs(want, peak, 1e-3);
}
