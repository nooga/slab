//! Contact-sheet panels: waveform, spectrogram, zoom, spectrum, curves.
//! Each drawer owns one rect; the runner arranges them into a sheet.

const std = @import("std");
const plot = @import("plot.zig");
const an = @import("analysis.zig");

const Canvas = plot.Canvas;
const Rect = plot.Rect;

pub const Marker = struct { t: f64, label: []const u8 = "", col: plot.Color = plot.dim };

fn title(cv: *Canvas, r: Rect, s: []const u8) void {
    _ = cv.print(r.x + 4, r.y + 3, s, plot.text);
}

fn inner(r: Rect) Rect {
    return .{ .x = r.x + 2, .y = r.y + plot.text_h + 5, .w = r.w - 4, .h = r.h - plot.text_h - 7 };
}

/// Min/max waveform over [t0, t1). `scale` 0 = auto-fit the peak.
pub fn waveform(
    cv: *Canvas,
    r: Rect,
    name: []const u8,
    l: []const f32,
    rr: ?[]const f32,
    sr: f64,
    t0: f64,
    t1: f64,
    scale_in: f64,
    markers: []const Marker,
) void {
    cv.frame(r);
    const ir = inner(r);
    const a0: usize = @intFromFloat(std.math.clamp(t0 * sr, 0, @as(f64, @floatFromInt(l.len))));
    const a1: usize = @intFromFloat(std.math.clamp(t1 * sr, 0, @as(f64, @floatFromInt(l.len))));
    if (a1 <= a0) return;
    var scale = scale_in;
    if (scale <= 0) {
        var pk: f64 = 1e-6;
        for (l[a0..a1]) |v| pk = @max(pk, @abs(v));
        if (rr) |rs| for (rs[a0..a1]) |v| {
            pk = @max(pk, @abs(v));
        };
        scale = pk * 1.05;
    }
    var buf: [96]u8 = undefined;
    const hdr = std.fmt.bufPrint(&buf, "{s}  {d:.3}-{d:.3}s  +-{d:.3}", .{ name, t0, t1, scale }) catch name;
    title(cv, r, hdr);

    const mid = ir.y + @divTrunc(ir.h, 2);
    cv.hline(ir.x, ir.x + ir.w - 1, mid, plot.grid);
    for (markers) |m| {
        if (m.t < t0 or m.t >= t1) continue;
        const x = ir.x + @as(i32, @intFromFloat((m.t - t0) / (t1 - t0) * @as(f64, @floatFromInt(ir.w))));
        cv.vline(x, ir.y, ir.y + ir.h - 1, m.col);
        if (m.label.len > 0) _ = cv.print(x + 2, ir.y + 1, m.label, plot.dim);
    }
    const span = a1 - a0;
    const Chan = struct { s: []const f32, col: plot.Color };
    var chans: [2]Chan = .{ .{ .s = l, .col = plot.amber }, .{ .s = l, .col = plot.cyan } };
    var nch: usize = 1;
    if (rr) |rs| {
        chans[1].s = rs;
        nch = 2;
    }
    for (chans[0..nch]) |ch| {
        var prev_y: ?i32 = null;
        var x: i32 = 0;
        while (x < ir.w) : (x += 1) {
            const s0 = a0 + span * @as(usize, @intCast(x)) / @as(usize, @intCast(ir.w));
            const s1 = @max(s0 + 1, a0 + span * @as(usize, @intCast(x + 1)) / @as(usize, @intCast(ir.w)));
            var lo: f64 = 1e9;
            var hi: f64 = -1e9;
            for (ch.s[s0..@min(s1, a1)]) |v| {
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
            const ylo = plot.linY(ir, lo, -scale, scale);
            const yhi = plot.linY(ir, hi, -scale, scale);
            cv.vline(ir.x + x, yhi, ylo, ch.col);
            // Connect sparse columns (zoomed views) so the trace reads as a line.
            if (prev_y) |py| cv.vline(ir.x + x, py, yhi, ch.col);
            prev_y = plot.linY(ir, ch.s[@min(s1, a1) - 1], -scale, scale);
        }
    }
}

/// Log-frequency spectrogram of the whole buffer, dB -100..0.
pub fn spectrogram(alloc: std.mem.Allocator, cv: *Canvas, r: Rect, x: []const f32, sr: f64, markers: []const Marker) !void {
    cv.frame(r);
    title(cv, r, "spectrogram  20Hz-20kHz log  -100..0 dBFS  (4096 Hann)");
    const ir = inner(r);
    const n: usize = 4096;
    const re = try alloc.alloc(f64, n);
    defer alloc.free(re);
    const im = try alloc.alloc(f64, n);
    defer alloc.free(im);
    var wsum: f64 = 0;
    for (0..n) |i| wsum += 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
    const norm = 2.0 / wsum;
    const ax = plot.LogX{ .lo = 20, .hi = @min(20000, sr / 2), .r = .{ .x = ir.y, .y = 0, .w = ir.h, .h = 1 } };
    const bin_hz = sr / @as(f64, @floatFromInt(n));

    var col: i32 = 0;
    while (col < ir.w) : (col += 1) {
        const center: i64 = @intCast(x.len * @as(usize, @intCast(col)) / @as(usize, @intCast(ir.w)));
        for (0..n) |i| {
            const idx = center - @as(i64, n / 2) + @as(i64, @intCast(i));
            const s: f64 = if (idx >= 0 and idx < x.len) x[@intCast(idx)] else 0;
            re[i] = s * (0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n))));
            im[i] = 0;
        }
        an.fft(re, im);
        var row: i32 = 0;
        while (row < ir.h) : (row += 1) {
            // row 0 = top = highest frequency
            const y_from_bottom = ir.h - 1 - row;
            const f0 = ax.hz(ir.y + y_from_bottom);
            const f1 = ax.hz(ir.y + y_from_bottom + 1);
            const b0: usize = @intFromFloat(@floor(f0 / bin_hz));
            const b1: usize = @max(b0 + 1, @as(usize, @intFromFloat(@ceil(f1 / bin_hz))));
            var m: f64 = 0;
            for (b0..@min(b1, n / 2)) |b| m = @max(m, (re[b] * re[b] + im[b] * im[b]) * norm * norm);
            const db = an.dbPow(m);
            cv.set(ir.x + col, ir.y + row, plot.heat((db + 100) / 100));
        }
    }
    // frequency ticks on the left edge
    const ticks = [_]f64{ 100, 1000, 10000 };
    for (ticks) |f| {
        const y = ir.y + ir.h - 1 - (ax.x(f) - ir.y);
        cv.hline(ir.x, ir.x + 4, y, plot.text);
        if (f >= 1000)
            _ = cv.printf(ir.x + 6, y - 5, plot.text, "{d}k", .{@as(u32, @intFromFloat(f / 1000))})
        else
            _ = cv.printf(ir.x + 6, y - 5, plot.text, "{d}", .{@as(u32, @intFromFloat(f))});
    }
    const dur = @as(f64, @floatFromInt(x.len)) / sr;
    for (markers) |m| {
        const px = ir.x + @as(i32, @intFromFloat(m.t / dur * @as(f64, @floatFromInt(ir.w))));
        cv.vline(px, ir.y + ir.h - 6, ir.y + ir.h - 1, plot.text);
    }
}

/// Averaged spectrum on a log axis; optional harmonic ticks at k*f0.
pub fn spectrumPanel(cv: *Canvas, r: Rect, name: []const u8, s: an.Spectrum, f0: ?f64, lo_db: f64, hi_db: f64) void {
    cv.frame(r);
    title(cv, r, name);
    var ir = inner(r);
    ir.h -= plot.text_h + 2;
    const ax = plot.LogX{ .lo = 20, .hi = @min(20000, s.bin_hz * @as(f64, @floatFromInt(s.pow.len - 1))), .r = ir };
    plot.freqGrid(cv, ax, ir.y + ir.h + 2);
    plot.dbGrid(cv, ir, lo_db, hi_db, 20);
    if (f0) |f| {
        var k: f64 = 1;
        while (k * f < ax.hi) : (k += 1) {
            const x = ax.x(k * f);
            cv.vline(x, ir.y, ir.y + 4, plot.cyan);
        }
    }
    var prev: ?[2]i32 = null;
    var x = ir.x;
    while (x < ir.x + ir.w) : (x += 1) {
        const db = s.dbRange(ax.hz(x), ax.hz(x + 1));
        const y = plot.linY(ir, db, lo_db, hi_db);
        if (prev) |p| cv.line(p[0], p[1], x, y, plot.amber);
        prev = .{ x, y };
    }
}

pub const Series = struct {
    ys: []const f64,
    col: plot.Color,
    lo: f64,
    hi: f64,
    label: []const u8,
};

/// Generic curve plot over x = 0..1 (knob travel, steps). Each series has
/// its own y range; labels list the ranges.
pub fn curves(cv: *Canvas, r: Rect, name: []const u8, series: []const Series, xlabel: []const u8) void {
    cv.frame(r);
    title(cv, r, name);
    var ir = inner(r);
    ir.h -= plot.text_h + 2;
    var gx: i32 = 0;
    while (gx <= 4) : (gx += 1) {
        const x = ir.x + @divTrunc(ir.w * gx, 4) - @as(i32, if (gx == 4) 1 else 0);
        cv.vline(x, ir.y, ir.y + ir.h - 1, plot.grid);
    }
    _ = cv.print(ir.x, ir.y + ir.h + 2, xlabel, plot.dim);
    var ly = ir.y + 2;
    for (series) |s| {
        if (s.ys.len == 0) continue;
        var prev: ?[2]i32 = null;
        for (s.ys, 0..) |v, i| {
            const t = if (s.ys.len > 1) @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(s.ys.len - 1)) else 0.5;
            const x = ir.x + @as(i32, @intFromFloat(t * @as(f64, @floatFromInt(ir.w - 1))));
            const y = plot.linY(ir, v, s.lo, s.hi);
            if (prev) |p| cv.line(p[0], p[1], x, y, s.col);
            cv.fill(.{ .x = x - 1, .y = y - 1, .w = 3, .h = 3 }, s.col);
            prev = .{ x, y };
        }
        _ = cv.printf(ir.x + ir.w - 170, ly, s.col, "{s} {d:.1}..{d:.1}", .{ s.label, s.lo, s.hi });
        ly += plot.text_h + 1;
    }
}

/// Plain text block (tables), clipped to the rect.
pub fn textBlock(cv: *Canvas, r: Rect, name: []const u8, text: []const u8) void {
    cv.frame(r);
    title(cv, r, name);
    const ir = inner(r);
    var y = ir.y;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| {
        if (y + plot.text_h > ir.y + ir.h) break;
        const maxc: usize = @intCast(@divTrunc(ir.w - 4, plot.char_w));
        _ = cv.print(ir.x + 2, y, ln[0..@min(ln.len, maxc)], plot.text);
        y += plot.text_h + 1;
    }
}
