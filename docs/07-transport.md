# 07 — Transport, scheduling, graph

## The clock

One authoritative clock: the **audio callback**. Everything else
(UI, timers, animations, MIDI output) reads derived time.

```zig
pub const Transport = struct {
    state:                 State = .stopped,
    sample_rate:           u32 = 48000,

    // Audio thread writes; everyone else reads.
    audio_samples_played:  std.atomic.Value(u64) = .init(0),

    play_start_sample:     u64 = 0,
    scrub_sample:          u64 = 0,
    project_duration_samples: u64 = 0,

    tempo_bpm:             f64 = 120.0,
    // Tempo can change; sample-accurate tempo map lives in the Document.
    tempo_map:             TempoMap,

    loop_enabled:          bool = false,
    loop_start_samples:    u64 = 0,
    loop_end_samples:      u64 = 0,
};
```

UI thread asks `current_sample()` or `current_beat()`. Both are
derived from the atomic. No locking.

## The audio callback

Invariant structure:

```zig
fn audioCallback(out: []f32, frames: u32) void {
    transport.advance(frames);   // atomic fetchAdd — called first
    block_arena.reset();         // new block = fresh scratch

    const block_start = transport.play_start_sample
                      + transport.audio_samples_played.load(.monotonic)
                      - frames;   // we already advanced
    const ctx_common = buildCommonCtx(block_start, frames);

    scheduler.runBlock(&ctx_common, graph, out);
}
```

Ordering:
1. Advance clock first. Downstream reads see the new value;
   this is what makes the clock authoritative.
2. Reset block arena.
3. Compute ctx fields common to all machines (tempo, ppq, transport
   state).
4. Run the graph: walk machines in topo order, fill each machine's
   ctx, call `process`.
5. Final mix into `out`.

## The graph

v1 is **Live-style**, not Reaktor-style.

```
      ┌─────────────────────────────────────────────────┐
      │                TRACK GRAPH                       │
      │                                                  │
      │  Track 1 (drums)                                  │
      │    clip source → insert1 → insert2 → ... ─┐      │
      │                                             │    │
      │  Track 2 (bass)                             │    │
      │    clip source → insert1 → insert2 → ... ──┤    │
      │                                             ▼    │
      │  Track 3 (lead)         (sum) ─────────→ master  │
      │    clip source → insert1 → insert2 → ... ──┤    │
      │                                             │    │
      │    also: send1 →────→ return1 (reverb) ────┘    │
      │          send2 →────→ return2 (delay) ─────→ master
      └─────────────────────────────────────────────────┘
```

Concepts:

- **Track:** a row. Owns a chain of **inserts** (machines), has a
  volume/pan, mute/solo/arm flags, may have instrument-type or
  audio-type semantics.
- **Insert:** a machine in a track's chain. Audio flows through it
  in order.
- **Send:** a tap from a track's post-insert point into a return
  track.
- **Return:** a track that only receives from sends (typically FX
  like reverb/delay).
- **Master:** the final mix bus.

Topologically a DAG. Cycles via sends are rejected (send-to-a-return-that-sends-to-itself).

> **Status (implemented):** the **master bus** exists. Audio tracks
> accumulate (post-fader) into a planar master bus on the `Engine`
> struct; the master Track's effect chain processes the sum, the master
> fader is applied, then the interleaved write + soft-clip. The master is
> a standalone `Track` (`kind = .master`) outside the `tracks` array — a
> silent instrument with an effects-only chain, its `volume()` the master
> fader and `meter()` the master meter. It is edited via the machine bay
> (`device_sel` selects track vs master) and shown as a pinned strip at
> the bottom of the track bay. Buses, outputs and sends are built;
> see [23-routing.md](23-routing.md), which supersedes this section's
> send/return sketch and §Topological order.

### Why not a free node graph?

Because **v1 needs to be shippable**, and a node-graph editor is a
product in itself. Live-style covers 90% of use cases with 10% of
the UI effort. A "patch mode" that exposes the graph as free wiring
can come later, built *on top of* the same scheduler.

### Clip sources

Tracks can have **clips** on their timeline. A clip is one of:
- **Pattern clip:** a MIDI/note pattern + reference to an
  instrument machine at the head of the track's chain
- **Audio clip:** a sample / rendered audio buffer, played through
  the chain (no instrument; inserts start at the first effect)
- **Automation** is not a clip kind: note clips carry clip lanes, and
  tracks carry track lanes. See [22-automation.md](22-automation.md).

When transport is in a clip's range, the track's first insert (or
the clip directly, for audio clips) receives the clip's data. When
outside any clip, the track is silent (or looping, per settings).

**As built (Phase C).** Audio clips are implemented and play back in
the arrangement. The host owns an **AudioPool** (`src/audio_pool.zig`):
decoded f64 mono sources (via `wav.zig`) each paired with a
`waveform.PeakCache` for zoomable waveform drawing. A `Clip` carries a
`kind` (`note` | `audio`); audio clips hold an `AudioRef { source, gain }`
indexing the pool. `Track.publishSnapshot` freezes each audio clip's raw
`data` pointer + length + native rate into the `TrackSnapshot`; the audio
thread mixes them (`engine.mixAudioClips`) on top of the instrument output
into the same planar L/R, so the track's insert chain processes the sum.
The source plays from its top at native rate (linear-interp resample to the
engine rate) and stops when either the timeline window or the source data
runs out — speed/warp and a trim window are Phase D. Sources are pool-indexed
and never freed mid-session, so the snapshot pointer stays valid without a
fence. The pool survives undo/redo; the document persists audio clips by
file path (`ACLIP` line) and re-resolves to a pool index on load (dedup by
path). Import via the arrangement's right-click **Import audio…**. Unlike
the doc's "audio-head track" split above, an audio clip can sit on any
track and coexists with that track's instrument — the engine simply sums.

### Topological order

Computed once at graph build; cached until the graph changes.
Order:

1. All instrument-head tracks (each feeds its inserts in chain order)
2. All audio-head tracks (same)
3. Return tracks (in order they are declared; sends are always
   post-insert so this ordering is valid)
4. Master

Each step within a track runs its inserts in order.

## Graph swap

When the user adds/removes a machine or reorders inserts, the host
rebuilds the graph on the main thread and atomically swaps the
pointer the audio callback reads. Double-buffering again:

```zig
struct Graph {
    current: *GraphState,    // atomic<*GraphState>
    pending: *GraphState,
    ...
}
```

Main thread prepares `pending`, stages new machine arenas,
atomically swaps `current <- pending`. Old graph's machines are
retired on the main thread after a block passes (so the audio
thread has definitely moved on).

## Plugin Delay Compensation (PDC)

Machines declare latency in samples. The host computes, per chain
and per branch point, how much delay to insert to realign parallel
signals. Canonical example: a send with a reverb that has 0
internal latency arrives earlier than the dry track that went
through a lookahead compressor with 1024 samples of latency. The
host inserts 1024 samples of delay on the dry path.

Algorithm:

1. Traverse the graph, compute `latency_to_output` for each node
   (sum of latencies along the path).
2. For each node with multiple incoming paths (mixer sums), take
   `max(latency_to_output_of_parents)` and apply delay on the
   shorter paths.
3. For machines themselves: they operate "latency-naively" — they
   process their input and produce their output. The host's delay
   lines handle alignment.

Delay buffers come from a per-chain persistent arena (separate from
machine persistent arenas — host-owned). Max expected project
latency is bounded (a few thousand samples) so these are small.

PDC runs at graph build. Live-adjusting latency during playback
(machine changes its own latency) is possible but requires another
graph swap; machines shouldn't do this continuously.

## Sample accuracy

All machines see the same `block_start` within a block. Note event
offsets are block-local (`sample_offset` in the event). Transport
state is homogeneous within a block — if transport stops mid-block,
the host splits the block. Same for tempo ramps crossing a block
boundary.

This means:
- Offline render at any block size produces bit-identical output to
  realtime at any block size (within float determinism caveats).
- Unit tests can drive ctx directly without running the audio
  thread.

## Scheduler parallelism (deferred)

v1: single-threaded graph walk on the audio thread. Fine for
dozens of machines at 64-sample blocks.

Later: tracks with no inter-dependencies (most of them) can run in
parallel on worker threads. The pure `(ctx, persistent) → output`
contract makes this trivial to add later. The block arena becomes
one-per-worker; the voice pool services become thread-local (or
lock-free per-machine). Not a v1 concern.

## UI-side scheduling (control-rate)

Some things run on the UI thread, not audio:

- Piano roll visual playhead (reads `transport.current_sample()`
  60× per second)
- Level meters (read from an SPSC ring the audio thread writes to)
- Preset loads (prepare new params on UI thread, mark dirty)
- File watcher triggers for hot-patch
- Project save/load
- Animations (knob tweaks, UI transitions)

None of these cross into audio directly. They communicate with
audio only through:
- Transport commands (play/stop/seek — atomic state + scrub_sample)
- Param writes (pending buffer + dirty flag)
- Note events from UI (piano roll playback) — pushed into an SPSC
  ring that the audio thread drains at the top of each block
- Graph swaps (atomic pointer)
- Hot-patch trampoline repoints (atomic pointer under fy's mutex)

## Transport commands

```zig
pub fn play(self: *Transport) void;
pub fn stop(self: *Transport) void;
pub fn pause(self: *Transport) void;
pub fn seek(self: *Transport, sample: u64) void;
pub fn setLoop(self: *Transport, start: u64, end: u64) void;
pub fn setTempo(self: *Transport, bpm: f64) void;
pub fn setRecording(self: *Transport, on: bool) void;
```

All called on the UI thread. The audio thread reads consistent
state at block boundaries only.

**Discontinuities.** The engine remembers where its last block left the
transport. Finding it elsewhere while playing means the UI seeked: the
instruments are reset, so notes held across the jump don't hang (effects
keep their tails), and a seek landing mid-block survives, since the block
end is written with a compare-exchange. After a seek, play start, loop
wrap or the start of an offline render, the first block **chases**: a
note already sounding at that point starts on the block's first sample,
unless it has under 5 ms left.

## Tempo map

Tempo is not just a scalar — it's a **map**: piecewise-linear curve
vs. musical time, or vs. sample time. Click-based tempo changes
(Ableton-style warp) live here too.

```zig
pub const TempoMap = struct {
    points: []TempoPoint,   // sorted by sample
    pub fn tempoAt(sample: u64) f64;
    pub fn beatAt(sample: u64) f64;
    pub fn sampleAt(beat: f64) u64;
};

pub const TempoPoint = struct {
    sample: u64,
    tempo_bpm: f64,
    beat_at_point: f64,
};
```

At block start, the host computes `(tempo_bpm, ppq_position)` from
the map for the block's start sample and puts them in ctx. Within a
block, tempo is constant — if the map has a change inside this
block, the host splits the block.

## Meter map

Meter (time signature) is **not a clock.** The atomic musical unit
stays the quarter-note beat (PPQ); the tempo map alone maps
beats↔samples. Meter only groups beats into bars — it answers "where
is the downbeat", never "how fast". The audio callback never reads it,
and a meter change **never splits a block** (unlike a tempo change).
It is a view over the beat axis, parallel to the tempo map.

A bar of `N/D` spans `N * (4/D)` quarter-beats: 4/4 = 4, 7/8 = 3.5,
13/16 = 3.25. Meter changes happen at bar boundaries, so the map is
keyed by bar index, not by sample or beat.

```zig
pub const MeterMap = struct {
    points:         []MeterPoint,  // sorted by start_bar; points[0].start_bar == 0
    bar_start_beat: []f64,         // prefix-sum cache, rebuilt on edit

    pub fn barLenBeats(bar: u32) f64;      // quarter-beats in that bar
    pub fn barStartBeat(bar: u32) f64;     // quarter-beat where the bar begins
    pub fn beatToBarPos(beat: f64) BarPos; // beat → {bar, beat_in_bar, tick}
};

pub const MeterPoint = struct {
    start_bar:   u32,
    numerator:   u8,
    denominator: u8,          // power of two: 2, 4, 8, 16
    groups:      Groups = .{},      // additive grouping (7/8 as {2,2,3}), inline [16]u8 + len
};
```

Because bar lengths vary, `barStartBeat` is a prefix-sum walk over the
segments. Cache it (`bar_start_beat`) and rebuild on edit; that cache
is what the ruler, snap grid, metronome, and bar:beat:tick readout all
read. Seeking to any bar stays O(1).

`groups` carries the additive feel (7/8 as 2+2+3 vs 3+2+2). It drives
the metronome's secondary accents and the brighter in-bar grid lines.
Empty means the default: /4 meters accent only the downbeat; /8 and
finer split into 3s when the numerator divides by 3, else 2s with a
trailing 3 (7/8 → 2+2+3, 11/8 → 2+2+2+2+3). Groups that don't sum to
the numerator are ignored, and changing a point's numerator clears
them. They are stored inline (at most 16 — numerator ≤ 32, groups ≥ 2)
so a point stays plain data for the audio copy, and saved as
`"groups":[3,2,2]` on the meter entry only when set. The ruler's
right-click meter menu has **Grouping of N/D**: the default, then every
split into 2s and 3s, fewest groups first (`meter.groupingChoices`,
up to 12). slabkit: `Song(meter=(7, 8), groups=(3, 2, 2))`.

### Generators

A meter map can be authored by hand (drop change markers, see
[Markers](#markers)) or **generated by a normal fy word**. Generators
run on the main thread at authoring/patch time, never on the audio
thread — so they are plain `:` words with the full language
(recursion, lists, heap), **not `dsp:` words.** The dsp/non-dsp split
is exactly the audio/not-audio split, and meter is not audio; writing
a generator in dsp2 would mean fighting constraints that exist to
protect a thread the generator never runs on.

The contract is **materialize-on-run**: a generator emits the list of
`MeterPoint`s, the host stamps it into the map and rebuilds the
prefix-sum cache. The document stores the materialized map (dumb,
serializable, deterministic on load); the generator word is an
attached recipe that can be re-run — like a freeze you can thaw.

```
\ illustrative — emit (start_bar num den groups) per bar
: fib-meter ( bars -- )
    0 do
        i fib 8 mod 1+    \ numerator: fibonacci folded to 1..8
        8                 \ denominator: eighth
        i emit-meter-bar  \ host collects into the map
    loop ;
```

Two rules keep generators safe:

- **Total over `[0, project_bars)` and bounded.** Raw Fibonacci bar
  lengths blow up (bar 15 ≈ 610 eighths) — cap or cycle.
- **Seeded if random.** Generators that use randomness (random-walk
  meter, cellular rules) must seed from a value stored in the project,
  so save/load reproduces. Main-thread fy may use randomness; the
  audio thread may not.

Menu, all ~5–15 lines of plain fy returning `(num den groups)` per
bar and all consumed identically by the engine: Euclidean grouping
(bjorklund → 2+2+3), Fibonacci/Lucas folded mod-N, cyclic lists,
rule-based ("every 4th bar drops a beat"), per-section lists, L-system
rewrites, prime-length bars, seeded random walk.

### Runtime change

Both maps are mutable while playing. Tempo edits take effect via
block-splitting (above). Meter edits — including a generator
re-materializing after a hot-patch — **take effect at the next bar
boundary**, not mid-bar: re-laying bar lengths under a live playhead
would jump the loop and the metronome accent. The host quantizes the
swap to the next downbeat, the same discipline as the graph swap. This
is what makes livecoding the *structure of time* safe: edit the
generator word, and the next bar lays out the new grid while the audio
path is untouched.

## Markers

The arrangement ruler carries **markers** — positioned annotations in
beats. Two families:

- **Binding markers** are the editing handles for the tempo and meter
  maps. A tempo marker *is* a `TempoPoint`; a signature marker *is* a
  `MeterPoint`. Dragging one edits the underlying map; the map stays
  the source of truth, the marker is just its visual handle on the
  ruler.
- **Locator markers** are a standalone list on the Document — named
  cue points ("verse", "drop", "B section") with no audio or grid
  effect. They exist for navigation and structure.

```zig
pub const Marker = struct {
    beat: f64,
    kind: enum { locator, tempo, meter },
    name: []const u8, // locators; binding markers label from their map point
    ref:  u32,        // index into the tempo/meter map, for binding kinds
};
```

Locators give jump targets (next/prev marker, loop-between-markers)
and a place to hang section names. Keeping them separate from the maps
means moving a label never perturbs timing. Persisted with the
document; edited on the ruler per
[docs/12](12-ux-interaction-spec.md#markers-and-meter).

## Recording

### Audio input capture (implemented — v1)

The device is **playback-only** until the mic is needed: while a track
is armed or a take is recording it re-opens in **duplex** mode
(`ma_device_type_duplex`): stereo f32 playback plus a **mono f32
capture** half, both at 48 kHz in one callback. Opening the mic at
startup would switch Bluetooth headsets (AirPods) into their call
profile for the whole session, whose narrow band and noise suppression
mangle the output (drums vanish into clicks). If duplex init fails — no
input device, denied mic permission — the device falls back to
playback-only and recording is disabled (`Audio.capture_available ==
false`); the app still runs. See `src/audio.zig`
(`Audio.setWantCapture`).

The pipeline (`src/recorder.zig`):

1. **Capture (audio thread).** `Recorder.captureFn` runs *before*
   render each block, so it stamps the take's start from the
   block-start transport position. It only copies the input block into
   a preallocated **lock-free SPSC ring** (`Ring`) — no allocation, no
   syscalls, no locks. A short push counts as an overrun.
2. **Writer thread.** Drains the ring and streams it to a float32-mono
   **WAV** under `recordings/take-NNN.wav`, patching the RIFF/data
   sizes on close. (Streaming to a real file — not an in-memory buffer
   — so takes survive reload: audio clips resolve by path through the
   `AudioPool`.)
3. **Finalize (UI thread).** When the writer signals done, the host
   joins it, `AudioPool.loadFile`s the take (reusing the normal
   loader), and drops an audio clip on the armed track via the same
   undoable path as audio import. The clip start is **latency-
   compensated** — shifted earlier by `Audio.roundTripLatencyFrames()`
   (capture + playback internal periods) so it lands where the sound
   actually occurred.

UI: a per-track **R** arm toggle (audio tracks only) in the
arrangement header; the top-bar record button records the first armed
track, starts the transport, and lights `accent_rec` while capturing.
`Track.armed` is a transient atomic (not persisted). While recording,
the armed lane shows a **live take** — a red region growing from the
take's start beat to the playhead, with a waveform drawn from the
recorder's peak buckets (the writer thread fills one peak per
`SAMPLES_PER_BUCKET` drained frames; the UI reads the published count).
It's replaced by the real clip on stop.

**Input device** is chosen from a caret dropdown next to the record
button (top bar). `Audio` keeps a persistent `ma_context`;
`listInputDevices` enumerates capture devices and `useInputDevice`
stops/re-opens/restarts the device with the chosen `ma_device_id`
(render + capture hooks persist across the swap). Device switching is
blocked while recording.

### Deferred

- **Monitoring** — no live input-through-graph monitoring yet (it adds
  a full round-trip of latency). The `audio_in` ports on `MachineCtx`
  are the eventual route.
- **Multitrack / takes / punch / count-in / loop-record.**
- **Note recording.** Instrument-track note capture (keyboard / MIDI
  in → active clip) is unbuilt; it reuses the same arm model but writes
  to the Document, not disk.

## Summary of what the transport guarantees

- Sample-accurate block scheduling; no drift between machines.
- Audio thread reads block-consistent state for transport/tempo.
- UI reads approximate time via atomic; never blocks the audio.
- Graph changes are applied atomically between blocks.
- PDC keeps parallel paths aligned automatically.
