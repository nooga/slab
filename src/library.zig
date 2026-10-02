//! What the browser lists (docs/25 §The browser): every item on disk the
//! user can drag in, from the four places files live. Scanned on the UI
//! thread when the browser asks (it opens, the project changes, a save
//! to the library, REFRESH); the items' strings live in an arena that a
//! rescan replaces.
//!
//! | Kind   | Project                | User (home)        | Factory               | Pack (lib:)    |
//! |--------|------------------------|--------------------|-----------------------|----------------|
//! | preset | presets/<id>/          | Presets/<id>/      | machines/<id>/presets | cmi-*, vcsl-*  |
//! | table  | tables/*.wav           | Wavetables/*.wav   | machines/*/assets (clm)|               |
//! | clip   |                        | Clips/*.slabclip   | clips/*.slabclip      |                |
//! | sample | audio/*.wav            | Samples/**.wav     |                       | Library/**.wav |
//! | song   |                        | Projects/*.slab    | demos/, songs/        |                |
//!
//! Generated pack presets still live in the repo's machines/*/presets
//! (gitignored) until packs carry their own (docs/25 §Pack presets); they
//! are listed as the pack's by their bank name.
//!
//! Favorites are a list of references in favorites.txt beside
//! settings.json: a per-user convenience, like settings, never shared.

const std = @import("std");
const storage = @import("storage.zig");
const presets_mod = @import("presets.zig");
const registry_mod = @import("machine_registry.zig");

pub const Kind = enum(u8) { preset, table, clip, sample, song };
pub const Source = enum(u8) { project, user, factory, pack };

pub const Item = struct {
    kind: Kind,
    source: Source,
    /// Shown name: the file's stem, a preset's name inside its bank.
    name: []const u8,
    /// The group it is listed under (a machine, a folder, a pack).
    folder: []const u8,
    /// The file, absolute.
    path: []const u8,
    /// A preset: its machine id and its name as the machine lists it.
    machine: []const u8 = "",
    preset: []const u8 = "",
    fav: bool = false,
    /// From a pack that isn't redistributable: Publish refuses it.
    shareable: bool = true,
};

pub const MAX_ITEMS = 24000;
/// How deep a sample folder is walked.
const MAX_DEPTH = 6;

pub const Library = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    favs: std.ArrayList([]u8) = .empty,
    favs_loaded: bool = false,
    /// Bumped by every scan, so views can tell their indices went stale.
    generation: u32 = 0,
    scanned: bool = false,

    pub fn init(alloc: std.mem.Allocator) Library {
        return .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Library) void {
        self.items.deinit(self.alloc);
        for (self.favs.items) |f| self.alloc.free(f);
        self.favs.deinit(self.alloc);
        self.arena.deinit();
    }

    /// Rescan everything. `reg` lists the machines whose presets count.
    pub fn scan(self: *Library, reg: *const registry_mod.Registry) void {
        if (!self.favs_loaded) self.loadFavs();
        self.items.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.scanPresets(reg);
        self.scanFiles();
        std.mem.sort(Item, self.items.items, {}, itemLess);
        for (self.items.items) |*it| it.fav = self.isFav(it);
        self.generation +%= 1;
        self.scanned = true;
    }

    fn add(self: *Library, it: Item) void {
        if (self.items.items.len >= MAX_ITEMS) return;
        self.items.append(self.alloc, it) catch {};
    }

    fn dupe(self: *Library, s: []const u8) []const u8 {
        return self.arena.allocator().dupe(u8, s) catch "";
    }

    // ── Presets ──────────────────────────────────────────────────────

    fn scanPresets(self: *Library, reg: *const registry_mod.Registry) void {
        const list = self.alloc.create(presets_mod.List) catch return;
        defer self.alloc.destroy(list);
        for (reg.entries[0..reg.count]) |*e| {
            const id = e.idSlice();
            var db: [storage.MAX_PATH]u8 = undefined;
            const dir = presets_mod.dirFromMachinePath(&db, e.pathSlice()) orelse continue;
            var fb: [storage.MAX_PATH]u8 = undefined;
            const factory_dir = storage.absolute(&fb, dir);
            list.* = presets_mod.scanMachine(factory_dir, id);
            for (list.names[0..list.count]) |*nm| {
                const name = nm.slice();
                const bank = presets_mod.bankOf(name);
                var src: Source = switch (bank) {
                    .project => .project,
                    .user => .user,
                    .factory => .factory,
                };
                const shown = switch (bank) {
                    .project => name[presets_mod.PROJECT_BANK.len + 1 ..],
                    .user => name[presets_mod.USER_BANK.len + 1 ..],
                    .factory => name,
                };
                var shareable = true;
                if (src == .factory and (std.mem.startsWith(u8, name, "cmi") or std.mem.startsWith(u8, name, "vcsl"))) {
                    src = .pack;
                    shareable = !std.mem.startsWith(u8, name, "cmi");
                }
                var lb: [storage.MAX_PATH]u8 = undefined;
                const w = presets_mod.locate(&lb, factory_dir, id, name) orelse continue;
                var pb: [storage.MAX_PATH]u8 = undefined;
                const file = std.fmt.bufPrint(&pb, "{s}/{s}.preset", .{ w.dir, w.name }) catch continue;
                self.add(.{
                    .kind = .preset,
                    .source = src,
                    .name = self.dupe(shown),
                    .folder = self.dupe(e.nameSlice()),
                    .path = self.dupe(file),
                    .machine = self.dupe(id),
                    .preset = self.dupe(name),
                    .shareable = shareable,
                });
            }
        }
    }

    // ── Files ────────────────────────────────────────────────────────

    fn scanFiles(self: *Library) void {
        var hb: [storage.MAX_PATH]u8 = undefined;
        const home = storage.home(&hb);
        var fb: [storage.MAX_PATH]u8 = undefined;
        const factory = storage.factory(&fb);
        var lb: [storage.MAX_PATH]u8 = undefined;
        const lib = storage.library(&lb);
        const pd = storage.projectDir();
        const pkg = std.mem.endsWith(u8, pd, ".slab");
        var b: [storage.MAX_PATH]u8 = undefined;

        if (pkg) {
            self.walk(.table, .project, sub(&b, pd, "tables"), "TABLES", 0, ".wav");
            self.walk(.sample, .project, sub(&b, pd, "audio"), "AUDIO", 0, ".wav");
        }
        if (home.len > 0) {
            self.walk(.table, .user, sub(&b, home, "Wavetables"), "WAVETABLES", 0, ".wav");
            self.walk(.clip, .user, sub(&b, home, "Clips"), "CLIPS", 0, ".slabclip");
            self.walk(.sample, .user, sub(&b, home, "Samples"), null, MAX_DEPTH, ".wav");
            self.walk(.song, .user, sub(&b, home, "Projects"), "PROJECTS", 0, ".slab");
        }
        if (factory.len > 0) {
            self.walk(.clip, .factory, sub(&b, factory, "clips"), "CLIPS", 0, ".slabclip");
            self.walk(.song, .factory, sub(&b, factory, "demos"), "DEMOS", 0, ".slab");
            self.walk(.song, .factory, sub(&b, factory, "songs"), "SONGS", 0, ".slab");
            self.factoryTables(factory);
        }
        if (lib.len > 0) self.packs(lib);
    }

    /// Wavetables that ship with machines: the assets carrying a clm chunk,
    /// listed under their machine.
    fn factoryTables(self: *Library, factory: []const u8) void {
        var b: [storage.MAX_PATH]u8 = undefined;
        var md = Dir.open(sub(&b, factory, "machines")) orelse return;
        defer md.close();
        while (md.next()) |e| {
            if (!e.dir or e.name[0] == '.') continue;
            var ab: [storage.MAX_PATH]u8 = undefined;
            const assets = std.fmt.bufPrint(&ab, "{s}/machines/{s}/assets", .{ factory, e.name }) catch continue;
            var ad = Dir.open(assets) orelse continue;
            defer ad.close();
            while (ad.next()) |f| {
                if (f.dir or !std.ascii.endsWithIgnoreCase(f.name, ".wav")) continue;
                if (std.mem.eql(u8, f.name, "bank.wav")) continue; // the built-in bank, not a table to load
                var pb: [storage.MAX_PATH]u8 = undefined;
                const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ assets, f.name }) catch continue;
                if (!hasClm(path)) continue;
                self.add(.{ .kind = .table, .source = .factory, .name = self.dupe(stem(f.name)), .folder = self.dupe(e.name), .path = self.dupe(path) });
            }
        }
    }

    /// Every pack folder's samples, grouped by the pack's own folders.
    fn packs(self: *Library, lib: []const u8) void {
        var d = Dir.open(lib) orelse return;
        defer d.close();
        while (d.next()) |e| {
            if (!e.dir or e.name[0] == '.') continue;
            var pb: [storage.MAX_PATH]u8 = undefined;
            const root = std.fmt.bufPrint(&pb, "{s}/{s}", .{ lib, e.name }) catch continue;
            // The CMI disks and the drum machines are yours, not to share.
            const shareable = std.mem.eql(u8, e.name, "vcsl");
            self.walkPack(root, e.name, shareable);
        }
    }

    fn walkPack(self: *Library, root: []const u8, pack: []const u8, shareable: bool) void {
        var d = Dir.open(root) orelse return;
        defer d.close();
        while (d.next()) |e| {
            if (!e.dir or e.name[0] == '.') continue;
            var pb: [storage.MAX_PATH]u8 = undefined;
            const top = std.fmt.bufPrint(&pb, "{s}/{s}", .{ root, e.name }) catch continue;
            // A pack's raw folder (_sources) and its sorted ones both
            // group by the folder inside them.
            var sd = Dir.open(top) orelse continue;
            defer sd.close();
            var loose = false;
            while (sd.next()) |s| {
                if (s.name[0] == '.') continue;
                if (!s.dir) {
                    loose = true;
                    continue;
                }
                var gb: [storage.MAX_PATH]u8 = undefined;
                const group_dir = std.fmt.bufPrint(&gb, "{s}/{s}", .{ top, s.name }) catch continue;
                var lb: [256]u8 = undefined;
                const label = std.fmt.bufPrint(&lb, "{s} \u{B7} {s}", .{ pack, s.name }) catch s.name;
                self.walkSamples(.pack, group_dir, group_dir, self.dupe(label), MAX_DEPTH, shareable);
            }
            if (loose) {
                var lb: [256]u8 = undefined;
                const label = std.fmt.bufPrint(&lb, "{s} \u{B7} {s}", .{ pack, e.name }) catch e.name;
                self.walkSamples(.pack, top, top, self.dupe(label), 0, shareable);
            }
        }
    }

    /// Files ending in `ext` in `dir` (and below, to `depth`), under one
    /// group, or, with no group, a group per first-level folder.
    fn walk(self: *Library, kind: Kind, source: Source, dir: []const u8, group: ?[]const u8, depth: u8, ext: []const u8) void {
        if (kind == .sample and group == null) {
            // Home Samples: loose files under SAMPLES, a folder a group.
            var d = Dir.open(dir) orelse return;
            defer d.close();
            var loose = false;
            while (d.next()) |e| {
                if (e.name[0] == '.') continue;
                if (!e.dir) {
                    loose = true;
                    continue;
                }
                var gb: [storage.MAX_PATH]u8 = undefined;
                const gd = std.fmt.bufPrint(&gb, "{s}/{s}", .{ dir, e.name }) catch continue;
                self.walkSamples(source, gd, gd, self.dupe(e.name), depth, true);
            }
            if (loose) self.walkSamples(source, dir, dir, "SAMPLES", 0, true);
            return;
        }
        var d = Dir.open(dir) orelse return;
        defer d.close();
        while (d.next()) |e| {
            if (e.name[0] == '.') continue;
            if (!std.ascii.endsWithIgnoreCase(e.name, ext)) continue;
            // A project is a folder (a package) or, from before, a file.
            if (e.dir and kind != .song) continue;
            var pb: [storage.MAX_PATH]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, e.name }) catch continue;
            self.add(.{ .kind = kind, .source = source, .name = self.dupe(stem(e.name)), .folder = group orelse "", .path = self.dupe(path) });
        }
    }

    fn walkSamples(self: *Library, source: Source, root: []const u8, dir: []const u8, group: []const u8, depth: u8, shareable: bool) void {
        var d = Dir.open(dir) orelse return;
        defer d.close();
        while (d.next()) |e| {
            if (e.name[0] == '.') continue;
            var pb: [storage.MAX_PATH]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, e.name }) catch continue;
            if (e.dir) {
                if (depth > 0) self.walkSamples(source, root, path, group, depth - 1, shareable);
                continue;
            }
            if (!std.ascii.endsWithIgnoreCase(e.name, ".wav")) continue;
            // Named by its path below the group's folder.
            const rel = if (path.len > root.len + 1) path[root.len + 1 ..] else e.name;
            self.add(.{ .kind = .sample, .source = source, .name = self.dupe(rel[0 .. rel.len - 4]), .folder = group, .path = self.dupe(path), .shareable = shareable });
        }
    }

    // ── Favorites ────────────────────────────────────────────────────

    fn favsPath(buf: []u8) []const u8 {
        var sb: [storage.MAX_PATH]u8 = undefined;
        const s = storage.settingsPath(&sb);
        const dir = std.fs.path.dirname(s) orelse return "";
        return std.fmt.bufPrint(buf, "{s}/favorites.txt", .{dir}) catch "";
    }

    fn loadFavs(self: *Library) void {
        self.favs_loaded = true;
        var pb: [storage.MAX_PATH]u8 = undefined;
        const data = readAll(self.alloc, favsPath(&pb)) orelse return;
        defer self.alloc.free(data);
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |l| {
            const t = std.mem.trim(u8, l, " \r\t");
            if (t.len == 0) continue;
            const d = self.alloc.dupe(u8, t) catch continue;
            self.favs.append(self.alloc, d) catch self.alloc.free(d);
        }
    }

    fn saveFavs(self: *Library) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        for (self.favs.items) |f| {
            out.appendSlice(self.alloc, f) catch return;
            out.append(self.alloc, '\n') catch return;
        }
        var pb: [storage.MAX_PATH]u8 = undefined;
        const path = favsPath(&pb);
        if (path.len == 0) return;
        storage.makeParents(std.fs.path.dirname(path) orelse return);
        writeAll(path, out.items);
    }

    /// The reference a favorite is kept by: a preset's machine and name, a
    /// file's portable reference.
    fn favKey(buf: []u8, it: *const Item) []const u8 {
        if (it.kind == .preset) return std.fmt.bufPrint(buf, "preset:{s}/{s}", .{ it.machine, it.preset }) catch "";
        return storage.ref(buf, it.path);
    }

    fn isFav(self: *const Library, it: *const Item) bool {
        var kb: [storage.MAX_PATH]u8 = undefined;
        const k = favKey(&kb, it);
        for (self.favs.items) |f| if (std.mem.eql(u8, f, k)) return true;
        return false;
    }

    pub fn setFav(self: *Library, i: usize, on: bool) void {
        const it = &self.items.items[i];
        if (it.fav == on) return;
        it.fav = on;
        var kb: [storage.MAX_PATH]u8 = undefined;
        const k = favKey(&kb, it);
        if (on) {
            const d = self.alloc.dupe(u8, k) catch return;
            self.favs.append(self.alloc, d) catch {
                self.alloc.free(d);
                return;
            };
        } else {
            for (self.favs.items, 0..) |f, j| if (std.mem.eql(u8, f, k)) {
                self.alloc.free(f);
                _ = self.favs.orderedRemove(j);
                break;
            };
        }
        self.saveFavs();
    }
};

fn itemLess(_: void, a: Item, b: Item) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    const f = std.ascii.orderIgnoreCase(a.folder, b.folder);
    if (f != .eq) return f == .lt;
    if (a.source != b.source) return @intFromEnum(a.source) < @intFromEnum(b.source);
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn sub(buf: []u8, dir: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch "";
}

fn stem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

// ── POSIX ────────────────────────────────────────────────────────────
// The std.fs surface moved in zig 0.16; like presets.zig, the codebase
// reads directories through libc.

const DIR = opaque {};
const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};
extern fn opendir(path: [*:0]const u8) ?*DIR;
extern fn readdir(dir: *DIR) ?*Dirent;
extern fn closedir(dir: *DIR) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern fn close(fd: c_int) c_int;

const DT_DIR: u8 = 4;
const DT_LNK: u8 = 10;

const Dir = struct {
    d: *DIR,

    const Entry = struct { name: []const u8, dir: bool };

    fn open(path: []const u8) ?Dir {
        var zb: [storage.MAX_PATH:0]u8 = undefined;
        if (path.len == 0 or path.len >= zb.len) return null;
        @memcpy(zb[0..path.len], path);
        zb[path.len] = 0;
        return .{ .d = opendir(&zb) orelse return null };
    }

    fn next(self: *Dir) ?Entry {
        const e = readdir(self.d) orelse return null;
        const name = e.d_name[0..e.d_namlen];
        return .{ .name = name, .dir = e.d_type == DT_DIR };
    }

    fn close(self: *Dir) void {
        _ = closedir(self.d);
    }
};

fn zpath(buf: *[storage.MAX_PATH:0]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf;
}

fn readAll(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    const fd = open(zpath(&zb, path) orelse return null, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        out.appendSlice(alloc, chunk[0..@intCast(n)]) catch {
            out.deinit(alloc);
            return null;
        };
    }
    return out.toOwnedSlice(alloc) catch null;
}

fn writeAll(path: []const u8, data: []const u8) void {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    const O_WRONLY = 0x1;
    const O_CREAT = 0x200;
    const O_TRUNC = 0x400;
    const fd = open(zpath(&zb, path) orelse return, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return;
    defer _ = close(fd);
    _ = write(fd, data.ptr, data.len);
}

/// A WAV with a Serum `clm ` chunk is a wavetable.
fn hasClm(path: []const u8) bool {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    const fd = open(zpath(&zb, path) orelse return false, 0);
    if (fd < 0) return false;
    defer _ = close(fd);
    var head: [512]u8 = undefined;
    const n = read(fd, &head, head.len);
    if (n <= 0) return false;
    return std.mem.indexOf(u8, head[0..@intCast(n)], "clm ") != null;
}

test "library lists the home folder's files and keeps favorites" {
    const t = std.testing;
    var tmp_buf: [256]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "/tmp/slab-library-test-{d}", .{std.c.getpid()}) catch unreachable;
    var b: [512]u8 = undefined;
    storage.makeParents(std.fmt.bufPrint(&b, "{s}/Clips", .{tmp}) catch unreachable);
    storage.makeParents(std.fmt.bufPrint(&b, "{s}/Samples/Drums", .{tmp}) catch unreachable);
    writeAll(std.fmt.bufPrint(&b, "{s}/Clips/bass line.slabclip", .{tmp}) catch unreachable, "{}");
    writeAll(std.fmt.bufPrint(&b, "{s}/Samples/Drums/kick.wav", .{tmp}) catch unreachable, "RIFF");
    writeAll(std.fmt.bufPrint(&b, "{s}/Samples/loose.wav", .{tmp}) catch unreachable, "RIFF");
    var zb: [512:0]u8 = undefined;
    _ = setenv("SLAB_HOME", zpathSmall(&zb, tmp), 1);
    var sb: [512:0]u8 = undefined;
    _ = setenv("SLAB_SETTINGS", zpathSmall(&sb, std.fmt.bufPrint(&b, "{s}/settings.json", .{tmp}) catch unreachable), 1);
    var lb: [512:0]u8 = undefined;
    _ = setenv("SLAB_LIBRARY", zpathSmall(&lb, std.fmt.bufPrint(&b, "{s}/NoLibrary", .{tmp}) catch unreachable), 1);
    defer {
        _ = unsetenv("SLAB_HOME");
        _ = unsetenv("SLAB_SETTINGS");
        _ = unsetenv("SLAB_LIBRARY");
    }

    var reg = registry_mod.Registry.init(t.allocator);
    defer reg.deinit();
    var lib = Library.init(t.allocator);
    defer lib.deinit();
    lib.scan(&reg);
    var clip: ?usize = null;
    var kick = false;
    var loose = false;
    for (lib.items.items, 0..) |it, i| {
        if (it.kind == .clip and it.source == .user and std.mem.eql(u8, it.name, "bass line")) clip = i;
        if (it.kind == .sample and std.mem.eql(u8, it.folder, "Drums") and std.mem.eql(u8, it.name, "kick")) kick = true;
        if (it.kind == .sample and std.mem.eql(u8, it.folder, "SAMPLES") and std.mem.eql(u8, it.name, "loose")) loose = true;
    }
    try t.expect(clip != null and kick and loose);
    lib.setFav(clip.?, true);
    // A fresh library reads the favorite back.
    var again = Library.init(t.allocator);
    defer again.deinit();
    again.scan(&reg);
    var fav = false;
    for (again.items.items) |it| {
        if (it.kind == .clip and it.fav) fav = true;
    }
    try t.expect(fav);
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

fn zpathSmall(buf: *[512:0]u8, s: []const u8) [*:0]const u8 {
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf;
}
