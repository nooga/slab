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
    /// 1 or 2: the samples handed to `writeFile` and `encode` are
    /// interleaved by this many channels.
    channels: u8 = 2,
    /// Tags (docs/27 §Names and metadata): WAV's LIST/INFO and AIFF's
    /// NAME/AUTH/ANNO, plus an ID3 chunk in both; FLAC's Vorbis comments;
    /// the .m4a's iTunes atoms. Empty: none.
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    year: []const u8 = "",
    comment: []const u8 = "",
    bpm: f64 = 0,
    /// WAV only (docs/28 §Locators and sections): cue points (the
    /// locators and section starts in the file, a `cue ` chunk named by
    /// `adtl` labels) and the `acid` chunk that tells a loop's tempo and
    /// length to the apps that sync loops.
    cues: []const Cue = &.{},
    acid: ?Acid = null,

    fn hasTags(f: Format) bool {
        return f.title.len > 0 or f.artist.len > 0 or f.album.len > 0 or f.year.len > 0 or f.comment.len > 0 or f.bpm > 0;
    }
};

pub const Cue = struct {
    /// Frames from the file's start, at its rate.
    frame: u32,
    name: []const u8,
};

pub const Acid = struct {
    beats: u32,
    num: u16 = 4,
    den: u16 = 4,
    bpm: f32,
};

extern fn slab_write_m4a(path: [*:0]const u8, ints: ?[*]const c_int, floats: ?[*]const f32, frames: c_ulong, channels: c_int, rate: f64, alac: c_int, bits: c_int, bitrate: c_int) c_int;

/// Write `samples` (interleaved by `f.channels`) to `path` in format `f`.
pub fn writeFile(alloc: std.mem.Allocator, path: []const u8, samples: []const f32, f: Format) !void {
    if (f.container == .alac or f.container == .aac) {
        const z = try alloc.dupeZ(u8, path);
        defer alloc.free(z);
        const ch: usize = f.channels;
        const frames = samples.len / ch;
        var st: c_int = 0;
        if (f.container == .alac) {
            var g = f;
            if (g.bits == .float32) g.bits = .pcm24;
            const ints = try alloc.alloc(c_int, samples.len);
            defer alloc.free(ints);
            var q = Quantizer.init(g);
            for (ints, samples) |*o, x| o.* = q.next(x);
            st = slab_write_m4a(z.ptr, ints.ptr, null, frames, @intCast(ch), @floatFromInt(f.sample_rate), 1, if (g.bits == .pcm16) 16 else 24, 0);
        } else {
            st = slab_write_m4a(z.ptr, null, samples.ptr, frames, @intCast(ch), @floatFromInt(f.sample_rate), 0, 0, @as(c_int, f.aac_kbps) * 1000);
        }
        if (st != 0) {
            std.log.err("m4a write failed: OSStatus {d}", .{st});
            return error.EncodeFailed;
        }
        if (f.hasTags()) {
            const doc = @import("document.zig");
            const bytes = try doc.readFile(alloc, path);
            defer alloc.free(bytes);
            if (try tagM4a(alloc, bytes, f)) |tagged| {
                defer alloc.free(tagged);
                try doc.writeFile(alloc, path, tagged);
            } else std.log.warn("{s}: no room for tags", .{path});
        }
        return;
    }
    const bytes = try encode(alloc, samples, f);
    defer alloc.free(bytes);
    try @import("document.zig").writeFile(alloc, path, bytes);
}

/// Encode `samples` (interleaved by `f.channels`) as a file image. PCM is
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
        var tags: [6][2][]const u8 = undefined;
        var nt: usize = 0;
        var bpm_buf: [16]u8 = undefined;
        const fields = [_][2][]const u8{
            .{ "TITLE", f.title },
            .{ "ARTIST", f.artist },
            .{ "ALBUM", f.album },
            .{ "DATE", f.year },
            .{ "COMMENT", f.comment },
            .{ "BPM", if (f.bpm > 0) bpmText(&bpm_buf, f.bpm) else "" },
        };
        for (fields) |kv| if (kv[1].len > 0) {
            tags[nt] = kv;
            nt += 1;
        };
        return flac.encode(alloc, ints, .{
            .sample_rate = g.sample_rate,
            .channels = @intCast(f.channels),
            .bits = if (g.bits == .pcm16) 16 else 24,
            .level = g.flac_level,
            .tags = tags[0..nt],
        });
    }
    const nb = f.bits.bytes();
    const ch: u32 = f.channels;
    const data_len = samples.len * nb;
    const frames: u32 = @intCast(samples.len / ch);
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
            le16(&out, @intCast(ch));
            le32(&out, f.sample_rate);
            le32(&out, f.sample_rate * ch * nb);
            le16(&out, @intCast(ch * nb));
            le16(&out, @intCast(nb * 8));
            out.appendSliceAssumeCapacity("data");
            le32(&out, @intCast(data_len));
            writeSamples(&out, samples, f, .little);
            if (data_len & 1 != 0) try out.append(alloc, 0);
            // LIST/INFO and ID3 after the data; the RIFF size grows to
            // cover them.
            if (f.hasTags()) {
                const at = out.items.len;
                try out.appendSlice(alloc, "LIST\x00\x00\x00\x00INFO");
                if (f.title.len > 0) try infoChunk(alloc, &out, "INAM", f.title);
                if (f.artist.len > 0) try infoChunk(alloc, &out, "IART", f.artist);
                if (f.album.len > 0) try infoChunk(alloc, &out, "IPRD", f.album);
                if (f.year.len > 0) try infoChunk(alloc, &out, "ICRD", f.year);
                if (f.comment.len > 0) try infoChunk(alloc, &out, "ICMT", f.comment);
                try infoChunk(alloc, &out, "ISFT", "Slab");
                std.mem.writeInt(u32, out.items[at + 4 ..][0..4], @intCast(out.items.len - at - 8), .little);
                try id3Chunk(alloc, &out, "id3 ", f, .little);
            }
            try cueChunks(alloc, &out, f.cues);
            if (f.acid) |a| try acidChunk(alloc, &out, a);
            std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .little);
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
            be16(&out, @intCast(ch));
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
            if (f.title.len > 0) try textChunk(alloc, &out, "NAME", f.title, .big);
            if (f.artist.len > 0) try textChunk(alloc, &out, "AUTH", f.artist, .big);
            if (f.comment.len > 0) try textChunk(alloc, &out, "ANNO", f.comment, .big);
            if (f.hasTags()) try id3Chunk(alloc, &out, "ID3 ", f, .big);
            std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .big);
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

/// A `cue ` chunk with a point per cue and a LIST/adtl of their `labl`
/// names. Nothing when there are none.
fn cueChunks(alloc: std.mem.Allocator, out: *std.ArrayList(u8), cues: []const Cue) !void {
    if (cues.len == 0) return;
    var b: [4]u8 = undefined;
    try out.appendSlice(alloc, "cue ");
    std.mem.writeInt(u32, &b, @intCast(4 + 24 * cues.len), .little);
    try out.appendSlice(alloc, &b);
    std.mem.writeInt(u32, &b, @intCast(cues.len), .little);
    try out.appendSlice(alloc, &b);
    for (cues, 1..) |cue, id| {
        for ([_]u32{ @intCast(id), cue.frame }) |v| {
            std.mem.writeInt(u32, &b, v, .little);
            try out.appendSlice(alloc, &b);
        }
        try out.appendSlice(alloc, "data");
        for ([_]u32{ 0, 0, cue.frame }) |v| {
            std.mem.writeInt(u32, &b, v, .little);
            try out.appendSlice(alloc, &b);
        }
    }
    const at = out.items.len;
    try out.appendSlice(alloc, "LIST\x00\x00\x00\x00adtl");
    for (cues, 1..) |cue, id| {
        try out.appendSlice(alloc, "labl");
        std.mem.writeInt(u32, &b, @intCast(4 + cue.name.len + 1), .little);
        try out.appendSlice(alloc, &b);
        std.mem.writeInt(u32, &b, @intCast(id), .little);
        try out.appendSlice(alloc, &b);
        try out.appendSlice(alloc, cue.name);
        try out.append(alloc, 0);
        if ((cue.name.len + 1) & 1 != 0) try out.append(alloc, 0);
    }
    std.mem.writeInt(u32, out.items[at + 4 ..][0..4], @intCast(out.items.len - at - 8), .little);
}

/// The `acid` chunk: a loop (stretchable, not a one-shot), root C4, its
/// length in beats, meter and tempo.
fn acidChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), a: Acid) !void {
    var c: [32]u8 = undefined;
    @memcpy(c[0..4], "acid");
    std.mem.writeInt(u32, c[4..8], 24, .little);
    std.mem.writeInt(u32, c[8..12], 0x04, .little); // stretch
    std.mem.writeInt(u16, c[12..14], 60, .little); // root note
    std.mem.writeInt(u16, c[14..16], 0x8000, .little);
    std.mem.writeInt(u32, c[16..20], 0, .little);
    std.mem.writeInt(u32, c[20..24], a.beats, .little);
    std.mem.writeInt(u16, c[24..26], a.den, .little);
    std.mem.writeInt(u16, c[26..28], a.num, .little);
    std.mem.writeInt(u32, c[28..32], @bitCast(a.bpm), .little);
    try out.appendSlice(alloc, &c);
}

/// A RIFF INFO entry: the text NUL-terminated, padded to even.
fn infoChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: []const u8, text: []const u8) !void {
    try out.appendSlice(alloc, id);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(text.len + 1), .little);
    try out.appendSlice(alloc, &b);
    try out.appendSlice(alloc, text);
    try out.append(alloc, 0);
    if ((text.len + 1) & 1 != 0) try out.append(alloc, 0);
}

/// `m4a` with iTunes tags (title, artist, album, year, comment, tempo,
/// encoder) added to its moov/udta/meta/ilst. AudioToolbox writes the
/// moov first and pads it with a `free` atom before the audio, so the
/// tags take that room: the audio doesn't move and no chunk offset
/// changes. Null when the file isn't laid out that way.
pub fn tagM4a(alloc: std.mem.Allocator, m4a: []const u8, f: Format) !?[]u8 {
    var items: std.ArrayList(u8) = .empty;
    defer items.deinit(alloc);
    const texts = [_][2][]const u8{
        .{ "\xa9nam", f.title },
        .{ "\xa9ART", f.artist },
        .{ "\xa9alb", f.album },
        .{ "\xa9day", f.year },
        .{ "\xa9cmt", f.comment },
        .{ "\xa9too", "Slab" },
    };
    for (texts) |kv| if (kv[1].len > 0) try m4aItem(alloc, &items, kv[0], 1, kv[1]);
    if (f.bpm > 0) {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intFromFloat(@min(@round(f.bpm), 65535)), .big);
        try m4aItem(alloc, &items, "tmpo", 21, &b);
    }
    const n = items.items.len;

    // The path to ilst; each box on it grows by n.
    const moov = findBox(m4a, 0, m4a.len, "moov") orelse return null;
    const udta = findBox(m4a, moov + 8, moov + boxSize(m4a, moov), "udta") orelse return null;
    const meta = findBox(m4a, udta + 8, udta + boxSize(m4a, udta), "meta") orelse return null;
    // meta is a full box: version and flags before its children.
    const ilst = findBox(m4a, meta + 12, meta + boxSize(m4a, meta), "ilst") orelse return null;
    const free = moov + boxSize(m4a, moov);
    if (free + 8 > m4a.len or !std.mem.eql(u8, m4a[free + 4 .. free + 8], "free")) return null;
    const free_size = boxSize(m4a, free);
    if (free_size < n + 8) return null;

    const ilst_end = ilst + boxSize(m4a, ilst);
    const out = try alloc.alloc(u8, m4a.len);
    @memcpy(out[0..ilst_end], m4a[0..ilst_end]);
    @memcpy(out[ilst_end..][0..n], items.items);
    @memcpy(out[ilst_end + n .. free + n], m4a[ilst_end..free]);
    for ([_]usize{ moov, udta, meta, ilst }) |at| std.mem.writeInt(u32, out[at..][0..4], @intCast(boxSize(m4a, at) + n), .big);
    std.mem.writeInt(u32, out[free + n ..][0..4], @intCast(free_size - n), .big);
    @memcpy(out[free + n + 4 ..][0..4], "free");
    @memset(out[free + n + 8 .. free + free_size], 0);
    @memcpy(out[free + free_size ..], m4a[free + free_size ..]);
    return out;
}

fn boxSize(b: []const u8, at: usize) usize {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

/// The first box of type `kind` among the boxes from `start` to `end`.
fn findBox(b: []const u8, start: usize, end: usize, kind: []const u8) ?usize {
    var at = start;
    while (at + 8 <= @min(end, b.len)) {
        const size = boxSize(b, at);
        if (size < 8) return null;
        if (std.mem.eql(u8, b[at + 4 .. at + 8], kind)) return at;
        at += size;
    }
    return null;
}

/// An ilst item: the box, then its `data` box (type, locale, value).
fn m4aItem(alloc: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, data_type: u32, value: []const u8) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(8 + 16 + value.len), .big);
    try out.appendSlice(alloc, &b);
    try out.appendSlice(alloc, kind);
    std.mem.writeInt(u32, &b, @intCast(16 + value.len), .big);
    try out.appendSlice(alloc, &b);
    try out.appendSlice(alloc, "data");
    std.mem.writeInt(u32, &b, data_type, .big);
    try out.appendSlice(alloc, &b);
    try out.appendSlice(alloc, &.{ 0, 0, 0, 0 });
    try out.appendSlice(alloc, value);
}

fn bpmText(buf: []u8, bpm: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{@round(bpm * 100) / 100}) catch "";
}

/// An ID3v2.3 tag in a chunk `id` (WAV's "id3 ", AIFF's "ID3 "), which
/// Music, Finder and most players read from both: title, artist, album,
/// year, BPM, comment and the encoder. Latin-1 text; other bytes as `?`.
fn id3Chunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: []const u8, f: Format, endian: std.builtin.Endian) !void {
    var tag: std.ArrayList(u8) = .empty;
    defer tag.deinit(alloc);
    var bpm_buf: [16]u8 = undefined;
    const frames = [_][2][]const u8{
        .{ "TIT2", f.title },
        .{ "TPE1", f.artist },
        .{ "TALB", f.album },
        .{ "TYER", f.year },
        .{ "TBPM", if (f.bpm > 0) std.fmt.bufPrint(&bpm_buf, "{d}", .{@round(f.bpm)}) catch "" else "" },
        .{ "TSSE", "Slab" },
    };
    for (frames) |fr| if (fr[1].len > 0) try id3Frame(alloc, &tag, fr[0], "", fr[1]);
    // COMM: encoding, language, an empty description, the text.
    if (f.comment.len > 0) try id3Frame(alloc, &tag, "COMM", "eng\x00", f.comment);
    const n = tag.items.len;
    var head = [10]u8{ 'I', 'D', '3', 3, 0, 0, 0, 0, 0, 0 };
    // Synchsafe size: 7 bits a byte.
    for (0..4) |k| head[6 + k] = @intCast((n >> @intCast(7 * (3 - k))) & 0x7f);
    try out.appendSlice(alloc, id);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(10 + n), endian);
    try out.appendSlice(alloc, &b);
    try out.appendSlice(alloc, &head);
    try out.appendSlice(alloc, tag.items);
    if ((10 + n) & 1 != 0) try out.append(alloc, 0);
}

fn id3Frame(alloc: std.mem.Allocator, tag: *std.ArrayList(u8), id: []const u8, prefix: []const u8, text: []const u8) !void {
    try tag.appendSlice(alloc, id);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(1 + prefix.len + text.len), .big);
    try tag.appendSlice(alloc, &b);
    try tag.appendSlice(alloc, &.{ 0, 0 }); // flags
    try tag.append(alloc, 0); // ISO-8859-1
    try tag.appendSlice(alloc, prefix);
    for (text) |ch| try tag.append(alloc, if (ch < 0x20 or ch >= 0x80) '?' else ch);
}

/// An IFF text chunk, padded to even.
fn textChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: []const u8, text: []const u8, endian: std.builtin.Endian) !void {
    try out.appendSlice(alloc, id);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(text.len), endian);
    try out.appendSlice(alloc, &b);
    try out.appendSlice(alloc, text);
    if (text.len & 1 != 0) try out.append(alloc, 0);
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
    /// The section's place in the song, 1-based, two digits.
    sn: usize = 0,
    /// YYYY-MM-DD.
    date: []const u8 = "",
    bpm: f64 = 0,
};

/// The template fields, as the name field's token menu offers them.
pub const NAME_TOKENS = [_][]const u8{ "{project}", "{track}", "{nn}", "{section}", "{sn}", "{date}", "{bpm}" };

/// Fill `template`'s `{project}`, `{track}`, `{nn}`, `{section}`, `{sn}`, `{date}`
/// and `{bpm}`. A `/` in the template makes a folder; in a field's value
/// it, like other characters a file name can't hold, becomes `-`.
pub fn fillName(buf: []u8, template: []const u8, f: NameFields) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var num_buf: [16]u8 = undefined;
    while (i < template.len) {
        var piece = template[i .. i + 1];
        var is_field = false;
        i += 1;
        if (piece[0] == '{') if (std.mem.indexOfScalarPos(u8, template, i, '}')) |j| {
            const key = template[i..j];
            const field: ?[]const u8 = if (std.mem.eql(u8, key, "project"))
                f.project
            else if (std.mem.eql(u8, key, "track"))
                f.track
            else if (std.mem.eql(u8, key, "section"))
                f.section
            else if (std.mem.eql(u8, key, "date"))
                f.date
            else if (std.mem.eql(u8, key, "bpm"))
                std.fmt.bufPrint(&num_buf, "{d}", .{@round(f.bpm * 100) / 100}) catch ""
            else if (std.mem.eql(u8, key, "nn"))
                std.fmt.bufPrint(&num_buf, "{d:0>2}", .{f.nn}) catch ""
            else if (std.mem.eql(u8, key, "sn"))
                std.fmt.bufPrint(&num_buf, "{d:0>2}", .{f.sn}) catch ""
            else
                null;
            if (field) |v| {
                piece = v;
                is_field = true;
                i = j + 1;
            }
        };
        for (piece) |ch| {
            if (n == buf.len) return buf[0..n];
            // No absolute paths and no empty folders.
            if (ch == '/' and !is_field and (n == 0 or buf[n - 1] == '/')) continue;
            buf[n] = if ((ch == '/' and is_field) or ch == ':' or ch < 0x20) '-' else ch;
            n += 1;
        }
    }
    // No ".." folders either.
    var k: usize = 0;
    while (std.mem.indexOfPos(u8, buf[0..n], k, "..")) |at| : (k = at + 2) {
        const starts = at == 0 or buf[at - 1] == '/';
        const ends = at + 2 == n or buf[at + 2] == '/';
        if (starts and ends) {
            buf[at] = '-';
            buf[at + 1] = '-';
        }
    }
    return buf[0..n];
}

/// A name template for one file per section (docs/28 §Export by
/// section): as it is when it names `{section}` or `{sn}`; else the mix
/// gets " {sn} {section}" after its name, and a stem a "{sn} {section}"
/// folder before its own.
pub fn sectionTemplate(buf: []u8, template: []const u8, stem: bool) []const u8 {
    if (std.mem.indexOf(u8, template, "{section}") != null or std.mem.indexOf(u8, template, "{sn}") != null) return template;
    if (!stem) return std.fmt.bufPrint(buf, "{s} {{sn}} {{section}}", .{template}) catch template;
    const cut = if (std.mem.lastIndexOfScalar(u8, template, '/')) |i| i + 1 else 0;
    return std.fmt.bufPrint(buf, "{s}{{sn}} {{section}}/{s}", .{ template[0..cut], template[cut..] }) catch template;
}

test "section templates" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("{project} {sn} {section}", sectionTemplate(&b, "{project}", false));
    try std.testing.expectEqualStrings("{project} stems/{sn} {section}/{nn} {track}", sectionTemplate(&b, "{project} stems/{nn} {track}", true));
    try std.testing.expectEqualStrings("{sn} {section}/{track}", sectionTemplate(&b, "{track}", true));
    try std.testing.expectEqualStrings("{section}-{track}", sectionTemplate(&b, "{section}-{track}", true));
    var nb: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Song 02 verse", fillName(&nb, sectionTemplate(&b, "{project}", false), .{ .project = "Song", .sn = 2, .section = "verse" }));
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;

/// Today's date as YYYY-MM-DD, local time.
pub fn today(buf: *[10]u8) []const u8 {
    const t = time(null);
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return "";
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)) }) catch "";
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

test "mono files: one channel in WAV, AIFF and FLAC" {
    const s = [_]f32{ 0.5, -0.25, 0.125, 0 };
    const w = try encode(testing.allocator, &s, .{ .channels = 1, .bits = .float32 });
    defer testing.allocator.free(w);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, w[22..24], .little));
    try testing.expectEqual(@as(usize, 44 + 16), w.len);
    var got = try wav.parse(testing.allocator, w);
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), got.data.len);
    try testing.expectApproxEqAbs(@as(f64, -0.25), got.data[1], 1e-6);
    const a = try encode(testing.allocator, &s, .{ .container = .aiff, .channels = 1, .bits = .pcm16, .dither = false });
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, a[20..22], .big));
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, a[22..26], .big));
    const f = try encode(testing.allocator, &s, .{ .container = .flac, .channels = 1, .bits = .pcm16 });
    defer testing.allocator.free(f);
    try testing.expectEqualSlices(u8, "fLaC", f[0..4]);
}

test "tags: INFO and ID3 in a WAV, Vorbis comments in a FLAC" {
    const s = [_]f32{ 0, 0 };
    const tags = Format{ .title = "Broken Glass", .artist = "nooga", .album = "Slabs", .year = "2026", .bpm = 124, .comment = "Slab 0.0.7" };
    var f = tags;
    const w = try encode(testing.allocator, &s, f);
    defer testing.allocator.free(w);
    try testing.expectEqual(@as(u32, @intCast(w.len - 8)), std.mem.readInt(u32, w[4..8], .little));
    for ([_][]const u8{ "IART", "IPRD", "ICRD", "id3 ", "ID3\x03", "TPE1", "TALB", "TYER", "TBPM", "COMM", "nooga" }) |want| {
        try testing.expect(std.mem.indexOf(u8, w, want) != null);
    }
    f.container = .aiff;
    const a = try encode(testing.allocator, &s, f);
    defer testing.allocator.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "AUTH") != null and std.mem.indexOf(u8, a, "ID3 ") != null);
    try testing.expectEqual(@as(u32, @intCast(a.len - 8)), std.mem.readInt(u32, a[4..8], .big));
    f.container = .flac;
    const fl = try encode(testing.allocator, &s, f);
    defer testing.allocator.free(fl);
    for ([_][]const u8{ "ARTIST=nooga", "ALBUM=Slabs", "DATE=2026", "BPM=124" }) |want| try testing.expect(std.mem.indexOf(u8, fl, want) != null);
}

test "tagM4a fills the ilst from the free room; the audio stays put" {
    const alloc = testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    const box = struct {
        fn put(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, size: u32) !void {
            var s4: [4]u8 = undefined;
            std.mem.writeInt(u32, &s4, size, .big);
            try out.appendSlice(a, &s4);
            try out.appendSlice(a, kind);
        }
    }.put;
    try box(alloc, &b, "ftyp", 8);
    try box(alloc, &b, "moov", 8 + 8 + 12 + 8);
    try box(alloc, &b, "udta", 8 + 12 + 8);
    try box(alloc, &b, "meta", 12 + 8);
    try b.appendSlice(alloc, &.{ 0, 0, 0, 0 });
    try box(alloc, &b, "ilst", 8);
    try box(alloc, &b, "free", 200);
    try b.appendNTimes(alloc, 0, 192);
    try box(alloc, &b, "mdat", 12);
    try b.appendSlice(alloc, "AUDI");
    const out = (try tagM4a(alloc, b.items, .{ .title = "Song", .artist = "nooga", .bpm = 124 })).?;
    defer alloc.free(out);
    try testing.expectEqual(b.items.len, out.len);
    try testing.expectEqualSlices(u8, "AUDI", out[out.len - 4 ..]);
    const moov = findBox(out, 0, out.len, "moov").?;
    const grown = boxSize(out, moov) - 36;
    try testing.expect(grown > 0);
    try testing.expectEqualSlices(u8, "free", out[moov + boxSize(out, moov) + 4 ..][0..4]);
    try testing.expectEqual(200 - grown, boxSize(out, moov + boxSize(out, moov)));
    try testing.expect(std.mem.indexOf(u8, out, "\xa9ARTnooga") == null); // inside a data box
    try testing.expect(std.mem.indexOf(u8, out, "nooga") != null and std.mem.indexOf(u8, out, "tmpo") != null);
    // No free atom to take: no tags.
    try testing.expect((try tagM4a(alloc, b.items[0 .. 8 + 36], .{ .title = "x" })) == null);
}

test "fillName fills the fields and keeps paths flat" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Song-03-Kick", fillName(&buf, "{project}-{nn}-{track}", .{ .project = "Song", .nn = 3, .track = "Kick" }));
    try testing.expectEqualStrings("Song - verse-a-b", fillName(&buf, "{project} - {section}", .{ .project = "Song", .section = "verse/a:b" }));
    try testing.expectEqualStrings("x{odd}", fillName(&buf, "x{odd}", .{}));
    // Folders from the template, not from a field; never absolute or up.
    try testing.expectEqualStrings("stems/03 Kick-Snare", fillName(&buf, "/stems//{nn} {track}", .{ .nn = 3, .track = "Kick/Snare" }));
    try testing.expectEqualStrings("--/x", fillName(&buf, "../x", .{}));
    try testing.expectEqualStrings("Song 124 2026-10-04", fillName(&buf, "{project} {bpm} {date}", .{ .project = "Song", .bpm = 124, .date = "2026-10-04" }));
}

test "WAV cue points and the acid chunk" {
    const alloc = std.testing.allocator;
    const x = [_]f32{0} ** 64;
    const bytes = try encode(alloc, &x, .{ .bits = .pcm16, .cues = &.{ .{ .frame = 0, .name = "intro" }, .{ .frame = 20, .name = "drop!" } }, .acid = .{ .beats = 16, .num = 7, .den = 8, .bpm = 140 } });
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(u32, @intCast(bytes.len - 8)), std.mem.readInt(u32, bytes[4..8], .little));
    // Walk the chunks.
    var at: usize = 12;
    var seen_cue = false;
    var seen_acid = false;
    var labels: usize = 0;
    while (at + 8 <= bytes.len) {
        const id = bytes[at..][0..4];
        const len = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const body = bytes[at + 8 ..][0..len];
        if (std.mem.eql(u8, id, "cue ")) {
            seen_cue = true;
            try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, body[0..4], .little));
            try std.testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, body[4 + 24 + 4 ..][0..4], .little));
        } else if (std.mem.eql(u8, id, "LIST") and std.mem.eql(u8, body[0..4], "adtl")) {
            labels = std.mem.count(u8, body, "labl");
            try std.testing.expect(std.mem.indexOf(u8, body, "drop!\x00") != null);
        } else if (std.mem.eql(u8, id, "acid")) {
            seen_acid = true;
            try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, body[12..16], .little));
            try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, body[16..18], .little));
            try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, body[18..20], .little));
            try std.testing.expectEqual(@as(f32, 140), @as(f32, @bitCast(std.mem.readInt(u32, body[20..24], .little))));
        }
        at += 8 + len + (len & 1);
    }
    try std.testing.expect(seen_cue and seen_acid);
    try std.testing.expectEqual(@as(usize, 2), labels);
}
