"""Fretwire slap demo: the thumb, the pop, then a line.

Generate: PYTHONPATH=tools python3 songs/slap_demo.py
Render:   ... --render

THUMB: thumbed notes alone, soft to hard.  POP: popped notes alone.
GROOVE: one `slap` track playing both; the preset pops E2 and up and
thumbs the rest, so the line is written as plain notes.  The soft
notes [@60] are ghosts.
"""
import argparse
from slabkit import Song, fx

song = Song("Slap Demo", bpm=100, key="E minor")
thumb = song.section("THUMB", 4)
pop = song.section("POP", 4)
groove = song.section("GROOVE", 8)

song.master(fx=[fx("limiter2", gain=4, ceil=-1)])

bass = song.track("SLAP", "bass", "slap", volume=0.9)
bass.clip(thumb).melody("E1:2@50 E1:2@80 E1:2@105 E1:2@127 A1:2@110 D2:2@110 G1:1@120 A1:1@120 B1:1@120 D2:1@120")
bass.clip(pop).melody("E2:2@50 E2:2@80 E2:2@105 E2:2@127 G2:2@110 D3:2@110 E2:1@120 G2:1@120 A2:1@120 D3:1@120")
A = ("E1:0.5@118 E2:0.25@112 r:0.5 G1:0.25@100 A1:0.25@110 r:0.25 "
     "E1:0.25@118 E1:0.25@60 D3:0.25@115 r:0.5 E2:0.25@108 G2:0.25@112 r:0.25 ")
B = ("A1:0.5@118 A2:0.25@112 r:0.5 A1:0.25@96 B1:0.25@104 r:0.25 "
     "D2:0.25@116 D2:0.25@60 D3:0.25@116 r:0.5 E2:0.25@104 F#2:0.25@112 G2:0.25@116 ")
bass.clip(groove).melody(A + A + B + A + A + A + B + B)

drums = song.track("DRUMS", "drum2", volume=0.7)
drums.clip(groove).drums({
    "kick":  "x.....x...x.....",
    "snare": "....X.......X..o",
    "ch":    "x.x.x.x.x.x.x.x.",
})

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render(stems=True)
