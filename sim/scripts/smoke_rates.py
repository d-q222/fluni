"""Smoke test for calibrated base rates (campussim/rates.py, personality.rates_source = "calibrated").

A synthetic behavior_calibrated.json (as cfg["behavior_calibrated"]) says Claude agents stay home when
sick only 10% of the time (far below population.json), comply with app advice 90% of the time, and
have a bigger friend_sick worry jump and a shorter half-life:

- n large (100,000 rows): the 7,500-agent population's stay_home share drops to ~0.10, with personality
  off and with big_five; archetype order is kept; compliance moves up; worry jumps / half-life change.
- n small (30 rows, prior n 30): stay_home moves about halfway.
- unfitted entries (fitted false, n = 0) leave their rates unchanged.
- "config" (default or explicit): run id and every output file identical to no behavior_calibrated.
- "calibrated" changes the run id.
"""
import copy
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim import codes, rates  # noqa: E402
from campussim.campus import Campus  # noqa: E402
from campussim.config import ROOT, load_config  # noqa: E402
from campussim.engine import make_run_id, run  # noqa: E402
from campussim.population import build_population  # noqa: E402
from campussim.worry import Worry  # noqa: E402

FIT_SICK = {"stay_home": 0.10, "vaden": 0.20, "carry_on": 0.70}


def synthetic(n_sick, n_comp=None, n_worry=None):
    n_comp = n_sick if n_comp is None else n_comp
    n_worry = n_sick if n_worry is None else n_worry
    A = codes.ARCHETYPES
    per = n_sick // len(A)
    return {
        "source_runs": ["synthetic"], "created": "2026-10-18T00:00:00Z",
        "worry": {"fitted": True, "jump": {"friend_sick": 0.6, "saw_sick": 0.4}, "half_life_days": 1.0,
                  "jump_fitted": {"friend_sick": True, "saw_sick": False}, "half_life_fitted": True},
        "behaviors": {
            "sick_response": {"fitted": True, "n": per * len(A), "archetype_check": {
                a: {"n": per, **{c: {"observed": v} for c, v in FIT_SICK.items()}} for a in A}},
            "app_compliance": {"fitted": True, "n": n_comp, "by_kind": {
                "isolate_until": {"n": n_comp // 2, "observed": 0.8}, "wear_mask": {"n": n_comp - n_comp // 2, "observed": 1.0},
                "go_to_vaden": {"n": 0, "observed": 0.0}}},
            "worry": {"jump_n": {"friend_sick": n_worry, "saw_sick": n_worry}, "n_decay_points": n_worry + 10,
                      "n_decay_chains": 10},
            "disclosure": {"fitted": False, "n": 3},
        },
    }


def build(cfg, campus):
    rngs = np.random.SeedSequence(int(cfg["run"]["seed"])).spawn(9)
    return build_population(cfg, campus, np.random.default_rng(rngs[1]))


def shares(pop):
    return np.bincount(np.asarray(pop.sick_profile), minlength=3) / pop.N


def files(d):
    return {p.relative_to(d).as_posix(): p.read_bytes() for p in sorted(d.rglob("*")) if p.is_file()}


def mk(base, cal=None, sets=()):
    cfg = load_config(overrides=copy.deepcopy(base), set_args=list(sets))
    cfg.pop("behavior_calibrated", None)
    if cal is not None:
        cfg["behavior_calibrated"] = cal
    return cfg


def main():
    base = {"run": {"n_agents": 7500, "seed": 42}}
    big, small = synthetic(100_000), synthetic(30)
    cfg0 = mk(base)
    campus = Campus.build(cfg0["map"], data_dir=ROOT / "data" / "osm")
    p0 = build(cfg0, campus)
    s0 = shares(p0)
    cal_big = mk(base, big, ["personality.rates_source=calibrated"])
    print("\n".join(rates.summary(cal_big)))
    p_big = build(cal_big, campus)
    p_small = build(mk(base, small, ["personality.rates_source=calibrated"]), campus)
    p_b5 = build(mk(base, big, ["personality.rates_source=calibrated", "personality.mode=big_five"]), campus)
    s_big, s_small, s_b5 = shares(p_big), shares(p_small), shares(p_b5)
    print(f"stay_home share: config {s0[0]:.3f}, n=100k {s_big[0]:.3f}, n=30 {s_small[0]:.3f}, "
          f"n=100k big_five {s_b5[0]:.3f} (fitted {FIT_SICK['stay_home']})")
    assert s0[0] > 0.3, s0
    assert abs(s_big[0] - 0.10) < 0.02 and abs(s_b5[0] - 0.10) < 0.02, (s_big, s_b5)
    mid = 0.5 * (s0[0] + 0.10)   # n = k = 30: halfway
    assert abs(s_small[0] - mid) < 0.03, (s_small, mid)
    for f in ("archetype", "home_room", "friend_group", "team_id"):
        assert np.array_equal(getattr(p0, f), getattr(p_big, f)), f"{f} changed"
    # archetype differences kept: per-archetype log odds between responses shift by the same amount
    first = [int(np.flatnonzero(np.asarray(p0.archetype) == a)[0]) for a in range(len(codes.ARCHETYPES))]
    P0, P1 = (np.asarray(p.param("sick_profile_p"), float)[first] for p in (p0, p_big))
    P0 = P0 / P0.sum(axis=1, keepdims=True)
    for c in (0, 1):
        d = np.log(P1[:, c] / P1[:, 2]) - np.log(P0[:, c] / P0[:, 2])
        assert np.ptp(d) < 1e-9, d
    print("sick_profile_p by archetype: " + ", ".join(f"{a} {x:.3f}->{y:.3f}"
                                                     for a, x, y in zip(codes.ARCHETYPES, P0[:, 0], P1[:, 0])))
    c0, c1 = p0.compliance.mean(), p_big.compliance.mean()
    print(f"compliance mean: {c0:.3f} -> {c1:.3f}; kind multipliers {p_big.compliance_kind_mult}")
    assert c1 > c0 + 0.1 and abs(c1 - 0.9) < 0.03, (c0, c1)
    km = p_big.compliance_kind_mult
    assert km["wear_mask"] > 1 > km["isolate_until"] and "go_to_vaden" not in km, km
    assert p0.compliance_kind_mult is None

    # worry: fitted friend_sick jump and half-life move, unfitted saw_sick doesn't
    w0, w1 = Worry(cfg0, p0), Worry(cal_big, p_big)
    print(f"worry jumps friend_sick {w0.jumps['friend_sick']} -> {w1.jumps['friend_sick']:.4f}, "
          f"saw_sick {w0.jumps['saw_sick']} -> {w1.jumps['saw_sick']}, decay/step {w0.f:.6f} -> {w1.f:.6f}")
    assert abs(w1.jumps["friend_sick"] - 0.6) < 0.01 and w1.jumps["saw_sick"] == w0.jumps["saw_sick"]
    assert w1.jumps["own_symptoms"] == w0.jumps["own_symptoms"] and w1.f < w0.f
    wc = rates.adjusted(cal_big)[0]["worry"]
    assert abs(wc["half_life_days"] - 1.0) < 0.01, wc["half_life_days"]
    assert cal_big["worry"]["jumps"]["friend_sick"] == cfg0["worry"]["jumps"]["friend_sick"], "cfg was modified"

    # unfitted / n = 0 entries change nothing
    nofit = synthetic(100_000)
    for b in ("sick_response", "app_compliance"):
        nofit["behaviors"][b]["fitted"] = False
    nofit["worry"]["fitted"] = False
    cfg_nf = mk(base, nofit, ["personality.rates_source=calibrated"])
    new, ch = rates.adjusted(cfg_nf)
    assert ch == [] and new["population"] == cfg0["population"], ch
    assert np.array_equal(build(cfg_nf, campus).sick_profile, p0.sick_profile)
    zero = synthetic(0)
    assert rates.adjusted(mk(base, zero, ["personality.rates_source=calibrated"]))[1] == []
    print("unfitted / n=0: nothing applied")

    # run ids and outputs
    tmp = Path(tempfile.mkdtemp())
    over = {"run": {"n_agents": 30, "days": 1, "seed": 5, "initial_seeds": 2, "intervention": "fluni"}}
    none = mk(over)
    dflt = mk(over, big)
    expl = mk(over, big, ["personality.rates_source=config", "personality.rates_prior_n=5"])
    assert make_run_id(none) == make_run_id(dflt) == make_run_id(expl), "config changed the run id"
    on = mk(over, big, ["personality.rates_source=calibrated"])
    on_k = mk(over, big, ["personality.rates_source=calibrated", "personality.rates_prior_n=5"])
    assert len({make_run_id(none), make_run_id(on), make_run_id(on_k)}) == 3, "calibrated rates didn't change the run id"
    none["run"]["out_dir"], expl["run"]["out_dir"] = str(tmp / "none"), str(tmp / "expl")
    a, b = files(run(none, quiet=True)), files(run(expl, quiet=True))
    assert a.keys() == b.keys(), set(a) ^ set(b)
    diff = [k for k in a if a[k] != b[k]]
    assert not diff, f"outputs differ with rates_source config: {diff}"
    on["run"]["out_dir"] = str(tmp / "on")
    run(on, quiet=True)
    print(f"config: run id {make_run_id(none)} unchanged, {len(a)} files byte-identical; calibrated: {make_run_id(on)}")
    print("OK: fitted rates applied with shrinkage, archetype order kept, unfitted left alone, config unchanged")


if __name__ == "__main__":
    main()
