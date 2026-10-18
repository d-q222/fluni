"""Score every model in ml/out/preds/ on the same agents (non-seeds of the val runs in ml/runs.json).

    ml/.venv/bin/python ml/scripts/compare.py [--split val]
"""
import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import preds  # noqa: E402
from fluniml.data import load_run, run_dirs  # noqa: E402
from fluniml.metrics import recall_by_route, score  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--split", default="val", choices=["val", "stop", "train"])
args = ap.parse_args()

truth = []
for d in run_dirs(args.split):
    r = load_run(d)
    truth.append(pd.DataFrame({"run_id": r.run_id, "agent_id": r.agent_ids, "label": r.label,
                               "route": r.route, "seed": r.seed}))
truth = pd.concat(truth)
truth = truth[~truth.seed]
print(f"{args.split}: {truth.run_id.nunique()} runs, {len(truth)} scored agents, "
      f"{int(truth.label.sum())} infected ({truth.label.mean():.1%})\n")

rows, routes = {}, {}
if not len(truth):
    sys.exit("no runs in that split; check ml/runs.json")
for name, p in preds.read_all().items():
    df = truth.merge(p, on=["run_id", "agent_id"], how="left")
    if df.p.isna().any():
        print(f"skipping {name}: no predictions for {df.p.isna().sum()} agents")
        continue
    rows[name] = score(df)
    routes[name] = recall_by_route(df)

if not rows:
    sys.exit("no model has predictions for every agent in this split; run the models first")
cols = ["run_AUC", "run_AP", "run_P@k", "AUC", "AP", "logloss", "Brier", "ECE"]
tab = pd.DataFrame(rows).T[cols].sort_values("run_AUC", ascending=False)
print(tab.to_markdown(floatfmt=".3f"))
print("\nRecall of each infection route among each run's top-k (k = true number infected):\n")
print(pd.DataFrame(routes).T.loc[tab.index].to_markdown(floatfmt=".3f"))
