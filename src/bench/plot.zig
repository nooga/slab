//! Headless raster canvas for bench contact sheets.
//!
//! CPU-only RGBA buffer, 1px non-antialiased lines, a 6x11 pixel font, and
//! PNG export through raylib's CPU-side ExportImage (no window, no GL).
//! Same brutalist look as the UI: flat greys, three accents, no AA.

const std = @import("std");
const c = @import("../c.zig");
const font = @import("font.zig");

pub const Color = [4]u8;

pub const bg: Color = .{ 22, 22, 22, 255 };
pub const panel: Color = .{ 34, 34, 34, 255 };
pub const grid: Color = .{ 58, 58, 58, 255 };
pub const grid_hi: Color = .{ 84, 84, 84, 255 };
pub const text: Color = .{ 196, 196, 196, 255 };
pub const dim: Color = .{ 120, 120, 120, 255 };
pub const amber: Color = .{ 255, 170, 0, 255 };
pub const cyan: Color = .{ 0, 190, 214, 255 };
pub const red: Color = .{ 232, 64, 56, 255 };
pub const green: Color = .{ 90, 200, 90, 255 };

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn inset(r: Rect, d: i32) Rect {
        return .{ .x = r.x + d, .y = r.y + d, .w = r.w - 2 * d, .h = r.h - 2 * d };
    }
};

pub const Canvas = struct {
    w: i32,
    h: i32,
    px: []u8,

    pub fn init(alloc: std.mem.Allocator, w: i32, h: i32) !Canvas {
        const px = try alloc.alloc(u8, @intCast(w * h * 4));
        var cv = Canvas{ .w = w, .h = h, .px = px };
        cv.fill(.{ .x = 0, .y = 0, .w = w, .h = h }, bg);
        return cv;
    }

    pub fn deinit(self: *Canvas, alloc: std.mem.Allocator) void {
        alloc.free(self.px);
    }

    pub fn set(self: *Canvas, x: i32, y: i32, col: Color) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i: usize = @intCast((y * self.w + x) * 4);
        @memcpy(self.px[i..][0..4], &col);
    }

    pub fn fill(self: *Canvas, r: Rect, col: Color) void {
        var y = @max(r.y, 0);
        while (y < @min(r.y + r.h, self.h)) : (y += 1) {
            var x = @max(r.x, 0);
            while (x < @min(r.x + r.w, self.w)) : (x += 1) self.set(x, y, col);
        }
    }

    pub fn hline(self: *Canvas, x0: i32, x1: i32, y: i32, col: Color) void {
        var x = @min(x0, x1);
        while (x <= @max(x0, x1)) : (x += 1) self.set(x, y, col);
    }

    pub fn vline(self: *Canvas, x: i32, y0: i32, y1: i32, col: Color) void {
        var y = @min(y0, y1);
        while (y <= @max(y0, y1)) : (y += 1) self.set(x, y, col);
    }

    pub fn line(self: *Canvas, x0_: i32, y0_: i32, x1: i32, y1: i32, col: Color) void {
        var x0 = x0_;
        var y0 = y0_;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.set(x0, y0, col);
            if (x0 == x1 and y0 == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x0 += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    /// 1px raised frame, the UI bevel: light top/left, dark bottom/right.
    pub fn frame(self: *Canvas, r: Rect) void {
        self.fill(r, panel);
        self.hline(r.x, r.x + r.w - 1, r.y, grid_hi);
        self.vline(r.x, r.y, r.y + r.h - 1, grid_hi);
        self.hline(r.x, r.x + r.w - 1, r.y + r.h - 1, .{ 10, 10, 10, 255 });
        self.vline(r.x + r.w - 1, r.y, r.y + r.h - 1, .{ 10, 10, 10, 255 });
    }

    pub fn print(self: *Canvas, x: i32, y: i32, s: []const u8, col: Color) i32 {
        var cx = x;
        for (s) |ch| {
            const g = if (ch >= 32 and ch < 127) font.glyphs[ch - 32] else font.glyphs['?' - 32];
            for (g, 0..) |row, gy| {
                var gx: u3 = 0;
                while (gx < font.W) : (gx += 1) {
                    if (row & (@as(u8, 1) << @intCast(font.W - 1 - @as(u8, gx))) != 0)
                        self.set(cx + gx, y + @as(i32, @intCast(gy)), col);
                }
            }
            cx += font.W;
        }
        return cx;
    }

    pub fn printf(self: *Canvas, x: i32, y: i32, col: Color, comptime fmt: []const u8, args: anytype) i32 {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        return self.print(x, y, s, col);
    }

    pub fn savePng(self: *Canvas, alloc: std.mem.Allocator, path: []const u8) !void {
        const z = try alloc.dupeZ(u8, path);
        defer alloc.free(z);
        const img = c.rl.Image{
            .data = self.px.ptr,
            .width = self.w,
            .height = self.h,
            .mipmaps = 1,
            .format = c.rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        };
        if (!c.rl.ExportImage(img, z)) return error.PngExportFailed;
    }
};

pub const text_h: i32 = font.H;
pub const char_w: i32 = font.W;

// ── Axes ────────────────────────────────────────────────────────────────

/// Log-frequency x axis mapping, 20 Hz .. nyquist-ish.
pub const LogX = struct {
    lo: f64,
    hi: f64,
    r: Rect,

    pub fn x(self: LogX, f: f64) i32 {
        const t = @log(@max(f, self.lo) / self.lo) / @log(self.hi / self.lo);
        return self.r.x + @as(i32, @intFromFloat(@round(t * @as(f64, @floatFromInt(self.r.w - 1)))));
    }

    pub fn hz(self: LogX, px: i32) f64 {
        const t = @as(f64, @floatFromInt(px - self.r.x)) / @as(f64, @floatFromInt(@max(self.r.w - 1, 1)));
        return self.lo * @exp(@log(self.hi / self.lo) * t);
    }
};

pub fn linY(r: Rect, v: f64, lo: f64, hi: f64) i32 {
    const t = std.math.clamp((v - lo) / (hi - lo), 0.0, 1.0);
    return r.y + r.h - 1 - @as(i32, @intFromFloat(@round(t * @as(f64, @floatFromInt(r.h - 1)))));
}

/// Vertical gridlines + labels at decades/octave-ish points of a log axis.
pub fn freqGrid(cv: *Canvas, ax: LogX, label_y: i32) void {
    const marks = [_]f64{ 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000 };
    for (marks) |m| {
        if (m < ax.lo or m > ax.hi) continue;
        const x = ax.x(m);
        cv.vline(x, ax.r.y, ax.r.y + ax.r.h - 1, grid);
        if (m >= 1000)
            _ = cv.printf(x - 6, label_y, dim, "{d}k", .{@as(u32, @intFromFloat(m / 1000))})
        else
            _ = cv.printf(x - 6, label_y, dim, "{d}", .{@as(u32, @intFromFloat(m))});
    }
}

pub fn dbGrid(cv: *Canvas, r: Rect, lo: f64, hi: f64, step: f64) void {
    var v = @ceil(lo / step) * step;
    while (v <= hi) : (v += step) {
        const y = linY(r, v, lo, hi);
        cv.hline(r.x, r.x + r.w - 1, y, grid);
        _ = cv.printf(r.x + 2, y - text_h + 1, dim, "{d}", .{@as(i32, @intFromFloat(v))});
    }
}

/// Sequential colormap for spectrograms: black -> grey -> amber -> white.
pub fn heat(t_: f64) Color {
    const t = std.math.clamp(t_, 0.0, 1.0);
    const stops = [_][3]f64{
        .{ 0, 0, 0 },
        .{ 40, 40, 70 },
        .{ 120, 60, 110 },
        .{ 230, 120, 20 },
        .{ 255, 220, 120 },
        .{ 255, 255, 255 },
    };
    const f = t * @as(f64, stops.len - 1);
    const i: usize = @min(@as(usize, @intFromFloat(f)), stops.len - 2);
    const u = f - @as(f64, @floatFromInt(i));
    var out: Color = .{ 0, 0, 0, 255 };
    for (0..3) |k| out[k] = @intFromFloat(stops[i][k] + (stops[i + 1][k] - stops[i][k]) * u);
    return out;
}
