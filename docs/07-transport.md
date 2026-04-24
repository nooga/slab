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
- **Automation clip:** a curve for a param; bound to the mod matrix

When transport is in a clip's range, the track's first insert (or
the clip directly, for audio clips) receives the clip's data. When
outside any clip, the track is silent (or looping, per settings).

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

## Recording

When `transport_state == .recording`, tracks that are record-armed
capture their input:
- Instrument track armed: record incoming note events (from
  keyboard / MIDI in) to the active clip.
- Audio track armed: record the summed output of its input chain to
  the active clip's audio buffer (appending).

Implementation detail: recording uses a lock-free SPSC ring between
audio thread and a writer thread that persists to disk (for audio)
or to the Document (for notes).

## Summary of what the transport guarantees

- Sample-accurate block scheduling; no drift between machines.
- Audio thread reads block-consistent state for transport/tempo.
- UI reads approximate time via atomic; never blocks the audio.
- Graph changes are applied atomically between blocks.
- PDC keeps parallel paths aligned automatically.
