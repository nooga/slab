//! Export dialog (docs/27 §Export): what to write (the mix, stems or
//! both), the range and its tail, and the file format; then a live LED
//! progress bar and stats while the offline render runs on a worker
//! thread. A `dialog` (modal; main suppresses the input behind it while
//! `active`).

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");
const export_mod = @import("../export.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const What = enum(u8) { mix = 0, stems = 1, both = 2 };
pub const Stems = enum(u8) { tracks = 0, buses = 1, all = 2 };
pub const StemTap = enum(u8) { fx = 0, fader = 1 };
pub const Range = enum(u8) { project = 0, loop = 1, selection = 2 };

pub const State = struct {
    active: bool = false,
    what: u8 = @intFromEnum(What.mix),
    stems: u8 = @intFromEnum(Stems.tracks),
    stem_tap: u8 = @intFromEnum(StemTap.fader),
    range: u8 = @intFromEnum(Range.project),
    tail_auto: bool = true,
    tail_sec: f32 = 2.0,
    container: u8 = @intFromEnum(export_mod.Container.wav),
    bits: u8 = @intFromEnum(export_mod.Bits.pcm24),
    /// AAC: 128, 192, 256 (default) or 320 kb/s.
    aac_rate: u8 = 2,
    /// The file's sample rate, an index into RATES (48 kHz).
    rate: u8 = 1,
    /// LOOP-WRAP, for a LOOP or SELECTION range.
    loop_wrap: bool = false,
    dither: bool = true,
    /// NORMALIZE: OFF, PEAK (to PEAK_TARGETS dBTP) or LUFS (to
    /// LUFS_TARGETS, under a -1 dBTP ceiling).
    normalize: u8 = 0,
    peak_target: u8 = 1,
    lufs_target: u8 = 1,
    /// The last export's report, shown until OK.
    card: ?Card = null,

    pub fn whatMode(self: State) What {
        return @enumFromInt(self.what);
    }
    pub fn stemsMode(self: State) Stems {
        return @enumFromInt(self.stems);
    }
    pub fn stemTap(self: State) StemTap {
        return @enumFromInt(self.stem_tap);
    }
    pub fn rangeMode(self: State) Range {
        return @enumFromInt(self.range);
    }
    pub fn normalizeTarget(self: State) f64 {
        return if (self.normalize == 1) PEAK_TARGETS[@min(self.peak_target, 2)] else LUFS_TARGETS[@min(self.lufs_target, 3)];
    }

    pub fn format(self: State) export_mod.Format {
        return .{
            .container = @enumFromInt(self.container),
            .bits = @enumFromInt(self.bits),
            .dither = self.dither,
            .aac_kbps = ([_]u16{ 128, 192, 256, 320 })[@min(self.aac_rate, 3)],
            .sample_rate = RATES[@min(self.rate, 3)],
        };
    }
};

/// Live render telemetry, sampled by main each frame from the worker job.
pub const Progress = struct {
    fraction: f32, // 0..1
    elapsed_s: f64, // wall-clock since start
    speed_x: f64, // rendered-audio-seconds / wall-seconds
    rendered_s: f64, // audio seconds produced so far
    total_s: f64, // audio seconds total
};

pub const PEAK_TARGETS = [_]f64{ -0.1, -1, -3 };
pub const RATES = [_]u32{ 44_100, 48_000, 88_200, 96_000 };
pub const LUFS_TARGETS = [_]f64{ -9, -14, -16, -23 };

/// An export's report card (docs/27 §Normalize and the loudness report).
pub const Card = struct {
    has_mix: bool = false,
    lufs: f64 = -70,
    lra: f64 = 0,
    true_peak: f64 = -180,
    gain_db: f64 = 0,
    files: usize = 0,
    secs: f64 = 0,
    stem_names: [MAX_STEMS][24]u8 = undefined,
    stem_name_len: [MAX_STEMS]u8 = undefined,
    stem_lufs: [MAX_STEMS]f64 = undefined,
    stem_count: usize = 0,

    pub const MAX_STEMS = 32;

    pub fn addStem(self: *Card, name: []const u8, lufs: f64) void {
        if (self.stem_count == MAX_STEMS) return;
        const n = @min(name.len, 24);
        @memcpy(self.stem_names[self.stem_count][0..n], name[0..n]);
        self.stem_name_len[self.stem_count] = @intCast(n);
        self.stem_lufs[self.stem_count] = lufs;
        self.stem_count += 1;
    }
};

pub const Result = enum { none, cancel, render };

const W: i32 = 340;
const H: i32 = 290;
const ROW_H: i32 = 20;
/// The longest tail: AUTO renders up to this and stops at silence.
pub const TAIL_MAX: f32 = 30;
const SEGS: i32 = 24;

/// What the dialog can offer: a loop to render, selected clips.
pub const Avail = struct { loop: bool, selection: bool };

/// Draw the dialog centered in `screen`.
///   - `progress == null`  → options (CANCEL / EXPORT).
///   - `progress != null`  → rendering (LED bar + stats; CANCEL).
pub fn draw(ui: *Ui, screen: Rect, state: *State, avail: Avail, progress: ?Progress) Result {
    if (!state.active) return .none;
    if (state.card) |*card| {
        if (drawCard(ui, screen, card)) {
            state.card = null;
            state.active = false;
        }
        return .none;
    }
    const f = dialog.begin(ui, screen, "export-dialog", "EXPORT AUDIO", W, H);
    defer dialog.end(ui);
    if (progress) |p| {
        drawProgress(ui, f.body, p);
        if (dialog.buttons(ui, f.buttons, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }
    drawOptions(ui, f.body, state, avail);
    if (dialog.buttons(ui, f.buttons, &.{ "CANCEL", "EXPORT" }, 1)) |i| return if (i == 0) .cancel else .render;
    if (f.escape) return .cancel;
    if (f.enter) return .render;
    return .none;
}

/// A row of latching caps, the chosen one lit; `off` disables by index.
pub fn choice(ui: *Ui, r_: Rect, labels: []const []const u8, value: *u8, off: []const bool) void {
    var r = r_;
    const n: i32 = @intCast(labels.len);
    const cw = @divFloor(r.w, n);
    for (labels, 0..) |lab, i| {
        const cr = if (i + 1 < labels.len) r.cutLeft(cw) else r;
        var on = value.* == i;
        const disabled = i < off.len and off[i];
        if (ctl.button(ui, cr, lab, &on, .{ .kind = .latch, .label = lab, .lit = style.accent, .disabled = disabled })) value.* = @intCast(i);
    }
}

/// TAIL: AUTO (until silent) or a slider in seconds.
pub fn tailRow(ui: *Ui, r_: Rect, auto: *bool, sec: *f32) void {
    var r = r_;
    var on = auto.*;
    if (ctl.button(ui, r.cutLeft(48), "AUTO", &on, .{ .kind = .latch, .label = "AUTO", .lit = style.accent })) auto.* = !auto.*;
    _ = r.cutLeft(6);
    var buf: [16]u8 = undefined;
    const s = if (auto.*) "SILENCE" else std.fmt.bufPrint(&buf, "{d:.1} S", .{sec.*}) catch "";
    ctl.display(ui, r.cutRight(7 * ctl.CELL_W + 4).center(7 * ctl.CELL_W + 4, ctl.displayHeight(false)), s, .{ .align_ = .right, .color = if (auto.*) style.text_dim else style.text });
    _ = r.cutRight(6);
    if (!auto.*) {
        var v = sec.* / TAIL_MAX;
        if (ctl.slider(ui, r.center(r.w, 14), "tail", &v, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 0, .default = 2.0 / TAIL_MAX })) {
            sec.* = @round(v * TAIL_MAX * 10) / 10;
        }
    }
}

fn drawOptions(ui: *Ui, body_in: Rect, state: *State, avail: Avail) void {
    var body = body_in;
    if (!avail.loop and state.rangeMode() == .loop) state.range = @intFromEnum(Range.project);
    if (!avail.selection and state.rangeMode() == .selection) state.range = @intFromEnum(Range.project);
    const no_stems = state.whatMode() == .mix;
    choice(ui, dialog.row(ui, &body, "WRITE", ROW_H), &.{ "MIX", "STEMS", "BOTH" }, &state.what, &.{});
    choice(ui, dialog.row(ui, &body, "STEMS", ROW_H), &.{ "TRACKS", "BUSES", "ALL" }, &state.stems, &.{ no_stems, no_stems, no_stems });
    choice(ui, dialog.row(ui, &body, "STEM TAP", ROW_H), &.{ "FX", "FADER" }, &state.stem_tap, &.{ no_stems, no_stems });
    {
        var r = dialog.row(ui, &body, "RANGE", ROW_H);
        const wrappable = state.rangeMode() != .project;
        var w = r.cutRight(52);
        _ = r.cutRight(6);
        choice(ui, r, &.{ "PROJECT", "LOOP", "SELECT" }, &state.range, &.{ false, !avail.loop, !avail.selection });
        var on = state.loop_wrap and wrappable;
        if (ctl.button(ui, w.cutLeft(w.w), "WRAP", &on, .{ .kind = .latch, .label = "WRAP", .lit = style.accent, .disabled = !wrappable })) state.loop_wrap = !state.loop_wrap;
    }
    tailRow(ui, dialog.row(ui, &body, "TAIL", ROW_H), &state.tail_auto, &state.tail_sec);
    choice(ui, dialog.row(ui, &body, "FORMAT", ROW_H), &.{ "WAV", "AIFF", "FLAC", "ALAC", "AAC" }, &state.container, &.{});
    const container: export_mod.Container = @enumFromInt(state.container);
    if (container.intOnly() and state.bits == @intFromEnum(export_mod.Bits.float32)) state.bits = @intFromEnum(export_mod.Bits.pcm24);
    {
        var r = dialog.row(ui, &body, "BITS", ROW_H);
        const sixteen = state.bits == @intFromEnum(export_mod.Bits.pcm16);
        var d = r.cutRight(64);
        _ = r.cutRight(6);
        if (container == .aac) {
            // AAC has a bitrate, not a depth.
            choice(ui, r, &.{ "128", "192", "256", "320" }, &state.aac_rate, &.{});
        } else choice(ui, r, &.{ "16", "24", "32F" }, &state.bits, &.{ false, false, container.intOnly() });
        var on = state.dither and sixteen;
        if (ctl.button(ui, d.cutLeft(d.w), "DITHER", &on, .{ .kind = .latch, .label = "DITHER", .lit = style.accent, .disabled = !sixteen or container == .aac })) state.dither = !state.dither;
    }
    choice(ui, dialog.row(ui, &body, "RATE", ROW_H), &.{ "44.1", "48", "88.2", "96" }, &state.rate, &.{});
    {
        var r = dialog.row(ui, &body, "LEVEL", ROW_H);
        choice(ui, r.cutLeft(126), &.{ "OFF", "PEAK", "LUFS" }, &state.normalize, &.{ false, state.whatMode() == .stems, state.whatMode() == .stems });
        _ = r.cutLeft(8);
        ui.pushId("target");
        defer ui.popId();
        switch (state.normalize) {
            1 => choice(ui, r, &.{ "-0.1", "-1", "-3" }, &state.peak_target, &.{}),
            2 => choice(ui, r, &.{ "-9", "-14", "-16", "-23" }, &state.lufs_target, &.{}),
            else => ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), "AS MIXED", .{ .color = style.text_dim }),
        }
    }
}

fn cardRow(u: *Ui, b: *Rect, label: []const u8, s: []const u8, col: core.Color) void {
    const r = dialog.row(u, b, label, ROW_H);
    ctl.display(u, r.center(r.w, ctl.displayHeight(false)), s, .{ .color = col });
}

/// The report: the mix's loudness, range, true peak and gain, and each
/// stem's loudness against the loudest. True once OK is pressed.
fn drawCard(ui: *Ui, screen: Rect, card: *const Card) bool {
    const stem_rows: i32 = @intCast((card.stem_count + 1) / 2);
    const mix_rows: i32 = if (card.has_mix) 4 else 1;
    const h = 56 + mix_rows * (ROW_H + 6) + if (stem_rows > 0) 18 + stem_rows * 14 else 0;
    const f = dialog.begin(ui, screen, "export-card", "EXPORTED", W, h);
    defer dialog.end(ui);
    var body = f.body;
    var buf: [48]u8 = undefined;
    const row = cardRow;
    row(ui, &body, "FILES", std.fmt.bufPrint(&buf, "{d}  {d:.1} S", .{ card.files, card.secs }) catch "", style.text);
    if (card.has_mix) {
        row(ui, &body, "LOUDNESS", std.fmt.bufPrint(&buf, "{d:.1} LUFS  LRA {d:.1} LU", .{ card.lufs, card.lra }) catch "", style.text);
        row(ui, &body, "PEAK", std.fmt.bufPrint(&buf, "{d:.1} DBTP", .{card.true_peak}) catch "", if (card.true_peak > -1) style.vfd else style.text);
        row(ui, &body, "GAIN", std.fmt.bufPrint(&buf, "{s}{d:.1} DB", .{ if (card.gain_db >= 0) "+" else "", card.gain_db }) catch "", style.text);
    }
    if (card.stem_count > 0) {
        var loudest: f64 = -70;
        for (card.stem_lufs[0..card.stem_count]) |l| loudest = @max(loudest, l);
        const head = body.cutTop(14);
        ui.textIn(&ui.fonts.legend, head, "STEMS, LU UNDER THE LOUDEST", style.text_dim, .left, true);
        _ = body.cutTop(4);
        const col_w = @divFloor(body.w, 2);
        for (0..card.stem_count) |i| {
            const k: i32 = @intCast(i);
            const x = body.x + @mod(k, 2) * col_w;
            const y = body.y + @divFloor(k, 2) * 14;
            const name = card.stem_names[i][0..card.stem_name_len[i]];
            ui.textIn(&ui.fonts.legend, Rect.xywh(x, y, col_w - 52, 14), name, style.text, .left, false);
            const v = if (card.stem_lufs[i] <= -70) "-" else std.fmt.bufPrint(&buf, "{d:.1}", .{card.stem_lufs[i] - loudest}) catch "";
            ui.textIn(&ui.fonts.legend, Rect.xywh(x + col_w - 52, y, 44, 14), v, style.text_dim, .right, false);
        }
    }
    return dialog.buttons(ui, f.buttons, &.{"OK"}, 0) != null or f.escape or f.enter;
}

pub fn drawProgress(ui: *Ui, body_in: Rect, p: Progress) void {
    var body = body_in;
    const frac = std.math.clamp(p.fraction, 0, 1);
    // LED bargraph + percent.
    {
        var r = dialog.row(ui, &body, "PROGRESS", ROW_H);
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{frac * 100}) catch "";
        ctl.display(ui, r.cutRight(4 * ctl.CELL_W + 4).center(4 * ctl.CELL_W + 4, ctl.displayHeight(false)), s, .{ .align_ = .right, .color = style.play });
        _ = r.cutRight(6);
        const inner = ui.well(r.center(r.w, 12), style.well).inset(1);
        const lit: i32 = @intFromFloat(@round(frac * @as(f32, @floatFromInt(SEGS))));
        var i: i32 = 0;
        while (i < SEGS) : (i += 1) {
            const x0 = inner.x + @divFloor(i * inner.w, SEGS);
            const x1 = inner.x + @divFloor((i + 1) * inner.w, SEGS);
            ctl.ledBar(ui, Rect.xywh(x0, inner.y, x1 - x0 - 1, inner.h), if (i < lit) .on else .off, style.play);
        }
        ui.animate();
    }
    {
        const r = dialog.row(ui, &body, "AUDIO", ROW_H);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.1} / {d:.1} S", .{ p.rendered_s, p.total_s }) catch "";
        ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), s, .{});
    }
    {
        const r = dialog.row(ui, &body, "SPEED", ROW_H);
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.1} S  {d:.1}X RT", .{ p.elapsed_s, p.speed_x }) catch "";
        ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), s, .{});
    }
}
