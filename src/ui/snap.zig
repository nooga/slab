//! Shared edit-grid snap setting.

const std = @import("std");

pub const Setting = enum {
    bar,
    note_4,
    note_8,
    note_16,
    note_32,
    note_64,
    off,

    pub fn label(self: Setting) [*:0]const u8 {
        return switch (self) {
            .bar => "1 BAR",
            .note_4 => "1/4",
            .note_8 => "1/8",
            .note_16 => "1/16",
            .note_32 => "1/32",
            .note_64 => "1/64",
            .off => "OFF",
        };
    }

    pub fn tooltip(self: Setting) [*:0]const u8 {
        return switch (self) {
            .off => "Snap off  [ / ]",
            else => "Edit snap  [ / ]  Alt bypasses mouse snap",
        };
    }

    pub fn beats(self: Setting) ?f64 {
        return switch (self) {
            .bar => 4.0,
            .note_4 => 1.0,
            .note_8 => 0.5,
            .note_16 => 0.25,
            .note_32 => 0.125,
            .note_64 => 0.0625,
            .off => null,
        };
    }

    pub fn coarser(self: Setting) Setting {
        return switch (self) {
            .bar => .bar,
            .note_4 => .bar,
            .note_8 => .note_4,
            .note_16 => .note_8,
            .note_32 => .note_16,
            .note_64 => .note_32,
            .off => .note_64,
        };
    }

    pub fn finer(self: Setting) Setting {
        return switch (self) {
            .bar => .note_4,
            .note_4 => .note_8,
            .note_8 => .note_16,
            .note_16 => .note_32,
            .note_32 => .note_64,
            .note_64 => .off,
            .off => .off,
        };
    }
};

pub fn activeStep(setting: Setting, bypass: bool) ?f64 {
    if (bypass) return null;
    return setting.beats();
}

pub fn snapNearest(setting: Setting, beats_value: f64, bypass: bool) f64 {
    const step = activeStep(setting, bypass) orelse return beats_value;
    return @round(beats_value / step) * step;
}

pub fn snapPositive(setting: Setting, beats_value: f64, bypass: bool) f64 {
    return @max(0.0, snapNearest(setting, beats_value, bypass));
}

pub fn snapDownPositive(setting: Setting, beats_value: f64, bypass: bool) f64 {
    const step = activeStep(setting, bypass) orelse return @max(0.0, beats_value);
    return @max(0.0, @floor(beats_value / step) * step);
}

pub fn nudgeStep(setting: Setting, fine: bool, coarse: bool) f64 {
    if (fine) return 0.0625;
    if (coarse) return 1.0;
    return setting.beats() orelse 0.25;
}

pub fn visualStep(setting: Setting, px_per_beat: f32) f64 {
    var step = setting.beats() orelse 1.0;
    while (@as(f32, @floatCast(step)) * px_per_beat < 4.0 and step < 4.0) {
        step *= 2.0;
    }
    return @min(step, 4.0);
}

pub fn isBar(beat: f64) bool {
    return nearInt(beat / 4.0);
}

pub fn isBeat(beat: f64) bool {
    return nearInt(beat);
}

fn nearInt(v: f64) bool {
    return @abs(v - @round(v)) < 0.0001;
}
