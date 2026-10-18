"""Scores for P(sick) predictions. Seeds are never scored.

Pooled metrics mix runs with very different attack rates, so a model can look good just by
guessing which runs are big. The per-run means (AUC, AP, precision@k with k = true number of
infections in that run) only reward ranking people within a run.
"""
import numpy as np
import pandas as pd
from sklearn.metrics import average_precision_score, roc_auc_score


def ece(y, p, bins=10):
    edges = np.quantile(p, np.linspace(0, 1, bins + 1))
    idx = np.clip(np.searchsorted(edges, p, side="right") - 1, 0, bins - 1)
    err = 0.0
    for k in range(bins):
        m = idx == k
        if m.any():
            err += m.mean() * abs(y[m].mean() - p[m].mean())
    return err


def score(df: pd.DataFrame) -> dict:
    """df columns: run_id, p, label (scored agents only)."""
    y, p = df.label.to_numpy(float), np.clip(df.p.to_numpy(float), 1e-6, 1 - 1e-6)
    out = {
        "AUC": roc_auc_score(y, p),
        "AP": average_precision_score(y, p),
        "logloss": float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p))),
        "Brier": float(np.mean((p - y) ** 2)),
        "ECE": ece(y, p),
    }
    auc, ap, pk = [], [], []
    for _, g in df.groupby("run_id"):
        yy, pp = g.label.to_numpy(float), g.p.to_numpy(float)
        if 0 < yy.sum() < len(yy):
            auc.append(roc_auc_score(yy, pp))
            ap.append(average_precision_score(yy, pp))
            k = int(yy.sum())
            pk.append(yy[np.argsort(-pp)[:k]].mean())
    out["run_AUC"] = float(np.mean(auc))
    out["run_AP"] = float(np.mean(ap))
    out["run_P@k"] = float(np.mean(pk))
    return out


def recall_by_route(df: pd.DataFrame) -> dict:
    """Within each run, flag the top-k agents (k = true infections); recall per infection route."""
    hits = []
    for _, g in df.groupby("run_id"):
        k = int(g.label.sum())
        top = np.zeros(len(g), bool)
        top[np.argsort(-g.p.to_numpy())[:k]] = True
        hits.append(pd.DataFrame({"route": g.route.to_numpy(), "hit": top})[g.label.to_numpy() == 1])
    h = pd.concat(hits)
    return h.groupby("route").hit.mean().to_dict()
