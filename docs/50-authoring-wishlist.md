# 50 — Machine authoring wishlist

**Status: proposals.** Nothing here is built. These are the points where
writing a machine in fy cost time or forced a workaround, collected
while building the Magnet Zither (`kernels/07-effects/zither.fy`,
2026-11-11): ten strings of eight modes, two call-staged render words,
and both an effect and an instrument over one kernel. Each item says
what happened, what would fix it, and where the fix would land.
docs/34 is the same kind of list for production work.

## Language (`dsp:`, docs/18)

### 1. `call:` stage words can't compute anything

A word that contains `call:` may hold only its frame, references to the
frame's args, and `call:` lines. The zither instrument keeps its strings
in the shared region, so every block-prepare stage needs
`ctx.shared& p@64` first. The wrapper can't fetch it, so there are
eleven one-line words (`zi-prep-0` … `zi-prep-9`, `zi-prep-misc`) that
each fetch the pointer and inline the real stage.

Proposal: let a stage word bind values before its calls and pass them as
pointer args, or give entry words the shared region as an explicit
argument. Lands in `compileDsp2` (`fy/src/main.zig`).

### 2. No arrays of structs

A string's modes are six parallel `f64 … 80` arrays indexed by a
hand-computed `si 8.0 f* n f+`. A wrong index is not an error, only a
wrong sound.

Proposal: `ustruct` array fields with an indexed accessor
(`s.modes[j].y1`), where a constant index stays a plain field access as
`f@i` does today. Lands in the `ustruct:` parser and dsp2's field
addressing.

### 3. Indices are f64

`f@i` and `f!i` floor a float index. Ring and table code carries
counters as floats and pays the conversion on a runtime index.

Proposal: an integer local type for indices and counters.

### 4. Stack-shape errors don't show the shapes

A build error names the word, token, line, depth and arity. Inside a
`times` body or an `ifte` arm the useful fact is the stack the compiler
expected against the one it found.

Proposal: print both, with the names of bound locals, for mismatches in
`times` copies and `ifte` arms.

## Machine model (docs/02, docs/04)

### 5. Derived coefficients have no home

Params are capped at 4096 bytes (`MAX_PARAMS`), and derived fields live
in them. The zither's 480 per-mode coefficients overflowed
(`RawMachineStorageTooLarge`) and moved into state. State is the wrong
place: it is per region, zeroed on reset, and for an effect there are
two of them.

Proposal: a third region for derived data, sized by the manifest
(`derived-size!`), written by `derive` / `block-prepare`, read-only in
render, and kept across reset. Lands in `src/machines/fy_raw_machine.zig`
and `machines/lib/manifest.fy`.

### 6. A machine is a voice or an effect, never a generator

The zither sounds from silence (a spinning disc) and also answers notes
and input. As an effect it needs an instrument in front that never
plays. As a voice machine its shared word sleeps until the first
note-on, so a disc can't drone on an empty track.

Proposal: a generator mode, or the smaller rule that a voice machine
declaring `-1.0 tail!` keeps its shared word awake from load. The
second is a few lines in `renderVoiceSegment` and `updateIdle`.

### 7. Live replacement while playing

Source changes take effect when a new instance loads. With the bench
answering in seconds, hearing a kernel edit on the next block is the
largest remaining change to how the work feels (docs/09).

## Bench and tests (docs/13)

### 8. Knob sweeps are masked by the dry signal

`--sweep=all` on an effect measures the mixed output, so a knob that
only shapes the wet path (the zither's SPIN, ACROSS, ALONG) shows no
response. They went out unverified by numbers.

Proposal: sweep with the machine's mix control at full wet when it has
one, or let the manifest name the control and value to hold during
sweeps.

### 9. `--all --check` always fails

ambika, shift2, resonator2, buffer2 and phaser2 have no goldens, so the
full check exits non-zero and a real regression hides in the noise.

Proposal: record the five, and make a missing golden a distinct exit
status from a mismatch.

### 10. An unexplained stuck render

`zig build test` once reported "no progress for 30 s at 100 of 1000
frames: the render is stuck" and passed on two reruns. The cause was not
found. A flaky hang in the test host can hide a real bug; the watchdog
should dump which machine and entry word was running.

## Order

Items 5 and 2 together would have made the zither kernel about a third
shorter and removed both bugs hit while writing it. Item 6's small form
and item 9 are an afternoon each. Item 7 is the big one.
