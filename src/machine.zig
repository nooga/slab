//! Machine interface + ABI-shaped structs that cross the Zig↔fy
//! boundary. `NoteEvent` and `MachineCtx` follow the layout in
//! docs/04-block-contract.md; fields we don't have infra for yet
//! (voice pool, block arena, services, multi-port routing) are
//! declared in the struct but stubbed with null / zero counts so the
//! byte layout stays stable for the future.

const std = @import("std");
const c = @import("c.zig");
const ui_core = @import("ui/core.zig");

// ── NoteEvent ────────────────────────────────────────────────────────

pub const NoteKind = enum(u8) {
    note_on = 0,
    note_off = 1,
    note_hold = 2,
    pressure = 3,
    slide = 4,
    glide = 5,
    cc = 6,
    program_change = 7,
    reset = 8,
};

pub const NoteEvent = extern struct {
    /// Offset in samples within the current block [0, block_size).
    sample_offset: u32,

    kind: NoteKind,
    channel: u8,
    _pad0: u16 = 0,

    /// Source-assigned id. Note-off matches note-on by (channel, note_id).
    note_id: i32,

    /// MIDI pitch as a float: 60.0 = middle C, fractional for microtones.
    pitch: f32,
    /// 0..1 normalized velocity.
    velocity: f32,

    // MPE expression — always present, neutral defaults for non-MPE sources.
    pressure: f32 = 0.5,
    slide: f32 = 0.0,
    glide: f32 = 0.0,

    /// Extra payload (CC value, program change, etc.).
    value: f32 = 0,
    /// CC number for kind=cc, else 0.
    param_index: u32 = 0,

    _reserved: [2]u32 = .{ 0, 0 },

    pub fn isOn(self: NoteEvent) bool {
        return self.kind == .note_on and self.velocity > 0;
    }
};

// ── MachineCtx ───────────────────────────────────────────────────────
//
// Host fills this once per machine per block. Pointers are block-
// local and invalid after render() returns.

pub const TransportState = enum(u32) {
    stopped = 0,
    playing = 1,
    recording = 2,
};

pub const MachineCtx = extern struct {
    // Block parameters.
    sample_rate: f64,
    block_size: u32,
    _pad_a: u32 = 0,
    block_start: u64,
    tempo_bpm: f64,
    ppq_position: f64,
    transport_state: TransportState,
    _pad0: u32 = 0,

    // Audio ports — channel-planar. audio_out[port][channel] → [*]f32.
    audio_in: ?[*]const [*]const f32 = null,
    audio_in_count: u32 = 0,
    _pad_b: u32 = 0,
    audio_out: ?[*]const [*]f32 = null,
    audio_out_count: u32 = 0,
    _pad1: u32 = 0,

    // Note ports. Events in note_in are sorted by sample_offset ascending.
    note_in: ?[*]const NoteEvent = null,
    note_in_count: u32 = 0,
    _pad_c: u32 = 0,
    note_out: ?[*]NoteEvent = null,
    note_out_cap: u32 = 0,
    note_out_count: ?*u32 = null,

    // CV (modulation) — unused in v1.
    cv_in: ?[*]const [*]const f32 = null,
    cv_in_count: u32 = 0,
    _pad_d: u32 = 0,
    cv_out: ?[*]const [*]f32 = null,
    cv_out_count: u32 = 0,
    _pad_e: u32 = 0,

    // Params — machine-specific for now; proper smoothing infra later.
    params_current: ?*anyopaque = null,
    params_per_sample: ?*anyopaque = null,

    // Persistent state slab (between blocks). Not used yet.
    persistent: ?[*]u8 = null,
    persistent_len: u32 = 0,
    _pad_f: u32 = 0,

    // Services that will arrive in later passes.
    voice_pool: ?*anyopaque = null,
    block_arena: ?*anyopaque = null,
    assets: ?*const anyopaque = null,
    assets_count: u32 = 0,
    _pad_g: u32 = 0,
    services: ?*anyopaque = null,

    // Meter position, filled by the host from the document's meter map
    // (docs/07 §meter-map). Carved from the reserved tail so existing fy
    // ctx offsets are unchanged. `beat_in_bar` is quarter-beats since the
    // current bar's downbeat; normalized bar phase is
    // `beat_in_bar / bar_len_beats`.
    bar: u32 = 0,
    _pad_h: u32 = 0,
    beat_in_bar: f64 = 0,
    bar_len_beats: f64 = 0,

    _reserved: [5]u64 = @splat(0),
};

// ── Machine vtable (host-facing) ─────────────────────────────────────

pub const RenderFn = *const fn (
    state: *anyopaque,
    ctx: *const MachineCtx,
    l: []f32,
    r: []f32,
) void;

/// Draw the machine's panel body into `rect` with the new UI core
/// (docs/06). Controls use ids scoped under the machine instance.
pub const DrawPanelFn = *const fn (
    state: *anyopaque,
    ui: *ui_core.Ui,
    rect: ui_core.Rect,
) void;

/// Called when the transport stops or the host otherwise wants the
/// machine to drop any sustained voices and reset to silence.
pub const ResetFn = *const fn (state: *anyopaque) void;
pub const DeinitFn = *const fn (state: *anyopaque, alloc: std.mem.Allocator) void;
pub const SyncParamsFn = *const fn (dst: *anyopaque, src: *anyopaque) void;
pub const PresetCountFn = *const fn (state: *anyopaque) u8;
pub const PresetNameFn = *const fn (state: *anyopaque, index: u8) [*:0]const u8;
pub const ApplyPresetFn = *const fn (state: *anyopaque, index: u8) void;
/// Save the machine's current control values as a new preset (the machine
/// picks the name). Returns the new preset's index, or null on failure.
pub const SavePresetFn = *const fn (state: *anyopaque) ?u8;
/// Save the current control values under a host-supplied name. The machine
/// sanitizes the name and overwrites any same-named preset. Returns the new
/// sorted index, or null on failure (empty/invalid name, IO error).
pub const SavePresetNamedFn = *const fn (state: *anyopaque, name: [*:0]const u8) ?u8;
/// Rename preset `index` to `new_name` on disk and rescan. Returns the
/// renamed preset's new sorted index, or null on failure.
pub const RenamePresetFn = *const fn (state: *anyopaque, index: u8, new_name: [*:0]const u8) ?u8;
/// Index of the last applied/saved preset, or -1 — drives the
/// "name -> preset" titlebar label.
pub const CurrentPresetFn = *const fn (state: *anyopaque) i32;
/// Append the machine's current settings as a JSON object `{"id":value,…}`
/// (real values, same convention as presets) for embedding in a project.
pub const WriteParamsJsonFn = *const fn (state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void;
/// Apply one control `id` → `value` pair when restoring a machine's settings
/// from a project. Unknown ids are ignored.
pub const SetParamFn = *const fn (state: *anyopaque, id: []const u8, value: f64) void;
/// The files a machine has loaded (a sampler's keymap), as a JSON object
/// {"asset-name": "path", ...}; write nothing when there are none.
pub const WriteAssetsJsonFn = *const fn (state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void;
/// Load one named asset from `path` when restoring a project. False on a
/// missing or bad file; the machine keeps what it had.
pub const LoadAssetFn = *const fn (state: *anyopaque, name: []const u8, path: []const u8) bool;
/// Per-zone edits (a sampler's level/tune/decay/tone), keyed by zone name,
/// as a JSON object; write nothing when every zone is flat.
pub const WriteZonesJsonFn = *const fn (state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void;
/// Restore per-zone edits from such an object. Unknown zones are ignored.
pub const ApplyZonesJsonFn = *const fn (state: *anyopaque, zones: std.json.Value) void;
/// The machine's current note map, when it can change at runtime (a
/// sampler that loads a kit). Valid until the machine next loads.
pub const NoteLabelsFn = *const fn (state: *anyopaque) []const NoteLabel;

pub const NOTE_LABEL_TEXT = 23;

/// One entry of a machine's note map: a MIDI pitch it answers to plus a
/// short label. Machines with a note map (drum machines) get a labelled
/// drum-lane piano roll instead of the chromatic keyboard.
pub const NoteLabel = struct {
    pitch: u8 = 0,
    label: [NOTE_LABEL_TEXT:0]u8 = [_:0]u8{0} ** NOTE_LABEL_TEXT,
    label_len: u8 = 0,

    pub fn labelSlice(self: *const NoteLabel) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn labelZ(self: *const NoteLabel) [*:0]const u8 {
        return @ptrCast(&self.label[0]);
    }
};

pub const Machine = struct {
    name: []const u8,
    state: *anyopaque,
    render: RenderFn,
    draw_panel: DrawPanelFn,
    reset: ResetFn,
    deinit: ?DeinitFn = null,
    sync_params: ?SyncParamsFn = null,
    preset_count: ?PresetCountFn = null,
    preset_name: ?PresetNameFn = null,
    apply_preset: ?ApplyPresetFn = null,
    save_preset: ?SavePresetFn = null,
    save_preset_named: ?SavePresetNamedFn = null,
    rename_preset: ?RenamePresetFn = null,
    current_preset: ?CurrentPresetFn = null,
    /// Project persistence: dump/restore the machine's settings as JSON.
    write_params_json: ?WriteParamsJsonFn = null,
    set_param: ?SetParamFn = null,
    write_assets_json: ?WriteAssetsJsonFn = null,
    load_asset: ?LoadAssetFn = null,
    write_zones_json: ?WriteZonesJsonFn = null,
    apply_zones_json: ?ApplyZonesJsonFn = null,
    /// Preferred panel card width in pixels. The bay uses this to size
    /// the rect passed to draw_panel. 0 = bay chooses a default.
    panel_w: f32 = 0,
    /// When true, the bay draws the title bar (name + preset) and passes
    /// draw_panel only the body rect below it. When false (legacy callback
    /// machines like mono1) the machine draws its own title bar.
    host_titlebar: bool = false,
    /// Advisory note map (drum machines); empty = chromatic machine.
    /// Points into instance-owned storage, valid for the machine's lifetime.
    note_labels: []const NoteLabel = &.{},
    /// Overrides note_labels when set: the map as of now.
    note_labels_fn: ?NoteLabelsFn = null,

    /// The note map to draw: the live one if the machine has it.
    pub fn noteLabels(self: *const Machine) []const NoteLabel {
        if (self.note_labels_fn) |f| return f(self.state);
        return self.note_labels;
    }
};
