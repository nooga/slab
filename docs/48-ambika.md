# 48 — Ambika: Mutable Instruments' six-voice polysynth

`ambika` is a port of the Ambika's voicecard firmware: six voices, each two
digital oscillators, a mixer with cross-modulation, sub-oscillator or
transient, noise, fuzz and a sample-rate crusher, then an analog filter and
VCA, under three envelopes, four LFOs and a 14-slot modulation matrix.
**Status:** first milestone, 2026-11-02: the voice and the panel. The
sequencer, arpeggiator, multi and SD-card library are not ported: Slab has
its own (docs/45).

Code:
- `kernels/06-voices/ambika.fy`: the voice.
- `kernels/06-voices/ambika_tables.fy`: offsets into the table asset, generated.
- `machines/ambika/`: the panel; `assets/tables.wav` holds the firmware's tables.
- `tools/ambika/gen_tables.py`: packs the tables from a checkout of the firmware.

## Sources and license

The firmware is Émilie Gillet's, in
[pichenettes/ambika](https://github.com/pichenettes/ambika) (GPL-3.0-or-later,
like Slab; the hardware designs and documentation are CC-BY-SA 3.0), and the
manual is the
[Ambika archive manual](https://pichenettes.github.io/mutable-instruments-diy-archive/ambika/manual/).
The oscillators, mixer, envelopes, LFOs, modifiers and matrix are ported
from `voicecard/` and `common/`; the tables are the firmware's own, unscaled.
Marked below: **[F]** from the firmware, **[M]** from the manual, **[G]** our
guess.

## What the firmware does

| part | behavior | |
|---|---|---|
| clock | the voicecard renders at 20 MHz / 510 = 39.2 kHz, 8-bit samples, 16-bit phases (24 with a fraction); control at that rate / 40 = 980 Hz | [F] |
| pitch | 14 bits per note: 7 for the note, 7 for 1/128 semitone | [F] |
| OSC 1/2 | 38 shapes: saw, square, triangle, sine from band-limited tables blended by note; PARA waveshapes them. The CZ family (zsaw, LP/PK/BP/HP resonant saw and pulse, ztriangle); a quad saw pad; 2-op FM; 8-bit land; dirty PWM; filtered noise; vowel; 16 wavetables; the wavequence | [F][M] |
| band-limited PWM | the square with PARA > 0: two saws PARA apart, at half rate | [F] |
| mixer | MIX balance, XMOD: sum, sync, ring, xor, fold, bits, with AMNT; SUB (square, triangle, pulse, 1 or 2 octaves down) or a TRANSIENT (click, glitch, blow, metal, pop), never both; NOIS; FUZZ through a tanh table; CRSH holds the DAC for 1..64 ticks | [F] |
| DAC | 12 bits at the same rate; the filter takes its CV through PWM and RC | [F] |
| filter | SMR4 board: 4-pole low-pass only; SVF board: low-, band-, high-pass | [M] |
| envelopes | 3: attack, decay, sustain, release on a 128-step rate table, an exponential curve; ENV 2 is hardwired to the filter, ENV 3 is the VCA in the default patch | [F][M] |
| LFOs | LFO 1–3 are the part's, shared by the voices; LFO 4 is the voice's, with its own rate in the matrix. Triangle, square, S&H, ramp and 16 wavetables | [F] |
| matrix | 14 slots, SRC, DEST, AMT −63..63; the last slot's amount is scaled by the mod wheel; LFOs, bend and note are centered, the others unipolar; VCA is multiplicative, 63 meaning the whole source | [F] |
| modifiers | 4: add, product, attenuate, max, min, xor, ≥, ≤, quantize, lag | [F] |
| ranges | the mixer and filter resonance take 0..63 (they are shifted into 14 bits: 64 and up wraps); the rest 0..127 | [F] |

## What this port does

The digital half is the firmware's arithmetic in floating point with the
integer truncations kept: the same table reads, the same shifts, the 8-bit
values. It runs as a *native tick* at 39.2 kHz, scheduled by a fractional
accumulator inside the host's 48 kHz sample, and the DAC's value is held
between ticks, as the hardware's output stage does. So the aliasing and
imaging are the unit's.

Control runs once per `CTL-P` = 49 host samples (980 Hz). The filter, the
resonance and the VCA take their targets smoothed, as the PWM-and-RC stages
on the board do [G: 0.7 ms].

Faithfully kept quirks: the PARA of a wavetable scans the 80 waves of the
firmware's table; the vowel renders at half rate with the unshifted
increment, so it sounds an octave under the key; `sub-lvl` above 63 wraps in
the transient's gain.

### The filter

The SMR4 is an OTA cascade (an AS3320, as a Prophet-5's): `ota_cascade.fy`,
run at the host rate, one step per sample, with its coefficients worked out at the control rate and smoothed per sample. Its cutoff is linear in semitones, two CV steps
per semitone: `20 Hz × 2^(CV/24)`, which puts the default FREQ at 90 and the
key tracking at the top of the range [G: the firmware writes a CV, the
analog circuit's scale is not in the repository].

### Values

Parameters are the Ambika's raw numbers (0..127; the mixer and RESO 0..63),
so a patch reads as it does on the hardware. Matrix sources and
destinations are the firmware's, minus the sequencer and arpeggiator sources
(SEQ1, SEQ2, ARP), which Slab does not have: indexes here are the panel's
own, not the firmware's patch bytes.

| source | | source | |
|---|---|---|---|
| ENV1–3 | envelopes | VELO | note velocity |
| LFO1–3 | part LFOs | AFTR | pressure (note expression) |
| LFO4 | the voice LFO | BEND, MWHL, WHL2, PDAL | the PERFORM knobs |
| MOD1–4 | modifiers | NOTE, GATE, NOIS, RAND | note, gate, noise, a value per note |
| [256]…[4] | constants | | |

Destinations: PRM1, PRM2, OSC1, OSC2, ~1+2 (coarse, ±4 semitones), VIBR
(fine), MIX, XMOD, NOIS, SUB, FUZZ, CRSH, FREQ, RESO, ATTK, DECA, RELE, LFO4
(its rate), VCA.

## Panel and presets

Three pages: SOUND (oscillators, mixer, filter, envelopes), MOD (the dock, LFOs, the matrix display, modifiers) and PART. Long lists (shapes, sources, destinations) are display selects. `tools/ambika/factory_presets.py` writes 10 presets of ours, chord pads first. `tools/ambika/import_programs.py` imports the unit's golden card (358 programs, in bank folders A, B, F and S: `A/000-junon` and so on, so the preset menu shows four submenus). The CZ waves are unipolar, so the voice AC-couples the DAC ahead of the filter (5 Hz).

## Not yet

- The SVF board's modes: BOARD and MODE are on the panel and the SMR4 is
  all that sounds.
- LFO tempo sync and the LFO→ENV retrigger; part LFOs are free-running or
  RETRIG.
- Unison and the firmware's SPREAD.
- The golden card's 2 multis, and importing a patch file from a user's own card.
- Rings on the panel's knobs for matrix destinations other than PRM1 and PRM2.

## Note off

The host retires a released voice once its output is silent. A patch whose matrix does not put ENV 3 on the VCA would drone on the unit (its VCA stays at VOLUME) and so would here, forever, after a note off, a transport stop or a playhead move. So a released voice is muted once ENV 3 has run its release; patches that route ENV 3 to the VCA already end there.

## Cost

A held voice costs about 230 ns/sample at ReleaseFast (570 before the restructure), 300–330 with the vowel, PWM or wavetables. fy versions a word on its params-only `ifte` guards, one loop per path, up to 32 paths and then runs every arm; the first port had 14 stages and each oscillator ran all its shapes. Now each oscillator is four paths (CZ resonant waves, the small algorithms and the vowel, the band-limited PWM, and the table family, where one pair of reads serves the saw, square, triangle, sine, CZ saw, wavetables and wavequence), the sub/transient choice has two, so a word has at most 4 × 4 × 2 = 32. The mixer's cross-mod is a select, not five paths: every path is compiled up front, and five paths on top of the oscillators' sixteen made a Debug build spend 7 s compiling the machine (0.4 s now). The vowel's formants and the filter's coefficients are worked out at the control rate.
