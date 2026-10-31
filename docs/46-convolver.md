# 46 — The convolver: impulse responses for effects

**Status: prototype.** A host service that convolves an effect machine's
input with an impulse response (IR), and CONVO (`convo`), the convolution
reverb built on it. The engine is `src/convolver.zig`; the hookup is in
`src/machines/fy_raw_machine.zig`. CONVO's controls are in
[20-machine-reference.md](20-machine-reference.md).

## Why the host does it

A convolution reverb multiplies the input against seconds of IR. Done
sample by sample in a `dsp:` word, a 3.5 s stereo IR costs about 336 000
multiply-adds per sample, far past the per-track budget. Done by FFT in
blocks it is cheap, but block FFTs, partition spectra and their
bookkeeping are not what fy kernels are for. So the host convolves, and
the machine's kernel does everything after: the predelay, the filters,
the width and the mix, in fy like any other effect.

## The machine side

A machine asks for one IR with `convolver`, in place of `asset`:

```
"room" P.ir P.ir-len P.ir-sr "assets/hall.wav" convolver
```

- The file is a WAV relative to the machine's directory, mono or stereo.
  A stereo IR is true to its channels: L feeds L, R feeds R. A mono IR
  feeds both.
- It loads as an asset, with the same three PARAMS offsets, so the UI can
  swap it, presets can name another file (`"assets": {"room": ...}`), and
  `waveform-display` can draw it.
- Each sample, the kernel reads the convolved input as `io.cv-l` and
  `io.cv-r`. It arrives N = 256 samples late; the machine reports that
  with `latency!`, so the host delays the other tracks to match, and
  delays its own dry by N to line up.
- Effects only, one per machine.

## The engine

Uniform partitioned overlap-save. When the IR loads (off the audio
thread), it is resampled to the engine's rate, scaled so white noise keeps
its level, and cut into N-sample partitions, each transformed once to a
2N-point spectrum. Every N input samples the audio thread does one forward
FFT of the last 2N inputs, multiplies each partition against the matching
past input spectrum, sums, and does one inverse FFT, which gives the next
N outputs. Left and right share each transform: both are real, so they
travel as one complex signal, l + i·r, and split by the spectrum's
symmetry. `process()` allocates nothing.

Cost scales with IR length. CONVO with its 3.5 s stereo hall takes about
930 ns per sample in a ReleaseFast bench, under 5% of one core (as of
2026-10-31).

## CONVO

The host's convolved signal, then in fy (`kernels/07-effects/convo.fy`):
PREDELAY up to 200 ms, LO CUT and HI CUT one-poles, WIDTH on the mid and
side, LEVEL, and MIX against the dry. Two IRs ship:

- `hall.wav`: a synthetic stereo hall, early reflections over a decaying
  noise tail. No recording.
- `bowed-cymbal.wav`: a bowed cymbal from VSCO 2 CE (CC0), as a texture.
  Every note swells through the cymbal: convolution with a sound rather
  than a room. The `bowed-cymbal` preset loads it.

`songs/convolver_demo.py` plays one phrase dry, through verb2's hall, and
through each IR.

## Limits, and what would lift them

- **The IR is built for 48 kHz.** The engine doesn't know the session
  rate when the IR loads, and doesn't rebuild when it changes. At 44.1 kHz
  the room plays about 9% longer and lower; at 96 kHz it plays at half
  its length and an octave up. CONVO's own PREDELAY and filters follow
  the session rate. Rebuilding the IR on a rate change, off the audio
  thread, fixes it.
- **No crossfade on an IR swap.** A new IR replaces the old one whole, so
  swapping while the tail rings cuts it.
- **Uniform partitions.** Every partition is N long, so cost grows
  linearly with the IR. Non-uniform partitions (short ones first, longer
  ones later) would make long IRs much cheaper and allow a lower latency.
- **One IR per machine,** effects only.
