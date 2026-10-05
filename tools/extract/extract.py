#!/usr/bin/env python3
"""The Extract pack (docs/30 §Stems): HTDemucs as a CoreML model for
Slab's stem separation.

Run by the pack's IMPORT (or by hand). It needs `uv` to make its own
Python 3.12 with PyTorch, Demucs and coremltools (about 1 GB, in
<home>/Cache/extract-venv), downloads the HTDemucs weights (Meta's, MIT,
about 80 MB), converts the network's core — the spectrogram and the
waveform in, each stem's spectrogram and waveform out; Slab does the STFT
and its inverse — compiles it, checks it against PyTorch on a test signal,
and installs it into $SLAB_LIBRARY/extract/models/.

    python3 tools/extract/extract.py

It runs in 32-bit floats: in 16 the network's normalizations overflow
(NaN), and on the GPU 32-bit takes 0.3 s per 7.8 s segment anyway.
"""
import os, sys, subprocess, shutil, json, math

HERE = os.path.dirname(os.path.abspath(__file__))
PY_VERSION = "3.12"
DEPS = ["torch==2.5.1", "torchaudio==2.5.1", "coremltools==9.0", "demucs==4.0.1", "numpy<2.3", "soundfile"]
SEGMENT = 343980          # HTDemucs' 7.8 s at 44.1 kHz
FRAMES = 336              # ceil(SEGMENT / 1024)
SOURCES = ["drums", "bass", "other", "vocals"]


def home():
    """As Slab finds it: $SLAB_HOME, else settings.json's "home", else
    ~/Music/Slab (storage.zig)."""
    if os.environ.get("SLAB_HOME"):
        return os.environ["SLAB_HOME"]
    settings = os.environ.get("SLAB_SETTINGS") or os.path.expanduser("~/Library/Application Support/Slab/settings.json")
    try:
        with open(settings) as f:
            h = json.load(f).get("home") or ""
        if h:
            return os.path.expanduser(h)
    except (OSError, ValueError):
        pass
    return os.path.join(os.path.expanduser("~"), "Music", "Slab")


def library():
    return os.environ.get("SLAB_LIBRARY") or os.path.join(home(), "Library")


def log(*a):
    print(*a, flush=True)


def bootstrap():
    """Re-run inside our own venv, making it first."""
    venv = os.path.join(home(), "Cache", "extract-venv")
    py = os.path.join(venv, "bin", "python")
    if os.path.realpath(sys.executable) == os.path.realpath(py) or os.environ.get("SLAB_EXTRACT_INNER"):
        return
    uv = shutil.which("uv") or os.path.expanduser("~/.local/bin/uv")
    if not os.path.exists(uv):
        sys.exit("The Extract pack needs uv to set up its Python: brew install uv")
    if not os.path.exists(py):
        log(f"Making a Python {PY_VERSION} for the converter in {venv}")
        subprocess.check_call([uv, "venv", "-q", "--python", PY_VERSION, venv])
    log("Installing PyTorch, Demucs and coremltools (once; about 1 GB)")
    subprocess.check_call([uv, "pip", "install", "-q", "--python", py] + DEPS)
    env = dict(os.environ, SLAB_EXTRACT_INNER="1")
    os.execve(py, [py, "-u", os.path.abspath(__file__)] + sys.argv[1:], env)


class Core:
    """HTDemucs from its normalized-later inputs to its denormalized
    outputs, without the STFT: forward() in demucs/htdemucs.py between
    `_magnitude` and `_mask`, and the time branch."""

    @staticmethod
    def make(model):
        import torch
        from einops import rearrange

        class M(torch.nn.Module):
            def __init__(self, m):
                super().__init__()
                self.m = m

            def forward(self, mag, mix):
                m = self.m
                x = mag
                # Fixed shapes, as constants: a size read off a tensor
                # traces into casts CoreML can't take.
                B, Fq, T = 1, 2048, FRAMES
                mean = x.mean(dim=(1, 2, 3), keepdim=True)
                std = x.std(dim=(1, 2, 3), keepdim=True)
                x = (x - mean) / (1e-5 + std)
                xt = mix
                meant = xt.mean(dim=(1, 2), keepdim=True)
                stdt = xt.std(dim=(1, 2), keepdim=True)
                xt = (xt - meant) / (1e-5 + stdt)
                saved, saved_t, lengths, lengths_t = [], [], [], []
                for idx, encode in enumerate(m.encoder):
                    lengths.append(x.shape[-1])
                    inject = None
                    if idx < len(m.tencoder):
                        lengths_t.append(xt.shape[-1])
                        tenc = m.tencoder[idx]
                        xt = tenc(xt)
                        if not tenc.empty:
                            saved_t.append(xt)
                        else:
                            inject = xt
                    x = encode(x, inject)
                    if idx == 0 and m.freq_emb is not None:
                        frs = torch.arange(x.shape[-2], device=x.device)
                        emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                        x = x + m.freq_emb_scale * emb
                    saved.append(x)
                if m.crosstransformer:
                    if m.bottom_channels:
                        b, c, f, t = x.shape
                        x = rearrange(x, "b c f t-> b c (f t)")
                        x = m.channel_upsampler(x)
                        x = rearrange(x, "b c (f t)-> b c f t", f=f)
                        xt = m.channel_upsampler_t(xt)
                    x, xt = m.crosstransformer(x, xt)
                    if m.bottom_channels:
                        x = rearrange(x, "b c f t-> b c (f t)")
                        x = m.channel_downsampler(x)
                        x = rearrange(x, "b c (f t)-> b c f t", f=f)
                        xt = m.channel_downsampler_t(xt)
                for idx, decode in enumerate(m.decoder):
                    skip = saved.pop(-1)
                    x, pre = decode(x, skip, lengths.pop(-1))
                    offset = m.depth - len(m.tdecoder)
                    if idx >= offset:
                        tdec = m.tdecoder[idx - offset]
                        length_t = lengths_t.pop(-1)
                        if tdec.empty:
                            pre = pre[:, :, 0]
                            xt, _ = tdec(pre, None, length_t)
                        else:
                            skip = saved_t.pop(-1)
                            xt, _ = tdec(xt, skip, length_t)
                S = len(m.sources)
                x = x.view(B, S, -1, Fq, T)
                x = x * std[:, None] + mean[:, None]
                xt = xt.view(B, S, -1, SEGMENT)
                xt = xt * stdt[:, None] + meant[:, None]
                return x, xt

        return M(model).eval()


def patch_coremltools():
    """coremltools 9 casts a folded one-element shape with `int(array)`,
    which NumPy 2 refuses; cast its one element."""
    import numpy as np
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops

    def _cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
            raise ValueError("input to cast must be either a scalar or a length 1 tensor")
        if x.can_be_folded_to_const():
            v = x.val
            res = x if isinstance(v, dtype) else mb.const(val=dtype(np.asarray(v).reshape(-1)[0]), name=node.name)
        elif len(x.shape) > 0:
            res = mb.cast(x=mb.squeeze(x=x, name=node.name + "_item"), dtype=dtype_name, name=node.name)
        else:
            res = mb.cast(x=x, dtype=dtype_name, name=node.name)
        context.add(res, node.name)

    ops._cast = _cast


def convert():
    import numpy as np
    import torch
    import coremltools as ct
    from demucs.pretrained import get_model
    patch_coremltools()
    # Trace attention as its plain ops, not PyTorch's fused kernel.
    torch.backends.mha.set_fastpath_enabled(False)

    log("Downloading HTDemucs (once; about 80 MB)")
    bag = get_model("htdemucs")
    model = bag.models[0].eval()
    assert list(model.sources) == SOURCES, model.sources
    assert int(model.segment * model.samplerate) == SEGMENT
    core = Core.make(model)

    # A test signal: a minute of something with drums, bass and a tone.
    rng = np.random.default_rng(1)
    t = np.arange(SEGMENT) / 44100
    mix = 0.2 * np.sin(2 * np.pi * 110 * t) + 0.1 * np.sin(2 * np.pi * 440 * t)
    for k in range(16):
        s = int(k * 0.5 * 44100)
        n = min(9000, SEGMENT - s)
        tt = np.arange(n) / 44100
        mix[s:s + n] += 0.6 * np.exp(-tt * 20) * np.sin(2 * np.pi * (50 + 100 * np.exp(-tt * 40)) * tt)
        mix[s + 11025:s + 11025 + 3000] += 0.1 * rng.standard_normal(min(3000, max(0, SEGMENT - s - 11025)))
    mixt = torch.tensor(np.stack([mix, mix * 0.9]), dtype=torch.float32)[None]
    with torch.no_grad():
        z = model._spec(mixt)
        mag = model._magnitude(z)
        ref = model(mixt)
        traced = torch.jit.trace(core, (mag, mixt))

    log("Converting to CoreML")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mag", shape=tuple(mag.shape)), ct.TensorType(name="mix", shape=tuple(mixt.shape))],
        outputs=[ct.TensorType(name="spec"), ct.TensorType(name="wave")],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "HTDemucs (Défossez et al., MIT) core for Slab's stem separation: mag (1,4,2048,336) and mix (1,2,343980) at 44.1 kHz in; per stem (drums, bass, other, vocals) a complex-as-channels spectrogram and a waveform out."

    # The same through CoreML, finished as demucs finishes it.
    out = mlmodel.predict({"mag": mag.numpy(), "mix": mixt.numpy()})
    spec = torch.tensor(out["spec"])
    wave = torch.tensor(out["wave"])
    with torch.no_grad():
        zout = model._mask(z, spec)
        est = model._ispec(zout, SEGMENT) + wave
    err = (est - ref).pow(2).sum().item()
    sig = ref.pow(2).sum().item()
    sdr = 10 * math.log10(sig / max(err, 1e-20))
    log(f"CoreML against PyTorch: {sdr:.1f} dB")
    if not sdr >= 25:
        sys.exit("The converted model doesn't match PyTorch; not installing it")
    return mlmodel, sdr


def main():
    bootstrap()
    import coremltools as ct
    mlmodel, sdr = convert()
    dest = os.path.join(library(), "extract")
    models = os.path.join(dest, "models")
    os.makedirs(models, exist_ok=True)
    tmp = os.path.join(models, "htdemucs.mlpackage")
    if os.path.exists(tmp):
        shutil.rmtree(tmp)
    mlmodel.save(tmp)
    log("Compiling")
    out = os.path.join(models, "htdemucs.mlmodelc")
    if os.path.exists(out):
        shutil.rmtree(out)
    compiled = ct.models.utils.compile_model(tmp)
    shutil.move(str(compiled), out)
    shutil.rmtree(tmp)
    with open(os.path.join(dest, "README.txt"), "w") as f:
        f.write("HTDemucs (Hybrid Transformer Demucs), Alexandre Défossez et al., Meta AI.\n"
                "https://github.com/facebookresearch/demucs — MIT License, Copyright (c) Meta Platforms, Inc.\n"
                "Converted to CoreML by Slab's tools/extract/extract.py for its stem separation (docs/30).\n")
    with open(os.path.join(models, "htdemucs.json"), "w") as f:
        json.dump({"sources": SOURCES, "rate": 44100, "segment": SEGMENT, "frames": FRAMES,
                   "nfft": 4096, "hop": 1024, "precision": "fp32",
                   "check_db": round(sdr, 1)}, f, indent=1)
    log(f"Installed {out}")


if __name__ == "__main__":
    main()
