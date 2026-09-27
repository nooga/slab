//! Machine presets: one JSON file per preset at
//! `<machine-dir>/presets/<name>.preset`:
//! `{"schema":1,"machine":"<id>","note":"…","params":{"<id>":value,…}}`.
//! Param values are real (Hz, seconds, an option index for switches) — not
//! 0..1 norms — so retuning a knob range later doesn't move saved sounds;
//! they clamp into range on apply. `machine`/`note` are hub forward-compat
//! metadata the loader ignores. Factory presets are checked-in files; user
//! saves land in the same directory. All IO runs on the UI thread.

const std = @import("std");

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
// 256 is the natural cap since the machine vtable indexes presets with a u8
// (presetCount/presetName), and `count` clamps to 255. Many presets are meant
// to live in bank subdirectories (presets/<bank>/<name>) so the picker groups
// them into submenus instead of one flat list — see machine_bay presetTopItems.
pub const MAX_PRESETS = 256;
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

fn scanInto(list: *List, dir_path: []const u8, prefix: []const u8, recurse: bool) void {
    var zbuf: [512:0]u8 = undefined;
    if (dir_path.len >= zbuf.len) return;
    @memcpy(zbuf[0..dir_path.len], dir_path);
    zbuf[dir_path.len] = 0;
    const dir = opendir(@ptrCast(&zbuf[0])) orelse return;
    defer _ = closedir(dir);
    while (readdir(dir)) |entry| {
        const name_full = entry.d_name[0..entry.d_namlen];
        if (name_full.len == 0 or name_full[0] == '.') continue;
        if (entry.d_type == DT_DIR) {
            // One level of grouping subdirectories: "dir/name".
            if (!recurse) continue;
            var sub_buf: [512]u8 = undefined;
            const sub = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ dir_path, name_full }) catch continue;
            scanInto(list, sub, name_full, false);
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

/// Scan a preset directory (plus one level of subdirectories — entries
/// named "dir/name") into a sorted List. Missing directory = empty.
pub fn scan(dir_path: []const u8) List {
    var list = List{};
    scanInto(&list, dir_path, "", true);
    // Insertion sort — stable, allocation-free, and tiny n. Sorted order is
    // the index contract between the picker menus and apply-by-index.
    var i: usize = 1;
    while (i < list.count) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, list.names[j].slice(), list.names[j - 1].slice())) : (j -= 1) {
            std.mem.swap(Name, &list.names[j], &list.names[j - 1]);
        }
    }
    return list;
}

/// Read `<dir>/<name>.preset` into buf; null on any failure.
pub fn readFileBuf(buf: []u8, dir_path: []const u8, name: []const u8) ?[]const u8 {
    var path_buf: [512:0]u8 = undefined;
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
    var dir_z: [512:0]u8 = undefined;
    if (dir_path.len >= dir_z.len) return false;
    @memcpy(dir_z[0..dir_path.len], dir_path);
    dir_z[dir_path.len] = 0;
    _ = mkdir(@ptrCast(&dir_z[0]), 0o755); // EEXIST is fine
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        var sub_z: [512:0]u8 = undefined;
        const sub = std.fmt.bufPrintZ(&sub_z, "{s}/{s}", .{ dir_path, name[0..slash] }) catch return false;
        _ = mkdir(sub.ptr, 0o755);
    }

    var path_buf: [512:0]u8 = undefined;
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
    var old_z: [512:0]u8 = undefined;
    var new_z: [512:0]u8 = undefined;
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
