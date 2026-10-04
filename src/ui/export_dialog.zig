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
    dither: bool = true,

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
    pub fn format(self: State) export_mod.Format {
        return .{
            .container = @enumFromInt(self.container),
            .bits = @enumFromInt(self.bits),
            .dither = self.dither,
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

pub const Result = enum { none, cancel, render };

const W: i32 = 340;
const H: i32 = 262;
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
    choice(ui, dialog.row(ui, &body, "RANGE", ROW_H), &.{ "PROJECT", "LOOP", "SELECTION" }, &state.range, &.{ false, !avail.loop, !avail.selection });
    tailRow(ui, dialog.row(ui, &body, "TAIL", ROW_H), &state.tail_auto, &state.tail_sec);
    choice(ui, dialog.row(ui, &body, "FORMAT", ROW_H), &.{ "WAV", "AIFF", "FLAC" }, &state.container, &.{});
    if (state.container == @intFromEnum(export_mod.Container.flac) and state.bits == @intFromEnum(export_mod.Bits.float32)) state.bits = @intFromEnum(export_mod.Bits.pcm24);
    {
        var r = dialog.row(ui, &body, "BITS", ROW_H);
        const sixteen = state.bits == @intFromEnum(export_mod.Bits.pcm16);
        var d = r.cutRight(64);
        _ = r.cutRight(6);
        const is_flac = state.container == @intFromEnum(export_mod.Container.flac);
        choice(ui, r, &.{ "16", "24", "32F" }, &state.bits, &.{ false, false, is_flac });
        var on = state.dither and sixteen;
        if (ctl.button(ui, d.cutLeft(d.w), "DITHER", &on, .{ .kind = .latch, .label = "DITHER", .lit = style.accent, .disabled = !sixteen })) state.dither = !state.dither;
    }
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
