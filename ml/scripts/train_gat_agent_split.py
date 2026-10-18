"""Train the daily GAT on ONE run, holding out a random fraction of its agents for validation.

    ml/.venv/bin/python ml/scripts/train_gat_agent_split.py --run sim/runs/<run> [--val-frac 0.1]

The whole run stays in the graph (every agent, every contact, the seeds), so the model sees the
full epidemic; only the loss is restricted to the train agents. Val agents are scored every epoch
on the same forward pass (metrics use the parameters before that epoch's update). This measures
within-epidemic generalisation: same outbreak, same transmission rate, unseen people. It says
nothing about other runs.

Outputs: ml/out/gat/<name>.pt (best val AP), <name>_log.json, and ml/out/gat/<name>_val_preds.parquet
(val agents only; not in out/preds, since compare.py scores whole runs).
"""
import argparse
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from sklearn.metrics import average_precision_score, roc_auc_score

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import data, gat_daily  # noqa: E402
from fluniml.data import ML  # noqa: E402

OUT = ML / "out" / "gat"


def metrics(y, p):
    k = int(y.sum())
    return {"AUC": roc_auc_score(y, p), "AP": average_precision_score(y, p),
            "P@k": float(y[np.argsort(-p)[:k]].mean()) if k else float("nan")}


def seed_minutes_early(r, days=3):
    """Reference heuristic: close-contact minutes with seeds in the first `days` days."""
    close = r.ch[:, :6].sum(1) + r.ch[:, 7]
    w = close * (r.hour < 24 * days)
    f = np.zeros(r.N)
    np.add.at(f, r.a, w * r.seed[r.b])
    np.add.at(f, r.b, w * r.seed[r.a])
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--val-frac", type=float, default=0.1)
    ap.add_argument("--name", default="gat_daily_agentsplit")
    ap.add_argument("--epochs", type=int, default=150)
    ap.add_argument("--patience", type=int, default=25)
    ap.add_argument("--lr", type=float, default=5e-3)
    ap.add_argument("--step-h", type=int, default=24)
    ap.add_argument("--d", type=int, default=32)
    ap.add_argument("--heads", type=int, default=4)
    ap.add_argument("--edge-attn", default="gatv2_sigmoid", choices=["gatv2_sigmoid", "softmax", "none"])
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--threads", type=int, default=8)
    args = ap.parse_args()
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    OUT.mkdir(parents=True, exist_ok=True)

    run_dir = Path(args.run)
    run_dir = run_dir if run_dir.is_absolute() else ML.parent / run_dir
    t = time.time()
    r = data.load_run(run_dir)
    g = gat_daily.to_graph(r, step_h=args.step_h)
    print(f"{r.run_id}: N={r.N}, {g.steps} steps, {len(g.a)} edges, seeds {int(r.seed.sum())}, "
          f"loaded in {time.time() - t:.0f}s", flush=True)

    # stratified agent split over non-seeds
    rng = np.random.default_rng(args.seed)
    val = np.zeros(r.N, bool)
    for lab in (0, 1):
        idx = np.flatnonzero(~r.seed & (r.label == lab))
        val[rng.choice(idx, int(round(args.val_frac * len(idx))), replace=False)] = True
    train = ~r.seed & ~val
    y = r.label
    print(f"train agents {train.sum()} ({y[train].mean():.1%} infected), "
          f"val agents {val.sum()} ({y[val].mean():.1%} infected)", flush=True)
    ref = seed_minutes_early(r)
    ref_m = metrics(y[val], ref[val])
    print(f"reference on val agents (seed minutes, days 0-2): AUC {ref_m['AUC']:.3f} AP {ref_m['AP']:.3f} "
          f"P@k {ref_m['P@k']:.3f}", flush=True)

    model = gat_daily.GATDaily(d=args.d, heads=args.heads, edge_attn=args.edge_attn, step_h=args.step_h)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: 0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * min(s, args.epochs) / args.epochs)))
    t_inf = torch.as_tensor(r.t_inf, dtype=torch.long)
    excl_train = torch.as_tensor(~train)          # survival_nll scores everyone not excluded
    excl_val = torch.as_tensor(~val)
    log = {"args": vars(args), "reference_val": ref_m, "epochs": []}
    ckpt, log_path = OUT / f"{args.name}.pt", OUT / f"{args.name}_log.json"
    best, best_ep, bad, best_p = -1.0, -1, 0, None

    for ep in range(args.epochs):
        t0 = time.time()
        model.train()
        H = model(g)
        loss = gat_daily.survival_nll(H, t_inf, excl_train, step_h=args.step_h)
        with torch.no_grad():
            val_loss = float(gat_daily.survival_nll(H, t_inf, excl_val, step_h=args.step_h))
            p = (-torch.expm1(-H.sum(0))).numpy()
        mv, mt = metrics(y[val], p[val]), metrics(y[train], p[train])
        if mv["AP"] > best:   # these metrics come from the current weights: save them before updating
            best, best_ep, bad, best_p = mv["AP"], ep, 0, p.copy()
            log["best_epoch"] = ep
            torch.save({"state": model.state_dict(), "epoch": ep, "val": mv, "args": vars(args),
                        "val_agents": r.agent_ids[val].tolist()}, ckpt)
        else:
            bad += 1
        opt.zero_grad(set_to_none=True)
        loss.backward()
        gn = float(torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0))
        opt.step()
        sched.step()
        rec = {"epoch": ep, "train_loss": float(loss), "val_loss": val_loss, "grad_norm": gn,
               "train": mt, "val": mv, "mean_p_val": float(p[val].mean()), "sec": time.time() - t0}
        log["epochs"].append(rec)
        print(f"epoch {ep}: loss train {float(loss):.4f} val {val_loss:.4f} | train AUC {mt['AUC']:.3f} "
              f"AP {mt['AP']:.3f} | val AUC {mv['AUC']:.3f} AP {mv['AP']:.3f} P@k {mv['P@k']:.3f} "
              f"mean P {p[val].mean():.3f} | {rec['sec']:.0f}s", flush=True)
        json.dump(log, open(log_path, "w"), indent=1, default=float)
        if bad >= args.patience:
            print(f"early stop: no val AP gain for {bad} epochs", flush=True)
            break

    print(f"best epoch {best_ep}: val AP {best:.3f} (reference {ref_m['AP']:.3f})", flush=True)
    pd.DataFrame({"run_id": r.run_id, "agent_id": r.agent_ids[val], "p": best_p[val],
                  "label": y[val]}).to_parquet(OUT / f"{args.name}_val_preds.parquet", index=False)
    print("wrote", OUT / f"{args.name}_val_preds.parquet", flush=True)


if __name__ == "__main__":
    main()
