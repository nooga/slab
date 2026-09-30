"""Consequences — a short Profit-5 demo. Original material.

116 BPM, A minor, 80s synth-pop. Every pitched part is Profit-5, one
signature sound per role:

  intro   poly-mod bell arp over the string pad
  verse   heated bass, Prophet brass stabs, the bell arp keeps going
  chorus  OB brass riff, sync-sweep lead on top
  break   pluck keys and the clangy FM bass, drums thin out
  solo    the shred lead over everything
  outro   pad and bell alone

    PYTHONPATH=tools python3 songs/profit_five_demo.py --render --stems
    zig-out/bin/slab songs/consequences.slab
"""
from slabkit import Song, fx

song = Song("Consequences", bpm=116, key="A minor")

intro = song.section("intro", 4)
verse = song.section("verse", 8)
chorus = song.section("chorus", 8)
brk = song.section("break", 4)
solo = song.section("solo", 8)
outro = song.section("outro", 4)

VERSE = "Am F C G"
CHORUS = "F G Am Am F G C E"
SOLO = "Am F C G"

# ── tracks ─────────────────────────────────────────────────────────────
kit = song.track("KIT", "drum2", "gated-snare-kit", volume=0.8, fx=[
    fx("comp2", "dry-drum-punch"),
    fx("verb2", "gated-drum-room", mix=0.18),
])
bass = song.track("BASS", "profit5", "heavy-bass", volume=0.55, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=35),
    fx("comp2", "bass-leveler"),
])
fmbass = song.track("FM BASS", "profit5", "clang-fm-bass", volume=0.5, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=40),
])
pad = song.track("STRINGS", "profit5", "poly-strings", volume=0.32, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=180),
    fx("chorus2", "string-ensemble"),
    fx("verb2", "big-hall", mix=0.3),
])
bell = song.track("BELL", "profit5", "poly-mod-bell", volume=0.3, pan=0.25, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=300),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.35, damp=3500, mix=0.25),
    fx("verb2", "big-plate-hall", mix=0.25),
])
brass = song.track("BRASS", "profit5", "prophet-brass", volume=0.63, pan=-0.2, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=150),
    fx("verb2", "medium-plate", mix=0.2),
])
obrass = song.track("OB BRASS", "profit5", "ob-jump-brass", volume=0.56, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=160),
    fx("chorus2", "wide-keys"),
    fx("verb2", "medium-plate", mix=0.2),
])
lead = song.track("SYNC LEAD", "profit5", "sync-lead", volume=0.42, pan=0.1, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=250),
    fx("delay2", sync="SYNC", div="1/4", fb=0.3, damp=4000, mix=0.2),
    fx("verb2", "big-plate-hall", mix=0.2),
])
pluck = song.track("PLUCK", "profit5", "pluck-keys", volume=0.4, pan=-0.3, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=200),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.4, damp=3000, mix=0.3),
])
shred = song.track("SHRED", "profit5", "shred-lead", volume=0.63, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=180, hs_hz=7000, hs_db=-3),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.3, damp=3000, mix=0.18),
    fx("verb2", "big-hall", mix=0.18),
])

# ── patterns ───────────────────────────────────────────────────────────
BEAT = {"kick": "x.......x.x.....", "snare": "....x.......x...", "ch": "x.x.x.x.x.x.x.xo"}
HALF = {"kick": "x...............", "snare": "........x.......", "ch": "..x...x...x...x."}

# ── intro: bell arp over the pad ───────────────────────────────────────
pad.clip(intro).chords(VERSE, near=60, spread=True, vel=80)
bell.clip(intro).arp(VERSE, "updown", rate=0.5, octave=5)

# ── verse ──────────────────────────────────────────────────────────────
kit.clip(verse).drums(BEAT).humanize(time=0.002, vel=5)
bass.clip(verse).bass(VERSE + " " + VERSE, "x.xo.xx.x.xo.x5.", octave=2)
brass.clip(verse).chords(VERSE + " " + VERSE, "x.....x...x.....", near=64, vel=96, gate=0.5)
bell.clip(verse).arp(VERSE + " " + VERSE, "up", rate=0.5, octave=5).velocities(lambda n: n["vel"] * 0.8)
pad.clip(verse).chords(VERSE + " " + VERSE, near=60, spread=True, vel=70)

# ── chorus: the OB brass riff and the sync lead ────────────────────────
kit.clip(chorus, bars=7).drums(BEAT).humanize(time=0.002, vel=5)
kit.clip(chorus, at_bar=7, bars=1, name="fill").drums({"snare": "....x.x.xxxxXXXX"})
bass.clip(chorus).bass(CHORUS, "x.xo.xx.x.xo.x5.", octave=2)
obrass.clip(chorus).chords(CHORUS, "x..x..x...x.x...", near=65, vel=104, gate=0.4)
pad.clip(chorus).chords(CHORUS, near=60, spread=True, vel=74)
lead.clip(chorus).melody(
    "A5:1.5 G5:.5 E5:1 C5:1 | D5:1.5 E5:.5 G5:2 | A5:1 C6:1 B5:1 A5:1 | E5:4 |"
    " F5:1.5 E5:.5 D5:1 C5:1 | D5:1.5 E5:.5 G5:2 | A5:2 B5:1 C6:1 | B5:2 G#5:2", vel=108)

# ── break: pluck and the FM bass ───────────────────────────────────────
kit.clip(brk).drums(HALF)
fmbass.clip(brk).seq("A2 . A3! . A2 A2 . G2~ | A2 . C3! . A2 E3 . G3", vel=100, accent=120)
pluck.clip(brk).arp("Am F", [0, 1, 2, 3, 2, 1], rate=0.5, octave=4)

# ── solo: the shred lead ───────────────────────────────────────────────
kit.clip(solo, bars=7).drums(BEAT).humanize(time=0.002, vel=5)
kit.clip(solo, at_bar=7, bars=1, name="fill").drums({"snare": "xxxxxxxxXXXXXXXX"})
bass.clip(solo).bass(SOLO + " " + SOLO, "x.xo.xx.x.xo.x5.", octave=2)
brass.clip(solo).chords(SOLO + " " + SOLO, "x.....x...x.....", near=64, vel=90, gate=0.5)
shred.clip(solo).melody(
    "A4:.5 C5:.5 E5:.5 A5:1.5 G5:1 | F5:.5 E5:.5 D5:.5 C5:.5 A4:2 |"
    " E5:.5 G5:.5 C6:1 B5:.5 G5:.5 E5:1 | D5:.5 E5:.5 G5:1 B5:2 |"
    " A5:1 C6:.5 A5:.5 E5:1 C5:1 | F5:.5 A5:.5 C6:1 A5:1 F5:1 |"
    " G5:.75 E5:.75 C5:.5 E5:1 G5:1 | B5:.5 A5:.5 G5:.5 B5:.5 A5:2", vel=112)

# ── outro ──────────────────────────────────────────────────────────────
pad.clip(outro).chords("Am F Am Am", near=60, spread=True, vel=74)
bell.clip(outro).arp("Am F Am Am", "down", rate=0.5, octave=5)

song.master(fx=[
    fx("eq2", hpf_on="ON", hpf_hz=26),
    fx("comp2", "gentle-bus-glue"),
    fx("limiter2", gain=4, ceil=-1.0),
])

if __name__ == "__main__":
    import sys
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
