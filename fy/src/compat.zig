//! Zig-0.15 → 0.16 compatibility shims.
//!
//! The 0.16 stdlib removed/reshaped several APIs fy uses heavily:
//! - `std.ArrayList` became the unmanaged version. The managed variant
//!   lives at `std.array_list.Managed` (deprecated but present).
//! - `std.io.getStd{Out,Err,In}()` and most of `std.posix`'s blocking
//!   read/write were replaced with the new `std.Io` async model. Our
//!   usage is synchronous blocking I/O to stderr/stdout for
//!   diagnostics — no need for the new model; we call libc directly.
//! - `std.fmt.fmtSliceHexLower` was removed in favour of the new
//!   formatter API.
//!
//! Rather than touching hundreds of call sites, we re-export a small
//! compat surface here and rename call-site prefixes. When fy's stdlib
//! usage is modernized properly, this file goes away.

const std = @import("std");
const posix = std.posix;

/// Managed ArrayList with the pre-0.16 API (init(allocator), append(x),
/// deinit(), items, etc.). Backed by `std.array_list.Managed` which
/// zig marks deprecated but still exports in 0.16.
pub fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// File-descriptor-backed writer with the minimal subset of the pre-0.16
/// writer interface fy uses: `print(comptime fmt, args) !void` and
/// `writeAll(bytes) !void`. Errors are coarse-grained — every fy call
/// site wraps in `catch {}` so we don't need a rich error set.
pub const FdWriter = struct {
    fd: posix.fd_t,

    pub const Error = error{WriteFailed};

    pub fn writeAll(self: FdWriter, bytes: []const u8) Error!void {
        var idx: usize = 0;
        while (idx < bytes.len) {
            const n = std.c.write(self.fd, bytes.ptr + idx, bytes.len - idx);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.WriteFailed;
            idx += @intCast(n);
        }
    }

    pub fn print(self: FdWriter, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => {
                try self.writeAll(&buf);
                try self.writeAll("...[truncated]");
                return;
            },
        };
        try self.writeAll(s);
    }
};

pub const FdReader = struct {
    fd: posix.fd_t,

    pub const Error = error{ReadFailed};

    pub fn read(self: FdReader, buf: []u8) Error!usize {
        const n = std.c.read(self.fd, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    pub fn readAll(self: FdReader, buf: []u8) Error!usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    /// Read bytes up to (but not including) the first `delimiter`, or up
    /// to `max_bytes`. Returns owned slice allocated from `allocator`.
    /// Returns `error.EndOfStream` if EOF is hit before any bytes are read.
    pub fn readUntilDelimiterAlloc(
        self: FdReader,
        allocator: std.mem.Allocator,
        delimiter: u8,
        max_bytes: usize,
    ) ![]u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        var byte: [1]u8 = undefined;
        while (buf.items.len < max_bytes) {
            const n = try self.read(&byte);
            if (n == 0) {
                if (buf.items.len == 0) return error.EndOfStream;
                break;
            }
            if (byte[0] == delimiter) break;
            try buf.append(byte[0]);
        }
        return buf.toOwnedSlice();
    }
};

pub fn stdoutWriter() FdWriter {
    // Under `zig build test` with --listen=-, fd 1 is the test runner's
    // IPC pipe, not a terminal. Any bytes we write there corrupt the
    // protocol. Route to stderr in test builds, matching `outPrint`'s
    // existing behaviour.
    if (@import("builtin").is_test) return .{ .fd = posix.STDERR_FILENO };
    return .{ .fd = posix.STDOUT_FILENO };
}

pub fn stderrWriter() FdWriter {
    return .{ .fd = posix.STDERR_FILENO };
}

pub fn stdinReader() FdReader {
    return .{ .fd = posix.STDIN_FILENO };
}

// ------------------------------------------------------------------
// File I/O helpers — 0.16 moved std.fs.* under the new async Io model
// which threads an Io instance through every call. fy's usage is
// synchronous blocking; we call libc directly.
// ------------------------------------------------------------------

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("dirent.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
});

pub const FileError = error{
    OpenFailed,
    ReadFailed,
    WriteFailed,
    StatFailed,
    OutOfMemory,
    AccessDenied,
};

fn cstr(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

/// Read the entire contents of `path` into a new allocation, capped at
/// `max_bytes`. Replacement for `std.fs.cwd().readFileAlloc(…)`.
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const z = cstr(allocator, path) catch return FileError.OutOfMemory;
    defer allocator.free(z);
    const fd = c.open(z.ptr, c.O_RDONLY);
    if (fd < 0) return FileError.OpenFailed;
    defer _ = c.close(fd);

    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return FileError.StatFailed;
    const size: usize = @intCast(st.st_size);
    if (size > max_bytes) return FileError.ReadFailed;

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var total: usize = 0;
    while (total < size) {
        const n = c.read(fd, buf.ptr + total, size - total);
        if (n <= 0) return FileError.ReadFailed;
        total += @intCast(n);
    }
    return buf;
}

/// Write `data` to `path`, truncating/creating. Replacement for
/// `std.fs.cwd().createFile(path, .{}).writeAll(data)`.
pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try cstr(allocator, path);
    defer allocator.free(z);
    const fd = c.open(z.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o644));
    if (fd < 0) return FileError.OpenFailed;
    defer _ = c.close(fd);
    var idx: usize = 0;
    while (idx < data.len) {
        const n = c.write(fd, data.ptr + idx, data.len - idx);
        if (n <= 0) return FileError.WriteFailed;
        idx += @intCast(n);
    }
}

/// `mkdir -p`. Creates intermediate directories as needed. Returns
/// success if the path already exists as a directory.
pub fn makePath(allocator: std.mem.Allocator, path: []const u8) !void {
    const z = try cstr(allocator, path);
    defer allocator.free(z);
    // Try full path first; walk up if ENOENT.
    if (c.mkdir(z.ptr, 0o755) == 0) return;
    const errno = c.__error().*;
    if (errno == c.EEXIST) return;
    if (errno != c.ENOENT) return FileError.OpenFailed;

    // Walk up: make each parent in turn.
    var i: usize = path.len;
    while (i > 0 and path[i - 1] == '/') i -= 1;
    while (i > 0 and path[i - 1] != '/') i -= 1;
    if (i == 0) return FileError.OpenFailed;
    try makePath(allocator, path[0 .. i - 1]);
    if (c.mkdir(z.ptr, 0o755) != 0 and c.__error().* != c.EEXIST) return FileError.OpenFailed;
}

pub const DirEntry = struct {
    name: []const u8, // borrowed from internal buffer; valid until next .next()
};

pub const DirIter = struct {
    dir: *c.DIR,
    name_buf: [1024]u8 = undefined,

    pub fn next(self: *DirIter) !?DirEntry {
        const ent = c.readdir(self.dir);
        if (ent == null) return null;
        const name_ptr: [*:0]const u8 = @ptrCast(&ent.*.d_name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return self.next();
        }
        if (name.len > self.name_buf.len) return FileError.ReadFailed;
        @memcpy(self.name_buf[0..name.len], name);
        return DirEntry{ .name = self.name_buf[0..name.len] };
    }

    pub fn close(self: *DirIter) void {
        _ = c.closedir(self.dir);
    }
};

pub fn openDirIter(allocator: std.mem.Allocator, path: []const u8) !DirIter {
    const z = try cstr(allocator, path);
    defer allocator.free(z);
    const dir = c.opendir(z.ptr) orelse return FileError.OpenFailed;
    return .{ .dir = dir };
}

/// Hex-formatter for `{}`-style print. Replaces the removed
/// `std.fmt.fmtSliceHexLower`.
pub fn fmtSliceHexLower(bytes: []const u8) HexLower {
    return .{ .bytes = bytes };
}

pub const HexLower = struct {
    bytes: []const u8,

    pub fn format(self: HexLower, writer: anytype) !void {
        for (self.bytes) |b| {
            try writer.print("{x:0>2}", .{b});
        }
    }
};
