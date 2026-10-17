"""summary.json: epidemic outcome summary (d2 keys first, in mock order, then extras)."""
import numpy as np
import pandas as pd

from . import codes


def _mean_days(v):
    """Mean of a duration spec: number | {"mean": m, ...} | [lo, hi]."""
    if v is None:
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, dict):
        if "mean" in v:
            return float(v["mean"])
        if "mu" in v and "sigma" in v:  # lognormal
            return float(np.exp(v["mu"] + v["sigma"] ** 2 / 2))
        return 0.0
    if isinstance(v, (list, tuple)) and len(v) == 2:
        return (float(v[0]) + float(v[1])) / 2
    return 0.0


def r_window_days(cfg):
    """Days a case needs to finish transmitting: mean latent + presymptomatic + infectious."""
    o = (cfg.get("output") or {}).get("R_window_days")
    if o is not None:
        return float(o)
    d = cfg.get("disease") or {}
    w = sum(_mean_days(d.get(k)) for k in ("latent_days", "presym_days", "infectious_days"))
    return w if w > 0 else 7.0


def _counts(keys):
    s = pd.Series(keys, dtype=object).value_counts()
    return {str(k): int(s[k]) for k in sorted(s.index, key=str)}


def compute_summary(cfg, campus, pop, infections_df, n_steps, extra=None):
    rc = cfg["run"]
    N = int(pop.N) if hasattr(pop, "N") else len(pop.agent_id)
    spd = 1440 // int(rc["step_min"])
    n_days = int(-(-int(n_steps) // spd))
    df = infections_df if infections_df is not None else pd.DataFrame()
    if len(df) == 0:
        df = pd.DataFrame({c: pd.Series(dtype=d) for c, d in
                           [("t", np.int64), ("infectee", np.int64), ("infector", np.int64), ("route", object),
                            ("r", np.int64), ("b", np.int64), ("contribution", float)]})
    t = df["t"].to_numpy(np.int64)
    infectee = df["infectee"].to_numpy(np.int64)
    infector = df["infector"].to_numpy(np.int64)
    route = df["route"].astype(str).to_numpy(dtype=object)
    b = df["b"].fillna(-1).to_numpy(np.int64)
    day = t // spd

    daily = np.bincount(day[(day >= 0) & (day < n_days)], minlength=n_days).astype(int) if n_days else np.zeros(0, int)
    n_infected = int(len(np.unique(infectee)))
    attack_rate = n_infected / N if N else 0.0
    peak_day = int(np.argmax(daily)) if len(daily) else 0

    # measured R: mean secondary infections per case infected early enough to finish transmitting
    window = r_window_days(cfg)
    secondary = pd.Series(infector[infector >= 0]).value_counts()
    sec_per_case = np.array([int(secondary.get(i, 0)) for i in infectee.tolist()], dtype=np.int64)
    eligible = day < (n_days - window)
    R_n = int(eligible.sum())
    measured_R = float(round(sec_per_case[eligible].mean(), 4)) if R_n else 0.0
    r_by_day = {}
    for d in range(n_days):
        m = day == d
        if m.any():
            r_by_day[str(d)] = float(round(sec_per_case[m].mean(), 4))
    # generations: imports/seeds = 0, child = parent + 1
    gen = {}
    for i, p in sorted(zip(range(len(t)), infector.tolist()), key=lambda z: (t[z[0]], z[0])):
        e = int(infectee[i])
        gen.setdefault(e, 0 if p < 0 else gen.get(p, 0) + 1)
    gen_counts = np.bincount(np.array(list(gen.values()), dtype=np.int64)) if gen else np.zeros(0, int)
    r_gen = float(round(gen_counts[1] / gen_counts[0], 4)) if len(gen_counts) > 1 and gen_counts[0] else 0.0

    btype = campus.buildings["type"].to_numpy(dtype=object) if campus is not None else np.zeros(0, object)
    loc_keys = [("off_campus" if ro == "import" else "seed" if ro == "seed" else "unknown") if bb < 0 or bb >= len(btype)
                else str(btype[bb]) for bb, ro in zip(b.tolist(), route.tolist())]
    arch = np.asarray(codes.ARCHETYPES, dtype=object)[np.asarray(pop.archetype, np.int64)[infectee]] \
        if len(infectee) else []
    out = {
        "attack_rate": float(round(attack_rate, 6)),
        "peak_day": peak_day,
        "measured_R": measured_R,
        "daily_incidence": [int(v) for v in daily],
        "infections_by_location_type": _counts(loc_keys),
        "infections_by_archetype": _counts(list(arch)),
        "infections_by_route": _counts(route.tolist()),
        "n_imports": int((route == "import").sum()),
        # ---- extras
        "n_infected": n_infected,
        "n_seed": int((route == "seed").sum()),
        "n_agents": N,
        "R_window_days": round(window, 4),
        "R_n_cases": R_n,
        "R_by_infection_day": r_by_day,
        "R_generation_based": r_gen,
        "cases_by_generation": [int(v) for v in gen_counts],
    }
    ocfg = cfg.get("output") or {}
    notes = []
    if N < int(ocfg.get("R_min_agents", 200)):
        notes.append(f"N={N} is too small for measured_R / attack_rate to be epidemiologically meaningful")
    if R_n < int(ocfg.get("R_min_cases", 20)):
        notes.append(f"measured_R is based on only {R_n} case(s) infected before day {n_days - window:.1f}")
    if notes:
        out["note"] = "; ".join(notes)
    if extra:
        out.update(extra)
    return out
