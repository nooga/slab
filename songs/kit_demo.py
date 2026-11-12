"""Skinwork Kit demo (docs/41): one hit of each piece, then a beat.

Generate: PYTHONPATH=tools python3 songs/kit_demo.py
Render:   ... --render
"""
import argparse
from slabkit import Song, fx

song = Song("Kit Demo", bpm=96, key="C major")
pieces = song.section("PIECES", 6)
beat = song.section("BEAT", 8)
fill = song.section("FILL", 2)

song.master(fx=[fx("limiter2", gain=7, ceil=-1)])
room = song.bus("ROOM", fx=[fx("verb2", "velvet-hall", mix=1.0)])
kit = song.track("KIT", "kit", "default", volume=0.9)
kit.send(room, -18)

# kick snare side toms hats crash ride bell, two beats each
kit.clip(pieces).melody("C2:2 D2:2 C#2:2 F2:2 A2:2 C3:2 F#2:2 G#2:2 A#2:2 C#3:2 D#3:2 F3:2", vel=108)
kit.clip(beat).drums({
    "kick":  "x.....x.x.......x.....x.x..x....",
    "snare": "....X..o....X.......X..o....X...",
    "ch":    "x.x.x.x.x.x.x.x.x.x.x.x.x.x.x...",
    "oh":    "..............................x.",
    "ride":  "................................",
}, bars=4)
kit.clip(beat).drums({
    "kick":  "x.....x.x.......x.....x.x..x....",
    "snare": "....X..o....X.......X..o....X...",
    "ride":  "x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.",
    "bell":  "x.......x.......x.......x.......",
    "crash": "x...............................",
}, at=16, bars=4)
kit.clip(fill).melody("D2:0.5 D2:0.5 C3:0.5 C3:0.5 A2:0.5 A2:0.5 F2:0.5 F2:0.5 C#3:4", vel=116)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render(stems=True)
