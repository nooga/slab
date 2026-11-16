#!/usr/bin/env python3
"""Expanded Cream correction pilot: 23 continuous and 6 categorical controls (legacy 26-control profile supported)."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import time
import numpy as np
from generate import ROOT,CONTROLS as OLD,GIB
from diverse_data import recipe as base_recipe,schema as base_schema,context,guard,render_file
from slabkit import Song,fx,machine
from ablations import multires

PROFILE=os.environ.get('SLAB_SOUNDMATCH_PROFILE','ranges')
if PROFILE not in ['legacy26','ranges','oscillator']:raise ValueError('Unknown SLAB_SOUNDMATCH_PROFILE')
BASE=ROOT/({'legacy26':'scratch/soundmatch-expanded','ranges':'scratch/soundmatch-expanded-ranges','oscillator':'scratch/soundmatch-oscillator-5k'}[PROFILE])
TRAIN_COUNT=5000 if PROFILE=='oscillator' else 2000
TOTAL_COUNT=TRAIN_COUNT+400
CONTROLS={**OLD,'lvl1':(.2,1,False),'lvl2':(0,1,False),'lvl3':(0,.7,False),
 'f_atk':(.001,1,True),'f_sus':(0,1,False),'f_rel':(.02,1,True),
 'a_atk':(.001,.8,True),'a_dec':(.03,1.5,True),'a_sus':(.1,1,False),
 'lfo_rate':(.15,12,True),'lfo_pitch':(0,.3,False)}
CATEGORIES={'wave1':5,'wave2':5,'lfo_wave':4}
if PROFILE=='ranges':CATEGORIES.update(range1=5,range2=5,range3=5)
if PROFILE=='oscillator':
    CONTROLS={'lvl1':(.2,1,False),'lvl2':(.1,1,False),'lvl3':(.1,.7,False),'detune2':(-.15,.15,False)}
    CATEGORIES={'wave1':5,'wave2':5,'range1':5,'range2':5,'range3':5}
KEYS=list(CONTROLS);CATS=list(CATEGORIES);ALL=KEYS+CATS
NEW=[k for k in ALL if k not in OLD]

def schema():
    m=machine('cream')
    if PROFILE=='oscillator':
        removed={m.resolve(k) for k in ALL};fields=[]
        for k,p in m.params.items():
            if k in removed:continue
            if p.type=='switch':fields.extend(dict(key=k,option=i) for i in range(len(p.options)))
            else:fields.append(dict(key=k,min=p.min,max=p.max,log=p.curve=='exp' and p.min>0))
        return fields
    removed={m.resolve(k) for k in NEW}
    return [f for f in base_schema() if f['key'] not in removed]

def recipe(i,offset=0):
    if PROFILE=='oscillator':return oscillator_recipe(i,offset)
    split='train' if i<2000 else 'validation' if i<2200 else 'test'
    group='familiar' if split=='train' else ['familiar','patch','phrase','joint'][((i-2000)%200)//50]
    r=base_recipe(dict(index=i,seed=(20400000 if PROFILE=='legacy26' else 20500000)+i+offset,split=split,group=group),base_schema());rng=random.Random(r['seed']+999)
    target={**r['target'],**{k:rng.uniform(.08,.92) for k in CONTROLS if k not in OLD},**{k:rng.randrange(n) for k,n in CATEGORIES.items()}}
    current=dict(target);bucket=i%10
    mode='identity' if bucket<2 else 'new-only' if bucket<6 else 'combined'
    chosen=[]
    if mode!='identity':
        chosen=rng.sample(NEW,rng.randrange(3,7))
        if not any(k in CATEGORIES for k in chosen):chosen[-1]=rng.choice(CATS)
        if mode=='combined':chosen+=rng.sample(list(OLD),rng.randrange(3,5))
    for k in chosen:
        if k in CATEGORIES:current[k]=rng.choice([n for n in range(CATEGORIES[k]) if n!=target[k]])
        else:current[k]=float(np.clip(target[k]+(1 if target[k]<.5 else -1)*rng.uniform(.35,.7),0,1))
    r.update(target=target,current=current,changed=chosen,severity=mode,context=context(r['fixed'],schema()))
    r['correction']={k:target[k]-current[k] for k in KEYS}
    return r

def oscillator_recipe(i,offset=0):
    split='train' if i<TRAIN_COUNT else 'validation' if i<TRAIN_COUNT+200 else 'test'
    group='familiar' if split=='train' else ['familiar','patch','phrase','joint'][((i-TRAIN_COUNT)%200)//50]
    row=base_recipe(dict(index=i,seed=20600000+i+offset,split=split,group=group),base_schema());rng=random.Random(row['seed']+999)
    m=machine('cream');fixed={k:p.default for k,p in m.params.items()}
    settings=dict(osc3_mode=1,wave3=rng.choice([0,1]),sync2=0,env_osc2=0,detune3=0,
        noise=0,drive=0,cutoff=12000,emphasis=.05,contour=0,kbd=0,flt_mode=0,
        f_atk=.001,f_dec=.1,f_sus=1,f_rel=.1,a_atk=.005,a_dec=.1,a_sus=1,a_rel=.15,
        lfo_rate=5,lfo_wave=0,lfo_pitch=0,lfo_cut=0,glide=0,age=0,level=.6,fbk=0)
    if group in ['patch','joint']:settings['wave3']=3 if split=='validation' else 2
    for k,v in settings.items():fixed[m.resolve(k)]=v
    target={k:rng.uniform(.08,.92) for k in KEYS};target.update({k:rng.randrange(n) for k,n in CATEGORIES.items()})
    current=dict(target);bucket=i%10;mode='identity' if bucket<2 else 'sparse' if bucket<6 else 'dense'
    chosen=[] if mode=='identity' else rng.sample(ALL,rng.randint(1,2) if mode=='sparse' else rng.randint(3,5))
    for k in chosen:
        if k in CATEGORIES:current[k]=rng.choice([n for n in range(CATEGORIES[k]) if n!=target[k]])
        else:current[k]=float(np.clip(target[k]+(1 if target[k]<.5 else -1)*rng.uniform(.3,.65),0,1))
    row.update(fixed=fixed,patch=f'osc3-wave-{settings["wave3"]}',target=target,current=current,changed=chosen,severity=mode,context=context(fixed,schema()),correction={k:target[k]-current[k] for k in KEYS})
    return row

def make_project(path,row,state):
    p={k:(lo*(hi/lo)**state[k] if log else lo+(hi-lo)*state[k]) for k,(lo,hi,log) in CONTROLS.items()}
    params=dict(row['fixed']);m=machine('cream')
    for k,v in p.items():
        if k not in ['sweep','comp_thresh','delay_mix','delay_fb']:params[m.resolve(k)]=v
    for k,n in CATEGORIES.items():
        assert isinstance(state[k],int) and 0<=state[k]<n
        params[m.resolve(k)]=state[k]
    song=Song('Expanded Cream correction',bpm=120,groove_seed=row['seed']);section=song.section('PHRASE',2)
    track=song.track('SYNTH','cream',params=params,volume=.18,fx=[fx('comp2',thresh=p.get('comp_thresh',-12),ratio=3,makeup=0),fx('delay2',time=.25,fb=p.get('delay_fb',.2),mix=p.get('delay_mix',0),damp=4000)])
    clip=track.clip(section)
    for pitch,onset,duration,velocity in row['notes']:clip.note(pitch,onset,duration,velocity)
    if PROFILE!='oscillator':track.automate('cutoff',(0,p['cutoff']),(8,p['cutoff']*p['sweep']))
    song.master(volume=.7);song.save(str(path),quiet=True)

def generate(count=None,benchmark=False):
    count=TOTAL_COUNT if count is None else count
    guard(reserve=(15 if PROFILE=='oscillator' else 8)*GIB if not benchmark else GIB)
    out=BASE.with_name(BASE.name+'-bench') if benchmark else BASE;out.mkdir(exist_ok=False)
    manifest=machine('cream')
    for k,n in CATEGORIES.items():assert len(manifest.params[manifest.resolve(k)].options)==n
    fields=schema();run=dict(profile=PROFILE,count=count,controls=CONTROLS,categories=CATEGORIES,context_schema=fields,source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),renderer_sha256=hashlib.sha256((ROOT/'zig-out/bin/slab').read_bytes()).hexdigest(),scope='Known notes and chain; expanded parameter task. Holdout patch and phrase families. No audio-normalization in training.')
    (out/'run.json').write_text(json.dumps(run,indent=2));started=time.perf_counter()
    def work(i):
        guard();r=recipe(i,100000 if benchmark else 0);folder=out/str(r['seed']);folder.mkdir();r['folder']=str(folder)
        for name in ['target','current']:make_project(folder/f'{name}.slab',r,r[name])
        target=render_file(folder/'target.slab',folder/'target.wav')
        if r['changed']:current=render_file(folder/'current.slab',folder/'current.wav')
        else:os.link(folder/'target.wav',folder/'current.wav');current=target
        assert not r['changed'] or target['sha256']!=current['sha256']
        r['audio']={'target':target,'current':current};(folder/'labels.json').write_text(json.dumps(r,indent=2));return r
    rows=[]
    with ThreadPoolExecutor(max_workers=8) as pool:
        for n,r in enumerate(pool.map(work,range(count)),1):
            rows.append(r)
            if n%200==0 or n==count:print(f'generated {n}/{count}, {time.perf_counter()-started:.1f}s, {shutil.disk_usage(ROOT).free/GIB:.1f} GiB free',flush=True)
    (out/'rows.json').write_text(json.dumps(rows));seconds=time.perf_counter()-started
    (out/'generation.json').write_text(json.dumps(dict(seconds=seconds,count=count,projected_full_seconds=seconds/count*TOTAL_COUNT,free_gib=shutil.disk_usage(ROOT).free/GIB),indent=2))
    print(f'Generation complete: {seconds:.1f}s; projected full run {seconds/count*TOTAL_COUNT/60:.1f}min',flush=True)

def prepare():
    rows=json.loads((BASE/'rows.json').read_text());guard(reserve=2*GIB)
    path=BASE/'features.npy'
    if path.exists():raise RuntimeError('Feature cache exists')
    data=np.lib.format.open_memmap(path,mode='w+',dtype='float32',shape=(len(rows),2,6,128,128));start=time.perf_counter()
    def work(r):
        folder=Path(r['folder']);a=multires(folder/'target.wav');b=multires(folder/'current.wav') if r['changed'] else a.copy()
        return np.stack([a,b])
    with ThreadPoolExecutor(max_workers=2) as pool:
        for i,value in enumerate(pool.map(work,rows)):
            assert np.isfinite(value).all();data[i]=value
            if (i+1)%400==0:guard();data.flush();print(f'features {i+1}/{len(rows)}',flush=True)
    data.flush();(BASE/'features-ready.json').write_text(json.dumps(dict(seconds=time.perf_counter()-start,shape=list(data.shape),bytes=path.stat().st_size)));print('Features ready',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['bench','generate','prepare']);a=p.parse_args()
    if a.action=='prepare':prepare()
    else:generate(24 if a.action=='bench' else TOTAL_COUNT,a.action=='bench')
