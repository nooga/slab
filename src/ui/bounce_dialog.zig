//! Bounce dialog (docs/27 §Bounce selection): one page in sections. What
//! was selected heads it; the signal is picked on its chain (instrument,
//! effects, fader, sends); then what to make, what happens to the
//! originals, the tail, the channels and the new tracks' names; the
//! footer says what will happen. While the capture renders it shows the
//! Export sheet's progress. A `dialog` (modal; main suppresses the input
//! behind it while `active`).

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const dialog = @import("dialog.zig");
const text_field = @import("text_field.zig");
const export_dialog = @import("export_dialog.zig");
const exporter = @import("../exporter.zig");

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
    channels: exporter.Channels = .auto,
    /// The new tracks' names: {track} is the source's (or "Bounce" for
    /// several).
    name: text_field.TextBuf = text_field.TextBuf.init("{track} bounce", 32),
    /// The name field had the keyboard last frame: Enter and Esc are its.
    editing: bool = false,

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

/// What's selected, for the head and the footer.
pub const Info = struct {
    clips: usize,
    /// Tracks the selection spans (EACH needs two).
    tracks: usize,
    seconds: f64,
};

pub const Result = enum { none, cancel, bounce };

const W: i32 = 460;
const H: i32 = 330;
const ROW_H: i32 = 20;
const LABEL_W: i32 = 84;
/// The longest tail: AUTO renders up to this and stops at silence.
pub const TAIL_MAX = export_dialog.TAIL_MAX;

const TAILS = [_][]const u8{ "AUTO", "NONE", "1 S", "2 S", "4 S", "8 S", "15 S", "30 S" };
const TAIL_SECS = [_]f32{ 0, 0, 1, 2, 4, 8, 15, 30 };

/// Draw the dialog centered in `screen`.
///   - `progress == null`  → options (CANCEL / BOUNCE).
///   - `progress != null`  → bouncing (LED bar + stats; CANCEL).
pub fn draw(ui: *Ui, screen: Rect, state: *State, info: Info, progress: ?export_dialog.Progress) Result {
    if (!state.active) return .none;
    const f = dialog.begin(ui, screen, "bounce-dialog", "BOUNCE", W, H);
    defer dialog.end(ui);
    var head_buf: [64]u8 = undefined;
    ui.textIn(&ui.fonts.legend, f.title, std.fmt.bufPrint(&head_buf, "{d} CLIP{s} ON {d} TRACK{s} · {d:.1} S", .{
        info.clips, if (info.clips == 1) "" else "S", info.tracks, if (info.tracks == 1) "" else "S", info.seconds,
    }) catch "", style.text_dim, .right, false);
    if (progress) |p| {
        var body = f.body;
        _ = body.cutTop(30);
        export_dialog.drawProgress(ui, body, p);
        if (dialog.buttons(ui, f.buttons, &.{"CANCEL"}, null) != null or f.escape) return .cancel;
        return .none;
    }
    const editing = state.editing;
    state.editing = false;
    if (info.tracks < 2) state.mode = @intFromEnum(Mode.together);
    var body = f.body;

    dialog.section(ui, &body, "TAKE THE SIGNAL AFTER");
    chain(ui, body.cutTop(24), state);
    _ = body.cutTop(4);
    dialog.hint(ui, &body, TAP_ABOUT[state.tap], 0);

    dialog.section(ui, &body, "RESULT");
    const h = ctl.displayHeight(false);
    {
        var r = dialog.rowW(ui, &body, "MAKE", ROW_H, LABEL_W);
        const each_ok = info.tracks >= 2;
        _ = ctl.displaySelectEx(ui, r.cutLeft(190).center(190, h), "mode", &state.mode, &.{ "ONE CLIP", "ONE CLIP PER TRACK" }, "MAKE", .{ .align_ = .left, .disabled = !each_ok });
        if (!each_ok) ui.textIn(&ui.fonts.legend, r.insetXY(8, 0), "ONE TRACK SELECTED", style.text_mute, .left, false);
    }
    {
        var r = dialog.rowW(ui, &body, "ORIGINALS", ROW_H, LABEL_W);
        _ = ctl.displaySelectEx(ui, r.cutLeft(190).center(190, h), "originals", &state.originals, &.{ "MUTE, CAN THAW", "KEEP PLAYING", "DELETE" }, "ORIGINALS", .{ .align_ = .left });
    }
    {
        var r = dialog.rowW(ui, &body, "TAIL", ROW_H, LABEL_W);
        var tail = tailIndex(state);
        if (ctl.displaySelectEx(ui, r.cutLeft(88).center(88, h), "tail", &tail, &TAILS, "TAIL", .{ .align_ = .left })) {
            state.tail_auto = tail == 0;
            if (tail > 0) state.tail_sec = TAIL_SECS[tail];
        }
        _ = r.cutLeft(14);
        ui.textIn(&ui.fonts.legend, r.cutLeft(64), "CHANNELS", style.text_dim, .left, true);
        var ch: u8 = @intFromEnum(state.channels);
        if (ctl.displaySelectEx(ui, r.cutLeft(88).center(88, h), "channels", &ch, &.{ "STEREO", "MONO", "AUTO" }, "CHANNELS", .{ .align_ = .left })) state.channels = @enumFromInt(ch);
    }
    {
        const r = dialog.rowW(ui, &body, "NAME", ROW_H, LABEL_W);
        const key = "name";
        _ = text_field.field(ui, Rect.xywh(r.x, r.y, 190, r.h), key, &state.name, .{});
        if (ui.focus == ui.id(key)) state.editing = true;
        ui.textIn(&ui.fonts.legend, Rect.xywh(r.x + 198, r.y, r.w - 198, r.h), "{track}: THE SOURCE'S NAME", style.text_mute, .left, false);
    }

    var bar = f.buttons;
    var sum_buf: [96]u8 = undefined;
    const n = if (state.mixMode() == .each) info.tracks else 1;
    const what = std.fmt.bufPrint(&sum_buf, "{d} NEW TRACK{s} UNDER THE SOURCES · 32-BIT FLOAT WAV IN THE PROJECT", .{ n, if (n == 1) "" else "S" }) catch "";
    ui.marquee(&ui.fonts.legend, bar.cutLeft(bar.w - 2 * 76 - 12), what, style.text_dim, .left, false, false);
    if (dialog.buttons(ui, bar, &.{ "CANCEL", "BOUNCE" }, 1)) |i| return if (i == 0) .cancel else .bounce;
    if (editing) return .none;
    if (f.escape) return .cancel;
    if (f.enter) return .bounce;
    return .none;
}

const TAP_ABOUT = [_][]const u8{
    "THE INSTRUMENT ALONE: RE-EFFECT IT LATER",
    "THROUGH ITS EFFECTS, BEFORE THE FADER; THE NEW TRACK TAKES ITS MIX",
    "AS IT SITS IN THE MIX, FADER AND PAN PRINTED",
    "AS IT SITS IN THE MIX, WITH THE REVERB AND DELAY IT SENDS TO",
};

fn tailIndex(state: *const State) u8 {
    if (state.tail_auto) return 0;
    if (state.tail_sec <= 0) return 1;
    for (TAIL_SECS[2..], 2..) |sec, i| if (state.tail_sec <= sec) return @intCast(i);
    return TAILS.len - 1;
}

/// The chain, left to right, each stage a cap; the chosen one is lit and
/// the stages it passes through stay bright.
fn chain(ui: *Ui, r_: Rect, state: *State) void {
    var r = r_;
    ui.pushId("chain");
    defer ui.popId();
    const labels = [_][]const u8{ "INSTRUMENT", "EFFECTS", "FADER", "+ SENDS" };
    const arrow_w: i32 = 18;
    const cw = @divFloor(r.w - 3 * arrow_w, 4);
    for (labels, 0..) |lab, i| {
        var on = state.tap == i;
        const cr = r.cutLeft(cw);
        if (ctl.button(ui, cr, i, &on, .{ .kind = .latch, .label = lab, .lit = style.accent, .touch_name = "SIGNAL" })) state.tap = @intCast(i);
        if (i + 1 < labels.len) {
            const ar = r.cutLeft(arrow_w);
            const passed = i < state.tap;
            const col = if (passed) style.text else style.text_mute;
            const y = ar.y + @divFloor(ar.h, 2);
            ui.rect(Rect.xywh(ar.x + 4, y, ar.w - 8, 1), col);
            ui.rect(Rect.xywh(ar.right() - 6, y - 2, 1, 5), col);
            ui.rect(Rect.xywh(ar.right() - 5, y - 1, 1, 3), col);
        }
    }
}
