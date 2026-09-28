# 24 — Compressors: survey, bus2, multi2, character

Which compressors Slab should have beyond `comp2`, how the classic
designs make their sound, and how each new machine gets measured.
**Status:** (0) prerequisites and (2) the comp2 revision are built
(§comp2 as built); bus2, multi2 and the character modes are open. The
survey's numbers marked *measured* are the old comp2 and come from
`zig build bench` on comp2 (Debug, 2026-09-28) and from a numpy mirror
of `comp.fy` (a scratch script, not in the repo) that matches the bench to 0.1 dB where they overlap
(sine THD −53.0 dB default, −51.5 dB `dry-drum-punch`, −64.2 dB the
drum-bus recipe below).

Code this touches, as it lands: `kernels/07-effects/comp.fy`, new
`kernels/07-effects/{dyn,xover}.fy`, `machines/{comp2,bus2,multi2}/`,
`kernels/00-primitives/ctx.fy` + `src/machines/fy_raw_machine.zig`
(Io ABI), `src/bench/cases.zig` + `src/bench_main.zig` (new cases).

## comp2 today (what we build on)

| aspect | comp2 / `comp.fy` |
|---|---|
| topology | feed-forward |
| lanes | dual-mono: host runs the kernel once per channel against per-channel state; both lanes read the same `io.det`, so gains are identical |
| detector | host-computed `det = max(|L|,|R|)` (or of the key pair when keyed), already rectified |
| smoothing | smooth branching one-pole on the **linear level, before** the gain computer: `e = d + (e − d)·c`, `c = atk` when rising |
| time constants | `decay-exp-coeff`: `c = exp(−ln 1000 / (t·sr))`, i.e. the knob is a **T60 time** (to 99.9 %), τ = t / 6.91, 10–90 % ≈ 0.32 t. Clamped to t ≥ 0.5 ms, so ATK 0.2–0.5 ms (the bottom 15 % of the knob) does nothing |
| gain computer | log2 domain, quadratic soft knee (Giannoulis eq. 4), slope `1/R − 1` |
| output | `x·g·makeup·mix + x·(1 − mix)` |
| meter | `gr-db` state cell |
| cost | ≈ 95 ns/sample Debug, both lanes |

Measured behaviour worth knowing:

- **Static curve sits ~0.7 dB soft of theory at 200 Hz** (bench `ladder`,
  thresh −16, ratio 4, knee 6: GR 2.3 / 6.8 / 11.3 dB at −12 / −6 / 0 dBFS
  against 3.0 / 7.5 / 12.0 theory). The peak follower sags between
  half-cycles, so it reads below the peak.
- **That sag distorts bass.** 0.5-amplitude sine through the default
  settings (rel 0.12 → τ 17 ms):

  | setting | 50 Hz THD | 100 Hz | 1 kHz | GR ripple @ 50 Hz |
  |---|---|---|---|---|
  | default | −27.7 dB | −33.2 | −53.0 | 1.2 dB |
  | `dry-drum-punch` (rel 0.09) | −26.1 | −31.7 | −51.5 | 1.5 dB |
  | `bass-leveler` (rel 0.18) | −29.9 | −35.5 | −55.4 | 0.9 dB |
  | drum-bus recipe (rel 0.4) | −38.3 | −44.3 | −64.3 | 0.35 dB |

  4 % THD on a 50 Hz kick fundamental is audible grit. It is also the
  reason a peak compressor "sounds fast": the T60 labelling makes every
  REL value 6.9× shorter as a time constant than it reads.
- **No sidechain filter is possible yet.** `det` arrives rectified, and
  a high-pass after `|·|` is meaningless. The key's signed audio exists
  on the host (`ctx.audio_in` ports 2–3) but is not in `Io`.
- **REL tops out at 1.5 s T60 = τ 217 ms.** SSL/670-style slow release
  (τ 0.6–1.2 s) is out of reach.

## Survey

### The designs

| unit | gain element | topology | detector | ratio / knee | attack | release | where the colour comes from |
|---|---|---|---|---|---|---|---|
| **SSL G / 4000 bus** | VCA (dbx 202 / THAT 2180) | **feedback-like**: sidechain VCA replica driven by the same CV, rectified *after* it [Gyraf] | full-wave, peak-ish | 2, 4, 10; knee soft by rectifier/CV curve | 0.1, 0.3, 1, 3, 10, 30 ms | 0.1, 0.3, 0.6, 1.2 s, AUTO (two RC branches, 91k·6.8µ ≈ 0.62 s and 750k·0.47µ ≈ 0.35 s: short on peaks, slow under sustained GR) | clean VCA; the sound is the time constants + FB loop; later units (500 G-Comp, THE BUS+) add a sidechain HPF |
| **UREI 1176** | FET as variable resistor | feedback | peak | 4, 8, 12, 20; all-buttons ≈ 12–20 with rebiased, much higher THD | 20–800 µs | 50 ms–1.1 s | FET and transformer distortion, odd-leaning, rises with GR; all-buttons "British mode" |
| **LA-2A** | T4 electro-optical cell (EL panel + LDR) | feedback | opto: the panel's light is a thermal/chemical integrator — RMS-like, frequency-dependent | ~3:1 COMPRESS / ~∞ LIMIT; very soft, program dependent | ≈ 10 ms average | two stage: ≈ 60 ms to 50 %, then 1–15 s for the rest, longer after long, heavy GR | tube makeup stage; the release memory is the character |
| **Fairchild 660/670** | vari-mu (remote-cutoff 6386 tubes) | feedback | peak | not a knob: ratio rises with level → knee tens of dB wide | 0.2–0.4 ms | 6 settings 0.3–25 s; positions 5–6 auto (0.2–0.3 s single peaks, 10 s multiple, 25 s sustained) | tube gain stage, THD rises with GR, even-leaning; push-pull cancels some of it |
| **API 2500** | VCA | switch: NEW = feed-forward, OLD = feedback | RMS; THRUST filter in front of it | 1.5–∞; knee HARD / MED / SOFT | 0.03–30 ms | 0.05–2 s + variable | THRUST: MED = +3 dB/oct tilt below ~200 Hz and above ~3 kHz, flat between; LOUD = +3 dB/oct across the band (inverse pink) [SOS] — the detector hears equal energy per octave, so kick and bass stop running the comp |
| **Distressor** | (proprietary, VCA-class) | — | selectable: normal, HP-filtered detector, "opto" 10:1 mode with its own release | 1, 2, 3, 4, 6, 10 (opto), 20, Nuke (brick wall) | ~0.05–30 ms | ~0.05–3.5 s (opto mode longer) | DIST 2 (mostly 2nd harmonic when compressing) and DIST 3 (2nd + 3rd, tape-like flattening); 1:1 ratio = colour with no compression; HPF in audio and detector paths |
| **Neve 33609** | diode bridge | feedback | peak | ~1.5–6 compressor + separate limiter | fast / slow | ~0.1–1.5 s + AUTO (unverified, from manuals) | diode bridge + transformers; compressor and limiter as two stages in series |
| **Multiband (C4, Pro-MB, OTT)** | per band | FF | per band | per band | per band | per band | band split. OTT = Ableton Multiband Dynamics preset: splits 88.3 Hz / 2.5 kHz, downward ≈ 66:1 low+mid and ∞:1 high, **upward 4.17:1** on all bands, +5.2 dB in, soft knee |

### The DSP decisions, per Giannoulis/Massberg/Reiss 2012

The tutorial [G12] reduces every design above to four choices. Slab's
choices go in the last column.

| choice | options | consequence | Slab |
|---|---|---|---|
| **where smoothing sits** | (a) on the level before the gain computer (comp2 today); (b) on the gain in dB after the gain computer | (a) makes attack/release depend on how far over threshold you are, and the ripple of a linear follower becomes gain modulation; (b) gives times that don't depend on level and a smooth release | new kernels: (b) |
| **peak detector form** | branching (`atk` rising / `rel` falling); decoupled (instant-attack release stage then an attack smoother) | decoupled: attack effectively lengthens with release; branching keeps them independent. The "smooth" forms (`(1−α)` input term on both branches) avoid the discontinuity of the textbook peak hold | smooth branching, log domain |
| **peak vs RMS** | `|x|`, or one-pole mean of `x²` over 5–50 ms | RMS: much less LF ripple (and THD), slower, level-like; peak: catches transients | switch (`PEAK` / `RMS`) where cheap |
| **feed-forward vs feedback** | FF: detector on input; FB: detector on output (`y[n−1]`) | FB cannot look ahead, cannot reach ∞:1, and its static curve is not the gain computer's: with GR slope S, `y − T = (x − T)/(1 + S)`, so **R_eff = 1 + S** (S = 1 − 1/R gives at most 2:1). A digital FB mode must set S = R − 1 to honour the ratio label. FB is self-regulating, so its release is program-dependent for free | switch; FB via the SSL replica trick (below) |

Gain computer (both new machines keep `comp.fy`'s form), level `x` in
dB, threshold T, ratio R, knee width W:

```
y = x                                   2(x − T) < −W
y = x + (1/R − 1)(x − T + W/2)² / 2W    |2(x − T)| ≤ W
y = T + (x − T)/R                       2(x − T) > W
```

Log-domain smooth branching detector on the gain reduction
`g = x − y ≥ 0`, α = exp(−1/(τ·sr)):

```
s[n] = αA·s[n−1] + (1 − αA)·g[n]     g[n] > s[n−1]
s[n] = αR·s[n−1] + (1 − αR)·g[n]     otherwise
gain = 10^(−s/20)
```

**Feedback without a stereo pass.** The SSL sidechain VCA is a replica
of the audio VCA driven by the same control voltage, so the detector
sees `det · gain[n−1]`. That is available in dual-mono lanes: both
lanes carry the same `det` and the same gain history, so
`d = det · g_prev` keeps them linked. A true output-sensing FB would need
both lanes' outputs, which dual-mono lanes can't share.

**Program-dependent release (AUTO).** Two gain-domain followers in
parallel, output the larger:

```
fast: atk τA,        rel τF  (≈ 0.1–0.15 s)
slow: atk τS_atk (≈ 0.3–0.5 s, charges only under sustained GR), rel τS (≈ 1–1.5 s)
s = max(fast, slow)
```

Single hits release on τF; a held chorus charges the slow branch and
releases over a second. The 670 positions 5–6, the SSL AUTO and the
LA-2A's second stage are all versions of this. An opto flavour weights
the two branches (`0.5·fast + 0.5·slow`) instead of `max`, which gives
the LA-2A's "50 % in 60 ms, the rest over seconds".

**Where saturation sits.** FET, vari-mu and opto units all colour after
the gain element (makeup/transformer stages), and in FET and vari-mu
the THD **rises with gain reduction**. Cheapest convincing model:
the existing `shapers.fy` curve after the gain, input scaled by
`drive · (1 + k·GR_dB/10)`, 4× oversampled with the existing
`up4`/`dec4` (sat2's path). Without oversampling, a hard drive on a
drum bus aliases; the bench `NONHARM` ratchet catches it.

**Stereo link.** Linked = one detector from `max(|L|,|R|)` (bus use,
image stable); unlinked = per-channel detectors (M/S, wider but the
image shifts). A LINK % needs both channels in one pass (`stereo`
manifest flag).

### Character knobs ranked by mileage per line of fy

Line counts are estimates for `dsp:` fy against the existing kernels.

| knob | what it buys | cost | lines | notes |
|---|---|---|---|---|
| **SC HPF** (60–250 Hz, 12 dB/oct) | stops kick/bass pumping the bus; the single most-used bus comp control | 1 biquad per detector channel | ~15 (reuse `eq-coef-hpf`) | needs signed detector audio (ABI change below) |
| **program-dependent release** | glue without pumping on single hits, recovery after sections | 1 extra follower | ~10 | the SSL AUTO / 670 / LA-2A trick |
| **log-domain gain smoothing** | level-independent timing, 50 Hz THD −28 → below −40 dB | none (moves code) | ~10 | changes comp2 goldens |
| **parallel MIX** | NY compression | done | 0 | comp2 has it |
| **knee** | glue vs grab | done | 0 | |
| **FF / FB switch** | FB = softer, self-regulating, "old" | 1 multiply + ratio remap | ~6 | SSL replica form |
| **PEAK / RMS** | RMS = smoother, less LF THD | 1 one-pole on x², sqrt via exp2/log2 | ~8 | |
| **THRUST tilt** (API) | kick-proof detector, mids/highs drive GR | 2 shelves or 1st-order tilt | ~20 | a richer SC HPF; later |
| **GR-coupled drive** | FET/tube colour that grows with squash | shaper + 4× OS ≈ sat2 cost | ~25 | the only knob that costs real CPU |
| **stereo link %** | width vs stability | needs `stereo` flag, 2 detectors | ~10 | bus2/multi2 are stereo anyway |
| **upward compression** (OTT) | lifts low-level detail; the "OTT sound" | second gain-computer branch below a lower threshold | ~12 | multi2 follow-up |

## Proposal

Order: **(0) Io key audio + bench cases → (1) bus2 → (2) comp2 revision
→ (3) multi2 → (4) character modes.** bus2 first because it is the
machine every mix in `songs/` wants (drum bus, mix bus) and it
exercises every new primitive except the crossover.

### comp2 as built (2026-09-28)

What landed, and where it differs from the plan below:

- `Io` carries `sc-l`/`sc-r`; `det` is unchanged, so every other
  effect stays bit-exact. comp2 is now true stereo (`stereo`).
- Detector: `max |hp L| |hp R|`, then a **5 ms peak hold** (instant up)
  before the log gain computer. Without it a peak detector dips to zero
  every half-cycle and the gain chases a moving target: attack measured
  6.2 ms for a 3 ms knob. With it: attack τ 3.3 ms, release τ 102 ms
  for 3 / 100 ms knobs, the static curve within 0.1 dB of theory.
- RMS: `sqrt(2·mean x²)`, τ 10 ms, so a sine reads its peak in both
  modes and THRESH means the same.
- SC HPF: 12 dB/oct TPT SVF, 20 Hz = off.
- Measured on the default settings (bench): 50 Hz THD −27.7 → −41.9 dB
  (PEAK), −57.2 dB (RMS). HPF 150 Hz halves the kick's GR on the
  `drums` loop (6.0 → 2.9 dB) and leaves the snare's.
- The presets were then redesigned from their names (§Presets).

### Presets

Designed from intent, not from the old comp2 (which, measured on real
material, mostly worked against its names: 20 ms releases made the
levelers and glues raise crest and push transients up to 8 dB). Each
preset's character is fixed by its job; THRESH is solved on the songs'
own material (the signal each comp2 there hears, `tools/comp2_presets`)
for a GR target, MAKEUP for level. Measured with the bench's `file` case,
averaged over the material:

| preset | job | character | target | measured |
|---|---|---|---|---|
| `bass-leveler` | even out a bass line | 4:1, knee 6, 3 / 250 ms, PEAK | 3.5 dB median GR | spread −11 %, crest +0.8, pump 0.7 |
| `vocal-leveler` | ride a lead | 3:1, knee 10, 2 / 150 ms, HPF 80 | 3.5 dB median | spread −25 %, crest −0.4 |
| `dialog-leveler` | flatten talk | 6:1, knee 8, 2 / 150 ms, HPF 100 | 5.5 dB median | spread −33 %, crest −0.5 |
| `smooth-pad-comp` | calm pads / keys | 2:1, knee 12, 25 / 300 ms, RMS, HPF 60 | 2 dB median | pump 0.7, crest flat |
| `dry-drum-punch` | snap on a drum track | 4:1, knee 4, 10 / 60 ms | 5 dB on hits | transients +2.7 dB |
| `drum-smash` | parallel smash | 10:1, 0.3 / 30 ms, mix 0.5 | 18 dB wet on hits | body +2.6 dB, spread 4.8 → 2.8, +0.9 dB |
| `rude-clap` | clap/snare tail up | 8:1, 0.1 / 20 ms, mix 0.9 | 16 dB wet on hits | body +2.7 dB, spread 6.6 → 2.7 |
| `pump` | fast bus squash | 4:1, 3 / 120 ms | 7 dB p90 | pump 2.3 dB (audible) |
| `audible-pump` | dance breathing | 8:1, 8 / 220 ms | 9.5 dB p90 | pump 2.8 dB |
| `bus-glue` | mix bus, SSL-ish | 2:1, knee 6, 10 / 150 ms, HPF 90 | 2.5 dB p90 | pump 0.9, crest +0.2 |
| `gentle-bus-glue` | lighter mix bus | 2:1, knee 9, 30 / 200 ms, HPF 90 | 1.8 dB p90 | pump 0.6 |
| `gentle-glue` | barely there | 1.5:1, knee 12, 30 / 300 ms, RMS, HPF 60 | 1 dB p90 | pump 0.4 |
| `soft-master-glue` | master control | 2:1, knee 12, 20 / 300 ms, RMS, HPF 60 | 2 dB p90 | pump 0.7 |
| `drum-bus` | glue a kit | 4:1, knee 4, 10 / 150 ms, HPF 90 | 6 dB on hits | spread −15 %, transients +1, pump 1.4 |

(pump = std of the GR; spread = std of 100 ms levels; transients = the
loudest 1 ms in the first 15 ms over the 40–120 ms body.) Levelers push
note onsets up 1–2 dB: the attack lag any compressor without lookahead
has. THRESH is set for these songs' levels; on a hotter or quieter
source, trim it: Glass Horizon's quiet kit runs `drum-bus` at −22 dB,
measured in the song at 5.7 dB on hits, 1.1 dB median, level range −20 %.

### (0) Prerequisites

**Io carries signed detector audio.** Add two fields to `Io`
(`ctx.fy`) and `IoFrame` (`fy_raw_machine.zig`):

| field | value |
|---|---|
| `sc-l`, `sc-r` | key pair when keyed, else the input pair, signed |

`det` stays as-is (comp2/gate2/limiter2 unchanged, bit for bit). The
layout test in `fy_raw_machine.zig` and the `Io.det` offset table
update. ~10 lines Zig. This is what makes SC HPF, THRUST, RMS on a key,
and multi2's per-band keyed detection possible.

**Bench cases** (`src/bench/cases.zig`), effect suite, all at 48 kHz.
Gain is measured as `y/x` over 1 ms windows with MIX = 1 (the
compressor is a memoryless multiply), so no machine-specific meter
reading is needed:

| case | stimulus | reports |
|---|---|---|
| `curve` | 1 kHz sine, −48 → 0 dBFS in 2 dB steps, 0.3 s each | in/out/GR table + max deviation from the ideal curve for the machine's T/R/W |
| `step` | 1 kHz: 0.5 s at T − 10 dB, 0.5 s at T + 10 dB, 1 s at T − 10 dB | attack τ63 and 10–90 %, release τ63 and 10–90 %, overshoot |
| `bursts` | 1 kHz at T + 10: 50 ms burst, then a 2 s block, each followed by 2 s at T − 10 | release after each (AUTO must differ by > 3×) |
| `lowsine` | 50 Hz and 100 Hz at −6 dBFS, 2 s each | THD, GR ripple (ratchet, as `sine`) |
| `key` | input 1 kHz steady −20 dBFS; key = 50 ms 60 Hz / 3 kHz bursts at −6 | GR on each burst (SC HPF check); needs `audio_in_count = 4` in `bench_main.zig` |
| `link` | L = 1 kHz bursts at −6, R = 1 kHz steady at −30 | R's GR during L bursts (linked: equal to L's; unlinked: 0) |
| `drums` | synthetic 110 bpm kit loop (sine-sweep kick, noise+tone snare, hat), deterministic, peak −6 dBFS | crest, PLR, BS.1770 LUFS, GR per hit, GR at +1 ms, mean GR, transient-to-body ratio (0–4 ms peak vs 20–80 ms RMS) in and out |

The existing `burst` case reports nothing useful for a compressor
("level at burst end −300 dB"); `step`/`bursts` replace it for dynamics.

### (1) bus2 — SSL-style glue compressor

`stereo` machine, `sidechain`. Stepped like the hardware: fewer
choices, all of them useful.

| param | label | range | default | notes |
|---|---|---|---|---|
| `bus-thresh` | THRESH | −30 … 0 dB | −12 | linear |
| `bus-ratio` | RATIO | 2 / 4 / 10 | 4 | switch |
| `bus-atk` | ATK | 0.1 / 0.3 / 1 / 3 / 10 / 30 ms | 10 | switch; value = τ (63 %) |
| `bus-rel` | REL | 0.1 / 0.3 / 0.6 / 1.2 s / AUTO | AUTO | switch; value = τ; AUTO = fast 0.1 s ‖ slow (charge 0.4 s, release 1.2 s) |
| `bus-hpf` | SC HPF | OFF / 60 / 90 / 150 / 250 Hz | OFF | switch; 12 dB/oct Butterworth on `sc-l/sc-r` |
| `bus-topo` | TOPO | FB / FF | FB | switch; FB = replica (`det·g[n−1]`), S = R − 1 |
| `bus-makeup` | MAKEUP | 0 … 15 dB | 0 | linear |
| `bus-mix` | MIX | 0 … 1 | 1 | pow |

Knee is fixed at 4 dB (the hardware has none as a control; 4 dB is a
starting point to tune against a reference unit's `curve` sweep).
Meter: needle-style GR from a `gr-db` cell.

```
sc-l, sc-r ─► SC HPF ─► |·| ─► max ─► [FB: × g[n−1]] ─► log2 ─► gain computer (T, S, W=4)
                                                                   │ GR dB
                                                          smooth branching follower
                                                          (atk τ; rel τ or AUTO fast‖slow)
                                                                   │ exp2
in-l, in-r ────────────────────────────────────────────────► × g ─► × makeup ─► mix ─► out-l, out-r
```

Reuse: `comp-knee` as is; `eq-coef-hpf` (factored out of `eq.fy` into
a shared `biquad.fy`); `log2`/`exp2`/`db>lin`; the `pick5`-style
selector from `saturator.fy` for the stepped switches. New:
`dyn.fy` — `dyn-follow` (log-domain smooth branching, τ convention
`exp(−1/(τ·sr))`), `dyn-auto` (fast ‖ slow), `dyn-rms`. Estimated
~120 lines kernel + ~40 manifest; cost ≈ 1.5× comp2 (one pass, two
biquads, one log2/exp2 per sample instead of two).

### (2) comp2 revision

comp2 stays the clean, continuous utility compressor. Changes:

| change | why |
|---|---|
| detector → `dyn-follow` in log domain after the gain computer | 50 Hz THD, level-independent times |
| ATK/REL become τ (63 %) times; ATK 0.1 … 100 ms, REL 10 ms … 2 s | readable, matches bus2 and the hardware tables; no dead zone |
| new `comp-hpf` SC HPF knob, 20 (off) … 500 Hz, exp | ducking and bus use |
| new `comp-det` PEAK / RMS switch | bass and vocals |

This changes every comp2 render: re-record goldens after review, and
re-derive all 13 presets (times ÷ 6.9 for τ; check each preset's
GR on its intended source with `drums`/`lowsine`). Pre-1.0, so no
compatibility shim.

### (3) multi2 — 3-band glue / OTT

`stereo` machine, `sidechain`. Lean: per-band threshold, ratio and
gain; shared timing scaled per band; optional upward branch later.

| param | label | range | default | notes |
|---|---|---|---|---|
| `mb-xlo` | LO X | 40 … 400 Hz | 120 | exp |
| `mb-xhi` | HI X | 1 … 8 kHz | 2500 | exp |
| `mb-lo-thresh` / `-mid-` / `-hi-` | THRESH | −48 … 0 dB | −20 | per band |
| `mb-lo-ratio` / … | RATIO | 1 … 20 | 3 | pow; 1 = band bypassed dynamically |
| `mb-lo-gain` / … | GAIN | −12 … 12 dB | 0 | per band, post-comp |
| `mb-atk` | ATK | 0.5 … 100 ms | 10 | τ; low band ×2, high ×0.5 |
| `mb-rel` | REL | 20 ms … 2 s | 150 | τ; same scaling |
| `mb-mix` | MIX | 0 … 1 | 1 | pow |

14 controls; panel in three band strips + one global strip.

```
x ─► LR4 @ xlo ─┬─ LP ─────────► AP2 @ xhi ─► comp(lo) ─┐
                └─ HP ─► LR4 @ xhi ─┬─ LP ──► comp(mid) ─┼─► Σ ─► mix ─► out
                                    └─ HP ──► comp(hi)  ─┘
```

- LR4 = two cascaded Butterworth biquads (Q = 1/√2), LP and HP.
  LP + HP of an LR4 is a 2nd-order allpass with Butterworth poles, so
  the low band gets that allpass at `xhi` (AP2, Q = 1/√2) to match the
  phase the mid/high branch picked up. Without it the sum dips near
  `xhi` when the crossovers are within ~2 octaves.
- Per band: linked detector `max(|L|,|R|)` of the band signal (or the
  key through the same split), `dyn-follow`, `comp-knee`.
- 9 biquads per channel + 3 detectors ≈ 3–4× comp2.
- Follow-up: `mb-up` upward depth (second gain computer below
  `thresh − 20 dB` with slope `1 − 1/R_up`, capped at +12 dB) — the
  OTT half that downward-only multiband lacks.

New: `xover.fy` (`lr4-split`, `ap2`), coefficients per block from
the shared biquad words. ~150 lines kernel + ~60 manifest.

### (4) Character modes (after bus2 and multi2)

One `comp2` switch or a separate `char2`; decide when bus2 exists. Each
mode is a bundle of the knobs above, not a circuit model:

| mode | topology | detector | knee / ratio | times | colour |
|---|---|---|---|---|---|
| CLEAN | FF | peak | as set | as set | none |
| FET (1176) | FB replica | peak | as set; ALL = ratio 16 + knee 0 + drive ×2 | atk 0.02–0.8 ms range | tape-curve shaper, drive ∝ GR, 4× OS |
| OPTO (LA-2A) | FB replica | RMS 10 ms | knee 12, ratio 3 | atk 10 ms fixed; release 0.5·fast(60 ms) + 0.5·slow(1–5 s, slower after long GR) | TUBE shaper, light |
| VARI (670) | FB replica | peak | knee 24, ratio 2 → rises with level | 670 table incl. auto positions | TUBE shaper, drive ∝ GR |

Optical and vari-mu research models (Eichas & Zölzer on the LA-2A
optocoupler; recent state-space and neural models) exist, but the
bundle above is what fy can do inside the current per-sample budget.

## Test plan

Every machine: `zig build bench -- machines/<m> --no-sheets`, the
existing suite plus the new dynamics cases. Tolerances below are the
acceptance bar; failures block the machine.

| check | case | bus2 | comp2 rev | multi2 |
|---|---|---|---|---|
| static curve | `curve` | within ±0.3 dB of the ideal curve above threshold for R = 2/4/10 (FB and FF); FB R labels hold | within ±0.3 dB for 3 knee widths | per band with the other two at ratio 1 |
| attack / release | `step` | τ63 within ±15 % of the switch value for every ATK/REL position | within ±15 % across the knob; independent of step size (±10 vs ±20 dB step within 10 %) | per band, scaling ×2 / ×0.5 visible |
| program-dependent release | `bursts` | AUTO: release after 2 s block ≥ 3× release after 50 ms burst | — | — |
| LF distortion | `lowsine` | 50 Hz THD < −40 dB at 6 dB GR, REL ≥ 0.1 s | < −40 dB at defaults (today −27.7) | < −40 dB |
| colour | `sine` at 3 levels | clean: THD < −60 dB | clean | with drive (mode 4): harmonic signature — 2nd > 3rd for TUBE, 3rd > 2nd for tape/FET — and NONHARM < −70 dB (aliasing) |
| SC HPF | `key` | HPF 150: GR on 60 Hz burst ≥ 10 dB less than on 3 kHz burst; OFF: within 1 dB | same with `comp-hpf` 150 | per band: 60 Hz key only moves the low band |
| stereo link | `link` | R GR = L GR within 0.1 dB | same (host-linked) | per band |
| crossover null | `sweep`, `impulse` | — | — | all ratios 1: magnitude flat ±0.1 dB 20 Hz–20 kHz |
| drum loop | `drums` | defaults: 2–4 dB GR on kick/snare, GR at +1 ms < 1 dB (ATK 10) | recipe below | defaults: < 3 dB GR per band on the loop |
| stability | all | no NaN/denormal counts; `--all --check` of other machines unchanged | goldens re-recorded once, reviewed | — |
| cost | all | ≤ 2× comp2 ns/sample ReleaseFast | ≤ 1.2× today | ≤ 5× comp2 |

Song-level check (slabkit): render a song with the machine on the drum
bus, `render(stems=True)`, and compare the bus stem's `crest_db`,
`plr`, `lufs` against the same song with the effect removed
(`analyze.py` prints all three). Goldens: `--record` only after the
report and sheets have been read; `NONHARM WORSE` is never waved
through.

## Drum bus preset for comp2 (today)

A preset for the current seven parameters that behaves like an SSL on
drums: 4:1, slow enough attack that the stick gets through, release
long enough to stay out of the way. Proposed file
`machines/comp2/presets/drum-bus.preset`, note "SSL-style drum bus
glue: 4:1, transients through" (not created here).

| param | value | as a time constant | why |
|---|---|---|---|
| `comp-thresh` | −16 | — | ≈ bus peak − 10 dB; move with the bus level |
| `comp-ratio` | 4 | — | the SSL middle position |
| `comp-knee` | 6 | — | the default; firm enough to grab the hits |
| `comp-atk` | 0.03 | τ 4.3 ms, 10–90 % ≈ 9.5 ms | the SSL 3–10 ms region: first ~5 ms of each hit untouched |
| `comp-rel` | 0.4 | τ 58 ms, 10–90 % ≈ 130 ms | recovers inside an 8th at 110 bpm (270 ms); 50 Hz THD −38 dB instead of −28 |
| `comp-makeup` | 3 | — | about the loudness it takes away on hits |
| `comp-mix` | 1 | — | parallel is `drum-smash`'s job |

Measured with a numpy mirror of `comp.fy` on a VCSL acoustic kit loop
(kick on 1, 3, 3+; snare 2, 4; 8th hats; 110 bpm; peak −6 dBFS),
alongside the existing presets:

| preset | GR kick | GR snare | GR @ +1 ms | mean GR | crest Δ | LUFS Δ | transient/body Δ kick, snare |
|---|---|---|---|---|---|---|---|
| **drum-bus** | 3.9 dB | 2.8 dB | 0.0 | 0.4 dB | +0.3 dB | +1.0 | +3.1, +2.1 dB |
| `dry-drum-punch` | 8.2 | 7.6 | 0.0 | 0.8 | −1.3 | +0.3 | +5.0, +4.8 |
| `bus-glue` | 3.5 | 3.1 | 0.0 | 0.4 | −0.7 | +0.8 | +2.6, +2.4 |
| `drum-smash` (mix 0.45) | 20.1 | 19.3 | 3.2 | 4.1 | −1.6 | −1.8 | +1.5, +7.2 |

Bench (`-p` overrides, 200 Hz `ladder`): −12 → −11.3, −6 → −9.8,
0 → −8.3 dBFS out (GR 2.3 / 6.8 / 11.3 dB); 1 kHz `sine` THD −64.2 dB.

**Targets** for the preset on a real drum bus (peak −8 … −4 dBFS):

- 2–4 dB GR on kick and snare hits, < 1 dB mean GR.
- GR at 1 ms after a hit < 0.5 dB (transients through).
- crest factor within ±1 dB of the dry bus, transient-to-body **up**
  2–4 dB. A feed-forward peak comp with a slow attack adds punch, it
  does not reduce crest; on the loop above none of the slow-attack
  settings lowered crest by more than 1.3 dB. For density, run
  `drum-smash` in parallel (mix 0.3–0.5, crest −1.6 dB), or wait for
  bus2's FB + AUTO.
- LUFS +0.5 … +1.5 dB at matched fader.
- 50 Hz THD below −35 dB (`lowsine` when it exists; today via the
  numpy mirror).

**Verify** (read-only, nothing recorded):

```sh
zig build bench -- machines/comp2 --no-sheets --out=/tmp/b \
  -p comp-thresh=-16 -p comp-ratio=4 -p comp-knee=6 \
  -p comp-atk=0.03 -p comp-rel=0.4 -p comp-makeup=3 -p comp-mix=1
# expect ladder GR 2.3/6.8/11.3 dB at -12/-6/0, sine THD -64.2 dB
```

then on a song: put `fx("comp2", "drum-bus")` (or the params inline)
on the drum track or a `song.bus("DRUMS", …)`, `render(stems=True)`,
and compare the drum stem's crest, PLR and LUFS against a render
without it. Adjust THRESH so the targets hold at that bus's level;
the times and ratio should not need to move.

Limits of the recipe: REL 0.4 is τ 58 ms, far shorter than an SSL
"0.3 s" if that is a τ; comp2 can't go past τ 217 ms, and there is no
SC HPF, so a loud kick drives all the GR on busy material. Both are
bus2's reason to exist.

## Risks and open questions

- **fy/NEON.** Everything above is scalar per-sample code in the
  existing idiom; no NEON is needed to hit budget (bus2 ~1.5×, multi2
  ~3–4× comp2, ~100 ns/sample Debug today). Stereo machines process L
  and R in one pass, a natural 2× f64 NEON pair later.
- **Aliasing.** Any drive/colour stage must go through `up4`/`dec4`;
  gain modulation itself is band-limited enough at τ ≥ 0.1 ms, but a
  20 µs FET attack is not — the FET mode's fastest attack should be
  checked with `sine` NONHARM before shipping.
- **log2/exp2 accuracy** in `math.fy` sets the static-curve error; the
  ±0.3 dB bar assumes it is < 0.05 dB.
- **SSL time constants.** Hardware labels are nominal; treating them as
  τ is a choice. If a reference (e.g. the Diff-SSL-G-COMP dataset
  [Gu25]) says otherwise, change the mapping, not the switch labels.
- **Io ABI change** touches every effect's frame size; the layout test
  catches mismatches, but every machine's goldens must still pass
  `--check` unchanged afterwards.
- **multi2 panel width**: 14 knobs at the catalogue sizes may need two
  rows; don't shrink controls (docs/06).

## Sources

- [G12] D. Giannoulis, M. Massberg, J. D. Reiss, "Digital Dynamic Range
  Compressor Design — A Tutorial and Analysis", *JAES* 60(6):399–408,
  2012. <https://secure.aes.org/forum/pubs/journal/?ID=174>
- SSL G-series times and ratios: Sound On Sound, "SSL XLogic G-series
  Compressor", <https://www.soundonsound.com/reviews/ssl-xlogic-g-series-compressor>;
  SSL G-Comp 500 (sidechain HPF), <https://vintageking.com/ssl-g-comp-500-series-stereo-bus-compressor-module>
- [Gyraf] SSL mixbus compressor clone (sidechain VCA, AUTO RCs),
  <https://www.gyraf.dk/gy_pd/ssl/ssl.htm>
- API 2500 THRUST/knee/type: Sound On Sound, "What does an API 2500
  compressor's Thrust control do?",
  <https://www.soundonsound.com/sound-advice/q-what-does-api-2500-compressors-thrust-control-do>;
  UA API 2500 manual, <https://help.uaudio.com/hc/en-us/articles/4419505673620-API-2500-Bus-Compressor-Manual>
- 1176: UA manual, <https://help.uaudio.com/hc/en-us/articles/34530260482324-1176-Classic-FET-Compressor-Manual>;
  "All Buttons In", *JARP*, <https://www.arpjournal.com/asarpwp/all-buttons-in-an-investigation-into-the-use-of-the-1176-fet-compressor-in-popular-music-production/>
- LA-2A: UA manual, <https://media.uaudio.com/assetlibrary/l/a/la-2a_manual.pdf>;
  F. Eichas, U. Zölzer, "Modeling of an optocoupler-based audio dynamic
  range control circuit", 2016,
  <https://www.hsu-hh.de/ant/wp-content/uploads/sites/699/2017/10/Eichas-Modeling-of-an-optocoupler-based-audio-dynamic-range-control-circuit-99480W.pdf>
- Fairchild 670 time constants: UA Fairchild manual,
  <https://help.uaudio.com/hc/en-us/articles/13293388042900-Fairchild-Tube-Limiter-Collection-Manual>;
  Sound On Sound, <https://www.soundonsound.com/reviews/fairchild-660-670>
- Distressor: Empirical Labs manual, <https://www.empiricallabs.com/wp-content/uploads/distressor_manual.pdf>
- OTT settings: Faust `co.xfer_ott` PR, <https://github.com/grame-cncm/faustlibraries/pull/257>;
  <https://www.edmprod.com/ott-plugin/>
- LR crossovers and allpass compensation: ESP project 09,
  <https://sound-au.com/project09.htm>; KVR "N-band Linkwitz-Riley
  crossovers", <https://www.kvraudio.com/forum/viewtopic.php?t=479651>;
  MathWorks multiband DRC, <https://www.mathworks.com/help/audio/ug/multiband-dynamic-range-compression.html>
- [Gu25] Y. Gu et al., "Solid State Bus-Comp: A Large-Scale and Diverse
  Dataset for Dynamic Range Compressor Virtual Analog Modeling", 2025,
  <https://arxiv.org/abs/2504.04589>
