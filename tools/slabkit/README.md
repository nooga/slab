# slabkit

Write Slab songs as Python scripts. It checks machine ids and params
against the live manifests, handles the music theory, bounces the song
headless and reports on the mix. Background: docs/19 (format), docs/20
(machines), docs/21 (how to write and mix).

```sh
zig build                                   # slabkit calls zig-out/bin/slab
PYTHONPATH=tools python3 songs/paper_boulevard.py --render --stems
```

## Cheat sheet

```python
from slabkit import Song, fx, machine, presets

song = Song("Title", bpm=106, key="D major")        # meter=(4, 4)
verse = song.section("verse", 8)                     # sections run end to end
chorus = song.section("chorus", 8)

drums = song.track("KIT", "drum2", "gated-snare-kit", volume=1.0,
                   params=dict(snare_decay=0.26),    # prefix optional, _ for -
                   fx=[fx("comp2", "dry-drum-punch"), fx("verb2", "bright-plate", mix=0.2)])
keys = song.track("KEYS", "fm86", "e-piano-1", volume=0.32, pan=-0.25)
song.master(fx=[fx("comp2", "gentle-bus-glue"), fx("limiter2", gain=3, ceil=-3.2)])

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

song.save()                    # songs/title.slab, prints warnings
song.render(stems=True)        # bounce + mix report
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
| `copy(section)` | same notes on another section |

| Track method | Does |
|---|---|
| `automate(target, (beat, value[, shape[, tension]]), …)` | an automation lane (docs/22): target `"volume"`, `"pan"`, an instrument param (`"cutoff"`) or `"fx1:mix"`; values in the param's units; shape `linear`/`curve`/`hold` shapes the segment to the next point |
| `ramp(target, frm, to, v0, v1, tension=0)` | one sweep from `v0` to `v1` between two beats; tension + = fast start |

Discovery: `print(machine("juno2").help())`, `presets("fm86")`,
`python3 tools/slabkit/gen_reference.py` (regenerates docs/20).

Theory: `Key("A minor").progression("i VI III VII")`, `.degree(5)`,
`.diatonic(2, sevenths=True)`, `.snap(pitch)`, `Chord.parse("Cmaj7/E")`,
`note("C4") == 60`.
