//! The macOS app around the raylib window (native_app.m): projects Finder
//! opens, the menu bar, the window's title and document state. UI thread.

const std = @import("std");

extern fn slab_install_open_handler() void;
extern fn slab_take_opened_path() ?[*:0]u8;
extern fn slab_free_path(p: ?[*:0]u8) void;
extern fn slab_install_menus() void;
extern fn slab_take_menu_commands() c_uint;
extern fn slab_set_browser_checked(on: c_int) void;
extern fn slab_set_window_document(window: ?*anyopaque, title: [*:0]const u8, path: ?[*:0]const u8, edited: c_int) void;

/// Receive the projects Finder opens with slab (double-click, Open With,
/// a drop on the Dock icon). Call before InitWindow: a double-click that
/// launches slab is delivered while the window comes up.
pub fn installOpenHandler() void {
    slab_install_open_handler();
}

/// The path Finder asked slab to open since the last call, or null.
/// Caller owns the returned slice.
pub fn takeOpenedPath(alloc: std.mem.Allocator) !?[]u8 {
    const raw = slab_take_opened_path() orelse return null;
    defer slab_free_path(raw);
    return try alloc.dupe(u8, std.mem.sliceTo(raw, 0));
}

/// The menu bar's commands (the items' tags in native_app.m).
pub const Command = enum(u5) {
    new_project,
    open_project,
    save_project,
    save_project_as,
    clean_up_project,
    render_audio,
    undo,
    redo,
    toggle_browser,
};

pub const Commands = struct {
    bits: c_uint = 0,

    pub fn has(cs: Commands, cmd: Command) bool {
        return cs.bits & (@as(c_uint, 1) << @intFromEnum(cmd)) != 0;
    }
};

/// Add File, Edit and View to the menu bar. After InitWindow.
pub fn installMenus() void {
    slab_install_menus();
}

/// The menu items chosen since the last call.
pub fn takeCommands() Commands {
    return .{ .bits = slab_take_menu_commands() };
}

pub fn setBrowserChecked(on: bool) void {
    slab_set_browser_checked(@intFromBool(on));
}

/// The window's title bar: "SLAB — <project>", the project behind the
/// proxy icon, and the unsaved-changes dot. Only touches the window when
/// something changed.
pub const TitleBar = struct {
    last_path: [1024]u8 = undefined,
    last_len: usize = 0,
    last_chosen: bool = false,
    last_dirty: bool = false,
    shown: bool = false,

    pub fn update(tb: *TitleBar, window: ?*anyopaque, path: []const u8, chosen: bool, dirty: bool) void {
        if (tb.shown and chosen == tb.last_chosen and dirty == tb.last_dirty and
            std.mem.eql(u8, path, tb.last_path[0..tb.last_len])) return;
        const n = @min(path.len, tb.last_path.len);
        @memcpy(tb.last_path[0..n], path[0..n]);
        tb.last_len = n;
        tb.last_chosen = chosen;
        tb.last_dirty = dirty;
        tb.shown = true;

        const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/"));
        const name = if (!chosen) "Untitled" else if (std.mem.endsWith(u8, base, ".slab")) base[0 .. base.len - 5] else base;
        var tbuf: [256]u8 = undefined;
        const title = std.fmt.bufPrintZ(&tbuf, "SLAB \u{2014} {s}", .{name}) catch "SLAB";
        var pbuf: [1025]u8 = undefined;
        const zpath: ?[*:0]const u8 = if (chosen) (std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch null) else null;
        slab_set_window_document(window, title.ptr, zpath, @intFromBool(dirty));
    }
};
