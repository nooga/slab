//! Offline signal analysis for the bench: FFT, spectra, pitch, harmonic
//! content, envelopes, and sanity stats. Everything here runs off the audio
//! path on whole rendered buffers, so it allocates freely and favors
//! clarity over speed.

const std = @import("std");

// ── FFT ─────────────────────────────────────────────────────────────────

/// In-place iterative radix-2 complex FFT. `re.len` must be a power of 2.
pub fn fft(re: []f64, im: []f64) void {
    const n = re.len;
    std.debug.assert(std.math.isPowerOfTwo(n) and im.len == n);
    var j: usize = 0;
    for (1..n) |i| {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std.mem.swap(f64, &re[i], &re[j]);
            std.mem.swap(f64, &im[i], &im[j]);
        }
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f64, @floatFromInt(len));
        const wr = @cos(ang);
        const wi = @sin(ang);
        var i: usize = 0;
        while (i < n) : (i += len) {
            var cr: f64 = 1;
            var ci: f64 = 0;
            for (0..len / 2) |k| {
                const a = i + k;
                const b = a + len / 2;
                const tr = re[b] * cr - im[b] * ci;
                const ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                const ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
}

fn hannAt(i: usize, n: usize) f64 {
    return 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
}

pub fn dbPow(p: f64) f64 {
    return 10.0 * std.math.log10(@max(p, 1e-30));
}

pub fn dbAmp(a: f64) f64 {
    return 20.0 * std.math.log10(@max(a, 1e-15));
}

// ── Spectra ─────────────────────────────────────────────────────────────

/// Power spectrum, one value per bin 0..n/2. Scaled so a full-scale sine
/// reads 0 dB at its bin (Hann window, coherent-gain corrected).
pub const Spectrum = struct {
    pow: []f64,
    bin_hz: f64,

    pub fn deinit(self: *Spectrum, alloc: std.mem.Allocator) void {
        alloc.free(self.pow);
    }

    pub fn dbAt(self: Spectrum, bin: usize) f64 {
        return dbPow(self.pow[@min(bin, self.pow.len - 1)]);
    }

    /// Max dB over the bins covering [f0, f1) — for drawing on a log axis.
    pub fn dbRange(self: Spectrum, f0: f64, f1: f64) f64 {
        const b0: usize = @intFromFloat(@max(@floor(f0 / self.bin_hz), 0));
        const b1: usize = @max(b0 + 1, @as(usize, @intFromFloat(@ceil(f1 / self.bin_hz))));
        var m: f64 = 0;
        for (b0..@min(b1, self.pow.len)) |b| m = @max(m, self.pow[b]);
        return dbPow(m);
    }
};

/// Welch-averaged Hann spectrum of `x` (50% overlap). Short inputs are
/// zero-padded into a single frame.
pub fn spectrum(alloc: std.mem.Allocator, x: []const f32, sr: f64, n: usize) !Spectrum {
    const re = try alloc.alloc(f64, n);
    defer alloc.free(re);
    const im = try alloc.alloc(f64, n);
    defer alloc.free(im);
    const pow = try alloc.alloc(f64, n / 2 + 1);
    @memset(pow, 0);

    var wsum: f64 = 0;
    for (0..n) |i| wsum += hannAt(i, n);
    const norm = 2.0 / wsum;

    var frames: usize = 0;
    var start: usize = 0;
    while (true) : (start += n / 2) {
        for (0..n) |i| {
            const s: f64 = if (start + i < x.len) x[start + i] else 0;
            re[i] = s * hannAt(i, n);
            im[i] = 0;
        }
        fft(re, im);
        for (pow, 0..) |*p, b| {
            const m = @sqrt(re[b] * re[b] + im[b] * im[b]) * norm;
            p.* += m * m;
        }
        frames += 1;
        if (start + n >= x.len) break;
    }
    for (pow) |*p| p.* /= @floatFromInt(frames);
    return .{ .pow = pow, .bin_hz = sr / @as(f64, @floatFromInt(n)) };
}

/// Unwindowed magnitude response of an impulse response (the whole buffer,
/// truncated/zero-padded to `n`). 0 dB = unity gain.
pub fn impulseResponse(alloc: std.mem.Allocator, x: []const f32, sr: f64, n: usize) !Spectrum {
    const re = try alloc.alloc(f64, n);
    defer alloc.free(re);
    const im = try alloc.alloc(f64, n);
    defer alloc.free(im);
    for (0..n) |i| {
        re[i] = if (i < x.len) x[i] else 0;
        im[i] = 0;
    }
    fft(re, im);
    const pow = try alloc.alloc(f64, n / 2 + 1);
    for (pow, 0..) |*p, b| p.* = re[b] * re[b] + im[b] * im[b];
    return .{ .pow = pow, .bin_hz = sr / @as(f64, @floatFromInt(n)) };
}

/// Power-weighted mean frequency above 20 Hz.
pub fn centroid(s: Spectrum) f64 {
    var num: f64 = 0;
    var den: f64 = 0;
    for (s.pow, 0..) |p, b| {
        const f = @as(f64, @floatFromInt(b)) * s.bin_hz;
        if (f < 20) continue;
        num += f * p;
        den += p;
    }
    return if (den > 0) num / den else 0;
}

pub const Harmonics = struct {
    /// Power of harmonics 2..N relative to the fundamental, dB.
    thd_db: f64 = -200,
    /// Power NOT near any harmonic of f0 relative to harmonic power, dB.
    /// Aliasing, noise, and inharmonic junk all land here.
    nonharm_db: f64 = -200,
};

pub fn harmonics(s: Spectrum, f0: f64) Harmonics {
    if (f0 <= 0) return .{};
    const guard: f64 = 3; // bins either side of a harmonic (Hann main lobe = 2)
    var p_fund: f64 = 0;
    var p_harm: f64 = 0;
    var p_non: f64 = 0;
    for (s.pow, 0..) |p, b| {
        const f = @as(f64, @floatFromInt(b)) * s.bin_hz;
        if (f < 20) continue;
        const k = @round(f / f0);
        const near = k >= 1 and @abs(f - k * f0) <= guard * s.bin_hz + k * f0 * 0.002;
        if (!near) {
            p_non += p;
        } else if (k == 1) {
            p_fund += p;
        } else {
            p_harm += p;
        }
    }
    return .{
        .thd_db = dbPow(p_harm / @max(p_fund, 1e-30)),
        .nonharm_db = dbPow(p_non / @max(p_fund + p_harm, 1e-30)),
    };
}

// ── Pitch ───────────────────────────────────────────────────────────────

/// Autocorrelation pitch over `x` (use ~4096 samples of steady signal).
/// Picks the shortest lag whose peak is within 10% of the best, which
/// avoids octave-down errors. Null when nothing periodic is found.
pub fn pitch(x: []const f32, sr: f64) ?f64 {
    const n = x.len;
    const lag_lo: usize = @intFromFloat(sr / 4000.0);
    const lag_hi: usize = @min(@as(usize, @intFromFloat(sr / 25.0)), n / 2);
    if (lag_hi <= lag_lo + 2) return null;
    var energy: f64 = 0;
    for (x) |v| energy += @as(f64, v) * v;
    if (energy < 1e-9) return null;

    var r_buf: [4096]f64 = undefined;
    if (lag_hi + 2 > r_buf.len) return null;
    var best: f64 = 0;
    for (lag_lo..lag_hi + 2) |lag| {
        var acc: f64 = 0;
        for (0..n - lag) |i| acc += @as(f64, x[i]) * x[i + lag];
        r_buf[lag] = acc / energy;
        if (lag <= lag_hi) best = @max(best, r_buf[lag]);
    }
    if (best < 0.3) return null;
    var lag = lag_lo + 1;
    while (lag < lag_hi) : (lag += 1) {
        const r = r_buf[lag];
        if (r >= 0.9 * best and r >= r_buf[lag - 1] and r >= r_buf[lag + 1]) {
            const a = r_buf[lag - 1];
            const b = r;
            const cc = r_buf[lag + 1];
            const den = a - 2 * b + cc;
            const off = if (@abs(den) > 1e-12) 0.5 * (a - cc) / den else 0;
            return sr / (@as(f64, @floatFromInt(lag)) + off);
        }
    }
    return null;
}

pub fn centsOff(hz: f64, ref: f64) f64 {
    return 1200.0 * std.math.log2(hz / ref);
}

pub fn midiHz(note: f64) f64 {
    return 440.0 * std.math.pow(f64, 2.0, (note - 69.0) / 12.0);
}

// ── Stats and envelopes ─────────────────────────────────────────────────

pub const Stats = struct {
    peak: f64 = 0,
    rms: f64 = 0,
    dc: f64 = 0,
    max_step: f64 = 0,
    nan: usize = 0,
    denormal: usize = 0,
    clipped: usize = 0, // |x| >= 0.999 — the per-machine clamp at work
};

pub fn stats(x: []const f32) Stats {
    var s = Stats{};
    var sum: f64 = 0;
    var sq: f64 = 0;
    var prev: f64 = 0;
    for (x, 0..) |v32, i| {
        if (std.math.isNan(v32) or std.math.isInf(v32)) {
            s.nan += 1;
            continue;
        }
        const v: f64 = v32;
        if (v32 != 0 and @abs(v32) < std.math.floatMin(f32)) s.denormal += 1;
        if (@abs(v) >= 0.999) s.clipped += 1;
        s.peak = @max(s.peak, @abs(v));
        sum += v;
        sq += v * v;
        if (i > 0) s.max_step = @max(s.max_step, @abs(v - prev));
        prev = v;
    }
    const n: f64 = @floatFromInt(@max(x.len, 1));
    s.dc = sum / n;
    s.rms = @sqrt(sq / n);
    return s;
}

pub fn rms(x: []const f32) f64 {
    var sq: f64 = 0;
    for (x) |v| sq += @as(f64, v) * v;
    return @sqrt(sq / @as(f64, @floatFromInt(@max(x.len, 1))));
}

/// RMS envelope in dBFS, one value per `hop` samples.
pub fn envelopeDb(alloc: std.mem.Allocator, x: []const f32, hop: usize) ![]f64 {
    const n = (x.len + hop - 1) / hop;
    const env = try alloc.alloc(f64, n);
    for (env, 0..) |*e, i| {
        const a = i * hop;
        e.* = dbAmp(rms(x[a..@min(a + hop, x.len)]) * std.math.sqrt2);
    }
    return env;
}

pub const Shape = struct {
    onset_s: f64 = 0, // first window within 40 dB of the peak
    peak_s: f64 = 0, // time of the loudest window
    peak_db: f64 = -200,
    /// Time from the peak to fall 60 dB. Extrapolated from the -5..-25 dB
    /// slope (x3) when the tail never gets there. 0 = no decay seen.
    t60_s: f64 = 0,
};

pub fn shape(env: []const f64, hop_s: f64) Shape {
    var sh = Shape{};
    var pi: usize = 0;
    for (env, 0..) |e, i| if (e > sh.peak_db) {
        sh.peak_db = e;
        pi = i;
    };
    if (sh.peak_db < -120) return sh;
    sh.peak_s = @as(f64, @floatFromInt(pi)) * hop_s;
    for (env, 0..) |e, i| if (e > sh.peak_db - 40) {
        sh.onset_s = @as(f64, @floatFromInt(i)) * hop_s;
        break;
    };
    var t5: ?usize = null;
    var t25: ?usize = null;
    for (env[pi..], pi..) |e, i| {
        if (t5 == null and e < sh.peak_db - 5) t5 = i;
        if (t25 == null and e < sh.peak_db - 25) t25 = i;
        if (e < sh.peak_db - 60) {
            sh.t60_s = @as(f64, @floatFromInt(i - pi)) * hop_s;
            return sh;
        }
    }
    if (t5 != null and t25 != null)
        sh.t60_s = 3.0 * @as(f64, @floatFromInt(t25.? - t5.?)) * hop_s;
    return sh;
}

/// Reverb time from Schroeder backward integration of an impulse response:
/// T30 (the -5..-35 dB span of the energy decay curve) x2. Ignores the dry
/// spike, unlike envelope peak-relative timing. 0 = not enough decay.
pub fn edcT60(x: []const f32, sr: f64) f64 {
    var total: f64 = 0;
    for (x) |v| total += @as(f64, v) * v;
    if (total <= 0) return 0;
    var rem = total;
    var t5: ?usize = null;
    for (x, 0..) |v, i| {
        const db = dbPow(rem / total);
        if (t5 == null and db < -5) t5 = i;
        if (db < -35) {
            if (t5) |a| return 2.0 * @as(f64, @floatFromInt(i - a)) / sr;
            return 0;
        }
        rem -= @as(f64, v) * v;
    }
    return 0;
}

/// SHA-256 of the raw f32 samples — bit-exact identity for goldens.
pub fn hash(l: []const f32, r: []const f32) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(std.mem.sliceAsBytes(l));
    h.update(std.mem.sliceAsBytes(r));
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

test "fft finds a sine at its bin" {
    const alloc = std.testing.allocator;
    var x: [4096]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @floatCast(@sin(2 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / 48000.0));
    var s = try spectrum(alloc, &x, 48000, 4096);
    defer s.deinit(alloc);
    // 1 kHz sits 1/3 bin off-center: Hann scalloping costs ~0.6 dB there.
    try std.testing.expect(@abs(s.dbRange(990, 1010)) < 1.5);
    const h = harmonics(s, 1000);
    try std.testing.expect(h.thd_db < -80);
    const p = pitch(x[0..2048], 48000).?;
    try std.testing.expect(@abs(centsOff(p, 1000)) < 2);
}
