//! Crash recovery (docs/46): while a project has unsaved changes Slab keeps
//! a copy of it in ~/Library/Application Support/Slab/Recovery, one file
//! per running session. A clean quit with everything saved removes it; a
//! crash (or a quit without saving) leaves it, and the next start offers
//! the work back.
//!
//! A file is `<pid>.recovery`: a tag line, the chosen flag, the time, the
//! project's path, then the document. A file whose process is gone is
//! stale; one whose process runs belongs to another Slab and is left alone.

const std = @import("std");
const storage = @import("storage.zig");

const MAX_PATH = storage.MAX_PATH;
const TAG = "SLAB-RECOVERY 1";
/// Unrecovered files older than this many seconds are dropped.
const MAX_AGE: i64 = 14 * 24 * 3600;

extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
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

/// What a crashed session left.
pub const Recovered = struct {
    /// The document; owned.
    doc: []u8,
    /// The project it was (owned): its path, and whether the user had
    /// saved it somewhere (false for the untitled project).
    path: []u8,
    chosen: bool,
    /// When it was written (seconds since the epoch).
    time: i64,

    pub fn deinit(self: Recovered, alloc: std.mem.Allocator) void {
        alloc.free(self.doc);
        alloc.free(self.path);
    }
};

/// The folder ($SLAB_RECOVERY overrides it).
pub fn dir(buf: []u8) []const u8 {
    if (std.c.getenv("SLAB_RECOVERY")) |e| return std.fmt.bufPrint(buf, "{s}", .{std.mem.span(e)}) catch "";
    const h = if (std.c.getenv("HOME")) |e| std.mem.span(e) else "";
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/Slab/Recovery", .{h}) catch "";
}

fn filePath(buf: []u8, folder: []const u8, pid: c_int) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{d}.recovery", .{ folder, pid }) catch "";
}

fn zpath(buf: []u8, s: []const u8) ?[*:0]const u8 {
    const r = std.mem.printSentinel(buf, "{s}", .{s}, 0) catch return null;
    return r.ptr;
}

fn writeFileAtomic(path: []const u8, parts: []const []const u8) bool {
    var tb: [MAX_PATH + 8]u8 = undefined;
    var pb: [MAX_PATH + 8]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.tmp", .{path}) catch return false;
    const zt = zpath(&pb, tmp) orelse return false;
    const fd = open(zt, 0x0001 | 0x0200 | 0x0400, @as(c_uint, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) return false;
    var ok = true;
    for (parts) |bytes| {
        var done: usize = 0;
        while (done < bytes.len) {
            const w = write(fd, bytes[done..].ptr, bytes.len - done);
            if (w <= 0) {
                ok = false;
                break;
            }
            done += @intCast(w);
        }
    }
    _ = close(fd);
    var qb: [MAX_PATH + 8]u8 = undefined;
    const zq = zpath(&qb, path) orelse return false;
    if (!ok or rename(zt, zq) != 0) {
        _ = unlink(zt);
        return false;
    }
    return true;
}

/// Keep `doc` (the project at `project_path`) for this session.
pub fn save(project_path: []const u8, chosen: bool, doc: []const u8) bool {
    var db: [MAX_PATH]u8 = undefined;
    return saveIn(dir(&db), getpid(), project_path, chosen, doc, time(null));
}

fn saveIn(folder: []const u8, pid: c_int, project_path: []const u8, chosen: bool, doc: []const u8, when: i64) bool {
    storage.makeParents(folder);
    var pb: [MAX_PATH]u8 = undefined;
    var hb: [MAX_PATH + 64]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "{s}\n{d}\n{d}\n{s}\n", .{ TAG, @intFromBool(chosen), when, project_path }) catch return false;
    return writeFileAtomic(filePath(&pb, folder, pid), &.{ head, doc });
}

/// This session has nothing to recover (everything is saved).
pub fn clear() void {
    var db: [MAX_PATH]u8 = undefined;
    clearIn(dir(&db), getpid());
}

fn clearIn(folder: []const u8, pid: c_int) void {
    var pb: [MAX_PATH]u8 = undefined;
    var zb: [MAX_PATH + 8]u8 = undefined;
    if (zpath(&zb, filePath(&pb, folder, pid))) |z| _ = unlink(z);
}

fn alive(pid: c_int) bool {
    if (pid <= 0) return false;
    if (kill(pid, 0) == 0) return true;
    // EPERM: it exists, and isn't ours to signal.
    return std.c._errno().* == @intFromEnum(std.c.E.PERM);
}

fn parse(alloc: std.mem.Allocator, bytes: []const u8) ?Recovered {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, it.next() orelse return null, TAG)) return null;
    const chosen = std.mem.eql(u8, it.next() orelse return null, "1");
    const when = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const path = it.next() orelse return null;
    const doc = it.rest();
    if (doc.len == 0) return null;
    const p = alloc.dupe(u8, path) catch return null;
    const d = alloc.dupe(u8, doc) catch {
        alloc.free(p);
        return null;
    };
    return .{ .doc = d, .path = p, .chosen = chosen, .time = when };
}

/// The newest work a dead session left, or null. Every stale file is
/// removed (older ones are superseded, unreadable ones are junk).
pub fn takeStale(alloc: std.mem.Allocator) ?Recovered {
    var db: [MAX_PATH]u8 = undefined;
    return takeStaleIn(alloc, dir(&db), getpid());
}

fn takeStaleIn(alloc: std.mem.Allocator, folder: []const u8, own: c_int) ?Recovered {
    var zb: [MAX_PATH + 8]u8 = undefined;
    const d = opendir(zpath(&zb, folder) orelse return null) orelse return null;
    var best: ?Recovered = null;
    var stale: [64]c_int = undefined;
    var n: usize = 0;
    while (readdir(d)) |e| {
        const name = std.mem.sliceTo(&e.d_name, 0);
        if (!std.mem.endsWith(u8, name, ".recovery")) continue;
        const pid = std.fmt.parseInt(c_int, name[0 .. name.len - ".recovery".len], 10) catch continue;
        if (pid == own or alive(pid)) continue;
        if (n < stale.len) {
            stale[n] = pid;
            n += 1;
        }
    }
    _ = closedir(d);
    const now = time(null);
    for (stale[0..n]) |pid| {
        var pb: [MAX_PATH]u8 = undefined;
        defer clearIn(folder, pid);
        const bytes = storage.readFile(alloc, filePath(&pb, folder, pid)) orelse continue;
        defer alloc.free(bytes);
        const r = parse(alloc, bytes) orelse continue;
        if (now - r.time > MAX_AGE or (best != null and best.?.time >= r.time)) {
            r.deinit(alloc);
            continue;
        }
        if (best) |old| old.deinit(alloc);
        best = r;
    }
    return best;
}

test "a dead session's work comes back once, the newest first" {
    const alloc = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const folder = try std.fmt.bufPrint(&buf, "/private/tmp/slab-recovery-test-{d}", .{getpid()});
    // Two dead sessions (no such pids) and this one.
    const now = time(null);
    try std.testing.expect(saveIn(folder, 2_000_001, "a.slab", true, "{\"older\":1}", now - 60));
    try std.testing.expect(saveIn(folder, 2_000_002, "slab-project.slab", false, "{\"newer\":1}\nwith lines", now));
    try std.testing.expect(saveIn(folder, 7, "own.slab", true, "{}", now));
    const got = takeStaleIn(alloc, folder, 7) orelse return error.TestUnexpectedResult;
    defer got.deinit(alloc);
    try std.testing.expectEqualStrings("{\"newer\":1}\nwith lines", got.doc);
    try std.testing.expectEqualStrings("slab-project.slab", got.path);
    try std.testing.expect(!got.chosen);
    // Taken: nothing is left of the dead sessions, and the live file stays.
    try std.testing.expect(takeStaleIn(alloc, folder, 7) == null);
    clearIn(folder, 7);
    var zb: [160]u8 = undefined;
    _ = rmdir(zpath(&zb, folder).?);
}

test "a file that isn't a recovery file parses to nothing" {
    try std.testing.expect(parse(std.testing.allocator, "hello") == null);
    try std.testing.expect(parse(std.testing.allocator, TAG ++ "\n1\n5\npath\n") == null);
}
