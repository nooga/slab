//! Slab — workbench shell.
//!
//! Ableton-12-ish tiled layout: left browser | arrangement | machine bay.

const std = @import("std");
const c = @import("c.zig");

const audio_mod = @import("audio.zig");
const transport_mod = @import("transport.zig");
const engine_mod = @import("engine.zig");
const track_mod = @import("track.zig");
const clip_mod = @import("clip.zig");
const registry_mod = @import("machine_registry.zig");
const fy_host_mod = @import("fy_host.zig");
const document_mod = @import("document.zig");
const history_mod = @import("history.zig");
const native_dialog = @import("native_dialog.zig");

const theme = @import("ui/theme.zig");
const widgets = @import("ui/widgets.zig");
const fonts = @import("ui/fonts.zig");
const layout_mod = @import("ui/layout.zig");
const top_bar = @import("ui/top_bar.zig");
const snap_mod = @import("ui/snap.zig");
const browser = @import("ui/browser.zig");
const arrangement = @import("ui/arrangement.zig");
const clip_editor = @import("ui/clip_editor.zig");
const machine_bay = @import("ui/machine_bay.zig");

test {
    _ = @import("fy_host.zig");
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

const RenameKind = enum { none, track, clip };

const RenameState = struct {
    kind: RenameKind = .none,
    track: usize = 0,
    clip: usize = 0,
    buf: [track_mod.MAX_NAME + 1:0]u8 = [_:0]u8{0} ** (track_mod.MAX_NAME + 1),
    len: usize = 0,
    cursor: usize = 0,
    sel_anchor: ?usize = null,
    rect: c.rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    mouse_dragging: bool = false,

    fn active(self: *const RenameState) bool {
        return self.kind != .none;
    }

    fn text(self: *const RenameState) [*:0]const u8 {
        return @ptrCast(&self.buf[0]);
    }
};

// Silent placeholder machine — writes zeros, draws nothing.
fn silentRender(_: *anyopaque, _: *const @import("machine.zig").MachineCtx, l: []f32, r: []f32) void {
    @memset(l, 0);
    @memset(r, 0);
}
fn silentPanel(_: *anyopaque, _: c.rl.Rectangle, _: widgets.Mouse) void {}
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
    voices: u8,
) !void {
    const normalized = normalizePolyVoices(voices);
    audio.stop();
    defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});

    const mach = blk: {
        fy_host_mod.lockCallbacks();
        defer fy_host_mod.unlockCallbacks();
        break :blk try reg.instantiateWithPolyphony(reg_idx, normalized);
    };
    mach.reset(mach.state);
    t.replaceMachine(alloc, mach);
    t.machine_idx = @intCast(reg_idx);
    t.poly_voices = normalized;
}

fn addEffectToTrack(
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
    try t.addEffect(mach, @intCast(reg_idx));
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

fn applyPresetTo(t: *track_mod.Track, preset_idx: u8) void {
    if (t.machine.apply_preset) |apply| apply(t.machine.state, preset_idx);
}

fn normalizePolyVoices(v: u8) u8 {
    if (v >= 16) return 16;
    if (v >= 8) return 8;
    if (v >= 4) return 4;
    return 1;
}

fn polyStatusLabel(v: u8) []const u8 {
    return switch (normalizePolyVoices(v)) {
        4 => "Poly 4",
        8 => "Poly 8",
        16 => "Poly 16",
        else => "Mono",
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    c.rl.SetConfigFlags(c.rl.FLAG_WINDOW_RESIZABLE | c.rl.FLAG_VSYNC_HINT);
    c.rl.InitWindow(1400, 860, "slab");
    defer c.rl.CloseWindow();
    c.rl.SetTargetFPS(120);
    c.rl.SetExitKey(c.rl.KEY_NULL);

    fonts.init();
    defer fonts.deinit();
    defer clip_editor.deinit(alloc);

    // ── Machine registry (each entry owns its own Fy instance) ───────
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();

    try reg.load("sine", "machines/sine_v1/sine.fy", "sine-audio", "sine-ui", 108);
    try reg.load("square", "machines/square_v1/square.fy", "square-audio", "square-ui", 108);
    try reg.load("mono1", "machines/mono1/mono1.fy", "mono1-audio", "mono1-ui", 580);
    try reg.load("drum1", "machines/drum1/drum1.fy", "drum1-audio", "drum1-ui", 587);
    try reg.load("chorus", "machines/chorus1/chorus1.fy", "chorus1-audio", "chorus1-ui", 320);
    try reg.load("comp1", "machines/comp1/comp1.fy", "comp1-audio", "comp1-ui", 375);
    try reg.load("fm1", "machines/fm1/fm1.fy", "fm1-audio", "fm1-ui", 428);
    try reg.load("delay1", "machines/delay1/delay1.fy", "delay1-audio", "delay1-ui", 375);
    try reg.load("verb1", "machines/verb1/verb1.fy", "verb1-audio", "verb1-ui", 270);
    try reg.loadRawFixture("raw-osc");
    try reg.loadRawFixture("raw-silence");
    try reg.loadRawFixture("raw-sat");
    try reg.loadRawManifest("machines/raw_ms20/raw-ms20.manifest");

    // Hot-patch server on the sine machine's host.
    defer fy_host_mod.deleteFilePosix(".fy-port");
    if (reg.entries[0].host) |host| {
        _ = host.startHotPatchServer() catch |err|
            std.log.warn("hot-patch: {}", .{err});
    }

    // ── Tracks — start with silent placeholder machines ──────────────
    var transport: transport_mod.Transport = .{};
    transport.sample_rate = audio_mod.SAMPLE_RATE;
    if (DEV_BOOT_AUDITION) {
        transport.setBpm(124);
        transport.setLoopBeats(0, 16);
        if (DEV_BOOT_AUTOPLAY) transport.play();
    }

    // Registry indices: 0 sine, 1 square, 2 mono1, 3 drum1, 4 chorus, 5 comp1, 6 fm1, 7 delay1, 8 verb1.
    const MONO1_REG: usize = 2;
    const CHORUS_REG: usize = 4;

    _ = MONO1_REG;
    _ = CHORUS_REG;

    var tracks_buf: [MAX_TRACKS]track_mod.Track = undefined;
    var track_count: usize = 1;
    tracks_buf[0] = try track_mod.Track.init(alloc, "Track 1", theme.track_colors[0], silent_machine);
    defer for (tracks_buf[0..track_count]) |*t| t.deinit(alloc);

    var engine = engine_mod.Engine{
        .transport = &transport,
        .tracks = tracks_buf[0..track_count],
    };

    // ── Audio device ─────────────────────────────────────────────────
    var audio: audio_mod.Audio = undefined;
    try audio.init();
    defer {
        audio.setRender(null, null);
        audio.deinit();
    }
    audio.setRender(&engine, engine_mod.Engine.renderCallback);

    // ── UI state ─────────────────────────────────────────────────────
    var layout: layout_mod.State = .{};
    layout.clip_editor_visible = true;
    var selected_clip: ?clip_mod.ClipRef = null;
    var prev_selected_clip: ?clip_mod.ClipRef = selected_clip;
    var selected_track: ?usize = 0;
    var history: history_mod.History = .{};
    defer history.deinit(alloc);
    var project_path = try alloc.dupe(u8, document_mod.SAVE_PATH);
    defer alloc.free(project_path);
    var project_path_chosen = false;
    var focus: FocusPane = .arrangement;
    var dirty = false;
    var clipboard: EditClipboard = .{};
    defer clipboard.deinit(alloc);
    var status: StatusMessage = .{};
    var edit_snap: snap_mod.Setting = .note_16;
    var rename: RenameState = .{};

    while (!c.rl.WindowShouldClose()) {
        const m = widgets.Mouse.sample();
        const sw: f32 = @floatFromInt(c.rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(c.rl.GetScreenHeight());
        widgets.beginFrame();

        layout.handleInput(sw, sh, m);

        var rects = layout.compute(sw, sh);
        var tracks = tracks_buf[0..track_count];
        if (!layout.clip_editor_visible and focus == .piano_roll) focus = .arrangement;
        if (m.left_pressed) focus = focusFromPoint(rects, m, layout.clip_editor_visible);

        if (rename.active()) {
            try updateRename(alloc, &history, &rename, tracks, &transport, &dirty, &status, m);
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
            if (c.rl.IsKeyPressed(c.rl.KEY_SPACE)) transport.toggle();
            if (c.rl.IsKeyPressed(c.rl.KEY_HOME)) transport.rewind();
            if (c.rl.IsKeyPressed(c.rl.KEY_TAB)) layout.clip_editor_visible = !layout.clip_editor_visible;
            handleUiScaleKeys();
        }

        c.rl.BeginDrawing();
        c.rl.ClearBackground(theme.bg);

        const tres = top_bar.draw(rects.top_bar, &transport, &edit_snap, m);

        // Browser — handles machine assignment to the selected track.
        const bres = browser.draw(rects.browser, layout.browser_collapsed, &reg, m);
        if (bres.toggled) layout.browser_collapsed = !layout.browser_collapsed;
        if (bres.assigned) |reg_idx| {
            if (selected_track) |ti| if (ti < tracks.len) {
                const entry = &reg.entries[reg_idx];
                if (entry.in_audio and entry.out_audio and !entry.in_notes) {
                    addEffectToTrack(&audio, &reg, &tracks[ti], reg_idx) catch |err| {
                        std.log.err("add effect failed: {s}", .{@errorName(err)});
                        status.set("Effect failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    dirty = true;
                    status.set("Added {s}", .{entry.nameSlice()});
                } else {
                    assignMachineToTrack(alloc, &audio, &reg, &tracks[ti], reg_idx, 1) catch |err| {
                        std.log.err("instantiate machine failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    dirty = true;
                    status.set("Assigned {s}", .{entry.nameSlice()});
                    // Rename track to the machine name.
                    const nm = entry.nameSlice();
                    const n = @min(nm.len, track_mod.MAX_NAME);
                    @memcpy(tracks[ti].name_buf[0..n], nm[0..n]);
                    tracks[ti].name_len = @intCast(n);
                }
            };
        }

        const ares = arrangement.draw(rects.arrangement, tracks, alloc, &selected_track, &selected_clip, &transport, edit_snap, clipboard.mode == .clips, arrangementRenameTarget(&rename), m);
        if (ares.rename_clip) |ref| beginRenameClip(&rename, tracks, ref);
        if (ares.rename_track) |ti| beginRenameTrack(&rename, tracks, ti);
        if (ares.rename_rect) |rr| rename.rect = rr;
        if (ares.command != .none) {
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
                theme.track_colors[track_count % theme.track_colors.len],
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
            const cres = clip_editor.draw(rects.clip_editor, tracks, alloc, selected_clip, edit_snap, clipboard.mode == .notes, m);
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
        const mbres = machine_bay.draw(rects.machine_bay, tracks, selected_track, layout.machine_bay_collapsed, m);
        if (mbres.minimize) layout.machine_bay_collapsed = !layout.machine_bay_collapsed;
        if (mbres.preset_index) |preset| {
            if (selected_track) |ti| if (ti < tracks.len) {
                if (tracks[ti].machine.apply_preset) |apply| {
                    pushHistorySnapshot(alloc, &history, tracks, &transport);
                    audio.stop();
                    defer audio.start() catch |err| std.log.err("audio restart failed: {s}", .{@errorName(err)});
                    apply(tracks[ti].machine.state, preset);
                    dirty = true;
                    status.set("Preset {s}", .{if (tracks[ti].machine.preset_name) |name| name(tracks[ti].machine.state, preset) else ""});
                }
            };
        }
        if (mbres.poly_voices) |voices| {
            if (selected_track) |ti| if (ti < tracks.len) {
                if (tracks[ti].machine_idx) |reg_idx| {
                    if (tracks[ti].poly_voices != voices) {
                        pushHistorySnapshot(alloc, &history, tracks, &transport);
                        assignMachineToTrack(alloc, &audio, &reg, &tracks[ti], reg_idx, voices) catch |err| {
                            std.log.err("polyphony change failed: {s}", .{@errorName(err)});
                            status.set("Polyphony failed: {s}", .{@errorName(err)});
                            continue;
                        };
                        dirty = true;
                        status.set("{s} {s}", .{ tracks[ti].name(), polyStatusLabel(voices) });
                    }
                }
            };
        }

        layout.drawSplitters(rects, m);
        drawStatusBar(rects.status_bar, &transport, selected_track, selected_clip, tracks, project_path, project_path_chosen, dirty, status.text(), focus, edit_snap);
        if (rename.active()) drawInlineRename(&rename);
        widgets.drawTooltip(sw, sh);
        widgets.drawContextMenu();
        widgets.applyCursor();

        for (tracks) |*t| t.publishSnapshot();

        c.rl.EndDrawing();
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

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
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
    for (tracks.*) |*t| t.publishSnapshot();
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
    renameSelectAll(rename);
}

fn beginRenameClip(rename: *RenameState, tracks: []track_mod.Track, ref: clip_mod.ClipRef) void {
    if (ref.track >= tracks.len) return;
    const t = &tracks[ref.track];
    if (ref.clip >= t.clips.items.len) return;
    rename.* = .{ .kind = .clip, .track = @intCast(ref.track), .clip = @intCast(ref.clip) };
    renameSetText(rename, t.clips.items[ref.clip].name());
    renameSelectAll(rename);
}

fn renameSetText(rename: *RenameState, text: []const u8) void {
    @memset(&rename.buf, 0);
    const n = @min(text.len, track_mod.MAX_NAME);
    @memcpy(rename.buf[0..n], text[0..n]);
    rename.len = n;
    rename.cursor = n;
    rename.sel_anchor = null;
}

fn renameSelectAll(rename: *RenameState) void {
    rename.sel_anchor = 0;
    rename.cursor = rename.len;
}

fn renameHasSelection(rename: *const RenameState) bool {
    if (rename.sel_anchor) |a| return a != rename.cursor;
    return false;
}

fn renameSelection(rename: *const RenameState) struct { start: usize, end: usize } {
    const a = rename.sel_anchor orelse return .{ .start = rename.cursor, .end = rename.cursor };
    return .{ .start = @min(a, rename.cursor), .end = @max(a, rename.cursor) };
}

fn renameDeleteSelection(rename: *RenameState) bool {
    const sel = renameSelection(rename);
    if (sel.start == sel.end) return false;
    const tail = rename.len - sel.end;
    var i: usize = 0;
    while (i < tail) : (i += 1) rename.buf[sel.start + i] = rename.buf[sel.end + i];
    rename.len -= sel.end - sel.start;
    rename.cursor = sel.start;
    rename.sel_anchor = null;
    @memset(rename.buf[rename.len..], 0);
    return true;
}

fn renameInsertText(rename: *RenameState, text: []const u8) void {
    _ = renameDeleteSelection(rename);
    const n = @min(text.len, track_mod.MAX_NAME - rename.len);
    if (n == 0) return;
    var i = rename.len;
    while (i > rename.cursor) {
        i -= 1;
        rename.buf[i + n] = rename.buf[i];
    }
    @memcpy(rename.buf[rename.cursor..][0..n], text[0..n]);
    rename.len += n;
    rename.cursor += n;
    rename.buf[rename.len] = 0;
    rename.sel_anchor = null;
}

fn renameDeleteBack(rename: *RenameState, word: bool) void {
    if (renameDeleteSelection(rename)) return;
    if (rename.cursor == 0) return;
    const start = if (word) wordLeft(rename.buf[0..rename.len], rename.cursor) else rename.cursor - 1;
    const count = rename.cursor - start;
    var i = start;
    while (i < rename.len - count) : (i += 1) rename.buf[i] = rename.buf[i + count];
    rename.len -= count;
    rename.cursor = start;
    @memset(rename.buf[rename.len..], 0);
}

fn renameDeleteForward(rename: *RenameState, word: bool) void {
    if (renameDeleteSelection(rename)) return;
    if (rename.cursor >= rename.len) return;
    const end = if (word) wordRight(rename.buf[0..rename.len], rename.cursor) else rename.cursor + 1;
    const count = end - rename.cursor;
    var i = rename.cursor;
    while (i < rename.len - count) : (i += 1) rename.buf[i] = rename.buf[i + count];
    rename.len -= count;
    @memset(rename.buf[rename.len..], 0);
}

fn renameMoveCursor(rename: *RenameState, next: usize, shift: bool) void {
    if (shift) {
        if (rename.sel_anchor == null) rename.sel_anchor = rename.cursor;
    } else {
        rename.sel_anchor = null;
    }
    rename.cursor = @min(next, rename.len);
}

fn wordLeft(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and text[i - 1] == ' ') i -= 1;
    while (i > 0 and text[i - 1] != ' ') i -= 1;
    return i;
}

fn wordRight(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i < text.len and text[i] != ' ') i += 1;
    while (i < text.len and text[i] == ' ') i += 1;
    return i;
}

fn renameHitTest(rename: *const RenameState, x: f32) usize {
    const local = x - rename.rect.x - 4;
    var best: usize = 0;
    var best_dist: f32 = 999999;
    var i: usize = 0;
    while (i <= rename.len) : (i += 1) {
        var tmp: [track_mod.MAX_NAME + 1:0]u8 = [_:0]u8{0} ** (track_mod.MAX_NAME + 1);
        @memcpy(tmp[0..i], rename.buf[0..i]);
        const px = widgets.measureTextF(@ptrCast(&tmp[0]), theme.fsBody());
        const dist = @abs(px - local);
        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
    }
    return best;
}

fn updateRename(
    alloc: std.mem.Allocator,
    history: *history_mod.History,
    rename: *RenameState,
    tracks: []track_mod.Track,
    transport: *transport_mod.Transport,
    dirty: *bool,
    status: *StatusMessage,
    m: widgets.Mouse,
) !void {
    if (!rename.active()) return;

    const cmd = commandModifierDown();
    const shift = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);

    if (widgets.contains(rename.rect, m.x, m.y)) widgets.requestCursor(c.rl.MOUSE_CURSOR_IBEAM, 4);
    if (m.left_pressed) {
        if (widgets.contains(rename.rect, m.x, m.y)) {
            if (m.double_clicked) {
                renameSelectAll(rename);
            } else {
                const pos = renameHitTest(rename, m.x);
                rename.cursor = pos;
                rename.sel_anchor = pos;
                rename.mouse_dragging = true;
            }
        } else {
            try commitRename(alloc, history, rename, tracks, transport, dirty, status);
            return;
        }
    }
    if (rename.mouse_dragging) {
        if (m.left_down) {
            rename.cursor = renameHitTest(rename, m.x);
        } else {
            rename.mouse_dragging = false;
            if (rename.sel_anchor) |a| {
                if (a == rename.cursor) rename.sel_anchor = null;
            }
        }
    }

    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_A)) {
        renameSelectAll(rename);
        return;
    }
    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_C)) {
        if (renameHasSelection(rename)) {
            const sel = renameSelection(rename);
            var tmp: [track_mod.MAX_NAME + 1:0]u8 = [_:0]u8{0} ** (track_mod.MAX_NAME + 1);
            const n = sel.end - sel.start;
            @memcpy(tmp[0..n], rename.buf[sel.start..sel.end]);
            c.rl.SetClipboardText(@ptrCast(&tmp[0]));
        }
        return;
    }
    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_X)) {
        if (renameHasSelection(rename)) {
            const sel = renameSelection(rename);
            var tmp: [track_mod.MAX_NAME + 1:0]u8 = [_:0]u8{0} ** (track_mod.MAX_NAME + 1);
            const n = sel.end - sel.start;
            @memcpy(tmp[0..n], rename.buf[sel.start..sel.end]);
            c.rl.SetClipboardText(@ptrCast(&tmp[0]));
            _ = renameDeleteSelection(rename);
        }
        return;
    }
    if (cmd and c.rl.IsKeyPressed(c.rl.KEY_V)) {
        const clip_text = c.rl.GetClipboardText();
        if (clip_text != null) renameInsertText(rename, std.mem.span(clip_text));
        return;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_LEFT)) {
        if (!shift and renameHasSelection(rename)) {
            rename.cursor = renameSelection(rename).start;
            rename.sel_anchor = null;
        } else {
            const next = if (cmd) wordLeft(rename.buf[0..rename.len], rename.cursor) else if (rename.cursor > 0) rename.cursor - 1 else 0;
            renameMoveCursor(rename, next, shift);
        }
        return;
    }
    if (c.rl.IsKeyPressed(c.rl.KEY_RIGHT)) {
        if (!shift and renameHasSelection(rename)) {
            rename.cursor = renameSelection(rename).end;
            rename.sel_anchor = null;
        } else {
            const next = if (cmd) wordRight(rename.buf[0..rename.len], rename.cursor) else @min(rename.cursor + 1, rename.len);
            renameMoveCursor(rename, next, shift);
        }
        return;
    }
    if (c.rl.IsKeyPressed(c.rl.KEY_HOME)) {
        renameMoveCursor(rename, 0, shift);
        return;
    }
    if (c.rl.IsKeyPressed(c.rl.KEY_END)) {
        renameMoveCursor(rename, rename.len, shift);
        return;
    }

    while (true) {
        const ch = c.rl.GetCharPressed();
        if (ch <= 0) break;
        if (ch >= 32 and ch <= 126 and rename.len < track_mod.MAX_NAME) {
            const one = [1]u8{@intCast(ch)};
            renameInsertText(rename, &one);
        }
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_BACKSPACE)) {
        renameDeleteBack(rename, cmd);
        return;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_DELETE)) {
        renameDeleteForward(rename, cmd);
        return;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_ESCAPE)) {
        rename.kind = .none;
        status.set("Rename canceled", .{});
        return;
    }

    if (!c.rl.IsKeyPressed(c.rl.KEY_ENTER) and !c.rl.IsKeyPressed(c.rl.KEY_KP_ENTER)) return;
    try commitRename(alloc, history, rename, tracks, transport, dirty, status);
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
    if (rename.len == 0) {
        rename.kind = .none;
        status.set("Rename canceled", .{});
        return;
    }

    const before = try document_mod.serialize(alloc, tracks, transport);
    const text = rename.buf[0..rename.len];
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
        .none => {},
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

fn arrangementRenameTarget(rename: *const RenameState) arrangement.RenameTarget {
    return switch (rename.kind) {
        .track => .{ .kind = .track, .track = rename.track },
        .clip => .{ .kind = .clip, .track = rename.track, .clip = rename.clip },
        .none => .{},
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
    const before = if (editMutationKeyPressed()) try document_mod.serialize(alloc, tracks, transport) else null;
    defer if (before) |snapshot| if (!changed) alloc.free(snapshot);

    if (!cmd and c.rl.IsKeyPressed(c.rl.KEY_D)) {
        changed = switch (focus) {
            .arrangement => arrangement.duplicateSelectedClips(tracks, alloc, selected_track, selected_clip, edit_snap),
            .piano_roll => clip_editor.duplicateSelectedNotes(tracks, selected_clip.*, alloc, edit_snap),
            .browser, .machine_bay, .top_bar => false,
        };
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
    command: widgets.EditCommand,
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
                    .piano_roll => clip_editor.deleteSelectedNotes(tracks, selected_clip.*),
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
                .piano_roll => clip_editor.deleteSelectedNotes(tracks, selected_clip.*),
                .browser, .machine_bay, .top_bar => false,
            };
            if (changed) status.set("Deleted", .{});
        },
        .loop_selection => {
            changed = if (focus == .arrangement) arrangement.loopSelectedClips(tracks, transport) else false;
            if (changed) status.set("Looped selection", .{});
        },
        .split_at_playhead => {
            changed = if (focus == .arrangement) arrangement.splitSelectedClipsAt(tracks, alloc, selected_clip, transport.beats()) else false;
            if (changed) status.set("Split clips", .{});
        },
        .quantize => {
            changed = if (focus == .piano_roll) clip_editor.quantizeSelectedNotes(tracks, selected_clip.*, edit_snap) else false;
            if (changed) status.set("Quantized", .{});
        },
        .none, .copy, .select_all, .clear_selection, .rename => {},
    }

    if (changed) {
        try history.pushUndo(alloc, before);
        dirty.* = true;
    } else {
        alloc.free(before);
        if (command != .paste) status.set("No selection", .{});
    }
}

fn editMutationKeyPressed() bool {
    return !commandModifierDown() and (c.rl.IsKeyPressed(c.rl.KEY_D) or arrowKeyPressed());
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
        .piano_roll => clip_editor.deleteSelectedNotes(tracks, selected_clip.*),
        .arrangement => arrangement.deleteSelectedClips(tracks, alloc, selected_clip),
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

fn shouldCaptureHistory(m: widgets.Mouse, rects: layout_mod.Rects, focus: FocusPane) bool {
    if (!m.left_pressed) return false;
    return switch (focus) {
        .arrangement => widgets.contains(rects.arrangement, m.x, m.y),
        .piano_roll => widgets.contains(rects.clip_editor, m.x, m.y),
        .browser => widgets.contains(rects.browser, m.x, m.y),
        .machine_bay => widgets.contains(rects.machine_bay, m.x, m.y),
        .top_bar => false,
    };
}

fn focusFromPoint(rects: layout_mod.Rects, m: widgets.Mouse, clip_editor_visible: bool) FocusPane {
    if (widgets.contains(rects.top_bar, m.x, m.y)) return .top_bar;
    if (widgets.contains(rects.browser, m.x, m.y)) return .browser;
    if (clip_editor_visible and widgets.contains(rects.clip_editor, m.x, m.y)) return .piano_roll;
    if (widgets.contains(rects.machine_bay, m.x, m.y)) return .machine_bay;
    if (widgets.contains(rects.arrangement, m.x, m.y)) return .arrangement;
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

fn handleUiScaleKeys() void {
    const mod = commandModifierDown();
    if (!mod) return;

    if (c.rl.IsKeyPressed(c.rl.KEY_EQUAL) or c.rl.IsKeyPressed(c.rl.KEY_KP_ADD)) {
        theme.stepUiScale(0.05);
    } else if (c.rl.IsKeyPressed(c.rl.KEY_MINUS) or c.rl.IsKeyPressed(c.rl.KEY_KP_SUBTRACT)) {
        theme.stepUiScale(-0.05);
    } else if (c.rl.IsKeyPressed(c.rl.KEY_ZERO) or c.rl.IsKeyPressed(c.rl.KEY_KP_0)) {
        theme.resetScale();
    }
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

fn drawStatusBar(
    r: c.rl.Rectangle,
    transport: *const transport_mod.Transport,
    selected_track: ?usize,
    selected_clip: ?clip_mod.ClipRef,
    tracks: []track_mod.Track,
    project_path: []const u8,
    project_path_chosen: bool,
    dirty: bool,
    status_text: [*:0]const u8,
    focus: FocusPane,
    edit_snap: snap_mod.Setting,
) void {
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    c.rl.DrawRectangle(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), 1, theme.slab_edge);

    const fh = r.height - 4;
    var x = r.x + 2;
    const y = r.y + 2;

    const playing = transport.isPlaying();
    const state_s: [*:0]const u8 = if (playing) "Playing" else "Stopped";
    drawStatusCell(widgets.rect(x, y, theme.size(88), fh), "TRANSPORT", state_s, if (playing) theme.accent_play else theme.text_fg);
    x += theme.size(89);

    var buf: [96:0]u8 = undefined;
    const label: [*:0]const u8 = if (selected_clip) |s| blk: {
        const t = &tracks[s.track];
        if (s.clip < t.clips.items.len) {
            const cname = t.clips.items[s.clip].name();
            break :blk (std.fmt.bufPrintZ(&buf, "{s} / {s}", .{ t.name(), cname }) catch @as([:0]const u8, "?")).ptr;
        }
        break :blk "(invalid)";
    } else if (selected_track) |ti| blk: {
        break :blk (std.fmt.bufPrintZ(&buf, "{s}", .{tracks[ti].name()}) catch @as([:0]const u8, "?")).ptr;
    } else "(none)";
    const sel_w = @min(theme.size(320), @max(theme.size(170), r.width * 0.34));
    drawStatusCell(widgets.rect(x, y, sel_w, fh), if (selected_clip != null) "CLIP" else "TRACK", label, theme.text_fg);
    x += sel_w + theme.size(1);

    var path_buf: [128:0]u8 = undefined;
    const path_label = if (project_path_chosen)
        (std.fmt.bufPrintZ(&path_buf, "{s}{s}", .{ if (dirty) "*" else "", basename(project_path) }) catch "?")
    else
        (if (dirty) @as([:0]const u8, "*Untitled") else @as([:0]const u8, "Untitled"));
    drawStatusCell(widgets.rect(x, y, @min(theme.size(260), @max(theme.size(130), r.width * 0.18)), fh), "PROJECT", path_label.ptr, theme.text_dim);
    x += @min(theme.size(260), @max(theme.size(130), r.width * 0.18)) + theme.size(1);

    drawStatusCell(widgets.rect(x, y, theme.size(116), fh), "FOCUS", focusLabel(focus), theme.text_dim);
    x += theme.size(117);

    drawStatusCell(widgets.rect(x, y, theme.size(72), fh), "SNAP", edit_snap.label(), theme.text_dim);
    x += theme.size(73);

    var detail_buf: [128:0]u8 = undefined;
    const detail = selectionDetails(&detail_buf, selected_clip, tracks);
    const detail_w = @min(theme.size(300), @max(theme.size(150), r.width * 0.2));
    drawStatusCell(widgets.rect(x, y, detail_w, fh), "DETAILS", detail, theme.text_dim);
    x += detail_w + theme.size(1);

    if (std.mem.len(status_text) > 0) {
        drawStatusCell(widgets.rect(x, y, @min(theme.size(260), @max(theme.size(140), r.width * 0.2)), fh), "STATUS", status_text, theme.accent_hi);
    }

    const zoom = std.fmt.bufPrintZ(&buf, "{d:.0}% / {d:.0}%", .{ theme.ui_scale * 100, theme.font_scale * 100 }) catch "?";
    drawStatusCell(widgets.rect(r.x + r.width - theme.size(118), y, theme.size(116), fh), "UI ZOOM", zoom.ptr, theme.text_dim);
}

fn drawStatusCell(r: c.rl.Rectangle, cap: [*:0]const u8, value: [*:0]const u8, value_color: c.rl.Color) void {
    const inner = widgets.displayField(r);
    const cap_size = theme.fsTiny();
    const val_size = theme.fsBody();
    widgets.drawLabelF(cap, inner.x + 4, inner.y + 1, cap_size, theme.text_mute);
    const val_y = inner.y + inner.height - val_size - 1;
    const max_w = inner.width - 8;
    const val_w = widgets.measureTextF(value, val_size);
    const text_x = if (val_w > max_w) inner.x + 4 - (val_w - max_w) else inner.x + 4;
    c.rl.BeginScissorMode(@intFromFloat(inner.x + 4), @intFromFloat(inner.y), @intFromFloat(max_w), @intFromFloat(inner.height));
    widgets.drawLabelF(value, text_x, val_y, val_size, value_color);
    c.rl.EndScissorMode();
}

fn selectionDetails(buf: *[128:0]u8, selected_clip: ?clip_mod.ClipRef, tracks: []track_mod.Track) [*:0]const u8 {
    if (selected_clip) |s| {
        if (s.track >= tracks.len) return "(invalid)";
        const t = &tracks[s.track];
        if (s.clip >= t.clips.items.len) return "(invalid)";
        const clip = &t.clips.items[s.clip];
        const selected_notes = clip.selectedCount();
        if (selected_notes > 0) {
            var lo: u8 = 127;
            var hi: u8 = 0;
            var vel_lo: u8 = 127;
            var vel_hi: u8 = 0;
            for (clip.notes.items) |note| {
                if (!note.selected) continue;
                lo = @min(lo, note.pitch);
                hi = @max(hi, note.pitch);
                vel_lo = @min(vel_lo, note.velocity);
                vel_hi = @max(vel_hi, note.velocity);
            }
            const s_detail = std.fmt.bufPrintZ(buf, "{d} notes  pitch {d}-{d}  vel {d}-{d}", .{ selected_notes, lo, hi, vel_lo, vel_hi }) catch return "?";
            return s_detail.ptr;
        }
        const c_detail = std.fmt.bufPrintZ(buf, "start {d:.2}  len {d:.2}  notes {d}", .{ clip.start_beat, clip.length_beats, clip.notes.items.len }) catch return "?";
        return c_detail.ptr;
    }

    var clip_count: usize = 0;
    var selected_count: usize = 0;
    for (tracks) |t| {
        clip_count += t.clips.items.len;
        for (t.clips.items) |clip| {
            if (clip.selected) selected_count += 1;
        }
    }
    if (selected_count > 0) {
        const selected_detail = std.fmt.bufPrintZ(buf, "{d} clips selected", .{selected_count}) catch return "?";
        return selected_detail.ptr;
    }
    const all_detail = std.fmt.bufPrintZ(buf, "{d} tracks  {d} clips", .{ tracks.len, clip_count }) catch return "?";
    return all_detail.ptr;
}

fn drawInlineRename(rename: *const RenameState) void {
    if (rename.rect.width <= 0 or rename.rect.height <= 0) return;
    const r = widgets.rect(rename.rect.x, rename.rect.y, @max(rename.rect.width, theme.size(44)), @max(rename.rect.height, theme.size(14)));
    c.rl.DrawRectangleRec(r, theme.slab_edge);
    const inner = widgets.rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2);
    c.rl.DrawRectangleRec(inner, theme.pane_bg);

    const text_x = inner.x + 3;
    const text_y = inner.y + (inner.height - theme.fsBody()) / 2 - 1;
    c.rl.BeginScissorMode(@intFromFloat(inner.x), @intFromFloat(inner.y), @intFromFloat(inner.width), @intFromFloat(inner.height));
    defer c.rl.EndScissorMode();

    if (renameHasSelection(rename)) {
        const sel = renameSelection(rename);
        const x0 = text_x + measureRenamePrefix(rename, sel.start);
        const x1 = text_x + measureRenamePrefix(rename, sel.end);
        c.rl.DrawRectangleRec(widgets.rect(x0, inner.y + 2, x1 - x0, inner.height - 4), c.rl.ColorAlpha(theme.accent_hi, 0.35));
    }

    widgets.drawLabelF(rename.text(), text_x, text_y, theme.fsBody(), theme.text_fg);
    const blink = @mod(@as(i32, @intFromFloat(c.rl.GetTime() * 2.5)), 2) == 0;
    if (blink) {
        const cx = text_x + measureRenamePrefix(rename, rename.cursor);
        c.rl.DrawRectangle(@intFromFloat(cx), @intFromFloat(inner.y + 3), 1, @intFromFloat(inner.height - 6), theme.accent_hi);
    }
}

fn measureRenamePrefix(rename: *const RenameState, end: usize) f32 {
    var tmp: [track_mod.MAX_NAME + 1:0]u8 = [_:0]u8{0} ** (track_mod.MAX_NAME + 1);
    const n = @min(end, rename.len);
    @memcpy(tmp[0..n], rename.buf[0..n]);
    return widgets.measureTextF(@ptrCast(&tmp[0]), theme.fsBody());
}

test "synthpop demo notes fit a 4-bar loop and span bass to lead range" {
    const alloc = std.testing.allocator;
    var t = try track_mod.Track.init(alloc, "test", theme.track_colors[0], silent_machine);
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

test "synthpop_8bar demo clip note counts match file contents" {
    const data = try document_mod.readFile(std.testing.allocator, "demos/synthpop_8bar.slab");
    defer std.testing.allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    var expected: ?usize = null;
    var actual: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "CLIP\t")) {
            if (expected) |n| try std.testing.expectEqual(n, actual);
            var fields = std.mem.splitScalar(u8, line, '\t');
            _ = fields.next();
            _ = fields.next();
            _ = fields.next();
            _ = fields.next();
            expected = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidProject, 10);
            actual = 0;
        } else if (std.mem.startsWith(u8, line, "NOTE\t")) {
            actual += 1;
        }
    }
    if (expected) |n| try std.testing.expectEqual(n, actual);
}

const _fy_host = @import("fy_host.zig");
const _poly = @import("machines/poly.zig");

test {
    _ = _poly;
}
