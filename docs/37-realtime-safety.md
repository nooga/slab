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

Final validation: all 470 tests pass in both Debug and ReleaseFast; the
ReleaseFast application builds and signs successfully; fy's own 82 tests
also pass. The opt-in native
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
uses its existing Debug setting), baseline `b8b6566`, final callback-audit implementation. Median of three runs:

| Fixture | Helpers | Master | Publication | Change |
|---|---:|---:|---:|---:|
| Juno + Phaser | 0 | 131.710 ms | 129.183 ms | -1.92% |
| Juno + Phaser | 4 | 35.007 ms | 34.489 ms | -1.48% |
| Routed oscillators | 0 | 10.331 ms | 10.384 ms | +0.51% |
| Routed oscillators | 4 | 6.677 ms | 6.167 ms | -7.64% |

Output hashes match across implementations and thread counts. These are
headless throughput measurements, not per-callback worst-case bounds or a
CoreAudio device deadline certification. The decisive improvement under
control contention is structural and separately tested: the callback no
longer depends on that control thread releasing a mutex. Synchronous
parallel rendering still depends on admitted realtime workers completing
within the device's budget; workgroup membership does not prove arbitrary
machine code fits that budget.


## Follow-up callback audit (2026-10-13)

The audit traced playback/capture entry, graph scheduling and PDC, raw DSP
callers, rack/track adoption, clip stretching, and UI readers of DSP state.
It found and fixed these concrete issues:

- **Capture stop did not establish quiescence.** A callback that already
  saw recording could still push after the writer finalized. Entry/exit
  atomics now fence the final drain; the writer can wait, audio cannot.
  Writer creation completes before capture admission is published.
- **Lazy SMEAR pointer publication raced readers.** UI initializes and
  touches working storage before release-publishing pointers; audio uses
  acquire loads, and allocations survive until stopped teardown.
- **Displays read mutable DSP state and rings.** Voice selection/state,
  tempo/sample rate, scopes, dynamics/meters and graphic-EQ windows now use
  an audio-to-UI owned handoff. Storage allocates on UI when a panel first
  requests it. DSP performs bounded copies only on UI request, including
  while muted/idle; a suspended UI does not block DSP or expose overwritten
  buffers. Tests poison the instance allocator while publishing displays.
- **Latency queries read mutable parameters.** Machine-bay and engine queries
  now read an atomic audio-prepared report. Snapped/discrete control versions
  prepare derived latency before the engine computes compensation.
- **Limiter fractional wrap could read across a channel boundary.** The delay
  is now quantized to its reported whole-sample latency before ring indexing.
  A real limiter plus a direct impulse previously produced separate peaks;
  the regression now requires one aligned peak in the first changed block.
  Lookahead values near integer samples can shift by one sample compared
  with the old rounding behavior. Project/preset controls and syntax remain
  unchanged.
- **Interpreter/render-slot TLS was reached during raw rendering.** The
  binary imports `__tlv_bootstrap`; [Apple's TLV implementation](https://github.com/apple-oss-distributions/dyld/blob/main/libdyld/ThreadLocalVariables.cpp)
  can allocate on first access. Raw callers now have `callRealtime`, which
  executes prepared code without interpreter TLS. Worker slots pass as
  explicit arguments. The control caller API retains its previous behavior;
  a regression checks raw rendering leaves interpreter TLS untouched.
- **Preview retirement overflow leaked its current sample.** Full retirement
  storage now rejects replacement while retaining ownership; collection
  after acknowledgement allows retry. No audio wait or premature free.
- **Loop enable/bounds could come from different edits.** Audio now adopts
  the complete loop configuration once at callback start.
- **Unison reset overwrote atomic storage.** Reset now stores each independent
  target atomically. Creating boxed-word callbacks on sealed hosts is also
  rejected, closing another published-code mutation entry point.

Legacy host builtins and interpreter callbacks are used by standalone tests,
not by the application's raw DSP adapter. Their allocation/I/O capabilities
must not be mistaken for the permitted raw audio ABI. The instance-allocation
regressions are not a global interceptor for arbitrary OS/library allocation.

### Remaining deadline/timing limitations

**Large SMEAR windows exceed a normal callback budget.** This is existing
synchronous DSP work, even after allocation/publication fixes. A ReleaseFast
single mono clip probe on the Apple M1 Pro measured the following first-block
and peak costs over 160 blocks of 256 frames at 48 kHz (budget 5.333 ms):

| FFT window | First block | Peak block |
|---:|---:|---:|
| 16,384 | 3.637 ms | 3.637 ms |
| 32,768 | 10.819 ms | 10.819 ms |
| 65,536 | 16.640 ms | 16.640 ms |
| 131,072 | 29.360 ms | 29.360 ms |

These are observations on this host, not upper bounds. UI/control decoupling
cannot make this work fit a deadline. A prepared cache or an incremental DSP
schedule is needed before claiming these modes meet small live-block budgets;
waiting on a non-realtime background renderer would reintroduce the original
problem. Run the diagnostic explicitly:

```sh
SLAB_RT_AUDIT_BENCH=1 zig build test -Doptimize=ReleaseFast \
  -Dtest-filter='realtime audit benchmark'
```

**PDC remains chunk-granular.** The snapped/discrete first-block mismatch is
fixed; a latency that changes continuously during smoothing or automation
can still move within a chunk, while the graph uses one compensation delay
for that chunk. Per-sample compensation for varying lookahead is not proven
by the static/snap tests.

**Finite work is not a deadline proof.** Panic/stop clears preallocated delay
buffers; aggregate reset cost scales with the loaded machines. Parallel
callbacks still join admitted workers. Kernel complexity, physical memory
residency and OS/library behavior are outside the ownership proof. None of
these should be described as a universal worst-case realtime guarantee.
