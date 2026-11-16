#!/usr/bin/env python3
"""Learning curve on diverse Cream pairs with known fixed-parameter context."""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import random
import time
import wave

import numpy as np
import torch
from torch import nn
import torch.nn.functional as F

from ablations import multires, batch, Selective
from audit import read,distance
from diverse_data import BASE,ROOT,CONTROLS,GIB,guard,plan,make_project,render_file

KEYS=list(CONTROLS)


def prepare():
    guard(BASE,reserve=5*GIB)
    path=BASE/'features.npy'
    if path.exists():raise RuntimeError('Feature cache exists')
    schedule=plan();started=time.perf_counter()
    data=np.lib.format.open_memmap(path,mode='w+',dtype='float32',shape=(len(schedule),2,6,128,128))
    def work(item):
        label=BASE/str(item['seed'])/'labels.json'
        deadline=time.monotonic()+3600
        while not label.exists():
            if time.monotonic()>deadline:raise TimeoutError(f'Waiting for {label}')
            time.sleep(2)
        row=json.loads(label.read_text());folder=Path(row['folder'])
        a=multires(folder/'target.wav')
        b=a.copy() if not row['changed'] else multires(folder/'current.wav')
        value=np.stack([a,b]);assert np.isfinite(value).all()
        return item['index'],row,value
    rows=[]
    with ThreadPoolExecutor(max_workers=2) as pool:
        for n,(i,row,value) in enumerate(pool.map(work,schedule),1):
            data[i]=value;rows.append(row)
            if n%200==0 or n==len(schedule):
                guard();data.flush();print(f'features {n}/{len(schedule)}',flush=True)
                (BASE/'feature-progress.json').write_text(json.dumps(dict(completed=n,seconds=time.perf_counter()-started)))
    del data
    assert len({r['seed'] for r in rows})==len(rows)
    assert {r['patch'] for r in rows if r['group'] in ['patch','joint'] and r['split']=='test'}.isdisjoint({r['patch'] for r in rows if r['split']=='train'})
    assert {r['phrase'] for r in rows if r['group'] in ['phrase','joint'] and r['split']=='test'}.isdisjoint({r['phrase'] for r in rows if r['split']=='train'})
    (BASE/'feature-rows.json').write_text(json.dumps(rows))
    (BASE/'features-ready.json').write_text(json.dumps(dict(seconds_including_generation_wait=time.perf_counter()-started,shape=[len(rows),2,6,128,128],bytes=path.stat().st_size)))
    print('Feature cache complete',flush=True)


class ContextSelective(Selective):
    def __init__(self,context_size):
        super().__init__(18,True)
        self.head[0]=nn.Linear(2048+len(KEYS)+context_size,512)
        with torch.no_grad():self.head[-1].bias[len(KEYS):].fill_(math.log(2/13))


def load():
    assert (BASE/'features-ready.json').exists()
    rows=json.loads((BASE/'feature-rows.json').read_text())
    data=np.load(BASE/'features.npy',mmap_mode='r')
    c=torch.tensor([[r['current'][k] for k in KEYS] for r in rows],dtype=torch.float32)
    y=torch.tensor([[r['target'][k] for k in KEYS] for r in rows],dtype=torch.float32)
    context=torch.tensor([r['context'] for r in rows],dtype=torch.float32)
    return rows,data,c,y,context


def normalize(data,indices):
    total=squares=0.;n=0
    for i in indices:
        a,b=data[i];x=np.concatenate([a,b,a-b]).astype(np.float64)
        total+=x.sum();squares+=(x*x).sum();n+=x.size
    return math.sqrt((squares-total*total/n)/(n-1))


def evaluate(model,data,scale,c,context,indices,device,identity=False,legacy=False):
    model.eval();result=[]
    with torch.no_grad():
        for start in range(0,len(indices),32):
            ix=indices[start:start+32]
            x=batch(data,ix,scale,np.ones(len(ix),bool) if identity else None).to(device)
            state=c[ix] if legacy else torch.cat([c[ix],context[ix]],1)
            delta,_,_=model.decode(x,state.to(device))
            result.append((c[ix].to(device)+delta).clamp(0,1).cpu())
    return torch.cat(result)


def metrics(pred,identity,c,y,rows,indices):
    result={}
    for group in ['all','familiar','patch','phrase','joint']:
        choose=[j for j,i in enumerate(indices) if group=='all' or rows[i]['group']==group]
        if not choose:continue
        ix=indices[choose];p=pred[choose];z=identity[choose]
        changed=y[ix]!=c[ix];edited=(p-c[ix]).abs()>1e-6
        nonzero=torch.tensor([bool(rows[i]['changed']) for i in ix])
        identity_rows=~nonzero
        result[group]=dict(count=len(ix),changed_pairs=int(nonzero.sum()),baseline_mse=float(((c[ix]-y[ix])**2).mean()),
            mse=float(((p-y[ix])**2).mean()),changed_pair_mse=float(((p[nonzero]-y[ix][nonzero])**2).mean()),
            correct_control_drift=float((p-c[ix]).abs()[~changed].mean()),
            edit_precision=int((changed&edited).sum())/max(int(edited.sum()),1),
            edit_recall=int((changed&edited).sum())/max(int(changed.sum()),1),
            identity_probe_mean_edit=float((z-c[ix]).abs().mean()),
            identity_probes_over_005=int(((z-c[ix]).abs().max(1).values>.05).sum()),
            actual_identity_pairs_edited=int(((p[identity_rows]-c[ix][identity_rows]).abs().max(1).values>1e-6).sum()))
    return result


def save_predictions(out,model,data,scale,c,y,context,rows,device,legacy=False):
    reports={};records=[]
    for split in ['validation','test']:
        ix=np.array([i for i,r in enumerate(rows) if r['split']==split])
        p=evaluate(model,data,scale,c,context,ix,device,legacy=legacy)
        identity=evaluate(model,data,scale,c,context,ix,device,True,legacy)
        reports[split]=metrics(p,identity,c,y,rows,ix)
        for j,i in enumerate(ix):
            row=rows[i];record={k:row[k] for k in ['index','seed','folder','split','group','patch','phrase','severity','register','current']}
            record['predicted']={k:row['current'][k] if float(p[j,h])==float(c[i,h]) else float(p[j,h]) for h,k in enumerate(KEYS)}
            record['identity_predicted']={k:row['current'][k] if float(identity[j,h])==float(c[i,h]) else float(identity[j,h]) for h,k in enumerate(KEYS)}
            records.append(record)
    (out/'predictions.json').write_text(json.dumps(records));return reports


def train(count):
    guard();out=BASE/f'model-{count}';out.mkdir(exist_ok=False)
    torch.set_num_threads(4);torch.manual_seed(42);rng=np.random.default_rng(42)
    rows,data,c,y,context=load()
    all_train=np.array([i for i,r in enumerate(rows) if r['split']=='train'])
    selection=np.random.default_rng(12345).permutation(all_train)[:count]
    assert len(selection)==count
    val=np.array([i for i,r in enumerate(rows) if r['split']=='validation'])
    scale=normalize(data,selection)
    device=torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    model=ContextSelective(context.shape[1]).to(device)
    optimizer=torch.optim.AdamW(model.parameters(),lr=3e-4)
    epochs=60;steps=math.ceil(count*epochs/32);interval=math.ceil(count*5/32)
    best=.8*float(((c[val]-y[val])**2).mean());best_step=0;weights=copy.deepcopy(model.state_dict());history=[]
    started=time.perf_counter();peak=0
    print(f'{count} training examples, {steps} updates, {device}, context={context.shape[1]}',flush=True)
    for step in range(1,steps+1):
        model.train();ix=rng.choice(selection,32,replace=True)
        identity=rng.random(32)<.1
        x=batch(data,ix,scale,identity).to(device);state=torch.cat([c[ix],context[ix]],1).to(device)
        target=(y[ix]-c[ix]).clone();target[identity]=0
        target=target.to(device);mask=(target!=0).float()
        amount,logits=model(x,state).chunk(2,1)
        loss=((amount*logits.sigmoid()-target)**2).mean()
        loss+=.25*(((amount-target)**2)*mask).sum()/mask.sum().clamp_min(1)
        loss+=.02*F.binary_cross_entropy_with_logits(logits,mask)
        optimizer.zero_grad(set_to_none=True);loss.backward();optimizer.step()
        if device.type=='mps':peak=max(peak,torch.mps.driver_allocated_memory())
        if step%interval==0 or step==steps:
            guard();pred=evaluate(model,data,scale,c,context,val,device)
            ident=evaluate(model,data,scale,c,context,val,device,True)
            mse=float(((pred-y[val])**2).mean());imse=float(((ident-c[val])**2).mean());score=.8*mse+.2*imse
            history.append(dict(step=step,epochs=step*32/count,mse=mse,identity_mse=imse,score=score))
            if score<best:best=score;best_step=step;weights=copy.deepcopy(model.state_dict())
            (out/'history.json').write_text(json.dumps(history,indent=2))
            print(f'{count} step {step}/{steps}: val={mse:.6f}, identity={imse:.6f}, best={best_step}',flush=True)
    if device.type=='mps':torch.mps.synchronize()
    seconds=time.perf_counter()-started;model.load_state_dict(weights)
    report=save_predictions(out,model,data,scale,c,y,context,rows,device)
    torch.save(dict(model=model.cpu().state_dict(),context_size=context.shape[1],scale=scale,keys=KEYS,best_step=best_step,
                    train_indices=selection.tolist(),context_schema=json.loads((BASE/'run.json').read_text())['context_schema']),out/'checkpoint.pt')
    result=dict(count=count,epochs=epochs,steps=steps,best_step=best_step,seconds=seconds,device=str(device),seed=42,
        parameters=sum(p.numel() for p in model.parameters()),scale=scale,metrics=report,identity_augmentation=.1,
        sampled_mps_driver_peak_bytes=peak,free_gib=__import__('shutil').disk_usage(ROOT).free/GIB,
        source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        rows_sha256=hashlib.sha256((BASE/'feature-rows.json').read_bytes()).hexdigest())
    (out/'training.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2),flush=True)


def legacy():
    torch.set_num_threads(4);out=BASE/'previous-model';out.mkdir(exist_ok=False)
    rows,data,c,y,context=load()
    ck=torch.load(ROOT/'scratch/soundmatch-ablations/selective_multires/checkpoint.pt',map_location='cpu',weights_only=True)
    model=Selective(18,True);model.load_state_dict(ck['model'])
    reports=save_predictions(out,model,data,ck['scale'],c,y,context,rows,torch.device('cpu'),True)
    (out/'training.json').write_text(json.dumps(dict(metrics=reports,note='Prior single-preset model, context unavailable to this architecture'),indent=2))
    print('Prior model evaluated on new distribution',flush=True)


def render():
    models=['previous-model','model-1000','model-2000','model-5000'];tasks=[]
    for name in models:
        records=json.loads((BASE/name/'predictions.json').read_text())
        for group in ['familiar','patch','phrase','joint']:
            group_rows=[r for r in records if r['split']=='test' and r['group']==group]
            tasks.extend((name,r,'correction') for r in group_rows[:40])
            tasks.extend((name,r,'identity') for r in group_rows[4:6])
    def work(task):
        name,record,kind=task;guard();row=json.loads((Path(record['folder'])/'labels.json').read_text())
        out=BASE/name/'renders';out.mkdir(exist_ok=True)
        state=record['predicted'] if kind=='correction' else record['identity_predicted']
        wav=out/f'{row["seed"]}-{kind}.wav';project=wav.with_suffix('.slab')
        make_project(project,row,state);render_file(project,wav)
        target=read(Path(row['folder'])/('target.wav' if kind=='correction' else 'current.wav'))
        current=read(Path(row['folder'])/'current.wav');pred=read(wav)
        return dict(model=name,seed=row['seed'],group=row['group'],severity=row['severity'],kind=kind,
            before=distance(target,current),after=distance(target,pred),wav=str(wav),source=row['folder'])
    started=time.perf_counter();result=[]
    with ThreadPoolExecutor(max_workers=6) as pool:
        for n,row in enumerate(pool.map(work,tasks),1):
            result.append(row)
            if n%40==0 or n==len(tasks):
                (BASE/'render-progress.json').write_text(json.dumps(dict(completed=n,total=len(tasks),seconds=time.perf_counter()-started)))
                print(f'evaluation renders {n}/{len(tasks)}',flush=True)
    (BASE/'renders.json').write_text(json.dumps(result,indent=2))
    print('Render evaluation complete',flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['prepare','train','legacy','render']);p.add_argument('--count',type=int,choices=[1000,2000,5000])
    a=p.parse_args()
    if a.action=='prepare':prepare()
    elif a.action=='train':
        if a.count is None:p.error('--count required')
        train(a.count)
    elif a.action=='legacy':legacy()
    else:render()
