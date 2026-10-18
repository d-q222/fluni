"""Fitted base rates for rule-based agents (docs/AGENT_FRAMEWORK.md, section 4).

personality.rates_source = "config" (default) | "calibrated", read with .get (not in personality.json, so
run ids don't change). With "calibrated", the base rates that a calibration run measures are taken from
configs/behavior_calibrated.json (or cfg["behavior_calibrated"]; scripts/calibrate_agents.py writes it)
and shrunk toward the config value:

  new = (n * fitted + k * current) / (n + k)      k = personality.rates_prior_n (default 30), n = rows

Applied (pooled rates; archetype differences are kept by a pooled shift):
  - sick response shares (stay_home / vaden / carry_on): one shift in log-prob space added to every
    archetype's population.json sick_profile_p, then renormalized. Used by population.py with
    personality off and as the intercept targets of personality.py with big_five on.
  - app compliance: one logit shift added to every archetype's compliance_beta mean (concentration
    a + b kept). Per advice kind: pop.compliance_kind_mult[kind] = shrunk kind rate / shrunk pooled
    rate (the kind rate is shrunk toward the pooled one), a multiplier in interventions.apply_actions.
  - worry: jumps[kind] and half_life_days, shrunk toward worry.json (n = jump rows per kind, decay
    pairs for the half-life).
The shift is solved so the archetype-fraction-weighted population mean equals the shrunk pooled rate
exactly (its first step is logit(new) - logit(current)). Entries with fitted false or n = 0 are left
unchanged. adjusted(cfg) is pure; build_population and Worry call it, engine.run logs summary().
"""
import copy
import json

import numpy as np

from . import codes

SICK_ORDER = ("stay_home", "vaden", "carry_on")       # = codes.SICK_PROFILES order
ADVICE_KINDS = ("isolate_until", "wear_mask", "leave_location", "go_to_vaden")
WORRY_KINDS = ("own_symptoms", "friend_sick", "friend_positive", "app_alert", "warning_text", "saw_sick")


def is_on(cfg):
    return cfg.get("personality", {}).get("rates_source", "config") == "calibrated"


def prior_n(cfg):
    return float(cfg.get("personality", {}).get("rates_prior_n", 30))


def load_calibrated(cfg):
    cal = cfg.get("behavior_calibrated")
    if cal is None:
        from .config import CONFIG_DIR
        f = CONFIG_DIR / "behavior_calibrated.json"
        if not f.exists():
            raise FileNotFoundError(f"personality.rates_source = calibrated but {f} is missing "
                                    "(run scripts/calibrate_agents.py)")
        cal = json.loads(f.read_text())
    return cal


def shrink(fitted, current, n, k):
    return (n * fitted + k * current) / (n + k)


def _logit(p):
    p = np.clip(np.asarray(p, float), 1e-6, 1 - 1e-6)
    return np.log(p / (1 - p))


def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def extract(cal):
    """The pooled fitted rates in behavior_calibrated.json: {"sick": {n, share}, "compliance": {n, rate,
    by_kind: {kind: {n, rate}}}, "worry_jumps": {kind: {n, jump}}, "half_life": {n, days}}; a missing,
    unfitted or empty entry is omitted."""
    beh, out = cal.get("behaviors", {}), {}
    s = beh.get("sick_response", {})
    if s.get("fitted") and s.get("archetype_check"):
        n = sum(e["n"] for e in s["archetype_check"].values())
        if n > 0:
            share = {c: sum(e["n"] * e[c]["observed"] for e in s["archetype_check"].values()) / n for c in SICK_ORDER}
            out["sick"] = {"n": int(n), "share": share}
    c = beh.get("app_compliance", {})
    if c.get("fitted") and c.get("by_kind"):
        bk = {k: v for k, v in c["by_kind"].items() if v.get("n", 0) > 0}
        n = sum(v["n"] for v in bk.values())
        if n > 0:
            out["compliance"] = {"n": int(n), "rate": sum(v["n"] * v["observed"] for v in bk.values()) / n,
                                 "by_kind": {k: {"n": int(v["n"]), "rate": float(v["observed"])} for k, v in bk.items()}}
    wo, wb = cal.get("worry", {}), beh.get("worry", {})
    if wo.get("fitted"):
        jn, jf = wb.get("jump_n", wo.get("jump_n", {})), wo.get("jump_fitted", {})
        jumps = {k: {"n": int(jn.get(k, 0)), "jump": float(v)} for k, v in wo.get("jump", {}).items()
                 if jf.get(k) and jn.get(k, 0) > 0}
        if jumps:
            out["worry_jumps"] = jumps
        npairs = int(wb.get("n_decay_points", 0)) - int(wb.get("n_decay_chains", 0))
        if wo.get("half_life_fitted") and npairs > 0 and wo.get("half_life_days"):
            out["half_life"] = {"n": npairs, "days": float(wo["half_life_days"])}
    return out


def _weights(pcfg):
    fr = pcfg["archetype_fractions"]
    w = np.array([float(fr.get(a, 0.0)) for a in codes.ARCHETYPES])
    return w / w.sum()


def _shift_logit(means, wts, target):
    """d with sum(wts * sigmoid(logit(means) + d)) == target (bisection)."""
    lm, lo, hi = _logit(means), -20.0, 20.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        lo, hi = (mid, hi) if (wts * _sigmoid(lm + mid)).sum() < target else (lo, mid)
    return 0.5 * (lo + hi)


def _shift_logprob(P, wts, target):
    """Rows of P times exp(d), renormalized, with weighted mean == target (fixed point)."""
    d = np.log(np.clip(target, 1e-9, None)) - np.log(np.clip(wts @ P, 1e-9, None))
    for _ in range(200):
        Q = P * np.exp(d)
        Q /= Q.sum(axis=1, keepdims=True)
        d += np.log(np.clip(target, 1e-9, None)) - np.log(np.clip(wts @ Q, 1e-9, None))
    Q = P * np.exp(d)
    return Q / Q.sum(axis=1, keepdims=True)


def adjusted(cfg):
    """(cfg', changes): cfg with population.archetypes sick_profile_p / compliance_beta and worry
    jumps / half_life_days replaced by shrunken fitted rates, plus cfg'["population"]["_compliance_kind_mult"]
    ; changes is a list of (name, old, new). cfg itself is not modified; with rates_source "config" it is
    returned as is."""
    if not is_on(cfg):
        return cfg, []
    r, k = extract(load_calibrated(cfg)), prior_n(cfg)
    new = dict(cfg)
    new["population"] = pc = copy.deepcopy(cfg["population"])
    ap, wts, changes = pc["archetypes"], _weights(pc), []
    A = codes.ARCHETYPES
    if "sick" in r:
        P = np.array([ap[a]["sick_profile_p"] for a in A], float)
        P /= P.sum(axis=1, keepdims=True)
        cur = wts @ P
        fit = np.array([r["sick"]["share"][c] for c in SICK_ORDER])
        tgt = shrink(fit, cur, r["sick"]["n"], k)
        tgt = tgt / tgt.sum()
        Q = _shift_logprob(P, wts, tgt)
        for i, a in enumerate(A):
            ap[a]["sick_profile_p"] = [float(x) for x in Q[i]]
        for j, c in enumerate(SICK_ORDER):
            changes.append((f"sick_response.{c} (n={r['sick']['n']}, fit {fit[j]:.3f})", float(cur[j]), float(tgt[j])))
    if "compliance" in r:
        ab = np.array([ap[a]["compliance_beta"] for a in A], float)
        conc, m = ab.sum(axis=1), ab[:, 0] / ab.sum(axis=1)
        cur = float(wts @ m)
        rc = r["compliance"]
        tgt = shrink(rc["rate"], cur, rc["n"], k)
        m2 = _sigmoid(_logit(m) + _shift_logit(m, wts, tgt))
        for i, a in enumerate(A):
            ap[a]["compliance_beta"] = [float(m2[i] * conc[i]), float((1 - m2[i]) * conc[i])]
        changes.append((f"compliance (n={rc['n']}, fit {rc['rate']:.3f})", cur, tgt))
        mult = {}
        for kind, v in rc["by_kind"].items():
            if kind in ADVICE_KINDS:
                mult[kind] = shrink(v["rate"], tgt, v["n"], k) / max(tgt, 1e-9)
                changes.append((f"compliance multiplier {kind} (n={v['n']}, fit {v['rate']:.3f})", 1.0, mult[kind]))
        pc["_compliance_kind_mult"] = mult
    if "worry" in cfg and ("worry_jumps" in r or "half_life" in r):
        new["worry"] = wc = copy.deepcopy(cfg["worry"])
        for kind, v in r.get("worry_jumps", {}).items():
            if kind in wc["jumps"]:
                old = float(wc["jumps"][kind])
                wc["jumps"][kind] = float(np.clip(shrink(v["jump"], old, v["n"], k), 0.0, 1.0))
                changes.append((f"worry.jumps.{kind} (n={v['n']}, fit {v['jump']:.3f})", old, wc["jumps"][kind]))
        if "half_life" in r:
            old, v = float(wc["half_life_days"]), r["half_life"]
            wc["half_life_days"] = float(shrink(v["days"], old, v["n"], k))
            changes.append((f"worry.half_life_days (n={v['n']}, fit {v['days']:.3f})", old, wc["half_life_days"]))
    return new, changes


def summary(cfg):
    """Lines 'name: old -> new' for every applied rate (empty with rates_source "config")."""
    _, ch = adjusted(cfg)
    if not is_on(cfg):
        return []
    head = f"calibrated base rates (prior n {prior_n(cfg):g}): " + ("none fitted" if not ch else f"{len(ch)} applied")
    return [head] + [f"  {name}: {old:.4f} -> {new:.4f}" for name, old, new in ch]

