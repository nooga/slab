# 35 — Live buffers, modal resonators and frequency shifting

Five native fy effects and one instrument extend Slab's audio manipulation palette. They
use the normal insert/send routing, presets and automation; no new project
format or plugin host is involved. Source changes take effect in newly
loaded instances, as with the existing machines.

| ID | Panel | Role |
|---|---|---|
| `buffer2` | Buffer Loom | Live stereo capture, granular scatter, reverse grains, repeat/stutter |
| `resonator2` | Modal Bank | Eight tuned, damped modes per channel, excited by incoming audio |
| `shift2` | Sideband | Signed frequency shifting in Hz, ring modulation, shifted feedback |
| `zitherfx` | Magnet Zither FX | Ten tuned strings driven by the input and by two spinning magnet discs |
| `zither` | Magnet Zither | The same strings as an instrument: plucked from the keys, droning under the discs |
| `echo2` | Tape Echo | A tape loop past four heads: multi-head echo, swell, sound on sound, freeze |

Exact parameter IDs, ranges, switch indices and preset descriptions are
generated in [20-machine-reference.md](20-machine-reference.md). A preset
stores switch **indices**, while slabkit accepts labels. All process true
stereo in one pass; the first three and the echo keep left/right audio history
independent, and the zither's strings are shared and panned.

## Buffer Loom

Put it after a foley kit, break, percussion bus or texture. The input is
recorded into two host-allocated rings. **FREEZE** stops writes and holds
the write head; it does not mute the dry input. Capture first, then freeze.
A new/reset instance frozen before capture is silent on its wet path.
Captured audio is live state: presets/projects do not store the rings, and
transport reset clears them.

**GRAINS** launches up to eight Hann-windowed grains. **SIZE MS** is each
grain's length, **DENSITY** launches per second, and **POS** chooses its
lookback within **SPAN** (0 is newest safe history, 1 is oldest).
**SPRAY** scatters that position; **PITCH** is semitones, **JITTER** is
per-grain pitch variation in semitones, and **REVERSE** changes reading
direction. **WIDTH** distributes grains in stereo without summing the
input channels. Grain position, speed, size, reverse and pan are latched
at launch; edits affect subsequent grains. Sounding grains finish.

With **SYNC**, **DIV** governs the launch interval instead of DENSITY.
SPAN remains the history window. The launch clock runs from reset;
SYNC sets its interval, rather than re-anchoring its phase to a locator.
Launch rate is capped at 32 Hz. Size
is capped by available history, reading speed and the eight-slot overlap
budget, so short captures and high pitches may produce shorter grains
than requested. Overlap gain is compensated. Arbitrary grain positions
can interfere on sustained tones; this is a texture processor, rather
than transparent monophonic pitch correction (audio clips offer VOICE).

**REPEAT** captures a recent window and loops it. Free SPAN determines
the window length; SYNC uses DIV. Each loop latches its window and reverse
direction at its boundary, with seam fades up to 2 ms. PITCH changes the
read speed and loop duration. FREEZE holds the recorded source, while
pitch/repeat/grain controls remain playable. Mode changes crossfade over
approximately 5 ms.

FB recirculates a bounded wet signal into capture; it has no effect on a
frozen ring. TONE filters incoming capture with a four-pole lowpass. The
capture cutoff also falls for upward pitch/jitter. Four-point Hermite
interpolation reads grains and loops. Changing pitch upwards after
freezing cannot refilter the stored recording, so bright frozen material
can alias at high rates; record with a lower TONE for that use.

The two rings reserve 4.1 seconds at the host's 96 kHz buffer allocation
rate (about 6.3 MB total). The accessible history window is at most four
seconds. Audio processing allocates nothing. A negative declared tail
keeps the machine processing through silence, retaining frozen captures
and preparing future live input.

Start with `steel-scrambler` for chopped industrial hits,
`pneumatic-repeat` for clocked stutter, or `capture-cloud` and then FREEZE
for a sustained texture. `reverse-grains` and `half-speed-loop` explore
different reading directions/rates.

## Magnet Zither

Ten steel strings in a tuning, eight modes each, heard through a pickup
and panned low to high across the stereo field. Where the Modal Bank is
one body at one pitch, this is a chord of strings: as an insert, the
strings that agree with the input answer it and the rest stay quiet.

**TUNING** picks the ten notes (OPEN D, MINOR, PENTA, 5THS, LYDIAN,
CLUSTER, and HARM: partials 2–11 of D1, just). **ROOT** transposes in
semitones. **RING** is the T60 of a 110 Hz string's fundamental; higher
strings and higher modes decay faster. **TONE** moves the pickup toward
the bridge and opens its lowpass. **COIL** is how hard the input (summed
to mono) drives all ten strings.

Each **DISC** is a spinning disc of magnets held over the strings. Its
pull is a train of narrow bumps at **SPIN** passes a second, so its
harmonics fall at multiples of SPIN: where one lands on a string's mode,
that string blooms, and sweeping SPIN walks the bloom through the tuning.
Set SPIN to a note's frequency (36.71 Hz is D1) to bring out the strings
related to it. Every pass pulls a little differently and the motor
wanders, so strings under the disc stay faintly alive between blooms.
**HEIGHT** is the distance (the pull falls with its square), **ACROSS**
which strings the disc sits over (0 low, 1 high), **ALONG** where on
their length (near 0 is at the bridge and reaches the upper modes).

A string that is ringing hard takes less from whatever drives it, so the
level follows roughly the cube root of the drive and nothing runs away at
resonance. With a disc ON the machine sounds from silence, so the host
never idles it. Automate SPIN, HEIGHT and ACROSS to play it. It costs
about 190 ns per sample.

There are two machines over the one kernel. **Magnet Zither FX**
(`zitherfx`) is the insert described above, with COIL and MIX. **Magnet
Zither** (`zither`) is an instrument, so a drone needs nothing in front
of it: the discs sound on an empty track before any note, and the keys
pluck the strings. A note plucks the string nearest its pitch, so every
key lands in the tuning; velocity is how hard. **PLUCK** moves the
plectrum from the bridge (bright, every mode) toward the middle (round),
and **DAMP** lays a finger on the string when the key is let go; with it
off the strings ring out at RING. Ten keys can pluck at once. The
strings live in the machine's shared region and the voices only pluck
(docs/04 §Shared state); `-1.0 tail!` keeps the shared word running with
no note held.

The idea of magnet discs over a zither comes from the "Stitches Desk"
web instrument; the DSP here is written for Slab.

## Tape Echo

`echo2` is a loop of tape past one record head and four playback heads,
after the drum and tape echoes of the 1960s and 70s. The loop is
**LENGTH** long at **SPEED** 1 (or **DIV** beats with **SYNC** on), and
the heads sit a quarter, a half, three quarters and the whole way round
it. **1–4** switch which heads are heard; **SPREAD** places them left,
right, half left and center.

**MODE** says what is recorded again. In ECHO it is head 4: the whole
loop comes round **REPEAT** quieter each pass, and the other heads are
taps inside it. In SWELL it is every head that is on, shared between
them, so the repeats fall between each other and smear into a wash, the
drum echo's stand-in for a reverb. A long LENGTH with REPEAT near 1 is
sound on sound: play over what is there while it slowly fades (use it
fully wet on a send). REPEAT goes past 1, where the loop howls, held by
the tape curve.

Everything recorded passes the tape: a coupling cap, **TONE**'s
12 dB/octave rolloff (it follows SPEED) and the tape curve (**DRIVE**),
so each repeat is duller and rounder than the last. The motor has mass:
LENGTH and SPEED reach the loop through a quarter-second lag, and the
sound on the tape bends in pitch until it settles. **WOW** and
**FLUTTER** move every head together, and since repeats are re-recorded
the wobble compounds. **HISS** is on the playback and, half as loud, on
what is recorded. **POPS** are specks on the tape, a few a second at
most, and the splice, which ticks once every pass. **WEAR** makes the
wow wander, adds dropouts and dulls each pass. Hiss and pops follow the
level in the machine and shut in silence, so an idle track still goes
quiet and the host can skip it.

**FREEZE** lifts the record and erase heads: the loop plays as it is,
the input does not reach it, and nothing is lost per pass. The heads
still read through the wow, and above WEAR 0 the tape sheds a little
every pass, so a held loop can be left to erode. Automate SPEED on a
frozen loop for half-speed and double-speed passes.

Start with `drum-echo`; `four-head-swell` is the wash, `sound-on-sound`
the long loop, `worn-loop` a tired transport, `howl` the feedback
instrument. It costs about 140 ns per sample with all heads on, and the
loop is 8.2 s of memory per channel.

## Modal Bank

Incoming audio excites eight parallel damped complex resonators.
**HZ** sets the fundamental. **STRING** uses harmonics 1–8; **PIPE** uses
odd harmonics 1–15; **PLATE** uses a stylized inharmonic series. These are
sound-design families, not measured models of a particular physical object.
**INHARM** stretches upper mode frequencies further.

**DECAY** is the fundamental's T60: seconds to decay by 60 dB in amplitude.
**DAMP** shortens higher modes' decay. Pole radius is derived from sample
rate and T60; **SPREAD** offsets left/right modal frequencies by a small
number of Hz while preserving pole radius. Modes above 0.45 of sample rate
are omitted. State is independent per channel; SPREAD detunes the modes
without cross-feeding audio. Set SPREAD to zero to retain a mono source.

EXCITE is input drive in dB into a bounded tanh excitation. Modal peak
gains and weights are normalized before summing, so long decays ring
without an uncontrolled resonance gain. Consequently an isolated impulse
can be quiet on the wet path. Noise bursts, rattles, brushed metal and
longer foley excite it more strongly; use LEVEL or a return gain to bring
up a fully wet part. LEVEL affects both dry and wet. An 18-second declared
tail protects the maximum 12-second decay from idle skipping.

`steel-body` and `short-iron` suit percussion. `harmonic-string` makes
tuned harmonic ringing; `pipe-chamber` introduces odd modes;
`drone-body` uses long low resonances.

## Sideband

In **SHIFT** mode, HZ adds the same frequency offset to each partial.
Positive values shift upwards; negative values shift downwards. A 1 kHz
tone at +250 Hz becomes 1.25 kHz, without the equally strong 750 Hz
sideband of ring modulation. This changes harmonic relationships, unlike
pitch transposition. Frequencies crossing zero reflect when represented
as real audio.

An IIR quadrature pair creates the single-sideband signal. Its rejection
is approximate, particularly near DC and Nyquist. It also has
frequency-dependent phase; a 0 Hz fully wet shift is not a phase-neutral
bypass. MIX at zero and LEVEL at 0 dB pass the original samples exactly.
SPREAD offsets the two channels' carrier frequencies symmetrically around
HZ, retaining independent input signals.

**RING** mode multiplies input by a sinusoidal carrier, retaining both
sum and difference sidebands. FB sends bounded wet audio back into the
processor. A DC blocker and four-pole lowpass control that loop; TONE also
limits bandwidth before shifting. The lowpass cutoff automatically leaves
space below Nyquist for the largest carrier offset. Oscillator phase
persists between blocks and is normalized at block boundaries.

Use `slow-sidebands` for slow movement, `warped-steel` for inharmonic
foley, `ring-machine` for two-sided modulation, or the spiral/smear presets
for shifted feedback. Output level applies after the dry/wet blend.

The quadrature topology and pole values follow
[Olli Niemitalo's allpass-pair design](https://yehar.com/blog/?p=368).
The general frequency-shifting method is described in
[Miller Puckette's single-sideband modulation chapter](https://msp.ucsd.edu/techniques/v0.06/book-html/node148.html).
The fy recurrence and machine implementation are authored in this repo.

## Audition and verification

Generate a short comparison project and render it with the native engine:

```sh
zig build -Doptimize=ReleaseFast
PYTHONPATH=tools python3 tools/demo_industrial_machines.py --render
zig-out/bin/slab scratch/industrial-machines/demo.slab
```

The five four-bar sections use the same foley phrase: dry, buffer,
resonator, shifter, then a combined chain. All sources are collected into
the scratch package. The CC0 factory foley was generated with Stable
Audio, as identified in its factory preset notes; it is not field audio.
Fixed output trims bring the sections to roughly similar loudness. The
demo is a patch audition, not a mastered song or a blind instrument
fidelity comparison.

Adapter tests check signed sideband suppression at 44.1/48/96 kHz, ring
sidebands, exact dry bypass, modal pitch and T60, independent channels,
freeze retention, reset/ring reinjection, granular octave transposition,
block partition invariance, preset loading, declared tails, and bounded
output under dense/jittered feedback settings. The normal headless bench
also supplies impulse, sine, sweep, ladder and burst reports:

```sh
zig build test
zig build bench -Doptimize=ReleaseFast -- machines/buffer2 machines/resonator2 machines/shift2 --no-sheets
```

Measurements establish numerical behavior and cost; they do not replace
auditioning the presets and automation in a mix.
