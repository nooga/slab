# mono1 Benchmark Log

Bench command:

```sh
zig build bench-mono1 -- --warmup=512 --blocks=5000
zig build bench-mono1 -Doptimize=ReleaseFast -- --warmup=512 --blocks=5000
```

The benchmark renders one sustained mono1 voice through the same fy host callback path used by the app. It does not include miniaudio scheduling, track mixing, poly voice fan-out, effects, logging, or GUI work. `mono_voices_at_48k_256` is the ideal count if the entire 256-frame callback budget were spent only on that one voice case.

## 2026-04-29 Baseline After Param Caching

Live path uses raw saw/pulse/sub in the normal mixer. HQ path uses BLEP saw/pulse/sub through `mono1-audio-hq`.

### Debug

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.4864 | 0.4607 | 1.0117 | 1899.8 | 10.97 |
| live lush chord voice | `mono1-audio` | 0.5651 | 0.5310 | 5.9888 | 2207.4 | 9.44 |
| live arp pulse | `mono1-audio` | 0.5451 | 0.5127 | 1.1429 | 2129.4 | 9.78 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.6521 | 0.6018 | 13.4820 | 2547.1 | 8.18 |
| hq blep arp pulse | `mono1-audio-hq` | 0.6188 | 0.5841 | 1.5840 | 2417.0 | 8.62 |

### ReleaseFast

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.1883 | 0.1790 | 0.3073 | 735.4 | 28.33 |
| live lush chord voice | `mono1-audio` | 0.2070 | 0.1931 | 0.3304 | 808.6 | 25.76 |
| live arp pulse | `mono1-audio` | 0.2010 | 0.1931 | 0.3015 | 785.1 | 26.54 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.1733 | 0.1557 | 4.8189 | 676.9 | 30.78 |
| hq blep arp pulse | `mono1-audio-hq` | 0.1675 | 0.1563 | 0.3318 | 654.2 | 31.84 |

## 2026-04-29 Restored Stereo Writer

The temporary experiment that replaced `slab:write-stereo` with direct fy pointer stores was reverted. It was slower because it traded one host word for two pointer-fetch binds plus fy-side address arithmetic.

### Debug

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.4993 | 0.4677 | 2.5124 | 1950.5 | 10.68 |
| live lush chord voice | `mono1-audio` | 0.5717 | 0.5338 | 1.6485 | 2233.1 | 9.33 |
| live arp pulse | `mono1-audio` | 0.5537 | 0.5116 | 8.9280 | 2162.9 | 9.63 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.6448 | 0.6046 | 3.0296 | 2518.8 | 8.27 |
| hq blep arp pulse | `mono1-audio-hq` | 0.6414 | 0.5853 | 23.7386 | 2505.7 | 8.31 |

### ReleaseFast

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.1942 | 0.1804 | 1.9180 | 758.4 | 27.47 |
| live lush chord voice | `mono1-audio` | 0.2080 | 0.1969 | 1.3206 | 812.7 | 25.63 |
| live arp pulse | `mono1-audio` | 0.2089 | 0.1973 | 1.8539 | 816.1 | 25.53 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.1697 | 0.1584 | 1.7148 | 662.9 | 31.43 |
| hq blep arp pulse | `mono1-audio-hq` | 0.1707 | 0.1595 | 1.0493 | 667.0 | 31.24 |

## Compiler Targets

- Safe first pass: remove adjacent fy data-stack round trips such as `.push x0; .pop x0` after compilation and before relocation resolution. This preserves hot-patch semantics because it does not inline user words or bypass trampolines.
- Riskier pass: inline small `noalloc:` user words. This needs an inline-site invalidation story, otherwise hot-patching a helper word will not update already-compiled callers.
- Algorithmic words likely worth adding after the peephole baseline: fused `fclamp01`, `fwrap01`, `flerp`, and a stereo-store word that accepts one sample and one frame index without extra fy-side pointer arithmetic.

## Notes

- Debug builds are the meaningful comparison for the current app if the user runs the default `zig build run`.
- ReleaseFast numbers show fy callback execution is not inherently hopeless; a large part of current pain is debug-mode host/runtime overhead plus poly/mix overhead.
- App callback numbers remain higher than this single-voice benchmark because the app pays poly fan-out, per-track render setup, mixing, logging, and any active effects.
- Max values include OS scheduling noise; use avg/min for optimization comparison unless max regressions become persistent.
