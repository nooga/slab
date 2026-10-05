"""Afterimage Express — original cosmic outrun, 118 BPM, F# minor.

Generate factory demo: PYTHONPATH=tools python3 songs/afterimage_express.py
Preview:  ... --preview  (eight-bar first lift, all native machines)
Render:   ... --render --stems

The generator owns demos/afterimage_express.slab/project.json.
Save UI experiments under another name
before regenerating. All sound comes from Slab's bundled machines;
no third-party samples, transcribed hooks or post-render mastering.
"""
from pathlib import Path
import argparse
import json
import subprocess
import time
from slabkit import Song, fx
from slabkit.machines import ROOT, SLAB

song = Song("Afterimage Express", bpm=118, key="F# minor", groove_seed=1984)
intro = song.section("IGNITION", 8)
cruise = song.section("NIGHT MOTOR", 16)
lift = song.section("OVERPASS", 8)
wide = song.section("GLASS CITY", 16)
tunnel = song.section("UNDERCURRENT", 16)
brk = song.section("WEIGHTLESS", 8)
build = song.section("REENTRY", 8)
peak = song.section("AFTERIMAGE", 24)
outro = song.section("LAST LIGHT", 8)

# Native parallel spaces; no reverb on the bass/kick. Keep the transient
# paths short and let the returns provide the scale.
drums = song.bus("DRUM BUS", fx=[
    fx("sat2", "tape-glue", drive=4, mix=0.35, out=-0.8),
    fx("bus2", "drum-bus", thresh=-16, makeup=1, color=0.15, mix=0.75),
])
kick = song.track("01 KICK", "drum2", "tough-night-kit", volume=0.9, output=drums,
    params=dict(kick_tune=55, kick_sweep=9.5, kick_bend=0.025,
                kick_decay=0.25, kick_click=0.35, kick_drive=2.4,
                kick_level=1, master_drive=1.1),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=29, p1_hz=310, p1_db=-3, p1_q=0.85)])
snare = song.track("02 SNARE", "drum2", "gated-snare-kit", volume=0.70, output=drums,
    params=dict(snare_tune=194, snare_decay=0.19, snare_sdec=0.12,
                snare_snap=0.84, snare_tone=2600, clap_level=0.38,
                clap_tone=1250, clap_decay=0.14, master_drive=1.25),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=150, p1_hz=520, p1_db=-2.3,
           p2_hz=2600, p2_db=1.3, hs_hz=8000, hs_db=-4),
        fx("comp2", thresh=-16, ratio=3, atk=0.008, rel=0.065, makeup=1)])
hats = song.track("03 CHROME HATS", "drum2", "crisp-hat-kit", volume=0.23, pan=0.16, output=drums,
    params=dict(hat_tone=0.85, hat_tune=1.09, hat_chdec=0.036, hat_ohdec=0.19,
                hat_level=1.1, master_drive=1),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=680, hs_hz=8500, hs_db=-3.5),
        fx("comp2", ratio=1, thresh=0, makeup=16)])
perc = song.track("04 TOMS AND RIM", "drum2", "synthetic-tom-kit", volume=0.4, pan=-0.2, output=drums,
    params=dict(tom_tune=146.83, tom_sweep=1.8, tom_decay=0.17, tom_drive=1.7,
                snare_tune=370, snare_snap=0.12, snare_decay=0.052,
                snare_sdec=0.032, snare_tone=1450),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=130, hs_hz=6500, hs_db=-4)])
room = song.bus("GATED ROOM", volume=0.85, output=drums, fx=[
    fx("verb2", "gated-snare-slam", key=snare, mix=1, gate_hold=0.20,
       gate_thr=-37, lowcut=260, tone=6800, damp=5200, gate_shape=-0.4),
    fx("eq2", hpf_on="ON", hpf_hz=280, hs_hz=6500, hs_db=-3),
])
snare.send(room, -8)
perc.send(room, -19)

bass = song.track("05 V8 BASS", "cream", "synthwave-bass", volume=0.89,
    params=dict(range1="8", range2="8", lvl3=0.14, cutoff=640,
                emphasis=0.25, contour=2.4, f_dec=0.135, a_sus=0.35,
                a_dec=0.22, a_rel=0.045, age=0.17, drive=0.43, level=0.47),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=36, p1_hz=270, p1_db=-2.4, p1_q=0.9),
        fx("sat2", "iron-bass", drive=7, mix=0.38, out=-1),
        fx("comp2", key=kick, thresh=-23, ratio=4, knee=7, atk=0.0015, rel=0.10)])
arp = song.track("06 VECTOR ARP", "profit5", "pluck-keys", volume=0.55, pan=-0.10,
    unison=dict(count=2, voices=8, detune=9, spread=0.60, blend=0.8),
    params=dict(freq_b=0, saw_b=0, pul_b=1, pw_b=0.31, fine_b=0.045,
                cutoff=680, env=0.38, kbd=0.30, res=0.18,
                f_dec=0.15, a_dec=0.22, a_sus=0.04, a_rel=0.09,
                age=0.16, heat=0.13, level=0.65),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=220, p1_hz=460, p1_db=-2,
           p2_hz=3100, p2_db=-1.2, hs_hz=8500, hs_db=-2),
        fx("sat2", "tube-thicken", drive=4, mix=0.24, out=-0.7),
        fx("comp2", key=kick, thresh=-22, ratio=2.3, atk=0.003, rel=0.11, mix=0.65)])
glass = song.track("07 PRISM ANSWER", "fm86", "slab/glass-lead", volume=0.22, pan=0.27,
    params=dict(volume=0.70, op1_r4=77, op5_r4=77, op3_ol=78, op4_ol=73,
                lfo_pmd=0, feedback=1),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=550, p2_hz=3600, p2_db=-2.5, hs_hz=9000, hs_db=-4),
        fx("chorus2", "bell-widener", mix=0.16),
        fx("comp2", ratio=1, thresh=0, makeup=17)])
pad = song.track("08 HORIZON", "juno2", "lush-pad", volume=0.62,
    unison=dict(count=2, voices=16, detune=13, spread=0.8, blend=0.8),
    params=dict(sub=0, vib=0.016, lfo_rate=0.34, detune=0.22,
                cutoff=1200, env=0.12, lfovcf=0.018, kybd=0.22,
                atk=0.38, rel=0.85, level=0.19, age=0.23),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=330, p1_hz=480, p1_db=-2.5,
           p2_hz=2300, p2_db=-1.8, hs_hz=7000, hs_db=-3),
        fx("chorus2", "juno-ii", depth=0.8, mix=0.32),
        fx("comp2", key=kick, thresh=-24, ratio=3, atk=0.006, rel=0.15, mix=0.75)])
brass = song.track("09 SOLAR BRASS", "profit5", "ob-jump-brass", volume=0.43, pan=0.08,
    params=dict(cutoff=1050, res=0.12, env=0.28, f_atk=0.025,
                f_dec=0.38, f_sus=0.2, a_atk=0.012, a_sus=0.6,
                a_rel=0.26, fine_b=0.075, level=0.25, heat=0.10),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=300, p1_hz=550, p1_db=-2,
           p2_hz=2900, p2_db=-1.7, hs_hz=7500, hs_db=-2),
        fx("chorus2", "juno-i-mild", mix=0.16)])
lead = song.track("10 ION TRAIL", "ms20", "portamento-highway-lead", volume=0.33,
    params=dict(cutoff=1750, resonance=0.48, env_amount=1.45,
                drive=0.9, detune=0.06, amp_attack=0.013, amp_release=0.15,
                filter_decay=0.4, mg_pitch=0.0018, portamento=0.035, level=0.38),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=260, p1_hz=650, p1_db=-1.5,
           p2_hz=3500, p2_db=-2, hs_hz=6500, hs_db=-3)])
sweep = song.track("11 AERODYNAMICS", "concoction", "noise-sweep", volume=0.13, pan=-0.1,
    params=dict(level=0.45, e1_a=0.25, e1_r=0.4, f_res=0.22),
    fx=[fx("eq2", hpf_on="ON", hpf_hz=850, hs_hz=8000, hs_db=-6)])
echo = song.bus("ORBIT ECHO", volume=1.0, fx=[
    fx("delay2", sync="SYNC", div="1/8.", mode="PING", char="TAPE",
       fb=0.32, lowcut=450, damp=3800, drive=0.15, mod=0.10, duck=0.3, mix=1),
    fx("eq2", hpf_on="ON", hpf_hz=420, hs_hz=6500, hs_db=-4),
])
space = song.bus("NIGHT HALL", volume=1.0, fx=[
    fx("verb2", "big-hall", decay=2.8, predelay=0.033, lowcut=450,
       damp=4200, tone=6500, mod=4, width=1, mix=1),
    fx("eq2", hpf_on="ON", hpf_hz=400, p1_hz=550, p1_db=-2.5),
    fx("comp2", key=kick, thresh=-25, ratio=2.5, atk=0.006, rel=0.22),
])
for tr, send in [(arp,-8),(glass,-8),(lead,-8),(perc,-20)]: tr.send(echo, send)
for tr, send in [(pad,-5),(brass,-12),(glass,-14),(lead,-12),(sweep,-12)]: tr.send(space, send)

# Deliberate rootless voicings; each object is (bass MIDI, upper chord,
# arpeggio tones, duration). The dominant's E# gives the return tension.
A = [
    (42,[57,61,64,68],[54,61,64,68,69],8),       # F#m9
    (40,[56,59,61,66],[56,59,61,64,66],8),       # E6/9
    (38,[54,57,61,64],[54,57,61,64,69],8),       # Dmaj9
    (35,[57,61,62,66],[54,57,61,62,66],4),       # Bm9
    (37,[54,56,59,61],[56,59,61,66,68],2),       # C#7sus4
    (37,[53,56,59,62],[53,56,59,62,68],2),       # C#7b9
]
B = [
    (38,[54,57,61,64],[57,61,64,66,69],4),       # Dmaj9
    (40,[56,61,62,66],[56,61,62,66,68],4),       # E13
    (37,[56,59,63,64],[56,59,63,64,68],4),       # C#m9
    (42,[57,61,64,68],[57,61,64,68,69],4),       # F#m9
    (35,[57,61,62,66],[57,61,62,66,69],4),
    (40,[56,61,62,66],[56,61,62,66,68],4),
    (33,[56,59,61,64],[56,59,61,64,68],4),       # Amaj9
    (37,[53,56,59,62],[53,56,59,62,68],4),
]
C = [
    (38,[54,57,61,64],[54,57,61,64,69],8),
    (40,[55,59,62,66],[55,59,62,66,67],8),       # Em9: borrowed minor v of A
    (42,[57,61,64,68],[54,61,64,68,69],8),
    (37,[54,56,59,61],[54,56,59,61,68],6),
    (37,[53,56,59,62],[53,56,59,62,68],2),
]

def spans(sec, progression):
    t=i=0
    while t < sec.length:
        root, chord, tones, dur = progression[i % len(progression)]
        dur=min(dur, sec.length-t)
        yield t, root, chord, tones, dur
        t += dur
        i += 1

# Rhythm foundation. Hats lean by ~2 ms, backbeat by 6 ms; bass stays
# anchored. Fills are composed at phrase ends, never randomized globally.
for sec in song.sections:
    if sec == brk: continue
    kc, sc, hc, pc = [t.clip(sec) for t in (kick,snare,hats,perc)]
    for bar in range(sec.bars):
        t=bar*4
        kicks = [0,1,2,3]
        if sec == intro and bar < 4: kicks=[]
        if sec == build and bar < 4: kicks=[0,2]
        if sec == outro and bar >= 4: kicks=[]
        if bar == sec.bars-1 and sec in (lift,wide,tunnel,build,peak): kicks=[0,1,2]
        for b in kicks: kc.note(36,t+b,0.12,113 if b in (0,2) else 106)
        backbeat = sec not in (intro,outro) or (sec == intro and bar >= 6) or (sec == outro and bar < 4)
        if backbeat:
            for b in [1,3]:
                sc.note(38,t+b+0.012,0.1,108 if b==1 else 113)
                if sec in (wide,peak): sc.note(39,t+b+0.019,0.1,68)
            if bar % 4==3 and sec != build: sc.note(38,t+2.75,0.08,40)
        if not (sec == intro and bar < 2) and not (sec == outro and bar >= 6):
            for j in range(8):
                b=j*0.5
                oh = j % 2 == 1 and sec in (lift,wide,peak) and bar % 4 != 3
                hc.note(46 if oh else 42,t+b+(0.004 if j%2 else 0),0.05,
                        (83 if oh else 68) + (7 if j%2 else -7))
            if sec in (wide,tunnel,peak) and bar % 2:
                for b in [1.75,3.75]: hc.note(42,t+b+0.014,0.04,43)
        if sec in (cruise,tunnel,peak) and bar % 2 == 1:
            for b in [0.75,2.5]: pc.note(38,t+b+0.005,0.06,57)
        if bar % 8 == 7 and sec != outro:
            for j,b in enumerate([2.5,3,3.5,3.75]):
                pc.note(45,t+b,0.12,78+j*8)
            pc.automate("tom_tune",(t+2.5,190),(t+3.9,95))
        if sec==build and bar>=6:
            for j in range(4 if bar==6 else 8):
                sc.note(38,t+j*(1 if bar==6 else .5),.07,55+j*6)
    hc.humanize(time=0.002,vel=5)

# Each section owns its filter contour. Long ramps yield drama while
# the actual notes remain economical and sharply articulated.
for sec in song.sections:
    prog = B if sec in (wide,peak) else C if sec==brk else A
    bc=bass.clip(sec)
    ac=arp.clip(sec)
    gc=glass.clip(sec)
    pc=pad.clip(sec)
    cc=brass.clip(sec)
    lc=lead.clip(sec)
    for t,root,chord,tones,dur in spans(sec,prog):
        # Walking octaves and a few pickups. Four-to-the-floor kick is
        # distinct from these shorter notes; no permanent reverb/chorus.
        if sec != brk and not (sec==intro and t<16) and not (sec==outro and t>=16):
            for j in range(int(dur*2)):
                pos=t+j*.5
                if sec==build and pos>=sec.length-1: continue
                if sec==outro and pos>=16: continue
                pitch=root + (12 if j%8 in (3,7) else 0)
                if j%16==14: pitch=root+7
                bc.note(pitch,pos+0.022,.28 if j%2 else .31,100 if j%2 else 111)
        # Main arp uses a 3+3+2 accent against a 16-step pitch cycle.
        if sec != brk or t>=16:
            for j in range(int(dur*4)):
                pos=t+j*.25
                if sec==intro and pos<8: continue
                if sec==brk and j%2: continue
                if sec==outro and pos>=24: continue
                if sec==build and pos>=sec.length-.75: continue
                if j%16==15: continue
                idx=[0,2,1,3,1,4,2,3,0,2,4,3,1,2,3,4][j%16]
                pitch=tones[idx] + 12 + (12 if sec==peak and pos>=64 and j%8==6 else 0)
                ac.note(pitch,pos,.14 if j%8 else .18,91 if j%8 in (0,3,6) else 73)
        # The pad is absent through most of the tunnel: clearing space
        # makes its eventual return larger than another gain increase.
        if sec in (intro,lift,wide,brk,build,peak,outro) or (sec==cruise and t>=32):
            pc.chord(chord,t,min(dur-.12,7.8),vel=78 if sec in (intro,brk) else 87,strum=.007)
        # Sparse FM shards, on a displaced 3-step cycle and away from
        # the brass attack; upper-register answers, not a second wall.
        if sec in (lift,wide,tunnel,brk,peak) and (int(t)//4)%2==0:
            for j,p in enumerate([tones[3]+12,tones[1]+12,tones[4]+12]):
                at=t+.75+j*.75
                if at<t+dur: gc.note(p,at,.17,64+j*5)
        if sec in (wide,peak) or (sec==lift and t>=16):
            for b,ln in [(0.75,.55),(2.5,.75)]:
                if b<dur: cc.chord([chord[0],chord[1],chord[3]],t+b,min(ln,dur-b),85,strum=.006)
        # Fragmentary two/three-note calls every four bars, with long
        # empty answers. The texture carries the hook.
        if sec in (wide,peak,tunnel) and int(t)%16==8:
            notes=[(1.5,tones[3],.70),(2.75,tones[2],.45),(3.5,tones[1],1.3)]
            for b,p,ln in notes:
                if b<dur: lc.note(p+12,t+b,min(ln,dur-b),88)
    low,high = {intro:(260,820),cruise:(650,1100),lift:(1100,2600),
                wide:(1900,2600),tunnel:(500,1300),brk:(240,620),
                build:(420,3200),peak:(2300,3500),outro:(1450,220)}[sec]
    ac.ramp("cutoff",0,sec.length,low,high,tension=-.25)
    pc.ramp("cutoff",0,sec.length,650 if sec in (intro,brk) else 1100,
            2200 if sec in (wide,peak) else 950,tension=-.1)
    bc.ramp("cutoff",0,sec.length,510,780 if sec in (lift,wide,peak) else 570)
    # A little articulation changes with the rising filter, not just brightness.
    if sec in (lift,build): ac.ramp("f_dec",0,sec.length,.10,.22)

# An extra sustained brass answer gives the last eight bars their own
# identity; rootless 9ths, with no key-change gimmick.
for t,root,chord,tones,dur in spans(peak,B):
    if t>=64:
        next(c for c in brass.clips if c.start == peak.start).chord([chord[1],chord[2],chord[3]],t+3.25,.65,75)

# Whispers of swept air only at arrivals; no omnipresent white noise.
for sec in (intro,lift,build):
    sc=sweep.clip(sec,at_bar=sec.bars-2,bars=2)
    sc.note(66,0,7.65,80)
    sc.ramp("f_cut",0,7.65,600,6200,tension=-.35)
    sc.ramp("volume",0,7.9,.05,.23,tension=-.2)

# A resolved last chord with a proper decay rather than cutting the bus.
pad.clips[-1].notes = [n for n in pad.clips[-1].notes if n["start"] < 24]
pad.clips[-1].note(66,24,7.2,67)
pad.clips[-1].chord([57,61,64,68],24,7.2,70)
arp.ride({intro:(-9,-2),brk:-5,tunnel:-1,peak:1,outro:(0,-16)})
pad.ride({intro:-2,cruise:-3,lift:-1,wide:0,brk:1,build:-1,peak:1,outro:(-1,-8)})
glass.ride({brk:2,peak:-1})
brass.ride({peak:1})
lead.ride({tunnel:-2,peak:1})
echo.ride({brk:2,outro:(0,-9)})
space.ride({brk:1.5,outro:(0,-8)})

song.master(subsonic=True,fx=[
    fx("eq2", hpf_on="ON", hpf_hz=25, p1_hz=330, p1_db=-0.8,
       p1_q=.65, hs_hz=10500, hs_db=.8),
    fx("bus2", "master-glue", thresh=-13, makeup=.6, color=.08, mix=.7),
    fx("limiter2", gain=7, ceil=-3.0, look=3, rel=.14),
])


# Keep the arrangement readable: no silent placeholder clips.
for tr in song.tracks:
    tr.clips = [c for c in tr.clips if c.notes]
    if tr.machine is not None:
        # Capture fresh-instance defaults and label the saved sound with
        # its factory bank. The project's parameters remain authoritative.
        tr.params = {**{pid: p.default for pid, p in tr.machine.params.items()},
                     **tr.params}
        tr.preset = "afterimage/" + tr.name[3:].lower().replace(" ", "-")

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render",action="store_true")
    parser.add_argument("--stems",action="store_true")
    parser.add_argument("--preview",action="store_true")
    args=parser.parse_args()
    path=Path(song.save(Path(ROOT)/"demos"/"afterimage_express.slab"))
    render_dir=Path(ROOT)/"scratch"/"afterimage_express"
    render_dir.mkdir(parents=True,exist_ok=True)
    if not(args.preview or args.render): return
    output=render_dir/"preview.wav" if args.preview else Path(ROOT)/"songs"/"afterimage_express.wav"
    cmd=[SLAB,str(path),"--render",str(output),"--tail","4",
         "--title",song.title,"--artist","Slab Sessions","--bits","24"]
    if args.preview: cmd += ["--range",f"{wide.start}:{wide.start+32}"]
    if args.stems:
        cmd += ["--stems",str(render_dir/("preview-stems" if args.preview else "stems")),"--stem-kind","all"]
    began=time.monotonic()
    r=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,start_new_session=True)
    log=r.stdout+"\n"+r.stderr
    (render_dir/("preview-render.log" if args.preview else "render.log")).write_text(log)
    print(log[-8000:])
    print(f"Render wall time: {time.monotonic()-began:.1f} seconds")
    if r.returncode: raise SystemExit(r.returncode)
    from slabkit.analyze import analyze_wav, print_report
    sections=[] if args.preview else [(s.name,song.seconds_at(s.start),song.seconds_at(s.end)) for s in song.sections]
    stats=analyze_wav(str(output),sections)
    (render_dir/("preview-analysis.json" if args.preview else "analysis.json")).write_text(json.dumps(stats,indent=2)+"\n")
    print_report(str(output),stats)

if __name__=="__main__": main()
