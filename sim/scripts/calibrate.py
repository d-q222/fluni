"""Sweep disease.transmission_scale and report measured campus R per run.

    .venv/bin/python scripts/calibrate.py --agents 7000 --days 14 --scales 0.5 1 2 --seeds 1 2 --jobs 2

Each run goes to a temp dir with the heavy outputs off (per-agent files, parquet, trips) and is
deleted after its summary.json is read (--keep to keep them). Prints one row per run, the mean R per
scale, and the scale that linearly interpolates to --target (default 1.65, middle of 1.3-2.0).
Extra --set overrides are passed through to every run.
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

SIM = Path(__file__).resolve().parents[1]
LIGHT = ["output.by_agent=false", "output.parquet=false", "output.trips=false", "output.gzip_level=1"]


def one(args, scale, seed, out):
    cmd = [sys.executable, str(SIM / "simulate.py"), "--agents", str(args.agents), "--days", str(args.days),
           "--seed", str(seed), "--initial-seeds", str(args.initial_seeds), "--disease", args.disease,
           "--out", str(out), "--quiet"]
    for s in LIGHT + [f"disease.transmission_scale={scale}"] + args.set:
        cmd += ["--set", s]
    subprocess.run(cmd, check=True, cwd=SIM, stdout=subprocess.DEVNULL)
    run_dir = next(p for p in out.iterdir() if p.is_dir() and f"_s{seed}_" in p.name)
    s = json.loads((run_dir / "summary.json").read_text())
    if not args.keep:
        shutil.rmtree(run_dir)
    routes = s.get("infections_by_route", {})
    return dict(scale=scale, seed=seed, R=s["measured_R"], R_n=s["R_n_cases"], R_gen=s["R_generation_based"],
                attack=s["attack_rate"], close=routes.get("close", 0), aerosol=routes.get("aerosol", 0),
                imports=routes.get("import", 0), top_places=dict(sorted(s["infections_by_location_type"].items(),
                                                                        key=lambda kv: -kv[1])[:3]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agents", type=int, default=7000)
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--initial-seeds", type=int, default=40)
    ap.add_argument("--disease", default="influenza")
    ap.add_argument("--scales", type=float, nargs="+", default=[0.5, 1.0, 2.0])
    ap.add_argument("--seeds", type=int, nargs="+", default=[1, 2])
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--target", type=float, default=1.65)
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
    ap.add_argument("--keep", action="store_true", help="keep run dirs (printed path)")
    args = ap.parse_args()

    base = Path(tempfile.mkdtemp(prefix="calibrate_"))
    jobs = [(sc, sd, base / f"x{sc}_s{sd}") for sc in args.scales for sd in args.seeds]
    for *_, d in jobs:
        d.mkdir()
    with ThreadPoolExecutor(args.jobs) as ex:
        rows = list(ex.map(lambda j: one(args, *j), jobs))
    if not args.keep:
        shutil.rmtree(base)
    else:
        print("runs kept in", base)

    print(f"{'scale':>6} {'seed':>4} {'R':>6} {'R_n':>5} {'R_gen':>6} {'attack':>7} {'close':>6} {'aero':>6} {'imp':>4}  top places")
    for r in rows:
        print(f"{r['scale']:6.2f} {r['seed']:4d} {r['R']:6.2f} {r['R_n']:5d} {r['R_gen']:6.2f} {r['attack']:7.3f} "
              f"{r['close']:6d} {r['aerosol']:6d} {r['imports']:4d}  {r['top_places']}")
    sc = np.array(sorted(set(args.scales)))
    mean_R = np.array([np.mean([r["R"] for r in rows if r["scale"] == s]) for s in sc])
    print("\nmean R by scale: " + ", ".join(f"{s:g} -> {m:.2f}" for s, m in zip(sc, mean_R)))
    if len(sc) > 1 and mean_R.min() <= args.target <= mean_R.max() and np.all(np.diff(mean_R) > 0):
        print(f"scale for R={args.target}: {np.interp(args.target, mean_R, sc):.3f}")
    else:
        print(f"R={args.target} is outside the swept range (or R isn't increasing in scale); widen --scales")


if __name__ == "__main__":
    main()
