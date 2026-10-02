//! The project package (docs/25 §The project package): a project is a
//! folder, `Song.slab/`, holding project.json and every file the project
//! uses that slab doesn't ship.
//!
//!   project.json   the document (docs/19), plus its "assets" table
//!   tables/        wavetables edited in the project (the editor writes them)
//!   samples/       files collected for instruments: samples, keymaps, tables
//!   audio/         audio clips' files: recordings, collected audio
//!
//! Saving collects (§Collect on save): a file from the home folder, from
//! anywhere else, or (by default) from a sample pack is copied in and the
//! project names the copy; a factory file stays a reference. Every file
//! gets a SHA-256 in the asset table, so a copy that is already there is
//! not copied again. A bare `.slab` file still opens; saving it makes it a
//! package.

const std = @import("std");
const storage = @import("storage.zig");
const keymap = @import("keymap.zig");

pub const DOC = "project.json";
pub const TABLES = "tables";
pub const SAMPLES = "samples";
pub const AUDIO = "audio";
/// The folders whose files belong to the asset table; Clean Up looks here.
pub const DATA_DIRS = [_][]const u8{ TABLES, SAMPLES, AUDIO };

const MAX_PATH = storage.MAX_PATH;
const Value = std.json.Value;

// ── files ──────────────────────────────────────────────────────────────

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn closedir(d: *anyopaque) c_int;
extern "c" fn readdir(d: *anyopaque) ?*const Dirent;

const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};
const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

fn z(buf: []u8, path: []const u8) ?[*:0]const u8 {
    const s = std.fmt.bufPrintZ(buf, "{s}", .{path}) catch return null;
    return s.ptr;
}

pub fn exists(path: []const u8) bool {
    var zb: [MAX_PATH]u8 = undefined;
    return access(z(&zb, path) orelse return false, 0) == 0;
}

fn fileStat(path: []const u8) ?std.c.Stat {
    var zb: [MAX_PATH]u8 = undefined;
    var st: std.c.Stat = undefined;
    if (stat(z(&zb, path) orelse return null, &st) != 0) return null;
    return st;
}

pub fn isDir(path: []const u8) bool {
    const st = fileStat(path) orelse return false;
    return st.mode & std.c.S.IFMT == std.c.S.IFDIR;
}

/// True when `path` is a package (a folder), not a bare project file.
pub fn isPackage(path: []const u8) bool {
    return isDir(path);
}

/// The document inside a package, or the bare file itself.
pub fn docPath(buf: []u8, path: []const u8) []const u8 {
    if (!isPackage(path)) return path;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, path, "/"), DOC }) catch path;
}

/// Make `path` a package to save into. A bare project file there moves
/// inside as project.json first, so nothing is lost if the save fails.
pub fn prepare(path: []const u8) !void {
    if (isDir(path)) return;
    var zb: [MAX_PATH]u8 = undefined;
    var tb: [MAX_PATH]u8 = undefined;
    var db: [MAX_PATH]u8 = undefined;
    if (exists(path)) {
        const tmp = try std.fmt.bufPrint(&tb, "{s}.converting", .{path});
        if (rename(z(&zb, path) orelse return error.PathTooLong, z(&db, tmp) orelse return error.PathTooLong) != 0) return error.RenameFailed;
        storage.makeParents(path);
        if (!isDir(path)) return error.MakeDirFailed;
        const doc = try std.fmt.bufPrint(&db, "{s}/{s}", .{ path, DOC });
        var zb2: [MAX_PATH]u8 = undefined;
        var zb3: [MAX_PATH]u8 = undefined;
        if (rename(z(&zb2, tmp).?, z(&zb3, doc) orelse return error.PathTooLong) != 0) return error.RenameFailed;
        return;
    }
    storage.makeParents(path);
    if (!isDir(path)) return error.MakeDirFailed;
}

fn writeAll(path: []const u8, bytes: []const u8) !void {
    var zb: [MAX_PATH]u8 = undefined;
    const fd = open(z(&zb, path) orelse return error.PathTooLong, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const w = write(fd, bytes[done..].ptr, bytes.len - done);
        if (w <= 0) return error.WriteFailed;
        done += @intCast(w);
    }
}

/// Write the package's project.json, through a temporary file so a failed
/// write leaves the last one whole.
pub fn writeDoc(pkg: []const u8, bytes: []const u8) !void {
    var pb: [MAX_PATH]u8 = undefined;
    var tb: [MAX_PATH]u8 = undefined;
    const doc = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ pkg, DOC });
    const tmp = try std.fmt.bufPrint(&tb, "{s}/{s}.saving", .{ pkg, DOC });
    try writeAll(tmp, bytes);
    var za: [MAX_PATH]u8 = undefined;
    var zc: [MAX_PATH]u8 = undefined;
    if (rename(z(&za, tmp).?, z(&zc, doc).?) != 0) return error.RenameFailed;
}

fn copyFile(src: []const u8, dst: []const u8) !u64 {
    if (std.fs.path.dirname(dst)) |d| storage.makeParents(d);
    var zs: [MAX_PATH]u8 = undefined;
    var zd: [MAX_PATH]u8 = undefined;
    const in = open(z(&zs, src) orelse return error.PathTooLong, O_RDONLY);
    if (in < 0) return error.OpenFailed;
    defer _ = close(in);
    const out = open(z(&zd, dst) orelse return error.PathTooLong, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
    if (out < 0) return error.OpenFailed;
    defer _ = close(out);
    var buf: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = read(in, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        var done: usize = 0;
        const len: usize = @intCast(n);
        while (done < len) {
            const w = write(out, buf[done..len].ptr, len - done);
            if (w <= 0) return error.WriteFailed;
            done += @intCast(w);
        }
        total += len;
    }
    return total;
}

// ── content identity ───────────────────────────────────────────────────

pub const Sha = [32]u8;

/// Hashes by path, size and modification time, so a file is read once a
/// session however often the project is saved.
const HashCache = struct {
    const N = 1024;
    const Entry = struct { path: [MAX_PATH]u8 = undefined, len: usize = 0, size: i64 = 0, sec: i64 = 0, nsec: i64 = 0, sha: Sha = undefined };
    var entries: [N]Entry = [_]Entry{.{}} ** N;
    var next: usize = 0;
};

pub fn hashFile(path: []const u8, out: *Sha) bool {
    const st = fileStat(path) orelse return false;
    const t = st.mtime();
    for (&HashCache.entries) |*e| if (e.len == path.len and std.mem.eql(u8, e.path[0..e.len], path)) {
        if (e.size == st.size and e.sec == t.sec and e.nsec == t.nsec) {
            out.* = e.sha;
            return true;
        }
    };
    var zb: [MAX_PATH]u8 = undefined;
    const fd = open(z(&zb, path) orelse return false, O_RDONLY);
    if (fd < 0) return false;
    defer _ = close(fd);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n < 0) return false;
        if (n == 0) break;
        h.update(buf[0..@intCast(n)]);
    }
    h.final(out);
    if (path.len <= MAX_PATH) {
        const e = &HashCache.entries[HashCache.next];
        HashCache.next = (HashCache.next + 1) % HashCache.N;
        @memcpy(e.path[0..path.len], path);
        e.* = .{ .path = e.path, .len = path.len, .size = st.size, .sec = t.sec, .nsec = t.nsec, .sha = out.* };
    }
    return true;
}

fn hex(arena: std.mem.Allocator, sha: Sha) ![]const u8 {
    return std.fmt.allocPrint(arena, "{x}", .{&sha});
}

fn sameContent(a: []const u8, b: []const u8) bool {
    var ha: Sha = undefined;
    var hb: Sha = undefined;
    return hashFile(a, &ha) and hashFile(b, &hb) and std.mem.eql(u8, &ha, &hb);
}

// ── references in a document ───────────────────────────────────────────

pub const Use = enum { asset, audio };

/// Visit every file reference in a document: machine assets ("assets"
/// maps, wherever they sit: instruments, effects, rack parts) and audio
/// clips' sources. `ctx.visit(ref, use)` may return a replacement.
fn walk(v: *Value, ctx: anytype) anyerror!void {
    switch (v.*) {
        .array => |*a| for (a.items) |*x| try walk(x, ctx),
        .object => |*o| {
            const audio = if (o.get("type")) |t| t == .string and std.mem.eql(u8, t.string, "audio") else false;
            var it = o.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                if (audio and std.mem.eql(u8, key, "source") and kv.value_ptr.* == .string) {
                    if (try ctx.visit(kv.value_ptr.string, .audio)) |n| kv.value_ptr.* = .{ .string = n };
                } else if (std.mem.eql(u8, key, "assets") and kv.value_ptr.* == .object) {
                    var ai = kv.value_ptr.object.iterator();
                    while (ai.next()) |akv| if (akv.value_ptr.* == .string) {
                        if (try ctx.visit(akv.value_ptr.string, .asset)) |n| akv.value_ptr.* = .{ .string = n };
                    };
                } else try walk(kv.value_ptr, ctx);
            }
        },
        else => {},
    }
}

fn parse(arena: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, json, .{ .parse_numbers = false, .allocate = .alloc_always });
}

// ── collect on save ────────────────────────────────────────────────────

pub const Options = struct {
    /// Copy sample-pack files the project uses into it (settings
    /// "collect_lib"). Off: they stay `lib:` references.
    collect_lib: bool = true,
};

pub const Report = struct {
    /// Files copied into the package by this save.
    copied: usize = 0,
    bytes: u64 = 0,
    /// References whose file doesn't exist; they're written as they were.
    missing: usize = 0,
};

const Collector = struct {
    arena: std.mem.Allocator,
    alloc: std.mem.Allocator,
    pkg: []const u8,
    opts: Options,
    report: *Report,
    table: std.json.ObjectMap,

    fn visit(self: *Collector, reference: []const u8, use: Use) !?[]const u8 {
        if (reference.len == 0) return null;
        var rb: [MAX_PATH]u8 = undefined;
        const abs = storage.resolve(&rb, reference);
        if (!exists(abs)) {
            self.report.missing += 1;
            return null;
        }
        // Inside the package already: project-relative.
        if (under(abs, self.pkg)) {
            const rel = try self.arena.dupe(u8, abs[self.pkg.len + 1 ..]);
            try self.entry(rel, abs, null, null);
            return rel;
        }
        var fb: [MAX_PATH]u8 = undefined;
        const rooted = try self.arena.dupe(u8, storage.ref(&fb, abs));
        const is_lib = std.mem.startsWith(u8, rooted, storage.LIB);
        if (std.mem.startsWith(u8, rooted, storage.FACTORY) or (is_lib and !self.opts.collect_lib)) {
            try self.entry(rooted, abs, null, null);
            return rooted;
        }
        const files = if (use == .asset) try keymap.memberFiles(self.alloc, abs) else blk: {
            const one = try self.alloc.alloc([]u8, 1);
            one[0] = try self.alloc.dupe(u8, abs);
            break :blk one;
        };
        defer {
            keymap.freeFiles(self.alloc, files);
            self.alloc.free(files);
        }
        const rel = try self.collect(abs, files, use, is_lib);
        try self.entry(rel, abs, rooted, files);
        return rel;
    }

    /// Copy `files` (the reference's file first) into the package; returns
    /// the copy of `abs`, project-relative.
    fn collect(self: *Collector, abs: []const u8, files: []const []u8, use: Use, is_lib: bool) ![]const u8 {
        const kind = if (use == .audio) AUDIO else SAMPLES;
        var lb: [MAX_PATH]u8 = undefined;
        const lib = storage.library(&lb);
        const dir_asset = isDir(abs);
        // Where the members' relative layout starts, and the name the
        // asset goes by in the package.
        const base = if (is_lib) lib else if (dir_asset) abs else std.fs.path.dirname(abs) orelse "/";
        const multi = dir_asset or files.len > 1;
        const name = if (is_lib) "" else if (dir_asset) std.fs.path.basename(abs) else if (multi) std.fs.path.stem(abs) else std.fs.path.basename(abs);

        var n: usize = 1;
        while (n < 100) : (n += 1) {
            const at = try self.folder(kind, name, n, is_lib, multi);
            // A name is free when each member's spot is empty or holds
            // the same content.
            const fits = for (files) |f| {
                const dst = try self.dest(at, base, f);
                if (exists(dst) and !sameContent(f, dst)) break false;
            } else true;
            if (!fits and !is_lib) continue;
            for (files) |f| {
                const dst = try self.dest(at, base, f);
                if (exists(dst) and sameContent(f, dst)) continue;
                self.report.bytes += try copyFile(f, dst);
                self.report.copied += 1;
            }
            const root = if (dir_asset) try self.dest(at, base, abs) else try self.dest(at, base, files[0]);
            return try self.arena.dupe(u8, root[self.pkg.len + 1 ..]);
        }
        return error.NoFreeName;
    }

    /// The package folder an asset's members go under.
    fn folder(self: *Collector, kind: []const u8, name: []const u8, n: usize, is_lib: bool, multi: bool) ![]const u8 {
        if (is_lib) return std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.pkg, kind });
        if (multi) return if (n == 1)
            std.fmt.allocPrint(self.arena, "{s}/{s}/{s}", .{ self.pkg, kind, name })
        else
            std.fmt.allocPrint(self.arena, "{s}/{s}/{s}-{d}", .{ self.pkg, kind, name, n });
        // One file: the suffix goes on its stem, not on a folder.
        if (n == 1) return std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.pkg, kind });
        return std.fmt.allocPrint(self.arena, "{s}/{s}/{d}", .{ self.pkg, kind, n });
    }

    /// Where member `f` lands under folder `at`: at its path below `base`, or
    /// by name when it sits outside it.
    fn dest(self: *Collector, at: []const u8, base: []const u8, f: []const u8) ![]const u8 {
        const rel = if (under(f, base)) f[base.len + 1 ..] else if (std.mem.eql(u8, f, base)) "" else std.fs.path.basename(f);
        if (rel.len == 0) return at;
        return std.fmt.allocPrint(self.arena, "{s}/{s}", .{ at, rel });
    }

    /// The asset table's entry for `key`: the file's hash, where a copy
    /// came from, and an SFZ's or a folder's member files.
    fn entry(self: *Collector, key: []const u8, abs: []const u8, origin: ?[]const u8, files: ?[]const []u8) !void {
        if (self.table.contains(key)) return;
        var e = std.json.ObjectMap.empty;
        var rb: [MAX_PATH]u8 = undefined;
        const local = storage.resolve(&rb, key);
        const target = if (under(local, self.pkg)) local else abs;
        var sha: Sha = undefined;
        if (!isDir(target) and hashFile(target, &sha)) try e.put(self.arena, "sha256", .{ .string = try hex(self.arena, sha) });
        if (origin) |o| try e.put(self.arena, "origin", .{ .string = o });
        if (files) |fs| if (fs.len > 1 or isDir(abs)) {
            // Members by their place in the package.
            var m = std.json.ObjectMap.empty;
            const root_dir = if (isDir(target)) target else std.fs.path.dirname(target) orelse self.pkg;
            _ = root_dir;
            var it = MemberIter{ .c = self, .key = key, .abs = abs, .files = fs };
            while (try it.next()) |pair| try m.put(self.arena, pair.rel, .{ .string = pair.sha });
            try e.put(self.arena, "files", .{ .object = m });
        };
        try self.table.put(self.arena, key, .{ .object = e });
    }

    const MemberIter = struct {
        c: *Collector,
        key: []const u8,
        abs: []const u8,
        files: []const []u8,
        i: usize = 0,

        /// Each member's copy, project-relative, and its hash. The copy
        /// sits where collect() put it: beside the root, at the member's
        /// path relative to the original root's folder.
        fn next(it: *MemberIter) !?struct { rel: []const u8, sha: []const u8 } {
            while (it.i < it.files.len) {
                const f = it.files[it.i];
                it.i += 1;
                var rb: [MAX_PATH]u8 = undefined;
                const root_copy = storage.resolve(&rb, it.key);
                const src_base = if (isDir(it.abs)) it.abs else std.fs.path.dirname(it.abs) orelse "/";
                const dst_base = if (isDir(it.abs)) root_copy else std.fs.path.dirname(root_copy) orelse it.c.pkg;
                const rel_in = if (under(f, src_base)) f[src_base.len + 1 ..] else std.fs.path.basename(f);
                const copy = try std.fmt.allocPrint(it.c.arena, "{s}/{s}", .{ dst_base, rel_in });
                var sha: Sha = undefined;
                if (!hashFile(copy, &sha) and !hashFile(f, &sha)) continue;
                const rel = if (under(copy, it.c.pkg)) copy[it.c.pkg.len + 1 ..] else copy;
                return .{ .rel = rel, .sha = try hex(it.c.arena, sha) };
            }
            return null;
        }
    };
};

fn under(path: []const u8, root: []const u8) bool {
    return root.len > 0 and path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// Collect `json`'s files into the package at `pkg` (absolute, the
/// project folder storage resolves against) and return the document to
/// write: references rewritten to the copies, and the "assets" table.
pub fn collect(alloc: std.mem.Allocator, pkg: []const u8, json: []const u8, opts: Options, report: *Report) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = try parse(arena, json);
    if (root != .object) return error.NotAProject;
    var c = Collector{ .arena = arena, .alloc = alloc, .pkg = pkg, .opts = opts, .report = report, .table = std.json.ObjectMap.empty };
    try walk(&root, &c);
    _ = root.object.orderedRemove("assets");
    try root.object.put(arena, "assets", .{ .object = c.table });
    return std.json.Stringify.valueAlloc(alloc, root, .{});
}

// ── load: what's missing ───────────────────────────────────────────────

pub const Missing = struct {
    count: usize = 0,
    /// The first few, by reference, for a status line.
    first: [3][]const u8 = undefined,
    names: [3][MAX_PATH]u8 = undefined,
    shown: usize = 0,

    fn visit(self: *Missing, reference: []const u8, _: Use) !?[]const u8 {
        if (reference.len == 0) return null;
        var rb: [MAX_PATH]u8 = undefined;
        if (exists(storage.resolve(&rb, reference))) return null;
        self.count += 1;
        std.log.warn("missing file: {s}", .{reference});
        if (self.shown < self.first.len and reference.len <= MAX_PATH) {
            @memcpy(self.names[self.shown][0..reference.len], reference);
            self.first[self.shown] = self.names[self.shown][0..reference.len];
            self.shown += 1;
        }
        return null;
    }
};

/// The files `json` names that aren't there (resolved against the
/// project folder storage has).
pub fn missing(alloc: std.mem.Allocator, json: []const u8) Missing {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var m = Missing{};
    var root = parse(arena_state.allocator(), json) catch return m;
    walk(&root, &m) catch {};
    return m;
}

// ── Clean Up ───────────────────────────────────────────────────────────

/// Remove the files in the package's data folders that the saved project
/// doesn't name (its asset table: keys and members). `remove` takes each
/// path (the app moves it to the Trash). Returns how many went.
pub fn cleanUp(alloc: std.mem.Allocator, pkg: []const u8, remove: *const fn ([]const u8) bool) !usize {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var db: [MAX_PATH]u8 = undefined;
    const doc_path = try std.fmt.bufPrint(&db, "{s}/{s}", .{ pkg, DOC });
    const bytes = readAll(arena, doc_path) orelse return error.NoProject;
    const root = try parse(arena, bytes);
    if (root != .object) return error.NotAProject;
    var keep = std.StringHashMap(void).init(arena);
    if (root.object.get("assets")) |t| if (t == .object) {
        var it = t.object.iterator();
        while (it.next()) |kv| {
            try keepPath(&keep, arena, pkg, kv.key_ptr.*);
            if (kv.value_ptr.* == .object) if (kv.value_ptr.object.get("files")) |fs| if (fs == .object) {
                var fi = fs.object.iterator();
                while (fi.next()) |f| try keepPath(&keep, arena, pkg, f.key_ptr.*);
            };
        }
    };
    var removed: usize = 0;
    for (DATA_DIRS) |d| {
        const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ pkg, d });
        removed += try sweep(arena, dir, &keep, remove);
    }
    return removed;
}

fn keepPath(keep: *std.StringHashMap(void), arena: std.mem.Allocator, pkg: []const u8, key: []const u8) !void {
    for ([_][]const u8{ storage.LIB, storage.FACTORY, storage.USER }) |p| if (std.mem.startsWith(u8, key, p)) return;
    const rel = if (std.mem.startsWith(u8, key, storage.PROJECT)) key[storage.PROJECT.len..] else key;
    if (rel.len > 0 and rel[0] == '/') return;
    try keep.put(try std.fmt.allocPrint(arena, "{s}/{s}", .{ pkg, rel }), {});
}

fn sweep(arena: std.mem.Allocator, dir: []const u8, keep: *std.StringHashMap(void), remove: *const fn ([]const u8) bool) !usize {
    var zb: [MAX_PATH]u8 = undefined;
    const d = opendir(z(&zb, dir) orelse return 0) orelse return 0;
    defer _ = closedir(d);
    var removed: usize = 0;
    while (readdir(d)) |e| {
        const name = e.d_name[0..e.d_namlen];
        if (name.len == 0 or name[0] == '.') continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        // A kept folder (a folder kit) keeps all it holds.
        if (keep.contains(full)) continue;
        if (e.d_type == DT_DIR) {
            removed += try sweep(arena, full, keep, remove);
        } else if (remove(full)) removed += 1;
    }
    return removed;
}

fn readAll(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zb: [MAX_PATH]u8 = undefined;
    const fd = open(z(&zb, path) orelse return null, O_RDONLY);
    if (fd < 0) return null;
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n < 0) return null;
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..@intCast(n)]) catch return null;
    }
    return out.toOwnedSlice(alloc) catch null;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpRoot(buf: []u8, tmp: *const std.testing.TmpDir) []const u8 {
    var rb: [MAX_PATH]u8 = undefined;
    const rel = std.fmt.bufPrint(&rb, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
    return storage.absolute(buf, rel);
}

var removed_paths: [16][MAX_PATH]u8 = undefined;
var removed_count: usize = 0;
fn recordRemove(path: []const u8) bool {
    if (removed_count < removed_paths.len) {
        @memcpy(removed_paths[removed_count][0..path.len], path);
        removed_count += 1;
    }
    var zb: [MAX_PATH]u8 = undefined;
    _ = std.c.unlink(z(&zb, path).?);
    return true;
}

test "package: a bare file becomes a package, files are collected once, Clean Up sweeps" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [MAX_PATH]u8 = undefined;
    const root = tmpRoot(&rb, &tmp);

    // An outside sample, an outside SFZ with its sample in a subfolder, and
    // a bare project file.
    var pb: [MAX_PATH]u8 = undefined;
    const wav_path = try std.fmt.bufPrint(&pb, "{s}/elsewhere/hit.wav", .{root});
    storage.makeParents(std.fs.path.dirname(wav_path).?);
    try writeAll(wav_path, "RIFF-hit");
    var sb: [MAX_PATH]u8 = undefined;
    const sfz_path = try std.fmt.bufPrint(&sb, "{s}/elsewhere/kit/kit.sfz", .{root});
    storage.makeParents(std.fs.path.dirname(sfz_path).?);
    try writeAll(sfz_path, "<region> sample=smp/a.wav key=60\n<region> sample=smp/missing.wav key=61\n");
    var ab: [MAX_PATH]u8 = undefined;
    storage.makeParents(try std.fmt.bufPrint(&ab, "{s}/elsewhere/kit/smp", .{root}));
    try writeAll(try std.fmt.bufPrint(&ab, "{s}/elsewhere/kit/smp/a.wav", .{root}), "RIFF-a");

    // The factory is a folder of its own here: the test's files sit in the
    // repo, which a dev build takes for the factory.
    var fab: [MAX_PATH]u8 = undefined;
    const fac = try std.fmt.bufPrintZ(&fab, "{s}/factory", .{root});
    try writeFileMaking(try std.fmt.bufPrint(&ab, "{s}/machines/sampler/assets/default.wav", .{fac}), "RIFF-f");
    _ = setenv("SLAB_FACTORY", fac.ptr, 1);
    defer _ = unsetenv("SLAB_FACTORY");

    var kb: [MAX_PATH]u8 = undefined;
    const pkg = try std.fmt.bufPrint(&kb, "{s}/Song.slab", .{root});
    try writeAll(pkg, "{\"schema\":1}");
    try prepare(pkg);
    try testing.expect(isPackage(pkg));
    var db: [MAX_PATH]u8 = undefined;
    try testing.expect(exists(docPath(&db, pkg)));

    defer storage.setProject(null);
    storage.setProject(docPath(&db, pkg));
    const json = try std.fmt.allocPrint(alloc,
        \\{{"schema":1,"tracks":[{{"instrument":{{"machine":"sampler","assets":{{"smp":"{s}","kit":"{s}"}},"params":{{"x":0.10}}}},
        \\"clips":[{{"type":"audio","source":"{s}"}},{{"type":"audio","source":"factory:machines/sampler/assets/default.wav"}},{{"type":"audio","source":"/nowhere.wav"}}]}}]}}
    , .{ wav_path, sfz_path, wav_path });
    defer alloc.free(json);

    var rep = Report{};
    const out = try collect(alloc, pkg, json, .{}, &rep);
    defer alloc.free(out);
    // hit.wav twice (as a sample and as audio), the SFZ and its one sample.
    try testing.expectEqual(@as(usize, 4), rep.copied);
    try testing.expectEqual(@as(usize, 1), rep.missing);
    try testing.expect(std.mem.indexOf(u8, out, "\"smp\":\"samples/hit.wav\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kit\":\"samples/kit/kit.sfz\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"source\":\"audio/hit.wav\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"source\":\"factory:machines/sampler/assets/default.wav\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"source\":\"/nowhere.wav\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"x\":0.10") != null); // numbers kept as written
    try testing.expect(std.mem.indexOf(u8, out, "\"samples/kit/smp/a.wav\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"origin\":\"") != null);
    var cb: [MAX_PATH]u8 = undefined;
    try testing.expect(exists(try std.fmt.bufPrint(&cb, "{s}/samples/kit/smp/a.wav", .{pkg})));

    // A second save copies nothing new; a changed outside file of the
    // same name lands beside the first instead of over it.
    var rep2 = Report{};
    const out2 = try collect(alloc, pkg, json, .{}, &rep2);
    defer alloc.free(out2);
    try testing.expectEqual(@as(usize, 0), rep2.copied);
    try writeAll(wav_path, "RIFF-hit-v2");
    var rep3 = Report{};
    const out3 = try collect(alloc, pkg, json, .{}, &rep3);
    defer alloc.free(out3);
    try testing.expect(std.mem.indexOf(u8, out3, "\"smp\":\"samples/2/hit.wav\"") != null);

    // The project on disk names the new copies; the old ones go.
    try writeDoc(pkg, out3);
    removed_count = 0;
    const n = try cleanUp(alloc, pkg, recordRemove);
    try testing.expectEqual(@as(usize, 2), n); // samples/hit.wav, audio/hit.wav
    try testing.expect(exists(try std.fmt.bufPrint(&cb, "{s}/samples/2/hit.wav", .{pkg})));
    try testing.expect(exists(try std.fmt.bufPrint(&cb, "{s}/samples/kit/smp/a.wav", .{pkg})));

    // What a load finds missing.
    const m = missing(alloc, out3);
    try testing.expectEqual(@as(usize, 1), m.count);
    try testing.expectEqualStrings("/nowhere.wav", m.first[0]);
}

test "package: pack files stay references when collecting them is off" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rb: [MAX_PATH]u8 = undefined;
    const root = tmpRoot(&rb, &tmp);
    var kb: [MAX_PATH]u8 = undefined;
    const pkg = try std.fmt.bufPrint(&kb, "{s}/P.slab", .{root});
    try prepare(pkg);
    var lb: [MAX_PATH]u8 = undefined;
    const lib = storage.library(&lb);
    if (!isDir(lib)) return error.SkipZigTest;
    // Any file in the library will do.
    var fb: [MAX_PATH]u8 = undefined;
    const f = findFile(&fb, lib, 3) orelse return error.SkipZigTest;
    var refb: [MAX_PATH]u8 = undefined;
    const r = storage.ref(&refb, f);
    try testing.expect(std.mem.startsWith(u8, r, storage.LIB));
    const json = try std.fmt.allocPrint(alloc, "{{\"tracks\":[{{\"clips\":[{{\"type\":\"audio\",\"source\":\"{s}\"}}]}}]}}", .{r});
    defer alloc.free(json);
    var rep = Report{};
    const out = try collect(alloc, pkg, json, .{ .collect_lib = false }, &rep);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 0), rep.copied);
    try testing.expect(std.mem.indexOf(u8, out, r) != null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn writeFileMaking(path: []const u8, bytes: []const u8) !void {
    storage.makeParents(std.fs.path.dirname(path).?);
    try writeAll(path, bytes);
}

fn findFile(buf: []u8, dir: []const u8, depth: usize) ?[]const u8 {
    var zb: [MAX_PATH]u8 = undefined;
    const d = opendir(z(&zb, dir) orelse return null) orelse return null;
    defer _ = closedir(d);
    while (readdir(d)) |e| {
        const name = e.d_name[0..e.d_namlen];
        if (name.len == 0 or name[0] == '.') continue;
        const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return null;
        if (e.d_type == DT_REG) return full;
        if (e.d_type == DT_DIR and depth > 0) {
            var nb: [MAX_PATH]u8 = undefined;
            @memcpy(nb[0..full.len], full);
            if (findFile(buf, nb[0..full.len], depth - 1)) |found| return found;
        }
    }
    return null;
}
