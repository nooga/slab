//! Transport toolbar — OpenTTD-packed. No outer bevel on the bar; each
//! element carries its own bevel and abuts its neighbours with a 1 px
//! separator. Readout fields use the double (raised + sunken) bevel.
//!
//! Buttons:   ▶/■  ●                (transport)
//! Fields:   [ ● 120.0 BPM ]  [TAP]  [ 1.1.1 BAR ]
//! The LED on the BPM pulses with the beat.

const std = @import("std");
const c = @import("../c.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const Transport = @import("../transport.zig").Transport;

const GAP: f32 = 0;
const GROUP_GAP: f32 = 0;
// Tap tempo ring buffer.
const TAP_MAX = 4;
var tap_times: [TAP_MAX]f64 = .{ 0, 0, 0, 0 };
var tap_count: usize = 0;
var tap_last: f64 = 0;

pub const Result = struct {
    open_project: bool = false,
    save_project: bool = false,
    save_project_as: bool = false,
};

pub fn draw(r: c.rl.Rectangle, transport: *Transport, m: widgets.Mouse) Result {
    var result: Result = .{};

    // Bar background — flat, no bevel.
    c.rl.DrawRectangleRec(r, theme.pane_bg);
    // Bottom hairline separates bar from the panes below.
    c.rl.DrawRectangle(
        @intFromFloat(r.x),
        @intFromFloat(r.y + r.height - 1),
        @intFromFloat(r.width),
        1,
        theme.slab_edge,
    );

    const y = r.y + 1;
    const h = r.height - 2;
    var x = r.x + 2;
    const btn_w = theme.size(22);
    const tap_w = theme.size(30);
    const field_w_bpm = theme.size(80);
    const field_w_pos = theme.size(74);

    // ── File operations ──────────────────────────────────────────────
    if (widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), .folder, null, "Open project  Cmd+O", m)) {
        result.open_project = true;
    }
    x += btn_w + GAP;

    if (widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), .file, null, "Save project  Cmd+S", m)) {
        result.save_project = true;
    }
    x += btn_w + GAP;

    if (widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), .pencil, null, "Save project as  Cmd+Shift+S", m)) {
        result.save_project_as = true;
    }
    x += btn_w + GROUP_GAP;

    drawSeparator(widgets.rect(x, y, theme.size(10), h));
    x += theme.size(10) + GROUP_GAP;

    // ── Transport buttons ─────────────────────────────────────────────
    const playing = transport.isPlaying();
    const play_icon: widgets.Icon = if (playing) .stop else .play;
    const play_fill: ?c.rl.Color = if (playing) theme.accent_play else null;
    if (widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), play_icon, play_fill, if (playing) "Stop  Space" else "Play  Space", m)) {
        transport.toggle();
    }
    x += btn_w + GAP;

    _ = widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), .record, null, "Record arm", m);
    x += btn_w + GROUP_GAP;

    const loop_fill: ?c.rl.Color = if (transport.loopEnabled()) theme.accent_hi else null;
    if (widgets.iconButtonTip(widgets.rect(x, y, btn_w, h), .repeat, loop_fill, "Loop on/off", m)) {
        transport.toggleLoop();
    }
    x += btn_w + GROUP_GAP;

    // ── BPM field with metronome LED ─────────────────────────────────
    const bpm_rect = widgets.rect(x, y, field_w_bpm, h);
    bpmField(bpm_rect, transport);
    x += field_w_bpm + GAP;

    // ── Tap tempo button ─────────────────────────────────────────────
    if (widgets.buttonTip(widgets.rect(x, y, tap_w, h), "TAP", "Tap tempo", m)) {
        handleTap(transport);
    }
    x += tap_w + GROUP_GAP;

    // ── Position field ───────────────────────────────────────────────
    const pos_rect = widgets.rect(x, y, field_w_pos, h);
    posField(pos_rect, transport);
    x += field_w_pos;

    // ── SLAB title, right aligned ────────────────────────────────────
    const title = "SLAB";
    const title_size = theme.fsTitle();
    const tw = widgets.measureTextF(title, title_size);
    widgets.drawLabelF(
        title,
        r.x + r.width - tw - 6,
        r.y + (r.height - title_size) / 2 - 1,
        title_size,
        theme.accent_hi,
    );

    return result;
}

fn drawSeparator(r: c.rl.Rectangle) void {
    widgets.bevelRaised(r, theme.slab_fill, theme.slab_hi, theme.slab_lo);
}

fn bpmField(r: c.rl.Rectangle, transport: *const Transport) void {
    const inner = widgets.displayField(r);

    // Metronome LED — pulses for ~80 ms at the start of each beat,
    // red on the downbeat of each 4-beat bar, green elsewhere.
    const beats = transport.beats();
    const beat_frac = @mod(beats, 1);
    const is_downbeat = @as(u32, @intFromFloat(@floor(@mod(beats, 4)))) == 0;
    const pulse_on = transport.isPlaying() and beat_frac < 0.12;
    const led_color = if (is_downbeat) theme.accent_rec else theme.accent_play;

    const led_sz = theme.fine(6);
    const led_rect = widgets.rect(inner.x + 2, inner.y + (inner.height - led_sz) / 2, led_sz, led_sz);
    widgets.led(led_rect, pulse_on, led_color);

    // BPM value (monospace for stability).
    var buf: [16]u8 = undefined;
    const bpm_str = std.fmt.bufPrintZ(&buf, "{d:.1}", .{transport.bpm()}) catch "?";
    widgets.drawLabelF(
        bpm_str.ptr,
        led_rect.x + led_rect.width + 4,
        inner.y + 1,
        theme.fsBody(),
        theme.text_fg,
    );

    // "BPM" caption, right side.
    const cap = "BPM";
    const cap_w = widgets.measureTextF(cap, theme.fsTiny());
    widgets.drawLabelF(
        cap,
        inner.x + inner.width - cap_w - 2,
        inner.y + inner.height - theme.fsTiny() - 1,
        theme.fsTiny(),
        theme.text_mute,
    );
}

fn posField(r: c.rl.Rectangle, transport: *const Transport) void {
    const inner = widgets.displayField(r);

    var buf: [32]u8 = undefined;
    const beats = transport.beats();
    const bar = @as(u32, @intFromFloat(@floor(beats / 4))) + 1;
    const beat_in_bar = @as(u32, @intFromFloat(@floor(@mod(beats, 4)))) + 1;
    const sixteenth = @as(u32, @intFromFloat(@floor(@mod(beats, 1) * 4))) + 1;
    const s = std.fmt.bufPrintZ(&buf, "{d}.{d}.{d}", .{ bar, beat_in_bar, sixteenth }) catch "?";
    widgets.drawLabelF(s.ptr, inner.x + 3, inner.y + 1, theme.fsBody(), theme.text_fg);

    const cap = "BAR";
    const cap_w = widgets.measureTextF(cap, theme.fsTiny());
    widgets.drawLabelF(
        cap,
        inner.x + inner.width - cap_w - 2,
        inner.y + inner.height - theme.fsTiny() - 1,
        theme.fsTiny(),
        theme.text_mute,
    );
}

fn handleTap(transport: *Transport) void {
    const now = c.rl.GetTime();
    // If too long since last tap, reset the buffer.
    if (tap_count > 0 and (now - tap_last) > 2.0) {
        tap_count = 0;
    }
    tap_last = now;
    if (tap_count < TAP_MAX) {
        tap_times[tap_count] = now;
        tap_count += 1;
    } else {
        // Shift left.
        var i: usize = 0;
        while (i < TAP_MAX - 1) : (i += 1) tap_times[i] = tap_times[i + 1];
        tap_times[TAP_MAX - 1] = now;
    }

    if (tap_count >= 2) {
        // Average interval between taps.
        var sum: f64 = 0;
        var n: usize = 0;
        var i: usize = 1;
        const end = tap_count;
        while (i < end) : (i += 1) {
            sum += tap_times[i] - tap_times[i - 1];
            n += 1;
        }
        if (n > 0) {
            const interval = sum / @as(f64, @floatFromInt(n));
            if (interval > 0.1) {
                const bpm: f32 = @floatCast(60.0 / interval);
                transport.setBpm(bpm);
            }
        }
    }
}
