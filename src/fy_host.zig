//! Slab's fy runtime host.
//!
//! Owns a single `Fy` instance shared across all machines.
//! Host builtins (slab:sr, slab:block-size, etc.) are registered once via
//! `registerSlabBuiltins()` using fy's `bind:` injection pattern: we pass
//! Zig function pointers as integer literals so fy can call them via the
//! standard C ABI.  Float returns use `bind: :d` (tagged by compileBind).
//! Integer returns come from Zig already tagged (`Fy.makeInt(n)`) so
//! `bind: :i` pushes the correct fy value without an extra tag step.
//!
//! Thread-local ctx: `setCtx` / `clearCtx` set a per-thread pointer that
//! the host builtins read.  Set it before calling any audio word, clear
//! after.  Audio-thread safe: no heap allocation, no locks.

const std = @import("std");
const Fy = @import("fy").Fy;
const machine_mod = @import("machine.zig");
const MachineCtx = machine_mod.MachineCtx;
const c = @import("c.zig");
const theme = @import("ui/theme.zig");
const widgets = @import("ui/widgets.zig");

/// fy currently exposes callback/runtime state through global variables
/// (`Fy.Builtins.fyPtr` among them). Until that state is made thread-local
/// in fy, only one Slab fy callback may execute at a time.
pub var callback_mutex: std.atomic.Mutex = .unlocked;

pub fn lockCallbacks() void {
    while (!callback_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

pub fn unlockCallbacks() void {
    callback_mutex.unlock();
}

// ── Minimal TCP server using libc directly ────────────────────────────
// Zig 0.16 moved std.net into std.Io.net (async-only).  We use libc
// BSD socket calls directly — safe on macOS, matches what fy's own
// server does internally.

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET: c_int = 0xffff;
const SO_REUSEADDR: c_int = 0x0004;
const INADDR_LOOPBACK: u32 = 0x7f000001;

const SockAddrIn = extern struct {
    sin_len: u8 = 16,
    sin_family: u8 = 2, // AF_INET
    sin_port: u16, // big-endian
    sin_addr: u32, // big-endian
    sin_zero: [8]u8 = .{0} ** 8,
};

extern fn socket(domain: c_int, @"type": c_int, protocol: c_int) c_int;
extern fn bind(fd: c_int, addr: *const SockAddrIn, len: u32) c_int;
extern fn listen(fd: c_int, backlog: c_int) c_int;
extern fn accept(fd: c_int, addr: ?*SockAddrIn, len: ?*u32) c_int;
extern fn getsockname(fd: c_int, addr: *SockAddrIn, len: *u32) c_int;
extern fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const c_int, optlen: u32) c_int;
extern fn htons(x: u16) u16;

// ── File I/O via libc (std.fs.cwd() was removed in Zig 0.16) ─────────
// In Zig 0.16 most blocking file operations moved to std.Io.Dir which
// requires an async Io context.  We call libc directly instead.
extern fn close(fd: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn fstat(fd: c_int, sb: *std.c.Stat) c_int;
extern fn realpath(path: [*:0]const u8, buf: [*]u8) ?[*]u8;
extern fn unlink(path: [*:0]const u8) c_int;
const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0x200;
const O_TRUNC: c_int = 0x400;

fn readFilePosix(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_RDONLY);
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);
    var st: std.c.Stat = undefined;
    if (fstat(fd, &st) != 0) return error.StatFailed;
    const sz: usize = @intCast(st.size);
    const buf = try alloc.alloc(u8, sz);
    errdefer alloc.free(buf);
    var done: usize = 0;
    while (done < sz) {
        const n = std.posix.read(@intCast(fd), buf[done..]) catch break;
        if (n == 0) break;
        done += n;
    }
    if (done < sz) return error.ReadFailed;
    return buf;
}

fn writeFilePosix(path: []const u8, data: []const u8) void {
    var zbuf: [512:0]u8 = undefined;
    const n = @min(path.len, 511);
    @memcpy(zbuf[0..n], path[0..n]);
    zbuf[n] = 0;
    const fd = open(&zbuf, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return;
    defer _ = close(fd);
    _ = std.c.write(fd, data.ptr, data.len);
}

pub fn deleteFilePosix(path: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1:0]u8 = undefined;
    const n = @min(path.len, std.fs.max_path_bytes);
    @memcpy(buf[0..n], path[0..n]);
    buf[n] = 0;
    _ = unlink(&buf);
}

fn realpathPosix(path: []const u8, out: *[std.fs.max_path_bytes:0]u8) ?[]u8 {
    var z: [std.fs.max_path_bytes + 1:0]u8 = undefined;
    const n = @min(path.len, std.fs.max_path_bytes);
    @memcpy(z[0..n], path[0..n]);
    z[n] = 0;
    const r = realpath(&z, @ptrCast(out)) orelse return null;
    return std.mem.sliceTo(@as([*:0]u8, @ptrCast(r)), 0);
}

fn tcpRead(fd: c_int, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(@intCast(fd), buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

// Thread-local pointers set by the host before each block, read by builtins.
threadlocal var tl_ctx: ?*const MachineCtx = null;
threadlocal var tl_l_buf: ?[*]f32 = null;
threadlocal var tl_r_buf: ?[*]f32 = null;
threadlocal var tl_params: ?*anyopaque = null;
threadlocal var tl_noise_state: u32 = 0x6d2b79f5;

// ── Host builtins ─────────────────────────────────────────────────────
// All exported with C calling convention so fy's `bind:` trampoline can
// call them.  Integer-returning builtins return a pre-tagged Fy.Value
// (= raw int << 2) so `bind: :i` works without extra tag handling.

fn slab_sr() callconv(.c) f64 {
    return if (tl_ctx) |ctx| ctx.sample_rate else 0.0;
}

fn slab_block_size() callconv(.c) i64 {
    const n: i64 = if (tl_ctx) |ctx| @intCast(ctx.block_size) else 0;
    return Fy.makeInt(n);
}

fn slab_block_start() callconv(.c) i64 {
    const s: i64 = if (tl_ctx) |ctx| @intCast(ctx.block_start) else 0;
    return Fy.makeInt(s);
}

fn slab_tempo_bpm() callconv(.c) f64 {
    return if (tl_ctx) |ctx| @floatCast(ctx.tempo_bpm) else 0.0;
}

// ── Note event builtins ───────────────────────────────────────────────
// idx args are fy-tagged ints; untag with >> 2 before indexing.

fn slab_note_count() callconv(.c) i64 {
    const n: i64 = if (tl_ctx) |ctx| @intCast(ctx.note_in_count) else 0;
    return Fy.makeInt(n);
}

fn slab_note_kind(idx_tagged: i64) callconv(.c) i64 {
    const i: u32 = @intCast(idx_tagged >> 2);
    if (tl_ctx) |ctx| if (ctx.note_in) |ev| if (i < ctx.note_in_count)
        return Fy.makeInt(@intFromEnum(ev[i].kind));
    return 0;
}

fn slab_note_pitch(idx_tagged: i64) callconv(.c) f64 {
    const i: u32 = @intCast(idx_tagged >> 2);
    if (tl_ctx) |ctx| if (ctx.note_in) |ev| if (i < ctx.note_in_count)
        return @floatCast(ev[i].pitch);
    return 0;
}

fn slab_note_vel(idx_tagged: i64) callconv(.c) f64 {
    const i: u32 = @intCast(idx_tagged >> 2);
    if (tl_ctx) |ctx| if (ctx.note_in) |ev| if (i < ctx.note_in_count)
        return @floatCast(ev[i].velocity);
    return 0;
}

fn slab_audio_l() callconv(.c) i64 {
    return Fy.makeInt(@intCast(if (tl_l_buf) |p| @intFromPtr(p) else 0));
}

fn slab_audio_r() callconv(.c) i64 {
    return Fy.makeInt(@intCast(if (tl_r_buf) |p| @intFromPtr(p) else 0));
}

fn slab_input_l() callconv(.c) i64 {
    if (tl_ctx) |ctx| {
        if (ctx.audio_in_count >= 2) {
            if (ctx.audio_in) |ports| return Fy.makeInt(@intCast(@intFromPtr(ports[0])));
        }
    }
    return Fy.makeInt(0);
}

fn slab_input_r() callconv(.c) i64 {
    if (tl_ctx) |ctx| {
        if (ctx.audio_in_count >= 2) {
            if (ctx.audio_in) |ports| return Fy.makeInt(@intCast(@intFromPtr(ports[1])));
        }
    }
    return Fy.makeInt(0);
}

fn slab_input_l_sample(idx_tagged: i64) callconv(.c) f64 {
    const idx_raw = idx_tagged >> 2;
    if (idx_raw < 0) return 0;
    const i: usize = @intCast(idx_raw);
    if (tl_ctx) |ctx| {
        if (i >= ctx.block_size) return 0;
        if (ctx.audio_in_count >= 2) {
            if (ctx.audio_in) |ports| return @floatCast(ports[0][i]);
        }
    }
    return 0;
}

fn slab_input_r_sample(idx_tagged: i64) callconv(.c) f64 {
    const idx_raw = idx_tagged >> 2;
    if (idx_raw < 0) return 0;
    const i: usize = @intCast(idx_raw);
    if (tl_ctx) |ctx| {
        if (i >= ctx.block_size) return 0;
        if (ctx.audio_in_count >= 2) {
            if (ctx.audio_in) |ports| return @floatCast(ports[1][i]);
        }
    }
    return 0;
}

fn slab_params() callconv(.c) i64 {
    return Fy.makeInt(@intCast(if (tl_params) |p| @intFromPtr(p) else 0));
}

fn slab_write_stereo(sample: f64, idx_tagged: i64) callconv(.c) void {
    const idx_raw = idx_tagged >> 2;
    if (idx_raw < 0) return;
    const i: usize = @intCast(idx_raw);
    if (tl_ctx) |ctx| {
        if (i >= ctx.block_size) return;
    }
    const v: f32 = @floatCast(sample);
    if (tl_l_buf) |l| l[i] = v;
    if (tl_r_buf) |r| r[i] = v;
}

fn slab_write_l(sample: f64, idx_tagged: i64) callconv(.c) void {
    const idx_raw = idx_tagged >> 2;
    if (idx_raw < 0) return;
    const i: usize = @intCast(idx_raw);
    if (tl_ctx) |ctx| {
        if (i >= ctx.block_size) return;
    }
    if (tl_l_buf) |l| l[i] = @floatCast(sample);
}

fn slab_write_r(sample: f64, idx_tagged: i64) callconv(.c) void {
    const idx_raw = idx_tagged >> 2;
    if (idx_raw < 0) return;
    const i: usize = @intCast(idx_raw);
    if (tl_ctx) |ctx| {
        if (i >= ctx.block_size) return;
    }
    if (tl_r_buf) |r| r[i] = @floatCast(sample);
}

fn slab_noise() callconv(.c) f64 {
    var x = tl_noise_state;
    if (x == 0) x = 0x6d2b79f5;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    tl_noise_state = x;
    const unit = @as(f64, @floatFromInt(x & 0x00ff_ffff)) / 8_388_607.5;
    return unit - 1.0;
}

threadlocal var tl_debug_machine: [*:0]const u8 = "fy";

fn slab_debug_mark(mark_tagged: i64) callconv(.c) void {
    if (std.c.getenv("SLAB_FY_TRACE") == null) return;
    std.debug.print("fy-mark {s} {d}\n", .{ tl_debug_machine, mark_tagged >> 2 });
}

fn slab_debug_mode() callconv(.c) i64 {
    const raw = std.c.getenv("SLAB_MONO1_STAGE") orelse return Fy.makeInt(0);
    const s = std.mem.span(raw);
    if (std.mem.eql(u8, s, "dry") or std.mem.eql(u8, s, "mixer")) return Fy.makeInt(1);
    if (std.mem.eql(u8, s, "osc") or std.mem.eql(u8, s, "saw")) return Fy.makeInt(2);
    if (std.mem.eql(u8, s, "pulse")) return Fy.makeInt(3);
    if (std.mem.eql(u8, s, "sub")) return Fy.makeInt(4);
    if (std.mem.eql(u8, s, "pulseraw")) return Fy.makeInt(5);
    if (std.mem.eql(u8, s, "square")) return Fy.makeInt(6);
    if (std.mem.eql(u8, s, "0")) return Fy.makeInt(0);
    if (std.mem.eql(u8, s, "1")) return Fy.makeInt(1);
    if (std.mem.eql(u8, s, "2")) return Fy.makeInt(2);
    if (std.mem.eql(u8, s, "3")) return Fy.makeInt(3);
    if (std.mem.eql(u8, s, "4")) return Fy.makeInt(4);
    if (std.mem.eql(u8, s, "5")) return Fy.makeInt(5);
    if (std.mem.eql(u8, s, "6")) return Fy.makeInt(6);
    return Fy.makeInt(0);
}

// ── UI thread-locals ──────────────────────────────────────────────────
// Set by drawPanelImpl before calling the fy UI word each frame.
threadlocal var tl_ui_rect: c.rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
threadlocal var tl_ui_mouse: ?widgets.Mouse = null;

// ── UI panel rect builtins ────────────────────────────────────────────
fn slab_panel_x() callconv(.c) f64 {
    return tl_ui_rect.x;
}
fn slab_panel_y() callconv(.c) f64 {
    return tl_ui_rect.y;
}
fn slab_panel_w() callconv(.c) f64 {
    return tl_ui_rect.width;
}
fn slab_panel_h() callconv(.c) f64 {
    return tl_ui_rect.height;
}

// ── Widget builtins (called from fy UI words) ─────────────────────────
// Coordinates are fy-tagged f64; bind: strips the tag before calling.

fn widgetBevelRaisedC(x: f64, y: f64, w: f64, h: f64) callconv(.c) void {
    widgets.bevelRaised(
        c.rl.Rectangle{ .x = @floatCast(x), .y = @floatCast(y), .width = @floatCast(w), .height = @floatCast(h) },
        theme.slab_fill,
        theme.slab_hi,
        theme.slab_lo,
    );
}

// Label builtins take the label as a raw tagged-int pointer (bind: i arg).
// fy callers pass :: _lbl "TEXT" cstr-new ; constants so the C string is
// malloc'd once at compile time.  Untag: ptr = label_val >> 2.
fn labelPtr(label_val: i64) [*:0]const u8 {
    return @ptrFromInt(@as(usize, @bitCast(label_val >> 2)));
}

fn widgetDrawLabelC(x: f64, y: f64, label_val: i64) callconv(.c) void {
    widgets.drawLabelF(labelPtr(label_val), @floatCast(x), @floatCast(y), theme.fsTiny(), theme.text_fg);
}

fn widgetDrawLabelDimC(x: f64, y: f64, label_val: i64) callconv(.c) void {
    widgets.drawLabelF(labelPtr(label_val), @floatCast(x), @floatCast(y), theme.fsTiny(), theme.text_dim);
}

// Full knob: reads tl_ui_mouse internally, returns the (possibly updated) value.
fn widgetKnobC(x: f64, y: f64, w: f64, h: f64, label_val: i64, val: f64) callconv(.c) f64 {
    const r = c.rl.Rectangle{
        .x = @floatCast(x),
        .y = @floatCast(y),
        .width = @floatCast(w),
        .height = @floatCast(h),
    };
    var v: f32 = @floatCast(val);
    if (tl_ui_mouse) |m| _ = widgets.knob(r, labelPtr(label_val), &v, m);
    return v;
}

fn widgetSwitch3C(x: f64, y: f64, w: f64, h: f64, label_val: i64, opt0_val: i64, opt1_val: i64, opt2_val: i64, val: f64) callconv(.c) f64 {
    const r = c.rl.Rectangle{
        .x = @floatCast(x),
        .y = @floatCast(y),
        .width = @floatCast(w),
        .height = @floatCast(h),
    };
    var v: u8 = @intFromFloat(std.math.clamp(@round(val), 0.0, 2.0));
    if (tl_ui_mouse) |m| _ = widgets.switch3(r, labelPtr(label_val), labelPtr(opt0_val), labelPtr(opt1_val), labelPtr(opt2_val), &v, m);
    return @floatFromInt(v);
}

fn widgetSwitch3VerticalC(x: f64, y: f64, w: f64, h: f64, label_val: i64, opt0_val: i64, opt1_val: i64, opt2_val: i64, val: f64) callconv(.c) f64 {
    const r = c.rl.Rectangle{
        .x = @floatCast(x),
        .y = @floatCast(y),
        .width = @floatCast(w),
        .height = @floatCast(h),
    };
    var v: u8 = @intFromFloat(std.math.clamp(@round(val), 0.0, 2.0));
    if (tl_ui_mouse) |m| _ = widgets.switch3Vertical(r, labelPtr(label_val), labelPtr(opt0_val), labelPtr(opt1_val), labelPtr(opt2_val), &v, m);
    return @floatFromInt(v);
}

fn widgetToggleC(x: f64, y: f64, w: f64, h: f64, label_val: i64, val: f64) callconv(.c) f64 {
    const r = c.rl.Rectangle{
        .x = @floatCast(x),
        .y = @floatCast(y),
        .width = @floatCast(w),
        .height = @floatCast(h),
    };
    var on = val >= 0.5;
    if (tl_ui_mouse) |m| _ = widgets.toggleCell(r, labelPtr(label_val), &on, m);
    return if (on) 1.0 else 0.0;
}

// LED: on=nonzero int, colour = accent_play.
fn widgetLedC(x: f64, y: f64, sz: f64, on: i64) callconv(.c) void {
    const r = c.rl.Rectangle{
        .x = @floatCast(x),
        .y = @floatCast(y),
        .width = @floatCast(sz),
        .height = @floatCast(sz),
    };
    widgets.led(r, on != 0, theme.accent_play);
}

// ── FyHost ───────────────────────────────────────────────────────────

pub const FyHost = struct {
    fy: Fy,
    alloc: std.mem.Allocator,
    /// Incremented atomically after each successful hot-patch recompile.
    /// Callers poll this to know when to refresh their callbacks.
    hot_reload_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    hot_server_fd: c_int = -1,

    pub fn init(alloc: std.mem.Allocator) FyHost {
        return .{ .fy = Fy.init(alloc), .alloc = alloc };
    }

    pub fn deinit(self: *FyHost) void {
        if (self.hot_server_fd >= 0) _ = close(self.hot_server_fd);
        self.fy.deinit();
    }

    /// Compile a fy source string; definitions persist in the runtime.
    /// Stack top after the snippet runs is discarded.
    pub fn compile(self: *FyHost, src: []const u8) !void {
        _ = try self.fy.run(src);
    }

    /// Compile a fy file; definitions persist. Imports resolve relative
    /// to the file's directory (uses the now-public runWithBaseDir).
    pub fn compileFile(self: *FyHost, path: []const u8) !void {
        const src = try readFilePosix(self.alloc, path);
        defer self.alloc.free(src);
        const base_dir = dirName(path);
        _ = try self.fy.runWithBaseDir(src, base_dir);
    }

    /// Evaluate a fy expression and return the raw tagged Fy.Value on TOS.
    /// Callers untag with Fy.makeInt / Fy.isInt etc.
    pub fn callWord(self: *FyHost, expr: []const u8) !Fy.Value {
        return self.fy.run(expr);
    }

    /// Register Slab's host builtins into the runtime.  Call once after
    /// init.  Uses bind: injection — each builtin is a C function whose
    /// address is baked as a fy constant, then wrapped with bind:.
    pub fn registerSlabBuiltins(self: *FyHost) !void {
        const src = try std.fmt.allocPrint(self.alloc,
            \\ :: _slab_sr         {d} ;
            \\ :: _slab_n          {d} ;
            \\ :: _slab_block_start {d} ;
            \\ :: _slab_bpm        {d} ;
            \\ noalloc: slab:sr           _slab_sr          bind: :d ;
            \\ noalloc: slab:block-size   _slab_n           bind: :i ;
            \\ noalloc: slab:block-start  _slab_block_start bind: :i ;
            \\ noalloc: slab:bpm          _slab_bpm         bind: :d ;
            \\ :: _slab_nc  {d} ;
            \\ :: _slab_nk  {d} ; :: _slab_np  {d} ; :: _slab_nv  {d} ;
            \\ noalloc: slab:note-count  _slab_nc bind: :i ;
            \\ noalloc: slab:note-kind   _slab_nk bind: i:i ;
            \\ noalloc: slab:note-pitch  _slab_np bind: i:d ;
            \\ noalloc: slab:note-vel    _slab_nv bind: i:d ;
            \\ :: _slab_al         {d} ;
            \\ :: _slab_ar         {d} ;
            \\ :: _slab_il         {d} ;
            \\ :: _slab_ir         {d} ;
            \\ :: _slab_ils        {d} ;
            \\ :: _slab_irs        {d} ;
            \\ :: _slab_params     {d} ;
            \\ :: _slab_ws         {d} ;
            \\ :: _slab_wl         {d} ;
            \\ :: _slab_wr         {d} ;
            \\ :: _slab_noise      {d} ;
            \\ :: _slab_mark       {d} ;
            \\ noalloc: slab:audio-l      _slab_al          bind: :i ;
            \\ noalloc: slab:audio-r      _slab_ar          bind: :i ;
            \\ noalloc: slab:input-l      _slab_il          bind: :i ;
            \\ noalloc: slab:input-r      _slab_ir          bind: :i ;
            \\ noalloc: slab:input-l@     _slab_ils         bind: i:d ;
            \\ noalloc: slab:input-r@     _slab_irs         bind: i:d ;
            \\ noalloc: slab:params       _slab_params      bind: :i ;
            \\ noalloc: slab:write-stereo _slab_ws          bind: di:v ;
            \\ noalloc: slab:write-l      _slab_wl          bind: di:v ;
            \\ noalloc: slab:write-r      _slab_wr          bind: di:v ;
            \\ noalloc: slab:noise        _slab_noise       bind: :d ;
            \\ noalloc: slab:debug-mark   _slab_mark        bind: i:v ;
            \\ :: _slab_px  {d} ; :: _slab_py  {d} ;
            \\ :: _slab_pw  {d} ; :: _slab_ph  {d} ;
            \\ noalloc: slab:panel-x  _slab_px bind: :d ;
            \\ noalloc: slab:panel-y  _slab_py bind: :d ;
            \\ noalloc: slab:panel-w  _slab_pw bind: :d ;
            \\ noalloc: slab:panel-h  _slab_ph bind: :d ;
            \\ :: _w_bevel  {d} ;
            \\ :: _w_label  {d} ; :: _w_labd   {d} ;
            \\ :: _w_knob   {d} ; :: _w_led    {d} ;
            \\ :: _w_sw3    {d} ; :: _w_sw3v   {d} ; :: _w_toggle {d} ;
            \\ : widget:bevel-raised   _w_bevel bind: dddd:v ;
            \\ : widget:draw-label     _w_label bind: ddi:v ;
            \\ : widget:draw-label-dim _w_labd  bind: ddi:v ;
            \\ : widget:knob           _w_knob  bind: ddddid:d ;
            \\ : widget:led            _w_led   bind: dddi:v ;
            \\ : widget:switch3        _w_sw3   bind: ddddiiiid:d ;
            \\ : widget:switch3v       _w_sw3v  bind: ddddiiiid:d ;
            \\ : widget:toggle         _w_toggle bind: ddddid:d ;
        , .{
            @intFromPtr(&slab_sr),
            @intFromPtr(&slab_block_size),
            @intFromPtr(&slab_block_start),
            @intFromPtr(&slab_tempo_bpm),
            @intFromPtr(&slab_note_count),
            @intFromPtr(&slab_note_kind),
            @intFromPtr(&slab_note_pitch),
            @intFromPtr(&slab_note_vel),
            @intFromPtr(&slab_audio_l),
            @intFromPtr(&slab_audio_r),
            @intFromPtr(&slab_input_l),
            @intFromPtr(&slab_input_r),
            @intFromPtr(&slab_input_l_sample),
            @intFromPtr(&slab_input_r_sample),
            @intFromPtr(&slab_params),
            @intFromPtr(&slab_write_stereo),
            @intFromPtr(&slab_write_l),
            @intFromPtr(&slab_write_r),
            @intFromPtr(&slab_noise),
            @intFromPtr(&slab_debug_mark),
            @intFromPtr(&slab_panel_x),
            @intFromPtr(&slab_panel_y),
            @intFromPtr(&slab_panel_w),
            @intFromPtr(&slab_panel_h),
            @intFromPtr(&widgetBevelRaisedC),
            @intFromPtr(&widgetDrawLabelC),
            @intFromPtr(&widgetDrawLabelDimC),
            @intFromPtr(&widgetKnobC),
            @intFromPtr(&widgetLedC),
            @intFromPtr(&widgetSwitch3C),
            @intFromPtr(&widgetSwitch3VerticalC),
            @intFromPtr(&widgetToggleC),
        });
        defer self.alloc.free(src);
        try self.compile(src);

        const debug_src = try std.fmt.allocPrint(self.alloc,
            \\ :: _slab_dbg_mode {d} ;
            \\ noalloc: slab:debug-mode _slab_dbg_mode bind: :i ;
        , .{@intFromPtr(&slab_debug_mode)});
        defer self.alloc.free(debug_src);
        try self.compile(debug_src);
    }

    /// Set the thread-local ctx pointer before calling the audio word.
    pub fn setCtx(ctx: *const MachineCtx) void {
        tl_ctx = ctx;
    }

    /// Clear the thread-local ctx pointer after the audio word returns.
    pub fn clearCtx() void {
        tl_ctx = null;
    }

    /// Set the thread-local audio output buffer pointers before each block.
    pub fn setAudioBuffers(l: [*]f32, r: [*]f32) void {
        tl_l_buf = l;
        tl_r_buf = r;
    }

    pub fn setParams(params: ?*anyopaque) void {
        tl_params = params;
    }

    pub fn setDebugMachineName(name: [*:0]const u8) void {
        tl_debug_machine = name;
    }

    pub fn clearAudioBuffers() void {
        tl_l_buf = null;
        tl_r_buf = null;
    }

    pub fn setUiContext(r: c.rl.Rectangle, m: widgets.Mouse) void {
        tl_ui_rect = r;
        tl_ui_mouse = m;
    }

    pub fn clearUiContext() void {
        tl_ui_mouse = null;
    }

    /// Create a C-callable trampoline for the named fy word.
    /// The trampoline has its own private malloc'd data stack — safe to call
    /// from any thread, including the audio callback thread.
    /// Returns a bare function pointer; the caller owns no cleanup (the
    /// trampoline's stack is freed when the Fy instance is deinit'd).
    pub fn createAudioCallback(self: *FyHost, word_name: []const u8) !*const fn () callconv(.c) void {
        const src = try std.fmt.allocPrint(self.alloc, "callback: :v {s}", .{word_name});
        defer self.alloc.free(src);
        const cb_val = try self.fy.run(src);
        // cb_val = makeInt(tramp_ptr) — untag to recover the actual fn ptr.
        const tramp_ptr: usize = @intCast(@as(u64, @bitCast(cb_val)) >> 2);
        return @ptrFromInt(tramp_ptr);
    }

    /// Start the hot-patch TCP server.  Returns the bound port.
    /// Writes `.fy-port` so the VSCode fy extension auto-connects.
    /// After each successful recompile `hot_reload_count` is incremented;
    /// callers should poll it and call `createAudioCallback` to refresh.
    pub fn startHotPatchServer(self: *FyHost) !u16 {
        const fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        const one: c_int = 1;
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));

        var addr = SockAddrIn{
            .sin_port = htons(0), // port 0 = OS picks
            .sin_addr = std.mem.nativeToBig(u32, INADDR_LOOPBACK),
        };
        if (bind(fd, &addr, @sizeOf(SockAddrIn)) != 0) return error.BindFailed;
        if (listen(fd, 4) != 0) return error.ListenFailed;

        // Read back the actual assigned port.
        var bound = addr;
        var len: u32 = @sizeOf(SockAddrIn);
        _ = getsockname(fd, &bound, &len);
        const port = std.mem.bigToNative(u16, bound.sin_port);

        self.hot_server_fd = fd;

        var pbuf: [16]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&pbuf, "{d}", .{port});
        writeFilePosix(".fy-port", port_str);

        _ = try std.Thread.spawn(.{}, hotPatchServeThread, .{self});
        return port;
    }
};

// ── Hot-patch server internals ────────────────────────────────────────

fn hotPatchServeThread(host: *FyHost) void {
    while (host.hot_server_fd >= 0) {
        const conn = accept(host.hot_server_fd, null, null);
        if (conn < 0) return;
        hotPatchHandleConn(host, conn);
        _ = close(conn);
    }
}

fn fdWrite(fd: c_int, data: []const u8) void {
    _ = std.c.write(fd, data.ptr, data.len);
}

fn hotPatchHandleConn(host: *FyHost, fd: c_int) void {
    var buf: [1024 * 1024]u8 = undefined;
    const total = tcpRead(fd, &buf);
    if (total == 0) {
        fdWrite(fd, "error: empty\n");
        return;
    }

    const data = buf[0..total];
    const nl = std.mem.indexOfScalar(u8, data, '\n') orelse {
        fdWrite(fd, "error: no newline\n");
        return;
    };
    const file_path = data[0..nl];
    const code = data[nl + 1 ..];
    if (code.len == 0) {
        fdWrite(fd, "error: no code\n");
        return;
    }

    // Compile and execute under the hot-patch mutex.
    // runWithBaseDir re-runs top-level statements (e.g. phase reset) which
    // is desirable on hot-patch.
    host.fy.hot_mutex.lock();
    defer host.fy.hot_mutex.unlock();

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    const base_dir = dirName(file_path);
    _ = host.fy.runWithBaseDir(code, base_dir) catch |err| {
        var ebuf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "error:0:{s}\n", .{@errorName(err)}) catch "error:0:?\n";
        fdWrite(fd, msg);
        return;
    };

    _ = host.hot_reload_count.fetchAdd(1, .release);
    fdWrite(fd, "ok\n");
}

fn dirName(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[0..i];
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "Stage 0: define and call a word" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compile(": answer 42 ;");
    const got = try host.callWord("answer");
    try std.testing.expectEqual(Fy.makeInt(42), got);
}

test "Stage 0: words persist across compile calls" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compile(": base 10 ;");
    try host.compile(": doubled base dup + ;");
    const got = try host.callWord("doubled");
    try std.testing.expectEqual(Fy.makeInt(20), got);
}

test "Stage 0: integer arithmetic round-trips" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compile(": add3 3 + ;");
    const got = try host.callWord("7 add3");
    try std.testing.expectEqual(Fy.makeInt(10), got);
}

test "Stage 0: struct accessors and introspection work through the host" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.compile("struct: P ptr a ptr b ;");
    // P.new pops fields in reverse; P.a@ is (ptr -- ptr value)
    const a = try host.callWord("7 9 P.new P.a@ nip");
    try std.testing.expectEqual(Fy.makeInt(7), a);
    const sz = try host.callWord("P.size");
    try std.testing.expectEqual(Fy.makeInt(16), sz);
    const off = try host.callWord("P.b");
    try std.testing.expectEqual(Fy.makeInt(8), off);
}

test "Stage 1: slab:sr returns properly tagged float" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();

    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = 64;
    FyHost.setCtx(&ctx);
    defer FyHost.clearCtx();

    const got = try host.callWord("slab:sr");

    // bind: :d applies makeFloat: (bits & ~3) | TAG_FLT(2)
    const raw: u64 = @bitCast(@as(f64, 48000.0));
    const expected: Fy.Value = @bitCast((raw & ~@as(u64, 3)) | 2);
    try std.testing.expectEqual(expected, got);
}

test "Stage 1: slab:block-size returns tagged int 64" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();

    var ctx = std.mem.zeroes(MachineCtx);
    ctx.block_size = 64;
    FyHost.setCtx(&ctx);
    defer FyHost.clearCtx();

    const got = try host.callWord("slab:block-size");
    try std.testing.expectEqual(Fy.makeInt(64), got);
}

test "Stage 1: builtins compose with fy words" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();

    var ctx = std.mem.zeroes(MachineCtx);
    ctx.block_size = 32;
    FyHost.setCtx(&ctx);
    defer FyHost.clearCtx();

    // fy doubles the block size
    try host.compile(": double-n  slab:block-size dup + ;");
    const got = try host.callWord("double-n");
    try std.testing.expectEqual(Fy.makeInt(64), got);
}

// Stage 2 — read Machine struct from a compiled file, GC rooting test.

// Raw layout of Machine struct as fy stores it in malloc'd memory.
// Fields are stored as fy-tagged values — integers are n << 2, floats
// have lower 2 bits set to TAG_FLT.  Ptr fields (quote refs) store the
// full tagged heap reference.
const RawMachine = extern struct {
    audio: Fy.Value, // tagged heap ref (TAG_STR) — quote for the audio word
    ui: Fy.Value, // tagged heap ref — quote for the UI word (0 if none)
    state_size: u32, // fy-tagged u32: actual size = field >> 2
    params_size: u32,
    in_notes: u8, // fy-tagged u8: 0 or 4 (for 0 or 1)
    out_notes: u8,
    in_audio: u8,
    out_audio: u8,
    _pad: [4]u8,
};

const MACHINE_LIB = "machines/lib";
const SINE_PATH = "machines/sine_v1/sine.fy";
const MONO1_PATH = "machines/mono1/mono1.fy";
const DRUM1_PATH = "machines/drum1/drum1.fy";
const CHORUS1_PATH = "machines/chorus1/chorus1.fy";
const COMP1_PATH = "machines/comp1/comp1.fy";
const FM1_PATH = "machines/fm1/fm1.fy";
const DELAY1_PATH = "machines/delay1/delay1.fy";
const VERB1_PATH = "machines/verb1/verb1.fy";

test "Stage 2: manifest returns correct Machine struct" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();

    try host.registerSlabBuiltins();
    try host.compileFile(SINE_PATH);
    const manifest_val = try host.callWord("manifest");

    // manifest_val = makeInt(raw_ptr).  Untag to get the malloc ptr.
    const raw_ptr: usize = @intCast(@as(u64, @bitCast(manifest_val)) >> 2);
    const m: *const RawMachine = @ptrFromInt(raw_ptr);

    // Field checks.
    try std.testing.expect(Fy.isStr(m.audio)); // audio is a valid heap ref
    // SineState: f64+f64+u32+pad = 24 bytes. makeInt(24)=96 stored as u32.
    // SineParams: f64 = 8 bytes. makeInt(8)=32 stored as u32.
    try std.testing.expectEqual(@as(u32, 24 * 4), m.state_size);
    try std.testing.expectEqual(@as(u32, 8 * 4), m.params_size);
    try std.testing.expectEqual(@as(u8, 1 * 4), m.in_notes); // makeInt(1)
    try std.testing.expectEqual(@as(u8, 0), m.out_notes);
    try std.testing.expectEqual(@as(u8, 0), m.in_audio);
    try std.testing.expectEqual(@as(u8, 1 * 4), m.out_audio);
}

test "mono1 manifest compiles and exposes expected ABI shape" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();

    try host.registerSlabBuiltins();
    try host.compileFile(MONO1_PATH);
    _ = try host.createAudioCallback("mono1-audio");
    const manifest_val = try host.callWord("manifest");

    const raw_ptr: usize = @intCast(@as(u64, @bitCast(manifest_val)) >> 2);
    const m: *const RawMachine = @ptrFromInt(raw_ptr);

    try std.testing.expect(Fy.isStr(m.audio));
    try std.testing.expectEqual(@as(u32, 4 * 4), m.state_size);
    try std.testing.expectEqual(@as(u32, 92 * 4), m.params_size);
    try std.testing.expectEqual(@as(u8, 1 * 4), m.in_notes);
    try std.testing.expectEqual(@as(u8, 0), m.out_notes);
    try std.testing.expectEqual(@as(u8, 0), m.in_audio);
    try std.testing.expectEqual(@as(u8, 1 * 4), m.out_audio);
}

test "fm1 manifest compiles and exposes expected ABI shape" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();

    try host.registerSlabBuiltins();
    try host.compileFile(FM1_PATH);
    _ = try host.createAudioCallback("fm1-audio");
    _ = try host.createAudioCallback("fm1-reset");
    const manifest_val = try host.callWord("manifest");

    const raw_ptr: usize = @intCast(@as(u64, @bitCast(manifest_val)) >> 2);
    const m: *const RawMachine = @ptrFromInt(raw_ptr);

    try std.testing.expect(Fy.isStr(m.audio));
    try std.testing.expectEqual(@as(u32, 4 * 4), m.state_size);
    try std.testing.expectEqual(@as(u32, 56 * 4), m.params_size);
    try std.testing.expectEqual(@as(u8, 1 * 4), m.in_notes);
    try std.testing.expectEqual(@as(u8, 0), m.out_notes);
    try std.testing.expectEqual(@as(u8, 0), m.in_audio);
    try std.testing.expectEqual(@as(u8, 1 * 4), m.out_audio);
}

test "delay1 and verb1 manifests compile and expose effect ABI shape" {
    inline for (.{
        .{ DELAY1_PATH, "delay1-audio", "delay1-reset", @as(u32, 28 * 4) },
        .{ VERB1_PATH, "verb1-audio", "verb1-reset", @as(u32, 20 * 4) },
    }) |case| {
        var host = FyHost.init(std.testing.allocator);
        defer host.deinit();

        try host.registerSlabBuiltins();
        try host.compileFile(case[0]);
        _ = try host.createAudioCallback(case[1]);
        _ = try host.createAudioCallback(case[2]);
        const manifest_val = try host.callWord("manifest");

        const raw_ptr: usize = @intCast(@as(u64, @bitCast(manifest_val)) >> 2);
        const m: *const RawMachine = @ptrFromInt(raw_ptr);

        try std.testing.expect(Fy.isStr(m.audio));
        try std.testing.expectEqual(@as(u32, 4 * 4), m.state_size);
        try std.testing.expectEqual(case[3], m.params_size);
        try std.testing.expectEqual(@as(u8, 0), m.in_notes);
        try std.testing.expectEqual(@as(u8, 0), m.out_notes);
        try std.testing.expectEqual(@as(u8, 1 * 4), m.in_audio);
        try std.testing.expectEqual(@as(u8, 1 * 4), m.out_audio);
    }
}

test "Stage 2: GC rooting — quote refs survive collection" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();

    try host.registerSlabBuiltins();
    try host.compileFile(SINE_PATH);
    const manifest_val = try host.callWord("manifest");
    const raw_ptr: usize = @intCast(@as(u64, @bitCast(manifest_val)) >> 2);
    const m: *const RawMachine = @ptrFromInt(raw_ptr);

    // Force GC. Quote literals are rooted by fy when parsed, so the
    // manifest's audio quote reference must survive collection.
    _ = try host.fy.run("gc");

    try std.testing.expect(Fy.isStr(m.audio));
}

// Modified sine.fy with GAIN = 0.75 for hot-patch testing.
const SINE_HOT = machines_lib_src ++
    \\ : sine-audio
    \\   0 slab:block-size
    \\   [
    \\     0.75 over slab:write-stereo
    \\     1+
    \\   ] dotimes
    \\   drop
    \\ ;
    \\ : sine-ui  ;
    \\ : manifest
    \\   \sine-audio  \sine-ui
    \\   SineState.size  SineParams.size
    \\   notes->audio
    \\   Machine.new
    \\ ;
;

// Full text of machines/lib/machine.fy for inline embedding in SINE_HOT.
const machines_lib_src =
    \\ struct: Machine
    \\   ptr audio  ptr ui  u32 state-size  u32 params-size
    \\   u8 in-notes  u8 out-notes  u8 in-audio  u8 out-audio
    \\ ;
    \\ : notes->audio  1 0 0 1 ;
    \\ struct: SineState  f64 phase  f64 pitch  u32 gate ;
    \\ struct: SineParams  f64 gain ;
;

test "Stage 4: hot-patch recompiles file and callback reflects new GAIN" {
    const FRAMES = 16;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(SINE_PATH);

    // Original callback: GAIN = 0.25. Capture sample[1] as amplitude baseline.
    const cb_orig = try host.createAudioCallback("sine-audio");
    var l_buf = [_]f32{0.0} ** FRAMES;
    var r_buf = [_]f32{0.0} ** FRAMES;
    var ctx = std.mem.zeroes(MachineCtx);
    var on_event = [_]machine_mod.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_on,
        .channel = 0,
        .note_id = -1,
        .pitch = 69,
        .velocity = 1.0,
    }};
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.note_in = @ptrCast(on_event[0..].ptr);
    ctx.note_in_count = on_event.len;
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setAudioBuffers(&l_buf, &r_buf);
    cb_orig();
    FyHost.clearCtx();
    FyHost.clearAudioBuffers();
    const amp_orig = @abs(l_buf[1]);

    // Start hot-patch server.
    const port = try host.startHotPatchServer();
    defer deleteFilePosix(".fy-port");

    // Send modified source (GAIN = 0.75) via TCP.
    const sock = socket(AF_INET, SOCK_STREAM, 0);
    try std.testing.expect(sock >= 0);
    defer _ = close(sock);

    var srv_addr = SockAddrIn{
        .sin_port = htons(port),
        .sin_addr = std.mem.nativeToBig(u32, INADDR_LOOPBACK),
    };
    const connect_fn = struct {
        extern fn connect(fd: c_int, addr: *const SockAddrIn, len: u32) c_int;
    }.connect;
    _ = connect_fn(sock, &srv_addr, @sizeOf(SockAddrIn));

    // Protocol: first line = absolute path, rest = source.
    var abs_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const abs_path = realpathPosix(SINE_PATH, &abs_path_buf) orelse return error.RealpathFailed;
    const msg = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ abs_path, SINE_HOT });
    defer std.testing.allocator.free(msg);
    _ = std.c.write(sock, msg.ptr, msg.len);
    _ = std.c.shutdown(sock, 1); // SHUT_WR = 1

    // Wait for "ok\n".
    var resp_buf: [64]u8 = undefined;
    const resp_len = tcpRead(sock, &resp_buf);
    const resp = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.startsWith(u8, resp, "ok"));

    // Verify reload count incremented.
    try std.testing.expectEqual(@as(u32, 1), host.hot_reload_count.load(.acquire));

    // Create fresh callback — now points to new body with GAIN = 0.75.
    const cb_new = try host.createAudioCallback("sine-audio");
    @memset(&l_buf, 0.0);
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setAudioBuffers(&l_buf, &r_buf);
    cb_new();
    FyHost.clearCtx();
    FyHost.clearAudioBuffers();
    // Phase resets on hot-patch (phase-cell re-initialised by the new source).
    // sample[1] amplitude should be 3× larger (0.75 / 0.25 = 3).
    const amp_new = @abs(l_buf[1]);
    try std.testing.expect(amp_new > amp_orig * 2.0);
}

test "Stage 3: audio callback runs and writes to L/R buffers" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(SINE_PATH);

    // Create a C-callable trampoline for the audio word.
    const render = try host.createAudioCallback("sine-audio");

    // Allocate L/R scratch buffers (zeroed).
    var l_buf = [_]f32{0.0} ** FRAMES;
    var r_buf = [_]f32{0.0} ** FRAMES;

    // Set up ctx + audio buffers, call the trampoline, tear down.
    var ctx = std.mem.zeroes(MachineCtx);
    var on_event = [_]machine_mod.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_on,
        .channel = 0,
        .note_id = -1,
        .pitch = 69,
        .velocity = 1.0,
    }};
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.note_in = @ptrCast(on_event[0..].ptr);
    ctx.note_in_count = on_event.len;
    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setAudioBuffers(&l_buf, &r_buf);
    render();
    FyHost.clearCtx();
    FyHost.clearAudioBuffers();

    // sine-audio: phase starts at 0 → sample[0] = sin(0)*GAIN = 0.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), l_buf[0], 1e-5);
    // sample[1] = sin(step)*GAIN where step = 2π*440/48000 ≈ 0.0576.
    // sin(0.0576) ≈ 0.0575 → sample ≈ 0.0144. Must be positive.
    try std.testing.expect(l_buf[1] > 0.01);
    // L and R must be identical (mono sine into stereo).
    try std.testing.expectApproxEqAbs(l_buf[1], r_buf[1], 1e-5);
    // Buffer is not all zeros — audio is actually running.
    var any_nonzero = false;
    for (l_buf) |s| {
        if (@abs(s) > 1e-6) {
            any_nonzero = true;
            break;
        }
    }
    try std.testing.expect(any_nonzero);
}

test "Stage 3: mono1 renders with host-owned params" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(MONO1_PATH);

    const render = try host.createAudioCallback("mono1-audio");
    var params = extern struct {
        gain: f32 = 0.4,
        range: f32 = 1.0,
        saw: f32 = 1.0,
        pulse: f32 = 0.0,
        pw: f32 = 0.5,
        sub: f32 = 0.0,
        noise: f32 = 0.0,
        attack: f32 = 0.01,
        decay: f32 = 0.12,
        sustain: f32 = 0.7,
        release: f32 = 0.08,
        cutoff: f32 = 1.0,
        resonance: f32 = 0.0,
        drive: f32 = 0.0,
        hpf: f32 = 0.0,
        fenv: f32 = 0.5,
        keytrack: f32 = 0.0,
        lfo_rate: f32 = 0.25,
        lfo_delay: f32 = 0.0,
        lfo_pitch: f32 = 0.0,
        lfo_pw: f32 = 0.0,
        lfo_amp: f32 = 0.0,
        lfo_cutoff: f32 = 0.0,
    }{};

    var silent_l = [_]f32{123.0} ** FRAMES;
    var silent_r = [_]f32{123.0} ** FRAMES;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &.{}, FRAMES, &silent_l, &silent_r);
    for (silent_l, silent_r) |l, r| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), l, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), r, 1e-6);
    }

    var on_event = [_]machine_mod.NoteEvent{
        .{
            .sample_offset = 0,
            .kind = .note_off,
            .channel = 0,
            .note_id = -1,
            .pitch = 60,
            .velocity = 0,
        },
        .{
            .sample_offset = 0,
            .kind = .note_on,
            .channel = 0,
            .note_id = -1,
            .pitch = 60,
            .velocity = 1.0,
        },
    };
    var l_buf = [_]f32{0.0} ** FRAMES;
    var r_buf = [_]f32{0.0} ** FRAMES;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &l_buf, &r_buf);

    try std.testing.expect(@abs(l_buf[0]) < 0.001);
    try std.testing.expect(@abs(r_buf[0]) < 0.001);
    var peak: f32 = 0;
    for (l_buf, r_buf) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        peak = @max(peak, @abs(l), @abs(r));
        try std.testing.expect(@abs(l) <= 1.0);
        try std.testing.expect(@abs(r) <= 1.0);
    }
    try std.testing.expect(peak > 0.0001);

    var off_event = [_]machine_mod.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_off,
        .channel = 0,
        .note_id = -1,
        .pitch = 60,
        .velocity = 0,
    }};
    var rel_l = [_]f32{0.0} ** FRAMES;
    var rel_r = [_]f32{0.0} ** FRAMES;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &off_event, FRAMES, &rel_l, &rel_r);
    try expectMono1BlockFiniteBounded(rel_l, rel_r);
    try std.testing.expect(@abs(rel_l[0] - l_buf[FRAMES - 1]) < 0.25);

    var retrig_l = [_]f32{0.0} ** FRAMES;
    var retrig_r = [_]f32{0.0} ** FRAMES;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &retrig_l, &retrig_r);
    try expectMono1BlockNonzeroBounded(retrig_l, retrig_r);
    try std.testing.expect(@abs(retrig_l[0] - rel_l[FRAMES - 1]) < 0.25);

    var saw_l = [_]f32{0.0} ** FRAMES;
    var saw_r = [_]f32{0.0} ** FRAMES;
    params.saw = 1.0;
    params.pulse = 0.0;
    params.sub = 0.0;
    params.noise = 0.0;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &saw_l, &saw_r);

    var pulse_l = [_]f32{0.0} ** FRAMES;
    var pulse_r = [_]f32{0.0} ** FRAMES;
    params.saw = 0.0;
    params.pulse = 1.0;
    params.pw = 0.5;
    params.sub = 0.0;
    params.noise = 0.0;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &pulse_l, &pulse_r);

    var diff_sum: f32 = 0;
    for (saw_l, pulse_l) |saw, pulse| {
        try std.testing.expect(std.math.isFinite(pulse));
        try std.testing.expect(@abs(pulse) <= 1.0);
        diff_sum += @abs(saw - pulse);
    }
    try std.testing.expect(diff_sum > 0.01);

    var narrow_l = [_]f32{0.0} ** FRAMES;
    var narrow_r = [_]f32{0.0} ** FRAMES;
    params.pw = 0.01;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &narrow_l, &narrow_r);
    for (narrow_l, narrow_r) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        try std.testing.expect(@abs(l) <= 1.0);
        try std.testing.expect(@abs(r) <= 1.0);
    }

    var sub_l = [_]f32{0.0} ** FRAMES;
    var sub_r = [_]f32{0.0} ** FRAMES;
    params.pw = 0.5;
    params.saw = 0.0;
    params.pulse = 0.0;
    params.sub = 1.0;
    params.noise = 0.0;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &sub_l, &sub_r);
    try expectMono1BlockNonzeroBounded(sub_l, sub_r);

    var noise_l = [_]f32{0.0} ** FRAMES;
    var noise_r = [_]f32{0.0} ** FRAMES;
    params.saw = 0.0;
    params.pulse = 0.0;
    params.sub = 0.0;
    params.noise = 1.0;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &noise_l, &noise_r);
    try expectMono1BlockNonzeroBounded(noise_l, noise_r);

    var muted_l = [_]f32{0.0} ** FRAMES;
    var muted_r = [_]f32{0.0} ** FRAMES;
    params.saw = 0.0;
    params.pulse = 0.0;
    params.sub = 0.0;
    params.noise = 0.0;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &muted_l, &muted_r);
    try expectMono1BlockFiniteBounded(muted_l, muted_r);

    var resonant_l = [_]f32{0.0} ** FRAMES;
    var resonant_r = [_]f32{0.0} ** FRAMES;
    params.saw = 1.0;
    params.pulse = 0.4;
    params.sub = 0.3;
    params.noise = 0.2;
    params.cutoff = 0.36;
    params.resonance = 1.0;
    params.drive = 0.7;
    params.hpf = 0.6;
    params.fenv = 1.0;
    params.keytrack = 0.4;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &resonant_l, &resonant_r);
    try expectMono1BlockNonzeroBounded(resonant_l, resonant_r);

    var inv_env_l = [_]f32{0.0} ** FRAMES;
    var inv_env_r = [_]f32{0.0} ** FRAMES;
    params.fenv = 0.0;
    params.keytrack = 0.4;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &inv_env_l, &inv_env_r);
    try expectMono1BlockNonzeroBounded(inv_env_l, inv_env_r);

    var lfo_l = [_]f32{0.0} ** FRAMES;
    var lfo_r = [_]f32{0.0} ** FRAMES;
    params.lfo_rate = 0.75;
    params.lfo_delay = 0.0;
    params.lfo_pitch = 0.4;
    params.lfo_pw = 0.5;
    params.lfo_amp = 0.5;
    params.lfo_cutoff = 0.5;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &lfo_l, &lfo_r);
    try expectMono1BlockNonzeroBounded(lfo_l, lfo_r);
}

test "mono1 reset clears sustained voice state" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(MONO1_PATH);

    const render = try host.createAudioCallback("mono1-audio");
    const reset = try host.createAudioCallback("mono1-reset");
    var params = extern struct {
        gain: f32 = 0.45,
        range: f32 = 1.0,
        saw: f32 = 1.0,
        pulse: f32 = 0.0,
        pw: f32 = 0.5,
        sub: f32 = 0.0,
        noise: f32 = 0.0,
        attack: f32 = 0.01,
        decay: f32 = 0.12,
        sustain: f32 = 0.8,
        release: f32 = 0.2,
        cutoff: f32 = 1.0,
        resonance: f32 = 0.0,
        drive: f32 = 0.0,
        hpf: f32 = 0.0,
        fenv: f32 = 0.5,
        keytrack: f32 = 0.0,
        lfo_rate: f32 = 0.25,
        lfo_delay: f32 = 0.0,
        lfo_pitch: f32 = 0.0,
        lfo_pw: f32 = 0.0,
        lfo_amp: f32 = 0.0,
        lfo_cutoff: f32 = 0.0,
    }{};

    var on_event = [_]machine_mod.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_on,
        .channel = 0,
        .note_id = -1,
        .pitch = 60,
        .velocity = 1.0,
    }};
    var l_buf = [_]f32{0.0} ** FRAMES;
    var r_buf = [_]f32{0.0} ** FRAMES;
    try renderMono1TestBlock(&host, render, @ptrCast(&params), &on_event, FRAMES, &l_buf, &r_buf);
    try expectMono1BlockNonzeroBounded(l_buf, r_buf);

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setParams(@ptrCast(&params));
    reset();
    FyHost.setParams(null);

    try renderMono1TestBlock(&host, render, @ptrCast(&params), &.{}, FRAMES, &l_buf, &r_buf);
    for (l_buf, r_buf) |l, r| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), l, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), r, 0.000001);
    }
}

fn expectMono1BlockNonzeroBounded(l_buf: anytype, r_buf: anytype) !void {
    var peak: f32 = 0;
    for (l_buf, r_buf) |l, r| {
        try expectMono1SampleFiniteBounded(l);
        try expectMono1SampleFiniteBounded(r);
        peak = @max(peak, @abs(l), @abs(r));
    }
    try std.testing.expect(peak > 0.0001);
}

fn expectMono1BlockFiniteBounded(l_buf: anytype, r_buf: anytype) !void {
    for (l_buf, r_buf) |l, r| {
        try expectMono1SampleFiniteBounded(l);
        try expectMono1SampleFiniteBounded(r);
    }
}

fn expectMono1SampleFiniteBounded(s: f32) !void {
    try std.testing.expect(std.math.isFinite(s));
    try std.testing.expect(@abs(s) <= 1.0);
}

fn renderMono1TestBlock(
    host: *FyHost,
    render: *const fn () callconv(.c) void,
    params: *anyopaque,
    events: []const machine_mod.NoteEvent,
    comptime FRAMES: usize,
    l_buf: *[FRAMES]f32,
    r_buf: *[FRAMES]f32,
) !void {
    @memset(l_buf[0..], 0);
    @memset(r_buf[0..], 0);
    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.note_in = if (events.len > 0) @ptrCast(events.ptr) else null;
    ctx.note_in_count = @intCast(events.len);
    ctx.params_current = params;

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setParams(ctx.params_current);
    FyHost.setAudioBuffers(l_buf.ptr, r_buf.ptr);
    render();
    FyHost.clearAudioBuffers();
    FyHost.setParams(null);
    FyHost.clearCtx();
}

test "Stage 3: drum1 renders bounded drum lanes without crashing" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(DRUM1_PATH);

    const render = try host.createAudioCallback("drum1-audio");
    const pitches = [_]f32{ 36.0, 38.0, 42.0, 46.0, 60.0, 72.0 };
    for (pitches) |pitch| {
        var on_event = [_]machine_mod.NoteEvent{.{
            .sample_offset = 0,
            .kind = .note_on,
            .channel = 0,
            .note_id = -1,
            .pitch = pitch,
            .velocity = 0.9,
        }};
        const should_sound = pitch == 36.0 or pitch == 38.0 or pitch == 42.0 or pitch == 46.0 or pitch == 60.0 or pitch == 72.0;
        try renderDrum1TestBlock(&host, render, &on_event, FRAMES, should_sound);

        var block: usize = 0;
        while (block < 32) : (block += 1) {
            try renderDrum1TestBlock(&host, render, &.{}, FRAMES, false);
        }

        var off_event = [_]machine_mod.NoteEvent{.{
            .sample_offset = FRAMES - 1,
            .kind = .note_off,
            .channel = 0,
            .note_id = -1,
            .pitch = pitch,
            .velocity = 0,
        }};
        try renderDrum1TestBlock(&host, render, &off_event, FRAMES, false);
    }

    var stacked = [_]machine_mod.NoteEvent{
        .{
            .sample_offset = 0,
            .kind = .note_on,
            .channel = 0,
            .note_id = -1,
            .pitch = 36,
            .velocity = 0.9,
        },
        .{
            .sample_offset = 8,
            .kind = .note_on,
            .channel = 0,
            .note_id = -1,
            .pitch = 38,
            .velocity = 0.9,
        },
        .{
            .sample_offset = 16,
            .kind = .note_on,
            .channel = 0,
            .note_id = -1,
            .pitch = 42,
            .velocity = 0.9,
        },
        .{
            .sample_offset = 24,
            .kind = .note_on,
            .channel = 0,
            .note_id = -1,
            .pitch = 46,
            .velocity = 0.9,
        },
    };
    try renderDrum1TestBlock(&host, render, &stacked, FRAMES, true);

    var tail_block: usize = 0;
    while (tail_block < 128) : (tail_block += 1) {
        try renderDrum1TestBlock(&host, render, &.{}, FRAMES, false);
    }
}

fn renderDrum1TestBlock(host: *FyHost, render: *const fn () callconv(.c) void, events: []machine_mod.NoteEvent, comptime FRAMES: usize, expect_sound: bool) !void {
    var l_buf = [_]f32{0.0} ** FRAMES;
    var r_buf = [_]f32{0.0} ** FRAMES;
    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.note_in = if (events.len > 0) @ptrCast(events.ptr) else null;
    ctx.note_in_count = @intCast(events.len);

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setAudioBuffers(&l_buf, &r_buf);
    render();
    FyHost.clearCtx();
    FyHost.clearAudioBuffers();

    var peak: f32 = 0;
    for (l_buf, r_buf) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        peak = @max(peak, @abs(l), @abs(r));
    }
    if (expect_sound) try std.testing.expect(peak > 0.001);
}

test "fm1 renders bounded phase-modulated tones" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(FM1_PATH);

    const render = try host.createAudioCallback("fm1-audio");
    const reset = try host.createAudioCallback("fm1-reset");
    var params = @import("machines/fy_machine.zig").Fm1Params{
        .level = 0.48,
        .algorithm = 0.0,
        .feedback = 0.18,
        .op2_level = 0.60,
        .op3_level = 0.34,
        .op4_level = 0.18,
        .op2_ratio = 0.25,
        .op3_ratio = 0.50,
        .op4_ratio = 0.75,
        .attack = 0.002,
        .decay = 0.24,
        .sustain = 0.45,
        .release = 0.16,
        .wave = 0.0,
    };
    var on_event = [_]machine_mod.NoteEvent{.{
        .sample_offset = 0,
        .kind = .note_on,
        .channel = 0,
        .note_id = -1,
        .pitch = 60,
        .velocity = 1.0,
    }};

    var l_buf = [_]f32{0.0} ** FRAMES;
    var r_buf = [_]f32{0.0} ** FRAMES;
    try renderFm1TestBlock(&host, render, &params, &on_event, FRAMES, &l_buf, &r_buf);
    try expectFm1BlockNonzeroBounded(l_buf, r_buf);

    const alg0_l = l_buf;
    params.algorithm = 0.80;
    try renderFm1TestBlock(&host, render, &params, &on_event, FRAMES, &l_buf, &r_buf);
    try expectFm1BlockNonzeroBounded(l_buf, r_buf);

    var diff_sum: f32 = 0.0;
    for (alg0_l, l_buf) |a, b| diff_sum += @abs(a - b);
    try std.testing.expect(diff_sum > 0.001);

    params.wave = 0.45;
    try renderFm1TestBlock(&host, render, &params, &on_event, FRAMES, &l_buf, &r_buf);
    try expectFm1BlockNonzeroBounded(l_buf, r_buf);

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setParams(@ptrCast(&params));
    reset();
    FyHost.setParams(null);

    try renderFm1TestBlock(&host, render, &params, &.{}, FRAMES, &l_buf, &r_buf);
    for (l_buf, r_buf) |l, r| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), l, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), r, 0.000001);
    }
}

fn renderFm1TestBlock(
    host: *FyHost,
    render: *const fn () callconv(.c) void,
    params: *@import("machines/fy_machine.zig").Fm1Params,
    events: []const machine_mod.NoteEvent,
    comptime FRAMES: usize,
    l_buf: *[FRAMES]f32,
    r_buf: *[FRAMES]f32,
) !void {
    @memset(l_buf[0..], 0);
    @memset(r_buf[0..], 0);
    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.note_in = if (events.len > 0) @ptrCast(events.ptr) else null;
    ctx.note_in_count = @intCast(events.len);
    ctx.params_current = params;

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setParams(ctx.params_current);
    FyHost.setAudioBuffers(l_buf.ptr, r_buf.ptr);
    render();
    FyHost.clearAudioBuffers();
    FyHost.setParams(null);
    FyHost.clearCtx();
}

fn expectFm1BlockNonzeroBounded(l_buf: anytype, r_buf: anytype) !void {
    var peak: f32 = 0.0;
    for (l_buf, r_buf) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        try std.testing.expect(@abs(l) <= 1.0);
        try std.testing.expect(@abs(r) <= 1.0);
        peak = @max(peak, @abs(l), @abs(r));
    }
    try std.testing.expect(peak > 0.0001);
}

const ChorusTestParams = extern struct {
    mode: f32 = 0.0,
    mix: f32 = 0.42,
    noise: f32 = 0.0,
    level: f32 = 1.0,
};

fn renderChorusTestBlock(
    host: *FyHost,
    render: *const fn () callconv(.c) void,
    comptime FRAMES: usize,
    in_l: *[FRAMES]f32,
    in_r: *[FRAMES]f32,
    out_l: *[FRAMES]f32,
    out_r: *[FRAMES]f32,
    params: *ChorusTestParams,
) void {
    const in_ports = [_][*]const f32{ in_l[0..].ptr, in_r[0..].ptr };
    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;
    ctx.params_current = params;

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setParams(ctx.params_current);
    FyHost.setAudioBuffers(out_l, out_r);
    render();
    FyHost.clearAudioBuffers();
    FyHost.setParams(null);
    FyHost.clearCtx();
}

test "Stage 3: chorus1 processes audio input" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(CHORUS1_PATH);

    const render = try host.createAudioCallback("chorus1-audio");
    var in_l = [_]f32{0.25} ** FRAMES;
    var in_r = [_]f32{-0.25} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var params = ChorusTestParams{};

    renderChorusTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);

    var peak: f32 = 0;
    for (out_l, out_r) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        peak = @max(peak, @abs(l), @abs(r));
    }
    try std.testing.expect(peak > 0.01);
}

test "chorus1 silence remains silent with noise off" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(CHORUS1_PATH);

    const render = try host.createAudioCallback("chorus1-audio");
    var in_l = [_]f32{0.0} ** FRAMES;
    var in_r = [_]f32{0.0} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var params = ChorusTestParams{ .noise = 0.0 };

    renderChorusTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);

    for (out_l, out_r) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), l, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), r, 0.000001);
    }
}

test "chorus1 mix zero returns dry input" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(CHORUS1_PATH);

    const render = try host.createAudioCallback("chorus1-audio");
    var in_l = [_]f32{0.25} ** FRAMES;
    var in_r = [_]f32{-0.125} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var params = ChorusTestParams{ .mix = 0.0, .level = 1.0 };

    renderChorusTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);

    for (out_l[1..], out_r[1..], in_l[1..], in_r[1..]) |ol, or_, il, ir| {
        try std.testing.expectApproxEqAbs(il, ol, 0.000001);
        try std.testing.expectApproxEqAbs(ir, or_, 0.000001);
    }
}

test "chorus1 modes differ and decorrelate mono input" {
    const FRAMES = 64;
    var sums = [_]f64{0.0} ** 3;
    var diffs = [_]f64{0.0} ** 3;

    for (0..3) |mode| {
        var host = FyHost.init(std.testing.allocator);
        defer host.deinit();
        try host.registerSlabBuiltins();
        try host.compileFile(CHORUS1_PATH);

        const render = try host.createAudioCallback("chorus1-audio");
        var in_l: [FRAMES]f32 = undefined;
        var in_r: [FRAMES]f32 = undefined;
        var out_l = [_]f32{0.0} ** FRAMES;
        var out_r = [_]f32{0.0} ** FRAMES;
        var params = ChorusTestParams{
            .mode = @floatFromInt(mode),
            .mix = 1.0,
            .noise = 0.0,
            .level = 1.0,
        };

        for (0..36) |block| {
            for (&in_l, &in_r, 0..) |*l, *r, i| {
                const sample_index: f32 = @floatFromInt(block * FRAMES + i);
                const v: f32 = @floatCast(std.math.sin(@as(f64, sample_index) * 0.037) * 0.35);
                l.* = v;
                r.* = v;
            }
            renderChorusTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
        }

        for (out_l, out_r) |l, r| {
            try std.testing.expect(std.math.isFinite(l));
            try std.testing.expect(std.math.isFinite(r));
            sums[mode] += @as(f64, l);
            diffs[mode] += @abs(@as(f64, l) - @as(f64, r));
        }
    }

    try std.testing.expect(@abs(sums[0] - sums[1]) > 0.0001);
    try std.testing.expect(@abs(sums[1] - sums[2]) > 0.0001);
    try std.testing.expect(diffs[0] > 0.0001);
    try std.testing.expect(diffs[1] > 0.0001);
}

test "chorus1 high wet noise remains bounded" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(CHORUS1_PATH);

    const render = try host.createAudioCallback("chorus1-audio");
    var in_l = [_]f32{0.5} ** FRAMES;
    var in_r = [_]f32{-0.25} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var params = ChorusTestParams{ .mode = 2.0, .mix = 1.0, .noise = 1.0, .level = 1.0 };

    for (0..40) |_| {
        renderChorusTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
    }

    for (out_l, out_r) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        try std.testing.expect(@abs(l) < 2.0);
        try std.testing.expect(@abs(r) < 2.0);
    }
}

test "chorus1 registry defaults pass dry signal immediately" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(CHORUS1_PATH);

    const render = try host.createAudioCallback("chorus1-audio");
    var in_l = [_]f32{0.5} ** FRAMES;
    var in_r = [_]f32{-0.25} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var params = @import("machines/fy_machine.zig").Chorus1Params{
        .mode = 0.0,
        .mix = 0.42,
        .noise = 0.02,
        .level = 1.0,
    };

    const in_ports = [_][*]const f32{ in_l[0..].ptr, in_r[0..].ptr };
    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;
    ctx.params_current = &params;

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setParams(ctx.params_current);
    FyHost.setAudioBuffers(&out_l, &out_r);
    render();
    FyHost.clearAudioBuffers();
    FyHost.setParams(null);
    FyHost.clearCtx();

    try std.testing.expect(out_l[1] > 0.25);
    try std.testing.expect(out_r[1] < -0.1);
}

const Comp1TestParams = @import("machines/fy_machine.zig").Comp1Params;

fn renderComp1TestBlock(
    host: *FyHost,
    render: *const fn () callconv(.c) void,
    comptime FRAMES: usize,
    in_l: *[FRAMES]f32,
    in_r: *[FRAMES]f32,
    out_l: *[FRAMES]f32,
    out_r: *[FRAMES]f32,
    params: *Comp1TestParams,
) void {
    const in_ports = [_][*]const f32{ in_l[0..].ptr, in_r[0..].ptr };
    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;
    ctx.params_current = params;

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setParams(ctx.params_current);
    FyHost.setAudioBuffers(out_l, out_r);
    render();
    FyHost.clearAudioBuffers();
    FyHost.setParams(null);
    FyHost.clearCtx();
}

test "comp1 processes audio and remains bounded" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(COMP1_PATH);

    const render = try host.createAudioCallback("comp1-audio");
    var in_l = [_]f32{0.8} ** FRAMES;
    var in_r = [_]f32{-0.8} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var params = Comp1TestParams{
        .threshold = 0.10,
        .ratio = 1.0,
        .attack = 0.0,
        .release = 0.35,
        .makeup = 0.25,
        .mix = 1.0,
        .drive = 0.0,
    };

    for (0..48) |_| {
        renderComp1TestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
    }

    var peak: f32 = 0.0;
    for (out_l, out_r) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        peak = @max(peak, @abs(l), @abs(r));
    }
    try std.testing.expect(peak > 0.02);
    try std.testing.expect(peak < 0.72);
}

test "comp1 mix zero returns dry input" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(COMP1_PATH);

    const render = try host.createAudioCallback("comp1-audio");
    var in_l = [_]f32{0.25} ** FRAMES;
    var in_r = [_]f32{-0.125} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var params = Comp1TestParams{
        .threshold = 0.10,
        .ratio = 1.0,
        .attack = 0.0,
        .release = 0.35,
        .makeup = 0.25,
        .mix = 0.0,
        .drive = 1.0,
    };

    renderComp1TestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);

    for (out_l, out_r, in_l, in_r) |ol, or_, il, ir| {
        try std.testing.expectApproxEqAbs(il, ol, 0.000001);
        try std.testing.expectApproxEqAbs(ir, or_, 0.000001);
    }
}

test "delay1 produces bounded delayed tail" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(DELAY1_PATH);

    const render = try host.createAudioCallback("delay1-audio");
    var params = @import("machines/fy_machine.zig").Delay1Params{
        .time = 0.0,
        .feedback = 0.35,
        .mix = 0.65,
        .tone = 0.55,
        .ping = 0.8,
        .mod = 0.0,
        .level = 0.8,
    };

    var in_l = [_]f32{0.0} ** FRAMES;
    var in_r = [_]f32{0.0} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    in_l[0] = 0.8;
    renderEffectTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
    try expectEffectBlockFiniteBounded(out_l, out_r);

    var tail_peak: f32 = 0.0;
    @memset(in_l[0..], 0);
    var block: usize = 0;
    while (block < 8) : (block += 1) {
        renderEffectTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
        try expectEffectBlockFiniteBounded(out_l, out_r);
        for (out_l, out_r) |l, r| tail_peak = @max(tail_peak, @abs(l), @abs(r));
    }
    try std.testing.expect(tail_peak > 0.001);
}

test "verb1 produces bounded stereo tail" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(VERB1_PATH);

    const render = try host.createAudioCallback("verb1-audio");
    var params = @import("machines/fy_machine.zig").Verb1Params{
        .size = 0.75,
        .damp = 0.42,
        .mix = 0.7,
        .width = 0.9,
        .level = 0.78,
    };

    var in_l = [_]f32{0.0} ** FRAMES;
    var in_r = [_]f32{0.0} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    in_l[0] = 0.8;
    in_r[0] = 0.2;
    renderEffectTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
    try expectEffectBlockFiniteBounded(out_l, out_r);

    var tail_peak: f32 = 0.0;
    var wet_energy: f64 = 0.0;
    @memset(in_l[0..], 0);
    @memset(in_r[0..], 0);
    var block: usize = 0;
    while (block < 220) : (block += 1) {
        renderEffectTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
        try expectEffectBlockFiniteBounded(out_l, out_r);
        for (out_l, out_r) |l, r| {
            tail_peak = @max(tail_peak, @abs(l), @abs(r));
            wet_energy += @as(f64, l) * @as(f64, l) + @as(f64, r) * @as(f64, r);
        }
    }
    try std.testing.expect(tail_peak > 0.02);
    try std.testing.expect(wet_energy > 0.02);
}

test "verb1 silent input stays silent after reset" {
    const FRAMES = 64;
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerSlabBuiltins();
    try host.compileFile(VERB1_PATH);

    const render = try host.createAudioCallback("verb1-audio");
    const reset = try host.createAudioCallback("verb1-reset");
    var params = @import("machines/fy_machine.zig").Verb1Params{
        .size = 0.7,
        .damp = 0.4,
        .mix = 1.0,
        .width = 1.0,
        .level = 1.0,
    };

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setParams(@ptrCast(&params));
    reset();
    FyHost.setParams(null);

    var in_l = [_]f32{0.0} ** FRAMES;
    var in_r = [_]f32{0.0} ** FRAMES;
    var out_l = [_]f32{0.0} ** FRAMES;
    var out_r = [_]f32{0.0} ** FRAMES;
    var block: usize = 0;
    while (block < 24) : (block += 1) {
        renderEffectTestBlock(&host, render, FRAMES, &in_l, &in_r, &out_l, &out_r, &params);
        for (out_l, out_r) |l, r| {
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), l, 0.000001);
            try std.testing.expectApproxEqAbs(@as(f32, 0.0), r, 0.000001);
        }
    }
}

fn renderEffectTestBlock(
    host: *FyHost,
    render: *const fn () callconv(.c) void,
    comptime FRAMES: usize,
    in_l: *[FRAMES]f32,
    in_r: *[FRAMES]f32,
    out_l: *[FRAMES]f32,
    out_r: *[FRAMES]f32,
    params: *anyopaque,
) void {
    const in_ports = [_][*]const f32{ in_l[0..].ptr, in_r[0..].ptr };
    @memset(out_l[0..], 0);
    @memset(out_r[0..], 0);
    var ctx = std.mem.zeroes(MachineCtx);
    ctx.sample_rate = 48000.0;
    ctx.block_size = FRAMES;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;
    ctx.params_current = params;

    Fy.Builtins.fyPtr = @intFromPtr(&host.fy);
    FyHost.setCtx(&ctx);
    FyHost.setParams(ctx.params_current);
    FyHost.setAudioBuffers(out_l, out_r);
    render();
    FyHost.clearAudioBuffers();
    FyHost.setParams(null);
    FyHost.clearCtx();
}

fn expectEffectBlockFiniteBounded(l_buf: anytype, r_buf: anytype) !void {
    for (l_buf, r_buf) |l, r| {
        try std.testing.expect(std.math.isFinite(l));
        try std.testing.expect(std.math.isFinite(r));
        try std.testing.expect(@abs(l) <= 1.5);
        try std.testing.expect(@abs(r) <= 1.5);
    }
}

fn emptyAudioCallback() callconv(.c) void {}

test "fy machine preset banks expose juno-style mono1 and chorus sounds" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();

    const mono = try std.testing.allocator.create(@import("machines/fy_machine.zig").FyMachine);
    defer std.testing.allocator.destroy(mono);
    mono.* = @import("machines/fy_machine.zig").FyMachine.init(&host, "mono1", emptyAudioCallback, null, null, @sizeOf(@import("machines/fy_machine.zig").Mono1Params));
    const mono_iface = mono.machineInterface();
    try std.testing.expect((mono_iface.preset_count orelse unreachable)(mono_iface.state) >= 8);
    try std.testing.expectEqualStrings("JP PUNCH BASS", std.mem.span((mono_iface.preset_name orelse unreachable)(mono_iface.state, 3)));

    (mono_iface.apply_preset orelse unreachable)(mono_iface.state, 4);
    const mono_params: *align(1) const @import("machines/fy_machine.zig").Mono1Params = @ptrCast(&mono.params[0]);
    try std.testing.expect(mono_params.attack > 0.03);
    try std.testing.expect(mono_params.release > 0.3);
    try std.testing.expect(mono_params.lfo_pw > 0.0);

    const chorus = try std.testing.allocator.create(@import("machines/fy_machine.zig").FyMachine);
    defer std.testing.allocator.destroy(chorus);
    chorus.* = @import("machines/fy_machine.zig").FyMachine.init(&host, "chorus", emptyAudioCallback, null, null, @sizeOf(@import("machines/fy_machine.zig").Chorus1Params));
    const chorus_iface = chorus.machineInterface();
    try std.testing.expectEqual(@as(u8, 4), (chorus_iface.preset_count orelse unreachable)(chorus_iface.state));
    try std.testing.expectEqualStrings("JUNO I+II", std.mem.span((chorus_iface.preset_name orelse unreachable)(chorus_iface.state, 2)));

    (chorus_iface.apply_preset orelse unreachable)(chorus_iface.state, 2);
    const chorus_params: *align(1) const @import("machines/fy_machine.zig").Chorus1Params = @ptrCast(&chorus.params[0]);
    try std.testing.expectEqual(@as(f32, 2.0), chorus_params.mode);
    try std.testing.expect(chorus_params.mix > 0.5);
}

test "fy struct: S.size, S.new, field accessors work" {
    var host = FyHost.init(std.testing.allocator);
    defer host.deinit();
    // Two f64 fields = 16 bytes.
    try host.compile(
        \\ struct: V f64 x f64 y ;
    );
    // S.size should return makeInt(16) = 64.
    const sz = try host.callWord("V.size");
    try std.testing.expectEqual(Fy.makeInt(16), sz);
    // Create a V with x=1.5, y=2.5 and read back both fields.
    try host.compile(": make-v  1.5 2.5 V.new ;");
    try host.compile(": read-x  V.new V.x@ nip ;");
    try host.compile(": read-y  V.new V.y@ nip ;");
    // x=1.5: read via field accessor, result must be a tagged float.
    try host.compile(": getx  1.5 2.5 V.new V.x@ nip ;");
    const got_x = try host.callWord("getx");
    // 1.5 bits = 0x3FF8000000000000; tagged = (bits & ~3) | 2
    const x_raw: u64 = @bitCast(@as(f64, 1.5));
    const x_expected: Fy.Value = @bitCast((x_raw & ~@as(u64, 3)) | 2);
    try std.testing.expectEqual(x_expected, got_x);
}
