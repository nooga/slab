//! Slab — workbench shell.
//!
//! Ableton-12-ish tiled layout: left browser | arrangement | machine bay.

const std = @import("std");
const c = @import("c.zig");

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
const describe_mod = @import("describe.zig");
const history_mod = @import("history.zig");
const automation = @import("automation.zig");
const recorder_mod = @import("recorder.zig");
const native_dialog = @import("native_dialog.zig");

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
const render_dialog = @import("ui/render_dialog.zig");

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
    _ = @import("meter_gen.zig");
    _ = @import("automation.zig");
    _ = @import("ui/automation_lane.zig");
}

const MAX_TRACKS: usize = 16;
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

/// An in-flight offline bounce running on a worker thread. The UI thread
/// polls `progress`/`done` to draw the progress bar and finalizes the WAV
/// once the worker signals completion.
const RenderJob = struct {
    active: bool = false,
    thread: ?std.Thread = null,
    buf: []f32 = &.{},
    path: []u8 = &.{},
    total_frames: usize = 0,
    start_sample: u64 = 0,
    sample_rate: u32 = 48_000,
    start_ns: i128 = 0,
    progress: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn renderWorker(engine: *engine_mod.Engine, job: *RenderJob) void {
    engine.renderOffline(job.buf, job.total_frames, job.start_sample, &job.progress, &job.cancel);
    job.done.store(true, .release);
}

fn nowNs() i128 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @divTrunc(@as(i128, @intCast(std.c.mach_absolute_time())) * @as(i128, @intCast(info.numer)), @as(i128, @intCast(info.denom)));
}

const RenameKind = enum { none, track, clip, preset_save, preset_rename };

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
/// out.json` dumps every machine's params (docs/19).
const Cli = struct {
    project: ?[]const u8 = null,
    render: ?[]const u8 = null,
    describe: ?[]const u8 = null,
    gallery: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var cli: Cli = .{};
    {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        _ = args.next();
        while (args.next()) |a_z| {
            const a: []const u8 = a_z;
            if (std.mem.eql(u8, a, "--render")) {
                cli.render = args.next() orelse return error.MissingRenderPath;
            } else if (std.mem.eql(u8, a, "--describe")) {
                cli.describe = args.next() orelse return error.MissingDescribePath;
            } else if (std.mem.eql(u8, a, "--gallery")) {
                cli.gallery = true;
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
    if (cli.render) |out| return renderHeadless(alloc, cli.project orelse return error.MissingProject, out);

    c.rl.SetConfigFlags(c.rl.FLAG_WINDOW_RESIZABLE | c.rl.FLAG_VSYNC_HINT | c.rl.FLAG_WINDOW_HIGHDPI);
    c.rl.InitWindow(1400, 860, "slab");
    defer c.rl.CloseWindow();
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

    var engine = engine_mod.Engine{
        .transport = &transport,
        .tracks = tracks_buf[0..track_count],
        .master = &master,
        .meter_state = &meter_state,
    };

    // ── Audio device ─────────────────────────────────────────────────
    var audio: audio_mod.Audio = undefined;
    try audio.init();
    defer {
        audio.setRender(null, null);
        audio.deinit();
    }
    audio.setRender(&engine, engine_mod.Engine.renderCallback);

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
    var shot_frame: u32 = 0;
    var clipboard: EditClipboard = .{};
    defer clipboard.deinit(alloc);
    var status: StatusMessage = .{};
    var edit_snap: snap_mod.Setting = .note_16;
    var rename: RenameState = .{};
    var render_dlg: render_dialog.State = .{};
    var render_job: RenderJob = .{};

    if (cli.project) |path| {
        splash.bootFrame(ui, screenRect(), "LOADING PROJECT", 1);
        if (document_mod.readFile(alloc, path)) |data| {
            defer alloc.free(data);
            var boot_tracks = tracks_buf[0..track_count];
            applyProjectBytes(alloc, data, &reg, &tracks_buf, &track_count, &boot_tracks, &transport, &engine, &audio, &selected_track, &selected_clip, &prev_selected_clip) catch |err| {
                std.log.err("open {s} failed: {s}", .{ path, @errorName(err) });
            };
            replaceProjectPath(alloc, &project_path, try alloc.dupe(u8, path));
            project_path_chosen = true;
            status.set("Loaded {s}", .{basename(project_path)});
        } else |err| std.log.err("open {s} failed: {s}", .{ path, @errorName(err) });
    }

    splash.finishBoot();
    while (!c.rl.WindowShouldClose()) {
        const sw: f32 = @floatFromInt(c.rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(c.rl.GetScreenHeight());
        ui.beginFrame();
        pane.beginFrame();
        const m = pane.Mouse.fromInput(&ui.raw_in);
        menu.beginFrame(ui, @intFromFloat(sw), @intFromFloat(sh));
        // One owner of the pointer at a time: a legacy menu, modal or drag
        // hides input from the new Ui, and a new-Ui drag hides it from the
        // legacy panes.
        if (menu.active() or render_dlg.active or pane.hasActiveDrag()) ui.suppressInput();

        // While a menu is open it's modal for the mouse: panes get a
        // neutralized mouse (no hover/clicks fall through), the menu keeps
        // handling input off the raw frame mouse captured in beginFrame.
        // A new-Ui widget that owns or hovers the pointer (a seam, a toolbar
        // tile) hides it from the legacy panes, so one press never lands in
        // both UIs.
        const pane_m = if (menu.active() or render_dlg.active or ui.active != 0 or ui.hot != 0) pane.neutral() else m;


        layout.splitters(ui, sw, sh);

        var rects = layout.compute(sw, sh);
        var tracks = tracks_buf[0..track_count];
        if (!layout.clip_editor_visible and focus == .piano_roll) focus = .arrangement;
        if (pane_m.left_pressed) focus = focusFromPoint(rects, pane_m, layout.clip_editor_visible);

        if (render_dlg.active) {
            // Modal: only Esc/Enter act, handled after the dialog draws below.
        } else if (menu.active()) {
            // An open menu owns the keyboard (arrows, enter, esc).
        } else if (rename.active()) {
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
            handleSnapKeys(&edit_snap, &status);
            try handleFocusedEditCommands(alloc, &history, &clipboard, &status, focus, edit_snap, tracks, &transport, &selected_track, &selected_clip, &rename, &dirty);
            try handleFocusedDelete(alloc, &history, &status, focus, tracks, &transport, &selected_clip, &dirty);
            if (commandModifierDown() and c.rl.IsKeyPressed(c.rl.KEY_R)) render_dlg.active = true;
            if (c.rl.IsKeyPressed(c.rl.KEY_SPACE)) transport.toggle();
            if (c.rl.IsKeyPressed(c.rl.KEY_HOME)) transport.rewind();
            if (c.rl.IsKeyPressed(c.rl.KEY_TAB)) layout.clip_editor_visible = !layout.clip_editor_visible;
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

        const tres = transport_bar.draw(ui, uiRect(rects.top_bar), .{
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
        });
        if (tres.render_audio) render_dlg.active = true;
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

        // (Side browser removed — machines are added via the "+" in the
        // machine-bay titlebar; see mbres.add_machine below.)

        // Automation (docs/22): sticky overrides end when the transport
        // starts; every machine control shows its lane's value at the
        // playhead before any panel draws.
        const playing_now = transport.isPlaying();
        if (playing_now and !auto_was_playing) clearAutomationOverrides(tracks);
        auto_was_playing = playing_now;
        syncAutomationUi(tracks, transport.beats());

        const ares = arrangement.draw(ui, rects.arrangement, tracks, &master, &device_sel, &audio_pool, alloc, &selected_track, &selected_clip, &transport, &meter_state, edit_snap, clipboard.mode == .clips, arrangementRenameTarget(&rename), &recorder, pane_m);
        if (ares.rename_clip) |ref| beginRenameClip(&rename, tracks, ref);
        if (ares.rename_track) |ti| beginRenameTrack(&rename, tracks, ti);
        if (ares.rename_rect) |rr| rename.rect = rr;
        if (ares.command == .import_audio) {
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
        if (ares.add_track and track_count < MAX_TRACKS) {
            audio.stop();
            defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});

            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "Track {d}", .{track_count + 1}) catch "Track";
            tracks_buf[track_count] = try track_mod.Track.init(
                alloc,
                name,
                trackColor(track_count),
                silent_machine,
            );
            selected_track = track_count;
            selected_clip = null;
            track_count += 1;
            tracks = tracks_buf[0..track_count];
            engine.tracks = tracks;
            dirty = true;
            status.set("Added track", .{});
        }
        const selection_changed = !clipRefEq(selected_clip, prev_selected_clip);
        if (selection_changed and selected_clip != null) {
            layout.clip_editor_visible = true;
            rects = layout.compute(sw, sh);
        }
        if (layout.clip_editor_visible) {
            const cres = if (selectedClipIsAudio(tracks, selected_clip))
                audio_clip_editor.draw(ui, rects.clip_editor, tracks, &audio_pool, selected_clip, transport.bpm(), pane_m)
            else
                clip_editor.draw(ui, rects.clip_editor, tracks, alloc, selected_clip, meter_state.liveMap(), edit_snap, clipboard.mode == .notes, pane_m);
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
                };
            },
            .master => {
                bay_dev = &master;
                bay_is_bus = true;
            },
        }

        const mbres = machine_bay.draw(ui, rects.machine_bay, bay_dev, bay_idx, bay_is_bus, layout.machine_bay_collapsed, &reg);
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
            beginPresetSave(&rename, dev, refEffect(ref), mbres.preset_anchor);
        };
        if (mbres.preset_rename_ref) |ref| if (mbres.preset_rename_index) |idx| if (bay_dev) |dev| {
            const eff = refEffect(ref);
            if (deviceMachineOf(dev, eff)) |mach| {
                var cur: []const u8 = "";
                if (mach.preset_name) |nf| cur = std.mem.span(nf(mach.state, idx));
                beginPresetRename(&rename, dev, eff, idx, cur, mbres.preset_anchor);
            }
        };

        if (serviceAutomationRequests(alloc, &history, tracks, &transport, &selected_track, &status)) dirty = true;

        try runRename(ui, alloc, &history, &rename, tracks, &transport, &dirty, &status);

        // Render Audio dialog (modal: input behind it is suppressed above).
        var render_action: render_dialog.Result = .none;
        if (render_dlg.active) {
            const loop_available = transport.loopEnabled() and transport.loopEndBeats() > transport.loopStartBeats();
            const prog: ?render_dialog.Progress = if (render_job.active) renderProgress(&render_job) else null;
            render_action = render_dialog.draw(ui, uiRect(pane.rect(0, 0, sw, sh)), &render_dlg, loop_available, prog);
        }

        splash.overlay(ui, screenRect());
        menu.draw(ui);
        ui.render();

        pane.applyCursor(ui);
        ui.endFrame();

        for (tracks) |*t| t.publishSnapshot(&audio_pool);

        if (shot_frame == 0 and std.c.getenv("SLAB_SHOT_PLAY") != null) transport.play();
        if (shot_frame == 0 and std.c.getenv("SLAB_SHOT_EXPR") != null) clip_editor.toggleExpressionMode();
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
        devScreenshot(&shot_frame);
        c.rl.EndDrawing();

        switch (render_action) {
            .none => {},
            .cancel => {
                if (render_job.active) {
                    render_job.cancel.store(true, .monotonic); // worker stops; finalize below
                } else {
                    render_dlg.active = false;
                }
            },
            .render => {
                if (!render_job.active) {
                    startRender(alloc, &engine, &audio, &transport, tracks, render_dlg, project_path, &render_job, &status) catch |err| {
                        std.log.err("render start failed: {s}", .{@errorName(err)});
                        status.set("Render failed", .{});
                        render_dlg.active = false;
                    };
                }
            },
        }

        // Finalize a worker render once it signals done (or after a cancel).
        if (render_job.active and render_job.done.load(.acquire)) {
            finishRender(alloc, &audio, &render_job, &status);
            render_dlg.active = false;
        }

        // Finalize a recording once the writer thread has flushed and closed
        // the take file: turn it into a pooled source + clip on the armed track.
        if (rec_finishing and recorder.isFinished()) {
            const res = recorder.finish();
            placeRecordedClip(alloc, &audio_pool, &history, &status, tracks, &transport, &recorder, &audio, res, rec_track, &selected_track, &selected_clip, &dirty) catch |err| {
                std.log.err("record finalize failed: {s}", .{@errorName(err)});
                status.set("Recording finalize failed", .{});
            };
            rec_finishing = false;
            rec_track = null;
        }
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
        if (tres.open_project) {
            try openProject(
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
            );
        }
        prev_selected_clip = selected_clip;
    }

    // Window closing mid-render: stop the worker and free its buffers before
    // the engine/allocator tear down (the worker holds pointers into both).
    if (render_job.active) {
        render_job.cancel.store(true, .monotonic);
        if (render_job.thread) |t| t.join();
        alloc.free(render_job.buf);
        alloc.free(render_job.path);
        render_job = .{};
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

    const path = (try native_dialog.openAudioFile(alloc)) orelse return; // cancelled
    defer alloc.free(path);

    const source = try pool.loadFile(path);
    const src = pool.get(source) orelse return;

    const bpm: f64 = transport.bpm();
    const dur_sec = src.seconds();
    const len_beats = @max(0.25, dur_sec * bpm / 60.0);
    const raw_start = target_beat orelse transport.beats();
    const start = snap_mod.snapDownPositive(edit_snap, @max(0.0, raw_start), false);

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
    const bpm: f64 = transport.bpm();
    const len_beats = @max(0.25, dur_sec * bpm / 60.0);

    // Latency-compensate: captured audio arrives a round-trip late, so place
    // the clip earlier by that much so it lands where the sound occurred.
    const latency: u64 = audio.roundTripLatencyFrames();
    const adj_sample = if (res.start_sample > latency) res.start_sample - latency else 0;
    const start = transport.samplesToBeats(adj_sample);

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
        try openProject(alloc, history, tracks_buf, track_count, tracks, transport, engine, audio, reg, selected_track, selected_clip, prev_selected_clip, project_path, project_path_chosen, dirty, status);
        return true;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_Z)) {
        const current = try document_mod.serialize(alloc, tracks.*, transport);
        const shifted = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        const target = if (shifted)
            try history.redo(alloc, current)
        else
            try history.undo(alloc, current);
        if (target) |snapshot| {
            defer alloc.free(snapshot);
            applyProjectBytes(alloc, snapshot, reg, tracks_buf, track_count, tracks, transport, engine, audio, selected_track, selected_clip, prev_selected_clip) catch |err| {
                std.log.err("history apply failed: {s}", .{@errorName(err)});
            };
            dirty.* = true;
            if (shifted) {
                status.set("Redone", .{});
            } else {
                status.set("Undone", .{});
            }
        }
        return true;
    }

    return false;
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

    const snapshot = try document_mod.serialize(alloc, tracks, transport);
    defer alloc.free(snapshot);
    document_mod.writeFile(alloc, project_path.*, snapshot) catch |err| {
        std.log.err("save failed: {s}", .{@errorName(err)});
        status.set("Save failed", .{});
        return;
    };
    project_path_chosen.* = true;
    dirty.* = false;
    status.set("Saved {s}", .{basename(project_path.*)});
    std.log.info("saved {s}", .{project_path.*});
}

/// Begin an offline project bounce → 24-bit stereo WAV. Resolves the range,
/// prompts for a path, stops the device, and spawns a worker thread that
/// renders into `job.buf`. The UI thread polls progress and calls
/// finishRender once the worker is done. The device stays stopped for the
/// (brief, faster-than-realtime) duration because the offline render shares
/// the engine's scratch/machine state with the live callback.
fn startRender(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    audio: *audio_mod.Audio,
    transport: *transport_mod.Transport,
    tracks: []track_mod.Track,
    dlg: render_dialog.State,
    project_path: []const u8,
    job: *RenderJob,
    status: *StatusMessage,
) !void {
    const sr: u64 = transport.sample_rate;

    // Resolve the render range in samples.
    var start: u64 = 0;
    var end: u64 = 0;
    const loop_available = transport.loopEnabled() and transport.loopEndBeats() > transport.loopStartBeats();
    if (dlg.rangeMode() == .loop and loop_available) {
        start = transport.beatsToSamples(transport.loopStartBeats());
        end = transport.beatsToSamples(transport.loopEndBeats());
    } else {
        var last_beat: f64 = 0;
        for (tracks) |*t| {
            for (t.clips.items) |*clip| last_beat = @max(last_beat, clip.endBeat());
        }
        end = transport.beatsToSamples(last_beat);
    }
    if (end <= start) {
        status.set("Nothing to render", .{});
        return;
    }

    const tail_frames: u64 = @intFromFloat(@max(0.0, dlg.tail_sec) * @as(f32, @floatFromInt(sr)));
    const total_frames: usize = @intCast((end - start) + tail_frames);

    // Native save panel — default name derived from the project file.
    var name_buf: [128]u8 = undefined;
    const default_name = defaultBounceName(&name_buf, project_path);
    const path = (try native_dialog.saveAudioFile(alloc, default_name)) orelse return; // cancelled

    // Render buffer (interleaved stereo). ~46 MB per minute of stereo f32.
    const buf = alloc.alloc(f32, total_frames * audio_mod.CHANNELS) catch |err| {
        alloc.free(path);
        return err;
    };

    job.* = .{
        .active = true,
        .buf = buf,
        .path = path,
        .total_frames = total_frames,
        .start_sample = start,
        .sample_rate = @intCast(sr),
        .start_ns = nowNs(),
    };

    // The device must be stopped while the worker renders.
    audio.stop();
    job.thread = std.Thread.spawn(.{}, renderWorker, .{ engine, job }) catch |err| {
        // Spawn failed — fall back to a synchronous render so we still produce output.
        engine.renderOffline(buf, total_frames, start, &job.progress, &job.cancel);
        job.done.store(true, .release);
        std.log.warn("render thread spawn failed ({s}); ran synchronously", .{@errorName(err)});
        return;
    };
}

/// Build the live Progress telemetry from a running job.
fn renderProgress(job: *RenderJob) render_dialog.Progress {
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

/// Join the worker, restart the device, and (unless cancelled) encode + write
/// the WAV. Frees the job's buffers and clears it.
fn finishRender(alloc: std.mem.Allocator, audio: *audio_mod.Audio, job: *RenderJob, status: *StatusMessage) void {
    if (job.thread) |t| t.join();
    job.thread = null;
    audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});

    const cancelled = job.cancel.load(.monotonic);
    if (!cancelled) {
        if (wav_mod.encodeStereo24(alloc, job.buf, job.sample_rate)) |wav_bytes| {
            defer alloc.free(wav_bytes);
            if (document_mod.writeFile(alloc, job.path, wav_bytes)) |_| {
                const secs = @as(f64, @floatFromInt(job.total_frames)) / @as(f64, @floatFromInt(job.sample_rate));
                status.set("Rendered {s} ({d:.1}s)", .{ basename(job.path), secs });
                std.log.info("rendered {s} ({d} frames)", .{ job.path, job.total_frames });
            } else |err| {
                std.log.err("wav write failed: {s}", .{@errorName(err)});
                status.set("Render failed (write)", .{});
            }
        } else |err| {
            std.log.err("wav encode failed: {s}", .{@errorName(err)});
            status.set("Render failed (encode)", .{});
        }
    } else {
        status.set("Render cancelled", .{});
    }

    alloc.free(job.buf);
    alloc.free(job.path);
    job.* = .{};
}

/// Build a default ".wav" file name from the project path basename.
fn defaultBounceName(buf: []u8, project_path: []const u8) []const u8 {
    const base = basename(project_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
    if (stem.len == 0) return "bounce.wav";
    return std.fmt.bufPrint(buf, "{s}.wav", .{stem}) catch "bounce.wav";
}

fn openProject(
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
    const chosen = native_dialog.openProject(alloc) catch |err| {
        std.log.err("open dialog failed: {s}", .{@errorName(err)});
        return;
    };
    const path = chosen orelse return;
    defer alloc.free(path);

    const before = try document_mod.serialize(alloc, tracks.*, transport);
    errdefer alloc.free(before);
    const data = document_mod.readFile(alloc, path) catch |err| {
        std.log.err("load failed: {s}", .{@errorName(err)});
        return;
    };
    defer alloc.free(data);
    applyProjectBytes(alloc, data, reg, tracks_buf, track_count, tracks, transport, engine, audio, selected_track, selected_clip, prev_selected_clip) catch |err| {
        std.log.err("load failed: {s}", .{@errorName(err)});
        status.set("Load failed", .{});
        return;
    };
    try history.pushUndo(alloc, before);
    replaceProjectPath(alloc, project_path, try alloc.dupe(u8, path));
    project_path_chosen.* = true;
    dirty.* = false;
    status.set("Loaded {s}", .{basename(project_path.*)});
    std.log.info("loaded {s}", .{project_path.*});
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

/// Default colour for the n-th new track (the track palette, cycled).
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

/// Bounce `project` to `out` (24-bit WAV): every clip plus a 3 s tail,
/// through the same engine and master soft clip as a DAW render.
fn renderHeadless(alloc: std.mem.Allocator, project: []const u8, out: []const u8) !void {
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
    };
    var last_beat: f64 = 0;
    for (tracks) |*t| for (t.clips.items) |*clip| {
        last_beat = @max(last_beat, clip.endBeat());
    };
    const frames: usize = @intCast(transport.beatsToSamples(last_beat) + 3 * audio_mod.SAMPLE_RATE);
    const buf = try alloc.alloc(f32, frames * audio_mod.CHANNELS);
    defer alloc.free(buf);
    const t0 = nowNs();
    engine.renderOffline(buf, frames, 0, null, null);
    const secs = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(audio_mod.SAMPLE_RATE));
    const took = @as(f64, @floatFromInt(nowNs() - t0)) / 1e9;

    var peak: f32 = 0;
    var sq: f64 = 0;
    var over: usize = 0;
    for (buf) |v| {
        peak = @max(peak, @abs(v));
        sq += @as(f64, v) * v;
        if (@abs(v) >= 0.999) over += 1;
    }
    const rms = @sqrt(sq / @as(f64, @floatFromInt(buf.len)));
    const bytes = try wav_mod.encodeStereo24(alloc, buf, audio_mod.SAMPLE_RATE);
    defer alloc.free(bytes);
    try document_mod.writeFile(alloc, out, bytes);
    std.debug.print("rendered {s} -> {s}: {d:.1} s in {d:.2} s ({d:.1}x real time), peak {d:.1} dBFS, rms {d:.1} dBFS, {d} samples at the rail\n", .{
        project, out, secs, took, secs / took, 20 * std.math.log10(@max(peak, 1e-9)), 20 * std.math.log10(@max(rms, 1e-12)), over,
    });
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
/// SLAB_SHOT_EXPR=1 starts the piano roll in expression mode.
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

fn envU32(name: [*:0]const u8) ?u32 {
    const v = std.c.getenv(name) orelse return null;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch null;
}

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

fn beginPresetSave(rename: *RenameState, dev: *track_mod.Track, effect: ?usize, anchor: c.rl.Rectangle) void {
    rename.* = .{ .kind = .preset_save, .device_track = dev, .device_effect = effect };
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
        .preset_save, .preset_rename => {
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
        .preset_save, .preset_rename, .none => {},
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
                status.set("Saved preset {s}", .{name});
            } else status.set("Preset save failed (name in use?)", .{});
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
        .preset_save, .preset_rename, .none => .{},
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
        .split_at_playhead => {
            changed = if (focus == .arrangement) arrangement.splitSelectedClipsAt(tracks, alloc, selected_clip, transport.beats(), transport.bpm()) else false;
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
        .none, .copy, .select_all, .clear_selection, .rename, .file_open, .file_save, .file_save_as, .render_audio, .import_audio => {},
    }

    if (changed) {
        try history.pushUndo(alloc, before);
        dirty.* = true;
    } else {
        alloc.free(before);
        if (command != .paste) status.set("No selection", .{});
    }
}

fn editMutationKeyPressed(focus: FocusPane) bool {
    if (commandModifierDown()) return false;
    if (c.rl.IsKeyPressed(c.rl.KEY_D) or arrowKeyPressed()) return true;
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
