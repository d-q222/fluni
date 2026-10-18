"""Compare fitted behavior rates with published ones and write validation.md (docs/AGENT_FRAMEWORK.md, section 4).

    .venv/bin/python scripts/validation_report.py runs/<run> [runs/<run2> ...] \
        [--calibrated configs/behavior_calibrated.json] [--published configs/published_rates.json] \
        [--out validation.md]

A fitted rate is the mean predicted rate over a run's population: every agent of the given runs
(personality.csv + agents_static.csv; else the Claude agents in llm_events.csv; with no runs, one
agent per archetype at the archetype's Big Five mean, weighted by population.archetype_fractions),
with the covariates that are not traits (worry, severity, forced alert) at their calibration-data
means, and advice kinds / relationships mixed as in the calibration data. CIs (95%) come from
parametric draws of the fitted coefficients. Published rates (a list of {id, behavior, context, rate,
ci_low, ci_high, population, citation, url, notes, tolerance}; for sick_response the context, or an
optional "outcome" key, names stay_home / vaden / carry_on) are matched on (behavior, context).
|fitted - published| > tolerance (default 0.10) is flagged. Fitted rates without a published match
are listed as unvalidated; nothing is tuned.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

SIM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIM))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from calibrate_agents import SICK_CLASSES, archetype_means, feature_row  # noqa: E402
from campussim import codes  # noqa: E402
from campussim.personality import TRAITS  # noqa: E402

DEFAULT_TOL = 0.10


def population(run_dirs, cfg):
    """List of (archetype, dz) for every agent, plus a weight per agent."""
    mu = archetype_means(cfg)
    rows, wts = [], []
    for d in map(Path, run_dirs):
        pc, st = d / "personality.csv", d / "agents_static.csv"
        if pc.exists() and st.exists():
            df = pd.read_csv(pc, dtype={"agent_id": str}).merge(
                pd.read_csv(st, usecols=["agent_id", "archetype"], dtype={"agent_id": str}), on="agent_id")
        elif (d / "llm_events.csv").exists():
            ev = pd.read_csv(d / "llm_events.csv", dtype=str, keep_default_na=False)
            for t in TRAITS:
                ev[t] = pd.to_numeric(ev[t], errors="coerce")
            df = ev.groupby("agent_id").agg({"archetype": "first", **{t: "mean" for t in TRAITS}}).reset_index()
        else:
            continue
        df = df[df["archetype"].isin(codes.ARCHETYPES)]
        for _, r in df.iterrows():
            rows.append((r["archetype"], {t: (0.0 if pd.isna(r[t]) else float(r[t]) - mu[r["archetype"]][t]) for t in TRAITS}))
            wts.append(1.0)
    if not rows:
        fr = cfg["population"]["archetype_fractions"]
        rows = [(a, {t: 0.0 for t in TRAITS}) for a in codes.ARCHETYPES]
        wts = [float(fr[a]) for a in codes.ARCHETYPES]
    w = np.array(wts)
    return rows, w / w.sum()


def _coef_matrix(model, coef_vec=None):
    names, cls = model["names"], model["classes"][1:]
    if coef_vec is None:
        coef_vec = np.array([model["coef"][c][nm] for c in cls for nm in names])
    return coef_vec.reshape(len(cls), len(names)).T     # (p, K-1)


def _rate(X, wmix, B, cls_idx):
    """Weighted mean probability of class cls_idx; X (n_mix, n_pop, p), wmix (n_mix,), pop weights folded in."""
    eta = X @ B                                          # (n_mix, n_pop, K-1)
    eta = np.concatenate([np.zeros(eta.shape[:2] + (1,)), eta], axis=2)
    P = np.exp(eta - eta.max(axis=2, keepdims=True))
    P /= P.sum(axis=2, keepdims=True)
    return P[..., cls_idx]


def model_rates(model, pop, pw, mix_key, mix, fixed, cls_names, draws):
    """{context: (rate, lo, hi)} for one model. mix: {value: weight} of the kind / relationship mixed over."""
    cov_means = model.get("covariate_means", {})
    names = model["names"]
    out = {}
    contexts = {"": mix} | {k: {k: 1.0} for k in mix} if mix_key else {"": None}
    for ctx, m in contexts.items():
        vals = list(m) if m else [None]
        wm = np.array([m[v] for v in vals]) if m else np.array([1.0])
        wm = wm / wm.sum()
        X = np.array([[feature_row(names, {"archetype": a, "dz": dz, mix_key or "_": v, **cov_means, **fixed})
                       for a, dz in pop] for v in vals])
        W = wm[:, None] * pw[None, :]
        for cname in cls_names:
            ci = model["classes"].index(cname)
            est = float((W * _rate(X, wm, _coef_matrix(model), ci)).sum())
            sims = np.array([(W * _rate(X, wm, _coef_matrix(model, d), ci)).sum() for d in draws])
            key = ctx if len(cls_names) == 1 else cname if ctx == "" else f"{cname}|{ctx}"
            out[key] = (est, float(np.quantile(sims, 0.025)), float(np.quantile(sims, 0.975)))
    return out


def fitted_rates(cal, pop, pw, n_draws=300, seed=0):
    rng = np.random.default_rng(seed)
    res = []

    def draws(model):
        mean = np.array([model["coef"][c][nm] for c in model["classes"][1:] for nm in model["names"]])
        return rng.multivariate_normal(mean, np.array(model["cov"]), size=n_draws, method="eigh")

    b = cal["behaviors"]
    for beh, mix_key, mix_field, cls in [("app_compliance", "kind", "kind_freq", ["1"]),
                                         ("disclosure", "rel", "rel_freq", ["1"]),
                                         ("influence", "kind", None, ["1"]),
                                         ("sick_response", None, None, SICK_CLASSES[1:] + SICK_CLASSES[:1])]:
        f = b.get(beh, {})
        if not f.get("fitted") or "model" not in f:
            continue
        m = f["model"]
        if beh == "influence":
            rel_mix = m.get("rel_freq", {"friend": 1.0})
            kinds = [nm.split(":", 1)[1] for nm in m["names"] if nm.startswith("kind:")]
            d = draws(m)
            for k in kinds:
                r = model_rates(m, pop, pw, "rel", rel_mix, {"kind": k}, cls, d)[""]
                res.append(dict(behavior=beh, context=k, rate=r[0], lo=r[1], hi=r[2], n=f["n"]))
            continue
        mix = m.get(mix_field) if mix_field else None
        mix = {k: v for k, v in (mix or {}).items() if k} or None
        rates = model_rates(m, pop, pw, mix_key if mix else None, mix, {}, cls, draws(m))
        for ctx, r in rates.items():
            res.append(dict(behavior=beh, context=ctx, rate=r[0], lo=r[1], hi=r[2], n=f["n"]))
    no = cal.get("notice", {})
    if no.get("fitted"):
        for cue, p in no["rate"].items():
            se = no["se"][cue]
            res.append(dict(behavior="notice_reaction", context=cue, rate=p, lo=max(0, p - 1.96 * se),
                            hi=min(1, p + 1.96 * se), n=b["notice_reaction"]["n_cue"][cue]))
        ov = b["notice_reaction"].get("overall")
        if ov and "" not in no["rate"]:
            res.append(dict(behavior="notice_reaction", context="", rate=ov["rate"], lo=max(0, ov["rate"] - 1.96 * ov["se"]),
                            hi=min(1, ov["rate"] + 1.96 * ov["se"]), n=b["notice_reaction"]["n"]))
    wo = cal.get("worry", {})
    if wo.get("fitted"):
        for k, j in wo["jump"].items():
            if wo.get("jump_fitted", {}).get(k):
                se = wo["jump_se"][k]
                res.append(dict(behavior="worry", context=k, rate=j, lo=j - 1.96 * se, hi=j + 1.96 * se,
                                n=b["worry"]["jump_n"][k]))
    return res


def _fmt(x, nd=3):
    return "–" if x is None or (isinstance(x, float) and np.isnan(x)) else f"{x:.{nd}f}"


def report(cal, published, fitted, sources):
    by_key = {(r["behavior"], r["context"]): r for r in fitted}
    matched, lines = set(), []
    lines += ["# Validation: fitted vs published behavior rates", "",
              f"Calibration: `{sources['calibrated']}` (created {cal.get('created', '?')}, source runs "
              f"{', '.join(cal.get('source_runs', [])) or '–'}, models {', '.join(cal.get('models', {})) or '–'}).",
              f"Published rates: `{sources['published']}`. Population: {sources['population']}.", "",
              "Fitted rate = mean predicted rate over the population; 95% CI from coefficient draws. A gap "
              "larger than the published entry's tolerance is flagged, not tuned away.", "",
              "## Fitted vs published", "",
              "| id | behavior | context | fitted (95% CI) | n | published (95% CI) | gap | tol | status | source |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    flagged = 0
    missing = []
    for p in published:
        ctx = p.get("outcome") or p.get("context") or ""
        key = (p["behavior"], ctx)
        tol = float(p.get("tolerance") if p.get("tolerance") is not None else DEFAULT_TOL)
        f = by_key.get(key)
        cite = p.get("citation", "")
        if p.get("url"):
            cite = f"[{cite or 'link'}]({p['url']})"
        pub = _fmt(p["rate"]) + ("" if p.get("ci_low") is None and p.get("ci_high") is None
                                 else f" ({_fmt(p.get('ci_low'))}–{_fmt(p.get('ci_high'))})")
        if f is None:
            missing.append(p)
            lines.append(f"| {p.get('id', '')} | {p['behavior']} | {ctx or '(all)'} | not fitted | – | {pub} | – | {tol:.2f} "
                         f"| NO FIT | {cite} |")
            continue
        matched.add(key)
        gap = f["rate"] - float(p["rate"])
        ok = abs(gap) <= tol
        flagged += not ok
        lines.append(f"| {p.get('id', '')} | {p['behavior']} | {ctx or '(all)'} | {_fmt(f['rate'])} ({_fmt(f['lo'])}–{_fmt(f['hi'])}) "
                     f"| {f['n']} | {pub} | {gap:+.3f} | {tol:.2f} | {'ok' if ok else '**OUTSIDE TOLERANCE**'} | {cite} |")
    lines += ["", f"{len(published) - len(missing)} published rates compared, {flagged} outside tolerance, "
              f"{len(missing)} without a fitted rate.", "", "## Unvalidated fitted rates (no published match)", "",
              "| behavior | context | fitted (95% CI) | n |", "|---|---|---|---|"]
    for r in fitted:
        if (r["behavior"], r["context"]) not in matched:
            lines.append(f"| {r['behavior']} | {r['context'] or '(all)'} | {_fmt(r['rate'])} ({_fmt(r['lo'])}–{_fmt(r['hi'])}) | {r['n']} |")
    lines += ["", "For worry the value is the jump size (after = before + jump * (1 - before)), not a rate."]
    unf = [b for b, f in cal.get("behaviors", {}).items() if not f.get("fitted")]
    if unf:
        lines += ["", "Not fitted (too few rows; placeholders in use): " + ", ".join(unf) + "."]
    notes = [p for p in published if p.get("notes")]
    if notes:
        lines += ["", "## Notes on published rates", ""] + [f"- **{p.get('id', '')}** ({p.get('population', '')}): {p['notes']}"
                                                            for p in notes]
    return "\n".join(lines) + "\n", flagged


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("runs", nargs="*", help="run directories whose population the rates are averaged over")
    ap.add_argument("--calibrated", default=str(SIM / "configs" / "behavior_calibrated.json"))
    ap.add_argument("--published", default=str(SIM / "configs" / "published_rates.json"))
    ap.add_argument("--out", default=None, help="default: validation.md in the first run dir, else in sim/")
    ap.add_argument("--draws", type=int, default=300)
    args = ap.parse_args(argv)
    from campussim.config import load_config
    cfg = load_config()
    cal = json.loads(Path(args.calibrated).read_text())
    pub_path = Path(args.published)
    published = json.loads(pub_path.read_text()) if pub_path.exists() else []
    if isinstance(published, dict):
        published = published.get("rates", [])
    pop, pw = population(args.runs, cfg)
    fitted = fitted_rates(cal, pop, pw, args.draws)
    src = {"calibrated": args.calibrated, "published": args.published if pub_path.exists() else f"{args.published} (missing)",
           "population": (f"{len(pop)} agents from {', '.join(Path(r).name for r in args.runs)}" if args.runs
                          else "archetype means weighted by archetype_fractions")}
    md, flagged = report(cal, published, fitted, src)
    out = Path(args.out) if args.out else (Path(args.runs[0]) if args.runs else SIM) / "validation.md"
    out.write_text(md)
    print(md)
    print(f"wrote {out} ({flagged} outside tolerance)")
    return fitted, flagged, out


if __name__ == "__main__":
    main()
