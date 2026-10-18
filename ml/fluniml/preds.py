"""The prediction file every model writes, so compare.py can score them side by side.

ml/out/preds/<model>.parquet, one row per agent per run (at least the val runs in ml/runs.json):
    run_id (str), agent_id (str), p (float, P(infected during the run))
A GNN or any other model only has to write this file to join the comparison.
"""
from pathlib import Path

import pandas as pd

from .data import ML

PREDS = ML / "out" / "preds"


def write(model_name, rows):
    """rows: iterable of (run, p) with p an (N,) array aligned to run.agent_ids."""
    PREDS.mkdir(parents=True, exist_ok=True)
    df = pd.concat(pd.DataFrame({"run_id": r.run_id, "agent_id": r.agent_ids, "p": p})
                   for r, p in rows)
    path = PREDS / f"{model_name}.parquet"
    df.to_parquet(path, index=False)
    return path


def read_all():
    return {Path(f).stem: pd.read_parquet(f) for f in sorted(PREDS.glob("*.parquet"))}
