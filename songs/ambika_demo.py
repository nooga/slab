"""Ambika Demo — thirty seconds, every part on the Ambika: a kick, a snare and
a cowbell from the golden card's drum programs, a bass, a pad, an arpeggio,
a lead and a bell.  15 bars at 120 BPM.

    PYTHONPATH=tools python3 songs/ambika_demo.py --render [--stems]
    zig-out/bin/slab songs/ambika_demo.slab
"""
import sys

from slabkit import Song, fx

song = Song("Ambika Demo", bpm=120, key="A minor")
intro = song.section("intro", 2)
groove = song.section("groove", 6)
peak = song.section("peak", 6)
outro = song.section("outro", 1)

verb = fx("verb2", "bright-plate", mix=0.25)
kick = song.track("KICK", "ambika", "A/123-kicker", volume=0.55)
snare = song.track("SNARE", "ambika", "A/124-snare", volume=0.6, fx=[fx("verb2", "bright-plate", mix=0.12)])
bell = song.track("COWBELL", "ambika", "A/126-cowbell", volume=0.6, pan=0.25)
bass = song.track("BASS", "ambika", "A/026-fatbass", volume=0.4)
pad = song.track("PAD", "ambika", "A/058-pwm-string", volume=0.55, pan=-0.2, fx=[verb])
arp = song.track("ARP", "ambika", "A/078-arp-synth", volume=1.0, pan=0.3, fx=[verb])
lead = song.track("LEAD", "ambika", "F/022-finalead", volume=0.8, fx=[verb])
keys = song.track("BELLS", "ambika", "A/045-belpiano", volume=1.0, pan=-0.35, fx=[verb])
song.master(fx=[fx("comp2", "gentle-bus-glue"), fx("limiter2", gain=2, ceil=-1)])

PROG = "Am F C G"
LONG = "Am:4 F:4 C:4 G:4"

# intro: pad and a bell, the bass joins on the second bar
pad.clip(intro).chords("Am:4 F:4", "x...............", near=60)
keys.clip(intro).melody("E5:1 A5:1 C6:2 | B5:1 A5:1 C6:2")
bass.clip(intro, at_bar=1, bars=1).bass("F", "x.......x.......", octave=3)

# groove: drums, bass, arp
for sec in (groove, peak):
    k = kick.clip(sec)
    k.seq("A3 . . . A3 . . . A3 . . . A3 . . .", step=0.25)
    s = snare.clip(sec)
    s.seq(". . . . C3 . . . . . . . C3 . . .", step=0.25)
    c = bell.clip(sec)
    c.seq(". . C4 . . . C4 . . . C4 . . . C4 C4", step=0.25, vel=70)
    bass.clip(sec).bass(PROG, "x.xo..x.x.xo.5x.", octave=3)
    pad.clip(sec).chords(LONG, "x...............", near=60)
    arp.clip(sec).arp(PROG, "updown", rate=0.25, octave=4)
keys.clip(groove).melody("E5:.5 r:.5 A5:1 r:1 C6:1 | G5:.5 r:.5 B5:1 r:1 D6:1 | E6:1 C6:1 A5:2 | G5:2 B5:2")
lead.clip(peak).melody("A5:1.5 C6:.5 E6:1 D6:1 | C6:1.5 A5:.5 F5:2 | E5:1.5 G5:.5 C6:1 E6:1 | D6:2 B5:2 | "
                       "C6:1.5 E6:.5 D6:1 B5:1 | A5:4")
keys.clip(peak).melody("A4:2 E5:2 | F4:2 C5:2 | C5:2 G5:2 | G4:2 D5:2 | A4:2 E5:2 | F4:2 C5:2")

# outro: one hit and a ring-out
pad.clip(outro).chords("Am:4", "x...............", near=60)
bass.clip(outro).bass("Am", "x...............", octave=3)
keys.clip(outro).melody("A5:4")

if __name__ == "__main__":
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
