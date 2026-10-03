# 21 — Writing and mixing a song in Slab

A working guide for composing in Slab, by hand or with Claude driving
`tools/slabkit`. It covers finding references, song form, harmony,
melody, groove, choosing sounds, channel setup, compression, space, the
master chain, and how to read the render report. Where general
production advice meets a Slab limit (no sends, the master
soft-clip), the Slab way is spelled out.

File format: [19-project-format.md](19-project-format.md). Params and
presets: [20-machine-reference.md](20-machine-reference.md). Worked
example: `songs/paper_boulevard.py`.

## 1. The loop

1. **Brief.** Name a reference (artist, track, era), tempo, key, mood
   and length. "Something like Johnny Hates Jazz" is enough to start.
2. **Research the reference** (§2): tempo, key, form, palette, groove,
   signature production moves.
3. **Sketch an 8-bar loop** containing the chorus progression, the
   groove and the bass, with one sound per role. Render it. If the
   loop doesn't feel good, a full arrangement won't either.
4. **Lay out the form** as sections, then fill clips section by section.
5. **Mix by numbers** (§8): render with stems, fix the balance until
   each stem sits in its target band, then set the master.
6. **Listen and note.** Numbers catch balance and loudness. Taste,
   groove and whether the hook lands need ears. Write feedback in plain
   words ("snare too roomy", "chorus doesn't lift") and map it to
   changes (§9).

```sh
zig build
PYTHONPATH=tools python3 songs/paper_boulevard.py --render --stems
zig-out/bin/slab songs/paper_boulevard.slab     # open it and listen
```

## 2. Researching a reference

Before writing a note, collect the following facts about two or three
reference tracks:

| What | Where to look |
|---|---|
| tempo, key | songbpm.com, tunebat.com, musicstax.com |
| chords, common progressions | Hooktheory TheoryTab (progressions by song, with roman numerals), Ultimate Guitar chord sheets |
| form (bar map) | count it from the recording; write intro 8 / verse 16 / … |
| instruments and gear | Wikipedia (personnel, producer, studio), Sound On Sound "Classic Tracks", producer interviews, Gearspace threads, Vintage Synth Explorer |
| signature sounds | Reverb Machine patch recreations, Attack Magazine "recreate" articles, YouTube breakdowns ("how X got the sound on Y") |
| the scene around it | who else sounded like this (for sophisti-pop: Curiosity Killed the Cat, Living in a Box, Go West, Hue and Cry, Swing Out Sister, The Blue Nile, Danny Wilson) |

Distil it into a one-paragraph brief with tempo range, key and mode,
chord vocabulary, groove, palette, production signature and form.
Example for Johnny Hates Jazz, late 80s:

> 100–110 BPM, major keys. Maj7, m7 and sus4 chords; IV–V–iii–vi
> chorus movement; borrowed ♭VI/♭VII in the bridge; a whole-tone key
> change for the last chorus. Straight 16th hats with a light swing.
> LinnDrum-style kick and a big gated snare into a bright plate. DX7
> electric piano comping on the offbeats, Juno/Oberheim string pad,
> synth brass stabs, fretless or synth bass with octave pops, a clean
> tenor vocal carrying long lines. Glossy, spacious, never distorted.

**Take the style, not the song.** Chord vocabulary, grooves, palette,
form and production moves are the genre. Melodies and lyrics belong to
the song. Write new melodies (§5) and don't transcribe hooks.

## 3. Form

A song is a sequence of **sections**. Each one does a job, and each
changes the arrangement so the ear stays interested. Phrases are 4 or
8 bars. Something should change at least every 8 bars.

| Section | Job | Typical length | Arrangement move |
|---|---|---|---|
| intro | set the palette, often preview the hook | 4–8 | half the band, or the hook over pads; drums enter with a fill |
| verse | tell the story, low energy | 8–16 | drums, bass, one comping part, sparse lead |
| pre-chorus | build tension | 4–8 | new chords (often starting on ii or IV), rising melody, a snare build or brass pickup in the last bar |
| chorus | the payoff | 8–16 | everything: pad, stabs, ear candy, busier kick, open hats, highest melody |
| verse 2 | same as verse, plus one new element | 8–16 | add a countermelody or pad the first verse didn't have |
| bridge / middle 8 | contrast | 8 | new harmony (borrowed chords, a different key centre), half-time drums, drop parts |
| last chorus | the biggest | 8–16 | key change up a tone or semitone, extra layer, double chorus |
| outro | let go | 4–16 | repeat the chorus hook while parts drop out and velocities fade; or end on a held chord |

Pop forms that work:

- `intro 8 · V 8 · pre 4 · C 8 · V 8 · pre 4 · C 8 · bridge 8 · C 8 (+2) · outro 8`
  (the Paper Boulevard form, 2:47 at 106 BPM)
- `intro 8 · V 16 · C 16 · V 16 · C 16 · break 8 · C 16 · C 16 · outro 8`
  (dance/italo: longer sections, breakdown instead of bridge)
- `A 8 · A 8 · B 8 · A 8` (a short instrumental or loop piece)

Length check: `bars × 4 × 60 / bpm` seconds. 72 bars at 106 BPM is
2:43.

**Energy map.** Before writing, rank each section's energy from 1 to 5.
In the render report, section loudness should roughly follow it: verse
about 1–2 LU below the chorus, bridge lower, last chorus highest. If
every section reads the same (the report flags spreads under 2 LU),
parts aren't entering and leaving.

**Automate the long moves, arrange the rest.** Track automation
([22-automation.md](22-automation.md)) rides faders, filters and effect
sends: `track.ramp("cutoff", verse.start, chorus.start, 400, 3000,
tension=-0.4)` opens a filter into the chorus, `track.automate("volume",
…)` rides a fader, `track.automate("fx1:mix", …)` swells a reverb. A
slow-start curve (negative tension) sounds more natural on a filter
open than a straight line. Automation can't yet follow a clip or bend
single notes, so contour also comes from:
- parts entering and leaving section by section (the main tool);
- clip velocities: `clip.velocities(fn)` for fades and swells; drum2
  and most synths respond to velocity;
- a second track with the same instrument set differently, e.g. a
  brighter chorus pad on its own track that only has chorus clips;
- register: the chorus melody sits a third to a fifth higher than the
  verse.

## 4. Harmony

Pick the progression vocabulary from the genre, then voice-lead it.
slabkit's `clip.chords()` does the voice leading: each chord takes the
inversion nearest the previous one.

| Genre | Progressions (roman numerals, major unless noted) |
|---|---|
| sophisti-pop / AOR | `Imaj7 vi7 IVmaj7 V7sus4 V7`; chorus `IVmaj7 V iii7 vi7 ii7 V Imaj7`; bridge borrowing `♭VImaj7 ♭VII` |
| synthwave | minor: `i VI III VII`, `i VI VII`, `i iv VI V` |
| italo / disco | minor: `i VII VI VII`, `i iv VII III`; lots of octave-bass on the root |
| 80s funk / boogie | `ii7 V7` vamps, `Imaj7 IV9`, dominant 9ths, a static one-chord groove with a chord-stab riff |
| city pop | `IVmaj7 III7 vi7 v7 I7` (secondary dominants), `ii7 V7 Imaj7 VI7` |
| ambient | `Imaj7 IVmaj7` or `i ♭VI` pedal, slow changes (2–4 bars per chord) |

Rules of thumb:
- **Color follows genre.** Maj7, m7, add9 and sus4 sound sophisticated
  and 80s. Plain triads sound rock or synthwave. Dominant 9ths sound
  funk.
- **Put a sus4 before a V7** (`A7sus4:2 A7:2`) to lean into a
  turnaround.
- **Borrow for the bridge.** ♭VI and ♭VII from the parallel minor give
  instant contrast in a major key.
- **Key change** for the last chorus: up 2 semitones, prepared by the V
  of the new key or just slammed in on the downbeat. In slabkit,
  `clip.transpose(2)` on every pitched clip of that section.
- **Harmonic rhythm.** One chord per bar is the default. Two per bar in
  turnarounds. Two to four bars per chord for pads, ambient and
  breakdowns.

Registers, so parts don't fight:

| Part | Range | slabkit |
|---|---|---|
| bass | E1–C3 | `bass(..., octave=2)` (roots around C2) |
| pad | voicings centred around C4, spread | `chords(near=60, spread=True)` |
| keys comping | centred around E4 | `chords(near=64)` |
| stabs / brass | around G4 | `chords(near=67)` |
| lead / vocal line | A3–A5, chorus higher than verse | `melody(...)` |
| bells / arp | C5–C7 | `arp(octave=5)` |

## 5. Melody

- **Motif first.** Write a one-bar rhythmic idea, then repeat it with
  the pitches changed to fit each chord. Four bars can be A A′ A B:
  statement, varied repeat, repeat, answer.
- **Leave space.** Start phrases after the downbeat (`r:.5`) and end
  them with a rest. A lead that never stops is exhausting.
- **Land on chord tones** on strong beats (root, 3rd, 5th, and the
  maj7 for color). Put passing notes on the offbeats.
- **Contour**: the verse is lower and stepwise; the pre-chorus rises;
  the chorus holds the highest note of the song, usually on beat 1 of
  bar 1 or 5.
- **Call and response**: fill the lead's rests with a brass stab or
  a vibes phrase.
- **Mono synths glide** only between notes that overlap. slabkit's
  `melody()` uses a 0.95 gate. Add `~` to a note to tie it into the
  next one for a slide.

## 6. Groove

Step strings, 16 steps per 4/4 bar: `X` accent, `x` hit, `o` ghost,
`.` rest, `-` tie. drum2 lanes are kick, snare, clap, ch, oh, tom.

| Feel | Kick | Snare / clap | Hats |
|---|---|---|---|
| four on the floor (disco, italo, house) | `x...x...x...x...` | `....x.......x...` | offbeat oh `..x...x...x...x.` + ch 16ths |
| 80s pop | `x.....x...x.....` | `....x.......x...` | `xoxoxoxoxoxoxoxo`, swing 0.54 |
| pop chorus, busier | `x.....x.x.....x.` | `....x..o....x...` | 16ths + oh on the last 8th |
| half-time (bridge, breakdown) | `x.........x.....` | `........x.......` | 8ths |
| funk | `x..x..x...x..x..` | `....x..o.o..x..o` | 16ths with accents `Xoxo` |
| synthwave | `x.......x.......` | `....x.......x...` | 8ths, gated reverb on the snare |

- **Swing**: 0.5 is straight. 0.54–0.58 on 16th hats adds bounce
  (`clip.swing(0.55)`). 0.66 is a full triplet shuffle.
- **Humanize** a little: time about 0.003–0.006 beats (2–3 ms), velocity
  ±5–8. Big numbers sound sloppy, not human.
- **Put a fill in the last bar** of every section going somewhere new:
  snare 16ths rising in velocity, toms, or a kick drop.
- **Ghost notes** (`o`) on the snare and velocity accents on the hats
  make a groove live more than any sound choice does.
- **Split drums over two drum2 tracks** when the hats need their own
  processing, or when 16th hats would blow the 2048-note budget. Paper
  Boulevard has `KIT` (kick/snare/tom through a plate) and `HATS`
  (high-passed, small room).

## 7. Choosing instruments

Fill roles, not track slots. A full pop arrangement is about six
roles. Machines are named by id (what projects and slabkit use); the
panel shows their display names: `drum2` DS-404 Drums, `cream` Mog
Passenger, `ms20` SM-24 Mono, `juno2` Ju-Know, `profit5` Profit-5 (a Prophet-5 with an Oberheim filter switch), `fm86` FM-7.11 (a DX7: its
parameters are the DX7's own, 0..99, and .syx voices import byte for byte
into your library, never the repository; factory presets are Slab's own,
e.g. `slab/glass-lead`),
`rhodes` Rhodes E-Piano, `sampler` Sampler, `concoction` Concoction (a
clean digital wavetable synth after Serum: fixed oscillator phase, a
built-in table bank or any Serum wavetable, an 8-slot mod matrix).

| Role | Slab machines and starting presets |
|---|---|
| drums | `drum2`: `gated-snare-kit` (80s pop), `polite-studio-kit`, `909-punch`, `808-boom`, `tight-funk-kit`, `light-disco-kit` |
| bass | `concoction`: `crisp-saw-bass`, `clean-sine-bass`, `pluck-bass`, `kick-bass`, `reese`, `wobble` (the clean, punchy digital basses). `cream`: `outstanding-funk-bass`, `synthwave-bass`, `deep-sub-bass`. `profit5`: `heavy-bass`, `clang-fm-bass`. `ms20`: `rubber-bass`, `acid-bass`, `octave-night-bass`. `fm86`: `bass-1` (DX slap) |
| harmonic bed | `juno2`: `wide-sunny-pad`, `lush-pad`, `strings`, `string-machine-wash`. `profit5`: `poly-strings`, `ob-pad`. `fm86`: `strings-1` |
| rhythmic comping | `fm86`: `e-piano-1` (the DX7 ballad piano), `clav-1`. `rhodes`: `default`, `mellow`. `juno2`: `warm-chord-plucks`, `polite-synth-pop-keys`. `profit5`: `pluck-keys` |
| lead / vocal line | `cream`: `cream-lead`, `whistle`. `ms20`: `vibrato-lead`, `portamento-highway-lead`. `fm86`: `syn-lead-1`, `flute-1`. `profit5`: `sync-lead`, `shred-lead` |
| stabs / brass | `juno2`: `bright-brass-stab`, `brass-stab`, `posh-brass-poly`. `profit5`: `prophet-brass`, `ob-jump-brass`. `fm86`: `brass-1` |
| ear candy | `profit5`: `poly-mod-bell`. `fm86`: `vibe-1`, `marimba`, `tub-bells`, `orch-chime`. `delay2` on a sparse arp |

Genre palettes:

- **Sophisti-pop / AOR**: gated-snare kit, funk bass, DX e-piano, Juno
  pad, brass stabs, vibes, a soft lead with a little glide.
- **Synthwave**: `tough-night-kit`, `synthwave-bass` driving 8ths,
  `lush-pad`, `pluck-keys` arp through a dotted-8th delay, `cream-lead`.
- **Italo / disco**: four on the floor (`light-disco-kit`), octave bass
  (`rubber-disco-bass`), `party-chord-stab`, `string-machine-wash`.
- **Boogie / funk**: `tight-funk-kit`, `ms20` `squelchy-boogie-bass`,
  `clav-1` through `funk` (`clav-quack`), `posh-brass-poly`.

Tweak after loading a preset: `track.set(cutoff=..., level=...)`. The
most useful moves are the filter cutoff (darker sits further back),
env amount, `age` (analog drift on juno2, cream and profit5) and level.

## 8. Mixing

### Gain structure in Slab

- Machines have headroom and nothing clips inside the mix. The only
  nonlinearity is the **master soft-clip above −0.45 dBFS**, a safety
  net; the master meter's clip LED lights at 0 dBFS.
- Track `volume` is linear gain: 0.5 ≈ −6 dB, 0.25 ≈ −12 dB, 1.25 max.
  Pan is equal-power, so centred tracks are 3 dB down per side.
- Balance first with `volume`. Use instrument `level` params only when
  a track needs more than +2 dB.

### The insert chain

Order on a track:

```
EQ (clean-up: HPF, mud cut) → comp → sat → EQ (tone) → chorus → delay → verb
```

EQ before the comp so rumble doesn't pump it. Saturation after the comp
so it colors an even signal. Modulation, then time-based effects, at
the end.

### Channel starting points

Values from Paper Boulevard and the demos. Adjust by ear and by the
stem report.

| Track | Chain |
|---|---|
| kick + snare | `eq2` hpf 30–35 Hz, cut 400 Hz −2.5 dB, shelf 7 kHz +2 → `comp2` `dry-drum-punch` (or thresh −16, ratio 3.5, atk 3 ms, rel 30 ms, makeup +3) → `verb2` `bright-plate`, mix 0.15–0.2, predelay 10 ms for the 80s snare. For the big gated 80s room (Phil Collins, "Mama") use `verb2` in GATED mode instead: `gated-drum-room` on the kit (the dry drums key the gate, so the room bursts on each hit and cuts dead after HOLD), `gated-snare-slam` for a snare-only track, `reverse-nonlin` for the swell-up program. Keep DECAY long (10 s or more) so the tail is still full when the gate shuts, and a hat or shaker on the same track re-opens it: put those on their own track. The console way is a bus: `room = song.bus("ROOM", fx=[fx("verb2", "gated-drum-room", mix=1.0, key=kit)])`, `kit.send(room, -11)`; the room then keys off the kit's own signal and several tracks can share it. Key it from a snare on its own track instead (`key=snare`, Glass Horizon) and only the backbeat opens the room: toms ring into it only while a snare holds it open, so a fill after the last snare hit plays dry |
| hats | `eq2` hpf 400–500 Hz, shelf 9 kHz −2 if harsh → `verb2` `small-room` mix 0.1. Pan 0.2–0.3 |
| bass | `eq2` hpf 30–35 Hz, cut 250 Hz −2 → `comp2` `bass-leveler` (thresh −14, ratio 3, atk 1 ms, rel 25 ms; `det=1` RMS for less low-end grit). No chorus or reverb. Centred |
| e-piano / keys | `eq2` hpf 150–200 Hz, +1.5 dB at 2.8 kHz → `chorus2` `wide-keys` → `verb2` `medium-plate` 0.18. Pan ±0.25 |
| pad | `eq2` hpf 240–300 Hz, −3 dB at 500 Hz, shelf 8 kHz −3 → `chorus2` `juno-ii` → `verb2` `big-plate-hall` 0.3. Quiet: it's a bed |
| brass / stabs | `eq2` hpf 200–250 → `verb2` `medium-plate` 0.2. Pan opposite the keys |
| lead / vocal line | `eq2` hpf 200, +1.5 dB at 3 kHz → `delay2` sync 1/4 or 1/8., fb 0.25–0.35, mix 0.18 (or `ducked-vocal-throw`: the repeats bloom between phrases) → `verb2` `plate` 0.22, or `vocal-hall` for a ballad. Centred |
| arp / bells | `eq2` hpf 400 → `delay2` 1/8. dotted, mix 0.2–0.3. Pan wide |

### EQ

- **High-pass everything except kick and bass.** It's the single biggest
  clarity win. Pads at 250 Hz and keys at 150–200 Hz sound thin solo
  and correct in the mix.
- **Mud lives at 250–500 Hz.** Cut 2–3 dB there on pads, keys and the
  kit rather than boosting everything else.
- **Presence at 2–4 kHz** for the lead. **Air above 8 kHz** is better
  added once on the master than on every track.
- **Carve**: if two parts share a range, cut one where the other lives.

### Low end you can feel

Weight comes from **50–120 Hz**, not from the lowest octave. Ears are
insensitive below about 50 Hz, and laptops, earbuds and many monitors
barely play it. A mix whose low end sits at 40–45 Hz measures heavy and
sounds thin.
- Tune kicks to about 50–60 Hz (`kick-tune`) with enough sweep and drive
  that the body and harmonics reach 80–120 Hz. A 90 Hz low shelf helps.
- Keep the bass line out of the kick's fundamental. Put it an octave
  above, or put its notes between the kicks (rolling bass).
- Bass needs harmonics to be heard on small speakers: some filter
  opening, saturation (`sat2` XFMR or TAPE), and movement (chord roots,
  octave and fifth jumps) so it reads as a line, not a hum.
- Heavy resonance and fuzz on acid lines and stabs pull the whole mix
  up into the mids. When a mix "sits high", tame those before touching
  the EQ.

The report flags sub energy that dwarfs the 60–250 Hz band.

### Compression (`comp2`)

| Param | What it does | Typical |
|---|---|---|
| `thresh` | level where gain reduction starts | set so the loud hits get 3–6 dB of reduction |
| `ratio` | how hard above threshold | 2 glue, 3–4 control, 8+ smash |
| `knee` | softness around threshold | 6 default; 8–12 on buses |
| `atk` | how fast the gain clamps (a time constant: 63 % of the way) | 3–10 ms lets drum transients through; under 1 ms flattens them |
| `rel` | how fast it lets go (time constant) | 10–50 ms on drums and bass; 50–300 ms on buses; short pumps, and on bass distorts (try `det` RMS) |
| `hpf` | sidechain high-pass: the detector ignores what's below | 20 = off; 80–150 Hz on buses so the kick doesn't pump everything |
| `det` | PEAK (0) follows hits; RMS (1) follows average level | RMS on bass, vocals, pads |
| `makeup` | gain back after reduction | about half the reduction |
| `mix` | parallel blend | 0.3–0.5 with heavy settings for "parallel smash" |

Preset shortcuts (each measured against its job, docs/24 §Presets):
`dry-drum-punch`, `drum-smash` (parallel, mix 0.5), `drum-bus` (on a
DRUMS group), `rude-clap`, `bass-leveler`, `vocal-leveler`,
`smooth-pad-comp`, `bus-glue` / `gentle-bus-glue` / `soft-master-glue`,
`pump` / `audible-pump`. They're level-neutral on the songs' material;
trim THRESH to the source (a quieter track needs a lower one). For ducking, key the
detector from another track: `fx("comp2", thresh=-30, ratio=6, key=kick)`
on the bass or pad pumps it on every kick; a muted "ghost kick" track
still keys (docs/23 §Sidechain keys).

For groups and the mix bus, `bus2` (SSL-style, docs/24 §bus2) is the
glue: stepped RATIO/ATK/REL (indices: `ratio=1` is 4:1, `atk=4` 10 ms,
`rel=4` AUTO), AUTO release (fast after single hits, slow after loud
passages) and COLOR (distortion that grows with the squash). Presets
`drum-bus`, `mix-glue`, `master-glue`, `drum-crush` (parallel), `pump`.
Glass Horizon's DRUMS group runs `fx("bus2", "drum-bus", thresh=-23,
makeup=5)`, and its pad ducks under the group (`comp2` keyed by DRUMS)
so the kit stands in front of it.

For character, `char2` (docs/24 §char2) has three modes: FET (fast,
odd-harmonic grit: `fet-punch` on drums, `fet-smash` parallel under
them), OPTO (smooth two-stage release: `opto-vocal`, `opto-bass`,
`opto-smooth` for pads and keys) and VARI (wide knee, warm, a slow
floor: `vari-glue` on the mix bus, `vari-drums`). DRIVE sets how much
the color grows with the squash; 0 is clean.

On the master, `multi2` (three-band, docs/24 §multi2) holds the low
end in its own band so kicks stop ducking the rest through the limiter;
`master-balance` is the start, band GAIN adds presence. Use it instead
of a broadband glue comp, not on top: both together level the breaks
up to the drops. Voltage Riot's master is eq2 → `fx("multi2",
"master-balance", mlo_thresh=-18.9, mmid_gain=1, mhi_gain=1.5)` →
limiter2 at gain 9. Other presets: `low-control`, `de-harsh`, `radio`
(4:1 everywhere, upward lift), `upward-lift`. Keyed (`fx("multi2", ...,
key=kick)`), each band listens to the key's same band: the kick ducks
only the bass's lows, a vocal only a pad's mids.

`funk` (FUNK OVERLOAD) is one knob and a RANGE switch (BASS / GTR /
KEYS). 0 is bypass; up to 0.4 a touch wah; to 0.75 squeezed and more
resonant; above that it crossfades into the MS-20 HOT lowpass and
screams at 1. Each note opens the filter by how hard it hits against the
part's own running level, so the same setting works on a quiet or a hot
part, and an auto-gain holds the loudness (within about 1 dB). Presets:
`touch-wah`, `clav-quack`, `keys-quack`, `rubber-bass`, `squelch-bass`,
`overload`, `meltdown`.

Compress what moves too much: bass, drums, a lead with wide velocity.
Leave pads alone; they're already even.

### Saturation, chorus, space

- `sat2`: TAPE for warmth and glue on drums or bass at mix 0.4–0.6.
  TUBE for keys. XFMR for bass weight. DIODE and FUZZ are effects. Keep
  `out` compensating so the stem level doesn't jump.
- `chorus2`: `juno-i` / `juno-ii` for pads and keys. Never on bass or
  kick; it smears the low end out of mono.
- **Space without sends.** Every reverb is an insert with a `mix`, so
  pick **two or three spaces** and reuse the same `verb2` presets across
  tracks, varying only the mix:
  - a **room** (`small-room`, `short-plate-room`) for drums and hats;
  - a **plate** (`bright-plate`, `medium-plate`, `plate`) for the snare,
    keys and lead;
  - a **hall** (`big-plate-hall`, `dreamy-wash`) for pads only.
- **Pre-delay** (10–40 ms) keeps a sound dry and upfront with a tail
  behind it. **Damp** darkens tails so they sit behind the dry sound.
- **Delays** synced (`sync="SYNC"`, `div="1/8."`) are the lead's
  best friend. Damp them below 4 kHz so repeats duck behind the dry note.

### Stereo

Keep kick, snare, bass and lead in the centre. Spread keys and brass
opposite each other (±0.2–0.3), hats slightly off-centre, bells and arps
wide. Pads get width from chorus spread, not pan. The report's
correlation should stay above about 0.3; below 0.2 the mix will
collapse in mono.

### The master

```
eq2 (hpf 25 Hz, gentle air shelf) → comp2 gentle-bus-glue → limiter2 (ceil −1, gain to taste)
```

- **Subsonic**: `song.master(subsonic=True)` (the strip's `SUB 30`)
  cuts under 30 Hz at 24 dB/oct before the chain. Use it when a 16'/sub
  preset or an FM bass written low puts real energy under 20 Hz: the
  meters, the glue comp and the limiter all react to it, and nobody
  hears it. The eq2 hpf above still shapes what's left.
- **Limiter ceiling at −1 dB** keeps the output below the soft-clip
  knee (−0.45 dBFS) with room for inter-sample peaks. Existing songs
  that use −3.2 were written for the old −3.1 dBFS knee; they still work,
  2 dB quieter than they could be.
- **Limiter gain**: raise it until the integrated loudness reaches the
  target, then stop.

| Target | Integrated |
|---|---|
| streaming-safe, dynamic | −14 LUFS |
| modern pop / dance | −10 to −12 LUFS |
| too loud (squashed, crest under 8 dB) | above −9 LUFS |

### Rides

`track.ride({verse1: -2, chorus3: 1.5})` writes the volume lane: each
listed section sits that many dB off the fader (`(dB0, dB1)` moves across
it), with a one-beat glide in. Use it for section contrast (verses thin,
choruses open) and for the lead lifting in the chorus. Call it after the
fader is final. A stem whose track rides reads its average.

### Mixing by numbers: the stem report

`song.render(stems=True)` bounces every track on its own, through its
own inserts but without the master chain, and prints each stem's
integrated loudness. Compared with each other, those numbers are the
balance. Starting targets for a vocal-led pop mix, relative to the
loudest part:

| Stem | Relative to lead |
|---|---|
| lead / vocal line | 0 |
| kick + snare | −1 to −3 (drums read low in LUFS because they're transient) |
| bass | −1 to −3 |
| keys comping | −3 to −5 |
| pad | −5 to −7 |
| stabs | −4 to −6 |
| ear candy | −7 to −10 |
| hats | −9 to −13 (spiky; ears hear them louder than LUFS says) |

For dance music, move kick and bass up to 0 and the lead down 2–3 dB.
These targets get you close quickly. Final balance is by ear.

Report flags and what to do:

| Flag | Fix |
|---|---|
| low end only N% (thin) | raise bass/kick; check the HPFs aren't too high on bass-range parts |
| low end over 72% | bass or kick too loud, or pads not high-passed |
| a lot of top end | hats or noise too loud; bright presets; ease the master air shelf |
| crest under 8 dB | too much limiting or compression; lower limiter gain or comp ratio |
| samples past the knee | limiter ceiling at −1, or turn the master down |
| sections differ under 2 LU | arrangement too static: drop parts in verses and the bridge, add parts in choruses |

## 9. From listening notes to changes

| You hear | Try |
|---|---|
| muddy, boomy | HPF pads/keys higher; cut 250–400 Hz on the kit and pads; bass `cutoff` down |
| harsh, tiring | hats down or `hat-tone` lower; shelf off 8 kHz+; lead cutoff down |
| lead buried | lead +2 dB; +1.5 dB at 3 kHz on the lead; cut 3 kHz on pads/keys; drop the pad in that section |
| drums weak | kit up; comp attack slower (10 ms) for more snap; snare `snap` up; `sat2` TAPE at mix 0.4 |
| snare not 80s enough | more `bright-plate` mix (0.25), shorter `snare-decay`, higher `snare-tone` |
| groove stiff | swing hats 0.55; add snare ghosts; humanize velocity ±8 |
| chorus doesn't lift | chorus melody higher; add stabs and ear candy only in choruses; busier kick; open hats; thin the verse |
| too washy | reverb mix down, pre-delay up, damp lower; keep the hall on pads only |
| everything the same | more section contrast (§3); key change for the last chorus |

## 10. Working with Claude

Ask for a song by reference, form and mood:

> Make a 3-minute sophisti-pop song like Johnny Hates Jazz, D major,
> key change for the last chorus. Render with stems and tell me what
> the mix report says.

Claude researches the reference (§2), writes a script under `songs/`,
renders with stems, fixes the balance until the stems sit in the §8
targets, and reports the numbers. You listen and reply in plain words
(§9). Each round is a script edit plus a re-render. The `.py` file is
the source of truth and the `.slab` file is its output, so edits made in
the Slab UI will be overwritten by the next run of the script.
