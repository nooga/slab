"""Rhodes E-Piano demo: the same chords soft, medium and hard, then a line.

Generate: PYTHONPATH=tools python3 songs/rhodes_demo.py
Render:   ... --render

SOFT, MEDIUM, HARD: one progression at velocity 40, 80 and 120, dry: the
tone goes from round to bark with touch alone.  KEYS: single notes up the
keyboard at full velocity.  TUNE: comping and a line, with a little room.
"""
import argparse
from slabkit import Song, fx

song = Song("Rhodes Demo", bpm=84, key="D minor")
soft = song.section("SOFT", 4)
medium = song.section("MEDIUM", 4)
hard = song.section("HARD", 4)
keys = song.section("KEYS", 4)
tune = song.section("TUNE", 8)

song.master(fx=[fx("limiter2", gain=5, ceil=-1)])
room = song.bus("ROOM", fx=[fx("verb2", "velvet-hall", mix=1.0)])

CH = "Dm9:4 G9:4 Cmaj9:4 A7:4"
ep = song.track("RHODES", "rhodes", "default", volume=0.9)
ep.clip(soft).chords(CH, "x...............", near=60, vel=40)
ep.clip(medium).chords(CH, "x.......x.......", near=60, vel=80)
ep.clip(hard).chords(CH, "x..x..x.....x...", near=60, vel=120)
ep.clip(keys).melody("F1:2 E2:2 A2:2 D3:2 G3:2 D4:2 F4:1 B4:1 E5:1 A5:1", vel=120)

comp = song.track("COMP", "rhodes", "default", volume=0.8, pan=-0.15)
comp.send(room, -16)
comp.clip(tune).chords(CH + " " + CH, "x..x....x.x.....", near=58, vel=92)
lead = song.track("LEAD", "rhodes", "bright", volume=0.8, pan=0.15)
lead.send(room, -14)
LINE = ("r:1 A4:0.5@100 C5:0.5@108 E5:1@118 D5:0.5@96 C5:0.5@90 A4:1@104 r:1 G4:0.5@96 A4:0.5@104 B4:1@112 "
        "D5:1.5@120 r:0.5 E5:0.5@110 D5:0.5@100 B4:1@96 G4:1@88 r:1 E4:0.5@96 G4:0.5@104 C#5:1@118 A4:2@90 ")
lead.clip(tune).melody(LINE + LINE)
bass = song.track("BASS", "bass", "default", volume=0.8)
bass.clip(tune).melody("D2:3 A1:1 G1:3 D2:1 C2:3 G1:1 A1:2 E2:1 A1:1 " * 2, vel=96)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render(stems=True)
