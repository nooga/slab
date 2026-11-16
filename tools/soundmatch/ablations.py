#!/usr/bin/env python3
"""Controlled selective-edit / identity-data / spectral-input experiments."""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import time

import numpy as np
import torch
from torch import nn
import torch.nn.functional as F
from audit import read, distance
from generate import ROOT, CONTROLS, GIB, make_project, inspect_wav
from train_smoke import features, Corrector

BASE = ROOT / 'scratch/soundmatch-ablations'
KEYS = list(CONTROLS)
VARIANTS = ['dense', 'dense_zero', 'selective_zero', 'selective_multires']


def guard():
    if shutil.disk_usage(ROOT).free < 20*GIB:
        raise RuntimeError('20 GiB free-space floor reached')


def multires(path):
    x=read(path)
    outputs=[]
    frequencies=np.geomspace(30,20000,128)
    for size in (512,2048,8192):
        hop=size//4
        frames=np.lib.stride_tricks.sliding_window_view(x,size,axis=0)[::hop]
        mag=np.abs(np.fft.rfft(frames*np.hanning(size),axis=-1))
        positions=frequencies*size/48000
        lo=np.floor(positions).astype(int)
        frac=positions-lo
        band=mag[...,lo]*(1-frac)+mag[...,lo+1]*frac
        t=((np.arange(128)+.5)*len(x)/128-size/2)/hop
        t=np.clip(t,0,len(band)-1)
        ti=np.floor(t).astype(int); tf=(t-ti)[:,None,None]
        band=band[ti]*(1-tf)+band[np.minimum(ti+1,len(band)-1)]*tf
        outputs.append(np.log1p(10*band).transpose(1,2,0))
    return np.concatenate(outputs).astype(np.float32)


def prepare():
    guard(); BASE.mkdir(exist_ok=False)
    rows=[]
    folders=['soundmatch-pilot-01']+[f'soundmatch-scale-{i}' for i in range(4)]+['soundmatch-ablation-test']
    for name in folders:
        dataset=ROOT/'scratch'/name
        meta=json.loads((dataset/'report.json').read_text())
        labels=sorted(dataset.glob('*/labels.json'))
        assert len(labels)==meta['completed']
        for path in labels:
            row=json.loads(path.read_text())
            row['folder']=str(path.parent)
            if name=='soundmatch-ablation-test':row['split']='test'
            rows.append(row)
    assert len({r['seed'] for r in rows})==len(rows)
    (BASE/'rows.json').write_text(json.dumps(rows))
    plan=dict(variants=VARIANTS,seed=42,steps=3000,batch=16,eval_every=200,
        identity_fraction=.25,gate_threshold=.5,
        gate_loss='soft-gated delta MSE + 0.25 masked amount MSE + 0.02 BCE',
        selection='0.75 validation correction MSE + 0.25 validation identity MSE; initial no-change model eligible',
        representation='old versus 512/2048/8192 STFT magnitudes sampled at 128 log frequencies 30..20000 Hz and 128 aligned times; stereo',
        scope='Known notes, Cream/Comp/Delay; single seed; no audio-loss training',
        rows_sha256=hashlib.sha256((BASE/'rows.json').read_bytes()).hexdigest())
    (BASE/'plan.json').write_text(json.dumps(plan,indent=2))
    for representation,channels,fn in [('old',2,features),('multi',6,multires)]:
        guard(); start=time.perf_counter()
        dest=np.lib.format.open_memmap(BASE/f'{representation}.npy',mode='w+',dtype='float32',shape=(len(rows),2,channels,128,128))
        def work(item):
            i,row=item
            return i, np.stack([fn(Path(row['folder'])/'target.wav'),fn(Path(row['folder'])/'current.wav')])
        with ThreadPoolExecutor(max_workers=4) as pool:
            for n,(i,value) in enumerate(pool.map(work,enumerate(rows))):
                dest[i]=value
                if n%100==0:
                    guard();print(f'{representation} features {n}/{len(rows)}',flush=True)
        dest.flush()
        count=0; total=0.; squares=0.
        for i,row in enumerate(rows):
            if row['split']!='train':continue
            a,b=dest[i]
            xx=np.concatenate([a,b,a-b]).astype(np.float64)
            count+=xx.size;total+=xx.sum();squares+=(xx*xx).sum()
        scale=math.sqrt((squares-total*total/count)/(count-1))
        (BASE/f'{representation}-meta.json').write_text(json.dumps(dict(scale=scale,seconds=time.perf_counter()-start,shape=list(dest.shape))))
        del dest
    print('Features ready',flush=True)


class Selective(Corrector):
    def __init__(self,channels=6,selective=False):
        super().__init__(len(KEYS))
        self.selective=selective
        if channels!=6:self.encoder[0]=nn.Conv2d(channels,32,5,stride=2,padding=2)
        if selective:
            self.head[-1]=nn.Linear(512,len(KEYS)*2)
            nn.init.zeros_(self.head[-1].weight);nn.init.zeros_(self.head[-1].bias)
            with torch.no_grad():self.head[-1].bias[len(KEYS):].fill_(math.log(1/7))
    def decode(self,x,c):
        out=self(x,c)
        if self.selective:
            amount,logits=out.chunk(2,dim=1)
            return amount*(logits.sigmoid()>=.5),amount,logits
        return out,out,None


def load(variant):
    rows=json.loads((BASE/'rows.json').read_text())
    rep='multi' if variant=='selective_multires' else 'old'
    data=np.load(BASE/f'{rep}.npy',mmap_mode='r')
    scale=json.loads((BASE/f'{rep}-meta.json').read_text())['scale']
    c=torch.tensor([[r['current'][k] for k in KEYS] for r in rows],dtype=torch.float32)
    y=torch.tensor([[r['target'][k] for k in KEYS] for r in rows],dtype=torch.float32)
    return rows,data,scale,c,y


def batch(data,indices,scale,identity=None):
    pair=np.array(data[np.asarray(indices)],copy=True)
    if identity is not None:pair[identity,0]=pair[identity,1]
    a,b=pair[:,0],pair[:,1]
    return torch.from_numpy(np.concatenate([a,b,a-b],axis=1)/scale)


def train(variant):
    guard();out=BASE/variant;out.mkdir(exist_ok=False)
    torch.set_num_threads(4);torch.manual_seed(42)
    rng=np.random.default_rng(42)
    rows,data,scale,c,y=load(variant)
    train_ix=np.array([i for i,r in enumerate(rows) if r['split']=='train'])
    val_ix=np.array([i for i,r in enumerate(rows) if r['split']=='validation'])
    device=torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    model=Selective(data.shape[2]*3,variant.startswith('selective')).to(device)
    optimizer=torch.optim.AdamW(model.parameters(),lr=3e-4)
    zero=variant!='dense'
    def evaluate(indices,identity=False):
        model.eval();pred=[];gates=[]
        with torch.no_grad():
            for start in range(0,len(indices),16):
                ix=indices[start:start+16]
                xx=batch(data,ix,scale,np.ones(len(ix),bool) if identity else None).to(device)
                d,_,logits=model.decode(xx,c[ix].to(device))
                pred.append((c[ix].to(device)+d).clamp(0,1).cpu())
                if logits is not None:gates.append(logits.sigmoid().cpu())
        return torch.cat(pred),torch.cat(gates) if gates else None
    baseline=float(((c[val_ix]-y[val_ix])**2).mean())
    best=.75*baseline;best_step=0;best_state=copy.deepcopy(model.state_dict());history=[]
    start=time.perf_counter();peak=0
    for step in range(1,3001):
        model.train();ix=rng.choice(train_ix,16,replace=True)
        # Draw identical masks in every arm so sample sequences remain matched.
        identity=rng.random(16)<.25
        if not zero:identity[:]=False
        xx=batch(data,ix,scale,identity).to(device)
        target=(y[ix]-c[ix]).clone();target[identity]=0
        target=target.to(device);state=c[ix].to(device)
        raw=model(xx,state)
        if model.selective:
            amount,logits=raw.chunk(2,1);mask=(target!=0).float()
            loss=((amount*logits.sigmoid()-target)**2).mean()
            loss+=.25*(((amount-target)**2)*mask).sum()/mask.sum().clamp_min(1)
            loss+=.02*F.binary_cross_entropy_with_logits(logits,mask)
        else:loss=((raw-target)**2).mean()
        optimizer.zero_grad(set_to_none=True);loss.backward();optimizer.step()
        if device.type=='mps':peak=max(peak,torch.mps.driver_allocated_memory())
        if step%200==0:
            guard();p,_=evaluate(val_ix);ident,_=evaluate(val_ix,True)
            mse=float(((p-y[val_ix])**2).mean());identity_mse=float(((ident-c[val_ix])**2).mean())
            score=.75*mse+.25*identity_mse
            history.append(dict(step=step,mse=mse,identity_mse=identity_mse,score=score))
            if score<best:best=score;best_step=step;best_state=copy.deepcopy(model.state_dict())
            (out/'history.json').write_text(json.dumps(history,indent=2))
            print(f'{variant} step {step}: val={mse:.6f}, identity={identity_mse:.6f}, best={best_step}',flush=True)
    if device.type=='mps':torch.mps.synchronize()
    seconds=time.perf_counter()-start
    model.load_state_dict(best_state)
    metrics={};records=[]
    for split in ['validation','test']:
        indices=np.array([i for i,r in enumerate(rows) if r['split']==split])
        pred,gates=evaluate(indices);ident,identity_gates=evaluate(indices,True)
        changed=y[indices]!=c[indices];edited=(pred-c[indices]).abs()>1e-6
        true_positive=int((changed&edited).sum());false_positive=int((~changed&edited).sum())
        metrics[split]=dict(count=len(indices),baseline_mse=float(((c[indices]-y[indices])**2).mean()),
            mse=float(((pred-y[indices])**2).mean()),unchanged_mean_abs_edit=float((pred-c[indices]).abs()[~changed].mean()),
            edit_precision=true_positive/max(int(edited.sum()),1),edit_recall=true_positive/int(changed.sum()),
            false_positive_rate=false_positive/int((~changed).sum()),
            identity_mean_abs_edit=float((ident-c[indices]).abs().mean()),
            identity_examples_any_edit_over_005=int(((ident-c[indices]).abs().max(1).values>.05).sum()))
        for j,i in enumerate(indices):
            row=rows[i]
            records.append(dict(seed=row['seed'],split=split,source=row['folder'],notes=row['notes'],
                current=row['current'],target=row['target'],changed=row['changed'],
                predicted=dict(zip(KEYS,pred[j].tolist())),identity_predicted=dict(zip(KEYS,ident[j].tolist()))))
    torch.save(dict(model=model.cpu().state_dict(),scale=scale,variant=variant,best_step=best_step,keys=KEYS),out/'checkpoint.pt')
    (out/'predictions.json').write_text(json.dumps(records))
    report=dict(variant=variant,device=str(device),parameters=sum(p.numel() for p in model.parameters()),
                seconds=seconds,best_step=best_step,steps=3000,seed=42,metrics=metrics,
                sampled_mps_driver_peak_bytes=peak,free_gib=shutil.disk_usage(ROOT).free/GIB)
    (out/'training.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)


def render_one(task):
    variant,row,kind=task
    guard();out=BASE/variant/'renders';out.mkdir(exist_ok=True)
    state=row['identity_predicted'] if kind=='identity' else row['predicted']
    # A zero float32 action must preserve the original serialized parameter,
    # rather than introducing a float64 -> float32 -> float64 roundoff edit.
    state={k:row['current'][k] if v==float(np.float32(row['current'][k])) else v
           for k,v in state.items()}
    stem=f'{row["seed"]}-{kind}';project=out/f'{stem}.slab';wav=out/f'{stem}.wav'
    make_project(project,state,row['notes'],row['seed'])
    with (out/f'{stem}.log').open('w') as log:
        subprocess.run([str(ROOT/'zig-out/bin/slab'),str(project),'--render',str(wav),'--bits','16','--no-dither','--rate','48000','--tail','0.5','--threads','1'],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
    inspect_wav(wav)
    folder=Path(row['source']);ref=read(folder/('current.wav' if kind=='identity' else 'target.wav'));current=read(folder/'current.wav');prediction=read(wav)
    return dict(variant=variant,seed=row['seed'],split=row['split'],kind=kind,
        before=0 if kind=='identity' else distance(ref,current),after=distance(ref,prediction),
        source=str(folder),wav=str(wav))


def render():
    tasks=[]
    for variant in VARIANTS:
        rows=json.loads((BASE/variant/'predictions.json').read_text())
        val=[r for r in rows if r['split']=='validation'][:20]
        test=[r for r in rows if r['split']=='test']
        tasks.extend((variant,r,'correction') for r in val+test)
        tasks.extend((variant,r,'identity') for r in test[:10])
    result=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for i,row in enumerate(pool.map(render_one,tasks)):
            result.append(row)
            if (i+1)%20==0:
                (BASE/'render-progress.json').write_text(json.dumps(result))
                print(f'renders {i+1}/{len(tasks)}, free={shutil.disk_usage(ROOT).free/GIB:.2f} GiB',flush=True)
    (BASE/'renders.json').write_text(json.dumps(result,indent=2))
    summary={}
    for variant in VARIANTS:
        summary[variant]={}
        for split,kind in [('validation','correction'),('test','correction'),('test','identity')]:
            rr=[r for r in result if r['variant']==variant and r['split']==split and r['kind']==kind]
            a=np.array([r['before'] for r in rr]);b=np.array([r['after'] for r in rr])
            summary[variant][f'{split}_{kind}']=dict(n=len(rr),before_mean=float(a.mean()),after_mean=float(b.mean()),
                improved=int((b<a-1e-6).sum()),unchanged=int((np.abs(b-a)<=1e-6).sum()),worsened=int((b>a+1e-6).sum()))
    (BASE/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['prepare','train','render'])
    parser.add_argument('--variant',choices=VARIANTS)
    args=parser.parse_args()
    if args.action=='prepare':prepare()
    elif args.action=='train':
        if args.variant is None:parser.error('--variant required')
        train(args.variant)
    else:render()
