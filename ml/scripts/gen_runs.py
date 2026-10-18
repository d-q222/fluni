"""Generate many sim runs for training, keeping only the files the models read.

Run with the sim's venv:
    sim/.venv/bin/python ml/scripts/gen_runs.py --n 80 --start-seed 1000 --jobs 4

Each run varies the RNG seed (population, schedules, who the seeds are), the transmission scale and
the number of initial seeds, so attack rates span roughly 5-80%. Output: ml/data/runs/<run_id>/ with
contacts.parquet, infections.csv, agents_static.csv, config.json, summary.json.
"""
import argparse
import json
import random
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIM = ROOT / "sim"
KEEP = {"contacts.parquet", "infections.csv", "agents_static.csv", "config.json", "summary.json"}


def one(seed, args, out_root):
    r = random.Random(seed)
    scale = round(r.uniform(args.scale_min, args.scale_max), 2)
    seeds = r.choice([10, 20, 30, 40])
    tmp = out_root.parent / f"tmp_{seed}"
    shutil.rmtree(tmp, ignore_errors=True)
    cmd = [sys.executable, str(SIM / "simulate.py"), "--agents", str(args.agents), "--days",
           str(args.days), "--seed", str(seed), "--initial-seeds", str(seeds), "--out", str(tmp),
           "--quiet", "--set", f"disease.transmission_scale={scale}",
           "--set", "output.by_agent=false", "--set", "output.trips=false"]
    p = subprocess.run(cmd, cwd=SIM, capture_output=True, text=True)
    if p.returncode != 0:
        return f"seed {seed}: FAILED\n{p.stderr[-2000:]}"
    run = next(d for d in tmp.iterdir() if d.is_dir())
    dest = out_root / run.name
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    for f in KEEP:
        shutil.move(str(run / f), dest / f)
    shutil.rmtree(tmp)
    ar = json.load(open(dest / "summary.json"))["attack_rate"]
    return f"seed {seed}: scale {scale}, {seeds} seeds, attack rate {ar:.3f} -> {dest.name}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=80)
    ap.add_argument("--start-seed", type=int, default=1000)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--agents", type=int, default=1000)
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--scale-min", type=float, default=1.5)
    ap.add_argument("--scale-max", type=float, default=3.0)
    ap.add_argument("--out", default=str(ROOT / "ml" / "data" / "runs"))
    args = ap.parse_args()
    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)
    seeds = range(args.start_seed, args.start_seed + args.n)
    with ThreadPoolExecutor(args.jobs) as ex:
        for msg in ex.map(lambda s: one(s, args, out_root), seeds):
            print(msg, flush=True)


if __name__ == "__main__":
    main()
