"""Train GATEpi (fluniml/gat.py) within ONE run on the same agent split as ml/out/within (the MLP's).

    ml/.venv/bin/python ml/scripts/train_gatepi_within.py \
        --run sim/runs/influenza_none_n7000_d14_s42_f90e5e60 \
        --split-from ml/out/within/influenza_none_n7000_d14_s42_f90e5e60/mlp_full.parquet

Agents: the split file's "train" agents are cut into fit (90%) and early-stop (10%, stratified),
the way within_run.py does for the MLP; "val" agents are only scored. The whole run stays in the
graph. Loss = survival NLL on the fit agents. The first --tf-epochs epochs are teacher-forced:
the fit agents' (and seeds') true infection hours drive their infectiousness, so the model learns
the transmission rule first; early-stop and val agents always run on the model's own estimates, so
their labels never enter as inputs. After that the model runs free.

Every epoch, a free-running forward pass scores early-stop and val agents: hourly survival NLL,
skill vs an "epidemic curve only" baseline (same hourly hazard for everyone, fitted on the fit
agents), per-day AUC, whole-run AUC/AP (the MLP's metric). The checkpoint with the best
early-stop NLL is kept; val is reported for it.
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
from fluniml import data, gat  # noqa: E402
from fluniml.data import ML  # noqa: E402
from fluniml.meanfield import infectiousness_kernel  # noqa: E402

OUT = ML / "out" / "gat"


def survival_np(H, t_inf, mask):
    """Hourly discrete-time survival NLL over agents in mask (H [T, N] numpy)."""
    cum = np.cumsum(H, 0)
    T = H.shape[0]
    k = np.clip(t_inf, 0, T - 1)
    cols = np.arange(H.shape[1])
    Hk = H[k, cols]
    ll_inf = cum[k, cols] - Hk - np.log(-np.expm1(-np.maximum(Hk, 1e-10)))
    loss = np.where(t_inf >= 0, ll_inf, cum[-1])
    return float(loss[mask].mean())


def per_day_auc(H, t_inf, mask):
    Hd = H.reshape(-1, 24, H.shape[1]).sum(1)
    k = np.where(t_inf >= 0, t_inf // 24, -1)
    aucs, ws = [], []
    for d in range(Hd.shape[0]):
        risk = mask & ((k < 0) | (k >= d))
        y = (k == d)[risk]
        if 3 <= y.sum() < risk.sum():
            aucs.append(roc_auc_score(y, Hd[d, risk]))
            ws.append(y.sum())
    return float(np.average(aucs, weights=ws))


def scores(H, r, mask, nll_curve):
    p = -np.expm1(-H.sum(0))
    y = r.label[mask]
    nll = survival_np(H, r.t_inf, mask)
    return {"NLL": nll, "skill": 1 - nll / nll_curve, "day_AUC": per_day_auc(H, r.t_inf, mask),
            "AUC": roc_auc_score(y, p[mask]), "AP": average_precision_score(y, p[mask]),
            "mean_P": float(p[mask].mean()), "true_P": float(y.mean())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--split-from", required=True, help="parquet with agent_id and split (train/val/seed)")
    ap.add_argument("--name", default="gatepi_within")
    ap.add_argument("--edge-attn", default="gatv2_sigmoid", choices=["gatv2_sigmoid", "softmax", "none"])
    ap.add_argument("--epochs", type=int, default=150)
    ap.add_argument("--tf-epochs", type=int, default=40, help="teacher-forced epochs at the start")
    ap.add_argument("--patience", type=int, default=25, help="counted only after teacher forcing")
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--es-frac", type=float, default=0.1)
    ap.add_argument("--checkpoint-every", type=int, default=1)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--init", default=None, help="start from this checkpoint's weights (e.g. a teacher-forced one)")
    args = ap.parse_args()
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    OUT.mkdir(parents=True, exist_ok=True)
    root = ML.parent
    run_dir = Path(args.run) if Path(args.run).is_absolute() else root / args.run
    split_path = Path(args.split_from) if Path(args.split_from).is_absolute() else root / args.split_from

    t = time.time()
    r = data.load_run(run_dir)
    g = gat.to_graph(r)
    sp = pd.read_parquet(split_path).set_index("agent_id").split.reindex(r.agent_ids).to_numpy()
    assert not pd.isna(sp).any(), "split file doesn't cover every agent"
    val = sp == "val"
    train_all = sp == "train"
    assert not (val & r.seed).any() and not (train_all & r.seed).any()
    rng = np.random.default_rng(args.seed)
    es = np.zeros(r.N, bool)
    for lab in (0, 1):
        idx = np.flatnonzero(train_all & (r.label == lab))
        es[rng.choice(idx, int(round(args.es_frac * len(idx))), replace=False)] = True
    fit = train_all & ~es
    print(f"{r.run_id}: N={r.N}, {len(r.hour)} hourly edges, seeds {int(r.seed.sum())}; fit {fit.sum()}, "
          f"early-stop {es.sum()}, val {val.sum()} ({r.label[val].mean():.1%} infected); "
          f"loaded {time.time() - t:.0f}s", flush=True)

    # "epidemic curve only" baseline: one hourly hazard for everyone, from the fit agents
    T = r.hours
    at_risk = np.array([(fit & ((r.t_inf < 0) | (r.t_inf >= h))).sum() for h in range(T)], float)
    new = np.bincount(r.t_inf[fit & (r.t_inf >= 0)], minlength=T)[:T].astype(float)
    h_curve = -np.log1p(-np.clip(new / np.maximum(at_risk, 1), 0, 0.999))
    Hc = np.repeat(h_curve[:, None], r.N, 1)
    nll_curve = {"es": survival_np(Hc, r.t_inf, es), "val": survival_np(Hc, r.t_inf, val)}
    print(f"curve baseline NLL: early-stop {nll_curve['es']:.4f}, val {nll_curve['val']:.4f}", flush=True)

    model = gat.GATEpi(edge_attn=args.edge_attn, kernel_init=infectiousness_kernel(r.config, 240),
                       checkpoint_every=args.checkpoint_every)
    if args.init:
        init = torch.load(args.init, weights_only=False)
        model.load_state_dict(init["state"])
        print(f"initialised from {args.init} (epoch {init.get('epoch')})", flush=True)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: 0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * min(s, args.epochs) / args.epochs)))
    t_inf = torch.as_tensor(r.t_inf, dtype=torch.long)
    teach_mask = torch.as_tensor(fit | r.seed)
    excl = torch.as_tensor(~fit)
    ckpt, log_path = OUT / f"{args.name}.pt", OUT / f"{args.name}_log.json"
    log = {"args": vars(args), "curve_nll": nll_curve, "epochs": []}
    best, best_ep, bad = math.inf, -1, 0

    for ep in range(args.epochs):
        t0 = time.time()
        tf = ep < args.tf_epochs
        model.train()
        H = model(g, t_inf=t_inf, teach_mask=teach_mask) if tf else model(g)
        loss = gat.survival_nll(H, t_inf, excl)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        gn = float(torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0))
        opt.step()
        sched.step()
        t_train = time.time() - t0
        model.eval()
        with torch.no_grad():
            He = model(g).numpy()
        s_es, s_val = scores(He, r, es, nll_curve["es"]), scores(He, r, val, nll_curve["val"])
        rec = {"epoch": ep, "teacher_forced": tf, "train_loss": float(loss), "grad_norm": gn,
               "es": s_es, "val": s_val, "sec_train": t_train, "sec": time.time() - t0}
        log["epochs"].append(rec)
        print(f"epoch {ep}{' TF' if tf else ''}: train {float(loss):.4f} | early-stop NLL {s_es['NLL']:.4f} "
              f"skill {s_es['skill']:+.3f} dayAUC {s_es['day_AUC']:.3f} | val NLL {s_val['NLL']:.4f} "
              f"skill {s_val['skill']:+.3f} dayAUC {s_val['day_AUC']:.3f} AUC {s_val['AUC']:.3f} "
              f"AP {s_val['AP']:.3f} meanP {s_val['mean_P']:.3f} | {rec['sec']:.0f}s", flush=True)
        if s_es["NLL"] < best:
            best, best_ep = s_es["NLL"], ep
            bad = 0
            torch.save({"state": model.state_dict(), "epoch": ep, "es": s_es, "val": s_val,
                        "args": vars(args)}, ckpt)
        elif not tf:
            bad += 1
        log["best_epoch"] = best_ep
        json.dump(log, open(log_path, "w"), indent=1, default=float)
        if bad >= args.patience:
            print(f"early stop: no early-stop NLL gain for {bad} free-running epochs", flush=True)
            break

    ck = torch.load(ckpt, weights_only=False)
    model.load_state_dict(ck["state"])
    model.eval()
    with torch.no_grad():
        He = model(g).numpy()
    p = -np.expm1(-He.sum(0))
    p[r.seed] = 1.0
    pd.DataFrame({"agent_id": r.agent_ids, "p": p, "split": np.where(es, "early_stop", sp)}).to_parquet(
        OUT / f"{args.name}_preds.parquet", index=False)
    v = ck["val"]
    print(f"best epoch {best_ep} (by early-stop NLL): val NLL {v['NLL']:.4f} skill {v['skill']:+.3f} "
          f"dayAUC {v['day_AUC']:.3f} AUC {v['AUC']:.3f} AP {v['AP']:.3f}", flush=True)
    mlp = pd.read_parquet(split_path).set_index("agent_id")
    vid = r.agent_ids[val]
    print(f"same val agents, mlp_full: AUC {roc_auc_score(r.label[val], mlp.p.loc[vid]):.3f} "
          f"AP {average_precision_score(r.label[val], mlp.p.loc[vid]):.3f}", flush=True)
    print("wrote", OUT / f"{args.name}_preds.parquet", flush=True)


if __name__ == "__main__":
    main()
