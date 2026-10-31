"""Convolver demo — what CONVO and the host convolver are for (docs/46).

Generate: PYTHONPATH=tools python3 songs/convolver_demo.py
Render:   ... --render

One four-bar phrase four times, each through its own return: DRY, then
verb2's big hall for reference, then CONVO on its synthetic hall IR, then
CONVO with a bowed cymbal as the IR, where every note swells through the
cymbal: convolution with a sound, not only a room. Each phrase ends on a
short chord and a bar of rest, so the tail is heard on its own.
"""
import argparse
from slabkit import Song, fx

song = Song("Convolver Demo", bpm=84, key="D major")
names = ("DRY", "VERB2", "HALL", "CYMBAL")
sections = [song.section(n, 4) for n in names]
spaces = {
    "VERB2": fx("verb2", "big-hall", mix=1.0),
    "HALL": fx("convo", "hall", mix=1.0),
    "CYMBAL": fx("convo", "bowed-cymbal", mix=1.0),
}

# chord stabs in bars 1-3, a short one to end on, then a bar of rest
CHORDS = (((62, 66, 69), 0), ((59, 62, 66), 4), ((55, 59, 62), 8), ((57, 61, 64), 11))
BELL = "r:2 A5:.5 F#5 E5:1 | r:2 F#5:.5 D5 B4:1 | r:2 D5:.5 B4 A4:1 | r:4"

song.master(fx=[fx("limiter2", gain=8, ceil=-1)])
for sec in sections:
    keys = song.track(f"KEYS {sec.name}", "rhodes", "mellow", volume=0.7, pan=-0.15)
    bell = song.track(f"BELL {sec.name}", "rhodes", "tine-bell", volume=0.5, pan=0.2)
    clap = song.track(f"CLAP {sec.name}", "drum2", "polite-studio-kit", volume=0.55)
    k = keys.clip(sec)
    for pitches, at in CHORDS:
        k.chord(pitches, at, 0.5 if at == 11 else 1.5, vel=84)
    bell.clip(sec).melody(BELL, vel=88, gate=0.6)
    clap.clip(sec).drums({"clap": "....x.......x..." * 3 + "................"}, bars=4)
    if sec.name in spaces:
        room = song.bus(sec.name, fx=[spaces[sec.name]])
        keys.send(room, -4)
        bell.send(room, -6)
        clap.send(room, -8)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render()
