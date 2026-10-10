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
> fader is applied, then the interleaved write + the output stage
> (`MasterClip`: soft past ±0.95 by default, or hard, or off). The master is
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
decoded f64 sources (via `wav.zig`), mono or stereo (a file's first two
channels, `wav.loadStereo`), each paired with a `waveform.PeakCache`
(of the mid, for a stereo source) for zoomable waveform drawing. A
stereo source plays its channels to L and R; a mono one plays to both. A `Clip` carries a
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
path). Import via the arrangement's right-click **Import audio…** (WAV,
AIFF/AIFF-C or FLAC; `wav.loadStereo` parses WAV and AIFF itself and
decodes FLAC with miniaudio). Unlike
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

Machines report latency in samples (manifest `latency!`, docs/04), read
each block, so a knob that changes it (limiter2's LOOK) takes effect at
the next block. Canonical example: a send with a reverb that has 0
internal latency arrives earlier than the dry track that went through a
lookahead limiter with 97 samples of latency; the host delays the send.

Each block, before rendering (`Engine.computeLatencies`):

1. In render order, a track's latency at its taps is its input's (0 for
   a track, the latest of its feeds for a bus) plus its chain's: the
   instrument's (not a bus's) and every insert that isn't bypassed.
2. Each bus's input latency is the max over everything summed into it,
   outputs and sends alike (muted ones too, so muting doesn't move the
   others); the master's likewise.
3. Every path into a sum is delayed by the difference, read back from the
   source track's tap history (`PdcHistory`: a ring per track of the
   pre- and post-fader taps, 8192 samples, one heap allocation made at
   startup). A path needing no delay reads the block itself, so a
   project without latency renders exactly as without PDC.

Machines operate latency-naively; the host's delays do the aligning.
What's left late is the whole project, by `master_latency`: an offline
bounce drops that many frames from its start (keeping the block grid, so
block-rate randomness renders the same), and a recorded take is placed
earlier by it on top of the device round trip.

Sidechain keys are aligned too. A keyed effect's input is as late as
the track's input plus the instrument and the inserts before it; its key
is as late as the source's taps. An early key is read back from the
source's pre-tap history. A late key instead makes the track's own input
later (step 1 takes the max): a bus's feeds are delayed more, and an
instrument track's chain input (instrument plus audio clips) is delayed
through a third history tap. A track that doesn't render writes silence
into its history, so un-muting it replays nothing stale. A machine the
host skips while it's silent (docs/04 §Idle skipping) keeps its latency
in the sums, and its track's history is written every block as usual.

The UI shows `master_latency` in the transport bar while it isn't 0, and
each latent device's share on hover over its name.

Not compensated yet: a change of latency mid-play jumps the delays (a
click, like any insert added while playing).

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

## Parallel rendering

Built (`src/engine.zig` `renderChunk`, `src/render_pool.zig`). Tracks
render on several threads, and the output is bit-identical to a
one-thread render at any thread count.

**Render, then sum.** A block's work per node splits in two:

- *Render* (`renderNode`), on any thread: the instrument or the bus
  input, the insert chain and the fader, into the node's own pre and
  post taps and its PDC history, plus its meter. It touches only that
  node's state and what feeds it.
- *Sum* (`mixContrib`): one output or send of a rendered node, added
  into a bus's input or the master. Each destination keeps its
  contributions in render order and takes them one at a time, from
  whichever thread finishes the one it waits on (`advanceDest`). Every
  buffer adds in the order a serial render adds it, which is what keeps
  the floats identical.

**Readiness.** A bus is ready once its whole input is summed. A keyed
node is ready once its keys have rendered (it reads their pre taps and
history, not a sum). Everything else is ready at the block's start.
Only edges from nodes earlier in render order count, so a cycle left in
the graph renders, as it does serially.

**Scheduling.** A thread takes the ready node with the highest
priority: its own smoothed render time plus the costliest chain it
feeds, so long chains start first. A block can't finish faster than its
critical path, the costliest chain from a source through its buses to
the master, plus the master chain, which runs after the sums.

**Threads.** `--threads N` sets the total, the audio thread included;
the default is one per performance core. Workers sleep on a Mach
semaphore between blocks, are woken at a block's start (at most one per
node beyond the first), spin while it is open and help render.
A worker that wakes late finds the block closed. The audio thread
renders anything no worker took, so a descheduled worker costs time,
never output.

**Real-time workers.** Each worker takes Mach's time-constraint policy
(period one block, up to half of it computing) and joins the output
device's I/O workgroup (`kAudioDevicePropertyIOThreadOSWorkgroup`), so
it is scheduled like CoreAudio's own I/O thread. When the device is
reopened (the mic armed, another input chosen) the workers move to the
new workgroup as they next wake. `--no-rt-workers` leaves them at
user-interactive QoS, which the scheduler may preempt or move to
efficiency cores under load. Headless renders never use real-time
workers.

**Thread lamps.** The transport bar's stats display shows a lamp per
render thread (the audio thread first) beside CPU, lit by how much of the
audio budget that thread spent rendering and mixing nodes, and red from
85%. Each thread adds its ticks to its slot (`render_pool.slot`,
`Engine.thread_busy`); the UI reads and clears them every frame
(`takeThreadLoad`) and smooths them. CPU itself stays the callback's
wall time against the budget.

**fy.** Each machine owns its fy instance and JIT image; raw kernel
calls touch only that instance and their own slots. `Builtins.fyPtr` is
thread-local in fy. The callback lock that keeps hot-patch and runtime
asset swaps out of renders is taken once per block by the engine (the
audio callback and each offline chunk), not per machine.

**Measured** (offline bounce, M-series, 8 performance cores):
sweat_geometry 66.7 s → 21.4 s, broken_glass 4.5 s → 1.0 s, the others
1.8–2.8× faster. The slower ones are bound by their critical path: one
heavy synth through its bus and the master.

**Not yet:** splitting one node's insert chain across threads.

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
transport. Finding it elsewhere while playing means the UI seeked; a
loop wrap is a jump too. The first block after a jump sends note-offs to
the notes that were sounding where the playhead left, so their voices
release (a reset would cut them mid-waveform: a click), and **chases**
the notes under where it landed, starting them on its first sample
unless they have under 5 ms left. A note sounding at both points just
carries on, so scrubbing through a pad doesn't retrigger it. Effects
keep their tails. Play start and the start of an offline render chase
too. A seek landing mid-block survives, since the block end is written
with a compare-exchange.

## Tempo map

Tempo is a **map** over the beat axis: points at beats, each a step or a
linear ramp to the next, with the time each point starts cached so
beats↔seconds is one lookup and a closed-form formula. Blocks split at
tempo points (as they do at the loop end), `MachineCtx.tempo_bpm` is the
tempo at the chunk's start, and an edit while playing rebases the
sample counter so the playhead keeps its beat. The design, with
sections, groove, polytempo and freeze, is
[docs/28](28-time.md#tempo-map).

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
  cue points ("vocal in", "fix this") with no audio or grid effect.
  They exist for navigation. **Sections** (INTRO, VERSE, DROP) are a
  lane of their own, back to back; their TEMPO and METER fields edit
  the maps at the section's start
  ([docs/28](28-time.md#locators-and-sections)).

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
