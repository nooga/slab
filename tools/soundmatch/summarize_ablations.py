#!/usr/bin/env python3
"""Summarize predeclared ablations, with paired example bootstrap intervals."""
import json
import numpy as np
from ablations import BASE, VARIANTS


def main():
    renders=json.loads((BASE/'renders.json').read_text())
    summary=json.loads((BASE/'summary.json').read_text())
    combined={}
    rng=np.random.default_rng(123)
    resamples=rng.integers(0,100,size=(5000,100))
    for v in VARIANTS:
        training=json.loads((BASE/v/'training.json').read_text())
        rows=sorted([r for r in renders if r['variant']==v and r['split']=='test' and r['kind']=='correction'],key=lambda r:r['seed'])
        assert len(rows)==100
        before=np.array([r['before'] for r in rows]);after=np.array([r['after'] for r in rows])
        diff=after-before
        ci=np.quantile(diff[resamples].mean(1),[.025,.975])
        combined[v]=dict(training=training,audio=summary[v],
                        test_spectral_mean_difference_ci95=ci.tolist(),
                        test_spectral_relative_change_percent=float(100*(after.mean()/before.mean()-1)))
    winner=min(VARIANTS,key=lambda v:summary[v]['validation_correction']['after_mean'])
    def errors(variant):
        return np.array([r['after'] for r in sorted(
            [r for r in renders if r['variant']==variant and r['split']=='test' and r['kind']=='correction'],
            key=lambda r:r['seed'])])
    representation_diff=errors('selective_multires')-errors('selective_zero')
    representation_ci=np.quantile(representation_diff[resamples].mean(1),[.025,.975])
    result=dict(validation_audio_winner=winner,variants=combined,
                representation_mean_difference=float(representation_diff.mean()),
                representation_difference_ci95=representation_ci.tolist(),
                note='Single training seed. Bootstrap resamples test examples, not training runs. Negative spectral differences favor correction. Listening ratings not collected.')
    (BASE/'comparison.json').write_text(json.dumps(result,indent=2))
    lines=['# Ablation results — 2026-11-03','',
           'All four arms trained for 3,000 updates on the same 800 training phrases. Checkpoints used 200 validation phrases, including identity probes. Test: 100 fresh phrases, plus their matching-audio counterparts. No threshold or hyperparameter was tuned using the new test scores.','',
           '| Model | Test parameter MSE | Spectral error ↓ | Improved / unchanged / worsened | Identity probes with >5% edit | Train seconds |',
           '|---|---:|---:|---:|---:|---:|']
    first=combined['dense'];before=first['audio']['test_correction']['before_mean']
    lines.append(f'| Unchanged | {first["training"]["metrics"]["test"]["baseline_mse"]:.6f} | {before:.4f} | — | 0 | — |')
    for v,r in combined.items():
        m=r['training']['metrics']['test'];a=r['audio']['test_correction']
        lines.append(f'| {v} | {m["mse"]:.6f} | {a["after_mean"]:.4f} | {a["improved"]} / {a["unchanged"]} / {a["worsened"]} | {m["identity_examples_any_edit_over_005"]}/100 | {r["training"]["seconds"]:.1f} |')
    lines.extend(['',f'Validation-audio winner (first 20 validation examples, chosen independently of test scores): `{winner}`.','',
                  'Spectral error uses the same multiresolution convergence metric throughout. Parameter and audio rankings need not agree. Unchanged predictions count separately from improvements. Exact zero actions retain original parameter serialization to avoid roundoff edits.','',
                  '| Model | Edit precision | Edit recall | False-positive rate on correct controls | Mean identity edit | Test spectral difference 95% interval |',
                  '|---|---:|---:|---:|---:|---|'])
    for v,r in combined.items():
        m=r['training']['metrics']['test'];ci=r['test_spectral_mean_difference_ci95']
        lines.append(f'| {v} | {m["edit_precision"]:.1%} | {m["edit_recall"]:.1%} | {m["false_positive_rate"]:.1%} | {m["identity_mean_abs_edit"]:.5f} | [{ci[0]:.4f}, {ci[1]:.4f}] |')
    lines.extend(['','Intervals are paired bootstrap intervals over the 100 examples; they do not account for variation across training seeds. Dense-model false-positive rates count any edit above 1e-6 normalized units.','',
                  f'Multiresolution minus old selective mean spectral difference: {representation_diff.mean():.5f}; paired 95% interval [{representation_ci[0]:.5f}, {representation_ci[1]:.5f}]. Its point estimate is better, but the interval includes zero. The evidence for selective edits is stronger than the evidence for an additional representation benefit.','',
                  'Both selective models used a fixed 0.5 gate threshold, with generator labels only as training supervision. No oracle mask or detune freeze was used at inference. Identity probes are learned behavior, not a hard-coded bypass.','',
                  'All 20 selective identity renders (10 per model) have PCM bytes identical to their current recordings. Whole WAV hashes differ because export metadata reflects the newly generated project.','',
                  'The selective architecture is a package of gating and additional supervised losses. Multiresolution changes spectral sampling and adds 9,600 first-layer parameters. All runs have one training seed, one synth family and known notes. These results do not establish real-recording or mixed-track performance.','',
                  'No acoustic-loss training was performed in these ablations. This suite tests zero-correction data, selective prediction and input representation; the renderer evaluates predictions. Future audio-loss experiments should remain a separate comparison.','',
                  'Preparation took '+str(round(sum(json.loads((BASE/f'{rep}-meta.json').read_text())['seconds'] for rep in ['old','multi']),1))+' seconds. Training times include periodic validation; all 520 renders and metric computation are additional.','',
                  'Listening materials: `scratch/soundmatch-ablations/listening/README.md`, three randomized montages and an empty ratings CSV. No human listening scores have been collected. Examples are the first three fresh test phrases, not selected for favorable results.','',
                  'Machine-readable reports, checkpoints and learning curves: `scratch/soundmatch-ablations/`. See [ABLATIONS.md](ABLATIONS.md) for protocol and commands.'])
    from pathlib import Path
    Path('tools/soundmatch/ABLATION_RESULTS.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines[:12]))


if __name__=='__main__':main()
