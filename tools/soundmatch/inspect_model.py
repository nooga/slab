#!/usr/bin/env python3
"""Weight-guided diagnostic probes, without training or replacing checkpoints."""
import copy
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess

import numpy as np
import torch
from audit import read, distance
from generate import ROOT, GIB, make_project, inspect_wav
from train_smoke import Corrector, features


def main():
    torch.set_num_threads(4)
    out = ROOT / 'scratch/soundmatch-inspection'
    out.mkdir(exist_ok=True)
    path = ROOT / 'scratch/soundmatch-large-audio/checkpoint.pt'
    checkpoint_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    ck = torch.load(path, map_location='cpu', weights_only=True)
    keys = ck['controls']
    model = Corrector(len(keys)).eval()
    model.load_state_dict(ck['model'])
    original = json.loads((ROOT/'scratch/soundmatch-large-audio/report.json').read_text())
    rows = original['rendered_checks']
    inputs, states, targets, labels = [], [], [], []
    for row in rows:
        folder = Path(row['source'])
        label = json.loads((folder/'labels.json').read_text())
        a, b = features(folder/'target.wav'), features(folder/'current.wav')
        inputs.append(np.concatenate([a, b, a-b]))
        states.append([label['current'][k] for k in keys])
        targets.append([label['target'][k] for k in keys])
        labels.append(label)
    x = torch.tensor(np.stack(inputs))/ck['feature_scale']
    c, y = torch.tensor(states), torch.tensor(targets)
    def forward(m, audio):
        with torch.no_grad():
            return torch.cat([m(xx, cc) for xx,cc in zip(audio.split(10),c.split(10))])
    delta = forward(model,x)
    identical = x.clone()
    identical[:,:2] = x[:,2:4]
    identical[:,4:] = 0
    identity_delta = forward(model,identical)
    biasless = copy.deepcopy(model)
    with torch.no_grad():
        biasless.head[-1].bias.zero_()
    biasless_delta = forward(biasless,x)
    detuneless = copy.deepcopy(model)
    idx = keys.index('detune2')
    with torch.no_grad():
        detuneless.head[-1].weight[idx].zero_()
        detuneless.head[-1].bias[idx].zero_()
    detuneless_delta = forward(detuneless,x)
    with torch.no_grad():
        h = model.head[0](torch.cat([model.encoder(x),c],1))
        gelu_prime = .5*(1+torch.erf(h/math.sqrt(2))) + h*torch.exp(-h*h/2)/math.sqrt(2*math.pi)
        jac = torch.einsum('oh,bh,hi->boi', model.head[2].weight,gelu_prime,model.head[0].weight[:,-len(keys):])
    def metrics(d):
        pred=(c+d).clamp(0,1)
        unchanged=(y==c)
        return dict(mse=float(((pred-y)**2).mean()), unchanged_mean_abs_edit=float((pred-c).abs()[unchanged].mean()))
    result = dict(checkpoint_sha256=checkpoint_hash, examples=len(rows),
                  unchanged=metrics(torch.zeros_like(delta)), full=metrics(delta),
                  output_bias_zero=metrics(biasless_delta), detune_row_zero=metrics(detuneless_delta),
                  identical_audio_mean_abs_delta=float(identity_delta.abs().mean()),
                  identical_audio_examples_max_delta_over_005=int((identity_delta.abs().max(1).values>.05).sum()),
                  identity_by_control={k:float(identity_delta[:,j].abs().mean()) for j,k in enumerate(keys)},
                  direct_settings_jacobian_mean=jac.mean(0).tolist(),
                  direct_settings_self_derivative={k:float(jac[:,j,j].mean()) for j,k in enumerate(keys)},
                  feature_resolution=dict(stft_bin_hz=48000/1024,pooled_bin_hz=48000/1024*4,
                                          pooled_time_seconds=256/48000*8),
                  output_bias_contribution_mean_abs=float((delta-biasless_delta).abs().mean()))
    # Diagnostic, not independent evaluation: the first 24 already-used test pairs.
    results=[]
    for i,row in enumerate(rows[:24]):
        label=labels[i]
        target=read(Path(row['source'])/'target.wav')
        for variant,d in [('detune_row_zero',detuneless_delta[i]),('oracle_edit_mask',delta[i])]:
            if shutil.disk_usage(out).free<20*GIB:raise RuntimeError('Disk floor')
            state=dict(zip(keys,(c[i]+d).clamp(0,1).tolist()))
            if variant=='oracle_edit_mask':
                for k in keys:
                    if k not in label['changed']:state[k]=label['current'][k]
            project=out/f'{row["seed"]}-{variant}.slab'
            wav=project.with_suffix('.wav')
            make_project(project,state,label['notes'],label['seed'])
            with project.with_suffix('.log').open('w') as log:
                subprocess.run([str(ROOT/'zig-out/bin/slab'),str(project),'--render',str(wav),
                                '--bits','16','--no-dither','--rate','48000','--tail','0.5','--threads','1'],
                               cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
            inspect_wav(wav)
            results.append(dict(seed=row['seed'],variant=variant,before=row['before'],full=row['after'],after=distance(target,read(wav))))
        if (i+1)%8==0:print(f'diagnostic renders {i+1}/24',flush=True)
    result['render_rows']=results
    result['render_summary']={}
    for variant in ['detune_row_zero','oracle_edit_mask']:
        rr=[r for r in results if r['variant']==variant]
        result['render_summary'][variant]=dict(count=len(rr),before=float(np.mean([r['before'] for r in rr])),
            full=float(np.mean([r['full'] for r in rr])),after=float(np.mean([r['after'] for r in rr])),
            better_than_full=sum(r['after']<r['full'] for r in rr),better_than_unchanged=sum(r['after']<r['before'] for r in rr))
    assert hashlib.sha256(path.read_bytes()).hexdigest()==checkpoint_hash
    result['note']='No training; diagnostic reuse of prior test data; oracle mask uses hidden labels and is not deployable. Original checkpoint unchanged.'
    (out/'probes.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ['render_rows','direct_settings_jacobian_mean']},indent=2))


if __name__=='__main__':main()
