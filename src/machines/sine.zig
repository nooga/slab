//! Reference Zig machine: monophonic note-driven sine oscillator.
//! Responds to `ctx.note_in` (sorted by sample_offset). Last-note-wins
//! for overlapping note-ons; a note-off matching the current pitch
//! drops the gate. `reset` drops the gate and zeroes the phase.

const std = @import("std");
const c = @import("../c.zig");
const machine = @import("../machine.zig");
const ui_core = @import("../ui/core.zig");
const ui_ctl = @import("../ui/controls.zig");
const ui_style = @import("../ui/style.zig");

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

fn drawPanelImpl(state: *anyopaque, ui: *ui_core.Ui, r: ui_core.Rect) void {
    const self: *Sine = @ptrCast(@alignCast(state));
    ui.pushId(self);
    defer ui.popId();
    var body = ui_ctl.strip(ui, r, "SINE");
    // Gate LED in the strip header, right-aligned.
    ui_ctl.led(ui, r.right() - 10, r.y + 5, .round5, if (self.gate) .on else .off, ui_style.led_green);
    var g_norm: f32 = self.gain();
    const cell = ui_ctl.knobCell(.m, false);
    if (ui_ctl.knob(ui, body.cutLeft(cell[0] + 12), "gain", &g_norm, .{ .label = "GAIN", .show_readout = false })) self.setGain(g_norm);
    // Pitch readout: MIDI note while gated, dashes when idle.
    var buf: [8]u8 = undefined;
    const s = if (self.gate) (std.fmt.bufPrint(&buf, "{d:.0}", .{self.pitch}) catch "?") else "--";
    const d = body.center(@min(body.w, 48), ui_ctl.displayHeight(true));
    ui.textIn(&ui.fonts.legend, ui_core.Rect.xywh(d.x, d.y - 12, d.w, 12), "PITCH", ui_style.text_dim, .center, true);
    ui_ctl.display(ui, d, s, .{ .align_ = .center, .large = true });
}
