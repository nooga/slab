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

/// Which tracks `stemsOf` takes: tracks that play, audible buses, or both.
pub const Stems = enum { none, tracks, buses, all };

/// One gain for every file of an export (docs/27 §Normalize): none, the
/// mix's true peak to `target` dBTP, or its integrated loudness to
/// `target` LUFS, lowered if that would push the true peak past `ceiling`.
pub const Normalize = enum { off, peak, loudness };

/// A file's channels: as rendered, summed to mono ((L + R) / 2), or mono
/// only when its two sides are the same (a mono source panned center).
pub const Channels = enum(u8) { stereo = 0, mono = 1, auto = 2 };

/// The stems' gain under Normalize: the mix's (they keep their balance
/// and still sum to the written mix), or none (as mixed).
pub const StemGain = enum(u8) { mix = 0, none = 1 };

/// One track's stem: where its signal is taken (none: no stem), and its
/// channels.
pub const Stem = struct {
    tap: engine_mod.CaptureTap = .none,
    channels: Channels = .stereo,
};

pub const Options = struct {
    /// Every file goes under `folder` (made if missing), named by a
    /// template (export.fillName; a `/` in it makes a subfolder) and the
    /// format's extension.
    folder: []const u8 = "",
    /// The mix's name template; null writes no mix.
    mix_name: ?[]const u8 = null,
    mix_channels: Channels = .stereo,
    /// Per track (by index): its stem, if any.
    stems: [routing.MAX_TRACKS]Stem = @splat(.{}),
    stem_name: []const u8 = "{project}-{nn}-{track}",
    /// Where the stems go instead of `folder` (the command line's
    /// --stems <dir>).
    stem_folder: ?[]const u8 = null,
    stem_gain: StemGain = .mix,
    /// An existing file is replaced; otherwise the new one is numbered
    /// ("Song 2.wav"). Two files of one export never share a name.
    replace: bool = true,
    /// The name fields (the tempo is the format's).
    project: []const u8 = "",
    date: []const u8 = "",
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

    fn hasStems(o: *const Options) bool {
        for (o.stems) |st| if (st.tap != .none) return true;
        return false;
    }
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
    fn noteFile(self: *Report, path: []const u8) void {
        if (self.files == 0) {
            self.first_len = @min(path.len, self.first_buf.len);
            @memcpy(self.first_buf[0..self.first_len], path[0..self.first_len]);
        }
        self.files += 1;
    }

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
    /// The first file written (the mix when there is one).
    first_buf: [storage.MAX_PATH]u8 = undefined,
    first_len: usize = 0,

    pub fn first(self: *const Report) []const u8 {
        return self.first_buf[0..self.first_len];
    }
};

/// Stems at `tap` for every track `kind` takes (`stemSet`).
pub fn stemsOf(tracks: []track_mod.Track, kind: Stems, tap: engine_mod.CaptureTap) [routing.MAX_TRACKS]Stem {
    var out: [routing.MAX_TRACKS]Stem = @splat(.{});
    const set = stemSet(tracks, kind);
    for (0..tracks.len) |ti| if (set & routing.bit(@intCast(ti)) != 0) {
        out[ti].tap = tap;
    };
    return out;
}

/// The tracks `kind` takes: tracks that sound (audible, with clips that
/// play) and/or buses that are audible.
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

pub fn hasPlayingClips(t: *const track_mod.Track) bool {
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
    if (opts.mix_name == null and !opts.hasStems()) return error.NothingToExport;

    var cap = engine_mod.Capture{
        .min_frames = range,
        .hold = if (opts.tail_auto) opts.format.sample_rate / 2 else 0,
        .watch_master = opts.mix_name != null,
    };
    defer for (&cap.l, &cap.r) |l, r| {
        if (l.len > 0) alloc.free(l);
        if (r.len > 0) alloc.free(r);
    };
    for (0..tracks.len) |ti| if (opts.stems[ti].tap != .none) {
        cap.tap[ti] = opts.stems[ti].tap;
        cap.l[ti] = try alloc.alloc(f32, total + engine_mod.PDC_MAX);
        cap.r[ti] = try alloc.alloc(f32, total + engine_mod.PDC_MAX);
        @memset(cap.l[ti], 0);
        @memset(cap.r[ti], 0);
    };
    const mix: []f32 = if (opts.mix_name != null) try alloc.alloc(f32, total * 2) else &.{};
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
    var names = Names{ .opts = &opts };
    var gain: f32 = 1;
    if (opts.mix_name) |template| {
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
        var path_buf: [storage.MAX_PATH]u8 = undefined;
        const path = try names.next(&path_buf, template, 0, "");
        try writeAs(alloc, path, m, opts.format, opts.mix_channels);
        report.noteFile(path);
    }
    if (opts.hasStems()) {
        const stem_gain: f32 = if (opts.stem_gain == .mix) gain else 1;
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
                buf[i * 2] = cap.l[ti][lat + i] * stem_gain;
                buf[i * 2 + 1] = cap.r[ti][lat + i] * stem_gain;
            }
            var lv = &report.stems[report.stem_count];
            lv.name_len = @min(t.name().len, lv.name_buf.len);
            @memcpy(lv.name_buf[0..lv.name_len], t.name()[0..lv.name_len]);
            const out = try convert(alloc, if (opts.loop_wrap) wrap(buf, range) else buf, rate, out_rate, opts.loop_wrap);
            defer alloc.free(out);
            lv.lufs = (try loudness.measure(alloc, out, out_rate)).integrated;
            report.stem_count += 1;
            var path_buf: [storage.MAX_PATH]u8 = undefined;
            const path = try names.next(&path_buf, opts.stem_name, nn, t.name());
            var sf = opts.format;
            var title_buf: [256]u8 = undefined;
            sf.title = if (opts.format.title.len > 0) std.fmt.bufPrint(&title_buf, "{s} - {s}", .{ opts.format.title, t.name() }) catch t.name() else t.name();
            try writeAs(alloc, path, out, sf, opts.stems[ti].channels);
            report.noteFile(path);
        }
    }
    return report;
}

/// Each file's path: the folder, its filled template, a number when the
/// name is taken, the extension.
const Names = struct {
    opts: *const Options,
    /// Hashes of the paths this export wrote.
    taken: [routing.MAX_TRACKS + 1]u64 = undefined,
    count: usize = 0,

    fn next(self: *Names, buf: []u8, template: []const u8, nn: usize, track: []const u8) ![]const u8 {
        const o = self.opts;
        const folder = if (nn > 0) o.stem_folder orelse o.folder else o.folder;
        var name_buf: [256]u8 = undefined;
        var name = export_mod.fillName(&name_buf, template, .{ .project = o.project, .nn = nn, .track = track, .date = o.date, .bpm = o.format.bpm });
        if (name.len == 0 or name[name.len - 1] == '/') name = if (track.len > 0) track else "export";
        const ext = o.format.container.ext();
        var k: usize = 1;
        while (true) : (k += 1) {
            var num_buf: [8]u8 = undefined;
            const num = if (k == 1) "" else std.fmt.bufPrint(&num_buf, " {d}", .{k}) catch "";
            const path = try std.fmt.bufPrint(buf, "{s}/{s}{s}{s}", .{ folder, name, num, ext });
            const h = std.hash.Wyhash.hash(0, path);
            const mine = std.mem.indexOfScalar(u64, self.taken[0..self.count], h) != null;
            if (mine or (!o.replace and exists(path))) continue;
            if (self.count < self.taken.len) {
                self.taken[self.count] = h;
                self.count += 1;
            }
            if (std.fs.path.dirname(path)) |dir| storage.makeParents(dir);
            return path;
        }
    }
};

fn exists(path: []const u8) bool {
    var z: [storage.MAX_PATH + 1]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return false;
    return std.c.access(p, 0) == 0;
}

/// Write interleaved stereo `x`, summed to mono when `ch` asks for it.
fn writeAs(alloc: std.mem.Allocator, path: []const u8, x: []const f32, f: export_mod.Format, ch: Channels) !void {
    const mono = switch (ch) {
        .stereo => false,
        .mono => true,
        .auto => sidesMatch(x),
    };
    if (!mono) return write(alloc, path, x, f);
    const m = try alloc.alloc(f32, x.len / 2);
    defer alloc.free(m);
    for (m, 0..) |*v, i| v.* = (x[i * 2] + x[i * 2 + 1]) * 0.5;
    var g = f;
    g.channels = 1;
    try write(alloc, path, m, g);
}

/// L and R within -100 dBFS of each other everywhere.
fn sidesMatch(x: []const f32) bool {
    var i: usize = 0;
    while (i + 1 < x.len) : (i += 2) if (@abs(x[i] - x[i + 1]) > 1e-5) return false;
    return true;
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
        .folder = dir,
        .mix_name = "{project}",
        .stems = stemsOf(&tracks, .tracks, .post),
        .stem_name = "{project} stems/{project}-{nn}-{track}",
        .project = "song",
        .end = 4800,
        .tail_frames = 2400,
        .format = .{ .bits = .float32 },
    }, null, null);
    try testing.expectEqual(@as(usize, 3), r.files);
    try testing.expectEqual(@as(usize, 7200), r.frames);
    try testing.expectEqualStrings(mix_path, r.first());

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
    _ = stem_dir;
    const r = try run(alloc, eng, &tracks, .{
        .folder = dir,
        .mix_name = "n",
        .stems = stemsOf(&tracks, .tracks, .post),
        .stem_name = "stems/{track}",
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

    // Again, not replacing: the files are numbered; the stem, as mixed
    // and summed to mono (the tone is centered), has one channel.
    var stems = stemsOf(&tracks, .tracks, .post);
    stems[0].channels = .auto;
    const r2 = try run(alloc, eng, &tracks, .{
        .folder = dir,
        .mix_name = "n",
        .stems = stems,
        .stem_name = "stems/{track}",
        .stem_gain = .none,
        .replace = false,
        .end = 48_000,
        .format = .{ .bits = .float32 },
        .normalize = .loudness,
        .target = -16,
    }, null, null);
    try testing.expectEqual(@as(usize, 2), r2.files);
    var nb: [storage.MAX_PATH]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&nb, "{s}/n 2.wav", .{dir}), r2.first());
    var tb: [storage.MAX_PATH]u8 = undefined;
    var tone = try wav.loadStereo(alloc, try std.fmt.bufPrint(&tb, "{s}/stems/Tone 2.wav", .{dir}));
    defer tone.deinit(alloc);
    try testing.expect(!tone.isStereo());
    var tpeak: f64 = 0;
    for (tone.data) |v| tpeak = @max(tpeak, @abs(v));
    try testing.expectApproxEqAbs(0.1 * @cos(std.math.pi / 4.0), tpeak, 1e-3);
}
