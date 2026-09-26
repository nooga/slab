# Audio Probe

Offline debugging tools for Slab machines.

## Kernel Probe

Run a single Fy `dsp:` kernel fixture with deterministic aligned buffers:

```sh
zig build kernel-probe -- \
  --kernel=kernels/00-primitives/v2.fy \
  --word=k-v2-add \
  --case=v2-add \
  --iters=1000000 \
  --out=scratch/kernel_v2_add
```

Outputs:

```text
scratch/kernel_v2_add_metrics.json
scratch/kernel_v2_add_disasm.txt
scratch/kernel_v2_add_lanes.csv
```

Supported initial cases:

```text
v2-add
v2-mul
v2-fmadd
tanh-table-sweep
tanh-rational-sweep
saw-polyblep-render
saw-falling-polyblep-render
saw-cap-polyblep-render
saw-topcut-polyblep-render
square-polyblep-render
pulse-polyblep-render
adsr-linear-render
adsr-cap-render
```

Table saturator fixture:

```sh
zig build kernel-probe -- \
  --kernel=kernels/02-shapers/tanh_table.fy \
  --word=k-tanh-table \
  --case=tanh-table-sweep \
  --iters=1000000 \
  --out=scratch/kernel_tanh_table
```

Plot a kernel-probe run:

```sh
python3 tools/audio_probe/plot_kernel_probe.py scratch/kernel_tanh_table
```

For `tanh-table-sweep`, metrics also include a libc `tanh` baseline,
a native Zig table-lookup baseline, and table error versus true tanh.

Oscillator fixture example:

```sh
zig build kernel-probe -- \
  --kernel=kernels/01-oscillators/square_polyblep.fy \
  --word=k-square-polyblep \
  --case=square-polyblep-render \
  --iters=1000000 \
  --out=scratch/sweep_square_50_2000
```

Oscillator probes emit the normal metrics/disassembly/CSV artifacts plus
a 48 kHz stereo WAV. The WAV is a 2 second 50-2000 Hz sweep for audition;
the metrics still use the fixed bin-aligned render for deterministic
alias/error ratchets.

Envelope fixture example:

```sh
zig build kernel-probe -- \
  --kernel=kernels/03-envelopes/adsr_linear.fy \
  --word=k-adsr-linear \
  --case=adsr-linear-render \
  --iters=1000000 \
  --out=scratch/kernel_adsr_linear
```

Capacitor-like ADSR:

```sh
zig build kernel-probe -- \
  --kernel=kernels/03-envelopes/adsr_cap.fy \
  --word=k-adsr-cap \
  --case=adsr-cap-render \
  --iters=1000000 \
  --out=scratch/kernel_adsr_cap
```

Envelope probes emit time/value CSV, metrics, disassembly, and an
envelope plot with attack, decay, gate-off, and release-end markers.

## Render

Render a machine chain through the real fy machine ABI:

```sh
zig build machine-probe -- \
  --chain=verb1 \
  --input=impulse \
  --seconds=2 \
  --out=scratch/verb1_impulse \
  --params=verb1.mix=1,verb1.level=1
```

Another example, using a note source through effects:

```sh
zig build machine-probe -- \
  --chain=fm1,chorus,verb1 \
  --input=note:60 \
  --seconds=2 \
  --out=scratch/fm_chorus_verb \
  --params=fm1.level=0.5,verb1.mix=0.5
```

Outputs:

```text
scratch/name.wav
scratch/name_metrics.json
```

Supported inputs:

```text
impulse
step
sine:440
note:60
```

## Plot

The plotting scripts use `numpy` and `matplotlib`:

```sh
python3 -m pip install matplotlib numpy
```

Then:

```sh
python3 tools/audio_probe/plot_probe.py scratch/verb1_impulse.wav
```

Outputs:

```text
scratch/verb1_impulse_waveform.png
scratch/verb1_impulse_levels.png
scratch/verb1_impulse_spectrum.png
scratch/verb1_impulse_spectrogram.png
```

Compare two renders:

```sh
python3 tools/audio_probe/compare_probe.py \
  scratch/old.wav \
  scratch/new.wav \
  --out-prefix scratch/verb_compare
```

Drum kernels (kernels/05-drums, docs/16):

```sh
zig build kernel-probe -- --kernel=kernels/05-drums/decay.fy --word=k-decay-exp --case=decay-exp-render --iters=1000000 --out=scratch/drum_decay
zig build kernel-probe -- --kernel=kernels/05-drums/kick.fy --word=k-kick-render --case=drum-kick-render --iters=96000 --out=scratch/drum_kick
zig build kernel-probe -- --kernel=kernels/05-drums/snare.fy --word=k-snare-render --case=drum-snare-render --iters=96000 --out=scratch/drum_snare
zig build kernel-probe -- --kernel=kernels/05-drums/clap.fy --word=k-clap-render --case=drum-clap-render --iters=96000 --out=scratch/drum_clap
zig build kernel-probe -- --kernel=kernels/05-drums/hat.fy --word=k-hat-render --case=drum-hat-render --iters=96000 --out=scratch/drum_hat_ch
zig build kernel-probe -- --kernel=kernels/05-drums/hat.fy --word=k-hat-render --case=drum-openhat-render --iters=96000 --out=scratch/drum_hat_oh
```

`decay-exp-render` ratchets the decay coefficient against libm exp plus
an exact multiplicative trace (the dsp-std functions themselves are
covered by `src/dsp_std_test.zig`);
`drum-kick-render` renders three velocity-varied kick hits to a WAV +
lane CSV with peak/DC/finite ratchets.
