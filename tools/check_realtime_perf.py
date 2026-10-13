#!/usr/bin/env python3
"""Compare identical realtime render fixtures in two checkouts.

Requires macOS/ARM64, Zig 0.16 and Slab's native dependencies. Both checkouts
must contain the same 'realtime benchmark' tests. Preparation/JIT time is
excluded; each fixture measures nine warmed renders and hashes output.
This checks throughput, not a hard realtime deadline guarantee.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess


def measure(root):
    env = dict(os.environ, SLAB_REALTIME_BENCH="1")
    proc = subprocess.Popen(
        ["zig", "build", "test", "-Doptimize=ReleaseFast", "-Dtest-filter=realtime benchmark"],
        cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=300)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        stdout, stderr = proc.communicate()
        raise RuntimeError(f"Benchmark exceeded 300 s in {root}\n{stdout}{stderr}")
    if proc.returncode:
        raise RuntimeError(stdout + stderr)
    records = [json.loads(m) for m in re.findall(r"SLAB_PERF (\{[^\n]+\})", stdout + stderr)]
    if not records:
        raise RuntimeError("No benchmark records; install the identical benchmark tests in both checkouts")
    return {(v.get("fixture", "routing"), v["workers"]): v for v in records}


def compare(baseline, candidate, limit):
    if baseline.keys() != candidate.keys():
        raise ValueError("Benchmark fixture sets differ")
    rows = []
    for key in sorted(baseline):
        before, after = baseline[key], candidate[key]
        if before["hash"] != after["hash"]:
            raise ValueError(f"Output changed for {key}")
        delta = 100 * (after["median_ns"] / before["median_ns"] - 1)
        rows.append({"fixture": key[0], "workers": key[1], "baseline_ns": before["median_ns"],
                     "candidate_ns": after["median_ns"], "change_percent": round(delta, 2), "hash": after["hash"]})
        if delta > limit:
            raise ValueError(f"Performance regression for {key}: {delta:.2f}% exceeds {limit}%")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, default=Path.cwd())
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--max-regression-percent", type=float, default=5)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--install-fixtures", action="store_true", help="Copy only the benchmark tests into the baseline checkout")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.install_fixtures:
        pattern = r'^test "realtime benchmark: [^"]+" \{.*?(?=^test |\Z)'
        source = (args.candidate / "src/engine.zig").read_text()
        fixtures = re.findall(pattern, source, re.MULTILINE | re.DOTALL)
        if not fixtures:
            parser.error("Candidate contains no benchmark fixtures")
        target = args.baseline / "src/engine.zig"
        original = target.read_text()
        original = re.sub(pattern, "", original, flags=re.MULTILINE | re.DOTALL)
        target.write_text(original.rstrip() + "\n\n" + "\n".join(fixtures))
    baseline, candidate = [], []
    for i in range(args.runs):
        # Alternate order to reduce temperature/order bias; avoid concurrent
        # benchmarks or compilations competing for the measured cores.
        if i % 2:
            candidate.append(measure(args.candidate))
            baseline.append(measure(args.baseline))
        else:
            baseline.append(measure(args.baseline))
            candidate.append(measure(args.candidate))
        print(f"Completed comparison {i + 1}/{args.runs}", flush=True)
    def aggregate(runs):
        out = {}
        for key in runs[0]:
            values = [r[key] for r in runs]
            if len({v["hash"] for v in values}) != 1:
                raise ValueError(f"Nondeterministic output for {key}")
            out[key] = {**values[0], "median_ns": statistics.median(v["median_ns"] for v in values)}
        return out
    report = {"runs": args.runs, "max_regression_percent": args.max_regression_percent,
              "results": compare(aggregate(baseline), aggregate(candidate), args.max_regression_percent)}
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered)
    print(rendered, end="")


if __name__ == "__main__":
    main()
