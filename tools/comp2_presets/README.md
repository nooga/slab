# comp2 preset design

The harness the comp2 presets were designed with (docs/24 §Presets): each
preset's character (ratio, knee, times, detector, HPF, mix) is fixed by its
intent in `design.py`; the threshold is solved on real material for a GR
target and the makeup for a level target, and the result is measured with
the bench's `file` case.

```sh
S=scratch/comp2-presets
python3 tools/comp2_presets/dry_stems.py zig-out/bin/slab $S/dry     # what each comp2 in the songs hears
python3 tools/comp2_presets/drum_stems.py zig-out/bin/slab $S/dry    # each song's drum group
zig build bench -Doptimize=ReleaseFast -- --help                     # builds the bench (newest one is used)
python3 tools/comp2_presets/tune.py before                           # the current presets on their material
python3 tools/comp2_presets/design.py [preset ...]                   # solve, print, write $S/designed.json
python3 tools/comp2_presets/explore.py drum-bus '{"rel":0.25}' '{"hpf":150}'
```

Stems come from `songs/*.slab`; regenerate the songs first when their
chains change. The printed columns: absolute gain percentiles (g50/g10/g01
at mix 1 and makeup 0 are -GR), pump = GR std, crest = median over 400 ms,
spread = std of 100 ms levels, t/b = loudest 1 ms in the first 15 ms over
the 40-120 ms body, lvl = output minus input RMS.
