//! slab bench — headless machine workbench (docs/17 Track C, docs/13).
//!
//! Loads machines through the SAME adapter the DAW uses (FyRawMachine via
//! its manifest), drives them with scripted blocks instead of a sound card,
//! and writes per-case contact sheets (PNG), WAVs, and one short report per
//! machine, sized for an agent to read.
//!
//!   zig build bench -- machines/ms20                  default suite
//!   zig build bench -- --all --check                  every machine vs goldens
//!   zig build bench -- machines/ms20 --sweep=all      knob-response curves
//!   zig build bench -- machines/juno2 --case=held --preset=strings -p jn-cutoff=900
//!
//! Output: scratch/bench/<machine>/{report.md, <case>.png, <case>.wav}
//! Goldens: bench/golden/<machine>.txt (hashes, committed) plus local
//! audio in scratch/bench-golden/ for difference sheets.

const std = @import("std");
const machine = @import("machine.zig");
const registry = @import("machine_registry.zig");
const raw = @import("machines/fy_raw_machine.zig");
const FyRawMachine = raw.FyRawMachine;
const wav = @import("wav.zig");
const machine_desc = @import("machine_desc.zig");
const an = @import("bench/analysis.zig");
const cases = @import("bench/cases.zig");
const plot = @import("bench/plot.zig");
const sheet = @import("bench/sheet.zig");

test {
    _ = an;
}

const SR: f64 = 48000;
/// Real-time budget of one core per sample at SR, ns.
const BUDGET_NS: f64 = 1e9 / SR;
const BLOCK: usize = 256;

const GoldenMode = enum { none, check, record };

/// The --input audio, for the `file` case.
var file_input: []const f32 = &.{};

const CostRow = struct { name: []const u8, ns: f64, voices: usize };
var cost_rows: [64]CostRow = undefined;
var cost_count: usize = 0;

const ParamSet = struct { id: []const u8, value: f64 };

const Cli = struct {
    paths: [64][]const u8 = undefined,
    path_count: usize = 0,
    case_filter: ?[]const u8 = null,
    sweep: ?[]const u8 = null,
    preset: ?[]const u8 = null,
    params: [32]ParamSet = undefined,
    param_count: usize = 0,
    out: []const u8 = "scratch/bench",
    golden: GoldenMode = .none,
    no_sheets: bool = false,
    /// --input=FILE: run an effect on this audio (mono) as the `file` case.
    input: ?[]const u8 = null,
};

const usage_text =
    \\usage: zig build bench -- [machines/<name> ...] [options]
    \\  --all                 every machine the DAW registers
    \\  --case=NAME           only this case (notes velocity held high chord hits
    \\                        impulse sine sweep ladder burst)
    \\  --sweep=ID|all        knob-response sweep of one control or all knobs
    \\  --preset=NAME         apply a preset first
    \\  -p ID=VALUE           set a control (real units, like presets)
    \\  --check | --record    compare with / write bench/golden/<machine>.txt
    \\  --no-sheets           skip PNGs (fast golden checks)
    \\  --out=DIR             output root (default scratch/bench)
    \\  --input=FILE.wav      effects: run only the `file` case on this audio
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    var cli = Cli{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |a_z| {
        const a = a_z[0..a_z.len];
        if (std.mem.eql(u8, a, "--all")) {
            for (registry.builtin_machines) |p| {
                cli.paths[cli.path_count] = p;
                cli.path_count += 1;
            }
        } else if (std.mem.startsWith(u8, a, "--case=")) {
            cli.case_filter = a["--case=".len..];
        } else if (std.mem.startsWith(u8, a, "--sweep=")) {
            cli.sweep = a["--sweep=".len..];
        } else if (std.mem.startsWith(u8, a, "--preset=")) {
            cli.preset = a["--preset=".len..];
        } else if (std.mem.startsWith(u8, a, "--input=")) {
            cli.input = a["--input=".len..];
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            cli.out = a["--out=".len..];
        } else if (std.mem.eql(u8, a, "--check")) {
            cli.golden = .check;
        } else if (std.mem.eql(u8, a, "--record")) {
            cli.golden = .record;
        } else if (std.mem.eql(u8, a, "--no-sheets")) {
            cli.no_sheets = true;
        } else if (std.mem.eql(u8, a, "-p")) {
            const kv_z = args.next() orelse return usage();
            const kv = kv_z[0..kv_z.len];
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return usage();
            cli.params[cli.param_count] = .{ .id = kv[0..eq], .value = std.fmt.parseFloat(f64, kv[eq + 1 ..]) catch return usage() };
            cli.param_count += 1;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return usage();
        } else {
            cli.paths[cli.path_count] = try resolveMachinePath(alloc, a);
            cli.path_count += 1;
        }
    }
    if (cli.path_count == 0) return usage();

    var failures: usize = 0;
    for (cli.paths[0..cli.path_count]) |path| {
        failures += runMachine(alloc, &cli, path) catch |err| blk: {
            std.debug.print("{s}: bench failed: {s}\n", .{ path, @errorName(err) });
            break :blk 1;
        };
    }
    if (cost_count > 1) {
        std.debug.print("# cost summary ({s} build; one core at 48 kHz = {d:.0} ns/smp)\n", .{ @tagName(@import("builtin").mode), BUDGET_NS });
        std.debug.print("machine      voices   ns/smp   % core\n", .{});
        for (cost_rows[0..cost_count]) |row|
            std.debug.print("{s:<12} {d:>6}  {d:>7.0}  {d:>7.2}\n", .{ row.name, row.voices, row.ns, 100 * row.ns / BUDGET_NS });
    }
    if (failures > 0) std.process.exit(1);
}

fn usage() void {
    std.debug.print("{s}", .{usage_text});
    std.process.exit(2);
}

/// `machines/ms20` or `ms20` -> `machines/ms20/ms20.fy`; `.fy` paths pass.
fn resolveMachinePath(alloc: std.mem.Allocator, a: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, a, ".fy")) return a;
    const trimmed = std.mem.trimEnd(u8, a, "/");
    const base = std.fs.path.basename(trimmed);
    if (std.mem.indexOfScalar(u8, trimmed, '/') == null)
        return std.fmt.allocPrint(alloc, "machines/{s}/{s}.fy", .{ base, base });
    return std.fmt.allocPrint(alloc, "{s}/{s}.fy", .{ trimmed, base });
}

fn machineName(path: []const u8) []const u8 {
    return std.fs.path.basename(std.fs.path.dirname(path) orelse path);
}

// ── Machine setup and rendering ─────────────────────────────────────────

/// A fresh instance per case keeps renders deterministic. Instances are
/// never deinit'd: fy's deinitUserWords teardown is a known crash, and the
/// process is short-lived.
fn instantiate(alloc: std.mem.Allocator, cli: *const Cli, path: []const u8) !*FyRawMachine {
    const inst = try FyRawMachine.create(alloc, path);
    const m = inst.machineInterface();
    if (cli.preset) |name| {
        var found = false;
        for (0..inst.presets.count) |i| {
            const pn = inst.presets.names[i].slice();
            if (std.mem.eql(u8, pn, name) or (std.mem.endsWith(u8, pn, name) and pn.len > name.len and pn[pn.len - name.len - 1] == '/')) {
                m.apply_preset.?(m.state, @intCast(i));
                found = true;
                break;
            }
        }
        if (!found) return error.PresetNotFound;
    }
    for (cli.params[0..cli.param_count]) |ps| m.set_param.?(m.state, ps.id, ps.value);
    return inst;
}

const Render = struct {
    l: []f32,
    r: []f32,
    ns_per_sample: f64,
};

const KnobStep = struct { at: usize, ctl: usize, norm: f32 };

fn render(
    alloc: std.mem.Allocator,
    inst: *FyRawMachine,
    frames: usize,
    events: []const cases.Event,
    input: ?[]const f32,
    knob_steps: []const KnobStep,
) !Render {
    const m = inst.machineInterface();
    const l = try alloc.alloc(f32, frames);
    const r = try alloc.alloc(f32, frames);
    @memset(l, 0);
    @memset(r, 0);

    var ev_buf: [256]machine.NoteEvent = undefined;
    var next_ev: usize = 0;
    var next_knob: usize = 0;
    var ns: u64 = 0;
    var pos: usize = 0;
    while (pos < frames) {
        const n = @min(BLOCK, frames - pos);
        while (next_knob < knob_steps.len and knob_steps[next_knob].at < pos + n) : (next_knob += 1) {
            inst.setControlNorm(knob_steps[next_knob].ctl, knob_steps[next_knob].norm);
        }
        var ev_count: usize = 0;
        while (next_ev < events.len) {
            const e = events[next_ev];
            const at: usize = @intFromFloat(@round(e.t * SR));
            if (at >= pos + n) break;
            ev_buf[ev_count] = .{
                .sample_offset = @intCast(at -| pos),
                .kind = if (e.on) .note_on else .note_off,
                .channel = 0,
                .note_id = -1,
                .pitch = e.pitch,
                .velocity = if (e.on) e.vel else 0,
            };
            ev_count += 1;
            next_ev += 1;
        }
        var ports: [2][*]const f32 = undefined;
        if (input) |in| {
            ports = .{ in[pos..].ptr, in[pos..].ptr };
        }
        const ctx = machine.MachineCtx{
            .sample_rate = SR,
            .block_size = @intCast(n),
            .block_start = pos,
            .tempo_bpm = 120,
            .ppq_position = @as(f64, @floatFromInt(pos)) / SR * 2.0,
            .transport_state = .playing,
            .audio_in = if (input != null) &ports else null,
            .audio_in_count = if (input != null) 2 else 0,
            .note_in = if (ev_count > 0) &ev_buf else null,
            .note_in_count = @intCast(ev_count),
        };
        const t0 = nowNs();
        m.render(m.state, &ctx, l[pos .. pos + n], r[pos .. pos + n]);
        ns += nowNs() - t0;
        pos += n;
    }
    if (inst.failed) return error.MachineRenderFailed;
    return .{ .l = l, .r = r, .ns_per_sample = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(frames)) };
}

fn isDrum(inst: *const FyRawMachine) bool {
    return inst.desc.note_pitch;
}

fn isEffect(inst: *const FyRawMachine) bool {
    return inst.desc.mode != .voice_sample;
}

// ── Per-machine driver ──────────────────────────────────────────────────

const CaseResult = struct {
    ns_per_sample: f64 = 0,
    /// Steady-state spectrum figures, kept next to the hash as a ratchet:
    /// non-harmonic energy (aliasing, noise) and THD, dB. Null for cases
    /// without a steady tone.
    ratchet: ?an.Harmonics = null,
    name: []const u8,
    hash: [64]u8,
    l: []f32,
    r: []f32,
};

fn runMachine(alloc: std.mem.Allocator, cli: *const Cli, path: []const u8) !usize {
    const name = machineName(path);
    const dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cli.out, name });
    try mkdirs(alloc, dir);

    var rep: std.ArrayList(u8) = .empty;
    const probe = FyRawMachine.create(alloc, path) catch |err| {
        std.debug.print("{s}: load failed: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    const kind: []const u8 = if (isEffect(probe)) "effect" else if (isDrum(probe)) "drum voice" else "voice";
    try rep.print(alloc, "# bench: {s} ({s}, {s}, {d} voices)\n", .{ name, probe.desc.name[0..probe.desc.name_len], kind, probe.desc.voices });
    try rep.print(alloc, "sr {d} block {d} build {s}", .{ @as(u32, @intFromFloat(SR)), BLOCK, @tagName(@import("builtin").mode) });
    if (@import("builtin").mode == .Debug) try rep.print(alloc, " (cpu numbers include Debug host overhead; use -Doptimize=ReleaseFast)", .{});
    if (cli.preset) |p| try rep.print(alloc, " preset {s}", .{p});
    for (cli.params[0..cli.param_count]) |ps| try rep.print(alloc, " {s}={d}", .{ ps.id, ps.value });
    try rep.print(alloc, "\n\n", .{});

    if (cli.sweep) |which| {
        try runSweep(alloc, cli, path, probe, which, dir, &rep);
        try finishReport(alloc, dir, rep.items);
        return 0;
    }

    // Pick the suite.
    var suite_buf: [16]cases.Case = undefined;
    var suite_n: usize = 0;
    var drum_store: [64]cases.Event = undefined;
    var file_audio: ?[]f32 = null;
    if (cli.input) |path_in| {
        if (!isEffect(probe)) return error.InputNeedsAnEffect;
        var smp = try wav.load(alloc, path_in);
        const buf = try alloc.alloc(f32, smp.data.len);
        for (buf, smp.data) |*d, v| d.* = @floatCast(v);
        smp.deinit(alloc);
        file_audio = buf;
        file_input = buf;
        suite_buf[0] = .{ .name = "file", .seconds = @as(f64, @floatFromInt(buf.len)) / SR, .focus = .file, .input = .file };
        suite_n = 1;
    } else if (isEffect(probe)) {
        for (cases.effect_suite) |cs| {
            suite_buf[suite_n] = cs;
            suite_n += 1;
        }
        if (isDynamics(name)) for (cases.dynamics_suite) |cs| {
            suite_buf[suite_n] = cs;
            suite_n += 1;
        };
    } else if (isDrum(probe)) {
        var pitches: [32]f32 = undefined;
        var np: usize = 0;
        for (probe.desc.note_labels[0..probe.desc.note_label_count]) |nl| {
            if (np == pitches.len) break;
            pitches[np] = @floatFromInt(nl.pitch);
            np += 1;
        }
        if (np == 0) for (36..48) |p| {
            pitches[np] = @floatFromInt(p);
            np += 1;
        };
        suite_buf[0] = cases.drumCase(pitches[0..np], &drum_store);
        suite_n = 1;
    } else {
        for (cases.voice_suite) |cs| {
            suite_buf[suite_n] = cs;
            suite_n += 1;
        }
        if (probe.desc.voices > 1) {
            suite_buf[suite_n] = cases.poly_extra[0];
            suite_n += 1;
        }
    }

    _ = &file_audio;
    var results: [16]CaseResult = undefined;
    var nres: usize = 0;
    for (suite_buf[0..suite_n]) |cs| {
        if (cli.case_filter) |f| if (!std.mem.eql(u8, f, cs.name)) continue;
        const res = runCase(alloc, cli, path, name, cs, dir, &rep) catch |err| {
            try rep.print(alloc, "## {s}\nFAILED: {s}\n\n", .{ cs.name, @errorName(err) });
            continue;
        };
        results[nres] = res;
        nres += 1;
    }

    if (nres > 0) {
        var worst: f64 = 0;
        var worst_case: []const u8 = "";
        for (results[0..nres]) |res| if (res.ns_per_sample > worst) {
            worst = res.ns_per_sample;
            worst_case = res.name;
        };
        const voices: f64 = @floatFromInt(@max(probe.desc.voices, 1));
        try rep.print(alloc, "## cost\nworst {d:.0} ns/smp ({s}) = {d:.2}% of one core at 48 kHz; {d:.0} ns/smp per voice slot; {d:.0} instances fit one core\n\n", .{
            worst, worst_case, 100 * worst / BUDGET_NS, worst / voices, BUDGET_NS / @max(worst, 1e-3),
        });
        if (cost_count < cost_rows.len) {
            cost_rows[cost_count] = .{ .name = name, .ns = worst, .voices = probe.desc.voices };
            cost_count += 1;
        }
    }

    var bad: usize = 0;
    switch (cli.golden) {
        .none => {},
        .record => try recordGoldens(alloc, name, results[0..nres], &rep),
        .check => bad = try checkGoldens(alloc, cli, name, results[0..nres], dir, &rep),
    }
    try finishReport(alloc, dir, rep.items);
    return bad;
}

fn finishReport(alloc: std.mem.Allocator, dir: []const u8, text: []const u8) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/report.md", .{dir});
    try writeFile(alloc, p, text);
    std.debug.print("{s}\n[report: {s}]\n\n", .{ text, p });
}

// ── One case ────────────────────────────────────────────────────────────

fn runCase(
    alloc: std.mem.Allocator,
    cli: *const Cli,
    path: []const u8,
    mname: []const u8,
    cs: cases.Case,
    dir: []const u8,
    rep: *std.ArrayList(u8),
) !CaseResult {
    const inst = try instantiate(alloc, cli, path);
    const frames: usize = @intFromFloat(cs.seconds * SR);
    var ratchet: ?an.Harmonics = null;
    var input: ?[]f32 = null;
    if (cs.input != .none) {
        const buf = try alloc.alloc(f32, frames);
        if (cs.input == .file) @memcpy(buf, file_input[0..frames]) else cases.genInput(cs, SR, buf);
        input = buf;
    }
    const out = try render(alloc, inst, frames, cs.events, input, &.{});
    const st_l = an.stats(out.l);
    const st_r = an.stats(out.r);
    const stereo = !std.mem.eql(f32, out.l, out.r);
    const h = an.hash(out.l, out.r);

    var tbl: std.ArrayList(u8) = .empty;
    try rep.print(alloc, "## {s}\n", .{cs.name});
    try rep.print(alloc, "peak {d:.1} dBFS  rms {d:.1}  dc {d:.4}  {s}  cpu {d:.0} ns/smp ({d:.2}% core)", .{
        an.dbAmp(@max(st_l.peak, st_r.peak)), an.dbAmp(an.rms(out.l)), st_l.dc, if (stereo) "stereo" else "mono", out.ns_per_sample, 100 * out.ns_per_sample / BUDGET_NS,
    });
    const nan = st_l.nan + st_r.nan;
    const den = st_l.denormal + st_r.denormal;
    const over = st_l.over + st_r.over;
    if (nan > 0) try rep.print(alloc, "  NAN {d}", .{nan});
    if (den > 0) try rep.print(alloc, "  DENORMAL {d}", .{den});
    if (over > 0) try rep.print(alloc, "  OVER 0dBFS {d} smp", .{over});
    try rep.print(alloc, "\n", .{});

    // Markers for the sheet.
    var markers: [64]sheet.Marker = undefined;
    var nm: usize = 0;
    var labels: [64][8]u8 = undefined;
    for (cs.events) |e| {
        if (nm == markers.len) break;
        if (e.on) {
            const lbl = cases.noteName(&labels[nm], e.pitch);
            markers[nm] = .{ .t = e.t, .label = lbl, .col = plot.grid_hi };
        } else {
            markers[nm] = .{ .t = e.t, .col = plot.grid };
        }
        nm += 1;
    }

    // Focus-specific analysis. Each branch writes table rows and picks the
    // spectrum window + zoom points for the sheet.
    var spec_win: [2]f64 = cs.win;
    var spec_f0: ?f64 = null;
    var onset: f64 = 0;
    var steady: f64 = (cs.win[0] + cs.win[1]) / 2;
    var off: f64 = cs.seconds - 0.2;
    var curve_series: [4]sheet.Series = undefined;
    var ncurve: usize = 0;
    var ir_spec: ?an.Spectrum = null;

    switch (cs.focus) {
        .notes => {
            try tbl.print(alloc, "note   vel   f0 meas   cents  level dB  nonharm dB  centroid\n", .{});
            var levels: [16]f64 = undefined;
            var nl: usize = 0;
            var i: usize = 0;
            while (i + 1 < cs.events.len) : (i += 2) {
                const on = cs.events[i];
                const offe = cs.events[i + 1];
                const w0 = on.t + 0.15;
                const w1 = @min(offe.t, on.t + 0.45);
                const seg = slice(out.l, w0, w1);
                const f = an.pitch(seg[0..@min(seg.len, 4096)], SR);
                var sp = try an.spectrum(alloc, seg, SR, 8192);
                defer sp.deinit(alloc);
                const exp_hz = an.midiHz(on.pitch);
                const hm = an.harmonics(sp, f orelse exp_hz);
                const lvl = an.dbAmp(an.rms(seg) * std.math.sqrt2);
                var nb: [8]u8 = undefined;
                if (f) |hz| {
                    try tbl.print(alloc, "{s:<5} {d:>4.2}  {d:>7.1}  {d:>6.1}  {d:>8.1}  {d:>10.1}  {d:>8.0}\n", .{
                        cases.noteName(&nb, on.pitch), on.vel, hz, an.centsOff(hz, exp_hz), lvl, hm.nonharm_db, an.centroid(sp),
                    });
                } else {
                    try tbl.print(alloc, "{s:<5} {d:>4.2}  {s:>7}  {s:>6}  {d:>8.1}  {s:>10}  {d:>8.0}\n", .{
                        cases.noteName(&nb, on.pitch), on.vel, "-", "-", lvl, "-", an.centroid(sp),
                    });
                }
                if (nl < levels.len) {
                    levels[nl] = lvl;
                    nl += 1;
                }
            }
            if (cs.events.len >= 4) {
                spec_win = .{ cs.events[2].t + 0.15, cs.events[3].t };
                spec_f0 = an.midiHz(cs.events[2].pitch);
                onset = cs.events[2].t;
                steady = cs.events[2].t + 0.3;
                off = cs.events[3].t;
            }
            curve_series[0] = .{ .ys = try alloc.dupe(f64, levels[0..nl]), .col = plot.amber, .lo = -60, .hi = 0, .label = "level dB" };
            ncurve = 1;
        },
        .held => {
            const env = try an.envelopeDb(alloc, out.l, 240);
            const hop_s = 240.0 / SR;
            const sh = an.shape(env, hop_s);
            var rel_t60: f64 = 0;
            var gate_off: f64 = cs.seconds;
            for (cs.events) |e| if (!e.on) {
                gate_off = e.t;
                break;
            };
            const gi: usize = @min(env.len - 1, @as(usize, @intFromFloat(gate_off / hop_s)));
            const at_off = env[gi];
            for (env[gi..], gi..) |e, k| if (e < at_off - 60) {
                rel_t60 = @as(f64, @floatFromInt(k - gi)) * hop_s;
                break;
            };
            const seg = slice(out.l, cs.win[0], cs.win[1]);
            const f = an.pitch(seg[0..@min(seg.len, 4096)], SR);
            var sp = try an.spectrum(alloc, seg, SR, 16384);
            defer sp.deinit(alloc);
            const base = an.midiHz(cs.events[0].pitch);
            const hm = an.harmonics(sp, f orelse base);
            ratchet = hm;
            try tbl.print(alloc, "onset {d:.3}s  peak {d:.1} dB at {d:.3}s\n", .{ sh.onset_s, sh.peak_db, sh.peak_s });
            try tbl.print(alloc, "level at gate-off {d:.1} dB, release -60 dB in {s}\n", .{ at_off, if (rel_t60 > 0) try std.fmt.allocPrint(alloc, "{d:.3}s", .{rel_t60}) else "(not reached)" });
            if (f) |hz| {
                try tbl.print(alloc, "steady {d:.1}-{d:.1}s: f0 {d:.2} Hz ({d:.1} c)  nonharm {d:.1} dB  centroid {d:.0} Hz\n", .{ cs.win[0], cs.win[1], hz, an.centsOff(hz, base), hm.nonharm_db, an.centroid(sp) });
            } else {
                try tbl.print(alloc, "steady {d:.1}-{d:.1}s: no stable pitch  centroid {d:.0} Hz\n", .{ cs.win[0], cs.win[1], an.centroid(sp) });
            }
            spec_f0 = f orelse base;
            onset = 0;
            off = gate_off;
            // Envelope curve, decimated.
            curve_series[0] = .{ .ys = try decimate(alloc, env, 200), .col = plot.amber, .lo = -100, .hi = 0, .label = "env dB" };
            ncurve = 1;
        },
        .hits => {
            try tbl.print(alloc, "hit    peak dB   t60 s   centroid\n", .{});
            var i: usize = 0;
            while (i < cs.events.len) : (i += 2) {
                const on = cs.events[i];
                const seg = slice(out.l, on.t, on.t + 0.48);
                const env = try an.envelopeDb(alloc, seg, 120);
                const sh = an.shape(env, 120.0 / SR);
                var sp = try an.spectrum(alloc, seg, SR, 8192);
                defer sp.deinit(alloc);
                var nb: [8]u8 = undefined;
                try tbl.print(alloc, "{s:<5} {d:>8.1}  {d:>6.3}  {d:>8.0}\n", .{ cases.noteName(&nb, on.pitch), an.dbAmp(an.stats(seg).peak), sh.t60_s, an.centroid(sp) });
            }
            spec_win = .{ 0, cs.seconds };
            onset = 0;
            steady = 0.02;
            off = if (cs.events.len > 2) cs.events[2].t else 0.4;
        },
        .impulse => {
            const at = cases.impulse_at_s;
            const seg = slice(out.l, at, cs.seconds);
            var irs = try an.impulseResponse(alloc, seg, SR, 65536);
            const env = try an.envelopeDb(alloc, seg, 240);
            const sh = an.shape(env, 240.0 / SR);
            try tbl.print(alloc, "gain @100 {d:.1}  @1k {d:.1}  @10k {d:.1} dB\n", .{ bandDb(irs, 100), bandDb(irs, 1000), bandDb(irs, 10000) });
            try tbl.print(alloc, "peak-relative -60 dB {d:.3}s  EDC T60 (Schroeder, T30x2) {d:.3}s\n", .{ sh.t60_s, an.edcT60(seg, SR) });
            ir_spec = irs;
            spec_win = .{ at, cs.seconds };
            onset = at - 0.005;
            steady = at + 0.05;
            off = at + 0.25;
            _ = &irs;
        },
        .sine => {
            const seg = slice(out.l, cs.win[0], cs.win[1]);
            var sp = try an.spectrum(alloc, seg, SR, 16384);
            defer sp.deinit(alloc);
            const hm = an.harmonics(sp, cs.input_hz);
            ratchet = hm;
            const in_rms = cases.dbToAmp(cs.input_db) / std.math.sqrt2;
            try tbl.print(alloc, "in {d:.0} Hz {d:.1} dBFS: gain {d:.2} dB  THD {d:.1} dB  nonharm {d:.1} dB\n", .{ cs.input_hz, cs.input_db, an.dbAmp(an.rms(seg) / in_rms), hm.thd_db, hm.nonharm_db });
            spec_f0 = cs.input_hz;
            onset = 0;
            off = 1.5;
        },
        .sweep => {
            const dur = 4.0;
            try tbl.print(alloc, "level along the sweep (out dB, input {d:.0} dBFS):\n", .{cs.input_db});
            const probes = [_]f64{ 30, 100, 300, 1000, 3000, 10000, 16000 };
            for (probes) |f| {
                const t = dur * @log(f / 20.0) / @log(1000.0);
                const seg = slice(out.l, t - 0.01, t + 0.01);
                try tbl.print(alloc, "  {d:>6.0} Hz  {d:>6.1} dB\n", .{ f, an.dbAmp(an.rms(seg) * std.math.sqrt2) });
            }
            spec_win = .{ 0, dur };
            onset = 0;
            steady = 2.0;
            off = dur;
        },
        .ladder => {
            try tbl.print(alloc, "in dB   out dB   gain\n", .{});
            var outs: [cases.ladder_steps.len]f64 = undefined;
            var gains: [cases.ladder_steps.len]f64 = undefined;
            for (cases.ladder_steps, 0..) |db, s| {
                const t0 = @as(f64, @floatFromInt(s)) * cases.ladder_step_s;
                const seg = slice(out.l, t0 + 0.15, t0 + cases.ladder_step_s - 0.02);
                const o = an.dbAmp(an.rms(seg) * std.math.sqrt2);
                outs[s] = o;
                gains[s] = o - db;
                try tbl.print(alloc, "{d:>5.0}  {d:>7.1}  {d:>6.1}\n", .{ db, o, o - db });
            }
            curve_series[0] = .{ .ys = try alloc.dupe(f64, &outs), .col = plot.amber, .lo = -48, .hi = 6, .label = "out dB" };
            curve_series[1] = .{ .ys = try alloc.dupe(f64, &gains), .col = plot.cyan, .lo = -24, .hi = 24, .label = "gain dB" };
            ncurve = 2;
            spec_win = .{ 2.5 + 0.1, 3.0 };
            spec_f0 = cs.input_hz;
            onset = 0;
            steady = 2.75;
            off = 2.95;
        },
        .burst => {
            const env = try an.envelopeDb(alloc, out.l, 240);
            const hop_s = 240.0 / SR;
            const end_i: usize = @intFromFloat((cases.burst_at_s + cases.burst_len_s) / hop_s);
            const at_end = env[@min(end_i, env.len - 1)];
            var t60: f64 = 0;
            for (env[end_i..], end_i..) |e, k| if (e < at_end - 60) {
                t60 = @as(f64, @floatFromInt(k - end_i)) * hop_s;
                break;
            };
            try tbl.print(alloc, "level at burst end {d:.1} dB; -60 dB after {s}\n", .{ at_end, if (t60 > 0) try std.fmt.allocPrint(alloc, "{d:.3}s", .{t60}) else "(not reached)" });
            const probes = [_]f64{ 0.25, 0.5, 1.0, 1.5 };
            for (probes) |t| try tbl.print(alloc, "  +{d:.2}s  {d:.1} dB\n", .{ t, env[@min(env.len - 1, @as(usize, @intFromFloat((cases.burst_at_s + cases.burst_len_s + t) / hop_s)))] });
            curve_series[0] = .{ .ys = try decimate(alloc, env, 200), .col = plot.amber, .lo = -100, .hi = 0, .label = "env dB" };
            ncurve = 1;
            spec_win = .{ cases.burst_at_s, cs.seconds };
            onset = cases.burst_at_s - 0.005;
            steady = cases.burst_at_s + 0.05;
            off = cases.burst_at_s + cases.burst_len_s;
        },
        .curve => {
            const x = input orelse return error.NoInput;
            try tbl.print(alloc, "in dB   out dB   gain dB\n", .{});
            var outs: [cases.curve_steps]f64 = undefined;
            var gains: [cases.curve_steps]f64 = undefined;
            for (0..cases.curve_steps) |k| {
                const t1 = @as(f64, @floatFromInt(k + 1)) * cases.curve_step_s;
                const in_db = cases.curve_lo_db + cases.curve_step_db * @as(f64, @floatFromInt(k));
                const seg = slice(out.l, t1 - 0.1, t1);
                const o = an.dbAmp(an.rms(seg) / an.rms(slice(x, t1 - 0.1, t1)) * cases.dbToAmp(in_db));
                outs[k] = o;
                gains[k] = o - in_db;
                try tbl.print(alloc, "{d:>5.0}  {d:>7.2}  {d:>7.2}\n", .{ in_db, o, o - in_db });
            }
            curve_series[0] = .{ .ys = try alloc.dupe(f64, &outs), .col = plot.amber, .lo = -48, .hi = 6, .label = "out dB" };
            curve_series[1] = .{ .ys = try alloc.dupe(f64, &gains), .col = plot.cyan, .lo = -24, .hi = 24, .label = "gain dB" };
            ncurve = 2;
            spec_f0 = 1000;
            spec_win = .{ cs.seconds - 0.2, cs.seconds };
            onset = 0;
            steady = cs.seconds - 0.1;
            off = cs.seconds - 0.01;
        },
        .step => {
            const x = input orelse return error.NoInput;
            const g = try gainTraceDb(alloc, x, out.l, @floatCast(0.3 * cases.dbToAmp(cases.step_lo_db)));
            const up: usize = @intFromFloat(cases.step_up_s * SR);
            const down: usize = @intFromFloat(cases.step_down_s * SR);
            const g_lo = meanOf(g[up - 4800 .. up]);
            const g_hi = meanOf(g[down - 4800 .. down]);
            const g_end = meanOf(g[g.len - 4800 ..]);
            const dg = g_hi - g_lo;
            const dr = g_end - g_hi;
            try tbl.print(alloc, "gain {d:.2} dB at {d:.0} dBFS, {d:.2} dB at {d:.0} dBFS (GR {d:.2} dB), {d:.2} dB after\n", .{ g_lo, cases.step_lo_db, g_hi, cases.step_hi_db, g_lo - g_hi, g_end });
            if (@abs(dg) > 0.1) {
                try tbl.print(alloc, "attack  tau63 {s}  10-90% {s}\n", .{
                    try fmtMs(alloc, crossAt(g, up, g_lo + 0.632 * dg, dg < 0)),
                    try fmtMs(alloc, blk: {
                        const a = crossAt(g, up, g_lo + 0.1 * dg, dg < 0) orelse break :blk null;
                        const b = crossAt(g, up, g_lo + 0.9 * dg, dg < 0) orelse break :blk null;
                        break :blk b - a;
                    }),
                });
                var mn: f64 = g_hi;
                for (g[up..down]) |v| mn = @min(mn, v);
                try tbl.print(alloc, "overshoot {d:.2} dB\n", .{g_hi - mn});
            }
            if (@abs(dr) > 0.1) {
                try tbl.print(alloc, "release tau63 {s}  10-90% {s}\n", .{
                    try fmtMs(alloc, crossAt(g, down, g_hi + 0.632 * dr, dr < 0)),
                    try fmtMs(alloc, blk: {
                        const a = crossAt(g, down, g_hi + 0.1 * dr, dr < 0) orelse break :blk null;
                        const b = crossAt(g, down, g_hi + 0.9 * dr, dr < 0) orelse break :blk null;
                        break :blk b - a;
                    }),
                });
            }
            curve_series[0] = .{ .ys = try decimate(alloc, g, 400), .col = plot.cyan, .lo = -24, .hi = 6, .label = "gain dB" };
            ncurve = 1;
            spec_f0 = 1000;
            spec_win = .{ cases.step_up_s + 0.2, cases.step_down_s };
            onset = cases.step_up_s;
            steady = cases.step_down_s - 0.05;
            off = cases.step_down_s;
        },
        .bursts => {
            const x = input orelse return error.NoInput;
            const g = try gainTraceDb(alloc, x, out.l, @floatCast(0.3 * cases.dbToAmp(cases.step_lo_db)));
            const base = meanOf(g[@as(usize, @intFromFloat(0.4 * SR))..@as(usize, @intFromFloat(0.5 * SR))]);
            var taus: [2]?f64 = .{ null, null };
            const spans = [_][2]f64{ cases.bursts_short, cases.bursts_long };
            const names = [_][]const u8{ "50 ms burst", "2 s block" };
            for (spans, names, 0..) |sp, label, k| {
                const end: usize = @intFromFloat(sp[1] * SR);
                const at_end = g[end - 48];
                const dr = base - at_end;
                taus[k] = if (dr > 0.1) crossAt(g, end, at_end + 0.632 * dr, false) else null;
                try tbl.print(alloc, "{s}: GR {d:.2} dB at its end, release tau63 {s}\n", .{ label, dr, try fmtMs(alloc, taus[k]) });
            }
            if (taus[0] != null and taus[1] != null) try tbl.print(alloc, "release ratio long/short {d:.2}\n", .{taus[1].? / taus[0].?});
            curve_series[0] = .{ .ys = try decimate(alloc, g, 400), .col = plot.cyan, .lo = -24, .hi = 6, .label = "gain dB" };
            ncurve = 1;
            spec_f0 = 1000;
            spec_win = .{ cases.bursts_long[0] + 0.5, cases.bursts_long[1] };
            onset = cases.bursts_long[0];
            steady = cases.bursts_long[1] - 0.05;
            off = cases.bursts_long[1];
        },
        .drums => {
            const x = input orelse return error.NoInput;
            const g = try gainTraceDb(alloc, x, out.l, 0.001);
            var store: [128]cases.DrumHit = undefined;
            const hits = cases.drumHits(&store);
            try tbl.print(alloc, "in:  peak {d:.1} dBFS  rms {d:.1}  crest {d:.1} dB\n", .{ an.dbAmp(peakAbs(x)), an.dbAmp(an.rms(x)), an.dbAmp(peakAbs(x) / an.rms(x)) });
            try tbl.print(alloc, "out: peak {d:.1} dBFS  rms {d:.1}  crest {d:.1} dB  (overall gain {d:.2} dB)\n", .{ an.dbAmp(peakAbs(out.l)), an.dbAmp(an.rms(out.l)), an.dbAmp(peakAbs(out.l) / an.rms(out.l)), an.dbAmp(an.rms(out.l) / an.rms(x)) });
            const kinds = [_]@TypeOf(hits[0].kind){ .kick, .snare };
            const kind_names = [_][]const u8{ "kick", "snare" };
            try tbl.print(alloc, "hit     GR max  GR +1ms  trans/body in  out\n", .{});
            for (kinds, kind_names) |kind, kname| {
                var gr_max: f64 = 0;
                var gr_1: f64 = 0;
                var tb_in: f64 = 0;
                var tb_out: f64 = 0;
                var cnt: f64 = 0;
                for (hits) |hit| {
                    if (hit.kind != kind) continue;
                    const at: usize = @intFromFloat(hit.t * SR);
                    if (at + 4800 >= g.len) continue;
                    var mn: f64 = 0;
                    for (g[at .. at + 3840]) |v| mn = @min(mn, v);
                    // Relative to the gain just before the hit (makeup, mix).
                    const base = g[at -| 1];
                    gr_max += base - mn;
                    gr_1 += base - g[at + 48];
                    const tr_in = peakAbs(slice(x, hit.t, hit.t + 0.004));
                    const bd_in = an.rms(slice(x, hit.t + 0.02, hit.t + 0.08));
                    const tr_out = peakAbs(slice(out.l, hit.t, hit.t + 0.004));
                    const bd_out = an.rms(slice(out.l, hit.t + 0.02, hit.t + 0.08));
                    tb_in += an.dbAmp(tr_in / bd_in);
                    tb_out += an.dbAmp(tr_out / bd_out);
                    cnt += 1;
                }
                if (cnt == 0) continue;
                try tbl.print(alloc, "{s:<6} {d:>7.2} {d:>8.2} {d:>13.2} {d:>5.2}\n", .{ kname, gr_max / cnt, gr_1 / cnt, tb_in / cnt, tb_out / cnt });
            }
            curve_series[0] = .{ .ys = try decimate(alloc, g, 600), .col = plot.cyan, .lo = -24, .hi = 12, .label = "gain dB" };
            ncurve = 1;
            spec_win = .{ 0, cs.seconds };
            onset = 0;
            steady = 60.0 / cases.drums_bpm;
            off = 2 * 60.0 / cases.drums_bpm;
        },
        .file => {
            const x = input orelse return error.NoInput;
            try fileMetrics(alloc, &tbl, x, out.l);
            spec_win = .{ 0, @min(cs.seconds, 10) };
            onset = 0;
            steady = cs.seconds / 2;
            off = cs.seconds - 0.2;
        },
    }
    try rep.appendSlice(alloc, tbl.items);
    try rep.print(alloc, "\n", .{});

    // Files.
    const base = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, cs.name });
    try writeWav(alloc, try std.fmt.allocPrint(alloc, "{s}.wav", .{base}), out.l, out.r);
    if (!cli.no_sheets) {
        var cv = try plot.Canvas.init(alloc, 1280, 940);
        defer cv.deinit(alloc);
        _ = cv.printf(8, 6, plot.amber, "{s} / {s}", .{ mname, cs.name });
        _ = cv.printf(8, 18, plot.text, "peak {d:.1} dBFS  rms {d:.1}  {s}  {d:.2}s  cpu {d:.0} ns/smp  nan {d}  over 0dBFS {d}", .{
            an.dbAmp(@max(st_l.peak, st_r.peak)), an.dbAmp(an.rms(out.l)), if (stereo) "stereo" else "mono", cs.seconds, out.ns_per_sample, nan, over,
        });
        const rr: ?[]const f32 = if (stereo) out.r else null;
        sheet.waveform(&cv, .{ .x = 8, .y = 32, .w = 1264, .h = 150 }, "waveform L amber / R cyan", out.l, rr, SR, 0, cs.seconds, 1.0, markers[0..nm]);
        try sheet.spectrogram(alloc, &cv, .{ .x = 8, .y = 188, .w = 1264, .h = 262 }, out.l, SR, markers[0..nm]);
        var period: f64 = 0.02;
        if (spec_f0) |f| period = std.math.clamp(4.0 / f, 0.002, 0.05);
        sheet.waveform(&cv, .{ .x = 8, .y = 456, .w = 416, .h = 170 }, "attack", out.l, rr, SR, @max(onset - 0.005, 0), onset + 0.045, 0, &.{});
        sheet.waveform(&cv, .{ .x = 432, .y = 456, .w = 416, .h = 170 }, "steady", out.l, rr, SR, steady, steady + period, 0, &.{});
        sheet.waveform(&cv, .{ .x = 856, .y = 456, .w = 416, .h = 170 }, "release/tail", out.l, rr, SR, @max(off - 0.01, 0), @min(off + 0.19, cs.seconds), 0, &.{});

        const left = plot.Rect{ .x = 8, .y = 632, .w = 628, .h = 300 };
        const right = plot.Rect{ .x = 644, .y = 632, .w = 628, .h = 300 };
        if (ir_spec) |irs| {
            sheet.spectrumPanel(&cv, left, "magnitude response (impulse)", irs, null, -60, 12);
        } else {
            var sp = try an.spectrum(alloc, slice(out.l, spec_win[0], spec_win[1]), SR, 16384);
            defer sp.deinit(alloc);
            var tb: [64]u8 = undefined;
            const t = std.fmt.bufPrint(&tb, "spectrum {d:.2}-{d:.2}s  (ticks = harmonics)", .{ spec_win[0], spec_win[1] }) catch "spectrum";
            sheet.spectrumPanel(&cv, left, t, sp, spec_f0, -120, 0);
        }
        if (ncurve > 0) {
            const split = plot.Rect{ .x = right.x, .y = right.y, .w = right.w, .h = 150 };
            sheet.textBlock(&cv, split, "measurements", tbl.items);
            sheet.curves(&cv, .{ .x = right.x, .y = right.y + 154, .w = right.w, .h = 146 }, "curve", curve_series[0..ncurve], if (cs.focus == .held or cs.focus == .burst) "time ->" else "step ->");
        } else {
            sheet.textBlock(&cv, right, "measurements", tbl.items);
        }
        try cv.savePng(alloc, try std.fmt.allocPrint(alloc, "{s}.png", .{base}));
    }
    return .{ .name = cs.name, .hash = h, .l = out.l, .r = out.r, .ns_per_sample = out.ns_per_sample, .ratchet = ratchet };
}

/// Compressors get the dynamics cases too (docs/24 §Test plan). By name
/// until per-machine bench cases land (docs/17 Track C).
fn isDynamics(name: []const u8) bool {
    const names = [_][]const u8{ "comp2", "bus2", "multi2" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Per-sample gain out/in in dB, held across samples where the input is
/// too small to divide by (a compressor is a memoryless multiply, so the
/// ratio is exact wherever the input isn't near zero).
fn gainTraceDb(alloc: std.mem.Allocator, in: []const f32, out: []const f32, floor: f32) ![]f64 {
    const g = try alloc.alloc(f64, in.len);
    var last: f64 = 0;
    for (in, out, g) |x, y, *d| {
        if (@abs(x) > floor) last = an.dbAmp(@abs(@as(f64, y) / @as(f64, x)));
        d.* = last;
    }
    return g;
}

/// Real-material dynamics report (docs/24 §Test plan). Active = 10 ms
/// windows of the input above -45 dBFS RMS. GR is relative to the gain
/// the machine applies to quiet passages (its makeup and mix), the 99th
/// percentile of the per-window gain. One `metrics:` line of key=value
/// pairs for scripts.
fn fileMetrics(alloc: std.mem.Allocator, tbl: *std.ArrayList(u8), x: []const f32, y: []const f32) !void {
    const W: usize = 480; // 10 ms
    const nw = x.len / W;
    var gains: std.ArrayList(f64) = .empty;
    var lv_in: std.ArrayList(f64) = .empty;
    var lv_out: std.ArrayList(f64) = .empty;
    for (0..nw) |k| {
        const a = x[k * W .. (k + 1) * W];
        const b = y[k * W .. (k + 1) * W];
        const ri = an.rms(a);
        if (an.dbAmp(ri) < -45) continue;
        try gains.append(alloc, an.dbAmp(an.rms(b) / ri));
        try lv_in.append(alloc, an.dbAmp(ri));
        try lv_out.append(alloc, an.dbAmp(an.rms(b)));
    }
    if (gains.items.len < 10) {
        try tbl.print(alloc, "input too quiet\n", .{});
        return;
    }
    const g_sorted = try alloc.dupe(f64, gains.items);
    std.mem.sort(f64, g_sorted, {}, std.sort.asc(f64));
    const pct = struct {
        fn of(v: []const f64, p: f64) f64 {
            return v[@min(v.len - 1, @as(usize, @intFromFloat(p * @as(f64, @floatFromInt(v.len - 1)))))];
        }
    };
    const g_top = pct.of(g_sorted, 0.99);
    const gr50 = g_top - pct.of(g_sorted, 0.5);
    const gr90 = g_top - pct.of(g_sorted, 0.1);
    const gr99 = g_top - pct.of(g_sorted, 0.01);
    // Level spread: 100 ms RMS (ten windows) in dB, std and p90-p10.
    const spread = struct {
        fn of(a: std.mem.Allocator, lv: []const f64) ![2]f64 {
            var blocks: std.ArrayList(f64) = .empty;
            var k: usize = 0;
            while (k + 10 <= lv.len) : (k += 10) {
                var p: f64 = 0;
                for (lv[k .. k + 10]) |d| p += std.math.pow(f64, 10, d / 10);
                try blocks.append(a, 10 * std.math.log10(p / 10));
            }
            if (blocks.items.len < 2) return .{ 0, 0 };
            var m: f64 = 0;
            for (blocks.items) |v| m += v;
            m /= @floatFromInt(blocks.items.len);
            var v2: f64 = 0;
            for (blocks.items) |v| v2 += (v - m) * (v - m);
            std.mem.sort(f64, blocks.items, {}, std.sort.asc(f64));
            return .{ @sqrt(v2 / @as(f64, @floatFromInt(blocks.items.len))), pct.of(blocks.items, 0.9) - pct.of(blocks.items, 0.1) };
        }
    };
    const sp_in = try spread.of(alloc, lv_in.items);
    const sp_out = try spread.of(alloc, lv_out.items);
    // Pumping: std of the per-window GR.
    var gm: f64 = 0;
    for (gains.items) |g| gm += g;
    gm /= @floatFromInt(gains.items.len);
    var gv: f64 = 0;
    for (gains.items) |g| gv += (g - gm) * (g - gm);
    const pump = @sqrt(gv / @as(f64, @floatFromInt(gains.items.len)));
    // Onsets: a 5 ms window 8 dB over the mean of the previous 50 ms and
    // above -30 dBFS; transient = the loudest 1 ms RMS in the first 15 ms
    // (what the ear hears as the hit, not a few samples of overshoot; a
    // sampled snare can take 10 ms to peak), body = RMS 40-120 ms.
    const O: usize = 240;
    var tb_in: f64 = 0;
    var tb_out: f64 = 0;
    var n_on: f64 = 0;
    var i: usize = 10 * O;
    while (i + 26 * O < x.len) : (i += O) {
        const cur = an.rms(x[i .. i + O]);
        const prev = an.rms(x[i - 10 * O .. i]);
        if (an.dbAmp(cur) < -30 or an.dbAmp(cur / @max(prev, 1e-9)) < 8) continue;
        const body_in = an.rms(x[i + 8 * O .. i + 24 * O]);
        const body_out = an.rms(y[i + 8 * O .. i + 24 * O]);
        tb_in += an.dbAmp(transientRms(x[i .. i + 3 * O]) / @max(body_in, 1e-9));
        tb_out += an.dbAmp(transientRms(y[i .. i + 3 * O]) / @max(body_out, 1e-9));
        n_on += 1;
        i += 26 * O; // one onset per 130 ms at most
    }
    // Crest: the median over 400 ms windows of peak/RMS, so one onset
    // after silence (where any compressor has let go) doesn't decide it.
    const crest = struct {
        fn of(a: std.mem.Allocator, v: []const f32) !f64 {
            const C: usize = 19200;
            var cs: std.ArrayList(f64) = .empty;
            var k: usize = 0;
            while (k + C <= v.len) : (k += C) {
                const seg = v[k .. k + C];
                const r = an.rms(seg);
                if (an.dbAmp(r) < -45) continue;
                try cs.append(a, an.dbAmp(peakAbs(seg) / r));
            }
            if (cs.items.len == 0) return 0;
            std.mem.sort(f64, cs.items, {}, std.sort.asc(f64));
            return cs.items[cs.items.len / 2];
        }
    };
    const crest_in = try crest.of(alloc, x);
    const crest_out = try crest.of(alloc, y);
    try tbl.print(alloc, "active {d:.1} s  gain quiet {d:.2} dB\n", .{ @as(f64, @floatFromInt(gains.items.len)) * 0.01, g_top });
    try tbl.print(alloc, "GR p50 {d:.2}  p90 {d:.2}  p99 {d:.2} dB   pump (GR std) {d:.2} dB\n", .{ gr50, gr90, gr99, pump });
    try tbl.print(alloc, "crest (median 400 ms) {d:.2} -> {d:.2} dB   spread std {d:.2} -> {d:.2}, p90-p10 {d:.2} -> {d:.2} dB\n", .{ crest_in, crest_out, sp_in[0], sp_out[0], sp_in[1], sp_out[1] });
    if (n_on > 0) try tbl.print(alloc, "onsets {d:.0}: transient/body {d:.2} -> {d:.2} dB\n", .{ n_on, tb_in / n_on, tb_out / n_on });
    try tbl.print(alloc, "gain p50 {d:.2}  p10 {d:.2}  p01 {d:.2} dB (absolute)\n", .{ pct.of(g_sorted, 0.5), pct.of(g_sorted, 0.1), pct.of(g_sorted, 0.01) });
    try tbl.print(alloc, "metrics: g50={d:.3} g10={d:.3} g01={d:.3} ", .{ pct.of(g_sorted, 0.5), pct.of(g_sorted, 0.1), pct.of(g_sorted, 0.01) });
    try tbl.print(alloc, "gr50={d:.3} gr90={d:.3} gr99={d:.3} pump={d:.3} crest_in={d:.3} crest_out={d:.3} spread_in={d:.3} spread_out={d:.3} range_in={d:.3} range_out={d:.3} tb_in={d:.3} tb_out={d:.3} onsets={d:.0} gain_quiet={d:.3} out_rms={d:.3} in_rms={d:.3}\n", .{
        gr50, gr90, gr99, pump, crest_in, crest_out, sp_in[0], sp_out[0], sp_in[1], sp_out[1],
        if (n_on > 0) tb_in / n_on else 0, if (n_on > 0) tb_out / n_on else 0, n_on, g_top, an.dbAmp(an.rms(y)), an.dbAmp(an.rms(x)),
    });
}

fn transientRms(x: []const f32) f64 {
    var best: f64 = 0;
    var k: usize = 0;
    while (k + 48 <= x.len) : (k += 12) best = @max(best, an.rms(x[k .. k + 48]));
    return best;
}

fn meanOf(xs: []const f64) f64 {
    if (xs.len == 0) return 0;
    var a: f64 = 0;
    for (xs) |x| a += x;
    return a / @as(f64, @floatFromInt(xs.len));
}

/// First time at or after `from` where the trace crosses `level` in the
/// direction of travel (`down` = falling).
fn crossAt(g: []const f64, from: usize, level: f64, down: bool) ?f64 {
    for (g[from..], from..) |v, i| {
        if ((down and v <= level) or (!down and v >= level)) return @as(f64, @floatFromInt(i - from)) / SR;
    }
    return null;
}

fn fmtMs(alloc: std.mem.Allocator, t: ?f64) ![]const u8 {
    return if (t) |x| std.fmt.allocPrint(alloc, "{d:.2} ms", .{x * 1000}) else "-";
}

fn peakAbs(x: []const f32) f64 {
    var p: f32 = 0;
    for (x) |v| p = @max(p, @abs(v));
    return p;
}

fn bandDb(s: an.Spectrum, f: f64) f64 {
    return s.dbRange(f / 1.06, f * 1.06);
}

fn slice(x: []const f32, t0: f64, t1: f64) []const f32 {
    const a: usize = @intFromFloat(std.math.clamp(t0 * SR, 0, @as(f64, @floatFromInt(x.len))));
    const b: usize = @intFromFloat(std.math.clamp(t1 * SR, 0, @as(f64, @floatFromInt(x.len))));
    return x[a..@max(a, b)];
}

fn decimate(alloc: std.mem.Allocator, xs: []const f64, n: usize) ![]f64 {
    const out = try alloc.alloc(f64, @min(n, xs.len));
    for (out, 0..) |*o, i| o.* = xs[i * xs.len / out.len];
    return out;
}

// ── Knob-response sweeps ────────────────────────────────────────────────

const SWEEP_STEPS = 21;
const SWEEP_STEP_S = 0.4;

const SweepResult = struct {
    level: [SWEEP_STEPS]f64,
    bright: [SWEEP_STEPS]f64, // log2 centroid
    pitch: [SWEEP_STEPS]f64, // semitones re C3 (0 when unpitched)
};

/// Travel metrics for one curve: how much it changes and how evenly the
/// change is spread across the knob's travel.
const Travel = struct {
    travel: f64, // sum of |step deltas|
    dead: f64, // fraction of steps doing <10% of an even share
    uneven: f64, // max gap between cumulative change and a straight line
};

fn travelOf(ys: []const f64) Travel {
    var tr: f64 = 0;
    for (1..ys.len) |i| tr += @abs(ys[i] - ys[i - 1]);
    if (tr < 1e-9) return .{ .travel = 0, .dead = 1, .uneven = 0 };
    const share = tr / @as(f64, @floatFromInt(ys.len - 1));
    var dead: usize = 0;
    var cum: f64 = 0;
    var worst: f64 = 0;
    for (1..ys.len) |i| {
        const d = @abs(ys[i] - ys[i - 1]);
        if (d < 0.1 * share) dead += 1;
        cum += d;
        const ideal = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(ys.len - 1));
        worst = @max(worst, @abs(cum / tr - ideal));
    }
    return .{ .travel = tr, .dead = @as(f64, @floatFromInt(dead)) / @as(f64, @floatFromInt(ys.len - 1)), .uneven = worst };
}

fn sweepMeasure(
    alloc: std.mem.Allocator,
    inst: *FyRawMachine,
    frames: usize,
    events: []const cases.Event,
    input: ?[]const f32,
    steps: []const KnobStep,
) !SweepResult {
    const out = try render(alloc, inst, frames, events, input, steps);
    var res: SweepResult = undefined;
    for (0..SWEEP_STEPS) |s| {
        const t0 = @as(f64, @floatFromInt(s)) * SWEEP_STEP_S;
        const seg = slice(out.l, t0 + 0.05, t0 + 0.28);
        res.level[s] = @max(an.dbAmp(an.rms(seg) * std.math.sqrt2), -100);
        var sp = try an.spectrum(alloc, seg, SR, 4096);
        defer sp.deinit(alloc);
        res.bright[s] = std.math.log2(@max(an.centroid(sp), 20));
        const f = an.pitch(seg[0..@min(seg.len, 4096)], SR);
        var st = if (f) |hz| an.centsOff(hz, an.midiHz(48)) / 100.0 else if (s > 0) res.pitch[s - 1] else 0;
        // Autocorrelation on resonant/detuned tones makes octave errors;
        // real knob sweeps move pitch smoothly, so unwrap octave jumps.
        if (s > 0) st -= 12.0 * @round((st - res.pitch[s - 1]) / 12.0);
        res.pitch[s] = st;
    }
    return res;
}

fn runSweep(
    alloc: std.mem.Allocator,
    cli: *const Cli,
    path: []const u8,
    probe: *FyRawMachine,
    which: []const u8,
    dir: []const u8,
    rep: *std.ArrayList(u8),
) !void {
    var idxs: [machine_desc.MAX_CONTROLS]usize = undefined;
    var n: usize = 0;
    for (probe.desc.controls[0..probe.desc.control_count], 0..) |*ctl, i| {
        if (ctl.kind != .direct_f64) continue;
        if (!std.mem.eql(u8, which, "all") and !std.mem.eql(u8, which, ctl.idSlice())) continue;
        idxs[n] = i;
        n += 1;
    }
    if (n == 0) return error.NoSuchControl;

    const frames: usize = @intFromFloat(SWEEP_STEPS * SWEEP_STEP_S * SR);
    const effect = isEffect(probe);
    var input: ?[]f32 = null;
    if (effect) {
        const buf = try alloc.alloc(f32, frames);
        cases.genInput(.{ .name = "saw", .seconds = 0, .focus = .sine, .input = .saw, .input_hz = 110, .input_db = -12 }, SR, buf);
        input = buf;
    }
    var events: [SWEEP_STEPS * 2]cases.Event = undefined;
    const pitch: f32 = if (isDrum(probe) and probe.desc.note_label_count > 0) @floatFromInt(probe.desc.note_labels[0].pitch) else 48;
    for (0..SWEEP_STEPS) |s| {
        const t = @as(f64, @floatFromInt(s)) * SWEEP_STEP_S;
        events[2 * s] = .{ .t = t + 0.005, .on = true, .pitch = pitch };
        events[2 * s + 1] = .{ .t = t + 0.3, .on = false, .pitch = pitch };
    }

    try rep.print(alloc, "## knob sweep  ({d} steps x {d:.1}s, {s})\n", .{ SWEEP_STEPS, SWEEP_STEP_S, if (effect) "saw 110 Hz -12 dBFS in" else "C3 retriggered each step" });
    try rep.print(alloc, "level/bright = total change across travel; dead = share of travel doing <10% of an even share; uneven = 0 even .. 0.5 all at one end\n\n", .{});
    try rep.print(alloc, "control              range                 level dB  bright oct  pitch st  dead  uneven  (pitch ~ = tracker unstable)\n", .{});

    // Baseline: the same stimulus with no knob movement. Step-to-step
    // jitter (free-running phases, VCO beating, LFOs) sets the noise floor a
    // knob must beat to count as audible.
    const base = try sweepMeasure(alloc, try instantiate(alloc, cli, path), frames, if (effect) &.{} else &events, input, &.{});
    const base_l = travelOf(&base.level).travel;
    const base_b = travelOf(&base.bright).travel;
    const base_p = travelOf(&base.pitch).travel;
    try rep.print(alloc, "baseline (no knob movement): level {d:.1} dB  bright {d:.2} oct  pitch {d:.2} st\n", .{ base_l, base_b, base_p });

    const cols: i32 = 4;
    const cell_w: i32 = 316;
    const cell_h: i32 = 170;
    const rows: i32 = @intCast((n + 3) / 4);
    var cv = try plot.Canvas.init(alloc, 8 + cols * (cell_w + 4), 28 + rows * (cell_h + 4));
    defer cv.deinit(alloc);
    _ = cv.printf(8, 8, plot.amber, "{s} knob sweeps: amber = level dB, cyan = brightness (log2 centroid), green = pitch st", .{machineName(path)});

    for (idxs[0..n], 0..) |ci, k| {
        const ctl = &probe.desc.controls[ci];
        const inst = try instantiate(alloc, cli, path);
        var steps: [SWEEP_STEPS]KnobStep = undefined;
        for (0..SWEEP_STEPS) |s| steps[s] = .{
            .at = @intFromFloat(@as(f64, @floatFromInt(s)) * SWEEP_STEP_S * SR),
            .ctl = ci,
            .norm = @floatCast(@as(f64, @floatFromInt(s)) / @as(f64, SWEEP_STEPS - 1)),
        };
        const res = try sweepMeasure(alloc, inst, frames, if (effect) &.{} else &events, input, &steps);
        const tl = travelOf(&res.level);
        const tb = travelOf(&res.bright);
        // Pitch only counts when the tracker is stable across steps; resonant
        // or detuned tones otherwise make fifth/octave errors.
        var jumps: usize = 0;
        for (1..SWEEP_STEPS) |si| {
            if (@abs(res.pitch[si] - res.pitch[si - 1]) > 2.0) jumps += 1;
        }
        const pitch_ok = jumps * 10 <= SWEEP_STEPS - 1;
        const tp = if (pitch_ok) travelOf(&res.pitch) else Travel{ .travel = 0, .dead = 0, .uneven = 0 };
        // Judge evenness on whichever axis the knob mostly moves.
        var main_t = if (tl.travel / 12.0 >= tb.travel / 2.0) tl else tb;
        const lb_flat = tl.travel < 1.5 * base_l + 0.5 and tb.travel < 1.5 * base_b + 0.05;
        if (lb_flat and tp.travel > 1.5 * base_p + 0.1) main_t = tp;
        var rbuf: [48]u8 = undefined;
        const lo = raw.normToValue(ctl.*, 0);
        const hi = raw.normToValue(ctl.*, 1);
        const range = std.fmt.bufPrint(&rbuf, "{d:.3}..{d:.3} {s}", .{ lo, hi, @tagName(ctl.curve) }) catch "";
        const silent = tl.travel < 1.5 * base_l + 0.5 and tb.travel < 1.5 * base_b + 0.05 and tp.travel < 1.5 * base_p + 0.1;
        const flag: []const u8 = if (silent) "  <- no effect (within baseline noise)" else if (main_t.uneven > 0.3) "  <- uneven" else "";
        var pbuf: [16]u8 = undefined;
        const pcol = if (pitch_ok) std.fmt.bufPrint(&pbuf, "{d:.2}", .{tp.travel}) catch "" else "~";
        try rep.print(alloc, "{s:<20} {s:<21} {d:>8.1}  {d:>10.2}  {s:>8}  {d:>3.0}%  {d:>6.2}{s}\n", .{ ctl.idSlice(), range, tl.travel, tb.travel, pcol, main_t.dead * 100, main_t.uneven, flag });

        const col: i32 = @intCast(k % 4);
        const row: i32 = @intCast(k / 4);
        const r = plot.Rect{ .x = 8 + col * (cell_w + 4), .y = 24 + row * (cell_h + 4), .w = cell_w, .h = cell_h };
        var lmin: f64 = 1e9;
        var lmax: f64 = -1e9;
        var bmin: f64 = 1e9;
        var bmax: f64 = -1e9;
        for (res.level) |v| {
            lmin = @min(lmin, v);
            lmax = @max(lmax, v);
        }
        for (res.bright) |v| {
            bmin = @min(bmin, v);
            bmax = @max(bmax, v);
        }
        var pmin: f64 = 1e9;
        var pmax: f64 = -1e9;
        for (res.pitch) |v| {
            pmin = @min(pmin, v);
            pmax = @max(pmax, v);
        }
        const show_pitch = pitch_ok and tp.travel > 1.5 * base_p + 0.1;
        const series = [_]sheet.Series{
            .{ .ys = &res.level, .col = plot.amber, .lo = @min(lmin, lmax - 6), .hi = @max(lmax, lmin + 6), .label = "dB" },
            .{ .ys = &res.bright, .col = plot.cyan, .lo = @min(bmin, bmax - 1), .hi = @max(bmax, bmin + 1), .label = "oct" },
            .{ .ys = if (show_pitch) &res.pitch else &.{}, .col = plot.green, .lo = @min(pmin, pmax - 1), .hi = @max(pmax, pmin + 1), .label = "st" },
        };
        var tbuf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "{s}  dead {d:.0}% uneven {d:.2}", .{ ctl.idSlice(), main_t.dead * 100, main_t.uneven }) catch "";
        sheet.curves(&cv, r, title, &series, range);
    }
    try rep.print(alloc, "\n", .{});
    const p = try std.fmt.allocPrint(alloc, "{s}/sweep-{s}.png", .{ dir, which });
    if (!cli.no_sheets) try cv.savePng(alloc, p);
}

// ── Goldens ─────────────────────────────────────────────────────────────

fn goldenPath(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "bench/golden/{s}.txt", .{name});
}

fn goldenAudioPath(alloc: std.mem.Allocator, name: []const u8, case: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "scratch/bench-golden/{s}/{s}.f32", .{ name, case });
}

fn recordGoldens(alloc: std.mem.Allocator, name: []const u8, results: []const CaseResult, rep: *std.ArrayList(u8)) !void {
    try mkdirs(alloc, "bench/golden");
    try mkdirs(alloc, try std.fmt.allocPrint(alloc, "scratch/bench-golden/{s}", .{name}));
    var txt: std.ArrayList(u8) = .empty;
    try txt.print(alloc, "# bench goldens for {s}: case sha256(f32 L ++ f32 R) [nonharm_db thd_db]\n", .{name});
    for (results) |res| {
        if (res.ratchet) |r| {
            try txt.print(alloc, "{s} {s} {d:.1} {d:.1}\n", .{ res.name, res.hash, r.nonharm_db, r.thd_db });
        } else {
            try txt.print(alloc, "{s} {s}\n", .{ res.name, res.hash });
        }
        var bytes: std.ArrayList(u8) = .empty;
        try bytes.appendSlice(alloc, std.mem.sliceAsBytes(res.l));
        try bytes.appendSlice(alloc, std.mem.sliceAsBytes(res.r));
        try writeFile(alloc, try goldenAudioPath(alloc, name, res.name), bytes.items);
    }
    try writeFile(alloc, try goldenPath(alloc, name), txt.items);
    try rep.print(alloc, "goldens recorded: {d} cases -> {s}\n", .{ results.len, try goldenPath(alloc, name) });
}

fn checkGoldens(alloc: std.mem.Allocator, cli: *const Cli, name: []const u8, results: []const CaseResult, dir: []const u8, rep: *std.ArrayList(u8)) !usize {
    const gp = try goldenPath(alloc, name);
    const data = readFile(alloc, gp) catch {
        try rep.print(alloc, "goldens: none at {s} (run --record)\n", .{gp});
        return 1;
    };
    var bad: usize = 0;
    try rep.print(alloc, "## goldens\n", .{});
    for (results) |res| {
        var want: ?[]const u8 = null;
        var old_nonharm: ?f64 = null;
        var old_thd: ?f64 = null;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0 or ln[0] == '#') continue;
            var tok = std.mem.tokenizeAny(u8, ln, " \r");
            const case = tok.next() orelse continue;
            if (!std.mem.eql(u8, case, res.name)) continue;
            want = tok.next();
            if (tok.next()) |t| old_nonharm = std.fmt.parseFloat(f64, t) catch null;
            if (tok.next()) |t| old_thd = std.fmt.parseFloat(f64, t) catch null;
        }
        if (want == null) {
            try rep.print(alloc, "{s}: NEW (no golden)\n", .{res.name});
            bad += 1;
            continue;
        }
        if (std.mem.eql(u8, want.?, &res.hash)) {
            try rep.print(alloc, "{s}: ok (bit-exact)\n", .{res.name});
            continue;
        }
        bad += 1;
        // The ratchet: a changed render must not get dirtier.
        if (res.ratchet) |r| if (old_nonharm) |on| {
            const worse = r.nonharm_db > on + 3.0;
            try rep.print(alloc, "{s}: nonharm {d:.1} -> {d:.1} dB  thd {d:.1} -> {d:.1} dB{s}\n", .{
                res.name,                                             on, r.nonharm_db, old_thd orelse 0, r.thd_db,
                if (worse) "  NONHARM WORSE (aliasing/noise)" else "",
            });
        };
        const old = readFile(alloc, try goldenAudioPath(alloc, name, res.name)) catch {
            try rep.print(alloc, "{s}: CHANGED (no local golden audio for a diff)\n", .{res.name});
            continue;
        };
        const want_bytes = (res.l.len + res.r.len) * 4;
        if (old.len != want_bytes) {
            try rep.print(alloc, "{s}: CHANGED (length {d} -> {d} samples)\n", .{ res.name, old.len / 8, res.l.len });
            continue;
        }
        const old_f: []align(1) const f32 = std.mem.bytesAsSlice(f32, old);
        const diff = try alloc.alloc(f32, res.l.len);
        var max_d: f64 = 0;
        for (diff, 0..) |*d, i| {
            d.* = res.l[i] - old_f[i];
            max_d = @max(max_d, @abs(d.*));
        }
        for (res.r, 0..) |v, i| max_d = @max(max_d, @abs(v - old_f[res.l.len + i]));
        try rep.print(alloc, "{s}: CHANGED  max diff {d:.1} dBFS  diff rms {d:.1} dBFS  -> {s}-diff.png\n", .{ res.name, an.dbAmp(max_d), an.dbAmp(an.rms(diff)), res.name });
        if (!cli.no_sheets) {
            var cv = try plot.Canvas.init(alloc, 1280, 480);
            defer cv.deinit(alloc);
            _ = cv.printf(8, 6, plot.red, "{s} / {s}: new - golden (L)", .{ name, res.name });
            const dur = @as(f64, @floatFromInt(diff.len)) / SR;
            sheet.waveform(&cv, .{ .x = 8, .y = 20, .w = 1264, .h = 170 }, "difference", diff, null, SR, 0, dur, 0, &.{});
            try sheet.spectrogram(alloc, &cv, .{ .x = 8, .y = 196, .w = 1264, .h = 276 }, diff, SR, &.{});
            try cv.savePng(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}-diff.png", .{ dir, res.name }));
        }
    }
    return bad;
}

// ── Files (libc, like kernel_probe) ─────────────────────────────────────

fn writeWav(alloc: std.mem.Allocator, path: []const u8, l: []const f32, r: []const f32) !void {
    const inter = try alloc.alloc(f32, l.len * 2);
    defer alloc.free(inter);
    for (l, r, 0..) |a, b, i| {
        inter[2 * i] = std.math.clamp(a, -1, 1);
        inter[2 * i + 1] = std.math.clamp(b, -1, 1);
    }
    const bytes = try wav.encodeStereo24(alloc, inter, @intFromFloat(SR));
    defer alloc.free(bytes);
    try writeFile(alloc, path, bytes);
}

fn mkdirs(alloc: std.mem.Allocator, path: []const u8) !void {
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            if (i == 0) continue;
            const z = try alloc.dupeZ(u8, path[0..i]);
            defer alloc.free(z);
            if (std.c.mkdir(z, 0o755) != 0 and std.c._errno().* != 17) return error.MkdirFailed;
        }
    }
}

fn writeFile(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const f = std.c.fopen(z, "wb") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(f);
    if (data.len > 0 and std.c.fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    const f = std.c.fopen(z, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.items;
}

fn nowNs() u64 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return @intCast(@divTrunc(
        @as(u128, @intCast(std.c.mach_absolute_time())) * @as(u128, @intCast(info.numer)),
        @as(u128, @intCast(info.denom)),
    ));
}
