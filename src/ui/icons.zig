//! Phosphor (bold) icon codepoints + draw/measure helpers. The font
//! itself is loaded in fonts.zig; this module only knows about
//! codepoint names.
//!
//! Font shipped under MIT — see vendor/phosphor/LICENSE.

const c = @import("../c.zig");
const fonts = @import("fonts.zig");

pub const Icon = enum(u21) {
    // Transport
    play = 0xe3d0,
    pause = 0xe39e,
    stop = 0xe46c,
    record = 0xe3ee,
    skip_forward = 0xe5a6,
    skip_back = 0xe5a4,
    repeat = 0xe3f6,

    // Audio / channel
    speaker_high = 0xe44a,
    speaker_slash = 0xe45a,
    speaker_x = 0xe45c,
    waveform = 0xe802,
    music_note = 0xe33c,
    microphone = 0xe326,
    faders = 0xe228,
    sliders = 0xe432,
    equalizer = 0xebbc,
    metronome = 0xe324,

    // Actions / state
    plus = 0xe3d4,
    minus = 0xe32a,
    x = 0xe4f6,
    x_circle = 0xe4f8,
    check = 0xe182,
    pencil = 0xe3ae,
    trash = 0xe4a6,
    copy = 0xe1ca,
    scissors = 0xeae0,
    lock = 0xe2fa,
    lock_open = 0xe306,
    eye = 0xe220,
    eye_slash = 0xe224,
    plugs_connected = 0xeb5a,
    plugs = 0xeb56,
    note_pencil = 0xe34c,
    arrow_clockwise = 0xe036,

    // Navigation
    caret_right = 0xe13a,
    caret_left = 0xe138,
    caret_up = 0xe13c,
    caret_down = 0xe136,

    // UI
    gear = 0xe270,
    file = 0xe236,
    folder = 0xe24a,
    clock = 0xe19a,
    palette = 0xe6c8,
    star = 0xe458,
};

pub const all_codepoints = blk: {
    const fields = @typeInfo(Icon).@"enum".fields;
    var cps: [fields.len]c_int = undefined;
    for (fields, 0..) |f, i| {
        cps[i] = @intCast(f.value);
    }
    break :blk cps;
};

pub fn draw(icon: Icon, x: f32, y: f32, size: f32, color: c.rl.Color) void {
    var buf: [5:0]u8 = .{ 0, 0, 0, 0, 0 };
    _ = encodeUtf8(@intFromEnum(icon), &buf);
    c.rl.DrawTextEx(fonts.icons, @ptrCast(&buf[0]), .{ .x = @round(x), .y = @round(y) }, size, 0, color);
}

pub fn measure(icon: Icon, size: f32) f32 {
    var buf: [5:0]u8 = .{ 0, 0, 0, 0, 0 };
    _ = encodeUtf8(@intFromEnum(icon), &buf);
    return c.rl.MeasureTextEx(fonts.icons, @ptrCast(&buf[0]), size, 0).x;
}

fn encodeUtf8(cp: u21, out: *[5:0]u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        out[1] = 0;
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        out[2] = 0;
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        out[3] = 0;
        return 3;
    } else {
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        out[4] = 0;
        return 4;
    }
}
