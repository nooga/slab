//! Native macOS project file panels.

const std = @import("std");

extern fn slab_open_project_dialog() ?[*:0]u8;
extern fn slab_save_project_dialog(default_name: [*:0]const u8) ?[*:0]u8;
extern fn slab_open_audio_dialog() ?[*:0]u8;
extern fn slab_open_keymap_dialog() ?[*:0]u8;
extern fn slab_save_audio_dialog(default_name: [*:0]const u8) ?[*:0]u8;
extern fn slab_free_dialog_path(path: ?[*:0]u8) void;
extern fn slab_trash(path: [*:0]const u8) c_int;
extern fn slab_reveal(path: [*:0]const u8) void;
extern fn slab_open(target: [*:0]const u8) void;

/// Open a folder in Finder, or a link in the browser.
pub fn open(target: []const u8) void {
    var zb: [2048]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{target}) catch return;
    slab_open(z.ptr);
}

/// Show a file selected in a Finder window.
pub fn reveal(path: []const u8) void {
    var zb: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return;
    slab_reveal(z.ptr);
}

/// Move a file to the Trash. False if it couldn't.
pub fn trash(path: []const u8) bool {
    var zb: [1024]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return false;
    return slab_trash(z.ptr) == 1;
}

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
