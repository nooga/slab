//! A track's record menu, from right-clicking its R: the input (one
//! channel of the open input device, or a pair, recorded as a mono or
//! stereo take; the track's `rec_input`, saved as `input`), and whether a
//! take becomes notes (hum to notes, docs/30), and the MIDI channel it
//! plays and records (`midi_channel`, docs/44 §Channels).

const std = @import("std");
const menu = @import("menu.zig");
const Track = @import("../track.zig").Track;
const Input = @import("../recorder.zig").Input;

/// The open device's input channels; main sets it each frame (0: no input).
pub var channels: u32 = 0;
/// Set when a pick changed a track's input; main clears it (the project
/// is dirty).
pub var changed: bool = false;

const KEY: u64 = 0x2007_E000_0000_0002;
const PAIR: u32 = 0x100;
const NOTES: u32 = 0x200;
const MIDI_SUB: u32 = 0x300;
const MIDI: u32 = 0x400;
const MAX_ITEMS = 51;

var track_idx: usize = 0;
var labels: [MAX_ITEMS][24]u8 = undefined;
var midi_label: [24]u8 = undefined;
var sub_labels: [17][24]u8 = undefined;

/// The menu row naming what the track hears: MIDI channel N, or only
/// while selected (docs/44 §Channels).
fn midiLabel(buf: []u8, ch: u8) []const u8 {
    if (ch == 0) return "MIDI in: when selected";
    return std.fmt.bufPrint(buf, "MIDI in: channel {d}", .{ch}) catch "MIDI in";
}

pub fn open(ti: usize, x: i32, y: i32) void {
    track_idx = ti;
    menu.openAt(KEY, x, y);
}

pub fn tick(tracks: []Track) void {
    if (!menu.isOpen(KEY)) return;
    if (track_idx >= tracks.len) {
        menu.close();
        return;
    }
    const t = &tracks[track_idx];
    var items: [MAX_ITEMS]menu.Item = undefined;
    var k: usize = 0;
    if (channels == 0) {
        items[0] = .{ .label = "No input device open (arm a track)", .enabled = false };
        k = 1;
    } else {
        const n = @min(channels, 32);
        for (0..n) |ch| {
            items[k] = item(k, .{ .first = @intCast(ch) }, t.rec_input, @intCast(ch));
            k += 1;
        }
        var ch: u32 = 0;
        while (ch + 1 < n and k + 1 < MAX_ITEMS) : (ch += 2) {
            items[k] = item(k, .{ .first = @intCast(ch), .stereo = true }, t.rec_input, PAIR | ch);
            k += 1;
        }
    }
    items[k] = .{ .label = if (t.rec_notes) "\u{2022} Take becomes notes" else "  Take becomes notes", .id = NOTES };
    k += 1;
    items[k] = .{ .separator = true };
    k += 1;
    items[k] = .{ .label = midiLabel(&midi_label, t.midi_channel), .id = MIDI_SUB, .submenu = true };
    k += 1;
    if (menu.subOpen(KEY, 0)) |sub| if (sub == MIDI_SUB) {
        var sub_items: [17]menu.Item = undefined;
        for (&sub_items, 0..) |*it, ch| {
            const mark = if (t.midi_channel == ch) "\u{2022} " else "  ";
            const text = if (ch == 0)
                std.fmt.bufPrint(&sub_labels[ch], "{s}When selected", .{mark}) catch "?"
            else
                std.fmt.bufPrint(&sub_labels[ch], "{s}Channel {d}", .{ mark, ch }) catch "?";
            it.* = .{ .label = text, .id = MIDI | @as(u32, @intCast(ch)) };
        }
        if (menu.subPick(KEY, 1, &sub_items)) |sid| {
            const ch: u8 = @intCast(sid & 0x1f);
            if (ch != t.midi_channel) {
                t.midi_channel = ch;
                changed = true;
            }
        }
    };
    const id = menu.pick(KEY, items[0..k]) orelse return;
    if (id == MIDI_SUB) return;
    if (id == NOTES) {
        t.rec_notes = !t.rec_notes;
        return;
    }
    const in: Input = if (id & PAIR != 0) .{ .first = @intCast(id & 0xff), .stereo = true } else .{ .first = @intCast(id) };
    if (!std.meta.eql(in, t.rec_input)) {
        t.rec_input = in;
        changed = true;
    }
}

fn item(k: usize, in: Input, cur: Input, id: u32) menu.Item {
    var lb: [8]u8 = undefined;
    const mark = if (std.meta.eql(in, cur)) "\u{2022} " else "  ";
    const kind = if (in.stereo) "Stereo" else "Mono";
    const text = std.fmt.bufPrint(&labels[k], "{s}In {s} {s}", .{ mark, in.label(&lb), kind }) catch "?";
    return .{ .label = text, .id = id };
}

/// The R button's tooltip: what it records from, and into.
pub fn tip(buf: []u8, t: *const Track) []const u8 {
    var lb: [8]u8 = undefined;
    const verb = if (t.isArmed()) "Disarm" else "Arm";
    const into = if (t.rec_notes) ", to notes" else "";
    var mb: [12]u8 = undefined;
    const midi = if (t.midi_channel == 0) "" else std.fmt.bufPrint(&mb, ", MIDI ch {d}", .{t.midi_channel}) catch "";
    return std.fmt.bufPrint(buf, "{s}: input {s}{s}{s} (right-click: input, notes, MIDI)", .{ verb, t.rec_input.label(&lb), into, midi }) catch "Record arm";
}
