//! Sample packs (docs/25 §Packs): what slab knows of them, from the
//! manifests in `factory:packs/*.pack.json`, and where each stands in the
//! library: installed, waiting for its files, ready to import, importing.
//!
//! A pack counts as installed when `<library>/<id>/presets/` exists (its
//! importer writes the pack's presets there, §Pack presets), so the
//! folders set up by hand before manifests existed show up installed as
//! they are. A library folder no manifest names is listed too, as the
//! user's own.
//!
//! Importing still runs the pack's Python tool from tools/library/ in a
//! child process (`Job`), with its output in `<home>/Cache/packs/<id>.log`;
//! slab's own downloader and importers replace it later in phase 5.
//! Everything here runs on the UI thread.

const std = @import("std");
const storage = @import("storage.zig");

pub const Expect = struct {
    name: []const u8 = "",
    /// A file name pattern (`*`, `?`, any case); `**/` in front matches
    /// at any depth.
    glob: []const u8 = "",
    also: []const []const u8 = &.{},
    min: u32 = 1,
};

pub const Supply = struct {
    into: []const u8 = "_sources",
    expect: []const Expect = &.{},
    /// Ready when any expectation is met (else all of them).
    any: bool = false,
    help: []const u8 = "",
};

pub const Instructions = struct {
    text: []const u8 = "",
    link: []const u8 = "",
};

pub const Download = struct {
    url: []const u8 = "",
    sha256: []const u8 = "",
};

pub const Get = struct {
    download: ?[]const Download = null,
    supply: ?Supply = null,
    instructions: ?Instructions = null,
};

/// `<id>.pack.json`, `"slab": "pack"`, schema 1 (docs/25 §The pack manifest).
pub const Manifest = struct {
    slab: []const u8 = "pack",
    schema: u32 = 1,
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    license: []const u8 = "",
    redistributable: bool = false,
    size: u64 = 0,
    about: []const u8 = "",
    link: []const u8 = "",
    get: Get = .{},
    import: []const u8 = "",
};

pub const State = enum {
    /// Can be downloaded.
    available,
    /// Bought or fetched elsewhere: the card says how.
    instructions,
    /// Waiting for the user's files in `<id>/<supply.into>`.
    needs_files,
    /// The files are there; IMPORT turns them into presets.
    ready,
    /// The importer is running.
    running,
    installed,
};

pub const MAX_EXPECT = 4;

pub const Pack = struct {
    m: Manifest,
    /// Named by a manifest (else a library folder slab found on its own).
    known: bool,
    state: State = .installed,
    /// Files found per expectation, while it waits for them.
    found: [MAX_EXPECT]u32 = @splat(0),
    /// What the library lists from it.
    presets: u32 = 0,
    samples: u32 = 0,
    /// Its importer's last run, if any this session.
    job: ?usize = null,

    pub fn canImport(self: *const Pack) bool {
        return self.m.import.len > 0 and command(self.m.import) != null;
    }
};

pub const MAX_JOBS = 8;

pub const Job = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    pid: c_int = 0,
    running: bool = false,
    ok: bool = false,
    cancelled: bool = false,
    log: [storage.MAX_PATH]u8 = undefined,
    log_len: usize = 0,
    /// The output's last line, for the card.
    line: [160]u8 = undefined,
    line_len: usize = 0,

    pub fn idSlice(self: *const Job) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn lastLine(self: *const Job) []const u8 {
        return self.line[0..self.line_len];
    }

    pub fn logPath(self: *const Job) []const u8 {
        return self.log[0..self.log_len];
    }
};

pub const Catalog = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    packs: std.ArrayList(Pack) = .empty,
    jobs: [MAX_JOBS]Job = undefined,
    n_jobs: usize = 0,
    /// Packs the user said they have the files for ("I HAVE THE FILES").
    have: [8][64]u8 = undefined,
    have_len: [8]usize = undefined,
    n_have: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Catalog {
        return .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Catalog) void {
        // An import left running goes with the app; the tools resume.
        for (self.jobs[0..self.n_jobs]) |*j| if (j.running) {
            _ = kill(j.pid, SIGTERM);
        };
        self.packs.deinit(self.alloc);
        self.arena.deinit();
    }

    /// Read the manifests and look at the library again.
    pub fn scan(self: *Catalog) void {
        self.packs.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var fb: [storage.MAX_PATH]u8 = undefined;
        const factory = storage.factory(&fb);
        var db: [storage.MAX_PATH]u8 = undefined;
        if (factory.len > 0) if (Dir.open(std.fmt.bufPrint(&db, "{s}/packs", .{factory}) catch "")) |dir_| {
            var dir = dir_;
            defer dir.close();
            while (dir.next()) |e| {
                if (e.dir or !std.mem.endsWith(u8, e.name, ".pack.json")) continue;
                var pb: [storage.MAX_PATH]u8 = undefined;
                const path = std.fmt.bufPrint(&pb, "{s}/packs/{s}", .{ factory, e.name }) catch continue;
                const m = readManifest(a, path) orelse continue;
                if (self.find(m.id) != null) continue;
                self.packs.append(self.alloc, .{ .m = m, .known = true }) catch {};
            }
        };
        // Library folders no manifest names: the user's own packs.
        var lb: [storage.MAX_PATH]u8 = undefined;
        const lib = storage.library(&lb);
        if (Dir.open(lib)) |dir_| {
            var dir = dir_;
            defer dir.close();
            while (dir.next()) |e| {
                if (!e.dir or e.name[0] == '.' or self.find(e.name) != null) continue;
                const id = a.dupe(u8, e.name) catch continue;
                self.packs.append(self.alloc, .{ .m = .{ .id = id, .name = id }, .known = false }) catch {};
            }
        }
        std.mem.sort(Pack, self.packs.items, {}, packLess);
        for (self.packs.items) |*p| self.refresh(p);
    }

    /// Work out one pack's state (and count its files while it waits).
    pub fn refresh(self: *Catalog, p: *Pack) void {
        p.job = self.jobFor(p.m.id);
        if (p.job) |j| if (self.jobs[j].running) {
            p.state = .running;
            return;
        };
        var lb: [storage.MAX_PATH]u8 = undefined;
        const lib = storage.library(&lb);
        var b: [storage.MAX_PATH]u8 = undefined;
        // Installed: its presets are there (a sample pack), or its models
        // (the Extract pack, docs/30 §Stems).
        if (!p.known or exists(std.fmt.bufPrint(&b, "{s}/{s}/presets", .{ lib, p.m.id }) catch "") or
            exists(std.fmt.bufPrint(&b, "{s}/{s}/models", .{ lib, p.m.id }) catch ""))
        {
            p.state = .installed;
            return;
        }
        const g = &p.m.get;
        if (g.supply) |s| {
            const src = std.fmt.bufPrint(&b, "{s}/{s}/{s}", .{ lib, p.m.id, s.into }) catch "";
            const brought = exists(src) or self.hasFiles(p.m.id) or (g.instructions == null and g.download == null);
            if (brought) {
                countExpected(src, s.expect, &p.found);
                p.state = if (met(s, &p.found)) .ready else .needs_files;
                return;
            }
        }
        p.state = if (g.instructions != null) .instructions else if (g.download != null) .available else .needs_files;
    }

    pub fn find(self: *Catalog, id: []const u8) ?*Pack {
        for (self.packs.items) |*p| if (std.mem.eql(u8, p.m.id, id)) return p;
        return null;
    }

    /// May the files of library folder `id` be published? Unknown packs
    /// are taken as the user's alone.
    pub fn redistributable(self: *Catalog, id: []const u8) bool {
        const p = self.find(id) orelse return false;
        return p.known and p.m.redistributable;
    }

    /// The user has the files: the card asks for them.
    pub fn markHave(self: *Catalog, id: []const u8) void {
        if (self.hasFiles(id) or self.n_have == self.have.len or id.len > 64) return;
        @memcpy(self.have[self.n_have][0..id.len], id);
        self.have_len[self.n_have] = id.len;
        self.n_have += 1;
    }

    fn hasFiles(self: *const Catalog, id: []const u8) bool {
        for (0..self.n_have) |i| if (std.mem.eql(u8, self.have[i][0..self.have_len[i]], id)) return true;
        return false;
    }

    /// `<library>/<id>/<supply.into>`, created, for SHOW FOLDER.
    pub fn sourcesDir(self: *Catalog, buf: []u8, p: *const Pack) []const u8 {
        _ = self;
        var lb: [storage.MAX_PATH]u8 = undefined;
        const lib = storage.library(&lb);
        const into = if (p.m.get.supply) |s| s.into else "_sources";
        const d = std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ lib, p.m.id, into }) catch return "";
        storage.makeParents(d);
        return d;
    }

    /// `<library>/<id>`.
    pub fn packDir(buf: []u8, id: []const u8) []const u8 {
        var lb: [storage.MAX_PATH]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ storage.library(&lb), id }) catch "";
    }

    fn jobFor(self: *const Catalog, id: []const u8) ?usize {
        for (self.jobs[0..self.n_jobs], 0..) |*j, i| if (std.mem.eql(u8, j.idSlice(), id)) return i;
        return null;
    }

    /// Run pack `p`'s importer (which downloads, for a download pack).
    /// Returns a reason when it can't start.
    pub fn startImport(self: *Catalog, p: *Pack) ?[]const u8 {
        const cmd = command(p.m.import) orelse return "NO IMPORTER FOR THIS PACK";
        if (p.m.id.len > 64) return "PACK ID TOO LONG";
        const j = self.jobFor(p.m.id) orelse blk: {
            if (self.n_jobs == MAX_JOBS) return "TOO MANY IMPORTS AT ONCE";
            self.n_jobs += 1;
            break :blk self.n_jobs - 1;
        };
        const job = &self.jobs[j];
        if (job.running) return "ALREADY IMPORTING";
        job.* = .{};
        @memcpy(job.id[0..p.m.id.len], p.m.id);
        job.id_len = p.m.id.len;

        var hb: [storage.MAX_PATH]u8 = undefined;
        const home = storage.home(&hb);
        var cb: [storage.MAX_PATH]u8 = undefined;
        const cache = std.fmt.bufPrint(&cb, "{s}/Cache/packs", .{home}) catch return "NO HOME FOLDER";
        storage.makeParents(cache);
        const log = std.fmt.bufPrint(&job.log, "{s}/{s}.log", .{ cache, p.m.id }) catch return "NO HOME FOLDER";
        job.log_len = log.len;

        // argv: python, -u, the tool, its arguments.
        var fb: [storage.MAX_PATH]u8 = undefined;
        const factory = storage.factory(&fb);
        var lb: [storage.MAX_PATH]u8 = undefined;
        const lib = storage.library(&lb);
        var strs: [8][storage.MAX_PATH:0]u8 = undefined;
        var argv: [9:null]?[*:0]const u8 = @splat(null);
        var n: usize = 0;
        const py = python() orelse return "PYTHON 3 NOT FOUND";
        argv[n] = z(&strs[n], py);
        n += 1;
        argv[n] = z(&strs[n], "-u");
        n += 1;
        var tb: [storage.MAX_PATH]u8 = undefined;
        argv[n] = z(&strs[n], std.fmt.bufPrint(&tb, "{s}/{s}", .{ factory, cmd.tool }) catch return "PATH TOO LONG");
        n += 1;
        for (cmd.args) |arg| {
            if (std.mem.eql(u8, arg, "$sources")) {
                var sb: [storage.MAX_PATH]u8 = undefined;
                argv[n] = z(&strs[n], std.fmt.bufPrint(&sb, "{s}/{s}/_sources", .{ lib, p.m.id }) catch return "PATH TOO LONG");
            } else argv[n] = z(&strs[n], arg);
            n += 1;
        }

        // The environment, with the library the app uses (settings.json
        // can move the home folder, which the tools can't see).
        var env_buf: [256:null]?[*:0]const u8 = @splat(null);
        var ne: usize = 0;
        var i: usize = 0;
        while (environ[i]) |e| : (i += 1) {
            if (ne + 2 >= env_buf.len) break;
            if (std.mem.startsWith(u8, std.mem.sliceTo(e, 0), "SLAB_LIBRARY=")) continue;
            env_buf[ne] = e;
            ne += 1;
        }
        var lib_env: [storage.MAX_PATH + 16:0]u8 = undefined;
        const le = std.fmt.bufPrintZ(&lib_env, "SLAB_LIBRARY={s}", .{lib}) catch return "PATH TOO LONG";
        env_buf[ne] = le.ptr;

        var fa: SpawnActions = null;
        if (posix_spawn_file_actions_init(&fa) != 0) return "COULDN'T START THE IMPORTER";
        defer _ = posix_spawn_file_actions_destroy(&fa);
        var log_z: [storage.MAX_PATH:0]u8 = undefined;
        _ = posix_spawn_file_actions_addopen(&fa, 1, z(&log_z, log), O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        _ = posix_spawn_file_actions_adddup2(&fa, 1, 2);
        var pid: c_int = 0;
        if (posix_spawn(&pid, argv[0].?, &fa, null, &argv, &env_buf) != 0) return "COULDN'T START THE IMPORTER";
        job.pid = pid;
        job.running = true;
        self.refresh(p);
        return null;
    }

    pub fn cancel(self: *Catalog, p: *const Pack) void {
        const j = p.job orelse return;
        const job = &self.jobs[j];
        if (!job.running) return;
        job.cancelled = true;
        _ = kill(job.pid, SIGTERM);
    }

    pub fn jobOf(self: *Catalog, p: *const Pack) ?*Job {
        return &self.jobs[p.job orelse return null];
    }

    /// Check on running imports. True when one finished (rescan the library).
    pub fn poll(self: *Catalog) bool {
        var finished = false;
        for (self.jobs[0..self.n_jobs]) |*j| {
            if (!j.running) continue;
            readLastLine(j);
            var status: c_int = 0;
            const r = waitpid(j.pid, &status, WNOHANG);
            if (r == 0) continue;
            j.running = false;
            j.ok = r == j.pid and (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
            readLastLine(j);
            finished = true;
        }
        return finished;
    }

    pub fn anyRunning(self: *const Catalog) bool {
        for (self.jobs[0..self.n_jobs]) |*j| if (j.running) return true;
        return false;
    }
};

fn packLess(_: void, a: Pack, b: Pack) bool {
    if (a.known != b.known) return a.known;
    return std.ascii.lessThanIgnoreCase(a.m.name, b.m.name);
}

fn readManifest(a: std.mem.Allocator, path: []const u8) ?Manifest {
    const data = readAll(a, path) orelse return null;
    const m = std.json.parseFromSliceLeaky(Manifest, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| {
        std.debug.print("packs: {s}: {s}\n", .{ path, @errorName(e) });
        return null;
    };
    // A file tagged as another kind is refused (docs/25 §Formats).
    if (!std.mem.eql(u8, m.slab, "pack") or m.id.len == 0) return null;
    return m;
}

// ── Importers ────────────────────────────────────────────────────────

const Command = struct { tool: []const u8, args: []const []const u8 = &.{} };

/// A manifest's `import` → the tool that does it, for now.
fn command(import: []const u8) ?Command {
    if (std.mem.eql(u8, import, "vcsl")) return .{ .tool = "tools/library/vcsl.py" };
    if (std.mem.eql(u8, import, "drums")) return .{ .tool = "tools/library/drums.py" };
    if (std.mem.eql(u8, import, "cmi")) return .{ .tool = "tools/library/cmi.py", .args = &.{ "--collection", "disks", "$sources" } };
    if (std.mem.eql(u8, import, "extract")) return .{ .tool = "tools/extract/extract.py" };
    return null;
}

/// A Python 3: Homebrew's first (it has numpy, the tools measure with it).
fn python() ?[]const u8 {
    const candidates = [_][]const u8{ "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3" };
    for (candidates) |c| if (exists(c)) return c;
    return null;
}

// ── Finding the user's files ─────────────────────────────────────────

const MAX_WALK = 200_000;

fn countExpected(dir: []const u8, expect: []const Expect, found: *[MAX_EXPECT]u32) void {
    found.* = @splat(0);
    var budget: usize = MAX_WALK;
    walkCount(dir, 0, expect, found, &budget);
}

fn walkCount(dir: []const u8, depth: u8, expect: []const Expect, found: *[MAX_EXPECT]u32, budget: *usize) void {
    if (depth > 8) return;
    var d = Dir.open(dir) orelse return;
    defer d.close();
    while (d.next()) |e| {
        if (e.name[0] == '.') continue;
        if (budget.* == 0) return;
        budget.* -= 1;
        if (e.dir) {
            var b: [storage.MAX_PATH]u8 = undefined;
            walkCount(std.fmt.bufPrint(&b, "{s}/{s}", .{ dir, e.name }) catch continue, depth + 1, expect, found, budget);
            continue;
        }
        for (expect, 0..) |x, i| {
            if (i == MAX_EXPECT) break;
            var hit = pathMatch(x.glob, e.name, depth);
            for (x.also) |g| hit = hit or pathMatch(g, e.name, depth);
            if (hit) found[i] += 1;
        }
    }
}

fn met(s: Supply, found: *const [MAX_EXPECT]u32) bool {
    if (s.expect.len == 0) return false;
    var any = false;
    var all = true;
    for (s.expect, 0..) |x, i| {
        if (i == MAX_EXPECT) break;
        const ok = found[i] >= @max(1, x.min);
        any = any or ok;
        all = all and ok;
    }
    return if (s.any) any else all;
}

/// `**/` in front matches at any depth; otherwise only at the top.
fn pathMatch(pattern: []const u8, name: []const u8, depth: u8) bool {
    if (std.mem.startsWith(u8, pattern, "**/")) return glob(pattern[3..], name);
    return depth == 0 and glob(pattern, name);
}

/// `*` and `?`, any case.
pub fn glob(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= name.len) : (i += 1) if (glob(pattern[1..], name[i..])) return true;
        return false;
    }
    if (name.len == 0) return false;
    if (pattern[0] != '?' and std.ascii.toLower(pattern[0]) != std.ascii.toLower(name[0])) return false;
    return glob(pattern[1..], name[1..]);
}

fn readLastLine(j: *Job) void {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    const fd = open(z(&zb, j.logPath()), 0);
    if (fd < 0) return;
    defer _ = close(fd);
    const end = lseek(fd, 0, SEEK_END);
    if (end <= 0) return;
    var buf: [2048]u8 = undefined;
    const from = @max(0, end - @as(i64, buf.len));
    _ = lseek(fd, from, SEEK_SET);
    const n = read(fd, &buf, buf.len);
    if (n <= 0) return;
    // Progress lines end in \r; take the last one with text.
    var it = std.mem.splitBackwardsAny(u8, buf[0..@intCast(n)], "\r\n");
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t");
        if (t.len == 0) continue;
        const len = @min(t.len, j.line.len);
        @memcpy(j.line[0..len], t[0..len]);
        j.line_len = len;
        return;
    }
}

// ── POSIX ────────────────────────────────────────────────────────────

const SpawnActions = ?*anyopaque;
extern fn posix_spawn(pid: *c_int, path: [*:0]const u8, fa: ?*const SpawnActions, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn posix_spawn_file_actions_init(fa: *SpawnActions) c_int;
extern fn posix_spawn_file_actions_destroy(fa: *SpawnActions) c_int;
extern fn posix_spawn_file_actions_addopen(fa: *SpawnActions, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: u16) c_int;
extern fn posix_spawn_file_actions_adddup2(fa: *SpawnActions, fd: c_int, newfd: c_int) c_int;
extern fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;
extern var environ: [*:null]?[*:0]const u8;
extern fn access(path: [*:0]const u8, mode: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern fn lseek(fd: c_int, off: i64, whence: c_int) i64;
extern fn close(fd: c_int) c_int;

const WNOHANG: c_int = 1;
const SIGTERM: c_int = 15;
const O_WRONLY: c_int = 0x1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

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

const Dir = struct {
    d: *DIR,

    const Entry = struct { name: []const u8, dir: bool };

    fn open(path: []const u8) ?Dir {
        var zb: [storage.MAX_PATH:0]u8 = undefined;
        if (path.len == 0 or path.len >= zb.len) return null;
        return .{ .d = opendir(z(&zb, path)) orelse return null };
    }

    fn next(self: *Dir) ?Entry {
        while (readdir(self.d)) |e| {
            const name = e.d_name[0..e.d_namlen];
            if (name.len == 0) continue;
            return .{ .name = name, .dir = e.d_type == 4 };
        }
        return null;
    }

    fn close(self: *Dir) void {
        _ = closedir(self.d);
    }
};

fn z(buf: *[storage.MAX_PATH:0]u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf;
}

fn exists(path: []const u8) bool {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    if (path.len == 0 or path.len >= zb.len) return false;
    return access(z(&zb, path), 0) == 0;
}

fn readAll(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zb: [storage.MAX_PATH:0]u8 = undefined;
    const fd = open(z(&zb, path), 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        out.appendSlice(a, chunk[0..@intCast(n)]) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

test "glob matches names in any case" {
    const t = std.testing;
    try t.expect(glob("*.VC", "piano.vc"));
    try t.expect(glob("*.wav", "Kick Accent.WAV"));
    try t.expect(!glob("*.IMG", "disk.imd"));
    try t.expect(glob("DISK?.IMG", "disk1.img"));
    try t.expect(pathMatch("**/*.VC", "x.vc", 3));
    try t.expect(!pathMatch("*.VC", "x.vc", 1));
}

test "the shipped manifests parse" {
    const t = std.testing;
    var cat = Catalog.init(t.allocator);
    defer cat.deinit();
    cat.scan();
    for ([_][]const u8{ "vcsl", "cmi", "drum-machines" }) |id| {
        const p = cat.find(id) orelse return error.MissingManifest;
        try t.expect(p.known);
    }
    try t.expect(cat.redistributable("vcsl"));
    try t.expect(!cat.redistributable("cmi"));
    try t.expect(!cat.redistributable("drum-machines"));
    try t.expect(cat.find("cmi").?.m.get.supply.?.expect.len == 3);
}

