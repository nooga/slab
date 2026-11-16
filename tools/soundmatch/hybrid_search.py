#!/usr/bin/env python3
"""Compare oscillator correction network, discrete search and hybrid correction."""
import os
os.environ['SLAB_SOUNDMATCH_PROFILE']='oscillator'
import hashlib,json,random,shutil,time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import torch
import torch.nn.functional as F
import auraloss
from expanded_data import BASE,ROOT,KEYS,CATS,CATEGORIES,ALL,guard,make_project,render_file
from expanded_train import Expanded
from ablations import multires
from audit import read,distance
from auraloss_trial import CONFIG,tensor

OUT=ROOT/'scratch/soundmatch-hybrid-40'
METRICS=['spectral','auraloss']
ROUNDS=2
PROPOSAL_LIMIT=42
SECONDS_LIMIT=60

def save(path,obj):
    temporary=path.with_suffix(path.suffix+'.tmp');temporary.write_text(json.dumps(obj,indent=2)+'\n');temporary.replace(path)

def improved(new,old):return new<old-max(1e-6,.001*old)
def select(candidates,current):
    accepted=[c for c in candidates if all(improved(c['scores'][m],current['scores'][m]) for m in METRICS)]
    return min(accepted,key=lambda c:sum(c['scores'][m]/max(current['scores'][m],1e-9) for m in METRICS)) if accepted else current

def fingerprint(state):return hashlib.sha256(json.dumps(state,sort_keys=True).encode()).hexdigest()[:20]

def choose_rows():
    rr=json.loads((BASE/'rows.json').read_text())
    # Avoid the eight examples already selected for the previous listening round.
    heard={r['seed'] for r in json.loads((BASE/'blind-key.json').read_text()).values()}
    selected=[]
    for group in ['familiar','patch','phrase','joint']:
        for severity,n in [('identity',2),('sparse',4),('dense',4)]:
            pool=[r for r in rr if r['split']=='test' and r['group']==group and r['severity']==severity and r['seed'] not in heard]
            assert len(pool)>=n;selected.extend(pool[:n])
    assert len(selected)==40 and len({r['seed'] for r in selected})==40
    return selected

class Proposer:
    def __init__(self):
        self.checkpoint=torch.load(BASE/'model/checkpoint.pt',map_location='cpu',weights_only=False)
        assert self.checkpoint['keys']==KEYS and list(self.checkpoint['categories'])==CATS
        self.model=Expanded(self.checkpoint['context_size']);self.model.load_state_dict(self.checkpoint['model']);self.model.eval()
    def propose(self,row,current,target_features):
        current_features=multires(Path(current['wav']));a=target_features;b=current_features
        x=torch.from_numpy(np.concatenate([a,b,a-b])[None]/self.checkpoint['scale'])
        c=torch.tensor([[current['state'][k] for k in KEYS]],dtype=torch.float32)
        cat=torch.tensor([[current['state'][k] for k in CATS]])
        state=torch.cat([c]+[F.one_hot(cat[:,j],n).float() for j,n in enumerate(CATEGORIES.values())]+[torch.tensor([row['context']],dtype=torch.float32)],1)
        with torch.inference_mode():p,_=self.model.decode(x,state,c,cat)
        result=dict(current['state'])
        for j,k in enumerate(KEYS):
            if float(p[0,j])!=float(c[0,j]):result[k]=float(p[0,j])
        return result

def main():
    guard(reserve=4*2**30);OUT.mkdir(exist_ok=False);torch.set_num_threads(2)
    rows=choose_rows();proposer=Proposer();loss=auraloss.freq.MultiResolutionSTFTLoss(**CONFIG)
    predictions={r['seed']:r for r in json.loads((BASE/'model/predictions.json').read_text())}
    old_scores={r['seed']:r for r in json.loads((BASE/'evaluation/results.json').read_text())}
    plan=dict(seeds=[r['seed'] for r in rows],rounds=ROUNDS,max_proposals_per_method=PROPOSAL_LIMIT,max_seconds_per_method=SECONDS_LIMIT,workers=6,selection='First 2 identity, 4 sparse, 4 dense test examples per holdout group, excluding previous eight audition seeds; no selection by scores.',acceptance='Both metrics improve by more than max(1e-6, 0.001*current); select minimum sum of candidate/current ratios.',budget='Same 42-proposal and 60-second limits. Search uses up to 40 proposals; hybrid up to 42 including two neural proposals. Wall time includes feature extraction, inference, rendering and scoring; initial/reference scoring excluded for both. No cross-method cache. Running renderer calls finish before returning; no new work launches after deadline.',hybrid='Before each discrete round, propose gated levels/detuning only from the frozen nine-control checkpoint, recomputing current audio features and state. Ignore neural category outputs. Accept only on both metrics. Search-alone freezes continuous controls.',source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),checkpoint_sha256=hashlib.sha256((BASE/'model/checkpoint.pt').read_bytes()).hexdigest(),renderer_sha256=hashlib.sha256((ROOT/'zig-out/bin/slab').read_bytes()).hexdigest(),audio_loss=CONFIG)
    save(OUT/'plan.json',plan);shutil.copy2(__file__,OUT/'source.py')
    started=time.perf_counter();results=[]
    for number,row in enumerate(rows,1):
        folder=OUT/str(row['seed']);folder.mkdir();reference_path=Path(row['folder'])/'target.wav';target=read(reference_path);target_tensor=tensor(reference_path)
        def mags(x):return [np.abs(np.fft.rfft(np.lib.stride_tricks.sliding_window_view(x,n,axis=0)[::n//4]*np.hanning(n),axis=-1)) for n in [512,2048,8192]]
        reference=mags(target);norms=[max(np.linalg.norm(x),1e-9) for x in reference]
        def score(path):
            audio=read(path);spectral=float(np.mean([np.linalg.norm(a-b)/norm for a,b,norm in zip(reference,mags(audio),norms)]))
            with torch.inference_mode():au=float(loss(torch.from_numpy(audio.T.copy()).float().unsqueeze(0),target_tensor))
            assert np.isfinite([spectral,au]).all();return dict(spectral=spectral,auraloss=au)
        initial=dict(state=row['current'],wav=str(Path(row['folder'])/'current.wav'));initial['scores']=score(initial['wav'])
        assert abs(initial['scores']['spectral']-old_scores[row['seed']]['before'])<1e-8
        model=dict(state=predictions[row['seed']]['predicted'],wav=str(BASE/'evaluation'/f'{row["seed"]}.wav'));model['scores']=score(model['wav'])
        assert abs(model['scores']['spectral']-old_scores[row['seed']]['after'])<1e-8
        outputs={};traces={};timings={};counts={}
        target_features=None
        # Alternate order to reduce systematic thermal/cache timing bias.
        order=['search','hybrid'] if number%2 else ['hybrid','search']
        for method in order:
            directory=folder/method;directory.mkdir();cache={fingerprint(initial['state']):initial};current=initial;trace=[];count=0;renders=0;begin=time.perf_counter();deadline=begin+SECONDS_LIMIT
            def produce(state):
                # Queued jobs check the deadline when starting, not when queued.
                if time.perf_counter()>=deadline:return None
                sid=fingerprint(state);wav=directory/f'{sid}.wav';make_project(wav.with_suffix('.slab'),row,state);render_file(wav.with_suffix('.slab'),wav)
                return sid,dict(state=state,wav=str(wav))
            def evaluate(states):
                nonlocal count,renders
                states=states[:PROPOSAL_LIMIT-count];count+=len(states)
                missing={fingerprint(s):s for s in states if fingerprint(s) not in cache}
                with ThreadPoolExecutor(max_workers=6) as pool:
                    for item in pool.map(produce,missing.values()):
                        if item is None:continue
                        sid,candidate=item;renders+=1
                        if time.perf_counter()>=deadline:continue
                        candidate['scores']=score(candidate['wav']);cache[sid]=candidate
                return [cache[fingerprint(s)] for s in states if fingerprint(s) in cache]
            for iteration in range(ROUNDS):
                if time.perf_counter()>=deadline or all(current['scores'][m]<=1e-12 for m in METRICS):break
                before=current;events=[]
                if method=='hybrid':
                    # Include target feature extraction in each method's timed work.
                    if target_features is None:target_features=multires(reference_path)
                    proposal=proposer.propose(row,current,target_features)
                    if proposal!=current['state']:
                        chosen=select(evaluate([proposal]),current);events.append(dict(kind='neural',before=current['scores'],after=chosen['scores'],accepted=chosen is not current));current=chosen
                    else:events.append(dict(kind='neural',before=current['scores'],after=current['scores'],accepted=False,no_change=True))
                if time.perf_counter()>=deadline:break
                proposals=[]
                for k,n in CATEGORIES.items():
                    for v in range(n):
                        if v==current['state'][k]:continue
                        state=dict(current['state']);state[k]=v;proposals.append(state)
                chosen=select(evaluate(proposals),current);events.append(dict(kind='discrete',before=current['scores'],after=chosen['scores'],accepted=chosen is not current));current=chosen
                trace.append(dict(round=iteration+1,events=events))
                if current is before:break
            elapsed=time.perf_counter()-begin
            final_wav=folder/f'{method}.wav';shutil.copy2(current['wav'],final_wav);make_project(folder/f'{method}.slab',row,current['state'])
            outputs[method]=dict(state=current['state'],scores=current['scores'],wav=str(final_wav));traces[method]=trace;timings[method]=elapsed;counts[method]=dict(proposals=count,renders=renders,deadline_reached=elapsed>=SECONDS_LIMIT)
            # Intermediate audio has served its purpose. Preserve trace/state/scores and final WAV/project.
            shutil.rmtree(directory)
        entry=dict(seed=row['seed'],group=row['group'],severity=row['severity'],reference=str(reference_path),initial=initial,model=model,final=outputs,trace=traces,seconds=timings,counts=counts)
        save(folder/'result.json',entry);results.append(entry);save(OUT/'results.json',results);guard()
        print(f'{number}/40 {row["group"]}/{row["severity"]}: {time.perf_counter()-started:.1f}s total; search {timings["search"]:.1f}s, hybrid {timings["hybrid"]:.1f}s; {shutil.disk_usage(ROOT).free/2**30:.1f} GiB free',flush=True)
    summarize(results,time.perf_counter()-started)
    listening(results)

def summarize(results,seconds):
    altered=[r for r in results if r['severity']!='identity'];summary={}
    def result(r,m):return r['initial'] if m=='unchanged' else r['model'] if m=='model' else r['final'][m]
    for method in ['unchanged','model','search','hybrid']:
        report=dict(count=len(altered),metrics={},identity_pcm_changed=sum(not np.array_equal(read(result(r,method)['wav']),read(r['reference'])) for r in results if r['severity']=='identity'))
        for metric in METRICS:
            a=np.array([r['initial']['scores'][metric] for r in altered]);b=np.array([result(r,method)['scores'][metric] for r in altered])
            report['metrics'][metric]=dict(mean=float(b.mean()),improved=int((b<a-1e-6).sum()),worsened=int((b>a+1e-6).sum()),same=int((abs(b-a)<=1e-6).sum()))
        report['groups']={g:{m:float(np.mean([result(r,method)['scores'][m] for r in altered if r['group']==g])) for m in METRICS} for g in ['familiar','patch','phrase','joint']}
        if method in ['search','hybrid']:
            report.update(mean_seconds=float(np.mean([r['seconds'][method] for r in altered])),max_seconds=max(r['seconds'][method] for r in results),renders=sum(r['counts'][method]['renders'] for r in results),proposals=sum(r['counts'][method]['proposals'] for r in results),deadlines_reached=sum(r['counts'][method]['deadline_reached'] for r in results))
        summary[method]=report
    wins={m:sum(r['final']['hybrid']['scores'][m]<r['final']['search']['scores'][m]-1e-6 for r in altered) for m in METRICS}
    losses={m:sum(r['final']['hybrid']['scores'][m]>r['final']['search']['scores'][m]+1e-6 for r in altered) for m in METRICS}
    report=dict(seconds=seconds,summary=summary,hybrid_vs_search=dict(wins=wins,losses=losses),free_gib=shutil.disk_usage(ROOT).free/2**30)
    save(OUT/'report.json',report)
    lines=['# Hybrid oscillator correction results','','40 preselected test cases: 32 altered and 8 identity; four holdout groups. Frozen nine-control 5k checkpoint. No new training. Prior eight audition examples excluded. These test examples have previously been scored automatically, so this is exploratory evaluation.','','| Method | Spectral mean | Auraloss mean | Spectral improved / same / worse | Identity PCM changes |','|---|---:|---:|---:|---:|']
    for method,d in summary.items():
        s=d['metrics']['spectral'];lines.append(f'| {method} | {s["mean"]:.4f} | {d["metrics"]["auraloss"]["mean"]:.4f} | {s["improved"]} / {s["same"]} / {s["worsened"]} | {d["identity_pcm_changed"]}/8 |')
    lines+=['','Both search methods start from unchanged settings. Search edits only categories. Hybrid adds gated continuous-only neural proposals before each discrete round; the standalone model predicts all nine controls. Consensus acceptance requires both metrics to fall by more than max(1e-6, 0.001 × current error). Zero score regressions versus the start are therefore expected by construction, not independent evidence of perceptual safety.','','| Search method | Mean seconds / altered case | Maximum seconds | Rendered candidates | Logical proposals | Time limits reached |','|---|---:|---:|---:|---:|---:|']
    for method in ['search','hybrid']:
        d=summary[method];lines.append(f'| {method} | {d["mean_seconds"]:.2f} | {d["max_seconds"]:.2f} | {d["renders"]} | {d["proposals"]} | {d["deadlines_reached"]} |')
    lines+=['',f'Hybrid versus search on 32 altered cases: spectral {wins["spectral"]} wins / {32-wins["spectral"]-losses["spectral"]} ties / {losses["spectral"]} losses; auraloss {wins["auraloss"]} wins / {32-wins["auraloss"]-losses["auraloss"]} ties / {losses["auraloss"]} losses.','',f'Total runtime {seconds:.1f}s. Free space {report["free_gib"]:.1f} GiB. Same 60-second and 42-proposal ceilings; two rounds. Search spends at most 40 proposals; hybrid at most 42, including neural proposals. Duplicate states cached only within a method. Already exact cases exit immediately.','', 'Scores are the optimization objectives, not independent perceptual measures. Neural proposals after search see modified states outside the original training distribution. One checkpoint, small selected test subset. Protocol: [HYBRID_SEARCH.md](HYBRID_SEARCH.md). Artifacts: `scratch/soundmatch-hybrid-40`.']
    (ROOT/'tools/soundmatch/HYBRID_SEARCH_RESULTS.md').write_text('\n'.join(lines)+'\n');print(json.dumps(report,indent=2),flush=True)

def listening(results):
    # First distinct PCM comparison per group and matchup, not selected by score.
    trials=[];key={};rng=random.Random(20610000)
    for left,right in [('hybrid','search'),('hybrid','model')]:
        selected=[]
        for group in ['familiar','patch','phrase','joint']:
            for r in results:
                if r['severity']=='identity' or r['group']!=group:continue
                a=r['final'][left];b=r['model'] if right=='model' else r['final'][right]
                if np.array_equal(read(a['wav']),read(b['wav'])):continue
                selected.append((r,a,b));break
        sides=['A','B']*(len(selected)//2)+(['A'] if len(selected)%2 else []);rng.shuffle(sides)
        for (r,a,b),side in zip(selected,sides):
            other='B' if side=='A' else 'A';tid=f'hybrid-{len(trials)+1:02d}'
            trials.append(dict(id=tid,sources={'reference':r['reference'],side:a['wav'],other:b['wav']}));key[tid]=dict(seed=r['seed'],group=r['group'],assignment={side:left,other:right})
    rng.shuffle(trials);save(OUT/'manifest.json',dict(experiment='hybrid-40-v1',title='Oscillator correction strategies',trials=trials));save(OUT/'blind-key.json',key)
    print(f'Prepared {len(trials)} optional blind comparisons',flush=True)

if __name__=='__main__':main()
