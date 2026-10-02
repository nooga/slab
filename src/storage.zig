//! Roots and references (docs/25 §Roots). Projects, presets and racks name
//! files by reference: a root prefix and a path under it.
//!
//!   project:   the open project's folder; a path with no prefix means it too
//!   user:      the home folder, ~/Music/Slab ($SLAB_HOME, settings "home")
//!   factory:   what slab ships: $SLAB_FACTORY, else the working directory
//!              (a dev build runs from the repo)
//!   lib:       sample packs, <home>/Library ($SLAB_LIBRARY)
//!
//! In memory a file is always its real path; `resolve` turns a reference
//! into one when something loads, `ref` turns one back when something is
//! written. Only a project save writes project-relative references
//! (`beginProjectSave`): undo snapshots and presets name the root, so they
//! survive the project moving.
//!
//! UI thread only.

const std = @import("std");

pub const PROJECT = "project:";
pub const USER = "user:";
pub const FACTORY = "factory:";
pub const LIB = "lib:";

pub const MAX_PATH = 1024;

/// The open project's folder, absolute; empty for an untitled project.
var project_dir_buf: [MAX_PATH]u8 = undefined;
var project_dir_len: usize = 0;
/// Set while a project save serializes: files under the project folder
/// are written relative to it.
var saving: bool = false;

/// The home folder from settings.json, when it moves it.
var home_setting_buf: [MAX_PATH]u8 = undefined;
var home_setting_len: usize = 0;

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

fn env(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    const s = std.mem.span(p);
    return if (s.len > 0) s else null;
}

fn copyOut(buf: []u8, s: []const u8) []const u8 {
    if (s.len > buf.len) return "";
    @memcpy(buf[0..s.len], s);
    return std.mem.trimEnd(u8, buf[0..s.len], "/");
}

/// The home folder: $SLAB_HOME, else settings.json's "home", else
/// ~/Music/Slab.
pub fn home(buf: []u8) []const u8 {
    if (env("SLAB_HOME")) |s| return copyOut(buf, s);
    if (home_setting_len > 0) return copyOut(buf, home_setting_buf[0..home_setting_len]);
    const h = env("HOME") orelse "";
    return std.fmt.bufPrint(buf, "{s}/Music/Slab", .{h}) catch "";
}

/// Sample packs: $SLAB_LIBRARY, else <home>/Library.
pub fn library(buf: []u8) []const u8 {
    if (env("SLAB_LIBRARY")) |s| return copyOut(buf, s);
    var hb: [MAX_PATH]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/Library", .{home(&hb)}) catch "";
}

/// What slab ships: $SLAB_FACTORY, else the working directory.
pub fn factory(buf: []u8) []const u8 {
    if (env("SLAB_FACTORY")) |s| return absolute(buf, s);
    const p = getcwd(buf.ptr, buf.len) orelse return "";
    return std.mem.span(p);
}

pub fn projectDir() []const u8 {
    return project_dir_buf[0..project_dir_len];
}

/// Where a recording goes: the open package's audio/ folder, else (an
/// unsaved project, or a bare .slab file) <home>/Cache/recordings, from
/// where the next save collects it.
pub fn recordingsDir(buf: []u8) []const u8 {
    const pd = projectDir();
    if (std.mem.endsWith(u8, pd, ".slab")) return std.fmt.bufPrint(buf, "{s}/audio", .{pd}) catch "";
    var hb: [MAX_PATH]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/Cache/recordings", .{home(&hb)}) catch "";
}

/// Copy sample-pack files into a project when saving it (settings
/// "collect_lib", default on; docs/25 §Collect on save).
pub var collect_lib: bool = true;

/// The project file whose folder `project:` and plain relative paths
/// resolve against; null for an untitled project.
pub fn setProject(project_path: ?[]const u8) void {
    project_dir_len = 0;
    const p = project_path orelse return;
    var ab: [MAX_PATH]u8 = undefined;
    const abs = absolute(&ab, p);
    const dir = std.fs.path.dirname(abs) orelse return;
    if (dir.len > project_dir_buf.len) return;
    @memcpy(project_dir_buf[0..dir.len], dir);
    project_dir_len = dir.len;
}

/// Write project-relative references until endProjectSave.
pub fn beginProjectSave() void {
    saving = true;
}

pub fn endProjectSave() void {
    saving = false;
}

pub fn setHomeSetting(dir: []const u8) void {
    const n = @min(dir.len, home_setting_buf.len);
    @memcpy(home_setting_buf[0..n], dir[0..n]);
    home_setting_len = n;
}

fn rootPath(buf: []u8, prefix: []const u8) []const u8 {
    if (std.mem.eql(u8, prefix, PROJECT)) return copyOut(buf, projectDir());
    if (std.mem.eql(u8, prefix, USER)) return home(buf);
    if (std.mem.eql(u8, prefix, FACTORY)) return factory(buf);
    if (std.mem.eql(u8, prefix, LIB)) return library(buf);
    return "";
}

const PREFIXES = [_][]const u8{ PROJECT, USER, FACTORY, LIB };

/// The file a reference names, as an absolute path. Relative paths are
/// relative to the open project's folder (the working directory without
/// one).
pub fn resolve(buf: []u8, reference: []const u8) []const u8 {
    if (reference.len == 0) return reference;
    var jb: [MAX_PATH * 2]u8 = undefined;
    const joined = for (PREFIXES) |pre| {
        if (!std.mem.startsWith(u8, reference, pre)) continue;
        var rb: [MAX_PATH]u8 = undefined;
        const root = rootPath(&rb, pre);
        const rest = std.mem.trimStart(u8, reference[pre.len..], "/");
        break if (root.len == 0) rest else std.fmt.bufPrint(&jb, "{s}/{s}", .{ root, rest }) catch return reference;
    } else if (reference[0] == '/' or project_dir_len == 0)
        reference
    else
        std.fmt.bufPrint(&jb, "{s}/{s}", .{ projectDir(), reference }) catch return reference;
    return absolute(buf, joined);
}

/// How a file is written: under the root that holds it most closely, as
/// `lib:…`, `factory:…` or `user:…`, or, during a project save, relative
/// to the project's folder. Anything under no root stays absolute. A
/// reference passes through unchanged.
pub fn ref(buf: []u8, path: []const u8) []const u8 {
    for (PREFIXES) |pre| if (std.mem.startsWith(u8, path, pre)) return path;
    if (path.len == 0) return path;
    var ab: [MAX_PATH]u8 = undefined;
    const abs = absolute(&ab, path);

    var best_len: usize = 0;
    var best: ?[]const u8 = null;
    var roots: [4][MAX_PATH]u8 = undefined;
    // Ties go to the earlier root: lib inside user, factory before a
    // project saved at the factory root.
    const order = [_][]const u8{ LIB, FACTORY, USER, PROJECT };
    for (order, 0..) |pre, i| {
        if (std.mem.eql(u8, pre, PROJECT) and !saving) continue;
        const root = rootPath(&roots[i], pre);
        if (root.len <= best_len or !under(abs, root)) continue;
        best_len = root.len;
        best = pre;
    }
    const pre = best orelse return copyOut(buf, abs);
    const rest = abs[best_len + 1 ..];
    if (std.mem.eql(u8, pre, PROJECT)) return copyOut(buf, rest);
    return std.fmt.bufPrint(buf, "{s}{s}", .{ pre, rest }) catch path;
}

fn under(path: []const u8, root: []const u8) bool {
    return root.len > 0 and path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// `path` made absolute against the working directory, with `.` and `..`
/// collapsed.
pub fn absolute(buf: []u8, path: []const u8) []const u8 {
    var joined: [MAX_PATH * 2]u8 = undefined;
    const full = if (path.len > 0 and path[0] == '/') path else blk: {
        var cb: [MAX_PATH]u8 = undefined;
        const cwd = if (getcwd(&cb, cb.len)) |p| std.mem.span(p) else "";
        break :blk std.fmt.bufPrint(&joined, "{s}/{s}", .{ cwd, path }) catch return path;
    };
    // Collapse segment by segment.
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, full, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            while (n > 0 and buf[n - 1] != '/') n -= 1;
            if (n > 0) n -= 1;
            continue;
        }
        if (n + 1 + seg.len > buf.len) return path;
        buf[n] = '/';
        @memcpy(buf[n + 1 ..][0..seg.len], seg);
        n += 1 + seg.len;
    }
    if (n == 0) {
        buf[0] = '/';
        n = 1;
    }
    return buf[0..n];
}

// ── the home folder and settings ──────────────────────────────────────

/// The folders of the home folder (docs/25 §The home folder).
pub const HOME_DIRS = [_][]const u8{ "Projects", "Presets", "Wavetables", "Clips", "Samples", "Machines", "Library", "Cache" };

fn makeDir(path: []const u8) void {
    var zb: [MAX_PATH]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return;
    _ = mkdir(z.ptr, 0o755); // EEXIST is fine
}

/// Create the home folder and its folders where they're missing.
pub fn ensureHome() void {
    var hb: [MAX_PATH]u8 = undefined;
    const h = home(&hb);
    if (h.len == 0) return;
    makeParents(h);
    for (HOME_DIRS) |d| {
        var pb: [MAX_PATH]u8 = undefined;
        makeDir(std.fmt.bufPrint(&pb, "{s}/{s}", .{ h, d }) catch continue);
    }
}

/// mkdir -p.
pub fn makeParents(path: []const u8) void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') makeDir(path[0..i]);
    }
}

/// ~/Library/Application Support/Slab/settings.json ($SLAB_SETTINGS).
pub fn settingsPath(buf: []u8) []const u8 {
    if (env("SLAB_SETTINGS")) |s| return copyOut(buf, s);
    const h = env("HOME") orelse "";
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/Slab/settings.json", .{h}) catch "";
}

/// What settings.json holds. Settings are not content: never shared or
/// published (docs/25 §The home folder).
pub const Settings = struct {
    /// The home folder, when it isn't ~/Music/Slab.
    home: []const u8 = "",
    /// Copy the sample-pack files a project uses into it on save.
    collect_lib: bool = true,
};

/// Read settings.json and apply it. A missing file is the defaults; the
/// app writes them (`write_missing`) so the user can find and edit it, a
/// headless render doesn't.
pub fn loadSettings(alloc: std.mem.Allocator, write_missing: bool) void {
    var pb: [MAX_PATH]u8 = undefined;
    const path = settingsPath(&pb);
    if (path.len == 0) return;
    const bytes = readFile(alloc, path) orelse {
        if (write_missing) writeSettings(alloc, .{});
        return;
    };
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(Settings, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    if (parsed.value.home.len > 0) setHomeSetting(parsed.value.home);
    collect_lib = parsed.value.collect_lib;
}

pub fn writeSettings(alloc: std.mem.Allocator, s: Settings) void {
    var pb: [MAX_PATH]u8 = undefined;
    const path = settingsPath(&pb);
    if (std.fs.path.dirname(path)) |d| makeParents(d);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.print(alloc, "{f}\n", .{std.json.fmt(s, .{ .whitespace = .indent_2 })}) catch return;
    writeFile(path, out.items);
}

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

fn readFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zb: [MAX_PATH]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return null;
    const fd = open(z.ptr, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) {
            out.deinit(alloc);
            return null;
        }
        if (n == 0) break;
        out.appendSlice(alloc, chunk[0..@intCast(n)]) catch {
            out.deinit(alloc);
            return null;
        };
    }
    return out.toOwnedSlice(alloc) catch null;
}

fn writeFile(path: []const u8, bytes: []const u8) void {
    var zb: [MAX_PATH]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return;
    const fd = open(z.ptr, 0x0001 | 0x0200 | 0x0400, @as(c_uint, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) return;
    defer _ = close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const w = write(fd, bytes[done..].ptr, bytes.len - done);
        if (w <= 0) return;
        done += @intCast(w);
    }
}

test "storage: references resolve under their roots and come back" {
    var a: [MAX_PATH]u8 = undefined;
    var b: [MAX_PATH]u8 = undefined;
    var fb: [MAX_PATH]u8 = undefined;
    const fac = factory(&fb);

    // Factory files: a dev build's working directory.
    const kick = resolve(&a, "factory:machines/concoction/assets/kick.wav");
    try std.testing.expect(std.mem.startsWith(u8, kick, fac));
    try std.testing.expectEqualStrings("factory:machines/concoction/assets/kick.wav", ref(&b, kick));
    // A relative real path is under the working directory: factory too.
    try std.testing.expectEqualStrings("factory:machines/concoction/assets/kick.wav", ref(&b, "machines/concoction/assets/kick.wav"));
    try std.testing.expectEqualStrings("factory:machines/x.wav", ref(&b, "./machines/../machines/x.wav"));

    // Library files: lib: wins over user: (the library is inside home).
    var lb: [MAX_PATH]u8 = undefined;
    const lib = library(&lb);
    const m = resolve(&a, "lib:vcsl/Marimba/marimba.sfz");
    try std.testing.expect(std.mem.startsWith(u8, m, lib));
    try std.testing.expectEqualStrings("lib:vcsl/Marimba/marimba.sfz", ref(&b, m));

    // Home files.
    var hb: [MAX_PATH]u8 = undefined;
    const h = home(&hb);
    const w = resolve(&a, "user:Wavetables/growl.wav");
    try std.testing.expect(std.mem.startsWith(u8, w, h));
    try std.testing.expectEqualStrings("user:Wavetables/growl.wav", ref(&b, w));

    // Elsewhere: absolute, unchanged.
    try std.testing.expectEqualStrings("/Volumes/x/y.wav", ref(&b, "/Volumes/x/y.wav"));
    try std.testing.expectEqualStrings("/Volumes/x/y.wav", resolve(&a, "/Volumes/x/y.wav"));
    // References pass through ref().
    try std.testing.expectEqualStrings("lib:a/b.wav", ref(&b, "lib:a/b.wav"));
}

test "storage: project-relative references only while saving the project" {
    defer setProject(null);
    setProject("/tmp/songs/song.slab");
    var a: [MAX_PATH]u8 = undefined;
    var b: [MAX_PATH]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/songs/song.tables/a.wav", resolve(&a, "song.tables/a.wav"));
    try std.testing.expectEqualStrings("/tmp/songs/song.tables/a.wav", resolve(&a, "project:song.tables/a.wav"));
    // Undo snapshots and presets keep the absolute path.
    try std.testing.expectEqualStrings("/tmp/songs/song.tables/a.wav", ref(&b, "/tmp/songs/song.tables/a.wav"));
    beginProjectSave();
    defer endProjectSave();
    try std.testing.expectEqualStrings("song.tables/a.wav", ref(&b, "/tmp/songs/song.tables/a.wav"));
    try std.testing.expectEqualStrings("/tmp/other/a.wav", ref(&b, "/tmp/other/a.wav"));
    // Without a project, relative paths stay relative to the working directory.
    setProject(null);
    var cb: [MAX_PATH]u8 = undefined;
    try std.testing.expectEqualStrings(absolute(&cb, "x/a.wav"), resolve(&a, "x/a.wav"));
}

test "storage: absolute collapses . and .." {
    var a: [MAX_PATH]u8 = undefined;
    try std.testing.expectEqualStrings("/a/c", absolute(&a, "/a/b/../c/."));
    try std.testing.expectEqualStrings("/", absolute(&a, "/.."));
}

test "storage: the home folder is created, and settings move it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [MAX_PATH]u8 = undefined;
    const root = absolute(&rb, try std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}));
    var root_buf: [MAX_PATH]u8 = undefined;
    @memcpy(root_buf[0..root.len], root);
    const base = root_buf[0..root.len];

    var sb: [MAX_PATH]u8 = undefined;
    const settings = try std.fmt.bufPrintZ(&sb, "{s}/settings.json", .{base});
    var hb: [MAX_PATH]u8 = undefined;
    const moved = try std.fmt.bufPrint(&hb, "{s}/My Slab", .{base});
    const saved_home = home_setting_len;
    defer home_setting_len = saved_home;
    _ = setenv("SLAB_SETTINGS", settings.ptr, 1);
    defer _ = unsetenv("SLAB_SETTINGS");
    if (env("SLAB_HOME") != null) return error.SkipZigTest;

    // A missing file is written with the defaults, and changes nothing.
    loadSettings(alloc, true);
    const written = readFile(alloc, settings) orelse return error.TestUnexpectedResult;
    alloc.free(written);
    try std.testing.expectEqual(saved_home, home_setting_len);

    writeSettings(alloc, .{ .home = moved });
    loadSettings(alloc, false);
    var ob: [MAX_PATH]u8 = undefined;
    try std.testing.expectEqualStrings(moved, home(&ob));
    if (env("SLAB_LIBRARY") == null) {
        var lb: [MAX_PATH]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, library(&lb), moved));
    }
    ensureHome();
    for (HOME_DIRS) |d| {
        var pb: [MAX_PATH]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ moved, d });
        try std.testing.expect(access(p.ptr, 0) == 0);
    }
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
