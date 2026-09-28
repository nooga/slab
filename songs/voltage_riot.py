"""Voltage Riot — fast, angry techno with two drops. Original material.

142 BPM, F phrygian (the flat second, Gb, is the menace). A driven kick
tuned to F, a rolling bass in the gaps between kicks, an MS-20 acid
line, fuzzed chord stabs, industrial toms. Two breakdowns pull back to a
dark pad and a screaming MS-20 motif, then a riser and snare roll into a
beat of silence before each drop. Drop 2 adds a second, open acid line
and the motif as the drop hook.

    PYTHONPATH=tools python3 songs/voltage_riot.py --render --stems
    zig-out/bin/slab songs/voltage_riot.slab
"""
from slabkit import Song, fx

song = Song("Voltage Riot", bpm=142, key="F phrygian")

# ── form ───────────────────────────────────────────────────────────────
intro = song.section("intro", 16)
build = song.section("build", 16)
break1 = song.section("break1", 8)
drop1 = song.section("drop1", 16)
break2 = song.section("break2", 16)
drop2 = song.section("drop2", 16)
outro = song.section("outro", 16)

BAR = song.bar_beats
DROPS = (drop1, drop2)

# ── tracks ─────────────────────────────────────────────────────────────
kick = song.track("KICK", "drum2", "909-punch", volume=0.379, params=dict(
    # body at 55 Hz and up, where speakers and guts respond; 44 Hz measured
    # big and sounded like nothing
    kick_tune=55, kick_sweep=12, kick_bend=0.04, kick_decay=0.32, kick_click=0.5,
    kick_drive=5, kick_level=1.0, master_drive=1.6), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=30, ls_hz=90, ls_db=1.5, p1_hz=300, p1_db=-4, p1_q=1.2, p2_hz=3500, p2_db=2),
    fx("sat2", drive=9, mode="TAPE", mix=0.6),
])
# not a sub preset: its 16' oscillators and 2-octave sub put the line at
# 22-44 Hz, where nothing hears it. 8' saw + square play the written pitch.
bass = song.track("BASS", "cream", "deep-sub-bass", volume=0.359, params=dict(
    range1="8", wave1="SAW", range2="8", wave2="SQR", detune2=0.08, lvl1=1.0, lvl2=0.7, lvl3=0.0,
    cutoff=600, emphasis=0.2, contour=2.4, drive=0.7, f_dec=0.18, a_dec=0.22, a_sus=0.3, a_rel=0.06,
    level=0.8), fx=[
    # an octave above the kick's F1: the kick owns the sub, the bass the punch
    fx("eq2", hpf_on="ON", hpf_hz=45),
    fx("sat2", drive=12, mode="XFMR", tone=3000, mix=0.5, out=3),
    fx("comp2", "bass-leveler"),
])
acid = song.track("ACID", "ms20", "acid-bass", volume=1.25, params=dict(
    resonance=0.8, env_amount=3.5, drive=1.5), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=140, p2_hz=1500, p2_db=2, hs_hz=6000, hs_db=-3),
    fx("sat2", drive=10, mode="FUZZ", tone=4500, mix=0.3),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.35, damp=3000, mix=0.18),
])
# the drop-2 acid: same line an octave up, filter wide open, screaming
acid2 = song.track("ACID!", "ms20", "acid-bass", volume=0.645, pan=0.15, params=dict(
    cutoff=1100, resonance=1.0, env_amount=4.5, drive=2), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=250, hs_hz=6000, hs_db=-3),
    fx("sat2", drive=12, mode="DIODE", tone=4500, mix=0.35),
    fx("delay2", sync="SYNC", div="1/16", fb=0.4, damp=4000, mix=0.2),
])
clap = song.track("CLAP", "drum2", "clap-forward-kit", volume=0.511, params=dict(
    clap_decay=0.3, snare_tone=3000, master_drive=2.2), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=180, p2_hz=2500, p2_db=2),
    fx("verb2", "short-plate-room", mix=0.22),
])
hats = song.track("HATS", "drum2", "crisp-hat-kit", volume=0.809, pan=0.18, params=dict(
    hat_level=1.4, hat_chdec=0.035, hat_ohdec=0.3, master_drive=1.8), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=600),
    fx("sat2", drive=6, mode="TAPE", mix=0.4),
])
perc = song.track("PERC", "drum2", "synthetic-tom-kit", volume=0.3, pan=-0.2, params=dict(
    tom_tune=150, tom_decay=0.18, tom_drive=4), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=120),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.3, damp=3500, mix=0.2),
])
stab = song.track("STAB", "juno2", "party-chord-stab", volume=0.504, pan=-0.12, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=220),
    fx("sat2", drive=12, mode="FUZZ", tone=3500, mix=0.3),
    fx("delay2", sync="SYNC", div="1/8.", fb=0.42, damp=3200, mix=0.26),
    fx("verb2", "big-hall", mix=0.2),
])
pad = song.track("PAD", "juno2", "hazy-slow-attack-pad", volume=0.333, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=200, p1_hz=450, p1_db=-3),
    fx("chorus2", "juno-ii"),
    fx("verb2", "cathedral", mix=0.4),
])
scream = song.track("SCREAM", "ms20", "scream-lead", volume=0.457, params=dict(portamento=0.4), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=300),
    fx("delay2", sync="SYNC", div="1/4", fb=0.45, damp=3500, mix=0.25),
    fx("verb2", "big-plate-hall", mix=0.3),
])
riser = song.track("RISER", "ms20", "rising-filter-fx", volume=0.393, fx=[
    fx("eq2", hpf_on="ON", hpf_hz=400),
    fx("verb2", "big-hall", mix=0.35),
])
roll = song.track("ROLL", "drum2", "gated-snare-kit", volume=0.263, params=dict(
    snare_decay=0.12, snare_tone=3200, snare_level=1.0), fx=[
    fx("eq2", hpf_on="ON", hpf_hz=200),
    fx("verb2", "big-hall", mix=0.3),
])

# ── patterns ───────────────────────────────────────────────────────────
FOUR = "x...x...x...x..."
ROLLING = ".xxx.xxx.xxx.xxx"          # 16ths between the kicks
# the drop bass moves: it follows the chords and jumps octaves and fifths
MOVING = ".xox.xx5.xox.x5o"
BASS_PROG = "Fm Fm Db Gb"
# the acid line: accents and slides do the work; Gb is the flat second
ACID = "F1 F1 F2! F1 . F1 Gb1~ Ab1 | F1 C2! . F1 Eb2~ F2 F1 Db2"
ACID_B = "F1 F1 F2! F1 . F1 Gb1~ Ab1 | F1 C2! . Ab1~ Gb1 F1 C2! Eb2"
MOTIF = "C5:.75 Db5:.75 C5:.5 Ab4:1 G4:.5 Ab4:.5 | F4:4 | C5:.75 Db5:.75 Eb5:.5 Db5:1 C5:1 | Ab4:4"
CHORDS = "Fm Fm Dbmaj7 Gb"             # i i bVI bII: dark, then the phrygian lift


def four_floor(sec, bars=None, at_bar=0, soft=False):
    c = kick.clip(sec, at_bar=at_bar, bars=bars).drums({"kick": FOUR})
    if soft:
        c.velocities(lambda n: n["vel"] * 0.85)
    return c


def build_up(sec, bars=8):
    """The last `bars` of a breakdown: snare roll 8ths → 16ths → 32nds
    with a crescendo, a rising filter sweep, and one beat of silence
    before the drop."""
    first = sec.bars - bars
    r = roll.clip(sec, at_bar=first, bars=bars)
    half = bars // 2
    r.drums({"snare": "x.x.x.x."}, bars=half, step=0.25)
    r.drums({"snare": "xxxx"}, at=half * BAR, bars=bars - half - 1, step=0.25)
    r.drums({"snare": "xxxxxxxx xxxxxxxx xxxxxxxx"}, at=(bars - 1) * BAR, bars=1, step=0.125)
    r.notes = [n for n in r.notes if n["start"] < bars * BAR - 1]     # the pull: last beat silent
    total = bars * BAR
    r.velocities(lambda n: 40 + 87 * (n["start"] / total) ** 1.5)
    rs = riser.clip(sec, at_bar=first, bars=bars)
    for i in range(bars * 4 - 1):                                     # a semitone per beat
        rs.note(41 + i, i, 1.02, 60 + int(60 * i / (bars * 4)))


# ── intro: kick alone, then hats, then clap ────────────────────────────
four_floor(intro)
hats.clip(intro, at_bar=8).drums({"ch": "..x...x...x...x."})
clap.clip(intro, at_bar=12).drums({"clap": "....x.......x..."})
perc.clip(intro, at_bar=12).drums({"tom": "......x.....x..x"})

# ── build: rolling bass and acid enter, hats go 16ths ──────────────────
four_floor(build)
bass.clip(build).bass("Fm", ROLLING, octave=2, vel=100, gate=0.65)
acid.clip(build, at_bar=4).seq(ACID, vel=84, accent=112)
hats.clip(build).drums({"ch": "xoXoxoXoxoXoxoXo"}).humanize(time=0.002, vel=6)
clap.clip(build).drums({"clap": "....x.......x...", "snare": "....x.......x..."})
perc.clip(build).drums({"tom": "......x.....x..x|...x..x.....x..."})

# ── break 1: kick out, stabs and pad, short build ──────────────────────
pad.clip(break1).chords(CHORDS, near=58, spread=True, vel=80)
stab.clip(break1, bars=4).chords(CHORDS, "x.......", near=62, vel=76, gate=0.4)
build_up(break1, bars=4)

# ── drops: everything ──────────────────────────────────────────────────
for sec in DROPS:
    four_floor(sec)
    bass.clip(sec).bass(BASS_PROG, MOVING, octave=2, vel=110, gate=0.7)
    acid.clip(sec).seq(ACID_B if sec is drop2 else ACID, vel=96, accent=124)
    h = hats.clip(sec).drums({"ch": "xoXoxoXoxoXoxoXo", "oh": "..x...x...x...x."}).humanize(time=0.002, vel=6)
    h.note(46, 0, 1.0, 127)   # the drop's downbeat crash
    clap.clip(sec).drums({"clap": "....x.......x...", "snare": "....x.......x..o"})
    perc.clip(sec).drums({"tom": "..x...x..x..x...|x.....x...x..x.x"})
    stab.clip(sec).chords("Fm", "x..x..x...x..x..", near=62, vel=104, gate=0.35)

# drop 2 is harder: the open acid, the motif as the hook, busier stabs
acid2.clip(drop2).seq(ACID_B, vel=100, accent=127).transpose(12)
scream.clip(drop2).melody(MOTIF + " | " + MOTIF, vel=110)

# ── break 2: the long one — pad, the motif alone, a big build ──────────
pad.clip(break2).chords(CHORDS, near=58, spread=True, vel=70)
scream.clip(break2, bars=8).melody(MOTIF + " | " + MOTIF, vel=84)
stab.clip(break2, at_bar=4, bars=4).chords(CHORDS, "x.......", near=62, vel=74, gate=0.4)
kick.clip(break2, at_bar=8, bars=4, name="tease").drums({"kick": "x.......x......."})
acid.clip(break2, at_bar=12, bars=3).seq(ACID, vel=76, accent=104)
build_up(break2, bars=8)

# ── outro: strip back to kick, hats, perc ──────────────────────────────
four_floor(outro, soft=True)
bass.clip(outro, bars=8).bass("Fm", ROLLING, octave=2, vel=96, gate=0.55)
acid.clip(outro, bars=4).seq(ACID, vel=80, accent=110)
hats.clip(outro, bars=12).drums({"ch": "xoXoxoXoxoXoxoXo"})
clap.clip(outro, bars=8).drums({"clap": "....x.......x..."})
perc.clip(outro).drums({"tom": "......x.....x..x"})
for c in (kick.clips[-1], hats.clips[-1], perc.clips[-1]):
    c.velocities(lambda n, c=c: n["vel"] * (1 - 0.5 * n["start"] / c.length))

# ── mix rides (docs/21 §8) ─────────────────────────────────────────────
# the bass swells in across the build; the pad blooms in the breaks
bass.ride({build: (-8, 0)})
pad.ride({break1: 1, break2: (0, 2)})

# ── master: loud, but under the knee ───────────────────────────────────
# multi2 holds the kick and bass in their own band so the limiter stops
# ducking the whole mix on every kick; the mid and top get a little
# presence back. It replaces a broadband glue comp: the two stacked
# levelled the breaks up to the drops.
song.master(fx=[
    fx("eq2", hpf_on="ON", hpf_hz=26, ls_hz=90, ls_db=0),
    fx("multi2", "master-balance", mlo_thresh=-18.9, mmid_gain=1, mhi_gain=1.5),
    fx("limiter2", gain=9.0, ceil=-3.2),
])

if __name__ == "__main__":
    import sys
    if "--render" in sys.argv:
        song.render(stems="--stems" in sys.argv)
    else:
        song.save()
