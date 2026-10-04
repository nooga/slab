//! Slab — workbench shell.
//!
//! Ableton-12-ish tiled layout: left browser | arrangement | machine bay.

const std = @import("std");
const c = @import("c.zig");

/// Redraw rate once the UI has been quiet for IDLE_AFTER_FRAMES frames.
const IDLE_FPS = 20;
const IDLE_AFTER_FRAMES = 60;

const audio_mod = @import("audio.zig");
const transport_mod = @import("transport.zig");
const engine_mod = @import("engine.zig");
const meter_mod = @import("meter.zig");
const track_mod = @import("track.zig");
const clip_mod = @import("clip.zig");
const audio_pool_mod = @import("audio_pool.zig");
const wav_mod = @import("wav.zig");
const registry_mod = @import("machine_registry.zig");
const fy_host_mod = @import("fy_host.zig");
const document_mod = @import("document.zig");
const storage = @import("storage.zig");
const package = @import("package.zig");
const describe_mod = @import("describe.zig");
const history_mod = @import("history.zig");
const automation = @import("automation.zig");
const auto_lane = @import("ui/automation_lane.zig");
const recorder_mod = @import("recorder.zig");
const native_dialog = @import("native_dialog.zig");
const native_app = @import("native_app.zig");
const library_mod = @import("library.zig");
const preview_mod = @import("preview.zig");

const pane = @import("ui/pane_input.zig");
const ui_style = @import("ui/style.zig");
const ui_gallery = @import("ui/gallery.zig");
const layout_mod = @import("ui/layout.zig");
const transport_bar = @import("ui/transport_bar.zig");
const ui_core = @import("ui/core.zig");
const ui_geom = @import("ui/geom.zig");
const snap_mod = @import("ui/snap.zig");
const arrangement = @import("ui/arrangement.zig");
const clip_editor = @import("ui/clip_editor.zig");
const menu = @import("ui/menu.zig");
const text_field = @import("ui/text_field.zig");
const splash = @import("ui/splash.zig");
const audio_clip_editor = @import("ui/audio_clip_editor.zig");
const machine_bay = @import("ui/machine_bay.zig");
const mixer = @import("ui/mixer.zig");
const dialog = @import("ui/dialog.zig");
const export_dialog = @import("ui/export_dialog.zig");
const export_settings = @import("export_settings.zig");
const bounce_dialog = @import("ui/bounce_dialog.zig");
const export_mod = @import("export.zig");
const recipe_mod = @import("recipe.zig");
const build_options = @import("build_options");
const exporter = @import("exporter.zig");
const about = @import("ui/about.zig");
const unison_panel = @import("ui/unison_panel.zig");
const color_picker = @import("ui/color_picker.zig");
const browser = @import("ui/browser.zig");

test {
    _ = @import("ui/sprites.zig");
    _ = @import("ui/core.zig");
    _ = @import("ui/controls.zig");
    _ = @import("ui/geom.zig");
    _ = @import("ui/atlas.zig");
    _ = @import("ui/font.zig");
    _ = @import("ui/text_field.zig");
    _ = @import("fy_host.zig");
    _ = @import("meter.zig");
    _ = @import("tempo.zig");
    _ = @import("routing.zig");
    _ = @import("export.zig");
    _ = @import("exporter.zig");
    _ = @import("flac.zig");
    _ = @import("loudness.zig");
    _ = @import("export_settings.zig");
    _ = @import("ui/export_dialog.zig");
    _ = @import("resample.zig");
    _ = @import("ui/track_order.zig");
    _ = @import("engine.zig");
    _ = @import("track.zig");
    _ = @import("document.zig");
    _ = @import("meter_gen.zig");
    _ = @import("automation.zig");
    _ = @import("ui/automation_lane.zig");
    _ = @import("ui/lane_targets.zig");
    _ = @import("ui/arrangement.zig");
    _ = @import("ui/follow.zig");
    _ = @import("library.zig");
    _ = @import("packs.zig");
    _ = @import("ui/browser.zig");
}

const routing_mod = @import("routing.zig");
const track_order = @import("ui/track_order.zig");
const MAX_TRACKS: usize = routing_mod.MAX_TRACKS;
const DEV_BOOT_AUDITION = true;
const DEV_BOOT_AUTOPLAY = false;

const FocusPane = enum {
    arrangement,
    piano_roll,
    browser,
    machine_bay,
    top_bar,
};

const ClipboardMode = enum { empty, clips, notes };

const EditClipboard = struct {
    mode: ClipboardMode = .empty,
    clips: std.ArrayList(arrangement.CopiedClip) = .empty,
    notes: std.ArrayList(clip_mod.Note) = .empty,

    fn deinit(self: *EditClipboard, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.clips.deinit(alloc);
        self.notes.deinit(alloc);
    }

    fn clear(self: *EditClipboard, alloc: std.mem.Allocator) void {
        for (self.clips.items) |*item| item.clip.deinit(alloc);
        self.clips.clearRetainingCapacity();
        self.notes.clearRetainingCapacity();
        self.mode = .empty;
    }
};

const StatusMessage = struct {
    buf: [128:0]u8 = [_:0]u8{0} ** 128,
    until: f64 = 0,

    fn set(self: *StatusMessage, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrintZ(&self.buf, fmt, args) catch "status";
        self.buf[s.len] = 0;
        self.until = c.rl.GetTime() + 2.0;
    }

    fn text(self: *const StatusMessage) [*:0]const u8 {
        if (c.rl.GetTime() <= self.until) return @ptrCast(&self.buf[0]);
        return "";
    }
};

const EditTarget = struct {
    beat: ?f64 = null,
    track: ?usize = null,
    pitch: ?u8 = null,
};

/// An export running on a worker thread (docs/27 §Export): the worker
/// renders and writes every file; the UI thread polls `progress`/`done`
/// for the progress bar and reports the result.
const RenderJob = struct {
    active: bool = false,
    thread: ?std.Thread = null,
    opts: exporter.Options = .{},
    /// What `opts` points into: the settings as they were, the folder,
    /// the names and the comment.
    settings: export_settings.Settings = .{},
    folder_buf: [storage.MAX_PATH]u8 = undefined,
    project_buf: [128]u8 = undefined,
    date_buf: [10]u8 = undefined,
    comment_buf: [96]u8 = undefined,
    tracks: []track_mod.Track = &.{},
    total_frames: usize = 0,
    sample_rate: u32 = 48_000,
    start_ns: i128 = 0,
    result: ?exporter.Report = null,
    err: ?anyerror = null,
    progress: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn renderWorker(alloc: std.mem.Allocator, engine: *engine_mod.Engine, job: *RenderJob) void {
    if (exporter.run(alloc, engine, job.tracks, job.opts, &job.progress, &job.cancel)) |r| {
        job.result = r;
    } else |err| job.err = err;
    job.done.store(true, .release);
}

fn nowNs() i128 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @divTrunc(@as(i128, @intCast(std.c.mach_absolute_time())) * @as(i128, @intCast(info.numer)), @as(i128, @intCast(info.denom)));
}

const RenameKind = enum { none, track, clip, preset_save, preset_save_library, preset_rename };

const RenameState = struct {
    kind: RenameKind = .none,
    track: usize = 0,
    clip: usize = 0,
    /// For preset_save/preset_rename: the device's owning track (stable for
    /// the session) and which device on it owns the preset — null effect =
    /// instrument, else the effect index.
    device_track: ?*track_mod.Track = null,
    device_effect: ?usize = null,
    /// For preset_rename: the preset index being renamed.
    preset_index: u16 = 0,
    tb: text_field.TextBuf = .{ .limit = track_mod.MAX_NAME },
    /// Anchor for the field, reported by the pane that owns the name.
    rect: c.rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Focus the field on its first frame.
    start_focus: bool = true,

    fn active(self: *const RenameState) bool {
        return self.kind != .none;
    }
};

// Silent placeholder machine — writes zeros, draws nothing.
fn silentRender(_: *anyopaque, _: *const @import("machine.zig").MachineCtx, l: []f32, r: []f32) void {
    @memset(l, 0);
    @memset(r, 0);
}
fn silentPanel(_: *anyopaque, _: *ui_core.Ui, _: ui_geom.Rect) void {}
fn silentReset(_: *anyopaque) void {}
var silent_state: u8 = 0;
const silent_machine = @import("machine.zig").Machine{
    .name = "(empty)",
    .state = &silent_state,
    .render = silentRender,
    .draw_panel = silentPanel,
    .reset = silentReset,
};

fn assignMachineToTrack(
    alloc: std.mem.Allocator,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    t: *track_mod.Track,
    reg_idx: usize,
) !void {
    audio.stop();
    defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});

    const mach = blk: {
        fy_host_mod.lockCallbacks();
        defer fy_host_mod.unlockCallbacks();
        break :blk try reg.instantiate(reg_idx);
    };
    mach.reset(mach.state);
    t.replaceMachine(alloc, mach);
    t.machine_idx = @intCast(reg_idx);
}

fn addEffectToTrack(
    alloc: std.mem.Allocator,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    t: *track_mod.Track,
    reg_idx: usize,
) !void {
    audio.stop();
    defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});

    const mach = blk: {
        fy_host_mod.lockCallbacks();
        defer fy_host_mod.unlockCallbacks();
        break :blk try reg.instantiate(reg_idx);
    };
    mach.reset(mach.state);
    try t.addEffect(alloc, mach, @intCast(reg_idx));
}

fn replaceEffectOnTrack(
    alloc: std.mem.Allocator,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    t: *track_mod.Track,
    i: usize,
    reg_idx: usize,
) !void {
    audio.stop();
    defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});

    const mach = blk: {
        fy_host_mod.lockCallbacks();
        defer fy_host_mod.unlockCallbacks();
        break :blk try reg.instantiate(reg_idx);
    };
    mach.reset(mach.state);
    t.replaceEffect(alloc, i, mach, @intCast(reg_idx));
}

// DeviceRef → effect index (null = instrument), for resolving a machine.
fn refEffect(ref: machine_bay.DeviceRef) ?usize {
    return switch (ref) {
        .instrument => null,
        .effect => |i| i,
    };
}

// 80s synthpop demo: vi–IV–I–V in C major (Am | F | C | G), 4 bars looped.
// Three mono1 voices — punch bass, brass lead, lush pad chord — with chorus
// on the lead. BPM 124. Loop 0..16 beats.
const PatternNote = struct {
    pitch: u8,
    start: f64,
    len: f64,
    vel: u8,
};

const bass_notes = [_]PatternNote{
    // Bar 1 — Am: A2/A3/E3 octave-fifth pulse
    .{ .pitch = 45, .start = 0.0, .len = 0.45, .vel = 110 },
    .{ .pitch = 57, .start = 0.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 52, .start = 1.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 57, .start = 1.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 45, .start = 2.0, .len = 0.45, .vel = 108 },
    .{ .pitch = 57, .start = 2.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 52, .start = 3.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 57, .start = 3.5, .len = 0.45, .vel = 92 },
    // Bar 2 — F: F2/F3/C3
    .{ .pitch = 41, .start = 4.0, .len = 0.45, .vel = 110 },
    .{ .pitch = 53, .start = 4.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 48, .start = 5.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 53, .start = 5.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 41, .start = 6.0, .len = 0.45, .vel = 108 },
    .{ .pitch = 53, .start = 6.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 48, .start = 7.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 53, .start = 7.5, .len = 0.45, .vel = 92 },
    // Bar 3 — C: C3/C4/G3
    .{ .pitch = 48, .start = 8.0, .len = 0.45, .vel = 110 },
    .{ .pitch = 60, .start = 8.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 55, .start = 9.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 60, .start = 9.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 48, .start = 10.0, .len = 0.45, .vel = 108 },
    .{ .pitch = 60, .start = 10.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 55, .start = 11.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 60, .start = 11.5, .len = 0.45, .vel = 92 },
    // Bar 4 — G: G2/G3/D3
    .{ .pitch = 43, .start = 12.0, .len = 0.45, .vel = 110 },
    .{ .pitch = 55, .start = 12.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 50, .start = 13.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 55, .start = 13.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 43, .start = 14.0, .len = 0.45, .vel = 108 },
    .{ .pitch = 55, .start = 14.5, .len = 0.45, .vel = 92 },
    .{ .pitch = 50, .start = 15.0, .len = 0.45, .vel = 104 },
    .{ .pitch = 55, .start = 15.5, .len = 0.45, .vel = 92 },
};

const lead_notes = [_]PatternNote{
    // Bar 1 — over Am, A-minor pentatonic
    .{ .pitch = 76, .start = 0.0, .len = 0.45, .vel = 100 }, // E5
    .{ .pitch = 79, .start = 0.5, .len = 0.45, .vel = 96 }, // G5
    .{ .pitch = 81, .start = 1.0, .len = 0.95, .vel = 110 }, // A5
    .{ .pitch = 79, .start = 2.0, .len = 0.45, .vel = 96 }, // G5
    .{ .pitch = 76, .start = 2.5, .len = 1.45, .vel = 102 }, // E5
    // Bar 2 — over F
    .{ .pitch = 77, .start = 4.0, .len = 0.45, .vel = 100 }, // F5
    .{ .pitch = 81, .start = 4.5, .len = 0.45, .vel = 96 }, // A5
    .{ .pitch = 84, .start = 5.0, .len = 0.95, .vel = 112 }, // C6
    .{ .pitch = 81, .start = 6.0, .len = 0.45, .vel = 96 }, // A5
    .{ .pitch = 77, .start = 6.5, .len = 1.45, .vel = 102 }, // F5
    // Bar 3 — over C
    .{ .pitch = 79, .start = 8.0, .len = 0.95, .vel = 104 }, // G5
    .{ .pitch = 76, .start = 9.0, .len = 0.45, .vel = 96 }, // E5
    .{ .pitch = 79, .start = 9.5, .len = 0.45, .vel = 96 }, // G5
    .{ .pitch = 84, .start = 10.0, .len = 0.95, .vel = 110 }, // C6
    .{ .pitch = 79, .start = 11.0, .len = 0.95, .vel = 100 }, // G5
    // Bar 4 — over G, lifts to B5 hook
    .{ .pitch = 74, .start = 12.0, .len = 0.45, .vel = 100 }, // D5
    .{ .pitch = 79, .start = 12.5, .len = 0.45, .vel = 96 }, // G5
    .{ .pitch = 83, .start = 13.0, .len = 0.95, .vel = 112 }, // B5
    .{ .pitch = 81, .start = 14.0, .len = 0.45, .vel = 96 }, // A5
    .{ .pitch = 79, .start = 14.5, .len = 1.45, .vel = 100 }, // G5
};

const pad_notes = [_]PatternNote{
    // Bar 1 — Am triad held
    .{ .pitch = 57, .start = 0.0, .len = 4.0, .vel = 80 },
    .{ .pitch = 60, .start = 0.0, .len = 4.0, .vel = 78 },
    .{ .pitch = 64, .start = 0.0, .len = 4.0, .vel = 78 },
    // Bar 2 — F triad
    .{ .pitch = 53, .start = 4.0, .len = 4.0, .vel = 80 },
    .{ .pitch = 57, .start = 4.0, .len = 4.0, .vel = 78 },
    .{ .pitch = 60, .start = 4.0, .len = 4.0, .vel = 78 },
    // Bar 3 — C triad
    .{ .pitch = 60, .start = 8.0, .len = 4.0, .vel = 80 },
    .{ .pitch = 64, .start = 8.0, .len = 4.0, .vel = 78 },
    .{ .pitch = 67, .start = 8.0, .len = 4.0, .vel = 78 },
    // Bar 4 — G triad
    .{ .pitch = 55, .start = 12.0, .len = 4.0, .vel = 80 },
    .{ .pitch = 59, .start = 12.0, .len = 4.0, .vel = 78 },
    .{ .pitch = 62, .start = 12.0, .len = 4.0, .vel = 78 },
};

fn addClipFromNotes(
    alloc: std.mem.Allocator,
    track: *track_mod.Track,
    name: []const u8,
    notes: []const PatternNote,
) !void {
    var clip = clip_mod.Clip.init(name, 0, 16);
    for (notes) |n| {
        try clip.addNote(alloc, .{
            .pitch = n.pitch,
            .start_beat = n.start,
            .length_beats = n.len,
            .velocity = n.vel,
        });
    }
    try track.addClip(alloc, clip);
}

fn applyPresetTo(t: *track_mod.Track, preset_idx: u16) void {
    if (t.machine.apply_preset) |apply| apply(t.machine.state, preset_idx);
}

/// `slab [project.slab] [--render out.wav]`: open a project at startup, or
/// bounce it headless (no window, no audio device) and exit. `slab
/// --gallery` opens the UI gallery (docs/06), no engine. `slab --describe
/// out.json` dumps every machine's params (docs/19). `--no-idle-skip`
/// renders every machine every block (docs/04 §Idle skipping). `--no-neon`
/// renders dual-mono effects in two scalar passes (docs/05 §Lane mode).
/// `--no-branches` computes both arms of every dsp `ifte` (docs/05
/// §Branching). `--threads N` renders tracks on N threads, 1 on the audio
/// thread alone (docs/07 §Parallel rendering; default: the performance
/// cores). The render workers get real-time scheduling and join the
/// device's I/O workgroup (render_pool.zig); `--no-rt-workers` leaves them
/// at user-interactive QoS. `--no-machine-cache` compiles every machine
/// instance in a host of its own; `--flush-each` flushes fy's instruction
/// cache per linked word instead of once per file (docs/25 §Load time).
const Cli = struct {
    project: ?[]const u8 = null,
    render: ?[]const u8 = null,
    /// Export options for --render / --stems (docs/27 §Command line).
    stems: ?[]const u8 = null,
    stems_kind: exporter.Stems = .tracks,
    stem_tap: engine_mod.CaptureTap = .post,
    bits: export_mod.Bits = .pcm24,
    dither: bool = true,
    /// .m4a: ALAC instead of AAC, and AAC's bitrate.
    alac: bool = false,
    kbps: u16 = 256,
    /// --normalize <LUFS> or peak:<dBTP>.
    normalize: exporter.Normalize = .off,
    norm_target: f64 = -14,
    /// The file's sample rate; null: the engine's.
    rate: ?u32 = null,
    /// --range <beat>:<beat>; null: the project.
    range: ?[2]f64 = null,
    loop_wrap: bool = false,
    /// The mix summed to mono.
    mono: bool = false,
    flac_level: u4 = 5,
    /// Tags; the title defaults to the project's name.
    title: ?[]const u8 = null,
    artist: []const u8 = "",
    album: []const u8 = "",
    year: []const u8 = "",
    /// Seconds; null: AUTO.
    tail: ?f32 = 3,
    describe: ?[]const u8 = null,
    gallery: bool = false,
    idle_skip: bool = true,
    /// Render threads, the audio thread included; null: the default.
    threads: ?usize = null,
    rt_workers: bool = true,

    /// Render workers beside the audio thread.
    fn workers(cli: Cli) usize {
        const t = cli.threads orelse return @import("render_pool.zig").defaultWorkers();
        return @min(t -| 1, @import("render_pool.zig").MAX_WORKERS);
    }
};

extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;

/// Run from Slab.app (tools/package_app.sh), the factory files live in
/// Contents/Resources: work from there, as a dev build works from the repo.
fn enterBundleResources() void {
    var buf: [storage.MAX_PATH]u8 = undefined;
    var n: u32 = buf.len;
    if (_NSGetExecutablePath(&buf, &n) != 0) return;
    const exe = std.mem.sliceTo(&buf, 0);
    const macos = std.fs.path.dirname(exe) orelse return;
    if (!std.mem.endsWith(u8, macos, ".app/Contents/MacOS")) return;
    var rb: [storage.MAX_PATH]u8 = undefined;
    const res = std.fmt.bufPrintZ(&rb, "{s}/../Resources", .{macos}) catch return;
    _ = chdir(res);
}

pub fn main(init: std.process.Init) !void {
    enterBundleResources();
    var cli: Cli = .{};
    {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        _ = args.next();
        while (args.next()) |a_z| {
            const a: []const u8 = a_z;
            if (std.mem.eql(u8, a, "--render")) {
                cli.render = args.next() orelse return error.MissingRenderPath;
            } else if (std.mem.eql(u8, a, "--stems")) {
                cli.stems = args.next() orelse return error.MissingStemsDir;
            } else if (std.mem.eql(u8, a, "--stem-kind")) {
                const v = args.next() orelse return error.MissingStemKind;
                cli.stems_kind = std.meta.stringToEnum(exporter.Stems, v) orelse return error.BadStemKind;
            } else if (std.mem.eql(u8, a, "--tap")) {
                const v = args.next() orelse return error.MissingTap;
                cli.stem_tap = if (std.mem.eql(u8, v, "fx")) .pre else if (std.mem.eql(u8, v, "fader")) .post else return error.BadTap;
            } else if (std.mem.eql(u8, a, "--bits")) {
                const v = args.next() orelse return error.MissingBits;
                cli.bits = if (std.mem.eql(u8, v, "16")) .pcm16 else if (std.mem.eql(u8, v, "24")) .pcm24 else if (std.mem.eql(u8, v, "32f")) .float32 else return error.BadBits;
            } else if (std.mem.eql(u8, a, "--mono")) {
                cli.mono = true;
            } else if (std.mem.eql(u8, a, "--flac-level")) {
                const v = args.next() orelse return error.MissingFlacLevel;
                cli.flac_level = std.fmt.parseInt(u4, v, 10) catch return error.BadFlacLevel;
                if (cli.flac_level > 8) return error.BadFlacLevel;
            } else if (std.mem.eql(u8, a, "--title")) {
                cli.title = args.next() orelse return error.MissingTitle;
            } else if (std.mem.eql(u8, a, "--artist")) {
                cli.artist = args.next() orelse return error.MissingArtist;
            } else if (std.mem.eql(u8, a, "--album")) {
                cli.album = args.next() orelse return error.MissingAlbum;
            } else if (std.mem.eql(u8, a, "--year")) {
                cli.year = args.next() orelse return error.MissingYear;
            } else if (std.mem.eql(u8, a, "--no-dither")) {
                cli.dither = false;
            } else if (std.mem.eql(u8, a, "--normalize")) {
                const v = args.next() orelse return error.MissingNormalizeTarget;
                if (std.mem.startsWith(u8, v, "peak:")) {
                    cli.normalize = .peak;
                    cli.norm_target = std.fmt.parseFloat(f64, v[5..]) catch return error.BadNormalizeTarget;
                } else {
                    cli.normalize = .loudness;
                    cli.norm_target = std.fmt.parseFloat(f64, v) catch return error.BadNormalizeTarget;
                }
            } else if (std.mem.eql(u8, a, "--range")) {
                const v = args.next() orelse return error.MissingRange;
                const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.BadRange;
                cli.range = .{
                    std.fmt.parseFloat(f64, v[0..colon]) catch return error.BadRange,
                    std.fmt.parseFloat(f64, v[colon + 1 ..]) catch return error.BadRange,
                };
            } else if (std.mem.eql(u8, a, "--loop-wrap")) {
                cli.loop_wrap = true;
            } else if (std.mem.eql(u8, a, "--rate")) {
                const v = args.next() orelse return error.MissingRate;
                cli.rate = std.fmt.parseInt(u32, v, 10) catch return error.BadRate;
            } else if (std.mem.eql(u8, a, "--alac")) {
                cli.alac = true;
            } else if (std.mem.eql(u8, a, "--kbps")) {
                const v = args.next() orelse return error.MissingKbps;
                cli.kbps = std.fmt.parseInt(u16, v, 10) catch return error.BadKbps;
            } else if (std.mem.eql(u8, a, "--tail")) {
                const v = args.next() orelse return error.MissingTail;
                cli.tail = if (std.mem.eql(u8, v, "auto")) null else std.fmt.parseFloat(f32, v) catch return error.BadTail;
            } else if (std.mem.eql(u8, a, "--describe")) {
                cli.describe = args.next() orelse return error.MissingDescribePath;
            } else if (std.mem.eql(u8, a, "--gallery")) {
                cli.gallery = true;
            } else if (std.mem.eql(u8, a, "--threads")) {
                const v = args.next() orelse return error.MissingThreadCount;
                cli.threads = @max(1, std.fmt.parseInt(usize, v, 10) catch return error.BadThreadCount);
            } else if (std.mem.eql(u8, a, "--no-rt-workers")) {
                cli.rt_workers = false;
            } else if (std.mem.eql(u8, a, "--no-idle-skip")) {
                cli.idle_skip = false;
            } else if (std.mem.eql(u8, a, "--no-neon")) {
                @import("machines/fy_raw_machine.zig").neon_lanes = false;
            } else if (std.mem.eql(u8, a, "--no-branches")) {
                @import("machines/fy_raw_machine.zig").dsp_versioning = false;
            } else if (std.mem.eql(u8, a, "--no-machine-cache")) {
                @import("machines/fy_raw_machine.zig").share_hosts = false;
            } else if (std.mem.eql(u8, a, "--flush-each")) {
                @import("fy_host.zig").batch_flush = false;
            } else cli.project = a;
        }
    }

    // DebugAllocator keeps leak + double-free + bounds checking, but
    // stack_trace_frames=0 skips the per-allocation stack unwind. The fy
    // compiler allocates heavily during machine load; capturing a 6-frame
    // trace per alloc cost ~6s at startup (24 machines) vs ~130ms without.
    // Trade-off: leak reports no longer show the allocation site — bump
    // frames back up temporarily when hunting a specific leak.
    var gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    if (cli.gallery) return ui_gallery.run(alloc);
    if (cli.describe) |out| return describe_mod.run(alloc, out);
    // Settings may move the home folder, which user: and lib: resolve in.
    storage.loadSettings(alloc, cli.render == null and cli.stems == null);
    if (cli.render != null or cli.stems != null) return renderHeadless(alloc, cli.project orelse return error.MissingProject, cli);

    storage.ensureHome();

    native_app.installOpenHandler();
    c.rl.SetConfigFlags(c.rl.FLAG_WINDOW_RESIZABLE | c.rl.FLAG_VSYNC_HINT | c.rl.FLAG_WINDOW_HIGHDPI);
    c.rl.InitWindow(1400, 860, "SLAB");
    defer c.rl.CloseWindow();
    native_app.installMenus();
    var title_bar: native_app.TitleBar = .{};
    c.rl.SetTargetFPS(120);
    c.rl.SetExitKey(c.rl.KEY_NULL);

    defer clip_editor.deinit(alloc);

    // New UI core (docs/06). Runs alongside the legacy widgets while panes
    // migrate: legacy panes draw first, then the Ui's draw list, then the
    // legacy menus and tooltips on top of both.
    const ui = try ui_core.Ui.init(alloc);
    defer ui.deinit(alloc);
    defer transport_bar.unloadLogo();
    defer splash.unload();

    // ── Machine registry (each entry owns its own Fy instance) ───────
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();

    // A machine whose fy doesn't compile is skipped, not fatal: machines are
    // livecoded, so a broken one must never take the workbench down.
    // Each compile takes a moment: the splash shows which one is running.
    for (registry_mod.builtin_machines, 0..) |path, i| {
        var sbuf: [48]u8 = undefined;
        const name = std.fs.path.basename(std.fs.path.dirname(path) orelse path);
        var ubuf: [48]u8 = undefined;
        const msg = std.ascii.upperString(&ubuf, std.fmt.bufPrint(&sbuf, "LOADING {s}", .{name}) catch "LOADING");
        const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(registry_mod.builtin_machines.len));
        splash.bootFrame(ui, screenRect(), msg, frac);
        reg.loadFyMachine(path) catch |err| std.log.err("machine {s} failed to load: {s}", .{ path, @errorName(err) });
    }
    reg.loadNative() catch |err| std.log.err("native machines failed to load: {s}", .{@errorName(err)});
    splash.bootFrame(ui, screenRect(), "STARTING AUDIO", 1);

    // ── Audio pool — host-owned decoded audio backing arrangement clips.
    // Registered with the document layer (a process singleton) so save /
    // load / undo resolve clip ↔ file path through it.
    var audio_pool = audio_pool_mod.AudioPool.init(alloc);
    defer audio_pool.deinit();
    document_mod.setPool(&audio_pool);
    // Registered so serialize() resolves track machine index → stable id.
    document_mod.setRegistry(&reg);

    // ── Tracks — start with silent placeholder machines ──────────────
    var transport: transport_mod.Transport = .{};
    transport.sample_rate = audio_mod.SAMPLE_RATE;
    if (DEV_BOOT_AUDITION) {
        transport.setBpm(124);
        transport.setLoopBeats(0, 16);
        if (DEV_BOOT_AUTOPLAY) transport.play();
    }

    var tracks_buf: [MAX_TRACKS]track_mod.Track = undefined;
    var track_count: usize = 1;
    tracks_buf[0] = try track_mod.Track.init(alloc, "Track 1", trackColor(0), silent_machine);
    defer for (tracks_buf[0..track_count]) |*t| t.deinit(alloc);

    // Master bus — a standalone Track (silent instrument, effects-only,
    // its volume() is the master fader and meter() the master meter). It
    // lives outside tracks_buf so no audio-track index ever shifts.
    var master = try track_mod.Track.init(alloc, "Master", @bitCast(ui_style.face_hi), silent_machine);
    master.kind = .master;
    master.setVolume(1.0); // unity — Track defaults to 0.8, which would quiet the mix
    defer master.deinit(alloc);
    // Registered so serialize/apply persist the master bus (volume + FX chain).
    document_mod.setMaster(&master);

    // Document-owned meter map (defaults to 4/4). Registered so
    // serialize/apply persist it; the engine reads it per block and adopts
    // staged edits at bar boundaries.
    var meter_state: meter_mod.MeterState = .{};
    document_mod.setMeterState(&meter_state);
    // The project's export settings (docs/27 §Export), and the presets
    // saved beside settings.json.
    var export_cfg: export_settings.Settings = .{};
    document_mod.setExportSettings(&export_cfg);
    var export_presets: export_settings.UserPresets = .{};
    export_presets.load(alloc);

    var engine = engine_mod.Engine{
        .transport = &transport,
        .tracks = tracks_buf[0..track_count],
        .master = &master,
        .meter_state = &meter_state,
        .idle_skip = cli.idle_skip,
    };
    try engine.initPdc(alloc);
    defer engine.deinitPdc(alloc);
    try engine.initPool(alloc, cli.workers(), if (cli.rt_workers) .{ .period_ns = audio_mod.blockPeriodNs() } else null);
    defer engine.deinitPool(alloc);

    // The browser's preview data: declared before the device so it is
    // freed after the audio thread stops.
    var previewer = preview_mod.Previewer.init(alloc);
    defer previewer.deinit();

    // ── Audio device ─────────────────────────────────────────────────
    var audio: audio_mod.Audio = undefined;
    try audio.init();
    defer {
        audio.setRender(null, null);
        audio.deinit();
    }
    audio.setRender(&engine, engine_mod.Engine.renderCallback);
    var audio_gen = audio.device_gen;
    if (engine.pool) |p| {
        const wg = audio.workgroup();
        if (cli.rt_workers) std.log.info("render workers: real-time, {s}", .{if (wg != null) "in the audio workgroup" else "no audio workgroup"});
        p.setWorkgroup(wg);
    }

    // ── Recorder ─────────────────────────────────────────────────────
    // Owns the SPSC ring + writer thread; the audio thread pushes input
    // through `captureFn` each block. Only active when the device opened a
    // capture half (duplex).
    var recorder = try recorder_mod.Recorder.init(alloc, &transport);
    defer recorder.deinit();
    // Installed for good: the hook gets no input while the device is
    // playback-only (no track armed).
    audio.setCapture(&recorder, recorder_mod.Recorder.captureFn);
    var rec_finishing = false;
    var rec_track: ?usize = null;

    // Input-device picker state. Re-enumerated periodically (picks up hotplug
    // within ~1s). `input_name_ptrs` are C-string views into `input_devices`.
    var input_devices: [audio_mod.MAX_INPUT_DEVICES]audio_mod.InputDevice = undefined;
    var input_name_ptrs: [audio_mod.MAX_INPUT_DEVICES][*:0]const u8 = undefined;
    var input_count: usize = 0;
    var input_refresh: u32 = 0;

    // ── UI state ─────────────────────────────────────────────────────
    var layout: layout_mod.State = .{};
    layout.clip_editor_visible = true;
    var selected_clip: ?clip_mod.ClipRef = null;
    var prev_selected_clip: ?clip_mod.ClipRef = selected_clip;
    var selected_track: ?usize = 0;
    // Which device the machine bay shows. Decoupled from selected_track (the
    // audio/clip selection) so buses can be edited without touching clip code.
    var device_sel: arrangement.DeviceSel = .audio;
    var history: history_mod.History = .{};
    defer history.deinit(alloc);
    var project_path = try alloc.dupe(u8, document_mod.SAVE_PATH);
    defer alloc.free(project_path);
    var project_path_chosen = false;
    var focus: FocusPane = .arrangement;
    var dirty = false;
    var auto_was_playing = false;
    var auto_arm = false;
    var auto_rec: AutoRecorder = .{};
    var shot_frame: u32 = 0;
    var clipboard: EditClipboard = .{};
    defer clipboard.deinit(alloc);
    var status: StatusMessage = .{};
    var edit_snap: snap_mod.Setting = .note_16;
    var rename: RenameState = .{};
    var render_dlg: export_dialog.State = .{};
    var bounce_dlg: bounce_dialog.State = .{};
    var about_card: about.State = .{};
    var uni_panel: unison_panel.State = .{};
    var color_pick: color_picker.State = .{};
    // A track awaiting the delete confirmation, and the dialog's text.
    var pending_delete: ?usize = null;
    var delete_msg: DeleteMsg = .{};
    // Several tracks to delete, once the dialog says so.
    var pending_delete_set: ?[MAX_TRACKS]bool = null;
    var render_job: RenderJob = .{};
    var bounce_job: BounceJob = .{};
    var next_recipe_check: f64 = 0;
    // The library browser (docs/25 §The browser): scanned on first show
    // and whenever what it lists may have changed.
    var lib = library_mod.Library.init(alloc);
    defer lib.deinit();
    var br: browser.State = .{};
    defer br.deinit(alloc);
    var lib_stale = true;
    var drop_ok = false;
    br.devSetup();

    // What File > New Project starts from: the app as it boots.
    blank_project = try document_mod.serialize(alloc, tracks_buf[0..track_count], &transport);
    defer alloc.free(blank_project);

    // A double-click that launched slab names the project in place of argv.
    const finder_project = try native_app.takeOpenedPath(alloc);
    defer if (finder_project) |p| alloc.free(p);
    if (cli.project orelse finder_project) |path| {
        splash.bootFrame(ui, screenRect(), "LOADING PROJECT", 0);
        document_mod.progress = .{ .ctx = ui, .step = loadingStep };
        defer document_mod.progress = null;
        if (document_mod.readFile(alloc, path)) |data| {
            defer alloc.free(data);
            useProject(path);
            var boot_tracks = tracks_buf[0..track_count];
            applyProjectBytes(alloc, data, &reg, &tracks_buf, &track_count, &boot_tracks, &transport, &engine, &audio, &selected_track, &selected_clip, &prev_selected_clip) catch |err| {
                std.log.err("open {s} failed: {s}", .{ path, @errorName(err) });
            };
            replaceProjectPath(alloc, &project_path, try alloc.dupe(u8, path));
            project_path_chosen = true;
            reportLoaded(alloc, &status, data, project_path);
        } else |err| std.log.err("open {s} failed: {s}", .{ path, @errorName(err) });
    }

    splash.finishBoot();
    // Idle throttle: once the UI has been quiet (no input, no drag, stopped
    // transport) for a moment, redraw at IDLE_FPS instead of 120.
    var quiet_frames: u32 = 0;
    var fps_idle = false;
    while (!c.rl.WindowShouldClose()) {
        // A queued open runs here, between frames, behind the loading card.
        if (pending_open) |path| {
            pending_open = null;
            defer alloc.free(path);
            splash.bootFrame(ui, screenRect(), "LOADING PROJECT", 0);
            document_mod.progress = .{ .ctx = ui, .step = loadingStep };
            defer document_mod.progress = null;
            var open_tracks = tracks_buf[0..track_count];
            try openProjectPath(alloc, &history, &tracks_buf, &track_count, &open_tracks, &transport, &engine, &audio, &reg, &selected_track, &selected_clip, &prev_selected_clip, &project_path, &project_path_chosen, &dirty, &status, path);
            splash.finishBoot();
        }
        const sw: f32 = @floatFromInt(c.rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(c.rl.GetScreenHeight());
        ui.beginFrame();
        devDrag(ui, shot_frame);
        pane.beginFrame();
        const m = pane.Mouse.fromInput(&ui.raw_in);
        menu.beginFrame(ui, @intFromFloat(sw), @intFromFloat(sh));
        // One owner of the pointer at a time: a legacy menu, modal or drag
        // hides input from the new Ui, and a new-Ui drag hides it from the
        // legacy panes.
        const modal = render_dlg.active or bounce_dlg.active or about_card.active or pending_delete != null or pending_delete_set != null or uni_panel.active or color_pick.active;
        if (menu.active() or modal or pane.hasActiveDrag()) ui.suppressInput();

        // While a menu is open it's modal for the mouse: panes get a
        // neutralized mouse (no hover/clicks fall through), the menu keeps
        // handling input off the raw frame mouse captured in beginFrame.
        // A new-Ui widget that owns or hovers the pointer (a seam, a toolbar
        // tile) hides it from the legacy panes, so one press never lands in
        // both UIs.
        const pane_m = if (menu.active() or modal or ui.active != 0 or ui.hot != 0) pane.neutral() else m;

        layout.splitters(ui, sw, sh);

        var rects = layout.compute(sw, sh);
        var tracks = tracks_buf[0..track_count];
        if (!layout.clipShown() and focus == .piano_roll) focus = .arrangement;
        if (pane_m.left_pressed) focus = focusFromPoint(rects, pane_m, layout.clipShown());
        // The browser is all Ui widgets, which hide the press from the
        // panes: a press there, or one leaving it, moves the focus too.
        if (m.left_pressed and !menu.active() and !modal) {
            if (pane.contains(rects.browser, m.x, m.y)) focus = .browser else if (focus == .browser) focus = focusFromPoint(rects, m, layout.clipShown());
        }

        if (modal) {
            // Modal: only Esc/Enter act, handled after the dialog draws below.
        } else if (menu.active()) {
            // An open menu owns the keyboard (arrows, enter, esc).
        } else if (rename.active() or auto_lane.entryActive() or browser.typing(ui)) {
            // The rename field owns the keyboard (runs after the panes).
        } else if (try handleProjectShortcuts(
            alloc,
            &history,
            &tracks_buf,
            &track_count,
            &tracks,
            &transport,
            &engine,
            &audio,
            &reg,
            &selected_track,
            &selected_clip,
            &prev_selected_clip,
            &project_path,
            &project_path_chosen,
            &dirty,
            &status,
        )) {
            rects = layout.compute(sw, sh);
        } else {
            if (shouldCaptureHistory(m, rects, focus)) {
                pushHistorySnapshot(alloc, &history, tracks, &transport);
                dirty = true;
            }
            // With the browser focused, letters search and arrows move in
            // it: the panes' editing keys stand down.
            const in_browser = focus == .browser and layout.browser_visible;
            if (!in_browser) {
                handleSnapKeys(&edit_snap, &status);
                try handleFocusedEditCommands(alloc, &history, &clipboard, &status, focus, edit_snap, tracks, &transport, &selected_track, &selected_clip, &rename, &dirty);
                try handleFocusedDelete(alloc, &history, &status, focus, tracks, &transport, &selected_clip, &dirty);
            }
            if (commandModifierDown() and c.rl.IsKeyPressed(c.rl.KEY_R)) export_dialog.open(&render_dlg);
            if (commandModifierDown() and !ui.in.alt and c.rl.IsKeyPressed(c.rl.KEY_B)) openBounce(&bounce_dlg, tracks, &status);
            if (commandModifierDown() and c.rl.IsKeyPressed(c.rl.KEY_F)) {
                layout.browser_visible = true;
                focus = .browser;
                br.focusSearch();
            }
            if (commandModifierDown() and ui.in.alt and c.rl.IsKeyPressed(c.rl.KEY_B)) layout.browser_visible = !layout.browser_visible;
            if (c.rl.IsKeyPressed(c.rl.KEY_SPACE)) transport.toggle();
            if (c.rl.IsKeyPressed(c.rl.KEY_HOME)) transport.rewind();
            if (!in_browser and c.rl.IsKeyPressed(c.rl.KEY_TAB)) layout.clip_editor_visible = !layout.clip_editor_visible;
            if (!in_browser and !commandModifierDown() and c.rl.IsKeyPressed(c.rl.KEY_M)) {
                if (shiftDown()) {
                    try executeEditCommand(alloc, &history, &clipboard, &status, focus, edit_snap, .clear_solo_mute, .{}, tracks, &transport, &selected_track, &selected_clip, &rename, &dirty);
                } else layout.mixer_visible = !layout.mixer_visible;
            }
            if (focus == .piano_roll and !commandModifierDown() and c.rl.IsKeyPressed(c.rl.KEY_E)) clip_editor.toggleExpressionMode();
        }

        c.rl.BeginDrawing();
        c.rl.ClearBackground(@bitCast(ui_style.chassis));

        const rec_busy = recorder.isRecording() or rec_finishing;
        // The mic opens only while it can be used: an armed track or a take
        // in flight. Idle, the device is playback-only (see Audio.want_capture).
        audio.setWantCapture(rec_busy or firstArmedAudioTrack(tracks) != null) catch |err| {
            std.log.err("audio device switch failed: {s}", .{@errorName(err)});
            status.set("Audio device failed", .{});
        };
        // A reopened device has a new I/O workgroup for the workers.
        if (audio.device_gen != audio_gen) {
            audio_gen = audio.device_gen;
            if (engine.pool) |p| p.setWorkgroup(audio.workgroup());
        }

        // Refresh the input-device list ~once/sec and resolve the active one.
        if (input_refresh % 60 == 0) {
            input_count = audio.listInputDevices(&input_devices);
            for (0..input_count) |i| input_name_ptrs[i] = &input_devices[i].name;
        }
        input_refresh +%= 1;
        const cur_input_name = audio.currentInputName();
        var current_input_idx: ?usize = null;
        for (0..input_count) |i| {
            if (std.mem.eql(u8, std.mem.sliceTo(&input_devices[i].name, 0), cur_input_name)) {
                current_input_idx = i;
                break;
            }
        }

        const cpu_load = audio.takeLoad();
        var thread_load: [8]f32 = undefined;
        const n_threads = engine.takeThreadLoad(&thread_load, audio_mod.SAMPLE_RATE);
        var tres = transport_bar.draw(ui, uiRect(rects.top_bar), .{
            .transport = &transport,
            .meter_state = &meter_state,
            .edit_snap = &edit_snap,
            .project_path = project_path,
            .project_path_chosen = project_path_chosen,
            .dirty = dirty,
            .recording = rec_busy,
            .can_record = audio.capture_available,
            .input_names = input_name_ptrs[0..input_count],
            .current_input_idx = current_input_idx,
            .master_peak = .{ master.meter().l, master.meter().r },
            .master_volume = master.volume(),
            .auto_arm = auto_arm,
            .pdc_latency = engine.master_latency.load(.monotonic),
            .cpu_load = cpu_load.avg,
            .thread_load = thread_load[0..n_threads],
            .cpu_peak = cpu_load.peak,
            .browser_visible = layout.browser_visible,
        });
        // The menu bar's commands run as the in-app File menu's do.
        const menu_cmds = native_app.takeCommands();
        tres.new_project = tres.new_project or menu_cmds.has(.new_project);
        tres.open_project = tres.open_project or menu_cmds.has(.open_project);
        tres.save_project = tres.save_project or menu_cmds.has(.save_project);
        tres.save_project_as = tres.save_project_as or menu_cmds.has(.save_project_as);
        tres.clean_up_project = tres.clean_up_project or menu_cmds.has(.clean_up_project);
        tres.render_audio = tres.render_audio or menu_cmds.has(.render_audio);
        tres.toggle_browser = tres.toggle_browser or menu_cmds.has(.toggle_browser);
        if (menu_cmds.has(.undo) or menu_cmds.has(.redo)) {
            try undoRedo(alloc, &history, &tracks_buf, &track_count, &tracks, &transport, &engine, &audio, &reg, &selected_track, &selected_clip, &prev_selected_clip, &project_path, &project_path_chosen, &dirty, &status, menu_cmds.has(.redo));
        }
        if (tres.toggle_browser) {
            layout.browser_visible = !layout.browser_visible;
            rects = layout.compute(sw, sh);
        }
        if (tres.auto_arm_toggle) {
            auto_arm = !auto_arm;
            status.set("{s}", .{if (auto_arm) "Automation recording armed" else "Automation recording off"});
        }
        if (tres.render_audio) export_dialog.open(&render_dlg);
        if (menu_cmds.has(.bounce)) openBounce(&bounce_dlg, tracks, &status);
        if (tres.about or menu_cmds.has(.about)) about_card.active = true;
        if (tres.master_volume) |v| {
            master.setVolume(v);
            dirty = true;
        }
        if (tres.panic) {
            transport.stop();
            engine.panic();
            status.set("All sound killed", .{});
        }
        if (tres.input_pick) |pi| {
            if (rec_busy) {
                status.set("Stop recording before switching input", .{});
            } else if (pi < input_count) {
                audio.useInputDevice(&input_devices[pi].id) catch |err| {
                    std.log.err("input switch failed: {s}", .{@errorName(err)});
                    status.set("Input switch failed", .{});
                };
                input_refresh = 0; // force re-enumerate + re-resolve next frame
                status.set("Input: {s}", .{std.mem.sliceTo(&input_devices[pi].name, 0)});
            }
        }
        if (tres.record_toggle and !rec_finishing) {
            if (recorder.isRecording()) {
                recorder.requestStop();
                transport.stop();
                rec_finishing = true;
            } else {
                rec_track = firstArmedAudioTrack(tracks);
                if (rec_track == null) {
                    status.set("Arm a track (R) to record", .{});
                } else {
                    recorder.start() catch |err| {
                        std.log.err("record start failed: {s}", .{@errorName(err)});
                        status.set("Record failed to start", .{});
                        rec_track = null;
                    };
                    if (rec_track != null) {
                        transport.play();
                        status.set("Recording\u{2026}", .{});
                    }
                }
            }
        }

        // The library browser (docs/25 §The browser).
        previewer.collect(&engine);
        // A pack import that finished brings its presets and samples.
        if (lib.packs.poll()) {
            lib_stale = true;
            status.set("Pack import finished", .{});
        }
        if (layout.browser_visible) {
            if (lib_stale) {
                lib.scan(&reg);
                lib_stale = false;
            }
            const items = lib.items.items;
            br.play_at = previewer.at(&engine);
            br.playing = if (br.play_at == null) null else br.playing;
            br.wave = .{};
            if (br.current()) |cur| if (cur < items.len) if (previewer.cur) |*s| {
                if (std.mem.eql(u8, previewer.path(), items[cur].path)) br.wave = .{ .data = s.data, .frame = if (items[cur].kind == .table) (if (s.frame_size > 0) s.frame_size else 2048) else 0 };
            };
            const bres = browser.draw(ui, uiRect(rects.browser), &br, &lib, focus == .browser);
            // Clips dragged from the arrangement onto the browser are saved
            // to the library (docs/25 §Save to Library); they stay put.
            if (arrangement.clipMoveActive() and pane.contains(rects.browser, m.x, m.y)) {
                browser.drawTarget(ui, uiRect(rects.browser), true, "SAVE TO LIBRARY");
                if (!ui.raw_in.down) {
                    arrangement.abortClipMove(tracks);
                    saveClipsToLibrary(alloc, tracks, &status);
                    lib_stale = true;
                }
            }
            if (bres.rescan) lib_stale = true;
            if (bres.status) |msg| status.set("{s}", .{msg});
            if (bres.reveal) |p| native_dialog.reveal(p);
            if (bres.open) |p| native_dialog.open(p);
            if (bres.remove_pack) |p| {
                if (native_dialog.trash(p)) {
                    status.set("Moved {s} to the Trash", .{std.fs.path.basename(p)});
                    lib_stale = true;
                } else status.set("Couldn't move {s} to the Trash", .{p});
            }
            if (bres.selected) |sel| if (sel < items.len) {
                const k = items[sel].kind;
                if (k == .sample or k == .table) _ = previewer.select(&engine, items[sel].path);
            };
            if (bres.stop_audition) previewer.stop(&engine);
            if (bres.audition) |a| if (a < items.len and items[a].kind == .sample) {
                if (previewer.select(&engine, items[a].path) != null) {
                    previewer.play(&engine);
                    br.playing = a;
                } else status.set("Can't play {s}", .{items[a].name});
            };
            if (bres.load) if (br.current()) |cur| {
                const sel_t: ?usize = if (selected_track) |t| (if (t < tracks.len) t else null) else null;
                const target: BrowserDrop = switch (items[cur].kind) {
                    .song => .open_song,
                    .preset, .table => if (sel_t) |t| .{ .header = t } else .new_track,
                    else => if (sel_t) |t| .{ .lane = .{ .track = t, .beat = trackEnd(&tracks[t]) } } else .new_track,
                };
                const app = App{ .alloc = alloc, .history = &history, .tracks_buf = &tracks_buf, .track_count = &track_count, .tracks = &tracks, .transport = &transport, .engine = &engine, .audio = &audio, .reg = &reg, .pool = &audio_pool, .selected_track = &selected_track, .selected_clip = &selected_clip, .prev_selected_clip = &prev_selected_clip, .project_path = &project_path, .project_path_chosen = &project_path_chosen, .dirty = &dirty, .status = &status, .edit_snap = edit_snap };
                if (browserDrop(app, &lib, br.selection(), cur, target)) lib_stale = true;
                rects = layout.compute(sw, sh);
            };
        }

        // Automation (docs/22): sticky overrides end when the transport
        // starts; every machine control shows its lane's value at the
        // playhead before any panel draws.
        const playing_now = transport.isPlaying();
        if (playing_now and !auto_was_playing) clearAutomationOverrides(tracks);
        auto_was_playing = playing_now;
        syncAutomationUi(tracks, transport.beats());

        var ares: arrangement.Result = .{};
        if (layout.mixer_visible) {
            const mres = mixer.draw(ui, rects.arrangement, tracks, &master, &device_sel, &selected_track, transport.beats());
            ares.route = mres.route;
            ares.add_track = mres.add_track;
            ares.add_bus = mres.add_bus;
            ares.move_tracks = mres.move_tracks;
            ares.color_pick = mres.color_pick;
            if (mres.toggle) layout.mixer_visible = false;
        } else {
            ares = arrangement.draw(ui, rects.arrangement, tracks, &master, &device_sel, &audio_pool, alloc, &selected_track, &selected_clip, &transport, &meter_state, edit_snap, clipboard.mode == .clips, arrangementRenameTarget(&rename), &recorder, pane_m);
            if (ares.toggle_mixer) layout.mixer_visible = true;
        }
        if (ares.rename_clip) |ref| beginRenameClip(&rename, tracks, ref);
        if (ares.rename_track) |ti| beginRenameTrack(&rename, tracks, ti);
        if (ares.color_pick) |cp| color_pick.open(cp.track, cp.at);
        if (ares.move_tracks) |mv| {
            if (recorder.isRecording()) {
                status.set("Stop recording to move tracks", .{});
            } else {
                moveTracks(alloc, &history, &audio, &engine, &tracks_buf, track_count, &transport, &mv, &selected_track, &selected_clip, &prev_selected_clip, &rename) catch |err| status.set("Move failed: {s}", .{@errorName(err)});
                dirty = true;
            }
        }
        if (ares.rename_rect) |rr| rename.rect = rr;
        // Tempo changes on the ruler: one undo step each, a drag included.
        if (ares.tempo_edit != null or ares.tempo_drag_start) {
            pushHistorySnapshot(alloc, &history, tracks, &transport);
            if (ares.tempo_edit) |te| arrangement.applyTempoEdit(&transport, te);
            dirty = true;
        }
        if (ares.command == .bounce) {
            openBounce(&bounce_dlg, tracks, &status);
        } else if (ares.command == .rebounce) {
            startRebounce(alloc, &engine, &audio, &audio_pool, &transport, tracks, &selected_clip, &bounce_job, &bounce_dlg, &status);
        } else if (ares.command == .thaw) {
            thawBounce(alloc, &history, &status, tracks, &transport, &selected_clip, &dirty) catch |err| status.set("Thaw failed: {s}", .{@errorName(err)});
        } else if (ares.command == .import_audio) {
            importAudioClip(alloc, &audio_pool, &history, &status, tracks, &transport, edit_snap, &selected_track, &selected_clip, &dirty, ares.command_beat, ares.command_track) catch |err| {
                std.log.err("import audio failed: {s}", .{@errorName(err)});
                status.set("Audio import failed", .{});
            };
        } else if (ares.command != .none) {
            try executeEditCommand(alloc, &history, &clipboard, &status, .arrangement, edit_snap, ares.command, .{
                .beat = ares.command_beat,
                .track = ares.command_track,
            }, tracks, &transport, &selected_track, &selected_clip, &rename, &dirty);
        }
        if (ares.add_track or ares.add_bus) {
            if (appendTrack(alloc, &history, &audio, &tracks_buf, &track_count, &transport, ares.add_bus)) |ti| {
                selected_track = ti;
                selected_clip = null;
                tracks = tracks_buf[0..track_count];
                engine.tracks = tracks;
                dirty = true;
                status.set("Added {s}", .{tracks[ti].name()});
            } else |err| status.set("Can't add: {s}", .{@errorName(err)});
        }
        // ⌘G groups the selection (or the selected track).
        var route_edit = ares.route;
        if (route_edit == null and !modal and !rename.active() and ui.in.cmd and c.rl.IsKeyPressed(c.rl.KEY_G)) if (selected_track) |st| {
            route_edit = .{ .track = st, .what = .group, .selection = true };
        };
        // Dev hook: SLAB_SHOT_GROUP=NAME,NAME,… selects those tracks and
        // groups them on frame 200, as ⌘G would.
        if (route_edit == null and shot_frame == 200) if (std.c.getenv("SLAB_SHOT_GROUP")) |spec| {
            var it = std.mem.splitScalar(u8, std.mem.span(spec), ',');
            for (tracks) |*t| t.multi_sel = false;
            while (it.next()) |name| for (tracks, 0..) |*t, k| if (std.mem.eql(u8, t.name(), name)) {
                t.multi_sel = true;
                selected_track = k;
            };
            if (selected_track) |st| route_edit = .{ .track = st, .what = .group, .selection = true };
        };
        if (route_edit) |edit| if (edit.what == .group) {
            if (recorder.isRecording() or rec_finishing) {
                status.set("Stop recording to group tracks", .{});
            } else if (edit.track < track_count) {
                const set = actionSet(tracks, selected_track, edit.track, edit.selection);
                groupTracks(alloc, &history, &status, &audio, &engine, &tracks_buf, &track_count, &transport, &set, &selected_track, &selected_clip, &prev_selected_clip, &rename) catch |err| status.set("Can't group: {s}", .{@errorName(err)});
                tracks = tracks_buf[0..track_count];
                dirty = true;
            }
        } else if (edit.what == .duplicate and edit.selection) {
            const set = actionSet(tracks, selected_track, edit.track, true);
            if (document_mod.serialize(alloc, tracks, &transport)) |before| {
                var n: usize = 0;
                var k = track_count;
                // From the bottom, so each copy leaves the rest in place.
                while (k > 0) {
                    k -= 1;
                    if (!set[k]) continue;
                    duplicateTrack(alloc, &history, &status, &audio, &engine, &reg, &tracks_buf, &track_count, &transport, k, &selected_track, &selected_clip, &prev_selected_clip, false) catch break;
                    n += 1;
                }
                history.pushUndo(alloc, before) catch alloc.free(before);
                for (tracks_buf[0..track_count]) |*t| t.multi_sel = false;
                status.set("Duplicated {d} tracks", .{n});
            } else |err| status.set("Duplicate failed: {s}", .{@errorName(err)});
            tracks = tracks_buf[0..track_count];
            dirty = true;
        } else if (edit.what == .delete and edit.selection) {
            if (recorder.isRecording() or rec_finishing) {
                status.set("Stop recording before deleting a track", .{});
            } else {
                const set = actionSet(tracks, selected_track, edit.track, true);
                var n: usize = 0;
                for (set[0..track_count]) |b| n += @intFromBool(b);
                delete_msg = .{};
                delete_msg.add("{d} tracks and all on them go.", .{n});
                delete_msg.add("Undo brings them back.", .{});
                pending_delete_set = set;
            }
        } else if (edit.what == .duplicate) {
            duplicateTrack(alloc, &history, &status, &audio, &engine, &reg, &tracks_buf, &track_count, &transport, edit.track, &selected_track, &selected_clip, &prev_selected_clip, true) catch |err| status.set("Duplicate failed: {s}", .{@errorName(err)});
            tracks = tracks_buf[0..track_count];
            dirty = true;
        } else if (edit.what == .delete) {
            if (recorder.isRecording() or rec_finishing) {
                status.set("Stop recording before deleting a track", .{});
            } else if (edit.track < track_count) {
                if (trackContents(tracks, edit.track, &delete_msg)) pending_delete = edit.track else {
                    deleteTrack(alloc, &history, &status, &audio, &engine, &tracks_buf, &track_count, &transport, edit.track, &selected_track, &selected_clip, &prev_selected_clip, &rename, true) catch |err| status.set("Delete failed: {s}", .{@errorName(err)});
                    tracks = tracks_buf[0..track_count];
                    dirty = true;
                }
            }
        } else {
            applyRouteEdit(alloc, &history, &status, &audio, edit, &tracks_buf, &track_count, &transport) catch |err| {
                status.set("Routing failed: {s}", .{@errorName(err)});
            };
            tracks = tracks_buf[0..track_count];
            engine.tracks = tracks;
            dirty = true;
        };
        const selection_changed = !clipRefEq(selected_clip, prev_selected_clip);
        if (selection_changed and selected_clip != null) {
            layout.clip_editor_visible = true;
            rects = layout.compute(sw, sh);
        }
        if (layout.clipShown()) {
            const play_beat: ?f64 = if (transport.isPlaying()) transport.beats() else null;
            const cres = if (selectedClipIsAudio(tracks, selected_clip))
                audio_clip_editor.draw(ui, rects.clip_editor, tracks, &audio_pool, selected_clip, transport.map(), play_beat, pane_m)
            else
                clip_editor.draw(ui, rects.clip_editor, tracks, alloc, selected_clip, meter_state.liveMap(), edit_snap, clipboard.mode == .notes, play_beat, pane_m);
            if (rename.active() and rename.kind == .clip) {
                if (cres.rename_rect) |rr| rename.rect = rr;
            }
            if (cres.minimize or cres.close) layout.clip_editor_visible = false;
            if (cres.audition_pitch) |pitch| {
                if (selected_clip) |s| engine.auditionNote(s.track, pitch);
            }
            if (cres.command != .none) {
                try executeEditCommand(alloc, &history, &clipboard, &status, .piano_roll, edit_snap, cres.command, .{
                    .beat = cres.command_beat,
                    .pitch = cres.command_pitch,
                }, tracks, &transport, &selected_track, &selected_clip, &rename, &dirty);
            }
        }
        // Resolve which device the machine bay edits from device_sel.
        var bay_dev: ?*track_mod.Track = null;
        var bay_idx: ?usize = null;
        var bay_is_bus = false;
        switch (device_sel) {
            .audio => {
                if (selected_track) |ti| if (ti < tracks.len) {
                    bay_dev = &tracks[ti];
                    bay_idx = ti;
                    bay_is_bus = tracks[ti].isBus();
                };
            },
            .master => {
                bay_dev = &master;
                bay_is_bus = true;
            },
        }

        machine_bay.sample_rate = transport.sample_rate;
        const mbres = machine_bay.draw(ui, rects.machine_bay, bay_dev, bay_idx, bay_is_bus, layout.machine_bay_collapsed, &reg, tracks);
        if (mbres.key_menu_fx) |uid| if (bay_idx) |ti| @import("ui/route_menu.zig").openKey(ti, uid, mbres.key_menu_at[0], mbres.key_menu_at[1]);
        if (mbres.unison_at) |at| if (bay_idx) |ti| if (!bay_is_bus) {
            // One undo step for the panel's edits: the state it opened on.
            pushHistorySnapshot(alloc, &history, tracks, &transport);
            uni_panel.open(ti, at);
        };
        if (mbres.minimize) layout.machine_bay_collapsed = !layout.machine_bay_collapsed;
        if (mbres.add_machine) |reg_idx| {
            if (bay_dev) |dev| {
                const entry = &reg.entries[reg_idx];
                const is_effect = entry.in_audio and entry.out_audio and !entry.in_notes;
                if (bay_is_bus and !is_effect) {
                    status.set("Master takes effects only", .{});
                } else if (is_effect) {
                    addEffectToTrack(alloc, &audio, &reg, dev, reg_idx) catch |err| {
                        std.log.err("add effect failed: {s}", .{@errorName(err)});
                        status.set("Effect failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    if (mbres.add_preset) |pi| {
                        const fx = &dev.effects.items[dev.effects.items.len - 1].mach;
                        if (fx.apply_preset) |ap| ap(fx.state, pi);
                    }
                    dirty = true;
                    status.set("Added {s}", .{entry.nameSlice()});
                } else {
                    assignMachineToTrack(alloc, &audio, &reg, dev, reg_idx) catch |err| {
                        std.log.err("instantiate machine failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    if (mbres.add_preset) |pi| {
                        if (dev.machine.apply_preset) |ap| ap(dev.machine.state, pi);
                    }
                    dirty = true;
                    status.set("Assigned {s}", .{entry.nameSlice()});
                    const nm = entry.nameSlice();
                    const n = @min(nm.len, track_mod.MAX_NAME);
                    @memcpy(dev.name_buf[0..n], nm[0..n]);
                    dev.name_len = @intCast(n);
                }
            }
        }
        // Name block → replace an existing device's machine.
        if (mbres.replace_machine) |reg_idx| {
            if (mbres.replace_ref) |ref| if (bay_dev) |dev| {
                const entry = &reg.entries[reg_idx];
                const is_effect = entry.in_audio and entry.out_audio and !entry.in_notes;
                switch (ref) {
                    .instrument => {
                        if (bay_is_bus or is_effect) {
                            status.set("Pick an instrument", .{});
                        } else {
                            pushHistorySnapshot(alloc, &history, tracks, &transport);
                            assignMachineToTrack(alloc, &audio, &reg, dev, reg_idx) catch |err| {
                                std.log.err("replace instrument failed: {s}", .{@errorName(err)});
                                status.set("Replace failed: {s}", .{@errorName(err)});
                                continue;
                            };
                            if (mbres.replace_preset) |pi| if (dev.machine.apply_preset) |ap| ap(dev.machine.state, pi);
                            const nm = entry.nameSlice();
                            const n = @min(nm.len, track_mod.MAX_NAME);
                            @memcpy(dev.name_buf[0..n], nm[0..n]);
                            dev.name_len = @intCast(n);
                            dirty = true;
                            status.set("Replaced with {s}", .{entry.nameSlice()});
                        }
                    },
                    .effect => |i| {
                        if (!is_effect) {
                            status.set("Replacement must be an effect", .{});
                        } else if (i < dev.effectCount()) {
                            if (!bay_is_bus) pushHistorySnapshot(alloc, &history, tracks, &transport);
                            replaceEffectOnTrack(alloc, &audio, &reg, dev, i, reg_idx) catch |err| {
                                std.log.err("replace effect failed: {s}", .{@errorName(err)});
                                status.set("Replace failed: {s}", .{@errorName(err)});
                                continue;
                            };
                            if (mbres.replace_preset) |pi| {
                                const fx = &dev.effects.items[i].mach;
                                if (fx.apply_preset) |ap| ap(fx.state, pi);
                            }
                            dirty = true;
                            status.set("Replaced effect with {s}", .{entry.nameSlice()});
                        }
                    },
                }
            };
        }
        // Delete (confirmed) → remove the targeted device.
        if (mbres.remove_ref) |ref| if (bay_dev) |dev| {
            switch (ref) {
                .instrument => if (!bay_is_bus and dev.machine_idx != null) {
                    pushHistorySnapshot(alloc, &history, tracks, &transport);
                    audio.stop();
                    defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
                    dev.replaceMachine(alloc, silent_machine);
                    dev.machine_idx = null;
                    dev.setEnabled(true);
                    dirty = true;
                    status.set("Removed machine", .{});
                },
                .effect => |fx_i| if (fx_i < dev.effectCount()) {
                    // Audio-track effect removals are undoable; master FX aren't
                    // captured by the snapshot (FX chains aren't serialized yet).
                    if (!bay_is_bus) pushHistorySnapshot(alloc, &history, tracks, &transport);
                    audio.stop();
                    defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
                    dev.removeEffect(alloc, fx_i);
                    dirty = true;
                    status.set("Removed effect", .{});
                },
            }
        };
        // Drag-reorder effects.
        if (mbres.reorder_from) |from| if (mbres.reorder_to) |to| if (bay_dev) |dev| {
            if (!bay_is_bus) pushHistorySnapshot(alloc, &history, tracks, &transport);
            audio.stop();
            defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
            dev.moveEffect(from, to);
            dirty = true;
            status.set("Reordered effects", .{});
        };
        // Preset block → apply / save (name entry) / rename (name entry).
        if (mbres.preset_apply) |preset| if (mbres.preset_apply_ref) |ref| if (bay_dev) |dev| {
            if (deviceMachineOf(dev, refEffect(ref))) |mach| if (mach.apply_preset) |apply| {
                if (!bay_is_bus) pushHistorySnapshot(alloc, &history, tracks, &transport);
                audio.stop();
                defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
                apply(mach.state, preset);
                dirty = true;
                status.set("Preset {s}", .{if (mach.preset_name) |name| name(mach.state, preset) else ""});
            };
        };
        if (mbres.preset_save_ref) |ref| if (bay_dev) |dev| {
            beginPresetSave(&rename, dev, refEffect(ref), mbres.preset_anchor, mbres.preset_save_library);
        };
        if (mbres.preset_rename_ref) |ref| if (mbres.preset_rename_index) |idx| if (bay_dev) |dev| {
            const eff = refEffect(ref);
            if (deviceMachineOf(dev, eff)) |mach| {
                var cur: []const u8 = "";
                if (mach.preset_name) |nf| cur = std.mem.span(nf(mach.state, idx));
                // The field edits the bare name; the preset stays in its bank.
                if (std.mem.lastIndexOfScalar(u8, cur, '/')) |slash| cur = cur[slash + 1 ..];
                beginPresetRename(&rename, dev, eff, idx, cur, mbres.preset_anchor);
            }
        };

        // A drag from the browser: light the target under the pointer, and
        // do the drop on release.
        drop_ok = false;
        if (browser.dragging(&br)) {
            const items = lib.items.items;
            const cur = br.current() orelse 0;
            const kind = if (cur < items.len) items[cur].kind else .preset;
            const mx = ui.raw_in.mx;
            const my = ui.raw_in.my;
            var target: BrowserDrop = .none;
            const bay = uiRect(rects.machine_bay);
            if (kind == .song and pane.contains(rects.arrangement, mx, my)) {
                target = .open_song;
                browser.drawTarget(ui, uiRect(rects.arrangement), true, "OPEN THIS SONG");
            } else if (!layout.mixer_visible and arrangement.dropHit(tracks, mx, my) != null) {
                const hit = arrangement.dropHit(tracks, mx, my).?;
                if (hit.track) |ti| {
                    if (hit.header) target = .{ .header = ti } else {
                        const beat = snap_mod.snapDownPositive(edit_snap, hit.beat, ui.in.alt);
                        target = .{ .lane = .{ .track = ti, .beat = beat } };
                    }
                } else target = .new_track;
                drop_ok = dropAccepts(kind, target, tracks);
                switch (target) {
                    .header => browser.drawTarget(ui, hit.head, drop_ok, if (kind == .table) "LOAD TABLE" else if (kind == .preset) "LOAD PRESET" else ""),
                    .lane => |l| if (drop_ok and (kind == .clip or kind == .sample)) {
                        const len = dragBeats(&lib, &br, &previewer, transport.bpm());
                        browser.drawLanding(ui, hit.lane, @intFromFloat(arrangement.beatX(l.beat)), @intFromFloat(arrangement.beatX(l.beat + len)));
                    } else browser.drawTarget(ui, hit.lane, drop_ok, if (drop_ok and kind == .table) "LOAD TABLE" else if (drop_ok) "LOAD PRESET" else ""),
                    .new_track => browser.drawNewTrack(ui, hit.lane, drop_ok),
                    else => {},
                }
            } else if (bay.contains(@intFromFloat(mx), @intFromFloat(my)) and selected_track != null) {
                target = .{ .header = selected_track.? };
                drop_ok = dropAccepts(kind, target, tracks);
                browser.drawTarget(ui, bay, drop_ok, if (kind == .table) "LOAD TABLE" else if (kind == .preset) "LOAD PRESET" else "");
            }
            if (target == .open_song) drop_ok = kind == .song;
            if (ui.in.keyPressed(c.rl.KEY_ESCAPE)) {
                browser.endDrag(ui, &br);
            } else if (!ui.raw_in.down) {
                browser.endDrag(ui, &br);
                if (drop_ok) {
                    const app = App{ .alloc = alloc, .history = &history, .tracks_buf = &tracks_buf, .track_count = &track_count, .tracks = &tracks, .transport = &transport, .engine = &engine, .audio = &audio, .reg = &reg, .pool = &audio_pool, .selected_track = &selected_track, .selected_clip = &selected_clip, .prev_selected_clip = &prev_selected_clip, .project_path = &project_path, .project_path_chosen = &project_path_chosen, .dirty = &dirty, .status = &status, .edit_snap = edit_snap };
                    if (browserDrop(app, &lib, br.selection(), cur, target)) lib_stale = true;
                    rects = layout.compute(sw, sh);
                }
            }
        }

        if (serviceAutomationRequests(alloc, &history, tracks, &transport, &selected_track, &status)) dirty = true;
        // Edits no control holds (a wavetable drawn in the editor).
        for (tracks) |*t| if (t.machine.takeEdited()) {
            dirty = true;
        };
        if (auto_rec.tick(alloc, &history, tracks, &transport, auto_arm and transport.isPlaying())) dirty = true;

        try runRename(ui, alloc, &history, &rename, tracks, &transport, &dirty, &status);

        // Export dialog (modal: input behind it is suppressed above).
        var render_action: export_dialog.Result = .none;
        if (render_dlg.active) {
            const prog: ?export_dialog.Progress = if (render_job.active) renderProgress(&render_job) else null;
            render_action = export_dialog.draw(ui, uiRect(pane.rect(0, 0, sw, sh)), &render_dlg, .{
                .settings = &export_cfg,
                .presets = &export_presets,
                .tracks = tracks,
                .project = blk: {
                    const st = projectStem(project_path);
                    break :blk if (st.len > 0) st else "untitled";
                },
                .bpm = transport.baseBpm(),
                .range_secs = rangeSeconds(&transport, tracks),
            }, prog);
            if (render_dlg.changed) {
                render_dlg.changed = false;
                dirty = true;
            }
            if (render_dlg.presets_changed) {
                render_dlg.presets_changed = false;
                export_presets.save(alloc) catch |err| status.set("Presets not saved: {s}", .{@errorName(err)});
            }
            if (render_dlg.want_folder) {
                render_dlg.want_folder = false;
                var fb: [storage.MAX_PATH]u8 = undefined;
                const start = export_settings.resolveFolder(&fb, export_cfg.folder.get(), .{ .project = projectStem(project_path) });
                if (native_dialog.chooseFolder(alloc, start) catch null) |dir| {
                    defer alloc.free(dir);
                    export_cfg.folder.set(homeShort(&fb, dir));
                    dirty = true;
                }
            }
        }
        var bounce_action: bounce_dialog.Result = .none;
        if (bounce_dlg.active) {
            const prog: ?export_dialog.Progress = if (bounce_job.active) bounceProgress(&bounce_job) else null;
            bounce_action = bounce_dialog.draw(ui, uiRect(pane.rect(0, 0, sw, sh)), &bounce_dlg, bounceInfo(&transport, tracks, bounce_job.replace != 0), prog);
        }
        var delete_answer: ?bool = null;
        var delete_set_answer: ?bool = null;
        if (pending_delete_set != null) {
            delete_set_answer = dialog.confirm(ui, uiRect(pane.rect(0, 0, sw, sh)), "delete-tracks", "DELETE TRACKS", delete_msg.lines(), "DELETE");
        }
        if (pending_delete) |ti| {
            if (ti >= tracks.len) pending_delete = null else {
                const bus = tracks[ti].isBus();
                delete_answer = dialog.confirm(ui, uiRect(pane.rect(0, 0, sw, sh)), "delete-track", if (bus) "DELETE BUS" else "DELETE TRACK", delete_msg.lines(), "DELETE");
            }
        }

        if (uni_panel.active) {
            const u = if (uni_panel.track < tracks.len) tracks[uni_panel.track].machine.unison else null;
            if (u) |uu| {
                if (unison_panel.draw(ui, uiRect(pane.rect(0, 0, sw, sh)), &uni_panel, uu)) dirty = true;
            } else uni_panel.active = false;
        }

        if (color_pick.active) {
            if (color_pick.track < tracks.len) {
                const t = &tracks[color_pick.track];
                if (color_picker.draw(ui, uiRect(pane.rect(0, 0, sw, sh)), &color_pick, arrangement.trackColor(t.color))) |col| {
                    if (document_mod.serialize(alloc, tracks, &transport)) |before| {
                        history.pushUndo(alloc, before) catch alloc.free(before);
                    } else |_| {}
                    // On a selected track: the whole selection.
                    const set = actionSet(tracks, selected_track, color_pick.track, true);
                    for (tracks, set[0..tracks.len]) |*u, on| if (on) {
                        u.color = .{ .r = col.r, .g = col.g, .b = col.b, .a = 255 };
                    };
                    dirty = true;
                }
            } else color_pick.active = false;
        }

        if (about.draw(ui, uiRect(pane.rect(0, 0, sw, sh)), &about_card) == .licenses) native_app.showLicenses();

        if (browser.dragging(&br)) browser.drawGhost(ui, &br, lib.items.items, drop_ok);
        splash.overlay(ui, screenRect());
        menu.draw(ui);
        ui.render();

        pane.applyCursor(ui);
        ui.endFrame();

        quiet_frames = if (ui.wants_frame or transport.isPlaying() or modal) 0 else quiet_frames +| 1;
        const want_idle = quiet_frames > IDLE_AFTER_FRAMES;
        if (want_idle != fps_idle) {
            fps_idle = want_idle;
            c.rl.SetTargetFPS(if (fps_idle) IDLE_FPS else 120);
        }

        for (tracks) |*t| t.publishSnapshot(&audio_pool);
        // Bounces go stale as their sources change (docs/27 §Provenance).
        if (c.rl.GetTime() >= next_recipe_check and !bounce_job.active) {
            next_recipe_check = c.rl.GetTime() + 0.5;
            recipe_mod.checkAll(alloc, tracks, &transport);
        }
        engine.publishRouting();

        // Screenshots and scripted drags assume the default window.
        if (shot_frame < 2 and std.c.getenv("SLAB_SHOT") != null) c.rl.SetWindowSize(1400, 860);
        if (shot_frame == 0 and std.c.getenv("SLAB_SHOT_PLAY") != null) transport.play();
        if (shot_frame == 0 and std.c.getenv("SLAB_SHOT_EXPR") != null) clip_editor.toggleExpressionMode();
        if (shot_frame == 0 and std.c.getenv("SLAB_SHOT_MIXER") != null) layout.mixer_visible = true;
        if (shot_frame == 0 and std.c.getenv("SLAB_SHOT_ABOUT") != null) about_card.active = true;
        if (shot_frame == 200 and std.c.getenv("SLAB_SHOT_UNISON") != null) if (machine_bay.unison_chip_at) |at| uni_panel.open(selected_track orelse 0, at);
        if (shot_frame == 0) if (std.c.getenv("SLAB_SHOT_SELECT")) |sel| {
            // "track:clip" — open that clip in the editor (screenshots).
            var it = std.mem.splitScalar(u8, std.mem.span(sel), ':');
            const ti = std.fmt.parseInt(u32, it.next() orelse "", 10) catch 0;
            const ci = std.fmt.parseInt(u32, it.next() orelse "", 10) catch 0;
            if (ti < tracks.len and ci < tracks[ti].clips.items.len) {
                selected_track = ti;
                selected_clip = .{ .track = ti, .clip = ci };
            }
        };
        // "track:clip:notes" also selects the clip's notes, once the editor
        // has opened it (opening a clip clears its selection).
        if (shot_frame == 5) if (std.c.getenv("SLAB_SHOT_SELECT")) |sel| {
            if (std.mem.endsWith(u8, std.mem.span(sel), ":notes")) if (selected_clip) |ref| {
                for (tracks[ref.track].clips.items[ref.clip].notes.items) |*n| n.selected = true;
            };
        };
        devScreenshot(&shot_frame);
        c.rl.EndDrawing();

        if (delete_set_answer) |yes| {
            const set = pending_delete_set.?;
            pending_delete_set = null;
            if (yes) if (document_mod.serialize(alloc, tracks_buf[0..track_count], &transport)) |before| {
                var n: usize = 0;
                var k = track_count;
                while (k > 0) {
                    k -= 1;
                    if (!set[k]) continue;
                    deleteTrack(alloc, &history, &status, &audio, &engine, &tracks_buf, &track_count, &transport, k, &selected_track, &selected_clip, &prev_selected_clip, &rename, false) catch break;
                    n += 1;
                }
                history.pushUndo(alloc, before) catch alloc.free(before);
                status.set("Deleted {d} tracks", .{n});
                dirty = true;
            } else |err| status.set("Delete failed: {s}", .{@errorName(err)});
        }
        if (delete_answer) |yes| {
            const ti = pending_delete.?;
            pending_delete = null;
            if (yes) {
                deleteTrack(alloc, &history, &status, &audio, &engine, &tracks_buf, &track_count, &transport, ti, &selected_track, &selected_clip, &prev_selected_clip, &rename, true) catch |err| status.set("Delete failed: {s}", .{@errorName(err)});
                dirty = true;
            }
        }

        switch (render_action) {
            .none => {},
            .cancel => {
                if (render_job.active) {
                    render_job.cancel.store(true, .monotonic); // worker stops; finalize below
                } else {
                    render_dlg.active = false;
                }
            },
            .reveal => if (render_dlg.last().len > 0) native_dialog.reveal(render_dlg.last()),
            .render => {
                if (!render_job.active) {
                    startRender(alloc, &engine, &audio, &transport, tracks, &export_cfg, project_path, &render_job, &status) catch |err| {
                        std.log.err("render start failed: {s}", .{@errorName(err)});
                        status.set("Render failed", .{});
                        render_dlg.active = false;
                    };
                }
            },
        }

        switch (bounce_action) {
            .none => {},
            .cancel => {
                if (bounce_job.active) {
                    bounce_job.cancel.store(true, .monotonic);
                } else bounce_dlg.active = false;
            },
            .bounce => if (!bounce_job.active) {
                startBounce(alloc, &engine, &audio, &audio_pool, &transport, tracks, bounce_dlg, &bounce_job, &status, 0) catch |err| {
                    std.log.err("bounce start failed: {s}", .{@errorName(err)});
                    status.set("Bounce failed", .{});
                };
                if (!bounce_job.active) bounce_dlg.active = false;
            },
        }
        if (bounce_job.active and bounce_job.done.load(.acquire)) {
            finishBouncePass(alloc, &history, &status, &audio, &engine, &audio_pool, &tracks_buf, &track_count, &transport, &bounce_job, &selected_track, &selected_clip, &prev_selected_clip, &dirty);
            tracks = tracks_buf[0..track_count];
            if (!bounce_job.active) bounce_dlg.active = false;
        }

        // Finalize a worker render once it signals done (or after a cancel).
        if (render_job.active and render_job.done.load(.acquire)) {
            finishRender(alloc, &audio, &render_job, &status, &render_dlg);
            render_dlg.active = render_dlg.showing_card;
        }

        // Finalize a recording once the writer thread has flushed and closed
        // the take file: turn it into a pooled source + clip on the armed track.
        if (rec_finishing and recorder.isFinished()) {
            const res = recorder.finish();
            placeRecordedClip(alloc, &audio_pool, &history, &status, tracks, &transport, &recorder, &audio, engine.master_latency.load(.monotonic), res, rec_track, &selected_track, &selected_clip, &dirty) catch |err| {
                std.log.err("record finalize failed: {s}", .{@errorName(err)});
                status.set("Recording finalize failed", .{});
            };
            rec_finishing = false;
            rec_track = null;
        }
        if (tres.save_project or tres.save_project_as or tres.new_project or tres.open_project or tres.clean_up_project) lib_stale = true;
        if (tres.save_project) {
            try saveProject(
                alloc,
                tracks,
                &transport,
                &project_path,
                &project_path_chosen,
                &dirty,
                &status,
                false,
            );
        }
        if (tres.save_project_as) {
            try saveProject(
                alloc,
                tracks,
                &transport,
                &project_path,
                &project_path_chosen,
                &dirty,
                &status,
                true,
            );
        }
        if (tres.clean_up_project) {
            // Clean Up goes by the saved asset table, so it saves first:
            // a take recorded since the last save is the project's too.
            try saveProject(alloc, tracks, &transport, &project_path, &project_path_chosen, &dirty, &status, false);
            if (project_path_chosen and !dirty) cleanUpProject(alloc, project_path, &status);
        }
        if (tres.new_project) {
            try newProject(alloc, &history, &tracks_buf, &track_count, &tracks, &transport, &engine, &audio, &reg, &selected_track, &selected_clip, &prev_selected_clip, &project_path, &project_path_chosen, &dirty, &status);
        }
        if (try native_app.takeOpenedPath(alloc)) |path| {
            defer alloc.free(path);
            lib_stale = true;
            queueOpen(alloc, path);
        }
        if (tres.open_project) openProject(alloc);
        prev_selected_clip = selected_clip;
        title_bar.update(c.rl.GetWindowHandle(), project_path, project_path_chosen, dirty);
        native_app.setBrowserChecked(layout.browser_visible);
    }

    // Window closing mid-render: stop the worker and free its buffers before
    // the engine/allocator tear down (the worker holds pointers into both).
    if (render_job.active) {
        render_job.cancel.store(true, .monotonic);
        if (render_job.thread) |t| t.join();
        render_job = .{};
    }
    if (bounce_job.active) {
        bounce_job.cancel.store(true, .monotonic);
        if (bounce_job.thread) |t| t.join();
        engine.capture = null;
        freeBounceBuffers(alloc, &bounce_job.cap);
        bounce_job = .{};
    }
}

/// Import an audio file into the pool and drop it as an audio clip on the
/// target track at `target_beat`. Length is the source duration at the
/// current tempo. Pushes an undo snapshot and selects the new clip.
fn importAudioClip(
    alloc: std.mem.Allocator,
    pool: *audio_pool_mod.AudioPool,
    history: *history_mod.History,
    status: *StatusMessage,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    edit_snap: snap_mod.Setting,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    dirty: *bool,
    target_beat: ?f64,
    target_track: ?usize,
) !void {
    if (tracks.len == 0) return;
    const ti = @min(target_track orelse selected_track.* orelse 0, tracks.len - 1);
    if (tracks[ti].isBus()) {
        status.set("A bus takes no clips: import onto a track", .{});
        return;
    }

    const path = (try native_dialog.openAudioFile(alloc)) orelse return; // cancelled
    defer alloc.free(path);

    const source = try pool.loadFile(path);
    const src = pool.get(source) orelse return;

    const dur_sec = src.seconds();
    const raw_start = target_beat orelse transport.beats();
    const start = snap_mod.snapDownPositive(edit_snap, @max(0.0, raw_start), false);
    const len_beats = @max(0.25, transport.secondsToBeats(start, dur_sec));

    const before = try document_mod.serialize(alloc, tracks, transport);
    errdefer alloc.free(before);

    _ = arrangement.clearSelection(tracks, selected_clip);
    var clip = clip_mod.Clip.initAudio(src.name(), start, len_beats, source);
    clip.audio.start_sec = 0;
    clip.audio.dur_sec = dur_sec;
    clip.selected = true;
    tracks[ti].addClip(alloc, clip) catch |err| {
        clip.deinit(alloc);
        return err;
    };
    try history.pushUndo(alloc, before);

    selected_track.* = ti;
    selected_clip.* = .{ .track = @intCast(ti), .clip = @intCast(tracks[ti].clips.items.len - 1) };
    dirty.* = true;
    status.set("Imported {s}", .{src.name()});
}

/// First record-armed audio track, or null. Buses can't be armed.
fn firstArmedAudioTrack(tracks: []track_mod.Track) ?usize {
    for (tracks, 0..) |*t, i| {
        if (t.kind == .audio and t.isArmed()) return i;
    }
    return null;
}

/// Turn a finished take into a pooled source + audio clip on the armed track.
/// Runs on the UI thread after the writer thread closed the WAV.
fn placeRecordedClip(
    alloc: std.mem.Allocator,
    pool: *audio_pool_mod.AudioPool,
    history: *history_mod.History,
    status: *StatusMessage,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    recorder: *recorder_mod.Recorder,
    audio: *audio_mod.Audio,
    pdc_latency: u32,
    res: recorder_mod.Result,
    rec_track: ?usize,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    dirty: *bool,
) !void {
    if (res.frames == 0) {
        status.set("Recording was empty", .{});
        return;
    }
    const ti = (rec_track orelse firstArmedAudioTrack(tracks)) orelse return;
    if (ti >= tracks.len) return;

    const source = try pool.loadFile(res.path);
    const src = pool.get(source) orelse return;

    const dur_sec = src.seconds();

    // Latency-compensate: captured audio arrives a round-trip late, and the
    // playback it was played against was late by the project's own latency
    // (PDC), so place the clip earlier by both.
    const latency: u64 = @as(u64, audio.roundTripLatencyFrames()) + pdc_latency;
    const adj_sample = if (res.start_sample > latency) res.start_sample - latency else 0;
    const start = transport.samplesToBeats(adj_sample);
    const len_beats = @max(0.25, transport.secondsToBeats(start, dur_sec));

    const before = try document_mod.serialize(alloc, tracks, transport);
    errdefer alloc.free(before);

    _ = arrangement.clearSelection(tracks, selected_clip);
    var clip = clip_mod.Clip.initAudio(src.name(), start, len_beats, source);
    clip.audio.start_sec = 0;
    clip.audio.dur_sec = dur_sec;
    clip.selected = true;
    tracks[ti].addClip(alloc, clip) catch |err| {
        clip.deinit(alloc);
        return err;
    };
    try history.pushUndo(alloc, before);

    selected_track.* = ti;
    selected_clip.* = .{ .track = @intCast(ti), .clip = @intCast(tracks[ti].clips.items.len - 1) };
    dirty.* = true;

    const secs = @as(f64, @floatFromInt(res.frames)) / @as(f64, @floatFromInt(recorder_mod.SAMPLE_RATE));
    const dropped = recorder.overruns.load(.monotonic);
    if (dropped > 0) {
        status.set("Recorded {d:.1}s ({d} frames dropped)", .{ secs, dropped });
    } else {
        status.set("Recorded {d:.1}s", .{secs});
    }
}

fn handleProjectShortcuts(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    tracks: *[]track_mod.Track,
    transport: *transport_mod.Transport,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    project_path: *[]u8,
    project_path_chosen: *bool,
    dirty: *bool,
    status: *StatusMessage,
) !bool {
    const mod = commandModifierDown();
    if (!mod) return false;

    if (c.rl.IsKeyPressed(c.rl.KEY_S)) {
        const shifted = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        try saveProject(alloc, tracks.*, transport, project_path, project_path_chosen, dirty, status, shifted);
        return true;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_O)) {
        openProject(alloc);
        return true;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_N)) {
        try newProject(alloc, history, tracks_buf, track_count, tracks, transport, engine, audio, reg, selected_track, selected_clip, prev_selected_clip, project_path, project_path_chosen, dirty, status);
        return true;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_Z)) {
        const shifted = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        try undoRedo(alloc, history, tracks_buf, track_count, tracks, transport, engine, audio, reg, selected_track, selected_clip, prev_selected_clip, project_path, project_path_chosen, dirty, status, shifted);
        return true;
    }

    return false;
}

fn undoRedo(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    tracks: *[]track_mod.Track,
    transport: *transport_mod.Transport,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    project_path: *[]u8,
    project_path_chosen: *bool,
    dirty: *bool,
    status: *StatusMessage,
    redo: bool,
) !void {
    const current = try document_mod.serialize(alloc, tracks.*, transport);
    if (try stepHistory(alloc, history, current, project_path, project_path_chosen, redo)) |entry| {
        defer entry.deinit(alloc);
        applyProjectBytes(alloc, entry.doc, reg, tracks_buf, track_count, tracks, transport, engine, audio, selected_track, selected_clip, prev_selected_clip) catch |err| {
            std.log.err("history apply failed: {s}", .{@errorName(err)});
        };
        dirty.* = true;
        if (redo) {
            status.set("Redone", .{});
        } else {
            status.set("Undone", .{});
        }
    }
}

/// Undo (or redo) from `current` (owned), returning the document to
/// apply. A step over Open or New Project goes back to that project
/// first: its path and chosen flag, so the title and ⌘S follow, and the
/// storage root, so its references resolve against its folder as the
/// document is applied.
fn stepHistory(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    current: []u8,
    project_path: *[]u8,
    project_path_chosen: *bool,
    redo: bool,
) !?history_mod.Entry {
    const here: history_mod.Project = .{ .path = project_path.*, .chosen = project_path_chosen.* };
    const entry = (if (redo) try history.redo(alloc, current, here) else try history.undo(alloc, current, here)) orelse return null;
    if (entry.project) |p| {
        const path = alloc.dupe(u8, p.path) catch |err| {
            entry.deinit(alloc);
            return err;
        };
        replaceProjectPath(alloc, project_path, path);
        project_path_chosen.* = p.chosen;
        useProjectOf(p);
    }
    return entry;
}

fn saveProject(
    alloc: std.mem.Allocator,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    project_path: *[]u8,
    project_path_chosen: *bool,
    dirty: *bool,
    status: *StatusMessage,
    force_dialog: bool,
) !void {
    if (force_dialog or !project_path_chosen.*) {
        const chosen = native_dialog.saveProject(alloc, basename(project_path.*)) catch |err| {
            std.log.err("save dialog failed: {s}", .{@errorName(err)});
            return;
        };
        if (chosen) |path| {
            replaceProjectPath(alloc, project_path, path);
            project_path_chosen.* = true;
        } else {
            return;
        }
    }

    // A project is a package (docs/25 §The project package); a bare
    // .slab file there moves inside first.
    var ab: [storage.MAX_PATH]u8 = undefined;
    const pkg = storage.absolute(&ab, project_path.*);
    package.prepare(pkg) catch |err| {
        std.log.err("save failed: {s}: {s}", .{ pkg, @errorName(err) });
        status.set("Save failed", .{});
        return;
    };
    // Save As to another package takes the project's presets along; its
    // files come by collecting.
    var old_buf: [storage.MAX_PATH]u8 = undefined;
    const old_dir = old_buf[0..storage.projectDir().len];
    @memcpy(old_dir, storage.projectDir());
    if (std.mem.endsWith(u8, old_dir, ".slab") and !std.mem.eql(u8, old_dir, pkg)) {
        var sb: [storage.MAX_PATH]u8 = undefined;
        var tb: [storage.MAX_PATH]u8 = undefined;
        const from = std.fmt.bufPrint(&sb, "{s}/presets", .{old_dir}) catch "";
        const to = std.fmt.bufPrint(&tb, "{s}/presets", .{pkg}) catch "";
        if (from.len > 0 and to.len > 0) _ = package.copyTree(from, to);
    }
    var db: [storage.MAX_PATH]u8 = undefined;
    storage.setProject(package.docPath(&db, pkg));
    // Edited wavetables are written into the package first, so the
    // project names their files.
    for (tracks) |*t| if (t.machine.save_files) |f| f(t.machine.state, pkg, t.name());
    // Files in the package are written relative to it.
    storage.beginProjectSave();
    const snapshot = document_mod.serialize(alloc, tracks, transport) catch |err| {
        storage.endProjectSave();
        return err;
    };
    storage.endProjectSave();
    defer alloc.free(snapshot);
    // Everything else it uses that slab doesn't ship is copied in.
    var report: package.Report = .{};
    const doc = package.collect(alloc, pkg, snapshot, .{ .collect_lib = storage.collect_lib }, &report) catch |err| {
        std.log.err("save failed: collecting files: {s}", .{@errorName(err)});
        status.set("Save failed (collecting files)", .{});
        return;
    };
    defer alloc.free(doc);
    package.writeDoc(pkg, doc) catch |err| {
        std.log.err("save failed: {s}", .{@errorName(err)});
        status.set("Save failed", .{});
        return;
    };
    project_path_chosen.* = true;
    dirty.* = false;
    if (report.missing > 0)
        status.set("Saved {s}; {d} files missing", .{ basename(pkg), report.missing })
    else if (report.copied > 0)
        status.set("Saved {s}; copied {d} files in ({d} MB)", .{ basename(pkg), report.copied, report.bytes / (1024 * 1024) })
    else
        status.set("Saved {s}", .{basename(pkg)});
    std.log.info("saved {s} (copied {d} files, {d} bytes; {d} missing)", .{ pkg, report.copied, report.bytes, report.missing });
}

/// Begin an export from the project's export settings: resolve the
/// range, the folder and the stems, stop the device and start the worker.
/// finishRender reports once it's done. The device stays stopped
/// meanwhile because the offline render shares the engine's scratch and
/// machine state with the live callback.
fn startRender(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    transport: *transport_mod.Transport,
    tracks: []track_mod.Track,
    settings: *const export_settings.Settings,
    project_path: []const u8,
    job: *RenderJob,
    status: *StatusMessage,
) !void {
    const sr = transport.sample_rate;
    const rec = &settings.recipe;
    const range = exportRange(transport, tracks, rec.range) orelse {
        status.set("Nothing to export", .{});
        return;
    };
    job.* = .{
        .active = true,
        .tracks = tracks,
        .sample_rate = sr,
        .start_ns = nowNs(),
        .settings = settings.*,
    };
    const s = &job.settings;
    const stem_name = projectStem(project_path);
    const project = std.fmt.bufPrint(&job.project_buf, "{s}", .{if (stem_name.len > 0) stem_name else "untitled"}) catch "untitled";
    const date = export_mod.today(&job.date_buf);
    const folder = export_settings.resolveFolder(&job.folder_buf, s.folder.get(), .{ .project = project, .date = date, .bpm = transport.baseBpm() });
    if (folder.len == 0) return error.NoFolder;

    // Tags: the name, the tempo, and what made it (docs/27 §Names and metadata).
    var fmt = s.recipe.format();
    fmt.bpm = transport.baseBpm();
    fmt.comment = blk: {
        const doc = document_mod.serialize(alloc, tracks, transport) catch break :blk "";
        defer alloc.free(doc);
        break :blk exportComment(&job.comment_buf, doc);
    };
    fmt.title = if (s.title.len > 0) s.title.get() else project;
    fmt.artist = s.artist.get();
    fmt.album = s.album.get();
    fmt.year = s.year.get();

    const tail_s: f32 = if (s.recipe.tail_auto) export_settings.TAIL_MAX else @max(0, s.recipe.tail_sec);
    job.opts = .{
        .folder = folder,
        .mix_name = if (s.recipe.mix) s.recipe.mix_name.get() else null,
        .mix_channels = s.recipe.mix_channels,
        .stems = export_settings.stems(&s.recipe, tracks),
        .stem_name = s.recipe.stem_name.get(),
        .stem_gain = s.recipe.stem_gain,
        .replace = s.recipe.exists == .replace,
        .project = project,
        .date = date,
        .start = range.start,
        .end = range.end,
        .tail_auto = s.recipe.tail_auto,
        .tail_frames = @intFromFloat(tail_s * @as(f32, @floatFromInt(sr))),
        .format = fmt,
        .normalize = if (s.recipe.mix) s.recipe.normalize else .off,
        .target = s.recipe.target(),
        .ceiling = s.recipe.ceilingDb(),
        .loop_wrap = s.recipe.wrap,
    };
    job.total_frames = @intCast(range.end - range.start + job.opts.tail_frames);

    audio.stop();
    job.thread = std.Thread.spawn(.{}, renderWorker, .{ alloc, engine, job }) catch |err| blk: {
        std.log.warn("export thread spawn failed ({s}); ran synchronously", .{@errorName(err)});
        renderWorker(alloc, engine, job);
        break :blk null;
    };
}

/// Each range's length in seconds, for the Export sheet; null where it's
/// empty.
fn rangeSeconds(transport: *const transport_mod.Transport, tracks: []const track_mod.Track) [3]?f64 {
    var out: [3]?f64 = undefined;
    for (0..3) |i| out[i] = if (exportRange(transport, tracks, @enumFromInt(i))) |r|
        @as(f64, @floatFromInt(r.end - r.start)) / @as(f64, @floatFromInt(transport.sample_rate))
    else
        null;
    return out;
}

const SampleRange = struct { start: u64, end: u64 };

/// An export's range in samples: the project (beat 0 to the last clip
/// that plays), the loop, or the selected clips.
fn exportRange(transport: *const transport_mod.Transport, tracks: []const track_mod.Track, mode: export_settings.Range) ?SampleRange {
    var lo: f64 = 0;
    var hi: f64 = 0;
    switch (mode) {
        .project => for (tracks) |*t| for (t.clips.items) |*cl| if (!cl.muted) {
            hi = @max(hi, cl.endBeat());
        },
        .loop => {
            if (!transport.loopEnabled()) return null;
            lo = transport.loopStartBeats();
            hi = transport.loopEndBeats();
        },
        .selection => {
            lo = std.math.inf(f64);
            for (tracks) |*t| for (t.clips.items) |*cl| if (cl.selected) {
                lo = @min(lo, cl.start_beat);
                hi = @max(hi, cl.endBeat());
            };
        },
    }
    if (!(hi > lo)) return null;
    return .{ .start = transport.beatsToSamples(lo), .end = transport.beatsToSamples(hi) };
}

/// The comment an export carries: the Slab version and a hash of the
/// project as it was rendered, so a file traces back to its render.
fn exportComment(buf: []u8, doc: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Slab {s}, project {x:0>16}", .{ build_options.version, std.hash.Wyhash.hash(0, doc) }) catch "";
}

/// `path` with the home folder as `~`, as the Export sheet shows it.
fn homeShort(buf: []u8, path: []const u8) []const u8 {
    const home = std.mem.sliceTo(std.c.getenv("HOME") orelse "", 0);
    if (home.len > 0 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/'))
        return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
    return path;
}

/// A path's file name without its extension.
fn projectStem(path: []const u8) []const u8 {
    const base = basename(path);
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
}

/// Live Progress telemetry from a running export.
fn renderProgress(job: *RenderJob) export_dialog.Progress {
    const sr_f: f64 = @floatFromInt(job.sample_rate);
    const done_f: f64 = @floatFromInt(job.progress.load(.monotonic));
    const total_f: f64 = @floatFromInt(job.total_frames);
    const elapsed: f64 = @as(f64, @floatFromInt(nowNs() - job.start_ns)) / 1_000_000_000.0;
    const rendered_s = done_f / sr_f;
    return .{
        .fraction = if (total_f > 0) @floatCast(done_f / total_f) else 0,
        .elapsed_s = elapsed,
        .speed_x = if (elapsed > 0.001) rendered_s / elapsed else 0,
        .rendered_s = rendered_s,
        .total_s = total_f / sr_f,
    };
}

/// Join the worker, restart the device and report: the status line, and
/// the sheet's report; Finder shows the files when the settings ask.
fn finishRender(alloc: std.mem.Allocator, audio: *audio_mod.Audio, job: *RenderJob, status: *StatusMessage, dlg: *export_dialog.State) void {
    _ = alloc;
    if (job.thread) |t| t.join();
    job.thread = null;
    audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
    if (job.result) |*r| {
        var card = export_dialog.Card{
            .has_mix = job.opts.mix_name != null,
            .lufs = r.loudness.integrated,
            .lra = r.loudness.lra,
            .true_peak = r.loudness.true_peak,
            .gain_db = r.gain_db,
            .files = r.files,
            .secs = @as(f64, @floatFromInt(r.frames)) / @as(f64, @floatFromInt(r.sample_rate)),
        };
        for (r.stems[0..r.stem_count]) |*st| card.addStem(st.name(), st.lufs);
        dlg.card = card;
        dlg.showing_card = true;
        dlg.setLast(r.first());
        if (job.settings.reveal) native_dialog.reveal(r.first());
        if (r.files == 1) status.set("Exported {s} ({d:.1}s)", .{ basename(r.first()), card.secs }) else status.set("Exported {d} files ({d:.1}s)", .{ r.files, card.secs });
    } else if (job.err) |err| {
        if (err == error.Cancelled) status.set("Export cancelled", .{}) else status.set("Export failed: {s}", .{@errorName(err)});
        std.log.err("export failed: {s}", .{@errorName(err)});
    }
    job.* = .{};
}

// ── Bounce selection (docs/27 §Bounce selection) ──────────────────────

/// One bounced clip written to disk, waiting to be placed: the source
/// tracks it holds and its file.
const BounceOut = struct {
    sources: u32 = 0,
    path_buf: [storage.MAX_PATH]u8 = undefined,
    path_len: usize = 0,

    fn path(self: *const BounceOut) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// A bounce in flight: one capture render per pass on a worker thread
/// (one pass, or one per source track for EACH with +SENDS, whose buses
/// must hear one source at a time). Each pass's clips are written as it
/// ends; the last places them in the project as one undo step.
const BounceJob = struct {
    active: bool = false,
    thread: ?std.Thread = null,
    opts: bounce_dialog.State = .{},
    /// Tracks with selected clips.
    sources: u32 = 0,
    /// A re-bounce (docs/27 §Provenance): the bounced clip it renders
    /// into again, by id; its muted originals play. 0 for a bounce.
    replace: u32 = 0,
    passes: [MAX_TRACKS]u32 = undefined,
    pass_count: usize = 0,
    pass: usize = 0,
    start_sample: u64 = 0,
    start_beat: f64 = 0,
    range_frames: usize = 0,
    total_frames: usize = 0,
    sample_rate: u32 = 48_000,
    cap: engine_mod.Capture = .{},
    outs: [MAX_TRACKS]BounceOut = undefined,
    out_count: usize = 0,
    start_ns: i128 = 0,
    progress: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn bounceWorker(engine: *engine_mod.Engine, job: *BounceJob) void {
    engine.renderOffline(&.{}, job.total_frames, job.start_sample, &job.progress, &job.cancel);
    job.done.store(true, .release);
}

fn bit(i: usize) u32 {
    return @as(u32, 1) << @intCast(i);
}

/// The tracks a bounce takes: those with selected clips, unmuted unless
/// `muted` (a re-bounce).
fn bounceSources(tracks: []const track_mod.Track, muted: bool) u32 {
    var set: u32 = 0;
    for (tracks, 0..) |*t, ti| {
        if (t.isBus()) continue;
        for (t.clips.items) |*cl| if (cl.selected and (muted or !cl.muted)) {
            set |= bit(ti);
        };
    }
    return set;
}

/// The buses the sends of the tracks in `set` reach.
fn sendBuses(tracks: []const track_mod.Track, set: u32) u32 {
    var buses: u32 = 0;
    for (tracks, 0..) |*t, ti| if (set & bit(ti) != 0) {
        for (t.sends[0..t.send_count]) |s| buses |= bit(s.bus);
    };
    return buses;
}

/// Resolve the selection and start the first pass. The device stays
/// stopped until the last pass is placed (or the bounce is cancelled).
fn startBounce(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    audio: ?*audio_mod.Audio,
    pool: *audio_pool_mod.AudioPool,
    transport: *transport_mod.Transport,
    tracks: []track_mod.Track,
    opts: bounce_dialog.State,
    job: *BounceJob,
    status: *StatusMessage,
    replace: u32,
) !void {
    const muted = replace != 0;
    const sources = bounceSources(tracks, muted);
    if (sources == 0) {
        status.set("Select clips to bounce", .{});
        return;
    }
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = 0;
    for (tracks, 0..) |*t, ti| if (sources & bit(ti) != 0) {
        for (t.clips.items) |*cl| if (cl.selected and (muted or !cl.muted)) {
            lo = @min(lo, cl.start_beat);
            hi = @max(hi, cl.endBeat());
        };
    };
    const sr = transport.sample_rate;
    const start = transport.beatsToSamples(lo);
    const end = transport.beatsToSamples(hi);
    if (end <= start) {
        status.set("Nothing to bounce", .{});
        return;
    }

    job.* = .{
        .active = true,
        .opts = opts,
        .sources = sources,
        .replace = replace,
        .start_sample = start,
        .start_beat = lo,
        .range_frames = @intCast(end - start),
        .sample_rate = sr,
        .start_ns = nowNs(),
    };
    const tail_s: f32 = if (opts.tail_auto) bounce_dialog.TAIL_MAX else @max(0, opts.tail_sec);
    job.total_frames = job.range_frames + @as(usize, @intFromFloat(tail_s * @as(f32, @floatFromInt(sr))));
    if (opts.mixMode() == .each and opts.tapMode() == .sends) {
        for (0..tracks.len) |ti| if (sources & bit(ti) != 0) {
            job.passes[job.pass_count] = bit(ti);
            job.pass_count += 1;
        };
    } else {
        job.passes[0] = sources;
        job.pass_count = 1;
    }

    // Only the selected clips play on the source tracks.
    for (tracks, 0..) |*t, ti| {
        t.play_selected = sources & bit(ti) != 0;
        t.play_muted = muted;
        t.publishSnapshot(pool);
    }
    if (audio) |a| a.stop();
    beginBouncePass(alloc, engine, tracks, job) catch |err| {
        endBounce(audio, engine, pool, tracks, job, alloc);
        return err;
    };
}

/// Set up the capture for the job's current pass and start its worker.
fn beginBouncePass(alloc: std.mem.Allocator, engine: *engine_mod.Engine, tracks: []track_mod.Track, job: *BounceJob) !void {
    const heard = job.passes[job.pass];
    const opts = job.opts;
    job.cap = .{ .sources = heard, .min_frames = job.range_frames };
    if (opts.tail_auto) job.cap.hold = job.sample_rate / 2;
    const tap: engine_mod.CaptureTap = switch (opts.tapMode()) {
        .instr => .input,
        .fx => .pre,
        .fader, .sends => .post,
    };
    const buses = if (opts.tapMode() == .sends) sendBuses(tracks, heard) else 0;
    const len = job.total_frames + engine_mod.PDC_MAX;
    for (0..tracks.len) |ti| {
        const t: engine_mod.CaptureTap = if (heard & bit(ti) != 0) tap else if (buses & bit(ti) != 0) .post else .none;
        if (t == .none) continue;
        job.cap.tap[ti] = t;
        job.cap.l[ti] = try alloc.alloc(f32, len);
        job.cap.r[ti] = try alloc.alloc(f32, len);
        @memset(job.cap.l[ti], 0);
        @memset(job.cap.r[ti], 0);
    }
    job.progress.store(0, .monotonic);
    job.done.store(false, .monotonic);
    engine.capture = &job.cap;
    job.thread = std.Thread.spawn(.{}, bounceWorker, .{ engine, job }) catch |err| blk: {
        std.log.warn("bounce thread spawn failed ({s}); ran synchronously", .{@errorName(err)});
        bounceWorker(engine, job);
        break :blk null;
    };
}

fn freeBounceBuffers(alloc: std.mem.Allocator, cap: *engine_mod.Capture) void {
    for (&cap.l, &cap.r) |*l, *r| {
        if (l.len > 0) alloc.free(l.*);
        if (r.len > 0) alloc.free(r.*);
        l.* = &.{};
        r.* = &.{};
    }
}

/// Back to playing: masks off, buffers freed, the device restarted.
fn endBounce(audio: ?*audio_mod.Audio, engine: *engine_mod.Engine, pool: *audio_pool_mod.AudioPool, tracks: []track_mod.Track, job: *BounceJob, alloc: std.mem.Allocator) void {
    engine.capture = null;
    freeBounceBuffers(alloc, &job.cap);
    for (tracks) |*t| {
        t.play_selected = false;
        t.play_muted = false;
        t.publishSnapshot(pool);
    }
    if (audio) |a| a.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
    job.* = .{};
}

/// The groups of tapped tracks that each become one clip this pass.
fn bounceGroups(job: *const BounceJob, tracks: []const track_mod.Track, out: *[MAX_TRACKS]u32) usize {
    var tapped: u32 = 0;
    for (job.cap.tap[0..tracks.len], 0..) |tp, ti| {
        if (tp != .none) tapped |= bit(ti);
    }
    // TOGETHER, or EACH with +SENDS (a pass is one source and its buses).
    if (job.opts.mixMode() == .together or job.opts.tapMode() == .sends) {
        out[0] = tapped;
        return 1;
    }
    var n: usize = 0;
    for (0..tracks.len) |ti| if (tapped & bit(ti) != 0) {
        out[n] = bit(ti);
        n += 1;
    };
    return n;
}

/// The worker is done: write this pass's clips, then start the next pass
/// or place them all. Returns true once the bounce is over.
fn finishBouncePass(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: *StatusMessage,
    audio: ?*audio_mod.Audio,
    engine: *engine_mod.Engine,
    pool: *audio_pool_mod.AudioPool,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    transport: *transport_mod.Transport,
    job: *BounceJob,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    dirty: *bool,
) void {
    if (job.thread) |t| t.join();
    job.thread = null;
    engine.capture = null;
    const tracks = tracks_buf[0..track_count.*];
    if (job.cancel.load(.monotonic)) {
        endBounce(audio, engine, pool, tracks, job, alloc);
        status.set("Bounce cancelled", .{});
        return;
    }
    writeBounceClips(alloc, tracks, job) catch |err| {
        std.log.err("bounce write failed: {s}", .{@errorName(err)});
        endBounce(audio, engine, pool, tracks, job, alloc);
        status.set("Bounce failed (write)", .{});
        return;
    };
    freeBounceBuffers(alloc, &job.cap);
    job.pass += 1;
    if (job.pass < job.pass_count) {
        beginBouncePass(alloc, engine, tracks, job) catch |err| {
            std.log.err("bounce pass failed: {s}", .{@errorName(err)});
            endBounce(audio, engine, pool, tracks, job, alloc);
            status.set("Bounce failed", .{});
        };
        return;
    }
    // Masks off before placing, so the new clips publish as they are.
    for (tracks) |*t| t.play_selected = false;
    if (job.replace != 0) {
        replaceBounce(alloc, history, status, pool, tracks, transport, job, selected_track, selected_clip) catch |err| {
            std.log.err("re-bounce place failed: {s}", .{@errorName(err)});
            status.set("Re-bounce failed: {s}", .{@errorName(err)});
        };
        dirty.* = true;
        endBounce(audio, engine, pool, tracks, job, alloc);
        return;
    }
    placeBounce(alloc, history, status, engine, pool, tracks_buf, track_count, transport, job, selected_track, selected_clip, prev_selected_clip) catch |err| {
        std.log.err("bounce place failed: {s}", .{@errorName(err)});
        status.set("Bounce failed: {s}", .{@errorName(err)});
    };
    dirty.* = true;
    endBounce(audio, engine, pool, tracks_buf[0..track_count.*], job, alloc);
}

/// Sum each group's taps, each read from its own latency on, trimmed to
/// the range plus the tail that sounds, into a 32-bit float WAV in the
/// project's audio folder.
fn writeBounceClips(alloc: std.mem.Allocator, tracks: []const track_mod.Track, job: *BounceJob) !void {
    const cap = &job.cap;
    var groups: [MAX_TRACKS]u32 = undefined;
    const n = bounceGroups(job, tracks, &groups);
    var dir_buf: [storage.MAX_PATH]u8 = undefined;
    const dir = storage.recordingsDir(&dir_buf);
    if (dir.len == 0) return error.NoAudioFolder;
    storage.makeParents(dir);
    for (groups[0..n]) |g| {
        // Its length: the range and, past it, what still sounds.
        var len: usize = job.range_frames;
        for (0..tracks.len) |ti| if (g & bit(ti) != 0) {
            const lat = cap.lat[ti];
            const avail = cap.rendered -| lat;
            const sounds = if (cap.hold > 0) cap.loud_end[ti] -| lat else job.total_frames;
            len = @max(len, @min(sounds, avail));
        };
        len = @min(len, job.total_frames);
        const buf = try alloc.alloc(f32, len * 2);
        defer alloc.free(buf);
        @memset(buf, 0);
        for (0..tracks.len) |ti| if (g & bit(ti) != 0) {
            const lat = cap.lat[ti];
            const l = cap.l[ti];
            const r = cap.r[ti];
            const m = @min(len, l.len -| lat);
            for (0..m) |i| {
                buf[i * 2] += l[lat + i];
                buf[i * 2 + 1] += r[lat + i];
            }
        };
        const mono = switch (job.opts.channels) {
            .stereo => false,
            .mono => true,
            .auto => exporter.sidesMatch(buf),
        };
        if (mono) for (0..len) |i| {
            buf[i] = (buf[i * 2] + buf[i * 2 + 1]) * 0.5;
        };
        const bytes = try export_mod.encode(alloc, if (mono) buf[0..len] else buf, .{ .bits = .float32, .channels = if (mono) 1 else 2, .sample_rate = job.sample_rate });
        defer alloc.free(bytes);

        // Named after its source, or "bounce" for several.
        const src_set = g & job.sources;
        var stem_buf: [64]u8 = undefined;
        var slug_buf: [48]u8 = undefined;
        const stem = if (@popCount(src_set) == 1)
            std.fmt.bufPrint(&stem_buf, "{s}-bounce", .{storage.slug(&slug_buf, tracks[@ctz(src_set)].name())}) catch "bounce"
        else
            "bounce";
        var out = &job.outs[job.out_count];
        out.* = .{ .sources = src_set };
        const path = storage.freshPath(&out.path_buf, dir, stem, ".wav");
        if (path.len == 0) return error.NoFreeName;
        out.path_len = path.len;
        try document_mod.writeFile(alloc, path, bytes);
        job.out_count += 1;
    }
}

/// Put each bounced clip on a new track below the lowest source, and
/// mute, keep or delete the originals. One undo step; the new clips end
/// up selected.
fn placeBounce(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: *StatusMessage,
    engine: *engine_mod.Engine,
    pool: *audio_pool_mod.AudioPool,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    transport: *transport_mod.Transport,
    job: *const BounceJob,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
) !void {
    const n = job.out_count;
    if (n == 0) return;
    if (track_count.* + n > MAX_TRACKS) return error.TooManyTracks;
    var sources: [MAX_TRACKS]u32 = undefined;
    var srcs: [MAX_TRACKS]u32 = undefined;
    for (job.outs[0..n], 0..) |*o, k| {
        srcs[k] = try pool.loadFile(o.path());
        sources[k] = o.sources;
    }

    const before = try document_mod.serialize(alloc, tracks_buf[0..track_count.*], transport);
    errdefer alloc.free(before);

    // Each clip's recipe: the selected clips on its source tracks. Deleted
    // originals leave nothing to re-bounce or thaw.
    var recipes: [MAX_TRACKS]?clip_mod.Recipe = @splat(null);
    if (job.opts.originalsMode() != .delete) for (0..n) |k| {
        var r = clip_mod.Recipe{ .tap = job.opts.tap, .tail_auto = job.opts.tail_auto, .tail_sec = job.opts.tail_sec };
        var fits = true;
        for (tracks_buf[0..track_count.*], 0..) |*t, ti| if (sources[k] & bit(ti) != 0) {
            for (t.clips.items) |*cl| if (cl.selected and !cl.muted) {
                if (r.source_count == clip_mod.Recipe.MAX_SOURCES) {
                    fits = false;
                    break;
                }
                r.sources[r.source_count] = cl.uid;
                r.source_count += 1;
            };
        };
        if (fits) recipes[k] = r;
    };

    switch (job.opts.originalsMode()) {
        .mute => for (tracks_buf[0..track_count.*]) |*t| for (t.clips.items) |*cl| {
            if (cl.selected) cl.muted = true;
        },
        .keep => {},
        .delete => _ = arrangement.deleteSelectedClips(tracks_buf[0..track_count.*], alloc, selected_clip),
    }
    _ = arrangement.clearSelection(tracks_buf[0..track_count.*], selected_clip);

    // Below the lowest source.
    var last: usize = 0;
    for (0..track_count.*) |ti| if (job.sources & bit(ti) != 0) {
        last = ti;
    };
    const pos: usize = last + 1;
    const printed = job.opts.tapMode() == .fader or job.opts.tapMode() == .sends;
    for (0..n) |k| {
        const o_src = sources[k];
        const first: usize = @ctz(o_src);
        var name_buf: [track_mod.MAX_NAME]u8 = undefined;
        var fill_buf: [96]u8 = undefined;
        const source_name = if (@popCount(o_src) == 1) tracks_buf[first].name() else freeName(&name_buf, tracks_buf[0..track_count.*], "Bounce", 1);
        const filled = export_mod.fillName(&fill_buf, job.opts.name.text(), .{ .track = source_name });
        const name = if (filled.len > 0) filled[0..@min(filled.len, track_mod.MAX_NAME)] else source_name;
        var t = try track_mod.Track.init(alloc, name, tracks_buf[first].color, silent_machine);
        // Where its sources went, when they agree; else the master.
        var output: u8 = tracks_buf[first].output;
        for (0..track_count.*) |ti| if (o_src & bit(ti) != 0 and tracks_buf[ti].output != output) {
            output = routing_mod.NONE;
        };
        t.output = output;
        if (printed) {
            t.setVolume(1.0);
        } else if (@popCount(o_src) == 1) {
            // Unprinted, it stands in for its source: same fader, pan, sends.
            const s = &tracks_buf[first];
            t.setVolume(s.volume());
            t.setPan(s.pan());
            for (s.sends[0..s.send_count]) |*snd| t.addSend(snd.bus, snd.pre, snd.level()) catch break;
        }
        const src = pool.get(srcs[k]).?;
        const dur = src.seconds();
        const end_sample = job.start_sample + @as(u64, @intFromFloat(dur * @as(f64, @floatFromInt(job.sample_rate))));
        var clip = clip_mod.Clip.initAudio(src.name(), job.start_beat, transport.samplesToBeats(end_sample) - job.start_beat, srcs[k]);
        clip.audio.dur_sec = dur;
        clip.selected = true;
        clip.recipe = recipes[k];
        t.addClip(alloc, clip) catch |err| {
            clip.deinit(alloc);
            t.deinit(alloc);
            return err;
        };
        insertTrackAt(engine, tracks_buf, track_count, @intCast(pos + k), t);
    }
    try history.pushUndo(alloc, before);
    // Fingerprints once the originals are muted (which they don't count).
    for (0..n) |k| {
        const cl = &tracks_buf[pos + k].clips.items[0];
        if (cl.recipe) |*r| r.hash = (recipe_mod.fingerprint(alloc, tracks_buf[0..track_count.*], transport, r) catch null) orelse 0;
    }

    if (prev_selected_clip.*) |r| if (r.track >= pos) {
        prev_selected_clip.*.?.track = r.track + @as(u32, @intCast(n));
    };
    selected_track.* = pos;
    selected_clip.* = .{ .track = @intCast(pos), .clip = 0 };
    if (n == 1) status.set("Bounced to {s}", .{tracks_buf[pos].name()}) else status.set("Bounced to {d} tracks", .{n});
}

/// A re-bounce's result: the clip it was asked for gets the new file and
/// length and a fresh fingerprint; its originals stay as they are. One
/// undo step.
fn replaceBounce(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: *StatusMessage,
    pool: *audio_pool_mod.AudioPool,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    job: *const BounceJob,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
) !void {
    if (job.out_count == 0) return;
    const f = recipe_mod.find(tracks, job.replace) orelse return error.ClipGone;
    const source = try pool.loadFile(job.outs[0].path());
    const src = pool.get(source).?;
    const before = try document_mod.serialize(alloc, tracks, transport);
    errdefer alloc.free(before);
    _ = arrangement.clearSelection(tracks, selected_clip);
    const cl = &tracks[f.track].clips.items[f.clip];
    const dur = src.seconds();
    const end_sample = job.start_sample + @as(u64, @intFromFloat(dur * @as(f64, @floatFromInt(job.sample_rate))));
    cl.audio = .{ .source = source, .dur_sec = dur, .gain = cl.audio.gain };
    cl.start_beat = job.start_beat;
    cl.length_beats = transport.samplesToBeats(end_sample) - job.start_beat;
    cl.setName(src.name());
    cl.selected = true;
    if (cl.recipe) |*r| {
        r.hash = (try recipe_mod.fingerprint(alloc, tracks, transport, r)) orelse r.hash;
        r.stale = false;
    }
    try history.pushUndo(alloc, before);
    selected_track.* = f.track;
    selected_clip.* = .{ .track = @intCast(f.track), .clip = @intCast(f.clip) };
    status.set("Re-bounced {s}", .{tracks[f.track].name()});
}

/// The focused clip's recipe and where the clip is, if it has one.
fn focusedRecipe(tracks: []track_mod.Track, focused: ?clip_mod.ClipRef) ?struct { ref: clip_mod.ClipRef, recipe: clip_mod.Recipe } {
    const f = focused orelse return null;
    if (f.track >= tracks.len or f.clip >= tracks[f.track].clips.items.len) return null;
    const r = tracks[f.track].clips.items[f.clip].recipe orelse return null;
    return .{ .ref = f, .recipe = r };
}

/// Re-bounce the focused clip from its recipe: its originals selected,
/// rendered as they were bounced, into the same clip.
fn startRebounce(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    pool: *audio_pool_mod.AudioPool,
    transport: *transport_mod.Transport,
    tracks: []track_mod.Track,
    focused: *?clip_mod.ClipRef,
    job: *BounceJob,
    dlg: *bounce_dialog.State,
    status: *StatusMessage,
) void {
    const fr = focusedRecipe(tracks, focused.*) orelse {
        status.set("Not a bounce", .{});
        return;
    };
    if (recipe_mod.sourceTracks(tracks, &fr.recipe) == null) {
        status.set("Its source clips are gone", .{});
        return;
    }
    const uid = tracks[fr.ref.track].clips.items[fr.ref.clip].uid;
    _ = arrangement.clearSelection(tracks, focused);
    for (fr.recipe.ids()) |id| {
        const f = recipe_mod.find(tracks, id).?;
        tracks[f.track].clips.items[f.clip].selected = true;
    }
    const opts = bounce_dialog.State{
        .active = true,
        .tap = fr.recipe.tap,
        .mode = @intFromEnum(bounce_dialog.Mode.together),
        .originals = @intFromEnum(bounce_dialog.Originals.keep),
        .tail_auto = fr.recipe.tail_auto,
        .tail_sec = fr.recipe.tail_sec,
    };
    startBounce(alloc, engine, audio, pool, transport, tracks, opts, job, status, uid) catch |err| {
        status.set("Re-bounce failed: {s}", .{@errorName(err)});
        return;
    };
    // The dialog shows its progress.
    if (job.active) dlg.* = opts;
}

/// Thaw the focused bounce: its originals unmuted, the bounce gone. One
/// undo step.
fn thawBounce(alloc: std.mem.Allocator, history: *history_mod.History, status: *StatusMessage, tracks: []track_mod.Track, transport: *transport_mod.Transport, focused: *?clip_mod.ClipRef, dirty: *bool) !void {
    const fr = focusedRecipe(tracks, focused.*) orelse {
        status.set("Not a bounce", .{});
        return;
    };
    if (recipe_mod.sourceTracks(tracks, &fr.recipe) == null) {
        status.set("Its source clips are gone", .{});
        return;
    }
    const before = try document_mod.serialize(alloc, tracks, transport);
    errdefer alloc.free(before);
    _ = arrangement.clearSelection(tracks, focused);
    // The bounce first: removing it moves later clips on its track.
    var gone = tracks[fr.ref.track].clips.orderedRemove(fr.ref.clip);
    gone.deinit(alloc);
    for (fr.recipe.ids()) |id| {
        const f = recipe_mod.find(tracks, id).?;
        const cl = &tracks[f.track].clips.items[f.clip];
        cl.muted = false;
        cl.selected = true;
    }
    try history.pushUndo(alloc, before);
    dirty.* = true;
    status.set("Thawed", .{});
}

/// Insert `t` at `pos`, the tracks from there moving up one; outputs,
/// sends and keys follow. Audio stopped.
fn insertTrackAt(engine: *engine_mod.Engine, tracks_buf: *[MAX_TRACKS]track_mod.Track, track_count: *usize, pos: u8, t: track_mod.Track) void {
    var i = track_count.*;
    while (i > pos) : (i -= 1) tracks_buf[i] = tracks_buf[i - 1];
    track_count.* += 1;
    for (tracks_buf[0..track_count.*], 0..) |*u, j| {
        if (j != pos) u.makeRoomAt(pos);
    }
    tracks_buf[pos] = t;
    tracks_buf[pos].makeRoomAt(pos);
    engine.tracks = tracks_buf[0..track_count.*];
    engine.send_prev = @splat(@splat(-1));
    engine.clearPdc();
    engine.publishRouting();
}

fn bounceProgress(job: *BounceJob) export_dialog.Progress {
    const sr_f: f64 = @floatFromInt(job.sample_rate);
    const per: f64 = @floatFromInt(job.total_frames);
    const done_f: f64 = @as(f64, @floatFromInt(job.pass)) * per + @as(f64, @floatFromInt(job.progress.load(.monotonic)));
    const total_f: f64 = per * @as(f64, @floatFromInt(@max(job.pass_count, 1)));
    const elapsed: f64 = @as(f64, @floatFromInt(nowNs() - job.start_ns)) / 1_000_000_000.0;
    return .{
        .fraction = if (total_f > 0) @floatCast(done_f / total_f) else 0,
        .elapsed_s = elapsed,
        .speed_x = if (elapsed > 0.001) done_f / sr_f / elapsed else 0,
        .rendered_s = done_f / sr_f,
        .total_s = total_f / sr_f,
    };
}

/// Open the Bounce dialog when clips are selected.
/// What the Bounce dialog names: the selected clips, the tracks they're
/// on and how long they run.
fn bounceInfo(transport: *const transport_mod.Transport, tracks: []const track_mod.Track, muted: bool) bounce_dialog.Info {
    var clips: usize = 0;
    for (tracks) |*t| for (t.clips.items) |*cl| {
        if (cl.selected) clips += 1;
    };
    const secs = (rangeSeconds(transport, tracks))[2] orelse 0;
    return .{ .clips = clips, .tracks = @popCount(bounceSources(tracks, muted)), .seconds = secs };
}

fn openBounce(dlg: *bounce_dialog.State, tracks: []const track_mod.Track, status: *StatusMessage) void {
    if (bounceSources(tracks, false) == 0) {
        status.set("Select clips to bounce", .{});
        return;
    }
    dlg.active = true;
}

/// File > Open: the Open panel, then the pick is opened at the top of the
/// next frame (queueOpen).
fn openProject(alloc: std.mem.Allocator) void {
    const chosen = native_dialog.openProject(alloc) catch |err| {
        std.log.err("open dialog failed: {s}", .{@errorName(err)});
        return;
    };
    const path = chosen orelse return;
    defer alloc.free(path);
    queueOpen(alloc, path);
}

/// The project to open at the top of the next frame. Opens are asked for
/// mid-frame (a menu, the Open panel, a Finder double-click, a song from
/// the browser); loading between frames lets the loading card draw.
var pending_open: ?[]u8 = null;

fn queueOpen(alloc: std.mem.Allocator, path: []const u8) void {
    const p = alloc.dupe(u8, path) catch return;
    if (pending_open) |old| alloc.free(old);
    pending_open = p;
}

/// The loading card while a project's tracks are built: the splash over
/// the empty chassis, naming each track, as at boot.
fn loadingStep(ctx: *anyopaque, done: usize, total: usize, name: []const u8) void {
    const ui: *ui_core.Ui = @ptrCast(@alignCast(ctx));
    var sbuf: [48]u8 = undefined;
    var ubuf: [48]u8 = undefined;
    const msg = std.ascii.upperString(&ubuf, std.fmt.bufPrint(&sbuf, "LOADING {s}", .{name}) catch "LOADING PROJECT");
    const frac = @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(@max(total, 1)));
    splash.bootFrame(ui, screenRect(), msg, frac);
}

/// Open the project at `path` (the Open panel's pick, a song from the
/// browser, a double-click in Finder). Undoable, like New Project.
fn openProjectPath(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    tracks: *[]track_mod.Track,
    transport: *transport_mod.Transport,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    project_path: *[]u8,
    project_path_chosen: *bool,
    dirty: *bool,
    status: *StatusMessage,
    path: []const u8,
) !void {
    // The panel lets folders through so it can navigate them; only a
    // .slab folder is a project.
    if (package.isPackage(path) and !std.mem.endsWith(u8, std.mem.trimEnd(u8, path, "/"), ".slab")) {
        status.set("Not a Slab project: {s}", .{basename(path)});
        return;
    }

    const before = try document_mod.serialize(alloc, tracks.*, transport);
    errdefer alloc.free(before);
    const data = document_mod.readFile(alloc, path) catch |err| {
        std.log.err("load failed: {s}", .{@errorName(err)});
        return;
    };
    defer alloc.free(data);
    // The new project's relative references resolve against its folder.
    useProject(path);
    applyProjectBytes(alloc, data, reg, tracks_buf, track_count, tracks, transport, engine, audio, selected_track, selected_clip, prev_selected_clip) catch |err| {
        std.log.err("load failed: {s}", .{@errorName(err)});
        status.set("Load failed", .{});
        useProjectOf(.{ .path = project_path.*, .chosen = project_path_chosen.* });
        return;
    };
    try history.pushSwitch(alloc, before, .{ .path = project_path.*, .chosen = project_path_chosen.* });
    replaceProjectPath(alloc, project_path, try alloc.dupe(u8, path));
    project_path_chosen.* = true;
    dirty.* = false;
    reportLoaded(alloc, status, data, project_path.*);
    std.log.info("loaded {s}", .{project_path.*});
}

// ── The browser's drops (docs/25 §The browser) ───────────────────────

/// Where a browser item lands.
const BrowserDrop = union(enum) {
    none,
    /// A track's lane at a beat: clips and samples go there, a preset
    /// loads on the track.
    lane: struct { track: usize, beat: f64 },
    /// A track's header (or the machine bay showing it): presets and
    /// wavetables load on its machine.
    header: usize,
    /// Below the tracks: a new track with the item on it.
    new_track,
    open_song,
};

/// What a drop needs of the app: the same state the menus act on.
const App = struct {
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    tracks: *[]track_mod.Track,
    transport: *transport_mod.Transport,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    pool: *audio_pool_mod.AudioPool,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    project_path: *[]u8,
    project_path_chosen: *bool,
    dirty: *bool,
    status: *StatusMessage,
    edit_snap: snap_mod.Setting,
};

/// The beat after a track's last clip.
fn trackEnd(t: *const track_mod.Track) f64 {
    var e: f64 = 0;
    for (t.clips.items) |*cl| e = @max(e, cl.start_beat + cl.length_beats);
    return e;
}

fn dropAccepts(kind: library_mod.Kind, d: BrowserDrop, tracks: []const track_mod.Track) bool {
    return switch (d) {
        .none => false,
        .open_song => kind == .song,
        .new_track => kind != .song,
        .lane => |l| switch (kind) {
            .clip, .sample => l.track < tracks.len and !tracks[l.track].isBus(),
            .preset => true,
            else => false,
        },
        .header => kind == .preset or kind == .table,
    };
}

/// How long the dragged clips and samples run, for the landing outline.
fn dragBeats(lib: *const library_mod.Library, br: *const browser.State, pv: *const preview_mod.Previewer, bpm: f64) f64 {
    var len: f64 = 0;
    for (br.selection()) |i| {
        if (i >= lib.items.items.len) continue;
        const it = &lib.items.items[i];
        switch (it.kind) {
            .clip => len += if (br.clip_for != null and br.clip_for.? == i) @max(1, br.clip_len) else 4,
            .sample => len += if (pv.cur != null and std.mem.eql(u8, pv.path(), it.path)) @max(0.25, @as(f64, @floatFromInt(pv.cur.?.data.len)) / @max(1, pv.cur.?.sample_rate) * bpm / 60) else 4,
            else => {},
        }
    }
    return if (len > 0) len else 4;
}

/// Do a drop: `first` is the item under the drag (the cursor), `sel`
/// everything selected. Returns true when the library changed.
fn browserDrop(app: App, lib: *library_mod.Library, sel: []const u32, first: u32, target: BrowserDrop) bool {
    const items = lib.items.items;
    if (first >= items.len) return false;
    const it = &items[first];
    if (target == .open_song) {
        queueOpen(app.alloc, it.path);
        return true;
    }
    // One undo step for the whole drop, a new track included.
    const before = document_mod.serialize(app.alloc, app.tracks.*, app.transport) catch return false;
    var ti: usize = 0;
    var beat: f64 = 0;
    switch (target) {
        .lane => |l| {
            ti = l.track;
            beat = l.beat;
        },
        .header => |h| {
            ti = h;
            beat = trackEnd(&app.tracks.*[h]);
        },
        .new_track => {
            if (app.track_count.* >= MAX_TRACKS) {
                app.alloc.free(before);
                app.status.set("No room for another track", .{});
                return false;
            }
            ti = blk: {
                app.audio.stop();
                defer app.audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
                break :blk newTrack(app.alloc, app.tracks_buf, app.track_count, false, "Track") catch {
                    app.alloc.free(before);
                    return false;
                };
            };
            app.tracks.* = app.tracks_buf[0..app.track_count.*];
            app.engine.tracks = app.tracks.*;
        },
        else => {
            app.alloc.free(before);
            return false;
        },
    }
    const t = &app.tracks.*[ti];
    const ok = switch (it.kind) {
        .preset => dropPreset(app, t, it, target == .new_track),
        .table => dropTable(app, t, it),
        .clip, .sample => dropClips(app, t, ti, lib, sel, beat),
        .song => false,
    };
    if (!ok and target != .new_track) {
        app.alloc.free(before);
        return false;
    }
    // A new track stays even when nothing landed on it; Undo takes it.
    if (ok and target == .new_track) setTrackName(t, it.name);
    app.history.pushUndo(app.alloc, before) catch app.alloc.free(before);
    app.selected_track.* = ti;
    app.dirty.* = true;
    return false;
}

/// A preset onto a track: its machine first (an instrument replaces the
/// track's, an effect joins the chain), then the preset by name.
fn dropPreset(app: App, t: *track_mod.Track, it: *const library_mod.Item, fresh: bool) bool {
    const reg_idx = app.reg.findById(it.machine) orelse {
        app.status.set("No machine {s}", .{it.machine});
        return false;
    };
    const entry = &app.reg.entries[reg_idx];
    const is_effect = entry.in_audio and entry.out_audio and !entry.in_notes;
    var mach: *@import("machine.zig").Machine = undefined;
    if (is_effect) {
        addEffectToTrack(app.alloc, app.audio, app.reg, t, reg_idx) catch |err| {
            app.status.set("Effect failed: {s}", .{@errorName(err)});
            return false;
        };
        mach = &t.effects.items[t.effects.items.len - 1].mach;
    } else {
        if (t.isBus()) {
            app.status.set("A bus takes effects, not {s}", .{entry.nameSlice()});
            return false;
        }
        if (t.machine_idx == null or t.machine_idx.? != reg_idx) {
            assignMachineToTrack(app.alloc, app.audio, app.reg, t, reg_idx) catch |err| {
                app.status.set("Load failed: {s}", .{@errorName(err)});
                return false;
            };
        }
        mach = &t.machine;
    }
    _ = fresh;
    const count: usize = if (mach.preset_count) |f| f(mach.state) else 0;
    const name_of = mach.preset_name orelse return true;
    const apply = mach.apply_preset orelse return true;
    for (0..count) |i| {
        if (!std.mem.eql(u8, std.mem.span(name_of(mach.state, @intCast(i))), it.preset)) continue;
        app.audio.stop();
        defer app.audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
        apply(mach.state, @intCast(i));
        app.status.set("{s}: {s}", .{ entry.nameSlice(), it.name });
        return true;
    }
    app.status.set("{s} has no preset {s}", .{ entry.nameSlice(), it.name });
    return true;
}

/// A wavetable onto a track: the first oscillator plays it. An empty
/// track gets Concoction to play it on.
fn dropTable(app: App, t: *track_mod.Track, it: *const library_mod.Item) bool {
    if (t.machine_idx == null and !t.isBus()) {
        if (app.reg.findById("concoction")) |ci| {
            assignMachineToTrack(app.alloc, app.audio, app.reg, t, ci) catch {};
        }
    }
    const load = t.machine.load_table orelse {
        app.status.set("{s} has no wavetable oscillator", .{t.name()});
        return false;
    };
    if (!load(t.machine.state, it.path, 0)) {
        app.status.set("{s} won't take {s}", .{ t.name(), it.name });
        return false;
    }
    app.status.set("Table {s} on {s}", .{ it.name, t.name() });
    return true;
}

/// Clips and samples onto a lane, one after another from `beat`.
fn dropClips(app: App, t: *track_mod.Track, ti: usize, lib: *const library_mod.Library, sel: []const u32, beat: f64) bool {
    if (t.isBus()) {
        app.status.set("A bus takes no clips", .{});
        return false;
    }
    _ = arrangement.clearSelection(app.tracks.*, app.selected_clip);
    var at = beat;
    var n: usize = 0;
    var last: []const u8 = "";
    for (sel) |i| {
        if (i >= lib.items.items.len) continue;
        const it = &lib.items.items[i];
        switch (it.kind) {
            .clip => {
                const data = document_mod.readFile(app.alloc, it.path) catch continue;
                defer app.alloc.free(data);
                document_mod.insertClipFile(app.alloc, t, data, at) catch |err| {
                    app.status.set("{s}: {s}", .{ it.name, @errorName(err) });
                    continue;
                };
                const cl = &t.clips.items[t.clips.items.len - 1];
                at += cl.length_beats;
            },
            .sample => {
                const source = app.pool.loadFile(it.path) catch |err| {
                    app.status.set("{s}: {s}", .{ it.name, @errorName(err) });
                    continue;
                };
                const src = app.pool.get(source) orelse continue;
                const dur = src.seconds();
                const len = @max(0.25, app.transport.secondsToBeats(at, dur));
                var clip = clip_mod.Clip.initAudio(src.name(), at, len, source);
                clip.audio.start_sec = 0;
                clip.audio.dur_sec = dur;
                t.addClip(app.alloc, clip) catch {
                    clip.deinit(app.alloc);
                    continue;
                };
                at += len;
            },
            else => continue,
        }
        t.clips.items[t.clips.items.len - 1].selected = true;
        app.selected_clip.* = .{ .track = @intCast(ti), .clip = @intCast(t.clips.items.len - 1) };
        last = it.name;
        n += 1;
    }
    if (n == 0) return false;
    if (n == 1) app.status.set("Inserted {s} on {s}", .{ last, t.name() }) else app.status.set("Inserted {d} clips on {s}", .{ n, t.name() });
    return true;
}

fn setTrackName(t: *track_mod.Track, name: []const u8) void {
    const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
    const n = @min(base.len, track_mod.MAX_NAME);
    @memcpy(t.name_buf[0..n], base[0..n]);
    t.name_len = @intCast(n);
}

/// Every selected clip as a `.slabclip` in the home folder's Clips
/// (docs/25 §Save to Library), under its name, never over another.
fn saveClipsToLibrary(alloc: std.mem.Allocator, tracks: []track_mod.Track, status: *StatusMessage) void {
    var hb: [storage.MAX_PATH]u8 = undefined;
    var db: [storage.MAX_PATH]u8 = undefined;
    const dir = std.fmt.bufPrint(&db, "{s}/Clips", .{storage.home(&hb)}) catch return;
    storage.makeParents(dir);
    var saved: usize = 0;
    var last: [storage.MAX_PATH]u8 = undefined;
    var last_len: usize = 0;
    for (tracks) |*t| for (t.clips.items) |*clip| {
        if (!clip.selected) continue;
        const bytes = document_mod.clipFile(alloc, t, clip) catch |err| {
            std.log.err("clip to library: {s}", .{@errorName(err)});
            continue;
        };
        defer alloc.free(bytes);
        var sb: [64]u8 = undefined;
        const stem = storage.slug(&sb, if (clip.name().len > 0) clip.name() else "clip");
        var pb: [storage.MAX_PATH]u8 = undefined;
        const path = storage.freshPath(&pb, dir, if (stem.len > 0) stem else "clip", document_mod.CLIP_EXT);
        if (path.len == 0) continue;
        document_mod.writeFile(alloc, path, bytes) catch continue;
        saved += 1;
        const base = std.fs.path.basename(path);
        @memcpy(last[0..base.len], base);
        last_len = base.len;
    };
    if (saved == 1) status.set("Saved {s} to the library", .{last[0..last_len]}) else if (saved > 1) status.set("Saved {d} clips to the library", .{saved}) else status.set("Nothing saved", .{});
}

/// Move the package's files the project no longer names to the Trash.
fn cleanUpProject(alloc: std.mem.Allocator, project_path: []const u8, status: *StatusMessage) void {
    var ab: [storage.MAX_PATH]u8 = undefined;
    const pkg = storage.absolute(&ab, project_path);
    if (!package.isPackage(pkg)) return;
    const n = package.cleanUp(alloc, pkg, native_dialog.trash) catch |err| {
        std.log.err("clean up failed: {s}", .{@errorName(err)});
        status.set("Clean Up failed", .{});
        return;
    };
    if (n == 0) status.set("Nothing to clean up", .{}) else status.set("Moved {d} unused files to the Trash", .{n});
}

/// Resolve the project's relative references against `path`: a package,
/// or a bare .slab file's folder.
fn useProject(path: []const u8) void {
    var db: [storage.MAX_PATH]u8 = undefined;
    storage.setProject(package.docPath(&db, path));
}

/// Resolve references for `p`: its folder, or none for the untitled
/// project.
fn useProjectOf(p: history_mod.Project) void {
    if (p.chosen) useProject(p.path) else storage.setProject(null);
}

/// "Loaded …", or which files it names that aren't there.
fn reportLoaded(alloc: std.mem.Allocator, status: *StatusMessage, data: []const u8, path: []const u8) void {
    const gone = package.missing(alloc, data);
    if (document_mod.newer_schema) {
        status.set("Loaded {s}: made by a newer slab, some settings may be missing", .{basename(path)});
    } else if (gone.count == 0) {
        status.set("Loaded {s}", .{basename(path)});
    } else {
        status.set("Loaded {s}; {d} files missing: {s}", .{ basename(path), gone.count, std.fs.path.basename(gone.first[0]) });
    }
}

/// The document File > New Project applies: the app's state at boot.
var blank_project: []u8 = &.{};

/// Start an untitled project, as the app does at launch. Undoable, like
/// opening one: the project it replaces is a step back.
fn newProject(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    tracks: *[]track_mod.Track,
    transport: *transport_mod.Transport,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    reg: *registry_mod.Registry,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    project_path: *[]u8,
    project_path_chosen: *bool,
    dirty: *bool,
    status: *StatusMessage,
) !void {
    const before = try document_mod.serialize(alloc, tracks.*, transport);
    errdefer alloc.free(before);
    storage.setProject(null);
    applyProjectBytes(alloc, blank_project, reg, tracks_buf, track_count, tracks, transport, engine, audio, selected_track, selected_clip, prev_selected_clip) catch |err| {
        std.log.err("new project failed: {s}", .{@errorName(err)});
        status.set("New project failed", .{});
        if (project_path_chosen.*) useProject(project_path.*);
        alloc.free(before);
        return;
    };
    try history.pushSwitch(alloc, before, .{ .path = project_path.*, .chosen = project_path_chosen.* });
    replaceProjectPath(alloc, project_path, try alloc.dupe(u8, document_mod.SAVE_PATH));
    project_path_chosen.* = false;
    dirty.* = false;
    status.set("New project", .{});
}

fn replaceProjectPath(alloc: std.mem.Allocator, project_path: *[]u8, next: []u8) void {
    alloc.free(project_path.*);
    project_path.* = next;
}

/// Legacy f32 layout rect → new-core logical rect (the app runs the Ui at
/// zoom 1, so points and logical px coincide).
fn screenRect() ui_geom.Rect {
    return ui_geom.Rect.xywh(0, 0, c.rl.GetScreenWidth(), c.rl.GetScreenHeight());
}

/// Default color for the n-th new track (the track palette, cycled).
fn trackColor(n: usize) c.rl.Color {
    return @bitCast(ui_style.track[n % ui_style.track.len]);
}

fn uiRect(r: c.rl.Rectangle) ui_geom.Rect {
    return ui_geom.Rect.xywh(@intFromFloat(@round(r.x)), @intFromFloat(@round(r.y)), @intFromFloat(@round(r.width)), @intFromFloat(@round(r.height)));
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

/// A header routing edit (docs/23) with one undo step. A new bus is
/// appended with the device stopped, like an added track.
fn applyRouteEdit(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: anytype,
    audio: *audio_mod.Audio,
    edit: arrangement.RouteEdit,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    transport: *const transport_mod.Transport,
) !void {
    const routing = @import("routing.zig");
    if (edit.track >= track_count.* or edit.what == .delete or edit.what == .duplicate or edit.what == .group) return;
    const before = try document_mod.serialize(alloc, tracks_buf[0..track_count.*], transport);
    errdefer alloc.free(before);

    var target: u8 = routing.NONE;
    switch (edit.what) {
        .output => |o| target = o,
        .send_toggle => |bus| target = bus,
        .send_add => |a| target = a.bus,
        .send_pre => |p| target = p.bus,
        .key => |k| target = k.src,
        .output_new_bus, .send_new_bus => {
            audio.stop();
            defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
            target = @intCast(try newTrack(alloc, tracks_buf, track_count, true, if (edit.what == .output_new_bus) "Group" else "Return"));
        },
        .delete, .duplicate, .group => unreachable,
    }
    const t = &tracks_buf[edit.track];
    switch (edit.what) {
        .output, .output_new_bus => {
            t.output = target;
            status.set("{s} outputs to {s}", .{ t.name(), if (target == routing.NONE) "Master" else tracks_buf[target].name() });
        },
        .send_toggle, .send_new_bus => {
            if (t.sendTo(target)) |_| {
                for (t.sendSlots(), 0..) |snd, i| if (snd.bus == target) {
                    t.removeSend(i);
                    break;
                };
                status.set("{s}: send to {s} removed", .{ t.name(), tracks_buf[target].name() });
            } else {
                try t.addSend(target, false, 1.0);
                status.set("{s}: sends to {s}", .{ t.name(), tracks_buf[target].name() });
            }
        },
        .send_add => |a| {
            if (t.sendTo(target) != null) { // already there: the knob set its level
                alloc.free(before);
                return;
            }
            try t.addSend(target, false, a.level);
            status.set("{s}: sends to {s}", .{ t.name(), tracks_buf[target].name() });
        },
        .key => |k| {
            const fx = t.effectByUid(k.fx_uid) orelse {
                alloc.free(before);
                return;
            };
            fx.key = k.src;
            if (k.src == routing.NONE)
                status.set("{s}: {s} unkeyed", .{ t.name(), fx.mach.name })
            else
                status.set("{s}: {s} keyed by {s}", .{ t.name(), fx.mach.name, tracks_buf[k.src].name() });
        },
        .send_pre => |p| {
            const snd = t.sendTo(target) orelse {
                alloc.free(before);
                return;
            };
            snd.pre = p.pre;
            status.set("{s}: send to {s} {s}-fader", .{ t.name(), tracks_buf[target].name(), if (p.pre) "pre" else "post" });
        },
        .delete, .duplicate, .group => unreachable,
    }
    try history.pushUndo(alloc, before);
}

/// Append an empty track or bus named `prefix` and the next free number
/// ("Track 5", "Group 2"). Audio-stopped. Returns its index.
fn newTrack(alloc: std.mem.Allocator, tracks_buf: *[MAX_TRACKS]track_mod.Track, track_count: *usize, bus: bool, prefix: []const u8) !usize {
    if (track_count.* >= MAX_TRACKS) return error.TooManyTracks;
    var name_buf: [track_mod.MAX_NAME]u8 = undefined;
    const name = freeName(&name_buf, tracks_buf[0..track_count.*], prefix, 1);
    var t = try track_mod.Track.init(alloc, name, trackColor(track_count.*), silent_machine);
    if (bus) {
        t.kind = .bus;
        t.setVolume(1.0);
    }
    tracks_buf[track_count.*] = t;
    track_count.* += 1;
    return track_count.* - 1;
}

/// "`base` N" for the lowest N from `from` that no track is named yet.
fn freeName(buf: []u8, tracks: []const track_mod.Track, base: []const u8, from: usize) []const u8 {
    var k = from;
    while (k < 1000) : (k += 1) {
        const name = std.fmt.bufPrint(buf, "{s} {d}", .{ base, k }) catch return base;
        var taken = false;
        for (tracks) |*t| taken = taken or std.mem.eql(u8, t.name(), name);
        if (!taken) return name;
    }
    return base;
}

/// "+" / "+ BUS": `newTrack` as one undo step.
fn appendTrack(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    audio: *audio_mod.Audio,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    transport: *const transport_mod.Transport,
    bus: bool,
) !usize {
    if (track_count.* >= MAX_TRACKS) return error.TooManyTracks;
    const before = try document_mod.serialize(alloc, tracks_buf[0..track_count.*], transport);
    errdefer alloc.free(before);
    const ti = blk: {
        audio.stop();
        defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
        break :blk try newTrack(alloc, tracks_buf, track_count, bus, if (bus) "Bus" else "Track");
    };
    try history.pushUndo(alloc, before);
    return ti;
}

/// The delete confirmation's text: what the track holds and what feeds it.
const DeleteMsg = struct {
    buf: [3][96]u8 = undefined,
    len: [3]usize = .{ 0, 0, 0 },
    n: usize = 0,
    slices: [3][]const u8 = undefined,

    fn add(self: *DeleteMsg, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.buf[self.n], fmt, args) catch self.buf[self.n][0..0];
        self.len[self.n] = out.len;
        self.n += 1;
    }

    fn lines(self: *DeleteMsg) []const []const u8 {
        for (0..self.n) |i| self.slices[i] = self.buf[i][0..self.len[i]];
        return self.slices[0..self.n];
    }
};

/// What deleting track `ti` would lose, written into `msg`; false when the
/// track is empty (no clips, lanes, machines, nothing routed into it).
fn trackContents(tracks: []track_mod.Track, ti: usize, msg: *DeleteMsg) bool {
    const t = &tracks[ti];
    var feeds: usize = 0;
    for (tracks, 0..) |*u, j| {
        if (j == ti) continue;
        var hit = u.output == ti or u.sendTo(@intCast(ti)) != null;
        for (u.effects.items) |fx| hit = hit or fx.key == ti;
        if (hit) feeds += 1;
    }
    const clips = t.clips.items.len;
    const fx = t.effects.items.len;
    const lanes = t.lanes.items.len;
    const inst = t.machine_idx != null;
    if (clips == 0 and fx == 0 and lanes == 0 and !inst and feeds == 0) return false;

    var parts: [4][32]u8 = undefined;
    var part: [4][]const u8 = undefined;
    var k: usize = 0;
    if (clips > 0) {
        part[k] = std.fmt.bufPrint(&parts[k], "{d} clip{s}", .{ clips, if (clips == 1) "" else "s" }) catch "";
        k += 1;
    }
    if (inst) {
        part[k] = "an instrument";
        k += 1;
    }
    if (fx > 0) {
        part[k] = std.fmt.bufPrint(&parts[k], "{d} effect{s}", .{ fx, if (fx == 1) "" else "s" }) catch "";
        k += 1;
    }
    if (lanes > 0) {
        part[k] = std.fmt.bufPrint(&parts[k], "{d} automation lane{s}", .{ lanes, if (lanes == 1) "" else "s" }) catch "";
        k += 1;
    }
    msg.* = .{};
    switch (k) {
        0 => msg.add("{s} holds nothing itself.", .{t.name()}),
        1 => msg.add("{s} has {s}.", .{ t.name(), part[0] }),
        2 => msg.add("{s} has {s} and {s}.", .{ t.name(), part[0], part[1] }),
        3 => msg.add("{s} has {s}, {s} and {s}.", .{ t.name(), part[0], part[1], part[2] }),
        else => msg.add("{s} has {s}, {s}, {s} and {s}.", .{ t.name(), part[0], part[1], part[2], part[3] }),
    }
    if (feeds > 0) msg.add("{d} track{s} route{s} into it.", .{ feeds, if (feeds == 1) "" else "s", if (feeds == 1) "s" else "" });
    msg.add("Undo brings it back.", .{});
    return true;
}

/// Copy track `ti` in right under itself (docs/23 §Duplicating a track):
/// the tracks after it move up one and every reference is renumbered.
/// The copy is selected. One undo step.
fn duplicateTrack(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: anytype,
    audio: *audio_mod.Audio,
    engine: *engine_mod.Engine,
    reg: *registry_mod.Registry,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    transport: *const transport_mod.Transport,
    ti: usize,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    undo: bool,
) !void {
    if (ti >= track_count.*) return;
    if (track_count.* >= MAX_TRACKS) return error.TooManyTracks;
    const tracks = tracks_buf[0..track_count.*];
    const before: ?[]u8 = if (undo) try document_mod.serialize(alloc, tracks, transport) else null;
    errdefer if (before) |b| alloc.free(b);
    var copy = try document_mod.cloneTrack(alloc, tracks, ti, transport, reg, silent_machine);
    // "KIT" → "KIT 2"; "Track 3" → the next free "Track N".
    {
        const orig = tracks[ti].name();
        var base = orig;
        if (std.mem.lastIndexOfScalar(u8, orig, ' ')) |sp| {
            if (sp + 1 < orig.len and std.fmt.parseInt(u32, orig[sp + 1 ..], 10) catch null != null) base = orig[0..sp];
        }
        var name_buf: [track_mod.MAX_NAME]u8 = undefined;
        copy.setName(freeName(&name_buf, tracks, base, 2));
    }
    const pos: u8 = @intCast(ti + 1);
    {
        audio.stop();
        defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
        var i = track_count.*;
        while (i > pos) : (i -= 1) tracks_buf[i] = tracks_buf[i - 1];
        track_count.* += 1;
        for (tracks_buf[0..track_count.*], 0..) |*t, j| {
            if (j != pos) t.makeRoomAt(pos);
        }
        copy.makeRoomAt(pos);
        tracks_buf[pos] = copy;
        engine.tracks = tracks_buf[0..track_count.*];
        engine.send_prev = @splat(@splat(-1));
        engine.publishRouting();
    }
    if (before) |b| try history.pushUndo(alloc, b);

    inline for (.{ selected_clip, prev_selected_clip }) |ref| if (ref.*) |r| {
        if (r.track >= pos) ref.*.?.track = r.track + 1;
    };
    selected_track.* = pos;
    status.set("Duplicated as {s}", .{tracks_buf[pos].name()});
}

/// Apply a header drag (docs/23 §Arrangement): set the moved tracks'
/// outputs, then renumber the tracks to the new order (position k holds
/// the old index of the track that goes there); outputs, sends, keys and
/// the selection follow. One undo step.
fn moveTracks(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    audio: *audio_mod.Audio,
    engine: *engine_mod.Engine,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: usize,
    transport: *const transport_mod.Transport,
    mv: *const track_order.Move,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    rename: *RenameState,
) !void {
    const before = try document_mod.serialize(alloc, tracks_buf[0..track_count], transport);
    errdefer alloc.free(before);
    const map = blk: {
        audio.stop();
        defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
        break :blk try applyMove(engine, tracks_buf, track_count, mv);
    };
    try history.pushUndo(alloc, before);

    if (selected_track.*) |sel| if (sel < track_count) {
        selected_track.* = map[sel];
    };
    inline for (.{ selected_clip, prev_selected_clip }) |ref| if (ref.*) |r| {
        if (r.track < track_count) ref.*.?.track = map[r.track];
    };
    if (rename.kind != .none and rename.track < track_count) rename.track = map[rename.track];
}

/// Set a move's outputs and renumber the tracks to its order; the old →
/// new index map. Audio stopped.
fn applyMove(engine: *engine_mod.Engine, tracks_buf: *[MAX_TRACKS]track_mod.Track, track_count: usize, mv: *const track_order.Move) ![routing_mod.MAX_TRACKS]u8 {
    const new_order = &mv.order;
    var map: [routing_mod.MAX_TRACKS]u8 = @splat(routing_mod.NONE);
    for (new_order[0..track_count], 0..) |old, k| map[old] = @intCast(k);
    for (map[0..track_count]) |m| if (m == routing_mod.NONE) return error.BadOrder;
    {
        for (tracks_buf[0..track_count], mv.output[0..track_count]) |*t, out| {
            if (out != track_order.KEEP) t.output = out;
        }
        // In place, cycle by cycle: slot k takes the track from new_order[k].
        var done: [MAX_TRACKS]bool = @splat(false);
        for (0..track_count) |k| {
            if (done[k]) continue;
            const tmp = tracks_buf[k];
            var j = k;
            while (true) {
                done[j] = true;
                const src = new_order[j];
                if (src == k) {
                    tracks_buf[j] = tmp;
                    break;
                }
                tracks_buf[j] = tracks_buf[src];
                j = src;
            }
        }
        for (tracks_buf[0..track_count]) |*t| t.remapTracks(&map);
        engine.tracks = tracks_buf[0..track_count];
        engine.send_prev = @splat(@splat(-1));
        engine.clearPdc();
        engine.publishRouting();
    }
    return map;
}

/// Group tracks (docs/23 §Arrangement): a new group bus where the first
/// row of `set` sits, inside that row's group, with the set's rows (a
/// group carrying all it holds) routed into it; then the tracks renumber
/// to display order. One undo step; the new group is selected and its
/// name opens for editing.
fn groupTracks(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: anytype,
    audio: *audio_mod.Audio,
    engine: *engine_mod.Engine,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    transport: *const transport_mod.Transport,
    set: *const [MAX_TRACKS]bool,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    rename: *RenameState,
) !void {
    const tracks = tracks_buf[0..track_count.*];
    const o = track_order.Order.ofAll(tracks);
    var roots: [MAX_TRACKS]u8 = undefined;
    const n = o.roots(set, false, &roots);
    if (n == 0) return error.NothingToGroup;
    if (track_count.* >= MAX_TRACKS) return error.TooManyTracks;
    const parent = o.parent[roots[0]];
    if (parent != routing_mod.NONE) {
        var nodes: [MAX_TRACKS]routing_mod.Node = undefined;
        for (tracks, 0..) |*t, i| nodes[i] = t.routingNode();
        const graph = routing_mod.Routing.build(nodes[0..tracks.len]);
        for (roots[0..n]) |ti| if (graph.wouldCycle(ti, parent)) return error.WouldLoop;
    }
    const before = try document_mod.serialize(alloc, tracks, transport);
    errdefer alloc.free(before);
    var g: usize = 0;
    const map = blk: {
        audio.stop();
        defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
        g = try newTrack(alloc, tracks_buf, track_count, true, "Group");
        tracks_buf[g].output = parent;
        for (roots[0..n]) |ti| tracks_buf[ti].output = @intCast(g);
        // It sits where its first member did, so display order is index
        // order again once renumbered to it.
        const o2 = track_order.Order.ofAll(tracks_buf[0..track_count.*]);
        var mv: track_order.Move = .{ .order = undefined, .output = @splat(track_order.KEEP) };
        for (o2.rows[0..o2.n], 0..) |row, k| mv.order[k] = row.ti;
        break :blk try applyMove(engine, tracks_buf, track_count.*, &mv);
    };
    try history.pushUndo(alloc, before);

    for (tracks_buf[0..track_count.*]) |*t| t.multi_sel = false;
    inline for (.{ selected_clip, prev_selected_clip }) |ref| if (ref.*) |cr| {
        if (cr.track < track_count.*) ref.*.?.track = map[cr.track];
    };
    selected_track.* = map[g];
    if (rename.active()) rename.* = .{};
    beginRenameTrack(rename, tracks_buf[0..track_count.*], map[g]);
    status.set("Grouped {d} into {s}", .{ n, tracks_buf[map[g]].name() });
}

/// The tracks an action on `ti` takes: the selection when `whole` and
/// `ti` is in it, else `ti` alone.
fn actionSet(tracks: []const track_mod.Track, sel: ?usize, ti: usize, whole: bool) [MAX_TRACKS]bool {
    var set: [MAX_TRACKS]bool = @splat(false);
    if (whole and arrangement.inSet(tracks, sel, ti)) {
        for (0..tracks.len) |k| set[k] = arrangement.inSet(tracks, sel, k);
    } else if (ti < tracks.len) set[ti] = true;
    return set;
}

/// Remove track `ti`: the tracks above it move down one, and every
/// output, send and key that pointed at it goes (an output falls back to
/// the master). One undo step; the selection follows the renumbering.
fn deleteTrack(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: anytype,
    audio: *audio_mod.Audio,
    engine: *engine_mod.Engine,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    transport: *const transport_mod.Transport,
    ti: usize,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
    rename: *RenameState,
    undo: bool,
) !void {
    if (ti >= track_count.*) return;
    const before: ?[]u8 = if (undo) try document_mod.serialize(alloc, tracks_buf[0..track_count.*], transport) else null;
    errdefer if (before) |b| alloc.free(b);
    var name_buf: [track_mod.MAX_NAME]u8 = undefined;
    const name = name_buf[0..tracks_buf[ti].name().len];
    @memcpy(name, tracks_buf[ti].name());
    {
        audio.stop();
        defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
        tracks_buf[ti].deinit(alloc);
        var i = ti;
        while (i + 1 < track_count.*) : (i += 1) tracks_buf[i] = tracks_buf[i + 1];
        track_count.* -= 1;
        for (tracks_buf[0..track_count.*]) |*t| t.forgetTrack(@intCast(ti));
        engine.tracks = tracks_buf[0..track_count.*];
        engine.send_prev = @splat(@splat(-1));
        engine.publishRouting();
    }
    if (before) |b| try history.pushUndo(alloc, b);

    if (selected_track.*) |s| {
        if (s > ti) selected_track.* = s - 1 else if (s == ti) selected_track.* = if (track_count.* == 0) null else @min(ti, track_count.* - 1);
    }
    inline for (.{ selected_clip, prev_selected_clip }) |ref| if (ref.*) |r| {
        if (r.track == ti) ref.* = null else if (r.track > ti) ref.*.?.track = r.track - 1;
    };
    if (rename.active()) rename.* = .{};
    status.set("Deleted {s}", .{name});
}

/// Bounce `project` to `out` (24-bit WAV): every clip plus a 3 s tail,
/// through the same engine and master soft clip as a DAW render.
/// `--render` / `--stems`: export a project without a window or device
/// (docs/27 §Command line).
fn renderHeadless(alloc: std.mem.Allocator, project: []const u8, cli: Cli) !void {
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    for (registry_mod.builtin_machines) |path| try reg.loadFyMachine(path);
    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    document_mod.setPool(&pool);
    document_mod.setRegistry(&reg);

    var transport: transport_mod.Transport = .{};
    transport.sample_rate = audio_mod.SAMPLE_RATE;
    var master = try track_mod.Track.init(alloc, "Master", @bitCast(ui_style.face_hi), silent_machine);
    master.kind = .master;
    master.setVolume(1.0);
    defer master.deinit(alloc);
    document_mod.setMaster(&master);
    var meter_state: meter_mod.MeterState = .{};
    document_mod.setMeterState(&meter_state);

    const data = try document_mod.readFile(alloc, project);
    useProject(project);
    const gone = package.missing(alloc, data);
    if (gone.count > 0) std.log.warn("{d} files missing", .{gone.count});
    defer alloc.free(data);
    var tracks_buf: [MAX_TRACKS]track_mod.Track = undefined;
    var track_count: usize = 0;
    try document_mod.apply(alloc, data, &reg, &tracks_buf, &track_count, &transport, silent_machine);
    defer for (tracks_buf[0..track_count]) |*t| t.deinit(alloc);
    const tracks = tracks_buf[0..track_count];
    for (tracks) |*t| t.publishSnapshot(&pool);
    master.publishSnapshot(&pool);

    var engine = engine_mod.Engine{
        .transport = &transport,
        .tracks = tracks,
        .master = &master,
        .meter_state = &meter_state,
        .idle_skip = cli.idle_skip,
    };
    try engine.initPdc(alloc);
    defer engine.deinitPdc(alloc);
    try engine.initPool(alloc, cli.workers(), null);
    defer engine.deinitPool(alloc);
    engine.publishRouting();
    var last_beat: f64 = 0;
    for (tracks) |*t| for (t.clips.items) |*clip| if (!clip.muted) {
        last_beat = @max(last_beat, clip.endBeat());
    };
    const sr = audio_mod.SAMPLE_RATE;
    var comment_buf: [96]u8 = undefined;
    var container = if (cli.render) |out| export_mod.Container.ofPath(out) orelse return error.UnknownAudioExtension else export_mod.Container.wav;
    if (container == .aac and cli.alac) container = .alac;
    const tail_s = cli.tail orelse export_settings.TAIL_MAX;
    const out_dir = if (cli.render) |out| std.fs.path.dirname(out) orelse "." else ".";
    const opts = exporter.Options{
        .folder = out_dir,
        .mix_name = if (cli.render) |out| projectStem(out) else null,
        .mix_channels = if (cli.mono) .mono else .stereo,
        .stems = if (cli.stems != null) exporter.stemsOf(tracks, cli.stems_kind, cli.stem_tap) else @splat(.{}),
        .stem_folder = cli.stems,
        .project = projectStem(project),
        .start = if (cli.range) |r| transport.beatsToSamples(r[0]) else 0,
        .end = transport.beatsToSamples(if (cli.range) |r| r[1] else last_beat),
        .loop_wrap = cli.loop_wrap,
        .tail_auto = cli.tail == null,
        .tail_frames = @intFromFloat(tail_s * @as(f32, @floatFromInt(sr))),
        .format = .{
            .container = container,
            .bits = cli.bits,
            .dither = cli.dither,
            .sample_rate = cli.rate orelse sr,
            .aac_kbps = cli.kbps,
            .title = cli.title orelse projectStem(project),
            .artist = cli.artist,
            .album = cli.album,
            .year = cli.year,
            .flac_level = cli.flac_level,
            .comment = exportComment(&comment_buf, data),
            .bpm = transport.baseBpm(),
        },
        .normalize = cli.normalize,
        .target = cli.norm_target,
    };
    const t0 = nowNs();
    const r = try exporter.run(alloc, &engine, tracks, opts, null, null);
    const secs = @as(f64, @floatFromInt(r.frames)) / @as(f64, @floatFromInt(r.sample_rate));
    const took = @as(f64, @floatFromInt(nowNs() - t0)) / 1e9;
    if (cli.render) |out| {
        std.debug.print("rendered {s} -> {s}: {d:.1} s in {d:.2} s ({d:.1}x real time), peak {d:.1} dBFS, rms {d:.1} dBFS, {d} samples at the rail, {d:.1} LUFS, LRA {d:.1} LU, true peak {d:.1} dBTP{s}\n", .{
            project, out, secs, took, secs / took, 20 * std.math.log10(@max(r.peak, 1e-9)), 20 * std.math.log10(@max(r.rms, 1e-12)), r.over,
            r.loudness.integrated, r.loudness.lra, r.loudness.true_peak, if (r.gain_db != 0) " (normalized)" else "",
        });
    }
    if (cli.stems) |dir| std.debug.print("stems {s} -> {s}/: {d} files, {d:.1} s each\n", .{ project, dir, r.files - @intFromBool(cli.render != null), secs });
}

fn applyProjectBytes(
    alloc: std.mem.Allocator,
    data: []const u8,
    reg: *registry_mod.Registry,
    tracks_buf: *[MAX_TRACKS]track_mod.Track,
    track_count: *usize,
    tracks: *[]track_mod.Track,
    transport: *transport_mod.Transport,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    prev_selected_clip: *?clip_mod.ClipRef,
) !void {
    transport.stop();
    audio.stop();
    audio.setRender(null, null);
    defer {
        audio.setRender(engine, engine_mod.Engine.renderCallback);
        audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
    }

    var next_buf: [MAX_TRACKS]track_mod.Track = undefined;
    var next_count: usize = 0;
    try document_mod.apply(alloc, data, reg, &next_buf, &next_count, transport, silent_machine);

    for (tracks_buf[0..track_count.*]) |*t| t.deinit(alloc);
    for (next_buf[0..next_count], 0..) |t, i| tracks_buf[i] = t;
    track_count.* = next_count;
    tracks.* = tracks_buf[0..next_count];
    engine.tracks = tracks.*;
    engine.publishRouting();
    selected_track.* = if (track_count.* > 0) 0 else null;
    selected_clip.* = null;
    prev_selected_clip.* = null;
    if (document_mod.activePool()) |p| {
        for (tracks.*) |*t| t.publishSnapshot(p);
    }
}

/// Dev hook: SLAB_SHOT=<path.png> saves the window's own framebuffer after
/// SLAB_SHOT_FRAME frames (default 60), and every SLAB_SHOT_EVERY frames
/// after that when set. SLAB_SHOT_PLAY=1 starts the transport at load;
/// SLAB_SHOT_SELECT=track:clip opens that clip in the editor;
/// SLAB_SHOT_EXPR=1 starts the piano roll in expression mode;
/// SLAB_SHOT_GROUP=NAME,… groups those tracks on frame 200;
/// SLAB_SHOT_MIXER=1 opens the mixer page; SLAB_SHOT_UNISON=1 opens the
/// selected instrument's unison panel. SLAB_SHOT_DRAG=x0,y0,x1,y1,frame
/// scripts a left drag in logical pixels (see devDrag).
fn devScreenshot(frame: *u32) void {
    frame.* +%= 1;
    const path = std.c.getenv("SLAB_SHOT") orelse return;
    const first = envU32("SLAB_SHOT_FRAME") orelse 60;
    const every = envU32("SLAB_SHOT_EVERY") orelse 0;
    const f = frame.*;
    const due = f == first or (every > 0 and f > first and (f - first) % every == 0);
    if (!due) return;
    const img = c.rl.LoadImageFromScreen();
    defer c.rl.UnloadImage(img);
    _ = c.rl.ExportImage(img, path);
}

/// Dev hook: SLAB_SHOT_DRAG=x0,y0,x1,y1,f hovers (x0, y0) from frame f,
/// presses the left button there on f + 5, moves to (x1, y1) over 20
/// frames and releases on f + 26, overriding the real pointer (screenshots
/// of drags). Logical pixels; the window is pinned to 1400x860.
fn devDrag(ui: *ui_core.Ui, frame: u32) void {
    const v = std.c.getenv("SLAB_SHOT_DRAG") orelse return;
    var it = std.mem.splitScalar(u8, std.mem.span(v), ',');
    var a: [5]f32 = undefined;
    for (&a) |*x| x.* = std.fmt.parseFloat(f32, it.next() orelse return) catch return;
    const f0: u32 = @intFromFloat(a[4]);
    if (frame < f0 or frame > f0 + 26) return;
    const k: i32 = @as(i32, @intCast(frame - f0)) - 5;
    const t: f32 = std.math.clamp(@as(f32, @floatFromInt(k)) / 20, 0, 1);
    inline for (.{ &ui.in, &ui.raw_in }) |in| {
        const px = in.mx;
        const py = in.my;
        in.mx = a[0] + (a[2] - a[0]) * t;
        in.my = a[1] + (a[3] - a[1]) * t;
        in.dx = in.mx - px;
        in.dy = in.my - py;
        in.pressed = k == 0;
        in.down = k >= 0 and k < 21;
        in.released = k == 21;
    }
}

fn envU32(name: [*:0]const u8) ?u32 {
    const v = std.c.getenv(name) orelse return null;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch null;
}

/// Automation recording (docs/22 §Manual changes): while armed and
/// playing, a held control writes its track lane — touch-write, one undo
/// step per pass. The stroke is thinned to 1 px at the arrangement's zoom
/// and rewritten into the lane every frame, so the curve shows as it goes.
const AutoRecorder = struct {
    const MAX: usize = 16384;
    active: bool = false,
    track: usize = 0,
    target: automation.Target = automation.Target.volume(),
    stepped: bool = false,
    beats: [MAX]f64 = undefined,
    vals: [MAX]f32 = undefined,
    n: usize = 0,

    const Held = struct { track: usize, target: automation.Target, stepped: bool, knob: f32 };

    /// The control a hand holds this frame, if any (clears every report).
    fn held(tracks: []track_mod.Track) ?Held {
        var out: ?Held = null;
        for (tracks, 0..) |*t, ti| {
            if (t.touch_vol) out = .{ .track = ti, .target = automation.Target.volume(), .stepped = false, .knob = t.volume() / 1.25 };
            if (t.touch_pan) out = .{ .track = ti, .target = automation.Target.pan(), .stepped = false, .knob = (t.pan() + 1) / 2 };
            t.touch_vol = false;
            t.touch_pan = false;
            if (takeTouch(&t.machine, ti, .inst, 0)) |h| out = h;
            for (t.effects.items) |*fx| if (takeTouch(&fx.mach, ti, .fx, fx.uid)) |h| {
                out = h;
            };
        }
        return out;
    }

    fn takeTouch(m: *const @import("machine.zig").Machine, ti: usize, kind: automation.TargetKind, uid: u16) ?Held {
        const take = m.take_touch orelse return null;
        const tc = take(m.state) orelse return null;
        const info = (m.control_info orelse return null)(m.state, tc.control);
        return .{ .track = ti, .target = automation.Target.control(kind, uid, info.id), .stepped = info.stepped, .knob = tc.knob };
    }

    /// Returns true when the document changed.
    fn tick(self: *AutoRecorder, alloc: std.mem.Allocator, history: *history_mod.History, tracks: []track_mod.Track, transport: *transport_mod.Transport, recording: bool) bool {
        const h = held(tracks);
        if (!recording) {
            self.active = false;
            return false;
        }
        const hv = h orelse {
            self.active = false;
            return false;
        };
        const beat = transport.beats();
        const same = self.active and self.track == hv.track and self.target.eql(hv.target) and self.n > 0 and beat >= self.beats[self.n - 1] - 1e-9;
        if (!same) {
            // A new pass (or the loop wrapped): one undo step each.
            pushHistorySnapshot(alloc, history, tracks, transport);
            self.* = .{ .active = true, .track = hv.track, .target = hv.target, .stepped = hv.stepped };
        }
        if (self.n < MAX and (self.n == 0 or beat > self.beats[self.n - 1] + 1e-6)) {
            self.beats[self.n] = beat;
            self.vals[self.n] = hv.knob;
            self.n += 1;
        } else if (self.n > 0) {
            self.vals[self.n - 1] = hv.knob;
        }
        if (hv.track >= tracks.len) return false;
        self.write(alloc, &tracks[hv.track]) catch return false;
        return true;
    }

    /// Replace the lane's points over the pass with the thinned stroke.
    fn write(self: *AutoRecorder, alloc: std.mem.Allocator, t: *track_mod.Track) !void {
        const lane = try t.laneFor(alloc, self.target, self.stepped);
        t.lanes_shown = true;
        const b0 = self.beats[0];
        const b1 = self.beats[self.n - 1];
        var w: usize = 0;
        for (lane.points.items) |pt| {
            if (pt.beat >= b0 - 1e-9 and pt.beat <= b1 + 1e-9) continue;
            lane.points.items[w] = pt;
            w += 1;
        }
        lane.points.items.len = w;
        var xs: [MAX]f32 = undefined;
        var ys: [MAX]f32 = undefined;
        var keep: [MAX]bool = undefined;
        const ppb = arrangement.pxPerBeat();
        for (0..self.n) |i| {
            xs[i] = @floatCast((self.beats[i] - b0) * ppb);
            ys[i] = self.vals[i] * arrangement.AUTO_H;
        }
        automation.thin(xs[0..self.n], ys[0..self.n], 1.0, keep[0..self.n]);
        for (0..self.n) |i| {
            if (!keep[i]) continue;
            _ = try lane.insert(alloc, .{ .beat = self.beats[i], .value = self.vals[i] });
        }
    }
};

/// Push each lane's value at `beat` into its machine control's display,
/// and null into every control no lane drives.
fn syncAutomationUi(tracks: []track_mod.Track, beat: f64) void {
    for (tracks) |*t| {
        syncMachineAutoUi(t, &t.machine, .inst, 0, beat);
        for (t.effects.items) |*fx| syncMachineAutoUi(t, &fx.mach, .fx, fx.uid, beat);
    }
}

fn syncMachineAutoUi(t: *track_mod.Track, m: *const @import("machine.zig").Machine, kind: automation.TargetKind, uid: u16, beat: f64) void {
    const set = m.set_auto_ui orelse return;
    const info = m.control_info orelse return;
    for (0..m.controlCount()) |i| {
        const target = automation.Target.control(kind, uid, info(m.state, i).id);
        if (!t.isAutomated(target)) {
            set(m.state, i, null);
            continue;
        }
        // Automated somewhere; where no lane speaks it shows its own value.
        const base: f32 = if (m.control_base) |f| f(m.state, i) else 0;
        set(m.state, i, t.autoValue(target, beat) orelse base);
    }
}

fn clearAutomationOverrides(tracks: []track_mod.Track) void {
    for (tracks) |*t| {
        t.vol_override.store(0, .monotonic);
        t.pan_override.store(0, .monotonic);
        if (t.machine.clear_overrides) |f| f(t.machine.state);
        for (t.effects.items) |*fx| if (fx.mach.clear_overrides) |f| f(fx.mach.state);
    }
}

/// Serve panels' Show/Clear automation requests. Returns true on an edit.
fn serviceAutomationRequests(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    selected_track: *?usize,
    status: *StatusMessage,
) bool {
    var edited = false;
    for (tracks, 0..) |*t, ti| {
        if (serviceMachineAutoRequest(alloc, history, tracks, transport, t, &t.machine, .inst, 0, status)) |e| {
            edited = edited or e;
            selected_track.* = ti;
        }
        for (t.effects.items) |*fx| {
            if (serviceMachineAutoRequest(alloc, history, tracks, transport, t, &fx.mach, .fx, fx.uid, status)) |e| {
                edited = edited or e;
                selected_track.* = ti;
            }
        }
    }
    return edited;
}

/// Null when the machine raised nothing; else whether the document changed.
fn serviceMachineAutoRequest(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    t: *track_mod.Track,
    m: *const @import("machine.zig").Machine,
    kind: automation.TargetKind,
    uid: u16,
    status: *StatusMessage,
) ?bool {
    const take = m.take_auto_request orelse return null;
    const req = take(m.state) orelse return null;
    const info_fn = m.control_info orelse return false;
    if (req.control >= m.controlCount()) return false;
    const info = info_fn(m.state, req.control);
    const target = automation.Target.control(kind, uid, info.id);
    switch (req.action) {
        .show => {
            t.lanes_shown = true;
            if (t.findLane(target) != null) return false;
            pushHistorySnapshot(alloc, history, tracks, transport);
            _ = t.laneFor(alloc, target, info.stepped) catch return false;
            status.set("Automation lane: {s}", .{info.label});
            return true;
        },
        .clear => {
            for (t.lanes.items, 0..) |*l, li| if (l.target.eql(target)) {
                pushHistorySnapshot(alloc, history, tracks, transport);
                t.removeLane(alloc, li);
                status.set("Cleared automation: {s}", .{info.label});
                return true;
            };
            return false;
        },
    }
}

fn pushHistorySnapshot(alloc: std.mem.Allocator, history: *history_mod.History, tracks: []track_mod.Track, transport: *transport_mod.Transport) void {
    const snapshot = document_mod.serialize(alloc, tracks, transport) catch |err| {
        std.log.err("history snapshot failed: {s}", .{@errorName(err)});
        return;
    };
    history.pushUndo(alloc, snapshot) catch |err| {
        alloc.free(snapshot);
        std.log.err("history push failed: {s}", .{@errorName(err)});
    };
}

fn beginRenameTrack(rename: *RenameState, tracks: []track_mod.Track, track_idx: usize) void {
    if (track_idx >= tracks.len) return;
    rename.* = .{ .kind = .track, .track = track_idx };
    renameSetText(rename, tracks[track_idx].name());
}

fn beginRenameClip(rename: *RenameState, tracks: []track_mod.Track, ref: clip_mod.ClipRef) void {
    if (ref.track >= tracks.len) return;
    const t = &tracks[ref.track];
    if (ref.clip >= t.clips.items.len) return;
    rename.* = .{ .kind = .clip, .track = @intCast(ref.track), .clip = @intCast(ref.clip) };
    renameSetText(rename, t.clips.items[ref.clip].name());
}

fn deviceMachineOf(t: *track_mod.Track, effect: ?usize) ?*@import("machine.zig").Machine {
    if (effect) |i| {
        if (i >= t.effects.items.len) return null;
        return &t.effects.items[i].mach;
    }
    return &t.machine;
}

// Float the inline text field over the preset block (widened to a usable
// minimum so typing isn't cramped against a tiny preset label).
fn anchorRenameRect(rename: *RenameState, anchor: c.rl.Rectangle) void {
    rename.rect = .{ .x = anchor.x, .y = anchor.y, .width = @max(anchor.width, 120), .height = @max(anchor.height, 18) };
}

fn beginPresetSave(rename: *RenameState, dev: *track_mod.Track, effect: ?usize, anchor: c.rl.Rectangle, library: bool) void {
    rename.* = .{ .kind = if (library) .preset_save_library else .preset_save, .device_track = dev, .device_effect = effect };
    anchorRenameRect(rename, anchor);
}

fn beginPresetRename(rename: *RenameState, dev: *track_mod.Track, effect: ?usize, index: u16, current: []const u8, anchor: c.rl.Rectangle) void {
    rename.* = .{ .kind = .preset_rename, .device_track = dev, .device_effect = effect, .preset_index = index };
    renameSetText(rename, current);
    anchorRenameRect(rename, anchor);
}

/// Start the field with `text`, all selected (typing replaces it).
fn renameSetText(rename: *RenameState, text: []const u8) void {
    rename.tb = text_field.TextBuf.init(text, track_mod.MAX_NAME);
    rename.tb.selectAll();
}

/// The inline rename field, floated over the name being edited. Runs after
/// the panes (they report `rename.rect` this frame) and before the draw.
fn runRename(
    ui: *ui_core.Ui,
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    rename: *RenameState,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    dirty: *bool,
    status: *StatusMessage,
) !void {
    if (!rename.active() or rename.rect.width <= 0) return;
    var r = uiRect(rename.rect);
    r.w = @max(r.w, 60);
    r.h = @max(r.h, 14);
    const ev = text_field.field(ui, r, "rename", &rename.tb, .{ .focus = rename.start_focus, .commit_on_blur = true });
    rename.start_focus = false;
    switch (ev) {
        .commit => try commitRename(alloc, history, rename, tracks, transport, dirty, status),
        .cancel => {
            rename.kind = .none;
            status.set("Rename canceled", .{});
        },
        .none, .changed => {},
    }
}

fn commitRename(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    rename: *RenameState,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    dirty: *bool,
    status: *StatusMessage,
) !void {
    // Preset save/rename act on machine preset files, not the document.
    switch (rename.kind) {
        .preset_save, .preset_save_library, .preset_rename => {
            commitPreset(rename, tracks, dirty, status);
            rename.kind = .none;
            return;
        },
        else => {},
    }

    if (rename.tb.len == 0) {
        rename.kind = .none;
        status.set("Rename canceled", .{});
        return;
    }

    const before = try document_mod.serialize(alloc, tracks, transport);
    const text = rename.tb.text();
    var changed = false;
    switch (rename.kind) {
        .track => if (rename.track < tracks.len) {
            tracks[rename.track].setName(text);
            changed = true;
        },
        .clip => if (rename.track < tracks.len and rename.clip < tracks[rename.track].clips.items.len) {
            tracks[rename.track].clips.items[rename.clip].setName(text);
            changed = true;
        },
        // Preset kinds are handled above and returned early.
        .preset_save, .preset_save_library, .preset_rename, .none => {},
    }
    if (changed) {
        try history.pushUndo(alloc, before);
        dirty.* = true;
        status.set("Renamed", .{});
    } else {
        alloc.free(before);
    }
    rename.kind = .none;
}

// Apply a preset save/rename to the targeted device's machine. Preset files
// live next to the machine, so there's no document snapshot/undo here.
fn commitPreset(rename: *RenameState, tracks: []track_mod.Track, dirty: *bool, status: *StatusMessage) void {
    _ = tracks;
    const t = rename.device_track orelse {
        status.set("Preset target gone", .{});
        return;
    };
    const mach = deviceMachineOf(t, rename.device_effect) orelse {
        status.set("Preset target gone", .{});
        return;
    };
    const name = rename.tb.text();
    if (name.len == 0) {
        status.set("Preset name empty", .{});
        return;
    }
    var name_buf: [track_mod.MAX_NAME + 1:0]u8 = [_:0]u8{0} ** (track_mod.MAX_NAME + 1);
    @memcpy(name_buf[0..name.len], name);
    const name_z: [*:0]const u8 = @ptrCast(&name_buf[0]);
    switch (rename.kind) {
        .preset_save => {
            const f = mach.save_preset_named orelse return;
            if (f(mach.state, name_z) != null) {
                dirty.* = true;
                const where = if (std.mem.endsWith(u8, storage.projectDir(), ".slab")) "the project" else "the library (save the project to keep presets in it)";
                status.set("Saved preset {s} to {s}", .{ name, where });
            } else status.set("Preset save failed (name in use?)", .{});
        },
        .preset_save_library => {
            const f = mach.save_preset_library orelse return;
            if (f(mach.state, name_z) != null) {
                dirty.* = true;
                status.set("Saved preset {s} to the library", .{name});
            } else status.set("Preset save failed", .{});
        },
        .preset_rename => {
            const f = mach.rename_preset orelse return;
            if (f(mach.state, rename.preset_index, name_z) != null) {
                dirty.* = true;
                status.set("Renamed preset {s}", .{name});
            } else status.set("Preset rename failed (name in use?)", .{});
        },
        else => {},
    }
}

fn arrangementRenameTarget(rename: *const RenameState) arrangement.RenameTarget {
    return switch (rename.kind) {
        .track => .{ .kind = .track, .track = rename.track },
        .clip => .{ .kind = .clip, .track = rename.track, .clip = rename.clip },
        .preset_save, .preset_save_library, .preset_rename, .none => .{},
    };
}

fn handleFocusedEditCommands(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    clipboard: *EditClipboard,
    status: *StatusMessage,
    focus: FocusPane,
    edit_snap: snap_mod.Setting,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    rename: *RenameState,
    dirty: *bool,
) !void {
    const cmd = commandModifierDown();

    if (c.rl.IsKeyPressed(c.rl.KEY_ESCAPE)) {
        const cancelled = switch (focus) {
            .arrangement => arrangement.cancelInteractions(),
            .piano_roll => clip_editor.cancelInteractions(),
            .browser, .machine_bay, .top_bar => false,
        };
        if (cancelled) return;
        _ = switch (focus) {
            .arrangement => arrangement.clearSelection(tracks, selected_clip),
            .piano_roll => clip_editor.clearSelection(tracks, selected_clip.*),
            .browser, .machine_bay, .top_bar => false,
        };
        status.set("Selection cleared", .{});
        return;
    }

    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_C)) {
        _ = copyFocusedSelection(alloc, clipboard, status, focus, tracks, selected_clip.*);
        return;
    }

    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_X)) {
        const copied = copyFocusedSelection(alloc, clipboard, status, focus, tracks, selected_clip.*);
        if (!copied) return;
        try handleFocusedDelete(alloc, history, status, focus, tracks, transport, selected_clip, dirty);
        return;
    }

    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_V)) {
        const before = try document_mod.serialize(alloc, tracks, transport);
        const changed = pasteFocusedClipboard(alloc, clipboard, status, focus, edit_snap, .{ .beat = transport.beats() }, tracks, selected_track, selected_clip, transport.beats());
        if (changed) {
            try history.pushUndo(alloc, before);
            dirty.* = true;
        } else {
            alloc.free(before);
        }
        return;
    }

    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_A)) {
        const changed = switch (focus) {
            .arrangement => arrangement.selectAllClips(tracks, selected_track, selected_clip),
            .piano_roll => clip_editor.selectAllNotes(tracks, selected_clip.*),
            .browser, .machine_bay, .top_bar => false,
        };
        if (changed) status.set("Selected all", .{});
        return;
    }

    if (!cmd and c.rl.IsKeyPressed(c.rl.KEY_ENTER)) {
        if (focus == .piano_roll or selected_clip.* != null) {
            if (selected_clip.*) |s| beginRenameClip(rename, tracks, s);
        } else if (selected_track.*) |ti| {
            beginRenameTrack(rename, tracks, ti);
        }
        return;
    }

    var changed = false;
    const before = if (editMutationKeyPressed(focus)) try document_mod.serialize(alloc, tracks, transport) else null;
    defer if (before) |snapshot| if (!changed) alloc.free(snapshot);

    if (!cmd and c.rl.IsKeyPressed(c.rl.KEY_D)) {
        changed = switch (focus) {
            .arrangement => arrangement.duplicateSelectedClips(tracks, alloc, selected_track, selected_clip, edit_snap),
            .piano_roll => clip_editor.duplicateSelectedNotes(tracks, selected_clip.*, alloc, edit_snap),
            .browser, .machine_bay, .top_bar => false,
        };
    } else if (!cmd and (c.rl.IsKeyPressed(c.rl.KEY_ZERO) or c.rl.IsKeyPressed(c.rl.KEY_KP_0))) {
        changed = switch (focus) {
            .arrangement => arrangement.toggleClipMute(tracks, selected_clip.*, true),
            .piano_roll => arrangement.toggleClipMute(tracks, selected_clip.*, false),
            .browser, .machine_bay, .top_bar => false,
        };
    } else if (!cmd and focus == .piano_roll and c.rl.IsKeyPressed(c.rl.KEY_Q)) {
        changed = clip_editor.quantizeSelectedNotes(tracks, selected_clip.*, edit_snap);
    } else if (!cmd and focus == .piano_roll and c.rl.IsKeyPressed(c.rl.KEY_H)) {
        changed = clip_editor.humanizeSelectedNotes(tracks, selected_clip.*, edit_snap);
    } else if (!cmd and focus == .piano_roll and c.rl.IsKeyPressed(c.rl.KEY_S)) {
        changed = clip_editor.snapSelectedToScale(tracks, selected_clip.*);
    } else if (!cmd and arrowKeyPressed()) {
        const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        const alt = c.rl.IsKeyDown(c.rl.KEY_LEFT_ALT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_ALT);
        const beat_step = snap_mod.nudgeStep(edit_snap, alt, shift);
        const octave = if (shift) @as(i32, 12) else @as(i32, 1);
        changed = switch (focus) {
            .arrangement => blk: {
                if (c.rl.IsKeyPressed(c.rl.KEY_LEFT)) break :blk arrangement.nudgeSelectedClips(tracks, alloc, selected_clip, -beat_step, 0, edit_snap);
                if (c.rl.IsKeyPressed(c.rl.KEY_RIGHT)) break :blk arrangement.nudgeSelectedClips(tracks, alloc, selected_clip, beat_step, 0, edit_snap);
                if (c.rl.IsKeyPressed(c.rl.KEY_UP)) break :blk arrangement.nudgeSelectedClips(tracks, alloc, selected_clip, 0, -1, edit_snap);
                if (c.rl.IsKeyPressed(c.rl.KEY_DOWN)) break :blk arrangement.nudgeSelectedClips(tracks, alloc, selected_clip, 0, 1, edit_snap);
                break :blk false;
            },
            .piano_roll => blk: {
                if (c.rl.IsKeyPressed(c.rl.KEY_LEFT)) break :blk clip_editor.nudgeSelectedNotes(tracks, selected_clip.*, -beat_step, 0, edit_snap);
                if (c.rl.IsKeyPressed(c.rl.KEY_RIGHT)) break :blk clip_editor.nudgeSelectedNotes(tracks, selected_clip.*, beat_step, 0, edit_snap);
                if (c.rl.IsKeyPressed(c.rl.KEY_UP)) break :blk clip_editor.nudgeSelectedNotes(tracks, selected_clip.*, 0, octave, edit_snap);
                if (c.rl.IsKeyPressed(c.rl.KEY_DOWN)) break :blk clip_editor.nudgeSelectedNotes(tracks, selected_clip.*, 0, -octave, edit_snap);
                break :blk false;
            },
            .browser, .machine_bay, .top_bar => false,
        };
    }

    if (changed) {
        if (before) |snapshot| try history.pushUndo(alloc, snapshot);
        dirty.* = true;
        status.set("Edited", .{});
    }
}

fn copyFocusedSelection(
    alloc: std.mem.Allocator,
    clipboard: *EditClipboard,
    status: *StatusMessage,
    focus: FocusPane,
    tracks: []track_mod.Track,
    selected_clip: ?clip_mod.ClipRef,
) bool {
    clipboard.clear(alloc);
    switch (focus) {
        .arrangement => {
            if (arrangement.copySelectedClips(tracks, alloc, &clipboard.clips)) {
                clipboard.mode = .clips;
                status.set("Copied {d} clip{s}", .{ clipboard.clips.items.len, plural(clipboard.clips.items.len) });
                return true;
            }
        },
        .piano_roll => {
            if (clip_editor.copySelectedNotes(tracks, selected_clip, alloc, &clipboard.notes)) {
                clipboard.mode = .notes;
                status.set("Copied {d} note{s}", .{ clipboard.notes.items.len, plural(clipboard.notes.items.len) });
                return true;
            }
        },
        .browser, .machine_bay, .top_bar => {},
    }
    status.set("Nothing to copy", .{});
    return false;
}

fn pasteFocusedClipboard(
    alloc: std.mem.Allocator,
    clipboard: *const EditClipboard,
    status: *StatusMessage,
    focus: FocusPane,
    edit_snap: snap_mod.Setting,
    target: EditTarget,
    tracks: []track_mod.Track,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    fallback_beat: f64,
) bool {
    const target_beat = target.beat orelse fallback_beat;
    const changed = switch (focus) {
        .arrangement => if (clipboard.mode == .clips)
            arrangement.pasteClips(tracks, alloc, selected_track, selected_clip, clipboard.clips.items, target_beat, target.track, edit_snap)
        else
            false,
        .piano_roll => if (clipboard.mode == .notes)
            clip_editor.pasteNotes(tracks, selected_clip.*, alloc, clipboard.notes.items, target_beat, target.pitch, edit_snap)
        else
            false,
        .browser, .machine_bay, .top_bar => false,
    };
    if (changed) {
        switch (clipboard.mode) {
            .clips => status.set("Pasted {d} clip{s}", .{ clipboard.clips.items.len, plural(clipboard.clips.items.len) }),
            .notes => status.set("Pasted {d} note{s}", .{ clipboard.notes.items.len, plural(clipboard.notes.items.len) }),
            .empty => {},
        }
    } else {
        status.set("Nothing to paste", .{});
    }
    return changed;
}

fn executeEditCommand(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    clipboard: *EditClipboard,
    status: *StatusMessage,
    focus: FocusPane,
    edit_snap: snap_mod.Setting,
    command: menu.EditCommand,
    target: EditTarget,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    selected_track: *?usize,
    selected_clip: *?clip_mod.ClipRef,
    rename: *RenameState,
    dirty: *bool,
) !void {
    switch (command) {
        .none => return,
        .copy => {
            _ = copyFocusedSelection(alloc, clipboard, status, focus, tracks, selected_clip.*);
            return;
        },
        .save_to_library => {
            saveClipsToLibrary(alloc, tracks, status);
            return;
        },
        .select_all => {
            const changed = switch (focus) {
                .arrangement => arrangement.selectAllClips(tracks, selected_track, selected_clip),
                .piano_roll => clip_editor.selectAllNotes(tracks, selected_clip.*),
                .browser, .machine_bay, .top_bar => false,
            };
            if (changed) status.set("Selected all", .{});
            return;
        },
        .clear_selection => {
            const changed = switch (focus) {
                .arrangement => arrangement.clearSelection(tracks, selected_clip),
                .piano_roll => clip_editor.clearSelection(tracks, selected_clip.*),
                .browser, .machine_bay, .top_bar => false,
            };
            if (changed) status.set("Selection cleared", .{});
            return;
        },
        .rename => {
            if (focus == .piano_roll or selected_clip.* != null) {
                if (selected_clip.*) |s| beginRenameClip(rename, tracks, s);
            } else if (selected_track.*) |ti| {
                beginRenameTrack(rename, tracks, ti);
            }
            return;
        },
        else => {},
    }

    const before = try document_mod.serialize(alloc, tracks, transport);
    var changed = false;
    switch (command) {
        .cut => {
            if (copyFocusedSelection(alloc, clipboard, status, focus, tracks, selected_clip.*)) {
                changed = switch (focus) {
                    .arrangement => arrangement.deleteSelectedClips(tracks, alloc, selected_clip),
                    .piano_roll => clip_editor.deleteSelectedPoints(tracks, selected_clip.*) or clip_editor.deleteSelectedNotes(tracks, selected_clip.*),
                    .browser, .machine_bay, .top_bar => false,
                };
                if (changed) status.set("Cut", .{});
            }
        },
        .paste => {
            changed = pasteFocusedClipboard(alloc, clipboard, status, focus, edit_snap, target, tracks, selected_track, selected_clip, transport.beats());
        },
        .duplicate => {
            changed = switch (focus) {
                .arrangement => arrangement.duplicateSelectedClips(tracks, alloc, selected_track, selected_clip, edit_snap),
                .piano_roll => clip_editor.duplicateSelectedNotes(tracks, selected_clip.*, alloc, edit_snap),
                .browser, .machine_bay, .top_bar => false,
            };
            if (changed) status.set("Duplicated", .{});
        },
        .delete => {
            changed = switch (focus) {
                .arrangement => arrangement.deleteSelectedClips(tracks, alloc, selected_clip),
                .piano_roll => clip_editor.deleteSelectedPoints(tracks, selected_clip.*) or clip_editor.deleteSelectedNotes(tracks, selected_clip.*),
                .browser, .machine_bay, .top_bar => false,
            };
            if (changed) status.set("Deleted", .{});
        },
        .loop_selection => {
            changed = if (focus == .arrangement) arrangement.loopSelectedClips(tracks, transport) else false;
            if (changed) status.set("Looped selection", .{});
        },
        .loop_arrangement => {
            changed = if (focus == .arrangement) arrangement.loopArrangement(tracks, transport) else false;
            if (changed) status.set("Looped arrangement", .{});
        },
        .clear_loop => {
            if (focus == .arrangement) {
                transport.clearLoop();
                changed = true;
                status.set("Loop cleared", .{});
            }
        },
        .reverse => {
            changed = switch (focus) {
                .arrangement => arrangement.reverseAudioClips(tracks, selected_clip.*, true),
                .piano_roll => arrangement.reverseAudioClips(tracks, selected_clip.*, false),
                else => false,
            };
            if (changed) status.set("Reversed", .{});
        },
        .mute_clips => {
            changed = switch (focus) {
                .arrangement => arrangement.toggleClipMute(tracks, selected_clip.*, true),
                .piano_roll => arrangement.toggleClipMute(tracks, selected_clip.*, false),
                else => false,
            };
        },
        .clear_solo_mute => {
            changed = arrangement.clearSolosAndMutes(tracks);
            if (changed) status.set("Solos and mutes cleared", .{});
        },
        .split_at_playhead => {
            changed = if (focus == .arrangement) arrangement.splitSelectedClipsAt(tracks, alloc, selected_clip, transport.beats(), transport.map()) else false;
            if (changed) status.set("Split clips", .{});
        },
        .quantize => {
            changed = if (focus == .piano_roll) clip_editor.quantizeSelectedNotes(tracks, selected_clip.*, edit_snap) else false;
            if (changed) status.set("Quantized", .{});
        },
        .humanize => {
            changed = if (focus == .piano_roll) clip_editor.humanizeSelectedNotes(tracks, selected_clip.*, edit_snap) else false;
            if (changed) status.set("Humanized", .{});
        },
        .snap_to_scale => {
            changed = if (focus == .piano_roll) clip_editor.snapSelectedToScale(tracks, selected_clip.*) else false;
            if (changed) status.set("Snapped to scale", .{});
        },
        .octave_up => {
            changed = if (focus == .piano_roll) clip_editor.nudgeSelectedNotes(tracks, selected_clip.*, 0, 12, edit_snap) else false;
            if (changed) status.set("Octave up", .{});
        },
        .octave_down => {
            changed = if (focus == .piano_roll) clip_editor.nudgeSelectedNotes(tracks, selected_clip.*, 0, -12, edit_snap) else false;
            if (changed) status.set("Octave down", .{});
        },
        // `import_audio` is intercepted in the arrangement-result handler
        // (it needs the audio pool + file dialog); never reaches here.
        .none, .copy, .select_all, .clear_selection, .rename, .file_new, .file_open, .file_save, .file_save_as, .file_clean_up, .render_audio, .import_audio, .bounce, .rebounce, .thaw, .save_to_library => {},
    }

    if (changed) {
        try history.pushUndo(alloc, before);
        dirty.* = true;
    } else {
        alloc.free(before);
        if (command == .clear_solo_mute) status.set("No solos or mutes", .{}) else if (command != .paste) status.set("No selection", .{});
    }
}

fn editMutationKeyPressed(focus: FocusPane) bool {
    if (commandModifierDown()) return false;
    if (c.rl.IsKeyPressed(c.rl.KEY_D) or arrowKeyPressed()) return true;
    if (c.rl.IsKeyPressed(c.rl.KEY_ZERO) or c.rl.IsKeyPressed(c.rl.KEY_KP_0)) return true;
    return focus == .piano_roll and (c.rl.IsKeyPressed(c.rl.KEY_Q) or
        c.rl.IsKeyPressed(c.rl.KEY_H) or c.rl.IsKeyPressed(c.rl.KEY_S));
}

fn arrowKeyPressed() bool {
    return c.rl.IsKeyPressed(c.rl.KEY_LEFT) or c.rl.IsKeyPressed(c.rl.KEY_RIGHT) or
        c.rl.IsKeyPressed(c.rl.KEY_UP) or c.rl.IsKeyPressed(c.rl.KEY_DOWN);
}

fn handleFocusedDelete(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    status: *StatusMessage,
    focus: FocusPane,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    selected_clip: *?clip_mod.ClipRef,
    dirty: *bool,
) !void {
    if (!deletePressed()) return;
    const before = try document_mod.serialize(alloc, tracks, transport);
    const changed = switch (focus) {
        .piano_roll => clip_editor.deleteSelectedPoints(tracks, selected_clip.*) or clip_editor.deleteSelectedNotes(tracks, selected_clip.*),
        .arrangement => arrangement.deleteSelectedPoints(tracks) or arrangement.deleteSelectedClips(tracks, alloc, selected_clip),
        .browser, .machine_bay, .top_bar => false,
    };
    if (changed) {
        try history.pushUndo(alloc, before);
        dirty.* = true;
        status.set("Deleted", .{});
    } else {
        alloc.free(before);
        status.set("Nothing to delete", .{});
    }
}

fn deletePressed() bool {
    return c.rl.IsKeyPressed(c.rl.KEY_DELETE) or c.rl.IsKeyPressed(c.rl.KEY_BACKSPACE);
}

fn shiftDown() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
}

fn shouldCaptureHistory(m: pane.Mouse, rects: layout_mod.Rects, focus: FocusPane) bool {
    if (!m.left_pressed) return false;
    return switch (focus) {
        .arrangement => pane.contains(rects.arrangement, m.x, m.y),
        .piano_roll => pane.contains(rects.clip_editor, m.x, m.y),
        .browser => pane.contains(rects.browser, m.x, m.y),
        .machine_bay => pane.contains(rects.machine_bay, m.x, m.y),
        .top_bar => false,
    };
}

fn focusFromPoint(rects: layout_mod.Rects, m: pane.Mouse, clip_editor_visible: bool) FocusPane {
    if (pane.contains(rects.top_bar, m.x, m.y)) return .top_bar;
    if (pane.contains(rects.browser, m.x, m.y)) return .browser;
    if (clip_editor_visible and pane.contains(rects.clip_editor, m.x, m.y)) return .piano_roll;
    if (pane.contains(rects.machine_bay, m.x, m.y)) return .machine_bay;
    if (pane.contains(rects.arrangement, m.x, m.y)) return .arrangement;
    return .arrangement;
}

fn focusLabel(focus: FocusPane) [*:0]const u8 {
    return switch (focus) {
        .arrangement => "Arrangement",
        .piano_roll => "Piano roll",
        .browser => "Browser",
        .machine_bay => "Machine bay",
        .top_bar => "Top bar",
    };
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

fn commandModifierDown() bool {
    return c.rl.IsKeyDown(c.rl.KEY_LEFT_SUPER) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SUPER) or
        c.rl.IsKeyDown(c.rl.KEY_LEFT_CONTROL) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_CONTROL);
}

fn handleSnapKeys(edit_snap: *snap_mod.Setting, status: *StatusMessage) void {
    if (commandModifierDown()) return;
    if (c.rl.IsKeyPressed(c.rl.KEY_LEFT_BRACKET)) {
        edit_snap.* = edit_snap.*.coarser();
        status.set("Snap {s}", .{std.mem.span(edit_snap.*.label())});
    } else if (c.rl.IsKeyPressed(c.rl.KEY_RIGHT_BRACKET)) {
        edit_snap.* = edit_snap.*.finer();
        status.set("Snap {s}", .{std.mem.span(edit_snap.*.label())});
    }
}

fn clipRefEq(a: ?clip_mod.ClipRef, b: ?clip_mod.ClipRef) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.track == b.?.track and a.?.clip == b.?.clip;
}

fn selectedClipIsAudio(tracks: []track_mod.Track, selected: ?clip_mod.ClipRef) bool {
    const s = selected orelse return false;
    if (s.track >= tracks.len) return false;
    const t = &tracks[s.track];
    if (s.clip >= t.clips.items.len) return false;
    return t.clips.items[s.clip].isAudio();
}

test "synthpop demo notes fit a 4-bar loop and span bass to lead range" {
    const alloc = std.testing.allocator;
    var t = try track_mod.Track.init(alloc, "test", trackColor(0), silent_machine);
    defer t.deinit(alloc);

    try addClipFromNotes(alloc, &t, "Bass", &bass_notes);
    try addClipFromNotes(alloc, &t, "Lead", &lead_notes);
    try addClipFromNotes(alloc, &t, "Pad", &pad_notes);

    var lo: u8 = 127;
    var hi: u8 = 0;
    for (t.clips.items) |*clip| {
        try std.testing.expectEqual(@as(f64, 0), clip.start_beat);
        try std.testing.expectEqual(@as(f64, 16), clip.length_beats);
        for (clip.notes.items) |note| {
            lo = @min(lo, note.pitch);
            hi = @max(hi, note.pitch);
            try std.testing.expect(note.start_beat >= 0);
            try std.testing.expect(note.start_beat + note.length_beats <= 16);
        }
    }
    try std.testing.expect(lo <= 45); // bass reaches A2
    try std.testing.expect(hi >= 83); // lead reaches B5
}

test "synthpop_8bar demo loads as JSON with expected note counts" {
    const alloc = std.testing.allocator;
    const data = try document_mod.readFile(alloc, "demos/synthpop_8bar.slab");
    defer alloc.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const tracks = parsed.value.object.get("tracks").?.array;
    try std.testing.expectEqual(@as(usize, 3), tracks.items.len);

    // Bass=60, Chords=32, Arp=64 (each track has one note clip).
    const expected = [_]usize{ 60, 32, 64 };
    for (tracks.items, expected) |trk, want| {
        const clips = trk.object.get("clips").?.array;
        try std.testing.expectEqual(@as(usize, 1), clips.items.len);
        const notes = clips.items[0].object.get("notes").?.array;
        try std.testing.expectEqual(want, notes.items.len);
    }
}

const _fy_host = @import("fy_host.zig");

test "undoing Open goes back to the project it left, redo to the one it opened" {
    const alloc = std.testing.allocator;
    var history: history_mod.History = .{};
    defer history.deinit(alloc);
    var project_path = try alloc.dupe(u8, document_mod.SAVE_PATH);
    defer alloc.free(project_path);
    var chosen = false;
    defer storage.setProject(null);

    // What openProjectPath and newProject record: the document before, in
    // the project before.
    const open = struct {
        fn f(a: std.mem.Allocator, h: *history_mod.History, path: *[]u8, ch: *bool, doc: []const u8, next: ?[]const u8) !void {
            try h.pushSwitch(a, try a.dupe(u8, doc), .{ .path = path.*, .chosen = ch.* });
            replaceProjectPath(a, path, try a.dupe(u8, next orelse document_mod.SAVE_PATH));
            ch.* = next != null;
            useProjectOf(.{ .path = path.*, .chosen = ch.* });
        }
    }.f;
    try open(alloc, &history, &project_path, &chosen, "untitled", "songs/voltage_riot.slab");
    try history.pushUndo(alloc, try alloc.dupe(u8, "riot")); // an edit in the riot
    try open(alloc, &history, &project_path, &chosen, "riot edited", "demos/night_drive.slab");
    try std.testing.expect(std.mem.endsWith(u8, storage.projectDir(), "demos/night_drive.slab"));

    // ⌘Z: the riot's tracks, title, save path and references.
    const back = (try stepHistory(alloc, &history, try alloc.dupe(u8, "night"), &project_path, &chosen, false)).?;
    defer back.deinit(alloc);
    try std.testing.expectEqualStrings("riot edited", back.doc);
    try std.testing.expectEqualStrings("songs/voltage_riot.slab", project_path);
    try std.testing.expect(chosen);
    try std.testing.expect(std.mem.endsWith(u8, storage.projectDir(), "songs/voltage_riot.slab"));

    // The edit before it stays in the riot.
    const edit = (try stepHistory(alloc, &history, try alloc.dupe(u8, "riot edited"), &project_path, &chosen, false)).?;
    defer edit.deinit(alloc);
    try std.testing.expectEqualStrings("songs/voltage_riot.slab", project_path);

    // Back past the first Open: untitled, nothing to resolve against.
    const first = (try stepHistory(alloc, &history, try alloc.dupe(u8, "riot"), &project_path, &chosen, false)).?;
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings(document_mod.SAVE_PATH, project_path);
    try std.testing.expect(!chosen);
    try std.testing.expectEqualStrings("", storage.projectDir());

    // ⇧⌘Z all the way: night_drive again.
    for (0..3) |_| {
        const e = (try stepHistory(alloc, &history, try alloc.dupe(u8, "x"), &project_path, &chosen, true)).?;
        e.deinit(alloc);
    }
    try std.testing.expectEqualStrings("demos/night_drive.slab", project_path);
    try std.testing.expect(chosen);
    try std.testing.expect(std.mem.endsWith(u8, storage.projectDir(), "demos/night_drive.slab"));
}

test "bounce: the selected clip lands on a new track below its source, the original muted" {
    const alloc = std.testing.allocator;
    const env = struct {
        extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern fn unsetenv(name: [*:0]const u8) c_int;
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [storage.MAX_PATH]u8 = undefined;
    var root_buf: [storage.MAX_PATH]u8 = undefined;
    const root = storage.absolute(&root_buf, try std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    var hb: [storage.MAX_PATH]u8 = undefined;
    _ = env.setenv("SLAB_HOME", (try std.fmt.bufPrintZ(&hb, "{s}/home", .{root})).ptr, 1);
    defer _ = env.unsetenv("SLAB_HOME");
    storage.setProject(null);

    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    document_mod.setPool(&pool);
    const src = try pool.loadFile("machines/sampler/assets/default.wav");

    const col = c.rl.Color{ .r = 10, .g = 20, .b = 30, .a = 255 };
    var tracks_buf: [MAX_TRACKS]track_mod.Track = undefined;
    var track_count: usize = 2;
    tracks_buf[0] = try track_mod.Track.init(alloc, "Bass", col, silent_machine);
    tracks_buf[1] = try track_mod.Track.init(alloc, "Keys", col, silent_machine);
    defer for (tracks_buf[0..track_count]) |*t| t.deinit(alloc);
    tracks_buf[0].setVolume(0.5);
    var picked = clip_mod.Clip.initAudio("hit", 0, 1, src);
    picked.audio.dur_sec = pool.get(src).?.seconds();
    picked.selected = true;
    try tracks_buf[0].addClip(alloc, picked);
    var other = clip_mod.Clip.initAudio("other", 0, 1, src);
    other.audio.dur_sec = pool.get(src).?.seconds();
    try tracks_buf[1].addClip(alloc, other);

    var transport = transport_mod.Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(engine_mod.Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = tracks_buf[0..track_count] };
    eng.publishRouting();
    var history: history_mod.History = .{};
    defer history.deinit(alloc);
    var status: StatusMessage = .{};
    const job = try alloc.create(BounceJob);
    defer alloc.destroy(job);
    job.* = .{};
    var sel_track: ?usize = 0;
    var sel_clip: ?clip_mod.ClipRef = null;
    var prev_clip: ?clip_mod.ClipRef = null;
    var dirty = false;

    try startBounce(alloc, eng, null, &pool, &transport, tracks_buf[0..track_count], .{}, job, &status, 0);
    try std.testing.expect(job.active);
    finishBouncePass(alloc, &history, &status, null, eng, &pool, &tracks_buf, &track_count, &transport, job, &sel_track, &sel_clip, &prev_clip, &dirty);
    try std.testing.expect(!job.active);

    try std.testing.expectEqual(@as(usize, 3), track_count);
    try std.testing.expectEqualStrings("Bass bounce", tracks_buf[1].name());
    try std.testing.expectEqualStrings("Keys", tracks_buf[2].name());
    try std.testing.expect(tracks_buf[0].clips.items[0].muted);
    try std.testing.expect(!tracks_buf[2].clips.items[0].muted);
    // The FX tap is before the fader: the bounce keeps its source's.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), tracks_buf[1].volume(), 1e-6);
    try std.testing.expect(!tracks_buf[1].play_selected and !tracks_buf[0].play_selected);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
    try std.testing.expect(dirty);

    // The clip: the hit as it played, from beat 0; mono, as AUTO writes
    // a file whose sides match.
    const b = &tracks_buf[1].clips.items[0];
    try std.testing.expect(b.isAudio() and b.selected);
    try std.testing.expectEqual(@as(f64, 0), b.start_beat);
    try std.testing.expect(b.length_beats >= 1);
    const out = pool.get(b.audio.source).?;
    try std.testing.expect(!out.sample.isStereo());
    try std.testing.expect(out.seconds() >= 0.5);
    const hit = pool.get(src).?.sample;
    var peak: f64 = 0;
    for (out.sample.data[0..1000]) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0);
    if (hit.sample_rate == 48_000) {
        for (0..1000) |i| try std.testing.expectApproxEqAbs(hit.data[i], out.sample.data[i], 1e-6);
    }
}

test "bounce provenance: a recipe stays fresh, goes stale with its source, re-bounces and thaws" {
    const alloc = std.testing.allocator;
    const env = struct {
        extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern fn unsetenv(name: [*:0]const u8) c_int;
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [storage.MAX_PATH]u8 = undefined;
    var root_buf: [storage.MAX_PATH]u8 = undefined;
    const root = storage.absolute(&root_buf, try std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    var hb: [storage.MAX_PATH]u8 = undefined;
    _ = env.setenv("SLAB_HOME", (try std.fmt.bufPrintZ(&hb, "{s}/home", .{root})).ptr, 1);
    defer _ = env.unsetenv("SLAB_HOME");
    storage.setProject(null);

    var pool = audio_pool_mod.AudioPool.init(alloc);
    defer pool.deinit();
    document_mod.setPool(&pool);
    const src = try pool.loadFile("machines/sampler/assets/default.wav");
    const col = c.rl.Color{ .r = 10, .g = 20, .b = 30, .a = 255 };
    var tracks_buf: [MAX_TRACKS]track_mod.Track = undefined;
    var track_count: usize = 1;
    tracks_buf[0] = try track_mod.Track.init(alloc, "Drums", col, silent_machine);
    defer for (tracks_buf[0..track_count]) |*t| t.deinit(alloc);
    var hit = clip_mod.Clip.initAudio("hit", 0, 1, src);
    hit.audio.dur_sec = pool.get(src).?.seconds();
    hit.selected = true;
    try tracks_buf[0].addClip(alloc, hit);
    const hit_uid = tracks_buf[0].clips.items[0].uid;

    var transport = transport_mod.Transport{};
    transport.sample_rate = 48_000;
    const eng = try alloc.create(engine_mod.Engine);
    defer alloc.destroy(eng);
    eng.* = .{ .transport = &transport, .tracks = tracks_buf[0..track_count] };
    eng.publishRouting();
    var history: history_mod.History = .{};
    defer history.deinit(alloc);
    var status: StatusMessage = .{};
    const job = try alloc.create(BounceJob);
    defer alloc.destroy(job);
    job.* = .{};
    var sel_track: ?usize = 0;
    var sel_clip: ?clip_mod.ClipRef = null;
    var prev_clip: ?clip_mod.ClipRef = null;
    var dirty = false;

    try startBounce(alloc, eng, null, &pool, &transport, tracks_buf[0..track_count], .{}, job, &status, 0);
    finishBouncePass(alloc, &history, &status, null, eng, &pool, &tracks_buf, &track_count, &transport, job, &sel_track, &sel_clip, &prev_clip, &dirty);
    var tracks = tracks_buf[0..track_count];
    const bounced = &tracks[1].clips.items[0];
    const r = bounced.recipe.?;
    try std.testing.expectEqualSlices(u32, &.{hit_uid}, r.ids());
    try std.testing.expect(r.hash != 0);
    recipe_mod.checkAll(alloc, tracks, &transport);
    try std.testing.expect(!tracks[1].clips.items[0].recipe.?.stale);

    // Saved and loaded, it keeps its id and recipe.
    {
        const bytes = try document_mod.serialize(alloc, tracks, &transport);
        defer alloc.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"recipe\":{\"clips\":[") != null);
    }

    // Moving the source makes it stale; moving it back, fresh again.
    tracks[0].clips.items[0].start_beat = 0.5;
    recipe_mod.checkAll(alloc, tracks, &transport);
    try std.testing.expect(tracks[1].clips.items[0].recipe.?.stale);
    tracks[0].clips.items[0].start_beat = 0;
    recipe_mod.checkAll(alloc, tracks, &transport);
    try std.testing.expect(!tracks[1].clips.items[0].recipe.?.stale);

    // Re-bounce after a change: the same clip, fresh, the original still muted.
    tracks[0].clips.items[0].audio.gain = 0.5;
    recipe_mod.checkAll(alloc, tracks, &transport);
    try std.testing.expect(tracks[1].clips.items[0].recipe.?.stale);
    sel_clip = .{ .track = 1, .clip = 0 };
    {
        const fr = focusedRecipe(tracks, sel_clip).?;
        _ = arrangement.clearSelection(tracks, &sel_clip);
        for (fr.recipe.ids()) |id| {
            const f = recipe_mod.find(tracks, id).?;
            tracks[f.track].clips.items[f.clip].selected = true;
        }
        try startBounce(alloc, eng, null, &pool, &transport, tracks, .{ .tap = fr.recipe.tap, .originals = 1 }, job, &status, tracks[1].clips.items[0].uid);
    }
    finishBouncePass(alloc, &history, &status, null, eng, &pool, &tracks_buf, &track_count, &transport, job, &sel_track, &sel_clip, &prev_clip, &dirty);
    tracks = tracks_buf[0..track_count];
    try std.testing.expectEqual(@as(usize, 2), track_count);
    try std.testing.expectEqual(@as(usize, 1), tracks[1].clips.items.len);
    try std.testing.expect(!tracks[1].clips.items[0].recipe.?.stale);
    try std.testing.expect(tracks[0].clips.items[0].muted);
    const out = pool.get(tracks[1].clips.items[0].audio.source).?;
    const hit_data = pool.get(src).?.sample.data;
    for (0..500) |i| try std.testing.expectApproxEqAbs(hit_data[i] * 0.5, out.sample.data[i], 1e-6);

    // Thaw: the original plays again and the bounce is gone.
    sel_clip = .{ .track = 1, .clip = 0 };
    try thawBounce(alloc, &history, &status, tracks, &transport, &sel_clip, &dirty);
    try std.testing.expect(!tracks[0].clips.items[0].muted);
    try std.testing.expectEqual(@as(usize, 0), tracks[1].clips.items.len);
    try std.testing.expectEqual(@as(usize, 3), history.undo_stack.items.len);
}

test "automation recording writes a thinned pass over the span it covered" {
    const alloc = std.testing.allocator;
    var history: history_mod.History = .{};
    defer history.deinit(alloc);
    var transport: transport_mod.Transport = .{};
    transport.sample_rate = 48_000;
    var tracks = [_]track_mod.Track{try track_mod.Track.init(alloc, "t", .{ .r = 0, .g = 0, .b = 0, .a = 255 }, silent_machine)};
    defer tracks[0].deinit(alloc);
    // An existing lane: points inside the pass get replaced, the one after stays.
    const lane = try tracks[0].laneFor(alloc, automation.Target.volume(), false);
    _ = try lane.insert(alloc, .{ .beat = 1.5, .value = 0.9 });
    _ = try lane.insert(alloc, .{ .beat = 10, .value = 0.2 });

    const rec = try alloc.create(AutoRecorder);
    defer alloc.destroy(rec);
    rec.* = .{};
    // A hand holds the fader and rides it linearly from 0.2 to 0.6 over beats 1..3.
    var beat: f64 = 1;
    while (beat <= 3.0001) : (beat += 0.05) {
        transport.seekToSample(transport.beatsToSamples(beat));
        tracks[0].touch_vol = true;
        tracks[0].setVolume(@floatCast((0.2 + 0.2 * (beat - 1)) * 1.25));
        _ = rec.tick(alloc, &history, &tracks, &transport, true);
    }
    _ = rec.tick(alloc, &history, &tracks, &transport, true); // released
    try std.testing.expect(!rec.active);
    const pts = tracks[0].findLane(automation.Target.volume()).?.points.items;
    // A straight ride thins to its two ends; 0.9 at 1.5 is gone, 10 stays.
    try std.testing.expectEqual(@as(usize, 3), pts.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), pts[0].beat, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), pts[1].value, 1e-3);
    try std.testing.expectEqual(@as(f64, 10), pts[2].beat);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
}
