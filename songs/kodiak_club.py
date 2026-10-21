"""Kodiak Club: a French-touch electro demo for the harsh pack (docs/43).
Original material in the manner of the Ed Banger records: no riff
borrowed.

118 BPM, F# minor. The bass is the Cross Bass rig on a Juno saw: a
clean sub under a lane cut at 250 Hz, crushed to 12 bits, overdriven
into a Brit 4x12 and slammed. It plays held eighths, not clicks. A slap
bass plays the chopped funk part through a Grinder RAT. The drums are
hot: a 909-style kit smushed and clipped, with the bass and stabs
breathing around the kick.

Registers are set for what sounds, not what is written (docs/33 §Check
where the bass really sounds): the Junos run at 8', so the bass's
fundamental sits at 73-92 Hz with its sub at 37-46 Hz, and Kodiak's at
147-185 Hz with the octaver's sub an octave under.
In the drops a Fretwire guitar plays an Octavia riff through the
Octavia Portal rig, and a second Juno through Kodiak makes it big and
gnarly. The builds open the bass's DIRT and CRUSH macros.

    PYTHONPATH=tools python3 songs/kodiak_club.py --render
    zig-out/bin/slab songs/kodiak_club.slab
"""
from slabkit import Song, fx

song = Song("Kodiak Club", bpm=118, key="F# minor")

intro = song.section("intro", 8)
verse = song.section("verse", 16)
build = song.section("build", 4)
drop = song.section("drop", 16)
brk = song.section("break", 8)
build2 = song.section("build2", 4)
drop2 = song.section("drop2", 16)
outro = song.section("outro", 4)

PROG = "F#m D E F#m"
BREAK_PROG = "Bm D A E"
BEAT = {"kick": "x...x...x...x..."}
DRUMS = {"snare": "....x.......x...", "clap": "....x.......x..o",
         "ch": "x.xxx.xxx.xxx.xx", "oh": "..x...x...x...x."}

# ── drums: kick on its own track so the rest can duck to it ─────────────
kick = song.track("KICK", "drum2", "909-punch", volume=0.65,
                  fx=[fx("eq2", ls_hz=70, ls_db=-5), fx("grind2", "soft-clipper", drive=10)])
drums = song.track("DRUMS", "drum2", "909-punch", volume=0.9,
                   fx=[fx("char2", "smush-slam"), fx("grind2", "soft-clipper", drive=8)])
for sec in (verse, drop, drop2):
    kick.clip(sec).drums(BEAT)
    drums.clip(sec).drums(DRUMS)
k = kick.clip(intro)
k.drums(BEAT, bars=8)
drums.clip(intro).drums({"ch": "x.x.x.x.x.x.x.x."}, at=16, bars=4)
for b in (build, build2):
    kick.clip(b).drums(BEAT, bars=2)
    d = drums.clip(b)
    d.drums({"snare": "x...x...x...x..."}, bars=2)
    d.drums({"snare": "x.x.x.x.x.x.x.x."}, at=8, bars=1)
    d.drums({"snare": "xxxxxxxxxxxxxxXX"}, at=12, bars=1)
kick.clip(outro).drums(BEAT)

# kick ducking, kept gentle so the parts breathe rather than chop
def duck():
    return fx("comp2", "pump", key=kick, ratio=2.5, thresh=-20, rel=0.16, makeup=2.5)


# ── the synth bass: Juno saw at 8' into Cross Bass ──────────────────────
bass = song.track("BASS", "juno2", "juno-bass", volume=1.1,
                  params={"range": "8'", "sub": 0.35, "dec": 0.4, "sus": 0.7, "rel": 0.08, "cutoff": 1100},
                  fx=[fx("fxrack", "harsh/cross-bass", rk_m1=0.45, rk_m2=0.25, rk_m4=0.35), duck()])
for sec in (verse, drop, drop2):
    bass.clip(sec).bass(PROG, "x--xo-x-x--xo-x-", octave=2, vel=104, gate=0.95)
for b in (build, build2):
    bass.clip(b).bass(PROG, "x-x-x-x-x-x-x-x-", octave=2, vel=100, gate=0.9)
bass.clip(outro).bass("F#m", "x---------------", octave=2)
# the builds open the dirt and the crush; each drop starts wide open
for b, d in ((build, drop), (build2, drop2)):
    bass.automate("fx0:rk-m1", (b.start, 0.45), (b.end, 0.9, "curve", 0.4), (d.start + 0.5, 0.6))
    bass.automate("fx0:rk-m2", (b.start, 0.25), (b.end, 0.75), (d.start + 0.5, 0.35))

# ── slap bass, the chopped part: Grinder RAT, lows left to the synth ───
slap = song.track("SLAP", "bass", "slap", volume=0.8, pan=-0.12,
                  fx=[fx("eq2", hpf_on="ON", hpf_hz=180),
                      fx("grind2", "rat", drive=22)])
slap.clip(intro).bass(PROG, "x..o.x..x.o..xo.", octave=2, vel=110, at=16)
for sec in (verse, brk, drop, drop2):
    p = BREAK_PROG if sec is brk else PROG
    slap.clip(sec).bass(p, "x..o.x..x.o..xo.", octave=2, vel=112)

# ── stabs: Juno brass through the Phantom Stack, on the offbeats ────────
stabs = song.track("STABS", "juno2", "brass-stab", volume=0.9, pan=0.15,
                   params={"range": "8'", "sus": 0.55, "rel": 0.22},
                   fx=[fx("fxrack", "harsh/phantom-stack", rk_m1=0.35),
                       fx("eq2", hpf_on="ON", hpf_hz=250),
                       fx("verb2", "chamber", mix=0.12),
                       duck()])
for sec in (verse, drop, drop2):
    stabs.clip(sec).chords(PROG, "..x-..x-..x-.x-.", near=66, voices=3, vel=96, gate=0.95)

# ── the drop guitar: Octavia riff through the Octavia Portal ───────────
gtr = song.track("GTR", "guitar", "bridge", volume=0.5, pan=0.2,
                 fx=[fx("fxrack", "harsh/octavia-portal")])
RIFF = "F#4 . F#4 A4 . F#4 C#5 . B4 . A4 . F#4 . E4 ."
for sec in (drop, drop2):
    gtr.clip(sec).seq(RIFF, step=0.25, gate=0.8, vel=100)
# the wah opens over each drop
for d in (drop, drop2):
    gtr.automate("fx0:rk-m2", (d.start, 0.3), (d.end - 4, 1.0, "curve", -0.3), (d.end, 0.5))

# ── Kodiak: a second Juno an octave over the bass, big and gnarly ─────
gnarl = song.track("KODIAK", "juno2", "juno-bass", volume=0.8,
                   params={"range": "8'", "sus": 0.8, "cutoff": 1400},
                   fx=[fx("fxrack", "harsh/kodiak", rk_m1=0.0, rk_m2=0.55),
                       fx("eq2", hpf_on="ON", hpf_hz=160)])
for sec in (drop, drop2):
    gnarl.clip(sec).bass(PROG, "x-----x-x-----x-", octave=3, vel=100)

# ── break: strings over the chopped slap, no kick ──────────────────────
strings = song.track("STRINGS", "juno2", "strings", volume=0.45,
                     fx=[fx("chorus2", mode="I+II"), fx("verb2", "long-melancholy-verb", mix=0.3)])
strings.clip(brk).chords(BREAK_PROG, near=64, voices=4, vel=80)
strings.clip(build2).chords("F#m", near=64, voices=4, vel=70)

song.master(fx=[fx("bus2"), fx("limiter2", gain=7, ceil=-1)])

song.save()

if __name__ == "__main__":
    import sys
    if "--render" in sys.argv:
        song.render(stems=True)
