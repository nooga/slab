#!/usr/bin/env python3
"""The MRT2 pack (docs/42): Magenta RealTime 2 for *Render with MRT2…*.

Run by the pack's IMPORT (or by hand). It downloads Google DeepMind's
mrt2_small weights and the MusicCoCa and SpectroStream resources from
Hugging Face at a pinned revision (CC-BY-4.0, about 1.8 GB, checked by
SHA-256), then builds `mrt_render` (tools/mrt2/native) against upstream's
C++ engine, magentart::core. MLX comes prebuilt from the mlx-metal wheel,
so no Metal toolchain is needed; TFLite and SentencePiece build from
source (about 15 minutes and 2 GB in <home>/Cache, once). It needs uv,
git and the Xcode command-line tools.

It installs into $SLAB_LIBRARY/mrt2/:

    bin/        mrt_render, with MLX's dylibs and mlx.metallib beside it
    models/     mrt2_small/ (the .mlxfn and its state)
    resources/  musiccoca/ and spectrostream/

    python3 tools/mrt2/mrt2.py [--from DIR]

--from copies the weights from an existing Magenta RT 2 folder (the apps'
~/Documents/Magenta/magenta-rt-v2, say) instead of downloading them; they
are checked against the same hashes.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
HF_REPO = "google/magenta-realtime-2"
HF_REVISION = "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc"   # 2026-06-04
MAGENTA_REPO = "https://github.com/magenta/magenta-realtime.git"
MAGENTA_SHA = "694a545e4ba0b88bf1150137b129582166d3e07f"    # 2026-10-17
# magenta-rt leaves MLX unpinned. 0.32 can't load the published .mlxfn exports
# ("[import_function] Invalid string size", magenta/magenta-realtime#103).
MLX = ["mlx==0.31.2", "mlx-metal==0.31.2", "cmake>=3.27,<4"]
PY_VERSION = "3.12"

# (path in the HF repo, size, sha256): what mrt_render reads for mrt2_small.
FILES = [
    ("models/mrt2_small/mrt2_small.mlxfn", 455654550, "1a70b0de30b3e6ad054fe6a61a7765408f01127628e6362c1abc328809a3c422"),
    ("models/mrt2_small/mrt2_small_state.safetensors", 8676998, "23f1e05a6beea306fe39970bd61193f2d3e5fbd8f08af93570bda4ca9ec33255"),
    ("resources/musiccoca/audio_preprocessor.tflite", 8729640, "656ca4c358451c2b85932e66efcfd2ba62492f4435953d775bfc1d3c08329a30"),
    ("resources/musiccoca/mapper.tflite", 86166664, "2f9743cc8f121a588b69c7f4d79a2a4111ce81864cbde8830054cd5e97f3d717"),
    ("resources/musiccoca/music_encoder.tflite", 370935584, "0d4501af799834e383d904c34ee826c61eb53c69682bf15a981a46c1bb32793a"),
    ("resources/musiccoca/pretrained_vector_quantizer.tflite", 72422108, "7a8a19e2119ad405818eae84a331a970f1a582b3389d4bfd27814f75b455a444"),
    ("resources/musiccoca/spm.model", 517448, "ff325a99b61ba5726cf6437cde6eefbb633dbaa363a684f7a97ed99b55202cca"),
    ("resources/musiccoca/text_encoder.tflite", 418674324, "e1222e3418cbe8cc2623939571bae8e9ab6f0d511404b0d83da69f4e6e11b272"),
    ("resources/spectrostream/decoder.safetensors", 209853216, "0ac6f100a24945fb434783fde6acd7902ceaa8bca492ca317edfc75dd51c42dd"),
    ("resources/spectrostream/encoder.safetensors", 37013392, "f20c197ddcbb9cd43e1a97f9bee0d07d211f79966cd3862d9830a32885090f72"),
    ("resources/spectrostream/quantizer.safetensors", 67108984, "0ba89dcb85344bb14f4f34b8f597c0d6adaa560002d4fd88879a2944c98a20f0"),
    ("resources/spectrostream/spectrostream_encoder.mlxfn", 104319983, "887c25b21aa1714d19907fc96963c6440d5911f11571054cd5acf7306c260905"),
]

README = """Magenta RealTime 2 for Slab (docs/42)

Model weights: Google DeepMind, Magenta RealTime 2 (mrt2_small), CC-BY-4.0,
https://huggingface.co/google/magenta-realtime-2 at {rev}.
Google claims no rights in outputs you generate; you are responsible for them.
Engine: magentart::core, Apache-2.0, https://github.com/magenta/magenta-realtime
at {sha}, with MLX 0.31.2 (MIT, Apple).
"""


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


def find_tool(name):
    # An app started from Finder has launchd's PATH, without Homebrew's or
    # the installers' bin directories, so look where the tools usually land.
    candidates = [f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}", f"~/.local/bin/{name}", f"~/.cargo/bin/{name}"]
    return shutil.which(name) or next((p for p in map(os.path.expanduser, candidates) if os.path.exists(p)), None)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(rel, size, digest, dest, source):
    """One weight file into dest: copied from source, or downloaded with resume."""
    if os.path.exists(dest) and os.path.getsize(dest) == size and sha256(dest) == digest:
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    part = dest + ".part"
    if source:
        shutil.copyfile(os.path.join(source, rel), part)
    else:
        url = f"https://huggingface.co/{HF_REPO}/resolve/{HF_REVISION}/{rel}"
        have = os.path.getsize(part) if os.path.exists(part) else 0
        req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
        with urllib.request.urlopen(req) as r, open(part, "ab" if have and r.status == 206 else "wb") as f:
            got = have if r.status == 206 else 0
            last = -1
            while block := r.read(1 << 20):
                f.write(block)
                got += len(block)
                pct = got * 100 // size
                if pct // 10 != last // 10:
                    log(f"  {os.path.basename(rel)} {pct}%")
                    last = pct
    if os.path.getsize(part) != size or sha256(part) != digest:
        os.remove(part)
        sys.exit(f"{rel} doesn't match its pinned hash; not installing it")
    os.replace(part, dest)


def build(cache):
    """mrt_render against magentart::core, MLX from the wheel. Returns the bin dir."""
    uv = find_tool("uv")
    if not uv:
        sys.exit("The MRT2 pack needs uv to fetch MLX and CMake: brew install uv")
    venv = os.path.join(cache, "mrt2-venv")
    py = os.path.join(venv, "bin", "python")
    if not os.path.exists(py):
        log(f"Making a Python {PY_VERSION} for MLX and CMake in {venv}")
        subprocess.check_call([uv, "venv", "-q", "--python", PY_VERSION, venv])
    subprocess.check_call([uv, "pip", "install", "-q", "--python", py] + MLX)
    mlx = subprocess.check_output([py, "-c", "import mlx, os; print(mlx.__path__[0])"], text=True).strip()

    src = os.path.join(cache, "mrt2-src")
    git = ["git", "-C", src]
    if not os.path.isdir(os.path.join(src, ".git")):
        subprocess.check_call(["git", "init", "-q", src])
        subprocess.check_call(git + ["remote", "add", "origin", MAGENTA_REPO])
    log(f"Fetching magenta-realtime at {MAGENTA_SHA[:7]}")
    subprocess.check_call(git + ["fetch", "-q", "--depth", "1", "origin", MAGENTA_SHA])
    subprocess.check_call(git + ["checkout", "-q", "--detach", MAGENTA_SHA])

    out = os.path.join(cache, "mrt2-build")
    cmake = os.path.join(venv, "bin", "cmake")
    log("Configuring (the first time clones TensorFlow for TFLite; a few minutes)")
    subprocess.check_call([cmake, "-S", os.path.join(HERE, "native"), "-B", out, "-DMAGENTA_SRC=" + src,
                           "-DMAGENTA_SHA=" + MAGENTA_SHA[:7], "-DMLX_DIR=" + os.path.join(mlx, "share", "cmake", "MLX")],
                          stdout=subprocess.DEVNULL)
    jobs = str(max(2, (os.cpu_count() or 4) // 2))
    log(f"Building mrt_render with {jobs} jobs (TFLite takes most of it, about 15 minutes the first time)")
    proc = subprocess.Popen([cmake, "--build", out, "--target", "mrt_render", "-j", jobs],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    last = ""
    for line in proc.stdout:
        if line.startswith("[") and "%]" in line and line[:5] != last:
            last = line[:5]
            log(f"  build {last.strip('[ ]')}")
        elif " error:" in line:
            log(line.rstrip())
    if proc.wait():
        sys.exit("mrt_render didn't build; the log above has the error")
    return os.path.join(out, "mrt_render"), os.path.join(mlx, "lib")


def install_bin(binary, mlx_lib, dest):
    """mrt_render with MLX beside it, so it runs without the build venv."""
    os.makedirs(dest, exist_ok=True)
    # libmlx.dylib loads its siblings (libjaccl.dylib) by @rpath too.
    for f in os.listdir(mlx_lib):
        if f.endswith((".dylib", ".metallib")):
            shutil.copyfile(os.path.join(mlx_lib, f), os.path.join(dest, f))
    # Linked with @executable_path as its only rpath (native/CMakeLists.txt).
    target = os.path.join(dest, "mrt_render")
    shutil.copyfile(binary, target)
    os.chmod(target, 0o755)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--from", dest="source", help="copy the weights from this Magenta RT 2 folder instead of downloading")
    args = ap.parse_args()

    lib = os.path.join(library(), "mrt2")
    cache = os.path.join(home(), "Cache")
    # Slab counts a model pack installed once models/ exists, so everything
    # lands in _staging first and models/ moves into place last.
    staging = os.path.join(lib, "_staging")
    os.makedirs(cache, exist_ok=True)

    total = sum(s for _, s, _ in FILES)
    log(f"{'Copying' if args.source else 'Downloading'} the mrt2_small weights ({total / 1e9:.1f} GB)")
    for rel, size, digest in FILES:
        fetch(rel, size, digest, os.path.join(staging, rel), args.source)

    binary, mlx_lib = build(cache)
    install_bin(binary, mlx_lib, os.path.join(staging, "bin"))

    log("Checking mrt_render renders a second of audio")
    probe = os.path.join(staging, "probe.wav")
    subprocess.check_call([os.path.join(staging, "bin", "mrt_render"), os.path.join(staging, "models/mrt2_small/mrt2_small.mlxfn"),
                           os.path.join(staging, "resources"), "--seconds", "1", "--prompt", "solo piano", "-o", probe],
                          stdout=subprocess.DEVNULL)
    os.remove(probe)

    with open(os.path.join(staging, "README.txt"), "w") as f:
        f.write(README.format(rev=HF_REVISION, sha=MAGENTA_SHA))
    for part in ("bin", "resources", "README.txt", "models"):
        target = os.path.join(lib, part)
        if os.path.isdir(target):
            shutil.rmtree(target)
        os.replace(os.path.join(staging, part), target)
    shutil.rmtree(staging, ignore_errors=True)
    log(f"Installed in {lib}")


if __name__ == "__main__":
    main()
