//! Native macOS project file panels.

const std = @import("std");

extern fn slab_open_project_dialog() ?[*:0]u8;
extern fn slab_save_project_dialog(default_name: [*:0]const u8) ?[*:0]u8;
extern fn slab_open_audio_dialog() ?[*:0]u8;
extern fn slab_open_keymap_dialog() ?[*:0]u8;
extern fn slab_save_audio_dialog(default_name: [*:0]const u8) ?[*:0]u8;
extern fn slab_free_dialog_path(path: ?[*:0]u8) void;

pub fn openProject(alloc: std.mem.Allocator) !?[]u8 {
    const raw = slab_open_project_dialog() orelse return null;
    defer slab_free_dialog_path(raw);
    return try alloc.dupe(u8, std.mem.sliceTo(raw, 0));
}

pub fn saveProject(alloc: std.mem.Allocator, default_name: []const u8) !?[]u8 {
    const z = try alloc.dupeZ(u8, default_name);
    defer alloc.free(z);
    const raw = slab_save_project_dialog(z) orelse return null;
    defer slab_free_dialog_path(raw);
    return try alloc.dupe(u8, std.mem.sliceTo(raw, 0));
}

/// Native open panel filtered to audio files. Returns the chosen path, or
/// null if the user cancelled. Caller owns the returned slice.
pub fn openAudioFile(alloc: std.mem.Allocator) !?[]u8 {
    const raw = slab_open_audio_dialog() orelse return null;
    defer slab_free_dialog_path(raw);
    return try alloc.dupe(u8, std.mem.sliceTo(raw, 0));
}

/// Native open panel for a sampler keymap: a .wav, an .sfz or a folder.
pub fn openKeymap(alloc: std.mem.Allocator) !?[]u8 {
    const raw = slab_open_keymap_dialog() orelse return null;
    defer slab_free_dialog_path(raw);
    return try alloc.dupe(u8, std.mem.sliceTo(raw, 0));
}

/// Native save panel for a rendered .wav bounce. Returns the chosen path,
/// or null if cancelled. Caller owns the returned slice.
pub fn saveAudioFile(alloc: std.mem.Allocator, default_name: []const u8) !?[]u8 {
    const z = try alloc.dupeZ(u8, default_name);
    defer alloc.free(z);
    const raw = slab_save_audio_dialog(z) orelse return null;
    defer slab_free_dialog_path(raw);
    return try alloc.dupe(u8, std.mem.sliceTo(raw, 0));
}
