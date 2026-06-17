//! Render Audio modal — a small brutalist dialog that collects bounce
//! options (time range + reverb/delay tail), then shows a live progress bar
//! and stats while the offline render runs on a worker thread. Drawn after
//! everything else and modal for the mouse (main neutralizes pane input
//! while it is active, like an open menu).

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");

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

const TAIL_KEY: u64 = 0x52454e44544c; // "RENDTL"

/// Draw the modal centred on the screen.
///   - `progress == null`  → options view (RANGE, TAIL, FORMAT, buttons).
///   - `progress != null`  → rendering view (bar + stats + CANCEL).
/// `loop_available` greys the Loop range option when no loop region is set.
pub fn draw(state: *State, sw: f32, sh: f32, loop_available: bool, progress: ?Progress, m: widgets.Mouse) Result {
    if (!state.active) return .none;

    // Dim the rest of the UI.
    c.rl.DrawRectangle(0, 0, @intFromFloat(sw), @intFromFloat(sh), c.rl.Color{ .r = 0, .g = 0, .b = 0, .a = 150 });

    const w = theme.size(260);
    const h = theme.size(168);
    const x = @round((sw - w) / 2);
    const y = @round((sh - h) / 2);
    const panel = widgets.rect(x, y, w, h);
    widgets.bevelRaised(panel, theme.pane_bg, theme.slab_hi, theme.slab_lo);

    const pad = theme.size(12);

    // Title + underline.
    widgets.drawLabelF("RENDER AUDIO", x + pad, y + theme.size(8), theme.fsTitle(), theme.text_fg);
    c.rl.DrawRectangle(
        @intFromFloat(x + pad),
        @intFromFloat(y + theme.size(8) + theme.fsTitle() + theme.size(4)),
        @intFromFloat(w - pad * 2),
        1,
        theme.slab_edge,
    );

    if (progress) |p| return drawProgress(panel, pad, p, m);
    return drawOptions(state, panel, pad, loop_available, m);
}

fn drawOptions(state: *State, panel: c.rl.Rectangle, pad: f32, loop_available: bool, m: widgets.Mouse) Result {
    const x = panel.x;
    const y = panel.y;
    const w = panel.width;
    const h = panel.height;
    const fs = theme.fsBody();
    var cy = y + theme.size(34);
    const ctrl_w = w - pad * 2;

    // Range: Project | Loop (dead third cell as a spacer).
    var range_val: u8 = state.range;
    if (!loop_available and range_val == @intFromEnum(Range.loop)) range_val = @intFromEnum(Range.project);
    const range_rect = widgets.rect(x + pad, cy, ctrl_w, theme.size(30));
    const loop_label: [*:0]const u8 = if (loop_available) "LOOP" else "LOOP \u{2014}";
    if (widgets.switch3(range_rect, "RANGE", "PROJECT", loop_label, "", &range_val, m)) {
        if (range_val == 2) range_val = state.range; // ignore the dead third cell
        if (range_val == @intFromEnum(Range.loop) and !loop_available)
            range_val = @intFromEnum(Range.project);
    }
    state.range = range_val;
    cy += theme.size(38);

    // Tail field (seconds) — drag / scroll to adjust.
    widgets.drawLabelF("TAIL", x + pad, cy, theme.fsTiny(), theme.text_dim);
    const field = widgets.rect(x + pad, cy + theme.fsTiny() + 2, ctrl_w, theme.size(20));
    widgets.bevelSunken(field, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    state.tail_sec = widgets.dragValueV(field, TAIL_KEY, state.tail_sec, 0.0, 30.0, 0.05, 0.5, m);
    var tbuf: [24:0]u8 = undefined;
    const tstr = std.fmt.bufPrintZ(&tbuf, "{d:.1} s", .{state.tail_sec}) catch "0.0 s";
    const tw = widgets.measureTextF(tstr, fs);
    widgets.drawLabelF(tstr, field.x + (field.width - tw) / 2, field.y + (field.height - fs) / 2 - 1, fs, theme.text_fg);
    cy += theme.fsTiny() + 2 + theme.size(20) + theme.size(10);

    // Format note.
    widgets.drawLabelF("FORMAT  24-bit WAV \u{00B7} 48 kHz", x + pad, cy, theme.fsTiny(), theme.text_mute);

    // Buttons.
    const btn_h = theme.size(22);
    const btn_w = theme.size(76);
    const by = y + h - pad - btn_h;
    const render_rect = widgets.rect(x + w - pad - btn_w, by, btn_w, btn_h);
    const cancel_rect = widgets.rect(render_rect.x - theme.size(8) - btn_w, by, btn_w, btn_h);

    var result: Result = .none;
    if (widgets.button(cancel_rect, "CANCEL", m)) result = .cancel;
    if (widgets.buttonColored(render_rect, "RENDER", theme.accent_play, m)) result = .render;
    return result;
}

fn drawProgress(panel: c.rl.Rectangle, pad: f32, p: Progress, m: widgets.Mouse) Result {
    const x = panel.x;
    const y = panel.y;
    const w = panel.width;
    const h = panel.height;
    const ctrl_w = w - pad * 2;

    // Progress bar.
    const bar = widgets.rect(x + pad, y + theme.size(40), ctrl_w, theme.size(22));
    widgets.bevelSunken(bar, theme.pane_alt, theme.slab_hi, theme.slab_lo);
    const frac = std.math.clamp(p.fraction, 0.0, 1.0);
    const fill_w = (bar.width - 2) * frac;
    if (fill_w > 0)
        c.rl.DrawRectangleRec(widgets.rect(bar.x + 1, bar.y + 1, fill_w, bar.height - 2), theme.accent_play);
    var pbuf: [16:0]u8 = undefined;
    const pstr = std.fmt.bufPrintZ(&pbuf, "{d:.0}%", .{frac * 100.0}) catch "0%";
    const pfs = theme.fsBody();
    const pw = widgets.measureTextF(pstr, pfs);
    widgets.drawLabelF(pstr, bar.x + (bar.width - pw) / 2, bar.y + (bar.height - pfs) / 2 - 1, pfs, theme.text_fg);

    // Stats lines.
    var sy = bar.y + bar.height + theme.size(10);
    const fs = theme.fsTiny();
    var b0: [48:0]u8 = undefined;
    const l0 = std.fmt.bufPrintZ(&b0, "{d:.1}s / {d:.1}s audio", .{ p.rendered_s, p.total_s }) catch "";
    widgets.drawLabelF(l0, x + pad, sy, fs, theme.text_dim);
    sy += fs + theme.size(4);
    var b1: [48:0]u8 = undefined;
    const l1 = std.fmt.bufPrintZ(&b1, "{d:.1}s elapsed \u{00B7} {d:.1}x realtime", .{ p.elapsed_s, p.speed_x }) catch "";
    widgets.drawLabelF(l1, x + pad, sy, fs, theme.text_dim);

    // Cancel button.
    const btn_h = theme.size(22);
    const btn_w = theme.size(76);
    const by = y + h - pad - btn_h;
    const cancel_rect = widgets.rect(x + w - pad - btn_w, by, btn_w, btn_h);
    if (widgets.button(cancel_rect, "CANCEL", m)) return .cancel;
    return .none;
}
