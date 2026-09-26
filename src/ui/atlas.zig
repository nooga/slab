//! The one UI texture (docs/06 §The `Ui` core): fonts, display halos, the
//! noise tile and every control sprite. Built on the CPU once at startup
//! with a shelf packer, uploaded once, sampled nearest-neighbour.

const std = @import("std");
const style = @import("style.zig");
const Color = style.Color;

pub const SIZE: u16 = 1024;
const PAD: u16 = 1;

/// A region of the atlas, in texels.
pub const Region = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
};

pub const Atlas = struct {
    pixels: []Color,
    shelf_x: u16 = 0,
    shelf_y: u16 = 0,
    shelf_h: u16 = 0,
    /// Opaque white texel used for every solid fill (the renderer points
    /// raylib's shapes texture here so fills and sprites share one batch).
    white: Region = .{},

    pub fn init(alloc: std.mem.Allocator) !Atlas {
        const px = try alloc.alloc(Color, @as(usize, SIZE) * SIZE);
        @memset(px, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        var a = Atlas{ .pixels = px };
        a.white = try a.reserve(2, 2);
        a.fill(a.white, .{ .r = 255, .g = 255, .b = 255 });
        a.white.w = 1;
        a.white.h = 1;
        return a;
    }

    pub fn deinit(a: *Atlas, alloc: std.mem.Allocator) void {
        alloc.free(a.pixels);
        a.pixels = &.{};
    }

    /// Reserve a w×h region (plus padding so nearest sampling never
    /// bleeds a neighbour).
    pub fn reserve(a: *Atlas, w: u16, h: u16) !Region {
        if (w + PAD > SIZE or h + PAD > SIZE) return error.AtlasFull;
        if (a.shelf_x + w + PAD > SIZE) {
            a.shelf_y += a.shelf_h;
            a.shelf_x = 0;
            a.shelf_h = 0;
        }
        if (a.shelf_y + h + PAD > SIZE) return error.AtlasFull;
        const r = Region{ .x = a.shelf_x, .y = a.shelf_y, .w = w, .h = h };
        a.shelf_x += w + PAD;
        a.shelf_h = @max(a.shelf_h, h + PAD);
        return r;
    }

    pub fn put(a: *Atlas, r: Region, x: i32, y: i32, c: Color) void {
        if (x < 0 or y < 0 or x >= r.w or y >= r.h) return;
        const ix = @as(usize, r.x) + @as(usize, @intCast(x));
        const iy = @as(usize, r.y) + @as(usize, @intCast(y));
        a.pixels[iy * SIZE + ix] = c;
    }

    pub fn get(a: *const Atlas, r: Region, x: i32, y: i32) Color {
        if (x < 0 or y < 0 or x >= r.w or y >= r.h) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const ix = @as(usize, r.x) + @as(usize, @intCast(x));
        const iy = @as(usize, r.y) + @as(usize, @intCast(y));
        return a.pixels[iy * SIZE + ix];
    }

    pub fn fill(a: *Atlas, r: Region, c: Color) void {
        var y: i32 = 0;
        while (y < r.h) : (y += 1) {
            var x: i32 = 0;
            while (x < r.w) : (x += 1) a.put(r, x, y, c);
        }
    }

    /// Bytes of the whole atlas as RGBA8, for upload.
    pub fn bytes(a: *const Atlas) []const u8 {
        return std.mem.sliceAsBytes(a.pixels);
    }
};

test "shelf packer keeps regions disjoint" {
    var a = try Atlas.init(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    const r1 = try a.reserve(600, 10);
    const r2 = try a.reserve(600, 20); // doesn't fit the shelf → next shelf
    try std.testing.expect(r2.y >= r1.y + r1.h);
    const r3 = try a.reserve(100, 5);
    try std.testing.expect(r3.x >= r2.x + r2.w);
    try std.testing.expectError(error.AtlasFull, a.reserve(2000, 1));
}
