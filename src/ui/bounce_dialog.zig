//! Bounce dialog (docs/27 §Bounce selection): where the selected clips'
//! signal is taken, one clip or one per track, what happens to the
//! originals, and the tail; then the same LED progress as Render Audio
//! while the capture renders. A `dialog` (modal; main suppresses the input
//! behind it while `active`).

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");
const render_dialog = @import("render_dialog.zig");

const Ui = core.Ui;
const Rect = core.Rect;

pub const Tap = enum(u8) { instr = 0, fx = 1, fader = 2, sends = 3 };
pub const Mode = enum(u8) { together = 0, each = 1 };
pub const Originals = enum(u8) { mute = 0, keep = 1, delete = 2 };

pub const State = struct {
    active: bool = false,
    tap: u8 = @intFromEnum(Tap.fx),
    mode: u8 = @intFromEnum(Mode.together),
    originals: u8 = @intFromEnum(Originals.mute),
    tail_auto: bool = true,
    tail_sec: f32 = 2.0,

    pub fn tapMode(self: State) Tap {
        return @enumFromInt(self.tap);
    }
    pub fn mixMode(self: State) Mode {
        return @enumFromInt(self.mode);
    }
    pub fn originalsMode(self: State) Originals {
        return @enumFromInt(self.originals);
    }
};

pub const Result = enum { none, cancel, bounce };

const W: i32 = 320;
const H: i32 = 172;
const ROW_H: i32 = 20;
/// The longest tail: AUTO renders up to this and stops at silence.
pub const TAIL_MAX: f32 = 30;

/// Draw the dialog centered in `screen`. `tracks` is how many tracks the
/// selection spans (EACH needs two).
///   - `progress == null`  → options (CANCEL / BOUNCE).
///   - `progress != null`  → bouncing (LED bar + stats; CANCEL).
pub fn draw(ui: *Ui, screen: Rect, state: *State, tracks: usize, progress: ?render_dialog.Progress) Result {
    if (!state.active) return .none;
    const f = dialog.begin(ui, screen, "bounce-dialog", "BOUNCE SELECTION", W, H);
    defer dialog.end(ui);
    if (progress) |p| {
        render_dialog.drawProgress(ui, f.body, p);
        if (dialog.buttons(ui, f.buttons, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }
    drawOptions(ui, f.body, state, tracks);
    if (dialog.buttons(ui, f.buttons, &.{ "CANCEL", "BOUNCE" }, 1)) |i| return if (i == 0) .cancel else .bounce;
    if (f.escape) return .cancel;
    if (f.enter) return .bounce;
    return .none;
}

/// A row of latching caps, the chosen one lit.
fn choice(ui: *Ui, r_: Rect, labels: []const []const u8, value: *u8, disabled: ?usize) void {
    var r = r_;
    const n: i32 = @intCast(labels.len);
    const cw = @divFloor(r.w, n);
    for (labels, 0..) |lab, i| {
        const cr = if (i + 1 < labels.len) r.cutLeft(cw) else r;
        var on = value.* == i;
        const off = disabled != null and disabled.? == i;
        if (ctl.button(ui, cr, lab, &on, .{ .kind = .latch, .label = lab, .lit = style.accent, .disabled = off })) value.* = @intCast(i);
    }
}

fn drawOptions(ui: *Ui, body_in: Rect, state: *State, tracks: usize) void {
    var body = body_in;
    if (tracks < 2) state.mode = @intFromEnum(Mode.together);
    choice(ui, dialog.row(ui, &body, "TAP", ROW_H), &.{ "INSTR", "FX", "FADER", "+SENDS" }, &state.tap, null);
    choice(ui, dialog.row(ui, &body, "CLIPS", ROW_H), &.{ "TOGETHER", "EACH" }, &state.mode, if (tracks < 2) @as(?usize, 1) else null);
    choice(ui, dialog.row(ui, &body, "ORIGINALS", ROW_H), &.{ "MUTE", "KEEP", "DELETE" }, &state.originals, null);
    // TAIL: AUTO (until silent) or a slider in seconds.
    {
        var r = dialog.row(ui, &body, "TAIL", ROW_H);
        var on = state.tail_auto;
        if (ctl.button(ui, r.cutLeft(48), "AUTO", &on, .{ .kind = .latch, .label = "AUTO", .lit = style.accent })) state.tail_auto = !state.tail_auto;
        _ = r.cutLeft(6);
        var buf: [16]u8 = undefined;
        const s = if (state.tail_auto) "SILENCE" else std.fmt.bufPrint(&buf, "{d:.1} S", .{state.tail_sec}) catch "";
        ctl.display(ui, r.cutRight(7 * ctl.CELL_W + 4).center(7 * ctl.CELL_W + 4, ctl.displayHeight(false)), s, .{ .align_ = .right, .color = if (state.tail_auto) style.text_dim else style.text });
        _ = r.cutRight(6);
        if (!state.tail_auto) {
            var v = state.tail_sec / TAIL_MAX;
            if (ctl.slider(ui, r.center(r.w, 14), "bounce-tail", &v, .{ .kind = .mini, .horizontal = true, .show_readout = false, .ticks = 0, .default = 2.0 / TAIL_MAX })) {
                state.tail_sec = @round(v * TAIL_MAX * 10) / 10;
            }
        }
    }
    {
        const r = dialog.row(ui, &body, "FORMAT", ROW_H);
        ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), "32-BIT FLOAT WAV", .{ .color = style.text_dim });
    }
}
