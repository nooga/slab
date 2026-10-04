//! FLAC encoder (docs/27 §FLAC encoder): our own, no libFLAC. Fixed 4096-
//! frame blocks of 16 or 24-bit mono or stereo; per frame the smallest of
//! independent, left/side, right/side and mid/side; per subframe the
//! smallest of CONSTANT, FIXED orders 0–4, LPC (Levinson-Durbin on a
//! windowed autocorrelation, quantized with error feedback) and VERBATIM;
//! residuals in partitioned Rice codes, a parameter per partition. A
//! STREAMINFO with the MD5 of the audio and a VORBIS_COMMENT with the
//! vendor string. The level (0–8) sets how hard it searches, as
//! `flac -0..-8` does.

const std = @import("std");

pub const BLOCK: usize = 4096;
const MAX_LPC: usize = 32;

pub const Options = struct {
    sample_rate: u32 = 48_000,
    /// 16 or 24.
    bits: u5 = 24,
    channels: u2 = 2,
    level: u4 = 5,
    vendor: []const u8 = "slab",
};

/// What a level searches.
const Search = struct {
    lpc_order: usize,
    /// Try every LPC order up to `lpc_order`, not just it.
    exhaustive: bool,
    max_partition: u4,
};

fn search(level: u4) Search {
    return switch (level) {
        0 => .{ .lpc_order = 0, .exhaustive = false, .max_partition = 3 },
        1 => .{ .lpc_order = 0, .exhaustive = false, .max_partition = 4 },
        2 => .{ .lpc_order = 0, .exhaustive = false, .max_partition = 5 },
        3 => .{ .lpc_order = 6, .exhaustive = false, .max_partition = 4 },
        4 => .{ .lpc_order = 8, .exhaustive = false, .max_partition = 5 },
        5 => .{ .lpc_order = 8, .exhaustive = false, .max_partition = 6 },
        6 => .{ .lpc_order = 12, .exhaustive = false, .max_partition = 6 },
        7 => .{ .lpc_order = 12, .exhaustive = true, .max_partition = 6 },
        else => .{ .lpc_order = 12, .exhaustive = true, .max_partition = 8 },
    };
}

/// Encode interleaved integer samples (`channels` per frame, each within
/// `bits` bits signed) into a .flac file image.
pub fn encode(alloc: std.mem.Allocator, samples: []const i32, o: Options) ![]u8 {
    const ch: usize = o.channels;
    const frames = samples.len / ch;
    var w = BitWriter{ .alloc = alloc };
    errdefer w.out.deinit(alloc);

    // fLaC, then STREAMINFO (its frame sizes and MD5 patched at the end).
    try w.bytes("fLaC");
    try w.bits(0, 1); // not last
    try w.bits(0, 7); // STREAMINFO
    try w.bits(34, 24);
    const info_at = w.out.items.len;
    try w.bits(BLOCK, 16);
    try w.bits(BLOCK, 16);
    try w.bits(0, 24); // min frame size
    try w.bits(0, 24); // max frame size
    try w.bits(o.sample_rate, 20);
    try w.bits(ch - 1, 3);
    try w.bits(@as(u64, o.bits) - 1, 5);
    try w.bits(frames, 36);
    try w.bytes(&@as([16]u8, @splat(0)));

    // VORBIS_COMMENT: the vendor, no comments. Little-endian lengths.
    try w.bits(1, 1); // last
    try w.bits(4, 7);
    try w.bits(4 + o.vendor.len + 4, 24);
    try w.le32(@intCast(o.vendor.len));
    try w.bytes(o.vendor);
    try w.le32(0);

    // Frames are independent: encoded on several threads, joined in order.
    const nframes = (frames + BLOCK - 1) / BLOCK;
    const parts = try alloc.alloc([]u8, nframes);
    @memset(parts, &.{});
    defer {
        for (parts) |p| if (p.len > 0) alloc.free(p);
        alloc.free(parts);
    }
    var job = FrameJob{ .alloc = alloc, .samples = samples, .frames = frames, .o = o, .s = search(o.level), .parts = parts };
    const cpus = std.Thread.getCpuCount() catch 1;
    var threads: [7]?std.Thread = @splat(null);
    for (threads[0..@min(threads.len, cpus -| 1, nframes -| 1)]) |*t| t.* = std.Thread.spawn(.{}, FrameJob.work, .{&job}) catch null;
    job.work();
    for (threads) |t| if (t) |th| th.join();
    if (job.failed.load(.acquire)) return error.OutOfMemory;

    var md5 = std.crypto.hash.Md5.init(.{});
    for (samples) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .little);
        md5.update(b[0 .. @as(usize, o.bits) / 8]);
    }
    var min_frame: usize = std.math.maxInt(usize);
    var max_frame: usize = 0;
    for (parts) |p| {
        try w.bytes(p);
        min_frame = @min(min_frame, p.len);
        max_frame = @max(max_frame, p.len);
    }

    var digest: [16]u8 = undefined;
    md5.final(&digest);
    const info = w.out.items[info_at..];
    if (frames > 0) {
        writeBe(info[4..7], min_frame);
        writeBe(info[7..10], max_frame);
    }
    @memcpy(info[18..34], &digest);
    return w.out.toOwnedSlice(alloc);
}

fn writeBe(dst: []u8, v: usize) void {
    var x = v;
    var i = dst.len;
    while (i > 0) {
        i -= 1;
        dst[i] = @truncate(x);
        x >>= 8;
    }
}

/// Channel assignment: independent stereo is channels − 1.
/// Frames handed out to whichever thread asks next.
const FrameJob = struct {
    alloc: std.mem.Allocator,
    samples: []const i32,
    frames: usize,
    o: Options,
    s: Search,
    parts: [][]u8,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn work(self: *FrameJob) void {
        const ch: usize = self.o.channels;
        var chan: [4][BLOCK]i64 = undefined;
        while (true) {
            const fi = self.next.fetchAdd(1, .monotonic);
            if (fi >= self.parts.len) return;
            const start = fi * BLOCK;
            const n = @min(BLOCK, self.frames - start);
            for (0..n) |i| for (0..ch) |c| {
                chan[c][i] = self.samples[(start + i) * ch + c];
            };
            var w = BitWriter{ .alloc = self.alloc };
            encodeFrame(&w, &chan, n, fi, self.o, self.s, self.alloc) catch {
                w.out.deinit(self.alloc);
                self.failed.store(true, .release);
                return;
            };
            self.parts[fi] = w.out.toOwnedSlice(self.alloc) catch {
                w.out.deinit(self.alloc);
                self.failed.store(true, .release);
                return;
            };
        }
    }
};

const Assign = enum(u4) { independent = 1, left_side = 8, right_side = 9, mid_side = 10 };

fn encodeFrame(w: *BitWriter, chan: *[4][BLOCK]i64, n: usize, index: usize, o: Options, s: Search, alloc: std.mem.Allocator) !void {
    const bps: u6 = o.bits;
    // Candidate subframes: L, R, and for stereo side and mid.
    var subs: [4]Subframe = undefined;
    var count: usize = o.channels;
    if (o.channels == 2) {
        for (0..n) |i| {
            const l = chan[0][i];
            const r = chan[1][i];
            chan[2][i] = l - r; // side
            chan[3][i] = (l + r) >> 1; // mid
        }
        count = 4;
    }
    for (0..count) |c| subs[c] = try best(chan[c][0..n], if (c == 2) bps + 1 else bps, s, alloc);
    defer for (subs[0..count]) |*sf| sf.deinit(alloc);

    var assign: Assign = .independent;
    var pick = [2]usize{ 0, 1 };
    if (o.channels == 2) {
        const options = [_]struct { a: Assign, p: [2]usize }{
            .{ .a = .independent, .p = .{ 0, 1 } },
            .{ .a = .left_side, .p = .{ 0, 2 } },
            .{ .a = .right_side, .p = .{ 2, 1 } },
            .{ .a = .mid_side, .p = .{ 3, 2 } },
        };
        var cost: usize = std.math.maxInt(usize);
        for (options) |op| {
            const c = subs[op.p[0]].bits + subs[op.p[1]].bits;
            if (c < cost) {
                cost = c;
                assign = op.a;
                pick = op.p;
            }
        }
    }

    // Header.
    const frame_at = w.out.items.len;
    try w.bits(0b11111111111110, 14);
    try w.bits(0, 1); // reserved
    try w.bits(0, 1); // fixed blocksize
    const bs_code: u4 = if (n == BLOCK) 0b1100 else 0b0111;
    try w.bits(bs_code, 4);
    try w.bits(rateCode(o.sample_rate), 4);
    try w.bits(if (o.channels == 1) 0 else @intFromEnum(assign), 4);
    try w.bits(if (o.bits == 16) 0b100 else 0b110, 3);
    try w.bits(0, 1);
    try w.utf8(index);
    if (bs_code == 0b0111) try w.bits(n - 1, 16);
    try w.bits(crc8(w.out.items[frame_at..]), 8);

    for (0..o.channels) |k| try subs[pick[k]].write(w);
    try w.alignByte();
    try w.bits(crc16(w.out.items[frame_at..]), 16);
}

fn rateCode(sr: u32) u4 {
    return switch (sr) {
        88_200 => 0b0001,
        176_400 => 0b0010,
        192_000 => 0b0011,
        8_000 => 0b0100,
        16_000 => 0b0101,
        22_050 => 0b0110,
        24_000 => 0b0111,
        32_000 => 0b1000,
        44_100 => 0b1001,
        48_000 => 0b1010,
        96_000 => 0b1011,
        else => 0, // from STREAMINFO
    };
}

// ── Subframes ─────────────────────────────────────────────────────────

const Kind = enum { constant, verbatim, fixed, lpc };

/// A chosen subframe: how it predicts, and its residual's coding. `bits`
/// is its exact size.
const Subframe = struct {
    kind: Kind,
    bps: u6,
    data: []const i64,
    order: usize = 0,
    precision: u5 = 0,
    shift: u5 = 0,
    coefs: [MAX_LPC]i32 = undefined,
    residual: []i64 = &.{},
    rice: Rice = .{},
    bits: usize = 0,

    fn deinit(self: *Subframe, alloc: std.mem.Allocator) void {
        if (self.residual.len > 0) alloc.free(self.residual);
    }

    fn write(self: *const Subframe, w: *BitWriter) !void {
        try w.bits(0, 1);
        switch (self.kind) {
            .constant => {
                try w.bits(0, 6);
                try w.bits(0, 1);
                try w.signed(self.data[0], self.bps);
            },
            .verbatim => {
                try w.bits(1, 6);
                try w.bits(0, 1);
                for (self.data) |x| try w.signed(x, self.bps);
            },
            .fixed => {
                try w.bits(0b001000 | self.order, 6);
                try w.bits(0, 1);
                for (self.data[0..self.order]) |x| try w.signed(x, self.bps);
                try self.rice.write(w, self.residual);
            },
            .lpc => {
                try w.bits(0b100000 | (self.order - 1), 6);
                try w.bits(0, 1);
                for (self.data[0..self.order]) |x| try w.signed(x, self.bps);
                try w.bits(self.precision - 1, 4);
                try w.signed(self.shift, 5);
                for (self.coefs[0..self.order]) |q| try w.signed(q, self.precision);
                try self.rice.write(w, self.residual);
            },
        }
    }
};

/// The smallest subframe for `x`.
fn best(x: []const i64, bps: u6, s: Search, alloc: std.mem.Allocator) !Subframe {
    const n = x.len;
    const verbatim = Subframe{ .kind = .verbatim, .bps = bps, .data = x, .bits = 8 + n * bps };
    var all_same = true;
    for (x[1..]) |v| all_same = all_same and v == x[0];
    if (all_same) return .{ .kind = .constant, .bps = bps, .data = x, .bits = 8 + bps };

    var top = verbatim;
    errdefer top.deinit(alloc);
    const res = try alloc.alloc(i64, n);
    defer alloc.free(res);

    // FIXED orders 0–4.
    for (0..5) |order| {
        if (order >= n) break;
        fixedResidual(x, order, res);
        const rice = Rice.choose(res, n, order, s.max_partition) orelse continue;
        const total = 8 + order * bps + rice.bits;
        if (total < top.bits) {
            top.deinit(alloc);
            top = .{ .kind = .fixed, .bps = bps, .data = x, .order = order, .residual = try alloc.dupe(i64, res[0..n]), .rice = rice, .bits = total };
        }
    }

    // LPC.
    const max_order = @min(s.lpc_order, n -| 1);
    if (max_order > 0) {
        var lp: [MAX_LPC][MAX_LPC]f64 = undefined;
        const got = lpcCoefficients(x, max_order, &lp);
        var order: usize = if (s.exhaustive) 1 else got;
        while (order <= got) : (order += 1) {
            const precision: u5 = if (bps <= 17) 15 else 13;
            var q: [MAX_LPC]i32 = undefined;
            const shift = quantize(lp[order - 1][0..order], precision, &q) orelse continue;
            if (!lpcResidual(x, q[0..order], shift, res)) continue;
            const rice = Rice.choose(res, n, order, s.max_partition) orelse continue;
            const total = 8 + order * bps + 4 + 5 + order * @as(usize, precision) + rice.bits;
            if (total < top.bits) {
                top.deinit(alloc);
                top = .{ .kind = .lpc, .bps = bps, .data = x, .order = order, .precision = precision, .shift = shift, .residual = try alloc.dupe(i64, res[0..n]), .rice = rice, .bits = total };
                @memcpy(top.coefs[0..order], q[0..order]);
            }
        }
    }
    return top;
}

fn fixedResidual(x: []const i64, order: usize, res: []i64) void {
    for (order..x.len) |i| res[i] = switch (order) {
        0 => x[i],
        1 => x[i] - x[i - 1],
        2 => x[i] - 2 * x[i - 1] + x[i - 2],
        3 => x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3],
        else => x[i] - 4 * x[i - 1] + 6 * x[i - 2] - 4 * x[i - 3] + x[i - 4],
    };
}

/// Prediction coefficients for orders 1..`max_order` (row k holds order
/// k+1's) from a Welch-windowed autocorrelation; how many orders are valid.
fn lpcCoefficients(x: []const i64, max_order: usize, out: *[MAX_LPC][MAX_LPC]f64) usize {
    const n = x.len;
    var autoc: [MAX_LPC + 1]f64 = @splat(0);
    var wx: [BLOCK]f64 = undefined;
    const half = (@as(f64, @floatFromInt(n)) - 1) / 2;
    const den = (@as(f64, @floatFromInt(n)) + 1) / 2;
    for (0..n) |i| {
        const t = (@as(f64, @floatFromInt(i)) - half) / den;
        wx[i] = @as(f64, @floatFromInt(x[i])) * (1 - t * t);
    }
    for (0..max_order + 1) |lag| {
        var acc: f64 = 0;
        for (lag..n) |i| acc += wx[i] * wx[i - lag];
        autoc[lag] = acc;
    }
    if (autoc[0] == 0) return 0;
    var lpc: [MAX_LPC]f64 = @splat(0);
    var err = autoc[0];
    for (0..max_order) |i| {
        var r = -autoc[i + 1];
        for (0..i) |j| r -= lpc[j] * autoc[i - j];
        r /= err;
        lpc[i] = r;
        var j: usize = 0;
        while (j < i / 2) : (j += 1) {
            const tmp = lpc[j];
            lpc[j] += r * lpc[i - 1 - j];
            lpc[i - 1 - j] += r * tmp;
        }
        if (i & 1 == 1) lpc[j] += lpc[j] * r;
        err *= 1 - r * r;
        for (0..i + 1) |k| out[i][k] = -lpc[k];
        if (err <= 0) return i + 1;
    }
    return max_order;
}

/// Quantize `lp` to `precision`-bit coefficients with error feedback; the
/// shift, or null when they can't be (all zero, or too large).
fn quantize(lp: []const f64, precision: u5, q: *[MAX_LPC]i32) ?u5 {
    var cmax: f64 = 0;
    for (lp) |c| cmax = @max(cmax, @abs(c));
    if (cmax <= 0 or !std.math.isFinite(cmax)) return null;
    const qmax: i32 = (@as(i32, 1) << (precision - 1)) - 1;
    const qmin: i32 = -qmax - 1;
    const log2cmax: i32 = @as(i32, std.math.frexp(cmax).exponent) - 1;
    const shift: i32 = @as(i32, precision) - 1 - log2cmax - 1;
    if (shift < 0) return null;
    const sh: u5 = @intCast(@min(shift, 15));
    const scale: f64 = @floatFromInt(@as(i32, 1) << sh);
    var err: f64 = 0;
    for (lp, 0..) |c, i| {
        err += c * scale;
        const v: i32 = @intFromFloat(std.math.clamp(@round(err), @as(f64, @floatFromInt(qmin)), @as(f64, @floatFromInt(qmax))));
        q[i] = v;
        err -= @floatFromInt(v);
    }
    return sh;
}

/// The residual of a quantized predictor; false if it overflows what a
/// decoder holds (32 bits).
fn lpcResidual(x: []const i64, q: []const i32, shift: u5, res: []i64) bool {
    const order = q.len;
    for (order..x.len) |i| {
        var acc: i64 = 0;
        for (q, 0..) |c, j| acc += @as(i64, c) * x[i - 1 - j];
        const r = x[i] - (acc >> shift);
        if (r > std.math.maxInt(i31) or r < std.math.minInt(i31)) return false;
        res[i] = r;
    }
    return true;
}

// ── Rice coding ───────────────────────────────────────────────────────

const MAX_PARTITIONS = 256;

const Rice = struct {
    order: u4 = 0,
    /// Warm-up samples the first partition starts after.
    warm: usize = 0,
    /// 5-bit parameters (RICE2) when one is past 14.
    wide: bool = false,
    params: [MAX_PARTITIONS]u5 = undefined,
    bits: usize = 0,

    /// The smallest partitioning of `res[warm..n]` up to `max_order`.
    fn choose(res: []const i64, n: usize, warm: usize, max_order: u4) ?Rice {
        var top: ?Rice = null;
        var order: u4 = 0;
        while (order <= max_order) : (order += 1) {
            const parts = @as(usize, 1) << order;
            if (n % parts != 0) break;
            const size = n >> order;
            if (size <= warm) break;
            var r = Rice{ .order = order, .warm = warm, .bits = 2 + 4 };
            var max_k: u5 = 0;
            for (0..parts) |p| {
                const lo = if (p == 0) warm else p * size;
                const hi = (p + 1) * size;
                var sum: u64 = 0;
                for (res[lo..hi]) |v| sum += zigzag(v);
                const cnt = hi - lo;
                // Start from the mean's log2 and look either side.
                const mean = if (cnt > 0) sum / cnt else 0;
                const guess: u5 = if (mean > 0) @intCast(@min(30, std.math.log2_int(u64, mean))) else 0;
                var bk: u5 = guess;
                var bc: usize = std.math.maxInt(usize);
                var k: u5 = guess -| 1;
                while (k <= @min(30, @as(u6, guess) + 1)) : (k += 1) {
                    var c: usize = cnt * (@as(usize, k) + 1);
                    for (res[lo..hi]) |v| c += @intCast(zigzag(v) >> k);
                    if (c < bc) {
                        bc = c;
                        bk = k;
                    }
                    if (k == 30) break;
                }
                r.params[p] = bk;
                max_k = @max(max_k, bk);
                r.bits += bc;
            }
            r.wide = max_k > 14;
            r.bits += parts * @as(usize, if (r.wide) 5 else 4);
            if (top == null or r.bits < top.?.bits) top = r;
        }
        return top;
    }

    fn write(self: *const Rice, w: *BitWriter, res: []const i64) !void {
        try w.bits(@intFromBool(self.wide), 2);
        try w.bits(self.order, 4);
        const n = res.len;
        const parts = @as(usize, 1) << self.order;
        const size = n >> self.order;
        for (0..parts) |p| {
            const k = self.params[p];
            try w.bits(k, if (self.wide) 5 else 4);
            const lo = if (p == 0) self.warm else p * size;
            for (res[lo .. (p + 1) * size]) |v| {
                const u = zigzag(v);
                try w.unary(@intCast(u >> k));
                if (k > 0) try w.bits(u & ((@as(u64, 1) << k) - 1), k);
            }
        }
    }
};

fn zigzag(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}

// ── Bits ──────────────────────────────────────────────────────────────

const BitWriter = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    n: u6 = 0,

    fn bits(self: *BitWriter, v: u64, count: u7) !void {
        var left: u7 = count;
        while (left > 0) {
            const take: u6 = @intCast(@min(left, 32));
            left -= take;
            const chunk: u64 = (v >> @intCast(left)) & ((@as(u64, 1) << take) - 1);
            self.acc = (self.acc << take) | chunk;
            self.n += take;
            while (self.n >= 8) {
                self.n -= 8;
                try self.out.append(self.alloc, @truncate(self.acc >> self.n));
            }
            self.acc &= (@as(u64, 1) << self.n) - 1;
        }
    }

    fn signed(self: *BitWriter, v: i64, count: u7) !void {
        try self.bits(@as(u64, @bitCast(v)) & ((@as(u64, 1) << @intCast(count)) - 1), count);
    }

    /// `q` zeros, then a one.
    fn unary(self: *BitWriter, q: u64) !void {
        var z = q;
        while (z >= 32) : (z -= 32) try self.bits(0, 32);
        try self.bits(1, @intCast(z + 1));
    }

    fn alignByte(self: *BitWriter) !void {
        if (self.n > 0) try self.bits(0, 8 - @as(u7, self.n));
    }

    fn bytes(self: *BitWriter, b: []const u8) !void {
        std.debug.assert(self.n == 0);
        try self.out.appendSlice(self.alloc, b);
    }

    fn le32(self: *BitWriter, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.bytes(&b);
    }

    /// A frame number in FLAC's UTF-8-like code.
    fn utf8(self: *BitWriter, v: usize) !void {
        if (v < 0x80) return self.bits(v, 8);
        const len: u6 = if (v < 0x800) 2 else if (v < 0x10000) 3 else if (v < 0x200000) 4 else if (v < 0x4000000) 5 else 6;
        const lead: u64 = (@as(u64, 0xFF) << @intCast(8 - len)) & 0xFF;
        try self.bits(lead | (v >> @intCast(6 * (len - 1))), 8);
        var k: u6 = len - 1;
        while (k > 0) {
            k -= 1;
            try self.bits(0x80 | ((v >> @intCast(6 * k)) & 0x3F), 8);
        }
    }
};

fn crc8(data: []const u8) u8 {
    var c: u8 = 0;
    for (data) |b| {
        c ^= b;
        for (0..8) |_| c = if (c & 0x80 != 0) (c << 1) ^ 0x07 else c << 1;
    }
    return c;
}

fn crc16(data: []const u8) u16 {
    var c: u16 = 0;
    for (data) |b| {
        c ^= @as(u16, b) << 8;
        for (0..8) |_| c = if (c & 0x8000 != 0) (c << 1) ^ 0x8005 else c << 1;
    }
    return c;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const ma = @import("c.zig").ma;

/// Decode with miniaudio's FLAC decoder (dr_flac), as the app reads FLAC.
fn decode(alloc: std.mem.Allocator, bytes: []const u8, channels: usize, frames: usize) ![]i32 {
    var cfg = ma.ma_decoder_config_init(ma.ma_format_s32, 0, 0);
    cfg.encodingFormat = ma.ma_encoding_format_flac;
    var dec: ma.ma_decoder = undefined;
    if (ma.ma_decoder_init_memory(bytes.ptr, bytes.len, &cfg, &dec) != ma.MA_SUCCESS) return error.DecodeFailed;
    defer _ = ma.ma_decoder_uninit(&dec);
    try testing.expectEqual(channels, @as(usize, dec.outputChannels));
    const out = try alloc.alloc(i32, frames * channels + 64);
    var got: ma.ma_uint64 = 0;
    _ = ma.ma_decoder_read_pcm_frames(&dec, out.ptr, frames + 32, &got);
    try testing.expectEqual(@as(u64, frames), got);
    return out[0 .. frames * channels];
}

fn roundTrip(samples: []const i32, o: Options) !usize {
    const alloc = testing.allocator;
    const bytes = try encode(alloc, samples, o);
    defer alloc.free(bytes);
    const ch: usize = o.channels;
    const got = try decode(alloc, bytes, ch, samples.len / ch);
    defer alloc.free(got.ptr[0 .. got.len + 64]);
    // s32 output: the samples sit in the top bits.
    const up: u5 = @intCast(32 - @as(u6, o.bits));
    for (samples, got) |want, have| try testing.expectEqual(want, have >> up);
    return bytes.len;
}

const Signal = enum { silence, noise, sweep, dc_offset };

fn testSignal(alloc: std.mem.Allocator, kind: Signal, frames: usize, bits: u5) ![]i32 {
    const s = try alloc.alloc(i32, frames * 2);
    const full: f64 = @floatFromInt((@as(i64, 1) << (bits - 1)) - 1);
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / 48_000.0;
        const l: f64, const r: f64 = switch (kind) {
            .silence => .{ 0, 0 },
            .noise => .{ rnd.float(f64) * 2 - 1, rnd.float(f64) * 2 - 1 },
            .sweep => blk: {
                const ph = 2 * std.math.pi * (50 * t + 4000 * t * t);
                break :blk .{ 0.8 * @sin(ph), 0.6 * @sin(ph + 0.3) };
            },
            .dc_offset => .{ 0.25 + 0.1 * @sin(2 * std.math.pi * 440 * t), 0.25 },
        };
        s[i * 2] = @intFromFloat(@round(l * full));
        s[i * 2 + 1] = @intFromFloat(@round(r * full));
    }
    return s;
}

test "FLAC round-trips bit-exact through dr_flac: silence, noise, a sweep, a DC offset, 16 and 24 bits" {
    const alloc = testing.allocator;
    inline for (.{ 16, 24 }) |bits| {
        inline for (.{ Signal.silence, Signal.noise, Signal.sweep, Signal.dc_offset }) |kind| {
            // Not a whole number of blocks: the last frame is short.
            const s = try testSignal(alloc, kind, BLOCK * 3 + 1001, bits);
            defer alloc.free(s);
            for ([_]u4{ 0, 5, 8 }) |level| {
                const size = try roundTrip(s, .{ .bits = bits, .level = level });
                const raw = s.len * bits / 8;
                switch (kind) {
                    .silence => try testing.expect(size < 600),
                    .noise => try testing.expect(size < raw + raw / 50),
                    .sweep => try testing.expect(size < raw * 3 / 4),
                    .dc_offset => try testing.expect(size < raw / 2),
                }
            }
        }
    }
}

test "FLAC mono and a single short frame" {
    const alloc = testing.allocator;
    const s = try alloc.alloc(i32, 10);
    defer alloc.free(s);
    for (s, 0..) |*x, i| x.* = @as(i32, @intCast(i)) * 300 - 1500;
    _ = try roundTrip(s, .{ .channels = 1, .bits = 16 });
}
