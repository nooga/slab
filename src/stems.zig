//! Stems (docs/30 §Stems): a song taken apart into drums, bass, other
//! and vocals by HTDemucs, run through CoreML (ml.zig). The network's
//! core is the model; its STFT, the inverse and the segmenting around it
//! are here, made to match Demucs' (demucs/htdemucs.py `_spec`,
//! `_ispec`, `_mask`; demucs/apply.py `apply_model`) so the model sees
//! what it was trained on. A worker thread, never the audio thread.

const std = @import("std");
const fft = @import("fft.zig");
const ml = @import("ml.zig");
const storage = @import("storage.zig");
const C = fft.C;

/// The Extract pack (docs/30 §Stems) and its model in the library.
pub const PACK = "extract";

/// The separation model, if the Extract pack is installed.
pub fn modelPath(buf: []u8) ?[]const u8 {
    var lb: [storage.MAX_PATH]u8 = undefined;
    const p = std.fmt.bufPrint(buf, "{s}/{s}/models/htdemucs.mlmodelc", .{ storage.library(&lb), PACK }) catch return null;
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    if (p.len >= zb.len) return null;
    @memcpy(zb[0..p.len], p);
    zb[p.len] = 0;
    if (std.c.access(&zb, 0) != 0) return null;
    return p;
}

pub const RATE = 44_100;
/// HTDemucs' segment (7.8 s) and its frames.
pub const SEGMENT = 343_980;
pub const FRAMES = 336;
const NFFT = 4096;
const HOP = 1024;
pub const BINS = NFFT / 2;
const F = fft.Fft(NFFT);
pub const SOURCES = [_][]const u8{ "drums", "bass", "other", "vocals" };
pub const S = SOURCES.len;
/// Each frame's reach before its hop's start: `_spec` pads 1.5 hops.
const PAD = HOP / 2 * 3;
/// Segments overlap by a quarter (apply_model's default).
const STRIDE = SEGMENT * 3 / 4;

const SPEC_LEN = 4 * BINS * FRAMES;
const WAVE_LEN = 2 * SEGMENT;
pub const OUT_SPEC_LEN = S * SPEC_LEN;
pub const OUT_WAVE_LEN = S * WAVE_LEN;

/// torch.hann_window(4096): periodic.
const WINDOW: [NFFT]f32 = blk: {
    @setEvalBranchQuota(1_000_000);
    var w: [NFFT]f32 = undefined;
    for (&w, 0..) |*v, i| v.* = @floatCast(0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / NFFT));
    break :blk w;
};
/// `normalized=True`: the forward scaled by 1/√N, the inverse by √N.
const NORM: f32 = 1.0 / 64.0;

/// Sample `i` of a segment as `_spec` pads it: reflected at both ends.
fn padded(x: []const f32, i: isize) f32 {
    const n: isize = @intCast(x.len);
    var k = i;
    if (k < 0) k = -k;
    if (k >= n) k = 2 * (n - 1) - k;
    if (k < 0 or k >= n) return 0;
    return x[@intCast(k)];
}

/// `_magnitude(_spec(mix))` for one segment: per channel the real and the
/// imaginary part, `[l.re, l.im, r.re, r.im][bin][frame]`.
pub fn spec(l: []const f32, r: []const f32, out: []f32, buf: *[NFFT]C) void {
    std.debug.assert(l.len == SEGMENT and r.len == SEGMENT and out.len == SPEC_LEN);
    for (0..FRAMES) |t| {
        const s0: isize = @as(isize, @intCast(t * HOP)) - PAD;
        for (buf, 0..) |*b, n| {
            const i = s0 + @as(isize, @intCast(n));
            b.* = .{ .re = padded(l, i) * WINDOW[n], .im = padded(r, i) * WINDOW[n] };
        }
        F.forward(buf);
        for (0..BINS) |k| {
            const a = buf[k];
            const b = buf[(NFFT - k) % NFFT].conj();
            const zl = a.add(b).scale(0.5 * NORM);
            const d = a.sub(b);
            const zr = (C{ .re = d.im, .im = -d.re }).scale(0.5 * NORM);
            out[(0 * BINS + k) * FRAMES + t] = zl.re;
            out[(1 * BINS + k) * FRAMES + t] = zl.im;
            out[(2 * BINS + k) * FRAMES + t] = zr.re;
            out[(3 * BINS + k) * FRAMES + t] = zr.im;
        }
    }
}

/// The overlap of the windows squared, as torch.istft divides by: the
/// frames `_ispec` lays down (with its two empty ones each side), at
/// segment sample `j`.
fn envelope(j: usize) f32 {
    var e: f32 = 0;
    // Frame t (of FRAMES + 4, from −2) covers j ∈ [t·HOP − PAD, +NFFT).
    var t: isize = -2;
    while (t < FRAMES + 2) : (t += 1) {
        const n = @as(isize, @intCast(j)) + PAD - t * HOP;
        if (n >= 0 and n < NFFT) e += WINDOW[@intCast(n)] * WINDOW[@intCast(n)];
    }
    return e;
}

/// `_ispec` of one source's spectrogram (`spec`'s layout) added into
/// `l`/`r` (SEGMENT each).
pub fn ispec(z: []const f32, l: []f32, r: []f32, buf: *[NFFT]C) void {
    for (0..FRAMES) |t| {
        // Both channels at once: L + iR, each Hermitian.
        for (0..BINS) |k| {
            const zl = C{ .re = z[(0 * BINS + k) * FRAMES + t], .im = z[(1 * BINS + k) * FRAMES + t] };
            const zr = C{ .re = z[(2 * BINS + k) * FRAMES + t], .im = z[(3 * BINS + k) * FRAMES + t] };
            buf[k] = .{ .re = zl.re - zr.im, .im = zl.im + zr.re };
            if (k > 0) buf[NFFT - k] = .{ .re = zl.re + zr.im, .im = -zl.im + zr.re };
        }
        buf[BINS] = .{ .re = 0, .im = 0 };
        F.inverse(buf);
        const s0: isize = @as(isize, @intCast(t * HOP)) - PAD;
        for (0..NFFT) |n| {
            const j = s0 + @as(isize, @intCast(n));
            if (j < 0 or j >= SEGMENT) continue;
            const w = WINDOW[n] / NORM;
            l[@intCast(j)] += buf[n].re * w;
            r[@intCast(j)] += buf[n].im * w;
        }
    }
}

/// The envelope over a segment, once.
fn envelopes(alloc: std.mem.Allocator) ![]f32 {
    const env = try alloc.alloc(f32, SEGMENT);
    for (env, 0..) |*e, j| e.* = envelope(j);
    return env;
}

/// Divide what `ispec` laid down by the window overlap.
fn normalizeOla(l: []f32, r: []f32, env: []const f32) void {
    for (l, r, env) |*a, *b, e| {
        if (e > 1e-8) {
            a.* /= e;
            b.* /= e;
        }
    }
}

pub const Progress = struct {
    done: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
};

/// The four stems of `l`/`r` (44.1 kHz, the same length): `out[s][c]`
/// each as long as the input, allocated here.
pub fn separate(alloc: std.mem.Allocator, model: *ml.Model, l: []const f32, r: []const f32, progress: *Progress) ![S][2][]f32 {
    const len = l.len;
    var out: [S][2][]f32 = undefined;
    var made: usize = 0;
    errdefer for (out[0..made]) |o| {
        alloc.free(o[0]);
        alloc.free(o[1]);
    };
    for (&out) |*o| {
        o[0] = try alloc.alloc(f32, len);
        @memset(o[0], 0);
        o[1] = try alloc.alloc(f32, len);
        @memset(o[1], 0);
        made += 1;
    }
    const sum_w = try alloc.alloc(f32, len);
    defer alloc.free(sum_w);
    @memset(sum_w, 0);

    // The whole mix normalized by its mono mean and deviation, as
    // demucs' separate does.
    var mean: f64 = 0;
    for (l, r) |a, b| mean += (a + b) * 0.5;
    mean /= @floatFromInt(@max(1, len));
    var v: f64 = 0;
    for (l, r) |a, b| {
        const d = (a + b) * 0.5 - mean;
        v += d * d;
    }
    const sd: f32 = @floatCast(@max(1e-8, @sqrt(v / @as(f64, @floatFromInt(@max(1, len -| 1))))));
    const mf: f32 = @floatCast(mean);

    const seg_l = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(seg_l);
    const seg_r = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(seg_r);
    const mag = try alloc.alloc(f32, SPEC_LEN);
    defer alloc.free(mag);
    const mix = try alloc.alloc(f32, WAVE_LEN);
    defer alloc.free(mix);
    const o_spec = try alloc.alloc(f32, OUT_SPEC_LEN);
    defer alloc.free(o_spec);
    const o_wave = try alloc.alloc(f32, OUT_WAVE_LEN);
    defer alloc.free(o_wave);
    const st_l = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(st_l);
    const st_r = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(st_r);
    const buf = try alloc.create([NFFT]C);
    defer alloc.destroy(buf);
    const env = try envelopes(alloc);
    defer alloc.free(env);
    const sl = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(sl);
    const sr = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(sr);

    const segments = if (len == 0) 0 else (len - 1) / STRIDE + 1;
    progress.total.store(@intCast(segments), .release);
    var offset: usize = 0;
    while (offset < len) : (offset += STRIDE) {
        if (progress.cancel.load(.acquire)) return error.Canceled;
        // A short last chunk sits centered in a full segment of what's
        // around it (TensorChunk.padded), and its middle is kept.
        const chunk = @min(SEGMENT, len - offset);
        const delta = SEGMENT - chunk;
        const start: isize = @as(isize, @intCast(offset)) - @as(isize, @intCast(delta / 2));
        for (0..SEGMENT) |i| {
            const k = start + @as(isize, @intCast(i));
            const inside = k >= 0 and k < @as(isize, @intCast(len));
            seg_l[i] = if (inside) (l[@intCast(k)] - mf) / sd else 0;
            seg_r[i] = if (inside) (r[@intCast(k)] - mf) / sd else 0;
        }
        spec(seg_l, seg_r, mag, buf);
        @memcpy(mix[0..SEGMENT], seg_l);
        @memcpy(mix[SEGMENT..], seg_r);
        try model.predict(&.{
            .{ .name = "mag", .data = mag, .shape = &.{ 1, 4, BINS, FRAMES } },
            .{ .name = "mix", .data = mix, .shape = &.{ 1, 2, SEGMENT } },
        }, &.{
            .{ .name = "spec", .data = o_spec },
            .{ .name = "wave", .data = o_wave },
        });
        for (0..S) |s| {
            @memcpy(st_l, o_wave[(s * 2 + 0) * SEGMENT ..][0..SEGMENT]);
            @memcpy(st_r, o_wave[(s * 2 + 1) * SEGMENT ..][0..SEGMENT]);
            // The waveform branch is already in; the spectral one is
            // laid over it and the overlap divided out of it alone.
            @memset(sl, 0);
            @memset(sr, 0);
            ispec(o_spec[s * SPEC_LEN ..][0..SPEC_LEN], sl, sr, buf);
            normalizeOla(sl, sr, env);
            const keep = delta / 2;
            for (0..chunk) |i| {
                const w = weight(i);
                out[s][0][offset + i] += w * (st_l[keep + i] + sl[keep + i]);
                out[s][1][offset + i] += w * (st_r[keep + i] + sr[keep + i]);
            }
        }
        for (0..chunk) |i| sum_w[offset + i] += weight(i);
        _ = progress.done.fetchAdd(1, .acq_rel);
    }
    for (&out) |*o| for (o, 0..) |ch, c| {
        _ = c;
        for (ch, sum_w) |*x, w| x.* = (if (w > 0) x.* / w else 0) * sd + mf;
    };
    return out;
}

/// apply_model's transition: up to the middle of a segment and down.
fn weight(i: usize) f32 {
    const half = SEGMENT / 2;
    const w = if (i < half) i + 1 else SEGMENT - i;
    return @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(half));
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "stems: the STFT is torch's, scale and all" {
    const alloc = testing.allocator;
    const l = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(l);
    const r = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(r);
    @memset(l, 1);
    @memset(r, 0);
    const out = try alloc.alloc(f32, SPEC_LEN);
    defer alloc.free(out);
    const buf = try alloc.create([NFFT]C);
    defer alloc.destroy(buf);
    spec(l, r, out, buf);
    // A constant 1: bin 0 is the window's sum (N/2) over √N = 32, the
    // rest nothing; the right channel nothing.
    for (0..FRAMES) |t| {
        try testing.expectApproxEqAbs(@as(f32, 32), out[(0 * BINS + 0) * FRAMES + t], 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 0), out[(0 * BINS + 3) * FRAMES + t], 1e-3);
        try testing.expectApproxEqAbs(@as(f32, 0), out[(2 * BINS + 0) * FRAMES + t], 1e-3);
    }
}

test "stems: the inverse gives the segment back" {
    const alloc = testing.allocator;
    const l = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(l);
    const r = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(r);
    // Band-limited (noise would lose the Nyquist bin `_spec` drops).
    for (l, r, 0..) |*a, *b, i| {
        const x: f32 = @floatFromInt(i);
        a.* = @sin(x * 0.01) * 0.5 + 0.1 * @sin(x * 0.7 + 1);
        b.* = 0.3 * @sin(x * 0.123) - 0.2 * @cos(x * 2.1);
    }
    const z = try alloc.alloc(f32, SPEC_LEN);
    defer alloc.free(z);
    const buf = try alloc.create([NFFT]C);
    defer alloc.destroy(buf);
    spec(l, r, z, buf);
    const bl = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(bl);
    const br = try alloc.alloc(f32, SEGMENT);
    defer alloc.free(br);
    @memset(bl, 0);
    @memset(br, 0);
    ispec(z, bl, br, buf);
    const env = try envelopes(alloc);
    defer alloc.free(env);
    normalizeOla(bl, br, env);
    // Inside, exact; at the ends as Demucs' own round trip (PyTorch
    // gives 0.042076, 0.295079, 0.119719 there): `_ispec` lays empty
    // frames where `_spec` cut its edge ones off.
    for (4096..SEGMENT - 4096) |i| {
        try testing.expectApproxEqAbs(l[i], bl[i], 1e-4);
        try testing.expectApproxEqAbs(r[i], br[i], 1e-4);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.042076), bl[0], 2e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.295079), bl[100], 2e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.119719), bl[SEGMENT - 1], 2e-4);
}

test "stems: the transition weights sum flat across an overlap" {
    // Where two segments overlap their weights add to the sum the
    // output is divided by: positive everywhere a segment reaches.
    var i: usize = 0;
    while (i < STRIDE + SEGMENT) : (i += 997) {
        var s: f32 = 0;
        if (i < SEGMENT) s += weight(i);
        if (i >= STRIDE and i - STRIDE < SEGMENT) s += weight(i - STRIDE);
        try testing.expect(s > 0);
    }
}
