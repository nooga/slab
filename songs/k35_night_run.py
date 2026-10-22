"""K35 Night Run — a 122 BPM listening test for the SM-24 Mono's K35/OTA filters.

Generate: PYTHONPATH=tools python3 songs/k35_night_run.py
Render:   ... --render

The bass plays alone for four bars, then the drums come in and the K35's
CUT opens over eight bars while PEAK climbs.  The last eight bars add an
OTA lead and the k35-scream lead, both filters peaked.
"""
import argparse
from slabkit import Song, fx

song = Song("K35 Night Run", bpm=122, key="A minor")
intro = song.section("BASS ALONE", 4)
groove = song.section("OPENING UP", 8)
scream = song.section("SCREAM", 8)

kit = song.track("DRUMS", "drum2", "tough-night-kit", volume=0.8,
                 fx=[fx("comp2", "dry-drum-punch")])
bass = song.track("K35 BASS", "ms20", "k35-round-bass", volume=0.62,
                  fx=[fx("eq2", hpf_on="ON", hpf_hz=34)],
                  params=dict(lpf_mode="K35", cutoff=380, resonance=1.0,
                              drive=1.6, env_amount=2.6, filter_decay=0.18,
                              filter_sustain=0.05, age=0.3))
lead = song.track("OTA LEAD", "ms20", "ota-singing-lead", volume=0.75, pan=-0.15,
                  fx=[fx("delay2", mix=0.22)])
scr = song.track("K35 SCREAM", "ms20", "k35-scream", volume=0.7, pan=0.15,
                 fx=[fx("verb2", mix=0.18)])

song.master(fx=[fx("comp2", "gentle-bus-glue"), fx("limiter2", gain=5, ceil=-1)])

LINE = ("A1! . A1 A2 . A1 G1~ A1 . A1 C2 . A1! . E2 D2 |"
        " A1! . A1 A2 . A1 G1~ A1 . C2 . E2! . G2 . E2")
for sec in (intro, groove, scream):
    bass.clip(sec).seq(LINE, gate=0.55).repeat(8)

for sec in (groove, scream):
    kit.clip(sec).drums({"kick": "x...x...x...x...",
                         "snare": "....x.......x...",
                         "ch": "..x...x...x...x.",
                         "oh": "..............x."}, bars=8)

# CUT opens and PEAK climbs over the groove; the scream section keeps them up
g0 = groove.start * 4
bass.ramp("cutoff", g0, g0 + 32, 380, 1400, tension=-0.3)
bass.ramp("resonance", g0, g0 + 32, 1.0, 1.55)

lead.clip(scream).melody("E5:1.5 D5:.5 C5:1 B4:1 | A4:2 r:1 C5:1 | "
                         "E5:1.5 G5:.5 E5:1 D5:1 | C5:3 r:1")
scr.clip(scream, bars=4, at_bar=4).melody("A5:2 G5:1 E5:1 | A5:3 r:1")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render()
