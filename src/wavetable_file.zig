//! Wavetable files the editor writes (docs/15 §Wavetable editor): mono
//! 32-bit float WAVs of 2048-sample frames with a Serum `clm ` chunk, so
//! Serum and other tools read the frame size. The chunk says "(slab
//! levels kept)", and slab then keeps the levels as drawn
//! (wav.Sample.levels_kept) instead of normalizing the table.
//!
//! A project saves its edited tables beside itself: `song.slab` keeps
//! them in `song.tables/`.

const std = @import("std");
const wte = @import("wavetable_edit.zig");

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern fn access(path: [*:0]const u8, mode: c_int) c_int;

const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

const CLM = "<!>2048 00000000 wavetable (slab levels kept)";
const RATE: u32 = 48_000;

/// The doc's frames as a WAV file.
pub fn encode(alloc: std.mem.Allocator, doc: *const wte.Doc) ![]u8 {
    const n = doc.count * wte.N;
    const clm_len = CLM.len + (CLM.len & 1);
    const data_len = n * 4;
    const total = 12 + (8 + 16) + (8 + clm_len) + (8 + data_len);
    const buf = try alloc.alloc(u8, total);
    @memcpy(buf[0..4], "RIFF");
    put32(buf, 4, @intCast(total - 8));
    @memcpy(buf[8..12], "WAVE");
    var o: usize = 12;
    @memcpy(buf[o..][0..4], "fmt ");
    put32(buf, o + 4, 16);
    put16(buf, o + 8, 3); // IEEE float
    put16(buf, o + 10, 1);
    put32(buf, o + 12, RATE);
    put32(buf, o + 16, RATE * 4);
    put16(buf, o + 20, 4);
    put16(buf, o + 22, 32);
    o += 24;
    @memcpy(buf[o..][0..4], "clm ");
    put32(buf, o + 4, @intCast(clm_len));
    @memcpy(buf[o + 8 ..][0..CLM.len], CLM);
    if (clm_len > CLM.len) buf[o + 8 + CLM.len] = 0;
    o += 8 + clm_len;
    @memcpy(buf[o..][0..4], "data");
    put32(buf, o + 4, @intCast(data_len));
    o += 8;
    for (doc.data[0..n]) |v| {
        put32(buf, o, @bitCast(v));
        o += 4;
    }
    return buf;
}

/// Write the doc to `path`; false if it can't.
pub fn save(alloc: std.mem.Allocator, doc: *const wte.Doc, path: []const u8) bool {
    const bytes = encode(alloc, doc) catch return false;
    defer alloc.free(bytes);
    var zb: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return false;
    const fd = open(z.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return false;
    defer _ = close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const w = write(fd, bytes[done..].ptr, bytes.len - done);
        if (w <= 0) return false;
        done += @intCast(w);
    }
    return true;
}

/// Where a project keeps its tables: `song.slab` → `song.tables`.
pub fn tablesDir(buf: []u8, project_path: []const u8) []const u8 {
    const stem = if (std.mem.endsWith(u8, project_path, ".slab")) project_path[0 .. project_path.len - 5] else project_path;
    return std.fmt.bufPrint(buf, "{s}.tables", .{stem}) catch "";
}

pub fn makeDir(path: []const u8) void {
    var zb: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return;
    _ = mkdir(z.ptr, 0o755); // EEXIST is fine
}

pub fn exists(path: []const u8) bool {
    var zb: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return false;
    return access(z.ptr, 0) == 0;
}

/// True when `path` is a file directly inside `dir`.
pub fn inDir(path: []const u8, dir: []const u8) bool {
    return dir.len > 0 and path.len > dir.len + 1 and std.mem.startsWith(u8, path, dir) and
        path[dir.len] == '/' and std.mem.indexOfScalar(u8, path[dir.len + 1 ..], '/') == null;
}

/// `<dir>/<stem>.wav`, or `<stem>-2.wav` and on, the first not taken.
pub fn freshPath(buf: []u8, dir: []const u8, stem: []const u8) []const u8 {
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const p = if (n == 1)
            std.fmt.bufPrint(buf, "{s}/{s}.wav", .{ dir, stem }) catch return ""
        else
            std.fmt.bufPrint(buf, "{s}/{s}-{d}.wav", .{ dir, stem, n }) catch return "";
        if (!exists(p)) return p;
    }
    return "";
}

/// A name for a file: lower case letters, digits and dashes.
pub fn slug(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var dash = false;
    for (s) |ch| {
        if (n == buf.len) break;
        if (std.ascii.isAlphanumeric(ch)) {
            if (dash and n > 0 and n < buf.len) {
                buf[n] = '-';
                n += 1;
            }
            if (n == buf.len) break;
            buf[n] = std.ascii.toLower(ch);
            n += 1;
            dash = false;
        } else dash = true;
    }
    return buf[0..n];
}

fn put32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}

fn put16(b: []u8, o: usize, v: u16) void {
    std.mem.writeInt(u16, b[o..][0..2], v, .little);
}

test "wavetable file: frames, frame size and drawn levels survive a round trip" {
    const wav = @import("wav.zig");
    const wavetable = @import("wavetable.zig");
    const alloc = std.testing.allocator;
    var d = try wte.Doc.init(alloc);
    defer d.deinit();
    d.resize(3);
    for (d.frame(1)) |*v| v.* *= 0.25;
    d.setShape(2, .saw);
    const bytes = try encode(alloc, &d);
    defer alloc.free(bytes);
    var s = try wav.parse(alloc, bytes);
    defer s.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2048), s.frame_size);
    try std.testing.expect(s.levels_kept);
    try std.testing.expectEqual(@as(usize, 3 * 2048), s.data.len);
    try std.testing.expectEqual(@as(f64, d.frameConst(1)[512]), s.data[2048 + 512]);
    var t = try wavetable.build(alloc, s.data, s.frame_size, !s.levels_kept);
    defer t.deinit(alloc);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), t.data[wavetable.STRIDE + 512], 1e-4);
}

test "wavetable file: names and places" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("songs/pml.tables", tablesDir(&b, "songs/pml.slab"));
    try std.testing.expect(inDir("songs/pml.tables/a.wav", "songs/pml.tables"));
    try std.testing.expect(!inDir("songs/pml.tables/x/a.wav", "songs/pml.tables"));
    try std.testing.expect(!inDir("other/a.wav", "songs/pml.tables"));
    try std.testing.expectEqualStrings("acid-bass-wt-a", slug(&b, "Acid Bass · wt-a"));
}
