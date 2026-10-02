//! Synth displays (docs/15 §Displays): a wavetable's frames in depth with
//! the played cycle and its harmonics, a filter's response, an LFO's
//! cycle, a modulation meter. Machine panels draw them from their
//! controls and the newest voice's state (src/machines/fy_raw_machine.zig);
//! the gallery's CONCOCTION page draws them from its own model. Pure
//! drawing from plain values: the caller says what is live.

const std = @import("std");
const core = @import("core.zig");
const style = @import("style.zig");
const wavetable = @import("../wavetable.zig");

const Ui = core.Ui;
const Rect = core.Rect;
const Color = style.Color;

// ── Tables and warps ─────────────────────────────────────────────────

/// Frames `first` .. `first + count` of a built wavetable
/// (src/wavetable.zig), read at mip 0.
pub const Table = struct {
    data: []const f64 = &.{},
    first: usize = 0,
    count: usize = 0,

    fn frames(t: Table) usize {
        return t.data.len / wavetable.STRIDE;
    }

    /// Frame `i` of the table at phase `p` (0..1), interpolated.
    pub fn frameSample(t: Table, i: usize, p: f32) f32 {
        const n = t.frames();
        if (t.count == 0 or n == 0) return @sin(p * std.math.tau);
        const fi = @min(t.first + @min(i, t.count - 1), n - 1);
        const d = t.data[fi * wavetable.STRIDE ..][0 .. wavetable.SOURCE_FRAME + 1];
        const x = (p - @floor(p)) * @as(f32, wavetable.SOURCE_FRAME);
        const k: usize = @min(@as(usize, @intFromFloat(x)), wavetable.SOURCE_FRAME - 1);
        const fr = x - @as(f32, @floatFromInt(k));
        return @floatCast(d[k] + (d[k + 1] - d[k]) * fr);
    }

    /// The table at position `pos` (0..1 across its frames): the two
    /// nearest frames crossfaded, as the oscillator reads it.
    pub fn at(t: Table, pos: f32, p: f32) f32 {
        const last: f32 = @floatFromInt(@max(t.count, 1) - 1);
        const x = std.math.clamp(pos, 0, 1) * last;
        const f0: usize = @intFromFloat(@floor(x));
        const fr = x - @floor(x);
        if (fr == 0) return t.frameSample(f0, p);
        return t.frameSample(f0, p) * (1 - fr) + t.frameSample(f0 + 1, p) * fr;
    }
};

pub const Warp = enum(u8) { off, sync, pwm, bend, fm };

/// The phase a warp reads the table at (kernels/06-voices/concoction.fy
/// cn-warp): SYNC reads it 1..8 times a cycle, PWM squeezes the cycle into
/// the first 1/k of the period, BEND bends the phase toward the start, FM
/// moves it by `fm`.
pub fn warpPhase(p: f32, w: Warp, amt: f32, fm: f32) f32 {
    return switch (w) {
        .off => p,
        .sync => blk: {
            const q = p * (1 + 7 * amt);
            break :blk q - @floor(q);
        },
        .pwm => blk: {
            const q = p / (1 - 0.97 * amt);
            break :blk if (q < 1) q else 0;
        },
        .bend => blk: {
            const c = 1 + 15 * amt;
            break :blk p * c / (1 + (c - 1) * p);
        },
        .fm => blk: {
            const q = p + amt * 3 * fm;
            break :blk q - @floor(q);
        },
    };
}

/// An oscillator as its display shows it.
pub const Osc = struct {
    table: Table,
    /// Caption: the table's name.
    name: []const u8 = "",
    /// Where it plays (lit) and where the knob has it (the ghost).
    pos: f32 = 0,
    base_pos: f32 = 0,
    warp: Warp = .off,
    amt: f32 = 0,
    /// Off: drawn in the mute pen, no lit frame.
    dim: bool = false,

    /// The warped table at `pos`. An FM warp is drawn against a sine at
    /// the oscillator's own pitch.
    pub fn sample(o: Osc, pos: f32, p: f32) f32 {
        const fm = if (o.warp == .fm) @sin(p * std.math.tau) else 0;
        return o.table.at(pos, warpPhase(p, o.warp, o.amt, fm));
    }
};

/// Frames drawn in depth, at most; a longer table shows this many evenly.
const DEPTH_FRAMES: usize = 24;

/// The wavetable display: the frames stacked in depth on the left, the
/// played cycle and its harmonics on the right.
pub fn wavetableView(ui: *Ui, r: Rect, o: Osc) void {
    var area = r;
    const side_w = @min(@divFloor(area.w * 2, 5), 132);
    const side = area.cutRight(side_w);
    _ = area.cutRight(2);
    waterfall(ui, area, o);
    cycleView(ui, side, o);
}

/// Every frame stacked in depth, the front frame at the bottom left and
/// the rest receding up and to the right, each hiding what lies behind
/// it; the played frame lit at its depth with its warp, the knob's
/// position as a blue ghost when modulation moves it.
pub fn waterfall(ui: *Ui, r: Rect, o: Osc) void {
    const inner = ui.well(r, style.well);
    if (inner.w < 16 or inner.h < 16) return;
    ui.clip(inner);
    defer ui.unclip();
    const fw: f32 = @floatFromInt(inner.w);
    const fh: f32 = @floatFromInt(inner.h);
    const depth_x = fw * 0.22;
    const depth_y = fh * 0.42;
    const g = Geom{
        .x0 = @as(f32, @floatFromInt(inner.x)) + 4,
        .y0 = @as(f32, @floatFromInt(inner.bottom())) - (fh - depth_y) * 0.42 - 4,
        .ww = fw - depth_x - 8,
        .amp = (fh - depth_y) * 0.42,
        .dx = depth_x,
        .dy = depth_y,
    };
    const n = @max(@min(o.table.count, DEPTH_FRAMES), 1);
    const last: f32 = @floatFromInt(@max(o.table.count, 1) - 1);
    const pen = if (o.dim) style.text_mute else style.vfd;
    const PTS = 48;

    // Back to front: each frame blanks the field under its curve, so the
    // nearer frames hide the farther ones.
    var k: usize = n;
    while (k > 0) {
        k -= 1;
        const fi: usize = if (n > 1) @intFromFloat(@round(@as(f32, @floatFromInt(k)) * last / @as(f32, @floatFromInt(n - 1)))) else 0;
        const depth = if (last > 0) @as(f32, @floatFromInt(fi)) / last else 0;
        const near = 1 - @min(1, @abs(depth - o.pos) * @as(f32, @floatFromInt(n)) / 2);
        const a: u8 = @intFromFloat(110 + 110 * near);
        const ox = g.x0 + depth * g.dx;
        const oy = g.y0 - depth * g.dy;
        const floor_y: i32 = @intFromFloat(oy + g.amp);
        var prev: [2]f32 = undefined;
        for (0..PTS + 1) |i| {
            const p = @as(f32, @floatFromInt(i)) / PTS;
            const pt = [2]f32{ ox + p * g.ww, oy - o.table.frameSample(fi, p) * g.amp };
            if (i > 0) {
                var xi: i32 = @intFromFloat(prev[0]);
                const xb: i32 = @intFromFloat(pt[0]);
                while (xi < xb) : (xi += 1) {
                    const t = (@as(f32, @floatFromInt(xi)) - prev[0]) / @max(0.001, pt[0] - prev[0]);
                    const yi: i32 = @intFromFloat(prev[1] + (pt[1] - prev[1]) * t + 1);
                    if (floor_y > yi) ui.rect(Rect.xywh(xi, yi, 1, floor_y - yi), style.well);
                }
                ui.line(prev[0], prev[1], pt[0], pt[1], pen.alpha(a));
            }
            prev = pt;
        }
    }
    if (!o.dim) {
        if (@abs(o.base_pos - o.pos) > 0.004) trace(ui, g, o, o.base_pos, false, style.mod.alpha(150));
        const oy = g.y0 - o.pos * g.dy;
        ui.line(g.x0 + o.pos * g.dx, oy, g.x0 + o.pos * g.dx + g.ww, oy, style.vfd.alpha(40));
        trace(ui, g, o, o.pos, true, style.vfd_hi);
    }
    var buf: [32]u8 = undefined;
    const frame: usize = @intFromFloat(@round(std.math.clamp(o.pos, 0, 1) * last));
    const s = std.fmt.bufPrint(&buf, "{s} {d:0>2}/{d}", .{ o.name, frame + 1, o.table.count }) catch "";
    ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x + 3, inner.y + 2, inner.w, 10), s, pen.alpha(170), .left, false);
}

const Geom = struct { x0: f32, y0: f32, ww: f32, amp: f32, dx: f32, dy: f32 };

fn trace(ui: *Ui, g: Geom, o: Osc, pos: f32, warped: bool, col: Color) void {
    const ox = g.x0 + pos * g.dx;
    const oy = g.y0 - pos * g.dy;
    const N = 128;
    var prev: [2]f32 = undefined;
    for (0..N + 1) |i| {
        const p = @as(f32, @floatFromInt(i)) / N;
        const y = if (warped) o.sample(pos, p) else o.table.at(pos, p);
        const pt = [2]f32{ ox + p * g.ww, oy - y * g.amp };
        if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], col);
        prev = pt;
    }
}

/// The played cycle large (the unwarped frame dim behind it) over its
/// first 32 harmonics, −48..0 dB of the strongest.
pub fn cycleView(ui: *Ui, r: Rect, o: Osc) void {
    const inner = ui.well(r, style.well);
    if (inner.w < 16 or inner.h < 16) return;
    ui.clip(inner);
    defer ui.unclip();
    var area = inner.insetXY(3, 3);
    const spec_r = area.cutBottom(@divFloor(area.h * 2, 5));
    _ = area.cutBottom(3);
    const pen = if (o.dim) style.text_mute else style.vfd;

    const N = 256;
    var cyc: [N]f32 = undefined;
    for (&cyc, 0..) |*y, i| y.* = o.sample(o.pos, @as(f32, @floatFromInt(i)) / N);
    const ax: f32 = @floatFromInt(area.x);
    const aw: f32 = @floatFromInt(area.w);
    const mid: f32 = @as(f32, @floatFromInt(area.y)) + @as(f32, @floatFromInt(area.h)) / 2;
    const half: f32 = @as(f32, @floatFromInt(area.h)) / 2 - 1;
    ui.rect(Rect.xywh(area.x, @intFromFloat(mid), area.w, 1), pen.alpha(24));
    if (o.warp != .off and !o.dim) {
        var prev: [2]f32 = undefined;
        for (0..65) |i| {
            const p = @as(f32, @floatFromInt(i)) / 64;
            const pt = [2]f32{ ax + p * aw, mid - o.table.at(o.pos, p) * half };
            if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], style.text_mute.alpha(120));
            prev = pt;
        }
    }
    var prev: [2]f32 = undefined;
    for (0..N + 1) |i| {
        const pt = [2]f32{ ax + @as(f32, @floatFromInt(i)) / N * aw, mid - cyc[i % N] * half };
        if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], if (o.dim) pen else style.vfd_hi);
        prev = pt;
    }

    const H = 32;
    var mag: [H]f32 = undefined;
    var peak: f32 = 1e-9;
    for (&mag, 1..) |*mg, h| {
        var re: f32 = 0;
        var im: f32 = 0;
        for (cyc, 0..) |y, i| {
            const a = std.math.tau * @as(f32, @floatFromInt((h * i) % N)) / N;
            re += y * @cos(a);
            im -= y * @sin(a);
        }
        mg.* = @sqrt(re * re + im * im);
        peak = @max(peak, mg.*);
    }
    const bw = @max(1, @divFloor(spec_r.w, H));
    for (mag, 0..) |mg, i| {
        const db = 20 * std.math.log10(@max(mg / peak, 1e-6));
        const t = std.math.clamp(1 + db / 48, 0, 1);
        const bh: i32 = @intFromFloat(@round(t * @as(f32, @floatFromInt(spec_r.h))));
        const bx = spec_r.x + @as(i32, @intCast(i)) * bw;
        ui.rect(Rect.xywh(bx, spec_r.y, bw - 1, spec_r.h), pen.alpha(14));
        if (bh > 0) ui.rect(Rect.xywh(bx, spec_r.bottom() - bh, bw - 1, bh), pen.alpha(if (i == 0) 255 else 200));
    }
}

// ── Filter ───────────────────────────────────────────────────────────

pub const FilterKind = enum { flat, lp24, lp18, lp12, bp, hp12, hp24, notch };

/// A filter mode by its option name.
pub fn filterKind(label: []const u8) FilterKind {
    const names = [_]struct { s: []const u8, k: FilterKind }{
        .{ .s = "LP24", .k = .lp24 },   .{ .s = "LP18", .k = .lp18 }, .{ .s = "LP12", .k = .lp12 },
        .{ .s = "BP", .k = .bp },       .{ .s = "HP12", .k = .hp12 }, .{ .s = "HP24", .k = .hp24 },
        .{ .s = "NOTCH", .k = .notch },
    };
    for (names) |n| if (std.mem.eql(u8, n.s, label)) return n.k;
    return .flat;
}

pub const Cx = std.math.Complex(f32);

fn biquad(s: Cx, q: f32, kind: enum { lp, hp, bp, notch }) Cx {
    const den = s.mul(s).add(s.mul(Cx.init(1 / q, 0))).add(Cx.init(1, 0));
    const num = switch (kind) {
        .lp => Cx.init(1, 0),
        .hp => s.mul(s),
        .bp => s.mul(Cx.init(1 / q, 0)),
        .notch => s.mul(s).add(Cx.init(1, 0)),
    };
    return num.div(den);
}

/// An analog prototype of the mode at `hz` with cutoff `fc` and
/// resonance `res` (0..1): close enough to the ladder's taps to read.
pub fn response(kind: FilterKind, hz: f32, fc: f32, res: f32) Cx {
    const s = Cx.init(0, hz / @max(fc, 1));
    const q = 0.6 + res * res * 9;
    return switch (kind) {
        .flat => Cx.init(1, 0),
        .lp24 => biquad(s, q, .lp).mul(biquad(s, 0.54, .lp)),
        .lp18 => biquad(s, q, .lp).mul(Cx.init(1, 0).div(s.add(Cx.init(1, 0)))),
        .lp12 => biquad(s, q, .lp),
        .bp => biquad(s, q, .bp),
        .hp12 => biquad(s, q, .hp),
        .hp24 => biquad(s, q, .hp).mul(biquad(s, 0.54, .hp)),
        .notch => biquad(s, @max(0.3, q / 3), .notch),
    };
}

/// The response, 20 Hz..20 kHz across and −36..+18 dB up: where the knobs
/// have it (blue when something moves it) and, lit, where it is now.
/// `knob` and `live` are cutoff Hz and resonance.
pub fn filterView(ui: *Ui, r: Rect, kind: FilterKind, caption: []const u8, knob: [2]f32, live: ?[2]f32) void {
    const inner = ui.well(r, style.well);
    if (inner.w < 16 or inner.h < 16) return;
    ui.clip(inner);
    defer ui.unclip();
    const fx: f32 = @floatFromInt(inner.x);
    const fw: f32 = @floatFromInt(inner.w);
    const fy: f32 = @floatFromInt(inner.y);
    const fh: f32 = @floatFromInt(inner.h);
    const Y = struct {
        fn of(db: f32, y0: f32, h: f32) f32 {
            return y0 + h * (1 - (std.math.clamp(db, -36, 18) + 36) / 54);
        }
    };
    for ([_]f32{ 100, 1000, 10000 }) |gf| {
        const gx: i32 = @intFromFloat(fx + fw * std.math.log10(gf / 20) / 3);
        ui.rect(Rect.xywh(gx, inner.y, 1, inner.h), style.vfd.alpha(20));
    }
    ui.rect(Rect.xywh(inner.x, @intFromFloat(Y.of(0, fy, fh)), inner.w, 1), style.vfd.alpha(30));
    const moved = if (live) |l| @abs(l[0] - knob[0]) > knob[0] * 0.01 or @abs(l[1] - knob[1]) > 0.01 else false;
    const curves = [_]?[2]f32{ if (moved) knob else null, live orelse knob };
    for (curves, 0..) |cv, ci| {
        const c = cv orelse continue;
        var prev: [2]f32 = undefined;
        var i: i32 = 0;
        while (i <= inner.w) : (i += 2) {
            const hz = 20 * std.math.pow(f32, 1000, @as(f32, @floatFromInt(i)) / fw);
            const db = 20 * std.math.log10(@max(response(kind, hz, c[0], c[1]).magnitude(), 1e-5));
            const pt = [2]f32{ fx + @as(f32, @floatFromInt(i)), Y.of(db, fy, fh) };
            if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], if (ci == 0) style.mod.alpha(130) else style.vfd_hi);
            prev = pt;
        }
    }
    var buf: [32]u8 = undefined;
    const hz = (live orelse knob)[0];
    const s = if (hz >= 1000)
        std.fmt.bufPrint(&buf, "{s} {d:.2}K", .{ caption, hz / 1000 }) catch ""
    else
        std.fmt.bufPrint(&buf, "{s} {d:.0}", .{ caption, hz }) catch "";
    ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x + 3, inner.y + 2, inner.w, 10), s, style.vfd.alpha(170), .left, false);
}

// ── LFO ──────────────────────────────────────────────────────────────

pub const LfoShape = enum { sine, tri, saw_up, saw_dn, square, sh };

pub fn lfoShape(label: []const u8) LfoShape {
    const names = [_]struct { s: []const u8, k: LfoShape }{
        .{ .s = "TRI", .k = .tri },       .{ .s = "SAW UP", .k = .saw_up }, .{ .s = "SAW DN", .k = .saw_dn },
        .{ .s = "SQUARE", .k = .square }, .{ .s = "S&H", .k = .sh },
    };
    for (names) |n| if (std.mem.eql(u8, n.s, label)) return n.k;
    return .sine;
}

pub fn hash01(n: u64) f32 {
    var x = n *% 0x9E3779B97F4A7C15;
    x ^= x >> 29;
    x *%= 0xBF58476D1CE4E5B9;
    x ^= x >> 32;
    return @as(f32, @floatFromInt(x & 0xffff)) / 65535.0;
}

/// The shape at phase `ph`, −1..1, as kernels/06-voices/concoction.fy
/// cn-lfo-val has it; S&H holds one value per `cycle`.
pub fn lfoValue(shape: LfoShape, ph: f32, cycle: u64) f32 {
    return switch (shape) {
        .sine => @sin(ph * std.math.tau),
        .tri => blk: {
            // cn-lfo-val's: from 0 up, like the sine
            const q = ph + 0.25;
            break :blk 1 - 4 * @abs(q - @floor(q) - 0.5);
        },
        .saw_up => 2 * ph - 1,
        .saw_dn => 1 - 2 * ph,
        .square => if (ph < 0.5) 1 else -1,
        .sh => hash01(cycle) * 2 - 1,
    };
}

/// One cycle of the shape (unipolar ones sit on the floor), and when a
/// voice plays, its phase and value riding it. `live` is phase, value.
/// S&H holds one value a cycle: the voice's, or a preview without one.
pub fn lfoView(ui: *Ui, r: Rect, shape: LfoShape, uni: bool, caption: []const u8, live: ?[2]f32) void {
    const inner = ui.well(r, style.well);
    if (inner.w < 16 or inner.h < 12) return;
    ui.clip(inner);
    defer ui.unclip();
    const v = inner.insetXY(2, 3);
    const fx: f32 = @floatFromInt(v.x);
    const fw: f32 = @floatFromInt(v.w);
    const fy: f32 = @floatFromInt(v.y);
    const fh: f32 = @floatFromInt(v.h);
    const Y = struct {
        fn of(x: f32, u: bool, y0: f32, h: f32) f32 {
            const n = if (u) x else (x + 1) / 2;
            return y0 + h * (1 - std.math.clamp(n, 0, 1));
        }
    };
    ui.rect(Rect.xywh(v.x, @intFromFloat(Y.of(0, uni, fy, fh)), v.w, 1), style.vfd.alpha(24));
    var prev: [2]f32 = undefined;
    var i: i32 = 0;
    while (i <= v.w) : (i += 1) {
        const ph = @min(@as(f32, @floatFromInt(i)) / fw, 0.9999);
        const raw = lfoValue(shape, ph, 3);
        const val = if (shape == .sh and live != null) live.?[1] else if (uni) (raw + 1) / 2 else raw;
        const pt = [2]f32{ fx + @as(f32, @floatFromInt(i)), Y.of(val, uni, fy, fh) };
        if (i > 0) ui.line(prev[0], prev[1], pt[0], pt[1], style.vfd);
        prev = pt;
    }
    if (live) |l| {
        const px = fx + fw * std.math.clamp(l[0], 0, 1);
        ui.rect(Rect.xywh(@intFromFloat(px), inner.y, 1, inner.h), style.vfd.alpha(50));
        const raw = lfoValue(shape, std.math.clamp(l[0], 0, 0.9999), 3);
        const on = if (shape == .sh) l[1] else if (uni) (raw + 1) / 2 else raw;
        ui.rect(Rect.xywh(@as(i32, @intFromFloat(px)) - 1, @as(i32, @intFromFloat(Y.of(on, uni, fy, fh))) - 1, 3, 3), style.text);
    }
    ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x + 3, inner.y + 2, inner.w, 10), caption, style.vfd.alpha(170), .left, false);
}

// ── Modulation ───────────────────────────────────────────────────────

/// A thin bar in the modulation blue: unipolar from the left, bipolar
/// from the middle.
pub fn meterBar(ui: *Ui, r: Rect, v: f32, bipolar: bool) void {
    ui.rect(r, style.mod.alpha(40));
    const w: f32 = @floatFromInt(r.w);
    if (bipolar) {
        const mid = r.x + @divFloor(r.w, 2);
        const len: i32 = @intFromFloat(@round(std.math.clamp(v, -1, 1) * w / 2));
        if (len >= 0) ui.rect(Rect.xywh(mid, r.y, len + 1, r.h), style.mod) else ui.rect(Rect.xywh(mid + len, r.y, -len + 1, r.h), style.mod);
    } else {
        ui.rect(Rect.xywh(r.x, r.y, @intFromFloat(@round(std.math.clamp(v, 0, 1) * w)), r.h), style.mod);
    }
}

/// A modulation source's chip: its name over a live meter. Returns true
/// when a drag starts on it.
pub fn modChip(ui: *Ui, r: Rect, key: anytype, name: []const u8, v: f32, bipolar: bool, lit: bool) bool {
    const b = ui.behaviorEx(ui.id(key), r, .{ .focusable = false });
    const on = lit or b.hover or b.held;
    const inner = ui.plate(r, .{ .fill = if (on) style.face_hi else style.cap, .outline = .all });
    ui.textIn(&ui.fonts.legend, inner.insetXY(3, 0).takeTop(inner.h - 3), name, if (on) style.text else style.text_dim, .left, true);
    meterBar(ui, Rect.xywh(inner.x + 2, inner.bottom() - 3, inner.w - 4, 2), v, bipolar);
    if (b.hover) ui.requestCursor(@import("../c.zig").rl.MOUSE_CURSOR_POINTING_HAND, 1);
    return b.pressed;
}

/// The chip under the pointer while a source is dragged.
pub fn dragChip(ui: *Ui, name: []const u8, v: f32, bipolar: bool) void {
    const r = Rect.xywh(ui.in.ix() + 8, ui.in.iy() + 4, 56, 16);
    ui.rect(r, style.mod);
    ui.textIn(&ui.fonts.legend, r.insetXY(3, 0), name, style.well, .left, false);
    meterBar(ui, Rect.xywh(r.x + 2, r.bottom() - 3, r.w - 4, 2), v, bipolar);
}
