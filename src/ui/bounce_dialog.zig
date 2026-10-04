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
const export_dialog = @import("export_dialog.zig");

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
pub const TAIL_MAX = export_dialog.TAIL_MAX;

/// Draw the dialog centered in `screen`. `tracks` is how many tracks the
/// selection spans (EACH needs two).
///   - `progress == null`  → options (CANCEL / BOUNCE).
///   - `progress != null`  → bouncing (LED bar + stats; CANCEL).
pub fn draw(ui: *Ui, screen: Rect, state: *State, tracks: usize, progress: ?export_dialog.Progress) Result {
    if (!state.active) return .none;
    const f = dialog.begin(ui, screen, "bounce-dialog", "BOUNCE SELECTION", W, H);
    defer dialog.end(ui);
    if (progress) |p| {
        export_dialog.drawProgress(ui, f.body, p);
        if (dialog.buttons(ui, f.buttons, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }
    drawOptions(ui, f.body, state, tracks);
    if (dialog.buttons(ui, f.buttons, &.{ "CANCEL", "BOUNCE" }, 1)) |i| return if (i == 0) .cancel else .bounce;
    if (f.escape) return .cancel;
    if (f.enter) return .bounce;
    return .none;
}

fn drawOptions(ui: *Ui, body_in: Rect, state: *State, tracks: usize) void {
    var body = body_in;
    if (tracks < 2) state.mode = @intFromEnum(Mode.together);
    const choice = export_dialog.choice;
    choice(ui, dialog.row(ui, &body, "TAP", ROW_H), &.{ "INSTR", "FX", "FADER", "+SENDS" }, &state.tap, &.{});
    choice(ui, dialog.row(ui, &body, "CLIPS", ROW_H), &.{ "TOGETHER", "EACH" }, &state.mode, &.{ false, tracks < 2 });
    choice(ui, dialog.row(ui, &body, "SOURCE", ROW_H), &.{ "MUTE", "KEEP", "DELETE" }, &state.originals, &.{});
    export_dialog.tailRow(ui, dialog.row(ui, &body, "TAIL", ROW_H), &state.tail_auto, &state.tail_sec);
    {
        const r = dialog.row(ui, &body, "FORMAT", ROW_H);
        ctl.display(ui, r.center(r.w, ctl.displayHeight(false)), "32-BIT FLOAT WAV", .{ .color = style.text_dim });
    }
}
