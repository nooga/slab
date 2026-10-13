# 37 — Realtime publication and regression checks

Implemented on the audio publication branch from master `b8b6566`.

The callback must keep rendering its current valid version when UI,
compilation, loading or reclamation is delayed. It never acquires the
control/compiler mutex, takes a rack mutex, allocates a replacement,
destroys a retired object, or spins waiting for those operations.

## Phases

1. **Owned snapshots.** `handoff.Slots` has a producer slot, a consumer slot
   and an atomic exchange slot. A complete version publishes/adopts with
   one exchange; intermediate versions coalesce. No timing assumption
   permits reusing the consumer's slot. Notes/automation, routing (including
   send targets/levels), tempo, meter and preview use this protocol.
   Render/capture function/context pairs also publish coherently, with an
   acknowledgement for context lifetime. The rendering thread adopts track
   snapshots before latency calculation;
   every worker holds that same version until the chunk is finished.
2. **Assets and racks.** UI builds decoded assets, keymaps, anti-alias pools
   and wavetable levels before publishing coherent bindings. Old storage
   enters a bounded UI retirement list and cannot be collected before audio
   acknowledges adoption. Sampler zone settings publish with the related
   bindings. Rack configuration changes preserve unchanged parts' held
   notes, and presets publish as complete transactions. Existing sample
   replacement behavior (stop voices referencing the old pool) is preserved;
   wavetable/anti-alias changes keep voices running. Muted/idle machines
   adopt updates too.
3. **Controls and compiled instances.** Grouped model/preset targets and
   their snap generations publish together. DSP params/smoothing belong to
   audio. Instruments and insert chains are prepared outside playback and
   published without stopping the device. Reordered unchanged effects retain
   idle history. Removed/replaced instances and stable effect telemetry are
   freed after acknowledgement. New source instances have private compilers
   and executable images; published word definitions reject in-place compile
   and standalone TCP patching. This is instance replacement, not automatic
   state-preserving source hot-reload.
4. **Worker admission and completion.** Live callbacks enlist workers only
   when every worker acquired realtime policy and membership in the current
   device workgroup ([Apple's parallel-thread guidance](https://developer.apple.com/documentation/audiotoolbox/adding-parallel-real-time-threads-to-audio-workgroups)).
   Otherwise playback renders serially; non-realtime
   workers remain useful offline. Idle workers sleep instead of spinning.
   The rendering thread works on ready nodes and uses completion signals
   when remaining nodes have been claimed. It joins admitted workers before
   reusing their block data. A deferred sum must rescan ready nodes before
   sleeping: it can release a bus without changing the completed-node count.
5. **Regression/performance checks.** The tests below exercise ownership,
   delayed control work, memory lifetime, real DSP and scheduler handoffs.

## Limits and ownership contracts

Each handoff has exactly one producer and one consumer. Readers delegated
by the consumer must finish before it adopts another version. Atomics alone
are not a substitute for these ownership rules. Ordinary independent targets
(volume, pan, mute, solo, transport requests and unison controls) retain their
bounded atomic paths; held-note and recording streams retain bounded rings.

Asset retirement holds at most 64 pending resources per instance; rack and
track retirement hold at most 128 removed machines. A full list rejects or
defers control work, never blocks audio. Wavetable editing retains dirty work
for retry. Insert chains have a 128-effect limit; a project beyond that
limit fails explicitly with `TooManyEffects`. Saved syntax/control IDs are
unchanged. Extra owned snapshots trade preallocated memory for safe lifetime.
Large chain snapshots, retirement storage and adoption scratch are allocated on UI
at track creation; small track handles keep 32-track project loading within
the stack budget.

Document/track-array replacement, device reconfiguration and explicit offline
bounce retain their device-stopped lifecycle. Workgroups are reassigned with
the device stopped, and recording rings are destroyed only after stopping
capture callbacks. UI may not resize the track
array while a callback uses it. Source edits still reach the next instance;
retaining DSP state across a code/layout change needs a separate migration
contract. Live debug printing/getenv probes are disabled; offline probes
remain available. Do not add I/O back to the live callback for diagnostics.

## Regression checks

Final validation: all 459 tests pass in both Debug and ReleaseFast; the
ReleaseFast application builds and signs successfully. The opt-in native
output-device check also passes on the development Mac.

```sh
zig build test
zig build test -Doptimize=ReleaseFast
zig build test -Dtest-filter=handoff
zig build test -Dtest-filter=realtime
SLAB_AUDIO_DEVICE_TEST=1 zig build test -Dtest-filter='realtime device:'
```

Coverage includes:

- Holding an owned snapshot across 9,998 publications without overwrite;
  49,999 concurrent publications without torn cells or backwards generations.
- Tempo adoption while UI is suspended in an unfinished edit; coherent native
  callback function/context pairs, including disabling a hook.
- Bounded retirement/backpressure and destruction only after acknowledgement.
- Callbacks producing audible output while the control mutex is held. This
  test fails on pristine master and passes with publication; it allows a
  generous 500 ms for test-thread scheduling, not an audio deadline.
- Real sampler rendering while forty assets are replaced and another private
  fy instance compiles. DSP keeps progressing, samples remain finite and the
  testing allocator checks cleanup.
- Coalesced asset changes, zero instance-allocator calls during render,
  coherent grouped controls and rejection of in-place published definitions.
- Serial live fallback without realtime admission; routed parallel renders
  bit-identical to serial, including buses, sends, sidechains and PDC.
- An opt-in silent output-device check of workgroup identity across stop/start
  (passed on the development Mac); it opens playback only.
- A track-handle size budget and full Debug project-load tests, guarding
  against embedding large publication buffers in stack arrays.
- A deterministic deferred-bus-sum case that must find ready work before
  entering a completion wait. Repeated benchmarking caught this case during
  development; the reproducer now runs in the normal suite.

## Repeated throughput comparison

The opt-in benchmark uses two fixtures: twelve oscillators feeding four
buses/returns, and eight four-note Juno instruments with Phaser inserts.
Each measures nine warmed renders at zero/four helper threads, excludes JIT
preparation, and hashes the complete output. The comparison alternates
baseline/candidate order across three runs and rejects changed output hashes,
nondeterministic hashes or median regressions greater than 5%. Benchmarks
have a 300-second process-group timeout so a synchronization stall fails.

Prepare a disposable checkout; `--install-fixtures` copies only the same
benchmark tests into it, leaving its production implementation unchanged:

```sh
mkdir -p /tmp/slab-master-benchmark
git archive origin/master | tar -x -C /tmp/slab-master-benchmark
python3 tools/check_realtime_perf.py \
  --baseline /tmp/slab-master-benchmark --candidate "$PWD" \
  --install-fixtures --output /tmp/slab-realtime-performance.json
```

Measured 2026-10-13, macOS ARM64, Zig 0.16.0, ReleaseFast host (fy module
uses its existing Debug setting), baseline `b8b6566`. Median of three runs:

| Fixture | Helpers | Master | Publication | Change |
|---|---:|---:|---:|---:|
| Juno + Phaser | 0 | 128.528 ms | 128.049 ms | -0.37% |
| Juno + Phaser | 4 | 35.008 ms | 34.835 ms | -0.49% |
| Routed oscillators | 0 | 10.359 ms | 10.369 ms | +0.10% |
| Routed oscillators | 4 | 6.725 ms | 6.455 ms | -4.01% |

Output hashes match across implementations and thread counts. These are
headless throughput measurements, not per-callback worst-case bounds or a
CoreAudio device deadline certification. The decisive improvement under
control contention is structural and separately tested: the callback no
longer depends on that control thread releasing a mutex. Synchronous
parallel rendering still depends on admitted realtime workers completing
within the device's budget; workgroup membership does not prove arbitrary
machine code fits that budget.
