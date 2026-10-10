//! Minimal RIFF/WAVE and AIFF loader → f64 mono. The asset arena's first
//! consumer (samplers, wavetables): load a file on the UI thread into host
//! memory, then inject a pointer + length into a machine's params so a
//! `dsp:` voice can read it with `p@64` / `f@i`. Read-only and shared
//! across voices.
//!
//! Supports PCM 8/16/24/32-bit and IEEE-float 32/64-bit, mono or multi-
//! channel (folded to mono by averaging); AIFF and AIFF-C the same
//! (big-endian or `sowt` PCM, `fl32`/`fl64` float), told apart from WAV by
//! their FORM header; and FLAC (a .flac path, decoded by miniaudio; the
//! factory sample sets ship as FLAC). The std.fs surface moved in zig
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

/// A file name this loader reads: WAV, AIFF/AIFF-C or FLAC. The browser
/// lists these as samples and keymap folders take them.
pub fn isAudioFile(name: []const u8) bool {
    const exts = [_][]const u8{ ".wav", ".flac", ".aif", ".aiff", ".aifc" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
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

/// Parse an in-memory RIFF/WAVE or AIFF image into f64 mono. Exposed for
/// tests.
pub fn parse(alloc: std.mem.Allocator, buf: []const u8) Error!Sample {
    return parseAs(alloc, buf, false);
}

fn parseAs(alloc: std.mem.Allocator, buf: []const u8, stereo: bool) Error!Sample {
    if (buf.len < 12) return Error.NotRiffWave;
    if (std.mem.eql(u8, buf[0..4], "FORM")) return parseAiff(alloc, buf, stereo);
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

    // fmt 1 = PCM int (8-bit unsigned), fmt 3 = IEEE float.
    const layout: Layout = switch (audio_format) {
        1 => switch (bits) {
            8, 16, 24, 32 => .{ .bytes = bits / 8, .unsigned8 = true },
            else => return Error.UnsupportedFormat,
        },
        3 => switch (bits) {
            32, 64 => .{ .float = true, .bytes = bits / 8 },
            else => return Error.UnsupportedFormat,
        },
        else => return Error.UnsupportedFormat,
    };
    var s = try decodeFrames(alloc, buf[data_off..][0..data_len], channels, layout, stereo);
    s.sample_rate = @floatFromInt(sample_rate);
    s.root_key = root_key;
    s.loop_start = @min(loop_start, s.data.len);
    s.loop_end = @min(loop_end, s.data.len);
    s.frame_size = frame_size;
    s.levels_kept = levels_kept;
    return s;
}

/// How a file stores one sample.
const Layout = struct {
    float: bool = false,
    /// 1–4 for integers (left-justified: a 12-bit AIFF sample sits in 2),
    /// 4 or 8 for float.
    bytes: usize,
    big: bool = false,
    /// WAV's 8-bit is unsigned, AIFF's signed.
    unsigned8: bool = false,
};

/// Interleaved frames to f64: mono (channels averaged), or the first two
/// channels apart with `stereo`. Sets `data` and `right` only.
fn decodeFrames(alloc: std.mem.Allocator, data: []const u8, channels: usize, l: Layout, stereo: bool) Error!Sample {
    const frame_bytes = l.bytes * channels;
    const frames = data.len / frame_bytes;
    if (frames == 0) return Error.Empty;
    if (frames > MAX_SAMPLES) return Error.TooLarge;

    const out = alloc.alloc(f64, frames) catch return Error.OutOfMemory;
    errdefer alloc.free(out);
    if (stereo and channels >= 2) {
        const right = alloc.alloc(f64, frames) catch return Error.OutOfMemory;
        for (0..frames) |i| {
            out[i] = decodeSample(data, i * frame_bytes, l);
            right[i] = decodeSample(data, i * frame_bytes + l.bytes, l);
        }
        return .{ .data = out, .right = right, .sample_rate = 0 };
    }
    for (0..frames) |i| {
        var acc: f64 = 0;
        for (0..channels) |ch| acc += decodeSample(data, i * frame_bytes + ch * l.bytes, l);
        out[i] = acc / @as(f64, @floatFromInt(channels));
    }
    return .{ .data = out, .sample_rate = 0 };
}

fn decodeSample(d: []const u8, o: usize, l: Layout) f64 {
    var word: u64 = 0;
    for (0..l.bytes) |k| {
        const b: u64 = d[o + if (l.big) l.bytes - 1 - k else k];
        word |= b << @intCast(8 * k);
    }
    if (l.float) {
        if (l.bytes == 4) return @as(f32, @bitCast(@as(u32, @truncate(word))));
        return @bitCast(word);
    }
    if (l.unsigned8 and l.bytes == 1) return (@as(f64, @floatFromInt(word)) - 128.0) / 128.0;
    // Sign-extend from the container's top bit, scale to ±1.
    const width: u6 = @intCast(8 * l.bytes);
    const v: i64 = @as(i64, @bitCast(word << (63 - width + 1))) >> (63 - width + 1);
    return @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(@as(i64, 1) << (width - 1)));
}

fn rdBe16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .big);
}
fn rdBe32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .big);
}

/// An 80-bit IEEE extended float (AIFF's sample rate).
fn extended80(b: []const u8) f64 {
    const exp: i32 = @as(i32, rdBe16(b, 0) & 0x7FFF);
    const mant = std.mem.readInt(u64, b[2..10], .big);
    if (exp == 0 or mant == 0) return 0;
    return std.math.ldexp(@as(f64, @floatFromInt(mant)), exp - 16383 - 63);
}

/// An AIFF or AIFF-C image: COMM says the format, SSND holds the frames
/// (big-endian), INST's base note is the root key and its sustain loop,
/// two MARK positions, the loop.
fn parseAiff(alloc: std.mem.Allocator, buf: []const u8, stereo: bool) Error!Sample {
    const aifc = std.mem.eql(u8, buf[8..12], "AIFC");
    if (!aifc and !std.mem.eql(u8, buf[8..12], "AIFF")) return Error.NotRiffWave;

    var channels: usize = 0;
    var frames: usize = 0;
    var bits: usize = 0;
    var rate: f64 = 0;
    var comp: [4]u8 = "NONE".*;
    var have_comm = false;
    var data_off: usize = 0;
    var data_len: usize = 0;
    var root_key: f64 = -1;
    var loop_ids: ?[2]u16 = null;
    var mark_off: usize = 0;
    var mark_len: usize = 0;

    var pos: usize = 12;
    while (pos + 8 <= buf.len) {
        const id = buf[pos .. pos + 4];
        const size: usize = rdBe32(buf, pos + 4);
        const body = pos + 8;
        if (std.mem.eql(u8, id, "COMM") and body + 18 <= buf.len) {
            channels = rdBe16(buf, body);
            frames = rdBe32(buf, body + 2);
            bits = rdBe16(buf, body + 6);
            rate = extended80(buf[body + 8 .. body + 18]);
            if (aifc and body + 22 <= buf.len) @memcpy(&comp, buf[body + 18 .. body + 22]);
            have_comm = true;
        } else if (std.mem.eql(u8, id, "SSND") and body + 8 <= buf.len) {
            data_off = body + 8 + rdBe32(buf, body);
            // A truncated file (or a size never patched) runs to EOF.
            const end = if (size < 8 or body + size > buf.len) buf.len else body + size;
            data_len = if (data_off < end) end - data_off else 0;
        } else if (std.mem.eql(u8, id, "INST") and body + 20 <= buf.len) {
            // baseNote, detune, low/high note and velocity, gain (2), then
            // the sustain loop: play mode, begin and end marker ids.
            const base = buf[body];
            if (base < 128) root_key = @floatFromInt(base);
            if (rdBe16(buf, body + 8) != 0) loop_ids = .{ rdBe16(buf, body + 10), rdBe16(buf, body + 12) };
        } else if (std.mem.eql(u8, id, "MARK")) {
            mark_off = body;
            mark_len = @min(size, buf.len -| body);
        }
        pos = body + size + (size & 1); // chunks are word-aligned
    }

    if (!have_comm) return Error.NoFmtChunk;
    if (data_off == 0 or data_len == 0) return Error.NoDataChunk;
    if (channels == 0 or rate <= 0 or bits == 0) return Error.UnsupportedFormat;

    const ieq = std.ascii.eqlIgnoreCase;
    const layout: Layout = if (ieq(&comp, "NONE") or ieq(&comp, "twos") or ieq(&comp, "sowt")) blk: {
        if (bits > 32) return Error.UnsupportedFormat;
        break :blk .{ .bytes = (bits + 7) / 8, .big = !ieq(&comp, "sowt") };
    } else if (ieq(&comp, "fl32")) .{ .float = true, .bytes = 4, .big = true } else if (ieq(&comp, "fl64")) .{ .float = true, .bytes = 8, .big = true } else return Error.UnsupportedFormat;

    // COMM's frame count bounds the data (SSND may be padded).
    const want = frames * layout.bytes * channels;
    var s = try decodeFrames(alloc, buf[data_off..][0..@min(data_len, want)], channels, layout, stereo);
    s.sample_rate = rate;
    s.root_key = root_key;
    if (loop_ids) |ids| {
        const a = markerPos(buf[mark_off..][0..mark_len], ids[0]);
        const b = markerPos(buf[mark_off..][0..mark_len], ids[1]);
        if (a != null and b != null and b.? > a.?) {
            // Markers sit between samples: the end is exclusive already.
            s.loop_start = @min(a.?, s.data.len);
            s.loop_end = @min(b.?, s.data.len);
        }
    }
    return s;
}

/// A MARK chunk's position for marker `id`: count (2), then per marker id
/// (2), position (4) and a pascal string padded to an even length.
fn markerPos(mark: []const u8, id: u16) ?usize {
    if (mark.len < 2) return null;
    const n = rdBe16(mark, 0);
    var o: usize = 2;
    for (0..n) |_| {
        if (o + 7 > mark.len) return null;
        const pstr: usize = 1 + @as(usize, mark[o + 6]);
        if (rdBe16(mark, o) == id) return rdBe32(mark, o + 2);
        o += 6 + pstr + (pstr & 1);
    }
    return null;
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

extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

fn writeTestFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = open(path.ptr, 0x601, @as(c_uint, 0o644)); // O_WRONLY | O_CREAT | O_TRUNC
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    if (write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
}

test "a FLAC from slab's encoder loads sample-exact: 16 and 24 bits, mono and stereo" {
    const flac = @import("flac.zig");
    const alloc = testing.allocator;
    const frames = flac.BLOCK + 777;
    inline for (.{ 16, 24 }) |bits| {
        inline for (.{ 1, 2 }) |ch| {
            const ints = try alloc.alloc(i32, frames * ch);
            defer alloc.free(ints);
            const full: f64 = @floatFromInt((@as(i32, 1) << (bits - 1)) - 1);
            for (0..frames) |i| {
                const t: f64 = @floatFromInt(i);
                ints[i * ch] = @intFromFloat(@round(0.9 * full * @sin(t * 0.013 + 0.0004 * t * t / 100)));
                if (ch == 2) ints[i * ch + 1] = @intFromFloat(@round(-0.4 * full * @sin(t * 0.031)));
            }
            const bytes = try flac.encode(alloc, ints, .{ .sample_rate = 32_000, .bits = bits, .channels = ch });
            defer alloc.free(bytes);
            var pb: [256]u8 = undefined;
            const path = try std.fmt.bufPrintZ(&pb, "/tmp/slab-wav-flac-{d}-{d}-{d}.flac", .{ std.c.getpid(), bits, ch });
            try writeTestFile(path, bytes);

            const scale: f64 = @floatFromInt(@as(i32, 1) << (bits - 1));
            var s = try loadStereo(alloc, path);
            defer s.deinit(alloc);
            try testing.expectEqual(@as(f64, 32_000), s.sample_rate);
            try testing.expectEqual(@as(usize, frames), s.data.len);
            try testing.expectEqual(ch == 2, s.isStereo());
            for (0..frames) |i| {
                try testing.expectEqual(@as(f64, @floatFromInt(ints[i * ch])) / scale, s.data[i]);
                if (ch == 2) try testing.expectEqual(@as(f64, @floatFromInt(ints[i * ch + 1])) / scale, s.right[i]);
            }
        }
    }
}

// The fixtures in src/testdata: a sweep written by Python's wave module,
// then `afconvert -f flac -d flac x.wav x.flac` (macOS; afconvert writes
// an empty file for anything shorter than its 4608-frame packet).
test "a FLAC from an external encoder (afconvert) matches its source WAV" {
    const alloc = testing.allocator;
    inline for (.{ .{ "src/testdata/sweep-s24-44k", true, 44_100 }, .{ "src/testdata/sweep-m16-22k", false, 22_050 } }) |f| {
        var w = try loadStereo(alloc, f[0] ++ ".wav");
        defer w.deinit(alloc);
        var c = try loadStereo(alloc, f[0] ++ ".flac");
        defer c.deinit(alloc);
        try testing.expectEqual(@as(f64, f[2]), c.sample_rate);
        try testing.expectEqual(f[1], c.isStereo());
        try testing.expectEqualSlices(f64, w.data, c.data);
        try testing.expectEqualSlices(f64, w.right, c.right);
    }
}

test "AIFF from slab's exporter loads like its WAV: 16, 24 and float, mono and stereo" {
    const export_mod = @import("export.zig");
    const alloc = testing.allocator;
    var s: [2 * 1001]f32 = undefined;
    for (&s, 0..) |*x, i| x.* = 0.8 * @sin(@as(f32, @floatFromInt(i)) * 0.07) - 0.1;
    inline for (.{ export_mod.Bits.pcm16, export_mod.Bits.pcm24, export_mod.Bits.float32 }) |bits| {
        inline for (.{ 1, 2 }) |ch| {
            const f: export_mod.Format = .{ .bits = bits, .channels = ch, .sample_rate = 44_100, .dither = false };
            var g = f;
            g.container = .aiff;
            const w = try export_mod.encode(alloc, &s, f);
            defer alloc.free(w);
            const a = try export_mod.encode(alloc, &s, g);
            defer alloc.free(a);
            var sw = try parseAs(alloc, w, true);
            defer sw.deinit(alloc);
            var sa = try parseAs(alloc, a, true);
            defer sa.deinit(alloc);
            try testing.expectEqual(@as(f64, 44_100), sa.sample_rate);
            try testing.expectEqual(ch == 2, sa.isStereo());
            try testing.expectEqualSlices(f64, sw.data, sa.data);
            try testing.expectEqualSlices(f64, sw.right, sa.right);
        }
    }
}

/// A hand-built AIFF-C: COMM with compression `comp`, SSND of `data`, and
/// optionally INST (base note 64, sustain loop markers 1→2) with MARK.
fn testAifc(alloc: std.mem.Allocator, channels: u16, bits: u16, comp: *const [4]u8, data: []const u8, loop: ?[2]u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const Be = struct {
        fn u16_(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .big);
            try o.appendSlice(a, &b);
        }
        fn u32_(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .big);
            try o.appendSlice(a, &b);
        }
    };
    const frame_bytes = channels * ((bits + 7) / 8);
    try out.appendSlice(alloc, "FORM\x00\x00\x00\x00AIFCCOMM");
    try Be.u32_(&out, alloc, 24);
    try Be.u16_(&out, alloc, channels);
    try Be.u32_(&out, alloc, @intCast(data.len / frame_bytes));
    try Be.u16_(&out, alloc, bits);
    try out.appendSlice(alloc, &.{ 0x40, 0x0D, 0xFA, 0, 0, 0, 0, 0, 0, 0 }); // 32000
    try out.appendSlice(alloc, comp);
    try out.appendSlice(alloc, &.{ 0, 0 });
    if (loop) |l| {
        // Names of 2 and 3 letters: the first string pads to even.
        try out.appendSlice(alloc, "MARK");
        try Be.u32_(&out, alloc, 2 + 10 + 10);
        try Be.u16_(&out, alloc, 2);
        try Be.u16_(&out, alloc, 1);
        try Be.u32_(&out, alloc, l[0]);
        try out.appendSlice(alloc, &.{ 2, 'a', 'b', 0 });
        try Be.u16_(&out, alloc, 2);
        try Be.u32_(&out, alloc, l[1]);
        try out.appendSlice(alloc, &.{ 3, 'e', 'n', 'd' });
        try out.appendSlice(alloc, "INST");
        try Be.u32_(&out, alloc, 20);
        try out.appendSlice(alloc, &.{ 64, 0, 0, 127, 1, 127, 0, 0 });
        try Be.u16_(&out, alloc, 1); // forward
        try Be.u16_(&out, alloc, 1);
        try Be.u16_(&out, alloc, 2);
        try out.appendSlice(alloc, &.{ 0, 0, 0, 0, 0, 0 }); // release loop off
    }
    try out.appendSlice(alloc, "SSND");
    try Be.u32_(&out, alloc, @intCast(8 + 4 + data.len));
    try Be.u32_(&out, alloc, 4); // offset: 4 bytes before the frames
    try Be.u32_(&out, alloc, 0);
    try out.appendSlice(alloc, &.{ 0xAA, 0xAA, 0xAA, 0xAA });
    try out.appendSlice(alloc, data);
    if (data.len & 1 != 0) try out.append(alloc, 0);
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .big);
    return out.toOwnedSlice(alloc);
}

test "AIFF-C sowt, signed 8-bit, 12-bit, and the sustain loop and base note" {
    const alloc = testing.allocator;
    // sowt: little-endian 16-bit stereo.
    const le = [_]u8{ 0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x00, 0x80 };
    const a = try testAifc(alloc, 2, 16, "sowt", &le, null);
    defer alloc.free(a);
    var sa = try parseAs(alloc, a, true);
    defer sa.deinit(alloc);
    try testing.expectEqual(@as(f64, 32_000), sa.sample_rate);
    try testing.expectEqualSlices(f64, &.{ 0.5, 32767.0 / 32768.0 }, sa.data);
    try testing.expectEqualSlices(f64, &.{ -0.5, -1.0 }, sa.right);
    try testing.expectEqual(@as(f64, -1), sa.root_key);

    // AIFF's 8-bit is signed; an odd SSND length is padded.
    const s8 = [_]u8{ 0x40, 0xC0, 0x80, 0x00, 0x7F };
    const b = try testAifc(alloc, 1, 8, "NONE", &s8, .{ 1, 4 });
    defer alloc.free(b);
    var sb = try parse(alloc, b);
    defer sb.deinit(alloc);
    try testing.expectEqualSlices(f64, &.{ 0.5, -0.5, -1.0, 0.0, 127.0 / 128.0 }, sb.data);
    try testing.expectEqual(@as(f64, 64), sb.root_key);
    try testing.expectEqual(@as(usize, 1), sb.loop_start);
    try testing.expectEqual(@as(usize, 4), sb.loop_end);

    // 12 bits, left-justified in two bytes.
    const s12 = [_]u8{ 0x7F, 0xF0, 0x80, 0x00, 0x08, 0x00 };
    const c = try testAifc(alloc, 1, 12, "NONE", &s12, null);
    defer alloc.free(c);
    var sc = try parse(alloc, c);
    defer sc.deinit(alloc);
    try testing.expectEqualSlices(f64, &.{ 2047.0 / 2048.0, -1.0, 1.0 / 16.0 }, sc.data);

    // Compressed AIFF-C isn't read.
    const d = try testAifc(alloc, 1, 16, "ima4", &le, null);
    defer alloc.free(d);
    try testing.expectError(Error.UnsupportedFormat, parse(alloc, d));
}

// Made from the WAV fixtures with `afconvert -f AIFF -d BEI24` and
// `afconvert -f AIFC -d BEF32` (afconvert adds a FLLR chunk and an SSND
// offset to page-align the frames).
test "AIFF and AIFF-C from an external encoder (afconvert) match their source WAVs" {
    const alloc = testing.allocator;
    inline for (.{ .{ "sweep-s24-44k.wav", "sweep-s24-44k.aif", 44_100 }, .{ "sweep-m16-22k.wav", "sweep-m16-22k-fl32.aifc", 22_050 } }) |f| {
        var w = try loadStereo(alloc, "src/testdata/" ++ f[0]);
        defer w.deinit(alloc);
        var a = try loadStereo(alloc, "src/testdata/" ++ f[1]);
        defer a.deinit(alloc);
        try testing.expectEqual(@as(f64, f[2]), a.sample_rate);
        try testing.expectEqualSlices(f64, w.data, a.data);
        try testing.expectEqualSlices(f64, w.right, a.right);
    }
}
