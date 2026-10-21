"""Rack Rigs: a short demo of racks built from slabkit (docs/42).
Original material.

96 BPM, A minor. KEYS is a rack built here: a Rhodes and a Juno pad on
one track, the pad playing only above C4, with a WASH macro that brings
the pad up and the Rhodes' tine bark down. BASS is the bass-di-amp rig
from its preset, and DRUMS go through the parallel-squash effect rack.
The automation rides WASH across the song and reaches inside the bass
rig to the amp's gain (lane 1's insert 1, a rack inside the rack).

    PYTHONPATH=tools python3 songs/rack_rigs.py
    zig-out/bin/slab songs/rack_rigs.slab
"""
from slabkit import Song, fx, rack

song = Song("Rack Rigs", bpm=96, key="A minor")

intro = song.section("intro", 4)
verse = song.section("verse", 8)
lift = song.section("lift", 4)

PROG = "Am9 Fmaj7 Dm9 E7sus4"

# ── keys: Rhodes everywhere, a pad on top of the register ──────────────
keys = rack("Keys")
ep = keys.lane("EP", "rhodes", "mellow")
pad = keys.lane("PAD", "juno2", "lush-pad", keys=(60, 127), level=-6)
wash = keys.macro(1, "WASH", 0.3)
keys.map(wash, pad, "level", min=-40, max=0)
keys.map(wash, ep, "level", min=0, max=-8)
kt = song.track("KEYS", keys, volume=0.6, fx=[fx("verb2", "long-melancholy-verb", mix=0.18)])
for sec in (intro, verse, lift):
    kt.clip(sec).chords(PROG, near=60, voices=4, vel=78)
kt.automate("rk-m1", (0, 0.1), (verse.end, 0.6), (lift.end, 1.0))

# ── bass: the DI + amp rig, as saved ───────────────────────────────────
bass = song.track("BASS", "rack", "bass-di-amp", volume=0.75)
for sec in (verse, lift):
    bass.clip(sec).bass(PROG, pattern="x..x..x.x...x...", octave=2)
# The amp's gain inside the inner effect rack: lane 1's first insert is
# the fxrack, whose lane 2 has the amp as insert 1.
bass.automate("inst/1.1/2.1:amp-gain", (verse.start, 0.3), (lift.end, 0.8))

# ── drums through the parallel squash rack ─────────────────────────────
drums = song.track("DRUMS", "drum2", "dry-punch-kit", volume=0.7, fx=[fx("fxrack", "parallel-squash")])
for sec in (verse, lift):
    drums.clip(sec).drums({
        "kick":  "x.......x.x.....",
        "snare": "....x.......x...",
        "ch":    "x.x.x.x.x.x.x.x.",
    })

song.save()
if __name__ == "__main__":
    song.render(stems=True)
