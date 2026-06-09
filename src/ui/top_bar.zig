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
const snap_mod = @import("snap.zig");
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

const FILE_MENU_KEY: u64 = 0x5346494c45; // "SFILE"

pub fn draw(r: c.rl.Rectangle, transport: *Transport, edit_snap: *snap_mod.Setting, project_path: []const u8, project_path_chosen: bool, dirty: bool, m: widgets.Mouse) Result {
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
    const snap_btn_w = theme.size(18);
    const snap_field_w = theme.size(54);

    // ── File: one dropdown button showing the project name ───────────
    {
        var name_buf: [64:0]u8 = [_:0]u8{0} ** 64;
        const name = fileLabel(&name_buf, project_path, project_path_chosen, dirty);
        const fs = theme.fsBody();
        const icon_sz = fs;
        const nw = widgets.measureTextF(name, fs);
        const file_w = theme.size(6) + icon_sz + theme.size(4) + nw + theme.size(4) + icon_sz + theme.size(6);
        const file_rect = widgets.rect(x, y, file_w, h);
        const open = widgets.menuOpen(FILE_MENU_KEY);
        const hover = widgets.contains(file_rect, m.x, m.y) and !widgets.hasActiveDrag();
        const fill = if (open or hover) theme.slab_hi else theme.slab_fill;
        widgets.bevelRaised(file_rect, fill, theme.slab_hi, theme.slab_lo);
        widgets.drawIcon(.file, file_rect.x + theme.size(6), y + (h - icon_sz) / 2, icon_sz, theme.text_dim);
        widgets.drawLabelF(name, file_rect.x + theme.size(6) + icon_sz + theme.size(4), y + (h - fs) / 2 - 1, fs, if (dirty) theme.accent_hi else theme.text_fg);
        widgets.drawIcon(.caret_down, file_rect.x + file_w - icon_sz - theme.size(4), y + (h - icon_sz) / 2, icon_sz, theme.text_dim);
        widgets.tooltip(file_rect, "Project file", m);
        if (hover and m.left_pressed and !open) widgets.openMenuAt(FILE_MENU_KEY, file_rect.x, file_rect.y + file_rect.height);
        const file_items = [_]widgets.MenuItem{
            .{ .label = "Open\u{2026}  Cmd+O", .command = .file_open },
            .{ .label = "Save  Cmd+S", .command = .file_save },
            .{ .label = "Save As\u{2026}  Cmd+Shift+S", .command = .file_save_as },
        };
        switch (widgets.contextMenu(FILE_MENU_KEY, &file_items, m)) {
            .file_open => result.open_project = true,
            .file_save => result.save_project = true,
            .file_save_as => result.save_project_as = true,
            else => {},
        }
        x += file_w + GROUP_GAP;
    }

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

    // ── BPM: -  [LED 124.0 BPM]  +   (field drags/scrolls like a knob) ─
    const step_w = theme.size(16);
    if (widgets.buttonTip(widgets.rect(x, y, step_w, h), "-", "BPM -1", m)) {
        transport.setBpm(@round(transport.bpm()) - 1);
    }
    x += step_w + GAP;
    bpmField(widgets.rect(x, y, field_w_bpm, h), transport, m);
    x += field_w_bpm + GAP;
    if (widgets.buttonTip(widgets.rect(x, y, step_w, h), "+", "BPM +1", m)) {
        transport.setBpm(@round(transport.bpm()) + 1);
    }
    x += step_w + GAP;

    // ── Tap tempo button ─────────────────────────────────────────────
    if (widgets.buttonTip(widgets.rect(x, y, tap_w, h), "TAP", "Tap tempo", m)) {
        handleTap(transport);
    }
    x += tap_w + GROUP_GAP;

    // ── Position field ───────────────────────────────────────────────
    const pos_rect = widgets.rect(x, y, field_w_pos, h);
    posField(pos_rect, transport);
    x += field_w_pos + GROUP_GAP;

    drawSeparator(widgets.rect(x, y, theme.size(10), h));
    x += theme.size(10) + GROUP_GAP;

    if (widgets.buttonTip(widgets.rect(x, y, snap_btn_w, h), "-", "Coarser snap  [", m)) {
        edit_snap.* = edit_snap.*.coarser();
    }
    x += snap_btn_w + GAP;
    const snap_rect = widgets.rect(x, y, snap_field_w, h);
    snapField(snap_rect, edit_snap.*);
    widgets.tooltip(snap_rect, edit_snap.tooltip(), m);
    x += snap_field_w + GAP;
    if (widgets.buttonTip(widgets.rect(x, y, snap_btn_w, h), "+", "Finer snap  ]", m)) {
        edit_snap.* = edit_snap.*.finer();
    }
    x += snap_btn_w;

    // ── Logo plate (right) + blank-bevel filler ─────────────────────
    const title = "SLAB";
    const title_size = theme.fsTitle();
    const tw = widgets.measureTextF(title, title_size);
    const icon_sz = title_size;
    const logo_w = theme.size(8) + icon_sz + theme.size(5) + tw + theme.size(8);
    const logo_x = r.x + r.width - logo_w;

    // Inert raised bevel fills the empty space between the controls and the
    // logo so the bar reads as one complete instrument panel.
    const fill_x = x + GROUP_GAP;
    if (logo_x - fill_x > theme.size(4)) {
        widgets.bevelRaised(widgets.rect(fill_x, y, logo_x - fill_x - GROUP_GAP, h), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    }

    // Logo plate: waveform glyph + wordmark, amber on raised chrome.
    widgets.bevelRaised(widgets.rect(logo_x, y, logo_w, h), theme.slab_fill, theme.slab_hi, theme.slab_lo);
    widgets.drawIcon(.waveform, logo_x + theme.size(8), r.y + (r.height - icon_sz) / 2, icon_sz, theme.accent_hi);
    widgets.drawLabelF(title, logo_x + theme.size(8) + icon_sz + theme.size(5), r.y + (r.height - title_size) / 2 - 1, title_size, theme.accent_hi);

    return result;
}

fn fileLabel(buf: *[64:0]u8, path: []const u8, chosen: bool, dirty: bool) [*:0]const u8 {
    if (!chosen) return if (dirty) "*Untitled" else "Untitled";
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/') start = i + 1;
    }
    const base = path[start..];
    var off: usize = 0;
    if (dirty) {
        buf[0] = '*';
        off = 1;
    }
    const n = @min(base.len, 63 - off);
    @memcpy(buf[off .. off + n], base[0..n]);
    buf[off + n] = 0;
    return @ptrCast(&buf[0]);
}

fn drawSeparator(r: c.rl.Rectangle) void {
    widgets.bevelRaised(r, theme.slab_fill, theme.slab_hi, theme.slab_lo);
}

const BPM_SALT: u64 = 0x42504d44; // "BPMD"

fn bpmField(r: c.rl.Rectangle, transport: *Transport, m: widgets.Mouse) void {
    // Drag vertically / scroll to edit, like a knob.
    const new_bpm = widgets.dragValueV(r, BPM_SALT, transport.bpm(), 20.0, 400.0, 0.5, 1.0, m);
    if (new_bpm != transport.bpm()) transport.setBpm(new_bpm);

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

fn snapField(r: c.rl.Rectangle, edit_snap: snap_mod.Setting) void {
    const inner = widgets.displayField(r);
    const label = edit_snap.label();
    const tw = widgets.measureTextF(label, theme.fsBody());
    widgets.drawLabelF(label, inner.x + (inner.width - tw) / 2, inner.y + 1, theme.fsBody(), theme.text_fg);
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
