//! Wavetables for wavetable oscillators (manifest `wavetable`, docs/02).
//!
//! A wavetable WAV is a run of single-cycle frames. Serum writes 2048
//! samples a frame and says so in a `clm ` chunk ("<!>2048 …"); a file
//! without one is read as 2048-sample frames, and a file shorter than
//! that is one frame.
//!
//! Each frame is band-limited ahead of time into MIPS octave levels: mip m
//! keeps harmonics 1 … 1024 >> m (mip 0 drops bin 1024, which a 2048-cell
//! cycle can't hold as a sine), so an oscillator reads the level whose top
//! harmonic still lands under its alias limit. Levels with few harmonics
//! are stored shorter, sixteen cells a harmonic, so linear interpolation's
//! images stay under −75 dB on every level:
//!
//!   mip     0     1     2     3     4    5    6    7   8   9  10
//!   cells  2048  2048  2048  2048  1024  512  256  128  64  32  16
//!
//! Each level is followed by one guard cell equal to its first, so a read
//! at index len − 1 + frac stays in bounds. A frame is STRIDE f64 cells,
//! and frames follow each other. kernels/01-oscillators/wavetable.fy
//! computes the same offsets (`wt-mip`); the test below pins them.

const std = @import("std");

pub const MIPS: usize = 11;
pub const SOURCE_FRAME: usize = 2048;
pub const MAX_FRAMES: usize = 256;

/// Cells in mip `m` (without its guard).
pub fn mipLen(m: usize) usize {
    return @min(2048, @as(usize, 16384) >> @intCast(m));
}

/// Offset of mip `m` inside a frame, in cells.
pub fn mipOffset(m: usize) usize {
    var off: usize = 0;
    for (0..m) |j| off += mipLen(j) + 1;
    return off;
}

/// The highest harmonic mip `m` holds.
pub fn mipHarmonics(m: usize) usize {
    return if (m == 0) 1023 else @as(usize, 1024) >> @intCast(m);
}

pub const STRIDE: usize = mipOffset(MIPS);

/// One frame of zeros: what an oscillator reads with no table loaded.
pub const silent_frame = [_]f64{0} ** STRIDE;

pub const Table = struct {
    data: []f64 = &.{},
    frames: usize = 0,

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
        self.* = .{};
    }
};

pub const Error = error{ Empty, OutOfMemory };

/// Build the mipmapped table from a loaded file's samples. `frame_hint`
/// is the `clm ` frame size, 0 when the file doesn't say. `normalize`
/// scales the whole table so its loudest frame peaks at 1; a table saved
/// by the editor keeps its drawn levels.
pub fn build(alloc: std.mem.Allocator, samples: []const f64, frame_hint: usize, normalize: bool) Error!Table {
    if (samples.len == 0) return Error.Empty;
    const fsize: usize = if (frame_hint > 0 and frame_hint <= samples.len)
        frame_hint
    else if (samples.len >= SOURCE_FRAME)
        SOURCE_FRAME
    else
        samples.len;
    const frames = @min(MAX_FRAMES, samples.len / fsize);
    if (frames == 0 or fsize < 4) return Error.Empty;

    const data = try alloc.alloc(f64, frames * STRIDE);
    errdefer alloc.free(data);

    const max_h = @min(mipHarmonics(0), (fsize - 1) / 2);
    const spec = try alloc.alloc(Complex, max_h + 1);
    defer alloc.free(spec);
    const work = try alloc.alloc(Complex, @max(fsize, 2048));
    defer alloc.free(work);

    for (0..frames) |f| {
        spectrum(samples[f * fsize ..][0..fsize], spec, work);
        writeLevels(data[f * STRIDE ..][0..STRIDE], spec, max_h, work);
    }

    // One gain for the whole table, from the fullest level: frames keep
    // their relative levels, the loudest peaks at 1.
    if (!normalize) return .{ .data = data, .frames = frames };
    var peak: f64 = 0;
    for (0..frames) |f| {
        for (data[f * STRIDE ..][0..mipLen(0)]) |v| peak = @max(peak, @abs(v));
    }
    if (peak > 1e-9) {
        const g = 1.0 / peak;
        for (data) |*v| v.* *= g;
    }
    return .{ .data = data, .frames = frames };
}

/// Rebuild one frame's levels in place from a 2048-sample cycle, at the
/// cycle's own level (no table gain). The wavetable editor
/// (src/wavetable_edit.zig) writes its frames through this.
pub fn writeFrame(out: []f64, src: *const [SOURCE_FRAME]f64) void {
    var spec: [SOURCE_FRAME / 2]Complex = undefined;
    var work: [SOURCE_FRAME]Complex = undefined;
    spectrum(src, &spec, &work);
    writeLevels(out[0..STRIDE], &spec, spec.len - 1, &work);
}

/// Every mip level of one frame from its spectrum, each with its guard.
fn writeLevels(out: []f64, spec: []const Complex, max_h: usize, work: []Complex) void {
    for (0..MIPS) |m| {
        const len = mipLen(m);
        const level = out[mipOffset(m)..][0 .. len + 1];
        synth(spec, @min(max_h, mipHarmonics(m)), level[0..len], work[0..len]);
        level[len] = level[0];
    }
}

pub const Complex = std.math.Complex(f64);

/// Harmonics 1 … spec.len − 1 of one cycle, scaled so a harmonic of
/// amplitude a comes back as a when synth() resynthesizes it.
fn spectrum(src: []const f64, spec: []Complex, work: []Complex) void {
    const n = src.len;
    spec[0] = Complex.init(0, 0); // no DC
    if (std.math.isPowerOfTwo(n)) {
        const w = work[0..n];
        for (w, src) |*c, v| c.* = Complex.init(v, 0);
        fft(w, false);
        for (spec[1..], 1..) |*c, h| c.* = w[h].mul(Complex.init(2.0 / @as(f64, @floatFromInt(n)), 0));
        return;
    }
    // Odd sizes (a single cycle from another tool): a direct DFT, only up
    // to the harmonics kept.
    const nf: f64 = @floatFromInt(n);
    for (spec[1..], 1..) |*c, h| {
        var re: f64 = 0;
        var im: f64 = 0;
        for (src, 0..) |v, i| {
            const a = -2.0 * std.math.pi * @as(f64, @floatFromInt((h * i) % n)) / nf;
            re += v * @cos(a);
            im += v * @sin(a);
        }
        c.* = Complex.init(re * 2.0 / nf, im * 2.0 / nf);
    }
}

/// One cycle of `len` cells (a power of two) from harmonics 1 … top.
fn synth(spec: []const Complex, top: usize, out: []f64, work: []Complex) void {
    const len = out.len;
    const keep = @min(top, len / 2 - 1);
    @memset(work, Complex.init(0, 0));
    for (1..keep + 1) |h| {
        const c = spec[h].mul(Complex.init(0.5, 0));
        work[h] = c;
        work[len - h] = c.conjugate();
    }
    fft(work, true);
    for (out, work) |*o, c| o.* = c.re;
}

/// In-place radix-2 FFT; `inverse` uses e^{+i}, unscaled.
pub fn fft(x: []Complex, inverse: bool) void {
    const n = x.len;
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) std.mem.swap(Complex, &x[i], &x[j]);
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = (if (inverse) @as(f64, 2.0) else -2.0) * std.math.pi / @as(f64, @floatFromInt(len));
        const wl = Complex.init(@cos(ang), @sin(ang));
        var i: usize = 0;
        while (i < n) : (i += len) {
            var w = Complex.init(1, 0);
            for (0..len / 2) |k| {
                const u = x[i + k];
                const v = x[i + k + len / 2].mul(w);
                x[i + k] = u.add(v);
                x[i + k + len / 2] = u.sub(v);
                w = w.mul(wl);
            }
        }
    }
}

test "wavetable: mip layout matches the kernel's closed form" {
    // wt-mip in kernels/01-oscillators/wavetable.fy:
    //   off = m < 3 ? 2049 m : 10240 − 32768·2^−m + m,  len = min(2048, 16384·2^−m)
    for (0..MIPS) |m| {
        const s = std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(m)));
        const mf: f64 = @floatFromInt(m);
        const off: f64 = if (m < 3) 2049.0 * mf else 10240.0 - 32768.0 * s + mf;
        try std.testing.expectEqual(@as(f64, @floatFromInt(mipOffset(m))), off);
        try std.testing.expectEqual(@as(f64, @floatFromInt(mipLen(m))), @min(2048.0, 16384.0 * s));
    }
    try std.testing.expectEqual(@as(usize, 10235), STRIDE);
}

test "wavetable: a saw keeps its harmonics per level and wraps" {
    const alloc = std.testing.allocator;
    var src: [2048 * 2]f64 = undefined;
    for (0..2048) |i| {
        const p = @as(f64, @floatFromInt(i)) / 2048.0;
        src[i] = @sin(2 * std.math.pi * p); // frame 0: sine
        src[2048 + i] = if (i == 0) 0 else 1.0 - 2.0 * p; // frame 1: saw, the jump at its midpoint
    }
    var t = try build(alloc, &src, 0, true);
    defer t.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), t.frames);
    // The sine survives every level unchanged but for the table gain.
    for (0..MIPS) |m| {
        const lv = t.data[mipOffset(m)..][0 .. mipLen(m) + 1];
        const q = mipLen(m) / 4;
        try std.testing.expect(@abs(lv[0]) < 1e-9);
        try std.testing.expect(lv[q] > 0.5);
        try std.testing.expectEqual(lv[0], lv[mipLen(m)]);
    }
    // The top level of the saw is its fundamental alone: a sine.
    const top = t.data[STRIDE + mipOffset(10) ..][0..16];
    try std.testing.expect(@abs(top[0]) < 1e-9);
    try std.testing.expect(@abs(top[4] + top[12]) < 1e-9);
}

test "wavetable: a short file is one frame of its own length" {
    const alloc = std.testing.allocator;
    var src: [600]f64 = undefined;
    for (&src, 0..) |*v, i| v.* = @sin(2 * std.math.pi * @as(f64, @floatFromInt(i)) / 600.0);
    var t = try build(alloc, &src, 0, true);
    defer t.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), t.frames);
    const lv = t.data[mipOffset(2)..][0..2048];
    try std.testing.expect(@abs(lv[512] - 1.0) < 1e-6);
}
