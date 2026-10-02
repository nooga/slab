//! Bitmap fonts from BDF (docs/06 §Type). BDF is plain text, so the
//! fonts are parsed at startup straight from the embedded files and their
//! glyphs rasterized into the atlas as white-with-alpha, tinted at draw.

const std = @import("std");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const Region = atlas_mod.Region;

pub const Glyph = struct {
    src: Region = .{},
    /// Offset of the bitmap's top-left from the pen position at the top
    /// of the line box.
    dx: i8 = 0,
    dy: i8 = 0,
    advance: u8 = 0,
    present: bool = false,
};

pub const Font = struct {
    glyphs: [256]Glyph = [_]Glyph{.{}} ** 256,
    ascent: i32 = 0,
    descent: i32 = 0,
    /// Nominal cell width (these are monospaced fonts).
    advance: i32 = 0,

    pub fn lineHeight(f: *const Font) i32 {
        return f.ascent + f.descent;
    }

    /// Table index for a codepoint: remapped punctuation, else '?' when
    /// the font lacks it.
    pub fn index(f: *const Font, cp_in: u21) u8 {
        const cp = remap(cp_in);
        if (cp < 256 and f.glyphs[cp].present) return @intCast(cp);
        return '?';
    }

    pub fn glyph(f: *const Font, cp: u21) *const Glyph {
        return &f.glyphs[f.index(cp)];
    }

    pub fn measure(f: *const Font, s: []const u8) i32 {
        var w: i32 = 0;
        var it = Utf8Iter{ .s = s };
        while (it.next()) |cp| w += f.glyph(cp).advance;
        return w;
    }
};

/// Lenient UTF-8 decoder: malformed bytes decode as '?', never fail.
pub const Utf8Iter = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Utf8Iter) ?u21 {
        if (it.i >= it.s.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch {
            it.i += 1;
            return '?';
        };
        if (it.i + n > it.s.len) {
            it.i = it.s.len;
            return '?';
        }
        const cp = std.unicode.utf8Decode(it.s[it.i .. it.i + n]) catch '?';
        it.i += n;
        return cp;
    }
};

pub const Error = error{ BadBdf, AtlasFull };

/// Parse a BDF font and rasterize its Latin-1 glyphs into the atlas.
pub fn loadBdf(a: *Atlas, src: []const u8) Error!Font {
    var f = Font{};
    var lines = std.mem.tokenizeAny(u8, src, "\r\n");

    var enc: i32 = -1;
    var dwidth: i32 = 0;
    var bbx = [4]i32{ 0, 0, 0, 0 };
    var rows: [32]u32 = undefined;
    var nrows: usize = 0;
    var in_bitmap = false;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (in_bitmap) {
            if (std.mem.eql(u8, line, "ENDCHAR")) {
                in_bitmap = false;
                if (enc >= 0 and enc < 256) {
                    try rasterGlyph(a, &f, @intCast(enc), dwidth, bbx, rows[0..nrows]);
                }
                enc = -1;
                continue;
            }
            if (nrows < rows.len) {
                rows[nrows] = std.fmt.parseInt(u32, line, 16) catch return error.BadBdf;
                // Left-align the row to bit 31 regardless of hex width.
                const bits: u5 = @intCast(line.len * 4);
                rows[nrows] <<= @intCast(32 - @as(u6, bits));
                nrows += 1;
            }
            continue;
        }
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const key = words.next() orelse continue;
        if (std.mem.eql(u8, key, "FONT_ASCENT")) {
            f.ascent = try int(words.next());
        } else if (std.mem.eql(u8, key, "FONT_DESCENT")) {
            f.descent = try int(words.next());
        } else if (std.mem.eql(u8, key, "FONTBOUNDINGBOX")) {
            f.advance = try int(words.next());
        } else if (std.mem.eql(u8, key, "ENCODING")) {
            enc = try int(words.next());
        } else if (std.mem.eql(u8, key, "DWIDTH")) {
            dwidth = try int(words.next());
        } else if (std.mem.eql(u8, key, "BBX")) {
            for (&bbx) |*v| v.* = try int(words.next());
        } else if (std.mem.eql(u8, key, "BITMAP")) {
            in_bitmap = true;
            nrows = 0;
        }
    }
    if (f.ascent == 0 or !f.glyphs['?'].present) return error.BadBdf;
    try synthesize(a, &f);
    return f;
}

/// Glyphs Tamzen lacks but UI text uses: drawn to the font's own cell
/// metrics so they sit on the same baseline. Only fills absent slots.
fn synthesize(a: *Atlas, f: *Font) Error!void {
    const w: i32 = f.advance;
    const h: i32 = f.lineHeight();
    // Reference rows from the font: the x-height band's middle, the cap
    // top, the baseline.
    const base = f.ascent - 1;
    const cap_top = @max(0, f.ascent - @divFloor(f.ascent * 7, 10));
    const mid = base - @divFloor(base - cap_top, 2);
    const Synth = struct { cp: u8, px: []const [2]i32 };
    var dot = [_][2]i32{.{ @divFloor(w - 1, 2) - 1, mid }};
    var dots3 = [_][2]i32{ .{ 0, base }, .{ @divFloor(w - 1, 2), base }, .{ w - 2, base } };
    var buf_dash: [16][2]i32 = undefined;
    var n_dash: usize = 0;
    var x: i32 = 1;
    while (x < w - 2 and n_dash < buf_dash.len) : (x += 1) {
        buf_dash[n_dash] = .{ x, mid };
        n_dash += 1;
    }
    var buf_pm: [32][2]i32 = undefined;
    var n_pm: usize = 0;
    const cx = @divFloor(w - 1, 2) - 1;
    x = 0;
    while (x < w - 1 and n_pm < buf_pm.len) : (x += 1) {
        buf_pm[n_pm] = .{ x, mid };
        n_pm += 1;
        buf_pm[n_pm] = .{ x, base };
        n_pm += 1;
    }
    var yy: i32 = mid - 2;
    while (yy <= mid + 2 and n_pm < buf_pm.len) : (yy += 1) {
        buf_pm[n_pm] = .{ cx, yy };
        n_pm += 1;
    }
    const list = [_]Synth{
        .{ .cp = 0xB7, .px = &dot }, // ·
        .{ .cp = 0x85, .px = &dots3 }, // … (mapped from U+2026 below)
        .{ .cp = 0x96, .px = buf_dash[0..n_dash] }, // – (from U+2013/U+2014)
        .{ .cp = 0xB1, .px = buf_pm[0..n_pm] }, // ±
    };
    for (list) |s| {
        if (f.glyphs[s.cp].present) continue;
        var g = Glyph{ .advance = @intCast(w), .present = true };
        g.src = try a.reserve(@intCast(w), @intCast(h));
        for (s.px) |p| a.put(g.src, p[0], p[1], .{ .r = 255, .g = 255, .b = 255 });
        f.glyphs[s.cp] = g;
    }
    // Key-cap symbols for menu shortcut hints, as pixel art sitting on the
    // baseline, centred in the cell.
    for (KEY_GLYPHS) |k| {
        if (f.glyphs[k.slot].present) continue;
        var g = Glyph{ .advance = @intCast(w), .present = true };
        g.src = try a.reserve(@intCast(w), @intCast(h));
        const rows: i32 = @intCast(k.rows.len);
        const y0 = base - rows + 1;
        for (k.rows, 0..) |row, ry| {
            const x0 = @divFloor(w - @as(i32, @intCast(row.len)), 2);
            for (row, 0..) |ch, rx| {
                if (ch != '#') continue;
                const px = x0 + @as(i32, @intCast(rx));
                const py = y0 + @as(i32, @intCast(ry));
                if (px >= 0 and px < w and py >= 0 and py < h) a.put(g.src, px, py, .{ .r = 255, .g = 255, .b = 255 });
            }
        }
        f.glyphs[k.slot] = g;
    }
}

const KeyGlyph = struct { cp: u21, slot: u8, rows: []const []const u8 };

/// Unicode key symbols mapped onto unused C1 slots.
const KEY_GLYPHS = [_]KeyGlyph{
    .{ .cp = 0x2318, .slot = 0x81, .rows = &.{ "##.##", "#####", ".#.#.", "#####", "##.##" } }, // ⌘
    .{ .cp = 0x21E7, .slot = 0x82, .rows = &.{ "..#..", ".#.#.", "#...#", "##.##", ".#.#.", ".###." } }, // ⇧
    .{ .cp = 0x2325, .slot = 0x83, .rows = &.{ "##.##", "..#..", "...#.", "....#" } }, // ⌥
    .{ .cp = 0x232B, .slot = 0x84, .rows = &.{ "..#..", ".##..", "#####", ".##..", "..#.." } }, // ⌫
    .{ .cp = 0x21A9, .slot = 0x86, .rows = &.{ "....#", "....#", ".#..#", "#####", ".#..." } }, // ↩
    .{ .cp = 0x2191, .slot = 0x87, .rows = &.{ "..#..", ".###.", "#.#.#", "..#..", "..#..", "..#.." } }, // ↑
    .{ .cp = 0x2193, .slot = 0x88, .rows = &.{ "..#..", "..#..", "..#..", "#.#.#", ".###.", "..#.." } }, // ↓
    .{ .cp = 0x2303, .slot = 0x89, .rows = &.{ "..#..", ".#.#.", "#...#" } }, // ⌃
    .{ .cp = 0x25B8, .slot = 0x8A, .rows = &.{ "#..", "##.", "###", "##.", "#.." } }, // ▸
    .{ .cp = 0x25BE, .slot = 0x8E, .rows = &.{ "#####", ".###.", "..#..", "....." } }, // ▾
    // Marks and arrows for labels; the empty last row lifts them to mid-height.
    .{ .cp = 0x2022, .slot = 0x8B, .rows = &.{ ".##.", "####", "####", ".##.", "...." } }, // •
    .{ .cp = 0x2190, .slot = 0x8C, .rows = &.{ "..#..", ".#...", "#####", ".#...", "..#..", "....." } }, // ←
    .{ .cp = 0x2192, .slot = 0x8D, .rows = &.{ "..#..", "...#.", "#####", "...#.", "..#..", "....." } }, // →
    .{ .cp = 0x2605, .slot = 0x8F, .rows = &.{ "..#..", "..#..", "#####", ".###.", ".#.#.", "#...#" } }, // ★
    .{ .cp = 0x25B6, .slot = 0x90, .rows = &.{ "#...", "##..", "###.", "####", "###.", "##..", "#..." } }, // ▶
    .{ .cp = 0x25A0, .slot = 0x91, .rows = &.{ "#####", "#####", "#####", "#####", "#####" } }, // ■
    .{ .cp = 0x2713, .slot = 0x92, .rows = &.{ "....#", "...#.", "#.#..", ".#...", "....." } }, // ✓
};

/// Map a few common non-Latin-1 punctuation codepoints onto the
/// synthesized slots.
fn remap(cp: u21) u21 {
    return switch (cp) {
        0x2026 => 0x85,
        0x2013, 0x2014, 0x2212 => 0x96,
        else => {
            for (KEY_GLYPHS) |k| if (k.cp == cp) return k.slot;
            return cp;
        },
    };
}

fn int(w: ?[]const u8) Error!i32 {
    return std.fmt.parseInt(i32, w orelse return error.BadBdf, 10) catch error.BadBdf;
}

fn rasterGlyph(a: *Atlas, f: *Font, cp: u8, dwidth: i32, bbx: [4]i32, rows: []const u32) Error!void {
    const w: u16 = @intCast(@max(0, bbx[0]));
    const h: u16 = @intCast(@max(0, bbx[1]));
    var g = Glyph{
        .advance = @intCast(std.math.clamp(dwidth, 0, 255)),
        .dx = @intCast(bbx[2]),
        // BBX y-offset is the bitmap's bottom relative to the baseline.
        .dy = @intCast(f.ascent - (bbx[3] + bbx[1])),
        .present = true,
    };
    if (w > 0 and h > 0) {
        g.src = try a.reserve(w, h);
        for (rows, 0..) |row, y| {
            if (y >= h) break;
            var x: u5 = 0;
            while (x < w) : (x += 1) {
                if ((row >> (31 - x)) & 1 == 1) {
                    a.put(g.src, x, @intCast(y), .{ .r = 255, .g = 255, .b = 255 });
                }
            }
        }
    }
    f.glyphs[cp] = g;
}

test "Tamzen 6x12 loads with the expected metrics" {
    const tamzen = @import("tamzen");
    var a = try Atlas.init(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    const f = try loadBdf(&a, tamzen.r6x12);
    try std.testing.expectEqual(@as(i32, 10), f.ascent);
    try std.testing.expectEqual(@as(i32, 12), f.lineHeight());
    try std.testing.expectEqual(@as(u8, 6), f.glyph('A').advance);
    try std.testing.expectEqual(@as(i32, 6 * 5), f.measure("Slab!"));
    // 'A' apex is at row 2, column 2 of the 6x12 cell.
    const g = f.glyph('A');
    try std.testing.expectEqual(@as(u8, 255), a.get(g.src, 2, 2).a);
    try std.testing.expectEqual(@as(u8, 0), a.get(g.src, 0, 2).a);
    // Latin-1 decodes through UTF-8; synthesized punctuation fills gaps.
    try std.testing.expect(f.glyph(0xB0).present); // °
    try std.testing.expect(f.index(0x2014) != '?'); // —
    try std.testing.expect(f.index(0xB7) != '?'); // ·
}
