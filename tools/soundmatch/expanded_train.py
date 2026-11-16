#!/usr/bin/env python3
"""Mixed continuous/categorical correction model for expanded Cream pilot."""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import time
import numpy as np
import torch
from torch import nn
import torch.nn.functional as F
from train_smoke import Corrector
from ablations import batch
from diverse_train import normalize
from expanded_data import PROFILE,BASE,ROOT,KEYS,CATS,ALL,CATEGORIES,CONTROLS,schema,make_project,guard,render_file
from audit import read,distance

NC=len(KEYS);NK=len(CATS);NG=len(ALL)

class Expanded(Corrector):
    def __init__(self,context_size):
        super().__init__(NC+sum(CATEGORIES.values())+context_size)
        self.encoder[0]=nn.Conv2d(18,32,5,stride=2,padding=2)
        self.head[-1]=nn.Linear(512,NC+NG+sum(CATEGORIES.values()))
        nn.init.zeros_(self.head[-1].weight);nn.init.zeros_(self.head[-1].bias)
        with torch.no_grad():self.head[-1].bias[NC:NC+NG].fill_(-1.5)
    def split(self,x,state):
        out=self(x,state);return out[:,:NC],out[:,NC:NC+NG],out[:,NC+NG:].split(list(CATEGORIES.values()),1)
    def decode(self,x,state,c,cat):
        amount,gates,classes=self.split(x,state);edit=gates>=0
        continuous=torch.where(edit[:,:NC],(c+amount).clamp(0,1),c)
        categorical=torch.stack([torch.where(edit[:,NC+j],logits.argmax(1),cat[:,j]) for j,logits in enumerate(classes)],1)
        return continuous,categorical

def load():
    assert (BASE/'features-ready.json').exists()
    rows=json.loads((BASE/'rows.json').read_text());data=np.load(BASE/'features.npy',mmap_mode='r')
    c=torch.tensor([[r['current'][k] for k in KEYS] for r in rows],dtype=torch.float32)
    y=torch.tensor([[r['target'][k] for k in KEYS] for r in rows],dtype=torch.float32)
    cat=torch.tensor([[r['current'][k] for k in CATS] for r in rows]);yc=torch.tensor([[r['target'][k] for k in CATS] for r in rows])
    fixed=torch.tensor([r['context'] for r in rows],dtype=torch.float32)
    state=torch.cat([c]+[F.one_hot(cat[:,i],n).float() for i,n in enumerate(CATEGORIES.values())]+[fixed],1)
    return rows,data,c,y,cat,yc,state,fixed.shape[1]

def infer(model,data,scale,c,cat,state,indices,device,identity=False):
    model.eval();p=[];q=[]
    with torch.no_grad():
        for start in range(0,len(indices),32):
            ix=indices[start:start+32];x=batch(data,ix,scale,np.ones(len(ix),bool) if identity else None).to(device)
            a,b=model.decode(x,state[ix].to(device),c[ix].to(device),cat[ix].to(device));p.append(a.cpu());q.append(b.cpu())
    return torch.cat(p),torch.cat(q)

def train():
    guard();out=BASE/'model';out.mkdir(exist_ok=False);torch.set_num_threads(4);torch.manual_seed(42);rng=np.random.default_rng(42)
    rows,data,c,y,cat,yc,state,context_size=load();tr=np.array([i for i,r in enumerate(rows) if r['split']=='train']);val=np.array([i for i,r in enumerate(rows) if r['split']=='validation']);test=np.array([i for i,r in enumerate(rows) if r['split']=='test'])
    scale=normalize(data,tr);device=torch.device('mps' if torch.backends.mps.is_available() else 'cpu');model=Expanded(context_size).to(device);opt=torch.optim.AdamW(model.parameters(),lr=3e-4)
    def validation():
        p,q=infer(model,data,scale,c,cat,state,val,device);ip,iq=infer(model,data,scale,c,cat,state,val,device,True)
        mse=float(((p-y[val])**2).mean());ce=float((q!=yc[val]).float().mean());imse=float(((ip-c[val])**2).mean());ice=float((iq!=cat[val]).float().mean())
        return dict(mse=mse,category_error=ce,identity_mse=imse,identity_category_edit=ice,score=.8*mse+.05*ce+.2*imse+.05*ice)
    initial=validation();best=initial['score'];best_step=0;weights=copy.deepcopy(model.state_dict());history=[dict(step=0,**initial)]
    steps=math.ceil(len(tr)*60/32);every=math.ceil(len(tr)*5/32);start=time.perf_counter();peak=0
    print(f'Training {len(tr)} examples, {steps} updates, {sum(p.numel() for p in model.parameters())} weights on {device}',flush=True)
    for step in range(1,steps+1):
        model.train();ix=rng.choice(tr,32,replace=True);ident=rng.random(32)<.1
        x=batch(data,ix,scale,ident).to(device);target=(y[ix]-c[ix]).clone();target[ident]=0
        targets=yc[ix].clone();targets[ident]=cat[ix][ident]
        mask=torch.cat([(target!=0).float(),(targets!=cat[ix]).float()],1).to(device);target=target.to(device);targets=targets.to(device)
        amount,gates,classes=model.split(x,state[ix].to(device))
        loss=((amount*gates[:,:NC].sigmoid()-target)**2).mean()
        loss+=.25*(((amount-target)**2)*mask[:,:NC]).sum()/mask[:,:NC].sum().clamp_min(1)
        loss+=.02*F.binary_cross_entropy_with_logits(gates,mask)
        cat_loss=sum((F.cross_entropy(logits,targets[:,j],reduction='none')*mask[:,NC+j]).sum() for j,logits in enumerate(classes))/mask[:,NC:].sum().clamp_min(1)
        loss+=.05*cat_loss
        opt.zero_grad(set_to_none=True);loss.backward();opt.step()
        if device.type=='mps':peak=max(peak,torch.mps.driver_allocated_memory())
        if step%every==0 or step==steps:
            guard();metrics=validation();history.append(dict(step=step,**metrics))
            if metrics['score']<best:best=metrics['score'];best_step=step;weights=copy.deepcopy(model.state_dict())
            (out/'history.json').write_text(json.dumps(history,indent=2));print(f'{step}/{steps}: val MSE {metrics["mse"]:.4f}, category error {metrics["category_error"]:.3f}, selected {best_step}',flush=True)
    if device.type=='mps':torch.mps.synchronize()
    seconds=time.perf_counter()-start;model.load_state_dict(weights);reports={};records=[]
    for split,ix in [('validation',val),('test',test)]:
        p,q=infer(model,data,scale,c,cat,state,ix,device);ip,iq=infer(model,data,scale,c,cat,state,ix,device,True)
        reports[split]={}
        for group in ['all','familiar','patch','phrase','joint','new-only','combined','sparse','dense','identity']:
            take=[j for j,i in enumerate(ix) if group=='all' or rows[i]['group']==group or rows[i]['severity']==group]
            if not take:continue
            ii=ix[take];cm=cat[ii]!=yc[ii]
            reports[split][group]=dict(count=len(take),baseline_continuous_mse=float(((c[ii]-y[ii])**2).mean()),continuous_mse=float(((p[take]-y[ii])**2).mean()),baseline_category_accuracy=float((cat[ii]==yc[ii]).float().mean()),category_accuracy=float((q[take]==yc[ii]).float().mean()),changed_category_accuracy=float((q[take][cm]==yc[ii][cm]).float().mean()) if cm.any() else None,identity_probe_pairs_edited=int((((ip[take]-c[ii]).abs().max(1).values>1e-6)|(iq[take]!=cat[ii]).any(1)).sum()))
        for j,i in enumerate(ix):
            row=rows[i];pred={k:row['current'][k] if float(p[j,h])==float(c[i,h]) else float(p[j,h]) for h,k in enumerate(KEYS)}
            pred.update({k:int(q[j,h]) for h,k in enumerate(CATS)})
            records.append(dict(index=int(i),seed=row['seed'],split=split,group=row['group'],severity=row['severity'],folder=row['folder'],predicted=pred))
    (out/'predictions.json').write_text(json.dumps(records,indent=2))
    torch.save(dict(model=model.cpu().state_dict(),context_size=context_size,keys=KEYS,categories=CATEGORIES,context_schema=schema(),scale=scale,best_step=best_step),out/'checkpoint.pt')
    report=dict(seconds=seconds,seed=42,steps=steps,best_step=best_step,device=str(device),parameter_count=sum(p.numel() for p in model.parameters()),sampled_mps_driver_peak_bytes=peak,metrics=reports,source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),dataset_sha256=hashlib.sha256((BASE/'rows.json').read_bytes()).hexdigest())
    (out/'training.json').write_text(json.dumps(report,indent=2));print(json.dumps(dict(seconds=seconds,test=reports['test']['all']),indent=2),flush=True)

def render():
    import auraloss
    from auraloss_trial import CONFIG,tensor
    torch.set_num_threads(2);loss=auraloss.freq.MultiResolutionSTFTLoss(**CONFIG)
    rows={r['seed']:r for r in json.loads((BASE/'rows.json').read_text())};pred=[r for r in json.loads((BASE/'model/predictions.json').read_text()) if r['split']=='test'];out=BASE/'evaluation';out.mkdir(exist_ok=False)
    def work(p):
        row=rows[p['seed']];wav=out/f'{p["seed"]}.wav';make_project(wav.with_suffix('.slab'),row,p['predicted']);render_file(wav.with_suffix('.slab'),wav);return p,wav
    results=[]
    with ThreadPoolExecutor(max_workers=6) as pool:
        for p,wav in pool.map(work,pred):
            row=rows[p['seed']];folder=Path(row['folder']);target=read(folder/'target.wav');current=read(folder/'current.wav');predicted=read(wav)
            with torch.inference_mode():
                t=tensor(folder/'target.wav');before=float(loss(tensor(folder/'current.wav'),t));after=float(loss(tensor(wav),t))
            results.append(dict(seed=p['seed'],group=p['group'],severity=p['severity'],before=distance(target,current),after=distance(target,predicted),auraloss_before=before,auraloss_after=after,identity_pcm_equal=bool(np.array_equal(target,predicted)) if p['severity']=='identity' else None,wav=str(wav)))
            if len(results)%40==0:print(f'evaluated {len(results)}/200',flush=True)
    (out/'results.json').write_text(json.dumps(results,indent=2));summary={}
    for group in ['all','familiar','patch','phrase','joint']+(['sparse','dense'] if PROFILE=='oscillator' else ['new-only','combined']):
        rr=[r for r in results if r['severity']!='identity' and (group=='all' or r['group']==group or r['severity']==group)]
        summary[group]=dict(count=len(rr),before=float(np.mean([r['before'] for r in rr])),after=float(np.mean([r['after'] for r in rr])),auraloss_before=float(np.mean([r['auraloss_before'] for r in rr])),auraloss_after=float(np.mean([r['auraloss_after'] for r in rr])),improved=sum(r['after']<r['before']-1e-6 for r in rr),worsened=sum(r['after']>r['before']+1e-6 for r in rr))
    summary['identity_changed']=sum(not r['identity_pcm_equal'] for r in results if r['severity']=='identity')
    (out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2),flush=True)
    trials=[];key={};sides=['A','B']*4;rng=random.Random(2041);rng.shuffle(sides)
    for g in ['familiar','patch','phrase','joint']:
        for mode in (['sparse','dense'] if PROFILE=='oscillator' else ['new-only','combined']):
            r=next(r for r in results if r['group']==g and r['severity']==mode);row=rows[r['seed']];side=sides[len(trials)];other='B' if side=='A' else 'A';tid=f'expanded-{len(trials)+1:02d}'
            trials.append(dict(id=tid,sources={'reference':str(Path(row['folder'])/'target.wav'),side:r['wav'],other:str(Path(row['folder'])/'current.wav')}));key[tid]=dict(seed=r['seed'],group=g,mode=mode,assignment={side:'model',other:'unchanged'})
    rng.shuffle(trials);(BASE/'manifest.json').write_text(json.dumps(dict(experiment={'legacy26':'expanded-v1','ranges':'expanded-ranges-v1','oscillator':'oscillator-v1'}[PROFILE],title='Expanded Cream controls',trials=trials),indent=2));(BASE/'blind-key.json').write_text(json.dumps(key,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('action',choices=['train','render']);a=p.parse_args()
    train() if a.action=='train' else render()
