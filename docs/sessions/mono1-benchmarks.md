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

## 2026-04-29 fy Stack Round-Trip Peephole

Change in `../fy/src/main.zig`: after compiling a word, remove adjacent data-stack round trips such as `.push x0; .pop x0`, then remap BL relocation offsets. The first version also optimized branchy words and failed fy tests because already-patched local branch offsets became stale. The landed version skips words containing local branches, so it is correct but conservative.

fy validation: `zig build test --summary all` in `../fy` passed, 27/27 tests.

### Debug

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.4816 | 0.4462 | 3.6297 | 1881.2 | 11.07 |
| live lush chord voice | `mono1-audio` | 0.5971 | 0.5161 | 13.1802 | 2332.4 | 8.93 |
| live arp pulse | `mono1-audio` | 0.5354 | 0.4978 | 3.2878 | 2091.3 | 9.96 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.6489 | 0.5885 | 13.4163 | 2534.9 | 8.22 |
| hq blep arp pulse | `mono1-audio-hq` | 0.6089 | 0.5717 | 1.7530 | 2378.6 | 8.76 |

### ReleaseFast

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.1864 | 0.1753 | 0.9524 | 728.3 | 28.61 |
| live lush chord voice | `mono1-audio` | 0.2011 | 0.1895 | 0.8229 | 785.5 | 26.52 |
| live arp pulse | `mono1-audio` | 0.2055 | 0.1895 | 10.7475 | 802.8 | 25.95 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.1736 | 0.1519 | 6.9535 | 678.0 | 30.73 |
| hq blep arp pulse | `mono1-audio-hq` | 0.1642 | 0.1524 | 0.2827 | 641.2 | 32.49 |

Result: correctness is good, but perf impact is small. The next meaningful compiler step is branch-aware instruction removal or explicit `dsp:` inlining of selected `noalloc:` helpers.

## 2026-04-29 Conservative noalloc Inlining Attempt

Tried retaining body-only machine code for small `noalloc:` words and having callers inline that copy when the body contained no PC-relative `BL` calls. fy tests passed, but mono1 did not improve; ReleaseFast live cases regressed relative to the stack-round-trip peephole run. The active inliner was backed out.

### Debug

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.4931 | 0.4615 | 1.5123 | 1926.1 | 10.82 |
| live lush chord voice | `mono1-audio` | 0.5667 | 0.5332 | 1.5519 | 2213.8 | 9.41 |
| live arp pulse | `mono1-audio` | 0.5461 | 0.5145 | 1.2336 | 2133.2 | 9.77 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.6425 | 0.6017 | 3.9180 | 2509.8 | 8.30 |
| hq blep arp pulse | `mono1-audio-hq` | 0.6305 | 0.5824 | 15.3803 | 2462.9 | 8.46 |

### ReleaseFast

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.1935 | 0.1821 | 0.7215 | 755.8 | 27.57 |
| live lush chord voice | `mono1-audio` | 0.2116 | 0.1974 | 3.4996 | 826.4 | 25.21 |
| live arp pulse | `mono1-audio` | 0.2074 | 0.1964 | 0.9858 | 810.1 | 25.72 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.1704 | 0.1600 | 1.1887 | 665.5 | 31.30 |
| hq blep arp pulse | `mono1-audio-hq` | 0.1694 | 0.1595 | 0.7017 | 661.6 | 31.49 |

Takeaway: naive machine-code body inlining is not the right first win. It likely increases I-cache pressure and does not address the branch-heavy hot blocks. A real `dsp:` inliner should operate before branch lowering and should selectively fuse known arithmetic/load/store words rather than blindly copying helper bodies.

## 2026-04-29 Inline fy Scalar Float + f32 Cell Words

Hypothesis: mono1 is dominated by tiny float/memory words crossing from JIT code back into Zig helpers. This also explains why Zig Debug/Release changes fy-machine performance: `f+`, `f-`, `f*`, `f/`, `f<`, `f>`, `f=`, `fneg`, `f@32`, and `f!32` were JIT stack shuffles plus C-ABI calls into Zig.

Change in `../fy`: add scalar ARM64 encoders for `fadd`, `fsub`, `fmul`, `fdiv`, `fneg`, `fcmp`, and `cset`, then replace the hot float arithmetic/comparison and f32 cell load/store builtins with inline machine-code words. Semantics stay tagged-f64 on the fy stack and f32 in cells.

fy validation: `zig build test --summary all` in `../fy` passed, 27/27 tests. Added smoke coverage for inline float arithmetic, comparisons, negation, and `f!32`/`f@32`.

Slab validation: `zig build test --summary all` passed, 34/34 tests.

### Debug

Run command: `zig build bench-mono1 -- --warmup=512 --blocks=5000`

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.3063 | 0.2828 | 0.4733 | 1196.6 | 17.41 |
| live lush chord voice | `mono1-audio` | 0.3385 | 0.3058 | 3.8930 | 1322.1 | 15.76 |
| live arp pulse | `mono1-audio` | 0.3239 | 0.2981 | 1.5592 | 1265.1 | 16.47 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.3164 | 0.2799 | 3.0754 | 1235.9 | 16.86 |
| hq blep arp pulse | `mono1-audio-hq` | 0.2984 | 0.2760 | 1.5171 | 1165.5 | 17.87 |

### ReleaseFast

Run command: `zig build bench-mono1 -Doptimize=ReleaseFast -- --warmup=512 --blocks=5000`

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.2054 | 0.1842 | 4.8078 | 802.4 | 25.96 |
| live lush chord voice | `mono1-audio` | 0.2076 | 0.1985 | 1.1859 | 810.9 | 25.69 |
| live arp pulse | `mono1-audio` | 0.2083 | 0.1990 | 1.9655 | 813.6 | 25.61 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.1626 | 0.1540 | 0.5000 | 635.3 | 32.79 |
| hq blep arp pulse | `mono1-audio-hq` | 0.1629 | 0.1537 | 0.3579 | 636.4 | 32.74 |

Takeaway: this confirms the Debug pain was mostly helper-call overhead, not oscillator math. ReleaseFast is mixed on the live path because optimized Zig helpers were already cheap and the inline sequences are larger; HQ improves slightly. The next compiler opportunity is not broad user-word inlining, but reducing the inline scalar sequences themselves and fusing common DSP patterns so each math expression does not repeatedly untag/retag between adjacent float ops.

## 2026-04-29 Fused DSP Words Used In mono1

Added fy words for common scalar DSP shapes and rewrote mono1 to use them:

- `fmadd`: `(acc a b -- acc + a*b)` for mixer/modulation accumulation.
- `fma`: `(a b c -- a*b + c)` for scale+bias expressions such as bipolar phase.
- `fslew`: `(current target coeff -- current + (target-current)*coeff)` for envelopes and one-pole filter stages.
- `fclamp`, `fclamp01`: branchless scalar clamps using ARM64 `fmin/fmax`.
- `fwrap01`: phase wrap for values near one cycle.

mono1 changes: envelope tick, LFO pitch clamp, phase advance, saw/pulse scale+bias, pulse/sub edge wrap, limiter/softclip clamps, cutoff modulation, filter coefficient clamp, ladder one-pole stages, and oscillator mixer accumulation.

fy validation: `zig build test --summary all` in `../fy` passed, 27/27 tests.

Slab validation: `zig build test --summary all` passed, 34/34 tests.

### Debug

Run command: `zig build bench-mono1 -- --warmup=512 --blocks=5000`

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.2962 | 0.2701 | 1.8300 | 1157.0 | 18.01 |
| live lush chord voice | `mono1-audio` | 0.3160 | 0.2948 | 1.2241 | 1234.3 | 16.88 |
| live arp pulse | `mono1-audio` | 0.3106 | 0.2810 | 13.1197 | 1213.3 | 17.17 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.2729 | 0.2523 | 1.1413 | 1066.2 | 19.54 |
| hq blep arp pulse | `mono1-audio-hq` | 0.2700 | 0.2455 | 3.6525 | 1054.6 | 19.75 |

### ReleaseFast

Run command: `zig build bench-mono1 -Doptimize=ReleaseFast -- --warmup=1024 --blocks=20000`

| case | word | avg ms/block | min | max | ns/sample | ideal voices |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| live saw+sub | `mono1-audio` | 0.1818 | 0.1688 | 7.7746 | 710.0 | 29.34 |
| live lush chord voice | `mono1-audio` | 0.1927 | 0.1806 | 9.4604 | 752.7 | 27.68 |
| live arp pulse | `mono1-audio` | 0.1960 | 0.1803 | 4.7827 | 765.5 | 27.21 |
| hq blep lush chord voice | `mono1-audio-hq` | 0.1425 | 0.1333 | 1.4459 | 556.5 | 37.44 |
| hq blep arp pulse | `mono1-audio-hq` | 0.1447 | 0.1340 | 18.5248 | 565.3 | 36.85 |

Takeaway: source-level fused DSP words helped both Debug and ReleaseFast. The largest win is HQ BLEP because it contains more repeated phase/clamp/accumulate patterns. The max outliers are scheduler noise; avg/min moved in the right direction.

## Notes

- Debug builds are the meaningful comparison for the current app if the user runs the default `zig build run`; inline float/mem words materially improved that path.
- ReleaseFast numbers show fy callback execution is not inherently hopeless, but scalar stack-machine code still spends too much effort materializing each tiny operation independently.
- App callback numbers remain higher than this single-voice benchmark because the app pays poly fan-out, per-track render setup, mixing, logging, and any active effects.
- Max values include OS scheduling noise; use avg/min for optimization comparison unless max regressions become persistent.
