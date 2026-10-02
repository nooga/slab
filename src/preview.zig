//! What the browser previews (docs/25 §The browser): the selected
//! sample or wavetable, decoded for its picture, and played through the
//! engine's preview voice on request. One file at a time; a file being
//! replaced while the audio thread may still read it waits in `retired`
//! until the engine has taken a newer request.

const std = @import("std");
const wav = @import("wav.zig");
const storage = @import("storage.zig");
const engine_mod = @import("engine.zig");

const MAX_RETIRED = 8;

const Retired = struct { sample: wav.Sample, after: u32 };

pub const Previewer = struct {
    alloc: std.mem.Allocator,
    cur: ?wav.Sample = null,
    path_buf: [storage.MAX_PATH]u8 = undefined,
    path_len: usize = 0,
    /// Data the audio thread may still hold, and the request after which
    /// it doesn't.
    retired: [MAX_RETIRED]?Retired = [_]?Retired{null} ** MAX_RETIRED,
    playing: bool = false,

    pub fn init(alloc: std.mem.Allocator) Previewer {
        return .{ .alloc = alloc };
    }

    /// The engine must be stopped, or done with the data.
    pub fn deinit(self: *Previewer) void {
        if (self.cur) |*s| s.deinit(self.alloc);
        for (&self.retired) |*r| if (r.*) |*x| {
            x.sample.deinit(self.alloc);
            r.* = null;
        };
    }

    pub fn path(self: *const Previewer) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Decode `file` for the picture (and a later `play`); the one held
    /// before stops and is retired. Null if it won't load.
    pub fn select(self: *Previewer, engine: *engine_mod.Engine, file: []const u8) ?*const wav.Sample {
        if (self.cur != null and std.mem.eql(u8, self.path(), file)) return &self.cur.?;
        self.release(engine);
        if (file.len > self.path_buf.len) return null;
        const s = wav.load(self.alloc, file) catch return null;
        self.cur = s;
        @memcpy(self.path_buf[0..file.len], file);
        self.path_len = file.len;
        return &self.cur.?;
    }

    pub fn play(self: *Previewer, engine: *engine_mod.Engine) void {
        const s = self.cur orelse return;
        _ = engine.previewSample(s.data, s.sample_rate);
        self.playing = true;
    }

    pub fn stop(self: *Previewer, engine: *engine_mod.Engine) void {
        if (!self.playing) return;
        _ = engine.stopPreview();
        self.playing = false;
    }

    /// Where the playing preview is, in its frames; null when silent.
    pub fn at(self: *Previewer, engine: *const engine_mod.Engine) ?u32 {
        if (!self.playing) return null;
        const f = engine.previewFrame();
        if (f == null and engine.preview_ack.load(.acquire) == engine.preview_req.load(.acquire)) self.playing = false;
        return f;
    }

    /// Free what the audio thread has let go of. Call once a frame.
    pub fn collect(self: *Previewer, engine: *const engine_mod.Engine) void {
        const ack = engine.preview_ack.load(.acquire);
        for (&self.retired) |*r| if (r.*) |*x| {
            if (@as(i32, @bitCast(ack -% x.after)) >= 0) {
                x.sample.deinit(self.alloc);
                r.* = null;
            }
        };
    }

    fn release(self: *Previewer, engine: *engine_mod.Engine) void {
        var s = self.cur orelse return;
        self.cur = null;
        self.path_len = 0;
        // Stop the voice; the data lives until the engine took that.
        const after = engine.stopPreview();
        self.playing = false;
        for (&self.retired) |*r| if (r.* == null) {
            r.* = .{ .sample = s, .after = after };
            return;
        };
        // No room (the device isn't running blocks): keep it rather than
        // free what the audio thread might read.
        std.log.warn("preview: no room to retire a sample; keeping it", .{});
        _ = &s;
    }
};
