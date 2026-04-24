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
const browser = @import("ui/browser.zig");
const arrangement = @import("ui/arrangement.zig");
const clip_editor = @import("ui/clip_editor.zig");
const machine_bay = @import("ui/machine_bay.zig");

const MAX_TRACKS: usize = 16;

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
    try reg.load("mono1", "machines/mono1/mono1.fy", "mono1-audio", "mono1-ui", 322);

    // Hot-patch server on the sine machine's host.
    defer fy_host_mod.deleteFilePosix(".fy-port");
    _ = reg.entries[0].host.startHotPatchServer() catch |err|
        std.log.warn("hot-patch: {}", .{err});

    // ── Tracks — start with silent placeholder machines ──────────────
    var transport: transport_mod.Transport = .{};
    transport.sample_rate = audio_mod.SAMPLE_RATE;

    var tracks_buf: [MAX_TRACKS]track_mod.Track = undefined;
    var track_count: usize = 2;
    tracks_buf[0] = try track_mod.Track.init(alloc, "Track 1", theme.track_colors[0], silent_machine);
    tracks_buf[1] = try track_mod.Track.init(alloc, "Track 2", theme.track_colors[2], silent_machine);
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
    var selected_clip: ?clip_mod.ClipRef = null;
    var prev_selected_clip: ?clip_mod.ClipRef = null;
    var selected_track: ?usize = 0;
    var history: history_mod.History = .{};
    defer history.deinit(alloc);
    var project_path = try alloc.dupe(u8, document_mod.SAVE_PATH);
    defer alloc.free(project_path);
    var project_path_chosen = false;

    while (!c.rl.WindowShouldClose()) {
        const m = widgets.Mouse.sample();
        const sw: f32 = @floatFromInt(c.rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(c.rl.GetScreenHeight());
        widgets.beginFrame();

        layout.handleInput(sw, sh, m);

        var rects = layout.compute(sw, sh);
        var tracks = tracks_buf[0..track_count];

        if (try handleProjectShortcuts(
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
        )) {
            rects = layout.compute(sw, sh);
        } else {
            if (shouldCaptureHistory(m, rects) or c.rl.IsKeyPressed(c.rl.KEY_DELETE) or c.rl.IsKeyPressed(c.rl.KEY_BACKSPACE)) {
                pushHistorySnapshot(alloc, &history, tracks, &transport);
            }
            if (c.rl.IsKeyPressed(c.rl.KEY_SPACE)) transport.toggle();
            if (c.rl.IsKeyPressed(c.rl.KEY_HOME)) transport.rewind();
            if (c.rl.IsKeyPressed(c.rl.KEY_TAB)) layout.clip_editor_visible = !layout.clip_editor_visible;
            handleUiScaleKeys();
        }

        c.rl.BeginDrawing();
        c.rl.ClearBackground(theme.bg);

        const tres = top_bar.draw(rects.top_bar, &transport, m);

        // Browser — handles machine assignment to the selected track.
        const bres = browser.draw(rects.browser, layout.browser_collapsed, &reg, m);
        if (bres.toggled) layout.browser_collapsed = !layout.browser_collapsed;
        if (bres.assigned) |reg_idx| {
            if (selected_track) |ti| if (ti < tracks.len) {
                const mach = reg.instantiate(reg_idx) catch |err| {
                    std.log.err("instantiate machine failed: {s}", .{@errorName(err)});
                    continue;
                };
                tracks[ti].replaceMachine(alloc, mach);
                tracks[ti].machine_idx = @intCast(reg_idx);
                // Rename track to the machine name.
                const nm = reg.entries[reg_idx].nameSlice();
                const n = @min(nm.len, track_mod.MAX_NAME);
                @memcpy(tracks[ti].name_buf[0..n], nm[0..n]);
                tracks[ti].name_len = @intCast(n);
            };
        }

        const ares = arrangement.draw(rects.arrangement, tracks, alloc, &selected_track, &selected_clip, &transport, m);
        if (ares.add_track and track_count < MAX_TRACKS) {
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
        }
        const selection_changed = !clipRefEq(selected_clip, prev_selected_clip);
        if (selection_changed and selected_clip != null) {
            layout.clip_editor_visible = true;
            rects = layout.compute(sw, sh);
        }
        if (layout.clip_editor_visible) {
            const cres = clip_editor.draw(rects.clip_editor, tracks, alloc, selected_clip, m);
            if (cres.minimize or cres.close) layout.clip_editor_visible = false;
            if (!cres.consumed_delete and (c.rl.IsKeyPressed(c.rl.KEY_DELETE) or c.rl.IsKeyPressed(c.rl.KEY_BACKSPACE))) {
                _ = arrangement.deleteSelectedClips(tracks, alloc, &selected_clip);
            }
        } else if (c.rl.IsKeyPressed(c.rl.KEY_DELETE) or c.rl.IsKeyPressed(c.rl.KEY_BACKSPACE)) {
            _ = arrangement.deleteSelectedClips(tracks, alloc, &selected_clip);
        }
        const mbres = machine_bay.draw(rects.machine_bay, tracks, selected_track, layout.machine_bay_collapsed, m);
        if (mbres.minimize) layout.machine_bay_collapsed = !layout.machine_bay_collapsed;

        layout.drawSplitters(rects, m);
        drawStatusBar(rects.status_bar, &transport, selected_track, selected_clip, tracks, project_path, project_path_chosen);
        widgets.drawTooltip(sw, sh);
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
) !bool {
    const mod = commandModifierDown();
    if (!mod) return false;

    if (c.rl.IsKeyPressed(c.rl.KEY_S)) {
        const shifted = c.rl.IsKeyDown(c.rl.KEY_LEFT_SHIFT) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SHIFT);
        try saveProject(alloc, tracks.*, transport, project_path, project_path_chosen, shifted);
        return true;
    }

    if (c.rl.IsKeyPressed(c.rl.KEY_O)) {
        try openProject(alloc, history, tracks_buf, track_count, tracks, transport, engine, audio, reg, selected_track, selected_clip, prev_selected_clip, project_path, project_path_chosen);
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
        return;
    };
    project_path_chosen.* = true;
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
) !void {
    const chosen = native_dialog.openProject(alloc) catch |err| {
        std.log.err("open dialog failed: {s}", .{@errorName(err)});
        return;
    };
    const path = chosen orelse return;
    defer alloc.free(path);

    const before = try document_mod.serialize(alloc, tracks.*, transport);
    const data = document_mod.readFile(alloc, path) catch |err| {
        alloc.free(before);
        std.log.err("load failed: {s}", .{@errorName(err)});
        return;
    };
    defer alloc.free(data);
    try history.pushUndo(alloc, before);
    applyProjectBytes(alloc, data, reg, tracks_buf, track_count, tracks, transport, engine, audio, selected_track, selected_clip, prev_selected_clip) catch |err| {
        std.log.err("load failed: {s}", .{@errorName(err)});
        return;
    };
    replaceProjectPath(alloc, project_path, try alloc.dupe(u8, path));
    project_path_chosen.* = true;
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
    audio.setRender(null, null);
    defer audio.setRender(engine, engine_mod.Engine.renderCallback);

    try document_mod.apply(alloc, data, reg, tracks_buf, track_count, transport, silent_machine);
    tracks.* = tracks_buf[0..track_count.*];
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

fn shouldCaptureHistory(m: widgets.Mouse, rects: layout_mod.Rects) bool {
    if (!m.left_pressed) return false;
    return widgets.contains(rects.top_bar, m.x, m.y) or
        widgets.contains(rects.browser, m.x, m.y) or
        widgets.contains(rects.arrangement, m.x, m.y) or
        widgets.contains(rects.clip_editor, m.x, m.y) or
        widgets.contains(rects.machine_bay, m.x, m.y);
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
        (std.fmt.bufPrintZ(&path_buf, "{s}", .{basename(project_path)}) catch "?")
    else
        @as([:0]const u8, "Untitled");
    drawStatusCell(widgets.rect(x, y, @min(theme.size(260), @max(theme.size(130), r.width * 0.18)), fh), "PROJECT", path_label.ptr, theme.text_dim);

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

test "placeholder" {
    try std.testing.expect(true);
}

const _fy_host = @import("fy_host.zig");
