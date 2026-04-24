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

const theme = @import("ui/theme.zig");
const widgets = @import("ui/widgets.zig");
const fonts = @import("ui/fonts.zig");
const layout_mod = @import("ui/layout.zig");
const top_bar = @import("ui/top_bar.zig");
const browser = @import("ui/browser.zig");
const arrangement = @import("ui/arrangement.zig");
const clip_editor = @import("ui/clip_editor.zig");
const machine_bay = @import("ui/machine_bay.zig");

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

    var tracks = [_]track_mod.Track{
        try track_mod.Track.init(alloc, "Track 1", theme.track_colors[0], silent_machine),
        try track_mod.Track.init(alloc, "Track 2", theme.track_colors[2], silent_machine),
    };
    defer for (&tracks) |*t| t.deinit(alloc);

    var engine = engine_mod.Engine{
        .transport = &transport,
        .tracks = tracks[0..],
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

    while (!c.rl.WindowShouldClose()) {
        c.rl.SetMouseCursor(c.rl.MOUSE_CURSOR_DEFAULT);

        if (c.rl.IsKeyPressed(c.rl.KEY_SPACE)) transport.toggle();
        if (c.rl.IsKeyPressed(c.rl.KEY_HOME)) transport.rewind();
        if (c.rl.IsKeyPressed(c.rl.KEY_TAB)) layout.clip_editor_visible = !layout.clip_editor_visible;
        handleUiScaleKeys();

        const m = widgets.Mouse.sample();
        const sw: f32 = @floatFromInt(c.rl.GetScreenWidth());
        const sh: f32 = @floatFromInt(c.rl.GetScreenHeight());

        layout.handleInput(sw, sh, m);

        const selection_changed = !clipRefEq(selected_clip, prev_selected_clip);
        if (selection_changed and selected_clip != null) {
            layout.clip_editor_visible = true;
        }

        const rects = layout.compute(sw, sh);

        c.rl.BeginDrawing();
        c.rl.ClearBackground(theme.bg);

        top_bar.draw(rects.top_bar, &transport, m);

        // Browser — handles machine assignment to the selected track.
        const bres = browser.draw(rects.browser, layout.browser_collapsed, &reg, m);
        if (bres.toggled) layout.browser_collapsed = !layout.browser_collapsed;
        if (bres.assigned) |reg_idx| {
            if (selected_track) |ti| if (ti < tracks.len) {
                tracks[ti].machine = reg.entries[reg_idx].machineInterface();
                // Rename track to the machine name.
                const nm = reg.entries[reg_idx].nameSlice();
                const n = @min(nm.len, track_mod.MAX_NAME);
                @memcpy(tracks[ti].name_buf[0..n], nm[0..n]);
                tracks[ti].name_len = @intCast(n);
            };
        }

        arrangement.draw(rects.arrangement, tracks[0..], alloc, &selected_track, &selected_clip, &transport, m);
        if (layout.clip_editor_visible) {
            const cres = clip_editor.draw(rects.clip_editor, tracks[0..], alloc, selected_clip, m);
            if (cres.minimize or cres.close) layout.clip_editor_visible = false;
        }
        const mbres = machine_bay.draw(rects.machine_bay, tracks[0..], selected_track, layout.machine_bay_collapsed, m);
        if (mbres.minimize) layout.machine_bay_collapsed = !layout.machine_bay_collapsed;

        layout.drawSplitters(rects, m);
        drawStatusBar(rects.status_bar, &transport, selected_track, selected_clip, tracks[0..]);

        for (&tracks) |*t| t.publishSnapshot();

        c.rl.EndDrawing();
        prev_selected_clip = selected_clip;
    }
}

fn handleUiScaleKeys() void {
    const mod = c.rl.IsKeyDown(c.rl.KEY_LEFT_SUPER) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_SUPER) or
        c.rl.IsKeyDown(c.rl.KEY_LEFT_CONTROL) or c.rl.IsKeyDown(c.rl.KEY_RIGHT_CONTROL);
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
) void {
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    c.rl.DrawRectangle(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.width), 1, theme.slab_edge);

    const fh = r.height - 2;
    var x = r.x + 2;
    const y = r.y + 1;

    const playing = transport.isPlaying();
    const chip_w = theme.size(44);
    const chip = widgets.rect(x, y, chip_w, fh);
    const inner = widgets.displayField(chip);
    const state_s: [*:0]const u8 = if (playing) "PLAY" else "STOP";
    widgets.drawLabelF(state_s, inner.x + 4, inner.y, theme.fsTiny(), if (playing) theme.accent_play else theme.text_dim);
    x += chip_w;

    const trk_w = theme.size(180);
    const trk = widgets.rect(x, y, trk_w, fh);
    const trk_inner = widgets.displayField(trk);
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
    widgets.drawLabelF("SEL", trk_inner.x + 3, trk_inner.y, theme.fsTiny(), theme.text_mute);
    widgets.drawLabelF(label, trk_inner.x + 22, trk_inner.y, theme.fsTiny(), theme.text_fg);

    const hint = "SPACE play/stop  click browser machine → assign to selected track";
    const hw = widgets.measureTextF(hint, theme.fsTiny());
    widgets.drawLabelF(hint, r.x + r.width - hw - 6, y + 1, theme.fsTiny(), theme.text_mute);
}

test "placeholder" {
    try std.testing.expect(true);
}

const _fy_host = @import("fy_host.zig");
