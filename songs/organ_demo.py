"""Tonewheel Organ and Rotary Speaker demo (docs/52).

Generate: PYTHONPATH=tools python3 songs/organ_demo.py
Render:   ... --render

CHORALE: slow chords on the first three drawbars, the rotors slow.
LEAD: a percussion lead over it; the plink is on detached notes only.
FAST: the comp's SPEED goes to FAST on the downbeat (the horn gets there
in a second, the drum in four) and the upper drawbars are pulled out over
four bars.  BRAKE: back to SLOW, the drawbars pushed in, a last chord.
"""
import argparse
from slabkit import Song, fx

song = Song("Organ Demo", bpm=92, key="G minor")
chorale = song.section("CHORALE", 8)
lead_s = song.section("LEAD", 8)
fast = song.section("FAST", 8)
brake = song.section("BRAKE", 4)

song.master(fx=[fx("limiter2", gain=7, ceil=-1)])
hall = song.bus("HALL", fx=[fx("verb2", "velvet-hall", mix=1.0)])

CHORDS = "Gm:4 Eb:4 Bb:4 F:4 Gm:4 Cm:4 D7sus4:4 D7:4"
comp = song.track("COMP", "organ", "gospel", volume=0.7, pan=-0.1,
                  params={"d16": 5, "d513": 3},  # chords: less under the key
                  fx=[fx("rotary", "slow-chorale", drive=0.25)])
comp.send(hall, -14)
comp.clip(chorale).chords(CHORDS, "x...............", near=65, vel=70)
comp.clip(lead_s).chords(CHORDS, "x.......x.x.....", near=65, vel=90)
comp.clip(fast).chords(CHORDS, "x..x..x.x..x..x.", near=67, vel=110)
comp.clip(brake).chords("Gm:16", "x...............", near=65, vel=60)
# the performance: SPEED, and the upper drawbars
comp.automate("fx0:speed", (0, 1, "hold"), (64, 2, "hold"), (96, 1, "hold"))
comp.automate("d4", (0, 0), (64, 0), (80, 8), (96, 8), (104, 0))
comp.automate("d223", (0, 0), (68, 0), (84, 6), (96, 6), (104, 0))
comp.automate("d2", (0, 0), (72, 0), (88, 8), (96, 8), (104, 0))

lead = song.track("LEAD", "organ", "jazz-trio", volume=0.9, pan=0.15, params={"volume": 8},
                  fx=[fx("rotary", "slow-chorale", mic=0.2)])
lead.send(hall, -12)
LINE = ("r:1 D5:0.5 F5:0.5 G5:1 r:0.5 Bb5:0.5 A5:1 G5:1 F5:0.5 G5:1.5 "
        "r:1 Bb4:0.5 D5:0.5 Eb5:1 r:0.5 G5:0.5 F5:1 D5:1 C5:0.5 D5:1.5 ")
lead.clip(lead_s).melody(LINE + LINE, vel=112)
lead.clip(fast).melody("G5:0.5 Bb5:0.5 D6:1 C6:0.5 Bb5:0.5 G5:1 " * 8, vel=118)
lead.automate("fx0:speed", (0, 1, "hold"), (64, 2, "hold"), (96, 1, "hold"))

bass = song.track("PEDAL", "organ", "bass-pedal", volume=0.7)
bass.clip(chorale).melody("G1:4 Eb2:4 Bb1:4 F1:4 G1:4 C2:4 D2:4 D2:4", vel=80)
WALK = "G1:1 Bb1:1 D2:1 Bb1:1 Eb2:1 G1:1 Bb1:1 Eb2:1 Bb1:1 D2:1 F2:1 D2:1 F1:1 A1:1 C2:1 A1:1 "
WALK2 = "G1:1 Bb1:1 D2:1 Bb1:1 C2:1 Eb2:1 G2:1 Eb2:1 D2:1 G2:1 A2:1 G2:1 D2:1 F#2:1 A2:1 C3:1 "
bass.clip(lead_s).melody(WALK + WALK2, vel=96)
bass.clip(fast).melody(WALK + WALK2, vel=104)
bass.clip(brake).melody("G1:16", vel=80)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render(stems=True)
