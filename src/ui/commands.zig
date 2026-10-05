//! The command table (docs/31 §Keys): every edit command's key, its
//! shortcut hint and where it applies, in one place. The key dispatch in
//! main and the context menus' hints both read it, so a key and its menu
//! item always do the same thing.

const std = @import("std");
const c = @import("../c.zig");
const menu = @import("menu.zig");
const gesture = @import("gesture.zig");

pub const Command = menu.EditCommand;

/// Where a command acts: the arrangement, the piano roll (a note clip in
/// the clip editor), the audio editor (an audio clip in it).
pub const Scope = struct {
    arrangement: bool = false,
    notes: bool = false,
    audio: bool = false,

    pub const any: Scope = .{ .arrangement = true, .notes = true, .audio = true };
    pub const editors: Scope = .{ .notes = true, .audio = true };

    fn has(s: Scope, w: Where) bool {
        return switch (w) {
            .arrangement => s.arrangement,
            .notes => s.notes,
            .audio => s.audio,
        };
    }
};

pub const Where = enum { arrangement, notes, audio };

pub const Key = struct {
    key: c_int,
    cmd: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const Entry = struct {
    command: Command,
    /// The keys that run it (up to two: ⌘D and D both duplicate).
    keys: [2]?Key = .{ null, null },
    /// The hint menus show; empty: none.
    hint: []const u8 = "",
    scope: Scope = Scope.any,
};

fn k(key: c_int) Key {
    return .{ .key = key };
}
fn cmdK(key: c_int) Key {
    return .{ .key = key, .cmd = true };
}

pub const TABLE = [_]Entry{
    .{ .command = .copy, .keys = .{ cmdK(c.rl.KEY_C), null }, .hint = "\u{2318}C" },
    .{ .command = .cut, .keys = .{ cmdK(c.rl.KEY_X), null }, .hint = "\u{2318}X" },
    .{ .command = .paste, .keys = .{ cmdK(c.rl.KEY_V), null }, .hint = "\u{2318}V" },
    .{ .command = .duplicate, .keys = .{ cmdK(c.rl.KEY_D), k(c.rl.KEY_D) }, .hint = "\u{2318}D" },
    .{ .command = .delete, .keys = .{ k(c.rl.KEY_BACKSPACE), k(c.rl.KEY_DELETE) }, .hint = "\u{232B}" },
    .{ .command = .select_all, .keys = .{ cmdK(c.rl.KEY_A), null }, .hint = "\u{2318}A" },
    .{ .command = .clear_selection, .hint = "\u{238B}" },
    .{ .command = .rename, .keys = .{ k(c.rl.KEY_ENTER), null }, .hint = "\u{21A9}" },
    .{ .command = .mute_clips, .keys = .{ k(c.rl.KEY_ZERO), k(c.rl.KEY_KP_0) }, .hint = "0" },
    .{ .command = .zoom_to_selection, .keys = .{ k(c.rl.KEY_Z), null }, .hint = "Z" },
    .{ .command = .loop_selection, .keys = .{ cmdK(c.rl.KEY_L), null }, .hint = "\u{2318}L", .scope = .{ .arrangement = true, .notes = true } },
    .{ .command = .split_at_playhead, .keys = .{ cmdK(c.rl.KEY_E), null }, .hint = "\u{2318}E", .scope = .{ .arrangement = true } },
    .{ .command = .join, .keys = .{ cmdK(c.rl.KEY_J), null }, .hint = "\u{2318}J", .scope = .{ .arrangement = true } },
    .{ .command = .insert_time, .keys = .{ cmdK(c.rl.KEY_I), null }, .hint = "\u{2318}I", .scope = .{ .arrangement = true } },
    .{ .command = .delete_time, .keys = .{ .{ .key = c.rl.KEY_BACKSPACE, .cmd = true, .shift = true }, .{ .key = c.rl.KEY_DELETE, .cmd = true, .shift = true } }, .hint = "\u{2318}\u{21E7}\u{232B}", .scope = .{ .arrangement = true } },
    .{ .command = .quantize, .keys = .{ k(c.rl.KEY_Q), null }, .hint = "Q", .scope = .{ .notes = true } },
    .{ .command = .humanize, .keys = .{ k(c.rl.KEY_H), null }, .hint = "H", .scope = .{ .notes = true } },
    .{ .command = .snap_to_scale, .keys = .{ k(c.rl.KEY_S), null }, .hint = "S", .scope = .{ .notes = true } },
    // The arrows nudge (main); these only name the octave step in menus.
    .{ .command = .octave_up, .hint = "\u{21E7}\u{2191}", .scope = .{ .notes = true } },
    .{ .command = .octave_down, .hint = "\u{21E7}\u{2193}", .scope = .{ .notes = true } },
    // Run from main's project and global keys; listed for their hints.
    .{ .command = .file_save, .hint = "\u{2318}S" },
    .{ .command = .file_save_as, .hint = "\u{2318}\u{21E7}S" },
    .{ .command = .file_open, .hint = "\u{2318}O" },
    .{ .command = .file_new, .hint = "\u{2318}N" },
    .{ .command = .render_audio, .hint = "\u{2318}R" },
    .{ .command = .bounce, .hint = "\u{2318}B" },
    .{ .command = .clear_solo_mute, .hint = "\u{21E7}M" },
};

fn entry(cmd: Command) ?*const Entry {
    for (&TABLE) |*e| if (e.command == cmd) return e;
    return null;
}

/// The hint a menu shows for `cmd`.
pub fn hint(cmd: Command) ?[]const u8 {
    const e = entry(cmd) orelse return null;
    return if (e.hint.len > 0) e.hint else null;
}

/// Whether `cmd` acts in `w` (menus grey it out where it doesn't).
pub fn appliesIn(cmd: Command, w: Where) bool {
    const e = entry(cmd) orelse return true;
    return e.scope.has(w);
}

/// The modifiers must match exactly, so D and ⇧D stay apart.
fn matches(kd: Key, md: gesture.Mods) bool {
    return kd.cmd == md.cmd and kd.shift == md.shift and kd.alt == md.alt;
}

/// The command whose key was pressed this frame in `w`, if any.
pub fn pressed(w: Where, md: gesture.Mods, isPressed: *const fn (c_int) callconv(.c) bool) ?Command {
    for (&TABLE) |*e| {
        if (!e.scope.has(w)) continue;
        for (e.keys) |kd_opt| {
            const kd = kd_opt orelse continue;
            if (matches(kd, md) and isPressed(kd.key)) return e.command;
        }
    }
    return null;
}

const testing = std.testing;

var test_down: c_int = 0;
fn testPressed(key: c_int) callconv(.c) bool {
    return key == test_down;
}

test "keys map to commands by scope and modifiers" {
    test_down = c.rl.KEY_D;
    try testing.expectEqual(Command.duplicate, pressed(.arrangement, .{}, &testPressed).?);
    try testing.expectEqual(Command.duplicate, pressed(.notes, .{ .cmd = true }, &testPressed).?);
    try testing.expect(pressed(.notes, .{ .shift = true }, &testPressed) == null);
    test_down = c.rl.KEY_Q;
    try testing.expectEqual(Command.quantize, pressed(.notes, .{}, &testPressed).?);
    try testing.expect(pressed(.arrangement, .{}, &testPressed) == null);
    try testing.expect(pressed(.audio, .{}, &testPressed) == null);
    test_down = c.rl.KEY_L;
    try testing.expectEqual(Command.loop_selection, pressed(.arrangement, .{ .cmd = true }, &testPressed).?);
    try testing.expect(pressed(.arrangement, .{}, &testPressed) == null);
}

test "every command with a key has a hint" {
    for (TABLE) |e| {
        if (e.keys[0] != null) try testing.expect(e.hint.len > 0);
    }
}
