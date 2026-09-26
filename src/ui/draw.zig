//! Draw list + the one renderer (docs/06 §The `Ui` core). Widgets append
//! commands in logical pixels; `Renderer.flush` is the only code that
//! talks to raylib. Solid fills sample the atlas's white texel (raylib's
//! shapes texture is pointed there), so fills, glyphs and sprites all
//! share one texture and one batch.

const std = @import("std");
const c = @import("../c.zig");
const geom = @import("geom.zig");
const style = @import("style.zig");
const atlas_mod = @import("atlas.zig");
const Rect = geom.Rect;
const Color = style.Color;
const Region = atlas_mod.Region;

pub const Cmd = union(enum) {
    rect: struct { r: Rect, c: Color },
    vgrad: struct { r: Rect, top: Color, bot: Color },
    /// A sprite at a (possibly fractional) logical position/size. Fractional
    /// sizes are for display dots, which are sized in device pixels.
    sprite: struct { src: Region, x: f32, y: f32, w: f32, h: f32, tint: Color },
    /// `src` tiled over `r`, anchored to the screen origin (noise).
    tile: struct { src: Region, r: Rect, tint: Color },
    line: struct { x0: f32, y0: f32, x1: f32, y1: f32, c: Color },
    /// A whole non-atlas texture stretched into `r` (logo image).
    texture: struct { tex: c.rl.Texture2D, r: Rect, tint: Color },
    clip_push: Rect,
    clip_pop,
};

pub const DrawList = struct {
    cmds: []Cmd,
    len: usize = 0,
    overflowed: bool = false,

    pub fn push(dl: *DrawList, cmd: Cmd) void {
        if (dl.len == dl.cmds.len) {
            dl.overflowed = true;
            return;
        }
        dl.cmds[dl.len] = cmd;
        dl.len += 1;
    }

    pub fn reset(dl: *DrawList) void {
        dl.len = 0;
        dl.overflowed = false;
    }

    pub fn slice(dl: *const DrawList) []const Cmd {
        return dl.cmds[0..dl.len];
    }
};

inline fn rl(col: Color) c.rl.Color {
    return @bitCast(col);
}

pub const Renderer = struct {
    tex: c.rl.Texture2D,
    /// UI zoom on top of the display's own DPI scale (1, 2, 3).
    zoom: f32 = 1,
    clip_stack: [16]Rect = undefined,
    clip_depth: usize = 0,
    draw_calls: usize = 0,

    pub fn init(a: *const atlas_mod.Atlas) Renderer {
        const img = c.rl.Image{
            .data = @constCast(@ptrCast(a.bytes().ptr)),
            .width = atlas_mod.SIZE,
            .height = atlas_mod.SIZE,
            .mipmaps = 1,
            .format = c.rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        };
        const tex = c.rl.LoadTextureFromImage(img);
        c.rl.SetTextureFilter(tex, c.rl.TEXTURE_FILTER_POINT);
        c.rl.SetShapesTexture(tex, .{
            .x = @floatFromInt(a.white.x),
            .y = @floatFromInt(a.white.y),
            .width = 1,
            .height = 1,
        });
        return .{ .tex = tex };
    }

    pub fn deinit(r: *Renderer) void {
        c.rl.SetShapesTexture(.{ .id = 0 }, .{});
        c.rl.UnloadTexture(r.tex);
    }

    /// Device pixels per logical pixel (UI zoom × display DPI).
    pub fn deviceScale(r: *const Renderer) f32 {
        return r.zoom * c.rl.GetWindowScaleDPI().x;
    }

    pub fn flush(r: *Renderer, lists: []const *const DrawList) void {
        const cam = c.rl.Camera2D{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = r.zoom };
        c.rl.BeginMode2D(cam);
        r.clip_depth = 0;
        for (lists) |dl| {
            for (dl.slice()) |cmd| r.exec(cmd);
            while (r.clip_depth > 0) r.popClip();
        }
        c.rl.EndMode2D();
    }

    fn exec(r: *Renderer, cmd: Cmd) void {
        switch (cmd) {
            .rect => |q| c.rl.DrawRectangle(q.r.x, q.r.y, q.r.w, q.r.h, rl(q.c)),
            .vgrad => |q| c.rl.DrawRectangleGradientV(q.r.x, q.r.y, q.r.w, q.r.h, rl(q.top), rl(q.bot)),
            .sprite => |q| c.rl.DrawTexturePro(r.tex, srcRect(q.src), .{ .x = q.x, .y = q.y, .width = q.w, .height = q.h }, .{ .x = 0, .y = 0 }, 0, rl(q.tint)),
            .tile => |q| r.tile(q.src, q.r, q.tint),
            .line => |q| c.rl.DrawLineEx(.{ .x = q.x0, .y = q.y0 }, .{ .x = q.x1, .y = q.y1 }, 1.0, rl(q.c)),
            .texture => |q| c.rl.DrawTexturePro(q.tex, .{ .x = 0, .y = 0, .width = @floatFromInt(q.tex.width), .height = @floatFromInt(q.tex.height) }, .{ .x = @floatFromInt(q.r.x), .y = @floatFromInt(q.r.y), .width = @floatFromInt(q.r.w), .height = @floatFromInt(q.r.h) }, .{ .x = 0, .y = 0 }, 0, rl(q.tint)),
            .clip_push => |q| r.pushClip(q),
            .clip_pop => r.popClip(),
        }
    }

    fn srcRect(s: Region) c.rl.Rectangle {
        return .{ .x = @floatFromInt(s.x), .y = @floatFromInt(s.y), .width = @floatFromInt(s.w), .height = @floatFromInt(s.h) };
    }

    fn tile(r: *Renderer, src: Region, dst: Rect, tint: Color) void {
        const tw: i32 = src.w;
        const th: i32 = src.h;
        var y = dst.y - @mod(dst.y, th);
        while (y < dst.bottom()) : (y += th) {
            var x = dst.x - @mod(dst.x, tw);
            while (x < dst.right()) : (x += tw) {
                const cell = Rect.xywh(x, y, tw, th).intersect(dst);
                if (cell.empty()) continue;
                const s = Region{ .x = src.x + @as(u16, @intCast(cell.x - x)), .y = src.y + @as(u16, @intCast(cell.y - y)), .w = @intCast(cell.w), .h = @intCast(cell.h) };
                c.rl.DrawTexturePro(r.tex, srcRect(s), .{ .x = @floatFromInt(cell.x), .y = @floatFromInt(cell.y), .width = @floatFromInt(cell.w), .height = @floatFromInt(cell.h) }, .{ .x = 0, .y = 0 }, 0, rl(tint));
            }
        }
    }

    fn pushClip(r: *Renderer, want: Rect) void {
        const eff = if (r.clip_depth > 0) want.intersect(r.clip_stack[r.clip_depth - 1]) else want;
        if (r.clip_depth < r.clip_stack.len) {
            r.clip_stack[r.clip_depth] = eff;
            r.clip_depth += 1;
        }
        r.scissor(eff);
    }

    fn popClip(r: *Renderer) void {
        if (r.clip_depth == 0) return;
        r.clip_depth -= 1;
        if (r.clip_depth > 0) r.scissor(r.clip_stack[r.clip_depth - 1]) else c.rl.EndScissorMode();
    }

    fn scissor(r: *Renderer, q: Rect) void {
        // BeginScissorMode takes window points (it applies the DPI scale
        // itself); the camera zoom it doesn't know about.
        const z = r.zoom;
        c.rl.BeginScissorMode(
            @intFromFloat(@as(f32, @floatFromInt(q.x)) * z),
            @intFromFloat(@as(f32, @floatFromInt(q.y)) * z),
            @intFromFloat(@as(f32, @floatFromInt(q.w)) * z),
            @intFromFloat(@as(f32, @floatFromInt(q.h)) * z),
        );
    }
};
