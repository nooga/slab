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
