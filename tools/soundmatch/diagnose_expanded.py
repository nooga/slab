#!/usr/bin/env python3
"""Measure train/test generalization and per-control recovery for a saved model."""
import json
import time
import numpy as np
import torch
from expanded_train import Expanded,load,infer
from expanded_data import BASE,KEYS,CATS


def main():
    torch.set_num_threads(2);start=time.perf_counter()
    rows,data,c,y,cat,yc,state,ctx=load()
    checkpoint=torch.load(BASE/'model/checkpoint.pt',map_location='cpu',weights_only=False)
    assert checkpoint['keys']==KEYS and list(checkpoint['categories'])==CATS
    model=Expanded(ctx);model.load_state_dict(checkpoint['model']);report={}
    for split in ['train','validation','test']:
        ix=np.array([i for i,r in enumerate(rows) if r['split']==split]);p,q=infer(model,data,checkpoint['scale'],c,cat,state,ix,torch.device('cpu'))
        changed=cat[ix]!=yc[ix]
        metrics=dict(count=len(ix),continuous_mse=float(((p-y[ix])**2).mean()),baseline_continuous_mse=float(((c[ix]-y[ix])**2).mean()),category_accuracy=float((q==yc[ix]).float().mean()),baseline_category_accuracy=float((cat[ix]==yc[ix]).float().mean()),changed_category_accuracy=float((q[changed]==yc[ix][changed]).float().mean()))
        metrics['per_category']={}
        for j,k in enumerate(CATS):
            mask=changed[:,j]
            metrics['per_category'][k]=dict(changed_count=int(mask.sum()),changed_accuracy=float((q[mask,j]==yc[ix][mask,j]).float().mean()) if mask.any() else None,accuracy=float((q[:,j]==yc[ix,j]).float().mean()),baseline_accuracy=float((cat[ix,j]==yc[ix,j]).float().mean()))
            n=checkpoint['categories'][k]
            metrics['per_category'][k]['confusion_target_rows_predicted_columns']=torch.bincount(yc[ix,j]*n+q[:,j],minlength=n*n).reshape(n,n).tolist()
        report[split]=metrics;print(split,json.dumps(metrics),flush=True)
    report['seconds']=time.perf_counter()-start;(BASE/'model/generalization.json').write_text(json.dumps(report,indent=2))

if __name__=='__main__':main()
