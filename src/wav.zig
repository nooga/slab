//! Minimal RIFF/WAVE loader → f64 mono. The asset arena's first consumer
//! (samplers, wavetables): load a file on the UI thread into host memory,
//! then inject a pointer + length into a machine's params so a `dsp:` voice
//! can read it with `p@64` / `f@i`. Read-only and shared across voices.
//!
//! Supports PCM 8/16/24/32-bit and IEEE-float 32/64-bit, mono or multi-
//! channel (folded to mono by averaging), and FLAC (a .flac path, decoded
//! by miniaudio; the factory sample sets ship as FLAC). The std.fs surface moved in zig
//! 0.16, so IO is direct libc externs (the codebase convention; see
//! presets.zig, machine_registry.zig).

const std = @import("std");
const ma = @import("c.zig").ma;

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
const O_RDONLY: c_int = 0;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

// Refuse pathological files: 32 M samples of f64 ≈ 256 MB, plenty for a
// sampler and a hard guard against a malformed size field.
pub const MAX_SAMPLES: usize = 32 * 1024 * 1024;
const MAX_FILE_BYTES: usize = 512 * 1024 * 1024;

pub const Sample = struct {
    data: []f64,
    sample_rate: f64,
    // From the `smpl` chunk when there is one: the recorded pitch as a MIDI
    // note (with its fraction), and the first loop in samples, end
    // exclusive. root_key < 0 and loop_end == 0 mean the file doesn't say.
    root_key: f64 = -1,
    loop_start: usize = 0,
    loop_end: usize = 0,
    // From a Serum `clm ` chunk ("<!>2048 …"): samples per wavetable
    // frame. 0 when the file doesn't say.
    frame_size: usize = 0,
    // The `clm ` chunk says "(slab levels kept)": the wavetable editor
    // wrote it, its frames are at the levels drawn, and the table keeps
    // them instead of being normalized (src/wavetable_file.zig).
    levels_kept: bool = false,
    /// A stereo load (`loadStereo`) of a file with two or more channels:
    /// `data` is the left channel and this the right. Empty otherwise.
    right: []f64 = &.{},

    pub fn deinit(self: *Sample, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        self.data = &.{};
        if (self.right.len > 0) alloc.free(self.right);
        self.right = &.{};
    }

    pub fn isStereo(self: *const Sample) bool {
        return self.right.len > 0;
    }
};

pub const Error = error{
    OpenFailed,
    ReadFailed,
    NotRiffWave,
    NoFmtChunk,
    NoDataChunk,
    UnsupportedFormat,
    TooLarge,
    Empty,
    OutOfMemory,
};

fn rdU16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn rdU32(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) | (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}

/// Load `path` into a freshly allocated f64 mono buffer. Caller owns the
/// returned `data` (free via Sample.deinit).
pub fn load(alloc: std.mem.Allocator, path: []const u8) Error!Sample {
    return loadAs(alloc, path, false);
}

/// Load `path` keeping its first two channels apart (`Sample.right`), as
/// audio clips play them; a mono file loads as mono.
pub fn loadStereo(alloc: std.mem.Allocator, path: []const u8) Error!Sample {
    return loadAs(alloc, path, true);
}

fn loadAs(alloc: std.mem.Allocator, path: []const u8, stereo: bool) Error!Sample {
    var zbuf: [1024:0]u8 = undefined;
    if (path.len >= zbuf.len) return Error.OpenFailed;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    if (std.ascii.endsWithIgnoreCase(path, ".flac")) return loadFlac(alloc, &zbuf, stereo);

    const fd = open(@ptrCast(&zbuf[0]), O_RDONLY);
    if (fd < 0) return Error.OpenFailed;
    defer _ = close(fd);

    const end = lseek(fd, 0, SEEK_END);
    if (end <= 0) return Error.ReadFailed;
    if (@as(usize, @intCast(end)) > MAX_FILE_BYTES) return Error.TooLarge;
    _ = lseek(fd, 0, SEEK_SET);

    const file_len: usize = @intCast(end);
    const raw = alloc.alloc(u8, file_len) catch return Error.OutOfMemory;
    defer alloc.free(raw);
    var done: usize = 0;
    while (done < file_len) {
        const n = read(fd, raw[done..].ptr, file_len - done);
        if (n < 0) return Error.ReadFailed;
        if (n == 0) break;
        done += @intCast(n);
    }
    if (done < 44) return Error.NotRiffWave;

    return parseAs(alloc, raw[0..done], stereo);
}

/// Decode a FLAC file into f64 at its own rate: mono (channels averaged,
/// like a WAV), or its first two channels with `stereo`.
fn loadFlac(alloc: std.mem.Allocator, zpath: [*:0]const u8, stereo: bool) Error!Sample {
    var cfg = ma.ma_decoder_config_init(ma.ma_format_f32, 0, 0);
    cfg.encodingFormat = ma.ma_encoding_format_flac;
    var dec: ma.ma_decoder = undefined;
    if (ma.ma_decoder_init_file(zpath, &cfg, &dec) != ma.MA_SUCCESS) return Error.OpenFailed;
    defer _ = ma.ma_decoder_uninit(&dec);
    const ch: usize = dec.outputChannels;
    if (ch == 0) return Error.UnsupportedFormat;
    var frames: ma.ma_uint64 = 0;
    if (ma.ma_decoder_get_length_in_pcm_frames(&dec, &frames) != ma.MA_SUCCESS) return Error.ReadFailed;
    if (frames == 0) return Error.Empty;
    if (frames > MAX_SAMPLES) return Error.TooLarge;
    const n: usize = @intCast(frames);
    const tmp = alloc.alloc(f32, n * ch) catch return Error.OutOfMemory;
    defer alloc.free(tmp);
    var got: ma.ma_uint64 = 0;
    _ = ma.ma_decoder_read_pcm_frames(&dec, tmp.ptr, frames, &got);
    if (got == 0) return Error.ReadFailed;
    const len: usize = @intCast(got);
    const data = alloc.alloc(f64, len) catch return Error.OutOfMemory;
    errdefer alloc.free(data);
    if (stereo and ch >= 2) {
        const right = alloc.alloc(f64, len) catch return Error.OutOfMemory;
        for (0..len) |i| {
            data[i] = tmp[i * ch];
            right[i] = tmp[i * ch + 1];
        }
        return .{ .data = data, .right = right, .sample_rate = @floatFromInt(dec.outputSampleRate) };
    }
    for (0..len) |i| {
        var acc: f64 = 0;
        for (0..ch) |c| acc += tmp[i * ch + c];
        data[i] = acc / @as(f64, @floatFromInt(ch));
    }
    return .{ .data = data, .sample_rate = @floatFromInt(dec.outputSampleRate) };
}

/// Parse an in-memory RIFF/WAVE image into f64 mono. Exposed for tests.
pub fn parse(alloc: std.mem.Allocator, buf: []const u8) Error!Sample {
    return parseAs(alloc, buf, false);
}

fn parseAs(alloc: std.mem.Allocator, buf: []const u8, stereo: bool) Error!Sample {
    if (buf.len < 12) return Error.NotRiffWave;
    if (!std.mem.eql(u8, buf[0..4], "RIFF") or !std.mem.eql(u8, buf[8..12], "WAVE")) return Error.NotRiffWave;

    var audio_format: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits: u16 = 0;
    var have_fmt = false;
    var data_off: usize = 0;
    var data_len: usize = 0;
    var root_key: f64 = -1;
    var loop_start: usize = 0;
    var loop_end: usize = 0;
    var frame_size: usize = 0;
    var levels_kept = false;

    var pos: usize = 12;
    while (pos + 8 <= buf.len) {
        const id = buf[pos .. pos + 4];
        const size: usize = rdU32(buf, pos + 4);
        const body = pos + 8;
        if (std.mem.eql(u8, id, "fmt ") and body + 16 <= buf.len) {
            audio_format = rdU16(buf, body);
            channels = rdU16(buf, body + 2);
            sample_rate = rdU32(buf, body + 4);
            bits = rdU16(buf, body + 14);
            // WAVE_FORMAT_EXTENSIBLE: real format tag is in the subformat GUID's
            // first two bytes.
            if (audio_format == 0xFFFE and body + 26 <= buf.len) {
                audio_format = rdU16(buf, body + 24);
            }
            have_fmt = true;
        } else if (std.mem.eql(u8, id, "smpl") and body + 36 <= buf.len) {
            // dwMIDIUnityNote @12, dwMIDIPitchFraction @16 (2^32 = one
            // semitone up), cSampleLoops @28, loops of 24 bytes from @36:
            // id, type, start, end [inclusive], fraction, play count.
            const unity = rdU32(buf, body + 12);
            const frac: f64 = @as(f64, @floatFromInt(rdU32(buf, body + 16))) / 4294967296.0;
            if (unity < 128) root_key = @as(f64, @floatFromInt(unity)) + frac;
            if (rdU32(buf, body + 28) > 0 and body + 60 <= buf.len) {
                const ls = rdU32(buf, body + 44);
                const le = rdU32(buf, body + 48);
                if (le > ls) {
                    loop_start = ls;
                    loop_end = @as(usize, le) + 1;
                }
            }
        } else if (std.mem.eql(u8, id, "clm ") and body + 3 <= buf.len) {
            const text = buf[body..@min(buf.len, body + size)];
            if (std.mem.startsWith(u8, text, "<!>")) {
                var end: usize = 3;
                while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
                frame_size = std.fmt.parseInt(usize, text[3..end], 10) catch 0;
                levels_kept = std.mem.indexOf(u8, text, "(slab levels kept)") != null;
            }
        } else if (std.mem.eql(u8, id, "data")) {
            data_off = body;
            if (size == 0 or body + size > buf.len) {
                // A streaming take whose header size was never patched (clean
                // stop didn't run — e.g. a crash mid-record) leaves this at 0;
                // a truncated file leaves it overlong. Either way the trailing
                // data chunk runs to EOF.
                data_len = buf.len - body;
                break;
            }
            data_len = size;
        }
        pos = body + size + (size & 1); // chunks are word-aligned
    }

    if (!have_fmt) return Error.NoFmtChunk;
    if (data_off == 0 or data_len == 0) return Error.NoDataChunk;
    if (channels == 0 or sample_rate == 0) return Error.UnsupportedFormat;

    const bytes_per = bits / 8;
    if (bytes_per == 0) return Error.UnsupportedFormat;
    const frame_bytes = bytes_per * channels;
    const frames = data_len / frame_bytes;
    if (frames == 0) return Error.Empty;
    if (frames > MAX_SAMPLES) return Error.TooLarge;

    const out = alloc.alloc(f64, frames) catch return Error.OutOfMemory;
    errdefer alloc.free(out);

    const data = buf[data_off..][0..data_len];
    var right: []f64 = &.{};
    errdefer if (right.len > 0) alloc.free(right);
    if (stereo and channels >= 2) {
        right = alloc.alloc(f64, frames) catch return Error.OutOfMemory;
        for (0..frames) |i| {
            out[i] = decodeSample(data, i * frame_bytes, audio_format, bits) catch return Error.UnsupportedFormat;
            right[i] = decodeSample(data, i * frame_bytes + bytes_per, audio_format, bits) catch return Error.UnsupportedFormat;
        }
    }
    var fi: usize = if (right.len > 0) frames else 0;
    while (fi < frames) : (fi += 1) {
        var acc: f64 = 0;
        var ch: usize = 0;
        while (ch < channels) : (ch += 1) {
            const so = fi * frame_bytes + ch * bytes_per;
            acc += decodeSample(data, so, audio_format, bits) catch return Error.UnsupportedFormat;
        }
        out[fi] = acc / @as(f64, @floatFromInt(channels));
    }

    return .{
        .data = out,
        .sample_rate = @floatFromInt(sample_rate),
        .root_key = root_key,
        .loop_start = @min(loop_start, frames),
        .loop_end = @min(loop_end, frames),
        .frame_size = frame_size,
        .levels_kept = levels_kept,
        .right = right,
    };
}

fn decodeSample(d: []const u8, o: usize, fmt: u16, bits: u16) Error!f64 {
    // fmt 1 = PCM int, fmt 3 = IEEE float.
    if (fmt == 1) {
        switch (bits) {
            8 => return (@as(f64, @floatFromInt(d[o])) - 128.0) / 128.0, // 8-bit is unsigned
            16 => {
                const v: i16 = @bitCast(rdU16(d, o));
                return @as(f64, @floatFromInt(v)) / 32768.0;
            },
            24 => {
                const u: u32 = @as(u32, d[o]) | (@as(u32, d[o + 1]) << 8) | (@as(u32, d[o + 2]) << 16);
                const v: i32 = if (u & 0x800000 != 0) @as(i32, @bitCast(u | 0xFF000000)) else @intCast(u);
                return @as(f64, @floatFromInt(v)) / 8388608.0;
            },
            32 => {
                const v: i32 = @bitCast(rdU32(d, o));
                return @as(f64, @floatFromInt(v)) / 2147483648.0;
            },
            else => return Error.UnsupportedFormat,
        }
    } else if (fmt == 3) {
        switch (bits) {
            32 => return @as(f64, @as(f32, @bitCast(rdU32(d, o)))),
            64 => {
                var word: u64 = 0;
                inline for (0..8) |k| word |= @as(u64, d[o + k]) << (8 * k);
                return @bitCast(word);
            },
            else => return Error.UnsupportedFormat,
        }
    }
    return Error.UnsupportedFormat;
}

// ── 32-bit float stereo encoder (bounces) ──────────────────────────────
//
// Interleaved L R L R… f32 into a WAVE_FORMAT_IEEE_FLOAT stereo WAV, as is:
// no clamping, so a bounce that peaks over full scale before the master
// keeps its peaks (docs/27 §The new track and the originals).
pub fn encodeStereoF32(alloc: std.mem.Allocator, interleaved: []const f32, sample_rate: u32) Error![]u8 {
    const block_align: u32 = 2 * 4;
    const data_len: usize = interleaved.len * 4;
    const buf = try alloc.alloc(u8, 44 + data_len);
    errdefer alloc.free(buf);
    @memcpy(buf[0..4], "RIFF");
    writeU32(buf, 4, @intCast(36 + data_len));
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    writeU32(buf, 16, 16);
    writeU16(buf, 20, 3); // IEEE float
    writeU16(buf, 22, 2);
    writeU32(buf, 24, sample_rate);
    writeU32(buf, 28, sample_rate * block_align);
    writeU16(buf, 32, @intCast(block_align));
    writeU16(buf, 34, 32);
    @memcpy(buf[36..40], "data");
    writeU32(buf, 40, @intCast(data_len));
    for (interleaved, 0..) |x, k| writeU32(buf, 44 + k * 4, @bitCast(x));
    return buf;
}

// ── 24-bit PCM stereo encoder (project bounce) ─────────────────────────
//
// Encode interleaved L R L R… f32 samples in [-1, 1] into a standard
// 44-byte-header 24-bit PCM stereo WAV. Returns an owned byte buffer; the
// caller writes it to disk (e.g. via document.writeFile, which uses the
// codebase's libc IO convention). Samples are hard-clamped to [-1, 1] and
// rounded to signed 24-bit.
pub fn encodeStereo24(alloc: std.mem.Allocator, interleaved: []const f32, sample_rate: u32) Error![]u8 {
    const channels: u32 = 2;
    const bytes_per_sample: u32 = 3; // 24-bit
    const block_align: u32 = channels * bytes_per_sample; // 6
    const byte_rate: u32 = sample_rate * block_align;
    const data_len: usize = interleaved.len * bytes_per_sample;

    const buf = try alloc.alloc(u8, 44 + data_len);
    errdefer alloc.free(buf);

    @memcpy(buf[0..4], "RIFF");
    writeU32(buf, 4, @intCast(36 + data_len));
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    writeU32(buf, 16, 16);
    writeU16(buf, 20, 1); // PCM
    writeU16(buf, 22, @intCast(channels));
    writeU32(buf, 24, sample_rate);
    writeU32(buf, 28, byte_rate);
    writeU16(buf, 32, @intCast(block_align));
    writeU16(buf, 34, 24); // bits per sample
    @memcpy(buf[36..40], "data");
    writeU32(buf, 40, @intCast(data_len));

    var o: usize = 44;
    for (interleaved) |s| {
        const clamped = std.math.clamp(s, -1.0, 1.0);
        var v: i32 = @intFromFloat(@round(clamped * 8_388_607.0));
        if (v > 8_388_607) v = 8_388_607;
        if (v < -8_388_608) v = -8_388_608;
        const u: u32 = @bitCast(v);
        buf[o] = @truncate(u);
        buf[o + 1] = @truncate(u >> 8);
        buf[o + 2] = @truncate(u >> 16);
        o += 3;
    }
    return buf;
}

// ── tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeU32(b: []u8, o: usize, v: u32) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
    b[o + 2] = @truncate(v >> 16);
    b[o + 3] = @truncate(v >> 24);
}
fn writeU16(b: []u8, o: usize, v: u16) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
}

test "parse 16-bit mono PCM" {
    const n = 4;
    var buf: [44 + n * 2]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    writeU32(&buf, 4, @intCast(buf.len - 8));
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    writeU32(&buf, 16, 16);
    writeU16(&buf, 20, 1); // PCM
    writeU16(&buf, 22, 1); // mono
    writeU32(&buf, 24, 48000);
    writeU32(&buf, 28, 96000);
    writeU16(&buf, 32, 2);
    writeU16(&buf, 34, 16);
    @memcpy(buf[36..40], "data");
    writeU32(&buf, 40, n * 2);
    writeU16(&buf, 44, @bitCast(@as(i16, 16384))); // 0.5
    writeU16(&buf, 46, @bitCast(@as(i16, -16384))); // -0.5
    writeU16(&buf, 48, @bitCast(@as(i16, 32767))); // ~1.0
    writeU16(&buf, 50, @bitCast(@as(i16, 0)));

    var s = try parse(testing.allocator, &buf);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 48000), s.sample_rate);
    try testing.expectEqual(@as(usize, 4), s.data.len);
    try testing.expectApproxEqAbs(@as(f64, 0.5), s.data[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, -0.5), s.data[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 0.0), s.data[3], 1e-9);
}

test "salvages an unfinalized take (data size left at 0 -> runs to EOF)" {
    // A streaming recorder that never patched its header: float32 mono, the
    // data chunk size still 0. The loader should read to end of file.
    const n = 3;
    var buf: [44 + n * 4]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    writeU32(&buf, 4, 0); // RIFF size never patched
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    writeU32(&buf, 16, 16);
    writeU16(&buf, 20, 3); // IEEE float
    writeU16(&buf, 22, 1); // mono
    writeU32(&buf, 24, 48000);
    writeU32(&buf, 28, 192000);
    writeU16(&buf, 32, 4);
    writeU16(&buf, 34, 32);
    @memcpy(buf[36..40], "data");
    writeU32(&buf, 40, 0); // data size never patched
    writeU32(&buf, 44, @bitCast(@as(f32, 0.25)));
    writeU32(&buf, 48, @bitCast(@as(f32, -0.5)));
    writeU32(&buf, 52, @bitCast(@as(f32, 1.0)));

    var s = try parse(testing.allocator, &buf);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), s.data.len);
    try testing.expectApproxEqAbs(@as(f64, 0.25), s.data[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -0.5), s.data[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), s.data[2], 1e-6);
}

test "parse stereo folds to mono" {
    const frames = 3;
    var buf: [44 + frames * 4]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    writeU32(&buf, 4, @intCast(buf.len - 8));
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    writeU32(&buf, 16, 16);
    writeU16(&buf, 20, 1);
    writeU16(&buf, 22, 2); // stereo
    writeU32(&buf, 24, 44100);
    writeU32(&buf, 28, 176400);
    writeU16(&buf, 32, 4);
    writeU16(&buf, 34, 16);
    @memcpy(buf[36..40], "data");
    writeU32(&buf, 40, frames * 4);
    // L=1.0 R=0.0 -> 0.5 ; L=-0.5 R=0.5 -> 0 ; L=0 R=0 -> 0
    writeU16(&buf, 44, @bitCast(@as(i16, 32767)));
    writeU16(&buf, 46, @bitCast(@as(i16, 0)));
    writeU16(&buf, 48, @bitCast(@as(i16, -16384)));
    writeU16(&buf, 50, @bitCast(@as(i16, 16384)));
    writeU16(&buf, 52, @bitCast(@as(i16, 0)));
    writeU16(&buf, 54, @bitCast(@as(i16, 0)));

    var s = try parse(testing.allocator, &buf);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 44100), s.sample_rate);
    try testing.expectEqual(@as(usize, 3), s.data.len);
    try testing.expectApproxEqAbs(@as(f64, 0.5), s.data[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 0.0), s.data[1], 1e-4);
}

test "rejects non-RIFF" {
    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], "JUNK");
    try testing.expectError(Error.NotRiffWave, parse(testing.allocator, &buf));
}

test "encodeStereo24 round-trips through parse" {
    // Two frames: (0.5, -0.5) folds to 0.0; (1.0, 0.0) folds to 0.5.
    const interleaved = [_]f32{ 0.5, -0.5, 1.0, 0.0 };
    const bytes = try encodeStereo24(testing.allocator, &interleaved, 48_000);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "RIFF", bytes[0..4]);
    try testing.expectEqualSlices(u8, "WAVE", bytes[8..12]);
    try testing.expectEqual(@as(u16, 24), rdU16(bytes, 34));
    try testing.expectEqual(@as(usize, 44 + 4 * 3), bytes.len);

    var s = try parse(testing.allocator, bytes);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 48_000), s.sample_rate);
    try testing.expectEqual(@as(usize, 2), s.data.len);
    try testing.expectApproxEqAbs(@as(f64, 0.0), s.data[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 0.5), s.data[1], 1e-4);
}

test "encodeStereoF32 round-trips through a stereo parse, over full scale too" {
    const interleaved = [_]f32{ 0.25, -0.5, 1.5, 0.0, -2.0, 0.125 };
    const bytes = try encodeStereoF32(testing.allocator, &interleaved, 48_000);
    defer testing.allocator.free(bytes);
    var s = try parseAs(testing.allocator, bytes, true);
    defer s.deinit(testing.allocator);
    try testing.expect(s.isStereo());
    try testing.expectEqual(@as(usize, 3), s.data.len);
    try testing.expectEqual(@as(f64, 0.25), s.data[0]);
    try testing.expectEqual(@as(f64, -0.5), s.right[0]);
    try testing.expectEqual(@as(f64, 1.5), s.data[1]);
    try testing.expectEqual(@as(f64, -2.0), s.data[2]);
    try testing.expectEqual(@as(f64, 0.125), s.right[2]);
    // A plain load still folds it.
    var m = try parse(testing.allocator, bytes);
    defer m.deinit(testing.allocator);
    try testing.expect(!m.isStereo());
    try testing.expectApproxEqAbs(@as(f64, -0.125), m.data[0], 1e-9);
}

test "loads a FLAC: the factory kalimba's first sample" {
    var s = try load(std.testing.allocator, "machines/sampler/assets/vcsl/kalimba/001-Mbira6_Normal_MainSpirit_B2_k8_vl3_rr2.flac");
    defer s.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 44100), s.sample_rate);
    try std.testing.expect(s.data.len > 1000);
    var peak: f64 = 0;
    for (s.data) |x| peak = @max(peak, @abs(x));
    try std.testing.expect(peak > 0.01 and peak <= 1.0);
}
