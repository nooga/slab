"""MS-20 Patch Bay — a 118 BPM tour of the SM-24 Mono's patch cords.

Generate: PYTHONPATH=tools python3 songs/ms20_patch_bay.py
Render:   ... --render

Every part is an SM-24 Mono with cords in (PATCH page):
  METAL    VCO2 a fifth up into LPF CUT at audio rate   patch-fm-metal-bass
  BUBBLES  S&H on LPF CUT, clocked by the MG             patch-sh-bubbles
  GROWL    VCA OUT back into FLT IN                      patch-feedback-growl
  VOWEL    FENV on HPF CUT, both filters peaked          patch-vowel-sweep
  LEAD     KBD tracking + MG vibrato                     patch-tracking-lead
"""
import argparse
from slabkit import Song, fx

song = Song("MS-20 Patch Bay", bpm=118, key="D minor")
metal = song.section("METAL", 4)
bubbles = song.section("BUBBLES", 4)
growl = song.section("GROWL", 4)
vowel = song.section("VOWEL", 8)

kit = song.track("DRUMS", "drum2", "dry-punch-kit", volume=0.75,
                 fx=[fx("comp2", "dry-drum-punch")])
bass = song.track("METAL BASS", "ms20", "patch-fm-metal-bass", volume=0.7,
                  fx=[fx("eq2", hpf_on="ON", hpf_hz=30)])
bub = song.track("BUBBLES", "ms20", "patch-sh-bubbles", volume=0.55, pan=-0.3,
                 fx=[fx("delay2", mix=0.25)])
grr = song.track("GROWL", "ms20", "patch-feedback-growl", volume=0.55, pan=0.25,
                 fx=[fx("verb2", mix=0.15)])
vow = song.track("VOWEL", "ms20", "patch-vowel-sweep", volume=0.6, pan=0.15,
                 fx=[fx("delay2", mix=0.2)])
lead = song.track("LEAD", "ms20", "patch-tracking-lead", volume=0.6, pan=-0.1,
                  fx=[fx("verb2", mix=0.2)])

song.master(fx=[fx("comp2", "gentle-bus-glue"), fx("limiter2", gain=4, ceil=-1)])

LINE = "D1! . D1 D2 . D1 F1 . D1! . C2 . A1 . G1 F1"
for sec in (metal, bubbles, growl, vowel):
    bass.clip(sec).seq(LINE, gate=0.5).repeat(4 if sec is not vowel else 8)
    kit.clip(sec).drums({"kick": "x...x...x...x...",
                         "snare": "....x.......x...",
                         "ch": "x.xxx.x.x.xxx.x.",
                         "oh": "......x.......x."}, bars=sec.bars)

# long notes: the S&H bubbles under them
for sec in (bubbles, growl, vowel):
    bub.clip(sec).melody("D4:4 | F4:4 | A3:4 | C4:4")
# the feedback loop swells on held notes
grr.clip(growl).melody("D3:2 F3:2 | A3:3 G3:1 | F3:2 E3:2 | D3:4")
# talking stabs, then the tracking lead over them
vow.clip(vowel).seq("D3 . . D3 . . F3 . . . A3 . . . C4 . |"
                    " D3 . . D3 . . F3 . . . G3 . . . E3 .", gate=0.6).repeat(4)
lead.clip(vowel, bars=4, at_bar=4).melody("A4:1.5 G4:.5 F4:1 E4:1 | D4:2 F4:1 A4:1 | "
                                          "C5:1.5 A4:.5 G4:1 F4:1 | E4:3 r:1")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", action="store_true")
    a = ap.parse_args()
    song.save()
    if a.render:
        song.render()
