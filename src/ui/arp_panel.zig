//! The arpeggiator's card in the machine bay (docs/45): the note slot ahead
//! of the instrument. A title bar (remove, name, power) over two rows of
//! selects and knobs and the 16-step pattern.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const ctl = @import("controls.zig");
const menu = @import("menu.zig");
const arp_mod = @import("../arp.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Arp = arp_mod.Arp;

pub const TITLE_H: i32 = 20;
pub const W: i32 = 332;
const PAD: i32 = 6;
const LEGEND_H: i32 = 10;
const KNOB: ctl.Size = .s;

pub const Out = struct {
    /// The × was clicked.
    remove: bool = false,
    /// A setting changed (the project is dirty).
    changed: bool = false,
};

/// Draw the card in `card`; its height is the bay's.
pub fn draw(ui: *Ui, card: Rect, a: *Arp) Out {
    var out = Out{};
    ui.pushId(a);
    defer ui.popId();
    var bar = Rect.xywh(card.x, card.y, card.w, TITLE_H);
    const body = Rect.xywh(card.x, card.y + TITLE_H, card.w, card.h - TITLE_H);

    const del = bar.cutLeft(18);
    if (ctl.button(ui, del, "del", null, .{ .label = "\u{D7}", .flush = true })) out.remove = true;
    menu.tip(ui, del, "Remove the arpeggiator");

    var on = a.on.load(.monotonic) != 0;
    const pwr = bar.cutRight(56);
    if (ctl.button(ui, pwr, "power", &on, .{ .kind = .latch, .label = if (on) "ON" else "BYP", .led = style.led_green, .led_off = style.led_red, .flush = true })) {
        a.on.store(@intFromBool(on), .monotonic);
        out.changed = true;
    }
    menu.tip(ui, pwr, if (on) "Active: click to bypass (notes pass through)" else "Bypassed: click to arpeggiate");

    _ = ctl.button(ui, bar, "name", null, .{ .flush = true, .disabled = true });
    ui.textIn(&ui.fonts.body_bold, Rect.xywh(bar.x + 6, bar.y, bar.w - 8, bar.h - 1), "ARPEGGIATOR", style.text_dim, .left, true);

    var rest = ui.plate(body, .{});
    rest = rest.insetXY(PAD, 4);
    ui.clip(body);
    defer ui.unclip();

    // Row 1: what and when.
    var row = rest.cutTop(LEGEND_H + ctl.displayHeight(false));
    out.changed = selectCell(ui, &row, 78, "MODE", "mode", &a.mode, &arp_mod.MODE_LABELS, 0) or out.changed;
    out.changed = selectCell(ui, &row, 58, "RATE", "rate", &a.rate, &arp_mod.RATE_LABELS, 0) or out.changed;
    {
        const labels = [_][]const u8{ "1", "2", "3", "4" };
        const oct = a.octaves.load(.monotonic);
        var v: u8 = @intCast(std.math.clamp(oct, 1, arp_mod.OCTAVES_MAX) - 1);
        const cell = row.cutLeft(42);
        legend(ui, cell, "OCT");
        if (ctl.displaySelectEx(ui, selectRect(cell), "oct", &v, &labels, "OCTAVES", .{})) {
            a.octaves.store(@as(u32, v) + 1, .monotonic);
            out.changed = true;
        }
        _ = row.cutLeft(PAD);
    }
    out.changed = selectCell(ui, &row, 66, "VELOCITY", "vel", &a.vel_mode, &arp_mod.VEL_LABELS, 0) or out.changed;
    {
        var latch = a.latch.load(.monotonic) != 0;
        const lr = selectRect(row.cutLeft(54));
        if (ctl.button(ui, lr, "latch", &latch, .{ .kind = .latch, .label = "LATCH", .led = style.accent })) {
            a.latch.store(@intFromBool(latch), .monotonic);
            out.changed = true;
        }
        menu.tip(ui, lr, "Hold the notes after the keys are up; the next keys replace them");
    }

    // Row 2: feel.
    _ = rest.cutTop(2);
    const cell = ctl.knobCell(KNOB, true);
    var knobs = rest.cutTop(cell[1]);
    const cw = cell[0] + 12;
    var buf: [16]u8 = undefined;
    {
        var v = Arp.getF(&a.gate_bits);
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 100}) catch "";
        if (ctl.knob(ui, knobs.cutLeft(cw), "gate", &v, .{ .size = KNOB, .label = "GATE", .readout = s, .default = 0.6 })) {
            Arp.setF(&a.gate_bits, v);
            out.changed = true;
        }
    }
    {
        var v = Arp.getF(&a.swing_bits) / 0.75;
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 75}) catch "";
        if (ctl.knob(ui, knobs.cutLeft(cw), "swing", &v, .{ .size = KNOB, .label = "SWING", .readout = s, .default = 0 })) {
            Arp.setF(&a.swing_bits, v * 0.75);
            out.changed = true;
        }
    }
    {
        var v = Arp.getF(&a.accent_bits);
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 100}) catch "";
        if (ctl.knob(ui, knobs.cutLeft(cw), "accent", &v, .{ .size = KNOB, .label = "ACCENT", .readout = s, .default = 0.5 })) {
            Arp.setF(&a.accent_bits, v);
            out.changed = true;
        }
    }
    {
        var v = Arp.getF(&a.human_bits);
        const s = std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 100}) catch "";
        if (ctl.knob(ui, knobs.cutLeft(cw), "human", &v, .{ .size = KNOB, .label = "HUMAN", .readout = s, .default = 0 })) {
            Arp.setF(&a.human_bits, v);
            out.changed = true;
        }
    }
    {
        const fixed = a.vel_mode.load(.monotonic) == @intFromEnum(arp_mod.VelMode.fixed);
        var v = @as(f32, @floatFromInt(a.vel_fixed.load(.monotonic) - 1)) / 126.0;
        const s = std.fmt.bufPrint(&buf, "{d}", .{a.vel_fixed.load(.monotonic)}) catch "";
        if (ctl.knob(ui, knobs.cutLeft(cw), "fixed", &v, .{ .size = KNOB, .label = "VEL", .readout = s, .default = 99.0 / 126.0, .disabled = !fixed })) {
            a.vel_fixed.store(@intFromFloat(@round(v * 126) + 1), .monotonic);
            out.changed = true;
        }
    }

    // Row 3: the pattern. Click a step to cycle rest, note, accent, tie.
    _ = rest.cutTop(2);
    var pat = rest.cutTop(18);
    const len = std.math.clamp(a.steps.load(.monotonic), 1, arp_mod.MAX_STEPS);
    {
        var v: u8 = @intCast(len - 1);
        var labels: [arp_mod.MAX_STEPS][]const u8 = undefined;
        for (0..arp_mod.MAX_STEPS) |i| labels[i] = LEN_LABELS[i];
        const lr = pat.cutLeft(40);
        if (ctl.displaySelectEx(ui, lr, "len", &v, &labels, "STEPS", .{})) {
            a.steps.store(@as(u32, v) + 1, .monotonic);
            out.changed = true;
        }
        menu.tip(ui, lr, "Pattern length in steps");
        _ = pat.cutLeft(PAD);
    }
    const step_w = @divFloor(pat.w, arp_mod.MAX_STEPS);
    for (0..arp_mod.MAX_STEPS) |i| {
        const r = pat.cutLeft(step_w);
        const c = a.cell(i);
        var lit = c != .rest;
        const inside = i < len;
        if (ctl.button(ui, r, i, &lit, .{
            .kind = .latch,
            .label = arp_mod.CELL_LABELS[@intFromEnum(c)],
            .lit = if (c == .accent) style.accent else null,
            .disabled = !inside,
            .flush = true,
        })) {
            a.setCell(i, @enumFromInt(@intFromEnum(c) +% 1));
            out.changed = true;
        }
    }
    return out;
}

const LEN_LABELS = blk: {
    const names = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16" };
    break :blk names;
};

fn legend(ui: *Ui, cell: Rect, text: []const u8) void {
    ui.textIn(&ui.fonts.legend, Rect.xywh(cell.x, cell.y, cell.w, LEGEND_H), text, style.text_dim, .left, true);
}

fn selectRect(cell: Rect) Rect {
    return Rect.xywh(cell.x, cell.y + LEGEND_H, cell.w, ctl.displayHeight(false));
}

/// A legend over a select of width `w`, cut from the left of `row`.
fn selectCell(ui: *Ui, row: *Rect, w: i32, label: []const u8, key: []const u8, v: *std.atomic.Value(u32), labels: []const []const u8, base: u32) bool {
    const cell = row.cutLeft(w);
    _ = row.cutLeft(PAD);
    legend(ui, cell, label);
    var sel: u8 = @intCast(@min(v.load(.monotonic) -| base, labels.len - 1));
    if (ctl.displaySelectEx(ui, selectRect(cell), key, &sel, labels, label, .{})) {
        v.store(@as(u32, sel) + base, .monotonic);
        return true;
    }
    return false;
}
