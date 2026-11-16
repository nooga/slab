#!/usr/bin/env python3
"""Reproducible diverse Cream pairs, family holdouts, bounded concurrent renders."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import os
from pathlib import Path
import random
import shutil
import subprocess
import time
import numpy as np
from audit import read

from generate import ROOT, CONTROLS, GIB, physical
from slabkit import Song, fx, machine

BASE=ROOT/'scratch/soundmatch-diverse-5k'
TRAIN_PATCHES=['cream-lead','synthwave-bass','outstanding-funk-bass']
TRAIN_PHRASES=['staccato','pluck','legato','sustain']
VALIDATION_PATCH='bass-mog'
TEST_PATCH='growl'
VAL_PHRASE='syncopated'
TEST_PHRASE='octave-answer'
SEED=20300000
BUDGET=24*GIB
FLOOR=25*GIB


def guard(path=ROOT,reserve=16*1024**2):
    if shutil.disk_usage(path).free<FLOOR+reserve:raise RuntimeError('25 GiB free-space guard')


def schema():
    m=machine('cream')
    tuned={m.resolve(k) for k in CONTROLS if k not in ['sweep','comp_thresh','delay_mix','delay_fb']}
    fields=[]
    for k,p in m.params.items():
        if k in tuned:continue
        if p.type=='switch':
            fields.extend(dict(key=k,option=i) for i in range(len(p.options)))
        else:fields.append(dict(key=k,min=p.min,max=p.max,log=p.curve=='exp' and p.min>0))
    return fields


def context(fixed,fields):
    out=[]
    for f in fields:
        v=fixed[f['key']]
        if 'option' in f:out.append(float(round(v)==f['option']))
        elif f['log']:out.append(math.log(v/f['min'])/math.log(f['max']/f['min']))
        else:out.append((v-f['min'])/(f['max']-f['min']))
    assert all(-1e-6<=x<=1+1e-6 for x in out)
    return out


def plan(count=5000):
    rows=[]
    for i in range(count+600):
        if i<count:split,group='train','familiar'
        elif i<count+200:
            j=i-count;split='validation';group='familiar' if j<100 else ('patch' if j<150 else 'phrase')
        else:
            split='test';group=['familiar','patch','phrase','joint'][(i-count-200)//100]
        rows.append(dict(index=i,seed=SEED+i,split=split,group=group))
    return rows


def recipe(row,fields):
    row=dict(row);rng=random.Random(row['seed'])
    patch=rng.choice(TRAIN_PATCHES);phrase=rng.choice(TRAIN_PHRASES)
    if row['group'] in ['patch','joint']:patch=VALIDATION_PATCH if row['split']=='validation' else TEST_PATCH
    if row['group'] in ['phrase','joint']:phrase=VAL_PHRASE if row['split']=='validation' else TEST_PHRASE
    m=machine('cream')
    fixed={k:p.default for k,p in m.params.items()}
    fixed.update(json.loads((ROOT/f'machines/cream/presets/{patch}.preset').read_text())['params'])
    # These varied controls are known context, never correction targets.
    fixed['cr-a-atk']=rng.uniform(.06,.4) if phrase=='sustain' else rng.uniform(.001,.012)
    fixed['cr-a-dec']=rng.uniform(.15,1.2)
    fixed['cr-a-sus']=rng.uniform(.12,.5) if phrase=='pluck' else rng.uniform(.6,1)
    fixed['cr-glide']=rng.uniform(.02,.12) if phrase=='legato' else 0
    register=rng.choice(['bass','lead']);root=rng.randrange(36,49) if register=='bass' else rng.randrange(57,73)
    onsets={'staccato':list(range(8)),'pluck':[i*.5 for i in range(16)],'legato':[0,1.5,3,4.5,6],
            'sustain':[0,4],'syncopated':[0,.75,2.25,3,4.75,6.5],
            'octave-answer':[0,.5,1.75,3,4,5.5,6.5]}[phrase]
    notes=[]
    for j,onset in enumerate(onsets):
        interval=([0,12,7,0,12,3,7][j] if phrase=='octave-answer' else rng.choice([0,2,3,5,7,10,12]))
        duration={'staccato':rng.uniform(.2,.5),'pluck':rng.uniform(.12,.3),'legato':1.6,
                  'sustain':3.6,'syncopated':rng.uniform(.2,.65),'octave-answer':rng.uniform(.2,.8)}[phrase]
        notes.append([root+interval,onset,min(duration,8-onset),rng.randrange(45,121)])
    target={k:rng.uniform(.08,.92) for k in CONTROLS}
    current=dict(target);bucket=row['index']%20
    severity='identity' if bucket<4 else 'subtle' if bucket<9 else 'medium' if bucket<15 else 'large'
    changed=[] if severity=='identity' else rng.sample(list(CONTROLS),rng.randrange(1,4))
    for k in changed:
        lo,hi={'subtle':(.03,.1),'medium':(.15,.3),'large':(.4,.7)}[severity]
        direction=(1 if target[k]<.5 else -1) if severity=='large' else rng.choice([-1,1])
        current[k]=max(0,min(1,target[k]+direction*rng.uniform(lo,hi)))
    row.update(patch=patch,phrase=phrase,register=register,severity=severity,notes=notes,fixed=fixed,
        context=context(fixed,fields),target=target,current=current,changed=changed,
        correction={k:target[k]-current[k] for k in CONTROLS})
    return row


def make_project(path,row,state):
    p={k:physical(k,v) for k,v in state.items()}
    params=dict(row['fixed'])
    m=machine('cream')
    for k,v in p.items():
        if k not in ['sweep','comp_thresh','delay_mix','delay_fb']:params[m.resolve(k)]=v
    song=Song('Diverse correction',bpm=120,groove_seed=row['seed'])
    section=song.section('PHRASE',2)
    track=song.track('SYNTH','cream',params=params,volume=.18,fx=[
        fx('comp2',thresh=p['comp_thresh'],ratio=3,makeup=0),
        fx('delay2',time=.25,fb=p['delay_fb'],mix=p['delay_mix'],damp=4000)])
    clip=track.clip(section)
    for pitch,onset,duration,velocity in row['notes']:clip.note(pitch,onset,duration,velocity)
    track.automate('cutoff',(0,p['cutoff']),(8,p['cutoff']*p['sweep']))
    song.master(volume=.7);song.save(str(path),quiet=True)


def inspect_wav(path):
    audio=read(path)
    peak=float(np.max(np.abs(audio)))
    rms=float(np.sqrt(np.mean(audio*audio)))
    if not np.isfinite(audio).all() or rms<1e-5 or peak>=.999:
        raise RuntimeError(f"Silent, nonfinite or clipped example: {path}: {peak}, {rms}")
    return dict(rate=48000,frames=len(audio),seconds=len(audio)/48000,peak=peak,rms=rms,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def render_file(project,wav):
    guard(wav.parent)
    with wav.with_suffix('.log').open('w') as log:
        subprocess.run([str(ROOT/'zig-out/bin/slab'),str(project),'--render',str(wav),
            '--bits','16','--no-dither','--rate','48000','--tail','0.5','--threads','1'],cwd=ROOT,
            stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
    return inspect_wav(wav)


def generate(out,workers,benchmark=False,resume=False):
    fields=schema();rows=plan()
    if benchmark:
        # Cover all split/patch/phrase cases without consuming production seeds.
        rows=[rows[round(i*(len(rows)-1)/23)] for i in range(24)]
        for row in rows:row['seed']+=100000
    expected=len(rows)*(2*1024**2+6*128*128*2*4)
    guard(ROOT,reserve=expected)
    existed=out.exists()
    out.mkdir(parents=True,exist_ok=resume)
    if existed and not resume:raise RuntimeError('Output exists')
    metadata=dict(schema=1,training_count=5000 if not benchmark else None,count=len(rows),workers=workers,
        floor_gib=25,budget_gib=24,context_schema=fields,controls=CONTROLS,
        train_patches=TRAIN_PATCHES,train_phrases=TRAIN_PHRASES,validation_patch=VALIDATION_PATCH,test_patch=TEST_PATCH,
        validation_phrase=VAL_PHRASE,test_phrase=TEST_PHRASE,
        renderer_sha256=hashlib.sha256((ROOT/'zig-out/bin/slab').read_bytes()).hexdigest(),
        source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        presets_sha256={p:hashlib.sha256((ROOT/f'machines/cream/presets/{p}.preset').read_bytes()).hexdigest()
                        for p in TRAIN_PATCHES+[VALIDATION_PATCH,TEST_PATCH]},
        note='Identity current WAV hardlinks target; large denotes parameter perturbation, not a verified perceptual rating.')
    if existed:
        previous=json.loads((out/'run.json').read_text())
        assert previous==metadata,'Cannot resume with changed generator/renderer/plan'
    else:(out/'run.json').write_text(json.dumps(metadata,indent=2))
    start=time.perf_counter();free_start=shutil.disk_usage(out).free
    def worker(item):
        folder=out/f'{item["seed"]}'
        if (folder/'labels.json').exists():
            return json.loads((folder/'labels.json').read_text()),True
        folder.mkdir(exist_ok=True);row=recipe(item,fields);row['folder']=str(folder)
        audio={}
        for label in ['target','current']:
            project=folder/f'{label}.slab';wav=folder/f'{label}.wav'
            make_project(project,row,row[label])
            if label=='current' and not row['changed']:
                if wav.exists():wav.unlink()
                os.link(folder/'target.wav',wav)
                audio[label]=audio['target']
            else:audio[label]=render_file(project,wav)
        assert bool(row['changed'])==(audio['target']['sha256']!=audio['current']['sha256'])
        row['audio']=audio
        row['payload_bytes']=sum(p.stat().st_size for p in folder.rglob('*') if p.is_file())
        temp=folder/'labels.tmp';temp.write_text(json.dumps(row,indent=2));temp.replace(folder/'labels.json')
        return row,False
    finished=[];new=0;used=0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for n,(row,cached) in enumerate(pool.map(worker,rows),1):
            finished.append(row);new+=not cached;used+=row['payload_bytes']
            if used>BUDGET:raise RuntimeError('24 GiB output budget reached')
            if n%100==0 or n==len(rows):
                elapsed=time.perf_counter()-start
                progress=dict(completed=n,total=len(rows),new=new,seconds=elapsed,seconds_per_pair=elapsed/max(n,1),
                              payload_gib=used/GIB,free_gib=shutil.disk_usage(out).free/GIB)
                (out/'progress.json').write_text(json.dumps(progress,indent=2));print(json.dumps(progress),flush=True)
                guard(out)
    (out/'rows.json').write_text(json.dumps(finished))
    report=dict(count=len(rows),completed=len(finished),new=new,seconds=time.perf_counter()-start,
                free_start_gib=free_start/GIB,free_end_gib=shutil.disk_usage(out).free/GIB,payload_bytes=used,
                projected_full_seconds=(time.perf_counter()-start)/len(rows)*5600)
    (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,default=BASE);p.add_argument('--workers',type=int,default=6)
    p.add_argument('--benchmark',action='store_true');p.add_argument('--resume',action='store_true')
    a=p.parse_args()
    if not 1<=a.workers<=8:p.error('workers must be 1..8')
    generate(a.out.resolve(),a.workers,a.benchmark,a.resume)
