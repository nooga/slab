//! MP3 export (docs/27 §Format): LAME, linked statically (libmp3lame.a, LGPL),
//! so an installed Slab needs nothing from Homebrew. The stream is a leading
//! ID3v2 tag from export.zig, then LAME's frames with the Xing/Info frame
//! rewritten at the start once the length is known (players use it for the
//! duration and the encoder delay, so a loop plays gapless).

const std = @import("std");

const Lame = opaque {};
extern fn lame_init() ?*Lame;
extern fn lame_close(g: *Lame) c_int;
extern fn lame_set_in_samplerate(g: *Lame, rate: c_int) c_int;
extern fn lame_set_num_channels(g: *Lame, n: c_int) c_int;
extern fn lame_set_mode(g: *Lame, mode: c_int) c_int;
extern fn lame_set_brate(g: *Lame, kbps: c_int) c_int;
extern fn lame_set_VBR(g: *Lame, mode: c_int) c_int;
extern fn lame_set_quality(g: *Lame, q: c_int) c_int;
extern fn lame_set_write_id3tag_automatic(g: *Lame, on: c_int) void;
extern fn lame_init_params(g: *Lame) c_int;
extern fn lame_encode_buffer_interleaved_ieee_float(g: *Lame, pcm: [*]const f32, n: c_int, out: [*]u8, size: c_int) c_int;
extern fn lame_encode_buffer_ieee_float(g: *Lame, l: [*]const f32, r: ?[*]const f32, n: c_int, out: [*]u8, size: c_int) c_int;
extern fn lame_encode_flush(g: *Lame, out: [*]u8, size: c_int) c_int;
extern fn lame_get_lametag_frame(g: *const Lame, out: [*]u8, size: usize) usize;

/// The highest rate MP3 holds.
pub const MAX_RATE: u32 = 48_000;

const MODE_MONO = 3;
const MODE_JOINT = 1;
/// Frames fed per call: LAME's output bound is 1.25 n + 7200 bytes.
const CHUNK = 1 << 15;

/// `samples` interleaved by `channels` (1 or 2), full scale ±1, as an MP3
/// stream at `kbps` (constant bitrate). `rate` must be at most `MAX_RATE`.
pub fn encode(alloc: std.mem.Allocator, samples: []const f32, channels: u8, rate: u32, kbps: u16) ![]u8 {
    if (rate > MAX_RATE or channels < 1 or channels > 2) return error.UnsupportedFormat;
    const g = lame_init() orelse return error.OutOfMemory;
    defer _ = lame_close(g);
    _ = lame_set_in_samplerate(g, @intCast(rate));
    _ = lame_set_num_channels(g, channels);
    _ = lame_set_mode(g, if (channels == 1) MODE_MONO else MODE_JOINT);
    _ = lame_set_VBR(g, 0);
    _ = lame_set_brate(g, kbps);
    _ = lame_set_quality(g, 2);
    // The ID3 tag is ours (export.zig), written before the audio.
    lame_set_write_id3tag_automatic(g, 0);
    if (lame_init_params(g) < 0) return error.EncodeFailed;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const ch: usize = channels;
    const frames = samples.len / ch;
    var buf = try alloc.alloc(u8, CHUNK * 5 / 4 + 7200);
    defer alloc.free(buf);
    var at: usize = 0;
    while (at < frames) {
        const n = @min(CHUNK, frames - at);
        const part = samples[at * ch ..][0 .. n * ch];
        const got = if (ch == 2)
            lame_encode_buffer_interleaved_ieee_float(g, part.ptr, @intCast(n), buf.ptr, @intCast(buf.len))
        else
            lame_encode_buffer_ieee_float(g, part.ptr, null, @intCast(n), buf.ptr, @intCast(buf.len));
        if (got < 0) return error.EncodeFailed;
        try out.appendSlice(alloc, buf[0..@intCast(got)]);
        at += n;
    }
    const tail = lame_encode_flush(g, buf.ptr, @intCast(buf.len));
    if (tail < 0) return error.EncodeFailed;
    try out.appendSlice(alloc, buf[0..@intCast(tail)]);

    // The placeholder frame LAME left first becomes the Xing/Info frame.
    var tag: [2880]u8 = undefined;
    const tn = lame_get_lametag_frame(g, &tag, tag.len);
    if (tn > 0 and tn <= tag.len and tn <= out.items.len) @memcpy(out.items[0..tn], tag[0..tn]);
    return out.toOwnedSlice(alloc);
}

test "a second of stereo comes out as MP3 frames of about the right size" {
    const alloc = std.testing.allocator;
    const n = 44_100;
    const pcm = try alloc.alloc(f32, n * 2);
    defer alloc.free(pcm);
    for (0..n) |i| {
        const v: f32 = 0.5 * @sin(2.0 * std.math.pi * 440.0 * @as(f32, @floatFromInt(i)) / 44_100.0);
        pcm[i * 2] = v;
        pcm[i * 2 + 1] = v;
    }
    const mp3 = try encode(alloc, pcm, 2, 44_100, 192);
    defer alloc.free(mp3);
    // 192 kbit/s is 24,000 bytes a second, plus the encoder's flush.
    try std.testing.expect(mp3.len > 22_000 and mp3.len < 32_000);
    // The first frame is the Info frame: a sync word and "Info" (CBR).
    try std.testing.expectEqual(@as(u8, 0xFF), mp3[0]);
    try std.testing.expect(std.mem.indexOf(u8, mp3[0..200], "Info") != null);
}

test "mono and rates above 48 kHz" {
    const alloc = std.testing.allocator;
    const pcm = try alloc.alloc(f32, 8000);
    defer alloc.free(pcm);
    @memset(pcm, 0.1);
    const m = try encode(alloc, pcm, 1, 32_000, 128);
    alloc.free(m);
    try std.testing.expectError(error.UnsupportedFormat, encode(alloc, pcm, 1, 96_000, 128));
}
