"""Squelch Acid — a 128 BPM acid track for the Squelch 33.

Generate: PYTHONPATH=tools python3 songs/squelch_acid.py
Render:   ... --render

The line plays alone with CUT closed, the 909 comes in and the filter
opens over eight bars while RES climbs toward the scream; the last
section doubles it with a WET square an octave up, accents stacking.
"""
import argparse
from slabkit import Song, fx

song = Song("Squelch Acid", bpm=128, key="A minor")
intro = song.section("LINE", 4)
build = song.section("OPENING", 8)
peak = song.section("WOW", 8)

kit = song.track("909", "drum2", "909-punch", volume=0.8,
                 fx=[fx("comp2", "dry-drum-punch")])
acid = song.track("SQUELCH", "acid", "classic-squelch", volume=0.75,
                  fx=[fx("delay2", "dotted-eighth-lead-120", mix=0.14)],
                  params=dict(cutoff=140, resonance=0.55, env_mod=0.45, decay=0.4))
sq = song.track("SQUARE", "acid", "square-bounce", volume=0.5, pan=0.2,
                fx=[fx("verb2", mix=0.12)],
                params=dict(mode="WET", resonance=0.85, cutoff=420, tune=12))

song.master(fx=[fx("comp2", "gentle-bus-glue"), fx("limiter2", gain=4, ceil=-1)])

# accents (!) and slides (~) make the line
LINE = ("A1! . A1 A2~ A1 . C2! A1 . A1 G1~ A1 . A2! . E2 |"
        " A1! . A1 A2~ A1 . C2! A1 . D2~ E2 . G2! . A1 A1")
for sec in (intro, build, peak):
    acid.clip(sec).seq(LINE, gate=0.5).repeat(8)
sq.clip(peak).seq(LINE, gate=0.45).repeat(8)

for sec in (build, peak):
    kit.clip(sec).drums({"kick": "x...x...x...x...",
                         "clap": "....x.......x...",
                         "ch": "x.x.x.x.x.x.x.x.",
                         "oh": "..x...x...x...x."}, bars=8)

# the 303 move: open CUT and push RES by hand
b0 = build.start * 4
acid.ramp("cutoff", b0, b0 + 32, 140, 900, tension=-0.3)
acid.ramp("resonance", b0, b0 + 32, 0.55, 0.9)
acid.ramp("env_mod", b0, b0 + 32, 0.45, 0.7)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render()
