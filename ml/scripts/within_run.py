"""Train and score on one run by splitting its agents: fit on 90%, score the other 10%.

    ml/.venv/bin/python ml/scripts/within_run.py sim/runs/influenza_none_n7000_d14_s42_f90e5e60

Every model still sees the whole run's contacts and seeds (those are inputs); the split only
decides whose labels are used for fitting and whose are scored. Val agents share the outbreak
with the training agents, so scores are more optimistic than on a held-out run.
Among the training agents, --stop-frac are kept aside for the MLP's early stopping.
Predictions go to ml/out/within/<run_id>/<model>.parquet; the score table is printed and saved.
"""
import argparse
import dataclasses
import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml.data import ML, REPO, load_run, meta  # noqa: E402
from fluniml.meanfield import MeanField  # noqa: E402
from fluniml.metrics import recall_by_route, score  # noqa: E402
from fluniml.mlp import MLPModel, run_features  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("run")
ap.add_argument("--val-frac", type=float, default=0.1)
ap.add_argument("--stop-frac", type=float, default=0.1, help="share of training agents for early stopping")
ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--ensemble", type=int, default=3)
ap.add_argument("--models", default="meanfield,oracle,mlp_full,mlp_seed,mlp_activity")
args = ap.parse_args()
models = args.models.split(",")
torch.set_num_threads(4)

path = Path(args.run)
path = path if path.is_absolute() else REPO / path
t0 = time.time()
run = load_run(path)
print(f"{run.run_id}: {run.N} agents, {int(run.seed.sum())} seeds, {len(run.hour):,} hourly pair "
      f"edges, {int(run.label[~run.seed].sum())} non-seed infections; loaded in {time.time() - t0:.0f}s",
      flush=True)

# agent split (seeds are never scored, so only non-seeds are assigned)
rng = np.random.default_rng(args.seed)
cand = rng.permutation(np.flatnonzero(~run.seed))
n_val = int(round(args.val_frac * len(cand)))
n_stop = int(round(args.stop_frac * (len(cand) - n_val)))
val_m, stop_m, fit_m = (np.zeros(run.N, bool) for _ in range(3))
val_m[cand[:n_val]] = True
stop_m[cand[n_val:n_val + n_stop]] = True
fit_m[cand[n_val + n_stop:]] = True
train_m = fit_m | stop_m
print(f"split: train {train_m.sum()} (fit {fit_m.sum()} + early-stop {stop_m.sum()}), val {val_m.sum()}; "
      f"val infected {run.label[val_m].mean():.1%}", flush=True)

out = ML / "out" / "within" / run.run_id
out.mkdir(parents=True, exist_ok=True)
preds, info = {}, {}

for name in [m for m in models if m in ("meanfield", "oracle")]:
    t = time.time()
    mf = MeanField(run.config, run.hours, oracle=(name == "oracle"))
    mf.fit([dataclasses.replace(run, mask=train_m)], verbose=False)
    preds[name] = mf.predict(run)
    th = np.exp(mf.log_theta)
    info[name] = {"theta_close": th[0], "theta_room": th[1], "theta_imp": th[2]}
    print(f"{name}: fitted in {time.time() - t:.0f}s, theta_close {th[0]:.3g}, theta_room {th[1]:.3g}, "
          f"theta_imp {th[2]:.3g}", flush=True)

mlps = [m for m in models if m.startswith("mlp_")]
if mlps:
    t = time.time()
    run_features(run)
    print(f"features in {time.time() - t:.0f}s", flush=True)
    light = meta(run)
    for name in mlps:
        fs = name[len("mlp_"):]
        ms = []
        for s in range(args.ensemble):
            m = MLPModel(fs, seed=s).fit([dataclasses.replace(light, mask=fit_m)],
                                         [dataclasses.replace(light, mask=stop_m)], verbose=False)
            ms.append(m)
        preds[name] = np.mean([m.predict(light) for m in ms], 0)
        info[name] = {"features": len(ms[0].names), "params": ms[0].n_params(),
                      "epochs": [m.epochs for m in ms], "stop_logloss": [m.val_loss for m in ms]}
        print(f"{name}: {len(ms[0].names)} features, {ms[0].n_params()} params, epochs "
              f"{[m.epochs for m in ms]}, {time.time() - t:.0f}s", flush=True)

rows, routes = {}, {}
for name, p in preds.items():
    pd.DataFrame({"agent_id": run.agent_ids, "p": p, "split": np.where(val_m, "val", np.where(
        train_m, "train", "seed"))}).to_parquet(out / f"{name}.parquet", index=False)
    df = pd.DataFrame({"run_id": run.run_id, "p": p[val_m], "label": run.label[val_m],
                       "route": run.route[val_m]})
    rows[name] = score(df)
    routes[name] = recall_by_route(df)

cols = ["AUC", "AP", "run_P@k", "logloss", "Brier", "ECE"]
tab = pd.DataFrame(rows).T[cols].rename(columns={"run_P@k": "P@k"}).sort_values("AUC", ascending=False)
rt = pd.DataFrame(routes).T.loc[tab.index]
txt = (f"{run.run_id}, val = {val_m.sum()} agents ({args.val_frac:.0%} of non-seeds, seed {args.seed}), "
       f"{int(run.label[val_m].sum())} infected\n\n{tab.to_markdown(floatfmt='.3f')}\n\n"
       f"Recall by infection route among the top-k (k = true number infected in val):\n\n"
       f"{rt.to_markdown(floatfmt='.3f')}\n")
print("\n" + txt)
(out / "scores.md").write_text(txt)
json.dump(info, open(out / "models.json", "w"), indent=1, default=float)
