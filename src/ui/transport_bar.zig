//! Workbench transport bar on the new Ui (docs/06 §Packing: a toolbar of
//! flush tiles). Replaces the legacy top_bar.zig.
//!
//!   [file ▾][■/▶][●][▾][⟲][-][● 124.0][+][TAP][ 1.1.1][ 4/4][-][1/16][+][     ][SLAB]
//!
//! Menus (file, input device, meter denominator) and tooltips still go
//! through the legacy widgets until menus move onto the new core.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const pane = @import("pane_input.zig");
const menu = @import("menu.zig");
const bridge = @import("bridge.zig");
const snap_mod = @import("snap.zig");
const Transport = @import("../transport.zig").Transport;
const meter_mod = @import("../meter.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const HEIGHT: i32 = 32;

pub const Result = struct {
    open_project: bool = false,
    save_project: bool = false,
    save_project_as: bool = false,
    new_project: bool = false,
    clean_up_project: bool = false,
    render_audio: bool = false,
    record_toggle: bool = false,
    /// Index into `input_names` the user picked from the input-device menu.
    input_pick: ?usize = null,
    /// New master fader gain (linear, 0..MASTER_MAX_GAIN).
    master_volume: ?f32 = null,
    /// KILL: stop and silence everything.
    panic: bool = false,
    /// AUTO: arm/disarm automation recording.
    auto_arm_toggle: bool = false,
    /// BROWSE: show or hide the library browser (⌘⌥B).
    toggle_browser: bool = false,
};

pub const Args = struct {
    transport: *Transport,
    meter_state: *meter_mod.MeterState,
    edit_snap: *snap_mod.Setting,
    project_path: []const u8,
    project_path_chosen: bool,
    dirty: bool,
    recording: bool,
    can_record: bool,
    input_names: []const [*:0]const u8,
    current_input_idx: ?usize,
    /// Master bus peak (linear, L/R) for the output meter.
    master_peak: [2]f32 = .{ 0, 0 },
    /// Master fader gain (linear).
    master_volume: f32 = 1,
    /// Automation recording armed (docs/22 §Manual changes).
    auto_arm: bool = false,
    /// How late the master output is, samples (docs/07 §PDC).
    pdc_latency: u32 = 0,
    /// DSP load, render time over the callback budget: smoothed, and the
    /// worst callback since the last frame.
    cpu_load: f32 = 0,
    /// Each render thread's load since the last frame (Engine.takeThreadLoad).
    thread_load: []const f32 = &.{},
    cpu_peak: f32 = 0,
    /// The library browser is showing.
    browser_visible: bool = false,
};

const FILE_MENU_KEY: u64 = 0x5346494c45; // "SFILE"
const INPUT_MENU_KEY: u64 = 0x494e505544_4556; // "INPUDEV"
const DENOM_MENU_KEY: u64 = 0x44_45_4e_4f_4d_4d_4e_55; // "DENOMMNU"

const DENOM_ITEMS = [_]menu.Item{
    .{ .label = "/1", .id = 1 },
    .{ .label = "/2", .id = 2 },
    .{ .label = "/3", .id = 3 },
    .{ .label = "/4", .id = 4 },
    .{ .label = "/6", .id = 6 },
    .{ .label = "/8", .id = 8 },
    .{ .label = "/12", .id = 12 },
    .{ .label = "/16", .id = 16 },
    .{ .label = "/32", .id = 32 },
};

pub fn draw(ui: *Ui, r: Rect, a: Args) Result {
    ui.pushId("transport");
    defer ui.popId();
    var res = Result{};
    var bar = r;
    const t = a.transport;
    const map = a.meter_state.liveMap();

    fileTile(ui, bar.cutLeft(fileTileW(ui, a)), a, &res);
    const browse_r = bar.cutLeft(64);
    var browse_on = a.browser_visible;
    if (ctl.button(ui, browse_r, "browse", &browse_on, .{ .kind = .latch, .label = "BROWSE", .led = style.led_amber, .flush = true })) res.toggle_browser = true;
    menu.tip(ui, browse_r, "Browser (\u{2318}\u{2325}B)");

    // Transport.
    var playing = t.isPlaying();
    const play_r = bar.cutLeft(36);
    if (ctl.button(ui, play_r, "play", &playing, .{ .glyph = if (playing) .square6 else .tri_right, .glyph_on = style.play, .flush = true })) t.toggle();
    menu.tip(ui, play_r, if (playing) "Stop  Space" else "Play  Space");
    var rec_on = a.recording;
    const rec_r = bar.cutLeft(36);
    if (ctl.button(ui, rec_r, "rec", &rec_on, .{ .glyph = .round7, .glyph_on = style.rec, .flush = true, .disabled = !a.can_record })) res.record_toggle = true;
    menu.tip(ui, rec_r, if (!a.can_record) "Record (no input device)" else if (a.recording) "Stop recording" else "Record  (arm a track first)");
    inputTile(ui, bar.cutLeft(16), a, &res);
    var loop_on = t.loopEnabled();
    const loop_r = bar.cutLeft(36);
    if (ctl.button(ui, loop_r, "loop", &loop_on, .{ .label = "LOOP", .lit = style.accent, .flush = true })) t.toggleLoop();
    menu.tip(ui, loop_r, "Loop on/off");
    var arm = a.auto_arm;
    const arm_r = bar.cutLeft(40);
    if (ctl.button(ui, arm_r, "autoarm", &arm, .{ .label = "AUTO", .lit = style.rec, .flush = true })) res.auto_arm_toggle = true;
    menu.tip(ui, arm_r, if (a.auto_arm) "Automation recording armed: drags while playing write lanes" else "Arm automation recording");

    // Tempo: [LED 124.0 ▴▾]  TAP
    const bpm_r = bar.cutLeft(124);
    bpmTile(ui, bpm_r, t, map);
    const bpm_step = ctl.glassSteps(ui, bpm_r, "bpm-step");
    if (bpm_step != 0) t.setBpm(@round(t.bpm()) + @as(f32, @floatFromInt(bpm_step)));
    const tap_r = bar.cutLeft(48);
    if (ctl.button(ui, tap_r, "tap", null, .{ .label = "TAP", .flush = true })) handleTap(t, ui.in.time);
    menu.tip(ui, tap_r, "Tap tempo");

    // Position and meter.
    var pbuf: [32]u8 = undefined;
    const pos = map.beatToBarPos(t.beats());
    const sub = pos.tick / (meter_mod.PPQN / 4) + 1;
    const pos_s = std.fmt.bufPrint(&pbuf, "{d}.{d}.{d}", .{ pos.bar + 1, pos.beat + 1, sub }) catch "?";
    const pos_r = bar.cutLeft(120);
    ctl.display(ui, pos_r, pos_s, .{ .align_ = .right, .large = true, .flush = true });
    menu.tip(ui, pos_r, "Position  bar.beat.sub");
    meterTile(ui, bar.cutLeft(76), a.meter_state);

    // Snap: a select, finer upward.
    const snap_r = bar.cutLeft(92);
    var snap: u8 = @intFromEnum(a.edit_snap.*);
    if (ctl.displaySelectEx(ui, snap_r, "snap", &snap, &SNAP_LABELS, "SNAP", .{ .large = true, .flush = true })) a.edit_snap.* = @enumFromInt(snap);
    menu.tip(ui, snap_r, std.mem.span(a.edit_snap.tooltip()));

    // Logo plate on the right, the master meter beside it, blank plate
    // between.
    logoTile(ui, bar.cutRight(logoW(bar.h)));
    // The stats keep their room; the master meter gives way first.
    const stats_w: i32 = if (bar.w >= MASTER_MIN_W + STATS_W) STATS_W else 0;
    if (bar.w >= MASTER_MIN_W) masterTile(ui, bar.cutRight(@min(MASTER_W, bar.w - stats_w)), a, &res);
    if (stats_w > 0) statsTile(ui, bar.cutRight(stats_w), a);
    _ = ui.plate(bar, .{});
    return res;
}

const SNAP_LABELS = blk: {
    const fields = @typeInfo(snap_mod.Setting).@"enum".fields;
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = std.mem.span(@as(snap_mod.Setting, @enumFromInt(f.value)).label());
    break :blk out;
};

// ── Tiles ────────────────────────────────────────────────────────────

const MASTER_W: i32 = 400;
const MASTER_MIN_W: i32 = 220;
const VOL_W: i32 = 96;
const KILL_W: i32 = 44;
/// Master fader range (linear), as on the master track header.
pub const MASTER_MAX_GAIN: f32 = 1.25;

/// Master section: KILL, the master fader, and the output meter (a
/// horizontal stereo bargraph pair around a shared dB scale, clip LEDs
/// that reset on click).
fn masterTile(ui: *Ui, r: Rect, a: Args, res: *Result) void {
    ui.pushId("master");
    defer ui.popId();
    var row = r;
    const kill_r = row.cutLeft(KILL_W);
    if (ctl.button(ui, kill_r, "kill", null, .{ .label = "KILL", .flush = true })) res.panic = true;
    menu.tip(ui, kill_r, "Kill all sound: stop, and reset every machine (hung notes, tails)");

    var vol = ui.plate(row.cutLeft(VOL_W), .{});
    ui.textIn(&ui.fonts.legend, vol.cutLeft(24), "VOL", style.text_dim, .center, true);
    _ = vol.cutRight(4);
    const vol_r = vol.center(vol.w, 14);
    var v = std.math.clamp(a.master_volume / MASTER_MAX_GAIN, 0, 1);
    if (ctl.slider(ui, vol_r, "vol", &v, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 0, .default = 1 / MASTER_MAX_GAIN })) {
        res.master_volume = v * MASTER_MAX_GAIN;
    }
    var tbuf: [40]u8 = undefined;
    const db = 20 * std.math.log10(@max(a.master_volume, 1e-4));
    menu.tip(ui, vol_r, std.fmt.bufPrint(&tbuf, "Master volume {d:.1} dB (double-click: 0 dB)", .{db}) catch "Master volume");

    var body = ui.plate(row, .{});
    ui.textIn(&ui.fonts.legend, body.cutLeft(30), "OUT", style.text_dim, .center, true);
    _ = body.cutRight(4);
    ctl.meterStereo(ui, body, "meter", a.master_peak, a.master_peak, .{ .horizontal = true });
    menu.tip(ui, row, "Master output (peak, dBFS)");
}

const STATS_W: i32 = 112;
var peak_hold: f32 = 0;
/// The thread lamps, smoothed so they glow rather than flicker.
var lamp_shown: [8]f32 = @splat(0);
var cpu_shown: f32 = 0;
var cpu_at: f64 = -1;
var peak_at: f64 = 0;

/// Engine stats, two small rows: delay compensation and DSP load.
fn statsTile(ui: *Ui, r: Rect, a: Args) void {
    const sr = a.transport.sample_rate;
    const ms = @as(f32, @floatFromInt(a.pdc_latency)) * 1000 / @as(f32, @floatFromInt(@max(sr, 1)));
    var pbuf: [16]u8 = undefined;
    var cbuf: [16]u8 = undefined;
    // The number changes twice a second, so it can be read.
    if (ui.in.time - cpu_at >= 0.5 or ui.in.time < cpu_at) {
        cpu_shown = a.cpu_load;
        cpu_at = ui.in.time;
    }
    const cpu = @round(@min(cpu_shown, 9.99) * 100);
    const rows = [_][]const u8{
        std.fmt.bufPrint(&pbuf, "PDC {d:.1}ms", .{ms}) catch "PDC ?",
        std.fmt.bufPrint(&cbuf, "CPU {d:.0}%", .{cpu}) catch "CPU ?",
    };
    // The worst callback, held a second so a spike is seen.
    if (a.cpu_peak >= peak_hold or ui.in.time - peak_at > 1.0) {
        peak_hold = a.cpu_peak;
        peak_at = ui.in.time;
    }
    const hot = peak_hold >= 0.9;
    const n = @min(a.thread_load.len, lamp_shown.len);
    for (lamp_shown[0..n], a.thread_load[0..n]) |*s, v| s.* += (v - s.*) * 0.2;
    ctl.displayLines(ui, r, &rows, .{ .align_ = .left, .flush = true, .color = if (hot) style.rec else style.vfd, .lamps = lamp_shown[0..n] });
    var tbuf: [240]u8 = undefined;
    var w = std.Io.Writer.fixed(&tbuf);
    w.print("Delay compensation {d} smp ({d:.1} ms). DSP load {d:.0}%, peak {d:.0}% of the audio budget.", .{ a.pdc_latency, ms, cpu, @round(@min(peak_hold, 9.99) * 100) }) catch {};
    if (n > 0) {
        w.print(" Threads (a lamp each, the audio thread first):", .{}) catch {};
        for (lamp_shown[0..n]) |v| w.print(" {d:.0}%", .{@round(@min(v, 9.99) * 100)}) catch {};
    }
    menu.tip(ui, r, w.buffered());
}

fn fileLabel(buf: []u8, path: []const u8, chosen: bool, dirty: bool) []const u8 {
    if (!chosen) return if (dirty) "*Untitled" else "Untitled";
    const base = std.fs.path.basename(path);
    return std.fmt.bufPrint(buf, "{s}{s}", .{ if (dirty) "*" else "", base }) catch base;
}

fn fileTileW(ui: *const Ui, a: Args) i32 {
    var buf: [80]u8 = undefined;
    const name = fileLabel(&buf, a.project_path, a.project_path_chosen, a.dirty);
    return @max(96, ui.fonts.body.measure(name) + 36);
}

/// Project name as a dropdown tile: opens the (legacy) file menu.
fn fileTile(ui: *Ui, r: Rect, a: Args, res: *Result) void {
    var buf: [80]u8 = undefined;
    const name = fileLabel(&buf, a.project_path, a.project_path_chosen, a.dirty);
    const open = menu.isOpen(FILE_MENU_KEY);
    var shown = open;
    if (ctl.button(ui, r, "file", &shown, .{ .flush = true }) and !open) {
        menu.openBelow(FILE_MENU_KEY, r);
    }
    const inner = r.insetXY(8, 0);
    ui.textIn(&ui.fonts.body, inner, name, if (a.dirty) style.accent else style.text, .left, true);
    ctl.led(ui, inner.right() - 7, r.y + @divFloor(r.h - 4, 2), .tri_down, .off, style.text_dim);
    menu.tip(ui, r, "Project file");
    const items = [_]menu.Item{
        .{ .label = "New Project", .command = .file_new },
        .{ .label = "Open\u{2026}", .command = .file_open },
        .{ .label = "Save", .command = .file_save },
        .{ .label = "Save As\u{2026}", .command = .file_save_as },
        .{ .label = "Clean Up Project Files", .command = .file_clean_up },
        .{ .separator = true },
        .{ .label = "Render Audio\u{2026}", .command = .render_audio },
    };
    switch (menu.command(FILE_MENU_KEY, &items)) {
        .file_new => res.new_project = true,
        .file_open => res.open_project = true,
        .file_save => res.save_project = true,
        .file_save_as => res.save_project_as = true,
        .file_clean_up => res.clean_up_project = true,
        .render_audio => res.render_audio = true,
        else => {},
    }
}

/// Input-device caret next to record: opens the (legacy) device menu.
fn inputTile(ui: *Ui, r: Rect, a: Args, res: *Result) void {
    const have = a.input_names.len > 0;
    var open = menu.isOpen(INPUT_MENU_KEY);
    if (ctl.button(ui, r, "input", &open, .{ .glyph = .tri_down, .glyph_on = style.text, .flush = true, .disabled = !have }) and have and !menu.isOpen(INPUT_MENU_KEY)) {
        menu.openBelow(INPUT_MENU_KEY, r);
    }
    const cur_tip: []const u8 = if (!have)
        "Input device (none found)"
    else if (a.current_input_idx) |ci| std.mem.span(a.input_names[@min(ci, a.input_names.len - 1)]) else "Select input device";
    menu.tip(ui, r, cur_tip);
    if (menu.isOpen(INPUT_MENU_KEY) and have) {
        var items: [34]menu.Item = undefined;
        const n = @min(a.input_names.len, items.len);
        for (0..n) |i| items[i] = .{ .label = std.mem.span(a.input_names[i]), .id = @intCast(i) };
        if (menu.pick(INPUT_MENU_KEY, items[0..n])) |id| res.input_pick = @intCast(id);
    }
}

/// BPM readout that edits like a knob: vertical drag (Shift fine), ⌘-wheel
/// steps, double-click resets to 120. The LED pulses on each meter-beat:
/// red downbeat, amber group accent, green weak beat.
fn bpmTile(ui: *Ui, r: Rect, t: *Transport, map: meter_mod.MeterMap) void {
    const wid = ui.id("bpm");
    const b = ui.behavior(wid, r, false);
    var bpm = t.bpm();
    if (b.double) {
        bpm = 120;
    } else if (b.held) {
        bpm -= ui.in.dy * ui.renderer.zoom * (if (ui.in.shift) @as(f32, 0.05) else 0.5);
    }
    if (ui.in.cmd and ui.in.wheel_y != 0 and r.contains(ui.in.ix(), ui.in.iy())) bpm += ui.in.wheel_y;
    bpm = std.math.clamp(bpm, 20, 400);
    if (bpm != t.bpm()) t.setBpm(bpm);
    if (ui.isHot(wid)) ui.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);

    var buf: [16]u8 = undefined;
    // A spare cell on the right for the ▴▾ steps.
    const s = std.fmt.bufPrint(&buf, "{d:.1} ", .{t.bpm()}) catch "?";
    ctl.display(ui, r, s, .{ .align_ = .right, .large = true, .flush = true, .color = if (ui.active == wid) style.vfd_hi else style.vfd });
    const mb = map.meterBeat(t.beats());
    const on = t.isPlaying() and mb.phase < 0.12;
    const col = switch (mb.accent) {
        .downbeat => style.led_red,
        .group => style.led_amber,
        .weak => style.led_green,
    };
    ctl.led(ui, r.x + 5, r.y + @divFloor(r.h - 1 - 5, 2), .round5, if (on) .on else .off, col);
    if (t.isPlaying()) ui.animate();
    menu.tip(ui, r, "Tempo: drag, \u{2318}-scroll, \u{25B4}\u{25BE} step, double-click 120");
}

/// Time signature of bar 0: drag the numerator, right-click for the
/// denominator menu. Edits stage through MeterState (adopted at the next
/// bar boundary).
fn meterTile(ui: *Ui, r: Rect, state: *meter_mod.MeterState) void {
    const wid = ui.id("meter");
    const base = state.liveMap().points[0];
    const b = ui.behavior(wid, r, false);
    if (b.pressed) ui.drag_acc = @floatFromInt(base.numerator);
    if (b.held) {
        ui.drag_acc = std.math.clamp(ui.drag_acc - ui.in.dy * ui.renderer.zoom * 0.1, 1, 32);
        const num: u8 = @intFromFloat(@round(ui.drag_acc));
        if (num != base.numerator) state.editMeterAt(0, num, base.denominator);
    }
    if (ui.isHot(wid)) ui.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_NS, 1);
    if (ui.in.right_pressed and r.contains(ui.in.ix(), ui.in.iy())) menu.openAt(DENOM_MENU_KEY, ui.in.ix(), ui.in.iy());
    if (menu.isOpen(DENOM_MENU_KEY)) {
        if (menu.pick(DENOM_MENU_KEY, &DENOM_ITEMS)) |id| state.editMeterAt(0, base.numerator, @intCast(id));
    }
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}/{d}", .{ base.numerator, base.denominator }) catch "?";
    ctl.display(ui, r, s, .{ .align_ = .center, .large = true, .flush = true, .color = if (ui.active == wid) style.vfd_hi else style.vfd });
    menu.tip(ui, r, "Meter: drag numerator, right-click denominator");
}

// ── Logo ─────────────────────────────────────────────────────────────

var logo_tex: c.rl.Texture2D = undefined;
var logo_state: enum { unloaded, ok, missing } = .unloaded;

/// The slab.png wordmark, loaded once (lazily, so the GL context exists).
/// Mipmapped: it's a photographic image downscaled into a small plate,
/// the one place a filtered texture is right.
fn logoTexture() ?c.rl.Texture2D {
    if (logo_state == .unloaded) {
        var tex = c.rl.LoadTexture("slab.png");
        if (tex.id != 0) {
            c.rl.GenTextureMipmaps(&tex);
            c.rl.SetTextureFilter(tex, c.rl.TEXTURE_FILTER_TRILINEAR);
            logo_tex = tex;
            logo_state = .ok;
        } else logo_state = .missing;
    }
    return if (logo_state == .ok) logo_tex else null;
}

pub fn unloadLogo() void {
    if (logo_state == .ok) c.rl.UnloadTexture(logo_tex);
    logo_state = .unloaded;
}

const LOGO_PAD: i32 = 5;

fn logoW(h: i32) i32 {
    const tex = logoTexture() orelse return 72;
    const ih = h - 1 - 2 * LOGO_PAD;
    return @divFloor(ih * tex.width, tex.height) + 2 * LOGO_PAD + 2;
}

fn logoTile(ui: *Ui, r: Rect) void {
    const body = ui.plate(r, .{});
    if (logoTexture()) |tex| {
        const ih = r.h - 1 - 2 * LOGO_PAD;
        const iw = @divFloor(ih * tex.width, tex.height);
        ui.texture(tex, Rect.xywh(body.x + @divFloor(body.w - iw, 2), r.y + LOGO_PAD, iw, ih), .{ .r = 255, .g = 255, .b = 255 });
    } else {
        ui.textIn(&ui.fonts.body_bold, body, "SLAB", style.accent, .center, true);
    }
}

// ── Helpers ──────────────────────────────────────────────────────────


// Tap tempo: average of the last few intervals; a 2 s gap restarts.
const TAP_MAX = 4;
var tap_times: [TAP_MAX]f64 = .{ 0, 0, 0, 0 };
var tap_count: usize = 0;

fn handleTap(t: *Transport, now: f64) void {
    if (tap_count > 0 and now - tap_times[tap_count - 1] > 2.0) tap_count = 0;
    if (tap_count == TAP_MAX) {
        std.mem.copyForwards(f64, tap_times[0 .. TAP_MAX - 1], tap_times[1..TAP_MAX]);
        tap_count -= 1;
    }
    tap_times[tap_count] = now;
    tap_count += 1;
    if (tap_count < 2) return;
    const interval = (tap_times[tap_count - 1] - tap_times[0]) / @as(f64, @floatFromInt(tap_count - 1));
    if (interval > 0.1) t.setBpm(@floatCast(60.0 / interval));
}
