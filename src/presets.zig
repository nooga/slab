//! Machine presets: one JSON file per preset,
//! `{"slab":"preset","schema":1,"machine":"<id>","note":"…","params":{"<id>":value,…}}`.
//!
//! A machine's presets come from three places (docs/25 §Save to Library):
//! the factory's `machines/<id>/presets/`, read-only; the open project's
//! `presets/<id>/`, shown as the "Project" bank; and the home folder's
//! `Presets/<id>/`, the "User" bank. A preset's name says where it lives:
//! `rom1a/dx-bass` is the factory's, `Project/lead` the project's.
//! Param values are real (Hz, seconds, an option index for switches) — not
//! 0..1 norms — so retuning a knob range later doesn't move saved sounds;
//! they clamp into range on apply. `machine`/`note` are hub forward-compat
//! metadata the loader ignores. All IO runs on the UI thread.

const std = @import("std");
const storage = @import("storage.zig");

// POSIX file/dir IO — the std.fs surface moved in zig 0.16; the codebase
// convention is direct libc externs (see machine_registry, kernel_probe).
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

const DIR = opaque {};
extern fn opendir(path: [*:0]const u8) ?*DIR;
extern fn readdir(dir: *DIR) ?*Dirent;
extern fn closedir(dir: *DIR) c_int;

// macOS arm64 dirent (64-bit inode layout is the default on arm64).
const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};

// Per-machine preset ceiling. Bounded (codebase idiom) rather than heap-backed;
// The vtable indexes presets with a u16 (machine.PresetIndex); 2048 holds a
// whole CMI disk library in banks. Many presets are meant
// to live in bank subdirectories (presets/<bank>/<name>) so the picker groups
// them into submenus instead of one flat list — see machine_bay presetTopItems.
pub const MAX_PRESETS = 2048;
pub const MAX_NAME = 63;
pub const MAX_FILE = 8192;

pub const Name = struct {
    text: [MAX_NAME:0]u8 = [_:0]u8{0} ** MAX_NAME,
    len: u8 = 0,

    pub fn slice(self: *const Name) []const u8 {
        return self.text[0..self.len];
    }

    pub fn z(self: *const Name) [*:0]const u8 {
        return @ptrCast(&self.text[0]);
    }

    pub fn set(text: []const u8) Name {
        var n = Name{};
        const len = @min(text.len, MAX_NAME);
        @memcpy(n.text[0..len], text[0..len]);
        n.len = @intCast(len);
        return n;
    }
};

pub const List = struct {
    names: [MAX_PRESETS]Name = undefined,
    count: usize = 0,

    pub fn contains(self: *const List, name: []const u8) bool {
        for (self.names[0..self.count]) |*n| {
            if (std.mem.eql(u8, n.slice(), name)) return true;
        }
        return false;
    }
};

/// machines/foo/foo.fy → machines/foo/presets (written into buf).
pub fn dirFromMachinePath(buf: []u8, machine_path: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(machine_path) orelse return null;
    const suffix = "/presets";
    if (dir.len + suffix.len > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    @memcpy(buf[dir.len..][0..suffix.len], suffix);
    return buf[0 .. dir.len + suffix.len];
}

const DT_DIR: u8 = 4;

fn scanInto(list: *List, dir_path: []const u8, prefix: []const u8, depth: u8) void {
    var zbuf: [1024:0]u8 = undefined;
    if (dir_path.len >= zbuf.len) return;
    @memcpy(zbuf[0..dir_path.len], dir_path);
    zbuf[dir_path.len] = 0;
    const dir = opendir(@ptrCast(&zbuf[0])) orelse return;
    defer _ = closedir(dir);
    while (readdir(dir)) |entry| {
        const name_full = entry.d_name[0..entry.d_namlen];
        if (name_full.len == 0 or name_full[0] == '.') continue;
        if (entry.d_type == DT_DIR) {
            // Two levels of grouping subdirectories: "bank/name" and
            // "bank/sub/name" (a collection's disks).
            if (depth >= 2) continue;
            var sub_buf: [1024]u8 = undefined;
            const sub = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, name_full }) catch continue;
            var pre_buf: [128]u8 = undefined;
            const pre = if (prefix.len > 0)
                std.fmt.bufPrint(&pre_buf, "{s}/{s}", .{ prefix, name_full }) catch continue
            else
                name_full;
            scanInto(list, sub, pre, depth + 1);
            continue;
        }
        if (!std.mem.endsWith(u8, name_full, ".preset")) continue;
        const stem = name_full[0 .. name_full.len - ".preset".len];
        if (stem.len == 0) continue;
        if (list.count >= MAX_PRESETS) return;
        if (prefix.len > 0) {
            var nm_buf: [128]u8 = undefined;
            const nm = std.fmt.bufPrint(&nm_buf, "{s}/{s}", .{ prefix, stem }) catch continue;
            if (nm.len > MAX_NAME) continue;
            list.names[list.count] = Name.set(nm);
        } else {
            if (stem.len > MAX_NAME) continue;
            list.names[list.count] = Name.set(stem);
        }
        list.count += 1;
    }
}

/// Scan a preset directory (plus two levels of subdirectories — entries
/// named "dir/name" and "dir/sub/name") into a sorted List. Missing directory = empty.
pub fn scan(dir_path: []const u8) List {
    var list = List{};
    scanInto(&list, dir_path, "", 0);
    sortList(&list);
    return list;
}

// ── where presets live ───────────────────────────────────────────────

pub const PROJECT_BANK = "Project";
pub const USER_BANK = "User";

pub const Bank = enum { factory, project, user };

/// The open project's presets for machine `id`: `<package>/presets/<id>`.
/// Null without a package (an untitled project, a bare .slab file).
pub fn projectDir(buf: []u8, id: []const u8) ?[]const u8 {
    const pd = storage.projectDir();
    if (!std.mem.endsWith(u8, pd, ".slab") or id.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/presets/{s}", .{ pd, id }) catch null;
}

/// The home folder's presets for machine `id`: `<home>/Presets/<id>`.
pub fn userDir(buf: []u8, id: []const u8) ?[]const u8 {
    if (id.len == 0) return null;
    var hb: [storage.MAX_PATH]u8 = undefined;
    const h = storage.home(&hb);
    if (h.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/Presets/{s}", .{ h, id }) catch null;
}

/// Which source a preset name belongs to.
pub fn bankOf(name: []const u8) Bank {
    if (std.mem.startsWith(u8, name, PROJECT_BANK ++ "/")) return .project;
    if (std.mem.startsWith(u8, name, USER_BANK ++ "/")) return .user;
    return .factory;
}

/// `name` under `bank`: "Project/lead".
pub fn inBank(buf: []u8, bank: Bank, name: []const u8) ?[]const u8 {
    return switch (bank) {
        .factory => name,
        .project => std.fmt.bufPrint(buf, PROJECT_BANK ++ "/{s}", .{name}) catch null,
        .user => std.fmt.bufPrint(buf, USER_BANK ++ "/{s}", .{name}) catch null,
    };
}

pub const Where = struct { dir: []const u8, name: []const u8 };

/// The folder and file stem a preset name maps to. `factory_dir` is the
/// machine's own presets folder; `buf` backs the folder path.
pub fn locate(buf: []u8, factory_dir: []const u8, id: []const u8, name: []const u8) ?Where {
    return switch (bankOf(name)) {
        .factory => .{ .dir = factory_dir, .name = name },
        .project => .{ .dir = projectDir(buf, id) orelse return null, .name = name[PROJECT_BANK.len + 1 ..] },
        .user => .{ .dir = userDir(buf, id) orelse return null, .name = name[USER_BANK.len + 1 ..] },
    };
}

/// Every preset of machine `id`: the factory's, then the project's and the
/// home folder's as banks of their own.
pub fn scanMachine(factory_dir: []const u8, id: []const u8) List {
    var list = List{};
    scanInto(&list, factory_dir, "", 0);
    var pb: [storage.MAX_PATH]u8 = undefined;
    if (projectDir(&pb, id)) |d| scanInto(&list, d, PROJECT_BANK, 1);
    var ub: [storage.MAX_PATH]u8 = undefined;
    if (userDir(&ub, id)) |d| scanInto(&list, d, USER_BANK, 1);
    sortList(&list);
    return list;
}

/// Read preset `name` of machine `id` into `buf`.
pub fn readPreset(buf: []u8, factory_dir: []const u8, id: []const u8, name: []const u8) ?[]const u8 {
    var db: [storage.MAX_PATH]u8 = undefined;
    const w = locate(&db, factory_dir, id, name) orelse return null;
    return readFileBuf(buf, w.dir, w.name);
}

/// Write preset `name` of machine `id`. The factory's folder is read-only
/// from the app: only a Project or User name writes.
pub fn writePreset(factory_dir: []const u8, id: []const u8, name: []const u8, content: []const u8) bool {
    if (bankOf(name) == .factory) return false;
    var db: [storage.MAX_PATH]u8 = undefined;
    const w = locate(&db, factory_dir, id, name) orelse return false;
    storage.makeParents(w.dir);
    return writeFile(w.dir, w.name, content);
}

/// Rename a Project or User preset within its bank; `new_name` is the bare
/// name. Returns the full new name in `out`.
pub fn renameIn(out: []u8, factory_dir: []const u8, id: []const u8, old_name: []const u8, new_name: []const u8) ?[]const u8 {
    const bank = bankOf(old_name);
    if (bank == .factory) return null;
    var db: [storage.MAX_PATH]u8 = undefined;
    const w = locate(&db, factory_dir, id, old_name) orelse return null;
    // A preset inside a bank's subfolder stays in it.
    const sub = if (std.mem.lastIndexOfScalar(u8, w.name, '/')) |i| w.name[0 .. i + 1] else "";
    var nb: [MAX_NAME * 2]u8 = undefined;
    const stem = std.fmt.bufPrint(&nb, "{s}{s}", .{ sub, new_name }) catch return null;
    if (!renameFile(w.dir, w.name, stem)) return null;
    return inBank(out, bank, stem);
}

fn sortList(list: *List) void {
    // Insertion sort — stable, allocation-free, and tiny n. Sorted order is
    // the index contract between the picker menus and apply-by-index.
    var i: usize = 1;
    while (i < list.count) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, list.names[j].slice(), list.names[j - 1].slice())) : (j -= 1) {
            std.mem.swap(Name, &list.names[j], &list.names[j - 1]);
        }
    }
}

/// Read `<dir>/<name>.preset` into buf; null on any failure.
pub fn readFileBuf(buf: []u8, dir_path: []const u8, name: []const u8) ?[]const u8 {
    var path_buf: [1024:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}.preset", .{ dir_path, name }) catch return null;
    const fd = open(path.ptr, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    var done: usize = 0;
    while (done < buf.len) {
        const n = read(fd, buf[done..].ptr, buf.len - done);
        if (n < 0) return null;
        if (n == 0) break;
        done += @intCast(n);
    }
    if (done >= buf.len) return null; // oversized preset — refuse half a file
    return buf[0..done];
}

/// Write `<dir>/<name>.preset`, creating the directory if needed.
pub fn writeFile(dir_path: []const u8, name: []const u8, content: []const u8) bool {
    var dir_z: [1024:0]u8 = undefined;
    if (dir_path.len >= dir_z.len) return false;
    @memcpy(dir_z[0..dir_path.len], dir_path);
    dir_z[dir_path.len] = 0;
    _ = mkdir(@ptrCast(&dir_z[0]), 0o755); // EEXIST is fine
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        var sub_z: [1024:0]u8 = undefined;
        const sub = std.fmt.bufPrintZ(&sub_z, "{s}/{s}", .{ dir_path, name[0..slash] }) catch return false;
        _ = mkdir(sub.ptr, 0o755);
    }

    var path_buf: [1024:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}.preset", .{ dir_path, name }) catch return false;
    const fd = open(path.ptr, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return false;
    defer _ = close(fd);
    var done: usize = 0;
    while (done < content.len) {
        const n = write(fd, content[done..].ptr, content.len - done);
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}

/// Rename `<dir>/<old>.preset` to `<dir>/<new>.preset`. Both names are bare
/// stems (no extension). Returns false on any failure. Refuses to clobber an
/// existing `<new>.preset` — the caller validates collisions up front, but
/// this is the last line of defense.
pub fn renameFile(dir_path: []const u8, old_name: []const u8, new_name: []const u8) bool {
    var old_z: [1024:0]u8 = undefined;
    var new_z: [1024:0]u8 = undefined;
    const old_p = std.fmt.bufPrintZ(&old_z, "{s}/{s}.preset", .{ dir_path, old_name }) catch return false;
    const new_p = std.fmt.bufPrintZ(&new_z, "{s}/{s}.preset", .{ dir_path, new_name }) catch return false;
    // Don't overwrite a different existing preset.
    if (!std.mem.eql(u8, old_name, new_name)) {
        const probe = open(new_p.ptr, O_RDONLY);
        if (probe >= 0) {
            _ = close(probe);
            return false;
        }
    }
    return rename(old_p.ptr, new_p.ptr) == 0;
}

// Preset bodies are JSON ({"schema":1,"machine":id,"params":{…}}); parsing
// lives in the machine (fy_raw_machine.applyPresetImpl) which owns the
// control schema. This module only handles file discovery/read/write/rename.

const testing = std.testing;

test "preset dir derivation" {
    var buf: [512]u8 = undefined;
    const dir = dirFromMachinePath(&buf, "machines/drum2/drum2.fy").?;
    try testing.expectEqualStrings("machines/drum2/presets", dir);
}
