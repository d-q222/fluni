"""Fit rule-based behavior from measured Claude-agent decisions (docs/AGENT_FRAMEWORK.md, section 4).

    .venv/bin/python scripts/calibrate_agents.py runs/<calib_run> [runs/<run2> ...] \
        --out configs/behavior_calibrated.json [--min-rows 50] [--l2 1.0]

Reads each run's `llm_events.csv` (one row per measured decision) and `calibration_forced.csv`
(events the calibration scenario forced), and fits:

- sick response: multinomial logit over (carry_on = reference, stay_home, vaden) on archetype
  intercepts, Big Five centered at the archetype means of configs/personality.json, severity and
  worry -> weights.sick_stay_home / weights.sick_vaden, sick_severity;
- app compliance: logit on archetype intercepts, advice-kind effects, Big Five, worry and a
  forced-alert flag -> weights.compliance;
- disclosure: logit on archetype intercepts, relationship effects, Big Five, worry -> weights.honesty;
- influence: P(accept) logit with an intercept per message kind, A and E (centered at archetype
  means), worry and relationship effects (friend = 0) -> influence {b, w_A, w_E, w_worry, w_rel};
- worry: jump per event kind (after = before + jump * (1 - before), least squares) and the decay
  half-life toward an N baseline from consecutive measured values with no event between them;
- notice reaction: rate per cue.

All logits are fitted by Newton/IRLS with a small L2 penalty on everything except the intercepts;
standard errors come from the inverse penalized Hessian. Behaviors (or kinds/cues) with fewer than
--min-rows rows keep their placeholder and are flagged "fitted": false. Personality reads
weights[trait] only where weights_fitted[trait] is true (personality.weights_source = "calibrated").
"""
import argparse
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import least_squares

SIM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIM))
from campussim import codes  # noqa: E402
from campussim.personality import TRAITS  # noqa: E402

SICK_CLASSES = ["carry_on", "stay_home", "vaden"]       # class 0 is the reference (log-odds 0)
ADVICE_KINDS = ["isolate_until", "wear_mask", "leave_location", "go_to_vaden"]
MESSAGE_KINDS = ["invite", "warn", "tell_sick"]
RELATIONSHIPS = ["friend", "roommate", "dormmate", "teammate", "classmate", "stranger"]
WORRY_EVENTS = ["own_symptoms", "friend_sick", "friend_positive", "app_alert", "warning_text", "saw_sick"]
MEASURED = {"", "measured", "plan", "reflection"}
TRAIT_BEHAVIOR = {"compliance": "app_compliance", "honesty": "disclosure", "sick_stay_home": "sick_response",
                  "sick_vaden": "sick_response", "mask_propensity": None, "social_scale": None}
# placeholders when no config section provides them (reasoned guesses, not measurements)
INFLUENCE_PLACEHOLDER = {"b": {"invite": 0.0, "warn": -0.5, "tell_sick": -1.0}, "w_A": 1.5, "w_E": 1.0,
                         "w_worry": 1.0, "w_rel": {r: 0.0 for r in RELATIONSHIPS}}
WORRY_PLACEHOLDER = {"jump": {"own_symptoms": 0.4, "friend_sick": 0.15, "friend_positive": 0.25,
                              "app_alert": 0.3, "warning_text": 0.2, "saw_sick": 0.1}, "half_life_days": 3.0}
FORCED_MATCH = {"app_compliance": ("alert",), "worry": ("alert",), "sick_response": ("infect", "seed", "sever")}


# ---------------------------------------------------------------- regression

def fit_softmax(X, y, K, pen, lam, groups=None, max_iter=100, min_clusters=20):
    """Penalized multinomial logit (K = 2: logistic) by Newton's method. Class 0 is the reference.

    X (n, p), y (n,) ints in [0, K); pen (p,) bool, True = L2-penalized. Returns beta (p, K-1), the
    covariance of beta.ravel(order="F") (class-major) and its type: cluster-robust (sandwich, clustered
    by `groups`, i.e. by agent: an agent's decisions are not independent) when there are at least
    min_clusters groups, else the inverse penalized Hessian."""
    n, p = X.shape
    m = K - 1
    theta = np.zeros(p * m)
    Y = np.eye(K)[y][:, 1:]
    D = np.tile(np.where(pen, lam, 1e-8), m)

    def parts(th):
        eta = X @ th.reshape(p, m, order="F")
        eta = np.hstack([np.zeros((n, 1)), eta])
        eta -= eta.max(axis=1, keepdims=True)
        P = np.exp(eta)
        P /= P.sum(axis=1, keepdims=True)
        ll = float(np.log(np.clip(P[np.arange(n), y], 1e-300, None)).sum()) - 0.5 * float((D * th * th).sum())
        return ll, P[:, 1:]

    ll, P = parts(theta)
    for _ in range(max_iter):
        g = (X.T @ (Y - P)).ravel(order="F") - D * theta
        H = np.zeros((p * m, p * m))
        for k in range(m):
            for j in range(m):
                w = P[:, k] * ((k == j) - P[:, j])
                H[k * p:(k + 1) * p, j * p:(j + 1) * p] = (X * w[:, None]).T @ X
        H += np.diag(D)
        step = np.linalg.solve(H, g)
        s = 1.0
        while s > 1e-6:
            new = theta + s * step
            ll_new, P_new = parts(new)
            if ll_new >= ll - 1e-10:
                break
            s /= 2
        theta, done = new, abs(ll_new - ll) < 1e-9
        ll, P = ll_new, P_new
        if done:
            break
    H = np.zeros((p * m, p * m))
    for k in range(m):
        for j in range(m):
            w = P[:, k] * ((k == j) - P[:, j])
            H[k * p:(k + 1) * p, j * p:(j + 1) * p] = (X * w[:, None]).T @ X
    Hinv = np.linalg.inv(H + np.diag(D))
    cov, kind = Hinv, "model"
    if groups is not None:
        codes_g, G = pd.factorize(pd.Series(groups))[0], len(set(groups))
        if G >= min_clusters:
            R = Y - P                                                   # (n, m)
            S = np.hstack([X * R[:, [k]] for k in range(m)])            # per-row score, class-major
            Sg = np.zeros((G, p * m))
            np.add.at(Sg, codes_g, S)
            cov, kind = Hinv @ (Sg.T @ Sg) @ Hinv * G / (G - 1), "cluster_agent"
    return theta.reshape(p, m, order="F"), cov, kind


def feature_row(names, row):
    """Design vector for feature names (see design()) from a dict row:
    archetype, kind, rel, dz {trait: score - archetype mean}, worry, severity, forced."""
    out = np.zeros(len(names))
    for j, nm in enumerate(names):
        tag, _, val = nm.partition(":")
        if tag == "arch":
            out[j] = row.get("archetype") == val
        elif tag == "kind":
            out[j] = row.get("kind") == val
        elif tag == "rel":
            out[j] = row.get("rel") == val
        elif tag == "bf":
            out[j] = row.get("dz", {}).get(val, 0.0)
        elif tag == "one":
            out[j] = 1.0
        else:
            out[j] = row.get(tag, 0.0)
    return out


def predict(model, rows):
    """Class probabilities (n, K) for a fitted model dict and a list of feature rows."""
    X = np.array([feature_row(model["names"], r) for r in rows])
    B = np.array([[model["coef"][c][nm] for c in model["classes"][1:]] for nm in model["names"]])
    eta = np.hstack([np.zeros((len(rows), 1)), X @ B])
    P = np.exp(eta - eta.max(axis=1, keepdims=True))
    return P / P.sum(axis=1, keepdims=True)


# ---------------------------------------------------------------- data

def load_runs(run_dirs):
    ev, forced, step_min = [], [], {}
    for d in map(Path, run_dirs):
        f = d / "llm_events.csv"
        if not f.exists():
            raise SystemExit(f"{f} not found")
        df = pd.read_csv(f, dtype=str, keep_default_na=False)
        df["run"] = d.name
        ev.append(df)
        ff = d / "calibration_forced.csv"
        if ff.exists():
            fd = pd.read_csv(ff, dtype={"agent_id": str, "kind": str, "detail": str}, keep_default_na=False)
            fd["run"] = d.name
            forced.append(fd)
        sm = 5
        cj = d / "config.json"
        if cj.exists():
            c = json.loads(cj.read_text())
            sm = int(c.get("step_min") or c.get("run", {}).get("step_min") or 5)
        step_min[d.name] = sm
    ev = pd.concat(ev, ignore_index=True)
    for c in ["t", "severity", "value", "worry_before", "worry_after"] + TRAITS:
        ev[c] = pd.to_numeric(ev[c], errors="coerce")
    forced = (pd.concat(forced, ignore_index=True) if forced
              else pd.DataFrame(columns=["t", "agent_id", "kind", "detail", "run"]))
    forced["t"] = pd.to_numeric(forced["t"], errors="coerce")
    # time in hours: t (steps) * step_min, else the timestamp
    ev["hours"] = ev["t"] * ev["run"].map(step_min) / 60.0
    if ev["hours"].isna().any():
        ts = pd.to_datetime(ev["timestamp"], errors="coerce")
        ev.loc[ev["hours"].isna(), "hours"] = ((ts - ts.min()).dt.total_seconds() / 3600.0)[ev["hours"].isna()]
    forced["hours"] = forced["t"] * forced["run"].map(step_min).fillna(5) / 60.0
    return ev, forced


def archetype_means(cfg):
    return {a: {t: float(cfg["personality"]["big_five_mean"][a][t]) for t in TRAITS} for a in codes.ARCHETYPES}


def add_dz(df, mu):
    df = df[df["archetype"].isin(codes.ARCHETYPES)].copy()
    df["has_bf"] = df[TRAITS].notna().all(axis=1)
    for t in TRAITS:
        df["dz_" + t] = (df[t] - df["archetype"].map(lambda a: mu[a][t])).fillna(0.0)
    return df


def flag_forced(df, forced, behavior, window_h):
    keys = FORCED_MATCH.get(behavior, ())
    f = forced[forced["kind"].str.lower().apply(lambda k: any(s in k for s in keys))] if len(forced) else forced
    out = np.zeros(len(df), bool)
    if len(f):
        by = {k: g["hours"].to_numpy() for k, g in f.groupby(["run", "agent_id"])}
        for i, (r, a, h) in enumerate(zip(df["run"], df["agent_id"], df["hours"])):
            fh = by.get((r, a))
            if fh is not None and np.any((fh <= h + 1e-9) & (fh >= h - window_h)):
                out[i] = True
    return out


def rows_of(df, kind_col=None, rel=False):
    rows = []
    for _, r in df.iterrows():
        rows.append({"archetype": r["archetype"], "kind": r[kind_col] if kind_col else None,
                     "rel": r["relationship"] if rel else None,
                     "dz": {t: r["dz_" + t] for t in TRAITS}, "worry": r.get("worry_x", 0.0),
                     "severity": r.get("severity_x", 0.0), "forced": float(r.get("forced", 0.0))})
    return rows


def _worry_cov(df):
    """worry at the decision (worry_before), mean-imputed; used only if at least half the rows have it."""
    w = df["worry_before"]
    use = w.notna().mean() >= 0.5
    df["worry_x"] = w.fillna(w.mean() if w.notna().any() else 0.0)
    return use


def design(df, arch=True, kind_col=None, kinds=None, kind_ref=None, rel=False, rels=None, traits=TRAITS,
           extra=(), intercept_per_kind=False):
    names, pen = [], []
    if arch:
        for a in codes.ARCHETYPES:
            if (df["archetype"] == a).any():
                names.append("arch:" + a)
                pen.append(False)
    if kind_col:
        for k in kinds:
            if k == kind_ref and not intercept_per_kind:
                continue
            names.append("kind:" + k)
            pen.append(not intercept_per_kind)
    if rel:
        for r in rels:
            if r != "friend":
                names.append("rel:" + r)
                pen.append(True)
    for t in traits:
        names.append("bf:" + t)
        pen.append(True)
    for e in extra:
        names.append(e)
        pen.append(True)
    X = np.array([feature_row(names, r) for r in rows_of(df, kind_col, rel)]) if len(df) else np.zeros((0, len(names)))
    return names, np.array(pen), X


def model_dict(names, classes, fit, n, extra=None):
    beta, cov, se_type = fit
    se = np.sqrt(np.clip(np.diag(cov), 0, None))
    p = len(names)
    d = {"names": names, "classes": classes, "n": int(n), "se_type": se_type,
         "coef": {c: {nm: round(float(beta[j, i]), 5) for j, nm in enumerate(names)} for i, c in enumerate(classes[1:])},
         "se": {c: {nm: round(float(se[i * p + j]), 5) for j, nm in enumerate(names)} for i, c in enumerate(classes[1:])},
         "cov": np.round(cov, 7).tolist()}
    d.update(extra or {})
    return d


def arch_check(df, model, rows, classes, targets):
    """Per archetype: n, observed rate, mean fitted rate and config target, for each non-reference class
    (for a binary model, class "1")."""
    P = predict(model, rows)
    out = {}
    for a in codes.ARCHETYPES:
        m = (df["archetype"] == a).to_numpy()
        if not m.any():
            continue
        e = {"n": int(m.sum())}
        for i, c in enumerate(classes):
            if len(classes) == 2 and i == 0:
                continue
            key = "rate" if len(classes) == 2 else c
            tgt = targets.get(a, {}).get(c) if targets else None
            e[key] = {"observed": round(float((df["y"].to_numpy()[m] == i).mean()), 4),
                      "fitted": round(float(P[m, i].mean()), 4),
                      "target": None if tgt is None else round(float(tgt), 4)}
            if tgt is not None:
                e[key]["diff"] = round(e[key]["fitted"] - float(tgt), 4)
        out[a] = e
    return out


# ---------------------------------------------------------------- fits

def prep_binary(df, kind_col=None, kinds=None, rel=False, extra_cols=()):
    """Rows with a 0/1 outcome, the worry covariate, extra covariates that vary, kinds present (known
    ones first), the most common kind (reference) and relationships present."""
    df = df.copy()
    df["y"] = pd.to_numeric(df["outcome"], errors="coerce")
    df = df[df["y"].isin([0, 1])].copy()
    df["y"] = df["y"].astype(int)
    use_worry = _worry_cov(df) if len(df) else False
    extra = (["worry"] if use_worry else []) + [c for c in extra_cols if df[c].nunique() > 1]
    present_kinds = [k for k in (kinds or []) if (df[kind_col] == k).any()] if kind_col else None
    if kind_col:
        present_kinds += sorted(set(df[kind_col]) - set(present_kinds) - {""})
    kind_ref = df[kind_col].value_counts().idxmax() if kind_col and len(df) else None
    rels = [r for r in RELATIONSHIPS if (df["relationship"] == r).any()] if rel else None
    return df, extra, present_kinds, kind_ref, rels


def fit_compliance(ev, forced, mu, args, targets):
    df = add_dz(ev[ev["behavior"] == "app_compliance"], mu)
    df["forced"] = flag_forced(df, forced, "app_compliance", args.forced_window_h).astype(float)
    df, extra, kinds, ref, _ = prep_binary(df, "context", ADVICE_KINDS, extra_cols=("forced",))
    res = {"behavior": "app_compliance", "n": int(len(df)), "n_big_five": int(df["has_bf"].sum()) if len(df) else 0,
           "fitted": len(df) >= args.min_rows}
    if not res["fitted"]:
        return res
    names, pen, X = design(df, kind_col="context", kinds=kinds, kind_ref=ref, extra=extra)
    fit = fit_softmax(X, df["y"].to_numpy(), 2, pen, args.l2, df["run"] + "/" + df["agent_id"])
    res["model"] = model_dict(names, ["0", "1"], fit, len(df), {
        "kind_reference": ref, "covariate_means": {"worry": float(df["worry_x"].mean()), "forced": float(df["forced"].mean())},
        "kind_freq": df["context"].value_counts(normalize=True).round(4).to_dict()})
    rows = rows_of(df, "context")
    res["archetype_check"] = arch_check(df, res["model"], rows, ["0", "1"],
                                        {a: {"1": v} for a, v in targets["compliance"].items()})
    res["by_kind"] = {k: {"n": int((df["context"] == k).sum()), "observed": round(float(df.loc[df["context"] == k, "y"].mean()), 4)}
                      for k in kinds}
    res["by_forced"] = {("forced" if f else "natural"): {"n": int((df["forced"] == f).sum()),
                                                         "observed": round(float(df.loc[df["forced"] == f, "y"].mean()), 4)}
                        for f in (0.0, 1.0) if (df["forced"] == f).any()}
    return res


def fit_disclosure(ev, mu, args, targets):
    df = add_dz(ev[ev["behavior"] == "disclosure"], mu)
    df, extra, _, _, rels = prep_binary(df, rel=True)
    res = {"behavior": "disclosure", "n": int(len(df)), "n_big_five": int(df["has_bf"].sum()) if len(df) else 0,
           "fitted": len(df) >= args.min_rows}
    if not res["fitted"]:
        return res
    names, pen, X = design(df, rel=True, rels=rels, extra=extra)
    fit = fit_softmax(X, df["y"].to_numpy(), 2, pen, args.l2, df["run"] + "/" + df["agent_id"])
    res["model"] = model_dict(names, ["0", "1"], fit, len(df), {
        "rel_reference": "friend", "covariate_means": {"worry": float(df["worry_x"].mean())},
        "rel_freq": df["relationship"].value_counts(normalize=True).round(4).to_dict()})
    res["archetype_check"] = arch_check(df, res["model"], rows_of(df, rel=True), ["0", "1"],
                                        {a: {"1": v} for a, v in targets["honesty"].items()})
    res["relationship"] = {r: res["model"]["coef"]["1"].get("rel:" + r, 0.0) for r in rels}
    return res


def fit_sick(ev, forced, mu, args, targets):
    df = add_dz(ev[ev["behavior"] == "sick_response"], mu)
    df = df[df["outcome"].isin(SICK_CLASSES)].copy()
    df["y"] = df["outcome"].map({c: i for i, c in enumerate(SICK_CLASSES)})
    res = {"behavior": "sick_response", "n": int(len(df)), "n_big_five": int(df["has_bf"].sum()) if len(df) else 0,
           "fitted": len(df) >= args.min_rows}
    if len(df):
        res["hours_away"] = {c: {"n": int(g["value"].notna().sum()), "mean": round(float(g["value"].mean()), 3)
                                 if g["value"].notna().any() else None}
                             for c, g in df.groupby("outcome")}
        df["forced"] = flag_forced(df, forced, "sick_response", args.forced_window_h * 14)
        res["by_forced"] = {("forced" if f else "natural"): {"n": int((df["forced"] == f).sum()),
                            **{c: round(float((df.loc[df["forced"] == f, "outcome"] == c).mean()), 4) for c in SICK_CLASSES}}
                            for f in (False, True) if (df["forced"] == f).any()}
    if not res["fitted"]:
        return res
    use_worry = _worry_cov(df)
    df["severity_x"] = df["severity"].fillna(df["severity"].mean() if df["severity"].notna().any() else 0.0)
    extra = (["severity"] if df["severity"].notna().any() else []) + (["worry"] if use_worry else [])
    names, pen, X = design(df, extra=extra)
    fit = fit_softmax(X, df["y"].to_numpy(), 3, pen, args.l2, df["run"] + "/" + df["agent_id"])
    res["model"] = model_dict(names, SICK_CLASSES, fit, len(df), {
        "covariate_means": {"worry": float(df["worry_x"].mean()), "severity": float(df["severity_x"].mean())}})
    res["archetype_check"] = arch_check(df, res["model"], rows_of(df), SICK_CLASSES, targets["sick"])
    return res


def fit_influence(ev, mu, args, placeholder):
    df = add_dz(ev[ev["behavior"] == "influence"], mu)
    df, extra, _, _, rels = prep_binary(df, rel=True)
    res = {"behavior": "influence", "n": int(len(df)), "n_big_five": int(df["has_bf"].sum()) if len(df) else 0,
           "fitted": len(df) >= args.min_rows, "centered": "archetype_mean (configs/personality.json big_five_mean)"}
    params = json.loads(json.dumps(placeholder))
    if not res["fitted"]:
        res.update(params)
        return res
    kinds = [k for k in MESSAGE_KINDS if (df["context"] == k).sum() >= args.min_kind_rows]
    df = df[df["context"].isin(kinds)].copy()
    if "worry" not in extra:
        df["worry_x"] = 0.0
    names, pen, X = design(df, arch=False, kind_col="context", kinds=kinds, intercept_per_kind=True, rel=True,
                          rels=[r for r in RELATIONSHIPS if (df["relationship"] == r).any()],
                          traits=["agreeableness", "extraversion"], extra=["worry"] if "worry" in extra else [])
    fit = fit_softmax(X, df["y"].to_numpy(), 2, pen, args.l2, df["run"] + "/" + df["agent_id"])
    m = model_dict(names, ["0", "1"], fit, len(df), {
        "covariate_means": {"worry": float(df["worry_x"].mean())},
        "rel_freq": df["relationship"].value_counts(normalize=True).round(4).to_dict()})
    c, s = m["coef"]["1"], m["se"]["1"]
    params["b"].update({k: c["kind:" + k] for k in kinds})
    params["w_A"], params["w_E"] = c["bf:agreeableness"], c["bf:extraversion"]
    if "worry" in c:
        params["w_worry"] = c["worry"]
    params["w_rel"] = {r: 0.0 if r == "friend" else c.get("rel:" + r, params["w_rel"].get(r, 0.0))
                       for r in RELATIONSHIPS}
    res.update(params)
    res["se"] = {"b": {k: s["kind:" + k] for k in kinds}, "w_A": s["bf:agreeableness"], "w_E": s["bf:extraversion"],
                 "w_worry": s.get("worry"), "w_rel": {r: s["rel:" + r] for r in RELATIONSHIPS if "rel:" + r in s}}
    res["kind_fitted"] = {k: k in kinds for k in MESSAGE_KINDS}
    res["by_kind"] = {k: {"n": int((df["context"] == k).sum()), "observed": round(float(df.loc[df["context"] == k, "y"].mean()), 4)}
                      for k in kinds}
    res["model"] = m
    return res


def fit_worry(ev, forced, mu, args, placeholder):
    w = ev[ev["behavior"] == "worry"].copy()
    w["level"] = w["value"].where(w["value"].notna(), w["worry_after"])
    w["ctx"] = w["context"].fillna("").str.strip()
    res = {"behavior": "worry", "n": int(len(w)), "fitted": len(w) >= args.min_rows,
           "model_doc": "after = before + jump * (1 - before); between events "
                        "w(t2) = base + (w(t1) - base) * 2^(-dt / half_life), base = c0 + cN * (N - archetype mean N)"}
    out = {"jump": dict(placeholder.get("jump", {})), "half_life_days": float(placeholder.get("half_life_days", 3.0))}
    if not res["fitted"]:
        res.update(out)
        return res
    # jumps
    jumps, jse, jn, jfit = {}, {}, {}, {}
    ej = w[~w["ctx"].isin(MEASURED) & w["worry_before"].notna() & w["level"].notna()]
    for k, g in ej.groupby("ctx"):
        b, a = g["worry_before"].to_numpy(), g["level"].to_numpy()
        x = 1 - b
        jn[k] = int(len(g))
        if len(g) < args.min_kind_rows or (x * x).sum() < 1e-9:
            jfit[k] = False
            continue
        j = float((x * (a - b)).sum() / (x * x).sum())
        resid = a - b - j * x
        sig2 = float((resid ** 2).sum() / max(len(g) - 1, 1))
        jumps[k], jse[k], jfit[k] = round(j, 5), round(math.sqrt(sig2 / (x * x).sum()), 5), True
    out["jump"].update(jumps)
    res["jump_se"], res["jump_n"], res["jump_fitted"] = jse, jn, jfit
    if len(forced) and "app_alert" in jn:
        ea = ej[ej["ctx"] == "app_alert"].copy()
        ea["forced"] = flag_forced(ea, forced, "worry", args.forced_window_h)
        res["app_alert_by_forced"] = {}
        for f, g in ea.groupby("forced"):
            x = 1 - g["worry_before"].to_numpy()
            res["app_alert_by_forced"]["forced" if f else "natural"] = {
                "n": int(len(g)), "jump": round(float((x * (g["level"] - g["worry_before"])).sum() / max((x * x).sum(), 1e-9)), 4)}
    # decay: chains of consecutive measured values with no event (worry event or forced event) between
    # them. Each chain gets its own (latent) starting level, so measurement noise in the first value
    # doesn't bias the half-life short (as regressing w(t2) on a noisy w(t1) would).
    chains = []
    fby = {k: g["hours"].to_numpy() for k, g in forced.groupby(["run", "agent_id"])} if len(forced) else {}
    w = add_dz(w, mu)
    for (r, a), g in w.sort_values("hours", kind="stable").groupby(["run", "agent_id"]):
        g = g[g["hours"].notna() & g["level"].notna()]
        hrs, lev, is_m = g["hours"].to_numpy(), g["level"].to_numpy(), g["ctx"].isin(MEASURED).to_numpy()
        dzn = g["dz_neuroticism"].to_numpy()
        fh = fby.get((r, a), np.array([]))
        cur = []
        for i in range(len(g) + 1):
            broken = (i == len(g) or not is_m[i]
                      or (cur and (hrs[i] <= hrs[cur[-1]] or np.any((fh > hrs[cur[-1]]) & (fh <= hrs[i])))))
            if broken:
                if len(cur) >= 3:
                    chains.append((lev[cur], (hrs[cur] - hrs[cur[0]]) / 24.0, float(dzn[cur[0]])))
                cur = []
            if i < len(g) and is_m[i]:
                cur.append(i)
    res["n_decay_chains"] = len(chains)
    res["n_decay_points"] = int(sum(len(c[0]) for c in chains))
    if res["n_decay_points"] - len(chains) >= args.min_kind_rows:
        lv = np.concatenate([c[0] for c in chains])
        dt = np.concatenate([c[1] for c in chains])
        dn = np.concatenate([np.full(len(c[0]), c[2]) for c in chains])
        ci = np.concatenate([np.full(len(c[0]), j) for j, c in enumerate(chains)])

        def resid(th):
            h, c0, cn, s0 = math.exp(th[0]), th[1], th[2], th[3:]
            base = np.clip(c0 + cn * dn, 0, 1)
            return base + (s0[ci] - base) * np.power(2.0, -dt / h) - lv

        x0 = np.concatenate([[math.log(3.0), float(np.mean(lv)), 0.0], [c[0][0] for c in chains]])
        sol = least_squares(resid, x0=x0)
        J = sol.jac
        sig2 = float((sol.fun ** 2).sum() / max(len(lv) - len(x0), 1))
        try:
            cov = np.linalg.pinv(J.T @ J) * sig2
        except np.linalg.LinAlgError:
            cov = np.full((len(x0), len(x0)), np.nan)
        h = math.exp(sol.x[0])
        out["half_life_days"] = round(h, 4)
        res["half_life_se"] = round(h * math.sqrt(max(cov[0, 0], 0)), 4)
        res["baseline"] = {"c0": round(float(sol.x[1]), 4), "cN": round(float(sol.x[2]), 4),
                           "c0_se": round(math.sqrt(max(cov[1, 1], 0)), 4), "cN_se": round(math.sqrt(max(cov[2, 2], 0)), 4),
                           "noise_sd": round(math.sqrt(sig2), 4)}
        res["half_life_fitted"] = True
    else:
        res["half_life_fitted"] = False
    res.update(out)
    return res


def fit_notice(ev, args):
    df = ev[ev["behavior"] == "notice_reaction"].copy()
    df["y"] = pd.to_numeric(df["outcome"], errors="coerce")
    df = df[df["y"].isin([0, 1])]
    res = {"behavior": "notice_reaction", "n": int(len(df)), "fitted": len(df) >= args.min_rows, "rate": {}, "se": {},
           "n_cue": {}, "cue_fitted": {}}
    if len(df):
        p = float(df["y"].mean())
        res["overall"] = {"rate": round(p, 4), "se": round(math.sqrt(p * (1 - p) / len(df)), 4)}
    if not res["fitted"]:
        return res
    for cue, g in df.groupby(df["context"].fillna("")):
        p = float(g["y"].mean())
        res["n_cue"][cue] = int(len(g))
        res["cue_fitted"][cue] = len(g) >= args.min_kind_rows
        if res["cue_fitted"][cue]:
            res["rate"][cue], res["se"][cue] = round(p, 4), round(math.sqrt(max(p * (1 - p), 1e-4) / len(g)), 4)
    return res


# ---------------------------------------------------------------- assemble

def _find_section(cfg, key):
    for sec in cfg.values():
        if isinstance(sec, dict) and isinstance(sec.get(key), dict):
            return sec[key]
    return None


def targets_from(cfg):
    ap = cfg["population"]["archetypes"]
    mean = lambda ab: ab[0] / (ab[0] + ab[1])  # noqa: E731
    t = {k: {a: mean(ap[a][f"{k}_beta"]) for a in codes.ARCHETYPES} for k in ("compliance", "mask_propensity", "honesty")}
    t["sick"] = {}
    for a in codes.ARCHETYPES:
        sp = np.array(ap[a]["sick_profile_p"], float)
        sp /= sp.sum()
        t["sick"][a] = dict(zip(["stay_home", "vaden", "carry_on"], sp))
    return t


def calibrate(run_dirs, args, cfg=None):
    from campussim.config import load_config
    cfg = cfg or load_config()
    mu = archetype_means(cfg)
    targets = targets_from(cfg)
    ev, forced = load_runs(run_dirs)
    infl_ph = {**INFLUENCE_PLACEHOLDER, **(_find_section(cfg, "influence") or {})}
    worry_ph = {**WORRY_PLACEHOLDER, **(_find_section(cfg, "worry") or {})}
    fits = {
        "sick_response": fit_sick(ev, forced, mu, args, targets),
        "app_compliance": fit_compliance(ev, forced, mu, args, targets),
        "disclosure": fit_disclosure(ev, mu, args, targets),
        "influence": fit_influence(ev, mu, args, infl_ph),
        "worry": fit_worry(ev, forced, mu, args, worry_ph),
        "notice_reaction": fit_notice(ev, args),
    }
    placeholder = cfg["personality"]["weights"]
    weights, wse, wfit, worry_w = {}, {}, {}, {}
    for trait, ph in placeholder.items():
        beh = TRAIT_BEHAVIOR.get(trait)
        f = fits.get(beh) if beh else None
        ok = bool(f and f["fitted"] and "model" in f and f["n_big_five"] >= args.min_rows)
        wfit[trait] = ok
        if not ok:
            weights[trait], wse[trait] = dict(ph), None
            continue
        cls = {"sick_stay_home": "stay_home", "sick_vaden": "vaden"}.get(trait, "1")
        c, s = f["model"]["coef"][cls], f["model"]["se"][cls]
        weights[trait] = {t: c["bf:" + t] for t in TRAITS}
        wse[trait] = {t: s["bf:" + t] for t in TRAITS}
        if "worry" in c:
            worry_w[trait] = {"w": c["worry"], "se": s["worry"]}
    sick = fits["sick_response"]
    out = {
        "_doc": "Fitted by scripts/calibrate_agents.py from Claude-agent decisions (llm_events.csv). weights has the "
                "shape of personality.json weights (logit / log-odds change per unit of score - archetype mean); a trait "
                "is used by personality.weights_source = 'calibrated' only where weights_fitted is true, otherwise "
                "personality.json is used. Intercepts stay solved from population.json targets; archetype_check "
                "compares the fitted mean rates with those targets. behaviors[*].model has every coefficient, its "
                "standard error and covariance (validation_report.py uses them).",
        "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_runs": [Path(d).name for d in run_dirs],
        "models": {k: int(v) for k, v in ev["model"].replace("", "unknown").value_counts().items()},
        "min_rows": args.min_rows, "min_kind_rows": args.min_kind_rows, "l2": args.l2,
        "n": {b: int(v) for b, v in ev["behavior"].value_counts().items()},
        "n_forced": {k: int(v) for k, v in forced["kind"].value_counts().items()} if len(forced) else {},
        "weights": weights, "weights_se": wse, "weights_fitted": wfit,
        "worry_weights": worry_w,
        "sick_severity": ({c: {"w": sick["model"]["coef"][c]["severity"], "se": sick["model"]["se"][c]["severity"]}
                           for c in ("stay_home", "vaden")} if sick.get("model") and "severity" in sick["model"]["names"] else None),
        "influence": {k: fits["influence"][k] for k in ("b", "w_A", "w_E", "w_worry", "w_rel", "fitted", "n")}
        | ({"se": fits["influence"]["se"]} if "se" in fits["influence"] else {}),
        "worry": {k: v for k, v in fits["worry"].items() if k in ("jump", "half_life_days", "fitted", "jump_fitted",
                                                                   "half_life_fitted", "jump_se", "half_life_se", "baseline")},
        "notice": {k: fits["notice_reaction"][k] for k in ("rate", "se", "fitted", "n", "cue_fitted")},
        "archetype_check": {b: f["archetype_check"] for b, f in fits.items() if "archetype_check" in f},
        "behaviors": fits,
    }
    return out


def summary(out):
    lines = [f"source runs: {', '.join(out['source_runs'])}   models: {out['models']}",
             f"{'behavior':16} {'n':>6} fitted",]
    for b, f in out["behaviors"].items():
        lines.append(f"{b:16} {f['n']:6d} {'yes' if f['fitted'] else 'NO (placeholder)'}")
    lines.append("")
    lines.append(f"{'weights':16} " + " ".join(f"{t[:5]:>13}" for t in TRAITS))
    for trait, w in out["weights"].items():
        se = out["weights_se"][trait]
        cells = [f"{w.get(t, 0.0):+6.2f}" + (f"±{se[t]:4.2f}" if se else "      ") for t in TRAITS]
        lines.append(f"{trait:16} " + " ".join(f"{c:>13}" for c in cells) + ("" if out["weights_fitted"][trait] else "  (placeholder)"))
    if out["sick_severity"]:
        lines.append("sick severity: " + ", ".join(f"{c} {v['w']:+.2f}±{v['se']:.2f}" for c, v in out["sick_severity"].items()))
    if out["worry_weights"]:
        lines.append("worry weights: " + ", ".join(f"{t} {v['w']:+.2f}±{v['se']:.2f}" for t, v in out["worry_weights"].items()))
    inf = out["influence"]
    lines.append(f"influence ({'fitted' if inf['fitted'] else 'placeholder'}): b " +
                 ", ".join(f"{k} {v:+.2f}" for k, v in inf["b"].items()) +
                 f"; w_A {inf['w_A']:+.2f} w_E {inf['w_E']:+.2f} w_worry {inf['w_worry']:+.2f}; w_rel " +
                 ", ".join(f"{k} {v:+.2f}" for k, v in inf["w_rel"].items()))
    wo = out["worry"]
    lines.append(f"worry ({'fitted' if wo['fitted'] else 'placeholder'}): half-life {wo['half_life_days']:.2f} d"
                 + (f" ±{wo['half_life_se']:.2f}" if "half_life_se" in wo else "") + "; jumps " +
                 ", ".join(f"{k} {v:+.3f}" for k, v in wo["jump"].items()))
    no = out["notice"]
    lines.append(f"notice ({'fitted' if no['fitted'] else 'placeholder'}): " +
                 (", ".join(f"{k} {v:.2f}" for k, v in no["rate"].items()) or "-"))
    lines.append("")
    lines.append(f"{'archetype check':16} {'archetype':10} {'class':10} {'n':>5} {'obs':>6} {'fit':>6} {'target':>6}")
    for b, chk in out["archetype_check"].items():
        for a, e in chk.items():
            for c, v in e.items():
                if c == "n":
                    continue
                tg = "-" if v["target"] is None else f"{v['target']:.3f}"
                lines.append(f"{b:16} {a:10} {c:10} {e['n']:5d} {v['observed']:6.3f} {v['fitted']:6.3f} {tg:>6}")
    return "\n".join(lines)


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("runs", nargs="+", help="run directories with llm_events.csv")
    ap.add_argument("--out", default=str(SIM / "configs" / "behavior_calibrated.json"))
    ap.add_argument("--min-rows", type=int, default=50, help="minimum rows per behavior to fit it")
    ap.add_argument("--min-kind-rows", type=int, default=10, help="minimum rows per kind / cue / decay pairs")
    ap.add_argument("--l2", type=float, default=0.1, help="L2 penalty on non-intercept coefficients")
    ap.add_argument("--forced-window-h", type=float, default=24.0,
                    help="a decision within this many hours after a forced event counts as forced")
    ap.add_argument("--quiet", action="store_true")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    out = calibrate(args.runs, args)
    p = Path(args.out)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(out, indent=1, default=float) + "\n")
    if not args.quiet:
        print(summary(out))
        print(f"\nwrote {p}")
    return out


if __name__ == "__main__":
    main()
