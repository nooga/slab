//! Render Audio dialog: collects bounce options (time range + reverb/delay
//! tail), then shows a live LED progress bar and stats while the offline
//! render runs on a worker thread. A `dialog` (modal; main suppresses the
//! input behind it while `active`).

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const Range = enum(u8) { project = 0, loop = 1 };

pub const State = struct {
    active: bool = false,
    range: u8 = @intFromEnum(Range.project),
    tail_sec: f32 = 2.0,

    pub fn rangeMode(self: State) Range {
        return @enumFromInt(self.range);
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

const W: i32 = 300;
const H: i32 = 150;
const ROW_H: i32 = 20;
const TAIL_MAX: f32 = 30;
const SEGS: i32 = 24;

/// Draw the dialog centred in `screen`.
///   - `progress == null`  → options (RANGE, TAIL, FORMAT; CANCEL / RENDER).
///   - `progress != null`  → rendering (LED bar + stats; CANCEL).
/// `loop_available` disables the LOOP range when no loop region is set.
pub fn draw(ui: *Ui, screen: Rect, state: *State, loop_available: bool, progress: ?Progress) Result {
    if (!state.active) return .none;
    const f = dialog.begin(ui, screen, "render-dialog", "RENDER AUDIO", W, H);
    defer dialog.end(ui);
    if (progress) |p| {
        drawProgress(ui, f.body, p);
        if (dialog.buttons(ui, f.buttons, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }
    drawOptions(ui, f.body, state, loop_available);
    if (dialog.buttons(ui, f.buttons, &.{ "CANCEL", "RENDER" }, 1)) |i| return if (i == 0) .cancel else .render;
    if (f.escape) return .cancel;
    if (f.enter) return .render;
    return .none;
}

fn drawOptions(ui: *Ui, body_in: Rect, state: *State, loop_available: bool) void {
    var body = body_in;
    if (!loop_available and state.range == @intFromEnum(Range.loop)) state.range = @intFromEnum(Range.project);

    // RANGE: two latching caps, the chosen one lit.
    {
        var r = dialog.row(ui, &body, "RANGE", ROW_H);
        const labels = [_][]const u8{ "PROJECT", "LOOP" };
        const cw = @divFloor(r.w, 2);
        for (labels, 0..) |lab, i| {
            const cr = if (i == 0) r.cutLeft(cw) else r;
            var on = state.range == i;
            const disabled = i == @intFromEnum(Range.loop) and !loop_available;
            if (ctl.button(ui, cr, lab, &on, .{ .kind = .latch, .label = lab, .lit = style.accent, .disabled = disabled })) state.range = @intCast(i);
        }
    }
    // TAIL: slider + readout.
    {
        var r = dialog.row(ui, &body, "TAIL", ROW_H);
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.1} S", .{state.tail_sec}) catch "";
        ctl.display(ui, r.cutRight(7 * ctl.CELL_W + 4).center(7 * ctl.CELL_W + 4, ctl.displayHeight(false)), s, .{ .align_ = .right });
        _ = r.cutRight(6);
        var v = state.tail_sec / TAIL_MAX;
        if (ctl.slider(ui, r.center(r.w, 14), "tail", &v, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 0, .default = 2.0 / TAIL_MAX })) {
            state.tail_sec = @round(v * TAIL_MAX * 10) / 10;
        }
    }
    // FORMAT: fixed for now.
    {
        const r = dialog.row(ui, &body, "FORMAT", ROW_H);
        ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), "24-BIT WAV  48 KHZ", .{ .color = style.text_dim });
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
