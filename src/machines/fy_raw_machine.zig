//! Generic raw-DSP2 fy machine adapter.
//!
//! The host owns scheduling, state storage, params storage, note/event
//! routing, and buffers; fy owns the raw DSP2 entrypoints. The machine is
//! fully described by the `manifest` word in its .fy file (vocabulary in
//! machines/lib/manifest.fy, walker in src/machine_desc.zig) — entry words,
//! sizes, controls, panel layout, and the optional block-prepare word. The
//! adapter is generic: adding a machine never requires a Zig wrapper.

const std = @import("std");
const Fy = @import("fy").Fy;
const c = @import("../c.zig");
const machine = @import("../machine.zig");
const fy_host_mod = @import("../fy_host.zig");
const FyHost = fy_host_mod.FyHost;
const machine_desc = @import("../machine_desc.zig");
const dx7_algorithms = @import("../dx7_algorithms.zig");
const presets_mod = @import("../presets.zig");
const wav = @import("../wav.zig");
const waveform = @import("../waveform.zig");
const keymap = @import("../keymap.zig");
const native_dialog = @import("../native_dialog.zig");
const ui_core = @import("../ui/core.zig");
const ui_ctl = @import("../ui/controls.zig");
const ui_style = @import("../ui/style.zig");
const ui_menu = @import("../ui/menu.zig");
const automation = @import("../automation.zig");
const snapshot = @import("../snapshot.zig");
const Ui = ui_core.Ui;
const Rect = ui_core.Rect;

const MAX_STATE = 1024;
const MAX_PARAMS = 4096;
// State regions: polyphonic voice machines get one per voice, effect
// machines use two (L/R). The region index reaches kernels as ctx.chan.
const MAX_REGIONS = 8;
// Host-allocated buffers are sized in seconds at the highest sample rate we
// run at; kernels read the element count back from state and clamp, so a
// lower device rate just means extra headroom.
const BUFFER_SR = 96_000.0;
const MAX_BLOCK = 4096;
const MAX_OPTS = machine_desc.MAX_OPTS;
const MAX_CONTROLS = machine_desc.MAX_CONTROLS;
const MAX_STRIPS = machine_desc.MAX_STRIPS;
const RawCaller = Fy.Dsp2RawRepeatedCaller;
const RawSlots = Fy.Dsp2RawRepeatedSlots;

pub const Mode = machine_desc.Mode;

/// Kernel ABI context (docs/04 §Kernel ABI), mirrored by `Ctx` in
/// kernels/00-primitives/ctx.fy. Every entry word gets a pointer to this;
/// the host refreshes it before each call. All cells are 8 bytes so the
/// fy ustruct (f64 fields) lines up; `data` is a pointer read with p@64.
pub const KernelCtx = extern struct {
    sr: f64 = 48_000,
    inv_sr: f64 = 1.0 / 48_000.0,
    tempo: f64 = 120,
    beat: f64 = 0,
    frames: f64 = 0,
    chan: f64 = 0,
    hz: f64 = 0,
    vel: f64 = 0,
    pitch: f64 = 0,
    data: usize = 0,
    legato: f64 = 0,
    // Per-note expression (docs/22), for note-expr words.
    pressure: f64 = 0.5,
    slide: f64 = 0,
    gain: f64 = 1,
};

/// One sample's audio lanes, mirrored by `Io` in ctx.fy. Render words get a
/// pointer that the repeated caller advances by @sizeOf(IoFrame) per sample.
/// out_l is first so a stage handed io can store through it as `out`.
pub const IoFrame = extern struct {
    out_l: f64 = 0,
    out_r: f64 = 0,
    in_l: f64 = 0,
    in_r: f64 = 0,
    det: f64 = 0,
    /// Signed detector audio: the key pair when keyed, else the input
    /// pair; never swapped for the dual-mono R pass (docs/24 §Prerequisites).
    sc_l: f64 = 0,
    sc_r: f64 = 0,
};
const IO_STRIDE: u12 = @sizeOf(IoFrame);
/// Knob smoothing (docs/17 D, docs/08 §2): the normalized knob position
/// glides to its target with this time constant, so exp-curve knobs sweep
/// perceptually evenly. While any knob moves, the block renders in
/// SMOOTH_CHUNK-sample sub-blocks with params re-synced between them.
const SMOOTH_TAU_S: f64 = 0.02;
const SMOOTH_CHUNK: usize = 32;
const SMOOTH_EPS: f32 = 1e-5;
/// An automated knob within this of its curve stops gliding and follows it;
/// a lane jump bigger than AUTO_JUMP in one chunk glides instead.
const AUTO_CATCH: f32 = 1e-3;
const AUTO_JUMP: f32 = 0.05;

/// -120 dBFS: a released voice whose whole-block contribution stays below
/// this stops rendering until its next note-on.
const IDLE_FLOOR: f64 = 1e-6;
const Control = machine_desc.Control;
const Display = machine_desc.Display;

pub const FyRawMachine = struct {
    host: *FyHost,
    desc: machine_desc.Desc,
    // Per-region state: effect machines run L through region 0 and R through
    // region 1 so per-channel state never cross-talks; polyphonic voice
    // machines get one region per voice.
    state_buf: [MAX_REGIONS * MAX_STATE]u8 align(8) = [_]u8{0} ** (MAX_REGIONS * MAX_STATE),
    params_buf: [MAX_PARAMS]u8 align(8) = [_]u8{0} ** MAX_PARAMS,
    io: [MAX_BLOCK]IoFrame = [_]IoFrame{.{}} ** MAX_BLOCK,
    kctx: KernelCtx = .{},
    prepare_slots: RawSlots = .{},
    note_on_slots: RawSlots = .{},
    note_off_slots: RawSlots = .{},
    render_slots: RawSlots = .{},
    block_prepare_slots: RawSlots = .{},
    prepare_caller: ?RawCaller = null,
    note_on_caller: ?RawCaller = null,
    note_off_caller: ?RawCaller = null,
    note_expr_slots: RawSlots = .{},
    note_expr_caller: ?RawCaller = null,
    render_caller: ?RawCaller = null,
    // Optional per-block dsp2 word (params sample-rate --): coefficient fills
    // that must not run per sample, e.g. the MS-20 svf profile region.
    block_prepare_caller: ?RawCaller = null,
    raw_control_bits: [MAX_CONTROLS]std.atomic.Value(u32) = undefined,
    // Audio-thread smoothed knob positions (direct_f64 controls only) and
    // UI-thread snap requests: preset/project/param sets jump, drags glide.
    smooth_norm: [MAX_CONTROLS]f32 = [_]f32{0} ** MAX_CONTROLS,
    snap_req: [MAX_CONTROLS]std.atomic.Value(bool) = [_]std.atomic.Value(bool){std.atomic.Value(bool).init(true)} ** MAX_CONTROLS,
    // Automation (docs/22). Audio thread: this chunk's lane value per
    // control, and whether a gliding control has caught up with its curve
    // (then it follows exactly instead of lagging the 20 ms smoother).
    auto_on: [MAX_CONTROLS]bool = [_]bool{false} ** MAX_CONTROLS,
    auto_val: [MAX_CONTROLS]f32 = [_]f32{0} ** MAX_CONTROLS,
    auto_locked: [MAX_CONTROLS]bool = [_]bool{false} ** MAX_CONTROLS,
    // UI writes, audio reads: a manual override of an automated control,
    // 0 none, 1 held (touch), 2 sticky until the transport starts.
    auto_override: [MAX_CONTROLS]std.atomic.Value(u8) = [_]std.atomic.Value(u8){std.atomic.Value(u8).init(0)} ** MAX_CONTROLS,
    // UI thread: the automated value each control shows (null = no lane),
    // set by the host every frame, and a pending request for the host.
    ui_auto: [MAX_CONTROLS]?f32 = [_]?f32{null} ** MAX_CONTROLS,
    auto_request: ?machine.AutoRequest = null,
    // The control a drag holds this frame (automation recording).
    touch: ?machine.Touch = null,
    ctx_control: usize = 0,
    panel_w: f32 = 128,
    failed: bool = false,
    // Active panel tab for paged machines (index into desc.pages). Per
    // instance, UI-thread only.
    ui_tab: usize = 0,
    // Generic derived-params hook (params derive-data --): a machine-declared
    // dsp2 word run each block to compute params from controls + opaque data.
    derive_slots: RawSlots = .{},
    derive_caller: ?RawCaller = null,
    preset_dir: [512]u8 = [_]u8{0} ** 512,
    preset_dir_len: usize = 0,
    presets: presets_mod.List = .{},
    current_preset_idx: i32 = -1,
    // Host-allocated audio buffers (manifest `buffer` requests), one per
    // channel. Base pointer + element count are injected into each channel's
    // state at the request's introspected offsets.
    buffer_mem: [machine_desc.MAX_BUFFERS][2][]f64 = undefined,
    // Read-only audio assets loaded from disk at create (manifest `asset`),
    // shared across voices via params.
    asset_mem: [machine_desc.MAX_ASSETS]wav.Sample = [_]wav.Sample{.{ .data = &.{}, .sample_rate = 0 }} ** machine_desc.MAX_ASSETS,
    // Keymap assets (manifest `keymap`): the loaded pool + zone table.
    asset_keymap: [machine_desc.MAX_ASSETS]keymap.Keymap = [_]keymap.Keymap{.{}} ** machine_desc.MAX_ASSETS,
    /// A keymap's pool low-passed ahead of its stored rate
    /// (`keymap-antialias`), what the kernel reads when present, and the
    /// control value it was built for.
    aa_pool: [machine_desc.MAX_ASSETS][]f64 = [_][]f64{&.{}} ** machine_desc.MAX_ASSETS,
    aa_built: [machine_desc.MAX_ASSETS]f64 = [_]f64{-1} ** machine_desc.MAX_ASSETS,
    // A valid silent target for assets that failed to load, so a kernel's
    // clamped read hits real zeroed memory instead of an empty slice's ptr.
    // Long enough for an interpolator reading around the guard index.
    asset_silence: [16]f64 align(8) = [_]f64{0} ** 16,
    // The zone table an empty keymap points at: every slot unused.
    empty_zones: [keymap.MAX_ZONES]keymap.Zone = [_]keymap.Zone{keymap.unused_zone} ** keymap.MAX_ZONES,
    // Each asset's current source path (the manifest default, or what LOAD
    // picked), for the project file.
    asset_path: [machine_desc.MAX_ASSETS][512]u8 = undefined,
    asset_path_len: [machine_desc.MAX_ASSETS]usize = [_]usize{0} ** machine_desc.MAX_ASSETS,
    // Sampler zone editing, for the keymap asset: the per-zone edits the
    // voice reads through a params pointer, the zone the panel has
    // selected, the piano roll's key names for a kit, and the zone list's
    // hit lights (the voice writes zone_edits.hit / .last).
    zone_edits: keymap.ZoneEdits = .{},
    /// Reversed sounds and sounds copied onto keys, applied on every load.
    zone_derive: keymap.Derive = .{},
    zone_sel: usize = 0,
    /// The zone row a right-click opened the zone menu on.
    zone_ctx: usize = 0,
    // The zone list shows one row per zone name: velocity layers and round
    // robins of one sound (an SFZ label, a repeated file) edit together.
    zone_row_first: [keymap.MAX_ZONES]u16 = undefined,
    zone_row_of: [keymap.MAX_ZONES]u16 = undefined,
    zone_row_count: usize = 0,
    zone_follow_moved: bool = false,
    zone_follow: bool = false,
    zone_scroll: usize = 0,
    zone_last_seen: f64 = -1,
    zone_hit_seen: [keymap.MAX_ZONES]f64 = [_]f64{0} ** keymap.MAX_ZONES,
    zone_flash: [keymap.MAX_ZONES]f32 = [_]f32{0} ** keymap.MAX_ZONES,
    // The zone the waveform's peak cache holds (maxInt: rebuild), and its
    // sample's peak, for the normalized drawing and the readout.
    wave_zone: usize = std.math.maxInt(usize),
    wave_peak: f64 = 0,
    km_labels: [keymap.MAX_ZONES]machine.NoteLabel = undefined,
    km_label_count: usize = 0,
    // True once LOAD, a preset or a project replaced the manifest default.
    asset_loaded: [machine_desc.MAX_ASSETS]bool = [_]bool{false} ** machine_desc.MAX_ASSETS,
    // Peak pyramid per asset for oscillogram drawing (UI thread only).
    asset_cache: [machine_desc.MAX_ASSETS]waveform.PeakCache = [_]waveform.PeakCache{.{}} ** machine_desc.MAX_ASSETS,
    // Display name (basename) of each asset's currently loaded file.
    asset_label: [machine_desc.MAX_ASSETS][96]u8 = undefined,
    asset_label_len: [machine_desc.MAX_ASSETS]usize = [_]usize{0} ** machine_desc.MAX_ASSETS,
    // Stored so runtime sample loads can (re)allocate without a passed alloc.
    alloc: std.mem.Allocator = undefined,
    // Voice allocator (voice machines with desc.voices > 1). Voices are
    // never freed — like the Juno-106, every voice always renders; note-on
    // takes the oldest un-gated voice, else steals the oldest gated one.
    // note_id is -1 throughout the sequencer, so matching is by pitch.
    voice_pitch: [MAX_REGIONS]f32 = [_]f32{-1} ** MAX_REGIONS,
    voice_gate: [MAX_REGIONS]bool = [_]bool{false} ** MAX_REGIONS,
    voice_age: [MAX_REGIONS]u64 = [_]u64{0} ** MAX_REGIONS,
    age_counter: u64 = 0,
    // Mono machines (1 voice, melodic): held-note stack, newest last, for
    // last-note priority. Releasing the sounding note falls back to the
    // newest still-held one as a legato retrigger.
    mono_held: [16]f32 = undefined,
    mono_held_id: [16]i32 = undefined,
    mono_held_n: usize = 0,
    // The note id each voice plays (-1: a source without ids). Note-offs
    // and expression match by id, so a bent note is still found.
    voice_note_id: [MAX_REGIONS]i32 = [_]i32{-1} ** MAX_REGIONS,
    // Idle voices are skipped entirely (docs/17 D6). A voice wakes on
    // note-on and goes idle once released and its contribution stays under
    // IDLE_FLOOR for a whole block. voice_peak is this block's max |delta|
    // the voice added to the shared out lane.
    voice_idle: [MAX_REGIONS]bool = [_]bool{true} ** MAX_REGIONS,
    voice_peak: [MAX_REGIONS]f64 = [_]f64{0} ** MAX_REGIONS,
    // out_l before a voice's pass, to measure what that voice added.
    voice_snap: [MAX_BLOCK]f64 = [_]f64{0} ** MAX_BLOCK,
    // Per-frame meter ballistics (meter display kind). One per machine; a
    // limiter has a single meter. Updated on the UI thread from live state.
    meter_ui: MeterUi = .{},

    pub fn create(alloc: std.mem.Allocator, path: []const u8) !*FyRawMachine {
        const self = try alloc.create(FyRawMachine);
        errdefer alloc.destroy(self);
        const host = try alloc.create(FyHost);
        errdefer alloc.destroy(host);
        host.* = FyHost.init(alloc);
        errdefer host.deinit();

        try host.compileFile(path);
        const desc = try machine_desc.read(host);
        if (desc.state_size > MAX_STATE or desc.params_size > MAX_PARAMS) return error.RawMachineStorageTooLarge;
        if (desc.voices > MAX_REGIONS) return error.RawMachineTooManyVoices;
        // Host buffers are allocated per channel (2); polyphonic machines
        // would need per-voice rings — not wired yet.
        if (desc.voices > 1 and desc.buffer_count > 0) return error.RawMachineVoicesWithBuffers;

        try validateWord(host, desc.renderWord());
        if (desc.prepareWord()) |word| try validateWord(host, word);
        if (desc.noteOnWord()) |word| try validateWord(host, word);
        if (desc.noteOffWord()) |word| try validateWord(host, word);
        if (desc.blockPrepareWord()) |word| try validateWord(host, word);

        self.* = .{
            .host = host,
            .desc = desc,
            .panel_w = desc.panel_w,
            .alloc = alloc,
        };
        if (presets_mod.dirFromMachinePath(self.preset_dir[0..], path)) |dir| {
            self.preset_dir_len = dir.len;
            self.presets = presets_mod.scan(dir);
        }
        try self.allocBuffers(alloc);
        errdefer self.freeBuffersUpTo(alloc, self.desc.buffer_count);
        try self.loadAssets(alloc, path);
        errdefer self.freeAssets(alloc);
        try self.compileCallers();
        self.initRawControls(); // runs block-prepare, which reads asset SR
        return self;
    }

    // Load each declared asset (path relative to the machine's directory)
    // into f64 mono and inject ptr/len/native-sr into params. Missing files
    // are non-fatal: the asset stays empty (len 0) and the voice is silent
    // until something is loaded at runtime (Phase B).
    fn loadAssets(self: *FyRawMachine, alloc: std.mem.Allocator, machine_path: []const u8) !void {
        const dir = std.fs.path.dirname(machine_path) orelse ".";
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*req, ai| {
            var pbuf: [768]u8 = undefined;
            const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, req.fileSlice() }) catch continue;
            if (req.keymap) {
                self.asset_keymap[ai] = keymap.load(alloc, full) catch keymap.Keymap{};
                self.aa_pool[ai] = self.buildAntialias(ai, &self.asset_keymap[ai]) orelse &.{};
                self.keymapChanged(ai);
            } else {
                self.asset_mem[ai] = wav.load(alloc, full) catch wav.Sample{ .data = &.{}, .sample_rate = 0 };
                self.asset_cache[ai].build(alloc, self.asset_mem[ai].data) catch {};
            }
            self.setAssetSource(ai, full);
        }
        self.injectAssets();
    }

    /// Remember where an asset came from, and label it: the file name,
    /// plus the zone count for a keymap of more than one.
    fn setAssetSource(self: *FyRawMachine, ai: usize, path: []const u8) void {
        const np = @min(path.len, self.asset_path[ai].len);
        @memcpy(self.asset_path[ai][0..np], path[0..np]);
        self.asset_path_len[ai] = np;
        const base = std.fs.path.basename(path);
        const zones = self.asset_keymap[ai].count;
        const label = if (self.desc.assets[ai].keymap and zones > 1)
            std.fmt.bufPrint(&self.asset_label[ai], "{s} / {d} ZONES", .{ base, zones }) catch base
        else
            base;
        const n = @min(label.len, self.asset_label[ai].len);
        std.mem.copyForwards(u8, self.asset_label[ai][0..n], label[0..n]);
        self.asset_label_len[ai] = n;
    }

    /// The asset's current source path ("" if none): what a project saves.
    pub fn assetPath(self: *const FyRawMachine, ai: usize) []const u8 {
        return self.asset_path[ai][0..self.asset_path_len[ai]];
    }

    fn freeAssets(self: *FyRawMachine, alloc: std.mem.Allocator) void {
        for (self.asset_mem[0..self.desc.asset_count], 0..) |*s, ai| {
            if (s.data.len > 0) alloc.free(s.data);
            s.* = .{ .data = &.{}, .sample_rate = 0 };
            self.asset_keymap[ai].deinit(alloc);
            if (self.aa_pool[ai].len > 0) alloc.free(self.aa_pool[ai]);
            self.aa_pool[ai] = &.{};
            self.asset_cache[ai].deinit(alloc);
        }
    }

    /// The anti-aliased pool for keymap `ai` as `km`, at its control's
    /// current value; null when the asset has none or it can't be built.
    fn buildAntialias(self: *FyRawMachine, ai: usize, km: *const keymap.Keymap) ?[]f64 {
        const req = &self.desc.assets[ai];
        if (req.aa_control_len == 0 or km.count == 0) return null;
        const rate = controlValueById(self, req.aaControl()) orelse return null;
        if (!(rate > 0)) return null;
        const pool = keymap.antialias(self.alloc, km, rate * req.aa_ratio, rate, req.aa_cap) catch return null;
        self.aa_built[ai] = rate;
        return pool;
    }

    /// Rebuild every anti-aliased pool whose control moved since it was
    /// built. UI thread; the swap is fenced, and the pool keeps its layout,
    /// so sounding voices carry on.
    fn refreshAntialias(self: *FyRawMachine) void {
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*req, ai| {
            if (!req.keymap or req.aa_control_len == 0) continue;
            const rate = controlValueById(self, req.aaControl()) orelse continue;
            if (rate == self.aa_built[ai] and self.aa_pool[ai].len == self.asset_keymap[ai].pool.len) continue;
            const pool = self.buildAntialias(ai, &self.asset_keymap[ai]) orelse continue;
            fy_host_mod.lockCallbacks();
            const old = self.aa_pool[ai];
            self.aa_pool[ai] = pool;
            self.injectAssets();
            fy_host_mod.unlockCallbacks();
            if (old.len > 0) self.alloc.free(old);
        }
    }

    // Swap an asset's audio at runtime (UI thread). lockCallbacks fences the
    // render path so the audio thread can't be mid-read of the old buffer
    // while we free it and repoint params. The peak cache is UI-only and
    // needs no fence. On failure the old sample is kept.
    pub fn loadAssetRuntime(self: *FyRawMachine, ai: usize, path: []const u8) bool {
        if (ai >= self.desc.asset_count) return false;
        if (self.desc.assets[ai].keymap) return self.loadKeymapRuntime(ai, path);
        var rb: [1024]u8 = undefined;
        var pb: [1024]u8 = undefined;
        const src = keymap.portablePath(&pb, path);
        var loaded = wav.load(self.alloc, keymap.resolvePath(&rb, src)) catch return false;
        var new_cache = waveform.PeakCache{};
        new_cache.build(self.alloc, loaded.data) catch {
            loaded.deinit(self.alloc);
            return false;
        };

        fy_host_mod.lockCallbacks();
        const old = self.asset_mem[ai];
        self.asset_mem[ai] = loaded;
        self.injectAssets();
        self.silenceVoices();
        fy_host_mod.unlockCallbacks();

        if (old.data.len > 0) self.alloc.free(old.data);
        self.asset_cache[ai].deinit(self.alloc);
        self.asset_cache[ai] = new_cache;
        self.setAssetSource(ai, src);
        self.asset_loaded[ai] = true;
        return true;
    }

    /// The keymap flavour of loadAssetRuntime: load and map off the audio
    /// thread, swap the pool and zone pointers inside the fence, free the
    /// old map after.
    fn loadKeymapRuntime(self: *FyRawMachine, ai: usize, path: []const u8) bool {
        // Library files are kept as "lib:" paths, so a saved project finds
        // them wherever the library lives.
        var rb: [1024]u8 = undefined;
        var pb: [1024]u8 = undefined;
        const src = keymap.portablePath(&pb, path);
        const raw = keymap.load(self.alloc, keymap.resolvePath(&rb, src)) catch return false;
        var loaded = keymap.derive(self.alloc, raw, &self.zone_derive) catch return false;
        // Edits follow zones by name: a reloaded or swapped kit keeps the
        // clap you turned down.
        const edits = remapEdits(&self.zone_edits, &self.asset_keymap[ai], &loaded);
        const aa: []f64 = self.buildAntialias(ai, &loaded) orelse &.{};

        fy_host_mod.lockCallbacks();
        var old = self.asset_keymap[ai];
        const old_aa = self.aa_pool[ai];
        self.asset_keymap[ai] = loaded;
        self.aa_pool[ai] = aa;
        self.zone_edits = edits;
        self.injectAssets();
        self.silenceVoices();
        fy_host_mod.unlockCallbacks();

        old.deinit(self.alloc);
        if (old_aa.len > 0) self.alloc.free(old_aa);
        self.setAssetSource(ai, src);
        self.asset_loaded[ai] = true;
        self.keymapChanged(ai);
        return true;
    }

    /// Inside the fence, after a sample swap: sounding voices hold read
    /// positions into the old pool, which may be shorter than theirs, so
    /// they stop here; the next note-on sets a voice up from scratch.
    /// Reload the keymap with `zone_derive` as it is now, keeping the
    /// selected sound selected when it still exists.
    fn rederive(self: *FyRawMachine, ai: usize) void {
        var pbuf: [1024]u8 = undefined;
        const cur = self.assetPath(ai);
        if (cur.len == 0 or cur.len > pbuf.len) return;
        @memcpy(pbuf[0..cur.len], cur);
        const km = &self.asset_keymap[ai];
        var sel_name = keymap.Name{};
        if (self.zone_sel < km.count) sel_name = km.names[self.zone_sel];
        if (!self.loadKeymapRuntime(ai, pbuf[0..cur.len])) return;
        self.selectZoneNamed(ai, sel_name.slice());
    }

    fn selectZoneNamed(self: *FyRawMachine, ai: usize, name: []const u8) void {
        const km = &self.asset_keymap[ai];
        for (km.names, 0..) |nm, i| if (std.mem.eql(u8, nm.slice(), name)) {
            self.zone_sel = i;
            self.zone_follow_moved = true; // scroll it into view
            return;
        };
    }

    fn silenceVoices(self: *FyRawMachine) void {
        @memset(self.voice_idle[0..], true);
        @memset(self.voice_gate[0..], false);
        self.mono_held_n = 0;
    }

    /// After a keymap load: select the first zone, drop the waveform cache,
    /// relabel the piano roll, reset the hit lights.
    fn keymapChanged(self: *FyRawMachine, ai: usize) void {
        self.zone_sel = 0;
        self.zone_scroll = 0;
        self.wave_zone = std.math.maxInt(usize);
        self.zone_last_seen = self.zone_edits.last;
        self.zone_hit_seen = self.zone_edits.hit;
        @memset(&self.zone_flash, 0);
        self.rebuildLabels(ai);
        self.rebuildRows(ai);
    }

    fn rebuildRows(self: *FyRawMachine, ai: usize) void {
        const km = &self.asset_keymap[ai];
        self.zone_row_count = 0;
        for (0..km.count) |z| {
            const row = for (self.zone_row_first[0..self.zone_row_count], 0..) |f, r| {
                if (std.mem.eql(u8, km.names[f].slice(), km.names[z].slice())) break r;
            } else blk: {
                self.zone_row_first[self.zone_row_count] = @intCast(z);
                self.zone_row_count += 1;
                break :blk self.zone_row_count - 1;
            };
            self.zone_row_of[z] = @intCast(row);
        }
    }

    /// A kit's keys get their zones' names in the piano roll (KICK, SNARE);
    /// a melodic keymap keeps the plain chromatic roll.
    fn rebuildLabels(self: *FyRawMachine, ai: usize) void {
        self.km_label_count = 0;
        const km = &self.asset_keymap[ai];
        if (!km.isKit()) return;
        var seen = [_]bool{false} ** 128;
        for (km.zones[0..km.count], km.names) |z, nm| {
            const key: usize = @intFromFloat(std.math.clamp(z.lo_key, 0, 127));
            if (seen[key]) continue;
            seen[key] = true;
            var nl = machine.NoteLabel{ .pitch = @intCast(key) };
            const text = nm.slice();
            const n = @min(text.len, machine.NOTE_LABEL_TEXT);
            for (text[0..n], 0..) |ch, i| nl.label[i] = if (ch == '_') ' ' else std.ascii.toUpper(ch);
            nl.label_len = @intCast(n);
            self.km_labels[self.km_label_count] = nl;
            self.km_label_count += 1;
        }
        std.mem.sort(machine.NoteLabel, self.km_labels[0..self.km_label_count], {}, struct {
            fn lt(_: void, a: machine.NoteLabel, b: machine.NoteLabel) bool {
                return a.pitch < b.pitch;
            }
        }.lt);
    }

    /// The first keymap asset: the one the zone list edits.
    fn keymapAsset(self: *const FyRawMachine) ?usize {
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*a, i| if (a.keymap) return i;
        return null;
    }

    fn assetIndexByName(self: *const FyRawMachine, name: []const u8) ?usize {
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*a, i| {
            if (std.mem.eql(u8, a.nameSlice(), name)) return i;
        }
        return null;
    }

    // Asset pointer/length/native-SR live in params (shared, read-only).
    // syncRawParams never touches these offsets, so they persist across
    // blocks; only reset (which memsets params) needs a re-inject.
    fn injectAssets(self: *FyRawMachine) void {
        for (self.desc.assets[0..self.desc.asset_count], 0..) |*req, ai| {
            if (req.keymap) {
                const km = &self.asset_keymap[ai];
                const has = km.count > 0;
                const pool = if (self.aa_pool[ai].len == km.pool.len and km.pool.len > 0) self.aa_pool[ai] else km.pool;
                self.writeParamUsize(req.ptr_offset, if (has) @intFromPtr(pool.ptr) else @intFromPtr(&self.asset_silence[0]));
                self.writeParamUsize(req.len_offset, if (has) @intFromPtr(km.zones.ptr) else @intFromPtr(&self.empty_zones[0]));
                self.writeParamF64(req.sr_offset, @floatFromInt(km.count));
                self.writeParamUsize(req.edits_offset, @intFromPtr(&self.zone_edits));
                continue;
            }
            const s = self.asset_mem[ai];
            const ptr: usize = if (s.data.len > 0) @intFromPtr(s.data.ptr) else @intFromPtr(&self.asset_silence[0]);
            self.writeParamUsize(req.ptr_offset, ptr);
            self.writeParamF64(req.len_offset, @floatFromInt(s.data.len));
            self.writeParamF64(req.sr_offset, if (s.sample_rate > 0) s.sample_rate else 48_000);
        }
    }

    fn writeParamUsize(self: *FyRawMachine, offset: usize, value: usize) void {
        if (offset + @sizeOf(usize) > self.desc.params_size) return;
        const ptr: *align(8) usize = @ptrCast(@alignCast(&self.params_buf[offset]));
        ptr.* = value;
    }

    fn allocBuffers(self: *FyRawMachine, alloc: std.mem.Allocator) !void {
        var done: usize = 0;
        errdefer self.freeBuffersUpTo(alloc, done);
        for (self.desc.buffers[0..self.desc.buffer_count], 0..) |*req, bi| {
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(req.seconds * BUFFER_SR))));
            const mem_l = try alloc.alloc(f64, n);
            errdefer alloc.free(mem_l);
            const mem_r = try alloc.alloc(f64, n);
            @memset(mem_l, 0);
            @memset(mem_r, 0);
            self.buffer_mem[bi] = .{ mem_l, mem_r };
            done = bi + 1;
        }
        self.injectBuffers();
    }

    fn freeBuffersUpTo(self: *FyRawMachine, alloc: std.mem.Allocator, count: usize) void {
        for (self.buffer_mem[0..count]) |pair| {
            for (pair) |mem| alloc.free(mem);
        }
    }

    // Write each buffer's base pointer + element count into both channel
    // states. Must rerun after any state memset (reset).
    fn injectBuffers(self: *FyRawMachine) void {
        for (self.desc.buffers[0..self.desc.buffer_count], 0..) |*req, bi| {
            for (0..2) |ch| {
                const mem = self.buffer_mem[bi][ch];
                self.writeStateUsize(ch, req.ptr_offset, @intFromPtr(mem.ptr));
                self.writeStateF64(ch, req.len_offset, @floatFromInt(mem.len));
            }
        }
    }

    fn writeStateUsize(self: *FyRawMachine, ch: usize, offset: usize, value: usize) void {
        if (offset + @sizeOf(usize) > self.desc.state_size) return;
        const ptr: *align(8) usize = @ptrCast(@alignCast(&self.state_buf[ch * MAX_STATE + offset]));
        ptr.* = value;
    }

    fn writeStateF64(self: *FyRawMachine, ch: usize, offset: usize, value: f64) void {
        if (offset + @sizeOf(f64) > self.desc.state_size) return;
        const ptr: *align(8) f64 = @ptrCast(@alignCast(&self.state_buf[ch * MAX_STATE + offset]));
        ptr.* = value;
    }

    fn readStateF64(self: *const FyRawMachine, ch: usize, offset: usize) f64 {
        if (offset + @sizeOf(f64) > self.desc.state_size) return 0;
        const ptr: *align(8) const f64 = @ptrCast(@alignCast(&self.state_buf[ch * MAX_STATE + offset]));
        return ptr.*;
    }

    pub fn machineInterface(self: *FyRawMachine) machine.Machine {
        return .{
            .name = self.desc.nameSlice(),
            .state = self,
            .render = renderImpl,
            .draw_panel = drawPanelImpl,
            .reset = resetImpl,
            .deinit = deinitImpl,
            .panel_w = self.panel_w,
            .host_titlebar = true,
            .note_labels = self.desc.noteLabels(),
            .preset_count = presetCountImpl,
            .preset_name = presetNameImpl,
            .apply_preset = applyPresetImpl,
            .save_preset = savePresetImpl,
            .save_preset_named = savePresetNamedImpl,
            .rename_preset = renamePresetImpl,
            .current_preset = currentPresetImpl,
            .mark_preset = markPresetImpl,
            .write_params_json = writeParamsJsonImpl,
            .set_param = setParamImpl,
            .write_assets_json = writeAssetsJsonImpl,
            .load_asset = loadAssetImpl,
            .write_zones_json = writeZonesJsonImpl,
            .apply_zones_json = applyZonesJsonImpl,
            .note_labels_fn = noteLabelsImpl,
            .takes_expression = self.note_expr_caller != null,
            .takes_key = self.desc.sidechain,
            .control_count = controlCountImpl,
            .control_info = controlInfoImpl,
            .control_value = controlValueImpl,
            .control_knob = controlKnobImpl,
            .control_base = controlBaseImpl,
            .format_control = formatControlImpl,
            .set_auto_ui = setAutoUiImpl,
            .clear_overrides = clearOverridesImpl,
            .take_auto_request = takeAutoRequestImpl,
            .take_touch = takeTouchImpl,
        };
    }

    fn presetDir(self: *const FyRawMachine) []const u8 {
        return self.preset_dir[0..self.preset_dir_len];
    }

    /// Stable machine id = the machine's directory name, derived from the
    /// preset dir (`machines/ms20/presets` → `ms20`). Embedded in preset
    /// JSON for hub forward-compat; the loader ignores it.
    fn machineId(self: *const FyRawMachine) []const u8 {
        const dir = std.fs.path.dirname(self.presetDir()) orelse return "";
        return std.fs.path.basename(dir);
    }

    fn statePtr(self: *FyRawMachine) usize {
        return @intFromPtr(&self.state_buf[0]);
    }

    fn statePtrCh(self: *FyRawMachine, ch: usize) usize {
        return @intFromPtr(&self.state_buf[ch * MAX_STATE]);
    }

    fn regionCount(self: *const FyRawMachine) usize {
        return if (self.desc.mode == .voice_sample) @max(self.desc.voices, 1) else 2;
    }

    fn paramsPtr(self: *FyRawMachine) usize {
        return @intFromPtr(&self.params_buf[0]);
    }

    // Every entry word is ( ctx state params -- ); render words take a
    // leading io pointer ( io ctx state params -- ) advanced per sample.
    // `call:` compositions go through the composition caller.
    fn compileEntry(self: *FyRawMachine, word: []const u8, slots: *RawSlots, is_render: bool) !RawCaller {
        const fy = &self.host.fy;
        const stride: u12 = if (is_render) IO_STRIDE else 0;
        if (fy.isCompositionWord(word)) return fy.compileDsp2CompositionCaller(word, slots, stride, false);
        const kinds: []const Fy.Dsp2RawArgKind = if (is_render) &.{ .ptr, .ptr, .ptr, .ptr } else &.{ .ptr, .ptr, .ptr };
        return fy.compileDsp2RawRepeatedCaller(word, slots, kinds, stride, false);
    }

    fn compileCallers(self: *FyRawMachine) !void {
        if (self.desc.prepareWord()) |w| self.prepare_caller = try self.compileEntry(w, &self.prepare_slots, false);
        if (self.desc.noteOnWord()) |w| self.note_on_caller = try self.compileEntry(w, &self.note_on_slots, false);
        if (self.desc.noteOffWord()) |w| self.note_off_caller = try self.compileEntry(w, &self.note_off_slots, false);
        if (self.desc.noteExprWord()) |w| self.note_expr_caller = try self.compileEntry(w, &self.note_expr_slots, false);
        if (self.desc.blockPrepareWord()) |w| self.block_prepare_caller = try self.compileEntry(w, &self.block_prepare_slots, false);
        if (self.desc.deriveWord()) |w| self.derive_caller = try self.compileEntry(w, &self.derive_slots, false);
        self.render_caller = try self.compileEntry(self.desc.renderWord(), &self.render_slots, true);
    }

    fn initRawControls(self: *FyRawMachine) void {
        var i: usize = 0;
        while (i < MAX_CONTROLS) : (i += 1) {
            const value: f32 = if (i < self.desc.control_count) blk: {
                const ctl = self.desc.controls[i];
                // switches store the selected index and int-steps the raw
                // integer directly (not a 0..1 norm).
                break :blk switch (ctl.kind) {
                    .switch_sel, .int_range => @floatCast(ctl.default),
                    .direct_f64 => valueToNorm(ctl, ctl.default),
                };
            } else 0;
            self.raw_control_bits[i] = std.atomic.Value(u32).init(@bitCast(value));
            self.smooth_norm[i] = value;
        }
        self.syncRawParams(48_000.0, 120.0); // no transport yet at init; sane default
    }

    fn controlNorm(self: *const FyRawMachine, idx: usize) f32 {
        return @bitCast(self.raw_control_bits[idx].load(.monotonic));
    }

    /// Set a knob and jump straight there (no glide): presets, project load,
    /// host param sets.
    pub fn setControlNormSnap(self: *FyRawMachine, idx: usize, value: f32) void {
        self.setControlNorm(idx, value);
        self.snap_req[idx].store(true, .release);
    }

    /// Advance smoothed knobs by `n` samples (audio thread). Returns true
    /// while any knob is still gliding.
    fn advanceSmoothing(self: *FyRawMachine, n: usize) bool {
        const a: f32 = @floatCast(1.0 - @exp(-@as(f64, @floatFromInt(n)) / (SMOOTH_TAU_S * self.kctx.sr)));
        var moving = false;
        for (self.desc.controls[0..self.desc.control_count], 0..) |ctl, i| {
            if (ctl.kind != .direct_f64) continue;
            const auto = self.automated(i);
            const target = if (auto) self.auto_val[i] else self.controlNorm(i);
            if (self.snap_req[i].swap(false, .acq_rel)) self.smooth_norm[i] = target;
            var cur = self.smooth_norm[i];
            if (!auto) {
                self.auto_locked[i] = false;
            } else if (self.auto_locked[i]) {
                // A curve is already continuous: follow it exactly. A big
                // jump (a seek, a loop wrap, a step in the lane) glides.
                if (@abs(target - cur) <= AUTO_JUMP) {
                    self.smooth_norm[i] = target;
                    continue;
                }
                self.auto_locked[i] = false;
            }
            if (cur == target) {
                if (auto) self.auto_locked[i] = true;
                continue;
            }
            cur += (target - cur) * a;
            if (@abs(target - cur) < SMOOTH_EPS or (auto and @abs(target - cur) < AUTO_CATCH)) {
                cur = target;
                if (auto) self.auto_locked[i] = true;
            }
            self.smooth_norm[i] = cur;
            if (cur != target) moving = true;
        }
        return moving;
    }

    /// Block end: released voices that stayed under the floor all block go
    /// idle.
    fn updateIdle(self: *FyRawMachine) void {
        for (0..self.regionCount()) |v| {
            if (!self.voice_idle[v] and !self.voice_gate[v] and self.voice_peak[v] < IDLE_FLOOR) self.voice_idle[v] = true;
            self.voice_peak[v] = 0;
        }
    }

    /// True if any knob's smoothed position differs from its target.
    fn anyGliding(self: *FyRawMachine) bool {
        for (self.desc.controls[0..self.desc.control_count], 0..) |ctl, i| {
            if (ctl.kind != .direct_f64) continue;
            if (self.snap_req[i].load(.acquire)) continue;
            if (self.auto_on[i]) continue; // chunked anyway while automated
            if (self.smooth_norm[i] != self.controlNorm(i)) return true;
        }
        return false;
    }

    /// Audio thread: a lane drives control `i` this chunk and no hand
    /// override holds it.
    fn automated(self: *const FyRawMachine, i: usize) bool {
        return self.auto_on[i] and self.auto_override[i].load(.monotonic) == 0;
    }

    /// Audio thread: the raw value a stepped control plays this chunk.
    fn effRaw(self: *const FyRawMachine, i: usize) f32 {
        return if (self.automated(i)) self.auto_val[i] else self.controlNorm(i);
    }

    /// Audio thread: evaluate every lane on this machine at `beat`.
    fn evalAutomation(self: *FyRawMachine, view: *const snapshot.AutoView, beat: f64) void {
        @memset(self.auto_on[0..], false);
        const snap = view.snap;
        // Track lanes first, clip lanes by clip start: the last lane that
        // applies wins (docs/22 §Precedence).
        for (snap.lanes[0..snap.lane_count], 0..) |lane, li| {
            if (!view.matches(lane) or lane.control >= self.desc.control_count) continue;
            const lb = lane.localBeat(beat) orelse continue;
            self.auto_on[lane.control] = true;
            self.auto_val[lane.control] = automation.evalCursor(view.points(lane), lb, &view.cursors[li]);
        }
    }

    /// UI thread: the value a control shows — its automated value unless
    /// the hand overrides it.
    fn shownNorm(self: *const FyRawMachine, i: usize) f32 {
        if (self.ui_auto[i]) |v| if (self.auto_override[i].load(.monotonic) == 0) return v;
        return self.controlNorm(i);
    }

    pub fn setControlNorm(self: *FyRawMachine, idx: usize, value: f32) void {
        self.raw_control_bits[idx].store(@bitCast(std.math.clamp(value, 0.0, 1.0)), .monotonic);
    }

    // Unclamped store — switches keep the selected index here, not a 0..1 norm.
    fn setControlRaw(self: *FyRawMachine, idx: usize, value: f32) void {
        self.raw_control_bits[idx].store(@bitCast(value), .monotonic);
    }

    fn syncRawParams(self: *FyRawMachine, sample_rate: f64, tempo_bpm: f64) void {
        const controls = self.desc.controls[0..self.desc.control_count];
        for (controls, 0..) |control, i| {
            switch (control.kind) {
                .direct_f64 => self.writeParamF64(control.offset, normToValue(control, self.smooth_norm[i])),
                .switch_sel => self.writeParamF64(control.offset, control.option_values[switchIndex(control, self.effRaw(i))]),
                .int_range => self.writeParamF64(control.offset, intRangeValue(control, self.effRaw(i))),
            }
        }

        for (self.desc.consts[0..self.desc.const_count]) |cnst| {
            self.writeParamF64(cnst.offset, cnst.value);
        }

        // Machine-declared derive hook (params derive-data --): compute derived
        // params from the fresh control values, e.g. FM-86 expands ALGO into the
        // voice routing from its own fy table. Generic — the frame has no
        // machine-specific knowledge. Runs before block-prepare; both only touch
        // params, no ordering dependency.
        self.kctx.sr = sample_rate;
        self.kctx.inv_sr = 1.0 / sample_rate;
        self.kctx.tempo = tempo_bpm;
        self.kctx.chan = 0;
        self.kctx.data = self.desc.derive_data;
        if (self.derive_caller) |*dv| _ = dv.call(1, &self.entryArgs(0)) catch {};

        // Per-block coefficient fill in fy. Runs after controls/consts land
        // so the word reads fresh raw values.
        if (self.block_prepare_caller) |*bp| _ = bp.call(1, &self.entryArgs(0)) catch {};
    }

    /// ( ctx state params ) for region `reg`, with ctx.chan = reg.
    fn entryArgs(self: *FyRawMachine, reg: usize) [3]Fy.Dsp2RawArg {
        self.kctx.chan = @floatFromInt(reg);
        return .{
            .{ .ptr = @intFromPtr(&self.kctx) },
            .{ .ptr = self.statePtrCh(reg) },
            .{ .ptr = self.paramsPtr() },
        };
    }

    fn writeParamF64(self: *FyRawMachine, offset: usize, value: f64) void {
        if (offset + @sizeOf(f64) > self.desc.params_size) return;
        const ptr: *align(8) f64 = @ptrCast(@alignCast(&self.params_buf[offset]));
        ptr.* = value;
    }

    fn readParamF64(self: *const FyRawMachine, offset: usize) f64 {
        if (offset + @sizeOf(f64) > self.desc.params_size) return 0;
        const ptr: *align(8) const f64 = @ptrCast(@alignCast(&self.params_buf[offset]));
        return ptr.*;
    }
};

fn presetCountImpl(state: *anyopaque) machine.PresetIndex {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    return @intCast(self.presets.count);
}

fn presetNameImpl(state: *anyopaque, index: machine.PresetIndex) [*:0]const u8 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (index >= self.presets.count) return "";
    return self.presets.names[index].z();
}

// Apply = parse `id|value` lines and store each matching control's value
// (clamped via valueToNorm; switches store the option index raw). Runs on
// the UI thread; the audio thread sees the atomics next block.
fn currentPresetImpl(state: *anyopaque) i32 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    return self.current_preset_idx;
}

fn markPresetImpl(state: *anyopaque, index: i32) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    self.current_preset_idx = if (index >= 0 and index < self.presets.count) index else -1;
}

/// A switch moved on the panel: store the option, then whatever that
/// option `sets` (a MODEL switch moving the knobs it models).
fn pickOption(self: *FyRawMachine, gi: usize, idx: usize) void {
    self.setControlRaw(gi, @floatFromInt(idx));
    for (self.desc.opt_sets[0..self.desc.opt_set_count]) |*os| {
        if (os.ctl == gi and os.opt == idx) applyControlValue(self, os.idSlice(), os.value);
    }
}

// Store one real-valued control by its stable id. Shared by preset apply,
// the host param-set path (project load), and anything that restores a
// machine's settings from an id→value map. Switches clamp to the option
// index; direct controls go through valueToNorm.
fn applyControlValue(self: *FyRawMachine, id: []const u8, value: f64) void {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (!std.mem.eql(u8, ctl.idSlice(), id)) continue;
        switch (ctl.kind) {
            .switch_sel => {
                const hi: f64 = @floatFromInt(@max(ctl.option_count, 1) - 1);
                self.setControlRaw(i, @floatCast(std.math.clamp(value, 0, hi)));
            },
            .int_range => self.setControlRaw(i, @floatCast(intRangeValue(ctl.*, @floatCast(value)))),
            .direct_f64 => self.setControlNormSnap(i, valueToNorm(ctl.*, value)),
        }
        return;
    }
}

/// Edits for `new`, carried from `old` by zone name; unmatched zones start
/// flat. The hit lights restart.
fn remapEdits(edits: *const keymap.ZoneEdits, old: *const keymap.Keymap, new: *const keymap.Keymap) keymap.ZoneEdits {
    var out = keymap.ZoneEdits{};
    for (new.names, 0..) |nn, i| {
        for (old.names, 0..) |on, j| if (std.mem.eql(u8, nn.slice(), on.slice())) {
            out.level[i] = edits.level[j];
            out.tune[i] = edits.tune[j];
            out.decay[i] = edits.decay[j];
            out.tone[i] = edits.tone[j];
            out.cut[i] = edits.cut[j];
            break;
        };
    }
    return out;
}

fn applyPresetImpl(state: *anyopaque, index: machine.PresetIndex) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (index >= self.presets.count) return;
    self.current_preset_idx = index;
    var fbuf: [presets_mod.MAX_FILE]u8 = undefined;
    const data = presets_mod.readFileBuf(&fbuf, self.presetDir(), self.presets.names[index].slice()) orelse return;

    var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    // A preset may name files to load (a sampler's keymap: "assets":
    // {"smp": "path"}); without them the loaded files stay.
    if (parsed.value.object.get("assets")) |av| if (av == .object) {
        var ait = av.object.iterator();
        while (ait.next()) |kv| if (kv.value_ptr.* == .string) {
            _ = loadAssetImpl(self, kv.key_ptr.*, kv.value_ptr.string);
        };
        // A preset that brings its samples brings their balance too.
        if (parsed.value.object.get("zones")) |zv| applyZonesJsonImpl(self, zv) else resetZoneEdits(self);
    };
    if (parsed.value.object.get("assets") == null) if (parsed.value.object.get("zones")) |zv| applyZonesJsonImpl(self, zv);
    const params = parsed.value.object.get("params") orelse return;
    if (params != .object) return;
    var it = params.object.iterator();
    while (it.next()) |kv| applyControlValue(self, kv.key_ptr.*, jsonF64(kv.value_ptr.*));
    self.refreshAntialias();
}

fn jsonF64(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

// {"smp": "path/to/kit"}: every asset with a source path. Asset names are
// manifest identifiers; paths are JSON-escaped.
fn writeAssetsJsonImpl(state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    var first = true;
    for (self.desc.assets[0..self.desc.asset_count], 0..) |*req, ai| {
        const path = self.assetPath(ai);
        if (path.len == 0) continue;
        try out.appendSlice(alloc, if (first) "{\"" else ",\"");
        first = false;
        try out.appendSlice(alloc, req.nameSlice());
        try out.appendSlice(alloc, "\":\"");
        for (path) |ch| switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            0...0x1f => {},
            else => try out.append(alloc, ch),
        };
        try out.append(alloc, '"');
    }
    if (!first) try out.append(alloc, '}');
}

fn noteLabelsImpl(state: *anyopaque) []const machine.NoteLabel {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (self.km_label_count > 0) return self.km_labels[0..self.km_label_count];
    return self.desc.noteLabels();
}

// {"clap":{"level":-6},"kick":{"tune":-2,"decay":0.4}}: zones whose edits
// aren't flat, by name (names are file stems; quotes and backslashes are
// dropped rather than escaped). A reversed sound adds "reverse":true, a
// copy "copy":"<source name>","key":<key>.
fn writeZonesJsonImpl(state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const ai = self.keymapAsset() orelse return;
    const km = &self.asset_keymap[ai];
    const e = &self.zone_edits;
    var first = true;
    var buf: [160]u8 = undefined;
    const d = &self.zone_derive;
    for (km.names, 0..) |nm, i| {
        // one entry per sound: its layers share the name and the edits
        const dup = for (km.names[0..i]) |prev| {
            if (std.mem.eql(u8, prev.slice(), nm.slice())) break true;
        } else false;
        if (dup) continue;
        const rev = d.isReversed(nm.slice());
        const copy = d.copyIndex(nm.slice());
        if (e.level[i] == 0 and e.tune[i] == 0 and e.decay[i] == 0 and e.tone[i] == 0 and e.cut[i] == 0 and !rev and copy == null) continue;
        try out.appendSlice(alloc, if (first) "{\"" else ",\"");
        first = false;
        try appendZoneName(out, alloc, nm.slice());
        const frag = try std.fmt.bufPrint(&buf, "\":{{\"level\":{d},\"tune\":{d},\"decay\":{d},\"tone\":{d},\"cut\":{d}", .{ e.level[i], e.tune[i], e.decay[i], e.tone[i], e.cut[i] });
        try out.appendSlice(alloc, frag);
        if (rev) try out.appendSlice(alloc, ",\"reverse\":true");
        if (copy) |ci| {
            try out.appendSlice(alloc, ",\"copy\":\"");
            try appendZoneName(out, alloc, d.copies[ci].from.slice());
            try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "\",\"key\":{d}", .{d.copies[ci].key}));
        }
        try out.append(alloc, '}');
    }
    if (!first) try out.append(alloc, '}');
}

fn appendZoneName(out: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8) !void {
    for (name) |ch| if (ch != '"' and ch != '\\' and ch >= 0x20) try out.append(alloc, ch);
}

/// Set edits by zone name; every zone of that name (an SFZ can reuse a
/// sample) takes them. Zones not named start flat. Reversals and copies
/// are set first (reloading the keymap when they changed), so a copy's
/// own edits find it.
fn applyZonesJsonImpl(state: *anyopaque, zones: std.json.Value) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (zones != .object) return;
    const ai = self.keymapAsset() orelse return;
    var d = keymap.Derive{};
    var dit = zones.object.iterator();
    while (dit.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const o = kv.value_ptr.object;
        if (o.get("copy")) |cv| if (cv == .string) {
            const key = if (o.get("key")) |k| std.math.clamp(jsonF64(k), 0, 127) else 0;
            d.addCopy(kv.key_ptr.*, cv.string, @intFromFloat(key));
        };
        if (o.get("reverse")) |rv| if (rv == .bool and rv.bool) d.setReversed(kv.key_ptr.*, true);
    }
    // copies in the order they were made: sources before their copies
    sortCopies(&d);
    if (!d.eql(&self.zone_derive)) {
        self.zone_derive = d;
        self.rederive(ai);
    }
    const km = &self.asset_keymap[ai];
    var e = keymap.ZoneEdits{};
    e.hit = self.zone_edits.hit;
    e.last = self.zone_edits.last;
    var it = zones.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const o = kv.value_ptr.object;
        for (km.names, 0..) |nm, i| {
            if (!std.mem.eql(u8, nm.slice(), kv.key_ptr.*)) continue;
            if (o.get("level")) |v| e.level[i] = std.math.clamp(jsonF64(v), -48, 24);
            if (o.get("tune")) |v| e.tune[i] = std.math.clamp(jsonF64(v), -48, 48);
            if (o.get("decay")) |v| e.decay[i] = std.math.clamp(jsonF64(v), 0, 30);
            if (o.get("tone")) |v| e.tone[i] = std.math.clamp(jsonF64(v), -6, 6);
            if (o.get("cut")) |v| e.cut[i] = @round(std.math.clamp(jsonF64(v), 0, CUT_MAX));
        }
    }
    // Cell-wise stores the audio thread may read mid-update: a note-on
    // sees a zone's old or new value, both valid.
    self.zone_edits.level = e.level;
    self.zone_edits.tune = e.tune;
    self.zone_edits.decay = e.decay;
    self.zone_edits.tone = e.tone;
    self.zone_edits.cut = e.cut;
}

/// Order copies so each comes after the copy it was made from (JSON
/// objects keep no order we can rely on).
fn sortCopies(d: *keymap.Derive) void {
    var placed: usize = 0;
    var guard: usize = 0;
    while (placed < d.copy_n and guard < keymap.MAX_DERIVED * keymap.MAX_DERIVED) : (guard += 1) {
        // find an unplaced copy whose source isn't an unplaced copy
        var pick: ?usize = null;
        for (placed..d.copy_n) |i| {
            const from = d.copies[i].from.slice();
            const waits = for (placed..d.copy_n) |j| {
                if (j != i and std.mem.eql(u8, d.copies[j].name.slice(), from)) break true;
            } else false;
            if (!waits) {
                pick = i;
                break;
            }
        }
        const i = pick orelse return; // a cycle: leave the rest
        std.mem.swap(keymap.Copy, &d.copies[placed], &d.copies[i]);
        placed += 1;
    }
}

fn resetZoneEdits(self: *FyRawMachine) void {
    if (!self.zone_derive.empty()) {
        self.zone_derive = .{};
        if (self.keymapAsset()) |ai| self.rederive(ai);
    }
    const flat = keymap.ZoneEdits{};
    self.zone_edits.level = flat.level;
    self.zone_edits.tune = flat.tune;
    self.zone_edits.decay = flat.decay;
    self.zone_edits.tone = flat.tone;
    self.zone_edits.cut = flat.cut;
}

fn loadAssetImpl(state: *anyopaque, name: []const u8, path: []const u8) bool {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const ai = self.assetIndexByName(name) orelse return false;
    if (std.mem.eql(u8, self.assetPath(ai), path)) return true;
    return self.loadAssetRuntime(ai, path);
}

// ── Automation hooks (docs/22) ───────────────────────────────────────

fn controlCountImpl(state: *anyopaque) usize {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    return self.desc.control_count;
}

fn controlInfoImpl(state: *anyopaque, i: usize) machine.ControlInfo {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const ctl = &self.desc.controls[i];
    var info = machine.ControlInfo{ .id = ctl.idSlice(), .label = ctl.label[0..ctl.label_len], .module = ctl.moduleSlice() };
    switch (ctl.kind) {
        .direct_f64 => {},
        .switch_sel => {
            info.stepped = true;
            info.hi = @floatFromInt(@max(ctl.option_count, 1) - 1);
        },
        .int_range => {
            info.stepped = true;
            info.lo = @floatCast(ctl.min);
            info.hi = @floatCast(ctl.max);
        },
    }
    return info;
}

/// Knob space → real units, the preset convention (switches: option index).
fn controlValueImpl(state: *anyopaque, i: usize, knob: f32) f64 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const ctl = self.desc.controls[i];
    return switch (ctl.kind) {
        .switch_sel => @floatFromInt(switchIndex(ctl, knob)),
        .int_range => intRangeValue(ctl, knob),
        .direct_f64 => normToValue(ctl, knob),
    };
}

fn controlKnobImpl(state: *anyopaque, i: usize, value: f64) f32 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const ctl = self.desc.controls[i];
    return switch (ctl.kind) {
        .switch_sel => @floatFromInt(switchIndex(ctl, @floatCast(value))),
        .int_range => @floatCast(intRangeValue(ctl, @floatCast(value))),
        .direct_f64 => valueToNorm(ctl, value),
    };
}

fn controlBaseImpl(state: *anyopaque, i: usize) f32 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    return self.controlNorm(i);
}

fn formatControlImpl(state: *anyopaque, i: usize, knob: f32, buf: []u8) []const u8 {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const ctl = &self.desc.controls[i];
    return switch (ctl.kind) {
        .switch_sel => std.fmt.bufPrint(buf, "{s}", .{std.mem.span(ctl.optionLabelZ(switchIndex(ctl.*, knob)))}) catch "?",
        .int_range => std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(intRangeValue(ctl.*, knob)))}) catch "?",
        .direct_f64 => blk: {
            var vb: [16:0]u8 = undefined;
            break :blk std.fmt.bufPrint(buf, "{s}", .{std.mem.span(formatControlValue(&vb, normToValue(ctl.*, knob)))}) catch "?";
        },
    };
}

fn setAutoUiImpl(state: *anyopaque, i: usize, knob: ?f32) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (i >= MAX_CONTROLS) return;
    self.ui_auto[i] = knob;
    // Nothing left to override once the lane is gone.
    if (knob == null) self.auto_override[i].store(0, .monotonic);
}

fn clearOverridesImpl(state: *anyopaque) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    for (&self.auto_override) |*o| o.store(0, .monotonic);
}

fn takeTouchImpl(state: *anyopaque) ?machine.Touch {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const t = self.touch;
    self.touch = null;
    return t;
}

fn takeAutoRequestImpl(state: *anyopaque) ?machine.AutoRequest {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const r = self.auto_request;
    self.auto_request = null;
    return r;
}

// Host param-set (project load): apply one id→value pair. Same real-value
// convention as presets.
fn setParamImpl(state: *anyopaque, id: []const u8, value: f64) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    applyControlValue(self, id, value);
    self.refreshAntialias();
}

// Dump current control values as a JSON object {"id": realValue, ...} into
// `out`. Real values match the preset convention (Hz/sec/option index), so
// presets and embedded project settings share one representation.
fn writeParamsJsonImpl(state: *anyopaque, out: *std.ArrayList(u8), alloc: std.mem.Allocator) anyerror!void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    try out.append(alloc, '{');
    // Control ids are [a-z0-9-] (no JSON-escaping needed); values are finite.
    var buf: [96]u8 = undefined;
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        const value: f64 = switch (ctl.kind) {
            .switch_sel => @floatFromInt(switchIndex(ctl.*, self.controlNorm(i))),
            .int_range => intRangeValue(ctl.*, self.controlNorm(i)),
            .direct_f64 => normToValue(ctl.*, self.controlNorm(i)),
        };
        const sep: []const u8 = if (i > 0) "," else "";
        const frag = std.fmt.bufPrint(&buf, "{s}\"{s}\":{d}", .{ sep, ctl.idSlice(), value }) catch continue;
        try out.appendSlice(alloc, frag);
    }
    try out.append(alloc, '}');
}

// Serialize the current control values to a JSON preset body:
// {"schema":1,"machine":"<id>","params":{"id":value,...}}.
// Control ids are [a-z0-9-] so no JSON escaping is needed.
fn buildPresetContent(self: *FyRawMachine, content: []u8) ?usize {
    var used: usize = 0;
    {
        const head = std.fmt.bufPrint(content[used..], "{{\"schema\":1,\"machine\":\"{s}\",\"params\":{{", .{self.machineId()}) catch return null;
        used += head.len;
    }
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        const value: f64 = switch (ctl.kind) {
            .switch_sel => @floatFromInt(switchIndex(ctl.*, self.controlNorm(i))),
            .int_range => intRangeValue(ctl.*, self.controlNorm(i)),
            .direct_f64 => normToValue(ctl.*, self.controlNorm(i)),
        };
        const sep: []const u8 = if (i > 0) "," else "";
        const frag = std.fmt.bufPrint(content[used..], "{s}\"{s}\":{d}", .{ sep, ctl.idSlice(), value }) catch return null;
        used += frag.len;
    }
    const close = std.fmt.bufPrint(content[used..], "}}", .{}) catch return null;
    used += close.len;
    // Files loaded over the manifest's default go with the preset.
    var first = true;
    for (self.desc.assets[0..self.desc.asset_count], 0..) |*req, ai| {
        if (!self.asset_loaded[ai]) continue;
        const path = self.assetPath(ai);
        if (path.len == 0 or std.mem.indexOfAny(u8, path, "\"\\") != null) continue;
        const frag = std.fmt.bufPrint(content[used..], "{s}\"{s}\":\"{s}\"", .{ if (first) ",\"assets\":{" else ",", req.nameSlice(), path }) catch return null;
        used += frag.len;
        first = false;
    }
    if (!first) {
        const c2 = std.fmt.bufPrint(content[used..], "}}", .{}) catch return null;
        used += c2.len;
    }
    {
        var zl: std.ArrayList(u8) = .empty;
        defer zl.deinit(self.alloc);
        writeZonesJsonImpl(self, &zl, self.alloc) catch return null;
        if (zl.items.len > 0) {
            const zf = std.fmt.bufPrint(content[used..], ",\"zones\":{s}", .{zl.items}) catch return null;
            used += zf.len;
        }
    }
    const tail = std.fmt.bufPrint(content[used..], "}}\n", .{}) catch return null;
    used += tail.len;
    return used;
}

// Rescan the preset directory and re-find `name` as the current preset.
// Returns its sorted index, or null if it didn't reappear.
fn rescanAndSelect(self: *FyRawMachine, name: []const u8) ?machine.PresetIndex {
    self.presets = presets_mod.scan(self.presetDir());
    for (self.presets.names[0..self.presets.count], 0..) |*pn, i| {
        if (std.mem.eql(u8, pn.slice(), name)) {
            self.current_preset_idx = @intCast(i);
            return @intCast(i);
        }
    }
    return null;
}

// Write the current control values to `<name>.preset`, rescan, and select
// it. Returns the new sorted index. Shared by auto- and named-save paths.
fn writePreset(self: *FyRawMachine, name: []const u8) ?machine.PresetIndex {
    if (self.preset_dir_len == 0) return null;
    var content: [presets_mod.MAX_FILE]u8 = undefined;
    const used = buildPresetContent(self, &content) orelse return null;
    if (!presets_mod.writeFile(self.presetDir(), name, content[0..used])) return null;
    return rescanAndSelect(self, name);
}

// Save the current control values as `user-N.preset` (first free N) and
// rescan so the new preset shows up immediately.
fn savePresetImpl(state: *anyopaque) ?machine.PresetIndex {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (self.preset_dir_len == 0) return null;
    var name_buf: [presets_mod.MAX_NAME]u8 = undefined;
    var n: usize = 1;
    const name = blk: while (n < 100) : (n += 1) {
        const candidate = std.fmt.bufPrint(&name_buf, "user-{d}", .{n}) catch return null;
        if (!self.presets.contains(candidate)) break :blk candidate;
    } else return null;
    return writePreset(self, name);
}

// Save under a caller-supplied name. Sanitizes to the preset name limits;
// an empty/oversized name fails. Overwrites an existing preset of the same
// name (the rescan picks up the single file either way).
fn savePresetNamedImpl(state: *anyopaque, name_z: [*:0]const u8) ?machine.PresetIndex {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const name = presetSanitize(std.mem.span(name_z)) orelse return null;
    return writePreset(self, name);
}

// Rename preset `index` to `new_name`: rename the file on disk, rescan, and
// keep it selected. Returns the new sorted index.
fn renamePresetImpl(state: *anyopaque, index: machine.PresetIndex, new_name_z: [*:0]const u8) ?machine.PresetIndex {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (self.preset_dir_len == 0 or index >= self.presets.count) return null;
    const new_name = presetSanitize(std.mem.span(new_name_z)) orelse return null;
    var old_buf: [presets_mod.MAX_NAME]u8 = undefined;
    const old = self.presets.names[index].slice();
    if (old.len > old_buf.len) return null;
    @memcpy(old_buf[0..old.len], old);
    if (!presets_mod.renameFile(self.presetDir(), old_buf[0..old.len], new_name)) return null;
    return rescanAndSelect(self, new_name);
}

// Trim surrounding space and reject empty / oversized / path-bearing names
// (the `/` subdir separator is reserved for factory grouping dirs).
fn presetSanitize(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > presets_mod.MAX_NAME) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '/') != null) return null;
    return trimmed;
}

fn validateWord(host: *FyHost, word: []const u8) !void {
    // Composition (`call:`) words have no value-graph raw body to report —
    // they are validated by compileDsp2CompositionCaller instead.
    if (host.fy.isCompositionWord(word)) return;
    _ = try host.fy.reportDsp2RawWord(word);
}

pub fn normToValue(control: Control, norm: f32) f64 {
    const t = std.math.clamp(@as(f64, norm), 0.0, 1.0);
    return switch (control.curve) {
        .linear => control.min + (control.max - control.min) * t,
        .exp => control.min * @exp(@log(control.max / control.min) * t),
        .pow => control.min + (control.max - control.min) * t * t,
    };
}

fn valueToNorm(control: Control, value: f64) f32 {
    const v = std.math.clamp(value, control.min, control.max);
    const t = switch (control.curve) {
        .linear => (v - control.min) / (control.max - control.min),
        .exp => @log(v / control.min) / @log(control.max / control.min),
        .pow => @sqrt((v - control.min) / (control.max - control.min)),
    };
    return @floatCast(std.math.clamp(t, 0.0, 1.0));
}

fn switchIndex(control: Control, raw: f32) usize {
    if (control.option_count == 0) return 0;
    const r = @round(@as(f64, raw));
    const hi: f64 = @floatFromInt(control.option_count - 1);
    return @intFromFloat(std.math.clamp(r, 0, hi));
}

// Number of selectable steps in an int_range control (max - min + 1).
fn intRangeCount(control: Control) usize {
    return @intFromFloat(@round(control.max - control.min) + 1);
}

// The int_range param value: the stored raw rounded and clamped to [min, max].
fn intRangeValue(control: Control, raw: f32) f64 {
    return std.math.clamp(@round(@as(f64, raw)), control.min, control.max);
}

fn renderImpl(state: *anyopaque, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    const frames = @min(@as(usize, @intCast(ctx.block_size)), @min(l.len, @min(r.len, MAX_BLOCK)));
    if (frames == 0) return;

    fy_host_mod.lockCallbacks();
    defer fy_host_mod.unlockCallbacks();
    Fy.Builtins.fyPtr = @intFromPtr(&self.host.fy);

    self.kctx.beat = ctx.ppq_position;
    self.kctx.frames = @floatFromInt(frames);
    self.kctx.sr = ctx.sample_rate;

    // Steady knobs: one pass. Gliding or automated knobs: sub-blocks with
    // params re-synced between them; prepare still runs once per block (it
    // may reset per-block accumulators such as meters).
    const view: ?*const snapshot.AutoView = if (ctx.automation) |p| @ptrCast(@alignCast(p)) else null;
    const auto = if (view) |v| v.any() else false;
    if (!auto) @memset(self.auto_on[0..], false);
    const gliding = auto or self.anyGliding();
    const chunk: usize = if (gliding) SMOOTH_CHUNK else frames;
    const beats_per_sample = ctx.tempo_bpm / (60.0 * ctx.sample_rate);
    var pos: usize = 0;
    while (pos < frames) : (pos += chunk) {
        const n = @min(chunk, frames - pos);
        if (auto) self.evalAutomation(view.?, ctx.ppq_position + @as(f64, @floatFromInt(pos)) * beats_per_sample);
        _ = self.advanceSmoothing(if (gliding) n else frames);
        self.syncRawParams(ctx.sample_rate, ctx.tempo_bpm);
        if (pos == 0) callPrepare(self, ctx.sample_rate) catch {
            self.failed = true;
            @memset(l[0..frames], 0);
            @memset(r[0..frames], 0);
            return;
        };
        var ev_buf: [256]machine.NoteEvent = undefined;
        var ports: [4][*]const f32 = undefined;
        const sub = subCtx(ctx, pos, n, &ev_buf, &ports);
        const ok = switch (self.desc.mode) {
            .voice_sample => renderVoiceSample(self, &sub, l[pos .. pos + n], r[pos .. pos + n]),
            .effect_block => renderEffectBlock(self, &sub, l[pos .. pos + n], r[pos .. pos + n]),
        };
        ok catch {
            self.failed = true;
            @memset(l[0..frames], 0);
            @memset(r[0..frames], 0);
            return;
        };
    }
    if (self.desc.mode == .voice_sample) self.updateIdle();
}

/// A view of `ctx` covering frames [pos, pos+n): events re-based into the
/// window, audio inputs offset. Whole-block calls get `ctx` back unchanged.
fn subCtx(ctx: *const machine.MachineCtx, pos: usize, n: usize, ev_buf: *[256]machine.NoteEvent, ports: *[4][*]const f32) machine.MachineCtx {
    var sub = ctx.*;
    sub.block_size = @intCast(n);
    if (pos == 0 and n == ctx.block_size) return sub;
    var count: usize = 0;
    if (ctx.note_in) |evs| for (evs[0..ctx.note_in_count]) |e| {
        const at: usize = e.sample_offset;
        const last = pos + n == ctx.block_size; // late offsets land in the final window
        if ((at >= pos and at < pos + n) or (last and at >= pos + n)) {
            if (count == ev_buf.len) break;
            ev_buf[count] = e;
            ev_buf[count].sample_offset = @intCast(@min(at, pos + n - 1) - pos);
            count += 1;
        }
    };
    sub.note_in = if (count > 0) ev_buf else null;
    sub.note_in_count = @intCast(count);
    if (ctx.audio_in_count >= 2) if (ctx.audio_in) |p| {
        // In L/R, and the sidechain key L/R when there is one (docs/23).
        const k: usize = @min(ctx.audio_in_count, 4);
        for (ports[0..k], p[0..k]) |*d, src| d.* = src + pos;
        sub.audio_in = ports;
    };
    return sub;
}

fn callPrepare(self: *FyRawMachine, sample_rate: f64) !void {
    const caller = if (self.prepare_caller) |*c_| c_ else return;
    // Prepare runs once per state region: per channel for effects, per
    // voice for polyphonic machines.
    _ = sample_rate; // already in kctx.sr (syncRawParams)
    for (0..self.regionCount()) |reg| _ = try caller.call(1, &self.entryArgs(reg));
}

fn renderVoiceSample(self: *FyRawMachine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) !void {
    for (self.io[0..l.len]) |*f| {
        f.out_l = 0;
        f.out_r = 0;
    }

    const events = if (ctx.note_in) |p| p[0..ctx.note_in_count] else &[_]machine.NoteEvent{};
    var cursor: usize = 0;
    var event_index: usize = 0;
    while (cursor < l.len) {
        const next_event_sample = if (event_index < events.len)
            @min(@as(usize, @intCast(events[event_index].sample_offset)), l.len)
        else
            l.len;

        if (next_event_sample > cursor) {
            try renderVoiceSegment(self, cursor, next_event_sample);
            cursor = next_event_sample;
        }

        while (event_index < events.len and @min(@as(usize, @intCast(events[event_index].sample_offset)), l.len) == cursor) : (event_index += 1) {
            try applyNoteEvent(self, events[event_index]);
        }
    }

    // No clamp: machines have headroom (docs/17 D5); only the master bus
    // soft-clips.
    if (self.desc.stereo) {
        for (l, r, self.io[0..l.len]) |*sl, *sr, f| {
            sl.* = @floatCast(f.out_l);
            sr.* = @floatCast(f.out_r);
        }
        return;
    }
    for (l, r, self.io[0..l.len]) |*sl, *sr, f| {
        const y: f32 = @floatCast(f.out_l);
        sl.* = y;
        sr.* = y;
    }
}

fn renderVoiceSegment(self: *FyRawMachine, start: usize, end: usize) !void {
    if (end <= start) return;
    const caller = if (self.render_caller) |*c_| c_ else return error.UnknownWord;
    // Polyphonic machines render every voice every block (Juno-style — no
    // freeing, silent voices are cheap and predictable); kernels of
    // multi-voice machines ACCUMULATE into the host-zeroed out buffer.
    const io = self.io[start..end];
    for (0..self.regionCount()) |voice| {
        if (self.voice_idle[voice]) continue;
        const snap = self.voice_snap[start..end];
        for (snap, io) |*d, f| d.* = f.out_l;
        const e = self.entryArgs(voice);
        const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&io[0]) }, e[0], e[1], e[2] };
        _ = try caller.call(@intCast(end - start), &args);
        var pk = self.voice_peak[voice];
        for (snap, io) |b, f| pk = @max(pk, @abs(f.out_l - b));
        self.voice_peak[voice] = pk;
    }
}

fn applyNoteEvent(self: *FyRawMachine, ev: machine.NoteEvent) !void {
    switch (ev.kind) {
        .note_on => {
            if (ev.velocity <= 0) {
                try noteOffEvent(self, ev);
            } else {
                try noteOnEvent(self, ev);
            }
        },
        .note_off => try noteOffEvent(self, ev),
        .expression => try noteExprEvent(self, ev),
        .reset => {
            self.mono_held_n = 0;
            for (0..self.regionCount()) |voice| {
                self.voice_gate[voice] = false;
                try callNoteOff(self, voice);
            }
        },
        else => {},
    }
}

// Pick a voice: an idle one (oldest first), else the oldest released one
// still ringing, else steal the oldest held one.
fn allocVoice(self: *FyRawMachine) usize {
    const n = self.regionCount();
    const Pass = enum { idle, released, any };
    for ([_]Pass{ .idle, .released, .any }) |pass| {
        var best: ?usize = null;
        var best_age: u64 = std.math.maxInt(u64);
        for (0..n) |v| {
            const ok = switch (pass) {
                .idle => self.voice_idle[v],
                .released => !self.voice_gate[v],
                .any => true,
            };
            if (ok and self.voice_age[v] < best_age) {
                best = v;
                best_age = self.voice_age[v];
            }
        }
        if (best) |b| return b;
    }
    return 0;
}

fn isMonoMelodic(self: *const FyRawMachine) bool {
    return self.regionCount() == 1 and !self.desc.note_pitch;
}

/// Whether event `ev` refers to a note played as (pitch, id): by id when
/// both sides have one, else by pitch.
fn sameNote(pitch: f32, id: i32, ev: machine.NoteEvent) bool {
    if (ev.note_id >= 0 and id >= 0) return id == ev.note_id;
    return pitch == ev.pitch;
}

fn monoForget(self: *FyRawMachine, ev: machine.NoteEvent) void {
    var w: usize = 0;
    for (self.mono_held[0..self.mono_held_n], self.mono_held_id[0..self.mono_held_n]) |p, id| {
        if (sameNote(p, id, ev)) continue;
        self.mono_held[w] = p;
        self.mono_held_id[w] = id;
        w += 1;
    }
    self.mono_held_n = w;
}

fn noteOnEvent(self: *FyRawMachine, ev: machine.NoteEvent) !void {
    if (isMonoMelodic(self)) {
        monoForget(self, ev);
        if (self.mono_held_n == self.mono_held.len) {
            std.mem.copyForwards(f32, self.mono_held[0 .. self.mono_held.len - 1], self.mono_held[1..]);
            std.mem.copyForwards(i32, self.mono_held_id[0 .. self.mono_held_id.len - 1], self.mono_held_id[1..]);
            self.mono_held_n -= 1;
        }
        self.mono_held[self.mono_held_n] = ev.pitch;
        self.mono_held_id[self.mono_held_n] = ev.note_id;
        self.mono_held_n += 1;
    }
    // Legato: a note arriving while the voice is still held (mono slide).
    self.kctx.legato = if (isMonoMelodic(self) and self.voice_gate[0]) 1 else 0;
    const voice = allocVoice(self);
    self.age_counter += 1;
    self.voice_age[voice] = self.age_counter;
    self.voice_pitch[voice] = ev.pitch;
    self.voice_note_id[voice] = ev.note_id;
    self.voice_gate[voice] = true;
    self.voice_idle[voice] = false;
    self.voice_peak[voice] = 0;
    // note-pitch machines (drums) address slots by raw MIDI pitch.
    const note_arg = if (self.desc.note_pitch) @as(f64, ev.pitch) else midiToHz(ev.pitch);
    self.kctx.pitch = ev.pitch;
    try callNoteOn(self, voice, note_arg, ev.velocity);
    self.kctx.legato = 0;
}

// note_id is -1 throughout the sequencer, so note-off matches the newest
// gated voice holding this pitch. Mono machines just release voice 0.
fn noteOffEvent(self: *FyRawMachine, ev: machine.NoteEvent) !void {
    const n = self.regionCount();
    if (isMonoMelodic(self)) {
        monoForget(self, ev);
        // Releasing a note that isn't sounding just forgets it.
        if (!self.voice_gate[0] or !sameNote(self.voice_pitch[0], self.voice_note_id[0], ev)) return;
        if (self.mono_held_n > 0) {
            // Fall back to the newest held note, legato.
            const back = self.mono_held[self.mono_held_n - 1];
            self.voice_pitch[0] = back;
            self.voice_note_id[0] = self.mono_held_id[self.mono_held_n - 1];
            self.kctx.legato = 1;
            self.kctx.pitch = back;
            try callNoteOn(self, 0, midiToHz(back), self.kctx.vel);
            self.kctx.legato = 0;
            return;
        }
        self.voice_gate[0] = false;
        try callNoteOff(self, 0);
        return;
    }
    if (n == 1) {
        self.voice_gate[0] = false;
        try callNoteOff(self, 0);
        return;
    }
    var found: ?usize = null;
    var newest: u64 = 0;
    for (0..n) |v| {
        if (!self.voice_gate[v]) continue;
        if (!sameNote(self.voice_pitch[v], self.voice_note_id[v], ev)) continue;
        if (self.voice_age[v] >= newest) {
            newest = self.voice_age[v];
            found = v;
        }
    }
    if (found) |v| {
        self.voice_gate[v] = false;
        try callNoteOff(self, v);
    }
}

/// Per-note expression (docs/22 §Note expression): retune the voice that
/// plays `ev.note_id` to `ev.pitch` through the machine's `note-expr`
/// word. Machines without one ignore it.
fn noteExprEvent(self: *FyRawMachine, ev: machine.NoteEvent) !void {
    const caller = if (self.note_expr_caller) |*c_| c_ else return;
    if (ev.note_id < 0 or self.desc.note_pitch) return;
    for (0..self.regionCount()) |v| {
        if (self.voice_note_id[v] != ev.note_id) continue;
        self.kctx.pitch = ev.pitch;
        self.kctx.hz = midiToHz(ev.pitch);
        self.kctx.pressure = ev.pressure;
        self.kctx.slide = ev.slide;
        self.kctx.gain = std.math.pow(f64, 10, @as(f64, ev.value) / 20);
        _ = try caller.call(1, &self.entryArgs(v));
    }
}

fn callNoteOn(self: *FyRawMachine, voice: usize, hz: f64, velocity: f64) !void {
    const caller = if (self.note_on_caller) |*c_| c_ else return;
    self.kctx.hz = hz;
    self.kctx.vel = velocity;
    _ = try caller.call(1, &self.entryArgs(voice));
}

fn callNoteOff(self: *FyRawMachine, voice: usize) !void {
    const caller = if (self.note_off_caller) |*c_| c_ else return;
    _ = try caller.call(1, &self.entryArgs(voice));
}

fn renderEffectBlock(self: *FyRawMachine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) !void {
    const caller = if (self.render_caller) |*c_| c_ else return error.UnknownWord;
    const in_l, const in_r = inputChannels(ctx);
    const key = keyChannels(ctx);
    const io = self.io[0..l.len];
    for (io, 0..) |*f, i| {
        f.in_l = if (in_l) |p| p[i] else 0;
        f.in_r = if (in_r) |p| p[i] else f.in_l;
        // A sidechain key drives the detector instead of the input.
        f.sc_l = if (key) |kp| kp[0][i] else f.in_l;
        f.sc_r = if (key) |kp| kp[1][i] else f.in_r;
        f.det = @max(@abs(f.sc_l), @abs(f.sc_r));
    }
    if (self.desc.stereo) {
        // True stereo: one pass sees both inputs and writes both outputs.
        const e = self.entryArgs(0);
        const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&io[0]) }, e[0], e[1], e[2] };
        _ = try caller.call(l.len, &args);
        for (l, r, io) |*dl, *dr, f| {
            dl.* = @floatCast(f.out_l);
            dr.* = @floatCast(f.out_r);
        }
        return;
    }
    // Dual-mono lanes: each channel pass sees its input in in_l and writes
    // out_l, against its own state region (ctx.chan = channel).
    const outs = [2][]f32{ l, r };
    for (outs, 0..) |dst, ch| {
        if (ch == 1) for (io) |*f| std.mem.swap(f64, &f.in_l, &f.in_r);
        const e = self.entryArgs(ch);
        const args = [_]Fy.Dsp2RawArg{ .{ .ptr = @intFromPtr(&io[0]) }, e[0], e[1], e[2] };
        _ = try caller.call(l.len, &args);
        for (dst, io) |*d, f| d.* = @floatCast(f.out_l); // no clamp (D5)
    }
}

/// The sidechain key pair (ports 2 and 3), when the host sent one.
fn keyChannels(ctx: *const machine.MachineCtx) ?[2][*]const f32 {
    if (ctx.audio_in_count >= 4) if (ctx.audio_in) |ports| return .{ ports[2], ports[3] };
    return null;
}

fn inputChannels(ctx: *const machine.MachineCtx) struct { ?[*]const f32, ?[*]const f32 } {
    if (ctx.audio_in_count >= 2) {
        if (ctx.audio_in) |ports| return .{ ports[0], ports[1] };
    }
    return .{ null, null };
}

fn resetImpl(state: *anyopaque) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    for (0..self.regionCount()) |reg| {
        @memset(self.state_buf[reg * MAX_STATE ..][0..self.desc.state_size], 0);
    }
    @memset(self.voice_gate[0..], false);
    @memset(self.voice_pitch[0..], -1);
    @memset(self.voice_note_id[0..], -1);
    @memset(self.voice_idle[0..], true);
    self.mono_held_n = 0;
    @memset(self.params_buf[0..self.desc.params_size], 0);
    for (self.buffer_mem[0..self.desc.buffer_count]) |pair| {
        for (pair) |mem| @memset(mem, 0);
    }
    self.injectBuffers();
    self.injectAssets(); // params were memset; restore the asset pointers
    self.failed = false;
}

fn deinitImpl(state: *anyopaque, alloc: std.mem.Allocator) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    self.freeBuffersUpTo(alloc, self.desc.buffer_count);
    self.freeAssets(alloc);
    // derive-data is libc-malloc'd by fy's `alloc`; fy doesn't track it.
    if (self.desc.derive_data != 0) std.c.free(@ptrFromInt(self.desc.derive_data));
    self.host.deinit();
    alloc.destroy(self.host);
    alloc.destroy(self);
}

// Generic machine panel body on the new UI core (docs/06, docs/15): packed
// module strips laid out from the descriptor. The bay draws the title bar
// (host_titlebar = true), so `rect` is the body below it. The whole panel
// uses one knob size tier: the largest at which every strip fits.
fn drawPanelImpl(state: *anyopaque, ui: *Ui, rect: Rect) void {
    const self: *FyRawMachine = @ptrCast(@alignCast(state));
    if (rect.empty()) return;
    ui.pushId(self);
    defer ui.popId();
    if (self.desc.control_count == 0) {
        drawFixtureInfo(self, ui, rect);
        return;
    }
    const tier = chooseTier(self, ui, rect);
    _ = walkPanel(self, ui, rect, .{ .draw = tier });
    autoMenuTick(self);
    // a stored rate moved: re-filter once the knob is let go
    if (ui.active == 0) self.refreshAntialias();
}

fn drawFixtureInfo(self: *FyRawMachine, ui: *Ui, r: Rect) void {
    var body = ui.plate(r, .{}).insetXY(4, 2);
    const mode_text: []const u8 = switch (self.desc.mode) {
        .voice_sample => "RAW VOICE/SAMPLE",
        .effect_block => "RAW EFFECT/BLOCK",
    };
    _ = ui.engraved(&ui.fonts.legend, body.x, body.cutTop(14).y, mode_text, ui_style.text_dim);
    const name = self.desc.nameSlice();
    const detail: []const u8 = if (std.mem.eql(u8, name, "raw-osc"))
        "saw osc  note in"
    else if (std.mem.eql(u8, name, "raw-sat"))
        "rational tanh  drive 1.35"
    else if (std.mem.eql(u8, name, "raw-silence"))
        "zero output"
    else
        "dsp fixture";
    _ = ui.text(&ui.fonts.body, body.x, body.cutTop(18).y, detail, ui_style.text);
    ui_ctl.display(ui, body.cutTop(ui_ctl.displayHeight(false)).takeLeft(@min(body.w, 160)), if (self.failed) "FAILED" else "LIVE", .{ .color = if (self.failed) ui_style.rec else ui_style.vfd });
}

const StripView = struct {
    title: []const u8,
    module: []const u8,
    cols: usize,
};

// Strips come from descriptor `strip` declarations if present, else are
// derived as one column per distinct module in control order.
fn collectStrips(self: *FyRawMachine, out: *[MAX_STRIPS]StripView) usize {
    if (self.desc.strip_count > 0) {
        for (self.desc.strips[0..self.desc.strip_count], 0..) |*s, i| {
            out[i] = .{ .title = s.moduleSlice(), .module = s.moduleSlice(), .cols = s.cols };
        }
        return self.desc.strip_count;
    }
    var n: usize = 0;
    for (self.desc.controls[0..self.desc.control_count]) |*ctl| {
        const m = ctl.moduleSlice();
        var found = false;
        for (out[0..n]) |ex| {
            if (std.mem.eql(u8, ex.module, m)) {
                found = true;
                break;
            }
        }
        if (!found and n < MAX_STRIPS) {
            out[n] = .{ .title = m, .module = m, .cols = 1 };
            n += 1;
        }
    }
    return n;
}

fn stripViewAt(self: *const FyRawMachine, idx: usize) StripView {
    const s = &self.desc.strips[idx];
    return .{ .title = s.moduleSlice(), .module = s.moduleSlice(), .cols = s.cols };
}

fn controlNormByLabel(self: *const FyRawMachine, module: []const u8, label: []const u8) ?f32 {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.moduleSlice(), module) and
            std.mem.eql(u8, ctl.label[0..ctl.label_len], label))
            return self.shownNorm(i);
    }
    return null;
}

// Capacitor charge/discharge easing toward a target: fast then slow, used for
// every ADSR segment (matches the cap-discharge envelope). shape(0)=0, shape(1)=1.
fn capShape(t: f32) f32 {
    const k: f32 = 4.0;
    return (1.0 - @exp(-k * t)) / (1.0 - @exp(-k));
}

// ── Layout: one walk for fitting and drawing ─────────────────────────

const PanelPass = union(enum) {
    /// Check whether every strip fits at this tier; draws nothing.
    fit: ui_ctl.Size,
    draw: ui_ctl.Size,

    fn tier(p: PanelPass) ui_ctl.Size {
        return switch (p) {
            inline else => |t| t,
        };
    }
};

const TAB_BAR_H: i32 = 20;
const STRIP_HEAD: i32 = 14; // legend line + 2px, see ui_ctl.strip
const STRIP_PAD: i32 = 4; // between the strip title and its controls
const ROW_GAP: i32 = 4; // between rows of a strip's controls

/// Largest tier at which every strip's control grid fits its rect.
fn chooseTier(self: *FyRawMachine, ui: *Ui, body: Rect) ui_ctl.Size {
    for ([_]ui_ctl.Size{ .l, .m, .s }) |t| {
        if (walkPanel(self, ui, body, .{ .fit = t })) return t;
    }
    return .s;
}

/// Pages → tab bar + that page's rows; a row tree → rows; else strips side
/// by side. Returns false (fit pass) as soon as a strip doesn't fit.
fn walkPanel(self: *FyRawMachine, ui: *Ui, body: Rect, pass: PanelPass) bool {
    var area = body;
    if (self.desc.page_count > 0) {
        if (self.ui_tab >= self.desc.page_count) self.ui_tab = 0;
        const bar = area.cutTop(TAB_BAR_H);
        if (pass == .draw) drawTabBar(self, ui, bar);
        const pg = &self.desc.pages[self.ui_tab];
        return walkRows(self, ui, pg.rows[0..pg.row_count], area, pass);
    }
    if (self.desc.row_count > 0) return walkRows(self, ui, self.desc.rows[0..self.desc.row_count], area, pass);

    // No row tree: strips side by side, natural widths plus an equal share
    // of the slack.
    var strips: [MAX_STRIPS]StripView = undefined;
    const n = collectStrips(self, &strips);
    const tier = pass.tier();
    var sum_w: i32 = 0;
    for (strips[0..n]) |sv| {
        const nat = stripNatural(self, ui, sv, tier);
        sum_w += nat[0];
        if (pass == .fit and nat[1] > area.h) return false;
    }
    if (pass == .fit) return sum_w <= area.w;
    var used: i32 = 0;
    for (strips[0..n], 0..) |sv, i| {
        const w = portion(area.w, sum_w, stripNatural(self, ui, sv, tier)[0], 1, @floatFromInt(n), i + 1 == n, used);
        _ = walkStrip(self, ui, Rect.xywh(area.x + used, area.y, w, area.h), sv, pass);
        used += w;
    }
    return true;
}

// Natural-size box layout (docs/15 §Tiers and natural size): every row,
// cell and stacked item first gets its natural size at the tier; only the
// space beyond that is shared out by weight. A tier fits when the natural
// sizes fit the body.

/// Displays have no intrinsic size; they take weight-shared space above a
/// floor that keeps a curve readable.
const DISPLAY_MIN = [2]i32{ 40, 32 };
/// An operator graph needs room for its widest and tallest algorithm.
const ALGO_MIN = [2]i32{ 112, 96 };

fn stripNatural(self: *const FyRawMachine, ui: *const Ui, view: StripView, tier: ui_ctl.Size) [2]i32 {
    const t = stripTable(self, ui, view, tier);
    if (t.rows == 0) return .{ 0, STRIP_HEAD + 3 };
    // Plate: right/bottom seam + 1px bevel all round, then the header.
    return .{ t.width() + 3, t.height() + 3 + STRIP_HEAD + STRIP_PAD };
}

fn itemNatural(self: *const FyRawMachine, ui: *const Ui, it: machine_desc.LayoutItem, tier: ui_ctl.Size) [2]i32 {
    if (!it.is_display) return stripNatural(self, ui, stripViewAt(self, it.index), tier);
    return if (self.desc.displays[it.index].kind == .algo) ALGO_MIN else DISPLAY_MIN;
}

/// A cell stacks its items: width = widest, height = sum.
fn cellNatural(self: *const FyRawMachine, ui: *const Ui, cc: *const machine_desc.LayoutCell, tier: ui_ctl.Size) [2]i32 {
    var n = [2]i32{ 0, 0 };
    for (cc.items[0..cc.item_count]) |it| {
        const s = itemNatural(self, ui, it, tier);
        n[0] = @max(n[0], s[0]);
        n[1] += s[1];
    }
    return n;
}

/// A row places cells side by side: width = sum, height = tallest.
fn rowNatural(self: *const FyRawMachine, ui: *const Ui, r: *const machine_desc.LayoutRow, tier: ui_ctl.Size) [2]i32 {
    var n = [2]i32{ 0, 0 };
    for (r.cells[0..r.cell_count]) |*cc| {
        const s = cellNatural(self, ui, cc, tier);
        n[0] += s[0];
        n[1] = @max(n[1], s[1]);
    }
    return n;
}

/// Size of part `i` along one axis: its natural size plus a weighted share
/// of the slack; the last part takes the remainder so the parts tile.
fn portion(total: i32, sum_nat: i32, nat: i32, w: f32, sum_w: f32, last: bool, used: i32) i32 {
    if (last) return @max(0, total - used);
    const slack = @max(0, total - sum_nat);
    const extra: i32 = if (sum_w > 0) @intFromFloat(@floor(@as(f32, @floatFromInt(slack)) * w / sum_w)) else 0;
    return nat + extra;
}

fn walkRows(self: *FyRawMachine, ui: *Ui, rows: []const machine_desc.LayoutRow, body: Rect, pass: PanelPass) bool {
    const tier = pass.tier();
    var sum_h: i32 = 0;
    var sum_rw: f32 = 0;
    for (rows) |*r| {
        const n = rowNatural(self, ui, r, tier);
        if (pass == .fit and n[0] > body.w) return false;
        sum_h += n[1];
        sum_rw += r.weight;
    }
    if (pass == .fit) return sum_h <= body.h;

    var used_h: i32 = 0;
    for (rows, 0..) |*r, ri| {
        const rh = portion(body.h, sum_h, rowNatural(self, ui, r, tier)[1], r.weight, sum_rw, ri + 1 == rows.len, used_h);
        const row = Rect.xywh(body.x, body.y + used_h, body.w, rh);
        used_h += rh;

        var sum_w: i32 = 0;
        var sum_cw: f32 = 0;
        for (r.cells[0..r.cell_count]) |*cc| {
            sum_w += cellNatural(self, ui, cc, tier)[0];
            sum_cw += cc.weight;
        }
        var used_w: i32 = 0;
        for (r.cells[0..r.cell_count], 0..) |*cc, ci| {
            const cw = portion(row.w, sum_w, cellNatural(self, ui, cc, tier)[0], cc.weight, sum_cw, ci + 1 == r.cell_count, used_w);
            const col = Rect.xywh(row.x + used_w, row.y, cw, row.h);
            used_w += cw;

            var sum_ih: i32 = 0;
            var sum_iw: f32 = 0;
            for (cc.items[0..cc.item_count]) |it| {
                sum_ih += itemNatural(self, ui, it, tier)[1];
                sum_iw += it.weight;
            }
            var used_s: i32 = 0;
            for (cc.items[0..cc.item_count], 0..) |it, ii| {
                const sh = portion(col.h, sum_ih, itemNatural(self, ui, it, tier)[1], it.weight, sum_iw, ii + 1 == cc.item_count, used_s);
                const item = Rect.xywh(col.x, col.y + used_s, col.w, sh);
                used_s += sh;
                if (it.is_display) {
                    drawDisplay(self, ui, item, &self.desc.displays[it.index]);
                } else _ = walkStrip(self, ui, item, stripViewAt(self, it.index), pass);
            }
        }
    }
    return true;
}

fn walkStrip(self: *FyRawMachine, ui: *Ui, r: Rect, view: StripView, pass: PanelPass) bool {
    // Fitting is decided on natural sizes (walkRows / walkPanel); here we
    // only draw.
    if (pass == .draw) drawStrip(self, ui, r, view, pass.draw);
    return true;
}

fn drawTabBar(self: *FyRawMachine, ui: *Ui, bar: Rect) void {
    const n = @min(self.desc.page_count, 16);
    var names: [16][]const u8 = undefined;
    for (self.desc.pages[0..n], 0..) |*pg, i| names[i] = std.mem.span(pg.nameZ());
    var tab: u8 = @intCast(self.ui_tab);
    if (ui_ctl.segmentedFlush(ui, bar, "tabs", &tab, names[0..n])) self.ui_tab = tab;
}

fn drawStrip(self: *FyRawMachine, ui: *Ui, r: Rect, view: StripView, tier: ui_ctl.Size) void {
    const body = ui_ctl.strip(ui, r, view.title);
    const t = stripTable(self, ui, view, tier);
    if (t.rows == 0 or body.empty()) return;
    ui.clip(body);
    defer ui.unclip();
    var grid = body;
    _ = grid.cutTop(STRIP_PAD);
    // Horizontal slack is shared evenly between columns; rows stack from
    // the top at their natural pitch, so rows of equal height line up
    // across strips. A control keeps its natural size, centred across its
    // column and at the top of its row. Below the smallest tier the strip
    // clips instead of overlapping controls (docs/06 §Sizing).
    const cols: i32 = @intCast(t.cols);
    const slack_w = @max(0, grid.w - t.width());
    var col_x: [MAX_CONTROLS + 1]i32 = undefined;
    col_x[0] = grid.x;
    for (0..t.cols) |ci| {
        const k: i32 = @intCast(ci);
        col_x[ci + 1] = col_x[ci] + t.col_w[ci] + @divFloor(slack_w * (k + 1), cols) - @divFloor(slack_w * k, cols);
    }
    var row_y: [MAX_CONTROLS + 1]i32 = undefined;
    row_y[0] = grid.y;
    for (0..t.rows) |ri| row_y[ri + 1] = row_y[ri] + t.row_h[ri] + ROW_GAP;
    var local_i: usize = 0;
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, gi| {
        if (!std.mem.eql(u8, ctl.moduleSlice(), view.module)) continue;
        const ci = local_i % t.cols;
        const ri = local_i / t.cols;
        local_i += 1;
        const nat = controlCell(ui, ctl, tier);
        const cell_w = col_x[ci + 1] - col_x[ci];
        drawAutomatable(self, ui, Rect.xywh(col_x[ci] + @divFloor(cell_w - nat[0], 2), row_y[ri], nat[0], nat[1]), gi, ctl, tier);
    }
}

/// A strip's controls as a table: `cols` per row, each column as wide as
/// its widest control and each row as tall as its tallest, at the tier's
/// natural sizes.
const StripTable = struct {
    col_w: [MAX_CONTROLS]i32 = [_]i32{0} ** MAX_CONTROLS,
    row_h: [MAX_CONTROLS]i32 = [_]i32{0} ** MAX_CONTROLS,
    cols: usize = 0,
    rows: usize = 0,

    fn width(t: *const StripTable) i32 {
        var w: i32 = 0;
        for (t.col_w[0..t.cols]) |cw| w += cw;
        return w;
    }

    fn height(t: *const StripTable) i32 {
        var h: i32 = 0;
        for (t.row_h[0..t.rows]) |rh| h += rh;
        return h + ROW_GAP * @as(i32, @intCast(t.rows -| 1));
    }
};

fn stripTable(self: *const FyRawMachine, ui: *const Ui, view: StripView, tier: ui_ctl.Size) StripTable {
    var t = StripTable{};
    const cols: usize = @max(view.cols, 1);
    var n: usize = 0;
    for (self.desc.controls[0..self.desc.control_count]) |*ctl| {
        if (!std.mem.eql(u8, ctl.moduleSlice(), view.module)) continue;
        const nat = controlCell(ui, ctl, tier);
        t.col_w[n % cols] = @max(t.col_w[n % cols], nat[0]);
        t.row_h[n / cols] = @max(t.row_h[n / cols], nat[1]);
        n += 1;
    }
    t.cols = @min(n, cols);
    t.rows = (n + cols - 1) / cols;
    return t;
}

fn optionSlices(ctl: *const Control, buf: *[MAX_OPTS][]const u8) []const []const u8 {
    for (0..ctl.option_count) |i| buf[i] = std.mem.span(ctl.optionLabelZ(i));
    return buf[0..ctl.option_count];
}

/// Integer-range labels for a display select, "min".."max".
const IntLabels = struct {
    text: [machine_desc.MAX_DISPLAY_STEPS][6]u8 = undefined,
    slices: [machine_desc.MAX_DISPLAY_STEPS][]const u8 = undefined,

    fn fill(l: *IntLabels, ctl: *const Control) []const []const u8 {
        const lo: i64 = @intFromFloat(@round(ctl.min));
        const n = @min(intRangeCount(ctl.*), machine_desc.MAX_DISPLAY_STEPS);
        for (0..n) |i| l.slices[i] = std.fmt.bufPrint(&l.text[i], "{d}", .{lo + @as(i64, @intCast(i))}) catch "?";
        return l.slices[0..n];
    }
};

/// Natural cell of a control's widget at a tier.
fn controlCell(ui: *const Ui, ctl: *const Control, tier: ui_ctl.Size) [2]i32 {
    var ob: [MAX_OPTS][]const u8 = undefined;
    const opts = optionSlices(ctl, &ob);
    const label = ctl.label[0..ctl.label_len];
    return switch (ctl.widgetFor()) {
        .auto, .knob => ui_ctl.knobCell(tier, false),
        .fader => ui_ctl.faderCell(ui, tier, label),
        .lever => ui_ctl.toggleCell(ui, .{ .positions = @intCast(opts.len), .label = label, .marks = opts }),
        .slide => ui_ctl.slideCell(ui, .{ .positions = @intCast(opts.len), .label = label, .marks = opts }),
        .list => ui_ctl.listCell(ui, opts),
        .radio, .vradio => |w| ui_ctl.radioCell(ui, opts, .{ .size = tier, .label = label, .vertical = w == .vradio }),
        .button => ui_ctl.latchCell(ui, .{ .size = tier, .label = label }),
        .display => blk: {
            var il: IntLabels = .{};
            break :blk ui_ctl.displayFieldCell(ui, if (ctl.kind == .int_range) il.fill(ctl) else opts);
        },
    };
}

/// One control plus its automation state (docs/22 §Automated controls): it
/// draws the automated value, a hand change overrides the lane (held drags
/// until release, other edits until the transport starts), and the LED at
/// the end of its legend shows the state; clicking a hollow LED re-enables.
fn drawAutomatable(self: *FyRawMachine, ui: *Ui, kr: Rect, gi: usize, ctl: *const Control, tier: ui_ctl.Size) void {
    const base_before = self.controlNorm(gi);
    const was_pressed = ui.in.pressed;
    drawControl(self, ui, kr, gi, ctl, tier);
    const wid = ui.id(gi);
    if (ui.active == wid) self.touch = .{ .control = @intCast(gi), .knob = self.controlNorm(gi) };
    // Right-click a control (any widget: the whole cell): the automation
    // menu, ticked in drawPanelImpl.
    if (ui.in.right_pressed and kr.contains(ui.in.ix(), ui.in.iy()) and !ui_menu.active()) {
        self.ctx_control = gi;
        ui_menu.openAt(autoMenuKey(self), ui.in.ix(), ui.in.iy());
    }
    if (self.ui_auto[gi] == null) return;
    // The title display's value channel says the value isn't all yours.
    if (ui.isHot(wid) and ui.touch.time == ui.in.time) ui.touch.automated = true;
    const ov = &self.auto_override[gi];
    const held = ui.active == wid;
    if (self.controlNorm(gi) != base_before) {
        ov.store(if (held and !was_pressed) 1 else 2, .monotonic);
    } else if (ov.load(.monotonic) == 1 and !held) {
        ov.store(0, .monotonic);
    }
    const overridden = ov.load(.monotonic) != 0;
    const led_at = ui_ctl.autoLedPos(ui, kr, ctl.label[0..ctl.label_len]);
    if (ui_ctl.autoLed(ui, led_at[0], led_at[1], .{ "auto", gi }, overridden)) {
        if (overridden) ov.store(0, .monotonic) else self.auto_request = .{ .control = @intCast(gi), .action = .show };
    }
}

fn autoMenuKey(self: *const FyRawMachine) u64 {
    return @as(u64, @intFromPtr(self)) ^ 0xA070_A070_0000_0001;
}

const AUTO_SHOW: u32 = 1;
const AUTO_CLEAR: u32 = 2;
const AUTO_REENABLE: u32 = 3;

/// The per-control automation context menu.
fn autoMenuTick(self: *FyRawMachine) void {
    const key = autoMenuKey(self);
    if (!ui_menu.isOpen(key)) return;
    const gi = self.ctx_control;
    const automated = self.ui_auto[gi] != null;
    const overridden = self.auto_override[gi].load(.monotonic) != 0;
    const items = [_]ui_menu.Item{
        .{ .label = "Show automation", .id = AUTO_SHOW },
        .{ .label = "Clear automation", .id = AUTO_CLEAR, .enabled = automated },
        .{ .label = "Re-enable automation", .id = AUTO_REENABLE, .enabled = overridden },
    };
    const picked = ui_menu.pick(key, &items) orelse return;
    switch (picked) {
        AUTO_SHOW => self.auto_request = .{ .control = @intCast(gi), .action = .show },
        AUTO_CLEAR => self.auto_request = .{ .control = @intCast(gi), .action = .clear },
        AUTO_REENABLE => self.auto_override[gi].store(0, .monotonic),
        else => {},
    }
}

/// One control in its natural rect, drawn as its widget.
fn drawControl(self: *FyRawMachine, ui: *Ui, kr: Rect, gi: usize, ctl: *const Control, tier: ui_ctl.Size) void {
    const label = ctl.label[0..ctl.label_len];
    var ob: [MAX_OPTS][]const u8 = undefined;
    const opts = optionSlices(ctl, &ob);
    switch (ctl.widgetFor()) {
        .auto, .knob => drawKnob(self, ui, kr, gi, ctl, tier),
        .fader => {
            var value = self.shownNorm(gi);
            var vbuf: [16:0]u8 = undefined;
            const readout = std.mem.span(formatControlValue(&vbuf, normToValue(ctl.*, value)));
            if (ui_ctl.slider(ui, kr, gi, &value, .{
                .kind = ui_ctl.faderKind(tier),
                .label = label,
                .readout = readout,
                .show_readout = false,
                .bipolar = ctl.bipolar(),
                .default = valueToNorm(ctl.*, ctl.default),
            })) self.setControlNorm(gi, value);
        },
        .button => {
            var on = switchIndex(ctl.*, self.shownNorm(gi)) == 1;
            if (ui_ctl.latch(ui, kr, gi, &on, .{ .size = tier, .label = label })) self.setControlRaw(gi, if (on) 1 else 0);
        },
        .display => {
            var il: IntLabels = .{};
            if (ctl.kind == .int_range) {
                const labels = il.fill(ctl);
                const lo: i64 = @intFromFloat(@round(ctl.min));
                const cur: i64 = @intFromFloat(intRangeValue(ctl.*, self.shownNorm(gi)));
                var idx: u8 = @intCast(std.math.clamp(cur - lo, 0, @as(i64, @intCast(labels.len - 1))));
                if (ui_ctl.displayField(ui, kr, gi, &idx, labels, label)) self.setControlRaw(gi, @floatFromInt(lo + idx));
            } else {
                var idx: u8 = @intCast(switchIndex(ctl.*, self.shownNorm(gi)));
                if (ui_ctl.displayField(ui, kr, gi, &idx, opts, label)) pickOption(self, gi, idx);
            }
        },
        .lever, .slide, .list, .radio, .vradio => |w| {
            var idx: u8 = @intCast(switchIndex(ctl.*, self.shownNorm(gi)));
            const n: u8 = @intCast(opts.len);
            const changed = switch (w) {
                .lever => ui_ctl.toggle(ui, kr, gi, &idx, .{ .positions = n, .label = label, .marks = opts }),
                .slide => ui_ctl.slide(ui, kr, gi, &idx, .{ .positions = n, .label = label, .marks = opts }),
                .list => ui_ctl.list(ui, kr, gi, &idx, opts, label),
                else => ui_ctl.radio(ui, kr, gi, &idx, opts, .{ .size = tier, .label = label, .vertical = w == .vradio }),
            };
            if (changed) pickOption(self, gi, idx);
        },
    }
}

fn drawKnob(self: *FyRawMachine, ui: *Ui, kr: Rect, gi: usize, ctl: *const Control, tier: ui_ctl.Size) void {
    const label = ctl.label[0..ctl.label_len];
    switch (ctl.kind) {
        .switch_sel => {
            const n = ctl.option_count;
            if (n == 0) return;
            const idx = switchIndex(ctl.*, self.shownNorm(gi));
            var v: f32 = if (n > 1) @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(n - 1)) else 0;
            const readout = std.mem.span(ctl.optionLabelZ(idx));
            if (ui_ctl.knob(ui, kr, gi, &v, .{ .size = tier, .variant = .stepped, .steps = @intCast(n), .label = label, .readout = readout, .show_readout = false })) {
                const ni: usize = @intFromFloat(@round(v * @as(f32, @floatFromInt(n - 1))));
                if (ni != idx) pickOption(self, gi, ni);
            }
        },
        .int_range => {
            const n_steps = @max(intRangeCount(ctl.*), 1);
            const lo: i64 = @intFromFloat(@round(ctl.min));
            const cur: i64 = @intFromFloat(intRangeValue(ctl.*, self.shownNorm(gi)));
            const idx = std.math.clamp(cur - lo, 0, @as(i64, @intCast(n_steps - 1)));
            const steps_f: f32 = @floatFromInt(@max(n_steps - 1, 1));
            var v: f32 = @as(f32, @floatFromInt(idx)) / steps_f;
            var nb: [12]u8 = undefined;
            const readout = std.fmt.bufPrint(&nb, "{d}", .{cur}) catch "?";
            // Detents only render for small counts; wide ranges are a
            // plain knob that still snaps to integers.
            const stepped = n_steps <= 24;
            if (ui_ctl.knob(ui, kr, gi, &v, .{ .size = tier, .variant = if (stepped) .stepped else .plain, .steps = @intCast(@min(n_steps, 255)), .label = label, .readout = readout, .show_readout = false })) {
                const ni: i64 = @intFromFloat(@round(v * steps_f));
                self.setControlRaw(gi, @floatFromInt(lo + ni));
            }
        },
        .direct_f64 => {
            var value = self.shownNorm(gi);
            var vbuf: [16:0]u8 = undefined;
            const readout = std.mem.span(formatControlValue(&vbuf, normToValue(ctl.*, value)));
            if (ui_ctl.knob(ui, kr, gi, &value, .{
                .size = tier,
                .variant = if (ctl.bipolar()) .bipolar else .plain,
                .label = label,
                .readout = readout,
                .show_readout = false,
                .default = valueToNorm(ctl.*, ctl.default),
            })) self.setControlNorm(gi, value);
        },
    }
}

// ── Displays ─────────────────────────────────────────────────────────

/// Display pens: VFD amber-orange, OLED white, periwinkle.
const PENS = [_]ui_style.Color{ ui_style.vfd, ui_style.Color.hex(0xdcecff), ui_style.mod };

fn drawDisplay(self: *FyRawMachine, ui: *Ui, r: Rect, disp: *const Display) void {
    switch (disp.kind) {
        .adsr => {
            const field = ui.well(r, ui_style.well);
            ui.clip(field);
            defer ui.unclip();
            var it = std.mem.splitScalar(u8, disp.sourceSlice(), ',');
            var idx: usize = 0;
            while (it.next()) |raw| : (idx += 1) {
                drawAdsrCurve(self, ui, field, std.mem.trim(u8, raw, " "), PENS[idx % PENS.len], idx);
            }
        },
        .waveform => drawWaveformDisplay(self, ui, r, disp.sourceSlice()),
        .segments => drawSegmentDisplay(self, ui, r, disp.sourceSlice()),
        .meter => drawMeterDisplay(self, ui, r, disp),
        .response => drawResponseDisplay(self, ui, r),
        .dynamics => drawDynamicsDisplay(self, ui, r, disp),
        .algo => drawAlgoDisplay(self, ui, r, disp),
        .eg4 => drawEg4Display(self, ui, r, disp.sourceSlice()),
        .zones => drawZoneDisplay(self, ui, r, disp.sourceSlice()),
    }
}

// ── Operator routing graph (FM algorithms) ────────────────────────────
//
// Reads the selected row of the machine's derive-data routing table and
// lays it out as a tidy tree: carriers on the bottom row feeding the output
// bus, each modulator above the operator it feeds first. Leaves take
// successive columns; a parent sits over the mean of its children.
// Modulators feeding more than one operator draw their extra edges as
// diagonals, feedback as a loop over the box.

const AlgoGraph = struct {
    n: usize = 0,
    edge: [machine_desc.MAX_ALGO_OPS][machine_desc.MAX_ALGO_OPS]bool = undefined, // [mod][car]
    carrier: [machine_desc.MAX_ALGO_OPS]bool = undefined,
    feedback: [machine_desc.MAX_ALGO_OPS]bool = undefined,
    parent: [machine_desc.MAX_ALGO_OPS]?usize = undefined,
    placed: [machine_desc.MAX_ALGO_OPS]bool = undefined,
    x: [machine_desc.MAX_ALGO_OPS]f32 = undefined,
    depth: [machine_desc.MAX_ALGO_OPS]usize = undefined,
    slots: usize = 0,
    max_depth: usize = 0,

    fn place(g: *AlgoGraph, node: usize, depth: usize) void {
        g.placed[node] = true;
        g.depth[node] = depth;
        g.max_depth = @max(g.max_depth, depth);
        var sum: f32 = 0;
        var kids: f32 = 0;
        for (0..g.n) |ch| {
            if (g.parent[ch] != node or g.placed[ch] or depth >= g.n) continue;
            g.place(ch, depth + 1);
            sum += g.x[ch];
            kids += 1;
        }
        if (kids > 0) {
            g.x[node] = sum / kids;
        } else {
            g.x[node] = @floatFromInt(g.slots);
            g.slots += 1;
        }
    }
};

fn algoGraph(self: *const FyRawMachine, disp: *const Display) ?AlgoGraph {
    const base = self.desc.derive_data;
    if (base == 0) return null;
    const sel = controlIndexById(self, disp.sourceSlice()) orelse return null;
    const ctl = &self.desc.controls[sel];
    const row: usize = @intFromFloat(intRangeValue(ctl.*, self.controlNorm(sel)) - ctl.min);
    const cells: [*]const f64 = @ptrFromInt(base);
    const r = cells + row * disp.algoOffset(.stride);
    var g = AlgoGraph{ .n = disp.algoOffset(.ops) };
    for (0..g.n) |i| {
        g.carrier[i] = r[disp.algoOffset(.carriers) + i] > 0.5;
        g.feedback[i] = r[disp.algoOffset(.feedback) + i] > 0.5;
        g.placed[i] = false;
        g.parent[i] = null;
        for (0..g.n) |car| g.edge[i][car] = r[disp.algoOffset(.matrix) + car * g.n + i] > 0.5;
    }
    // Tree parent: the first operator a modulator feeds.
    for (0..g.n) |m| {
        if (g.carrier[m]) continue;
        for (0..g.n) |car| if (g.edge[m][car] and car != m) {
            g.parent[m] = car;
            break;
        };
    }
    for (0..g.n) |ci| if (g.carrier[ci]) g.place(ci, 0);
    return g;
}

fn controlIndexById(self: *const FyRawMachine, id: []const u8) ?usize {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.idSlice(), id)) return i;
    }
    return null;
}

fn drawAlgoDisplay(self: *FyRawMachine, ui: *Ui, r: Rect, disp: *const Display) void {
    const field = ui.well(r, ui_style.well);
    const g = algoGraph(self, disp) orelse return;
    if (g.slots == 0) return;
    ui.clip(field);
    defer ui.unclip();
    const BOX: i32 = 13;
    const pitch_x: i32 = @min(24, @divFloor(field.w - 8, @as(i32, @intCast(g.slots))));
    const rows: i32 = @intCast(g.max_depth + 1);
    const pitch_y: i32 = @min(22, @divFloor(field.h - 14, rows));
    const graph_w = pitch_x * @as(i32, @intCast(g.slots));
    const x0 = field.x + @divFloor(field.w - graph_w, 2) + @divFloor(pitch_x - BOX, 2);
    const bus_y = field.y + @divFloor(field.h + rows * pitch_y, 2) - 2;
    const col = ui_style.vfd;
    const dim = ui_style.vfd.alpha(150);

    const Box = struct { x: i32, y: i32 };
    var boxes: [machine_desc.MAX_ALGO_OPS]Box = undefined;
    for (0..g.n) |i| {
        if (!g.placed[i]) continue;
        boxes[i] = .{
            .x = x0 + @as(i32, @intFromFloat(@round(g.x[i] * @as(f32, @floatFromInt(pitch_x))))),
            .y = bus_y - 4 - (@as(i32, @intCast(g.depth[i])) + 1) * pitch_y + (pitch_y - BOX),
        };
    }
    // Output bus under the carriers.
    var bus_l: i32 = std.math.maxInt(i32);
    var bus_r: i32 = std.math.minInt(i32);
    for (0..g.n) |i| if (g.placed[i] and g.carrier[i]) {
        const cx = boxes[i].x + @divFloor(BOX, 2);
        ui.rect(Rect.xywh(cx, boxes[i].y + BOX, 1, bus_y - boxes[i].y - BOX), dim);
        bus_l = @min(bus_l, cx);
        bus_r = @max(bus_r, cx);
    };
    if (bus_r >= bus_l) ui.rect(Rect.xywh(bus_l, bus_y, bus_r - bus_l + 1, 1), dim);
    // Modulation edges: modulator's bottom to the fed operator's top.
    for (0..g.n) |m| for (0..g.n) |car| {
        if (!g.edge[m][car] or m == car or !g.placed[m] or !g.placed[car]) continue;
        const ax: f32 = @floatFromInt(boxes[m].x + @divFloor(BOX, 2));
        const bx: f32 = @floatFromInt(boxes[car].x + @divFloor(BOX, 2));
        ui.line(ax + 0.5, @as(f32, @floatFromInt(boxes[m].y + BOX)) + 0.5, bx + 0.5, @as(f32, @floatFromInt(boxes[car].y)) + 0.5, dim);
    };
    // Operators: carriers lit, modulators outlined; feedback loops over.
    for (0..g.n) |i| {
        if (!g.placed[i]) continue;
        const b = Rect.xywh(boxes[i].x, boxes[i].y, BOX, BOX);
        var nb: [2]u8 = undefined;
        const label = std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "?";
        if (g.carrier[i]) {
            ui.rect(b, col);
            ui.textIn(&ui.fonts.legend, b, label, ui_style.well, .center, false);
        } else {
            ui.rect(b, ui_style.well);
            ui.bevel(b, col, col);
            ui.textIn(&ui.fonts.legend, b, label, col, .center, false);
        }
        if (g.feedback[i]) {
            const rx = b.right() + 2;
            const cx = b.x + @divFloor(BOX, 2);
            ui.rect(Rect.xywh(b.right(), b.y + @divFloor(BOX, 2), 3, 1), col);
            ui.rect(Rect.xywh(rx, b.y - 3, 1, @divFloor(BOX, 2) + 4), col);
            ui.rect(Rect.xywh(cx, b.y - 3, rx - cx, 1), col);
            ui.rect(Rect.xywh(cx, b.y - 3, 1, 3), col);
        }
    }
    _ = ui.text(&ui.fonts.legend, field.x + 2, field.y, disp.nameSlice(), dim);
}

// ── Four-rate / four-level envelope (DX style) ────────────────────────
//
// Levels L1..L4, rates R1..R4 in level-per-sample. Attack runs from L4 to
// L1 at R1, then L2 at R2, L3 at R3 (held while the key is down), release
// back to L4 at R4. Segment widths follow each segment's duration on a
// compressed (log) scale so fast and slow segments both stay readable.

fn drawEg4Display(self: *FyRawMachine, ui: *Ui, r: Rect, module: []const u8) void {
    const field = ui.well(r, ui_style.well);
    var rate: [4]f64 = undefined;
    var level: [4]f64 = undefined;
    inline for (0..4) |k| {
        var lb: [2]u8 = undefined;
        lb = .{ 'R', '1' + k };
        rate[k] = controlValueByLabel(self, module, &lb) orelse 0.01;
        lb = .{ 'L', '1' + k };
        level[k] = controlValueByLabel(self, module, &lb) orelse 0.5;
    }
    ui.clip(field);
    defer ui.unclip();
    const x0: f32 = @as(f32, @floatFromInt(field.x)) + 2.5;
    const w: f32 = @as(f32, @floatFromInt(field.w)) - 5;
    const top: f32 = @as(f32, @floatFromInt(field.y)) + 12.5;
    const h: f32 = @as(f32, @floatFromInt(field.h)) - 15;
    if (w <= 1 or h <= 1) return;
    const base = top + h;
    const sr: f64 = 48000.0;
    // Segment starts/ends: L4→L1, L1→L2, L2→L3, [hold L3], L3→L4.
    const from = [4]f64{ level[3], level[0], level[1], level[2] };
    const to = [4]f64{ level[0], level[1], level[2], level[3] };
    var seg_w: [4]f32 = undefined;
    for (0..4) |k| {
        const secs = @abs(to[k] - from[k]) / @max(rate[k], 1e-9) / sr;
        seg_w[k] = @floatCast(@log(1.0 + secs / 0.01) + 0.15);
    }
    const hold: f32 = 1.2;
    const total = seg_w[0] + seg_w[1] + seg_w[2] + hold + seg_w[3];
    const col = ui_style.vfd;
    var x = x0;
    for (0..4) |k| {
        if (k == 3) {
            // Sustain hold at L3, then release.
            const hx = x + w * hold / total;
            const ly = base - @as(f32, @floatCast(level[2])) * h;
            ui.line(x, ly, hx, ly, col.alpha(150));
            x = hx;
        }
        const nx = x + w * seg_w[k] / total;
        ui.line(x, base - @as(f32, @floatCast(from[k])) * h, nx, base - @as(f32, @floatCast(to[k])) * h, col);
        x = nx;
    }
    _ = ui.text(&ui.fonts.legend, field.x + 2, field.y, module, col.alpha(150));
}

fn controlValueByLabel(self: *const FyRawMachine, module: []const u8, label: []const u8) ?f64 {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.moduleSlice(), module) and std.mem.eql(u8, ctl.label[0..ctl.label_len], label))
            return normToValue(ctl.*, self.controlNorm(i));
    }
    return null;
}

// ── Frequency-response curve (parametric EQ) ──────────────────────────
//
// Recomputes the composite biquad magnitude from the machine's own band
// controls (read on the UI thread from the same norms the audio thread
// turns into params) and draws it as a 1 px polyline over a log-frequency
// axis. The audio truth stays in fy (kernels/07-effects/eq.fy); this curve
// is a cosmetic mirror, so a fixed 48 kHz display rate is fine.

const EQ_DB_RANGE: f64 = 18.0; // half-range; the field spans ±18 dB

const Biquad = struct { b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64 };

fn rbjPeak(fc: f64, db: f64, q: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const alpha = sw / (2.0 * q);
    return .{ .b0 = 1 + alpha * a, .b1 = -2 * cw, .b2 = 1 - alpha * a, .a0 = 1 + alpha / a, .a1 = -2 * cw, .a2 = 1 - alpha / a };
}

fn rbjLowShelf(fc: f64, db: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const beta = 2.0 * @sqrt(a) * (sw / 2.0) * std.math.sqrt2;
    const ap1 = a + 1.0;
    const am1 = a - 1.0;
    return .{
        .b0 = a * (ap1 - am1 * cw + beta),
        .b1 = 2 * a * (am1 - ap1 * cw),
        .b2 = a * (ap1 - am1 * cw - beta),
        .a0 = ap1 + am1 * cw + beta,
        .a1 = -2 * (am1 + ap1 * cw),
        .a2 = ap1 + am1 * cw - beta,
    };
}

fn rbjHighShelf(fc: f64, db: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const a = std.math.pow(f64, 10.0, db / 40.0);
    const beta = 2.0 * @sqrt(a) * (sw / 2.0) * std.math.sqrt2;
    const ap1 = a + 1.0;
    const am1 = a - 1.0;
    return .{
        .b0 = a * (ap1 + am1 * cw + beta),
        .b1 = -2 * a * (am1 + ap1 * cw),
        .b2 = a * (ap1 + am1 * cw - beta),
        .a0 = ap1 - am1 * cw + beta,
        .a1 = 2 * (am1 - ap1 * cw),
        .a2 = ap1 - am1 * cw - beta,
    };
}

fn rbjHpf(fc: f64, q: f64, sr: f64) Biquad {
    const w = 2.0 * std.math.pi * fc / sr;
    const cw = @cos(w);
    const sw = @sin(w);
    const alpha = sw / (2.0 * q);
    const omc = 1.0 + cw;
    return .{ .b0 = omc / 2.0, .b1 = -omc, .b2 = omc / 2.0, .a0 = 1 + alpha, .a1 = -2 * cw, .a2 = 1 - alpha };
}

fn biquadMagDb(bq: Biquad, f: f64, sr: f64) f64 {
    const w = 2.0 * std.math.pi * f / sr;
    const cw = @cos(w);
    const c2w = @cos(2.0 * w);
    const num = bq.b0 * bq.b0 + bq.b1 * bq.b1 + bq.b2 * bq.b2 + 2.0 * (bq.b0 * bq.b1 + bq.b1 * bq.b2) * cw + 2.0 * bq.b0 * bq.b2 * c2w;
    const den = bq.a0 * bq.a0 + bq.a1 * bq.a1 + bq.a2 * bq.a2 + 2.0 * (bq.a0 * bq.a1 + bq.a1 * bq.a2) * cw + 2.0 * bq.a0 * bq.a2 * c2w;
    return 10.0 * std.math.log10(@max(num / @max(den, 1e-12), 1e-12));
}

fn controlValueById(self: *const FyRawMachine, id: []const u8) ?f64 {
    for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.idSlice(), id)) {
            return switch (ctl.kind) {
                .direct_f64 => normToValue(ctl.*, self.controlNorm(i)),
                .switch_sel => ctl.option_values[switchIndex(ctl.*, self.controlNorm(i))],
                .int_range => intRangeValue(ctl.*, self.controlNorm(i)),
            };
        }
    }
    return null;
}

const DYN_LO_DB: f64 = -48.0; // the curve's axes run DYN_LO_DB .. 0 dBFS
const DYN_GR_RANGE: f64 = 24.0;

/// The value of control `<prefix><suffix>` ("comp" ++ "-thresh"), or `def`.
fn prefixedValue(self: *const FyRawMachine, prefix: []const u8, suffix: []const u8, def: f64) f64 {
    var buf: [64]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, suffix }) catch return def;
    return controlValueById(self, id) orelse def;
}

/// A compressor's static gain (dB, <= 0) at input level `in` (dB): soft
/// knee of width `knee` around `thr` (the kernel's gain computer).
fn dynGainDb(in: f64, thr: f64, ratio: f64, knee: f64) f64 {
    const l = in - thr;
    const w = @max(knee, 1e-6);
    const slope = 1.0 / @max(ratio, 1.0) - 1.0;
    if (2 * l < -w) return 0;
    if (2 * @abs(l) <= w) return slope * (l + w / 2) * (l + w / 2) / (2 * w);
    return slope * l;
}

/// Transfer curve (docs/24): input dB across, output dB up, both
/// DYN_LO_DB..0; unity dim, the curve in the display pen, THRESH marked,
/// the detector level as a dot at the gain now applied (so attack and
/// release show as the dot leaving and rejoining the curve), and a GR
/// bar down the right edge.
fn drawDynamicsDisplay(self: *FyRawMachine, ui: *Ui, r: Rect, disp: *const Display) void {
    const field = ui.well(r, ui_style.well);
    if (field.w < 24 or field.h < 16) return;
    const pre = disp.sourceSlice();
    const thr = prefixedValue(self, pre, "-thresh", -18);
    const ratio = prefixedValue(self, pre, "-ratio", 4);
    const knee = prefixedValue(self, pre, "-knee", 6);
    const gr = @max(0, self.readStateF64(0, disp.dynOffset(.gr)));
    const lvl = self.readStateF64(0, disp.dynOffset(.lvl));
    ui.animate();

    var area = field.inset(2);
    const bar = area.cutRight(5);
    _ = area.cutRight(3);
    // Square plot, left-aligned: both axes in dB at the same scale.
    const side = @min(area.w, area.h);
    const plot_r = Rect.xywh(area.x, area.y + @divFloor(area.h - side, 2), side, side);
    const px: f32 = @floatFromInt(plot_r.x);
    const py: f32 = @floatFromInt(plot_r.y);
    const ps: f32 = @floatFromInt(plot_r.w);
    const X = struct {
        fn of(db: f64, o: f32, s: f32) f32 {
            return o + @as(f32, @floatCast(std.math.clamp((db - DYN_LO_DB) / -DYN_LO_DB, 0, 1))) * s;
        }
    };
    const grid = ui_style.vfd.alpha(26);
    ui.clip(field);
    defer ui.unclip();
    inline for (.{ -36.0, -24.0, -12.0 }) |g| {
        const gx: i32 = @intFromFloat(X.of(g, px, ps));
        const gy: i32 = @intFromFloat(py + ps - (X.of(g, px, ps) - px));
        ui.rect(Rect.xywh(gx, plot_r.y, 1, plot_r.h), grid);
        ui.rect(Rect.xywh(plot_r.x, gy, plot_r.w, 1), grid);
    }
    ui.line(px, py + ps, px + ps, py, ui_style.vfd.alpha(48)); // unity
    // THRESH: a dim tick up the plot.
    ui.rect(Rect.xywh(@intFromFloat(X.of(thr, px, ps)), plot_r.y, 1, plot_r.h), ui_style.vfd.alpha(60));
    const N: usize = 96;
    var prev: [2]f32 = .{ 0, 0 };
    for (0..N) |i| {
        const in = DYN_LO_DB * (1 - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(N - 1)));
        const out = in + dynGainDb(in, thr, ratio, knee);
        const p = [2]f32{ X.of(in, px, ps), py + ps - (X.of(out, px, ps) - px) };
        if (i > 0) ui.line(prev[0], prev[1], p[0], p[1], ui_style.vfd);
        prev = p;
    }
    // The detector level at the gain now applied.
    const lvl_db = 20 * std.math.log10(@max(lvl, 1e-6));
    if (lvl_db > DYN_LO_DB) {
        const dx: i32 = @intFromFloat(X.of(lvl_db, px, ps));
        const dy: i32 = @intFromFloat(py + ps - (X.of(lvl_db - gr, px, ps) - px));
        ui.rect(Rect.xywh(dx - 1, dy - 1, 3, 3), ui_style.text);
    }
    // GR bar, from the top down.
    ui.rect(bar, ui_style.vfd.alpha(18));
    const gh: i32 = @intFromFloat(@round(std.math.clamp(gr / DYN_GR_RANGE, 0, 1) * @as(f64, @floatFromInt(bar.h))));
    if (gh > 0) ui.rect(Rect.xywh(bar.x, bar.y, bar.w, gh), ui_style.vfd);
    var tb: [16]u8 = undefined;
    const txt = std.fmt.bufPrint(&tb, "GR {d:.1}", .{gr}) catch "";
    ui.textIn(&ui.fonts.legend, Rect.xywh(plot_r.x + 3, plot_r.y + 2, plot_r.w, 10), txt, ui_style.vfd, .left, false);
}

fn drawResponseDisplay(self: *FyRawMachine, ui: *Ui, r: Rect) void {
    const sr: f64 = 48000.0;
    const field = ui.well(r, ui_style.well);
    if (field.w < 4 or field.h < 4) return;

    const hpf_on = (controlValueById(self, "eq-hpf-on") orelse 0.0) >= 0.5;
    const hpf = rbjHpf(controlValueById(self, "eq-hpf-hz") orelse 20.0, std.math.sqrt1_2, sr);
    const ls = rbjLowShelf(controlValueById(self, "eq-ls-hz") orelse 100.0, controlValueById(self, "eq-ls-db") orelse 0.0, sr);
    const p1 = rbjPeak(controlValueById(self, "eq-p1-hz") orelse 500.0, controlValueById(self, "eq-p1-db") orelse 0.0, controlValueById(self, "eq-p1-q") orelse 0.9, sr);
    const p2 = rbjPeak(controlValueById(self, "eq-p2-hz") orelse 3000.0, controlValueById(self, "eq-p2-db") orelse 0.0, controlValueById(self, "eq-p2-q") orelse 0.9, sr);
    const hs = rbjHighShelf(controlValueById(self, "eq-hs-hz") orelse 8000.0, controlValueById(self, "eq-hs-db") orelse 0.0, sr);

    ui.clip(field);
    defer ui.unclip();
    const grid = ui_style.vfd.alpha(26);
    // Horizontal grid: 0 dB centre (brighter) + ±9 dB lines.
    const mid_y = field.y + @divFloor(field.h, 2);
    ui.rect(Rect.xywh(field.x, mid_y, field.w, 1), ui_style.vfd.alpha(48));
    inline for (.{ -9.0, 9.0 }) |g| {
        const gy = field.y + @as(i32, @intFromFloat(@as(f32, @floatCast(0.5 - @as(f64, g) / (2.0 * EQ_DB_RANGE))) * @as(f32, @floatFromInt(field.h))));
        ui.rect(Rect.xywh(field.x, gy, field.w, 1), grid);
    }
    // Vertical decade lines at 100 / 1k / 10k Hz (log axis 20..20000).
    inline for (.{ 100.0, 1000.0, 10000.0 }) |fline| {
        const tx = std.math.log10(@as(f64, fline) / 20.0) / 3.0;
        ui.rect(Rect.xywh(field.x + @as(i32, @intFromFloat(@as(f32, @floatCast(tx)) * @as(f32, @floatFromInt(field.w)))), field.y, 1, field.h), grid);
    }

    const N: usize = 160;
    const fx: f32 = @floatFromInt(field.x);
    const fy: f32 = @floatFromInt(field.y);
    const fw: f32 = @floatFromInt(field.w);
    const fh: f32 = @floatFromInt(field.h);
    var prev: [2]f32 = .{ 0, 0 };
    for (0..N) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(N - 1));
        const f = 20.0 * std.math.pow(f64, 1000.0, t);
        var db: f64 = 0;
        if (hpf_on) db += biquadMagDb(hpf, f, sr);
        db += biquadMagDb(ls, f, sr);
        db += biquadMagDb(p1, f, sr);
        db += biquadMagDb(p2, f, sr);
        db += biquadMagDb(hs, f, sr);
        const yn = std.math.clamp(0.5 - db / (2.0 * EQ_DB_RANGE), 0.0, 1.0);
        const p = [2]f32{ fx + @as(f32, @floatCast(t)) * fw, fy + @as(f32, @floatCast(yn)) * fh };
        if (i > 0) ui.line(prev[0], prev[1], p[0], p[1], ui_style.vfd);
        prev = p;
    }
}

// ── L2-style level / loudness meter ───────────────────────────────────
//
// Vertical full-scale meter (0 dB at top, -60 dB floor): per-channel input
// and output level bars, a gain-reduction band descending from the top, dB
// scale ticks, peak-hold lines, and LUFS (momentary/short-term/integrated)
// + output-peak numeric readouts. All log conversions happen here; the
// kernel stores only linear cells.

const METER_DB_FLOOR: f32 = -60.0;
const METER_GR_RANGE: f32 = 24.0; // dB of GR shown across the band height

const MeterUi = struct {
    // Smoothed display values (dB), fast attack / slow release.
    in_db: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    out_db: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    gr_db: f32 = 0,
    // Peak-hold (dB) with hold time then decay.
    in_hold: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    out_hold: [2]f32 = .{ METER_DB_FLOOR, METER_DB_FLOOR },
    gr_hold: f32 = 0,
    hold_age: f32 = 0,
    out_peak_db: f32 = METER_DB_FLOOR, // max output peak since last clear (clip readout)
    last_t: f64 = 0,
};

fn lin2db(x: f64) f32 {
    return @floatCast(20.0 * std.math.log10(@max(x, 1e-7)));
}

fn ms2lufs(ms: f64) f32 {
    return @floatCast(-0.691 + 10.0 * std.math.log10(@max(ms, 1e-12)));
}

// dB → y within [top, bottom], 0 dB at top, floor at bottom.
fn dbToY(db: f32, top: f32, bottom: f32) f32 {
    const frac = std.math.clamp((db - METER_DB_FLOOR) / (0.0 - METER_DB_FLOOR), 0.0, 1.0);
    return bottom - frac * (bottom - top);
}

/// Compressor/limiter display: IN pair | GR band | OUT pair (pro meters,
/// graduated on the output), then GR / output-peak / LUFS readouts.
fn drawMeterDisplay(self: *FyRawMachine, ui: *Ui, r: Rect, disp: *const Display) void {
    const regions = self.regionCount();
    const r1: usize = if (regions > 1) 1 else 0;

    // Live linear cells (region 0 = L, region 1 = R).
    const gmin = @min(self.readStateF64(0, disp.meterOffset(.gmin)), self.readStateF64(r1, disp.meterOffset(.gmin)));
    const gr_now: f32 = -lin2db(@max(gmin, 1e-7));
    const in_lin = [2]f32{ @floatCast(self.readStateF64(0, disp.meterOffset(.ipk))), @floatCast(self.readStateF64(r1, disp.meterOffset(.ipk))) };
    const out_lin = [2]f32{ @floatCast(self.readStateF64(0, disp.meterOffset(.opk))), @floatCast(self.readStateF64(r1, disp.meterOffset(.opk))) };
    const msm = self.readStateF64(0, disp.meterOffset(.msm)) + self.readStateF64(r1, disp.meterOffset(.msm));
    const mss = self.readStateF64(0, disp.meterOffset(.mss)) + self.readStateF64(r1, disp.meterOffset(.mss));
    const msum = self.readStateF64(0, disp.meterOffset(.msum)) + self.readStateF64(r1, disp.meterOffset(.msum));
    const mn = @max(self.readStateF64(0, disp.meterOffset(.mn)), 1.0);

    // GR ballistics + output-peak latch (the level bars use the Ui
    // meters' own ballistics).
    const st = &self.meter_ui;
    const dt = ui.in.dt;
    st.gr_db = if (gr_now >= st.gr_db) gr_now else @max(gr_now, st.gr_db - 60.0 * dt);
    if (gr_now > st.gr_hold) {
        st.gr_hold = gr_now;
        st.hold_age = 0;
    } else {
        st.hold_age += dt;
        if (st.hold_age > 1.5) st.gr_hold = @max(0, st.gr_hold - 18.0 * dt);
    }
    st.out_peak_db = @max(st.out_peak_db, @max(lin2db(out_lin[0]), lin2db(out_lin[1])));
    ui.animate();

    var area = r;
    const readouts = area.cutBottom(2 * ui_ctl.displayHeight(false));
    var graph = ui.well(area, ui_style.well).inset(2);
    // IN pair (bare) | 4 | GR 12 | 4 | OUT pair (with its 20px centre scale):
    // four equal bars share what's left.
    const in_w = @max(@divFloor(graph.w - 40, 2), 8);
    ui_ctl.meterStereo(ui, graph.cutLeft(in_w), "in", in_lin, in_lin, .{ .scale = .none });
    _ = graph.cutLeft(4);
    grBand(ui, graph.cutLeft(12), st.gr_db, st.gr_hold);
    _ = graph.cutLeft(4);
    ui_ctl.meterStereo(ui, graph, "out", out_lin, out_lin, .{});

    var b1: [48]u8 = undefined;
    const clip = st.out_peak_db > -0.05;
    const l1 = std.fmt.bufPrint(&b1, "GR {d:.1}  OUT {d:.1}", .{ st.gr_db, st.out_peak_db }) catch "";
    ui_ctl.display(ui, readouts.takeTop(ui_ctl.displayHeight(false)), l1, .{ .color = if (clip) ui_style.rec else ui_style.vfd });
    var b2: [56]u8 = undefined;
    const l2 = std.fmt.bufPrint(&b2, "M {d:.1} S {d:.1} I {d:.1} LU", .{ ms2lufs(msm), ms2lufs(mss), ms2lufs(msum / mn) }) catch "";
    var lr = readouts;
    _ = lr.cutTop(ui_ctl.displayHeight(false));
    ui_ctl.display(ui, lr, l2, .{});
}

/// Gain-reduction bargraph: red segments descend from the top, a bright
/// hold segment marks the recent maximum (METER_GR_RANGE dB full scale).
fn grBand(ui: *Ui, r: Rect, gr_db: f32, hold_db: f32) void {
    const inner = ui.well(r, ui_style.well);
    const n = @divFloor(inner.h, 3);
    if (n <= 0) return;
    const nf: f32 = @floatFromInt(n);
    const lit: i32 = @intFromFloat(@round(std.math.clamp(gr_db / METER_GR_RANGE, 0, 1) * nf));
    const hold_i = @as(i32, @intFromFloat(@round(std.math.clamp(hold_db / METER_GR_RANGE, 0, 1) * nf))) - 1;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const col = if (i < lit) ui_style.rec else if (i == hold_i and hold_db > 0.05) ui_style.rec.mix(ui_style.text, 0.3) else ui_style.rec.mix(ui_style.well, 0.86);
        ui.rect(Rect.xywh(inner.x, inner.y + i * 3, inner.w, 2), col);
    }
}

/// The sample displays' title row: LOAD (the native picker hot-swaps the
/// sample) beside the file or selected zone's name, peak and length.
/// Returns the area below it.
fn waveHeader(self: *FyRawMachine, ui: *Ui, r: Rect, ai: usize) Rect {
    var area = r;
    var bar = area.cutTop(20);
    if (ui_ctl.button(ui, bar.cutRight(52), .{ "load", ai }, null, .{ .label = "LOAD", .flush = true })) {
        const picked = if (self.desc.assets[ai].keymap) native_dialog.openKeymap(self.alloc) else native_dialog.openAudioFile(self.alloc);
        if (picked catch null) |path| {
            defer self.alloc.free(path);
            _ = self.loadAssetRuntime(ai, path);
        }
    }
    const is_km = self.desc.assets[ai].keymap;
    const km = &self.asset_keymap[ai];
    // A keymap shows its selected zone: name, peak and length in the bar,
    // the shape drawn to its own peak so quiet samples still read.
    if (is_km and km.count > 0 and self.wave_zone != self.zone_sel) {
        const zi = @min(self.zone_sel, km.count - 1);
        const smp = km.samples(km.zones[zi]);
        self.asset_cache[ai].deinit(self.alloc);
        self.asset_cache[ai] = .{};
        self.asset_cache[ai].build(self.alloc, smp) catch {};
        var pk: f64 = 0;
        for (smp) |x| pk = @max(pk, @abs(x));
        self.wave_peak = pk;
        self.wave_zone = self.zone_sel;
    }
    var lbuf: [96]u8 = undefined;
    const label = if (is_km and km.count > 0) blk: {
        const zi = @min(self.zone_sel, km.count - 1);
        const z = km.zones[zi];
        const pk_db = if (self.wave_peak > 0) 20 * std.math.log10(self.wave_peak) else -120;
        // a .VC zone has no rate of its own: it plays at the machine's
        break :blk if (z.sr > 0.5)
            std.fmt.bufPrint(&lbuf, "{s}  PK {d:.1} DB  {d:.2} S", .{ km.names[zi].slice(), pk_db, z.len / z.sr }) catch ""
        else
            std.fmt.bufPrint(&lbuf, "{s}  PK {d:.1} DB  {d} SMP", .{ km.names[zi].slice(), pk_db, @as(u64, @intFromFloat(z.len)) }) catch "";
    } else self.asset_label[ai][0..self.asset_label_len[ai]];
    ui_ctl.display(ui, bar, if (label.len > 0) label else "NO SAMPLE", .{ .flush = true });
    return area;
}

// Oscillogram of a loaded asset: the title row, then the peak waveform
// with draggable start / loop markers bound to the matching controls.
fn drawWaveformDisplay(self: *FyRawMachine, ui: *Ui, r: Rect, asset_name: []const u8) void {
    const ai = self.assetIndexByName(asset_name) orelse return;
    const area = waveHeader(self, ui, r, ai);
    const is_km = self.desc.assets[ai].keymap;
    const inner = ui.well(area, ui_style.well);
    if (inner.w < 2 or inner.h < 2) return;
    ui.clip(inner);
    defer ui.unclip();
    const cache = &self.asset_cache[ai];
    const mid = inner.y + @divFloor(inner.h, 2);
    ui.rect(Rect.xywh(inner.x, mid, inner.w, 1), ui_style.vfd.alpha(40));
    if (cache.sample_count > 0) {
        const span: f64 = @floatFromInt(@max(cache.sample_count, 1));
        const spp = span / @as(f64, @floatFromInt(inner.w));
        const norm: f32 = if (is_km and self.wave_peak > 1e-6) @floatCast(1 / self.wave_peak) else 1;
        const half: f32 = @as(f32, @floatFromInt(inner.h)) / 2 * norm * 0.95;
        const hh: f32 = @as(f32, @floatFromInt(inner.h)) / 2;
        var px: i32 = 0;
        while (px < inner.w) : (px += 1) {
            const s0 = @as(f64, @floatFromInt(px)) * spp;
            const p = cache.rangePeak(s0, s0 + spp, spp);
            const y0: i32 = @intFromFloat(@round(hh - std.math.clamp(@as(f32, @floatCast(p.max)) * half, -hh, hh)));
            const y1: i32 = @intFromFloat(@round(hh - std.math.clamp(@as(f32, @floatCast(p.min)) * half, -hh, hh)));
            ui.rect(Rect.xywh(inner.x + px, inner.y + @min(y0, y1), 1, @as(i32, @intCast(@abs(y1 - y0))) + 1), ui_style.vfd);
        }
    }
    drawMarker(self, ui, inner, "smp-start", ui_style.play);
    drawMarker(self, ui, inner, "smp-loop-start", ui_style.mod);
    drawMarker(self, ui, inner, "smp-loop-end", ui_style.mod);
}

/// A CMI voice's RAM as the machine holds it (docs/17): the selected zone
/// at RATE (`cmi-rate`), 16,384 samples, drawn as 128 segments, with the
/// loop span (`cmi-loop-start` .. `cmi-loop-end`, lit while `cmi-loop` is
/// on) and the START segment (`cmi-start`). The three markers drag, in
/// whole segments.
fn drawSegmentDisplay(self: *FyRawMachine, ui: *Ui, r: Rect, asset_name: []const u8) void {
    const ai = self.assetIndexByName(asset_name) orelse return;
    const area = waveHeader(self, ui, r, ai);
    const inner = ui.well(area, ui_style.well);
    if (inner.w < 2 or inner.h < 2) return;
    ui.clip(inner);
    defer ui.unclip();
    const km = &self.asset_keymap[ai];
    const rate = controlValueById(self, "cmi-rate") orelse 24000;
    const ls: i32 = @intFromFloat(controlValueById(self, "cmi-loop-start") orelse 0);
    const le: i32 = @intFromFloat(controlValueById(self, "cmi-loop-end") orelse 127);
    const st: i32 = @intFromFloat(controlValueById(self, "cmi-start") orelse 0);
    const loop_on = (controlValueById(self, "cmi-loop") orelse 0) > 0.5;

    // The RAM: source samples per stored one, and how many segments hold sound.
    var kr: f64 = 1;
    var used: i32 = 0;
    if (km.count > 0) {
        const z = km.zones[@min(self.zone_sel, km.count - 1)];
        const zsr = if (z.sr > 0.5) z.sr else rate;
        kr = std.math.clamp(@min(rate, zsr) / zsr, 0.001, 1);
        used = @intFromFloat(@ceil(@min(z.len * kr, 16384) / 128));
    }
    const segX = struct {
        fn at(in: Rect, seg: i32) i32 {
            return in.x + @divFloor(in.w * seg, 128);
        }
    }.at;

    // loop span, grid
    ui.rect(Rect.xywh(segX(inner, ls), inner.y, @max(1, segX(inner, le + 1) - segX(inner, ls)), inner.h), ui_style.mod.alpha(if (loop_on) 46 else 14));
    if (used < 128) ui.rect(Rect.xywh(segX(inner, used), inner.y, inner.right() - segX(inner, used), inner.h), ui_style.chassis.alpha(90));
    var g: i32 = 0;
    while (g <= 128) : (g += 1) {
        const x = segX(inner, g);
        if (@mod(g, 16) == 0) ui.rect(Rect.xywh(x, inner.y, 1, inner.h), ui_style.text_mute.alpha(50)) else ui.rect(Rect.xywh(x, inner.bottom() - 2, 1, 2), ui_style.text_mute.alpha(70));
    }
    const mid = inner.y + @divFloor(inner.h, 2);
    ui.rect(Rect.xywh(inner.x, mid, inner.w, 1), ui_style.vfd.alpha(40));

    // the stored waveform: pixel px covers RAM samples px/w * 16384 on
    const cache = &self.asset_cache[ai];
    if (cache.sample_count > 0) {
        const ram_src: f64 = 16384 / kr;
        const spp = ram_src / @as(f64, @floatFromInt(inner.w));
        const norm: f32 = if (self.wave_peak > 1e-6) @floatCast(1 / self.wave_peak) else 1;
        const hh: f32 = @as(f32, @floatFromInt(inner.h)) / 2;
        const half = hh * norm * 0.95;
        const end: f64 = @floatFromInt(cache.sample_count);
        var px: i32 = 0;
        while (px < inner.w) : (px += 1) {
            const s0 = @as(f64, @floatFromInt(px)) * spp;
            if (s0 >= end) break;
            const p = cache.rangePeak(s0, @min(s0 + spp, end), spp);
            const y0: i32 = @intFromFloat(@round(hh - std.math.clamp(@as(f32, @floatCast(p.max)) * half, -hh, hh)));
            const y1: i32 = @intFromFloat(@round(hh - std.math.clamp(@as(f32, @floatCast(p.min)) * half, -hh, hh)));
            ui.rect(Rect.xywh(inner.x + px, inner.y + @min(y0, y1), 1, @as(i32, @intCast(@abs(y1 - y0))) + 1), ui_style.vfd);
        }
    }

    // markers: drag in whole segments
    const Mk = struct { id: []const u8, seg: i32, edge: i32, col: ui_style.Color };
    const marks = [_]Mk{
        .{ .id = "cmi-loop-start", .seg = ls, .edge = 0, .col = ui_style.mod },
        .{ .id = "cmi-loop-end", .seg = le, .edge = 1, .col = ui_style.mod },
        .{ .id = "cmi-start", .seg = st, .edge = 0, .col = ui_style.play },
    };
    for (marks, 0..) |m, mi| {
        const x = segX(inner, m.seg + m.edge);
        const wid = ui.id(.{ "segmark", mi });
        const b = ui.behaviorEx(wid, Rect.xywh(x - 4, inner.y, 9, inner.h), .{ .prio = @intCast(1 + mi) });
        if (b.held) {
            const f = (ui.in.mx - @as(f32, @floatFromInt(inner.x))) / @as(f32, @floatFromInt(inner.w));
            const seg: i32 = @intFromFloat(std.math.clamp(@round(f * 128), 0, 128));
            const v: i32 = switch (mi) {
                0 => @min(seg, le),
                1 => @max(seg - 1, ls),
                else => @min(seg, 127),
            };
            applyControlValue(self, m.id, @floatFromInt(@min(v, 127)));
        }
        const hot = ui.isHot(wid) or b.held;
        if (hot) ui.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
        ui.rect(Rect.xywh(x, inner.y, if (hot) 2 else 1, inner.h), m.col);
        if (mi == 2) ui.rect(Rect.xywh(x - 3, inner.bottom() - 4, 7, 4), m.col) else ui.rect(Rect.xywh(x - 3, inner.y, 7, 4), m.col);
    }
    var buf: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&buf, "LOOP {s} {d}-{d}  START {d}  {d}/128 SEGS", .{ if (loop_on) "ON" else "OFF", ls, le, st, used }) catch "";
    ui.textIn(&ui.fonts.legend, Rect.xywh(inner.x + 6, inner.y + 5, inner.w - 12, 10), info, ui_style.text_dim, .left, false);
}

/// Zone list of a keymap: one row per zone (a light that flashes when it
/// plays, its key or key range, its name), click to select, wheel to
/// scroll; the selected zone's LEVEL / TUNE / DECAY / TONE knobs below,
/// FOLLOW to select whatever plays.
fn drawZoneDisplay(self: *FyRawMachine, ui: *Ui, r: Rect, asset_name: []const u8) void {
    const ai = self.assetIndexByName(asset_name) orelse return;
    zoneMenuTick(self, ai); // before the keymap is read: it may reload it
    const km = &self.asset_keymap[ai];
    const n = km.count;
    if (n == 0) return;
    if (self.zone_sel >= n) self.zone_sel = 0;
    const e = &self.zone_edits;

    // Hit lights and FOLLOW, from what the voices wrote.
    for (0..n) |i| {
        if (e.hit[i] != self.zone_hit_seen[i]) {
            self.zone_hit_seen[i] = e.hit[i];
            self.zone_flash[i] = 1;
        } else self.zone_flash[i] *= 0.88;
    }
    if (e.last != self.zone_last_seen) {
        self.zone_last_seen = e.last;
        if (self.zone_follow and e.last >= 0 and e.last < @as(f64, @floatFromInt(n))) {
            self.zone_sel = @intFromFloat(e.last);
            self.zone_follow_moved = true;
        }
    }

    var area = r;
    var bar = area.cutTop(20);
    var follow = self.zone_follow;
    if (ui_ctl.button(ui, bar.cutRight(60), .{ "zfollow", ai }, &follow, .{ .label = "FOLLOW", .flush = true })) self.zone_follow = follow;
    var tbuf: [32]u8 = undefined;
    const nrows = self.zone_row_count;
    if (nrows == 0) return;
    const sel_row: usize = self.zone_row_of[self.zone_sel];
    ui_ctl.display(ui, bar, if (nrows == n)
        std.fmt.bufPrint(&tbuf, "{d} ZONES", .{n}) catch ""
    else
        std.fmt.bufPrint(&tbuf, "{d} SOUNDS / {d}", .{ nrows, n }) catch "", .{ .flush = true });

    // Knob row for the selected zone.
    const cell = ui_ctl.knobCell(.s, true);
    const knobs = area.cutBottom(cell[1] + 2);
    const list = ui.well(area, ui_style.well);
    if (list.h < 4) return;

    const ROW: i32 = 12;
    const rows: usize = @intCast(@max(@divFloor(list.h, ROW), 1));
    if (list.contains(ui.in.ix(), ui.in.iy()) and ui.in.wheel_y != 0) {
        const d: i32 = if (ui.in.wheel_y > 0) -1 else 1;
        const top: i32 = @as(i32, @intCast(self.zone_scroll)) + d;
        self.zone_scroll = @intCast(std.math.clamp(top, 0, @as(i32, @intCast(nrows -| rows))));
    }
    if (self.zone_follow_moved) {
        // keep a row picked by FOLLOW in view
        if (sel_row < self.zone_scroll) self.zone_scroll = sel_row;
        if (sel_row >= self.zone_scroll + rows) self.zone_scroll = sel_row + 1 - rows;
        self.zone_follow_moved = false;
    }
    ui.clip(list);
    var r_i = self.zone_scroll;
    while (r_i < nrows and r_i < self.zone_scroll + rows) : (r_i += 1) {
        const i: usize = self.zone_row_first[r_i];
        const y = list.y + @as(i32, @intCast(r_i - self.zone_scroll)) * ROW;
        const row = Rect.xywh(list.x, y, list.w, ROW);
        const b = ui.behavior(ui.id(.{ "zrow", ai, r_i }), row, false);
        if (b.pressed) self.zone_sel = i;
        if (ui.in.right_pressed and row.contains(ui.in.ix(), ui.in.iy()) and !ui_menu.active()) {
            self.zone_sel = i;
            self.zone_ctx = i;
            ui_menu.openAt(zoneMenuKey(self), ui.in.ix(), ui.in.iy());
        }
        const sel = r_i == sel_row;
        if (sel) ui.rect(row, ui_style.vfd.alpha(36));
        // the row's light and key span cover all its zones
        var fl: f32 = 0;
        var lo_k: f64 = 127;
        var hi_k: f64 = 0;
        for (0..n) |zz| if (self.zone_row_of[zz] == r_i) {
            fl = @max(fl, self.zone_flash[zz]);
            lo_k = @min(lo_k, km.zones[zz].lo_key);
            hi_k = @max(hi_k, km.zones[zz].hi_key);
        };
        ui.rect(Rect.xywh(row.x + 3, y + 4, 4, 4), if (fl > 0.05) ui_style.vfd.alpha(@intFromFloat(60 + 195 * fl)) else ui_style.vfd.alpha(30));
        const z = km.zones[i];
        var kb: [16]u8 = undefined;
        var ka: [4]u8 = undefined;
        var kz: [4]u8 = undefined;
        const keys = if (lo_k == hi_k)
            keyName(&ka, lo_k)
        else
            std.fmt.bufPrint(&kb, "{s}-{s}", .{ keyName(&ka, lo_k), keyName(&kz, hi_k) }) catch "";
        const col = if (sel) ui_style.vfd else ui_style.vfd.alpha(170);
        ui.textIn(&ui.fonts.legend, Rect.xywh(row.x + 10, y, 48, ROW), keys, col, .left, true);
        ui.textIn(&ui.fonts.legend, Rect.xywh(row.x + 60, y, row.w - 62, ROW), km.names[i].slice(), col, .left, true);
        // choke group tag, then an edited zone's level change
        const cg = cutGroup(e.cut[i], z);
        if (cg > 0) {
            var gb: [8]u8 = undefined;
            ui.textIn(&ui.fonts.legend, Rect.xywh(row.right() - 62, y, 20, ROW), std.fmt.bufPrint(&gb, "G{d}", .{@as(i32, @intFromFloat(cg))}) catch "", col, .right, true);
        }
        if (self.zone_derive.isReversed(km.names[i].slice()))
            ui.textIn(&ui.fonts.legend, Rect.xywh(row.right() - 90, y, 26, ROW), "REV", col, .right, true);
        if (e.level[i] != 0) {
            var lb: [12]u8 = undefined;
            ui.textIn(&ui.fonts.legend, Rect.xywh(row.right() - 40, y, 38, ROW), std.fmt.bufPrint(&lb, "{d:.1}", .{e.level[i]}) catch "", col, .right, true);
        }
    }
    ui.unclip();

    // LEVEL -24..+12 dB · TUNE ±24 st · DECAY off..8 s · TONE ±4 oct · CUT
    const zi = self.zone_sel;
    const kw = @divFloor(knobs.w, 5);
    var edited = false;
    const Spec = struct { label: []const u8, lo: f64, hi: f64, v: *f64, exp: bool };
    const specs = [_]Spec{
        .{ .label = "LEVEL", .lo = -24, .hi = 12, .v = &e.level[zi], .exp = false },
        .{ .label = "TUNE", .lo = -24, .hi = 24, .v = &e.tune[zi], .exp = false },
        .{ .label = "DECAY", .lo = 0, .hi = 8, .v = &e.decay[zi], .exp = true },
        .{ .label = "TONE", .lo = -4, .hi = 4, .v = &e.tone[zi], .exp = false },
    };
    for (specs, 0..) |sp, k| {
        const kr = Rect.xywh(knobs.x + @as(i32, @intCast(k)) * kw, knobs.y, kw, knobs.h);
        const span = sp.hi - sp.lo;
        // DECAY: 0 is off; the rest of the travel is 20 ms..8 s, exponential.
        var norm: f32 = if (sp.exp)
            (if (sp.v.* <= 0) 0 else @floatCast(0.05 + 0.95 * std.math.log2(sp.v.* / 0.02) / std.math.log2(sp.hi / 0.02)))
        else
            @floatCast((sp.v.* - sp.lo) / span);
        const def: f32 = if (sp.exp) 0 else @floatCast(-sp.lo / span);
        var rb: [16]u8 = undefined;
        const readout = if (sp.exp and sp.v.* <= 0)
            "OFF"
        else
            std.fmt.bufPrint(&rb, "{d:.1}", .{sp.v.*}) catch "";
        if (ui_ctl.knob(ui, kr, .{ "zknob", ai, k }, &norm, .{ .size = .s, .label = sp.label, .default = def, .readout = readout, .variant = if (sp.exp) .plain else .bipolar })) {
            sp.v.* = if (sp.exp)
                (if (norm < 0.05) 0 else 0.02 * std.math.pow(f64, sp.hi / 0.02, (norm - 0.05) / 0.95))
            else
                sp.lo + span * norm;
            edited = true;
        }
    }
    // CUT: the pack's choke (SFZ group/off_by, the kit's hats), none, or a
    // group 1..8 that the zone both joins and is cut by.
    {
        const kr = Rect.xywh(knobs.x + 4 * kw, knobs.y, knobs.w - 4 * kw, knobs.h);
        const steps: f32 = CUT_MAX;
        var norm: f32 = @floatCast(e.cut[zi] / CUT_MAX);
        var rb: [16]u8 = undefined;
        const readout = cutName(&rb, e.cut[zi], km.zones[zi]);
        if (ui_ctl.knob(ui, kr, .{ "zknob", ai, @as(usize, 4) }, &norm, .{ .size = .s, .label = "CUT", .variant = .stepped, .steps = CUT_MAX + 1, .readout = readout })) {
            e.cut[zi] = @round(norm * steps);
            edited = true;
        }
    }
    // the row is one sound: its layers and round robins take the edit
    if (edited) for (0..n) |zz| if (zz != zi and self.zone_row_of[zz] == self.zone_row_of[zi]) {
        e.level[zz] = e.level[zi];
        e.tune[zz] = e.tune[zi];
        e.decay[zz] = e.decay[zi];
        e.tone[zz] = e.tone[zi];
        e.cut[zz] = e.cut[zi];
    };
}

fn zoneMenuKey(self: *const FyRawMachine) u64 {
    return @as(u64, @intFromPtr(self)) ^ 0x2073_2073_0000_0002;
}

const ZONE_DUPLICATE: u32 = 1;
const ZONE_REVERSE: u32 = 2;
const ZONE_REMOVE_COPY: u32 = 3;

/// A zone row's menu: copy the sound onto the nearest free key, play it
/// backwards, or remove a copy.
fn zoneMenuTick(self: *FyRawMachine, ai: usize) void {
    const key = zoneMenuKey(self);
    if (!ui_menu.isOpen(key)) return;
    const km = &self.asset_keymap[ai];
    if (self.zone_ctx >= km.count) return;
    const zi = self.zone_ctx;
    const name = km.names[zi];
    const z = km.zones[zi];
    const one_key = z.lo_key == z.hi_key;
    const free = if (one_key) keymap.freeKey(km, @intFromFloat(std.math.clamp(z.lo_key, 0, 127))) else null;
    var dup_buf: [32]u8 = undefined;
    var kn: [4]u8 = undefined;
    const dup_label = if (free) |k|
        std.fmt.bufPrint(&dup_buf, "Duplicate to {s}", .{keyName(&kn, @floatFromInt(k))}) catch "Duplicate"
    else
        "Duplicate";
    const d = &self.zone_derive;
    const rev = d.isReversed(name.slice());
    const is_copy = d.copyIndex(name.slice()) != null;
    const items = [_]ui_menu.Item{
        .{ .label = dup_label, .id = ZONE_DUPLICATE, .enabled = free != null and km.count < keymap.MAX_ZONES and d.copy_n < keymap.MAX_DERIVED },
        .{ .label = if (rev) "Play forward" else "Reverse", .id = ZONE_REVERSE, .enabled = rev or d.rev_n < keymap.MAX_DERIVED },
        .{ .separator = true },
        .{ .label = "Remove copy", .id = ZONE_REMOVE_COPY, .enabled = is_copy },
    };
    const picked = ui_menu.pick(key, &items) orelse return;
    switch (picked) {
        ZONE_DUPLICATE => {
            const k = free orelse return;
            var nb: [keymap.NAME_MAX]u8 = undefined;
            const copy_name = uniqueZoneName(km, d, &nb, name.slice());
            d.addCopy(copy_name, name.slice(), k);
            self.rederive(ai);
            // the copy starts as the sound it copies
            const e = &self.zone_edits;
            for (self.asset_keymap[ai].names, 0..) |nm, i| if (std.mem.eql(u8, nm.slice(), copy_name)) {
                e.level[i] = e.level[zi];
                e.tune[i] = e.tune[zi];
                e.decay[i] = e.decay[zi];
                e.tone[i] = e.tone[zi];
                e.cut[i] = e.cut[zi];
            };
            self.selectZoneNamed(ai, copy_name);
        },
        ZONE_REVERSE => {
            d.setReversed(name.slice(), !rev);
            self.rederive(ai);
        },
        ZONE_REMOVE_COPY => {
            d.removeCopy(name.slice());
            self.rederive(ai);
        },
        else => {},
    }
}

/// "<name> 2", "<name> 3", …: the first no zone or copy has, cut to fit.
fn uniqueZoneName(km: *const keymap.Keymap, d: *const keymap.Derive, buf: []u8, base: []const u8) []const u8 {
    var n: usize = 2;
    while (n < 1000) : (n += 1) {
        var sb: [8]u8 = undefined;
        const suffix = std.fmt.bufPrint(&sb, " {d}", .{n}) catch return base;
        const keep = @min(base.len, buf.len - suffix.len);
        @memcpy(buf[0..keep], base[0..keep]);
        @memcpy(buf[keep..][0..suffix.len], suffix);
        const cand = buf[0 .. keep + suffix.len];
        const taken = for (km.names) |nm| {
            if (std.mem.eql(u8, nm.slice(), cand)) break true;
        } else d.copyIndex(cand) != null;
        if (!taken) return cand;
    }
    return base;
}

/// CUT edit steps: 0 the pack's choke, 1 none, n+1 group n.
const CUT_MAX = 9;

/// The zone's choke group as the pack or the CUT edit sets it (0 = none).
fn cutGroup(cut: f64, z: keymap.Zone) f64 {
    return if (cut > 0.5) cut - 1 else z.group;
}

fn cutName(buf: []u8, cut: f64, z: keymap.Zone) []const u8 {
    if (cut > 0.5 and cut < 1.5) return "OFF";
    const g = cutGroup(cut, z);
    if (cut < 0.5) {
        if (g <= 0 and z.off_by <= 0) return "PACK";
        return std.fmt.bufPrint(buf, "PK {d}", .{@as(i32, @intFromFloat(if (g > 0) g else z.off_by))}) catch "";
    }
    return std.fmt.bufPrint(buf, "G{d}", .{@as(i32, @intFromFloat(g))}) catch "";
}

fn keyName(buf: []u8, key: f64) []const u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const k: i32 = @intFromFloat(std.math.clamp(key, 0, 127));
    return std.fmt.bufPrint(buf, "{s}{d}", .{ names[@intCast(@mod(k, 12))], @divFloor(k, 12) - 1 }) catch "";
}

/// Draggable marker bound to control `id`: dragging writes its normalized
/// value live (the audio thread reads it atomically) and the knob follows.
fn drawMarker(self: *FyRawMachine, ui: *Ui, area: Rect, id: []const u8, col: ui_style.Color) void {
    const idx = for (self.desc.controls[0..self.desc.control_count], 0..) |*ctl, i| {
        if (std.mem.eql(u8, ctl.idSlice(), id)) break i;
    } else return;
    const frac = std.math.clamp(@as(f32, self.controlNorm(idx)), 0, 1);
    const x = area.x + @as(i32, @intFromFloat(@round(frac * @as(f32, @floatFromInt(area.w - 1)))));
    const wid = ui.id(.{ "marker", idx });
    const b = ui.behaviorEx(wid, Rect.xywh(x - 4, area.y, 9, area.h), .{ .prio = 1 });
    if (b.held) {
        const nf = std.math.clamp((ui.in.mx - @as(f32, @floatFromInt(area.x))) / @as(f32, @floatFromInt(area.w)), 0, 1);
        self.setControlNorm(idx, nf);
    }
    const hot = ui.isHot(wid);
    if (hot) ui.requestCursor(c.rl.MOUSE_CURSOR_RESIZE_EW, 2);
    ui.rect(Rect.xywh(x, area.y, if (hot) 2 else 1, area.h), col);
    // Grab tab at the top so the handle reads as draggable.
    ui.rect(Rect.xywh(x - 3, area.y, 7, 4), col);
}

// A/D/S/R shape (segment widths from the knob norms, a fixed sustain
// hold), reacting live to the source module's ATK/DEC/SUS/REL knobs.
fn drawAdsrCurve(self: *FyRawMachine, ui: *Ui, area: Rect, source: []const u8, col: ui_style.Color, label_idx: usize) void {
    // Envelope knobs by legend: ATK/DEC/SUS/REL, or the 106's A/D/S/R.
    const atk = controlNormByLabel(self, source, "ATK") orelse controlNormByLabel(self, source, "A") orelse 0.3;
    const dec = controlNormByLabel(self, source, "DEC") orelse controlNormByLabel(self, source, "D") orelse 0.3;
    const sus = controlNormByLabel(self, source, "SUS") orelse controlNormByLabel(self, source, "S") orelse 0.5;
    const rel = controlNormByLabel(self, source, "REL") orelse controlNormByLabel(self, source, "R") orelse 0.3;

    const x0: f32 = @as(f32, @floatFromInt(area.x)) + 2.5;
    const w: f32 = @as(f32, @floatFromInt(area.w)) - 5;
    const top: f32 = @as(f32, @floatFromInt(area.y)) + 12.5; // leave the label row
    const h: f32 = @as(f32, @floatFromInt(area.h)) - 15;
    if (w <= 1 or h <= 1) return;
    const base = top + h;

    const hold: f32 = 0.5;
    const wsum = atk + dec + hold + rel + 0.0001;
    const xa1 = x0 + w * atk / wsum;
    const xd1 = xa1 + w * dec / wsum;
    const xh1 = xd1 + w * hold / wsum;
    const xr1 = xh1 + w * rel / wsum;

    capSeg(ui, x0, 0.0, xa1, 1.0, base, h, col);
    capSeg(ui, xa1, 1.0, xd1, sus, base, h, col);
    ui.line(xd1, base - sus * h, xh1, base - sus * h, col);
    capSeg(ui, xh1, sus, xr1, 0.0, base, h, col);

    // Inline label: the source's first token, in the curve's colour; labels
    // of overlaid sources sit side by side.
    const tok = source[0 .. std.mem.indexOfScalar(u8, source, ' ') orelse source.len];
    _ = ui.text(&ui.fonts.legend, area.x + 2 + @as(i32, @intCast(label_idx)) * 40, area.y, tok[0..@min(tok.len, 11)], col);
}

fn capSeg(ui: *Ui, xa: f32, la: f32, xb: f32, lb: f32, base: f32, h: f32, col: ui_style.Color) void {
    const N: usize = 14;
    var px = xa;
    var py = base - la * h;
    for (1..N + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(N));
        const nx = xa + (xb - xa) * t;
        const ny = base - (la + (lb - la) * capShape(t)) * h;
        ui.line(px, py, nx, ny, col);
        px = nx;
        py = ny;
    }
}

// Compact real-value readout for knobs: 3 significant-ish digits, k-suffix
// above 1000 (so 1.2k, 182, 50.3, 0.055 all fit the tiny font).
fn formatControlValue(buf: *[16:0]u8, v: f64) [*:0]const u8 {
    const av = @abs(v);
    const s = if (av >= 10_000.0)
        std.fmt.bufPrintZ(buf, "{d:.1}k", .{v / 1000.0})
    else if (av >= 1000.0)
        std.fmt.bufPrintZ(buf, "{d:.2}k", .{v / 1000.0})
    else if (av >= 100.0)
        std.fmt.bufPrintZ(buf, "{d:.0}", .{v})
    else if (av >= 10.0)
        std.fmt.bufPrintZ(buf, "{d:.1}", .{v})
    else if (av >= 1.0)
        std.fmt.bufPrintZ(buf, "{d:.2}", .{v})
    else
        std.fmt.bufPrintZ(buf, "{d:.3}", .{v});
    return (s catch return "?").ptr;
}

fn midiToHz(pitch: f32) f64 {
    return 440.0 * @exp(@log(2.0) * ((@as(f64, pitch) - 69.0) / 12.0));
}

const testing = std.testing;

fn testRender(mach: machine.Machine, ctx: *const machine.MachineCtx, l: []f32, r: []f32) void {
    mach.render(mach.state, ctx, l, r);
}

test "raw DSP2 silence fixture renders zeros through generic adapter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/silence.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 32;
    var l = [_]f32{1} ** 32;
    var r = [_]f32{1} ** 32;
    testRender(mach, &ctx, &l, &r);

    for (l, r) |sl, sr| {
        try testing.expectEqual(@as(f32, 0), sl);
        try testing.expectEqual(@as(f32, 0), sr);
    }
}

test "raw DSP2 oscillator fixture responds to note events" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/oscillator.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 45, .velocity = 0.8 },
        .{ .sample_offset = 32, .kind = .note_off, .channel = 0, .note_id = 1, .pitch = 45, .velocity = 0 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 64;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 64;
    var r = [_]f32{0} ** 64;
    testRender(mach, &ctx, &l, &r);

    var pre_off_energy: f64 = 0;
    var post_off_energy: f64 = 0;
    for (l[0..32]) |sample| pre_off_energy += @abs(sample);
    for (l[32..64]) |sample| post_off_energy += @abs(sample);
    try testing.expect(pre_off_energy > 0.01);
    try testing.expect(post_off_energy < 0.000001);
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expectEqual(sl, sr);
    }
}

test "FM-86 plays a note end to end (routing hook + staged voice)" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 57, .velocity = 0.9 },
        .{ .sample_offset = 700, .kind = .note_off, .channel = 0, .note_id = 1, .pitch = 57, .velocity = 0 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 1024;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 1024;
    var r = [_]f32{0} ** 1024;
    testRender(mach, &ctx, &l, &r);

    // Finite, mono-duplicated, and within the clamp.
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expectEqual(sl, sr);
        try testing.expect(@abs(sl) <= 1.0);
    }

    // The default patch (algorithm 1) must make sound once the carrier
    // envelopes have opened, then fall after note-off — proving the algorithm
    // routing hook filled carriers/weights and the staged voice ran.
    var sustain_energy: f64 = 0;
    for (l[300..700]) |s| sustain_energy += @abs(s);
    var release_tail: f64 = 0;
    for (l[1000..1024]) |s| release_tail += @abs(s);
    try testing.expect(sustain_energy > 1.0);
    try testing.expect(release_tail * 16 < sustain_energy);
}

test "FM-86 fy derive routing matches the dx7_algorithms oracle (all 32)" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // master 1.0 so carrier weights compare 1:1 with the oracle (which doesn't
    // fold master); a non-zero feedback to check the fb fields land.
    const feedback: f64 = 0.6;
    mach.set_param.?(mach.state, "master", 1.0);
    mach.set_param.?(mach.state, "feedback", feedback);

    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 16;
    var l = [_]f32{0} ** 16;
    var r = [_]f32{0} ** 16;

    // The ALGO int-step selects each algorithm; the fy derive word fills the
    // routing from its own table. Pin all 27 routing fields against the
    // validated Zig oracle for every algorithm.
    for (1..33) |n| {
        mach.set_param.?(mach.state, "algo", @floatFromInt(n));
        testRender(mach, &ctx, &l, &r); // syncRawParams -> fy derive fills routing

        var want = dx7_algorithms.VoiceParams{};
        dx7_algorithms.applyRouting(&want, dx7_algorithms.dx7_algorithms[n - 1], feedback);

        // Tolerance, not exact: feedback/master flow through the f32 control
        // atomics, so a value like 0.6 comes back as 0.6 + ~1e-7.
        inline for (.{ "w01", "w02", "w03", "w04", "w05", "w12", "w13", "w14", "w15", "w23", "w24", "w25", "w34", "w35", "w45", "c0", "c1", "c2", "c3", "c4", "c5", "fb0", "fb1", "fb2", "fb3", "fb4", "fb5" }) |f| {
            // Fm86Params carries the routing block by name (no inc/lvl prefix).
            const got = inst.readParamF64(try fyFieldOffset(inst, "Fm86Params." ++ f));
            testing.expectApproxEqAbs(@field(want, f), got, 1e-5) catch |e| {
                std.debug.print("algorithm {d} field {s}: want {d} got {d}\n", .{ n, f, @field(want, f), got });
                return e;
            };
        }
    }
}

test "FM-86 routing display lays out all 32 algorithms" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    const disp = for (inst.desc.displays[0..inst.desc.display_count]) |*d| {
        if (d.kind == .algo) break d;
    } else return error.TestUnexpectedResult;

    for (1..33) |n| {
        mach.set_param.?(mach.state, "algo", @floatFromInt(n));
        const g = algoGraph(inst, disp) orelse return error.TestUnexpectedResult;
        // Every operator is drawn, within six columns and six levels.
        for (0..g.n) |i| try testing.expect(g.placed[i]);
        try testing.expect(g.slots >= 1 and g.slots <= 6);
        try testing.expect(g.max_depth <= 5);
    }
}
test "FM-86 plays an imported DX7 preset (E.PIANO 1)" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Find the imported E.PIANO preset and apply it through the real loader.
    const count = mach.preset_count.?(mach.state);
    var idx: i32 = -1;
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(mach.preset_name.?(mach.state, i)), "e-piano-1")) idx = i;
    }
    // The factory bank is generated locally (machines/fm86/tools/dx7_import.py)
    // and may not be committed (Yamaha-derived); validate when present.
    if (idx < 0) return error.SkipZigTest;
    mach.apply_preset.?(mach.state, @intCast(idx));

    // Hold the note across ~0.5 s (render caps a call at MAX_BLOCK), note-on
    // only in the first block, then keep rendering with the gate held.
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 4096;
    var on = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 60, .velocity = 0.9 },
    };

    var attack_rms: f64 = 0;
    var late_rms: f64 = 0;
    var peak: f64 = 0;
    const blocks = 6; // 6 * 4096 ~= 0.5 s
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        if (b == 0) {
            ctx.note_in = @ptrCast(on[0..].ptr);
            ctx.note_in_count = on.len;
        } else {
            ctx.note_in = null;
            ctx.note_in_count = 0;
        }
        var l = [_]f32{0} ** 4096;
        var r = [_]f32{0} ** 4096;
        testRender(mach, &ctx, &l, &r);
        var sum: f64 = 0;
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expectEqual(sl, sr);
            try testing.expect(@abs(sl) <= 1.0);
            sum += @as(f64, sl) * sl;
            peak = @max(peak, @abs(sl));
        }
        const rms = @sqrt(sum / 4096.0);
        if (b == 0) attack_rms = rms;
        if (b == blocks - 1) late_rms = rms;
    }

    try testing.expect(peak > 0.05); // makes sound
    // Still ringing ~0.5 s in — the bug where decay/release was ~10x too fast
    // left this near-silent (notes played only their attack transient).
    try testing.expect(late_rms > 0.01);
    try testing.expect(late_rms > attack_rms * 0.05);
}

test "FM-86 is polyphonic — a chord sounds all three notes" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Three held notes, distinct note ids so the voice pool keeps them all.
    const pitches = [_]f32{ 60, 64, 67 }; // C4, E4, G4
    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = pitches[0], .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 2, .pitch = pitches[1], .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 3, .pitch = pitches[2], .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 4096;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;
    var l = [_]f32{0} ** 4096;
    var r = [_]f32{0} ** 4096;
    testRender(mach, &ctx, &l, &r);

    // Goertzel magnitude at each note's fundamental; all three must be present.
    for (pitches) |p| {
        const hz = midiToHz(p);
        const w = 2.0 * std.math.pi * hz / 48_000.0;
        const cw = @cos(w);
        var s1: f64 = 0;
        var s2: f64 = 0;
        for (l) |x| {
            const s0 = @as(f64, x) + 2.0 * cw * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        const mag = @sqrt(s1 * s1 + s2 * s2 - 2.0 * cw * s1 * s2) * 2.0 / 4096.0;
        try testing.expect(mag > 0.02); // this pitch is sounding
    }
}

test "DS-404 stays finite and bounded under live-style blocks" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/drum2/drum2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    // Night Drive's kit settings.
    inline for (.{ .{ "kick-tune", 52 }, .{ "kick-sweep", 8 }, .{ "kick-decay", 0.42 }, .{ "kick-drive", 2.4 }, .{ "kick-level", 0.8 }, .{ "snare-tune", 190 }, .{ "snare-decay", 0.22 }, .{ "snare-snap", 0.85 }, .{ "snare-tone", 2200 }, .{ "clap-decay", 0.35 }, .{ "hat-level", 1.0 }, .{ "hat-tone", 1.25 }, .{ "hat-chdec", 0.05 }, .{ "hat-ohdec", 0.35 }, .{ "tom-tune", 120 }, .{ "tom-decay", 0.35 }, .{ "master-drive", 1.3 } }) |kv| {
        mach.set_param.?(mach.state, kv[0], kv[1]);
    }
    const sizes = [_]usize{ 512, 471, 64, 256, 1, 333, 128, 512 };
    const pitches = [_]f32{ 36, 38, 39, 42, 45, 46, 60, 64, 0, 127 };
    var l = [_]f32{0} ** 512;
    var r = [_]f32{0} ** 512;
    for ([_]f64{ 44_100, 48_000 }) |sr| {
        var ctx = std.mem.zeroes(machine.MachineCtx);
        ctx.sample_rate = sr;
        var peak: f32 = 0;
        var blk: usize = 0;
        while (blk < 600) : (blk += 1) {
            const n = sizes[blk % sizes.len];
            ctx.block_size = @intCast(n);
            var evs: [2]machine.NoteEvent = undefined;
            var ne: usize = 0;
            if (blk % 3 == 0) {
                evs[ne] = .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = @intCast(blk), .pitch = pitches[(blk / 3) % pitches.len], .velocity = 0.9 };
                ne += 1;
            }
            if (blk % 3 == 1) {
                evs[ne] = .{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = @intCast(blk - 1), .pitch = pitches[(blk / 3) % pitches.len], .velocity = 0 };
                ne += 1;
            }
            ctx.note_in = if (ne > 0) @ptrCast(evs[0..].ptr) else null;
            ctx.note_in_count = @intCast(ne);
            testRender(mach, &ctx, l[0..n], r[0..n]);
            for (l[0..n], r[0..n]) |a, b| {
                if (!std.math.isFinite(a) or !std.math.isFinite(b) or @abs(a) > 4 or @abs(b) > 4) {
                    std.debug.print("sr {d} block {d} (n {d}): {d} {d}\n", .{ sr, blk, n, a, b });
                    return error.TestUnexpectedResult;
                }
                peak = @max(peak, @abs(a));
            }
        }
        try testing.expect(peak > 0.01);
    }
}

test "FM-86 survives many small live-style blocks with note churn" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/fm86/fm86.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 44_100;
    ctx.block_size = 256;
    var l = [_]f32{0} ** 256;
    var r = [_]f32{0} ** 256;

    var blk: usize = 0;
    while (blk < 300) : (blk += 1) {
        // Periodically toss in note-ons (chords + voice stealing) and offs.
        var evs: [4]machine.NoteEvent = undefined;
        var n: usize = 0;
        if (blk % 5 == 0) {
            const base: i32 = @intCast(48 + (blk % 24));
            for (0..3) |k| {
                evs[n] = .{ .sample_offset = @intCast(k * 30), .kind = .note_on, .channel = 0, .note_id = @intCast(blk * 4 + k), .pitch = @floatFromInt(base + @as(i32, @intCast(k * 4))), .velocity = 0.8 };
                n += 1;
            }
        }
        if (blk % 7 == 3) {
            // After any note-ons above — the render loop requires events sorted
            // by sample_offset (the real host guarantees this).
            evs[n] = .{ .sample_offset = 120, .kind = .note_off, .channel = 0, .note_id = @intCast((blk - 1) * 4), .pitch = 0, .velocity = 0 };
            n += 1;
        }
        ctx.note_in = if (n > 0) @ptrCast(evs[0..].ptr) else null;
        ctx.note_in_count = @intCast(n);
        testRender(mach, &ctx, &l, &r);
        for (l) |s| try testing.expect(std.math.isFinite(s));
    }
}

test "raw DSP2 saturator fixture processes audio input through generic adapter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/saturator.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var in_l = [_]f32{0.75} ** 32;
    var in_r = [_]f32{-0.75} ** 32;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 32;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l = [_]f32{0} ** 32;
    var r = [_]f32{0} ** 32;
    testRender(mach, &ctx, &l, &r);

    try testing.expect(l[0] > in_l[0]);
    try testing.expect(r[0] < in_r[0]);
    try testing.expect(@abs(l[0]) <= 1.0);
    try testing.expect(@abs(r[0]) <= 1.0);
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expect(std.math.isFinite(sr));
    }
}

test "raw DSP2 MS-20 fixture renders a finite note through generic adapter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/ms20/ms20.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 45, .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 512;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 512;
    var r = [_]f32{0} ** 512;
    testRender(mach, &ctx, &l, &r);

    var peak: f32 = 0;
    for (l, r) |sl, sr| {
        try testing.expect(std.math.isFinite(sl));
        try testing.expect(std.math.isFinite(sr));
        try testing.expectEqual(sl, sr);
        peak = @max(peak, @abs(sl));
    }
    try testing.expect(peak > 0.001);
    try testing.expect(peak < 4.0); // headroom, not clamped (D5); sane bound ~+12 dBFS
}

/// Byte offset of a ustruct field by its fy introspection constant.
fn fyFieldOffset(inst: *FyRawMachine, name: []const u8) !usize {
    const v = try inst.host.callWord(name);
    return @intCast(@divExact(v, Fy.makeInt(1))); // untag (ints are n << TAG_BITS)
}

test "MS-20 block-prepare derives the LPF, HPF and envelope coefficients in fy" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/ms20/ms20.fy");
    defer inst.machineInterface().deinit.?(inst, testing.allocator);
    inst.syncRawParams(48_000, 120.0);

    const res = inst.readParamF64(try fyFieldOffset(inst, "Ms20VoiceParams.resonance"));
    const drive = inst.readParamF64(try fyFieldOffset(inst, "Ms20VoiceParams.drive"));
    const hres = inst.readParamF64(try fyFieldOffset(inst, "Ms20VoiceParams.hpf-resonance"));
    // Defaults land raw: env amount in octaves, resonance and drive knobs.
    try testing.expectApproxEqAbs(@as(f64, 4.8), inst.readParamF64(try fyFieldOffset(inst, "Ms20VoiceParams.env-amount")), 1e-6); // knobs store f32 positions
    // LPF profile, HOT mode: drive 2.1 x DRV, feedback 10.125 x 0.8 RES,
    // damping 0.62 / (1 + 5.2 x 0.8 RES); the LPF runs at 4x.
    const pr = try fyFieldOffset(inst, "Ms20VoiceParams.lpf-pr");
    try testing.expectApproxEqAbs(2.1 * drive, inst.readParamF64(pr + try fyFieldOffset(inst, "Ms20LpfProfile.drive")), 1e-12);
    try testing.expectApproxEqAbs(10.125 * 0.8 * res, inst.readParamF64(pr + try fyFieldOffset(inst, "Ms20LpfProfile.fb-amt")), 1e-12);
    try testing.expectApproxEqAbs(@max(0.035, 0.62 / (1.0 + 5.2 * 0.8 * res)), inst.readParamF64(pr + try fyFieldOffset(inst, "Ms20LpfProfile.damping")), 1e-12);
    try testing.expectApproxEqAbs(4.0 * 48_000.0, inst.readParamF64(try fyFieldOffset(inst, "Ms20VoiceParams.osr")), 1e-9);
    // HPF damping 1.4 (1 - RES/2)^2.
    const u = @max(0.0, 1.0 - 0.5 * hres);
    try testing.expectApproxEqAbs(1.4 * u * u, inst.readParamF64(try fyFieldOffset(inst, "Ms20VoiceParams.hpf-q")), 1e-12);
    // Envelope sustain passes through to the coefficient block.
    const sus = inst.readParamF64(try fyFieldOffset(inst, "Ms20VoiceParams.amp-sustain"));
    const co = try fyFieldOffset(inst, "Ms20VoiceParams.amp-co");
    try testing.expectApproxEqAbs(sus, inst.readParamF64(co + try fyFieldOffset(inst, "EnvRcCoefs.sus")), 1e-12);
}

test "raw DSP2 delay machine: host buffer injection and echo" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/delay2/delay2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // One buffer request, allocated per channel and injected into both
    // channel states (pointer in cell 0, element count in cell 1).
    try testing.expectEqual(@as(usize, 1), inst.desc.buffer_count);
    const len_f: f64 = @floatFromInt(inst.buffer_mem[0][0].len);
    for (0..2) |ch| {
        const base = ch * MAX_STATE;
        const ptr_bits: *align(8) const usize = @ptrCast(@alignCast(&inst.state_buf[base]));
        try testing.expectEqual(@intFromPtr(inst.buffer_mem[0][ch].ptr), ptr_bits.*);
        const len_cell: *align(8) const f64 = @ptrCast(@alignCast(&inst.state_buf[base + 8]));
        try testing.expectEqual(len_f, len_cell.*);
    }

    // Impulse in the first block, silence after: the wet tap must come back
    // roughly one delay time later, and only on the channel that got fed.
    const block = 512;
    var in_l = [_]f32{0} ** block;
    var in_r = [_]f32{0} ** block;
    in_l[0] = 0.9;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    var echo_l: f64 = 0;
    var echo_r: f64 = 0;
    var blk: usize = 0;
    while (blk < 48) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        if (blk == 0) {
            in_l[0] = 0; // impulse only once
            try testing.expect(l[0] > 0.4); // dry portion passes immediately
        } else {
            for (l) |x| echo_l = @max(echo_l, @abs(x));
            for (r) |x| echo_r = @max(echo_r, @abs(x));
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    try testing.expect(echo_l > 0.05); // wet repeat arrived
    try testing.expect(echo_r < 0.0001); // R state/ring independent of L
}

test "kernel ABI: KernelCtx and IoFrame match ctx.fy's Ctx and Io" {
    var host = FyHost.init(testing.allocator);
    defer host.deinit();
    try host.compileFile("kernels/00-primitives/ctx.fy");
    const Check = struct { name: []const u8, off: usize };
    const ctx_fields = [_]Check{
        .{ .name = "Ctx.size", .off = @sizeOf(KernelCtx) },
        .{ .name = "Ctx.sr", .off = @offsetOf(KernelCtx, "sr") },
        .{ .name = "Ctx.inv-sr", .off = @offsetOf(KernelCtx, "inv_sr") },
        .{ .name = "Ctx.tempo", .off = @offsetOf(KernelCtx, "tempo") },
        .{ .name = "Ctx.beat", .off = @offsetOf(KernelCtx, "beat") },
        .{ .name = "Ctx.frames", .off = @offsetOf(KernelCtx, "frames") },
        .{ .name = "Ctx.chan", .off = @offsetOf(KernelCtx, "chan") },
        .{ .name = "Ctx.hz", .off = @offsetOf(KernelCtx, "hz") },
        .{ .name = "Ctx.vel", .off = @offsetOf(KernelCtx, "vel") },
        .{ .name = "Ctx.pitch", .off = @offsetOf(KernelCtx, "pitch") },
        .{ .name = "Ctx.data", .off = @offsetOf(KernelCtx, "data") },
        .{ .name = "Ctx.legato", .off = @offsetOf(KernelCtx, "legato") },
        .{ .name = "Io.size", .off = @sizeOf(IoFrame) },
        .{ .name = "Io.out-l", .off = @offsetOf(IoFrame, "out_l") },
        .{ .name = "Io.out-r", .off = @offsetOf(IoFrame, "out_r") },
        .{ .name = "Io.in-l", .off = @offsetOf(IoFrame, "in_l") },
        .{ .name = "Io.in-r", .off = @offsetOf(IoFrame, "in_r") },
        .{ .name = "Io.det", .off = @offsetOf(IoFrame, "det") },
        .{ .name = "Io.sc-l", .off = @offsetOf(IoFrame, "sc_l") },
        .{ .name = "Io.sc-r", .off = @offsetOf(IoFrame, "sc_r") },
    };
    for (ctx_fields) |f| {
        const v = try host.callWord(f.name);
        try testing.expectEqual(Fy.makeInt(@intCast(f.off)), v);
    }
}

test "stereo flag: stereo voices write L and R, stereo effects get one true-stereo pass" {
    const block = 64;
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    {
        const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/stereo_voice.fy");
        const mach = inst.machineInterface();
        defer mach.deinit.?(mach.state, testing.allocator);
        const on = [_]machine.NoteEvent{.{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 1 }};
        ctx.note_in = &on;
        ctx.note_in_count = 1;
        testRender(mach, &ctx, &l, &r);
        try testing.expectEqual(@as(f32, 0.25), l[block - 1]);
        try testing.expectEqual(@as(f32, -0.25), r[block - 1]);
        ctx.note_in = null;
        ctx.note_in_count = 0;
    }
    {
        const inst = try FyRawMachine.create(testing.allocator, "machines/raw_fixtures/stereo_swap.fy");
        const mach = inst.machineInterface();
        defer mach.deinit.?(mach.state, testing.allocator);
        var in_l = [_]f32{0.5} ** block;
        var in_r = [_]f32{-0.75} ** block;
        const ports = [_][*]const f32{ &in_l, &in_r };
        ctx.audio_in = @ptrCast(&ports[0]);
        ctx.audio_in_count = 2;
        testRender(mach, &ctx, &l, &r);
        try testing.expectEqual(@as(f32, -0.75), l[0]);
        try testing.expectEqual(@as(f32, 0.5), r[0]);
    }
}

test "mono note stack: last-note priority, releasing the sounding note falls back" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/ms20/ms20.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    const block = 256;
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    const Ev = struct {
        fn on(p: f32) machine.NoteEvent {
            return .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = p, .velocity = 0.8 };
        }
        fn off(p: f32) machine.NoteEvent {
            return .{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = p, .velocity = 0 };
        }
    };
    const steps = [_]struct { ev: machine.NoteEvent, gate: bool, pitch: f32 }{
        .{ .ev = Ev.on(48), .gate = true, .pitch = 48 },
        .{ .ev = Ev.on(52), .gate = true, .pitch = 52 }, // newest wins
        .{ .ev = Ev.off(48), .gate = true, .pitch = 52 }, // not sounding: forgotten
        .{ .ev = Ev.on(55), .gate = true, .pitch = 55 },
        .{ .ev = Ev.off(55), .gate = true, .pitch = 52 }, // falls back to held 52
        .{ .ev = Ev.off(52), .gate = false, .pitch = 52 }, // stack empty: release
    };
    for (steps) |st| {
        const evs = [_]machine.NoteEvent{st.ev};
        ctx.note_in = &evs;
        ctx.note_in_count = 1;
        testRender(mach, &ctx, &l, &r);
        try testing.expectEqual(st.gate, inst.voice_gate[0]);
        try testing.expectEqual(st.pitch, inst.voice_pitch[0]);
    }
}

test "knob smoothing: drags glide over ~20 ms, param sets snap" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/juno2/juno2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    var ci: usize = 0;
    while (!std.mem.eql(u8, inst.desc.controls[ci].idSlice(), "jn-level")) ci += 1;

    const block = 256;
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    testRender(mach, &ctx, &l, &r); // settle

    inst.setControlNormSnap(ci, 0.0);
    testRender(mach, &ctx, &l, &r);
    try testing.expectEqual(@as(f32, 0.0), inst.smooth_norm[ci]);

    // A drag to 1.0 covers 1 - exp(-5.33 ms / 20 ms) ~ 23% in one block.
    inst.setControlNorm(ci, 1.0);
    testRender(mach, &ctx, &l, &r);
    try testing.expect(inst.smooth_norm[ci] > 0.18 and inst.smooth_norm[ci] < 0.30);
    var blk: usize = 0;
    while (blk < 80) : (blk += 1) testRender(mach, &ctx, &l, &r); // ~430 ms
    try testing.expectEqual(@as(f32, 1.0), inst.smooth_norm[ci]); // settles exactly

    // Host param sets (presets, project load) jump.
    mach.set_param.?(mach.state, "jn-level", 0.0);
    testRender(mach, &ctx, &l, &r);
    try testing.expectEqual(@as(f32, 0.0), inst.smooth_norm[ci]);
}

test "voice service: idle voices are skipped, wake on note-on, sleep after release" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/juno2/juno2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    for (inst.voice_idle[0..8]) |idle| try testing.expect(idle);

    const block = 256;
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    const on = [_]machine.NoteEvent{.{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 0.8 }};
    ctx.note_in = &on;
    ctx.note_in_count = 1;
    testRender(mach, &ctx, &l, &r);
    try testing.expect(!inst.voice_idle[0]);
    for (inst.voice_idle[1..8]) |idle| try testing.expect(idle);

    const off = [_]machine.NoteEvent{.{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 0 }};
    ctx.note_in = &off;
    testRender(mach, &ctx, &l, &r);
    try testing.expect(!inst.voice_idle[0]); // still ringing out
    ctx.note_in = null;
    ctx.note_in_count = 0;
    var blk: usize = 0;
    while (blk < 1000 and !inst.voice_idle[0]) : (blk += 1) testRender(mach, &ctx, &l, &r);
    try testing.expect(inst.voice_idle[0]); // release finished -> asleep
    for (l) |x| try testing.expect(@abs(x) < 1e-5);
}

test "delay SYNC follows ctx.tempo: quarter-note echo lands on the beat" {
    const cases = [_]struct { bpm: f64, echo_at: usize }{
        .{ .bpm = 120, .echo_at = 24_000 }, // 0.5 s
        .{ .bpm = 90, .echo_at = 32_000 }, // 0.667 s
    };
    for (cases) |cs| {
        const inst = try FyRawMachine.create(testing.allocator, "machines/delay2/delay2.fy");
        const mach = inst.machineInterface();
        defer mach.deinit.?(mach.state, testing.allocator);
        mach.set_param.?(mach.state, "delay-sync", 1); // SYNC
        mach.set_param.?(mach.state, "delay-div", 4); // 1/4
        mach.set_param.?(mach.state, "delay-fb", 0);
        mach.set_param.?(mach.state, "delay-mix", 1);

        const block = 256;
        var in_l = [_]f32{0} ** block;
        const in_ports = [_][*]const f32{ &in_l, &in_l };
        var ctx = std.mem.zeroes(machine.MachineCtx);
        ctx.sample_rate = 48_000;
        ctx.block_size = block;
        ctx.tempo_bpm = cs.bpm;
        ctx.audio_in = @ptrCast(&in_ports[0]);
        ctx.audio_in_count = 2;
        var l = [_]f32{0} ** block;
        var r = [_]f32{0} ** block;
        var best: f32 = 0;
        var best_at: usize = 0;
        var pos: usize = 0;
        while (pos < cs.echo_at + 2 * block) : (pos += block) {
            in_l[0] = if (pos == 0) 1.0 else 0.0;
            testRender(mach, &ctx, &l, &r);
            for (l, 0..) |x, i| if (pos + i > 16 and @abs(x) > best) {
                best = @abs(x);
                best_at = pos + i;
            };
        }
        try testing.expect(best > 0.5);
        try testing.expect(@abs(@as(i64, @intCast(best_at)) - @as(i64, @intCast(cs.echo_at))) <= 2);
    }
}

test "raw DSP2 reverb machine: wide decorrelated tail" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/verb2/verb2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Centered impulse in: the tail must ring on both channels but differ
    // between them (decorrelated tap sets), and stay finite.
    const block = 512;
    var in_l = [_]f32{0} ** block;
    var in_r = [_]f32{0} ** block;
    in_l[0] = 0.9;
    in_r[0] = 0.9;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    var tail_l: f64 = 0;
    var tail_r: f64 = 0;
    var lr_diff: f64 = 0;
    var blk: usize = 0;
    while (blk < 60) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        if (blk == 0) {
            in_l[0] = 0;
            in_r[0] = 0;
        }
        if (blk >= 20) {
            for (l, r) |sl, sr| {
                tail_l += @abs(sl);
                tail_r += @abs(sr);
                lr_diff += @abs(sl - sr);
            }
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    try testing.expect(tail_l > 0.5); // the tank rings well past the impulse
    try testing.expect(tail_r > 0.5);
    try testing.expect(lr_diff > 0.1 * tail_l); // channels are decorrelated
}

test "raw DSP2 compressor machine: stereo-linked gain" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/comp2/comp2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Loud tone on L only, quiet tone on R: linked detection means the
    // loud left channel must pull the quiet right channel down by the
    // same gain. With per-channel (unlinked) detection R would stay ~1:1.
    const block = 512;
    var in_l: [block]f32 = undefined;
    var in_r: [block]f32 = undefined;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l: [block]f32 = undefined;
    var r: [block]f32 = undefined;
    var phase: f64 = 0;
    var blk: usize = 0;
    var r_gain_db: f64 = 0;
    while (blk < 40) : (blk += 1) {
        for (&in_l, &in_r) |*a, *b| {
            const s = @sin(phase);
            phase += 2.0 * std.math.pi * 1000.0 / 48_000.0;
            a.* = @floatCast(0.9 * s); // ~ -1 dBFS: far over the -18 dB threshold
            b.* = @floatCast(0.02 * s); // ~ -34 dBFS: far under it
        }
        testRender(mach, &ctx, &l, &r);
        if (blk == 39) {
            var in_e: f64 = 0;
            var out_e: f64 = 0;
            for (in_r, r) |x, y| {
                in_e += @as(f64, x) * x;
                out_e += @as(f64, y) * y;
            }
            r_gain_db = 10.0 * std.math.log10(out_e / in_e);
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    // Default: thresh -18, ratio 4 -> the ~-1 dBFS left drives ~12 dB of
    // reduction, which must land on the quiet right channel too.
    try testing.expect(r_gain_db < -8.0);
    try testing.expect(r_gain_db > -20.0);
}

test "raw DSP2 chorus machine: inverted-LFO stereo spread" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/chorus2/chorus2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Mono tone in: with SPREAD = 1 the two channels' modulated taps run
    // mirrored LFOs, so the wet outputs must differ; the difference is
    // the whole point of the Juno stereo.
    const block = 512;
    var in_l: [block]f32 = undefined;
    var in_r: [block]f32 = undefined;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;

    var l: [block]f32 = undefined;
    var r: [block]f32 = undefined;
    var phase: f64 = 0;
    var energy: f64 = 0;
    var lr_diff: f64 = 0;
    var blk: usize = 0;
    while (blk < 30) : (blk += 1) {
        for (&in_l, &in_r) |*a, *b| {
            const s: f32 = @floatCast(0.5 * @sin(phase));
            phase += 2.0 * std.math.pi * 440.0 / 48_000.0;
            a.* = s;
            b.* = s;
        }
        testRender(mach, &ctx, &l, &r);
        if (blk >= 10) {
            for (l, r) |sl, sr| {
                energy += @abs(sl);
                lr_diff += @abs(sl - sr);
            }
        }
        for (l, r) |sl, sr| {
            try testing.expect(std.math.isFinite(sl));
            try testing.expect(std.math.isFinite(sr));
        }
    }
    try testing.expect(energy > 1.0);
    try testing.expect(lr_diff > 0.02 * energy);
}

test "raw DSP2 juno machine: polyphonic chord through the voice pool" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/juno2/juno2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    try testing.expectEqual(@as(usize, 8), inst.desc.voices);

    // C major triad on, then release only the E: C and G keep sounding.
    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 60, .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 64, .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 67, .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 512;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 512;
    var r = [_]f32{0} ** 512;
    testRender(mach, &ctx, &l, &r);

    // Three voices gated on distinct pitches.
    var gated: usize = 0;
    for (inst.voice_gate[0..8]) |g| {
        if (g) gated += 1;
    }
    try testing.expectEqual(@as(usize, 3), gated);

    // Release the E by pitch.
    var off = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = 64, .velocity = 0 },
    };
    ctx.note_in = @ptrCast(off[0..].ptr);
    ctx.note_in_count = 1;
    var blk: usize = 0;
    var energy: f64 = 0;
    while (blk < 20) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        ctx.note_in_count = 0; // only the first block carries the off
        for (l) |x| {
            try testing.expect(std.math.isFinite(x));
            energy += @abs(x);
        }
    }
    gated = 0;
    for (inst.voice_gate[0..8]) |g| {
        if (g) gated += 1;
    }
    try testing.expectEqual(@as(usize, 2), gated);
    try testing.expect(energy > 5.0); // held C+G still sounding
}

test "raw DSP2 funk machine: macro drives the gate stutter" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/funk/funk.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // The funk macro is control 0; render a pluck (loud attack, decaying
    // tail) at min vs max and compare the tail energy. At max the gate
    // slams the tail shut, so its tail/peak ratio must collapse.
    const block = 512;
    var in_l: [block]f32 = undefined;
    var in_r: [block]f32 = undefined;
    const in_ports = [_][*]const f32{ &in_l, &in_r };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&in_ports[0]);
    ctx.audio_in_count = 2;
    var l: [block]f32 = undefined;
    var r: [block]f32 = undefined;

    const run = struct {
        fn pass(mc: machine.Machine, cx: *machine.MachineCtx, il: *[block]f32, ir: *[block]f32, ol: *[block]f32, or_: *[block]f32) struct { peak: f64, tail: f64 } {
            // 64 blocks: a sharp pluck at block 0, decaying, silent tail.
            var peak_sq: f64 = 0;
            var tail_sq: f64 = 0;
            var blk: usize = 0;
            while (blk < 64) : (blk += 1) {
                for (il, ir, 0..) |*aa, *bb, i| {
                    const n: f64 = @floatFromInt(blk * block + i);
                    const env = @exp(-n / 9000.0);
                    var s: f64 = 0;
                    var h: usize = 1;
                    while (h <= 8) : (h += 1) {
                        s += @sin(2.0 * std.math.pi * 220.0 * @as(f64, @floatFromInt(h)) * n / 48000.0) / @as(f64, @floatFromInt(h));
                    }
                    const v: f32 = @floatCast(0.4 * env * s);
                    aa.* = v;
                    bb.* = v;
                }
                mc.render(mc.state, cx, ol, or_);
                for (ol) |x| {
                    if (blk < 3) peak_sq += @as(f64, x) * x;
                    if (blk >= 40) tail_sq += @as(f64, x) * x;
                }
            }
            return .{ .peak = @sqrt(peak_sq), .tail = @sqrt(tail_sq) };
        }
    };

    inst.setControlNorm(0, 0.0); // clean
    const clean = run.pass(mach, &ctx, &in_l, &in_r, &l, &r);
    mach.reset(mach.state);
    inst.setControlRaw(0, 1.0); // funk macro is a knob (norm), 1.0 = full
    inst.setControlNorm(0, 1.0); // OVERLOAD
    const loud = run.pass(mach, &ctx, &in_l, &in_r, &l, &r);

    try testing.expect(std.math.isFinite(clean.peak) and std.math.isFinite(loud.peak));
    try testing.expect(clean.peak > 0.01); // the effect passes audio
    // Tail-to-peak ratio collapses under the gate.
    const clean_ratio = clean.tail / @max(clean.peak, 1e-9);
    const loud_ratio = loud.tail / @max(loud.peak, 1e-9);
    try testing.expect(loud_ratio < clean_ratio * 0.5);
}

test "raw DSP2 sampler machine: asset loads and polyphonic notes sound" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // The bundled keymap loaded into the arena and got injected into params.
    try testing.expectEqual(@as(usize, 1), inst.desc.asset_count);
    try testing.expect(inst.desc.assets[0].keymap);
    try testing.expectEqual(@as(usize, 1), inst.asset_keymap[0].count);
    try testing.expect(inst.asset_keymap[0].pool.len > 1000);
    const off = inst.desc.assets[0].ptr_offset;
    const ptr_bits: *align(8) const usize = @ptrCast(@alignCast(&inst.params_buf[off]));
    try testing.expectEqual(@intFromPtr(inst.asset_keymap[0].pool.ptr), ptr_bits.*);
    try testing.expectEqual(@as(usize, 8), inst.desc.voices);

    // Two-note chord through the voice pool produces sound; reset silences.
    var events = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 57, .velocity = 0.9 }, // A3 = root
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = 64, .velocity = 0.9 },
    };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = 512;
    ctx.note_in = @ptrCast(events[0..].ptr);
    ctx.note_in_count = events.len;

    var l = [_]f32{0} ** 512;
    var r = [_]f32{0} ** 512;
    var energy: f64 = 0;
    var blk: usize = 0;
    while (blk < 8) : (blk += 1) {
        testRender(mach, &ctx, &l, &r);
        ctx.note_in_count = 0;
        for (l) |x| {
            try testing.expect(std.math.isFinite(x));
            energy += @abs(x);
        }
    }
    try testing.expect(energy > 1.0); // the sample is playing

    // Runtime hot-swap (the path the LOAD button drives, minus the dialog):
    // the params pointer must follow the new buffer, the peak cache rebuild,
    // and the old buffer free without leaking (testing allocator enforces).
    const old_ptr = @intFromPtr(inst.asset_keymap[0].pool.ptr);
    try testing.expect(inst.loadAssetRuntime(0, "machines/sampler/assets/default.wav"));
    const new_ptr = @intFromPtr(inst.asset_keymap[0].pool.ptr);
    try testing.expect(new_ptr != old_ptr); // a fresh allocation
    const pbits: *align(8) const usize = @ptrCast(@alignCast(&inst.params_buf[off]));
    try testing.expectEqual(new_ptr, pbits.*);
    try testing.expectEqual(@as(usize, 1), inst.asset_keymap[0].count);
}

const keymap_test = struct {
    extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern fn close(fd: c_int) c_int;
    extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    const O_WRONLY: c_int = 1;
    const O_CREAT: c_int = 0x200;
    const O_TRUNC: c_int = 0x400;
    const dir = ".zig-cache/tmp/keymap-test";

    fn z(buf: []u8, path: []const u8) [*:0]const u8 {
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return @ptrCast(buf.ptr);
    }

    fn mkdirs(sub: []const u8) void {
        var b: [256]u8 = undefined;
        _ = mkdir(z(&b, ".zig-cache/tmp"), 0o755);
        _ = mkdir(z(&b, dir), 0o755);
        var p: [256]u8 = undefined;
        const full = std.fmt.bufPrint(&p, "{s}/{s}", .{ dir, sub }) catch return;
        _ = mkdir(z(&b, full), 0o755);
    }

    fn put(buf: []u8, at: *usize, bytes: []const u8) void {
        @memcpy(buf[at.*..][0..bytes.len], bytes);
        at.* += bytes.len;
    }

    fn le32(v: u32) [4]u8 {
        return .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) };
    }

    /// 16-bit mono WAV of a sine at hz for secs, with a smpl chunk when
    /// root or loop is given.
    fn sine(alloc: std.mem.Allocator, path: []const u8, hz: f64, secs: f64, root: ?u32, loop: ?[2]u32) !void {
        const sr: u32 = 48_000;
        const n: usize = @intFromFloat(secs * sr);
        const smpl_len: u32 = if (root != null or loop != null) 36 + (if (loop != null) @as(u32, 24) else 0) else 0;
        const total = 12 + 24 + (if (smpl_len > 0) 8 + smpl_len else 0) + 8 + n * 2;
        const buf = try alloc.alloc(u8, total);
        defer alloc.free(buf);
        @memset(buf, 0);
        var at: usize = 0;
        put(buf, &at, "RIFF");
        put(buf, &at, &le32(@intCast(total - 8)));
        put(buf, &at, "WAVEfmt ");
        put(buf, &at, &le32(16));
        put(buf, &at, &.{ 1, 0, 1, 0 });
        put(buf, &at, &le32(sr));
        put(buf, &at, &le32(sr * 2));
        put(buf, &at, &.{ 2, 0, 16, 0 });
        if (smpl_len > 0) {
            put(buf, &at, "smpl");
            put(buf, &at, &le32(smpl_len));
            const base = at;
            at += smpl_len;
            @memcpy(buf[base + 12 ..][0..4], &le32(root orelse 60));
            if (loop) |lp| {
                @memcpy(buf[base + 28 ..][0..4], &le32(1));
                @memcpy(buf[base + 44 ..][0..4], &le32(lp[0]));
                @memcpy(buf[base + 48 ..][0..4], &le32(lp[1] - 1));
            }
        }
        put(buf, &at, "data");
        put(buf, &at, &le32(@intCast(n * 2)));
        for (0..n) |i| {
            const t: f64 = @as(f64, @floatFromInt(i)) / sr;
            const v: i16 = @intFromFloat(@round(0.5 * 32767 * @sin(2 * std.math.pi * hz * t)));
            const u: u16 = @bitCast(v);
            put(buf, &at, &.{ @truncate(u), @truncate(u >> 8) });
        }
        try writeAll(path, buf);
    }

    fn writeAll(path: []const u8, bytes: []const u8) !void {
        var b: [512]u8 = undefined;
        const fd = open(z(&b, path), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
        if (fd < 0) return error.OpenFailed;
        defer _ = close(fd);
        if (write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
    }

    /// Play `events` into the first block, render `blocks`, return L.
    fn play(inst: *FyRawMachine, events: []machine.NoteEvent, blocks: usize, out: []f32) void {
        const mach = inst.machineInterface();
        var ctx = std.mem.zeroes(machine.MachineCtx);
        ctx.sample_rate = 48_000;
        ctx.block_size = 512;
        ctx.note_in = @ptrCast(events.ptr);
        ctx.note_in_count = @intCast(events.len);
        var r = [_]f32{0} ** 512;
        for (0..blocks) |bi| {
            testRender(mach, &ctx, out[bi * 512 ..][0..512], &r);
            ctx.note_in_count = 0;
        }
    }

    /// Rising zero crossings per second over x.
    fn freq(x: []const f32) f64 {
        var n: usize = 0;
        var first: ?usize = null;
        var last: usize = 0;
        for (1..x.len) |i| if (x[i - 1] <= 0 and x[i] > 0) {
            if (first == null) first = i;
            last = i;
            n += 1;
        };
        if (n < 2) return 0;
        return @as(f64, @floatFromInt(n - 1)) * 48_000 / @as(f64, @floatFromInt(last - first.?));
    }

    fn rms(x: []const f32) f64 {
        var acc: f64 = 0;
        for (x) |v| acc += @as(f64, v) * v;
        return @sqrt(acc / @as(f64, @floatFromInt(@max(x.len, 1))));
    }

    fn on(pitch: f32, vel: f32) machine.NoteEvent {
        return .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = -1, .pitch = pitch, .velocity = vel };
    }
    fn off(pitch: f32) machine.NoteEvent {
        return .{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = -1, .pitch = pitch, .velocity = 0 };
    }
};

test "sampler keymap: a folder of note-named samples maps by key, pitch follows the root" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("tones");
    try T.sine(a, T.dir ++ "/tones/tone_C3.wav", 130.8128, 1.0, null, null);
    try T.sine(a, T.dir ++ "/tones/tone_C5.wav", 523.2511, 1.0, null, null);
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/tones"));
    try testing.expectEqual(@as(usize, 2), inst.asset_keymap[0].count);

    var out = [_]f32{0} ** (512 * 16);
    // E3 falls in C3's half (0..60): 130.81 * 2^(4/12)
    var e1 = [_]machine.NoteEvent{T.on(52, 1)};
    T.play(inst, &e1, 16, &out);
    try testing.expectApproxEqRel(@as(f64, 164.81), T.freq(out[2048..]), 0.01);
    var e1o = [_]machine.NoteEvent{T.off(52)};
    T.play(inst, &e1o, 16, &out);
    // A4 falls in C5's half: 523.25 * 2^(-3/12)
    var e2 = [_]machine.NoteEvent{T.on(69, 1)};
    T.play(inst, &e2, 16, &out);
    try testing.expectApproxEqRel(@as(f64, 440.0), T.freq(out[2048..]), 0.01);
}

test "sampler keymap: smpl root and loop hold a note past the sample's end" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("");
    // 0.1 s of 480 Hz recorded as B4 (71), looped over its second half
    try T.sine(a, T.dir ++ "/loop.wav", 480, 0.1, 71, .{ 2400, 4800 });
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/loop.wav"));
    const z = inst.asset_keymap[0].zones[0];
    try testing.expectEqual(@as(f64, 71), z.root);
    try testing.expectEqual(keymap.LOOP_ON, z.loop_mode);
    var out = [_]f32{0} ** (512 * 24);
    var ev = [_]machine.NoteEvent{T.on(71, 1)};
    T.play(inst, &ev, 24, &out);
    // 0.25 s in, long past the 0.1 s sample, still sounding at pitch
    const tail = out[512 * 20 ..];
    try testing.expect(T.rms(tail) > 0.1);
    try testing.expectApproxEqRel(@as(f64, 480), T.freq(tail), 0.01);
}

test "sampler keymap: drum folder, one-shots ignore note-off, closed hat chokes open" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("kit");
    try T.sine(a, T.dir ++ "/kit/kick.wav", 60, 0.5, null, null);
    try T.sine(a, T.dir ++ "/kit/open hat.wav", 3000, 1.0, null, null);
    try T.sine(a, T.dir ++ "/kit/closed hat.wav", 5000, 0.01, null, null);
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/kit"));
    try testing.expectEqual(@as(usize, 3), inst.asset_keymap[0].count);

    var out = [_]f32{0} ** (512 * 8);
    // kick on and straight off: a one-shot keeps playing
    var k = [_]machine.NoteEvent{ T.on(36, 1), T.off(36) };
    T.play(inst, &k, 8, &out);
    try testing.expect(T.rms(out[512 * 6 ..]) > 0.05);
    try testing.expectApproxEqRel(@as(f64, 60), T.freq(out[512..]), 0.02);
    // let the kick finish
    var none = [_]machine.NoteEvent{};
    var long = [_]f32{0} ** (512 * 48);
    T.play(inst, &none, 48, &long);

    // open hat rings; a closed hat silences it within a few ms
    var oh = [_]machine.NoteEvent{T.on(46, 1)};
    T.play(inst, &oh, 4, &out);
    try testing.expect(T.rms(out[512 * 2 .. 512 * 4]) > 0.1);
    var ch = [_]machine.NoteEvent{T.on(42, 1)};
    T.play(inst, &ch, 8, &out);
    // the 10 ms closed hat is over and the open hat is gone
    try testing.expect(T.rms(out[512 * 3 ..]) < 0.001);
}

test "sampler MODEL sets the engine knobs; VARI and FIXED at a low RATE stay in tune" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("clk");
    try T.sine(a, T.dir ++ "/clk/tone_A4.wav", 440, 1.0, null, null);
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/clk"));
    const find = struct {
        fn of(m: *FyRawMachine, id: []const u8) usize {
            for (m.desc.controls[0..m.desc.control_count], 0..) |*ctl, i| if (std.mem.eql(u8, ctl.idSlice(), id)) return i;
            unreachable;
        }
    }.of;

    // SP-1200: FIXED clock, 26.04 kHz, 12 bits
    const model = find(inst, "smp-model");
    const sp = for (0..inst.desc.controls[model].option_count) |i| {
        if (std.mem.eql(u8, std.mem.span(inst.desc.controls[model].optionLabelZ(i)), "SP-1200")) break i;
    } else unreachable;
    pickOption(inst, model, sp);
    const rate = find(inst, "smp-rate");
    try testing.expectApproxEqRel(@as(f64, 26040), normToValue(inst.desc.controls[rate], inst.controlNorm(rate)), 1e-3);
    try testing.expectEqual(@as(usize, 2), switchIndex(inst.desc.controls[find(inst, "smp-engine")], inst.controlNorm(find(inst, "smp-engine"))));

    var vari = [_]f32{0} ** (512 * 8);
    var fixed = [_]f32{0} ** (512 * 8);
    var none = [_]machine.NoteEvent{};
    var tail = [_]f32{0} ** (512 * 64);
    // the filter keeps the images out of the zero-crossing count
    applyControlValue(inst, "smp-filter", 2000);
    applyControlValue(inst, "smp-rate", 8000);
    // a fifth up: 659 Hz off an 8 kHz store
    var ev = [_]machine.NoteEvent{T.on(76, 1)};
    applyControlValue(inst, "smp-engine", 2);
    T.play(inst, &ev, 8, &fixed);
    T.play(inst, &none, 64, &tail);
    applyControlValue(inst, "smp-engine", 1);
    T.play(inst, &ev, 8, &vari);
    for (fixed, vari) |x, y| try testing.expect(std.math.isFinite(x) and std.math.isFinite(y));
    try testing.expectApproxEqRel(@as(f64, 659.26), T.freq(vari[512 .. 512 * 6]), 0.02);
    try testing.expectApproxEqRel(@as(f64, 659.26), T.freq(fixed[512 .. 512 * 6]), 0.02);
    // the two clocks put different steps on the output
    var diff: f64 = 0;
    for (fixed[512..], vari[512..]) |x, y| diff += @abs(@as(f64, x) - y);
    try testing.expect(diff / @as(f64, @floatFromInt(fixed.len - 512)) > 1e-3);
}

test "sampler zones: CUT overrides the pack's choke per zone" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("cutkit");
    try T.sine(a, T.dir ++ "/cutkit/snare.wav", 200, 0.01, null, null);
    try T.sine(a, T.dir ++ "/cutkit/open hat.wav", 3000, 1.0, null, null);
    try T.sine(a, T.dir ++ "/cutkit/closed hat.wav", 5000, 0.01, null, null);
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/cutkit"));
    const km = &inst.asset_keymap[0];
    const idx = struct {
        fn of(k: *const keymap.Keymap, name: []const u8) usize {
            for (k.names[0..k.count], 0..) |nm, i| if (std.mem.eql(u8, nm.slice(), name)) return i;
            unreachable;
        }
    }.of;
    var out = [_]f32{0} ** (512 * 8);
    var none = [_]machine.NoteEvent{};
    var long = [_]f32{0} ** (512 * 96);

    // OFF on the open hat: the closed hat no longer cuts it
    inst.zone_edits.cut[idx(km, "open hat")] = 1;
    var oh = [_]machine.NoteEvent{T.on(46, 1)};
    T.play(inst, &oh, 2, &out);
    var ch = [_]machine.NoteEvent{T.on(42, 1)};
    T.play(inst, &ch, 8, &out);
    try testing.expect(T.rms(out[512 * 3 ..]) > 0.1);
    T.play(inst, &none, 96, &long);

    // snare and open hat in group 1: the snare cuts the hat
    inst.zone_edits.cut[idx(km, "open hat")] = 2;
    inst.zone_edits.cut[idx(km, "snare")] = 2;
    T.play(inst, &oh, 2, &out);
    var sn = [_]machine.NoteEvent{T.on(38, 1)};
    T.play(inst, &sn, 8, &out);
    try testing.expect(T.rms(out[512 * 3 ..]) < 0.001);
}

test "sampler zones: a reversed copy loads from the zones JSON, plays and writes back" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("revkit");
    try T.sine(a, T.dir ++ "/revkit/snare.wav", 200, 0.05, null, null);
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/revkit"));
    const km = &inst.asset_keymap[0];
    try testing.expectEqual(@as(usize, 1), km.count);
    const snare_key = km.zones[0].lo_key;

    var parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"snare":{"level":-3},"snare 2":{"level":-6,"copy":"snare","key":60,"reverse":true}}
    , .{});
    defer parsed.deinit();
    applyZonesJsonImpl(inst, parsed.value);
    try testing.expectEqual(@as(usize, 2), km.count);
    const fwd = km.samples(km.zones[0]);
    const back = km.samples(km.zones[1]);
    try testing.expectEqual(fwd.len, back.len);
    for (fwd, 0..) |v, i| try testing.expectEqual(v, back[back.len - 1 - i]);
    try testing.expectEqual(@as(f64, 60), km.zones[1].lo_key);
    try testing.expectEqual(snare_key, km.zones[0].lo_key);
    try testing.expectEqual(@as(f64, -6), inst.zone_edits.level[1]);
    try testing.expectEqual(@as(f64, -3), inst.zone_edits.level[0]);

    var out = [_]f32{0} ** (512 * 4);
    var ev = [_]machine.NoteEvent{T.on(60, 1)};
    T.play(inst, &ev, 4, &out);
    try testing.expect(T.rms(out[0..]) > 0.01);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try writeZonesJsonImpl(inst, &json, a);
    try testing.expect(std.mem.indexOf(u8, json.items, "\"snare 2\":{\"level\":-6") != null);
    try testing.expect(std.mem.indexOf(u8, json.items, "\"reverse\":true,\"copy\":\"snare\",\"key\":60}") != null);

    // a preset without zones drops the copy
    resetZoneEdits(inst);
    try testing.expectEqual(@as(usize, 1), km.count);
}

test "sampler keymap: sfz round robin alternates per key" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("rr");
    try T.sine(a, T.dir ++ "/rr/one.wav", 220, 0.2, null, null);
    try T.sine(a, T.dir ++ "/rr/two.wav", 330, 0.2, null, null);
    try T.writeAll(T.dir ++ "/rr/test.sfz",
        \\<group> key=57 seq_length=2 loop_mode=one_shot
        \\<region> sample=one.wav seq_position=1
        \\<region> sample=two.wav seq_position=2
    );
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/rr/test.sfz"));
    var out = [_]f32{0} ** (512 * 24);
    var ev = [_]machine.NoteEvent{T.on(57, 1)};
    for ([_]f64{ 220, 330, 220, 330 }) |want| {
        // 24 blocks outlast the 0.2 s one-shot, so notes don't overlap
        T.play(inst, &ev, 24, &out);
        try testing.expectApproxEqRel(want, T.freq(out[512 .. 512 * 12]), 0.01);
    }
}

test "sampler keymap: a release zone plays at note-off, in the same voice" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("relz");
    try T.sine(a, T.dir ++ "/relz/body.wav", 220, 2.0, null, null);
    try T.sine(a, T.dir ++ "/relz/thump.wav", 330, 0.3, null, null);
    try T.writeAll(T.dir ++ "/relz/test.sfz",
        \\<region> sample=body.wav key=57
        \\<region> sample=thump.wav key=57 trigger=release rt_decay=20
    );
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/relz/test.sfz"));
    applyControlValue(inst, "smp-rel", 0.01);
    var out = [_]f32{0} ** (512 * 12);
    // held: only the body, at pitch
    var on = [_]machine.NoteEvent{T.on(57, 1)};
    T.play(inst, &on, 12, &out);
    try testing.expectApproxEqRel(@as(f64, 220), T.freq(out[1024..]), 0.01);
    const held_s: f64 = 12.0 * 512.0 / 48000.0;
    // released: the body's 10 ms release is over, the thump rings
    var off = [_]machine.NoteEvent{T.off(57)};
    T.play(inst, &off, 12, &out);
    try testing.expectApproxEqRel(@as(f64, 330), T.freq(out[2048 .. 512 * 8]), 0.01);
    try testing.expect(!inst.voice_idle[0]);
    // rt_decay: 20 dB per second held
    const want = 0.5 * std.math.pow(f64, 10, -20 * held_s / 20) * 0.7 / std.math.sqrt2;
    try testing.expectApproxEqRel(want, T.rms(out[2048 .. 512 * 8]), 0.1);
    // a second note-off starts nothing
    var none = [_]machine.NoteEvent{};
    var tail = [_]f32{0} ** (512 * 32);
    T.play(inst, &none, 32, &tail);
    var again = [_]f32{0} ** (512 * 8);
    T.play(inst, &off, 8, &again);
    try testing.expect(T.rms(&again) < 1e-4);
}

test "sampler keymap: swapping to a smaller keymap mid-note doesn't read the old pool" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("swap");
    try T.sine(a, T.dir ++ "/swap/long_A3.wav", 220, 3.0, null, null);
    try T.sine(a, T.dir ++ "/swap/short_A3.wav", 220, 0.05, null, null);
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/swap/long_A3.wav"));
    var out = [_]f32{0} ** (512 * 200);
    // a note deep into the 3 s sample, far past the short one's end
    var ev = [_]machine.NoteEvent{T.on(57, 1)};
    T.play(inst, &ev, 200, &out);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/swap/short_A3.wav"));
    var none = [_]machine.NoteEvent{};
    var after = [_]f32{0} ** (512 * 4);
    T.play(inst, &none, 4, &after);
    for (after) |x| try testing.expectEqual(@as(f32, 0), x);
    // and the new map plays
    T.play(inst, &ev, 4, &after);
    try testing.expect(T.rms(&after) > 0.01);
}

test "unfairlight: 16 KB of voice RAM at RATE, segment loops, in tune on the card's clock" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("cmi");
    try T.sine(a, T.dir ++ "/cmi/tone_A3.wav", 220, 3.0, null, null);
    const inst = try FyRawMachine.create(a, "machines/unfairlight/unfairlight.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/cmi/tone_A3.wav"));
    applyControlValue(inst, "cmi-rate", 16384);
    applyControlValue(inst, "cmi-filter", 255);
    var out = [_]f32{0} ** (512 * 150);
    var tail = [_]f32{0} ** (512 * 40);
    // a fifth up, held: in tune, and the RAM (16384 samples at 16384 Hz,
    // 1 s at the root, 2/3 s a fifth up) runs out
    var ev = [_]machine.NoteEvent{T.on(64, 1)};
    T.play(inst, &ev, 150, &out);
    try testing.expectApproxEqRel(@as(f64, 329.63), T.freq(out[512 .. 512 * 50]), 0.003);
    try testing.expect(T.rms(out[512 * 20 .. 512 * 55]) > 0.05);
    try testing.expect(T.rms(out[512 * 66 ..]) < 1e-4);
    var off = [_]machine.NoteEvent{T.off(64)};
    T.play(inst, &off, 40, &tail);
    // looped on segments 0..127: still sounding past the RAM's end
    applyControlValue(inst, "cmi-loop", 1);
    T.play(inst, &ev, 150, &out);
    try testing.expect(T.rms(out[512 * 100 ..]) > 0.05);
    for (out) |x| try testing.expect(std.math.isFinite(x));
    T.play(inst, &off, 40, &tail);

    // START: 96 segments in, unlooped, the note runs out after the last 32
    applyControlValue(inst, "cmi-loop", 0);
    applyControlValue(inst, "cmi-start", 96);
    var at_root = [_]machine.NoteEvent{T.on(57, 1)};
    T.play(inst, &at_root, 150, &out);
    try testing.expect(T.rms(out[512 * 2 .. 512 * 20]) > 0.05);
    try testing.expect(T.rms(out[512 * 40 ..]) < 1e-4);
    var off57 = [_]machine.NoteEvent{T.off(57)};
    T.play(inst, &off57, 40, &tail);

    // VIB: a semitone of vibrato at 2 Hz sweeps the pitch around the root
    applyControlValue(inst, "cmi-start", 0);
    applyControlValue(inst, "cmi-loop", 1);
    applyControlValue(inst, "cmi-vib-depth", 1);
    applyControlValue(inst, "cmi-vib-rate", 2);
    T.play(inst, &at_root, 150, &out);
    // a quarter cycle in (125 ms) the pitch is near its top, at 3/4 near its bottom
    const top = T.freq(out[512 * 10 .. 512 * 14]);
    const bottom = T.freq(out[512 * 33 .. 512 * 37]);
    try testing.expect(top > 220.0 * 1.03);
    try testing.expect(bottom < 220.0 / 1.03);
    // over whole cycles it centres on the root
    try testing.expectApproxEqRel(@as(f64, 220), T.freq(out[0 .. 512 * 94]), 0.01);
}

test "sampler keymap: sfz velocity layers and ranges" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("sfz");
    try T.sine(a, T.dir ++ "/sfz/soft.wav", 220, 0.5, null, null);
    try T.sine(a, T.dir ++ "/sfz/hard.wav", 330, 0.5, null, null);
    try T.writeAll(T.dir ++ "/sfz/test.sfz",
        \\<group> lokey=0 hikey=127 pitch_keycenter=a3
        \\<region> sample=soft.wav hivel=63
        \\<region> sample=hard.wav lovel=64
    );
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/sfz/test.sfz"));
    try testing.expectEqual(@as(usize, 2), inst.asset_keymap[0].count);
    var out = [_]f32{0} ** (512 * 12);
    var soft = [_]machine.NoteEvent{T.on(57, 0.3)};
    T.play(inst, &soft, 12, &out);
    try testing.expectApproxEqRel(@as(f64, 220), T.freq(out[1024..]), 0.01);
    var so = [_]machine.NoteEvent{T.off(57)};
    T.play(inst, &so, 12, &out);
    var hard = [_]machine.NoteEvent{T.on(57, 0.9)};
    T.play(inst, &hard, 12, &out);
    try testing.expectApproxEqRel(@as(f64, 330), T.freq(out[1024..]), 0.01);
}

test "sampler CLOCK engine: drop-sample playback at BITS stays in tune" {
    const T = keymap_test;
    const a = testing.allocator;
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    applyControlValue(inst, "smp-engine", 1);
    applyControlValue(inst, "smp-bits", 8);
    applyControlValue(inst, "smp-filter", 8000);
    applyControlValue(inst, "smp-trk", 1);
    var out = [_]f32{0} ** (512 * 8);
    // the bundled pluck is A3 = 220 Hz; an octave up
    var ev = [_]machine.NoteEvent{T.on(69, 1)};
    T.play(inst, &ev, 8, &out);
    for (out) |x| try testing.expect(std.math.isFinite(x));
    try testing.expect(T.rms(out[512..]) > 0.01);
    try testing.expectApproxEqRel(@as(f64, 440), T.freq(out[512 .. 512 * 5]), 0.02);
}

test "sampler zones: per-zone level, tune and decay; kit labels; edits follow names" {
    const T = keymap_test;
    const a = testing.allocator;
    T.mkdirs("kit2");
    try T.sine(a, T.dir ++ "/kit2/kick.wav", 100, 1.0, null, null);
    try T.sine(a, T.dir ++ "/kit2/clap.wav", 400, 1.0, null, null);
    const inst = try FyRawMachine.create(a, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, a);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/kit2"));
    const km = &inst.asset_keymap[0];
    // clap sorts first: zone 0 = clap on 39, zone 1 = kick on 36
    try testing.expectEqualStrings("clap", km.names[0].slice());

    // The piano roll gets the kit's names, sorted by key.
    const labels = mach.noteLabels();
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqual(@as(u8, 36), labels[0].pitch);
    try testing.expectEqualStrings("KICK", labels[0].labelSlice());
    try testing.expectEqualStrings("CLAP", labels[1].labelSlice());

    var out = [_]f32{0} ** (512 * 8);
    var ev = [_]machine.NoteEvent{T.on(39, 1)};
    T.play(inst, &ev, 8, &out);
    const flat = T.rms(out[512 * 2 ..]);
    var none = [_]machine.NoteEvent{};
    var long = [_]f32{0} ** (512 * 96);
    T.play(inst, &none, 96, &long);

    // LEVEL -12 dB on the clap only, +12 st TUNE on it
    inst.zone_edits.level[0] = -12;
    inst.zone_edits.tune[0] = 12;
    T.play(inst, &ev, 8, &out);
    try testing.expectApproxEqRel(flat * 0.2512, T.rms(out[512 * 2 ..]), 0.03);
    try testing.expectApproxEqRel(@as(f64, 800), T.freq(out[512 * 2 ..]), 0.01);
    try testing.expectEqual(@as(f64, 0), inst.zone_edits.last); // the panel sees which zone played
    T.play(inst, &none, 96, &long);

    // DECAY 50 ms on the kick: gone 0.2 s in
    inst.zone_edits.decay[1] = 0.05;
    var k = [_]machine.NoteEvent{T.on(36, 1)};
    var kout = [_]f32{0} ** (512 * 24);
    T.play(inst, &k, 24, &kout);
    try testing.expect(T.rms(kout[512 * 20 ..]) < 1e-4);
    try testing.expect(T.rms(kout[0..1024]) > 0.05);

    // Edits by name: JSON out, reload the kit, they come back.
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(a);
    try writeZonesJsonImpl(inst, &js, a);
    try testing.expect(std.mem.indexOf(u8, js.items, "\"clap\":{\"level\":-12") != null);
    try testing.expect(inst.loadAssetRuntime(0, T.dir ++ "/kit2"));
    try testing.expectEqual(@as(f64, -12), inst.zone_edits.level[0]);
    try testing.expectEqual(@as(f64, 0.05), inst.zone_edits.decay[1]);
    resetZoneEdits(inst);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, js.items, .{});
    defer parsed.deinit();
    applyZonesJsonImpl(inst, parsed.value);
    try testing.expectEqual(@as(f64, 12), inst.zone_edits.tune[0]);

    // A melodic keymap keeps the chromatic roll.
    try testing.expect(inst.loadAssetRuntime(0, "machines/sampler/assets/default.wav"));
    try testing.expectEqual(@as(usize, 0), mach.noteLabels().len);
}

test "raw machine presets: scan factory, save round-trip, apply restores" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/drum2/drum2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Factory presets present and sorted.
    try testing.expect(inst.presets.count >= 2);
    try testing.expect(inst.presets.contains("808-boom"));
    try testing.expect(inst.presets.contains("909-punch"));

    // Move a knob, save, perturb, apply — value comes back.
    inst.setControlNorm(0, 0.25);
    const before = normToValue(inst.desc.controls[0], inst.controlNorm(0));
    const idx = savePresetImpl(inst) orelse return error.PresetSaveFailed;
    inst.setControlNorm(0, 0.9);
    applyPresetImpl(inst, idx);
    const after = normToValue(inst.desc.controls[0], inst.controlNorm(0));
    try testing.expectApproxEqAbs(before, after, 0.001);

    // Clean up the user-N file the save created.
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.preset", .{ inst.presetDir(), inst.presets.names[idx].slice() });
    fy_host_mod.deleteFilePosix(path);
}

test "raw machine presets: named save + rename round-trip" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/drum2/drum2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);

    // Named save lands a file at the chosen stem and selects it.
    inst.setControlNorm(0, 0.3);
    const before = normToValue(inst.desc.controls[0], inst.controlNorm(0));
    const idx = savePresetNamedImpl(inst, "zz-test-named") orelse return error.PresetSaveFailed;
    try testing.expectEqualStrings("zz-test-named", inst.presets.names[idx].slice());

    // Invalid names are refused.
    try testing.expectEqual(@as(?machine.PresetIndex, null), savePresetNamedImpl(inst, "   "));
    try testing.expectEqual(@as(?machine.PresetIndex, null), savePresetNamedImpl(inst, "has/slash"));

    // Rename moves the file; the value survives an apply afterwards.
    const ridx = renamePresetImpl(inst, idx, "zz-test-renamed") orelse return error.PresetRenameFailed;
    try testing.expectEqualStrings("zz-test-renamed", inst.presets.names[ridx].slice());
    try testing.expect(!inst.presets.contains("zz-test-named"));
    inst.setControlNorm(0, 0.95);
    applyPresetImpl(inst, ridx);
    try testing.expectApproxEqAbs(before, normToValue(inst.desc.controls[0], inst.controlNorm(0)), 0.001);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/zz-test-renamed.preset", .{inst.presetDir()});
    fy_host_mod.deleteFilePosix(path);
}

test "automation drives a knob per chunk, follows the curve, and yields to a hand override" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/juno2/juno2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    var ci: usize = 0;
    while (!std.mem.eql(u8, inst.desc.controls[ci].idSlice(), "jn-level")) ci += 1;

    // One lane on jn-level: 0 at beat 0 up to 1 at beat 4.
    var snap = std.mem.zeroes(snapshot.TrackSnapshot);
    snap.auto_points[0] = .{ .beat = 0, .value = 0 };
    snap.auto_points[1] = .{ .beat = 4, .value = 1 };
    snap.auto_point_count = 2;
    snap.lanes[0] = .{ .kind = .inst, .control = @intCast(ci), .points_start = 0, .points_count = 2 };
    snap.lane_count = 1;
    var cursors = [_]u32{0} ** snapshot.MAX_LANES_PER_TRACK;
    const view = snapshot.AutoView{ .snap = &snap, .cursors = &cursors, .kind = .inst };

    const block = 256;
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.tempo_bpm = 120;
    ctx.block_size = block;
    ctx.automation = &view;
    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    inst.setControlNormSnap(ci, 0.9);

    // Playing forward from beat 2: it glides onto the curve, then follows it
    // exactly at each 32-sample chunk.
    const bps = 120.0 / (60.0 * 48_000.0);
    var beat: f64 = 2.0;
    for (0..20) |_| {
        ctx.ppq_position = beat;
        testRender(mach, &ctx, &l, &r);
        beat += block * bps;
    }
    const last_chunk = beat - 32 * bps;
    try testing.expect(inst.auto_locked[ci]);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(last_chunk / 4)), inst.smooth_norm[ci], 1e-5);

    // A held override: the knob goes back to its hand-set base.
    inst.auto_override[ci].store(1, .monotonic);
    for (0..80) |_| {
        ctx.ppq_position = beat;
        testRender(mach, &ctx, &l, &r);
        beat += block * bps;
    }
    try testing.expectApproxEqAbs(@as(f32, 0.9), inst.smooth_norm[ci], 1e-3);
    try testing.expect(!inst.auto_locked[ci]);

    // A machine without its lane in the view ignores it.
    const other = snapshot.AutoView{ .snap = &snap, .cursors = &cursors, .kind = .fx, .fx_uid = 7 };
    try testing.expect(!other.any());
}

test "note ids: a note-off finds its voice by id after the voice was bent" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    try testing.expect(inst.note_expr_caller != null);

    const block = 64;
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.tempo_bpm = 120;
    ctx.block_size = block;
    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    // Two notes, then bend note 1 onto note 2's pitch: they're one pitch now.
    var evs = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 60, .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 2, .pitch = 67, .velocity = 0.9 },
        .{ .sample_offset = 10, .kind = .expression, .channel = 0, .note_id = 1, .pitch = 67, .velocity = 0 },
    };
    ctx.note_in = &evs;
    ctx.note_in_count = evs.len;
    testRender(mach, &ctx, &l, &r);

    var v1: ?usize = null;
    for (0..inst.regionCount()) |v| if (inst.voice_note_id[v] == 1) {
        v1 = v;
    };
    const voice = v1.?;
    // The bend reached the voice: its advance grew by 7 semitones.
    // SamplerState (kernels/06-voices/sampler.fy): inc, inc0 and bend are
    // its 18th-20th f64 fields.
    const bend = inst.readStateF64(voice, 19 * 8);
    try testing.expectApproxEqAbs(@as(f64, 7), bend, 1e-9);
    const inc = inst.readStateF64(voice, 17 * 8);
    const inc0 = inst.readStateF64(voice, 18 * 8);
    try testing.expectApproxEqAbs(std.math.pow(f64, 2, 7.0 / 12.0), inc / inc0, 1e-6);

    // Releasing note 1 releases its own voice, not note 2's.
    var off = [_]machine.NoteEvent{.{ .sample_offset = 0, .kind = .note_off, .channel = 0, .note_id = 1, .pitch = 60, .velocity = 0 }};
    ctx.note_in = &off;
    ctx.note_in_count = 1;
    testRender(mach, &ctx, &l, &r);
    try testing.expect(!inst.voice_gate[voice]);
    var still: usize = 0;
    for (0..inst.regionCount()) |v| still += @intFromBool(inst.voice_gate[v] and inst.voice_note_id[v] == 2);
    try testing.expectEqual(@as(usize, 1), still);
}

test "every pitched voice machine takes note expression" {
    const files = [_][]const u8{
        "machines/sampler/sampler.fy",   "machines/unfairlight/unfairlight.fy",
        "machines/juno2/juno2.fy",       "machines/fm86/fm86.fy",
        "machines/rhodes/rhodes.fy",     "machines/ms20/ms20.fy",
        "machines/cream/cream.fy",
    };
    for (files) |f| {
        const inst = try FyRawMachine.create(testing.allocator, f);
        const mach = inst.machineInterface();
        defer mach.deinit.?(mach.state, testing.allocator);
        testing.expect(inst.note_expr_caller != null) catch |err| {
            std.debug.print("{s}: no note-expr word\n", .{f});
            return err;
        };
        // A note, bent an octave up, renders finite.
        var ctx = std.mem.zeroes(machine.MachineCtx);
        ctx.sample_rate = 48_000;
        ctx.tempo_bpm = 120;
        ctx.block_size = 256;
        var l = [_]f32{0} ** 256;
        var r = [_]f32{0} ** 256;
        var evs = [_]machine.NoteEvent{
            .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 3, .pitch = 48, .velocity = 0.9 },
            .{ .sample_offset = 128, .kind = .expression, .channel = 0, .note_id = 3, .pitch = 60, .velocity = 0 },
        };
        ctx.note_in = &evs;
        ctx.note_in_count = evs.len;
        testRender(mach, &ctx, &l, &r);
        for (l) |x| try testing.expect(std.math.isFinite(x));
    }
}

test "an automated cutoff sweep renders like the knob set by hand at each chunk" {
    const a = try FyRawMachine.create(testing.allocator, "machines/juno2/juno2.fy");
    const ma = a.machineInterface();
    defer ma.deinit.?(ma.state, testing.allocator);
    const b = try FyRawMachine.create(testing.allocator, "machines/juno2/juno2.fy");
    const mb = b.machineInterface();
    defer mb.deinit.?(mb.state, testing.allocator);
    var ci: usize = 0;
    while (!std.mem.eql(u8, a.desc.controls[ci].idSlice(), "jn-cutoff")) ci += 1;

    // Lane: cutoff knob 0.2 → 0.8 over two beats. Gentle enough that each
    // 32-sample chunk moves well under AUTO_JUMP: a steep start would
    // (rightly) glide instead of following, and then the two differ.
    var snap = std.mem.zeroes(snapshot.TrackSnapshot);
    snap.auto_points[0] = .{ .beat = 0, .value = 0.2, .shape = .curve, .tension = -0.3 };
    snap.auto_points[1] = .{ .beat = 2, .value = 0.8 };
    snap.auto_point_count = 2;
    snap.lanes[0] = .{ .kind = .inst, .control = @intCast(ci), .points_start = 0, .points_count = 2 };
    snap.lane_count = 1;
    var cursors = [_]u32{0} ** snapshot.MAX_LANES_PER_TRACK;
    const view = snapshot.AutoView{ .snap = &snap, .cursors = &cursors, .kind = .inst };
    a.setControlNormSnap(ci, 0.2);
    b.setControlNormSnap(ci, 0.2);

    const sr = 48_000.0;
    const bps = 120.0 / (60.0 * sr);
    const block = 256;
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = sr;
    ctx.tempo_bpm = 120;
    var on = [_]machine.NoteEvent{.{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 48, .velocity = 0.9 }};
    var la = [_]f32{0} ** block;
    var ra = [_]f32{0} ** block;
    var lb = [_]f32{0} ** 32;
    var rb = [_]f32{0} ** 32;
    var max_diff: f32 = 0;
    var energy: f32 = 0;
    var pos: usize = 0;
    while (pos < 48_000) : (pos += block) {
        // A: the lane, one 256-sample block at a time.
        ctx.block_size = block;
        ctx.ppq_position = @as(f64, @floatFromInt(pos)) * bps;
        ctx.automation = &view;
        ctx.note_in = if (pos == 0) &on else null;
        ctx.note_in_count = if (pos == 0) 1 else 0;
        testRender(ma, &ctx, &la, &ra);
        // B: the same values set by hand before each 32-sample chunk.
        var k: usize = 0;
        while (k < block) : (k += 32) {
            const beat = @as(f64, @floatFromInt(pos + k)) * bps;
            b.setControlNormSnap(ci, automation.eval(snap.auto_points[0..2], beat));
            ctx.block_size = 32;
            ctx.ppq_position = beat;
            ctx.automation = null;
            ctx.note_in = if (pos == 0 and k == 0) &on else null;
            ctx.note_in_count = if (pos == 0 and k == 0) 1 else 0;
            testRender(mb, &ctx, &lb, &rb);
            for (la[k .. k + 32], lb) |x, y| {
                max_diff = @max(max_diff, @abs(x - y));
                energy = @max(energy, @abs(x));
            }
        }
    }
    if (max_diff >= 1e-4) std.debug.print("sweep: max diff {d} (energy {d})\n", .{ max_diff, energy });
    try testing.expect(energy > 0.01);
    try testing.expect(max_diff < 1e-4);
}

test "per-note gain scales the sampler voice from its onset" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/sampler/sampler.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.tempo_bpm = 120;
    ctx.block_size = 64;
    var l = [_]f32{0} ** 64;
    var r = [_]f32{0} ** 64;
    var evs = [_]machine.NoteEvent{
        .{ .sample_offset = 0, .kind = .note_on, .channel = 0, .note_id = 1, .pitch = 60, .velocity = 0.9 },
        .{ .sample_offset = 0, .kind = .expression, .channel = 0, .note_id = 1, .pitch = 60, .velocity = 0, .value = -30 },
    };
    ctx.note_in = &evs;
    ctx.note_in_count = evs.len;
    testRender(mach, &ctx, &l, &r);
    for (0..inst.regionCount()) |v| if (inst.voice_note_id[v] == 1) {
        // SamplerState: gain is field 7, gain0 field 22.
        const g = inst.readStateF64(v, 6 * 8);
        const g0 = inst.readStateF64(v, 21 * 8);
        try testing.expect(g0 > 0);
        try testing.expectApproxEqRel(g0 * std.math.pow(f64, 10, -1.5), g, 1e-6);
    };
}

test "sidechain: comp2 compresses its input by the key's level" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/comp2/comp2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    try testing.expect(mach.takes_key);

    // A quiet input (far under the -18 dB threshold) and a loud key: keyed,
    // the key's level sets the gain; unkeyed, the input passes ~1:1.
    const block = 512;
    var in_l: [block]f32 = undefined;
    var key_l: [block]f32 = undefined;
    const ports = [_][*]const f32{ &in_l, &in_l, &key_l, &key_l };
    var gains: [2]f64 = undefined;
    for (&gains, [_]u32{ 4, 2 }) |*g, count| {
        mach.reset(mach.state);
        var ctx = std.mem.zeroes(machine.MachineCtx);
        ctx.sample_rate = 48_000;
        ctx.block_size = block;
        ctx.audio_in = @ptrCast(&ports[0]);
        ctx.audio_in_count = count;
        var l: [block]f32 = undefined;
        var r: [block]f32 = undefined;
        var phase: f64 = 0;
        for (0..40) |blk| {
            for (&in_l, &key_l) |*a, *k| {
                const s = @sin(phase);
                phase += 2.0 * std.math.pi * 1000.0 / 48_000.0;
                a.* = @floatCast(0.02 * s);
                k.* = @floatCast(0.9 * s);
            }
            testRender(mach, &ctx, &l, &r);
            if (blk == 39) {
                var in_e: f64 = 0;
                var out_e: f64 = 0;
                for (in_l, l) |x, y| {
                    in_e += @as(f64, x) * x;
                    out_e += @as(f64, y) * y;
                }
                g.* = 10.0 * std.math.log10(out_e / in_e);
            }
        }
    }
    try testing.expect(gains[0] < -8.0); // keyed: the loud key pulls it down
    try testing.expect(@abs(gains[1]) < 1.0); // unkeyed: untouched
}

test "sidechain: verb2 GATED opens on the key, not the input" {
    const inst = try FyRawMachine.create(testing.allocator, "machines/verb2/verb2.fy");
    const mach = inst.machineInterface();
    defer mach.deinit.?(mach.state, testing.allocator);
    try testing.expect(mach.takes_key);

    // An impulse fills the tank at block 0; the key stays silent until a
    // hit at block 8. Wet only, so what comes out is the gated tail.
    const block = 512;
    var in_l = [_]f32{0} ** block;
    var key_l = [_]f32{0} ** block;
    const ports = [_][*]const f32{ &in_l, &in_l, &key_l, &key_l };
    var ctx = std.mem.zeroes(machine.MachineCtx);
    ctx.sample_rate = 48_000;
    ctx.block_size = block;
    ctx.audio_in = @ptrCast(&ports[0]);
    ctx.audio_in_count = 4;
    mach.set_param.?(mach.state, "verb-mode", 1); // GATED
    mach.set_param.?(mach.state, "verb-mix", 1.0);
    mach.set_param.?(mach.state, "verb-decay", 0.95);
    var l = [_]f32{0} ** block;
    var r = [_]f32{0} ** block;
    var before: f64 = 0;
    var after: f64 = 0;
    for (0..16) |blk| {
        in_l[0] = if (blk == 0) 0.9 else 0;
        key_l[0] = if (blk == 8) 0.9 else 0;
        testRender(mach, &ctx, &l, &r);
        for (l) |x| {
            if (blk < 8) before += @abs(x) else after += @abs(x);
        }
    }
    // The input's own hit doesn't open the gate: only the key's does.
    try testing.expect(before < 1e-3);
    try testing.expect(after > 0.05);
}
