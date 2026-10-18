"""Fit the mean-field baseline's 3 parameters on the train runs; write predictions for val runs.

    ml/.venv/bin/python ml/scripts/fit_meanfield.py [--max-train 40] [--oracle]

--oracle fits the reference ceiling instead (true infection times; not a fair competitor).
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import preds  # noqa: E402
from fluniml.data import ML, load_run, run_dirs  # noqa: E402
from fluniml.meanfield import MeanField  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--max-train", type=int, default=40,
                help="fit on at most this many train runs (first ones in ml/runs.json order)")
ap.add_argument("--oracle", action="store_true")
args = ap.parse_args()
name = "oracle_true_states" if args.oracle else "meanfield"

train = run_dirs("train")[: args.max_train]
first = load_run(train[0])
mf = MeanField(first.config, first.hours, oracle=args.oracle)
compacts = []
for d in train:
    compacts.append(mf.compact(load_run(d)))
print(f"fitting on {len(compacts)} train runs", flush=True)
t = time.time()
mf.fit_compacts(compacts)
print(f"done in {time.time() - t:.0f}s: theta_close {np.exp(mf.log_theta[0]):.3g}, "
      f"theta_room {np.exp(mf.log_theta[1]):.3g}, theta_imp {np.exp(mf.log_theta[2]):.3g}")
del compacts

rows = []
for d in run_dirs("val"):
    r = load_run(d)
    rows.append((r, mf.predict(r)))
path = preds.write(name, rows)
(ML / "out").mkdir(exist_ok=True)
json.dump({"theta_close": float(np.exp(mf.log_theta[0])), "theta_room": float(np.exp(mf.log_theta[1])),
           "theta_imp": float(np.exp(mf.log_theta[2])), "n_train_runs": len(train)},
          open(ML / "out" / f"{name}.json", "w"), indent=1)
print("wrote", path)
