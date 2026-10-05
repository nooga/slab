//! `slab --gallery` (docs/06 §The gallery). The pages:
//! CONTROLS — every material, token, type strike, display and control
//! family × size × state; DAW — the working surfaces assembled the way
//! the app will be (transport, arrangement, piano roll, machine bay);
//! CONCOCTION — the prototype of that machine's panel cards.
//! BROWSER — the library browser prototype (gallery_browser.zig).
//! DIALOGS — the Export sheet (each tab), its report, and Bounce (docs/27),
//! one at a time over mock tracks; SLAB_GALLERY_DIALOG=0..6 picks one.
//! Everything is packed: plates tile the window with shared 1px seams.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const surf = @import("surfaces.zig");
const concoction = @import("gallery_concoction.zig");
const browser = @import("gallery_browser.zig");
const menu = @import("menu.zig");
const export_dialog = @import("export_dialog.zig");
const bounce_dialog = @import("bounce_dialog.zig");
const marker_dialog = @import("marker_dialog.zig");
const groove_mod = @import("../groove.zig");
var gallery_groove_pool = groove_mod.Pool.init();
var gallery_groove_cx = groove_mod.Context{ .pool = &gallery_groove_pool };
const markers_mod = @import("../markers.zig");
const tempo_mod = @import("../tempo.zig");
const meter_mod = @import("../meter.zig");
const export_settings = @import("../export_settings.zig");
const track_mod = @import("../track.zig");
const machine_mod = @import("../machine.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;

const State = struct {
    page: u8 = 1,
    /// DIALOGS: which one is up: the Export tabs, the report, Bounce.
    dialog: u8 = 0,
    export_dlg: export_dialog.State = .{ .active = true },
    export_card: export_dialog.State = .{},
    bounce_dlg: bounce_dialog.State = .{ .active = true },
    marker_dlg: marker_dialog.State = .{},
    export_cfg: export_settings.Settings = .{},
    export_presets: export_settings.UserPresets = .{},
    mock_tracks: []track_mod.Track = &.{},
    zoom: u8 = 0, // index into ZOOMS
    materials_on: bool = true,
    running: bool = true,

    knobs: [4][3]f32 = .{ .{ 0.62, 0.35, 0.8 }, .{ 0.5, 0.72, 0.3 }, .{ 0.5, 0.25, 1.0 }, .{ 0.1, 0.55, 0.9 } },
    mod_knob: f32 = 0.4,
    dis_knob: f32 = 0.7,
    adsr: [4]f32 = .{ 0.05, 0.45, 0.6, 0.35 },
    fader: f32 = 0.75,
    pan: f32 = 0.5,
    minis: [6]f32 = .{ 0.2, 0.8, 0.5, 0.35, 0.9, 0.6 },
    hslider: f32 = 0.3,
    lever2: u8 = 0,
    lever3: u8 = 1,
    slide2: u8 = 1,
    slide3: u8 = 0,
    sync: bool = true,
    solo: bool = false,
    mute: bool = true,
    arm: bool = false,
    range: u8 = 1,
    wave: u8 = 1,
    octave: u8 = 2,
    preset: u8 = 3,
    sync_div: u8 = 6,
    bpm: f32 = 124,
    steps: [16]bool = .{ true, false, false, false, true, false, false, true, true, false, true, false, true, false, false, false },

    // Machine mock.
    m_wave: f32 = 0.33,
    m_det: f32 = 0.52,
    m_cut: f32 = 0.64,
    m_res: f32 = 0.28,
    m_env: f32 = 0.7,
    m_drv: f32 = 0.2,
    m_adsr: [4]f32 = .{ 0.02, 0.4, 0.5, 0.3 },
    m_oct: u8 = 1,
    d_time: f32 = 0.5,
    d_fb: f32 = 0.45,
    d_mix: f32 = 0.3,
    d_sync: u8 = 0,

    // DAW mock.
    playing: bool = true,
    loop_on: bool = true,
    metro: bool = false,
    rec: bool = false,
    tracks: [5]surf.TrackUi = .{
        .{ .name = "BASS", .color = style.track[0], .selected = true },
        .{ .name = "CHORDS", .color = style.track[4] },
        .{ .name = "ARP", .color = style.track[5] },
        .{ .name = "DRUMS", .color = style.track[2], .solo = false },
        .{ .name = "VOX", .color = style.track[6], .arm = true, .mute = true },
    },
    master_vol: f32 = 0.8,
    // Splitter-owned pane sizes (logical px).
    bay_h: i32 = 0, // 0 = pick the M tier on first frame
    roll_h: i32 = 320,
    headers_w: i32 = 208,
};

const ZOOMS = [_]f32{ 1, 2, 3 };

const presets = [_][]const u8{ "INIT", "ACID-BASS", "BUZZ-LEAD", "RUBBER-BASS", "GLASS-ARP", "LUSH-PAD" };

pub fn run(alloc: std.mem.Allocator) !void {
    c.rl.SetConfigFlags(c.rl.FLAG_WINDOW_RESIZABLE | c.rl.FLAG_VSYNC_HINT | c.rl.FLAG_WINDOW_HIGHDPI);
    c.rl.InitWindow(1400, 900, "slab gallery");
    defer c.rl.CloseWindow();
    c.rl.SetTargetFPS(120);
    c.rl.SetExitKey(c.rl.KEY_NULL);

    const ui = try Ui.init(alloc);
    defer ui.deinit(alloc);

    var st = State{};
    // SLAB_GALLERY_PAGE=0..3 opens on that page (screenshots, prototypes).
    if (std.c.getenv("SLAB_GALLERY_PAGE")) |pg| st.page = std.fmt.parseInt(u8, std.mem.span(pg), 10) catch st.page;
    var cn = concoction.State.init(alloc);
    defer cn.deinit(alloc);
    var br = try browser.State.init(alloc);
    defer br.deinit(alloc);
    if (std.c.getenv("SLAB_GALLERY_DIALOG")) |d| st.dialog = std.fmt.parseInt(u8, std.mem.span(d), 10) catch 0;
    var mock: [10]track_mod.Track = undefined;
    try mockTracks(alloc, &mock);
    defer for (&mock) |*t| t.deinit(alloc);
    st.mock_tracks = &mock;
    st.export_cfg.recipe = export_settings.BUILTIN[3].recipe;
    st.export_cfg.preset.set("STEMS FOR MIXING");
    st.export_cfg.artist.set("nooga");
    st.export_cfg.year.set("2026");
    st.export_presets.put("CLUB MASTER", export_settings.BUILTIN[1].recipe);
    genNotes();
    var build_ms: f64 = 0;
    while (!c.rl.WindowShouldClose()) {
        ui.renderer.zoom = ZOOMS[st.zoom];
        style.materials = if (st.materials_on) .{} else style.materials_off;
        const t0 = c.rl.GetTime();
        ui.beginFrame();
        {
            const z = ui.renderer.zoom;
            menu.beginFrame(ui, @intFromFloat(@as(f32, @floatFromInt(c.rl.GetScreenWidth())) / z), @intFromFloat(@as(f32, @floatFromInt(c.rl.GetScreenHeight())) / z));
        }
        if (menu.active()) ui.suppressInput();
        frame(ui, &st, &cn, &br, build_ms);
        menu.draw(ui);
        if (st.running) ui.animate();
        build_ms = build_ms * 0.9 + (c.rl.GetTime() - t0) * 1000 * 0.1;
        // Idle screens wait for events instead of redrawing at 120 fps.
        if (ui.wants_frame) c.rl.DisableEventWaiting() else c.rl.EnableEventWaiting();
        ui.endFrame();
        ui.present();
    }
}

fn frame(ui: *Ui, st: *State, cn: *concoction.State, br: *browser.State, build_ms: f64) void {
    const z = ui.renderer.zoom;
    const sw: i32 = @intFromFloat(@as(f32, @floatFromInt(c.rl.GetScreenWidth())) / z);
    const sh: i32 = @intFromFloat(@as(f32, @floatFromInt(c.rl.GetScreenHeight())) / z);
    var screen = Rect.xywh(0, 0, sw, sh);
    ui.chassis(screen);
    header(ui, screen.cutTop(24), st, build_ms);
    switch (st.page) {
        0 => controlsPage(ui, screen, st),
        1 => dawPage(ui, screen, st),
        2 => concoction.page(ui, screen, cn),
        3 => browser.page(ui, screen, br),
        else => dialogsPage(ui, screen, st),
    }
}

fn silentRender(_: *anyopaque, _: *const machine_mod.MachineCtx, l: []f32, r: []f32) void {
    @memset(l, 0);
    @memset(r, 0);
}
fn silentPanel(_: *anyopaque, _: *Ui, _: Rect) void {}
fn silentReset(_: *anyopaque) void {}
var silent_state: u8 = 0;

/// A song's tracks for the Export sheet: drums into a group, a return
/// the pad sends to.
fn mockTracks(alloc: std.mem.Allocator, out: *[10]track_mod.Track) !void {
    const m = machine_mod.Machine{ .name = "(mock)", .state = &silent_state, .render = silentRender, .draw_panel = silentPanel, .reset = silentReset };
    const names = [_][]const u8{ "KICK", "SNARE", "HATS", "PERC", "DRUMS", "SYNTH BASS", "PAD", "PIANO", "LEAD", "VERB" };
    const cols = [_]u24{ 0xe0607c, 0xe0607c, 0xe0607c, 0xe0607c, 0xd85a30, 0x3ddc84, 0x8a7fe0, 0x5aa9e6, 0xd65cff, 0x4fb3bf };
    for (names, 0..) |n, i| {
        const col = Color.hex(cols[i]);
        out[i] = try track_mod.Track.init(alloc, n, .{ .r = col.r, .g = col.g, .b = col.b, .a = 255 }, m);
        out[i].stem.on = !(i == 4 or i == 9);
    }
    for (0..4) |i| out[i].output = 4;
    out[4].kind = .bus;
    out[9].kind = .bus;
    try out[6].addSend(9, false, 0.4);
    out[0].stem.channels = 2;
    out[5].stem.channels = 2;
    out[4].stem = .{ .on = true, .signal = 2 };
}

const mock_sections = [_]markers_mod.Section{
    .{ .beat = 0, .name = markers_mod.Name.init("intro") },
    .{ .beat = 32, .name = markers_mod.Name.init("verse") },
    .{ .beat = 96, .name = markers_mod.Name.init("chorus") },
    .{ .beat = 160, .name = markers_mod.Name.init("outro") },
};

/// One dialog at a time, centered: a strip picks it.
fn dialogsPage(ui: *Ui, screen_in: Rect, st: *State) void {
    var screen = screen_in;
    {
        ui.pushId("pick");
        defer ui.popId();
        var strip = screen.cutTop(22);
        _ = ctl.segmentedFlush(ui, strip.cutLeft(600), "dialog", &st.dialog, &.{ "TRACKS", "FORMAT", "LEVEL", "FILES", "REPORT", "BOUNCE", "SECTION" });
        _ = ui.plate(strip, .{});
    }
    const cx = export_dialog.Context{
        .settings = &st.export_cfg,
        .presets = &st.export_presets,
        .tracks = st.mock_tracks,
        .project = "broken_glass",
        .bpm = 121,
        .range_secs = .{ 192.4, 16, null, 180.2 },
        .sections = &mock_sections,
    };
    switch (st.dialog) {
        0...3 => {
            if (!st.export_dlg.active) export_dialog.open(&st.export_dlg);
            if (ui.in.cmd == false) st.export_dlg.tab = st.dialog;
            _ = export_dialog.draw(ui, screen, &st.export_dlg, cx, null);
            st.dialog = st.export_dlg.tab;
        },
        4 => {
            if (st.export_card.card == null or !st.export_card.active) {
                var card = export_dialog.Card{ .has_mix = true, .lufs = -12.4, .lra = 3.4, .true_peak = -0.6, .gain_db = 1.6, .files = 11, .secs = 196.9 };
                const names = [_][]const u8{ "PIANO", "BITE", "PAD", "SPARKLE L", "LEAD", "SYNTH BASS", "KICK", "SNARE", "PERC", "HATS" };
                for (names, 0..) |n, i| card.addStem(n, -18 - @as(f64, @floatFromInt(i)) * 1.3);
                st.export_card = .{ .active = true, .card = card, .showing_card = true };
            }
            _ = export_dialog.draw(ui, screen, &st.export_card, cx, null);
        },
        6 => {
            // The grooves the dialog lists.
            if (groove_mod.active == null) groove_mod.active = &gallery_groove_cx;
            if (!st.marker_dlg.active) {
                var mk: markers_mod.Markers = .{};
                _ = mk.addSection(0, "intro");
                _ = mk.addSection(32, "verse");
                var tm = tempo_mod.TempoMap.constant(121);
                _ = tm.put(32, 140);
                tm.rebuild();
                const pts = [_]meter_mod.MeterPoint{ .{ .start_bar = 0, .numerator = 4, .denominator = 4 }, .{ .start_bar = 8, .numerator = 7, .denominator = 8 } };
                const mm = meter_mod.MeterMap{ .points = &pts };
                marker_dialog.open(&st.marker_dlg, &mk, .section, 1, &tm, mm);
            }
            _ = marker_dialog.draw(ui, screen, &st.marker_dlg);
        },
        else => {
            st.bounce_dlg.active = true;
            _ = bounce_dialog.draw(ui, screen, &st.bounce_dlg, .{ .clips = 3, .tracks = 2, .seconds = 15.9 }, null);
        },
    }
}

fn header(ui: *Ui, r: Rect, st: *State, build_ms: f64) void {
    ui.pushId("header");
    defer ui.popId();
    // A toolbar is a row of flush tiles: every button, group and display
    // is a full-height section of the bar, split by the bar's own seams.
    var bar = r;
    const logo = ui.plate(bar.cutLeft(52), .{});
    ui.textIn(&ui.fonts.body_bold, logo.insetXY(4, 0), "SLAB", style.accent, .left, true);
    _ = ctl.segmentedFlush(ui, bar.cutLeft(450), "page", &st.page, &.{ "CONTROLS", "DAW", "CONCOCTION", "BROWSER", "DIALOGS" });

    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "UI {d:.2}MS {d}CMD", .{ build_ms, ui.dl.len }) catch "";
    ctl.display(ui, bar.cutRight(168), s, .{ .align_ = .right, .flush = true });
    _ = ctl.button(ui, bar.cutRight(60), "run", &st.running, .{ .kind = .latch, .label = "RUN", .led = style.led_green, .flush = true });
    _ = ctl.button(ui, bar.cutRight(92), "materials", &st.materials_on, .{ .kind = .latch, .label = "MATERIAL", .led = style.led_amber, .flush = true });
    _ = ctl.segmentedFlush(ui, bar.cutRight(108), "zoom", &st.zoom, &.{ "1X", "2X", "3X" });
    const lab = ui.plate(bar.cutRight(48), .{});
    ui.textIn(&ui.fonts.legend, lab, "SCALE", style.text_dim, .center, true);
    _ = ui.plate(bar, .{});
}

// ═════════════════════════════ CONTROLS ═════════════════════════════

fn controlsPage(ui: *Ui, screen: Rect, st: *State) void {
    var s = screen;
    var col_a = s.cutLeft(392);
    var col_b = s.cutLeft(392);
    var col_c = s;

    knobsPanel(ui, col_a.cutTop(196), st);
    slidersPanel(ui, col_a.cutTop(168), st);
    palettePanel(ui, col_a);

    switchesPanel(ui, col_b.cutTop(208), st);
    selectorsPanel(ui, col_b.cutTop(120), st);
    ledsPanel(ui, col_b, st);

    var mrow = col_c.cutTop(212);
    machine(ui, mrow.cutLeft(@min(mrow.w, machineWidth(ui, .m))), st);
    if (mrow.w > 0) _ = ui.plate(mrow, .{});
    displaysPanel(ui, col_c.cutTop(232), st);
    typePanel(ui, col_c);
}

fn knobsPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("knobs");
    defer ui.popId();
    var body = ctl.strip(ui, r, "KNOBS · PLAIN BIPOLAR STEPPED ENCODER");
    const variants = [_]ctl.KnobVariant{ .plain, .bipolar, .stepped, .encoder };
    const labels = [_][]const u8{ "CUTOFF", "PAN", "RANGE", "TUNE" };
    const sizes = [_]ctl.Size{ .l, .m, .s };
    const cw = ctl.knobCell(.l, true)[0] + 12;
    for (sizes, 0..) |sz, si| {
        const cell = ctl.knobCell(sz, true);
        var row = body.cutTop(cell[1]);
        for (variants, 0..) |vr, vi| {
            var buf: [16]u8 = undefined;
            const v = st.knobs[vi][si];
            const readout: ?[]const u8 = switch (vr) {
                .bipolar => std.fmt.bufPrint(&buf, "{d:.0}", .{(v - 0.5) * 100}) catch null,
                .stepped => std.fmt.bufPrint(&buf, "{d}'", .{@as(u32, 32) >> @intFromFloat(@round(v * 3))}) catch null,
                else => null,
            };
            _ = ctl.knob(ui, row.cutLeft(cw), .{ vi, si }, &st.knobs[vi][si], .{
                .size = sz,
                .variant = vr,
                .label = labels[vi],
                .default = if (vr == .bipolar) 0.5 else 0,
                .steps = 4,
                .readout = readout,
            });
        }
        if (si == 0) {
            _ = ctl.knob(ui, row.cutLeft(cw), "mod", &st.mod_knob, .{ .size = sz, .label = "MOD'D", .mod = st.mod_knob + 0.25 * @as(f32, @floatCast(@sin(ui.in.time * 2))) });
        } else if (si == 1) {
            _ = ctl.knob(ui, row.cutLeft(cw), "dis", &st.dis_knob, .{ .size = sz, .label = "OFF", .disabled = true });
        }
    }
}

fn slidersPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("sliders");
    defer ui.popId();
    var body = ctl.strip(ui, r, "SLIDERS · FADER PANEL MINI");
    _ = ctl.slider(ui, body.cutLeft(ctl.sliderWidth(.fader)), "fader", &st.fader, .{ .kind = .fader, .label = "VOL", .default = 0.75 });
    const adsr_l = [_][]const u8{ "A", "D", "S", "R" };
    for (0..4) |i| {
        _ = ctl.slider(ui, body.cutLeft(ctl.sliderWidth(.slider)), .{ "adsr", i }, &st.adsr[i], .{ .kind = .slider, .label = adsr_l[i] });
    }
    for (0..6) |i| {
        _ = ctl.slider(ui, body.cutLeft(ctl.sliderWidth(.mini)), .{ "mini", i }, &st.minis[i], .{ .kind = .mini, .ticks = 5, .show_readout = false });
    }
    var right = body;
    _ = ctl.slider(ui, right.cutTop(52), "pan", &st.pan, .{ .kind = .slider, .horizontal = true, .bipolar = true, .default = 0.5, .label = "PAN" });
    _ = ctl.slider(ui, right.cutTop(48), "hs", &st.hslider, .{ .kind = .mini, .horizontal = true, .label = "SEND", .mod = st.hslider + 0.2 });
}

fn switchesPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("switches");
    defer ui.popId();
    var body = ctl.strip(ui, r, "SWITCHES · LEVER SLIDE LATCH LIT SEGMENTED");
    const t2 = ctl.ToggleOpts{ .label = "SYNC", .marks = &.{ "ON", "OFF" } };
    const t3 = ctl.ToggleOpts{ .positions = 3, .label = "RANGE", .marks = &.{ "HI", "MID", "LO" } };
    var row = body.cutTop(ctl.toggleCell(ui, t2)[1]);
    _ = ctl.toggle(ui, row.cutLeft(ctl.toggleCell(ui, t2)[0] + 8), "lv2", &st.lever2, t2);
    _ = ctl.toggle(ui, row.cutLeft(ctl.toggleCell(ui, t3)[0] + 8), "lv3", &st.lever3, t3);
    const o2 = ctl.SlideOpts{ .label = "KEY", .marks = &.{ "A", "B" } };
    const s2 = ctl.slideCell(ui, o2);
    _ = ctl.slide(ui, row.cutLeft(s2[0] + 8).takeTop(s2[1]), "sl2", &st.slide2, o2);
    const o3 = ctl.SlideOpts{ .positions = 3, .label = "WAVE", .marks = &.{ "~", "/", "#" } };
    const s3 = ctl.slideCell(ui, o3);
    _ = ctl.slide(ui, row.cutLeft(s3[0] + 8).takeTop(s3[1]), "sl3", &st.slide3, o3);

    var buttons = body.cutTop(ctl.buttonHeight(.m));
    _ = ctl.button(ui, buttons.cutLeft(28), "solo", &st.solo, .{ .kind = .latch, .label = "S", .lit = style.led_yellow });
    _ = ctl.button(ui, buttons.cutLeft(28), "mute", &st.mute, .{ .kind = .latch, .label = "M", .lit = style.led_blue });
    _ = ctl.button(ui, buttons.cutLeft(28), "arm", &st.arm, .{ .kind = .latch, .label = "R", .lit = style.rec });
    _ = ctl.button(ui, buttons.cutLeft(56), "tap", null, .{ .label = "TAP" });
    _ = ctl.button(ui, buttons.cutLeft(72), "sync", &st.sync, .{ .kind = .latch, .label = "SYNC", .led = style.led_amber });
    _ = ctl.button(ui, buttons.cutLeft(56), "dis", null, .{ .label = "N/A", .disabled = true });

    _ = ctl.segmented(ui, body.cutTop(ctl.buttonHeight(.m)).takeLeft(240), "range", &st.range, &.{ "16'", "8'", "4'", "2'" });
    // 808-style step row: lit caps, the playing step marked below.
    var steps = body.cutTop(ctl.buttonHeight(.l) + 4);
    const playing: usize = @intFromFloat(@mod(@floor(ui.in.time * 8), 16));
    const sw = @divFloor(steps.w, 16);
    for (0..16) |i| {
        const cr = steps.cutLeft(sw).takeTop(ctl.buttonHeight(.l));
        const lit: Color = if (i % 4 == 0) style.rec else if (i % 4 == 2) style.led_yellow else Color.hex(0xe8e4d8);
        _ = ctl.button(ui, cr, .{ "step", i }, &st.steps[i], .{ .kind = .latch, .lit = lit });
        if (i == playing and st.running) ctl.ledBar(ui, Rect.xywh(cr.x + 4, cr.bottom() + 2, cr.w - 8, 1), .on, style.accent);
    }
}

fn selectorsPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("selectors");
    defer ui.popId();
    var body = ctl.strip(ui, r, "SELECTORS · LIST DISPLAY");
    const waves = [_][]const u8{ "TRI", "SAW", "PULSE", "NOISE" };
    _ = ctl.list(ui, body.cutLeft(ctl.listCell(ui, &waves)[0] + 20), "wave", &st.wave, &waves, "WAVE");
    const octs = [_][]const u8{ "32'", "16'", "8'", "4'" };
    _ = ctl.list(ui, body.cutLeft(ctl.listCell(ui, &octs)[0] + 20), "oct", &st.octave, &octs, "OCT");
    var col = body;
    ui.textIn(&ui.fonts.legend, col.cutTop(12), "PRESET", style.text_dim, .left, true);
    _ = ctl.displaySelect(ui, col.cutTop(ctl.displayHeight(false)).takeLeft(180), "preset", &st.preset, &presets);
    _ = col.cutTop(4);
    var pair = col.cutTop(ctl.LEGEND_H + ctl.displayHeight(false));
    const syncs = [_][]const u8{ "8 BAR", "4 BAR", "2 BAR", "1 BAR", "1/2", "1/2T", "1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T", "1/64" };
    _ = ctl.displayField(ui, pair.cutLeft(ctl.displayFieldCell(ui, &syncs)[0]), "sync", &st.sync_div, &syncs, "SYNC");
    _ = pair.cutLeft(12);
    // Numeric readout: drag the glass, or the ▴▾ inside it.
    const bpm_r = pair.cutLeft(72);
    ui.textIn(&ui.fonts.legend, bpm_r.takeTop(ctl.LEGEND_H), "BPM", style.text_dim, .center, true);
    const glass = Rect.xywh(bpm_r.x, bpm_r.y + ctl.LEGEND_H, bpm_r.w, ctl.displayHeight(false));
    const wid = ui.id("bpm");
    const b = ui.behavior(wid, glass, false);
    if (b.held) st.bpm = std.math.clamp(st.bpm - ui.in.dy * 0.5, 20, 400);
    var buf: [16]u8 = undefined;
    ctl.display(ui, glass, std.fmt.bufPrint(&buf, "{d:.1}", .{st.bpm}) catch "?", .{ .align_ = .left });
    st.bpm = std.math.clamp(@round(st.bpm) + @as(f32, @floatFromInt(ctl.glassSteps(ui, glass, "bpm-steps"))), 20, 400);
}

fn ledsPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("leds");
    defer ui.popId();
    var body = ctl.strip(ui, r, "LEDS · SHAPES STATES LADDERS");
    const shapes = [_]ctl.LedShape{ .round3, .round5, .round7, .square4, .square6, .tri_up, .tri_right };
    const cols = [_]Color{ style.led_red, style.led_green, style.led_amber, style.led_blue, style.vfd };
    const states = [_]ctl.LedState{ .off, .dim, .on, .blink };
    // Pro meters on the right: a graduated stereo pair (centre scale)
    // and a mono meter with its scale on the left.
    const l: f32 = if (st.running) masterLevel(ui) else 0.5;
    const rr: f32 = if (st.running) @floatCast(std.math.clamp(0.5 + 0.4 * @abs(@sin(ui.in.time * 2.3 + 1)), 0, 1)) else 0.45;
    var meters = body.cutRight(96).takeTop(@min(body.h, 200));
    ctl.meterStereo(ui, meters.cutRight(40), "stereo", .{ l, rr }, .{ l * 0.5, rr * 0.5 }, .{});
    _ = meters.cutRight(8);
    ctl.meter(ui, meters.cutRight(32), "mono", rr, rr * 0.6, .{});

    for (states, 0..) |s, si| {
        var row = body.cutTop(20);
        ui.textIn(&ui.fonts.legend, row.cutLeft(44).insetXY(4, 0), @tagName(s), style.text_mute, .left, true);
        for (shapes, 0..) |sh, i| {
            const cell = row.cutLeft(36);
            ctl.led(ui, cell.x + 4, cell.y + 6, sh, s, cols[(i + si) % cols.len]);
        }
    }
    var bars = body.cutTop(14);
    for (cols) |col| ctl.ledBar(ui, bars.cutLeft(60).insetXY(6, 5), .on, col);
    const lvl: f32 = if (st.running) @floatCast(0.5 + 0.45 * @sin(ui.in.time * 3.1) * @abs(@sin(ui.in.time * 0.7))) else 0.4;
    ctl.ladder(ui, body.cutTop(14).insetXY(4, 2), "hl", lvl, .{ .horizontal = true, .segs = 32 });
}

fn displaysPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("displays");
    defer ui.popId();
    var body = ctl.strip(ui, r, "DISPLAYS · MATRIX SCOPE CURVE");
    const t = ui.in.time;
    var row = body.cutTop(ctl.displayHeight(true));
    var b1: [32]u8 = undefined;
    ctl.display(ui, row.cutLeft(136), position(&b1, t), .{ .align_ = .right, .large = true });
    ctl.display(ui, row.cutLeft(112), "118.00", .{ .align_ = .right, .large = true });
    ctl.display(ui, row.cutLeft(64), "4/4", .{ .align_ = .center, .large = true, .color = Color.hex(0xdcecff) });
    ctl.display(ui, row, "OLED", .{ .large = true, .color = Color.hex(0xdcecff) });
    ctl.display(ui, body.cutTop(ctl.displayHeight(false)), "AMBER VFD  CUTOFF 1.25 kHz", .{ .color = Color.hex(0xffb040) });

    var scopes = body;
    var pts: [128]f32 = undefined;
    const ph: f32 = @floatCast(t * 3);
    for (&pts, 0..) |*p, i| {
        const x = @as(f32, @floatFromInt(i)) / 127.0;
        p.* = 0.5 + 0.38 * @sin(x * std.math.tau * 2 + ph) * (0.6 + 0.4 * @sin(ph * 0.37));
    }
    const half = scopes.cutLeft(@divFloor(scopes.w, 2));
    if (st.running) ctl.scope(ui, half, "scope", &pts, style.vfd) else ctl.curve(ui, half, &pts, style.vfd);
    var env: [64]f32 = undefined;
    adsrCurve(&env, st.adsr);
    ctl.curve(ui, scopes, &env, style.vfd);
}

fn position(buf: []u8, t: f64) []const u8 {
    const bar: u32 = @intFromFloat(@floor(t / 2));
    const beat: u32 = @intFromFloat(@mod(@floor(t * 2), 4));
    const six: u32 = @intFromFloat(@mod(@floor(t * 8), 4));
    return std.fmt.bufPrint(buf, "{d:0>3}.{d}.{d}", .{ bar + 1, beat + 1, six + 1 }) catch "";
}

fn adsrCurve(out: []f32, p: [4]f32) void {
    const a = 0.05 + p[0] * 0.3;
    const d = 0.05 + p[1] * 0.3;
    const r = 0.05 + p[3] * 0.3;
    const hold = @max(0.05, 1 - a - d - r);
    for (out, 0..) |*o, i| {
        const x = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(out.len - 1));
        o.* = if (x < a) x / a else if (x < a + d) 1 - (1 - p[2]) * (x - a) / d else if (x < a + d + hold) p[2] else p[2] * @max(0, 1 - (x - a - d - hold) / r);
        o.* = 0.05 + o.* * 0.85;
    }
}

fn palettePanel(ui: *Ui, r: Rect) void {
    var body = ctl.strip(ui, r, "PALETTE · GRAPHITE");
    const Sw = struct { n: []const u8, c: Color };
    const sw = [_]Sw{
        .{ .n = "CHASSIS", .c = style.chassis }, .{ .n = "PANE", .c = style.pane },     .{ .n = "FACE", .c = style.face },
        .{ .n = "FACE HI", .c = style.face_hi }, .{ .n = "WELL", .c = style.well },     .{ .n = "TEXT", .c = style.text },
        .{ .n = "DIM", .c = style.text_dim },    .{ .n = "ACCENT", .c = style.accent }, .{ .n = "PLAY", .c = style.play },
        .{ .n = "REC", .c = style.rec },         .{ .n = "MOD", .c = style.mod },       .{ .n = "VFD", .c = style.vfd },
    };
    var top = body.cutTop(@divFloor(body.h * 2, 3));
    const cols: i32 = 6;
    for (sw, 0..) |s, i| {
        const ii: i32 = @intCast(i);
        var cc = top.cell(cols, 2, @mod(ii, cols), @divFloor(ii, cols)).inset(2);
        const chip = cc.cutTop(cc.h - 12);
        _ = ui.well(chip, s.c);
        ui.textIn(&ui.fonts.legend, cc, s.n, style.text_mute, .left, false);
    }
    // Track colors.
    const n: i32 = style.track.len;
    for (style.track, 0..) |tc, i| {
        const cell = body.cell(n, 1, @intCast(i), 0).inset(2);
        _ = ui.well(cell, tc);
    }
}

fn typePanel(ui: *Ui, r: Rect) void {
    const body = ctl.strip(ui, r, "TYPE · TAMZEN").insetXY(4, 0);
    const f = &ui.fonts;
    _ = ui.text(&f.body_bold, body.x, body.y, "Body bold 8x16 — SM-24 Mono · Glass Arp", style.text);
    _ = ui.text(&f.body, body.x, body.y + 16, "Body 8x16 — The quick brown fox 0123456789 °±…", style.text);
    _ = ui.text(&f.body, body.x, body.y + 32, "Dim / mute: secondary text, hints", style.text_dim);
    _ = ui.engraved(&f.legend_bold, body.x, body.y + 50, "LEGEND BOLD 6X12 · CUTOFF PEAK DRIVE", style.text_dim);
    _ = ui.engraved(&f.legend, body.x, body.y + 64, "LEGEND 6X12 · EG AMT 1.25K -6DB 120BPM", style.text_dim);
}

// ═════════════════════════════ MACHINES ═════════════════════════════

const TITLE_H: i32 = 20;
const SM24_OCTS = [_][]const u8{ "16'", "8'", "4'" };
const STRIP_HEAD: i32 = 14;

/// Natural width of the SM-24 faceplate at a tier: the sum of its strips.
fn machineWidth(ui: *const Ui, sz: ctl.Size) i32 {
    const cw = ctl.knobCell(sz, true)[0] + 4;
    return (ctl.listCell(ui, &SM24_OCTS)[0] + cw + 6) + cw * 2 + (ctl.sliderWidth(.slider) * 4 + 4);
}

/// Natural height at a tier: title strip, strip header, two knob rows,
/// the bottom seam.
fn machineHeight(sz: ctl.Size) i32 {
    return TITLE_H + STRIP_HEAD + 2 * ctl.knobCell(sz, true)[1] + 1;
}

/// Largest tier whose natural height fits `h`, or null (collapsed).
fn tierFor(h: i32) ?ctl.Size {
    for ([_]ctl.Size{ .l, .m, .s }) |sz| if (machineHeight(sz) <= h) return sz;
    return null;
}

/// A machine faceplate at its natural size: title strip + packed strips.
/// Collapsed (no tier fits) it shows only the title strip.
fn machine(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("sm24");
    defer ui.popId();
    var plate = r;
    ctl.titleStrip(ui, plate.cutTop(TITLE_H), "SM-24 MONO", presets[st.preset]);
    const sz = tierFor(r.h) orelse return;
    var body = plate;
    const cell = ctl.knobCell(sz, true);
    const cw = cell[0] + 4;
    // VCO
    var vco = ctl.strip(ui, body.cutLeft(ctl.listCell(ui, &SM24_OCTS)[0] + cw + 6), "VCO");
    _ = ctl.list(ui, vco.cutLeft(ctl.listCell(ui, &SM24_OCTS)[0] + 6), "oct", &st.m_oct, &SM24_OCTS, "OCT");
    _ = ctl.knob(ui, vco.cutTop(cell[1]), "wave", &st.m_wave, .{ .size = sz, .label = "WAVE" });
    _ = ctl.knob(ui, vco.cutTop(cell[1]), "det", &st.m_det, .{ .size = sz, .label = "DETUNE", .variant = .bipolar, .default = 0.5 });
    // VCF
    var vcf = ctl.strip(ui, body.cutLeft(cw * 2), "VCF");
    var fr1 = vcf.cutTop(cell[1]);
    var cbuf: [16]u8 = undefined;
    const hz = 20 * std.math.pow(f32, 1000, st.m_cut);
    const cut_s = if (hz >= 1000) std.fmt.bufPrint(&cbuf, "{d:.2}k", .{hz / 1000}) catch "" else std.fmt.bufPrint(&cbuf, "{d:.0}", .{hz}) catch "";
    _ = ctl.knob(ui, fr1.cutLeft(cw), "cut", &st.m_cut, .{ .size = sz, .label = "CUTOFF", .readout = cut_s, .mod = st.m_cut + st.m_env * 0.2 });
    _ = ctl.knob(ui, fr1, "res", &st.m_res, .{ .size = sz, .label = "PEAK" });
    var fr2 = vcf.cutTop(cell[1]);
    _ = ctl.knob(ui, fr2.cutLeft(cw), "env", &st.m_env, .{ .size = sz, .label = "EG AMT" });
    _ = ctl.knob(ui, fr2, "drv", &st.m_drv, .{ .size = sz, .label = "DRIVE" });
    // ENV
    var eg = ctl.strip(ui, body.cutLeft(ctl.sliderWidth(.slider) * 4 + 4), "ENV");
    var env_pts: [64]f32 = undefined;
    adsrCurve(&env_pts, st.m_adsr);
    ctl.curve(ui, eg.cutTop(36), &env_pts, style.vfd);
    const lab = [_][]const u8{ "A", "D", "S", "R" };
    for (0..4) |i| _ = ctl.slider(ui, eg.cutLeft(ctl.sliderWidth(.slider)), .{ "eg", i }, &st.m_adsr[i], .{ .label = lab[i], .show_readout = false });
    // Remaining width: an empty blank plate (nothing floats on chassis).
    if (body.w > 0) _ = ui.plate(body, .{});
}

fn delay(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("delay");
    defer ui.popId();
    var plate = r;
    ctl.titleStrip(ui, plate.cutTop(TITLE_H), "DELAY", "TAPE ECHO");
    if (tierFor(r.h) == null) return;
    var body = ctl.strip(ui, plate, "");
    const cell = ctl.knobCell(.m, true);
    var row = body.cutTop(cell[1]);
    _ = ctl.knob(ui, row.cutLeft(cell[0] + 4), "time", &st.d_time, .{ .label = "TIME" });
    _ = ctl.knob(ui, row.cutLeft(cell[0] + 4), "fb", &st.d_fb, .{ .label = "FEEDBK" });
    _ = ctl.knob(ui, row.cutLeft(cell[0] + 4), "mix", &st.d_mix, .{ .label = "MIX" });
    const so = ctl.SlideOpts{ .label = "SYNC", .marks = &.{ "HZ", "BPM" } };
    const sc = ctl.slideCell(ui, so);
    _ = ctl.slide(ui, body.cutTop(sc[1]).takeLeft(sc[0] + 8), "sync", &st.d_sync, so);
}

// ═════════════════════════════ DAW ══════════════════════════════════

const Clip = struct { track: u8, start: f32, len: f32, name: []const u8, notes: []const surf.MiniNote };

var bass_notes: [32]surf.MiniNote = undefined;
var chord_notes: [24]surf.MiniNote = undefined;
var arp_notes: [64]surf.MiniNote = undefined;
var drum_notes: [48]surf.MiniNote = undefined;

fn genNotes() void {
    const bass = [_]u8{ 36, 36, 43, 36, 39, 36, 43, 46 };
    for (&bass_notes, 0..) |*n, i| n.* = .{ .beat = @as(f32, @floatFromInt(i)) * 0.5, .len = 0.4, .pitch = bass[i % 8] + (if (i >= 16) @as(u8, 5) else 0), .vel = if (i % 4 == 0) 1.0 else 0.6 };
    const chords = [_][3]u8{ .{ 60, 63, 67 }, .{ 58, 62, 65 }, .{ 56, 60, 63 }, .{ 55, 58, 62 } };
    for (0..8) |k| for (0..3) |j| {
        chord_notes[k * 3 + j] = .{ .beat = @as(f32, @floatFromInt(k)) * 2, .len = 1.8, .pitch = chords[k % 4][j], .vel = 0.7 };
    };
    for (&arp_notes, 0..) |*n, i| n.* = .{ .beat = @as(f32, @floatFromInt(i)) * 0.25, .len = 0.2, .pitch = @intCast(72 + (i * 7) % 12), .vel = 0.5 + 0.5 * @as(f32, @floatFromInt((i * 5) % 7)) / 7 };
    for (&drum_notes, 0..) |*n, i| {
        const lane: u8 = @intCast(i % 3);
        n.* = .{ .beat = @as(f32, @floatFromInt(i / 3)) * 0.5 + (if (lane == 1) @as(f32, 0.5) else 0), .len = 0.2, .pitch = 36 + lane * 2, .vel = 0.9 };
    }
}

fn dawPage(ui: *Ui, screen: Rect, st: *State) void {
    var s = screen;
    transport(ui, s.cutTop(32), st);
    // Machine bay: snaps between the machines' natural-size tiers;
    // double-click the seam to fold it to its title strips.
    const tiers = [_]i32{ machineHeight(.s), machineHeight(.m), machineHeight(.l) };
    if (st.bay_h == 0) st.bay_h = tiers[1];
    const v = ctl.split(ui, s, "bay", &st.bay_h, .{ .from_end = true, .min = tiers[0], .min_other = 140, .snap = &tiers, .collapsed = TITLE_H });
    // Piano roll: continuous; double-click folds it to its title strip.
    const h = ctl.split(ui, v[0], "roll", &st.roll_h, .{ .from_end = true, .min = 96, .min_other = 100, .collapsed = TITLE_H });
    arrangement(ui, h[0], st);
    pianoRoll(ui, h[1], st);
    var b = v[1];
    const sz = tierFor(b.h) orelse .s;
    machine(ui, b.cutLeft(@min(b.w, machineWidth(ui, sz))), st);
    if (b.w > 0) delay(ui, b.cutLeft(@min(b.w, 176)), st);
    if (b.w > 0) _ = ui.plate(b, .{});
}

fn beatNow(ui: *const Ui, st: *const State) f32 {
    if (!st.playing) return 8;
    return @floatCast(@mod(ui.in.time * 2, 32));
}

fn transport(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("transport");
    defer ui.popId();
    var bar = r;
    var stop_on = !st.playing;
    if (ctl.button(ui, bar.cutLeft(36), "stop", &stop_on, .{ .glyph = .square6, .glyph_on = style.text, .flush = true })) st.playing = false;
    if (ctl.button(ui, bar.cutLeft(36), "play", &st.playing, .{ .glyph = .tri_right, .glyph_on = style.play, .flush = true })) st.playing = true;
    _ = ctl.button(ui, bar.cutLeft(36), "rec", &st.rec, .{ .kind = .latch, .glyph = .round7, .glyph_on = style.rec, .flush = true });
    _ = ctl.button(ui, bar.cutLeft(52), "loop", &st.loop_on, .{ .kind = .latch, .label = "LOOP", .lit = style.accent, .flush = true });
    var buf: [32]u8 = undefined;
    const b = beatNow(ui, st);
    const bar_n: u32 = @intFromFloat(@floor(b / 4));
    const beat: u32 = @intFromFloat(@mod(@floor(b), 4));
    const six: u32 = @intFromFloat(@mod(@floor(b * 4), 4));
    const pos = std.fmt.bufPrint(&buf, "{d:0>3}.{d}.{d}", .{ bar_n + 1, beat + 1, six + 1 }) catch "";
    ctl.display(ui, bar.cutLeft(140), pos, .{ .align_ = .right, .large = true, .flush = true });
    ctl.display(ui, bar.cutLeft(116), "118.00", .{ .align_ = .right, .large = true, .flush = true });
    ctl.display(ui, bar.cutLeft(64), "4/4", .{ .align_ = .center, .large = true, .flush = true });
    _ = ctl.button(ui, bar.cutLeft(80), "metro", &st.metro, .{ .kind = .latch, .label = "METRO", .led = style.led_amber, .flush = true });
    _ = ctl.button(ui, bar.cutLeft(52), "tap", null, .{ .label = "TAP", .flush = true });
    // Master meter tile at the far right: graduated stereo bargraph.
    const lvl: f32 = if (st.playing) masterLevel(ui) else 0;
    const mt = ui.plate(bar.cutRight(240), .{});
    ctl.meterStereo(ui, mt, "master", .{ lvl, lvl * 0.93 }, .{ lvl * 0.55, lvl * 0.5 }, .{ .horizontal = true });
    _ = ui.plate(bar, .{});
}

/// A plausible programme level: busy, occasionally kissing 0 dBFS.
fn masterLevel(ui: *const Ui) f32 {
    const t = ui.in.time;
    const env = 0.55 + 0.35 * @abs(@sin(t * 1.7)) + 0.12 * @sin(t * 11.0);
    return @floatCast(std.math.clamp(env, 0, 1.02));
}

fn arrangement(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("arrange");
    defer ui.popId();
    const cols = ctl.split(ui, r, "headers", &st.headers_w, .{ .axis = .cols, .from_end = true, .min = 150, .min_other = 240 });
    var area = cols[0];
    var headers = cols[1];
    const v = surf.TimeView{ .start = 0, .ppb = @as(f32, @floatFromInt(area.w)) / 40.0 };
    const head = beatNow(ui, st);
    surf.ruler(ui, area.cutTop(20), v, if (st.loop_on) .{ 0, 32 } else null, head);
    // Header column top: "TRACKS" plate aligned with the ruler.
    const th = ui.plate(headers.cutTop(20), .{});
    ui.textIn(&ui.fonts.legend, th.insetXY(4, 0), "TRACKS", style.text_dim, .left, true);

    const lane_h: i32 = 40;
    const clips = [_]Clip{
        .{ .track = 0, .start = 0, .len = 16, .name = "Punch Bass", .notes = &bass_notes },
        .{ .track = 0, .start = 16, .len = 16, .name = "Punch Bass 2", .notes = &bass_notes },
        .{ .track = 1, .start = 0, .len = 16, .name = "Lush Chords", .notes = &chord_notes },
        .{ .track = 2, .start = 8, .len = 16, .name = "Glass Arp", .notes = &arp_notes },
        .{ .track = 3, .start = 0, .len = 24, .name = "Beat A", .notes = &drum_notes },
        .{ .track = 4, .start = 20, .len = 8, .name = "Take 3", .notes = &.{} },
    };
    var lanes = area;
    for (&st.tracks, 0..) |*t, i| {
        const auto = i == 1;
        const h = lane_h + (if (auto) @as(i32, 28) else 0);
        var lane = lanes.cutTop(h);
        const hr = headers.cutTop(h);
        const auto_r = if (auto) lane.cutBottom(28) else Rect{};
        surf.timeGrid(ui, lane, v, if (t.selected) style.pane_alt else style.pane);
        ui.rect(Rect.xywh(lane.x, lane.bottom() - 1, lane.w, 1), style.chassis);
        for (clips) |cl| {
            if (cl.track != i) continue;
            surf.clip(ui, Rect.xywh(lane.x, lane.y, lane.w, lane.h - 1), v, cl.start, cl.len, cl.name, t.color, cl.notes, i == 0 and cl.start == 0);
        }
        if (auto) {
            surf.timeGrid(ui, auto_r, v, style.pane);
            const pts = [_][2]f32{ .{ 0, 0.2 }, .{ 8, 0.8 }, .{ 12, 0.5 }, .{ 24, 0.5 }, .{ 32, 0.1 } };
            surf.automation(ui, auto_r, v, &pts, t.color);
            _ = ui.text(&ui.fonts.legend, auto_r.x + 3, auto_r.y + 1, "CUTOFF", style.text_mute);
            ui.rect(Rect.xywh(auto_r.x, auto_r.bottom() - 1, auto_r.w, 1), style.chassis);
        }
        t.level = if (st.playing and !t.mute) @floatCast(0.4 + 0.35 * @abs(@sin(ui.in.time * (3 + @as(f64, @floatFromInt(i)))))) else 0;
        surf.trackHeader(ui, hr, i, t);
    }
    // Empty lane space below the tracks keeps the grid; headers column
    // below ends in the master strip.
    surf.timeGrid(ui, lanes, v, style.pane);
    surf.playhead(ui, Rect.xywh(area.x, area.y, area.w, area.h), v, head);
    var mh = headers;
    const master = mh.cutBottom(@min(mh.h, 40));
    if (mh.h > 0) _ = ui.plate(mh, .{ .fill = style.face.shade(-6) });
    var master_t = surf.TrackUi{ .name = "MASTER", .color = style.text_dim, .volume = st.master_vol, .level = if (st.playing) 0.7 else 0 };
    surf.trackHeader(ui, master, "master", &master_t);
    st.master_vol = master_t.volume;
}

fn pianoRoll(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("roll");
    defer ui.popId();
    var area = r;
    // Pane title strip.
    var title = ui.plate(area.cutTop(20), .{});
    const tc = style.track[0];
    ui.rect(Rect.xywh(title.x - 1, title.y - 1, 3, title.h + 1), tc);
    _ = title.cutLeft(6);
    ui.textIn(&ui.fonts.body_bold, title.cutLeft(200), "Punch Bass", style.text, .left, true);
    ui.textIn(&ui.fonts.legend, title.cutLeft(120), "BASS · 16 BEATS", style.text_mute, .left, true);
    if (area.h < 60) {
        if (area.h > 0) _ = ui.plate(area, .{});
        return;
    }

    const keys_w: i32 = 44;
    const vel_h: i32 = 44;
    var main = area;
    var keys_col = main.cutLeft(keys_w);
    const v = surf.TimeView{ .start = 0, .ppb = @as(f32, @floatFromInt(main.w)) / 16.0 };
    const head = @mod(beatNow(ui, st), 16);
    surf.ruler(ui, main.cutTop(20), v, null, head);
    _ = ui.plate(keys_col.cutTop(20), .{});
    const vel = main.cutBottom(vel_h);
    const vel_key = keys_col.cutBottom(vel_h);
    const vk = ui.plate(vel_key, .{});
    ui.textIn(&ui.fonts.legend, vk.insetXY(4, 0), "VEL", style.text_dim, .left, true);

    const p = surf.PitchView{ .top = 52, .row_h = 10 };
    surf.pianoKeys(ui, keys_col, p);
    surf.noteGrid(ui, main, v, p);
    ui.clip(main);
    for (bass_notes, 0..) |n, i| surf.note(ui, main, v, p, n, tc, i == 4 or i == 5);
    ui.unclip();
    surf.playhead(ui, main, v, head);
    surf.velocityLane(ui, vel, v, &bass_notes, tc);
    ui.rect(Rect.xywh(vel.x, vel.y, vel.w, 1), style.chassis);
}
