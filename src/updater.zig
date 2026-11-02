//! Updates from GitHub releases (docs/47). A background thread asks the
//! releases API for the latest version; a newer one is offered in the UI
//! and, from an installed Slab.app, downloaded, checked against the
//! release's checksum, and swapped in on a restart. Everything that
//! touches the network or the disk runs in /bin/sh scripts on that thread;
//! the UI only reads `state`.

const std = @import("std");
const build_options = @import("build_options");
const storage = @import("storage.zig");

pub const REPO = "nooga/slab";
const API = "https://api.github.com/repos/" ++ REPO ++ "/releases/latest";
const DOWNLOADS = "https://github.com/" ++ REPO ++ "/releases/download/";
pub const PAGE = "https://github.com/" ++ REPO ++ "/releases/latest";

pub const State = enum(u8) {
    idle,
    checking,
    /// Running the newest release.
    current,
    available,
    downloading,
    /// Staged: a restart swaps it in.
    ready,
    failed,
};

/// How an available update gets installed.
pub const Mode = enum {
    /// Slab replaces its own bundle.
    install,
    /// Homebrew owns the install: it upgrades after Slab exits.
    brew,
    /// A dev build or a folder Slab can't write: the release page.
    page,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn newerThan(a: Version, b: Version) bool {
        if (a.major != b.major) return a.major > b.major;
        if (a.minor != b.minor) return a.minor > b.minor;
        return a.patch > b.patch;
    }
};

/// "v0.0.20", "0.1.0-rc1" → numbers (a suffix after - or + is ignored).
pub fn parseVersion(s_in: []const u8) ?Version {
    var s = s_in;
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    if (std.mem.indexOfAny(u8, s, "-+")) |i| s = s[0..i];
    var it = std.mem.splitScalar(u8, s, '.');
    const a = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const b = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const c = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .major = a, .minor = b, .patch = c };
}

/// A release's notes without the install boilerplate release.sh appends
/// after a `---` line.
pub fn trimNotes(body: []const u8) []const u8 {
    var s = body;
    if (std.mem.indexOf(u8, s, "\n---")) |i| s = s[0..i];
    return std.mem.trim(u8, s, " \r\n");
}

const Asset = struct { name: []const u8 = "", browser_download_url: []const u8 = "" };
const Release = struct {
    tag_name: []const u8 = "",
    body: ?[]const u8 = null,
    assets: []const Asset = &.{},
};

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

pub const Updater = struct {
    state: std.atomic.Value(State) = .init(.idle),
    /// A restart was asked for and the swap is running: main quits.
    quit: std.atomic.Value(bool) = .init(false),
    /// The failure came from the check, not an install: nothing to show
    /// unless the user asked.
    fail_in_check: bool = false,
    mode: Mode = .page,
    /// Why the card only offers the release page (mode .page).
    reason: []const u8 = "",
    tag: [32]u8 = @splat(0),
    tag_len: usize = 0,
    notes: [2048]u8 = @splat(0),
    notes_len: usize = 0,
    zip_url: [512]u8 = @splat(0),
    zip_len: usize = 0,
    sum_url: [512]u8 = @splat(0),
    sum_len: usize = 0,
    err: [96]u8 = @splat(0),
    err_len: usize = 0,
    bundle: [storage.MAX_PATH]u8 = undefined,
    bundle_len: usize = 0,
    thread: ?std.Thread = null,

    pub fn get(self: *const Updater) State {
        return self.state.load(.acquire);
    }

    pub fn tagName(self: *const Updater) []const u8 {
        return self.tag[0..self.tag_len];
    }

    pub fn notesText(self: *const Updater) []const u8 {
        return self.notes[0..self.notes_len];
    }

    pub fn errorText(self: *const Updater) []const u8 {
        return self.err[0..self.err_len];
    }

    /// An update to offer in the UI: found, not skipped, not a failed
    /// check.
    pub fn pending(self: *const Updater) bool {
        return switch (self.get()) {
            .available => !std.mem.eql(u8, self.tagName(), storage.skippedVersion()),
            .downloading, .ready => true,
            .failed => !self.fail_in_check,
            else => false,
        };
    }

    fn fail(self: *Updater, in_check: bool, msg: []const u8) void {
        self.err_len = copyInto(&self.err, msg);
        self.fail_in_check = in_check;
        std.log.warn("update: {s}", .{msg});
        self.state.store(.failed, .release);
    }

    fn busy(self: *const Updater) bool {
        const s = self.get();
        return s == .checking or s == .downloading;
    }

    /// Look for a newer release, off the UI thread. Does nothing while a
    /// check or download runs.
    pub fn check(self: *Updater, alloc: std.mem.Allocator) void {
        if (self.busy()) return;
        self.join();
        self.fail_in_check = false;
        self.err_len = 0;
        self.state.store(.checking, .release);
        self.thread = std.Thread.spawn(.{}, checkJob, .{ self, alloc }) catch {
            self.fail(true, "COULDN'T START THE CHECK");
            return;
        };
    }

    /// Download and stage the found release (mode .install).
    pub fn download(self: *Updater, alloc: std.mem.Allocator) void {
        if (self.get() != .available or self.mode != .install) return;
        self.join();
        self.state.store(.downloading, .release);
        self.thread = std.Thread.spawn(.{}, downloadJob, .{ self, alloc }) catch {
            self.fail(false, "COULDN'T START THE DOWNLOAD");
            return;
        };
    }

    pub fn join(self: *Updater) void {
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Swap the staged bundle in once this process is gone, and ask main
    /// to quit. Slab reopens by itself.
    pub fn restart(self: *Updater, alloc: std.mem.Allocator) void {
        if (self.get() != .ready) return;
        var dir: [storage.MAX_PATH]u8 = undefined;
        const stage = cacheDir(&dir, "stage") orelse return;
        const pid = std.c.getpid();
        var pb: [16]u8 = undefined;
        const pid_s = std.fmt.bufPrint(&pb, "{d}", .{pid}) catch return;
        // Detached: the subshell outlives this process.
        const script =
            \\( while kill -0 "$3" 2>/dev/null; do sleep 0.2; done
            \\  rm -rf "$1.old"
            \\  if mv "$1" "$1.old"; then
            \\    if mv "$2/Slab.app" "$1"; then
            \\      xattr -dr com.apple.quarantine "$1" 2>/dev/null
            \\      rm -rf "$1.old" "$2"
            \\    else
            \\      mv "$1.old" "$1"
            \\    fi
            \\  fi
            \\  open "$1" ) >/dev/null 2>&1 &
        ;
        if (!sh(alloc, script, &.{ self.bundle[0..self.bundle_len], stage, pid_s }, false)) {
            self.fail(false, "COULDN'T START THE INSTALLER");
            return;
        }
        self.quit.store(true, .release);
    }

    /// Quit, let Homebrew upgrade the cask, and reopen Slab: a detached
    /// script (the tap-qualified token, since Homebrew's own `slab` cask is
    /// a different app that "upgrading" `slab` would install in Slab's place), whose output goes to brew-upgrade.log in the logs folder.
    pub fn brewUpgrade(self: *Updater, alloc: std.mem.Allocator) void {
        if (self.get() != .available or self.mode != .brew) return;
        var lb: [storage.MAX_PATH]u8 = undefined;
        const log_dir = diag_dir(&lb);
        storage.makeParents(log_dir);
        var pathb: [storage.MAX_PATH + 32]u8 = undefined;
        const log = std.fmt.bufPrint(&pathb, "{s}/brew-upgrade.log", .{log_dir}) catch return;
        var pb: [16]u8 = undefined;
        const pid_s = std.fmt.bufPrint(&pb, "{d}", .{std.c.getpid()}) catch return;
        const script =
            \\( while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            \\  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            \\    if [ -x "$b" ]; then
            \\      echo "$(date) $b upgrade --cask nooga/tap/slab"
            \\      "$b" upgrade --cask nooga/tap/slab
            \\      break
            \\    fi
            \\  done
            \\  open -a Slab ) >>"$2" 2>&1 &
        ;
        if (!sh(alloc, script, &.{ pid_s, log }, false)) {
            self.fail(false, "COULDN'T START HOMEBREW");
            return;
        }
        self.quit.store(true, .release);
    }

    /// The release page in the browser.
    pub fn openPage(alloc: std.mem.Allocator) void {
        _ = sh(alloc, "open \"$1\"", &.{PAGE}, false);
    }
};

fn diag_dir(buf: []u8) []const u8 {
    return @import("diag.zig").dir(buf);
}

fn checkJob(self: *Updater, alloc: std.mem.Allocator) void {
    var dir: [storage.MAX_PATH]u8 = undefined;
    const d = cacheDir(&dir, "") orelse return self.fail(true, "NO CACHE FOLDER");
    storage.makeParents(d);
    var jb: [storage.MAX_PATH + 16]u8 = undefined;
    const json_path = std.fmt.bufPrint(&jb, "{s}/latest.json", .{d}) catch return self.fail(true, "NO CACHE FOLDER");
    const api = if (std.c.getenv("SLAB_UPDATE_API")) |e| std.mem.span(e) else API;
    const ok = sh(alloc, "curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' -o \"$2\" \"$1\"", &.{ api, json_path }, true);
    if (!ok) return self.fail(true, "COULDN'T REACH GITHUB");
    const bytes = storage.readFile(alloc, json_path) orelse return self.fail(true, "NO ANSWER FROM GITHUB");
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(Release, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return self.fail(true, "UNREADABLE ANSWER");
    defer parsed.deinit();
    const rel = parsed.value;
    const theirs = parseVersion(rel.tag_name) orelse return self.fail(true, "UNREADABLE VERSION");
    const mine = parseVersion(build_options.version) orelse return self.fail(true, "UNREADABLE VERSION");
    if (!theirs.newerThan(mine)) {
        self.state.store(.current, .release);
        return;
    }

    self.tag_len = copyInto(&self.tag, rel.tag_name);
    self.notes_len = copyInto(&self.notes, trimNotes(rel.body orelse ""));
    self.zip_len = 0;
    self.sum_len = 0;
    const local = std.c.getenv("SLAB_UPDATE_API") != null;
    for (rel.assets) |a| {
        if (!local and !std.mem.startsWith(u8, a.browser_download_url, DOWNLOADS)) continue;
        if (std.mem.eql(u8, a.name, "Slab.zip")) self.zip_len = copyInto(&self.zip_url, a.browser_download_url);
        if (std.mem.eql(u8, a.name, "Slab.zip.sha256")) self.sum_len = copyInto(&self.sum_url, a.browser_download_url);
    }
    self.mode = installMode(self);
    // The test hook can also pick the mode, to see a card the dev build wouldn't show.
    if (local) if (std.c.getenv("SLAB_UPDATE_MODE")) |m| {
        const want = std.mem.span(m);
        if (std.mem.eql(u8, want, "brew")) self.mode = .brew;
        if (std.mem.eql(u8, want, "page")) self.mode = .page;
    };
    if (self.mode == .install and (self.zip_len == 0 or self.sum_len == 0)) {
        self.mode = .page;
        self.reason = "THIS RELEASE HAS NO CHECKSUM TO VERIFY";
    }
    std.log.info("update: {s} is available ({s})", .{ self.tagName(), @tagName(self.mode) });
    self.state.store(.available, .release);
}

fn downloadJob(self: *Updater, alloc: std.mem.Allocator) void {
    var dir: [storage.MAX_PATH]u8 = undefined;
    const d = cacheDir(&dir, "") orelse return self.fail(false, "NO CACHE FOLDER");
    var sb: [storage.MAX_PATH]u8 = undefined;
    const stage = cacheDir(&sb, "stage") orelse return self.fail(false, "NO CACHE FOLDER");
    // The zip must match the checksum the release publishes, and be a
    // validly signed bundle, before it is staged.
    const script =
        \\set -e
        \\cd "$1"; rm -rf "$2" unpack Slab.zip Slab.zip.sha256
        \\curl -fsSL --max-time 900 -o Slab.zip "$3"
        \\curl -fsSL --max-time 30 -o Slab.zip.sha256 "$4"
        \\want=$(cut -d' ' -f1 Slab.zip.sha256)
        \\got=$(shasum -a 256 Slab.zip | cut -d' ' -f1)
        \\[ -n "$want" ] && [ "$want" = "$got" ] || exit 3
        \\mkdir unpack
        \\ditto -x -k Slab.zip unpack
        \\codesign --verify --deep --strict unpack/Slab.app || exit 4
        \\mv unpack "$2"
        \\rm -f Slab.zip
    ;
    if (!sh(alloc, script, &.{ d, stage, self.zip_url[0..self.zip_len], self.sum_url[0..self.sum_len] }, true))
        return self.fail(false, "THE DOWNLOAD FAILED OR DIDN'T CHECK OUT");
    self.state.store(.ready, .release);
}

/// Where this Slab lives decides how it updates.
fn installMode(self: *Updater) Mode {
    var buf: [storage.MAX_PATH]u8 = undefined;
    var n: u32 = buf.len;
    if (_NSGetExecutablePath(&buf, &n) != 0) return .page;
    const exe = std.mem.sliceTo(&buf, 0);
    const macos = std.fs.path.dirname(exe) orelse return .page;
    if (!std.mem.endsWith(u8, macos, ".app/Contents/MacOS")) {
        self.reason = "RUNNING FROM A DEV BUILD";
        return .page;
    }
    // Slab.app is three levels up from the binary.
    const app = std.fs.path.dirname(std.fs.path.dirname(macos).?).?;
    // (SLAB_UPDATE_API is the test hook: a fake release, whatever installed this.)
    const testing = std.c.getenv("SLAB_UPDATE_API") != null;
    const have_brew = access("/opt/homebrew/bin/brew", 1) == 0 or access("/usr/local/bin/brew", 1) == 0;
    if (!testing and have_brew and (access("/opt/homebrew/Caskroom/slab", 0) == 0 or access("/usr/local/Caskroom/slab", 0) == 0)) return .brew;
    var zb: [storage.MAX_PATH + 1]u8 = undefined;
    const parent = std.fs.path.dirname(app) orelse return .page;
    const pz = std.mem.printSentinel(&zb, "{s}", .{parent}, 0) catch return .page;
    if (access(pz.ptr, 2) != 0) { // W_OK
        self.reason = "SLAB CAN'T WRITE ITS OWN FOLDER";
        return .page;
    }
    self.bundle_len = copyInto(&self.bundle, app);
    return .install;
}

/// ~/Library/Caches/Slab/update[/sub].
fn cacheDir(buf: []u8, sub: []const u8) ?[]const u8 {
    const h = if (std.c.getenv("HOME")) |e| std.mem.span(e) else return null;
    const sep: []const u8 = if (sub.len > 0) "/" else "";
    return std.fmt.bufPrint(buf, "{s}/Library/Caches/Slab/update{s}{s}", .{ h, sep, sub }) catch null;
}

/// Run `script` under /bin/sh with `args` as $1…; true when it exits 0
/// (always true for a detached run that started).
fn sh(alloc: std.mem.Allocator, script: []const u8, args: []const []const u8, wait: bool) bool {
    var argv: [16:null]?[*:0]const u8 = @splat(null);
    var owned: [16][:0]u8 = undefined;
    var n_owned: usize = 0;
    defer for (owned[0..n_owned]) |s| alloc.free(s);
    const fixed = [_][]const u8{ "/bin/sh", "-c", script, "sh" };
    if (fixed.len + args.len >= argv.len) return false;
    var n: usize = 0;
    for (fixed) |s| {
        owned[n_owned] = dupeZ(alloc, s) catch return false;
        n_owned += 1;
        argv[n] = owned[n_owned - 1].ptr;
        n += 1;
    }
    for (args) |s| {
        owned[n_owned] = dupeZ(alloc, s) catch return false;
        n_owned += 1;
        argv[n] = owned[n_owned - 1].ptr;
        n += 1;
    }
    var pid: c_int = 0;
    if (posix_spawn(&pid, "/bin/sh", null, null, &argv, environ) != 0) return false;
    if (!wait) return true;
    var status: c_int = 0;
    if (waitpid(pid, &status, 0) < 0) return false;
    return status == 0;
}

fn dupeZ(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;
extern fn posix_spawn(pid: *c_int, path: [*:0]const u8, fa: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern fn access(path: [*:0]const u8, mode: c_int) c_int;
extern var environ: [*:null]?[*:0]const u8;

test "versions compare numerically, not as text" {
    const a = parseVersion("v0.0.20").?;
    const b = parseVersion("0.0.9").?;
    try std.testing.expect(a.newerThan(b));
    try std.testing.expect(!b.newerThan(a));
    try std.testing.expect(!a.newerThan(a));
    try std.testing.expect(parseVersion("1.0.0").?.newerThan(parseVersion("0.99.99").?));
    try std.testing.expect(parseVersion("0.1.0-rc1").?.newerThan(parseVersion("0.0.19").?));
    try std.testing.expect(parseVersion("latest") == null);
    try std.testing.expect(parseVersion("1.2") == null);
    try std.testing.expect(parseVersion("1.2.3.4") == null);
}

test "notes stop before the install boilerplate" {
    try std.testing.expectEqualStrings("- one\n- two", trimNotes("- one\n- two\n\n---\n\nApple Silicon"));
    try std.testing.expectEqualStrings("only", trimNotes("only\n"));
}

test "the release answer parses" {
    const json =
        \\{"tag_name":"v0.0.20","body":"- x\n\n---\nfoo","assets":[{"name":"Slab.zip","browser_download_url":"https://github.com/nooga/slab/releases/download/v0.0.20/Slab.zip","size":1}],"id":3}
    ;
    const p = try std.json.parseFromSlice(Release, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    try std.testing.expectEqualStrings("v0.0.20", p.value.tag_name);
    try std.testing.expectEqual(@as(usize, 1), p.value.assets.len);
}
