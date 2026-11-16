"""Magnet Zither and Tape Echo demo (docs/35).

Generate: PYTHONPATH=tools python3 songs/zither_demo.py
Render:   ... --render

DISCS: the zither as an instrument on a track with no notes, two discs on
the minor tuning; disc A's SPIN sweeps from D1 up a fifth and back, so
the bloom walks through the strings.  PLUCKS: the same strings plucked
from the keys over the drone, into the tape echo (heads 2 and 4).  KEYS:
a Rhodes in D minor with the zither as an insert, the strings that agree
with each chord answering it, and a four-head SWELL on a send.  HOLD: the
echo freezes what the plucks left on the tape and the motor drops to half
speed and comes back.  BELL: a tubular bell far off, from the third bar,
a hit every few bars, on the chord.
"""
import argparse
from slabkit import Song, fx

song = Song("Zither Demo", bpm=72, key="D minor")
discs = song.section("DISCS", 8)
plucks = song.section("PLUCKS", 8)
keys_s = song.section("KEYS", 8)
hold = song.section("HOLD", 8)

# the tape on the master is the one set by ear in the app
song.master(fx=[fx("tape2", "vhs-hifi-dub"), fx("limiter2", gain=4, ceil=-1)])
hall = song.bus("HALL", fx=[fx("verb2", "velvet-hall", mix=1.0)])
swell = song.bus("SWELL", fx=[fx("echo2", "four-head-swell", mix=1.0)])

# the drone: no notes at all, the discs do the work
drone = song.track("DISCS", "zither", "two-discs", volume=0.8)
drone.send(hall, -8)
drone.automate("volume", (0, 0.8), (30, 0.8), (34, 0.3), (96, 0.3), (112, 0.45))
drone.automate("a-spin", (0, 36.71), (16, 55.0), (32, 36.71), (96, 36.71), (112, 49.0), (128, 36.71))
drone.automate("b-across", (0, 0.8), (16, 0.45), (32, 0.8), (96, 0.8), (128, 0.5))

# the same strings, plucked, through the tape
pl = song.track("PLUCKS", "zither", "plucked-minor", volume=0.9, params={"out": 10.5, "pluck": 0.5, "tone": 0.48},  # softer pick than the preset
                fx=[fx("echo2", "drum-echo", sync=1, div="3/4", repeat=0.6, mix=0.4)])
pl.send(hall, -12)
PHRASE = "D3:1 A3:1 D4:1 F4:1 A4:2 F4:1 D4:1  C4:1 G3:1 C4:1 E4:1 G4:2 E4:1 C4:1"
pl.clip(plucks).melody(PHRASE + "  " + PHRASE, vel=104)
pl.clip(hold).melody("D3:1 A3:1 D4:1 F4:1 A4:2 D5:2", vel=110)
# HOLD: catch the phrase on the tape, then lean on the motor
pl.automate("fx0:freeze", (0, 0, "hold"), (104, 1, "hold"))
pl.automate("fx0:speed", (0, 1.0, "hold"), (112, 1.0), (113, 0.5), (120, 0.5), (121, 1.0))

CHORDS = "Dm:4 Bb:4 F:4 C:4 Dm:4 Gm:4 A7sus4:4 A7:4"
RHYTHM = "x.......x.x....."
keys = song.track("KEYS", "rhodes", "mellow", volume=0.45, pan=-0.1,
                  fx=[fx("zitherfx", "sympathetic-strings", tuning="MINOR", mix=0.45)])
keys.send(hall, -10)
keys.send(swell, -9)
keys.clip(keys_s).chords(CHORDS, RHYTHM, near=62, vel=92)

# a tubular bell a long way off: little direct sound, the top rolled away
# by the air, nearly all of it hall, narrow, and no gap before the room
bell = song.track("BELL", "fm86", "slab/tubular-bells", volume=1.0, params={"volume": 1.0},
                  fx=[fx("eq2", hpf_hz=180, hs_hz=2500, hs_db=-12),
                      fx("verb2", "cathedral", predelay=0.001, tone=3200, width=0.6, mix=0.8)])
bell.clip(discs).melody("r:8 D4:8 r:4 A4:8 r:4", vel=84)
bell.clip(plucks).melody("D4:8 r:4 G4:8 r:4 A4:8", vel=84)
bell.clip(keys_s).melody("D4:6 r:2 C5:6 r:2 D4:6 r:2 A4:8", vel=88)
bell.clip(hold).melody("D4:8 r:8 A3:8 D4:8", vel=80)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render(stems=True)
