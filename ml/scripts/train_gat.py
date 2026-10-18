"""Train the GAT epidemic model (fluniml/gat.py) with a survival loss; write predictions.

    ml/.venv/bin/python ml/scripts/train_gat.py [--name gat] [--epochs 15] [--max-train N]
    ml/.venv/bin/python ml/scripts/train_gat.py --eval-only ml/out/gat/gat.pt [--name gat]
    ml/.venv/bin/python ml/scripts/train_gat.py --dry-run      # load one run, print sizes, no training

Splits come from ml/runs.json via data.run_dirs(split): "train" (fit), "stop" (early stopping
only) and "val" (held-out scoring, compare.py's default). Runs of any population size (1k, 7k)
mix freely and are loaded one at a time with data.load_run(d). Loaded runs stay in RAM between
epochs while their total stays under --mem-cache-gb; the rest are reloaded each time they are
used. One run = one optimizer step.

Loss: gat.survival_nll(H, t_inf, seed) with the true infection hour (training label only).
After every epoch the stop runs are scored (per-run AUC / AP / P@k on non-seeds); the best
run_AP checkpoint is kept, with early stopping.

Outputs:
  ml/out/gat/<name>.pt          checkpoint (model state + the args needed to rebuild it)
  ml/out/gat/<name>_log.json    per-epoch train loss, stop metrics, step time / RSS per run size
  ml/out/preds/<name>.parquet   predictions for --eval-splits (default val only) for compare.py
and a printed per-split (stop and val), per-run-size (N) metric table at the end.
"""
import argparse
import json
import math
import os
import random
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import data, gat, gat_daily, preds  # noqa: E402
from fluniml.data import ML  # noqa: E402
from fluniml.metrics import score  # noqa: E402

OUT = ML / "out" / "gat"
MODEL_KEYS = ["model", "d", "heads", "n_curves", "max_lag_h", "edge_attn", "checkpoint_every", "step_h"]


def is_daily(model):
    return isinstance(model, gat_daily.GATDaily)


def graph_of(model, r, device):
    """The model's input graph: hourly (GATEpi) or one step per step_h hours (GATDaily)."""
    if is_daily(model):
        return gat_daily.to_graph(r, device=device, step_h=model.step_h)
    return gat.to_graph(r, device=device)


def nll_of(model, H, t_inf, seed):
    if is_daily(model):
        return gat_daily.survival_nll(H, t_inf, seed, step_h=model.step_h)
    return gat.survival_nll(H, t_inf, seed)


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", default="gat")
    ap.add_argument("--model", default="epi", choices=["epi", "daily"],
                    help="epi: hourly GATEpi (fluniml/gat.py); daily: simple time-ordered GAT (fluniml/gat_daily.py)")
    ap.add_argument("--step-h", type=int, default=24, help="daily model: hours per step (24, 12, 6)")
    ap.add_argument("--runs", action="append", default=[], metavar="SPLIT=PATH[,PATH]",
                    help="use these run dirs for a split instead of ml/runs.json (paths relative to the repo root)")
    ap.add_argument("--edge-attn", default="gatv2_sigmoid", choices=["gatv2_sigmoid", "softmax", "none"])
    ap.add_argument("--d", type=int, default=32)
    ap.add_argument("--heads", type=int, default=4)
    ap.add_argument("--n-curves", type=int, default=8)
    ap.add_argument("--max-lag-h", type=int, default=240)
    ap.add_argument("--checkpoint-every", type=int, default=1, help="passed to GATEpi (activation checkpointing)")
    ap.add_argument("--kernel-init", action="store_true",
                    help="init temporal curves from meanfield.infectiousness_kernel(first run's config)")
    ap.add_argument("--teacher-force", action="store_true",
                    help="train with forward(g, t_inf=...) (hist/surv from true infection hours)")
    ap.add_argument("--epochs", type=int, default=15)
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--lr-sched", default="cosine", choices=["cosine", "step", "none"])
    ap.add_argument("--weight-decay", type=float, default=0.0)
    ap.add_argument("--clip", type=float, default=1.0)
    ap.add_argument("--patience", type=int, default=4)
    ap.add_argument("--big-n", type=int, default=2000, help="runs with N >= this count as 'big'")
    ap.add_argument("--big-weight", type=int, default=1, help="repeat each big train run this many times per epoch")
    ap.add_argument("--max-train", type=int, default=None, help="use only the first N train runs")
    ap.add_argument("--max-stop", type=int, default=None, help="use only the first N stop runs")
    ap.add_argument("--max-val", type=int, default=None, help="use only the first N val runs")
    ap.add_argument("--stop-split", default="stop", help="split used for early stopping")
    ap.add_argument("--eval-splits", default="val", help="splits written to out/preds/<name>.parquet")
    ap.add_argument("--dry-run", action="store_true",
                    help="list splits, load the first train run, build its HourlyGraph and the model, "
                         "print sizes; no forward/backward, writes nothing")
    ap.add_argument("--mem-cache-gb", type=float, default=4.0, help="keep loaded runs in RAM up to this total")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--device", default="cpu", choices=["cpu", "mps", "auto"])
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--eval-only", metavar="CHECKPOINT", default=None)
    ap.add_argument("--no-preds", action="store_true", help="don't write out/preds/<name>.parquet")
    return ap.parse_args(argv)


def rss_mb():
    try:
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())])) / 1024
    except Exception:
        return float("nan")


def peak_rss_mb():
    import resource
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return r / 2**20 if sys.platform == "darwin" else r / 1024


def run_bytes(r):
    return sum(x.nbytes for x in (r.hour, r.a, r.b, r.ch))


class RunPool:
    """Run dirs, loaded on demand. Keeps runs in RAM while the total stays under a budget."""

    def __init__(self, budget_gb):
        self.budget = budget_gb * 2**30
        self.used = 0
        self.mem = {}
        self.sizes = {}   # run dir -> N (known after first load)

    def get(self, d):
        d = Path(d)
        if d in self.mem:
            return self.mem[d]
        r = data.load_run(d)
        self.sizes[d] = r.N
        nb = run_bytes(r)
        if self.used + nb <= self.budget:
            self.mem[d] = r
            self.used += nb
        return r


def pick_device(name):
    if name == "auto":
        return "mps" if torch.backends.mps.is_available() else "cpu"
    return name


def size_label(N, big_n):
    return f"N={N}" if N < big_n else f"N={N} (big)"


def predict_run(model, r, device):
    g = graph_of(model, r, device)
    with torch.no_grad():
        p = np.asarray((gat_daily if is_daily(model) else gat).predict(model, g), dtype=float)
    p = np.where(r.seed, 1.0, p)
    return p


def score_rows(rows):
    """rows: list of (run, p). Score on non-seeds; returns metrics dict or None."""
    if not rows:
        return None
    df = pd.concat(pd.DataFrame({"run_id": r.run_id, "p": p[~r.seed], "label": r.label[~r.seed]})
                   for r, p in rows)
    if df.label.nunique() < 2:
        return None
    try:
        return score(df)
    except Exception as e:  # e.g. no run with both classes
        print("  scoring failed:", e)
        return None


def evaluate(model, dirs, pool, device, keep_p=False):
    """Predict each run; return (metrics, rows_or_light, per-run info)."""
    model.eval()
    rows, info = [], []
    for d in dirs:
        t = time.time()
        r = pool.get(d)
        p = predict_run(model, r, device)
        light = data.meta(r)
        rows.append((light, p))
        info.append({"run_id": r.run_id, "N": int(r.N), "edges": int(len(r.hour)),
                     "sec": round(time.time() - t, 2)})
        del r
    return score_rows(rows), rows, info


def build_model(margs, kernel=None):
    kw = {k: margs[k] for k in MODEL_KEYS if k in margs}
    if kw.pop("model", "epi") == "daily":
        return gat_daily.GATDaily(**kw)
    kw.pop("step_h", None)
    if kernel is not None:
        kw["kernel_init"] = torch.as_tensor(np.asarray(kernel), dtype=torch.float32)
    return gat.GATEpi(**kw)


def fmt(m, keys=("run_AUC", "run_AP", "run_P@k", "logloss")):
    if m is None:
        return "n/a"
    return " ".join(f"{k} {m[k]:.4f}" for k in keys)


def main(argv=None):
    args = parse_args(argv)
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    rng = random.Random(args.seed)
    device = pick_device(args.device)
    ckpt_path = OUT / f"{args.name}.pt"
    log_path = OUT / f"{args.name}_log.json"

    eval_splits = [s for s in args.eval_splits.split(",") if s]
    names = list(dict.fromkeys(["train", args.stop_split] + eval_splits))
    splits = {s: list(data.run_dirs(s)) for s in names}   # from ml/runs.json
    for spec in args.runs:                                 # --runs split=path[,path] overrides
        s, paths = spec.split("=", 1)
        root = ML.parent
        splits[s] = [p if Path(p).is_absolute() else root / p for p in (Path(x) for x in paths.split(","))]
        missing = [p for p in splits[s] if not Path(p).is_dir()]
        if missing:
            sys.exit(f"--runs {s}: not found: {missing}")
    for s, mx in (("train", args.max_train), ("stop", args.max_stop), ("val", args.max_val)):
        if mx is not None and s in splits:
            splits[s] = splits[s][:mx]
    print("runs: " + ", ".join(f"{s} {len(v)}" for s, v in splits.items())
          + f"; device {device}, threads {args.threads}", flush=True)
    pool = RunPool(args.mem_cache_gb)
    if args.dry_run:
        return dry_run(args, splits, device)
    OUT.mkdir(parents=True, exist_ok=True)

    log = {"args": vars(args), "epochs": [], "steps_by_N": {}}
    if args.eval_only:
        ck = torch.load(args.eval_only, map_location="cpu", weights_only=False)
        model = build_model(ck["model_args"])
        model.load_state_dict(ck["state"])
        model.to(device)
        print(f"loaded {args.eval_only} (epoch {ck.get('epoch')}, val run_AP {ck.get('val_run_AP')})")
    else:
        model, log = train(args, splits, pool, device, rng, ckpt_path, log_path, log)

    # ---- final eval: stop + eval splits, broken down by run size; preds only for eval splits ----
    t = time.time()
    results, all_rows, info_all = {}, [], []
    for s in dict.fromkeys([args.stop_split] + eval_splits):
        _, rows, info = evaluate(model, splits[s], pool, device)
        if s in eval_splits:
            all_rows += rows
        for i in info:
            i["split"] = s
        info_all += info
        Ns = sorted({r.N for r, _ in rows})
        for N in Ns:
            results[(s, size_label(N, args.big_n))] = score_rows([(r, p) for r, p in rows if r.N == N])
        results[(s, "all")] = score_rows(rows)
    print(f"final eval on {len(info_all)} runs in {time.time() - t:.0f}s", flush=True)
    if not args.no_preds and all_rows:
        path = preds.write(args.name, all_rows)
        print("wrote", path)

    cols = ["run_AUC", "run_AP", "run_P@k", "AUC", "AP", "logloss", "Brier", "ECE"]
    tab = []
    for (s, lab), m in results.items():
        n_runs = sum(1 for i in info_all if i["split"] == s and (lab == "all" or lab == size_label(i["N"], args.big_n)))
        row = {"split": s, "size": lab, "runs": n_runs}
        row.update({c: (m[c] if m else float("nan")) for c in cols})
        tab.append(row)
    tab = pd.DataFrame(tab)
    print()
    print(tab.to_markdown(index=False, floatfmt=".3f"))
    print(f"\npeak RSS {peak_rss_mb():.0f} MB")

    log["final"] = tab.to_dict(orient="records")
    log["eval_runs"] = info_all
    log["peak_rss_mb"] = peak_rss_mb()
    log_out = log_path if not args.eval_only else OUT / f"{args.name}_eval_log.json"
    json.dump(log, open(log_out, "w"), indent=1, default=float)
    print("log", log_out)
    return tab


def dry_run(args, splits, device):
    """Static check of the data path: one run -> HourlyGraph -> model. No forward, no outputs."""
    if not splits["train"]:
        sys.exit("no train runs")
    cache = getattr(data, "CACHE", None)
    cached = [d for d in splits["train"] if cache is not None and (cache / f"{Path(d).name}.npz").exists()]
    d = (cached or splits["train"])[0]   # prefer a cached run so the dry run builds no cache
    t = time.time()
    r = data.load_run(d)
    t_load = time.time() - t
    kernel = None
    if args.kernel_init and args.model == "epi":
        from fluniml.meanfield import infectiousness_kernel
        kernel = infectiousness_kernel(r.config, args.max_lag_h)
        print(f"kernel init: len {len(kernel)}, peak at lag {int(np.argmax(kernel))} h")
    margs = {k: getattr(args, k) for k in MODEL_KEYS}
    model = build_model(margs, kernel)
    t = time.time()
    g = graph_of(model, r, device)
    t_graph = time.time() - t
    print(f"run {r.run_id}: N={r.N}, hours={r.hours}, edges={len(r.hour)}, seeds={int(r.seed.sum())}, "
          f"infected non-seeds={int(r.label[~r.seed].sum())}, edge arrays {run_bytes(r) / 2**20:.0f} MB, "
          f"load {t_load:.2f}s")
    print(f"{type(g).__name__}: built in {t_graph:.2f}s")
    for k, v in vars(g).items():
        if torch.is_tensor(v):
            print(f"  {k}: {tuple(v.shape)} {v.dtype} {v.device} {v.element_size() * v.nelement() / 2**20:.1f} MB")
        else:
            print(f"  {k}: {v}")
    print(f"{type(model).__name__} {margs}: {sum(p.numel() for p in model.parameters())} params")
    print(f"RSS {rss_mb():.0f} MB, peak {peak_rss_mb():.0f} MB. Dry run: nothing trained or written.")


def train(args, splits, pool, device, rng, ckpt_path, log_path, log):
    train_dirs = splits["train"]
    if not train_dirs:
        sys.exit("no train runs")
    first = pool.get(train_dirs[0])
    kernel = None
    if args.kernel_init and args.model == "epi":
        from fluniml.meanfield import infectiousness_kernel
        kernel = infectiousness_kernel(first.config, args.max_lag_h)
        print(f"kernel init from {first.run_id}: peak at lag {int(np.argmax(kernel))} h", flush=True)
    margs = {k: getattr(args, k) for k in MODEL_KEYS}
    model = build_model(margs, kernel).to(device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"{type(model).__name__} {margs}: {n_params} params", flush=True)
    log["n_params"] = n_params

    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)

    def epoch_list():
        lst = []
        for d in train_dirs:
            N = pool.sizes.get(Path(d))
            rep = args.big_weight if (N is not None and N >= args.big_n) else 1
            lst += [d] * rep
        rng.shuffle(lst)
        return lst

    # total steps estimate for the schedule (sizes of unseen runs are learned in epoch 1)
    steps_per_epoch = len(epoch_list())
    total = max(1, steps_per_epoch * args.epochs)
    if args.lr_sched == "cosine":
        sched = torch.optim.lr_scheduler.LambdaLR(
            opt, lambda s: 0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * min(s, total) / total)))
    elif args.lr_sched == "step":
        sched = torch.optim.lr_scheduler.StepLR(opt, step_size=max(1, steps_per_epoch * max(1, args.epochs // 3)),
                                                gamma=0.3)
    else:
        sched = None

    best, best_ep, bad = -1.0, -1, 0
    steps_by_N = {}
    for ep in range(args.epochs):
        model.train()
        t_ep = time.time()
        losses, nans = [], 0
        lst = epoch_list()
        for i, d in enumerate(lst):
            t0 = time.time()
            r = pool.get(d)
            t_load = time.time() - t0
            g = graph_of(model, r, device)
            t_inf = torch.as_tensor(r.t_inf, dtype=torch.long, device=device)
            seed = torch.as_tensor(r.seed, dtype=torch.bool, device=device)
            t1 = time.time()
            H = model(g, t_inf=t_inf) if args.teacher_force else model(g)
            loss = nll_of(model, H, t_inf, seed)
            if not torch.isfinite(loss):
                nans += 1
                opt.zero_grad(set_to_none=True)
                print(f"  ep {ep} step {i}: non-finite loss on {r.run_id}, skipped", flush=True)
                continue
            opt.zero_grad(set_to_none=True)
            loss.backward()
            gn = torch.nn.utils.clip_grad_norm_(model.parameters(), args.clip)
            opt.step()
            if sched is not None:
                sched.step()
            dt = time.time() - t1
            losses.append(float(loss))
            s = steps_by_N.setdefault(int(r.N), {"steps": 0, "sec": 0.0, "load_sec": 0.0, "max_rss_mb": 0.0})
            s["steps"] += 1
            s["sec"] += dt
            s["load_sec"] += t_load
            if s["steps"] <= 3 or i % 10 == 0:
                s["max_rss_mb"] = max(s["max_rss_mb"], rss_mb())
            if i % 10 == 0 or i == len(lst) - 1:
                print(f"  ep {ep} step {i + 1}/{len(lst)} N={r.N} loss {float(loss):.4f} |g| {float(gn):.2f} "
                      f"lr {opt.param_groups[0]['lr']:.2e} {dt:.1f}s (+load {t_load:.1f}s)", flush=True)
            del g, H, loss, r
        t_train = time.time() - t_ep

        t_v = time.time()
        vm, _, vinfo = evaluate(model, splits[args.stop_split], pool, device)
        t_val = time.time() - t_v
        rec = {"epoch": ep, "train_loss": float(np.mean(losses)) if losses else float("nan"),
               "n_steps": len(losses), "nonfinite": nans, "val": vm, "train_sec": round(t_train, 1),
               "val_sec": round(t_val, 1), "rss_mb": rss_mb(), "lr": opt.param_groups[0]["lr"]}
        log["epochs"].append(rec)
        log["steps_by_N"] = {str(N): dict(v, sec_per_step=v["sec"] / max(1, v["steps"]))
                             for N, v in steps_by_N.items()}
        cur = vm["run_AP"] if vm else -1.0
        print(f"epoch {ep}: train loss {rec['train_loss']:.4f} | val {fmt(vm)} | "
              f"{t_train:.0f}s train, {t_val:.0f}s val, RSS {rec['rss_mb']:.0f} MB", flush=True)
        if cur > best or best_ep < 0:
            best, best_ep, bad = cur, ep, 0
            torch.save({"state": model.state_dict(), "model_args": margs, "epoch": ep, "val_run_AP": cur,
                        "val": vm, "args": vars(args)}, ckpt_path)
            print(f"  saved {ckpt_path} (val run_AP {cur:.4f})", flush=True)
        else:
            bad += 1
            if bad >= args.patience:
                print(f"early stop: no val run_AP gain for {bad} epochs", flush=True)
                break
        json.dump(log, open(log_path, "w"), indent=1, default=float)

    log["best_epoch"], log["best_val_run_AP"] = best_ep, best
    for N, v in sorted(steps_by_N.items()):
        print(f"train step time N={N}: {v['sec'] / max(1, v['steps']):.2f}s/step "
              f"(+{v['load_sec'] / max(1, v['steps']):.2f}s load), RSS up to {v['max_rss_mb']:.0f} MB")
    ck = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    model.load_state_dict(ck["state"])
    model.to(device)
    print(f"best epoch {best_ep}, val run_AP {best:.4f}", flush=True)
    return model, log


if __name__ == "__main__":
    main()
