"""Broken Glass — an intro in the manner of late-80s London digital pop
(Johnny Hates Jazz's "Shattered Dreams" was the reference). Original
material.

The sound is "no microphone": every part direct-in, nothing through a
room. Transients land in a millisecond, the top octaves are full, notes
stop dead, and the only space is what was printed on purpose: a short
bright plate on the keys (RAK-era records printed their Lexicons) and
the snare's gated room. The master is left nearly unlimited so the hits
keep their crest.

Measured on the reference intro (bars 1-8): 4-8 kHz octave -13 dB of
the whole, 8-16 kHz -17 dB, crest 16.6 dB, side/mid -10 dB, the bass
stopping hard mid-bar. Those are the targets, with more 125-500 Hz
weight than the reference by request.

121 BPM, D minor. Bars 1-2 piano and bass alone; the hats and the lead
enter at bar 3, the pad at bar 5, the kit at bar 7; bar 8 turns on A to
land the downbeat of bar 9.

Groups: KEYS (piano, bite, sparkle pair, tines, pad), LEADS (lead, glass), BASS (synth + DX),
DRUMS (kick, snare, hats, perc and the gated room).

    PYTHONPATH=tools python3 songs/broken_glass.py --render
    zig-out/bin/slab songs/broken_glass.slab
"""
from slabkit import Song, fx

song = Song("Broken Glass", bpm=121, key="D minor")

intro = song.section("intro", 8)
land = song.section("land", 1)

PROG = "Dm Am Bb C Dm Am Bb C:2 A:2"

# ── the hook ───────────────────────────────────────────────────────────
# Falling glass: each bar starts high and steps down, the fourth bar
# climbs back; bar 8 lands on the leading tone for the A chord.
HOOK = """
r:.5 A5:.5 G5:.5 A5:.5 F5:1 E5:1 | r:.5 E5:.5 D5:.5 E5:.5 C5:1 A4:1
r:.5 D5:.5 C5:.5 D5:.5 F5:1 D5:1 | r:.5 E5:.5 F5:.5 G5:.5 A5:2
r:.5 A5:.5 G5:.5 A5:.5 F5:1 E5:1 | r:.5 E5:.5 D5:.5 C5:.5 C#5:.5 E5:1.5
"""

# ── groups ─────────────────────────────────────────────────────────────
keys_bus = song.bus("KEYS", volume=1.0)
lead_bus = song.bus("LEADS", volume=1.0)
bass_bus = song.bus("BASS", volume=1.0)
# the drum bus: bus2's SSL-style glue, 10 ms lets the stick through
drums = song.bus("DRUMS", volume=1.1, fx=[fx("bus2", "drum-bus", thresh=-22, makeup=4.0)])

# ── keys ───────────────────────────────────────────────────────────────
# slab/piano: an FM grand with a fast attack and a bright sustain. Pulsing 8ths, accented 3-3-2, voiced
# low enough to carry the 125-500 Hz weight; a DI chorus spreads it.
piano = song.track("PIANO", "fm86", "slab/piano", volume=0.95, pan=-0.65, output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, ls_hz=240, ls_db=3, p1_hz=480, p1_db=-3, p1_q=1.4, p2_hz=4500, p2_db=4, hs_hz=10000, hs_db=2),
    fx("chorus2", "wide-keys", mix=0.5),
    fx("verb2", "bright-plate", decay=11.89, predelay=0.018, mix=0.14, damp=9000),
])
# the bite: the clav doubling the stabs on the other side, the click
# the piano lacks above 4 kHz
bite = song.track("BITE", "fm86", "slab/clav", volume=0.62, pan=0.7, output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=800, p2_hz=3000, p2_db=-2, hs_hz=7000, hs_db=2),
])
pad = song.track("PAD", "juno2", "bittersweet-minor-pad", volume=0.27, params=dict(level=0.5, age=0.2),
                 output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=170, p1_hz=550, p1_db=-3, p2_hz=2500, p2_db=-2, hs_hz=7000, hs_db=-4),
    fx("chorus2", "juno-ii"),
])
# The sparkle: two harpsichords, one per side, playing the stabs up an
# octave: the harpsichord holds its 5-14 kHz harmonics for a full
# second after the hit, bright lines, not noise. Different voicings on each side, so the pair decorrelates into width.
spark_l = song.track("SPARKLE L", "fm86", "slab/harpsichord", volume=0.8, pan=-0.85, output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=1000, p1_hz=1600, p1_db=-3, p2_hz=6000, p2_db=3, hs_hz=12000, hs_db=2),
    fx("chorus2", "bell-widener", mix=0.35),
])
spark_r = song.track("SPARKLE R", "fm86", "slab/harpsichord", volume=0.8, pan=0.85, output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=1000, p1_hz=1600, p1_db=-3, p2_hz=7000, p2_db=3, hs_hz=12000, hs_db=2),
    fx("chorus2", "bell-widener", mix=0.35),
])

# The tines: the reference's side channel is full of short bright
# plucks between 400 Hz and 2 kHz that live only in the stereo image.
# A pair interlocking in 16ths: our own tine e-piano left, the classic
# FM ballad tine right.
tine_l = song.track("TINES L", "fm86", "slab/e-piano", volume=0.5, pan=-0.9,
                    output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=350, p1_hz=600, p1_db=-2, p2_hz=3500, p2_db=3, hs_hz=9000, hs_db=2),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.2, damp=5000, mix=0.18),
])
tine_r = song.track("TINES R", "fm86", "slab/e-piano-2", volume=0.5, pan=0.9, output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=350, p1_hz=600, p1_db=-2, p2_hz=4000, p2_db=3, hs_hz=9000, hs_db=2),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.2, damp=5000, mix=0.18),
])

# ── lead ───────────────────────────────────────────────────────────────
# slab/glass-lead: a sine body (a 1:1 pair and a detuned twin) under a
# two-octave sparkle (a 4:3 pair). Measured on D6: harmonics 3-11 at +6
# dB over the fundamental on the attack, settling to a bright -17..-21 dB
# sustain: squeaky on the hit, still glittering while it holds.
lead = song.track("LEAD", "fm86", "slab/glass-lead", volume=1.25, pan=0.05, params=dict(volume=2.0), output=lead_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=320, p1_hz=700, p1_db=-2, p2_hz=3200, p2_db=2, hs_hz=10000, hs_db=2),
    fx("chorus2", "bell-widener", mix=0.3),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.3, damp=6500, mix=0.22),
    fx("verb2", "bright-plate", decay=17.26, predelay=0.02, mix=0.16, damp=10000),
])
# the glass: bells an octave over the lead, quiet, wide
glass = song.track("GLASS", "fm86", "slab/bells", volume=0.5, pan=0.6, output=lead_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=900, hs_hz=9000, hs_db=2),
    fx("delay2", sync="SYNC", div="1/4.", fb=0.25, damp=6000, mix=0.25),
])

# ── bass ───────────────────────────────────────────────────────────────
bass = song.track("SYNTH BASS", "cream", "outstanding-funk-bass", volume=0.5, params=dict(
    cutoff=2000, contour=2.4, glide=0.0, age=0.1, level=0.8), output=bass_bus, fx=[
    # weight at 90, the growl at 800 that says "bass" on small speakers
    fx("eq2", hpf_on="ON", hpf_hz=40, ls_hz=70, ls_db=-3, p1_hz=750, p1_db=4.5, p1_q=0.9, p2_hz=2200, p2_db=3),
])
# the bass's edge: the solid FM bass an octave up, all 100-2k snarl
bass_dx = song.track("DX BASS", "fm86", "slab/solid-bass", volume=0.8, output=bass_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, p1_hz=200, p1_db=3.5, p1_q=0.9, p2_hz=1400, p2_db=2),
])

# ── drums: the LinnDrum (the record's Linn 2) ──────────────────────────
KIT = "drums/linndrum/kit"
KICK, SNARE, HAT, OPEN, CRASH, TAMB = 36, 38, 42, 46, 49, 54
TOMS = [48, 45, 41]  # high to low

kick = song.track("KICK", "sampler", KIT, volume=1.0, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=35, p1_hz=380, p1_db=-5, p1_q=1.2, p2_hz=3500, p2_db=3),
    fx("comp2", "dry-drum-punch", makeup=4.0),
])
snare = song.track("SNARE", "sampler", KIT, volume=1.0, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, p1_hz=450, p1_db=-3, p1_q=0.9, p2_hz=2200, p2_db=4, hs_hz=6000, hs_db=3),
    fx("comp2", "drum-smash", makeup=14),
])
perc = song.track("PERC", "sampler", KIT, volume=0.7, pan=0.35, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=120, p1_hz=400, p1_db=-3, p2_hz=5000, p2_db=2),
])
# the hats: a tick, not a hiss. Quiet, the wash above 9 kHz shelved off
# so the sparkle up there belongs to the keys.
hats = song.track("HATS", "sampler", KIT, volume=0.42, pan=0.3, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=700, p2_hz=5000, p2_db=2, hs_hz=9000, hs_db=-6),
])
# The room is a return, fully wet, keyed from the snare: each backbeat
# blooms and slams shut, and the toms ring into it only while the snare
# holds the gate open.
room = song.bus("GATED ROOM", output=drums, fx=[fx("verb2", "gated-drum-room", mix=1.0, key=snare)])
snare.send(room, -9)
perc.send(room, -18)

# ── parts ──────────────────────────────────────────────────────────────
ACCENT = {0.0, 1.5, 3.0}   # 3-3-2 across the 8ths
p = piano.clip(intro).chords(PROG, "x.x.x.x.x.x.x.x.", near=60, voices=4, vel=86, gate=0.8)
p.velocities(lambda n: min(127, n["vel"] + 24) if n["start"] % 4 in ACCENT else n["vel"])
p.humanize(time=0.003, vel=4)
piano.clip(land).chords("Dm", near=60, voices=4, vel=118, gate=0.98)
bite.clip(intro).chords(PROG, "x.x.x.x.x.x.x.x.", near=72, voices=3, vel=80, gate=0.5).velocities(
    lambda n: min(127, n["vel"] + 28) if n["start"] % 4 in ACCENT else n["vel"])
bite.clip(land).chords("Dm", near=72, voices=3, vel=110, gate=0.9)
# the sparkle rides the stabs from bar 1, a little longer than the piano
# so the harmonics ring between the hits
for trk, near in ((spark_l, 76), (spark_r, 81)):
    trk.clip(intro).chords(PROG, "x.x.x.x.x.x.x.x.", near=near, voices=3, vel=84, gate=0.95).velocities(
        lambda n: min(127, n["vel"] + 20) if n["start"] % 4 in ACCENT else n["vel"])
    trk.clip(land).chords("Dm", near=near, voices=3, vel=110, gate=0.98)
# tines from bar 3 with the lead: left on the 8ths going up, right on
# the 16th offbeats coming down, so the pair chatters across the image
tine_l.clip(intro, at_bar=2, bars=6).arp(PROG, [0, 1, 2, 3], rate=0.5, octave=5, vel=92, gate=0.5, accent=10)
tine_r.clip(intro, at_bar=2, bars=6).arp(PROG, [4, 3, 2, 1], rate=0.5, at=0.25, octave=5, vel=88, gate=0.5, accent=10)
pad.clip(intro, at_bar=4, bars=4).chords("Dm Am Bb C:2 A:2", near=57, voices=4, spread=True, vel=80)
pad.clip(land).chords("Dm", near=57, voices=4, spread=True, vel=84)

# the bass holds, stops dead on the and-of-2, and kicks back in late
BASS_PAT = "x-----..xx-.x-o."
bass.clip(intro).bass(PROG, BASS_PAT, vel=100, gate=0.92).humanize(time=0.002, vel=5)
bass_dx.clip(intro).bass(PROG, BASS_PAT, octave=3, vel=96, gate=0.92).humanize(time=0.002, vel=5)
bass.clip(land).note("D1", 0, 3.0, 118)
bass_dx.clip(land).note("D2", 0, 3.0, 112)

lead.clip(intro, at_bar=2, bars=6).melody(HOOK, vel=100, gate=0.92)
glass.clip(intro, at_bar=2, bars=6).melody(HOOK, vel=88, gate=0.6).transpose(12)
lead.clip(land).note("D6", 0, 3.0, 108)
glass.clip(land).chord([81, 86, 93], 0, 3.0, vel=96)

# hats: straight 8ths from bar 3, 16ths through bar 8; the tambourine
# marks bar 7's backbeat, the toms run into the land
h = hats.clip(intro, at_bar=2, bars=6)
h.drums({HAT: "x.x.x.x.x.x.x.x."}, bars=5)
h.drums({HAT: "x.xox.xox.xoxxxx"}, at=20, bars=1)
h.humanize(time=0.002, vel=6)
hats.clip(land).drums({OPEN: "x"}, bars=1)
pc = perc.clip(intro, at_bar=6, bars=2)
pc.drums({TAMB: "....x.......x..."}, bars=1)
pc.drums({TOMS[0]: "........x.x.....", TOMS[1]: "............x...", TOMS[2]: "..............x."}, at=4, bars=1)
perc.clip(land).drums({CRASH: "X"}, bars=1)

# the kit arrives at bar 7: a bar of groove, then the fill into the land
k = kick.clip(intro, at_bar=6, bars=2)
k.drums({KICK: "x.........x....."}, bars=1)
k.drums({KICK: "x.....x.x......."}, at=4, bars=1)
s = snare.clip(intro, at_bar=6, bars=2)
s.drums({SNARE: "....x.......x..."}, bars=1)
s.drums({SNARE: "....x..ox.xo.xXX"}, at=4, bars=1)
s.velocities(lambda n: min(127, n["vel"] + int(8 * n["start"] / 8)))
kick.clip(land).drums({KICK: "X"}, bars=1)
snare.clip(land).drums({SNARE: "X"}, bars=1)

# light: a clip-guard, not a loudness limiter, so the hits keep their crest
song.master(fx=[
    fx("eq2", hpf_on="ON", hpf_hz=25, p1_hz=220, p1_db=2, p1_q=0.7, hs_hz=9000, hs_db=-1),
    fx("limiter2", gain=3.0, ceil=-1.0),
])

if __name__ == "__main__":
    import sys
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
