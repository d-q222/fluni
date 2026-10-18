"""frankenstein: within-run 90/10 agent split on run 17ed9cd6; train ML models on train agents, score KL on val.

    ml/.venv/bin/python ml/scripts/kl_frankenstein.py split|features|mlp|meanfield|oracle|gat|score

Split = ml/scripts/within_run.py's: rng default_rng(0), permute non-seeds, first 10% val, next 10% of the
rest = stop set (early stopping / model selection), remainder = fit. "train" = fit + stop.
All files go to ml/out/kl/frankenstein/ (nothing written to the shared ml/data/cache).
"""
import os
os.environ.setdefault("OMP_NUM_THREADS", "4")
import dataclasses, json, math, sys, time
from pathlib import Path

import numpy as np
import pandas as pd
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import data, mlp as mlpmod, gat_daily  # noqa: E402
from fluniml.data import Run, ML, REPO  # noqa: E402

torch.set_num_threads(4)
RUN_DIR = REPO / "sim/runs/influenza_none_n7500_d14_s42_17ed9cd6"
OUT = ML / "out/kl/frankenstein"
CACHE = OUT / "cache_frankenstein.npz"
FEAT = OUT / "feat_frankenstein.npz"
EPS = 1e-6


def load(edges=True) -> Run:
    z = np.load(CACHE, allow_pickle=False)
    e = np.zeros(0, np.int32)
    return Run(run_id=RUN_DIR.name, agent_ids=z["agent_ids"], seed=z["seed"], label=z["label"],
               t_inf=z["t_inf"], route=z["route"], hours=int(z["hours"]),
               hour=z["hour"] if edges else e, a=z["a"] if edges else e, b=z["b"] if edges else e,
               ch=z["ch"] if edges else np.zeros((0, 9), np.float32), config=json.loads(str(z["config"])))


def split_masks(run):
    rng = np.random.default_rng(0)
    cand = rng.permutation(np.flatnonzero(~run.seed))
    n_val = int(round(0.1 * len(cand)))
    n_stop = int(round(0.1 * (len(cand) - n_val)))
    val, stop, fit = (np.zeros(run.N, bool) for _ in range(3))
    val[cand[:n_val]] = True
    stop[cand[n_val:n_val + n_stop]] = True
    fit[cand[n_val + n_stop:]] = True
    return val, stop, fit


def save_pred(name, run, p, extra=None):
    df = pd.DataFrame({"agent_id": run.agent_ids, "p": p})
    df.to_csv(OUT / f"pred_{name}_frankenstein.csv", index=False)
    if extra:
        json.dump(extra, open(OUT / f"info_{name}_frankenstein.json", "w"), indent=1, default=float)


def my_run_features(run):
    z = np.load(FEAT)
    return z["X"], list(z["names"])


mlpmod.run_features = my_run_features   # keep MLPModel off the shared cache


def cmd_split():
    r = load(edges=False)
    val, stop, fit = split_masks(r)
    json.dump(r.agent_ids[val].tolist(), open(OUT / "val_ids.json", "w"))
    json.dump({"stop": r.agent_ids[stop].tolist(), "fit": r.agent_ids[fit].tolist()},
              open(OUT / "train_split_frankenstein.json", "w"))
    y = r.label
    print(f"N {r.N}, seeds {r.seed.sum()}, val {val.sum()} ({y[val].sum():.0f} pos, {y[val].mean():.4f}), "
          f"stop {stop.sum()} ({y[stop].mean():.4f}), fit {fit.sum()} ({y[fit].mean():.4f}), "
          f"train(fit+stop) rate {y[fit | stop].mean():.4f}")


def cmd_features():
    from fluniml.features import agent_features
    t = time.time()
    r = load()
    X, names = agent_features(r)
    np.savez(FEAT, X=X, names=np.array(names))
    print(f"features {X.shape} in {time.time() - t:.0f}s")


def cmd_mlp():
    r = load(edges=False)
    val, stop, fit = split_masks(r)
    t = time.time()
    ms = [mlpmod.MLPModel("full", seed=s).fit([dataclasses.replace(r, mask=fit)],
                                               [dataclasses.replace(r, mask=stop)], verbose=False) for s in range(3)]
    p = np.mean([m.predict(r) for m in ms], 0)
    sec = time.time() - t
    print(f"mlp: {len(ms[0].names)} feats, epochs {[m.epochs for m in ms]}, stop logloss "
          f"{[round(m.val_loss, 4) for m in ms]}, {sec:.0f}s")
    save_pred("mlp_full", r, p, {"epochs": [m.epochs for m in ms], "stop_logloss": [m.val_loss for m in ms],
                                 "n_features": len(ms[0].names), "params": ms[0].n_params(), "sec": sec})


def cmd_meanfield(oracle=False):
    from fluniml.meanfield import MeanField
    r = load()
    val, stop, fit = split_masks(r)
    t = time.time()
    mf = MeanField(r.config, r.hours, oracle=oracle)
    c = mf.compact(dataclasses.replace(r, mask=fit | stop))   # likelihood masked to the train agents
    del r.ch
    res = mf.fit_compacts([c], verbose=True)
    p = mf.forward(c)
    th = np.exp(mf.log_theta)
    sec = time.time() - t
    name = "oracle_true_states" if oracle else "meanfield_py"
    print(f"{name}: theta {th}, nll {res.fun:.4f}, nfev {res.nfev}, {sec:.0f}s")
    save_pred(name, r, p, {"theta_close": th[0], "theta_room": th[1], "theta_imp": th[2],
                           "train_nll": res.fun, "nfev": res.nfev, "sec": sec})


def gat_metrics(y, p):
    from sklearn.metrics import average_precision_score, roc_auc_score
    return {"AUC": roc_auc_score(y, p), "AP": average_precision_score(y, p)}


def cmd_gat(epochs=150, patience=25):
    r = load()
    val, stop, fit = split_masks(r)
    t = time.time()
    g = gat_daily.to_graph(r, step_h=24)
    y, t_inf_np, agent_ids = r.label, r.t_inf, r.agent_ids
    del r
    print(f"graph: {g.steps} steps, {len(g.a)} edges, built in {time.time() - t:.0f}s", flush=True)
    torch.manual_seed(0)
    model = gat_daily.GATDaily(d=32, heads=4, edge_attn="gatv2_sigmoid", step_h=24)
    opt = torch.optim.Adam(model.parameters(), lr=5e-3)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: 0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * min(s, epochs) / epochs)))
    t_inf = torch.as_tensor(t_inf_np, dtype=torch.long)
    excl_fit, excl_stop = torch.as_tensor(~fit), torch.as_tensor(~stop)
    best, best_ep, bad, best_p, log = -1.0, -1, 0, None, []
    t = time.time()
    for ep in range(epochs):
        t0 = time.time()
        model.train()
        H = model(g)
        loss = gat_daily.survival_nll(H, t_inf, excl_fit, step_h=24)
        with torch.no_grad():
            stop_loss = float(gat_daily.survival_nll(H, t_inf, excl_stop, step_h=24))
            p = (-torch.expm1(-H.sum(0))).numpy()
        ms = gat_metrics(y[stop], p[stop])
        if ms["AP"] > best:   # selection on the stop set (train agents), never val
            best, best_ep, bad, best_p = ms["AP"], ep, 0, p.copy()
            torch.save({"state": model.state_dict(), "epoch": ep}, OUT / "gat_frankenstein.pt")
        else:
            bad += 1
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        sched.step()
        log.append({"epoch": ep, "fit_loss": float(loss.detach()), "stop_loss": stop_loss, **{f"stop_{k}": v for k, v in ms.items()},
                    "mean_p_stop": float(p[stop].mean()), "sec": time.time() - t0})
        print(f"epoch {ep}: loss fit {float(loss):.4f} stop {stop_loss:.4f} | stop AUC {ms['AUC']:.3f} AP {ms['AP']:.3f} "
              f"mean P {p[stop].mean():.3f} | {time.time() - t0:.0f}s", flush=True)
        if bad >= patience:
            print("early stop", flush=True)
            break
    sec = time.time() - t
    seed = g.seed.numpy()
    best_p = np.where(seed, 1.0, best_p)
    print(f"best epoch {best_ep} stop AP {best:.3f}; {sec:.0f}s")
    run_stub = type("S", (), {"agent_ids": agent_ids})
    save_pred("gat_daily", run_stub, best_p, {"best_epoch": best_ep, "stop_AP": best, "epochs_run": ep + 1,
                                              "sec": sec, "log": log})


def kl_bern(y, p):
    p = np.clip(p, EPS, 1 - EPS)
    with np.errstate(divide="ignore", invalid="ignore"):
        a = np.where(y > 0, y * np.log(y / p), 0.0)
        b = np.where(y < 1, (1 - y) * np.log((1 - y) / (1 - p)), 0.0)
    return a + b


def metrics(y, p):
    from sklearn.metrics import average_precision_score, roc_auc_score
    p = np.clip(np.asarray(p, float), EPS, 1 - EPS)
    # 10 equal-count bins by quantile edges; tied p always share a bin (constant p -> calib_kl == aggregate_kl)
    edges = np.quantile(p, np.linspace(0, 1, 11))
    bix = np.clip(np.searchsorted(edges, p, side="right") - 1, 0, 9)
    bins = [np.flatnonzero(bix == k) for k in range(10) if (bix == k).any()]
    calib = sum(len(ix) / len(p) * float(kl_bern(y[ix].mean(), p[ix].mean())) for ix in bins)
    const = np.ptp(p) == 0
    return {"per_agent_kl": float(kl_bern(y, p).mean()),
            "aggregate_kl": float(kl_bern(y.mean(), p.mean())),
            "calib_kl": float(calib),
            "auc": 0.5 if const else float(roc_auc_score(y, p)),
            "ap": float(y.mean()) if const else float(average_precision_score(y, p)),
            "mean_p": float(p.mean())}


NOTES = {
    "mlp_full": "MLP+ReLU (fluniml.mlp, 'full' features, 3-seed ensemble), trained on fit agents, early-stopped on stop set",
    "gat_daily": "GATDaily (train_gat_agent_split.py logic, defaults except epochs capped at 12 with cosine schedule over 12, patience 12, for time); loss on fit agents, model selection by stop-set AP (original selects on val AP)",
    "meanfield_py": "fluniml.meanfield, 3 thetas fitted by masked likelihood on train (fit+stop) agents",
    "meanfield_js": "model/meanfield.js defaults via ml/scripts/kl_frankenstein.mjs; p = 1 - S at final step (P ever infected, incl. 2% prior mass)",
    "meanfield_js_calibrated": "model/meanfield.js with prior = n_seeds/N = 5/7500 and lambdaScale refit (meanfield-cli --calibrate procedure: true seeds, no reports, prior 0, no imports, geometric bisection, bracket grown from [0.01,1] until it holds the target) to a train-agents-only target; reports included in scored run; p = 1 - S final",
    "meanfield_js_fit_reports": "model/meanfield.js with prior = 5/7500 and lambdaScale fitted on the full scored model (reports included) so mean P(ever infected) over train agents = their attack rate (ml/scripts/kl_mf_fit.mjs, Illinois method; see mf_fit_frankenstein.log); p = 1 - S final",
    "meanfield_js_raw+isotonic": "reference: isotonic regression of raw meanfield_js p_ever fitted on train (fit+stop) agents, applied to val",
    "infer_js_max": "model/infer.js defaults; p = max over the run of P(infected now) (change points, prior if none)",
    "infer_js_final": "model/infer.js defaults; p = P(infected now) at end of run (secondary)",
    "oracle_true_states": "meanfield.py oracle=True: uses everyone else's TRUE infection times; reference upper bound, not a competitor; thetas fitted on train agents",
}


def cmd_score():
    r = load(edges=False)
    val, stop, fit = split_masks(r)
    ids = json.load(open(OUT / "val_ids.json"))
    assert ids == r.agent_ids[val].tolist()
    y = r.label[val].astype(float)
    pos = pd.Series(np.arange(r.N), index=r.agent_ids)
    preds = {}
    for name in ["mlp_full", "gat_daily"]:
        f = OUT / f"pred_{name}_frankenstein.csv"
        if f.exists():
            d = pd.read_csv(f)
            preds[name] = d.p.to_numpy()[pos[d.agent_id].argsort().to_numpy()] if False else \
                pd.Series(d.p.to_numpy(), index=d.agent_id.astype(str))[r.agent_ids].to_numpy()
    for f, cols in [("meanfield_js_frankenstein.csv", {"p_ever": "meanfield_js"}),
                    ("meanfield_cal_js_frankenstein.csv", {"p_ever": "meanfield_js_calibrated"}),
                    ("meanfield_fit_js_frankenstein.csv", {"p_ever": "meanfield_js_fit_reports"})]:
        if (OUT / f).exists():
            d = pd.read_csv(OUT / f).set_index("agent_id")
            d.index = d.index.astype(str)
            for c, n in cols.items():
                preds[n] = d[c][r.agent_ids].to_numpy()
    if "meanfield_js" in preds:   # reference: isotonic recalibration of raw meanfield.js fitted on train agents
        from sklearn.isotonic import IsotonicRegression
        tr_m = fit | stop
        iso = IsotonicRegression(y_min=0, y_max=1, out_of_bounds="clip").fit(preds["meanfield_js"][tr_m], r.label[tr_m])
        preds["meanfield_js_raw+isotonic"] = iso.predict(preds["meanfield_js"])
    models = {}
    for name, p in preds.items():
        models[name] = {**metrics(y, p[val]), "notes": NOTES[name]}
        if name == "oracle_true_states":
            models[name]["baseline"] = True
    tr = float(r.label[fit | stop].mean())
    for name, p, note in [("const_train_rate", tr, f"constant p = train (fit+stop) attack rate {tr:.4f}"),
                          ("const_val_rate", float(y.mean()), "constant p = val attack rate: cheats on prevalence (per-agent KL = H(ybar), aggregate KL = 0)"),
                          ("uniform_0.5", 0.5, "constant p = 0.5 (per-agent KL = ln 2)")]:
        models[name] = {**metrics(y, np.full(len(y), p)), "notes": note, "baseline": True}
    models["perfect"] = {"per_agent_kl": 0.0, "aggregate_kl": 0.0, "calib_kl": 0.0, "auc": 1.0, "ap": 1.0,
                         "mean_p": float(y.mean()), "notes": "p = y; the floor (not computed)", "baseline": True}
    res = {"run": r.run_id, "n_val": int(val.sum()), "n_val_pos": int(y.sum()), "val_attack_rate": float(y.mean()),
           "train_attack_rate": tr, "n_train": int((fit | stop).sum()), "n_stop": int(stop.sum()),
           "split": "within_run.py logic: default_rng(0) permutation of non-seeds; val = first 10%, stop = next 10% of rest",
           "models": models}
    json.dump(res, open(OUT / "results.json", "w"), indent=1)
    tab = pd.DataFrame({k: {c: v[c] for c in ["per_agent_kl", "aggregate_kl", "calib_kl", "auc", "ap", "mean_p"]}
                        for k, v in models.items()}).T
    print(f"n_val {res['n_val']}, pos {res['n_val_pos']}, ybar {y.mean():.4f}")
    print(tab.to_markdown(floatfmt=".4f"))


if __name__ == "__main__":
    c = sys.argv[1]
    {"split": cmd_split, "features": cmd_features, "mlp": cmd_mlp, "meanfield": cmd_meanfield,
     "oracle": lambda: cmd_meanfield(True), "gat": lambda: cmd_gat(*map(int, sys.argv[2:4])), "score": cmd_score}[c]()
