"""Train the MLP on the train runs, early-stopped on the stop runs; write predictions for val runs.
Splits come from ml/runs.json.

    ml/.venv/bin/python ml/scripts/train_mlp.py --features full      # or: seed, activity
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import preds  # noqa: E402
from fluniml.data import ML, load_run, meta, run_dirs  # noqa: E402
from fluniml.mlp import MLPModel, run_features  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--features", default="full", choices=["full", "seed", "activity"])
ap.add_argument("--ensemble", type=int, default=3, help="average this many seeds")
ap.add_argument("--hidden", default="128,64")
args = ap.parse_args()
torch.set_num_threads(4)

t = time.time()
runs = {}
for split in ("train", "stop", "val"):
    runs[split] = []
    for d in run_dirs(split):
        r = load_run(d)
        run_features(r)  # computes and caches features while the edges are in memory
        runs[split].append(meta(r))
print(f"features for {sum(map(len, runs.values()))} runs in {time.time() - t:.0f}s "
      f"(train {len(runs['train'])}, stop {len(runs['stop'])}, val {len(runs['val'])})", flush=True)

hidden = tuple(int(h) for h in args.hidden.split(","))
models = []
for s in range(args.ensemble):
    m = MLPModel(args.features, hidden=hidden, seed=s).fit(runs["train"], runs["stop"], verbose=False)
    print(f"seed {s}: {len(m.names)} features, {m.n_params()} params, {m.epochs} epochs, "
          f"stop-set logloss {m.val_loss:.4f}", flush=True)
    models.append(m)

name = f"mlp_{args.features}"
rows = [(r, np.mean([m.predict(r) for m in models], 0)) for r in runs["val"]]
path = preds.write(name, rows)
torch.save({"models": [{"state": m.net.state_dict(), "mu": m.mu, "sd": m.sd, "cols": m.cols,
                        "names": m.names} for m in models], "hidden": hidden},
           ML / "out" / f"{name}.pt")
json.dump({"features": args.features, "n_features": len(models[0].names),
           "params": models[0].n_params(), "ensemble": args.ensemble,
           "stop_logloss": [m.val_loss for m in models]},
          open(ML / "out" / f"{name}.json", "w"), indent=1)
print("wrote", path)
