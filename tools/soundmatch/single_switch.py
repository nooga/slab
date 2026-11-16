#!/usr/bin/env python3
"""Balanced single-switch recognition, diagnosis, and exhaustive-search diagnostic."""
import os
os.environ['SLAB_SOUNDMATCH_PROFILE']='oscillator'
import argparse, copy, hashlib, json, math, random, shutil, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np
import torch
from torch import nn
import torch.nn.functional as F
import expanded_data as ed
from ablations import multires,batch
from diverse_train import normalize
from train_smoke import Corrector
from audit import read,distance

BASE=ed.ROOT/'scratch/soundmatch-single-switch-1k'
CATS=ed.CATS

def save(path,value):path.write_text(json.dumps(value,indent=2)+'\n')
def rows():return json.loads((BASE/'rows.json').read_text())

def plan():
    output=[]
    transitions=[(j,a,b) for j in range(5) for a in range(5) for b in range(5) if a!=b]
    for split,count,old_start,offset in [('train',1000,0,1000000),('validation',200,5000,1010000),('test',200,5200,1020000)]:
        schedule=transitions*(count//100);random.Random(offset).shuffle(schedule)
        for i,(j,a,b) in enumerate(schedule):
            r=ed.oscillator_recipe(old_start+i,offset)
            r['target'][CATS[j]]=b;r['current']=dict(r['target']);r['current'][CATS[j]]=a
            r.update(changed=[CATS[j]],severity='single',action=j*5+b,changed_index=j,correction={k:0 for k in ed.KEYS})
            r['folder']=str(BASE/str(r['seed']));output.append(r)
    assert len({r['seed'] for r in output})==1400
    for r in output:assert [k for k in ed.ALL if r['target'][k]!=r['current'][k]]==r['changed']
    return output

def generate(bench=False):
    ed.guard(reserve=7*ed.GIB);out=BASE.with_name(BASE.name+'-bench') if bench else BASE;out.mkdir(exist_ok=False)
    rr=plan()[:20] if bench else plan();start=time.perf_counter()
    save(out/'run.json',dict(count=len(rr),source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),renderer_sha256=hashlib.sha256((ed.ROOT/'zig-out/bin/slab').read_bytes()).hexdigest(),categories=ed.CATEGORIES,context_schema=ed.schema()))
    def work(r):
        folder=out/str(r['seed']);folder.mkdir();r['folder']=str(folder)
        for kind in ['target','current']:
            ed.make_project(folder/f'{kind}.slab',r,r[kind]);ed.render_file(folder/f'{kind}.slab',folder/f'{kind}.wav')
        save(folder/'labels.json',r);return r
    with ThreadPoolExecutor(max_workers=8) as pool:
        rr=list(pool.map(work,rr))
    save(out/'rows.json',rr);save(out/'generation.json',dict(seconds=time.perf_counter()-start,count=len(rr),free_gib=shutil.disk_usage(BASE.parent).free/ed.GIB))
    print(f'Generated {len(rr)} pairs in {time.perf_counter()-start:.1f}s; {shutil.disk_usage(BASE.parent).free/ed.GIB:.1f} GiB free',flush=True)

def prepare():
    rr=rows();ed.guard(reserve=2*ed.GIB);path=BASE/'features.npy'
    if path.exists():raise RuntimeError('Feature file already exists')
    data=np.lib.format.open_memmap(path,mode='w+',dtype='float32',shape=(len(rr),2,6,128,128))
    def work(r):return np.stack([multires(Path(r['folder'])/f'{kind}.wav') for kind in ['target','current']])
    with ThreadPoolExecutor(max_workers=2) as pool:
        for i,x in enumerate(pool.map(work,rr)):
            assert np.isfinite(x).all();data[i]=x
            if (i+1)%200==0:ed.guard();print(f'Features {i+1}/{len(rr)}',flush=True)
    data.flush();save(BASE/'features-ready.json',dict(shape=list(data.shape)))

class SwitchModel(Corrector):
    def __init__(self,state_size):
        super().__init__(state_size)
        self.encoder[0]=nn.Conv2d(18,32,5,stride=2,padding=2)
        self.head[-1]=nn.Linear(512,25)
        nn.init.zeros_(self.head[-1].weight);nn.init.zeros_(self.head[-1].bias)

def load():
    rr=rows();data=np.load(BASE/'features.npy',mmap_mode='r')
    current=torch.tensor([[r['current'][k] for k in CATS] for r in rr])
    state=torch.cat([torch.tensor([[r['current'][k] for k in ed.KEYS]+r['context'] for r in rr])]+[F.one_hot(current[:,j],5).float() for j in range(5)],1)
    target=torch.tensor([r['action'] for r in rr]);changed=target//5
    valid=torch.ones(len(rr),5,5,dtype=torch.bool);valid.scatter_(2,current.unsqueeze(-1),False)
    return rr,data,state,target,changed,valid.reshape(-1,25)

def train(hinted):
    name='hinted' if hinted else 'unhinted';out=BASE/name;out.mkdir(exist_ok=False)
    torch.set_num_threads(4);torch.manual_seed(42);rng=np.random.default_rng(42)
    rr,data,state,target,changed,valid=load()
    if hinted:valid &= torch.arange(25)[None,:]//5==changed[:,None]
    split={s:np.array([i for i,r in enumerate(rr) if r['split']==s]) for s in ['train','validation','test']}
    scale=normalize(data,split['train']);device=torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    model=SwitchModel(state.shape[1]).to(device);opt=torch.optim.AdamW(model.parameters(),lr=3e-4)
    def infer(ix):
        model.eval();outputs=[];losses=[]
        with torch.no_grad():
            for start in range(0,len(ix),32):
                ids=ix[start:start+32];logits=model(batch(data,ids,scale).to(device),state[ids].to(device)).masked_fill(~valid[ids].to(device),-1e9)
                outputs.extend(logits.argmax(1).cpu().tolist());losses.extend(F.cross_entropy(logits,target[ids].to(device),reduction='none').cpu().tolist())
        return np.array(outputs),float(np.mean(losses))
    best=math.inf;weights=None;history=[];start=time.perf_counter();steps=1875
    for step in range(1,steps+1):
        model.train();ix=rng.choice(split['train'],32,replace=True)
        logits=model(batch(data,ix,scale).to(device),state[ix].to(device)).masked_fill(~valid[ix].to(device),-1e9)
        loss=F.cross_entropy(logits,target[ix].to(device));opt.zero_grad(set_to_none=True);loss.backward();opt.step()
        if step%156==0 or step==steps:
            ed.guard();p,ce=infer(split['validation']);acc=float((p==target[split['validation']].numpy()).mean());history.append(dict(step=step,ce=ce,accuracy=acc))
            if ce<best:best=ce;best_step=step;weights=copy.deepcopy(model.state_dict())
            print(f'{name} {step}/{steps}: validation exact {acc:.1%}, CE {ce:.3f}; selected {best_step}',flush=True)
    model.load_state_dict(weights);report=dict(seconds=time.perf_counter()-start,best_step=best_step,parameters=sum(p.numel() for p in model.parameters()),device=str(device),history=history,metrics={});predictions=[]
    for s,ix in split.items():
        p,ce=infer(ix);truth=target[ix].numpy();correct=p==truth
        report['metrics'][s]=dict(count=len(ix),exact=float(correct.mean()),control_accuracy=float((p//5==truth//5).mean()),ce=ce,per_control={k:float(correct[truth//5==j].mean()) for j,k in enumerate(CATS)},groups={g:float(correct[[rr[i]['group']==g for i in ix]].mean()) for g in sorted({rr[i]['group'] for i in ix})})
        if s=='test':predictions=[dict(seed=rr[i]['seed'],action=int(a)) for i,a in zip(ix,p)]
    save(out/'training.json',report);save(out/'predictions.json',predictions)
    torch.save(dict(model=model.cpu().state_dict(),state_size=state.shape[1],scale=scale,hinted=hinted,categories=CATS),out/'checkpoint.pt')
    print(name,json.dumps(report['metrics']),flush=True)

def search():
    import auraloss
    from auraloss_trial import CONFIG,tensor
    torch.set_num_threads(2);loss=auraloss.freq.MultiResolutionSTFTLoss(**CONFIG)
    out=BASE/'search';out.mkdir(exist_ok=False);rr=[r for r in rows() if r['split']=='test'];results=[];start=time.perf_counter()
    predictions={m:{p['seed']:p['action'] for p in json.loads((BASE/m/'predictions.json').read_text())} for m in ['hinted','unhinted']}
    with ThreadPoolExecutor(max_workers=6) as pool:
        for i,r in enumerate(rr):
            ed.guard();folder=out/str(r['seed']);folder.mkdir();reference=Path(r['folder'])/'target.wav';target_audio=read(reference);t=tensor(reference)
            def work(action):
                state=dict(r['current'])
                if action>=0:state[CATS[action//5]]=action%5
                wav=folder/f'{action}.wav';ed.make_project(wav.with_suffix('.slab'),r,state);ed.render_file(wav.with_suffix('.slab'),wav)
                return action,wav
            actions=[j*5+v for j,k in enumerate(CATS) for v in range(5) if v!=r['current'][k]]
            scores=[]
            for action,wav in pool.map(work,actions):
                with torch.inference_mode():a=float(loss(tensor(wav),t))
                scores.append(dict(action=action,spectral=distance(target_audio,read(wav)),auraloss=a))
            current=Path(r['folder'])/'current.wav'
            with torch.inference_mode():a=float(loss(tensor(current),t))
            scores.append(dict(action=-1,spectral=distance(target_audio,read(current)),auraloss=a))
            exact=next(s for s in scores if s['action']==r['action'])
            assert np.array_equal(read(folder/f'{r["action"]}.wav'),target_audio),'Exact candidate failed to reproduce target'
            choices={}
            for hint in [False,True]:
                subset=[s for s in scores if s['action']==-1 or not hint or s['action']//5==r['changed_index']]
                for metric in ['spectral','auraloss']:
                    ranked=sorted(subset,key=lambda s:(s[metric],s['action']))
                    choices[('hinted_' if hint else 'unhinted_')+metric]=ranked[0]['action']
            results.append(dict(seed=r['seed'],group=r['group'],target=r['action'],scores=scores,choices=choices,neural={m:p[r['seed']] for m,p in predictions.items()}))
            # Scores retain every candidate; audio retains target and model picks only.
            keep={r['action']}|{p[r['seed']] for p in predictions.values()}|set(choices.values())
            for action in actions:
                if action not in keep:
                    for suffix in ['.wav','.slab','.log']:
                        path=folder/f'{action}{suffix}'
                        if path.is_dir():shutil.rmtree(path)
                        elif path.exists():path.unlink()
            if (i+1)%20==0:
                save(out/'results.partial.json',results);print(f'Search {i+1}/{len(rr)}, {time.perf_counter()-start:.1f}s, {shutil.disk_usage(BASE).free/ed.GIB:.1f} GiB free',flush=True)
    save(out/'results.json',results);save(out/'timing.json',dict(seconds=time.perf_counter()-start,renders=len(rr)*20))

def report():
    rr=json.loads((BASE/'search/results.json').read_text());lines=['# Single-switch diagnostic results','', '1,000 training / 200 validation / 200 test pairs. Exactly one incorrect switch per pair; known MIDI, routing and continuous settings. Each split balances all 100 directed switch transitions. Single training seed.','', '| Model | Selected step | Train exact | Validation exact | Test exact | Test control identification |','|---|---:|---:|---:|---:|---:|']
    for m in ['hinted','unhinted']:
        t=json.loads((BASE/m/'training.json').read_text());a=t['metrics'];lines.append(f'| {m} | {t["best_step"]} | {a["train"]["exact"]:.1%} | {a["validation"]["exact"]:.1%} | {a["test"]["exact"]:.1%} | {a["test"]["control_accuracy"]:.1%} |')
    lines+=['','Random exact recovery is 25% with the changed-control hint and 5% without it. The hint masks the output choices; both models otherwise use the same network and train separately. Checkpoints minimize validation cross-entropy. No identity examples: this diagnostic assumes a correction is required.','','| Method | Exact recovery | Spectral mean | Auraloss mean | Spectral improved / same / worse |','|---|---:|---:|---:|---:|']
    summary={}
    for method in ['unchanged','hinted','unhinted','hinted_spectral','hinted_auraloss','unhinted_spectral','unhinted_auraloss']:
        picked=[];correct=improved=worse=0
        for r in rr:
            action=-1 if method=='unchanged' else r['neural'][method] if method in r['neural'] else r['choices'][method]
            s=next(s for s in r['scores'] if s['action']==action);before=next(s for s in r['scores'] if s['action']==-1)
            correct+=action==r['target'];improved+=s['spectral']<before['spectral']-1e-6;worse+=s['spectral']>before['spectral']+1e-6;picked.append(s)
        d=dict(exact=correct/len(rr),spectral=float(np.mean([s['spectral'] for s in picked])),auraloss=float(np.mean([s['auraloss'] for s in picked])),improved=improved,worsened=worse,unchanged=len(rr)-improved-worse);summary[method]=d
        lines.append(f'| {method} | {d["exact"]:.1%} | {d["spectral"]:.4f} | {d["auraloss"]:.4f} | {improved} / {d["unchanged"]} / {worse} |')
    lines+=['','Search enumerates 20 distinct edits plus the unchanged candidate; hinted search restricts this to four edits plus unchanged. Target settings are guaranteed to be in the search space, and their renders were checked sample-identical to the reference. This is an upper-bound pipeline check, not validation of perceptual scoring when the target is unattainable. Search ties use the lowest action index.','','Protocol and commands: [SINGLE_SWITCH.md](SINGLE_SWITCH.md). Artifacts: `scratch/soundmatch-single-switch-1k`.']
    save(BASE/'summary.json',summary);(ed.ROOT/'tools/soundmatch/SINGLE_SWITCH_RESULTS.md').write_text('\n'.join(lines)+'\n');print('\n'.join(lines),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['bench','generate','prepare','hinted','unhinted','search','report']);a=p.parse_args().action
    if a in ['bench','generate']:generate(a=='bench')
    elif a in ['hinted','unhinted']:train(a=='hinted')
    else:globals()[a]()
