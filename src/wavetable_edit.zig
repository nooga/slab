//! The wavetable editor's document (docs/15 §Wavetable editor): a table
//! held as plain 2048-sample cycles, the source the oscillator's mip
//! levels are built from (src/wavetable.zig). The editor draws on a
//! frame, paints its harmonics, fills it with a shape, processes it, adds
//! and removes frames, and morphs between keyframes. Every edit marks
//! the frames it touched; the owner takes that range and rebuilds just
//! those frames (wavetable.writeFrame), or the whole table when the
//! frame count changed.
//!
//! Pure data, UI thread only. Undo keeps whole snapshots, one per
//! gesture (`checkpoint` before it starts).

const std = @import("std");
const wavetable = @import("wavetable.zig");

pub const N: usize = wavetable.SOURCE_FRAME;
pub const MAX_FRAMES: usize = wavetable.MAX_FRAMES;
const UNDO: usize = 32;

const Complex = wavetable.Complex;
/// A bin under this (a harmonic under −80 dB) is silent: its phase is
/// the f32 frame's rounding noise.
const SILENT: f64 = 1e-4 * @as(f64, N) / 2;
const Keys = std.StaticBitSet(MAX_FRAMES);

pub const Shape = enum { sine, triangle, saw, square, noise };
pub const Op = enum { normalize, dc, invert, reverse, smooth };
pub const Morph = enum { crossfade, spectral };

/// What changed since the last `takeDirty`: frames lo..hi (inclusive),
/// or the frame count, which means the whole table.
pub const Dirty = struct { lo: usize, hi: usize, resized: bool };

const Snap = struct { data: []f32, count: usize, keys: Keys, sel: usize };

pub const Doc = struct {
    alloc: std.mem.Allocator,
    /// MAX_FRAMES cycles of N samples; the first `count` are the table.
    data: []f32,
    count: usize = 1,
    /// Keyframes: the frames a morph keeps and fills between. The first
    /// and the last frame are always keys.
    keys: Keys = Keys.initEmpty(),
    /// The frame being edited.
    sel: usize = 0,
    undo_s: [UNDO]Snap = undefined,
    undo_n: usize = 0,
    redo_s: [UNDO]Snap = undefined,
    redo_n: usize = 0,
    dirty_lo: usize = NONE,
    dirty_hi: usize = 0,
    resized: bool = false,
    /// Bumped by every change, so views can cache what they derive.
    version: u64 = 0,

    const NONE = std.math.maxInt(usize);

    pub fn init(alloc: std.mem.Allocator) !Doc {
        const data = try alloc.alloc(f32, MAX_FRAMES * N);
        @memset(data, 0);
        var d = Doc{ .alloc = alloc, .data = data };
        d.setShape(0, .sine);
        d.dirty_lo = NONE;
        return d;
    }

    pub fn deinit(d: *Doc) void {
        d.clearHistory();
        d.alloc.free(d.data);
    }

    pub fn frame(d: *Doc, i: usize) []f32 {
        return d.data[i * N ..][0..N];
    }

    pub fn frameConst(d: *const Doc, i: usize) []const f32 {
        return d.data[i * N ..][0..N];
    }

    pub fn isKey(d: *const Doc, i: usize) bool {
        return i == 0 or i + 1 == d.count or d.keys.isSet(i);
    }

    // ── Loading ──────────────────────────────────────────────────────

    /// A wavetable file's samples (wav.load): frames of `frame_hint`
    /// samples (the `clm ` size, 0 when unknown), as wavetable.build
    /// reads them; a frame of another size is resampled to N.
    pub fn load(d: *Doc, src_samples: []const f64, frame_hint: usize) void {
        if (src_samples.len == 0) return;
        const fsize: usize = if (frame_hint > 0 and frame_hint <= src_samples.len)
            frame_hint
        else if (src_samples.len >= N)
            N
        else
            src_samples.len;
        const frames = @max(1, @min(MAX_FRAMES, src_samples.len / fsize));
        for (0..frames) |f| {
            const src = src_samples[f * fsize ..][0..fsize];
            const out = d.frame(f);
            const step = @as(f64, @floatFromInt(fsize)) / @as(f64, @floatFromInt(N));
            for (out, 0..) |*o, k| {
                const x = @as(f64, @floatFromInt(k)) * step;
                const k0: usize = @intFromFloat(@floor(x));
                const fr = x - @floor(x);
                const a = src[k0 % fsize];
                const b = src[(k0 + 1) % fsize];
                o.* = @floatCast(a + (b - a) * fr);
            }
        }
        d.reset(frames);
    }

    /// Frames `first` .. `first + count` of a built table, read back from
    /// their fullest level (what a bank table holds before it is copied
    /// into a USER table).
    pub fn loadBuilt(d: *Doc, table: []const f64, first: usize, count: usize) void {
        const n = @min(count, MAX_FRAMES);
        for (0..n) |f| {
            const src = table[(first + f) * wavetable.STRIDE ..][0..N];
            for (d.frame(f), src) |*o, v| o.* = @floatCast(v);
        }
        d.reset(@max(n, 1));
    }

    fn reset(d: *Doc, count: usize) void {
        d.count = count;
        d.keys = Keys.initEmpty();
        d.sel = 0;
        d.clearHistory();
        d.markResized();
    }

    // ── Output ───────────────────────────────────────────────────────

    /// What changed since the last call, if anything.
    pub fn takeDirty(d: *Doc) ?Dirty {
        if (d.dirty_lo == NONE and !d.resized) return null;
        const out = Dirty{ .lo = if (d.dirty_lo == NONE) 0 else d.dirty_lo, .hi = @min(d.dirty_hi, d.count - 1), .resized = d.resized };
        d.dirty_lo = NONE;
        d.dirty_hi = 0;
        d.resized = false;
        return out;
    }

    /// Build frames lo..hi into `out`, one after the other from its start
    /// (wavetable.STRIDE cells each): a built table's slice from frame
    /// lo, or a scratch buffer to copy in later.
    pub fn writeFrames(d: *const Doc, out: []f64, lo: usize, hi: usize) void {
        var buf: [N]f64 = undefined;
        var f = lo;
        while (f <= hi and f < d.count) : (f += 1) {
            for (&buf, d.frameConst(f)) |*o, v| o.* = v;
            wavetable.writeFrame(out[(f - lo) * wavetable.STRIDE ..][0..wavetable.STRIDE], &buf);
        }
    }

    /// A whole new built table of `count` frames.
    pub fn build(d: *const Doc, alloc: std.mem.Allocator) !wavetable.Table {
        const data = try alloc.alloc(f64, d.count * wavetable.STRIDE);
        d.writeFrames(data, 0, d.count - 1);
        return .{ .data = data, .frames = d.count };
    }

    /// The table as a file's samples: `count` frames of N, in order.
    pub fn samples(d: *const Doc, out: []f64) void {
        for (out[0 .. d.count * N], d.data[0 .. d.count * N]) |*o, v| o.* = v;
    }

    fn mark(d: *Doc, lo: usize, hi: usize) void {
        d.dirty_lo = @min(d.dirty_lo, lo);
        d.dirty_hi = @max(d.dirty_hi, hi);
        d.version +%= 1;
    }

    fn markResized(d: *Doc) void {
        d.resized = true;
        d.dirty_lo = NONE;
        d.version +%= 1;
    }

    // ── Undo ─────────────────────────────────────────────────────────

    /// Remember the table before a gesture changes it.
    pub fn checkpoint(d: *Doc) void {
        const s = d.snap() orelse return;
        push(d.alloc, &d.undo_s, &d.undo_n, s);
        while (d.redo_n > 0) {
            d.redo_n -= 1;
            d.alloc.free(d.redo_s[d.redo_n].data);
        }
    }

    pub fn canUndo(d: *const Doc) bool {
        return d.undo_n > 0;
    }

    pub fn canRedo(d: *const Doc) bool {
        return d.redo_n > 0;
    }

    pub fn undo(d: *Doc) void {
        swapHistory(d, &d.undo_s, &d.undo_n, &d.redo_s, &d.redo_n);
    }

    pub fn redo(d: *Doc) void {
        swapHistory(d, &d.redo_s, &d.redo_n, &d.undo_s, &d.undo_n);
    }

    fn swapHistory(d: *Doc, from: *[UNDO]Snap, from_n: *usize, to: *[UNDO]Snap, to_n: *usize) void {
        if (from_n.* == 0) return;
        const now = d.snap() orelse return;
        from_n.* -= 1;
        const s = from[from_n.*];
        push(d.alloc, to, to_n, now);
        @memcpy(d.data[0..s.data.len], s.data);
        const was = d.count;
        d.count = s.count;
        d.keys = s.keys;
        d.sel = @min(s.sel, s.count - 1);
        d.alloc.free(s.data);
        if (was != d.count) d.markResized() else d.mark(0, d.count - 1);
    }

    fn snap(d: *const Doc) ?Snap {
        const data = d.alloc.dupe(f32, d.data[0 .. d.count * N]) catch return null;
        return .{ .data = data, .count = d.count, .keys = d.keys, .sel = d.sel };
    }

    fn push(alloc: std.mem.Allocator, stack: *[UNDO]Snap, n: *usize, s: Snap) void {
        if (n.* == UNDO) {
            alloc.free(stack[0].data);
            std.mem.copyForwards(Snap, stack[0 .. UNDO - 1], stack[1..UNDO]);
            n.* -= 1;
        }
        stack[n.*] = s;
        n.* += 1;
    }

    fn clearHistory(d: *Doc) void {
        for (d.undo_s[0..d.undo_n]) |s| d.alloc.free(s.data);
        for (d.redo_s[0..d.redo_n]) |s| d.alloc.free(s.data);
        d.undo_n = 0;
        d.redo_n = 0;
    }

    // ── Drawing ──────────────────────────────────────────────────────

    fn cell(x: f32) usize {
        const k: i64 = @intFromFloat(@round(x * @as(f32, N)));
        return @intCast(std.math.clamp(k, 0, N - 1));
    }

    /// A straight line from (x0, y0) to (x1, y1): x is the phase 0..1,
    /// y the level, clamped to ±1.
    pub fn drawLine(d: *Doc, i: usize, x0: f32, y0: f32, x1: f32, y1: f32) void {
        var a = [2]f32{ x0, y0 };
        var b = [2]f32{ x1, y1 };
        if (a[0] > b[0]) std.mem.swap([2]f32, &a, &b);
        const k0 = cell(a[0]);
        const k1 = cell(b[0]);
        const f = d.frame(i);
        for (k0..k1 + 1) |k| {
            const t: f32 = if (k1 > k0) @as(f32, @floatFromInt(k - k0)) / @as(f32, @floatFromInt(k1 - k0)) else 1;
            f[k] = std.math.clamp(a[1] + (b[1] - a[1]) * t, -1, 1);
        }
        d.mark(i, i);
    }

    /// One level from x0 to x1 (a grid step).
    pub fn fillStep(d: *Doc, i: usize, x0: f32, x1: f32, y: f32) void {
        const k0 = cell(@min(x0, x1));
        const k1 = cell(@max(x0, x1));
        @memset(d.frame(i)[k0 .. k1 + 1], std.math.clamp(y, -1, 1));
        d.mark(i, i);
    }

    pub fn setShape(d: *Doc, i: usize, shape: Shape) void {
        var rng = std.Random.DefaultPrng.init(@as(u64, i) *% 0x9E37_79B9_7F4A_7C15 +% d.version);
        for (d.frame(i), 0..) |*o, k| {
            const p = @as(f32, @floatFromInt(k)) / @as(f32, N);
            o.* = switch (shape) {
                .sine => @sin(p * std.math.tau),
                .triangle => if (p < 0.25) 4 * p else if (p < 0.75) 2 - 4 * p else 4 * p - 4,
                .saw => if (k == 0) 0 else 1 - 2 * p,
                .square => if (k == 0 or k == N / 2) 0 else if (p < 0.5) 1 else -1,
                .noise => rng.random().float(f32) * 2 - 1,
            };
        }
        d.mark(i, i);
    }

    pub fn apply(d: *Doc, i: usize, op: Op) void {
        const f = d.frame(i);
        switch (op) {
            .normalize => {
                var peak: f32 = 0;
                for (f) |v| peak = @max(peak, @abs(v));
                if (peak > 1e-6) for (f) |*v| {
                    v.* /= peak;
                };
            },
            .dc => {
                var sum: f32 = 0;
                for (f) |v| sum += v;
                const m = sum / @as(f32, N);
                for (f) |*v| v.* = std.math.clamp(v.* - m, -1, 1);
            },
            .invert => for (f) |*v| {
                v.* = -v.*;
            },
            .reverse => std.mem.reverse(f32, f[1..]),
            .smooth => {
                // Five taps around the cycle, twice: a gentle low-pass that
                // rounds corners and keeps the shape.
                var tmp: [N]f32 = undefined;
                for (0..2) |_| {
                    for (&tmp, 0..) |*o, k| {
                        var s: f32 = 0;
                        for (0..5) |j| s += f[(k + N + j - 2) % N];
                        o.* = s / 5;
                    }
                    @memcpy(f, &tmp);
                }
            },
        }
        d.mark(i, i);
    }

    pub fn applyAll(d: *Doc, op: Op) void {
        for (0..d.count) |i| d.apply(i, op);
    }

    // ── Harmonics ────────────────────────────────────────────────────

    fn spectrum(d: *const Doc, i: usize, x: *[N]Complex) void {
        for (x, d.frameConst(i)) |*c, v| c.* = Complex.init(v, 0);
        wavetable.fft(x, false);
    }

    fn resynth(d: *Doc, i: usize, x: *[N]Complex) void {
        wavetable.fft(x, true);
        for (d.frame(i), x) |*o, c| o.* = @floatCast(c.re / @as(f64, N));
        d.mark(i, i);
    }

    /// Harmonics 1 … mag.len of frame i: amplitude (a sine of level a
    /// reads a) and phase (radians, cosine phase).
    pub fn harmonics(d: *const Doc, i: usize, mag: []f32, ph: []f32) void {
        var x: [N]Complex = undefined;
        d.spectrum(i, &x);
        for (mag, ph, 1..) |*m, *p, h| {
            m.* = @floatCast(x[h].magnitude() * 2 / @as(f64, N));
            p.* = @floatCast(std.math.atan2(x[h].im, x[h].re));
        }
    }

    /// Set harmonic h of frame i to amplitude `amp`, keeping its phase; a
    /// harmonic that was silent comes in as a sine.
    pub fn setHarmonic(d: *Doc, i: usize, h: usize, amp: f32) void {
        if (h == 0 or h >= N / 2) return;
        var x: [N]Complex = undefined;
        d.spectrum(i, &x);
        const old = x[h].magnitude();
        const ph: f64 = if (old > SILENT) std.math.atan2(x[h].im, x[h].re) else -std.math.pi / 2.0;
        const r = @as(f64, @max(amp, 0)) * @as(f64, N) / 2;
        x[h] = Complex.init(r * @cos(ph), r * @sin(ph));
        x[N - h] = x[h].conjugate();
        d.resynth(i, &x);
    }

    // ── Frames ───────────────────────────────────────────────────────

    /// A copy of frame i after it, selected.
    pub fn duplicate(d: *Doc, i: usize) void {
        if (d.count == MAX_FRAMES) return;
        const tail = (d.count - i - 1) * N;
        std.mem.copyBackwards(f32, d.data[(i + 2) * N ..][0..tail], d.data[(i + 1) * N ..][0..tail]);
        @memcpy(d.frame(i + 1), d.frameConst(i));
        var keys = Keys.initEmpty();
        for (0..d.count) |k| if (d.keys.isSet(k)) keys.set(if (k > i) k + 1 else k);
        d.keys = keys;
        d.count += 1;
        d.sel = i + 1;
        d.markResized();
    }

    pub fn remove(d: *Doc, i: usize) void {
        if (d.count == 1) return;
        const tail = (d.count - i - 1) * N;
        std.mem.copyForwards(f32, d.data[i * N ..][0..tail], d.data[(i + 1) * N ..][0..tail]);
        var keys = Keys.initEmpty();
        for (0..d.count) |k| {
            if (k != i and d.keys.isSet(k)) keys.set(if (k > i) k - 1 else k);
        }
        d.keys = keys;
        d.count -= 1;
        d.sel = @min(d.sel, d.count - 1);
        d.markResized();
    }

    /// `n` frames: more repeat the last, fewer drop from the end.
    pub fn resize(d: *Doc, n: usize) void {
        const to = std.math.clamp(n, 1, MAX_FRAMES);
        if (to == d.count) return;
        var f = d.count;
        while (f < to) : (f += 1) @memcpy(d.frame(f), d.frameConst(d.count - 1));
        var k = to;
        while (k < MAX_FRAMES) : (k += 1) d.keys.unset(k);
        d.count = to;
        d.sel = @min(d.sel, to - 1);
        d.markResized();
    }

    pub fn toggleKey(d: *Doc, i: usize) void {
        if (i == 0 or i + 1 == d.count) return;
        d.keys.toggle(i);
        d.version +%= 1;
    }

    /// Refill every frame between two keyframes from them: a crossfade of
    /// the waves, or a spectral morph (each harmonic's amplitude and phase
    /// moved separately, so a harmonic grows and shrinks without the
    /// cancellation a crossfade has).
    pub fn morph(d: *Doc, mode: Morph) void {
        if (d.count < 3) return;
        var a: usize = 0;
        var b: usize = 1;
        while (b < d.count) : (b += 1) {
            if (!d.isKey(b)) continue;
            if (b - a > 1) d.morphSpan(a, b, mode);
            a = b;
        }
    }

    fn morphSpan(d: *Doc, a: usize, b: usize, mode: Morph) void {
        const span: f32 = @floatFromInt(b - a);
        switch (mode) {
            .crossfade => for (a + 1..b) |f| {
                const t = @as(f32, @floatFromInt(f - a)) / span;
                for (d.frame(f), d.frameConst(a), d.frameConst(b)) |*o, x, y| o.* = x + (y - x) * t;
            },
            .spectral => {
                const xa = d.alloc.create([N]Complex) catch return;
                defer d.alloc.destroy(xa);
                const xb = d.alloc.create([N]Complex) catch return;
                defer d.alloc.destroy(xb);
                const x = d.alloc.create([N]Complex) catch return;
                defer d.alloc.destroy(x);
                d.spectrum(a, xa);
                d.spectrum(b, xb);
                for (a + 1..b) |f| {
                    const t: f64 = @as(f64, @floatFromInt(f - a)) / span;
                    x[0] = Complex.init(xa[0].re + (xb[0].re - xa[0].re) * t, 0);
                    x[N / 2] = Complex.init(0, 0);
                    for (1..N / 2) |h| {
                        const ma = xa[h].magnitude();
                        const mb = xb[h].magnitude();
                        const pa = std.math.atan2(xa[h].im, xa[h].re);
                        // A silent end takes the other's phase: the harmonic
                        // fades in place instead of spinning.
                        const pb = if (mb > SILENT) std.math.atan2(xb[h].im, xb[h].re) else pa;
                        const p0 = if (ma > SILENT) pa else pb;
                        var dp = pb - p0;
                        dp -= std.math.tau * @round(dp / std.math.tau);
                        const m = ma + (mb - ma) * t;
                        const p = p0 + dp * t;
                        x[h] = Complex.init(m * @cos(p), m * @sin(p));
                        x[N - h] = x[h].conjugate();
                    }
                    d.resynth(f, x);
                }
            },
        }
        d.mark(a + 1, b - 1);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "wavetable edit: a line, a step, undo and redo" {
    var d = try Doc.init(testing.allocator);
    defer d.deinit();
    _ = d.takeDirty();
    d.checkpoint();
    d.drawLine(0, 0, -1, 0.5, 1);
    const f = d.frameConst(0);
    try testing.expectApproxEqAbs(@as(f32, -1), f[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), f[N / 4], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1), f[N / 2], 1e-6);
    const dirty = d.takeDirty().?;
    try testing.expectEqual(@as(usize, 0), dirty.lo);
    try testing.expect(!dirty.resized);
    d.checkpoint();
    d.fillStep(0, 0.5, 1, 0.25);
    try testing.expectEqual(@as(f32, 0.25), d.frameConst(0)[N - 1]);
    d.undo();
    try testing.expectApproxEqAbs(@as(f32, @sin(0.75 * std.math.tau)), d.frameConst(0)[3 * N / 4], 1e-5);
    d.undo();
    try testing.expectApproxEqAbs(@as(f32, 0), d.frameConst(0)[0], 1e-6);
    d.redo();
    try testing.expectEqual(@as(f32, -1), d.frameConst(0)[0]);
}

test "wavetable edit: harmonics read and set amplitudes" {
    var d = try Doc.init(testing.allocator);
    defer d.deinit();
    var mag: [8]f32 = undefined;
    var ph: [8]f32 = undefined;
    d.harmonics(0, &mag, &ph);
    try testing.expectApproxEqAbs(@as(f32, 1), mag[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), mag[1], 1e-4);
    d.setHarmonic(0, 3, 0.5);
    d.harmonics(0, &mag, &ph);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mag[2], 1e-4);
    // A new harmonic is a sine: zero at the start of the cycle.
    d.setHarmonic(0, 1, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), d.frameConst(0)[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), d.frameConst(0)[N / 12], 1e-3);
}

test "wavetable edit: frames, keys and morphs" {
    var d = try Doc.init(testing.allocator);
    defer d.deinit();
    d.resize(5);
    try testing.expectEqual(@as(usize, 5), d.count);
    try testing.expect(d.takeDirty().?.resized);
    // Frame 4: the same sine at a quarter of the level.
    for (d.frame(4)) |*v| v.* *= 0.25;
    d.morph(.crossfade);
    try testing.expectApproxEqAbs(@as(f32, 0.625), d.frameConst(2)[N / 4], 1e-4);
    d.morph(.spectral);
    try testing.expectApproxEqAbs(@as(f32, 0.8125), d.frameConst(1)[N / 4], 1e-3);
    // A key at 1 keeps it; 2 and 3 fill between 1 and 4.
    for (d.frame(1)) |*v| v.* = 0;
    d.toggleKey(1);
    d.morph(.crossfade);
    try testing.expectEqual(@as(f32, 0), d.frameConst(1)[N / 4]);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 12.0), d.frameConst(2)[N / 4], 1e-4);
    // Keys follow their frames through duplicate and remove.
    d.duplicate(0);
    try testing.expect(d.keys.isSet(2));
    try testing.expectEqual(@as(usize, 1), d.sel);
    d.remove(0);
    try testing.expect(d.keys.isSet(1));
    try testing.expectEqual(@as(usize, 5), d.count);
}

test "wavetable edit: frames write the built table" {
    var d = try Doc.init(testing.allocator);
    defer d.deinit();
    d.resize(2);
    d.setShape(1, .saw);
    var t = try d.build(testing.allocator);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), t.frames);
    // The sine comes back at its own level (no table gain).
    try testing.expectApproxEqAbs(@as(f64, 1), t.data[N / 4], 1e-4);
    // The top level of the saw is its fundamental: 2/π.
    const top = t.data[wavetable.STRIDE + wavetable.mipOffset(10) ..][0..16];
    try testing.expectApproxEqAbs(@as(f64, 2.0 / std.math.pi), top[4], 1e-3);
}
