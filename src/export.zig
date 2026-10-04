//! Export (docs/27 §Export): what goes into an audio file and what it's
//! called. Encoders for WAV and AIFF at 16 or 24-bit PCM or 32-bit float,
//! TPDF dither for 16-bit, and the file-name template. The renders that
//! feed them live in main (the export job) and engine (`Capture`).

const std = @import("std");
const flac = @import("flac.zig");

pub const Container = enum(u8) {
    wav = 0,
    aiff = 1,
    flac = 2,
    /// Apple Lossless and AAC, in .m4a through AudioToolbox.
    alac = 3,
    aac = 4,

    pub fn ext(self: Container) []const u8 {
        return switch (self) {
            .wav => ".wav",
            .aiff => ".aif",
            .flac => ".flac",
            .alac, .aac => ".m4a",
        };
    }

    /// Holds integer samples of 16 or 24 bits only.
    pub fn intOnly(self: Container) bool {
        return self == .flac or self == .alac;
    }

    /// The container a path's extension names, if any.
    pub fn ofPath(path: []const u8) ?Container {
        if (std.ascii.endsWithIgnoreCase(path, ".wav")) return .wav;
        if (std.ascii.endsWithIgnoreCase(path, ".aif") or std.ascii.endsWithIgnoreCase(path, ".aiff")) return .aiff;
        if (std.ascii.endsWithIgnoreCase(path, ".flac")) return .flac;
        if (std.ascii.endsWithIgnoreCase(path, ".m4a")) return .aac;
        return null;
    }
};

pub const Bits = enum(u8) {
    pcm16 = 0,
    pcm24 = 1,
    float32 = 2,

    pub fn bytes(self: Bits) u32 {
        return switch (self) {
            .pcm16 => 2,
            .pcm24 => 3,
            .float32 => 4,
        };
    }
};

pub const Format = struct {
    container: Container = .wav,
    bits: Bits = .pcm24,
    sample_rate: u32 = 48_000,
    /// TPDF dither at ±1 LSB before rounding to 16 bits. Ignored for 24-bit
    /// and float. Seeded, so an export is reproducible.
    dither: bool = true,
    seed: u64 = 0x5eed,
    /// FLAC's compression level, 0–8.
    flac_level: u4 = 5,
    /// AAC's bitrate.
    aac_kbps: u16 = 256,
};

extern fn slab_write_m4a(path: [*:0]const u8, ints: ?[*]const c_int, floats: ?[*]const f32, frames: c_ulong, rate: f64, alac: c_int, bits: c_int, bitrate: c_int) c_int;

/// Write interleaved stereo `samples` to `path` in format `f`.
pub fn writeFile(alloc: std.mem.Allocator, path: []const u8, samples: []const f32, f: Format) !void {
    if (f.container == .alac or f.container == .aac) {
        const z = try alloc.dupeZ(u8, path);
        defer alloc.free(z);
        const frames = samples.len / 2;
        var st: c_int = 0;
        if (f.container == .alac) {
            var g = f;
            if (g.bits == .float32) g.bits = .pcm24;
            const ints = try alloc.alloc(c_int, samples.len);
            defer alloc.free(ints);
            var q = Quantizer.init(g);
            for (ints, samples) |*o, x| o.* = q.next(x);
            st = slab_write_m4a(z.ptr, ints.ptr, null, frames, @floatFromInt(f.sample_rate), 1, if (g.bits == .pcm16) 16 else 24, 0);
        } else {
            st = slab_write_m4a(z.ptr, null, samples.ptr, frames, @floatFromInt(f.sample_rate), 0, 0, @as(c_int, f.aac_kbps) * 1000);
        }
        if (st != 0) {
            std.log.err("m4a write failed: OSStatus {d}", .{st});
            return error.EncodeFailed;
        }
        return;
    }
    const bytes = try encode(alloc, samples, f);
    defer alloc.free(bytes);
    try @import("document.zig").writeFile(alloc, path, bytes);
}

/// Encode interleaved stereo `samples` (L R L R…) as a file image. PCM is
/// clamped to full scale; float is written as is. FLAC holds 16 or 24
/// bits: float asks it for 24.
pub fn encode(alloc: std.mem.Allocator, samples: []const f32, f: Format) ![]u8 {
    if (f.container == .flac) {
        var g = f;
        if (g.bits == .float32) g.bits = .pcm24;
        const ints = try alloc.alloc(i32, samples.len);
        defer alloc.free(ints);
        var q = Quantizer.init(g);
        for (ints, samples) |*o, x| o.* = q.next(x);
        return flac.encode(alloc, ints, .{
            .sample_rate = g.sample_rate,
            .bits = if (g.bits == .pcm16) 16 else 24,
            .level = g.flac_level,
        });
    }
    const nb = f.bits.bytes();
    const data_len = samples.len * nb;
    const frames: u32 = @intCast(samples.len / 2);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    switch (f.container) {
        .wav => {
            try out.ensureTotalCapacity(alloc, 44 + data_len);
            out.appendSliceAssumeCapacity("RIFF");
            le32(&out, @intCast(36 + data_len));
            out.appendSliceAssumeCapacity("WAVEfmt ");
            le32(&out, 16);
            le16(&out, if (f.bits == .float32) 3 else 1);
            le16(&out, 2);
            le32(&out, f.sample_rate);
            le32(&out, f.sample_rate * 2 * nb);
            le16(&out, @intCast(2 * nb));
            le16(&out, @intCast(nb * 8));
            out.appendSliceAssumeCapacity("data");
            le32(&out, @intCast(data_len));
            writeSamples(&out, samples, f, .little);
        },
        .flac, .alac, .aac => unreachable,
        .aiff => {
            // Float needs AIFF-C ('fl32'); PCM is plain AIFF.
            const aifc = f.bits == .float32;
            const comm_len: u32 = if (aifc) 18 + 4 + 2 else 18; // + type + empty pstring (padded)
            const fver_len: u32 = if (aifc) 8 + 4 else 0;
            const ssnd_len: u32 = @intCast(8 + data_len);
            const form_len: u32 = 4 + fver_len + (8 + comm_len) + (8 + ssnd_len) + @as(u32, @intCast(data_len & 1));
            try out.ensureTotalCapacity(alloc, 8 + form_len);
            out.appendSliceAssumeCapacity("FORM");
            be32(&out, form_len);
            out.appendSliceAssumeCapacity(if (aifc) "AIFC" else "AIFF");
            if (aifc) {
                out.appendSliceAssumeCapacity("FVER");
                be32(&out, 4);
                be32(&out, 0xA2805140); // AIFF-C version 1
            }
            out.appendSliceAssumeCapacity("COMM");
            be32(&out, comm_len);
            be16(&out, 2);
            be32(&out, frames);
            be16(&out, @intCast(nb * 8));
            extended80(&out, @floatFromInt(f.sample_rate));
            if (aifc) {
                out.appendSliceAssumeCapacity("fl32");
                out.appendSliceAssumeCapacity(&.{ 0, 0 }); // empty name, padded
            }
            out.appendSliceAssumeCapacity("SSND");
            be32(&out, ssnd_len);
            be32(&out, 0); // offset
            be32(&out, 0); // block size
            writeSamples(&out, samples, f, .big);
            if (data_len & 1 != 0) out.appendAssumeCapacity(0);
        },
    }
    return out.toOwnedSlice(alloc);
}

/// Float samples to `bits`-bit integers, as every PCM format and FLAC
/// store them: clamped to full scale, rounded, TPDF-dithered at 16 bits
/// when `dither`.
pub const Quantizer = struct {
    prng: std.Random.DefaultPrng,
    bits: Bits,
    dither: bool,

    pub fn init(f: Format) Quantizer {
        return .{ .prng = std.Random.DefaultPrng.init(f.seed), .bits = f.bits, .dither = f.dither and f.bits == .pcm16 };
    }

    pub fn next(self: *Quantizer, x: f32) i32 {
        const full: f64 = if (self.bits == .pcm16) 32767.0 else 8_388_607.0;
        var v = std.math.clamp(@as(f64, x), -1, 1) * full;
        if (self.dither) {
            const rnd = self.prng.random();
            v += rnd.float(f64) - rnd.float(f64);
        }
        return @intFromFloat(std.math.clamp(@round(v), -full - 1, full));
    }
};

fn writeSamples(out: *std.ArrayList(u8), samples: []const f32, f: Format, endian: std.builtin.Endian) void {
    var q = Quantizer.init(f);
    for (samples) |x| switch (f.bits) {
        .float32 => {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(x), endian);
            out.appendSliceAssumeCapacity(&b);
        },
        .pcm16 => {
            var b: [2]u8 = undefined;
            std.mem.writeInt(i16, &b, @intCast(q.next(x)), endian);
            out.appendSliceAssumeCapacity(&b);
        },
        .pcm24 => {
            const u: u32 = @bitCast(q.next(x));
            const b = [3]u8{ @truncate(u), @truncate(u >> 8), @truncate(u >> 16) };
            if (endian == .little) out.appendSliceAssumeCapacity(&b) else out.appendSliceAssumeCapacity(&.{ b[2], b[1], b[0] });
        },
    };
}

fn le16(out: *std.ArrayList(u8), v: u16) void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    out.appendSliceAssumeCapacity(&b);
}
fn le32(out: *std.ArrayList(u8), v: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    out.appendSliceAssumeCapacity(&b);
}
fn be16(out: *std.ArrayList(u8), v: u16) void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    out.appendSliceAssumeCapacity(&b);
}
fn be32(out: *std.ArrayList(u8), v: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    out.appendSliceAssumeCapacity(&b);
}

/// An 80-bit IEEE extended float, big-endian, as AIFF's COMM rate wants.
fn extended80(out: *std.ArrayList(u8), v: f64) void {
    var b: [10]u8 = @splat(0);
    if (v > 0) {
        const e: i32 = std.math.log2_int(u64, @intFromFloat(v));
        const exp: u16 = @intCast(16383 + e);
        const mant: u64 = @intFromFloat(v * std.math.pow(f64, 2, @floatFromInt(63 - e)));
        std.mem.writeInt(u16, b[0..2], exp, .big);
        std.mem.writeInt(u64, b[2..10], mant, .big);
    }
    out.appendSliceAssumeCapacity(&b);
}

/// What a name template's fields stand for.
pub const NameFields = struct {
    project: []const u8 = "",
    /// 1-based, written with two digits.
    nn: usize = 0,
    track: []const u8 = "",
    section: []const u8 = "",
};

/// Fill `template`'s `{project}`, `{nn}`, `{track}` and `{section}`.
/// Characters a file name can't hold become `-`.
pub fn fillName(buf: []u8, template: []const u8, f: NameFields) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var num_buf: [8]u8 = undefined;
    while (i < template.len) {
        var piece = template[i .. i + 1];
        i += 1;
        if (piece[0] == '{') if (std.mem.indexOfScalarPos(u8, template, i, '}')) |j| {
            const key = template[i..j];
            const field: ?[]const u8 = if (std.mem.eql(u8, key, "project"))
                f.project
            else if (std.mem.eql(u8, key, "track"))
                f.track
            else if (std.mem.eql(u8, key, "section"))
                f.section
            else if (std.mem.eql(u8, key, "nn"))
                std.fmt.bufPrint(&num_buf, "{d:0>2}", .{f.nn}) catch ""
            else
                null;
            if (field) |v| {
                piece = v;
                i = j + 1;
            }
        };
        for (piece) |ch| {
            if (n == buf.len) return buf[0..n];
            buf[n] = if (ch == '/' or ch == ':' or ch < 0x20) '-' else ch;
            n += 1;
        }
    }
    return buf[0..n];
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const wav = @import("wav.zig");

test "WAV at each depth parses back" {
    const s = [_]f32{ 0.5, -0.25, 1.5, -1.0, 0, 0.125 };
    inline for (.{ Bits.pcm16, Bits.pcm24, Bits.float32 }) |bits| {
        const bytes = try encode(testing.allocator, &s, .{ .bits = bits, .dither = false });
        defer testing.allocator.free(bytes);
        try testing.expectEqual(@as(usize, 44 + 6 * bits.bytes()), bytes.len);
        var got = try wav.parse(testing.allocator, bytes);
        defer got.deinit(testing.allocator);
        try testing.expectEqual(@as(f64, 48_000), got.sample_rate);
        try testing.expectEqual(@as(usize, 3), got.data.len);
        const tol: f64 = if (bits == .pcm16) 1e-4 else 1e-6;
        try testing.expectApproxEqAbs(@as(f64, 0.125), got.data[0], tol); // (0.5 - 0.25) / 2
        // PCM clamps the 1.5 to full scale; float keeps it.
        const over: f64 = if (bits == .float32) 0.25 else 0.0;
        try testing.expectApproxEqAbs(over, got.data[1], 2e-4);
    }
}

test "16-bit dither stays within a step and repeats with its seed" {
    var s: [2048]f32 = undefined;
    for (&s, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 7)) * 0.001;
    const a = try encode(testing.allocator, &s, .{ .bits = .pcm16 });
    defer testing.allocator.free(a);
    const b = try encode(testing.allocator, &s, .{ .bits = .pcm16 });
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
    const plain = try encode(testing.allocator, &s, .{ .bits = .pcm16, .dither = false });
    defer testing.allocator.free(plain);
    var differ: usize = 0;
    for (0..s.len) |k| {
        const x = std.mem.readInt(i16, a[44 + k * 2 ..][0..2], .little);
        const y = std.mem.readInt(i16, plain[44 + k * 2 ..][0..2], .little);
        try testing.expect(@abs(@as(i32, x) - y) <= 1);
        if (x != y) differ += 1;
    }
    try testing.expect(differ > s.len / 8);
}

test "AIFF: big-endian PCM with an 80-bit rate, AIFF-C for float" {
    const s = [_]f32{ 0.5, -0.5 };
    const p = try encode(testing.allocator, &s, .{ .container = .aiff, .bits = .pcm16, .sample_rate = 44_100, .dither = false });
    defer testing.allocator.free(p);
    try testing.expectEqualSlices(u8, "FORM", p[0..4]);
    try testing.expectEqual(@as(u32, @intCast(p.len - 8)), std.mem.readInt(u32, p[4..8], .big));
    try testing.expectEqualSlices(u8, "AIFFCOMM", p[8..16]);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, p[20..22], .big));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, p[22..26], .big));
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, p[26..28], .big));
    // 44100 = 0x400E AC44 0000 0000 0000.
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0 }, p[28..38]);
    try testing.expectEqualSlices(u8, "SSND", p[38..42]);
    try testing.expectEqual(@as(i16, 16384), std.mem.readInt(i16, p[54..56], .big));
    try testing.expectEqual(@as(i16, -16384), std.mem.readInt(i16, p[56..58], .big));

    const f = try encode(testing.allocator, &s, .{ .container = .aiff, .bits = .float32 });
    defer testing.allocator.free(f);
    try testing.expectEqualSlices(u8, "AIFC", f[8..12]);
    try testing.expectEqual(@as(u32, @intCast(f.len - 8)), std.mem.readInt(u32, f[4..8], .big));
    try testing.expect(std.mem.indexOf(u8, f, "fl32") != null);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, -0.5))), std.mem.readInt(u32, f[f.len - 4 ..][0..4], .big));
}

test "fillName fills the fields and keeps paths flat" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Song-03-Kick", fillName(&buf, "{project}-{nn}-{track}", .{ .project = "Song", .nn = 3, .track = "Kick" }));
    try testing.expectEqualStrings("Song - verse-a-b", fillName(&buf, "{project} - {section}", .{ .project = "Song", .section = "verse/a:b" }));
    try testing.expectEqualStrings("x{odd}", fillName(&buf, "x{odd}", .{}));
}
