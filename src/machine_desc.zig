//! Machine descriptor walker.
//!
//! A machine .fy file defines a `manifest` word (vocabulary in
//! machines/lib/manifest.fy) that builds a MachineDesc graph on the fy heap.
//! This module calls `manifest` on a compiled host and copies the graph into
//! a flat, bounded `Desc` — the single Zig-side source of truth that replaces
//! the old pipe-delimited .manifest text files.
//!
//! Every descriptor struct field is a fy `ptr` slot, so the raw mirrors are
//! flat arrays of tagged i64 values: ints and pointers untag with >>2;
//! "float" slots dual-decode (float tag 0b10 → mask, else int >>2).

const std = @import("std");
const Fy = @import("fy").Fy;
const FyHost = @import("fy_host.zig").FyHost;
const machine = @import("machine.zig");

pub const MAX_NAME = 64;
pub const MAX_WORD = 64;
pub const MAX_TEXT = 24;
pub const MAX_CONTROLS = 128;
pub const MAX_OPTS = 8;
pub const MAX_CONSTS = 16;
pub const MAX_STRIPS = 16;
pub const MAX_DISPLAYS = 8;
pub const MAX_ROWS = 8;
pub const MAX_PAGES = 8;
pub const MAX_ROW_CELLS = 16;
pub const MAX_CELL_ITEMS = 6;
pub const MAX_NOTE_LABELS = 32;
pub const MAX_BUFFERS = 8;
pub const MAX_ASSETS = 4;
pub const MAX_PATH = 128;

pub const Mode = enum {
    voice_sample,
    effect_sample,
    effect_block,
};

pub const ParamCurve = enum {
    linear,
    exp, // log taper: frequencies, times (min > 0)
    pow, // squared audio taper: levels, sends, 0-based ranges
};

pub const ParamKind = enum {
    direct_f64,
    switch_sel,
};

pub const Control = struct {
    module: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    module_len: usize = 0,
    label: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    label_len: usize = 0,
    id: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    id_len: usize = 0,
    kind: ParamKind = .direct_f64,
    offset: usize = 0,
    min: f64 = 0,
    max: f64 = 1,
    default: f64 = 0,
    curve: ParamCurve = .linear,
    // switch_sel only: discrete options. The control stores the selected
    // index; sync writes option_values[index] to the param offset.
    option_count: usize = 0,
    option_values: [MAX_OPTS]f64 = [_]f64{0} ** MAX_OPTS,
    option_labels: [MAX_OPTS][MAX_TEXT:0]u8 = [_][MAX_TEXT:0]u8{[_:0]u8{0} ** MAX_TEXT} ** MAX_OPTS,

    pub fn optionLabelZ(self: *const Control, i: usize) [*:0]const u8 {
        return @ptrCast(&self.option_labels[i][0]);
    }

    pub fn moduleSlice(self: *const Control) []const u8 {
        return self.module[0..self.module_len];
    }

    pub fn moduleZ(self: *const Control) [*:0]const u8 {
        return @ptrCast(&self.module[0]);
    }

    pub fn labelZ(self: *const Control) [*:0]const u8 {
        return @ptrCast(&self.label[0]);
    }

    pub fn idSlice(self: *const Control) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const ConstF64 = struct {
    offset: usize = 0,
    value: f64 = 0,
};

/// A host-allocated audio-rate f64 buffer the machine requests by length in
/// seconds. The host allocates per channel and writes the base pointer +
/// element count into that channel's state at the two introspected offsets.
pub const BufferReq = struct {
    name: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    name_len: usize = 0,
    ptr_offset: usize = 0,
    len_offset: usize = 0,
    seconds: f64 = 0,

    pub fn nameSlice(self: *const BufferReq) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// A read-only audio asset loaded from disk at create. The host writes the
/// base pointer, sample count, and native sample rate into PARAMS at the
/// three introspected offsets (shared across voices).
pub const AssetReq = struct {
    name: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    name_len: usize = 0,
    ptr_offset: usize = 0,
    len_offset: usize = 0,
    sr_offset: usize = 0,
    file: [MAX_PATH:0]u8 = [_:0]u8{0} ** MAX_PATH,
    file_len: usize = 0,

    pub fn fileSlice(self: *const AssetReq) []const u8 {
        return self.file[0..self.file_len];
    }

    pub fn nameSlice(self: *const AssetReq) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Strip = struct {
    module: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    module_len: usize = 0,
    cols: usize = 1,

    pub fn moduleSlice(self: *const Strip) []const u8 {
        return self.module[0..self.module_len];
    }

    pub fn moduleZ(self: *const Strip) [*:0]const u8 {
        return @ptrCast(&self.module[0]);
    }
};

pub const DisplayKind = enum { adsr, waveform };

pub const Display = struct {
    name: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    name_len: usize = 0,
    kind: DisplayKind = .adsr,
    source: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    source_len: usize = 0,

    pub fn nameSlice(self: *const Display) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn sourceSlice(self: *const Display) []const u8 {
        return self.source[0..self.source_len];
    }
};

pub const LayoutItem = struct { is_display: bool = false, index: usize = 0, weight: f32 = 1 };
pub const LayoutCell = struct {
    items: [MAX_CELL_ITEMS]LayoutItem = undefined,
    item_count: usize = 0,
    weight: f32 = 1,
};
pub const LayoutRow = struct {
    cells: [MAX_ROW_CELLS]LayoutCell = undefined,
    cell_count: usize = 0,
    weight: f32 = 1,
};

/// One tab of a paged panel: a name and its own layout-row tree. Built only
/// when the manifest declares `page`s; otherwise the panel uses `Desc.rows`.
pub const Page = struct {
    name: [MAX_TEXT:0]u8 = [_:0]u8{0} ** MAX_TEXT,
    name_len: usize = 0,
    rows: [MAX_ROWS]LayoutRow = undefined,
    row_count: usize = 0,

    pub fn nameSlice(self: *const Page) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn nameZ(self: *const Page) [*:0]const u8 {
        return @ptrCast(&self.name[0]);
    }
};

pub const Desc = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: usize = 0,
    mode: Mode = .voice_sample,
    render_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    render_word_len: usize = 0,
    prepare_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    prepare_word_len: usize = 0,
    note_on_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    note_on_word_len: usize = 0,
    note_off_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    note_off_word_len: usize = 0,
    block_prepare_word: [MAX_WORD]u8 = [_]u8{0} ** MAX_WORD,
    block_prepare_word_len: usize = 0,
    state_size: usize = 0,
    params_size: usize = 0,
    panel_w: f32 = 128,
    controls: [MAX_CONTROLS]Control = undefined,
    control_count: usize = 0,
    consts: [MAX_CONSTS]ConstF64 = undefined,
    const_count: usize = 0,
    strips: [MAX_STRIPS]Strip = undefined,
    strip_count: usize = 0,
    displays: [MAX_DISPLAYS]Display = undefined,
    display_count: usize = 0,
    rows: [MAX_ROWS]LayoutRow = undefined,
    row_count: usize = 0,
    // Tabbed panel: when non-empty, each page is a named tab carrying its own
    // row tree, and the top-level `rows` are unused.
    pages: [MAX_PAGES]Page = undefined,
    page_count: usize = 0,
    // note-on receives raw MIDI pitch instead of Hz (drum machines).
    note_pitch: bool = false,
    note_labels: [MAX_NOTE_LABELS]machine.NoteLabel = undefined,
    note_label_count: usize = 0,
    buffers: [MAX_BUFFERS]BufferReq = undefined,
    buffer_count: usize = 0,
    // State offset where the host writes the channel index (0.0 L / 1.0 R)
    // after buffer injection and reset; null = machine doesn't care.
    channel_cell: ?usize = null,
    // State offset where the host writes a pointer to the per-block
    // stereo-linked detector buffer (max abs of both inputs per sample).
    detector_cell: ?usize = null,
    // Voice count for polyphonic voice-sample machines; 1 = mono.
    voices: usize = 1,
    assets: [MAX_ASSETS]AssetReq = undefined,
    asset_count: usize = 0,

    pub fn noteLabels(self: *const Desc) []const machine.NoteLabel {
        return self.note_labels[0..self.note_label_count];
    }

    pub fn nameSlice(self: *const Desc) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn renderWord(self: *const Desc) []const u8 {
        return self.render_word[0..self.render_word_len];
    }

    pub fn prepareWord(self: *const Desc) ?[]const u8 {
        return if (self.prepare_word_len == 0) null else self.prepare_word[0..self.prepare_word_len];
    }

    pub fn noteOnWord(self: *const Desc) ?[]const u8 {
        return if (self.note_on_word_len == 0) null else self.note_on_word[0..self.note_on_word_len];
    }

    pub fn noteOffWord(self: *const Desc) ?[]const u8 {
        return if (self.note_off_word_len == 0) null else self.note_off_word[0..self.note_off_word_len];
    }

    pub fn blockPrepareWord(self: *const Desc) ?[]const u8 {
        return if (self.block_prepare_word_len == 0) null else self.block_prepare_word[0..self.block_prepare_word_len];
    }

    pub fn stripIndexByModule(self: *const Desc, name: []const u8) ?usize {
        for (self.strips[0..self.strip_count], 0..) |*s, i| {
            if (std.mem.eql(u8, s.moduleSlice(), name)) return i;
        }
        return null;
    }

    pub fn displayIndexByName(self: *const Desc, name: []const u8) ?usize {
        for (self.displays[0..self.display_count], 0..) |*d, i| {
            if (std.mem.eql(u8, d.nameSlice(), name)) return i;
        }
        return null;
    }
};

// ── fy-heap mirrors (field order matches machines/lib/manifest.fy) ────

const MachineDescRaw = extern struct {
    name: Fy.Value,
    mode: Fy.Value,
    render: Fy.Value,
    prepare: Fy.Value,
    note_on: Fy.Value,
    note_off: Fy.Value,
    block_prepare: Fy.Value,
    state_size: Fy.Value,
    params_size: Fy.Value,
    panel_w: Fy.Value,
    controls: Fy.Value,
    strips: Fy.Value,
    displays: Fy.Value,
    rows: Fy.Value,
    consts: Fy.Value,
    note_pitch: Fy.Value,
    note_labels: Fy.Value,
    buffers: Fy.Value,
    channel_cell: Fy.Value,
    detector_cell: Fy.Value,
    voices: Fy.Value,
    assets: Fy.Value,
    pages: Fy.Value,
};

const PageRaw = extern struct { next: Fy.Value, name: Fy.Value, rows: Fy.Value };

const ControlRaw = extern struct {
    next: Fy.Value,
    module: Fy.Value,
    label: Fy.Value,
    id: Fy.Value,
    kind: Fy.Value,
    offset: Fy.Value,
    min: Fy.Value,
    max: Fy.Value,
    default: Fy.Value,
    curve: Fy.Value,
    options: Fy.Value,
};

const OptionRaw = extern struct { next: Fy.Value, label: Fy.Value, value: Fy.Value };
const StripRaw = extern struct { next: Fy.Value, module: Fy.Value, cols: Fy.Value };
const DisplayRaw = extern struct { next: Fy.Value, name: Fy.Value, kind: Fy.Value, sources: Fy.Value };
const RowRaw = extern struct { next: Fy.Value, weight: Fy.Value, cells: Fy.Value };
const CellRaw = extern struct { next: Fy.Value, weight: Fy.Value, items: Fy.Value };
const ItemRaw = extern struct { next: Fy.Value, name: Fy.Value, weight: Fy.Value };
const ConstRaw = extern struct { next: Fy.Value, offset: Fy.Value, value: Fy.Value };
const NoteLabelRaw = extern struct { next: Fy.Value, pitch: Fy.Value, label: Fy.Value };
const BufferRaw = extern struct { next: Fy.Value, name: Fy.Value, ptr_offset: Fy.Value, len_offset: Fy.Value, seconds: Fy.Value };
const AssetRaw = extern struct { next: Fy.Value, name: Fy.Value, ptr_offset: Fy.Value, len_offset: Fy.Value, sr_offset: Fy.Value, file: Fy.Value };

// ── tagged-value decode ───────────────────────────────────────────────

fn asInt(v: Fy.Value) i64 {
    return v >> 2;
}

// Dual decode: number slots may hold a float (tag 0b10) or an int literal.
fn asF64(v: Fy.Value) f64 {
    if ((v & 3) == 2) return @bitCast(@as(u64, @bitCast(v)) & ~@as(u64, 3));
    return @floatFromInt(v >> 2);
}

fn rawPtr(comptime T: type, v: Fy.Value) ?*const T {
    const p: usize = @intCast(@as(u64, @bitCast(v)) >> 2);
    if (p == 0) return null;
    return @ptrFromInt(p);
}

fn cstrSlice(v: Fy.Value) []const u8 {
    const p: usize = @intCast(@as(u64, @bitCast(v)) >> 2);
    if (p == 0) return "";
    return std.mem.span(@as([*:0]const u8, @ptrFromInt(p)));
}

fn copyBuf(dest: []u8, src: []const u8) !usize {
    if (src.len > dest.len) return error.MachineDescStringTooLong;
    @memcpy(dest[0..src.len], src);
    return src.len;
}

fn copyText(dest: *[MAX_TEXT:0]u8, src: []const u8) !usize {
    if (src.len >= MAX_TEXT) return error.MachineDescStringTooLong;
    @memcpy(dest[0..src.len], src);
    dest[src.len] = 0;
    return src.len;
}

// ── walker ────────────────────────────────────────────────────────────

/// Call `manifest` on an already-compiled host and copy the descriptor
/// graph out of the fy heap into a flat Desc.
pub fn read(host: *FyHost) !Desc {
    const val = try host.callWord("manifest");
    const md = rawPtr(MachineDescRaw, val) orelse return error.InvalidMachineDesc;

    var d = Desc{};
    d.name_len = try copyBuf(d.name[0..], cstrSlice(md.name));
    if (d.name_len == 0) return error.InvalidMachineDesc;
    d.mode = switch (asInt(md.mode)) {
        0 => .voice_sample,
        1 => .effect_sample,
        2 => .effect_block,
        else => return error.InvalidMachineDesc,
    };
    d.render_word_len = try copyBuf(d.render_word[0..], cstrSlice(md.render));
    if (d.render_word_len == 0) return error.InvalidMachineDesc;
    d.prepare_word_len = try copyBuf(d.prepare_word[0..], cstrSlice(md.prepare));
    d.note_on_word_len = try copyBuf(d.note_on_word[0..], cstrSlice(md.note_on));
    d.note_off_word_len = try copyBuf(d.note_off_word[0..], cstrSlice(md.note_off));
    d.block_prepare_word_len = try copyBuf(d.block_prepare_word[0..], cstrSlice(md.block_prepare));
    d.state_size = @intCast(asInt(md.state_size));
    d.params_size = @intCast(asInt(md.params_size));
    if (d.state_size == 0 or d.params_size == 0) return error.InvalidMachineDesc;
    const panel_w: f32 = @floatCast(asF64(md.panel_w));
    if (panel_w > 0) d.panel_w = panel_w;

    var ctl_it = rawPtr(ControlRaw, md.controls);
    while (ctl_it) |ctl| : (ctl_it = rawPtr(ControlRaw, ctl.next)) {
        if (d.control_count >= MAX_CONTROLS) return error.TooManyControls;
        const out = &d.controls[d.control_count];
        out.* = .{};
        out.module_len = try copyText(&out.module, cstrSlice(ctl.module));
        out.label_len = try copyText(&out.label, cstrSlice(ctl.label));
        out.id_len = try copyText(&out.id, cstrSlice(ctl.id));
        out.kind = switch (asInt(ctl.kind)) {
            0 => .direct_f64,
            1 => .switch_sel,
            else => return error.InvalidMachineDesc,
        };
        out.offset = @intCast(asInt(ctl.offset));
        out.min = asF64(ctl.min);
        out.max = asF64(ctl.max);
        out.default = asF64(ctl.default);
        out.curve = switch (asInt(ctl.curve)) {
            0 => .linear,
            1 => .exp,
            2 => .pow,
            else => return error.InvalidMachineDesc,
        };
        var opt_it = rawPtr(OptionRaw, ctl.options);
        while (opt_it) |opt| : (opt_it = rawPtr(OptionRaw, opt.next)) {
            if (out.option_count >= MAX_OPTS) return error.TooManyOptions;
            _ = try copyText(&out.option_labels[out.option_count], cstrSlice(opt.label));
            out.option_values[out.option_count] = asF64(opt.value);
            out.option_count += 1;
        }
        if (out.kind == .switch_sel and out.option_count == 0) return error.InvalidMachineDesc;
        d.control_count += 1;
    }

    var const_it = rawPtr(ConstRaw, md.consts);
    while (const_it) |cn| : (const_it = rawPtr(ConstRaw, cn.next)) {
        if (d.const_count >= MAX_CONSTS) return error.TooManyConsts;
        d.consts[d.const_count] = .{ .offset = @intCast(asInt(cn.offset)), .value = asF64(cn.value) };
        d.const_count += 1;
    }

    var strip_it = rawPtr(StripRaw, md.strips);
    while (strip_it) |s| : (strip_it = rawPtr(StripRaw, s.next)) {
        if (d.strip_count >= MAX_STRIPS) return error.TooManyStrips;
        const out = &d.strips[d.strip_count];
        out.* = .{};
        out.module_len = try copyText(&out.module, cstrSlice(s.module));
        out.cols = @intCast(@max(1, asInt(s.cols)));
        d.strip_count += 1;
    }

    var disp_it = rawPtr(DisplayRaw, md.displays);
    while (disp_it) |disp| : (disp_it = rawPtr(DisplayRaw, disp.next)) {
        if (d.display_count >= MAX_DISPLAYS) return error.TooManyDisplays;
        const out = &d.displays[d.display_count];
        out.* = .{};
        out.name_len = try copyText(&out.name, cstrSlice(disp.name));
        out.kind = switch (asInt(disp.kind)) {
            0 => .adsr,
            1 => .waveform,
            else => return error.InvalidMachineDesc,
        };
        out.source_len = try copyText(&out.source, cstrSlice(disp.sources));
        d.display_count += 1;
    }

    d.note_pitch = asInt(md.note_pitch) != 0;
    var nl_it = rawPtr(NoteLabelRaw, md.note_labels);
    while (nl_it) |nl| : (nl_it = rawPtr(NoteLabelRaw, nl.next)) {
        if (d.note_label_count >= MAX_NOTE_LABELS) return error.TooManyNoteLabels;
        const out = &d.note_labels[d.note_label_count];
        out.* = .{};
        out.pitch = @intCast(std.math.clamp(asInt(nl.pitch), 0, 127));
        const text = cstrSlice(nl.label);
        if (text.len > machine.NOTE_LABEL_TEXT) return error.MachineDescStringTooLong;
        @memcpy(out.label[0..text.len], text);
        out.label_len = @intCast(text.len);
        d.note_label_count += 1;
    }

    var buf_it = rawPtr(BufferRaw, md.buffers);
    while (buf_it) |b| : (buf_it = rawPtr(BufferRaw, b.next)) {
        if (d.buffer_count >= MAX_BUFFERS) return error.TooManyBuffers;
        const out = &d.buffers[d.buffer_count];
        out.* = .{};
        out.name_len = try copyText(&out.name, cstrSlice(b.name));
        out.ptr_offset = @intCast(asInt(b.ptr_offset));
        out.len_offset = @intCast(asInt(b.len_offset));
        out.seconds = asF64(b.seconds);
        if (out.seconds <= 0 or out.ptr_offset == out.len_offset) return error.InvalidMachineDesc;
        if (out.ptr_offset + 8 > d.state_size or out.len_offset + 8 > d.state_size) return error.InvalidMachineDesc;
        d.buffer_count += 1;
    }

    const chan_cell = asInt(md.channel_cell);
    if (chan_cell > 0) {
        const off: usize = @intCast(chan_cell - 1); // stored +1 so 0 = none
        if (off + 8 > d.state_size) return error.InvalidMachineDesc;
        d.channel_cell = off;
    }
    const det_cell = asInt(md.detector_cell);
    if (det_cell > 0) {
        const off: usize = @intCast(det_cell - 1);
        if (off + 8 > d.state_size) return error.InvalidMachineDesc;
        d.detector_cell = off;
    }
    const voices = asInt(md.voices);
    if (voices > 0) d.voices = @intCast(voices);
    if (d.voices > 1 and d.mode != .voice_sample) return error.InvalidMachineDesc;

    var asset_it = rawPtr(AssetRaw, md.assets);
    while (asset_it) |as| : (asset_it = rawPtr(AssetRaw, as.next)) {
        if (d.asset_count >= MAX_ASSETS) return error.TooManyAssets;
        const out = &d.assets[d.asset_count];
        out.* = .{};
        out.name_len = try copyText(&out.name, cstrSlice(as.name));
        out.ptr_offset = @intCast(asInt(as.ptr_offset));
        out.len_offset = @intCast(asInt(as.len_offset));
        out.sr_offset = @intCast(asInt(as.sr_offset));
        const file = cstrSlice(as.file);
        if (file.len == 0 or file.len >= MAX_PATH) return error.InvalidMachineDesc;
        @memcpy(out.file[0..file.len], file);
        out.file_len = file.len;
        if (out.ptr_offset + 8 > d.params_size or out.len_offset + 8 > d.params_size or out.sr_offset + 8 > d.params_size) {
            return error.InvalidMachineDesc;
        }
        d.asset_count += 1;
    }

    d.row_count = try parseRows(&d, rawPtr(RowRaw, md.rows), &d.rows);

    // Pages (tabbed panel): each carries its own row tree. Mixing top-level
    // rows with pages is rejected so the renderer has one source of truth.
    var page_it = rawPtr(PageRaw, md.pages);
    while (page_it) |pg| : (page_it = rawPtr(PageRaw, pg.next)) {
        if (d.page_count >= MAX_PAGES) return error.TooManyPages;
        const out = &d.pages[d.page_count];
        out.* = .{};
        out.name_len = try copyText(&out.name, cstrSlice(pg.name));
        if (out.name_len == 0) return error.InvalidMachineDesc;
        out.row_count = try parseRows(&d, rawPtr(RowRaw, pg.rows), &out.rows);
        d.page_count += 1;
    }
    if (d.page_count > 0 and d.row_count > 0) return error.InvalidMachineDesc;

    return d;
}

/// Walk a RowDesc chain into `out`, resolving each item to a strip or display
/// index. Returns the number of rows written. Shared by the top-level panel
/// and every page.
fn parseRows(d: *const Desc, head: ?*const RowRaw, out: []LayoutRow) !usize {
    var count: usize = 0;
    var row_it = head;
    while (row_it) |row| : (row_it = rawPtr(RowRaw, row.next)) {
        if (count >= out.len) return error.TooManyRows;
        const out_row = &out[count];
        out_row.* = .{};
        out_row.weight = @floatCast(asF64(row.weight));
        var cell_it = rawPtr(CellRaw, row.cells);
        while (cell_it) |cell| : (cell_it = rawPtr(CellRaw, cell.next)) {
            if (out_row.cell_count >= MAX_ROW_CELLS) return error.TooManyCells;
            const out_cell = &out_row.cells[out_row.cell_count];
            out_cell.* = .{};
            out_cell.weight = @floatCast(asF64(cell.weight));
            var item_it = rawPtr(ItemRaw, cell.items);
            while (item_it) |item| : (item_it = rawPtr(ItemRaw, item.next)) {
                if (out_cell.item_count >= MAX_CELL_ITEMS) return error.TooManyItems;
                const name = cstrSlice(item.name);
                var out_item = LayoutItem{ .weight = @floatCast(asF64(item.weight)) };
                if (d.stripIndexByModule(name)) |si| {
                    out_item.index = si;
                } else if (d.displayIndexByName(name)) |di| {
                    out_item.is_display = true;
                    out_item.index = di;
                } else return error.UnknownLayoutItem;
                out_cell.items[out_cell.item_count] = out_item;
                out_cell.item_count += 1;
            }
            out_row.cell_count += 1;
        }
        count += 1;
    }
    return count;
}

const testing = std.testing;

test "descriptor walker reads the FM-86 manifest (7 tabs, 63 controls)" {
    var host = FyHost.init(testing.allocator);
    defer host.deinit();
    try host.compileFile("machines/fm86/fm86.fy");
    const d = try read(&host);

    try testing.expectEqualStrings("FM-86", d.nameSlice());
    try testing.expectEqual(Mode.voice_sample, d.mode);
    try testing.expectEqualStrings("k-fm86-voice-sample", d.renderWord());
    try testing.expectEqualStrings("fm86-prepare", d.prepareWord().?);
    try testing.expectEqualStrings("fm86-block-prepare", d.blockPrepareWord().?);
    // 3 global + 6 operators * 10 = 63 controls; 7 tabs.
    try testing.expectEqual(@as(usize, 63), d.control_count);
    try testing.expectEqual(@as(usize, 7), d.page_count);
    try testing.expectEqual(@as(usize, 0), d.row_count);
    try testing.expectEqualStrings("GLOBAL", d.pages[0].nameSlice());
    try testing.expectEqualStrings("OP 6", d.pages[6].nameSlice());
    try testing.expectEqual(@as(usize, 6), d.const_count); // 6 rate-scale consts

    // The ALGO control's offset is the Fm86Params.algo field, which the host's
    // routing hook reads. It must be inside the params region.
    var found_algo = false;
    for (d.controls[0..d.control_count]) |*ctl| {
        if (std.mem.eql(u8, ctl.idSlice(), "algo")) {
            try testing.expect(ctl.offset + 8 <= d.params_size);
            found_algo = true;
        }
    }
    try testing.expect(found_algo);
}

test "descriptor walker reads a tabbed (paged) panel" {
    var host = FyHost.init(testing.allocator);
    defer host.deinit();
    try host.compileFile("machines/raw_fixtures/pages.fy");
    const d = try read(&host);

    try testing.expectEqualStrings("raw-pages", d.nameSlice());
    // Pages replace the top-level rows.
    try testing.expectEqual(@as(usize, 0), d.row_count);
    try testing.expectEqual(@as(usize, 2), d.page_count);
    try testing.expectEqualStrings("PAGE A", d.pages[0].nameSlice());
    try testing.expectEqualStrings("PAGE B", d.pages[1].nameSlice());
    // Each page carries its own one-row layout pointing at its strip.
    try testing.expectEqual(@as(usize, 1), d.pages[0].row_count);
    try testing.expectEqual(@as(usize, 1), d.pages[0].rows[0].cell_count);
    const item_a = d.pages[0].rows[0].cells[0].items[0];
    try testing.expect(!item_a.is_display);
    try testing.expectEqualStrings("AONE", d.strips[item_a.index].moduleSlice());
    const item_b = d.pages[1].rows[0].cells[0].items[0];
    try testing.expectEqualStrings("BTWO", d.strips[item_b.index].moduleSlice());
}

test "descriptor walker reads the drum2 note map" {
    var host = FyHost.init(testing.allocator);
    defer host.deinit();
    try host.compileFile("machines/drum2/drum2.fy");
    const d = try read(&host);

    try testing.expectEqualStrings("DS-404 Drums", d.nameSlice());
    try testing.expect(d.note_pitch);
    try testing.expectEqual(@as(usize, 6), d.note_label_count);
    try testing.expectEqual(@as(u8, 36), d.note_labels[0].pitch);
    try testing.expectEqualStrings("KICK", d.note_labels[0].labelSlice());
    try testing.expectEqual(@as(u8, 42), d.note_labels[3].pitch);
    try testing.expectEqualStrings("CH", d.note_labels[3].labelSlice());
    try testing.expectEqual(@as(u8, 46), d.note_labels[5].pitch);
    try testing.expectEqualStrings("OH", d.note_labels[5].labelSlice());
    try testing.expectEqual(@as(usize, 30), d.control_count);
    try testing.expectEqual(@as(usize, 6), d.strip_count);
    try testing.expectEqual(@as(usize, 2), d.const_count);
    try testing.expectEqual(@as(usize, 2), d.row_count);

    // Snare controls land past the kick params region (offset computed in
    // fy as KickParams.size + SnareParams.field).
    var found = false;
    for (d.controls[0..d.control_count]) |*ctl| {
        if (std.mem.eql(u8, ctl.idSlice(), "snare-tune")) {
            try testing.expectEqual(@as(usize, 88 + 0), ctl.offset);
            found = true;
        }
    }
    try testing.expect(found);
}

test "descriptor walker reads the MS-20 manifest from fy" {
    var host = FyHost.init(testing.allocator);
    defer host.deinit();
    try host.compileFile("machines/ms20/ms20.fy");
    const d = try read(&host);

    try testing.expectEqualStrings("SM-24 Mono", d.nameSlice());
    try testing.expectEqual(Mode.voice_sample, d.mode);
    try testing.expectEqualStrings("k-ms20-voice-sample", d.renderWord());
    try testing.expectEqualStrings("ms20-voice-prepare", d.prepareWord().?);
    try testing.expectEqualStrings("ms20-block-prepare", d.blockPrepareWord().?);
    try testing.expectEqual(@as(usize, 144), d.state_size);
    try testing.expectEqual(@as(usize, 360), d.params_size);
    try testing.expectEqual(@as(f32, 420.0), d.panel_w);
    try testing.expectEqual(@as(usize, 30), d.control_count);
    try testing.expectEqual(@as(usize, 10), d.strip_count);
    try testing.expectEqual(@as(usize, 1), d.display_count);
    try testing.expectEqual(@as(usize, 2), d.row_count);
    try testing.expectEqual(@as(usize, 7), d.rows[0].cell_count);
    try testing.expectEqual(@as(usize, 1), d.const_count);
    try testing.expectEqual(@as(usize, 64), d.consts[0].offset);
    try testing.expectApproxEqAbs(@as(f64, 0.0035), d.consts[0].value, 1e-12);

    // First control: VCO1 WAVE switch at the introspected vco1-wave offset.
    const c0 = &d.controls[0];
    try testing.expectEqualStrings("VCO1", c0.moduleSlice());
    try testing.expectEqual(ParamKind.switch_sel, c0.kind);
    try testing.expectEqual(@as(usize, 272), c0.offset);
    try testing.expectEqual(@as(usize, 3), c0.option_count);
    try testing.expectApproxEqAbs(@as(f64, 1.0), c0.option_values[1], 1e-12);

    // An exp knob: LPF CUT at the cutoff offset.
    var found = false;
    for (d.controls[0..d.control_count]) |*ctl| {
        if (std.mem.eql(u8, ctl.idSlice(), "cutoff")) {
            try testing.expectEqual(@as(usize, 32), ctl.offset);
            try testing.expectEqual(ParamCurve.exp, ctl.curve);
            try testing.expectApproxEqAbs(@as(f64, 180.0), ctl.default, 1e-12);
            found = true;
        }
    }
    try testing.expect(found);
}
