//! Registry of fy machines.  Each entry owns its own FyHost so word
//! names (phase-cell, gain-cell, …) don't alias across machines.

const std = @import("std");
const Fy = @import("fy").Fy;
const machine = @import("machine.zig");
const fy_host_mod = @import("fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const fy_machine_mod = @import("machines/fy_machine.zig");
const FyMachine = fy_machine_mod.FyMachine;
const poly_mod = @import("machines/poly.zig");
const fy_raw_machine_mod = @import("machines/fy_raw_machine.zig");

test {
    _ = fy_raw_machine_mod.FyRawMachine;
    _ = @import("ms20_svf_test.zig");
}

extern fn close(fd: c_int) c_int;
extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern fn fstat(fd: c_int, sb: *std.c.Stat) c_int;
const O_RDONLY: c_int = 0;

pub const MAX_MACHINES = 16;
pub const MAX_NAME = 32;
pub const MAX_PATH = 256;
pub const MAX_WORD = 64;

const EntryKind = enum {
    callback,
    raw_dsp2,
};

const RawMachine = extern struct {
    audio: Fy.Value,
    ui: Fy.Value,
    state_size: u32,
    params_size: u32,
    in_notes: u8,
    out_notes: u8,
    in_audio: u8,
    out_audio: u8,
    _pad: [4]u8,
};

pub const Entry = struct {
    kind: EntryKind = .callback,
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    path: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: u16 = 0,
    audio_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    audio_word_len: u8 = 0,
    ui_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    ui_word_len: u8 = 0,
    raw_prepare_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    raw_prepare_word_len: u8 = 0,
    raw_note_on_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    raw_note_on_word_len: u8 = 0,
    raw_note_off_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    raw_note_off_word_len: u8 = 0,
    raw_manifest_path: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    raw_manifest_path_len: u16 = 0,
    raw_mode: fy_raw_machine_mod.Mode = .voice_sample,
    raw_state_size: usize = 0,
    panel_w: f32 = 0,
    params_size: usize = 0,
    in_notes: bool = false,
    out_notes: bool = false,
    in_audio: bool = false,
    out_audio: bool = false,
    host: ?*FyHost = null, // heap-allocated, owned by this entry
    fy_machine: ?FyMachine = null, // references host
    raw_spec: ?fy_raw_machine_mod.Spec = null,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn machineInterface(self: *Entry) machine.Machine {
        return self.fy_machine.?.machineInterface();
    }

    pub fn pathSlice(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn audioWordSlice(self: *const Entry) []const u8 {
        return self.audio_word[0..self.audio_word_len];
    }

    pub fn uiWordSlice(self: *const Entry) []const u8 {
        return self.ui_word[0..self.ui_word_len];
    }

    fn rawPrepareWordSlice(self: *const Entry) ?[]const u8 {
        return if (self.raw_prepare_word_len == 0) null else self.raw_prepare_word[0..self.raw_prepare_word_len];
    }

    fn rawNoteOnWordSlice(self: *const Entry) ?[]const u8 {
        return if (self.raw_note_on_word_len == 0) null else self.raw_note_on_word[0..self.raw_note_on_word_len];
    }

    fn rawNoteOffWordSlice(self: *const Entry) ?[]const u8 {
        return if (self.raw_note_off_word_len == 0) null else self.raw_note_off_word[0..self.raw_note_off_word_len];
    }

    fn rawManifestPathSlice(self: *const Entry) ?[]const u8 {
        return if (self.raw_manifest_path_len == 0) null else self.raw_manifest_path[0..self.raw_manifest_path_len];
    }

    fn rawSpec(self: *const Entry) fy_raw_machine_mod.Spec {
        return .{
            .name = self.nameSlice(),
            .path = self.pathSlice(),
            .mode = self.raw_mode,
            .render_word = self.audioWordSlice(),
            .prepare_word = self.rawPrepareWordSlice(),
            .note_on_word = self.rawNoteOnWordSlice(),
            .note_off_word = self.rawNoteOffWordSlice(),
            .state_size = self.raw_state_size,
            .params_size = self.params_size,
            .panel_w = self.panel_w,
            .manifest_path = self.rawManifestPathSlice(),
        };
    }
};

pub const Registry = struct {
    entries: [MAX_MACHINES]Entry = undefined,
    count: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn instantiate(self: *Registry, idx: usize) !machine.Machine {
        if (idx >= self.count) return error.InvalidMachineIndex;
        const e = &self.entries[idx];
        if (e.kind == .raw_dsp2) {
            const raw = try fy_raw_machine_mod.FyRawMachine.create(self.alloc, e.rawSpec());
            return raw.machineInterface();
        }

        const host = try self.alloc.create(FyHost);
        errdefer self.alloc.destroy(host);
        host.* = FyHost.init(self.alloc);
        errdefer host.deinit();

        try host.registerSlabBuiltins();
        try host.compileFile(e.pathSlice());

        const audio_cb = try host.createAudioCallback(e.audioWordSlice());
        const ui_cb = try host.createAudioCallback(e.uiWordSlice());
        const reset_cb = tryOptionalResetCallback(host, e.audioWordSlice());

        const inst = try self.alloc.create(FyMachine);
        errdefer self.alloc.destroy(inst);
        inst.* = FyMachine.init(host, e.nameSlice(), audio_cb, ui_cb, reset_cb, e.params_size);
        inst.panel_w = e.panel_w;
        return inst.machineInterface();
    }

    pub fn instantiateWithPolyphony(self: *Registry, idx: usize, voices: u8) !machine.Machine {
        if (voices <= 1) return self.instantiate(idx);
        if (idx >= self.count) return error.InvalidMachineIndex;

        const voice_count = @min(voices, poly_mod.MAX_VOICES);
        const e = &self.entries[idx];
        const poly = try self.alloc.create(poly_mod.PolyMachine);
        errdefer self.alloc.destroy(poly);
        poly.* = poly_mod.PolyMachine.init(e.nameSlice(), voice_count);
        poly.panel_w = e.panel_w;

        var made: usize = 0;
        errdefer {
            for (0..made) |vi| {
                if (poly.voices[vi].deinit) |deinit_fn| {
                    deinit_fn(poly.voices[vi].state, self.alloc);
                }
            }
        }

        while (made < voice_count) : (made += 1) {
            poly.voices[made] = try self.instantiate(idx);
        }
        return poly.machineInterface();
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries[0..self.count]) |*e| {
            if (e.host) |host| {
                host.deinit();
                self.alloc.destroy(host);
            }
        }
    }

    pub fn loadRawFixture(self: *Registry, fixture_name: []const u8) !void {
        if (self.count >= MAX_MACHINES) return error.RegistryFull;
        const spec = fy_raw_machine_mod.fixtureSpec(fixture_name) orelse return error.UnknownRawFixture;

        var e = Entry{
            .kind = .raw_dsp2,
            .raw_spec = spec,
            .panel_w = spec.panel_w,
            .params_size = spec.params_size,
            .in_notes = spec.mode == .voice_sample,
            .out_audio = true,
            .in_audio = spec.mode == .effect_sample or spec.mode == .effect_block,
            .raw_mode = spec.mode,
            .raw_state_size = spec.state_size,
        };
        try copyEntryString(e.name[0..], &e.name_len, spec.name);
        try copyEntryString16(e.path[0..], &e.path_len, spec.path);
        try copyEntryString(e.audio_word[0..], &e.audio_word_len, spec.render_word);
        if (spec.prepare_word) |word| try copyEntryString(e.raw_prepare_word[0..], &e.raw_prepare_word_len, word);
        if (spec.note_on_word) |word| try copyEntryString(e.raw_note_on_word[0..], &e.raw_note_on_word_len, word);
        if (spec.note_off_word) |word| try copyEntryString(e.raw_note_off_word[0..], &e.raw_note_off_word_len, word);
        if (spec.manifest_path) |path| try copyEntryString16(e.raw_manifest_path[0..], &e.raw_manifest_path_len, path);

        self.entries[self.count] = e;
        self.count += 1;
    }

    pub fn loadRawManifest(self: *Registry, manifest_path: []const u8) !void {
        if (self.count >= MAX_MACHINES) return error.RegistryFull;
        var e = Entry{
            .kind = .raw_dsp2,
            .out_audio = true,
        };
        try copyEntryString16(e.raw_manifest_path[0..], &e.raw_manifest_path_len, manifest_path);

        const data = try readFilePosix(self.alloc, manifest_path);
        defer self.alloc.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var parts = std.mem.splitScalar(u8, line, '|');
            const key = parts.next() orelse continue;
            if (std.mem.eql(u8, key, "control") or
                std.mem.eql(u8, key, "derive") or
                std.mem.eql(u8, key, "const-f64") or
                std.mem.eql(u8, key, "strip")) continue;
            const value = parts.next() orelse return error.InvalidRawManifest;

            if (std.mem.eql(u8, key, "name")) {
                try copyEntryString(e.name[0..], &e.name_len, value);
            } else if (std.mem.eql(u8, key, "path")) {
                try copyEntryString16(e.path[0..], &e.path_len, value);
            } else if (std.mem.eql(u8, key, "mode")) {
                e.raw_mode = parseRawMode(value) orelse return error.InvalidRawManifest;
            } else if (std.mem.eql(u8, key, "render")) {
                try copyEntryString(e.audio_word[0..], &e.audio_word_len, value);
            } else if (std.mem.eql(u8, key, "prepare")) {
                try copyEntryString(e.raw_prepare_word[0..], &e.raw_prepare_word_len, value);
            } else if (std.mem.eql(u8, key, "note-on")) {
                try copyEntryString(e.raw_note_on_word[0..], &e.raw_note_on_word_len, value);
            } else if (std.mem.eql(u8, key, "note-off")) {
                try copyEntryString(e.raw_note_off_word[0..], &e.raw_note_off_word_len, value);
            } else if (std.mem.eql(u8, key, "state-size")) {
                e.raw_state_size = try std.fmt.parseInt(usize, value, 10);
            } else if (std.mem.eql(u8, key, "params-size")) {
                e.params_size = try std.fmt.parseInt(usize, value, 10);
            } else if (std.mem.eql(u8, key, "panel-w")) {
                e.panel_w = try std.fmt.parseFloat(f32, value);
            } else {
                return error.InvalidRawManifest;
            }
        }

        if (e.name_len == 0 or e.path_len == 0 or e.audio_word_len == 0 or e.raw_state_size == 0) return error.InvalidRawManifest;
        e.in_notes = e.raw_mode == .voice_sample;
        e.in_audio = e.raw_mode == .effect_sample or e.raw_mode == .effect_block;

        self.entries[self.count] = e;
        self.count += 1;
    }

    /// Load a fy machine file into its own Fy instance and register it.
    pub fn load(
        self: *Registry,
        display_name: []const u8,
        path: []const u8,
        audio_word: []const u8,
        ui_word: []const u8,
        panel_w: f32,
    ) !void {
        if (self.count >= MAX_MACHINES) return error.RegistryFull;

        const host = try self.alloc.create(FyHost);
        errdefer self.alloc.destroy(host);
        host.* = FyHost.init(self.alloc);
        errdefer host.deinit();

        try host.registerSlabBuiltins();
        try host.compileFile(path);

        const audio_cb = try host.createAudioCallback(audio_word);
        const ui_cb = try host.createAudioCallback(ui_word);
        const reset_cb = tryOptionalResetCallback(host, audio_word);
        const manifest_val = try host.callWord("manifest");
        const raw_ptr: usize = @intCast(@as(u64, @bitCast(manifest_val)) >> 2);
        const raw: *const RawMachine = @ptrFromInt(raw_ptr);
        const params_size: usize = @intCast(raw.params_size >> 2);

        var e = Entry{
            .kind = .callback,
            .host = host,
            .fy_machine = FyMachine.init(host, display_name, audio_cb, ui_cb, reset_cb, 0),
            .panel_w = panel_w,
            .params_size = params_size,
            .in_notes = raw.in_notes != 0,
            .out_notes = raw.out_notes != 0,
            .in_audio = raw.in_audio != 0,
            .out_audio = raw.out_audio != 0,
        };
        e.fy_machine.?.panel_w = panel_w;
        const n = @min(display_name.len, MAX_NAME);
        @memcpy(e.name[0..n], display_name[0..n]);
        e.name_len = @intCast(n);
        const path_n = @min(path.len, MAX_PATH);
        @memcpy(e.path[0..path_n], path[0..path_n]);
        e.path_len = @intCast(path_n);
        const audio_n = @min(audio_word.len, MAX_WORD);
        @memcpy(e.audio_word[0..audio_n], audio_word[0..audio_n]);
        e.audio_word_len = @intCast(audio_n);
        const ui_n = @min(ui_word.len, MAX_WORD);
        @memcpy(e.ui_word[0..ui_n], ui_word[0..ui_n]);
        e.ui_word_len = @intCast(ui_n);

        self.entries[self.count] = e;
        self.count += 1;
    }
};

fn copyEntryString(dest: []u8, len: *u8, src: []const u8) !void {
    if (src.len > dest.len) return error.RawManifestStringTooLong;
    @memset(dest, 0);
    @memcpy(dest[0..src.len], src);
    len.* = @intCast(src.len);
}

fn copyEntryString16(dest: []u8, len: *u16, src: []const u8) !void {
    if (src.len > dest.len) return error.RawManifestStringTooLong;
    @memset(dest, 0);
    @memcpy(dest[0..src.len], src);
    len.* = @intCast(src.len);
}

fn parseRawMode(raw: []const u8) ?fy_raw_machine_mod.Mode {
    if (std.mem.eql(u8, raw, "voice-sample")) return .voice_sample;
    if (std.mem.eql(u8, raw, "effect-sample")) return .effect_sample;
    if (std.mem.eql(u8, raw, "effect-block")) return .effect_block;
    return null;
}

fn readFilePosix(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const fd = open(z, O_RDONLY);
    if (fd < 0) return error.FileOpenFailed;
    defer _ = close(fd);
    var st: std.c.Stat = undefined;
    if (fstat(fd, &st) != 0) return error.StatFailed;
    const size: usize = @intCast(st.size);
    if (size > 64 * 1024) return error.FileTooLarge;
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    var done: usize = 0;
    while (done < size) {
        const n = try std.posix.read(@intCast(fd), buf[done..]);
        if (n == 0) break;
        done += n;
    }
    if (done != size) return error.ReadFailed;
    return buf;
}

test "raw manifest loads MS-20 machine spec" {
    var reg = Registry.init(std.testing.allocator);
    try reg.loadRawManifest("machines/raw_ms20/raw-ms20.manifest");
    try std.testing.expectEqual(@as(usize, 1), reg.count);
    const e = &reg.entries[0];
    try std.testing.expectEqualStrings("raw-ms20", e.nameSlice());
    try std.testing.expectEqualStrings("kernels/06-voices/ms20_voice_probe.fy", e.pathSlice());
    try std.testing.expectEqualStrings("k-ms20-voice-sample", e.audioWordSlice());
    try std.testing.expectEqualStrings("ms20-voice-prepare", e.rawPrepareWordSlice().?);
    try std.testing.expect(e.in_notes);
    try std.testing.expect(!e.in_audio);
    try std.testing.expectEqual(@as(usize, 144), e.raw_state_size);
    try std.testing.expectEqual(@as(usize, 360), e.params_size);
}

fn tryOptionalResetCallback(host: *FyHost, audio_word: []const u8) ?*const fn () callconv(.c) void {
    const reset_word =
        if (std.mem.eql(u8, audio_word, "mono1-audio"))
            "mono1-reset"
        else if (std.mem.eql(u8, audio_word, "chorus1-audio"))
            "chorus1-reset"
        else if (std.mem.eql(u8, audio_word, "comp1-audio"))
            "comp1-reset"
        else if (std.mem.eql(u8, audio_word, "fm1-audio"))
            "fm1-reset"
        else if (std.mem.eql(u8, audio_word, "delay1-audio"))
            "delay1-reset"
        else if (std.mem.eql(u8, audio_word, "verb1-audio"))
            "verb1-reset"
        else
            return null;
    return host.createAudioCallback(reset_word) catch null;
}
