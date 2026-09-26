//! `slab --gallery` (docs/06 §The gallery): every material, token, type
//! strike, display and control family × size × state on one screen, with
//! a scale selector and a materials-off switch. The look is tuned here
//! before panes adopt it.

const std = @import("std");
const c = @import("../c.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;

const State = struct {
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
    latches: [8]bool = .{ true, false, false, true, false, false, true, false },
    solo: bool = false,
    mute: bool = true,
    arm: bool = false,
    range: u8 = 1,
    wave: u8 = 1,
    octave: u8 = 2,
    preset: u8 = 3,
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
};

const ZOOMS = [_]f32{ 1, 2, 3 };

const presets = [_][]const u8{ "INIT", "ACID-BASS", "BUZZ-LEAD", "RUBBER-BASS", "GLASS-ARP", "LUSH-PAD" };

pub fn run(alloc: std.mem.Allocator) !void {
    c.rl.SetConfigFlags(c.rl.FLAG_WINDOW_RESIZABLE | c.rl.FLAG_VSYNC_HINT | c.rl.FLAG_WINDOW_HIGHDPI);
    c.rl.InitWindow(1280, 820, "slab gallery");
    defer c.rl.CloseWindow();
    c.rl.SetTargetFPS(120);
    c.rl.SetExitKey(c.rl.KEY_NULL);

    const ui = try Ui.init(alloc);
    defer ui.deinit(alloc);

    var st = State{};
    var build_ms: f64 = 0;
    while (!c.rl.WindowShouldClose()) {
        ui.renderer.zoom = ZOOMS[st.zoom];
        style.materials = if (st.materials_on) .{} else style.materials_off;
        const t0 = c.rl.GetTime();
        ui.beginFrame();
        frame(ui, &st, build_ms);
        if (st.running) ui.animate();
        build_ms = build_ms * 0.9 + (c.rl.GetTime() - t0) * 1000 * 0.1;
        // Idle screens wait for events instead of redrawing at 120 fps.
        if (ui.wants_frame) c.rl.DisableEventWaiting() else c.rl.EnableEventWaiting();
        ui.endFrame();
    }
}

fn frame(ui: *Ui, st: *State, build_ms: f64) void {
    const z = ui.renderer.zoom;
    const sw: i32 = @intFromFloat(@as(f32, @floatFromInt(c.rl.GetScreenWidth())) / z);
    const sh: i32 = @intFromFloat(@as(f32, @floatFromInt(c.rl.GetScreenHeight())) / z);
    var screen = Rect.xywh(0, 0, sw, sh);
    ui.chassis(screen);

    header(ui, screen.cutTop(24), st, build_ms);
    screen = screen.inset(4);

    var col_a = screen.cutLeft(372);
    _ = screen.cutLeft(4);
    var col_b = screen.cutLeft(360);
    _ = screen.cutLeft(4);
    var col_c = screen;

    knobsPanel(ui, col_a.cutTop(236), st);
    _ = col_a.cutTop(4);
    slidersPanel(ui, col_a.cutTop(148), st);
    _ = col_a.cutTop(4);
    palettePanel(ui, col_a.cutTop(@min(col_a.h, 150)));

    switchesPanel(ui, col_b.cutTop(196), st);
    _ = col_b.cutTop(4);
    selectorsPanel(ui, col_b.cutTop(96), st);
    _ = col_b.cutTop(4);
    ledsPanel(ui, col_b.cutTop(@min(col_b.h, 188)), st);

    machinePanel(ui, col_c.cutTop(172), st);
    _ = col_c.cutTop(4);
    displaysPanel(ui, col_c.cutTop(@min(col_c.h, 196)), st);
    _ = col_c.cutTop(4);
    if (col_c.h > 40) typePanel(ui, col_c);
}

fn header(ui: *Ui, r: Rect, st: *State, build_ms: f64) void {
    ui.pushId("header");
    defer ui.popId();
    var body = ui.plate(r, .{});
    _ = body.cutLeft(4);
    const title = body.cutLeft(120);
    ui.textIn(&ui.fonts.title, title, "SLAB", style.accent, .left, true);
    ui.textIn(&ui.fonts.legend, Rect.xywh(title.x + 40, title.y, 80, title.h), "UI GALLERY", style.text_dim, .left, true);

    var right = body;
    const perf_r = right.cutRight(180).insetXY(2, 3);
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "UI {d:.2}MS {d}CMD", .{ build_ms, ui.dl.len }) catch "";
    ctl.display(ui, perf_r, s, .{ .align_ = .right });
    _ = right.cutRight(6);
    const run_r = right.cutRight(52).insetXY(2, 4);
    _ = ctl.button(ui, run_r, "run", &st.running, .{ .kind = .latch, .label = "RUN", .led = style.led_green });
    _ = right.cutRight(6);
    const mat_r = right.cutRight(72).insetXY(2, 4);
    _ = ctl.button(ui, mat_r, "materials", &st.materials_on, .{ .kind = .latch, .label = "MATERIAL", .led = style.led_amber });
    _ = right.cutRight(6);
    const zoom_r = right.cutRight(84).insetXY(2, 4);
    _ = ctl.segmented(ui, zoom_r, "zoom", &st.zoom, &.{ "1X", "2X", "3X" });
    _ = right.cutRight(4);
    ui.textIn(&ui.fonts.legend, right.cutRight(28), "SCALE", style.text_dim, .right, true);
}

fn section(ui: *Ui, r: Rect, title: []const u8) Rect {
    return ctl.strip(ui, r, title).inset(3);
}

fn knobsPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("knobs");
    defer ui.popId();
    var body = section(ui, r, "KNOBS  ·  PLAIN  BIPOLAR  STEPPED  ENCODER");
    const variants = [_]ctl.KnobVariant{ .plain, .bipolar, .stepped, .encoder };
    const labels = [_][]const u8{ "CUTOFF", "PAN", "RANGE", "TUNE" };
    const sizes = [_]ctl.Size{ .l, .m, .s };
    for (sizes, 0..) |sz, si| {
        const cell = ctl.knobCell(sz);
        var row = body.cutTop(cell[1] + 4);
        for (variants, 0..) |vr, vi| {
            const cr = row.cutLeft(cell[0] + 12);
            var buf: [16]u8 = undefined;
            const v = st.knobs[vi][si];
            const readout: ?[]const u8 = switch (vr) {
                .bipolar => std.fmt.bufPrint(&buf, "{d:.0}", .{(v - 0.5) * 100}) catch null,
                .stepped => std.fmt.bufPrint(&buf, "{d}'", .{@as(u32, 32) >> @intFromFloat(@round(v * 3))}) catch null,
                else => null,
            };
            _ = ctl.knob(ui, cr, .{ vi, si }, &st.knobs[vi][si], .{
                .size = sz,
                .variant = vr,
                .label = labels[vi],
                .default = if (vr == .bipolar) 0.5 else 0,
                .steps = 4,
                .readout = readout,
            });
        }
        if (si == 0) {
            const cr = row.cutLeft(cell[0] + 12);
            _ = ctl.knob(ui, cr, "mod", &st.mod_knob, .{ .size = sz, .label = "MOD'D", .mod = st.mod_knob + 0.25 * @as(f32, @floatCast(@sin(ui.in.time * 2))) });
            ui.animate();
        } else if (si == 1) {
            const cr = row.cutLeft(cell[0] + 12);
            _ = ctl.knob(ui, cr, "dis", &st.dis_knob, .{ .size = sz, .label = "OFF", .disabled = true });
        }
    }
}

fn slidersPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("sliders");
    defer ui.popId();
    var body = section(ui, r, "SLIDERS  ·  FADER  PANEL  MINI");
    const w_f = ctl.sliderWidth(.fader);
    _ = ctl.slider(ui, body.cutLeft(w_f), "fader", &st.fader, .{ .kind = .fader, .label = "VOL", .default = 0.75 });
    _ = body.cutLeft(6);
    const adsr_l = [_][]const u8{ "A", "D", "S", "R" };
    for (0..4) |i| {
        _ = ctl.slider(ui, body.cutLeft(ctl.sliderWidth(.slider)), .{ "adsr", i }, &st.adsr[i], .{ .kind = .slider, .label = adsr_l[i] });
    }
    _ = body.cutLeft(6);
    for (0..6) |i| {
        _ = ctl.slider(ui, body.cutLeft(ctl.sliderWidth(.mini)), .{ "mini", i }, &st.minis[i], .{ .kind = .mini, .ticks = 5, .show_readout = false });
    }
    _ = body.cutLeft(6);
    var right = body;
    _ = ctl.slider(ui, right.cutTop(40), "pan", &st.pan, .{ .kind = .slider, .horizontal = true, .bipolar = true, .default = 0.5, .label = "PAN" });
    _ = ctl.slider(ui, right.cutTop(40), "hs", &st.hslider, .{ .kind = .mini, .horizontal = true, .label = "SEND", .mod = st.hslider + 0.2 });
}

fn switchesPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("switches");
    defer ui.popId();
    var body = section(ui, r, "SWITCHES  ·  LEVER  SLIDE  LATCH  LIT  SEGMENTED");
    var row = body.cutTop(ctl.toggleCell()[1] + 4);
    const tc = ctl.toggleCell();
    _ = ctl.toggle(ui, row.cutLeft(tc[0] + 8), "lv2", &st.lever2, .{ .label = "SYNC", .marks = &.{ "ON", "OFF" } });
    _ = ctl.toggle(ui, row.cutLeft(tc[0] + 8), "lv3", &st.lever3, .{ .positions = 3, .label = "RANGE", .marks = &.{ "HI", "MID", "LO" } });
    _ = row.cutLeft(8);
    const s2 = ctl.slideCell(2);
    _ = ctl.slide(ui, row.cutLeft(s2[0] + 8).takeTop(s2[1]), "sl2", &st.slide2, .{ .label = "KEY", .marks = &.{ "A", "B" } });
    const s3 = ctl.slideCell(3);
    _ = ctl.slide(ui, row.cutLeft(s3[0] + 8).takeTop(s3[1]), "sl3", &st.slide3, .{ .positions = 3, .label = "WAVE", .marks = &.{ "~", "/", "#" } });

    _ = body.cutTop(2);
    var buttons = body.cutTop(16);
    _ = ctl.button(ui, buttons.cutLeft(28), "solo", &st.solo, .{ .kind = .latch, .label = "S", .lit = style.led_yellow });
    _ = buttons.cutLeft(2);
    _ = ctl.button(ui, buttons.cutLeft(28), "mute", &st.mute, .{ .kind = .latch, .label = "M", .lit = style.led_blue });
    _ = buttons.cutLeft(2);
    _ = ctl.button(ui, buttons.cutLeft(28), "arm", &st.arm, .{ .kind = .latch, .label = "R", .lit = style.rec });
    _ = buttons.cutLeft(8);
    _ = ctl.button(ui, buttons.cutLeft(56), "tap", null, .{ .label = "TAP" });
    _ = buttons.cutLeft(4);
    _ = ctl.button(ui, buttons.cutLeft(64), "sync", &st.latches[0], .{ .kind = .latch, .label = "SYNC", .led = style.led_amber });
    _ = buttons.cutLeft(4);
    _ = ctl.button(ui, buttons.cutLeft(56), "dis", null, .{ .label = "N/A", .disabled = true });

    _ = body.cutTop(6);
    _ = ctl.segmented(ui, body.cutTop(16).takeLeft(200), "range", &st.range, &.{ "16'", "8'", "4'", "2'" });
    _ = body.cutTop(6);
    // 808-style step row: lit caps, the playing step blinks.
    var steps = body.cutTop(20);
    const playing: usize = @intFromFloat(@mod(@floor(ui.in.time * 8), 16));
    for (0..16) |i| {
        const cr = steps.cutLeft(20).insetXY(1, 0);
        const lit: Color = if (i % 4 == 0) style.rec else if (i % 4 == 2) style.led_yellow else Color.hex(0xe8e0c8);
        _ = ctl.button(ui, cr, .{ "step", i }, &st.steps[i], .{ .kind = .latch, .lit = lit });
        if (i == playing and st.running) ctl.ledBar(ui, Rect.xywh(cr.x + 4, cr.bottom() + 2, cr.w - 8, 1), .on, style.accent);
    }
}

fn selectorsPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("selectors");
    defer ui.popId();
    var body = section(ui, r, "SELECTORS  ·  LIST  DISPLAY");
    const waves = [_][]const u8{ "TRI", "SAW", "PULSE", "NOISE" };
    const lc = ctl.listCell(waves.len);
    _ = ctl.list(ui, body.cutLeft(lc[0] + 16), "wave", &st.wave, &waves, "WAVE");
    const octs = [_][]const u8{ "32'", "16'", "8'", "4'" };
    _ = ctl.list(ui, body.cutLeft(lc[0] + 16), "oct", &st.octave, &octs, "OCT");
    _ = body.cutLeft(8);
    var col = body;
    ui.textIn(&ui.fonts.legend, col.cutTop(10), "PRESET", style.text_dim, .left, true);
    _ = ctl.displaySelect(ui, col.cutTop(ctl.displayHeight()).takeLeft(152), "preset", &st.preset, &presets);
}

fn ledsPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("leds");
    defer ui.popId();
    var body = section(ui, r, "LEDS  ·  SHAPES  STATES  LADDERS");
    const shapes = [_]ctl.LedShape{ .round3, .round5, .round7, .square4, .square6, .tri_up, .tri_right };
    const cols = [_]Color{ style.led_red, style.led_green, style.led_amber, style.led_blue, style.phosphor };
    const states = [_]ctl.LedState{ .off, .dim, .on, .blink };
    var grid = body.cutLeft(250);
    for (states, 0..) |s, si| {
        var row = grid.cutTop(20);
        ui.textIn(&ui.fonts.legend, row.cutLeft(34), @tagName(s), style.text_mute, .left, true);
        for (shapes, 0..) |sh, i| {
            const cell = row.cutLeft(30);
            ctl.led(ui, cell.x + 4, cell.y + 6, sh, s, cols[(i + si) % cols.len]);
        }
    }
    _ = grid.cutTop(4);
    var bars = grid.cutTop(12);
    for (cols) |col| {
        ctl.ledBar(ui, bars.cutLeft(40).insetXY(4, 4), .on, col);
    }
    _ = grid.cutTop(6);
    // Horizontal ladder.
    const lvl: f32 = if (st.running) @floatCast(0.5 + 0.45 * @sin(ui.in.time * 3.1) * @abs(@sin(ui.in.time * 0.7))) else 0.4;
    ctl.ladder(ui, grid.cutTop(10).takeLeft(236), "hl", lvl, .{ .horizontal = true, .segs = 24 });

    _ = body.cutLeft(8);
    // Vertical stereo ladders.
    const l: f32 = if (st.running) @floatCast(0.55 + 0.4 * @sin(ui.in.time * 5.3) * @abs(@sin(ui.in.time * 1.3))) else 0.6;
    const rr: f32 = if (st.running) @floatCast(0.5 + 0.45 * @sin(ui.in.time * 4.1 + 1) * @abs(@sin(ui.in.time * 1.1))) else 0.55;
    ctl.ladder(ui, body.cutLeft(8).takeTop(@min(body.h, 140)), "vl", l, .{ .segs = 20 });
    _ = body.cutLeft(2);
    ctl.ladder(ui, body.cutLeft(8).takeTop(@min(body.h, 140)), "vr", rr, .{ .segs = 20 });
}

fn displaysPanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("displays");
    defer ui.popId();
    var body = section(ui, r, "DISPLAYS  ·  MATRIX  SCOPE  CURVE");
    // Transport-style readouts.
    var row = body.cutTop(ctl.displayHeight());
    const t = ui.in.time;
    var b1: [32]u8 = undefined;
    const bar: u32 = @intFromFloat(@floor(t / 2));
    const beat: u32 = @intFromFloat(@mod(@floor(t * 2), 4));
    const pos = std.fmt.bufPrint(&b1, "{d:0>3}.{d}.{d}", .{ bar + 1, beat + 1, @as(u32, @intFromFloat(@mod(@floor(t * 8), 4))) + 1 }) catch "";
    ctl.display(ui, row.cutLeft(80), pos, .{ .align_ = .right });
    _ = row.cutLeft(4);
    ctl.display(ui, row.cutLeft(68), "118.00", .{ .align_ = .right, .color = style.phosphor });
    _ = row.cutLeft(4);
    ctl.display(ui, row.cutLeft(44), "4/4", .{ .align_ = .center, .color = Color.hex(0xd8ecff) });
    _ = row.cutLeft(4);
    ctl.display(ui, row, "OLED WHITE", .{ .color = Color.hex(0xd8ecff) });
    _ = body.cutTop(4);
    ctl.display(ui, body.cutTop(ctl.displayHeight()), "AMBER VFD  CUTOFF 1.25 kHz", .{ .color = Color.hex(0xffb040) });
    _ = body.cutTop(4);

    var scopes = body;
    const w = @divFloor(scopes.w - 4, 2);
    var pts: [128]f32 = undefined;
    const ph: f32 = @floatCast(t * 3);
    for (&pts, 0..) |*p, i| {
        const x = @as(f32, @floatFromInt(i)) / 127.0;
        p.* = 0.5 + 0.38 * @sin(x * std.math.tau * 2 + ph) * (0.6 + 0.4 * @sin(ph * 0.37));
    }
    if (st.running) ctl.scope(ui, scopes.cutLeft(w), "scope", &pts, style.phosphor) else ctl.curve(ui, scopes.cutLeft(w), &pts, style.phosphor);
    _ = scopes.cutLeft(4);
    var env: [64]f32 = undefined;
    adsrCurve(&env, st.adsr);
    ctl.curve(ui, scopes, &env, style.phosphor);
}

fn adsrCurve(out: []f32, p: [4]f32) void {
    // Attack, decay to sustain, hold, release — segment widths from p.
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

fn machinePanel(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("machine");
    defer ui.popId();
    var plate = r;
    ctl.titleStrip(ui, plate.cutTop(20), "SM-24 MONO", presets[st.preset]);
    _ = plate.cutTop(2);
    var body = plate;
    const cell = ctl.knobCell(.m);
    // VCO strip
    var vco = ctl.strip(ui, body.cutLeft(cell[0] * 2 + 48), "VCO").inset(2);
    const octs = [_][]const u8{ "16'", "8'", "4'" };
    _ = ctl.list(ui, vco.cutLeft(36), "oct", &st.m_oct, &octs, "OCT");
    var vk = vco;
    _ = ctl.knob(ui, vk.cutTop(cell[1]).takeLeft(cell[0] + 4), "wave", &st.m_wave, .{ .label = "WAVE" });
    _ = ctl.knob(ui, vk.cutTop(cell[1]).takeLeft(cell[0] + 4), "det", &st.m_det, .{ .label = "DETUNE", .variant = .bipolar, .default = 0.5 });
    _ = body.cutLeft(2);
    // Filter strip
    var vcf = ctl.strip(ui, body.cutLeft(cell[0] * 2 + 16), "VCF").inset(2);
    var fr1 = vcf.cutTop(cell[1]);
    var cbuf: [16]u8 = undefined;
    const hz = 20 * std.math.pow(f32, 1000, st.m_cut);
    const cut_s = if (hz >= 1000) std.fmt.bufPrint(&cbuf, "{d:.2}k", .{hz / 1000}) catch "" else std.fmt.bufPrint(&cbuf, "{d:.0}", .{hz}) catch "";
    _ = ctl.knob(ui, fr1.cutLeft(cell[0] + 8), "cut", &st.m_cut, .{ .label = "CUTOFF", .readout = cut_s, .mod = st.m_cut + st.m_env * 0.2 });
    _ = ctl.knob(ui, fr1, "res", &st.m_res, .{ .label = "PEAK" });
    var fr2 = vcf.cutTop(cell[1]);
    _ = ctl.knob(ui, fr2.cutLeft(cell[0] + 8), "env", &st.m_env, .{ .label = "EG AMT" });
    _ = ctl.knob(ui, fr2, "drv", &st.m_drv, .{ .label = "DRIVE" });
    _ = body.cutLeft(2);
    // Envelope strip: sliders + curve.
    var eg = ctl.strip(ui, body, "ENV").inset(2);
    var env_pts: [64]f32 = undefined;
    adsrCurve(&env_pts, st.m_adsr);
    ctl.curve(ui, eg.cutTop(32), &env_pts, style.phosphor);
    _ = eg.cutTop(2);
    const lab = [_][]const u8{ "A", "D", "S", "R" };
    for (0..4) |i| _ = ctl.slider(ui, eg.cutLeft(ctl.sliderWidth(.slider)), .{ "eg", i }, &st.m_adsr[i], .{ .label = lab[i], .show_readout = false });
}

fn palettePanel(ui: *Ui, r: Rect) void {
    var body = section(ui, r, "PALETTE");
    const Sw = struct { n: []const u8, c: Color };
    const sw = [_]Sw{
        .{ .n = "CHASSIS", .c = style.chassis }, .{ .n = "PANE", .c = style.pane },     .{ .n = "FACE", .c = style.face },
        .{ .n = "FACE HI", .c = style.face_hi }, .{ .n = "FACE LO", .c = style.face_lo }, .{ .n = "WELL", .c = style.well },
        .{ .n = "TEXT", .c = style.text },       .{ .n = "DIM", .c = style.text_dim },  .{ .n = "MUTE", .c = style.text_mute },
        .{ .n = "ACCENT", .c = style.accent },   .{ .n = "PLAY", .c = style.play },     .{ .n = "REC", .c = style.rec },
        .{ .n = "MOD", .c = style.mod },         .{ .n = "PHOSPHOR", .c = style.phosphor },
    };
    const cols: i32 = 7;
    const rows: i32 = 2;
    var grid = body.cutTop(body.h);
    for (sw, 0..) |s, i| {
        const cell = grid.cell(cols, rows, @intCast(@mod(@as(i32, @intCast(i)), cols)), @intCast(@divFloor(@as(i32, @intCast(i)), cols))).inset(2);
        var cc = cell;
        const chip = cc.cutTop(cc.h - 11);
        _ = ui.well(chip, s.c);
        ui.textIn(&ui.fonts.legend, cc, s.n, style.text_mute, .left, false);
    }
}

fn typePanel(ui: *Ui, r: Rect) void {
    var body = section(ui, r, "TYPE  ·  TAMZEN");
    const f = &ui.fonts;
    _ = ui.text(&f.title, body.x, body.y, "Title 8x16 — Slab Audio Workstation", style.text);
    body.y += 18;
    _ = ui.text(&f.body_bold, body.x, body.y, "Body bold 6x12 — SM-24 Mono", style.text);
    body.y += 14;
    _ = ui.text(&f.body, body.x, body.y, "Body 6x12 — The quick brown fox 0123456789 °±µ", style.text);
    body.y += 14;
    _ = ui.text(&f.body, body.x, body.y, "Dim / mute: secondary text, hints", style.text_dim);
    body.y += 14;
    _ = ui.engraved(&f.legend, body.x, body.y, "LEGEND 5X9 · CUTOFF PEAK DRIVE EG AMT 1.25K", style.text_dim);
}
