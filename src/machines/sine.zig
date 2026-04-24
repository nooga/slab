//! Reference Zig machine: monophonic note-driven sine oscillator.
//! Responds to `ctx.note_in` (sorted by sample_offset). Last-note-wins
//! for overlapping note-ons; a note-off matching the current pitch
//! drops the gate. `reset` drops the gate and zeroes the phase.

const std = @import("std");
const c = @import("../c.zig");
const machine = @import("../machine.zig");
const theme = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");

const TAU: f32 = std.math.tau;

pub const Sine = struct {
    phase: f32 = 0,
    /// Current playing pitch (MIDI, fractional allowed).
    pitch: f32 = 60,
    /// Gate: true between note-on and matching note-off.
    gate: bool = false,
    /// 0..1 gain, bit-cast for UI↔audio atomic handoff.
    gain_bits: std.atomic.Value(u32),

    pub fn init() Sine {
        return .{
            .gain_bits = std.atomic.Value(u32).init(@bitCast(@as(f32, 0.25))),
        };
    }

    pub fn gain(self: *const Sine) f32 {
        return @bitCast(self.gain_bits.load(.monotonic));
    }

    pub fn setGain(self: *Sine, g: f32) void {
        const clamped = std.math.clamp(g, 0.0, 1.0);
        self.gain_bits.store(@bitCast(clamped), .monotonic);
    }

    pub fn machineInterface(self: *Sine) machine.Machine {
        return .{
            .name = "Sine",
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .panel_w = PANEL_W,
        };
    }
};

fn midiToHz(pitch: f32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (pitch - 69.0) / 12.0);
}

fn applyEvent(self: *Sine, event: machine.NoteEvent) void {
    switch (event.kind) {
        .note_on => {
            if (event.velocity > 0) {
                self.pitch = event.pitch;
                self.gate = true;
            } else {
                // Some sources send note-on with velocity=0 as note-off.
                if (self.gate and @abs(self.pitch - event.pitch) < 0.01) {
                    self.gate = false;
                }
            }
        },
        .note_off => {
            if (self.gate and @abs(self.pitch - event.pitch) < 0.01) {
                self.gate = false;
            }
        },
        .reset => {
            self.gate = false;
        },
        else => {},
    }
}

fn renderRange(self: *Sine, l: []f32, r: []f32, gain: f32, sr: f32) void {
    if (!self.gate) {
        @memset(l, 0);
        @memset(r, 0);
        return;
    }
    const step: f32 = TAU * midiToHz(self.pitch) / sr;
    var phase = self.phase;
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        const s = @sin(phase) * gain;
        l[i] = s;
        r[i] = s;
        phase += step;
        if (phase > TAU) phase -= TAU;
    }
    self.phase = phase;
}

fn renderImpl(
    state: *anyopaque,
    ctx: *const machine.MachineCtx,
    l: []f32,
    r: []f32,
) void {
    const self: *Sine = @ptrCast(@alignCast(state));
    const gain = self.gain();
    const sr: f32 = @floatCast(ctx.sample_rate);

    // Sub-block render: process events in order, render each gap
    // between events with current state.
    var pos: u32 = 0;
    const events: []const machine.NoteEvent = if (ctx.note_in) |p|
        p[0..ctx.note_in_count]
    else
        &[_]machine.NoteEvent{};

    for (events) |event| {
        const target = @min(event.sample_offset, ctx.block_size);
        if (target > pos) {
            renderRange(self, l[pos..target], r[pos..target], gain, sr);
            pos = target;
        }
        applyEvent(self, event);
    }
    if (pos < ctx.block_size) {
        renderRange(self, l[pos..], r[pos..], gain, sr);
    }
}

fn resetImpl(state: *anyopaque) void {
    const self: *Sine = @ptrCast(@alignCast(state));
    self.gate = false;
    self.phase = 0;
}

// Width of each control cell in the panel strip.
const CELL_W: f32 = 52;
// Total panel card width: 2 cells + 1px separator + 2px left/right borders.
pub const PANEL_W: f32 = CELL_W * 2 + 1 + 2;

fn drawPanelImpl(state: *anyopaque, r: c.rl.Rectangle, mouse: widgets.Mouse) void {
    const self: *Sine = @ptrCast(@alignCast(state));

    // ── Background (no outer border — bay edge is the boundary) ──
    c.rl.DrawRectangleRec(r, theme.pane_alt);

    // ── Header strip ─────────────────────────────────────────────
    const HDR_H: f32 = theme.paneHeaderH();
    const hdr = widgets.rect(r.x, r.y, r.width, HDR_H);
    widgets.bevelRaised(hdr, theme.slab_fill, theme.slab_hi, theme.slab_lo);
    widgets.drawLabelF("SINE", hdr.x + 4, hdr.y + 2, theme.fsTiny(), theme.text_fg);

    // Gate LED — lights up while a note is held.
    const LED_SZ: f32 = 5;
    const led_r = widgets.rect(
        hdr.x + hdr.width - LED_SZ - 4,
        hdr.y + (HDR_H - LED_SZ) / 2,
        LED_SZ,
        LED_SZ,
    );
    widgets.led(led_r, self.gate, theme.accent_play);

    // ── Body: horizontal row of cells ────────────────────────────
    const body = widgets.rect(r.x + 1, r.y + HDR_H + 1, r.width - 2, r.height - HDR_H - 2);

    // Cell 0 — GAIN knob.
    const gain_cell = widgets.rect(body.x, body.y, CELL_W, body.height);
    var g_norm: f32 = self.gain();
    if (widgets.knob(gain_cell, "GAIN", &g_norm, mouse)) {
        self.setGain(g_norm);
    }

    // Separator.
    c.rl.DrawRectangle(
        @intFromFloat(body.x + CELL_W),
        @intFromFloat(body.y),
        1,
        @intFromFloat(body.height),
        theme.slab_lo,
    );

    // Cell 1 — PITCH display.
    const pitch_cell = widgets.rect(body.x + CELL_W + 1, body.y, CELL_W, body.height);
    drawPitchCell(pitch_cell, self);
}

fn drawPitchCell(cell: c.rl.Rectangle, self: *const Sine) void {
    const cx = cell.x + cell.width / 2;
    const cy = cell.y + cell.height / 2;

    // "PITCH" title directly above value.
    const title_w = widgets.measureTextF("PITCH", theme.fsTiny());
    widgets.drawLabelF("PITCH", cx - title_w / 2, cy - theme.fsTiny() - 2, theme.fsTiny(), theme.text_dim);

    // Value: MIDI number when playing, dim dash when idle.
    var buf: [8:0]u8 = undefined;
    const s: [*:0]const u8 = if (self.gate) blk: {
        break :blk (std.fmt.bufPrintZ(&buf, "{d:.0}", .{self.pitch}) catch @as([:0]const u8, "?")).ptr;
    } else blk: {
        buf[0] = '-';
        buf[1] = '-';
        buf[2] = 0;
        break :blk @as([*:0]const u8, @ptrCast(&buf));
    };
    const col = if (self.gate) theme.accent_hi else theme.text_mute;
    const sw = widgets.measureTextF(s, theme.fsTiny());
    widgets.drawLabelF(s, cx - sw / 2, cy, theme.fsTiny(), col);
}
