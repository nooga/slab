"""Shattered Dreams (tribute) — the first 20 seconds of Johnny Hates
Jazz's 1987 single, rebuilt on Slab's machines.

The notes come from a karaoke MIDI file the user owns, read at build
time (nothing of the song is stored here). The MIDI's General MIDI
instrument choices are ignored: each part gets the sound the record is
known or measured to use.

  part (MIDI track)        the record              here
  stabs  (Rhythm Guitar)   Emax sampled piano      slab/piano + slab/clav bite, harpsichords an octave up
  riff   (Strings)         D-50 hook layer         slab/glass-lead + slab/bells an octave up
  tines  (Music Box)       Fairlight / DX tines    slab/e-piano left, slab/e-piano-2 right, alternating
  chords (Sawtooth Lead)   Jupiter 8               juno2 pad
  bass   (Bass)            Jupiter / CZ synth bass cream + slab/solid-bass, an octave up
  drums  (Drums)           Linn 2 / 9000           LinnDrum, sampled snare into a gated room
  voice  (Melody)          the vocal               the lead, an octave up, from the verse's pickup

Credits for the gear: Music Technology, April 1988; the band's Gearspace
thread. The mix targets are the reference intro's measured spectrum,
crest and width (see songs/broken_glass.py).

    PYTHONPATH=tools python3 songs/shattered_dreams_tribute.py --render [path/to/song.mid]
    zig-out/bin/slab songs/shattered_dreams_tribute.slab
"""
import os
import sys

from slabkit import Song, fx
from slabkit import smf

MIDI = next((a for a in sys.argv[1:] if a.endswith(".mid")),
            os.path.expanduser("~/Downloads/Shattered Dreams (Karaoke).mid"))
_, TRACKS, _ = smf.read(MIDI)
PART = {t["name"]: t["notes"] for t in TRACKS if t["name"]}

# The MIDI's bar 1 is the record's first bar; ten bars at the record's
# 121 BPM are the intro and the verse's first two bars, ~20 s.
FROM, BARS = 4.0, 10
song = Song("Shattered Dreams (tribute)", bpm=121, key="D minor")
intro = song.section("intro", 8)
verse = song.section("verse", 2)
tail = song.section("tail", 1)
END = FROM + BARS * 4


def notes(name, lo=FROM, hi=END):
    """(beat from the song start, length, pitch, velocity) of a MIDI track."""
    return [(b - FROM, ln, p, v) for b, ln, p, v, _ in sorted(PART[name]) if lo <= b < hi]


CLIPS = {}


def place(track, name, transpose=0, gate=1.0, vel=lambda v: v, where=None, lo=FROM, hi=END, pitch=None):
    """A MIDI track's notes onto a Slab track (one clip per track, shared)."""
    c = CLIPS.get(track.name) or CLIPS.setdefault(track.name, track.clip(None, bars=BARS))
    for b, ln, p, v in notes(name, lo, hi):
        if where and not where(b, p):
            continue
        c.note((pitch or {}).get(p, p + transpose), b, max(0.05, ln * gate), max(1, min(127, vel(v))))
    return c


# ── groups ─────────────────────────────────────────────────────────────
keys_bus = song.bus("KEYS")
lead_bus = song.bus("LEADS")
bass_bus = song.bus("BASS")
drums = song.bus("DRUMS", volume=1.1, fx=[fx("bus2", "drum-bus", thresh=-22, makeup=4.0)])

# ── keys ───────────────────────────────────────────────────────────────
piano = song.track("PIANO", "fm86", "slab/piano", volume=1.2, pan=-0.5, params=dict(volume=2.0), output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, ls_hz=200, ls_db=2, p1_hz=500, p1_db=-4, p1_q=1.0, p2_hz=5000, p2_db=5, hs_hz=10000, hs_db=4),
    fx("chorus2", "wide-keys", mix=0.5),
    fx("verb2", "bright-plate", decay=11.89, predelay=0.018, mix=0.14, damp=9000),
])
bite = song.track("BITE", "fm86", "slab/clav", volume=0.9, pan=0.6, params=dict(volume=2.0), output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=800, p2_hz=3000, p2_db=-2, hs_hz=6500, hs_db=5),
])
spark_l = song.track("SPARKLE L", "fm86", "slab/harpsichord", volume=1.3, pan=-0.85, params=dict(volume=2.0), output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=1000, p1_hz=1600, p1_db=-3, p2_hz=6000, p2_db=3, hs_hz=12000, hs_db=2),
    fx("chorus2", "bell-widener", mix=0.35),
])
spark_r = song.track("SPARKLE R", "fm86", "slab/harpsichord", volume=1.15, pan=0.85, params=dict(volume=2.0), output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=1000, p1_hz=1600, p1_db=-3, p2_hz=7000, p2_db=3, hs_hz=12000, hs_db=2),
    fx("chorus2", "bell-widener", mix=0.35),
])
tine_l = song.track("TINES L", "fm86", "slab/e-piano", volume=0.3, pan=-0.9, output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=350, p1_hz=600, p1_db=-2, p2_hz=3500, p2_db=3, hs_hz=9000, hs_db=2),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.2, damp=5000, mix=0.18),
])
tine_r = song.track("TINES R", "fm86", "slab/e-piano-2", volume=0.75, pan=0.9, output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=350, p1_hz=600, p1_db=-2, p2_hz=4000, p2_db=3, hs_hz=9000, hs_db=2),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.2, damp=5000, mix=0.18),
])
pad = song.track("PAD", "juno2", "bittersweet-minor-pad", volume=0.26, params=dict(level=0.5, age=0.2),
                 output=keys_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=170, p1_hz=550, p1_db=-3, p2_hz=2500, p2_db=-2, hs_hz=7000, hs_db=-4),
    fx("chorus2", "juno-ii"),
])

# ── leads ──────────────────────────────────────────────────────────────
lead = song.track("LEAD", "fm86", "slab/glass-lead", volume=1.25, pan=0.05, params=dict(volume=2.0),
                  output=lead_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=320, p1_hz=700, p1_db=-2, p2_hz=3200, p2_db=2, hs_hz=10000, hs_db=2),
    fx("chorus2", "bell-widener", mix=0.3),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.3, damp=6500, mix=0.22),
    fx("verb2", "bright-plate", decay=17.26, predelay=0.02, mix=0.16, damp=10000),
])
glass = song.track("GLASS", "fm86", "slab/bells", volume=0.7, pan=0.6, output=lead_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=900, hs_hz=9000, hs_db=2),
    fx("delay2", sync="SYNC", div="1/4.", fb=0.25, damp=6000, mix=0.25),
])

# ── bass ───────────────────────────────────────────────────────────────
bass = song.track("SYNTH BASS", "cream", "outstanding-funk-bass", volume=0.5, params=dict(
    cutoff=2000, contour=2.4, glide=0.0, age=0.1, level=0.8), output=bass_bus, fx=[
    # the growl at 750 says "bass" on small speakers; the sub stays lean
    fx("eq2", hpf_on="ON", hpf_hz=40, ls_hz=70, ls_db=-3, p1_hz=750, p1_db=4.5, p1_q=0.9, p2_hz=2200, p2_db=3),
])
bass_dx = song.track("DX BASS", "fm86", "slab/solid-bass", volume=0.8, output=bass_bus, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, p1_hz=200, p1_db=3.5, p1_q=0.9, p2_hz=1400, p2_db=2),
])

# ── drums: the LinnDrum ────────────────────────────────────────────────
KIT = "drums/linndrum/kit"
kick = song.track("KICK", "sampler", KIT, volume=1.0, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=35, p1_hz=380, p1_db=-5, p1_q=1.2, p2_hz=3500, p2_db=3),
    fx("comp2", "dry-drum-punch", makeup=4.0),
])
snare = song.track("SNARE", "sampler", KIT, volume=1.0, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=90, p1_hz=450, p1_db=-3, p1_q=0.9, p2_hz=2200, p2_db=4, hs_hz=6000, hs_db=3),
    fx("comp2", "drum-smash", makeup=14),
])
hats = song.track("HATS", "sampler", KIT, volume=0.42, pan=0.3, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=700, p2_hz=5000, p2_db=2, hs_hz=9000, hs_db=-6),
])
perc = song.track("PERC", "sampler", KIT, volume=0.45, pan=-0.35, params=dict(level=1.0), output=drums, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=150, p1_hz=400, p1_db=-3, p2_hz=5000, p2_db=2, hs_hz=10000, hs_db=-3),
])
room = song.bus("GATED ROOM", output=drums, fx=[fx("verb2", "gated-drum-room", mix=1.0, key=snare)])
snare.send(room, -9)
perc.send(room, -20)

# ── parts ──────────────────────────────────────────────────────────────
# stabs: the MIDI's offbeat dyads on the piano and its bite; the
# harpsichords take them an octave up, one voice per side
place(piano, "Rhythm Guitar", gate=2.5)
place(bite, "Rhythm Guitar", transpose=12, gate=1.5, vel=lambda v: v - 8)
place(spark_l, "Rhythm Guitar", transpose=12, gate=3, where=lambda b, p: p >= 62)
place(spark_r, "Rhythm Guitar", transpose=24, gate=3, where=lambda b, p: p < 62)

# the riff, and the voice's line from the verse's pickup, on the lead
place(lead, "Strings", transpose=0, hi=FROM + 32)
place(lead, "Melody", transpose=12, lo=FROM + 32, vel=lambda v: v + 10)
place(glass, "Strings", transpose=12, gate=0.6, hi=FROM + 32, vel=lambda v: v - 12)

# tines: on-beat notes left, off-beat notes right
place(tine_l, "Music Box", gate=4, where=lambda b, p: b % 1 < 0.25)
place(tine_r, "Music Box", gate=4, where=lambda b, p: b % 1 >= 0.25)

place(pad, "Sawtooth Lead")
place(bass, "Bass", transpose=12, gate=0.95, vel=lambda v: v + 25)
place(bass_dx, "Bass", transpose=24, gate=0.95, vel=lambda v: v + 20)

# drums: the MIDI's GM kit onto the LinnDrum's keys. The bongos go to
# its congas, the claves and the wood block to the sidestick.
GM_TO_LINN = {60: 63, 61: 64, 75: 37}
place(kick, "Drums", where=lambda b, p: p == 36)
place(snare, "Drums", where=lambda b, p: p == 38)
place(hats, "Drums", where=lambda b, p: p in (42, 44, 46))
place(perc, "Drums", where=lambda b, p: p in (60, 61, 69, 75), pitch=GM_TO_LINN)
place(perc, "Wood Block", pitch={64: 37}, vel=lambda v: v - 20)

# the tail: the verse's Dm rings out
piano.clip(tail).chords("Dm", near=62, voices=4, vel=100, gate=0.98)
pad.clip(tail).chords("Dm", near=62, voices=3, vel=80, gate=0.98)
bass.clip(tail).note("D2", 0, 3.0, 110)
kick.clip(tail).note(36, 0, 0.5, 118)
perc.clip(tail).note(49, 0, 2.0, 110)

song.master(fx=[
    fx("eq2", hpf_on="ON", hpf_hz=25, ls_hz=120, ls_db=1.5, p1_hz=2000, p1_db=-2.5, p1_q=0.7, p2_hz=6500, p2_db=1.5, p2_q=0.8, hs_hz=11000, hs_db=1.5),
    fx("limiter2", gain=1.5, ceil=-1.0),
])

if __name__ == "__main__":
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
