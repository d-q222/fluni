"""KL divergence on a 10% agent holdout of one run ("fixed" run) for ML models, P(flu) algorithms, baselines.

    ml/.venv/bin/python ml/scripts/kl_fixed.py split      # val/stop/fit ids -> ml/out/kl/fixed/val_ids.json
    ml/.venv/bin/python ml/scripts/kl_fixed.py mlp
    ml/.venv/bin/python ml/scripts/kl_fixed.py gat [--epochs 40 --patience 15]
    ml/.venv/bin/python ml/scripts/kl_fixed.py meanfield  # python mean-field + oracle, fitted on train agents
    node --max-old-space-size=8000 ml/scripts/kl_fixed.mjs <run> ml/out/kl/fixed/contacts_bin {infer,meanfield} ...
    ml/.venv/bin/python ml/scripts/kl_fixed.py score      # -> ml/out/kl/fixed/results.json

Split (as ml/scripts/within_run.py): non-seeds permuted with default_rng(0); first 10% = val, the next 10% of
the rest = stop (early stopping / model selection), the remaining = fit. train = fit + stop.
Every prediction file is ml/out/kl/fixed/<model>_fixed_preds.csv with agent_id,p (all agents).
"""
import argparse
import dataclasses
import json
import math
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "4")
import numpy as np
import pandas as pd
import torch
from sklearn.metrics import average_precision_score, roc_auc_score

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml.data import ML, REPO, load_run, meta  # noqa: E402

torch.set_num_threads(4)
RUN = REPO / "sim/runs/influenza_none_n7500_d14_s42_9776284a"
OUT = ML / "out/kl/fixed"
EPS = 1e-6


def split(run):
    rng = np.random.default_rng(0)
    cand = rng.permutation(np.flatnonzero(~run.seed))
    n_val = int(round(0.1 * len(cand)))
    n_stop = int(round(0.1 * (len(cand) - n_val)))
    m = {k: np.zeros(run.N, bool) for k in ("val", "stop", "fit")}
    m["val"][cand[:n_val]] = True
    m["stop"][cand[n_val:n_val + n_stop]] = True
    m["fit"][cand[n_val + n_stop:]] = True
    m["train"] = m["fit"] | m["stop"]
    return m


def save_preds(name, run, p):
    pd.DataFrame({"agent_id": run.agent_ids, "p": p}).to_csv(OUT / f"{name}_fixed_preds.csv", index=False)


def bce(y, p):
    p = np.clip(p, EPS, 1 - EPS)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def kl_bern(a, b):
    b = min(max(b, EPS), 1 - EPS)
    out = 0.0
    if a > 0:
        out += a * math.log(a / b)
    if a < 1:
        out += (1 - a) * math.log((1 - a) / (1 - b))
    return max(0.0, out)


def kl_metrics(y, p):
    p = np.clip(np.asarray(p, float), EPS, 1 - EPS)
    y = np.asarray(y, float)
    # 10 (roughly) equal-count bins: edges at deciles of p, tied p values always share a bin (as metrics.ece),
    # so a constant predictor has one bin and calib_kl == aggregate_kl
    edges = np.quantile(p, np.linspace(0, 1, 11))
    b = np.clip(np.searchsorted(edges, p, side="right") - 1, 0, 9)
    calib = 0.0
    for k in range(10):
        idx = b == k
        if idx.any():
            calib += idx.mean() * kl_bern(y[idx].mean(), p[idx].mean())
    const = np.ptp(p) == 0
    return {"per_agent_kl": bce(y, p), "aggregate_kl": max(0.0, kl_bern(y.mean(), p.mean())), "calib_kl": calib,
            "auc": None if const else float(roc_auc_score(y, p)),
            "ap": None if const else float(average_precision_score(y, p)),
            "mean_p": float(p.mean())}


def cmd_split(run, m):
    json.dump({"run": run.run_id, "rule": "non-seeds permuted by numpy default_rng(0); val = first 10%, "
               "stop = next 10% of the rest, fit = remainder; train = fit + stop",
               "val_ids": run.agent_ids[m["val"]].tolist(), "stop_ids": run.agent_ids[m["stop"]].tolist(),
               "n": {k: int(v.sum()) for k, v in m.items()},
               "attack_rate": {k: float(run.label[v].mean()) for k, v in m.items()}},
              open(OUT / "val_ids.json", "w"), indent=1)
    print({k: (int(v.sum()), round(float(run.label[v].mean()), 4)) for k, v in m.items()})


def cmd_mlp(run, m):
    from fluniml.mlp import MLPModel, run_features
    run_features(run)
    light = meta(run)
    t = time.time()
    ms = [MLPModel("full", seed=s).fit([dataclasses.replace(light, mask=m["fit"])],
                                       [dataclasses.replace(light, mask=m["stop"])], verbose=False)
          for s in range(3)]
    p = np.mean([x.predict(light) for x in ms], 0)
    save_preds("mlp_full", run, p)
    info = {"features": len(ms[0].names), "params": ms[0].n_params(), "epochs": [x.epochs for x in ms],
            "stop_logloss": [x.val_loss for x in ms], "sec": time.time() - t}
    json.dump(info, open(OUT / "mlp_full_fixed_info.json", "w"), indent=1, default=float)
    print(info)


def cmd_gat(run, m, a):
    from fluniml import gat_daily
    torch.manual_seed(0)
    g = gat_daily.to_graph(run, step_h=24)
    y, t_inf_np = run.label.copy(), run.t_inf.copy()
    run.ch = run.a = run.b = run.hour = None   # keep only the daily graph
    print(f"graph: {g.steps} steps, {len(g.a)} edges", flush=True)
    model = gat_daily.GATDaily(d=32, heads=4, edge_attn="gatv2_sigmoid", step_h=24)
    opt = torch.optim.Adam(model.parameters(), lr=5e-3)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: 0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * min(s, a.epochs) / a.epochs)))
    t_inf = torch.as_tensor(t_inf_np, dtype=torch.long)
    excl_fit = torch.as_tensor(~m["fit"])
    best, best_ep, bad, best_p, log = np.inf, -1, 0, None, []
    t_all = time.time()
    for ep in range(a.epochs):
        t0 = time.time()
        model.train()
        H = model(g)
        loss = gat_daily.survival_nll(H, t_inf, excl_fit, step_h=24)
        with torch.no_grad():
            p = (-torch.expm1(-H.sum(0))).numpy()
        st = m["stop"]
        sl = bce(y[st], p[st])
        rec = {"epoch": ep, "fit_loss": float(loss.detach()), "stop_logloss": sl,
               "stop_auc": float(roc_auc_score(y[st], p[st])), "stop_ap": float(average_precision_score(y[st], p[st])),
               "mean_p_stop": float(p[st].mean())}
        if sl < best:      # selection on the stop agents' logloss (= per-agent KL), weights before this update
            best, best_ep, bad, best_p = sl, ep, 0, p.copy()
            torch.save({"state": model.state_dict(), "epoch": ep}, OUT / "gat_daily_fixed.pt")
        else:
            bad += 1
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        sched.step()
        rec["sec"] = time.time() - t0
        log.append(rec)
        print(rec, flush=True)
        json.dump({"best_epoch": best_ep, "epochs": log, "sec": time.time() - t_all},
                  open(OUT / "gat_daily_fixed_log.json", "w"), indent=1)
        if bad >= a.patience:
            print("early stop", flush=True)
            break
    p = np.where(run.seed, 1.0, best_p)
    save_preds("gat_daily", run, p)
    print(f"best epoch {best_ep}, stop logloss {best:.4f}, {time.time() - t_all:.0f}s", flush=True)


def cmd_meanfield(run, m):
    from fluniml.meanfield import MeanField
    info = {}
    for name, oracle in (("meanfield_py", False), ("oracle_true_states", True)):
        t = time.time()
        mf = MeanField(run.config, run.hours, oracle=oracle)
        mf.fit([dataclasses.replace(run, mask=m["train"])], verbose=False)
        save_preds(name, run, mf.predict(run))
        th = np.exp(mf.log_theta)
        info[name] = {"theta_close": th[0], "theta_room": th[1], "theta_imp": th[2], "sec": time.time() - t}
        print(name, info[name], flush=True)
    json.dump(info, open(OUT / "meanfield_fixed_info.json", "w"), indent=1, default=float)


def cmd_score(run, m):
    val = m["val"]
    ids = run.agent_ids[val]
    y = run.label[val].astype(float)
    ybar, ytr = float(y.mean()), float(run.label[m["train"]].mean())
    models = {}

    def add(name, p, notes, baseline=False):
        r = kl_metrics(y, p)
        r["notes"] = notes
        if baseline:
            r["baseline"] = True
        models[name] = r

    notes = {
        "mlp_full": "MLP+ReLU, 'full' features, mean of 3 seeds; fit on fit agents, early-stopped on stop agents",
        "gat_daily": "GATDaily (gatv2_sigmoid, d=32, 4 heads, daily steps); whole run in graph, survival loss on fit "
                     "agents; checkpoint chosen by stop-agent logloss (not val)",
        "meanfield_py": "ml/fluniml/meanfield.py, 3 thetas fitted by ML on train agents (fit+stop) via Run.mask",
        "meanfield_js": "model/meanfield.js (Baker MF), default params (lambdaScale 0.901), phone inputs incl. reports; "
                        "p = 1 - P_S at end of run (includes the 2% prior infected mass at t=0). Uncalibrated for this run: "
                        "expected infections 2959/7500 (39%) vs ~5% observed",
        "infer_js": "model/infer.js (Rio update), default params; no P_S exposed, p = max over time of P(infected now) "
                    "(change points + prior 0.02)",
    }
    for name, f in [("mlp_full", "mlp_full_fixed_preds.csv"), ("gat_daily", "gat_daily_fixed_preds.csv"),
                    ("meanfield_js", "meanfield_js_fixed_preds.csv")]:   # infer.js / meanfield.py dropped by request
        path = OUT / f
        if not path.exists():
            print("missing", path)
            continue
        d = pd.read_csv(path).set_index("agent_id")
        col = "p_ever" if "p_ever" in d else "p"
        add(name, d.loc[ids, col].to_numpy(float), notes[name])
        if name == "meanfield_js":   # alternatives, for reference
            for alt in ("p_final", "p_max"):
                add(f"{name}[{alt}]", d.loc[ids, alt].to_numpy(float),
                    f"{name} scored with {alt} instead (reference only)")
    path = OUT / "meanfield_js_fixed_preds.csv"
    if path.exists():   # reference: raw meanfield.js p_ever, isotonic-recalibrated on train agents (non-val, non-seed)
        from sklearn.isotonic import IsotonicRegression
        d = pd.read_csv(path).set_index("agent_id")
        tr = run.agent_ids[m["train"]]
        iso = IsotonicRegression(y_min=0, y_max=1, out_of_bounds="clip").fit(
            d.loc[tr, "p_ever"].to_numpy(float), run.label[m["train"]].astype(float))
        add("meanfield_js_raw+isotonic", iso.predict(d.loc[ids, "p_ever"].to_numpy(float)),
            "reference: raw meanfield_js p_ever mapped by isotonic regression fitted on train agents (fit+stop)")
    path = OUT / "meanfield_js_calibrated_fixed_preds.csv"
    if path.exists():
        d = pd.read_csv(path).set_index("agent_id")
        cal = open(OUT / "mf_calib_fixed.log").read().strip().splitlines()
        add("meanfield_js_calibrated", d.loc[ids, "p_ever"].to_numpy(float),
            "model/meanfield.js with prior = n_seeds/N = 5/7500 and lambdaScale refitted as meanfield-cli --calibrate "
            "(true seeds, no reports, prior 0, no imports) to train-agent non-import infections scaled to all "
            "non-seeds (no val leakage); final pass with reports; p = 1 - P_S at end. " + "; ".join(
                l for l in cal if l.startswith(("fitted", "final", "no-report"))))
    path = OUT / "meanfield_js_fit_fixed_preds.csv"
    if path.exists():
        d = pd.read_csv(path).set_index("agent_id")
        fit_log = open(OUT / "mf_fit_fixed.log").read().strip().splitlines()
        add("meanfield_js_fit_reports", d.loc[ids, "p_ever"].to_numpy(float),
            "model/meanfield.js with prior = 5/7500 and lambdaScale fitted on the full scored model (reports included) "
            "so mean P(ever infected) over train agents = their attack rate (ml/scripts/kl_mf_fit.mjs); p = 1 - P_S at end. "
            + "; ".join(l for l in fit_log if l.startswith("fitted")))
    path = OUT / "oracle_true_states_fixed_preds.csv"
    if path.exists():
        d = pd.read_csv(path).set_index("agent_id")
        add("oracle_true_states", d.loc[ids, "p"].to_numpy(float),
            "meanfield.py oracle=True: uses others' TRUE infection times; reference, not a competitor", True)
    n = len(y)
    add("const_train_rate", np.full(n, ytr), f"constant p = train-agent attack rate {ytr:.4f}", True)
    add("const_val_rate", np.full(n, ybar), "constant p = val attack rate; cheats on prevalence "
        "(per-agent KL = entropy H(ybar), aggregate KL = 0)", True)
    add("uniform_0.5", np.full(n, 0.5), "constant p = 0.5 (per-agent KL = ln 2)", True)
    models["perfect"] = {"per_agent_kl": 0.0, "aggregate_kl": 0.0, "calib_kl": 0.0, "auc": 1.0, "ap": 1.0,
                         "mean_p": ybar, "notes": "p = y: the floor (not computed)", "baseline": True}
    res = {"run": run.run_id, "n_val": n, "n_val_pos": int(y.sum()), "val_attack_rate": ybar,
           "train_attack_rate": ytr, "eps_clip": EPS, "units": "nats", "models": models}
    json.dump(res, open(OUT / "results.json", "w"), indent=1)
    tab = pd.DataFrame(models).T[["per_agent_kl", "aggregate_kl", "calib_kl", "auc", "ap", "mean_p"]]
    print(f"n_val {n}, positives {int(y.sum())}, ybar {ybar:.4f}")
    print(tab.to_markdown(floatfmt=".4f"))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["split", "mlp", "gat", "meanfield", "score"])
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--patience", type=int, default=15)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    run = load_run(RUN)
    m = split(run)
    if a.cmd == "split":
        cmd_split(run, m)
    elif a.cmd == "mlp":
        cmd_mlp(run, m)
    elif a.cmd == "gat":
        cmd_gat(run, m, a)
    elif a.cmd == "meanfield":
        cmd_meanfield(run, m)
    else:
        cmd_score(run, m)
