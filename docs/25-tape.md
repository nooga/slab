# 25 — Tape: tape2, cassette and VHS audio

`tape2` is a stereo insert that sounds like a cassette deck (types I,
II and IV) or a VCR's audio (the linear track or Hi-Fi), new or worn
out. It started from the char2 SMUSH work (docs/24 §SMUSH): wow,
flutter and lo-fi suit tape just as well. Those stages became shared
kernels, and tape2 adds the rest of a transport. **Status:** built
2026-10-02 on branch `tape2`.

Code: `kernels/07-effects/tape.fy` (the machine's DSP),
`machines/tape2/`, and the kernels below.

## Research

These are the numbers the design leans on. A Sonnet research pass
(2026-10-02) gathered them; [C] means confirmed in a source, [I] means
inferred or general knowledge.

| what | number | source |
|---|---|---|
| cassette response | 24 Hz–10 kHz ±3 dB, SNR −61 dB [C, Goodhertz Wow Control's cassette mode]. Type I ≈ 40 Hz–12 kHz, II/IV to 15–16 kHz [I] | manuals.goodhertz.com/3.13/wow-ctrl |
| playback EQ | 120 µs (type I, ≈1.3 kHz corner), 70 µs (II/IV, ≈2.3 kHz) [I] | — |
| head bump | +1…3 dB, Q 1–2, 60–100 Hz [I] | — |
| wow and flutter | good cassette deck 0.08 % weighted [C]; worn or portable 0.3–1 % [I]; wow < 4 Hz, flutter 4–20 Hz | Wikipedia, Wow and flutter measurement |
| hiss | type I ≈ −50…−60 dB, type II ≈ −60…−65 dB unweighted [I] | — |
| Dolby B | up to 10 dB of HF boost above ≈400 Hz on quiet passages; replaying at the wrong level mistracks, and a low replay level sounds dull [C] | SOS, Tape noise reduction |
| dropouts | 3–20 dB, 1–50 ms, more HF than LF loss, Poisson at 0.1–5/s [I] | — |
| VHS linear | mono, ≈100 Hz–8/10 kHz at SP, 3–4 kHz at EP, SNR 40–45 dB, heavy wow [I]; poor, especially EP [C] | repairfaq.org VCR FAQ |
| VHS Hi-Fi | AFM carriers ≈1.3/1.7 MHz in the video tracks, 20 Hz–20 kHz, < 0.5 % THD; a companding NR that can't be switched off; head-switching buzz, worse with worn heads [C] | tapeheads.net, repairfaq.org |
| hysteresis | Chow Tape: Jiles-Atherton with RK4; low bias widens the loop and leaves a dead zone at low level [C] | github.com/jatinchowdhury18/AnalogTapeModel |
| age macros | RC-20's Magnitude scales every module together; SketchCassette II has AGE and 12 tape profiles [C] | XLN manual, aberrantdsp.com |

## Signal chain

```
in ─► DRIVE ─► record EQ (high shelf +) ─► [2× hysteresis] ─► playback EQ (−)
   ─► transport: wow · flutter · drift · azimuth skew ─► dropouts
   ─► + hiss (×(1 + burst·dropout)) + hum + head-switch buzz
   ─► head bump ─► tape bandwidth (12 dB/oct) ─► coupling cap
   ─► NR mistrack ─► [VHS linear: mono] ─► OUT, MIX
```

The record EQ pushes the highs into the curve and the playback EQ takes
them back out. This is sat2 TAPE's trick: a hot cymbal compresses
before a kick does. Hiss goes in before the band limit, so the tape
shapes it.

## Shared kernels

| kernel | does | users |
|---|---|---|
| `02-shapers/hysteresis.fy` | algebraic soft shoulder; a loop opened by the direction of motion, zero at rest, widest mid-curve, closed at saturation; a crossover dead zone at low BIAS; a magnetization offset for even harmonics | tape2 |
| `04-filters/tone.fy` | TPT one-pole, shelves whose cut and boost cancel exactly, Simper bell (moved out of `saturator.fy`, sat2 bit-exact) | sat2, tape2, compand |
| `07-effects/wow.fy` | Hermite read on one modulated head: wow + flutter sines (depth 1 = 2.5 % / 0.4 %), FLUTTER extra (1.2 % at 1), RND (noise through two one-poles, normalized to unit deviation: drift at the wow rate, jitter at the flutter rate), SKEW (right channel later: azimuth) | char2, tape2 |
| `07-effects/dropout.fy` | Poisson events, 3–80 ms raised-cosine dips to −26 dB with a gap low-pass 16 k → 1.2 k; returns the dip for the owner | tape2 |
| `00-primitives/rand.fy` | the Numerical Recipes LCG mod 2³² kept as a fraction, `f' = frac(1664525·f + 1013904223/2³²)`: exact in f64, period 2³², three native ops | every noise source: lofi, wow, dropout, tape hiss, drums, juno, profit5, cream, ms20, rhodes, analog drift |
| `07-effects/hum.fy` | 50/60 Hz: 0.7 sin + 0.6 (\|sin\| − 2/π), transformer plus rectifier buzz; head-switch spikes at 50 / 59.94 per second, audio-modulated; gated | tape2 |
| `07-effects/compand.fy` | NR out of alignment: the band above SPLIT followed (2 / 80 ms), AMT dB per dB under REF on it | tape2 |
| `07-effects/lofi.fy` | hold, bits, crunch, coupling cap, band limit, gated hiss; tape2 borrows its SVF low-pass, cap and noise | char2, tape2 |

Three lessons from the build:
- With a gentle direction term, `tanh(k·Δu)` grows with frequency, so
  the loop turned into a treble boost: Hi-Fi measured +1.8 dB at
  10 kHz. With k = 400 the term is nearly the sign of the motion and
  the response is flat.
- A fixed-width loop is a square wave in quadrature: −23.6 dB THD at
  −6 dBFS. Scaling the width by level (2.6·a·(1 − a²)) and keeping
  HYST-W at 0.06 brought type I to 1.8 %.
- The float hash `frac(x·1103515245 + c)` used for noise across the
  repo falls into a cycle of 3,143 values and never comes within 4.8e−4
  of 0. The consequences:
  - Hiss repeated every 65 ms.
  - Dropouts (p ≈ 8e−5 per sample) never fired.
  - Every voice of a poly synth played the same noise.
  - Because a 65 ms cycle has nothing below about 15 Hz, the analog
    drift (analog.fy: that noise low-passed at 0.15–0.35 Hz) was
    almost silent in profit5, juno, cream and ms20. With `rand.fy` it
    runs as designed: about 2.4 cents RMS at AGE 0.4. FM presets need a
    low AGE now (`poly-mod-bell` 0.3 → 0.05, nonharm −37 → −54 dB).

  A first Park–Miller version (floor plus two correcting selects)
  turned ms20 to crackle: inlined into its large voice word, the few
  extra ops hit fy's frame-corruption limit. The fractional LCG is
  three ops and doesn't.

## Controls

| param | range | default | does |
|---|---|---|---|
| `tape-mode` | CASS I / II / IV / VHS LIN / VHS HIFI | CASS I | the format (below) |
| `tape-wear` | 0…1 | 0.2 | everything a tired transport does, at once |
| `tape-nr` | OFF / ON | OFF | Dolby B (Hi-Fi's compander is always on) |
| `tape-drive` | −12…18 dB | 0 | into the curve; 0 dBFS sits 6 dB over its knee |
| `tape-bias` | 0…1 | 0.6 | low: wide loop and dead zone (grit); high: clean, duller |
| `tape-wow`, `tape-flutter` | 0…1 | 0.25 | 0.25 is the format's own, then on to 2.5 % wow and 1.2 % extra flutter at 1 (seasick); 0 is a perfect transport |
| `tape-drops` | 0…1 | 0 | dropouts, on top of WEAR's |
| `tape-hiss` | 0…1 | 0.5 | 0.5 is the format's own, ±12 dB across the knob, 0 off |
| `tape-hum` | 0…1 | 0 | −80 → −40 dB |
| `tape-mains` | 50 / 60 | 50 | hum, and the VHS field rate with it (PAL 50, NTSC 59.94) |
| `tape-out`, `tape-mix` | ±12 dB, 0…1 | 0, 1 | output; MIX below 1 combs against the transport's delay |

Formats:

| MODE | band | emphasis | hiss | sens | bump | wow / flutter | other |
|---|---|---|---|---|---|---|---|
| CASS I | 12 kHz | 1.3 k +6 dB | −52 | +3 dB | 80 Hz +2 | 0.5 % / 0.3 % | |
| CASS II | 15 kHz | 2.3 k +6 | −57 | 0 | 80 Hz +2 | 0.4 % / 0.24 % | |
| CASS IV | 17 kHz | 2.3 k +5 | −60 | −4 | 70 Hz +1.5 | 0.3 % / 0.2 % | |
| VHS LIN | 8 kHz | 1.3 k +4 | −44 | +2 | 100 Hz +1 | 1.6 % / 1.0 % | mono, cap 60 Hz, buzz |
| VHS HIFI | 20 kHz | — | −78 | −6 | — | 0.1 % / 0.05 % | no loop (FM), compander always, buzz, dropouts burst into hiss (×30) |

WEAR 0 → 1:
- band ×0.4 (Hi-Fi ×0.75), and BIAS takes up to 15 % more;
- hiss +10 dB, bump +1.5 dB;
- wow +0.4 %, flutter +0.25 %, randomness 0.2 → 1;
- dropouts at 6·(DROPS + 0.6·WEAR)² per second;
- azimuth skew up to 1.5 samples (cassette);
- head magnetization 0.02 → 0.14 (2nd harmonic);
- coupling cap ×4 (not Hi-Fi);
- NR mistrack −0.05 → −0.4 dB per dB (Dolby B), −0.03 → −0.23 (Hi-Fi);
- buzz −68 → −46 dB (VHS).

Hiss, hum and buzz are gated by a 0.7 s follower of the input. A 2 s
gate kept the machine awake for about 14 s after the music stopped.

## Measured

Debug bench, 1 kHz at −6 dBFS, transport and hiss off, unless noted.

| setting | THD | H2 / H3 |
|---|---|---|
| CASS I | −35.1 dB (1.8 %) | −46.5 / −35.5 |
| CASS II / IV | −39.1 / −38.7 | |
| VHS LIN | −36.6 | |
| VHS HIFI | −54.1 (0.2 %) | |
| BIAS 0 / 0.3 / 1 | −24.9 / −31.3 / −35.0 | |
| DRIVE +6 / +12 | −25.6 / −18.5 (gain −2.1 / −5.2 dB) | |
| WEAR 1 (all on) | −29.4 | H2 −30.2 > H3 −37.4: the magnetized head |

- NONHARM is −70.3 dB, the stimulus floor, so the 2× hysteresis doesn't
  alias. With the transport on, wow's FM sidebands count as nonharmonic
  (−23 dB at WEAR 0.8).
- The sweep at −12 dBFS, against 1 kHz:
  - CASS I at WEAR 0.2: +2 dB at 100 Hz, −4.6 dB at 10 kHz, −17 dB at 16 kHz.
  - CASS I at WEAR 0.8: −11.6 dB at 10 kHz.
  - VHS HIFI at WEAR 0.5: flat to −0.7 dB at 10 kHz.
- Cost, ReleaseFast:
  - 185 ns/sample at defaults;
  - 242 ns with every stage on;
  - 262 ns with `--no-branches`.

## Presets

Format and wear are fixed by intent (`tools/comp2_presets/design_tape2.py`);
OUT is solved for level-neutral output on each preset's material.

| preset | intent | material | measured |
|---|---|---|---|
| `chrome-glue` | fresh type II, Dolby B, mix glue | mixes | crest 14.0 → 13.0, OUT −0.2 |
| `four-track` | type I demo, pushed, a little worn | drums | crest 15.7 → 13.6 |
| `metal-hot` | type IV +12 dB on drums | drums | crest 15.7 → 13.9, t/b 11.6 → 10.5 |
| `walkman` | tired belt: wobble, hiss, Dolby mistrack | pads | OUT +0.7 |
| `chewed` | WEAR 1, dropouts, hum | pads | OUT +1.9, gain p01 −14 dB (the dropouts) |
| `vhs-rental` | mono linear, dull, hum and buzz | mixes | OUT +3.5 |
| `vhs-hifi-dub` | Hi-Fi, the compander breathing | mixes | OUT +0.2 |

## Open

- A VU meter display; the TAPE strip has room for it.
- Print-through (pre-echo one turn early), crosstalk, and a
  speed-drift / "tape stop" control.
- A Dolby encode half, so NR ON on a matched deck is transparent rather
  than only a decoder error.
