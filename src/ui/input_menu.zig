//! A track's record menu, from right-clicking its R: the input (one
//! channel of the open input device, or a pair, recorded as a mono or
//! stereo take; the track's `rec_input`, saved as `input`), and whether a
//! take becomes notes (hum to notes, docs/30), and the MIDI source it
//! plays and records (`midiSource`, docs/44 §Sources).

const std = @import("std");
const menu = @import("menu.zig");
const Track = @import("../track.zig").Track;
const Input = @import("../recorder.zig").Input;
const midi_in = @import("../midi_in.zig");

/// The open device's input channels; main sets it each frame (0: no input).
pub var channels: u32 = 0;
/// Set when a pick changed a track's input; main clears it (the project
/// is dirty).
pub var changed: bool = false;

const KEY: u64 = 0x2007_E000_0000_0002;
const PAIR: u32 = 0x100;
const NOTES: u32 = 0x200;
const MIDI_SUB: u32 = 0x300;
/// `MIDI | 0` is "when selected", `MIDI | 1 + i` source i, `MIDI_KEEP` the
/// saved source that isn't connected (picking it changes nothing).
const MIDI: u32 = 0x400;
const MIDI_KEEP: u32 = 0x4FF;
const MAX_ITEMS = 51;
const SUB_ITEMS = midi_in.MAX_SOURCES + 2;

var track_idx: usize = 0;
var labels: [MAX_ITEMS][24]u8 = undefined;
var midi_label: [72]u8 = undefined;
var sub_labels: [SUB_ITEMS][72]u8 = undefined;

/// The menu row naming what the track hears: a MIDI source, or only while
/// selected (docs/44 §Sources).
fn midiLabel(buf: []u8, name: []const u8) []const u8 {
    if (name.len == 0) return "MIDI in: when selected";
    const absent = if (midi_in.sourceIndex(name) == null) " (not connected)" else "";
    return std.fmt.bufPrint(buf, "MIDI in: {s}{s}", .{ name, absent }) catch "MIDI in";
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
    items[k] = .{ .label = midiLabel(&midi_label, t.midiSource()), .id = MIDI_SUB, .submenu = true };
    k += 1;
    if (menu.subOpen(KEY, 0)) |sub| if (sub == MIDI_SUB) {
        var sub_items: [SUB_ITEMS]menu.Item = undefined;
        var n: usize = 0;
        const cur = t.midiSource();
        sub_items[n] = .{ .label = std.fmt.bufPrint(&sub_labels[n], "{s}When selected", .{bullet(cur.len == 0)}) catch "?", .id = MIDI };
        n += 1;
        for (0..midi_in.sourceCount()) |i| {
            const name = midi_in.sourceName(i);
            sub_items[n] = .{ .label = std.fmt.bufPrint(&sub_labels[n], "{s}{s}", .{ bullet(std.mem.eql(u8, name, cur)), name }) catch "?", .id = MIDI | @as(u32, @intCast(1 + i)) };
            n += 1;
        }
        // A saved source that isn't plugged in stays listed, so the
        // menu shows what the track is waiting for.
        if (cur.len != 0 and midi_in.sourceIndex(cur) == null) {
            sub_items[n] = .{ .label = std.fmt.bufPrint(&sub_labels[n], "{s}{s} (not connected)", .{ bullet(true), cur }) catch "?", .id = MIDI_KEEP };
            n += 1;
        }
        if (menu.subPick(KEY, 1, sub_items[0..n])) |sid| {
            if (sid == MIDI_KEEP) return;
            const pick: []const u8 = if (sid == MIDI) "" else midi_in.sourceName(sid - MIDI - 1);
            if (!std.mem.eql(u8, pick, cur)) {
                t.setMidiSource(pick);
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

fn bullet(on: bool) []const u8 {
    return if (on) "\u{2022} " else "  ";
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
    var mb: [64]u8 = undefined;
    const midi = if (t.midiSource().len == 0) "" else std.fmt.bufPrint(&mb, ", MIDI {s}", .{t.midiSource()}) catch "";
    return std.fmt.bufPrint(buf, "{s}: input {s}{s}{s} (right-click: input, notes, MIDI)", .{ verb, t.rec_input.label(&lb), into, midi }) catch "Record arm";
}
