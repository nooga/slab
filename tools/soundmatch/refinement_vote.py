#!/usr/bin/env python3
"""Equal-budget single-metric and consensus refinement through real Slab renders."""
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import time
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import torch
import auraloss
from auraloss_trial import CONFIG,tensor
from audit import read,distance
from diverse_data import BASE,ROOT,guard,make_project,render_file
from generate import CONTROLS

OUT=ROOT/'scratch/soundmatch-refinement-vote'
STRATEGIES=['spectral','auraloss','consensus']
KEYS=list(CONTROLS)

def improved(value,old):return value<old-max(1e-6,.001*old)
def select(strategy,proposals,current):
    valid=[p for p in proposals if all(improved(p['scores'][m],current['scores'][m]) for m in (['spectral','auraloss'] if strategy=='consensus' else [strategy]))]
    if not valid:return current
    def rank(p):
        if strategy!='consensus':return p['scores'][strategy]
        return sum(p['scores'][m]/max(current['scores'][m],1e-9) for m in ['spectral','auraloss'])/2
    return min(valid,key=rank)

def main():
    torch.set_num_threads(2);guard();OUT.mkdir(exist_ok=False)
    rows=json.loads((BASE/'feature-rows.json').read_text());predictions={r['seed']:r for r in json.loads((BASE/'model-5000/predictions.json').read_text())}
    selected=[]
    for group in ['familiar','patch','phrase','joint']:
        pool=[r for r in rows if r['split']=='test' and r['group']==group][40:]
        for severity,count in [('identity',2),('subtle',2),('medium',3),('large',3)]:selected.extend([r for r in pool if r['severity']==severity][:count])
    assert len(selected)==40 and len({r['seed'] for r in selected})==40
    plan=dict(seeds=[r['seed'] for r in selected],steps=[.10,.04],proposals_per_strategy=48,strategies=STRATEGIES,tolerance='Each accepted metric must fall by more than max(1e-6, 0.001*current).',consensus_rank='Among candidates that improve both, minimize mean of candidate/current metric ratios.',cache='Identical parameter states share renders and scores; each strategy sees the same 24-neighbor budget per round.',selection='First 2 identity, 2 subtle, 3 medium, 3 large per test group beyond the first 40 previously scored examples.',audio_loss=CONFIG,source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),renderer_sha256=hashlib.sha256((ROOT/'zig-out/bin/slab').read_bytes()).hexdigest())
    (OUT/'plan.json').write_text(json.dumps(plan,indent=2))
    loss=auraloss.freq.MultiResolutionSTFTLoss(**CONFIG);start=time.perf_counter();results=[];renders=0
    for number,row in enumerate(selected,1):
        directory=OUT/str(row['seed']);directory.mkdir();target_path=Path(row['folder'])/'target.wav';target=read(target_path);target_tensor=tensor(target_path)
        # Cache reference spectra; numerically identical to audit.distance.
        def mags(x):
            return [np.abs(np.fft.rfft(np.lib.stride_tricks.sliding_window_view(x,n,axis=0)[::n//4]*np.hanning(n),axis=-1)) for n in [512,2048,8192]]
        reference=mags(target);norms=[max(np.linalg.norm(x),1e-9) for x in reference]
        def score(path):
            audio=read(path);spectral=float(np.mean([np.linalg.norm(a-b)/norm for a,b,norm in zip(reference,mags(audio),norms)]))
            with torch.inference_mode():new=float(loss(torch.from_numpy(audio.T.copy()).float().unsqueeze(0),target_tensor))
            assert np.isfinite([spectral,new]).all()
            return dict(spectral=spectral,auraloss=new)
        def state_id(state):return hashlib.sha256(json.dumps(state,sort_keys=True).encode()).hexdigest()[:20]
        cache={}
        def produce(task):
            sid,state=task;wav=directory/f'{sid}.wav';make_project(wav.with_suffix('.slab'),row,state);render_file(wav.with_suffix('.slab'),wav)
            return sid,dict(state=state,wav=str(wav))
        def evaluate(states):
            nonlocal renders
            missing={state_id(s):s for s in states if state_id(s) not in cache}
            with ThreadPoolExecutor(max_workers=6) as pool:rendered=list(pool.map(produce,missing.items()))
            for sid,result in rendered:result['scores']=score(result['wav']);cache[sid]=result
            renders+=len(rendered)
            return [cache[state_id(s)] for s in states]
        initial=evaluate([predictions[row['seed']]['predicted']])[0]
        assert abs(initial['scores']['spectral']-distance(target,read(initial['wav'])))<1e-10
        current={s:initial for s in STRATEGIES};accepted={s:0 for s in STRATEGIES};trace=[]
        for step in plan['steps']:
            states={}
            for strategy in STRATEGIES:
                states[strategy]=[]
                for key in KEYS:
                    for sign in [-1,1]:
                        s=dict(current[strategy]['state']);s[key]=float(np.clip(s[key]+sign*step,0,1));states[strategy].append(s)
            evaluate(list(itertools.chain.from_iterable(states.values())))
            round_info={}
            for strategy in STRATEGIES:
                chosen=select(strategy,[cache[state_id(s)] for s in states[strategy]],current[strategy])
                edited=chosen is not current[strategy];accepted[strategy]+=int(edited)
                round_info[strategy]=dict(before=current[strategy]['scores'],after=chosen['scores'],edited=edited)
                current[strategy]=chosen
            trace.append(round_info)
        entry=dict(seed=row['seed'],group=row['group'],severity=row['severity'],reference=str(target_path),initial=initial,final=current,accepted=accepted,trace=trace,unique_renders=len(cache))
        for strategy in STRATEGIES:
            shutil.copyfile(current[strategy]['wav'],directory/f'{strategy}.wav');make_project(directory/f'{strategy}.slab',row,current[strategy]['state'])
        (directory/'result.json').write_text(json.dumps(entry,indent=2));results.append(entry)
        (OUT/'results.json').write_text(json.dumps(results,indent=2));guard()
        print(f'{number}/40 complete; {renders} unique renders; {time.perf_counter()-start:.0f}s; {shutil.disk_usage(ROOT).free/2**30:.1f} GiB free',flush=True)
    summary={}
    changed=[r for r in results if r['severity']!='identity']
    for strategy in STRATEGIES:
        summary[strategy]=dict(metrics={m:dict(before=float(np.mean([r['initial']['scores'][m] for r in changed])),after=float(np.mean([r['final'][strategy]['scores'][m] for r in changed])),worsened=sum(r['final'][strategy]['scores'][m]>r['initial']['scores'][m]+1e-6 for r in changed)) for m in ['spectral','auraloss']},unchanged=sum(r['initial']['state']==r['final'][strategy]['state'] for r in changed),identity_changed=sum(read(r['initial']['wav']).tobytes()!=read(r['final'][strategy]['wav']).tobytes() for r in results if r['severity']=='identity'))
    report=dict(summary=summary,seconds=time.perf_counter()-start,unique_renders=renders,changed_count=len(changed),identity_count=40-len(changed),free_gib=shutil.disk_usage(ROOT).free/2**30)
    (OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
    # First distinct PCM outputs, without ranking by scores. Four pairs per matchup.
    trials=[];blind={};used=set();rng=random.Random(20261104)
    for left,right in [('consensus','spectral'),('consensus','auraloss'),('spectral','auraloss')]:
        chosen=[]
        for r in results:
            if r['severity']=='identity' or r['seed'] in used:continue
            a=Path(r['final'][left]['wav']);b=Path(r['final'][right]['wav'])
            if read(a).tobytes()==read(b).tobytes():continue
            chosen.append(r);used.add(r['seed'])
            if len(chosen)==4:break
        sides=['A','B']*(len(chosen)//2)+(['A'] if len(chosen)%2 else []);rng.shuffle(sides)
        for r,side in zip(chosen,sides):
            other='B' if side=='A' else 'A';tid=f'vote-{len(trials)+1:02d}'
            trials.append(dict(id=tid,sources={'reference':r['reference'],side:r['final'][left]['wav'],other:r['final'][right]['wav']}))
            blind[tid]=dict(seed=r['seed'],group=r['group'],assignment={side:left,other:right})
    rng.shuffle(trials)
    (OUT/'manifest.json').write_text(json.dumps(dict(experiment='refinement-vote-v1',title='Refinement strategies',trials=trials),indent=2));(OUT/'blind-key.json').write_text(json.dumps(blind,indent=2))
    print(f'Prepared {len(trials)} blind trials',flush=True)

if __name__=='__main__':main()
