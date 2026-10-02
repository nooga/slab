//! Gallery page CONCOCTION: a working mock of the Concoction panel, the
//! prototype for its two cards before the machine panel engine (docs/15)
//! learns them. OSC holds the sound: the two oscillators over live
//! wavetable displays, sub and noise, filter, amp envelope, pitch and the
//! output. MOD holds what moves it: the LFOs, the two mod envelopes and
//! the matrix. Modulation sources sit in a dock on both cards; drag one
//! onto a blue-ringed knob (or a matrix row) to route it.
//!
//! The tables are the machine's own bank (machines/concoction/assets/
//! bank.wav, mip 0 of each frame). A UI-side model of the modulation runs
//! off the clock, one note every two beats at 125 BPM, so the displays
//! move the way the voice would. Nothing here touches audio.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const wav = @import("../wav.zig");
const wavetable = @import("../wavetable.zig");
const sv = @import("synth_views.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;

const BANK_PATH = "machines/concoction/assets/bank.wav";
const BANK_FRAMES: usize = 16;
const BEAT: f64 = 60.0 / 125.0;
const NOTE_EVERY: f64 = 2 * BEAT;
const GATE: f64 = 1.25 * BEAT;
const GATE_S: f32 = @floatCast(GATE);
const NOTES = [_]i32{ 0, 12, 0, 7, 0, 10, 0, 3 };
const F0: f32 = 55; // the scope's note, A1

const TABLES = [_][]const u8{ "BASIC", "PWM", "SYNC", "FM", "PD", "DRIVE", "FOLD", "HARM", "RESO", "VOWEL" };
const WARPS = [_][]const u8{ "OFF", "SYNC", "PWM", "BEND", "FM" };
const SHAPES = [_][]const u8{ "SINE", "TRI", "SAW UP", "SAW DN", "SQUARE", "S&H" };
const SUB_SHAPES = [_][]const u8{ "SINE", "TRI", "SAW", "SQUARE" };
const SYNCS = [_][]const u8{ "HZ", "4 BAR", "2 BAR", "1 BAR", "1/2", "1/4", "1/8", "1/16", "1/32", "1/4D", "1/8D", "1/16D", "1/4T", "1/8T", "1/16T" };
const SYNC_BEATS = [_]f64{ 0, 16, 8, 4, 2, 1, 0.5, 0.25, 0.125, 1.5, 0.75, 0.375, 2.0 / 3.0, 1.0 / 3.0, 1.0 / 6.0 };
const LFO_MODES = [_][]const u8{ "FREE", "RETRIG", "ENV" };
const SRCS = [_][]const u8{ "OFF", "ENV2", "ENV3", "LFO1", "LFO2", "VEL", "NOTE", "PRESS", "SLIDE", "RAND" };
const DSTS = [_][]const u8{ "OFF", "A POS", "B POS", "A WARP", "B WARP", "A PITCH", "B PITCH", "PITCH", "A LVL", "B LVL", "SUB LVL", "NOISE", "CUTOFF", "RES", "DRIVE", "AMP" };
const FMODES = [_][]const u8{ "OFF", "LP24", "LP18", "LP12", "BP", "HP12", "HP24", "NOTCH" };
const PITCH_TO = [_][]const u8{ "ALL", "A+B" };
const GLIDE_MODES = [_][]const u8{ "ALWAYS", "LEGATO" };
const OCTS = rangeLabels(-4, 4);
const SEMIS = rangeLabels(-12, 12);
const SUB_OCTS = rangeLabels(-3, 1);
const PRESETS = [_][]const u8{ "VOWEL MORPH", "CRISP SAW BASS", "REESE", "WOBBLE" };

// Sources and destinations, as the machine's matrix switches number them.
const S = struct {
    const env2 = 1;
    const env3 = 2;
    const lfo1 = 3;
    const lfo2 = 4;
    const vel = 5;
    const note = 6;
    const rand = 9;
};
const D = struct {
    const a_pos = 1;
    const b_pos = 2;
    const a_warp = 3;
    const b_warp = 4;
    const a_pitch = 5;
    const b_pitch = 6;
    const a_lvl = 8;
    const b_lvl = 9;
    const sub_lvl = 10;
    const noise = 11;
    const cutoff = 12;
    const res = 13;
    const drive = 14;
    const amp = 15;
};
/// The sources the dock offers, in its order.
const DOCK = [_]u8{ S.lfo1, S.lfo2, S.env2, S.env3, S.vel, S.note, S.rand };

fn rangeLabels(comptime lo: i32, comptime hi: i32) [hi - lo + 1][]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: [hi - lo + 1][]const u8 = undefined;
        for (&out, 0..) |*s, i| {
            const v: i32 = lo + @as(i32, @intCast(i));
            s.* = if (v > 0) std.fmt.comptimePrint("+{d}", .{v}) else std.fmt.comptimePrint("{d}", .{v});
        }
        return out;
    }
}

// ── State ────────────────────────────────────────────────────────────

const Osc = struct {
    on: bool = true,
    table: u8 = 0,
    pos: f32 = 0,
    warp: u8 = 0,
    wamt: f32 = 0,
    oct: u8 = 4, // OCTS index: 0
    semi: u8 = 12, // SEMIS index: 0
    fine: f32 = 0.5,
    level: f32 = 0.75,
    phase: f32 = 0.5,
    rand: f32 = 0,
    filt: bool = true,
};

const Env = struct { a: f32, h: f32 = 0, d: f32, s: f32, r: f32 };
const Lfo = struct { shape: u8 = 0, rate: f32 = 0.45, sync: u8 = 0, mode: u8 = 1, uni: bool = false };
const Slot = struct { src: u8 = 0, dst: u8 = 0, amt: f32 = 0.5 };

/// A place a dragged source can land, recorded as it is drawn.
const Target = struct { r: Rect, dst: u8 = 0, slot: u8 = NO_SLOT };
const NO_SLOT: u8 = 0xff;
const MAX_TARGETS = 48;

pub const State = struct {
    bank: wavetable.Table = .{},
    card: u8 = 0,
    preset: u8 = 0,

    a: Osc = .{ .table = 9, .pos = 0.1, .level = 0.8 },
    b: Osc = .{ .table = 2, .pos = 0.3, .warp = 3, .wamt = 0.35, .oct = 3, .level = 0.45 },
    sub_on: bool = true,
    sub_shape: u8 = 0,
    sub_oct: u8 = 2, // SUB_OCTS index: −1
    sub_level: f32 = 0.6,
    sub_filt: bool = false,
    n_level: f32 = 0.1,
    n_color: f32 = 0.35,
    n_filt: bool = true,

    f_mode: u8 = 1,
    f_cut: f32 = 0.55,
    f_res: f32 = 0.35,
    f_drive: f32 = 0.2,
    f_key: f32 = 0.3,
    f_env: f32 = 0.7,

    amp: Env = .{ .a = 0.05, .h = 0.1, .d = 0.55, .s = 0.7, .r = 0.35 },
    fenv: Env = .{ .a = 0.05, .d = 0.45, .s = 0.2, .r = 0.4 },
    menv: Env = .{ .a = 0.3, .d = 0.6, .s = 0.0, .r = 0.4 },

    p_amt: f32 = 0.5,
    p_time: f32 = 0.3,
    p_to: u8 = 0,
    glide: f32 = 0.1,
    g_mode: u8 = 1,
    vel: f32 = 0.3,
    level: f32 = 0.7,

    lfo: [2]Lfo = .{ .{ .shape = 0, .sync = 6, .mode = 0 }, .{ .shape = 5, .rate = 0.55, .mode = 1, .uni = true } },
    slots: [8]Slot = .{
        .{ .src = S.lfo1, .dst = D.a_pos, .amt = 0.85 },
        .{ .src = S.env3, .dst = D.cutoff, .amt = 0.7 },
        .{ .src = S.lfo2, .dst = D.b_warp, .amt = 0.7 },
        .{},
        .{},
        .{},
        .{},
        .{},
    },

    // Drag and drop: the source in flight, and the targets drawn this
    // frame and the last (drops land on last frame's, the whole panel).
    drag_src: u8 = 0,
    targets: [MAX_TARGETS]Target = undefined,
    ntargets: usize = 0,
    prev: [MAX_TARGETS]Target = undefined,
    nprev: usize = 0,
    // The hovered knob's destination (this frame's, last frame's), and
    // the slot a drop would fill now.
    hot_next: u8 = 0,
    hot_dst: u8 = 0,
    drop_slot: u8 = NO_SLOT,

    pub fn init(alloc: std.mem.Allocator) State {
        var st = State{};
        if (std.c.getenv("SLAB_GALLERY_CARD")) |c| st.card = std.fmt.parseInt(u8, std.mem.span(c), 10) catch 0;
        var smp = wav.load(alloc, BANK_PATH) catch return st;
        defer smp.deinit(alloc);
        st.bank = wavetable.build(alloc, smp.data, smp.frame_size) catch .{};
        return st;
    }

    pub fn deinit(st: *State, alloc: std.mem.Allocator) void {
        st.bank.deinit(alloc);
    }

    fn target(st: *State, r: Rect, dst: u8, slot: u8) void {
        if (st.ntargets == MAX_TARGETS) return;
        st.targets[st.ntargets] = .{ .r = r, .dst = dst, .slot = slot };
        st.ntargets += 1;
    }

    fn hovered(st: *const State, ui: *const Ui) ?Target {
        for (st.prev[0..st.nprev]) |t| if (t.r.contains(ui.in.ix(), ui.in.iy())) return t;
        return null;
    }

    /// Route `src` to `t`: a matrix row takes the source; a knob's
    /// destination reuses the slot that already joins the two, else the
    /// first free one.
    fn drop(st: *State, src: u8, t: Target) void {
        const si = st.dropSlot(src, t) orelse return;
        const sl = &st.slots[si];
        if (t.slot != NO_SLOT) {
            sl.src = src;
            if (sl.amt == 0.5) sl.amt = 0.75;
        } else if (!(sl.src == src and sl.dst == t.dst)) {
            sl.* = .{ .src = src, .dst = t.dst, .amt = 0.75 };
        }
    }

    /// The slot a drop of `src` on `t` fills.
    fn dropSlot(st: *const State, src: u8, t: Target) ?u8 {
        if (t.slot != NO_SLOT) return t.slot;
        for (st.slots, 0..) |sl, i| if (sl.src == src and sl.dst == t.dst) return @intCast(i);
        for (st.slots, 0..) |sl, i| if (sl.src == 0 or sl.dst == 0) return @intCast(i);
        return null;
    }
};

// ── The modulation model ─────────────────────────────────────────────

const Mods = struct {
    src: [SRCS.len]f32 = [_]f32{0} ** SRCS.len,
    dst: [DSTS.len]f32 = [_]f32{0} ** DSTS.len,
    since: f64 = 0,
    lfo_ph: [2]f32 = .{ 0, 0 },
    note: i32 = 0,
};

fn expSecs(n: f32, lo: f32, hi: f32) f32 {
    return lo * std.math.pow(f32, hi / lo, n);
}

const EnvSecs = struct { a: f32, h: f32, d: f32, s: f32, r: f32 };

fn envSecs(e: Env) EnvSecs {
    return .{ .a = expSecs(e.a, 0.0005, 10), .h = e.h * e.h * 2, .d = expSecs(e.d, 0.001, 20), .s = e.s, .r = expSecs(e.r, 0.001, 20) };
}

fn envHeld(e: EnvSecs, t: f32) f32 {
    if (t < e.a) return t / e.a;
    if (t < e.a + e.h) return 1;
    return e.s + (1 - e.s) * @exp(-5 * (t - e.a - e.h) / e.d);
}

/// Level `t` seconds after a note that was held for `gate`.
fn envAt(e: EnvSecs, t: f32, gate: f32) f32 {
    if (t < gate) return envHeld(e, t);
    return envHeld(e, gate) * @exp(-5 * (t - gate) / e.r);
}

fn hash01(n: u64) f32 {
    return sv.hash01(n);
}

fn lfoShape(shape: u8, ph: f32, cycle: u64) f32 {
    return sv.lfoValue(sv.lfoShape(SHAPES[shape]), ph, cycle);
}

fn lfoPeriod(l: Lfo) f64 {
    if (l.sync > 0) return SYNC_BEATS[l.sync] * BEAT;
    return 1.0 / @as(f64, expSecs(l.rate, 0.01, 40));
}

fn model(st: *const State, time: f64) Mods {
    var m = Mods{};
    const n: u64 = @intFromFloat(@floor(time / NOTE_EVERY));
    m.since = time - @as(f64, @floatFromInt(n)) * NOTE_EVERY;
    m.note = NOTES[n % NOTES.len];
    const since: f32 = @floatCast(m.since);
    m.src[S.env2] = envAt(envSecs(st.fenv), since, GATE_S);
    m.src[S.env3] = envAt(envSecs(st.menv), since, GATE_S);
    for (st.lfo, 0..) |l, i| {
        const per = lfoPeriod(l);
        const t = switch (l.mode) {
            0 => time,
            1 => m.since,
            else => @min(m.since, per * 0.999),
        };
        const cyc = t / per;
        const ph: f32 = @floatCast(cyc - @floor(cyc));
        const v = lfoShape(l.shape, ph, @as(u64, @intFromFloat(@floor(cyc))) +% n *% 7919 *% @intFromBool(l.mode != 0));
        m.lfo_ph[i] = ph;
        m.src[S.lfo1 + i] = if (l.uni) (v + 1) / 2 else v;
    }
    m.src[S.vel] = 0.6 + 0.4 * hash01(n *% 31 +% 5);
    m.src[S.note] = @as(f32, @floatFromInt(m.note)) / 24;
    m.src[S.rand] = hash01(n *% 13 +% 1) * 2 - 1;
    for (st.slots) |s| {
        if (s.src == 0 or s.dst == 0) continue;
        m.dst[s.dst] += m.src[s.src] * (s.amt * 2 - 1);
    }
    return m;
}

fn eff(base: f32, m: *const Mods, dst: u8) f32 {
    return std.math.clamp(base + m.dst[dst], 0, 1);
}

// ── Oscillator math, as the voice does it ────────────────────────────

/// Table `t` of the bank: its 16 frames.
fn table(st: *const State, t: u8) sv.Table {
    if (st.bank.frames == 0) return .{};
    const first = @as(usize, t) * BANK_FRAMES;
    return .{ .data = st.bank.data, .first = first, .count = @min(BANK_FRAMES, st.bank.frames -| first) };
}

fn waveAt(st: *const State, t: u8, pos: f32, p: f32) f32 {
    return table(st, t).at(pos, p);
}

fn warp(p: f32, mode: u8, w: f32, fm: f32) f32 {
    return sv.warpPhase(p, @enumFromInt(@min(mode, 4)), w, fm);
}

const Voice = struct {
    a_pos: f32,
    b_pos: f32,
    a_w: f32,
    b_w: f32,
    b_ratio: f32,
};

fn voiceNow(st: *const State, m: *const Mods) Voice {
    const b_semis = @as(f32, @floatFromInt(@as(i32, st.b.oct) - 4)) * 12 + @as(f32, @floatFromInt(@as(i32, st.b.semi) - 12)) -
        (@as(f32, @floatFromInt(@as(i32, st.a.oct) - 4)) * 12 + @as(f32, @floatFromInt(@as(i32, st.a.semi) - 12)));
    return .{
        .a_pos = eff(st.a.pos, m, D.a_pos),
        .b_pos = eff(st.b.pos, m, D.b_pos),
        .a_w = eff(st.a.wamt, m, D.a_warp),
        .b_w = eff(st.b.wamt, m, D.b_warp),
        .b_ratio = std.math.pow(f32, 2, b_semis / 12),
    };
}

fn oscB(st: *const State, v: Voice, p: f32) f32 {
    const pb = p * v.b_ratio;
    return waveAt(st, st.b.table, v.b_pos, warp(pb - @floor(pb), st.b.warp, v.b_w, 0));
}

fn oscSample(st: *const State, v: Voice, which: u1, p: f32) f32 {
    if (which == 1) return oscB(st, v, p);
    const fm = if (st.a.warp == 4) oscB(st, v, p) else 0;
    return waveAt(st, st.a.table, v.a_pos, warp(p, st.a.warp, v.a_w, fm));
}

// ── Page ─────────────────────────────────────────────────────────────

pub const PANEL_W: i32 = 392 * 2 + 216;
const TITLE_H: i32 = 20;
const DOCK_H: i32 = 26;
const CARD_H: i32 = 372;

pub fn page(ui: *Ui, screen: Rect, st: *State) void {
    ui.pushId("concoction");
    defer ui.popId();
    @memcpy(st.prev[0..st.ntargets], st.targets[0..st.ntargets]);
    st.nprev = st.ntargets;
    st.ntargets = 0;
    st.hot_dst = st.hot_next;
    st.hot_next = 0;
    st.drop_slot = NO_SLOT;
    if (st.drag_src != 0) {
        if (st.hovered(ui)) |t| st.drop_slot = st.dropSlot(st.drag_src, t) orelse NO_SLOT;
    }
    const m = model(st, ui.in.time);
    ui.animate();

    var s = screen;
    var col = s.cutLeft(@min(s.w, PANEL_W));
    var panel = col.cutTop(@min(col.h, TITLE_H + DOCK_H + CARD_H));
    if (col.h > 0) _ = ui.plate(col, .{});
    notes(ui, s, st);

    var title = panel.cutTop(TITLE_H);
    _ = ctl.segmentedFlush(ui, title.cutRight(128), "card", &st.card, &.{ "OSC", "MOD" });
    ctl.titleStrip(ui, title, "CONCOCTION", PRESETS[st.preset]);
    dock(ui, panel.cutTop(DOCK_H), st, &m);
    switch (st.card) {
        0 => oscCard(ui, panel, st, &m),
        else => modCard(ui, panel, st, &m),
    }
    dragOverlay(ui, st, &m);
}

/// The right of the page: what the prototype is for, and how to drive it.
fn notes(ui: *Ui, r: Rect, st: *const State) void {
    if (r.w < 120) {
        if (r.w > 0) _ = ui.plate(r, .{});
        return;
    }
    var body = ctl.strip(ui, r, "PROTOTYPE · CONCOCTION CARDS");
    body = body.insetXY(6, 4);
    const lines = [_][]const u8{
        "OSC card: the sound. MOD card: what moves it.",
        "",
        "Drag a source from the MOD dock onto a knob",
        "with a blue ring to route it; onto a matrix",
        "row to set that row's source.",
        "",
        "Wavetable display: every frame stacked in",
        "depth, the played frame lit with its warp;",
        "the blue ghost is POS before modulation.",
        "Beside it the played cycle and its first",
        "32 harmonics.",
        "",
        "One note every two beats at 125 BPM drives",
        "the envelopes, LFO retrigs and the scope.",
    };
    var y = body.y;
    for (lines) |l| {
        _ = ui.text(&ui.fonts.body, body.x, y, l, style.text_dim);
        y += 16;
    }
    var buf: [64]u8 = undefined;
    const bank = if (st.bank.frames > 0)
        std.fmt.bufPrint(&buf, "bank: {d} tables of {d} frames", .{ st.bank.frames / BANK_FRAMES, BANK_FRAMES }) catch ""
    else
        "bank.wav not found: run from the repo root";
    _ = ui.text(&ui.fonts.body, body.x, y + 8, bank, style.text_mute);
}

// ── Dock: the modulation sources ─────────────────────────────────────

fn dock(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    ui.pushId("dock");
    defer ui.popId();
    var body = ui.plate(r, .{});
    _ = ui.engraved(&ui.fonts.legend, body.x + 3, body.y + @divFloor(body.h - 12, 2), "MOD", style.text_dim);
    _ = body.cutLeft(28);
    for (DOCK) |src| {
        chip(ui, body.cutLeft(72).insetXY(2, 3), st, m, src);
    }
    var buf: [40]u8 = undefined;
    const since: f32 = @floatCast(m.since);
    const s = std.fmt.bufPrint(&buf, "NOTE {s}{d}  {d:.2}S", .{ if (m.note > 0) "+" else "", m.note, since }) catch "";
    ctl.display(ui, body.insetXY(4, 3), s, .{ .align_ = .right });
}

/// A draggable source: name plus a live meter of its value.
fn chip(ui: *Ui, r: Rect, st: *State, m: *const Mods, src: u8) void {
    if (sv.modChip(ui, r, .{ "chip", src }, SRCS[src], m.src[src], bipolarSrc(st, src), st.drag_src == src)) st.drag_src = src;
}

fn bipolarSrc(st: *const State, src: u8) bool {
    return switch (src) {
        S.lfo1, S.lfo2 => !st.lfo[src - S.lfo1].uni,
        S.note, S.rand => true,
        else => false,
    };
}

fn meterBar(ui: *Ui, r: Rect, v: f32, bipolar: bool) void {
    sv.meterBar(ui, r, v, bipolar);
}

fn dragOverlay(ui: *Ui, st: *State, m: *const Mods) void {
    if (st.drag_src == 0) return;
    const over = st.hovered(ui);
    if (over) |t| ui.bevel(t.r.inset(-1), style.mod, style.mod);
    if (ui.in.down) {
        sv.dragChip(ui, SRCS[st.drag_src], m.src[st.drag_src], bipolarSrc(st, st.drag_src));
        return;
    }
    if (over) |t| st.drop(st.drag_src, t);
    st.drag_src = 0;
}

/// A knob that modulation can reach: blue ring at the modulated value,
/// and a drop target for the dock.
fn modKnob(ui: *Ui, r: Rect, st: *State, m: *const Mods, key: anytype, v: *f32, label: []const u8, dst: u8, bipolar: bool) void {
    const cell = ctl.knobCell(.m, true);
    const kr = r.takeTop(cell[1]).center(cell[0], cell[1]);
    const routed = m.dst[dst] != 0 or hasRoute(st, dst);
    _ = ctl.knob(ui, kr, key, v, .{
        .label = label,
        .variant = if (bipolar) .bipolar else .plain,
        .default = if (bipolar) 0.5 else 0,
        .show_readout = false,
        .mod = if (routed) eff(v.*, m, dst) else null,
    });
    st.target(kr, dst, NO_SLOT);
    if (kr.contains(ui.in.ix(), ui.in.iy())) st.hot_next = dst;
}

fn hasRoute(st: *const State, dst: u8) bool {
    for (st.slots) |s| if (s.src != 0 and s.dst == dst) return true;
    return false;
}

fn plainKnob(ui: *Ui, r: Rect, key: anytype, v: *f32, label: []const u8, bipolar: bool) void {
    const cell = ctl.knobCell(.m, true);
    _ = ctl.knob(ui, r.takeTop(cell[1]).center(cell[0], cell[1]), key, v, .{
        .label = label,
        .variant = if (bipolar) .bipolar else .plain,
        .default = if (bipolar) 0.5 else 0,
        .show_readout = false,
    });
}

fn field(ui: *Ui, row: *Rect, key: anytype, v: *u8, options: []const []const u8, label: []const u8) void {
    const w = ctl.displayFieldCell(ui, options)[0];
    _ = ctl.displayField(ui, row.cutLeft(w).insetXY(2, 0), key, v, options, label);
}

fn latchIn(ui: *Ui, row: *Rect, key: anytype, on: *bool, label: []const u8) void {
    const cell = ctl.latchCell(ui, .{ .label = label });
    _ = ctl.latch(ui, row.cutLeft(cell[0] + 4), key, on, .{ .label = label, .led = style.led_amber });
}

const KNOB_W: i32 = 44;

// ── OSC card ─────────────────────────────────────────────────────────

fn oscCard(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    var p = r;
    var row1 = p.cutTop(212);
    oscStrip(ui, row1.cutLeft(392), st, m, 0);
    oscStrip(ui, row1.cutLeft(392), st, m, 1);
    subNoise(ui, row1, st, m);
    var row2 = p;
    filterStrip(ui, row2.cutLeft(332), st, m);
    ampStrip(ui, row2.cutLeft(212), st, m);
    pitchStrip(ui, row2.cutLeft(196), st);
    outStrip(ui, row2, st, m);
}

fn oscStrip(ui: *Ui, r: Rect, st: *State, m: *const Mods, which: u1) void {
    ui.pushId(.{ "osc", which });
    defer ui.popId();
    const o = if (which == 0) &st.a else &st.b;
    var body = ctl.strip(ui, r, if (which == 0) "OSC A" else "OSC B");
    body = body.insetXY(2, 0);

    var sel = body.cutTop(30);
    if (which == 1) latchIn(ui, &sel, "on", &o.on, "ON");
    field(ui, &sel, "table", &o.table, &TABLES, "TABLE");
    field(ui, &sel, "warp", &o.warp, &WARPS, "WARP");
    field(ui, &sel, "oct", &o.oct, &OCTS, "OCT");
    field(ui, &sel, "semi", &o.semi, &SEMIS, "SEMI");
    latchIn(ui, &sel, "filt", &o.filt, "FILT");

    var knobs = body.cutBottom(ctl.knobCell(.m, true)[1] + 2);
    const pos_d: u8 = if (which == 0) D.a_pos else D.b_pos;
    const warp_d: u8 = if (which == 0) D.a_warp else D.b_warp;
    const pitch_d: u8 = if (which == 0) D.a_pitch else D.b_pitch;
    const lvl_d: u8 = if (which == 0) D.a_lvl else D.b_lvl;
    modKnob(ui, knobs.cutLeft(KNOB_W), st, m, "pos", &o.pos, "POS", pos_d, false);
    modKnob(ui, knobs.cutLeft(KNOB_W), st, m, "wamt", &o.wamt, "AMT", warp_d, false);
    modKnob(ui, knobs.cutLeft(KNOB_W), st, m, "fine", &o.fine, "FINE", pitch_d, true);
    modKnob(ui, knobs.cutLeft(KNOB_W), st, m, "level", &o.level, "LEVEL", lvl_d, false);
    plainKnob(ui, knobs.cutLeft(KNOB_W), "phase", &o.phase, "PHASE", false);
    plainKnob(ui, knobs.cutLeft(KNOB_W), "rand", &o.rand, "RAND", false);

    const v = voiceNow(st, m);
    const pos_eff = if (which == 0) v.a_pos else v.b_pos;
    sv.wavetableView(ui, body.insetXY(0, 2), .{
        .table = table(st, o.table),
        .name = TABLES[o.table],
        .pos = pos_eff,
        .base_pos = o.pos,
        .warp = @enumFromInt(@min(o.warp, 4)),
        .amt = if (which == 0) v.a_w else v.b_w,
        .dim = which == 1 and !o.on,
    });
}

fn subNoise(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    var col = r;
    {
        ui.pushId("sub");
        defer ui.popId();
        var body = ctl.strip(ui, col.cutTop(124), "SUB").insetXY(2, 0);
        var top = body.cutTop(ctl.listCell(ui, &SUB_SHAPES)[1] + 2);
        _ = ctl.list(ui, top.cutLeft(ctl.listCell(ui, &SUB_SHAPES)[0] + 6), "shape", &st.sub_shape, &SUB_SHAPES, "SHAPE");
        var right = top;
        var r1 = right.cutTop(30);
        latchIn(ui, &r1, "on", &st.sub_on, "ON");
        latchIn(ui, &r1, "filt", &st.sub_filt, "FILT");
        var r2 = right.cutTop(30);
        field(ui, &r2, "oct", &st.sub_oct, &SUB_OCTS, "OCT");
        var kn = body;
        modKnob(ui, kn.cutLeft(KNOB_W), st, m, "level", &st.sub_level, "LEVEL", D.sub_lvl, false);
        // The sub's cycle, two of them, at its level.
        const v = kn.insetXY(4, 6);
        var pts: [65]f32 = undefined;
        const lvl = if (st.sub_on) eff(st.sub_level, m, D.sub_lvl) else 0;
        for (&pts, 0..) |*y, i| {
            const p = @as(f32, @floatFromInt(i)) / 32;
            const ph = p - @floor(p);
            const s: f32 = switch (st.sub_shape) {
                0 => @sin(ph * std.math.tau),
                1 => 1 - 4 * @abs(ph - 0.5),
                2 => 1 - 2 * ph,
                else => if (ph < 0.5) 1 else -1,
            };
            y.* = 0.5 + 0.45 * s * lvl;
        }
        ctl.curve(ui, v, &pts, if (st.sub_on) style.vfd else style.text_mute);
    }
    {
        ui.pushId("noise");
        defer ui.popId();
        var body = ctl.strip(ui, col, "NOISE").insetXY(2, 0);
        var kn = body.cutTop(ctl.knobCell(.m, true)[1]);
        modKnob(ui, kn.cutLeft(KNOB_W), st, m, "level", &st.n_level, "LEVEL", D.noise, false);
        plainKnob(ui, kn.cutLeft(KNOB_W), "color", &st.n_color, "COLOR", true);
        latchIn(ui, &kn, "filt", &st.n_filt, "FILT");
        // The noise's tilt: dark below the middle, bright above.
        const v = ui.well(body.insetXY(4, 2), style.well);
        const tilt = st.n_color * 2 - 1;
        const lvl = eff(st.n_level, m, D.noise);
        var x: i32 = 0;
        while (x < v.w) : (x += 2) {
            const t = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(1, v.w)));
            const g = std.math.clamp(0.6 + tilt * (t - 0.5) * 1.2, 0.05, 1) * @sqrt(lvl) * (0.7 + 0.3 * hash01(@as(u64, @intCast(x)) +% @as(u64, @intFromFloat(ui.in.time * 30)) *% 977));
            const h: i32 = @intFromFloat(g * @as(f32, @floatFromInt(v.h - 2)));
            ui.rect(Rect.xywh(v.x + x, v.bottom() - 1 - h, 1, h), style.vfd.alpha(150));
        }
    }
}

fn cutHz(norm: f32) f32 {
    return 20 * std.math.pow(f32, 1000, std.math.clamp(norm, 0, 1));
}

fn filterNow(st: *const State, m: *const Mods) [2]f32 {
    const env = (st.f_env * 2 - 1) * m.src[S.env2] * 0.6;
    const key = st.f_key * @as(f32, @floatFromInt(m.note)) / 120;
    return .{ eff(st.f_cut + env + key, m, D.cutoff), eff(st.f_res, m, D.res) };
}

fn filterStrip(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    ui.pushId("filter");
    defer ui.popId();
    var body = ctl.strip(ui, r, "FILTER").insetXY(2, 0);
    var left = body.cutLeft(KNOB_W * 3 + 4);
    var top = left.cutTop(30);
    field(ui, &top, "mode", &st.f_mode, &FMODES, "MODE");
    var k1 = left.cutTop(ctl.knobCell(.m, true)[1]);
    modKnob(ui, k1.cutLeft(KNOB_W), st, m, "cut", &st.f_cut, "CUTOFF", D.cutoff, false);
    modKnob(ui, k1.cutLeft(KNOB_W), st, m, "res", &st.f_res, "RES", D.res, false);
    modKnob(ui, k1.cutLeft(KNOB_W), st, m, "drive", &st.f_drive, "DRIVE", D.drive, false);
    var k2 = left.cutTop(ctl.knobCell(.m, true)[1]);
    plainKnob(ui, k2.cutLeft(KNOB_W), "key", &st.f_key, "KEY", false);
    plainKnob(ui, k2.cutLeft(KNOB_W), "env", &st.f_env, "ENV", true);

    const now = filterNow(st, m);
    sv.filterView(ui, body.insetXY(2, 4), sv.filterKind(FMODES[st.f_mode]), FMODES[st.f_mode], .{ cutHz(st.f_cut), st.f_res }, .{ cutHz(now[0]), now[1] });
}

/// An envelope's shape over a fixed 2 s window with the note's playhead:
/// the gate shaded, the level now as a dot riding the curve.
fn envView(ui: *Ui, r: Rect, e: Env, since: f64, col: Color) void {
    const inner = ui.well(r, style.well);
    ui.clip(inner);
    defer ui.unclip();
    const es = envSecs(e);
    const span: f32 = @floatCast(NOTE_EVERY);
    const fx: f32 = @floatFromInt(inner.x + 1);
    const fw: f32 = @floatFromInt(inner.w - 2);
    const fy: f32 = @floatFromInt(inner.y + 2);
    const fh: f32 = @floatFromInt(inner.h - 4);
    const gx: i32 = @intFromFloat(fx + fw * @as(f32, GATE_S) / span);
    ui.rect(Rect.xywh(inner.x, inner.y, gx - inner.x, inner.h), col.alpha(10));
    var prev: [2]f32 = undefined;
    var i: i32 = 0;
    while (i <= inner.w - 2) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / fw * span;
        const pt = [2]f32{ fx + @as(f32, @floatFromInt(i)), fy + fh * (1 - envAt(es, t, GATE_S)) };
        if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], col);
        prev = pt;
    }
    const tn: f32 = @floatCast(since);
    const px = fx + fw * tn / span;
    const py = fy + fh * (1 - envAt(es, tn, GATE_S));
    ui.rect(Rect.xywh(@intFromFloat(px), inner.y, 1, inner.h), col.alpha(40));
    ui.rect(Rect.xywh(@as(i32, @intFromFloat(px)) - 1, @as(i32, @intFromFloat(py)) - 1, 3, 3), style.text);
}

fn envFaders(ui: *Ui, r: Rect, e: *Env, hold: bool) void {
    var row = r;
    const labels = [_][]const u8{ "ATK", "HOLD", "DEC", "SUS", "REL" };
    const vals = [_]*f32{ &e.a, &e.h, &e.d, &e.s, &e.r };
    for (labels, vals, 0..) |l, v, i| {
        if (i == 1 and !hold) continue;
        const cell = ctl.faderCell(ui, .m, l);
        _ = ctl.slider(ui, row.cutLeft(cell[0] + 6).takeTop(cell[1]), .{ "eg", i }, v, .{ .kind = ctl.faderKind(.m), .label = l, .show_readout = false });
    }
}

fn ampStrip(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    ui.pushId("amp");
    defer ui.popId();
    var body = ctl.strip(ui, r, "AMP").insetXY(2, 0);
    envView(ui, body.cutTop(40).insetXY(2, 2), st.amp, m.since, style.vfd);
    envFaders(ui, body, &st.amp, true);
}

fn pitchStrip(ui: *Ui, r: Rect, st: *State) void {
    ui.pushId("pitch");
    defer ui.popId();
    var body = ctl.strip(ui, r, "PITCH").insetXY(2, 0);
    var k1 = body.cutTop(ctl.knobCell(.m, true)[1]);
    plainKnob(ui, k1.cutLeft(KNOB_W), "amt", &st.p_amt, "P.ENV", true);
    plainKnob(ui, k1.cutLeft(KNOB_W), "time", &st.p_time, "TIME", false);
    _ = ctl.list(ui, k1.cutLeft(ctl.listCell(ui, &PITCH_TO)[0] + 6), "to", &st.p_to, &PITCH_TO, "TO");
    var k2 = body.cutTop(ctl.knobCell(.m, true)[1]);
    plainKnob(ui, k2.cutLeft(KNOB_W), "glide", &st.glide, "GLIDE", false);
    _ = ctl.list(ui, k2.cutLeft(ctl.listCell(ui, &GLIDE_MODES)[0] + 6), "gmode", &st.g_mode, &GLIDE_MODES, "MODE");
}

/// What the voice would put out now: A, B and the sub mixed, through the
/// filter (harmonic by harmonic, phases and all), scaled by the amp
/// envelope. Two cycles of the scope's note, with afterglow.
fn outStrip(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    ui.pushId("out");
    defer ui.popId();
    var body = ctl.strip(ui, r, "OUT").insetXY(2, 0);
    var kn = body.cutBottom(ctl.knobCell(.m, true)[1] + 2);
    plainKnob(ui, kn.cutLeft(KNOB_W), "vel", &st.vel, "VEL", false);
    modKnob(ui, kn.cutLeft(KNOB_W), st, m, "level", &st.level, "LEVEL", D.amp, false);

    const v = voiceNow(st, m);
    const N = 128;
    var mix: [N]f32 = undefined;
    const a_l = eff(st.a.level, m, D.a_lvl);
    const b_l = if (st.b.on) eff(st.b.level, m, D.b_lvl) else 0;
    const s_l = if (st.sub_on) eff(st.sub_level, m, D.sub_lvl) else 0;
    const s_k = std.math.pow(f32, 2, @as(f32, @floatFromInt(@as(i32, st.sub_oct) - 3)));
    for (&mix, 0..) |*y, i| {
        const p = @as(f32, @floatFromInt(i)) / N;
        const sp = p * s_k;
        y.* = a_l * oscSample(st, v, 0, p) + b_l * oscSample(st, v, 1, p) + s_l * @sin((sp - @floor(sp)) * std.math.tau);
    }
    // Filter: DFT, weight by the response at each harmonic, resynthesize.
    const H = 40;
    var re: [H + 1]f32 = undefined;
    var im: [H + 1]f32 = undefined;
    const fnow = filterNow(st, m);
    const fc = cutHz(fnow[0]);
    for (1..H + 1) |h| {
        var a: f32 = 0;
        var b: f32 = 0;
        for (mix, 0..) |y, i| {
            const ang = std.math.tau * @as(f32, @floatFromInt((h * i) % N)) / N;
            a += y * @cos(ang);
            b -= y * @sin(ang);
        }
        const hf = sv.response(sv.filterKind(FMODES[st.f_mode]), F0 * @as(f32, @floatFromInt(h)), fc, fnow[1]);
        const c = sv.Cx.init(a, b).mul(hf);
        re[h] = c.re * 2 / N;
        im[h] = c.im * 2 / N;
    }
    const env = envAt(envSecs(st.amp), @floatCast(m.since), GATE_S) * eff(st.level, m, D.amp);
    var acc: [core.TRAIL_PTS]f32 = undefined;
    var peak: f32 = 1e-6;
    for (&acc, 0..) |*y, i| {
        const p = 2 * @as(f32, @floatFromInt(i)) / @as(f32, acc.len - 1);
        var sum: f32 = 0;
        for (1..H + 1) |h| {
            const ang = std.math.tau * @as(f32, @floatFromInt(h)) * p;
            sum += re[h] * @cos(ang) - im[h] * @sin(ang);
        }
        y.* = sum;
        peak = @max(peak, @abs(sum));
    }
    // Scaled to the mix's own peak (so a closed filter still reads), then
    // by the amp envelope, so notes pulse.
    var pts: [core.TRAIL_PTS]f32 = undefined;
    const g = 0.45 / @max(peak, 0.25);
    for (&pts, acc) |*y, a| y.* = 0.5 + a * g * env;
    ctl.scope(ui, body.insetXY(2, 4), "scope", &pts, style.vfd);
}

// ── MOD card ─────────────────────────────────────────────────────────

fn modCard(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    var p = r;
    var row1 = p.cutTop(p.h - MATRIX_H);
    lfoStrip(ui, row1.cutLeft(250), st, m, 0);
    lfoStrip(ui, row1.cutLeft(250), st, m, 1);
    modEnvStrip(ui, row1.cutLeft(250), st, m, 0);
    modEnvStrip(ui, row1, st, m, 1);
    matrix(ui, p, st, m);
}

fn lfoStrip(ui: *Ui, r: Rect, st: *State, m: *const Mods, which: usize) void {
    ui.pushId(.{ "lfo", which });
    defer ui.popId();
    const l = &st.lfo[which];
    var body = ctl.strip(ui, r, if (which == 0) "LFO 1" else "LFO 2").insetXY(2, 0);
    const view = body.cutTop(60).insetXY(2, 2);
    var top = body.cutTop(30);
    field(ui, &top, "shape", &l.shape, &SHAPES, "SHAPE");
    field(ui, &top, "sync", &l.sync, &SYNCS, "SYNC");
    latchIn(ui, &top, "uni", &l.uni, "UNI");
    var kn = body;
    plainKnob(ui, kn.cutLeft(KNOB_W), "rate", &l.rate, "RATE", false);
    _ = ctl.list(ui, kn.cutLeft(ctl.listCell(ui, &LFO_MODES)[0] + 6), "mode", &l.mode, &LFO_MODES, "MODE");

    var buf: [24]u8 = undefined;
    const caption = if (l.sync > 0)
        std.fmt.bufPrint(&buf, "{s} {s}", .{ SYNCS[l.sync], LFO_MODES[l.mode] }) catch ""
    else
        std.fmt.bufPrint(&buf, "{d:.2}HZ {s}", .{ expSecs(l.rate, 0.01, 40), LFO_MODES[l.mode] }) catch "";
    sv.lfoView(ui, view, sv.lfoShape(SHAPES[l.shape]), l.uni, caption, .{ m.lfo_ph[which], m.src[S.lfo1 + which] });
}

fn modEnvStrip(ui: *Ui, r: Rect, st: *State, m: *const Mods, which: usize) void {
    ui.pushId(.{ "menv", which });
    defer ui.popId();
    const e = if (which == 0) &st.fenv else &st.menv;
    var body = ctl.strip(ui, r, if (which == 0) "ENV 2 · FILTER" else "ENV 3 · MOD").insetXY(2, 0);
    envView(ui, body.cutTop(60).insetXY(2, 2), e.*, m.since, style.vfd);
    envFaders(ui, body, e, false);
}

const MATRIX_H: i32 = 24 + 16 + 4 * sv.MATRIX_ROW + 8;

/// The matrix on one display: slots 1-4 and 5-8 side by side.
fn matrix(ui: *Ui, r: Rect, st: *State, m: *const Mods) void {
    ui.pushId("matrix");
    defer ui.popId();
    const body = ctl.strip(ui, r, "MATRIX").insetXY(4, 2);
    const g = sv.matrixBegin(ui, body);
    const half = @divFloor(g.w, 2);
    for (0..2) |hi| {
        var col = Rect.xywh(g.x + @as(i32, @intCast(hi)) * half, g.y + 2, half, g.h - 2);
        if (hi == 1) ui.rect(Rect.xywh(col.x, col.y + 2, 1, col.h - 6), style.vfd.alpha(30));
        sv.matrixHeader(ui, col.cutTop(16), &SRCS, &DSTS);
        for (0..4) |ri| {
            const si = hi * 4 + ri;
            const row = col.cutTop(sv.MATRIX_ROW);
            const sl = &st.slots[si];
            st.target(row, 0, @intCast(si));
            const e = sv.matrixSlot(ui, row, .{ "slot", si }, si + 1, .{
                .src = sl.src,
                .dst = sl.dst,
                .amt = sl.amt,
                .src_val = m.src[sl.src],
                .src_bipolar = bipolarSrc(st, sl.src),
                .lit = st.hot_dst != 0 and sl.src != 0 and sl.dst == st.hot_dst,
                .drop = st.drop_slot == si,
            }, &SRCS, &DSTS);
            if (e.src) |v| sl.src = v;
            if (e.dst) |v| sl.dst = v;
            if (e.amt) |v| sl.amt = v;
            if (e.clear) sl.* = .{};
        }
    }
    sv.matrixEnd(ui, g);
}
