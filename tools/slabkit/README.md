# slabkit

Write Slab songs as Python scripts. It checks machine ids and params
against the live manifests, handles the music theory, bounces the song
headless and reports on the mix. Background: docs/19 (format), docs/20
(machines), docs/21 (how to write and mix). Start with the runnable
[composing walkthrough](../../docs/33-composing.md) for a first session,
including GEQ, shared returns and permanent exports.

```sh
zig build                                   # slabkit calls zig-out/bin/slab
PYTHONPATH=tools python3 songs/paper_boulevard.py --render --stems
```

For permanent stems and the mix in one pass:

```sh
zig-out/bin/slab songs/paper_boulevard.slab --render /tmp/paper.wav \
  --stems /tmp/paper-stems --stem-kind tracks --tap fader --tail 4
```

`Song.render(stems=True)` currently bounces the mix and stems separately,
then deletes the temporary stems after analysis. Generating a project again
also overwrites its JSON: save UI edits under another name first.

## Cheat sheet

```python
from slabkit import Song, fx, machine, presets

song = Song("Title", bpm=106, key="D major")        # meter=(4, 4)
verse = song.section("verse", 8)                     # sections run end to end
chorus = song.section("chorus", 8)
song.tempo(16, 132, ramp=True).tempo(24, 140)       # changes at bar starts (docs/28)
# Song("Title", groove="MPC 58 1/16"); section(..., groove="NONE"); track.groove("SAMBA 1/16", amount=0.7, shift_ms=-5)
# track.time(meter=(5, 4), ratio=(3, 2)): its own bars and a tempo ratio; clip.span = its beats in the clip

drums = song.track("KIT", "drum2", "gated-snare-kit", volume=1.0,
                   params=dict(snare_decay=0.26),    # prefix optional, _ for -
                   fx=[fx("comp2", "dry-drum-punch"), fx("verb2", "bright-plate", mix=0.2)])
keys = song.track("KEYS", "fm86", "e-piano-1", volume=0.32, pan=-0.25)
song.master(fx=[fx("comp2", "gentle-bus-glue"), fx("limiter2", gain=3, ceil=-1)])

c = drums.clip(chorus)                               # whole section; or bars=, at_bar=
c.drums({"kick": "x.....x.x.....x.", "snare": "....x..o....x..."}, bars=7)
c.drums({"snare": "....x.x.xoxoXxXX"}, at=28, bars=1)   # fill in the last bar
c.swing(0.54).humanize()

keys.clip(chorus).chords("Gmaj7 A F#m7 Bm7 Em7 A Dmaj7 A7sus4:2 A7:2",
                         "x..x..x...x..x..", near=64)
song.track("BASS", "cream", "synthwave-bass").clip(chorus).bass("I V vi IV", "x.xo..x.x.xo.5x.")
song.track("LEAD", "cream", "cream-lead").clip(chorus).melody("F#5:1.5 E5:.5 D5:1 E5 | r:.5 A4:.5 C#5 E5")
# the sampler takes a keymap: a .wav, an .sfz, or a folder (a drum kit when
# the file names carry no notes; kick = C2 = 36)
song.track("HITS", "sampler", "sp1200-kit", samples="/path/to/kit")
# a preset that names its samples brings them: a library kit, a CMI voice
song.track("CR-78", "sampler", "drums/roland-cr-78/kit")
song.track("VOICE", "unfairlight", "sararr")

song.save()                    # songs/title.slab, prints warnings
song.render(stems=True)        # mix + report; temporary stems are deleted
```

| Clip method | Does |
|---|---|
| `note(pitch, at, len, vel)` | one note; pitch as int or "C#4" |
| `chord(pitches, at, len, vel, strum)` | notes together |
| `melody("E5:1.5 D5:.5 r:1 C5:1@110 A4~")` | pitch:beats, `r` rest, `@vel`, `~` tie/slide; length carries over |
| `drums({lane: steps}, at, bars, step)` | lanes kick/snare/clap/ch/oh/tom or aliases; X x o . - |
| `seq("F2 . F3! Ab2~ Gb2 - .", step, bars, vel, accent, gate)` | step sequencer: one token per step, `!` accent, `~` slide, `-` tie |
| `chords(prog, rhythm, near, voices, spread, vel, gate, strum)` | voice-led; prog is roman or symbols, `:beats` per chord |
| `bass(prog, pattern, octave)` | x/X root, o/O octave, 3 5 7 chord tones, b approach, - tie |
| `arp(prog, "up"/"down"/"updown"/"random"/[indices], rate, octave)` | arpeggio per chord |
| `repeat(every_beats)` | tile the first N beats across the clip |
| `transpose(n)`, `swing(amount, grid)`, `humanize(time, vel)`, `velocities(fn)` | transforms |
| `copy(section)` | same notes (and clip automation) on another section |
| `automate(target, points…)`, `ramp(target, frm, to, v0, v1, tension)` | clip automation: like the track's, beats from the clip's start; overrides the track lane while the clip plays |
| `bend(points, notes=None, dim="pitch")` | per-note expression: (beat from the note's start, value[, shape, tension]), max 8; pitch in semitones (every pitched machine), `gain` in dB (sampler, Unfairlight), `pressure`/`slide` 0..1 |
| `converge(to, start, end, tension=-0.3)` | every note sounding over [start, end) bends onto pitch `to` by `end`: a chord folding onto one note |

| Track method | Does |
|---|---|
| `automate(target, (beat, value[, shape[, tension]]), …)` | an automation lane (docs/22): target `"volume"`, `"pan"`, an instrument param (`"cutoff"`) or `"fx1:mix"`; values in the param's units; shape `linear`/`curve`/`hold` shapes the segment to the next point |
| `ramp(target, frm, to, v0, v1, tension=0)` | one sweep from `v0` to `v1` between two beats; tension + = fast start |
| `audio(path, section=None, at_bar=0, at_beat=None, start_sec=0, dur_sec=None, gain=1, fade_in=0, fade_out=0, reverse=False, warp=None, fit_beats=None, mode="tape", preserve="hits", gap="cut", decay=100, transpose=0, fine=0, grain=40, size=0.7, tune=None, scale="chromatic", speed=20, humanize=0)` | a WAV clip mixed straight into the track; `reverse=True` plays it backwards (end it on the downbeat for a swell); `warp=bpm` locks it to the beat (it follows the song's tempo), `fit_beats=n` stretches it to n beats, `mode="tape"` (speed and pitch together) or `"beats"` (sliced at the hits, for drums) with `preserve="hits"|"1/16"|"1/8"|"1/4"`, `gap="cut"|"loop"`, `decay=1..100`, `"mix"` (keeps pitch, for anything), `"voice"` (one line, `grain=` 10–80 ms) or `"smear"` (texture, `size=` 0.3/0.7/1.4/2.7 s); `transpose=` semitones, `fine=` cents (not with tape); `tune="A"` puts a voice in that key with `scale=` (`"chromatic"`, `"major"`, `"minor"`, `"harmonic"`, `"dorian"`, `"mixolydian"`, `"penta_major"`, `"penta_minor"`, `"blues"`), `speed=` ms (0: the hard effect) and `humanize=` 0–100 |
| `zone(name, level, tune, decay, tone, reverse)` | sampler/Unfairlight: edit one sound of the keymap by name |
| `duplicate_zone(name, key, as_name=None, reverse=False, **edits)` | copy a kit sound onto `key` (a note or number) as its own sound, e.g. a reversed snare next to the snare; returns the copy's name |

Discovery: `print(machine("juno2").help())`, `presets("fm86")`,
`python3 tools/slabkit/gen_reference.py` (regenerates docs/20).

Theory: `Key("A minor").progression("i VI III VII")`, `.degree(5)`,
`.diatonic(2, sevenths=True)`, `.snap(pitch)`, `Chord.parse("Cmaj7/E")`,
`note("C4") == 60`.
