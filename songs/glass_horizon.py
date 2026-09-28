"""Glass Horizon — early-80s Phil Collins territory ("In the Air Tonight",
"I Don't Care Anymore", Genesis' "Mama"). Original material.

93 BPM, E minor. A CR-78 loop that never stops, a dark poly pad, a
breathy Fairlight voice singing the line, fretless-ish synth bass with
glide. No real drums for two and a half minutes: the bridge's pad chord
folds onto one note under a reversed crash, the room goes quiet, and a
descending five-tom fill brings in the kit through verb2's gated room
(no cymbals but the one on the downbeat).

    PYTHONPATH=tools python3 songs/glass_horizon.py [--render [--stems]]
    zig-out/bin/slab songs/glass_horizon.slab
"""
import os

from slabkit import Song, fx
from slabkit.machines import library_path

song = Song("Glass Horizon", bpm=93, key="E minor")

# ── form ───────────────────────────────────────────────────────────────
intro = song.section("intro", 8)
verse1 = song.section("verse1", 8)
chorus1 = song.section("chorus1", 8)
verse2 = song.section("verse2", 8)
chorus2 = song.section("chorus2", 8)
bridge = song.section("bridge", 4)
brk = song.section("break", 2)       # the pad holds one note; bar 2 ends in the fill
chorus3 = song.section("chorus3", 8)  # the kit arrives
outro = song.section("outro", 8)
end = song.section("end", 2)

VERSE = "Em7 Cmaj7 Am7 Bm7"
CHORUS = "Cmaj7 D Em7 Em7 Cmaj7 D Bsus4 B"
BRIDGE = "Am7 Bm7 Cmaj7 D"

# ── the line (the "vocal") ─────────────────────────────────────────────
# Low and narrow in the verses, up a fifth for the chorus; the chorus
# ends on D#, the leading tone back to Em.
VERSE_LINE = """
r:1 B3:.5 B3:.5 G3:1 A3:1 | B3:2 r:2 | r:.5 A3:.5 C4:1 B3:.5 A3:.5 G3:1 | F#3:3 r:1
r:1 B3:.5 D4:.5 E4:1 D4:1 | B3:1.5 G3:.5 E3:2 | r:.5 E3:.5 G3:1 A3:1 B3:1 | F#3:4
"""
CHORUS_LINE = """
E4:1.5 D4:.5 E4:2 | F#4:1 E4:1 D4:2 | B3:4 | r:2 G4:1 F#4:1
E4:1.5 D4:.5 E4:1 G4:1 | F#4:2 A4:1 G4:1 | F#4:2 E4:2 | D#4:4
"""

# ── tracks ─────────────────────────────────────────────────────────────
# The CR-78: runs from the first bar to the last, dry-ish in a small room.
cr78 = song.track("CR-78", "sampler", "drums/roland-cr-78/kit", volume=0.9, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=40, p1_hz=350, p1_db=-2, hs_hz=8000, hs_db=1.5),
    fx("comp2", "dry-drum-punch", mix=0.5),
    fx("verb2", "small-room", mix=0.16),
])
# The kit: acoustic samples, toms filled out to five with copies, and the
# gated room doing the rest.
# Snare, toms and the crash go through the gated room; the kick has its
# own track (a room full of kick is mud, and the 80s mixes kept it out).
kit = song.track("KIT", "sampler", "vcsl-kits/acoustic-kit", volume=1.1, params=dict(level=1.0), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, p1_hz=450, p1_db=-3, p1_q=0.9, p2_hz=2200, p2_db=4, hs_hz=6000, hs_db=3),
    fx("comp2", "drum-smash", makeup=15),
    fx("verb2", "gated-drum-room", mix=0.65),
])
kick = song.track("KICK", "sampler", "vcsl-kits/acoustic-kit", volume=1.1, params=dict(level=1.0), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=35, p1_hz=380, p1_db=-5, p1_q=1.2, p2_hz=3500, p2_db=3),
    fx("comp2", "dry-drum-punch", makeup=10),
    fx("verb2", "small-room", mix=0.1),
])
TOM_HI2 = kit.duplicate_zone("high tom", 50, as_name="rack tom", tune=3)
TOM_LO2 = kit.duplicate_zone("mid tom", 43, as_name="floor tom hi", tune=-2.5)
KICK, SNARE, CRASH = 36, 38, 49
TOMS = [50, 48, 45, 43, 41]  # high to low

pad = song.track("PAD", "juno2", "bittersweet-minor-pad", volume=0.21, params=dict(level=0.55), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=180, p1_hz=520, p1_db=-2.5, hs_hz=7000, hs_db=-2),
    fx("chorus2", "juno-ii"),
    fx("verb2", "big-plate-hall", mix=0.32),
])
voice = song.track("VOICE", "unfairlight", "sararr", volume=1.0, params=dict(vib_depth=0.12, filter=215, vol=0.95), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=150, p1_hz=400, p1_db=-2, p2_hz=2600, p2_db=4, hs_hz=7000, hs_db=3),
    fx("comp2", "vocal-leveler"),
    fx("delay2", sync="SYNC", div="1/4", fb=0.28, damp=3500, mix=0.16),
    fx("verb2", "vocal-plate", mix=0.26),
])
choir = song.track("CHOIR", "unfairlight", "choir05", volume=0.17, pan=-0.15, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=250),
    fx("chorus2", "string-ensemble"),
    fx("verb2", "big-hall", mix=0.35),
])
bass = song.track("BASS", "cream", "deep-sub-bass", volume=1.25, params=dict(glide=0.07), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=32, p2_hz=900, p2_db=2),
    fx("comp2", "bass-leveler"),
])
keys = song.track("RHODES", "rhodes", "mellow", volume=0.35, pan=0.2, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=160),
    fx("chorus2", "wide-keys"),
    fx("verb2", "medium-plate", mix=0.22),
])
# The echo guitar stand-in: a pluck into long dub echoes.
echo = song.track("ECHO", "juno2", "pluck-keys", volume=0.26, pan=-0.3, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=400, hs_hz=6000, hs_db=-3),
    fx("delay2", "dub-tail", mix=0.4),
    fx("verb2", "plate", mix=0.25),
])
swell = song.track("SWELL", "sampler", volume=1.25, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=300),
    fx("verb2", "big-hall", mix=0.3),
])

# ── the CR-78 loop ─────────────────────────────────────────────────────
RIM, CHH, BONGO_HI, CONGA, GUIRO, TAMB = 37, 44, 60, 64, 73, 54
LOOP = {36: "x.......x.x.....", CHH: "x.x.x.x.x.x.x.x.",
        BONGO_HI: "...x.......x....", CONGA: "......x.......x.", GUIRO: "..........x....."}
LOOP_B = {**LOOP, 36: "x.......x.x...x.", RIM: "............x..."}  # every 4th bar
BUSY = {**LOOP_B, TAMB: "....x.......x..."}


def cr_section(sec, pattern=LOOP, turn=LOOP_B, vel=96):
    c = cr78.clip(sec)
    for bar in range(sec.bars):
        c.drums(turn if bar % 4 == 3 else pattern, at=bar * 4, bars=1)
    c.velocities(lambda n: vel if n["pitch"] != CHH or n["start"] % 1 == 0 else vel - 22)
    c.humanize(time=0.002, vel=4)
    return c


cr_section(intro, vel=90)
cr_section(verse1, vel=92)
cr_section(chorus1, BUSY, BUSY)
cr_section(verse2)
cr_section(chorus2, BUSY, BUSY)
cr_section(bridge, BUSY, BUSY, vel=100)
cr_section(brk, vel=86)
cr_section(chorus3, BUSY, BUSY, vel=100)
cr_section(outro, BUSY, BUSY, vel=100)

# ── the kit: fill, then the gated room ─────────────────────────────────
fill = kit.clip(brk, at_bar=1, bars=1)
for i, tom in enumerate([TOMS[0], TOMS[0], TOMS[1], TOMS[1], TOMS[2], TOMS[2], TOMS[3], TOMS[4]]):
    fill.note(tom, 2 + i * 0.25, 0.2, 96 + i * 4)
fill.note(SNARE, 1.5, 0.2, 90).note(SNARE, 1.75, 0.2, 100)

GROOVE = {KICK: "x.......x.x.....", SNARE: "....x.......x..."}
TURN = {KICK: "x.......x.x.....", SNARE: "....x.......x.x.", 45: "..............x.", 41: "...............x"}
for sec in (chorus3, outro):
    c = kit.clip(sec)
    for bar in range(sec.bars):
        last = bar == sec.bars - 1
        c.drums(TURN if bar % 4 == 3 and not last else GROOVE, at=bar * 4, bars=1)
    if sec is chorus3:
        c.note(CRASH, 0, 1, 118)
    c.humanize(time=0.004, vel=6)
# the last bar of the outro: a tom run into the final hit
c = kit.clips[-1]
c.notes = [n for n in c.notes if n["start"] < 28]
for i in range(10):
    c.note(TOMS[i % 5], 28 + i * 0.4, 0.2, 100 + i * 2)
kit.clip(end, bars=1).note(KICK, 0, 0.5, 120).note(SNARE, 0, 0.5, 118).note(CRASH, 0, 2, 120)

# the kick moves to its own track, clip for clip
for c in kit.clips:
    k = kick._new_clip(c.name, c.start, c.length)
    k.notes = [n for n in c.notes if n["pitch"] == KICK]
    c.notes = [n for n in c.notes if n["pitch"] != KICK]

# the reversed crash: swells over the end of the bridge and stops dead at the break
crash_wav = next(os.path.join(root, f) for root, _, files in os.walk(library_path("lib:vcsl"))
                 for f in files if f.startswith("cymbal_crash2_f1"))
SWELL_SEC = 3.6
swell.audio(crash_wav, at_beat=brk.start - SWELL_SEC * song.bpm / 60, start_sec=0.0,
            dur_sec=SWELL_SEC, fade_out=0.02, reverse=True, gain=2.0)

# ── pad ────────────────────────────────────────────────────────────────
for sec, prog, vel in [(intro, VERSE, 70), (verse1, VERSE, 74), (chorus1, CHORUS, 84), (verse2, VERSE, 76),
                       (chorus2, CHORUS, 88), (chorus3, CHORUS, 92), (outro, CHORUS, 90)]:
    pad.clip(sec).chords(prog, near=57, voices=4, spread=True, vel=vel)
# the bridge: the last chord folds onto E, and E holds through the break
b = pad.clip(bridge).chords(BRIDGE, near=57, voices=4, spread=True, vel=90)
b.converge("E3", 12, 16, tension=-0.35)
pad.clip(brk).note("E3", 0, 7.75, 86)
pad.clip(end).chords("Em9", near=57, voices=5, spread=True, vel=86)

# ── the line and the choir ─────────────────────────────────────────────
voice.clip(verse1).melody(VERSE_LINE, vel=100, gate=0.96)
voice.clip(chorus1).melody(CHORUS_LINE, vel=108, gate=0.96)
voice.clip(verse2).melody(VERSE_LINE, vel=100, gate=0.96)
voice.clip(chorus2).melody(CHORUS_LINE, vel=110, gate=0.96)
voice.clip(chorus3).melody(CHORUS_LINE, vel=114, gate=0.96)
# the outro: the chorus' first half, twice, answered by space
half = CHORUS_LINE.strip().split("\n")[0]
voice.clip(outro).melody(half + " | " + half.replace("r:2 G4:1 F#4:1", "r:4"), vel=106, gate=0.96)

# the choir is held back for the kit's arrival
for sec in (chorus3, outro):
    choir.clip(sec).chords(CHORUS, near=64, voices=3, vel=90)

# ── bass: whole notes that glide, entering at the first chorus ─────────
for sec, prog, pat in [(chorus1, CHORUS, "x-------x-----o-"), (verse2, VERSE, "x-----------x---"),
                       (chorus2, CHORUS, "x-------x-----o-"), (bridge, BRIDGE, "x-------x-x-----"),
                       (chorus3, CHORUS, "x.......x.x...o."), (outro, CHORUS, "x.......x.x...o.")]:
    bass.clip(sec).bass(prog, pat, octave=1, vel=96)
bass.clip(brk).note("E1", 0, 3.5, 90)
bass.clip(end, bars=1).note("E1", 0, 3.5, 110)

# ── rhodes and echo ────────────────────────────────────────────────────
for sec in (verse1, verse2):
    keys.clip(sec).chords(VERSE, "x.......x.......", near=60, voices=4, vel=70, gate=0.95)
echo.clip(verse2).arp(VERSE, [0, 2, 3, 2], rate=1.0, octave=4, vel=78, gate=0.4)
echo.clip(intro, at_bar=4, bars=4).arp(VERSE, [3, 2, 0], rate=1.5, octave=5, vel=70, gate=0.35)

# ── master ─────────────────────────────────────────────────────────────
song.master(fx=[
    fx("eq2", hpf_on="ON", hpf_hz=25, hs_hz=10000, hs_db=1),
    fx("comp2", "gentle-bus-glue", mix=0.6),
    fx("limiter2", gain=2.5, ceil=-3.2),
])

if __name__ == "__main__":
    import sys
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
