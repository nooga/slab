#!/usr/bin/env python3
"""Evaluate auraloss 0.4.0 and bounded black-box refinement; no weight updates."""
import hashlib
import json
from pathlib import Path
import random
import shutil
import time
import wave
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import torch
import auraloss
from audit import read, distance
from diverse_data import BASE, ROOT, guard, make_project, render_file
from generate import CONTROLS

OUT=ROOT/'scratch/soundmatch-auraloss'
CONFIG=dict(fft_sizes=[512,2048,8192],hop_sizes=[128,512,2048],win_lengths=[512,2048,8192],w_sc=1.,w_log_mag=1.,w_lin_mag=0.,w_phs=0.,sample_rate=48000)
MODELS=['previous-model','model-1000','model-2000','model-5000']

def tensor(path):
    return torch.from_numpy(read(path).T.copy()).float().unsqueeze(0)

def main():
    guard();OUT.mkdir(exist_ok=False);torch.set_num_threads(2)
    loss=auraloss.freq.MultiResolutionSTFTLoss(**CONFIG)
    def score(path,target):
        with torch.inference_mode():
            value=float(loss(tensor(path),target))
        assert np.isfinite(value)
        return value
    started=time.perf_counter()
    renders=json.loads((BASE/'renders.json').read_text())
    rows={r['seed']:r for r in json.loads((BASE/'feature-rows.json').read_text())}
    seeds=sorted({r['seed'] for r in renders if r['kind']=='correction'})
    records=[]
    for i,seed in enumerate(seeds):
        row=rows[seed];folder=Path(row['folder']);target=tensor(folder/'target.wav')
        assert score(folder/'target.wav',target)==0
        values={'unchanged':score(folder/'current.wav',target)}
        for name in MODELS:values[name]=score(BASE/name/'renders'/f'{seed}-correction.wav',target)
        records.append(dict(seed=seed,group=row['group'],severity=row['severity'],scores=values))
        if (i+1)%40==0:print(f'Scored {i+1}/160 pairs',flush=True)
    (OUT/'scores.json').write_text(json.dumps(records,indent=2))
    summary={}
    for name in ['unchanged']+MODELS:
        rr=[r for r in records if r['severity']!='identity']
        before=np.array([r['scores']['unchanged'] for r in rr]);after=np.array([r['scores'][name] for r in rr])
        summary[name]=dict(mean=float(after.mean()),improved=int((after<before-1e-6).sum()),worsened=int((after>before+1e-6).sum()),by_group={g:float(np.mean([r['scores'][name] for r in rr if r['group']==g])) for g in ['familiar','patch','phrase','joint']})
    print(json.dumps(summary,indent=2),flush=True)
    # Validation only: first medium and large case in each available validation group.
    selected=[next(r for r in rows.values() if r['split']=='validation' and r['group']==g and r['severity']==s) for g in ['familiar','patch','phrase'] for s in ['medium','large']]
    predictions={r['seed']:r for r in json.loads((BASE/'model-5000/predictions.json').read_text())}
    refined=[]
    for row in selected:
        target=tensor(Path(row['folder'])/'target.wav')
        for start in ['unchanged','model-5000']:
            directory=OUT/f'{row["seed"]}-{start}';directory.mkdir()
            state=dict(row['current'] if start=='unchanged' else predictions[row['seed']]['predicted'])
            initial=directory/'initial.wav';make_project(initial.with_suffix('.slab'),row,state);render_file(initial.with_suffix('.slab'),initial)
            initial_score=best=score(initial,target);best_wav=initial;accepted=[]
            # Two best-neighbor rounds, 24 proposals per round; no target parameters used.
            for iteration,step in enumerate([.10,.04]):
                tasks=[]
                for key in CONTROLS:
                    for sign in [-1,1]:
                        candidate=dict(state);candidate[key]=float(np.clip(candidate[key]+sign*step,0,1))
                        wav=directory/f'{iteration}-{key}-{sign}.wav';tasks.append((candidate,wav))
                def render(task):
                    candidate,wav=task;make_project(wav.with_suffix('.slab'),row,candidate);render_file(wav.with_suffix('.slab'),wav);return task
                with ThreadPoolExecutor(max_workers=6) as pool:
                    results=list(pool.map(render,tasks))
                ranked=[(score(wav,target),candidate,wav) for candidate,wav in results]
                value,candidate,wav=min(ranked,key=lambda x:x[0])
                if value<best-1e-6:
                    state=candidate;best=value;best_wav=wav;accepted.append(iteration)
            shutil.copyfile(best_wav,directory/'best.wav')
            make_project(directory/'best.slab',row,state)
            entry=dict(seed=row['seed'],group=row['group'],severity=row['severity'],start=start,before=initial_score,after=best,accepted_rounds=accepted,state=state,initial=str(initial),wav=str(directory/'best.wav'),old_before=distance(read(Path(row['folder'])/'target.wav'),read(initial)),old_after=distance(read(Path(row['folder'])/'target.wav'),read(directory/'best.wav')))
            refined.append(entry);print(f'Refine {row["seed"]} {start}: {initial_score:.4f} -> {best:.4f}',flush=True)
            (OUT/'refinement.json').write_text(json.dumps(refined,indent=2))
    # A small reproducible reference/A/B pack; labels concealed in separate key.
    listen=OUT/'listening';listen.mkdir();rng=random.Random(2031);key={};guide=['# Pairwise auraloss refinement trials','','Reference, A, reference, B. Each segment starts 5.25 seconds apart. Choose A, B, or indistinguishable. Same gain; no loudness normalization.','']
    for r in refined:
        if r['start']!='model-5000':continue
        pair=[('before',r['initial']),('refined',r['wav'])];rng.shuffle(pair);key[str(r['seed'])]={letter:name for letter,(name,p) in zip('AB',pair)}
        reference=Path(rows[r['seed']]['folder'])/'target.wav';dest=listen/f'{r["seed"]}-pair.wav'
        with wave.open(str(dest),'wb') as out:
            out.setparams((2,2,48000,0,'NONE','not compressed'))
            for p in [reference,pair[0][1],reference,pair[1][1]]:
                with wave.open(str(p),'rb') as src:out.writeframes(src.readframes(src.getnframes()))
                out.writeframes(bytes(36000*4))
        guide.extend([f'{r["group"]}, {r["severity"]}, {r["seed"]}',f'![Play]({dest})',''])
    (listen/'README.md').write_text('\n'.join(guide));(listen/'blind-key.json').write_text(json.dumps(key,indent=2))
    result=dict(config=CONFIG,auraloss_version='0.4.0',torch_version=torch.__version__,summary=summary,seconds=time.perf_counter()-started,free_gib=shutil.disk_usage(ROOT).free/2**30,source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),scope='Scoring and derivative-free refinement only; no neural training. Six validation cases; 49 renders per starting state. Audio objective monotonicity is by construction, not evidence of perceptual improvement.')
    (OUT/'report.json').write_text(json.dumps(result,indent=2));print('Completed',flush=True)

if __name__=='__main__':main()
