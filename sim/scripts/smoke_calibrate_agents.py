"""Smoke test for scripts/calibrate_agents.py, the calibrated-weights loader and scripts/validation_report.py.

- Writes two synthetic calibration runs (llm_events.csv + calibration_forced.csv, ~3,900 rows) from
  known coefficients, fits them, and checks every recovered coefficient is within 3.5 SE (~55 checks,
  so ~2% family-wise false alarms) and a fixed absolute tolerance of the truth; checks the unfitted traits keep their placeholders and that a
  high --min-rows flags behaviors "fitted": false.
- personality.weights_source = "calibrated" moves the trait draws toward the fitted weights (and keeps
  the archetype means); "config" leaves the run id unchanged even with behavior_calibrated loaded.
- validation_report.py on a synthetic published_rates file (test-only): flags a gap, lists
  unvalidated rates and published rates without a fit.
"""
import json
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

SIM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIM))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import calibrate_agents as ca  # noqa: E402
import validation_report as vr  # noqa: E402
from campussim import codes  # noqa: E402
from campussim.campus import Campus  # noqa: E402
from campussim.config import ROOT, load_config  # noqa: E402
from campussim.engine import make_run_id, recorded_config  # noqa: E402
from campussim.personality import TRAITS  # noqa: E402
from campussim.population import build_population  # noqa: E402

T = {t[0].upper(): t for t in TRAITS}  # O C E A N
START = datetime(2026, 1, 5)
STEP_MIN = 5

TRUE = {
    "sick": {"stay_home": {"C": 2.5, "N": 1.0, "E": -2.0}, "vaden": {"C": 1.0, "N": 2.0}},
    "sick_sev": {"stay_home": 1.5, "vaden": 2.0},
    "sick_b": {"stay_home": -0.6, "vaden": -1.6},
    "comp": {"C": 1.0, "A": 3.0, "N": 0.5}, "comp_worry": 1.5, "comp_b": 0.2,
    "comp_kind": {"isolate_until": 0.0, "wear_mask": 0.6, "leave_location": -0.4, "go_to_vaden": -0.8},
    "hon": {"A": 1.0, "C": 2.5, "E": 0.8}, "hon_b": 0.8,
    "hon_rel": {"friend": 0.0, "roommate": 0.5, "dormmate": -0.3, "teammate": 0.0, "classmate": -0.8, "stranger": -1.5},
    "inf_b": {"invite": 0.5, "warn": -0.2, "tell_sick": -0.8}, "inf_A": 2.0, "inf_E": 1.2, "inf_worry": 1.0,
    "inf_rel": {"friend": 0.0, "roommate": 0.4, "dormmate": -0.4, "teammate": 0.2, "classmate": -0.6, "stranger": -1.2},
    "jump": {"own_symptoms": 0.45, "friend_sick": 0.15, "friend_positive": 0.3, "app_alert": 0.25,
             "warning_text": 0.2, "saw_sick": 0.08},
    "half_life": 2.0, "base_c0": 0.35, "base_cN": 0.8,
    "notice": {"coughing": 0.6, "crowded_room": 0.2},
}
sig = lambda x: 1 / (1 + np.exp(-x))  # noqa: E731


def lin(w, dz):
    return sum(v * dz[T[k]] for k, v in w.items())


def make_run(d, rng, cfg, n_agents, model, sizes, with_population):
    mu = ca.archetype_means(cfg)
    fr = cfg["population"]["archetype_fractions"]
    arch = rng.choice(codes.ARCHETYPES, size=n_agents, p=np.array([fr[a] for a in codes.ARCHETYPES]))
    kappa = float(cfg["personality"]["concentration"])
    agents = []
    for i, a in enumerate(arch):
        m = np.array([mu[a][t] for t in TRAITS])
        s = rng.beta(m * kappa, (1 - m) * kappa)
        agents.append({"agent_id": f"A{i:04d}", "archetype": a, **dict(zip(TRAITS, s)),
                       "dz": {t: s[k] - m[k] for k, t in enumerate(TRAITS)}})
    rows, forced = [], []

    def row(ag, t, behavior, outcome="", value="", context="", relationship="", worry_before=None, severity="",
            worry_after=""):
        rows.append({"t": int(t), "timestamp": (START + timedelta(minutes=int(t) * STEP_MIN)).isoformat(),
                     "agent_id": ag["agent_id"], "archetype": ag["archetype"],
                     **{k: round(ag[k], 4) for k in TRAITS},
                     "compliance": "", "mask_propensity": "", "honesty": "",
                     "worry_before": "" if worry_before is None else round(worry_before, 4),
                     "worry_after": worry_after, "severity": severity, "symptomatic": int(behavior == "sick_response"),
                     "behavior": behavior, "context": context, "relationship": relationship,
                     "other_agent_id": "", "outcome": outcome, "value": value, "model": model})

    pick = lambda: agents[rng.integers(n_agents)]  # noqa: E731
    tmax = 7 * 288
    for _ in range(sizes["sick"]):
        ag, sev = pick(), rng.uniform(0.1, 1.0)
        eta = np.array([0.0] + [TRUE["sick_b"][c] + lin(TRUE["sick"][c], ag["dz"]) + TRUE["sick_sev"][c] * sev
                                for c in ("stay_home", "vaden")])
        p = np.exp(eta) / np.exp(eta).sum()
        y = ca.SICK_CLASSES[rng.choice(3, p=p)]
        hours = {"carry_on": 8, "stay_home": 1, "vaden": 2}[y] + rng.exponential(1.0)
        row(ag, rng.integers(tmax), "sick_response", y, round(hours, 2), severity=round(sev, 3))
    for _ in range(sizes["comp"]):
        ag, wb, k = pick(), rng.uniform(0.05, 0.8), rng.choice(ca.ADVICE_KINDS)
        t = rng.integers(10, tmax)
        if rng.random() < 0.5:
            forced.append({"t": int(t - rng.integers(1, 30)), "agent_id": ag["agent_id"], "kind": "app_alert", "detail": k})
        p = sig(TRUE["comp_b"] + TRUE["comp_kind"][k] + lin(TRUE["comp"], ag["dz"]) + TRUE["comp_worry"] * wb)
        row(ag, t, "app_compliance", str(int(rng.random() < p)), context=k, worry_before=wb)
    for _ in range(sizes["hon"]):
        ag, r = pick(), rng.choice(ca.RELATIONSHIPS)
        p = sig(TRUE["hon_b"] + TRUE["hon_rel"][r] + lin(TRUE["hon"], ag["dz"]))
        row(ag, rng.integers(tmax), "disclosure", str(int(rng.random() < p)), relationship=r,
            worry_before=rng.uniform(0.05, 0.8))
    for _ in range(sizes["inf"]):
        ag, r, k, wb = pick(), rng.choice(ca.RELATIONSHIPS), rng.choice(ca.MESSAGE_KINDS), rng.uniform(0.05, 0.8)
        p = sig(TRUE["inf_b"][k] + TRUE["inf_rel"][r] + TRUE["inf_A"] * ag["dz"]["agreeableness"]
                + TRUE["inf_E"] * ag["dz"]["extraversion"] + TRUE["inf_worry"] * wb)
        row(ag, rng.integers(tmax), "influence", str(int(rng.random() < p)), context=k, relationship=r, worry_before=wb)
    for _ in range(sizes["notice"]):
        cue = rng.choice(list(TRUE["notice"]))
        row(pick(), rng.integers(tmax), "notice_reaction", str(int(rng.random() < TRUE["notice"][cue])), context=cue)
    # worry: each agent's level decays toward its N baseline; measured twice a day, events in between
    lam = np.log(2) / TRUE["half_life"]
    for ag in agents[:sizes["worry_agents"]]:
        base = np.clip(TRUE["base_c0"] + TRUE["base_cN"] * ag["dz"]["neuroticism"], 0, 1)
        lvl, t = float(np.clip(base + rng.normal(0, 0.15), 0, 1)), 0.0
        while t < 7 * 24:
            dt = rng.uniform(6, 18)
            t += dt
            lvl = base + (lvl - base) * np.exp(-lam * dt / 24)
            step = int(round(t * 60 / STEP_MIN))
            if rng.random() < 0.25:
                k = rng.choice(list(TRUE["jump"]))
                before = lvl
                lvl = before + TRUE["jump"][k] * (1 - before)
                if k == "app_alert":
                    forced.append({"t": step, "agent_id": ag["agent_id"], "kind": "app_alert", "detail": "random"})
                    if rng.random() < 0.3:      # alert whose worry answer was not logged: only the forced file shows it
                        continue
                row(ag, step, "worry", value=round(float(np.clip(lvl + rng.normal(0, 0.02), 0, 1)), 4), context=k,
                    worry_before=float(np.clip(before + rng.normal(0, 0.02), 0, 1)))
            else:
                obs = round(float(np.clip(lvl + rng.normal(0, 0.02), 0, 1)), 4)
                row(ag, step, "worry", value=obs, context="measured", worry_after=obs)
    d.mkdir(parents=True)
    pd.DataFrame(rows).sort_values("t", kind="stable").to_csv(d / "llm_events.csv", index=False)
    pd.DataFrame(forced).to_csv(d / "calibration_forced.csv", index=False)
    (d / "config.json").write_text(json.dumps({"run_id": d.name, "step_min": STEP_MIN}))
    if with_population:
        pd.DataFrame([{k: a[k] for k in ["agent_id"] + TRAITS} for a in agents]).to_csv(d / "personality.csv", index=False)
        pd.DataFrame([{"agent_id": a["agent_id"], "archetype": a["archetype"]} for a in agents]).to_csv(
            d / "agents_static.csv", index=False)
    return len(rows)


def check(name, est, se, true, abs_tol, failures):
    ok = abs(est - true) <= max(3.5 * se, 0.05) and abs(est - true) <= abs_tol
    print(f"  {name:34} true {true:+7.3f}  fit {est:+7.3f} ± {se:5.3f}  {'ok' if ok else 'FAIL'}")
    if not ok:
        failures.append(name)


def main():
    tmp = Path(tempfile.mkdtemp())
    cfg = load_config()
    rng = np.random.default_rng(int(sys.argv[1]) if len(sys.argv) > 1 else 7)
    sizes = {"sick": 300, "comp": 450, "hon": 300, "inf": 330, "notice": 50, "worry_agents": 35}
    runs = [tmp / "calib_haiku_s1", tmp / "calib_opus_s2"]
    n = sum(make_run(d, rng, cfg, 300, m, sizes, i == 0)
            for i, (d, m) in enumerate(zip(runs, ["claude-haiku-4-5", "claude-opus-4-1"])))
    print(f"synthetic rows: {n}")
    out_path = tmp / "behavior_calibrated.json"
    out = ca.main([str(r) for r in runs] + ["--out", str(out_path)])
    print()

    # ---- shape
    for k in ("weights", "weights_se", "weights_fitted", "archetype_check", "n", "source_runs", "models", "created",
              "influence", "worry", "notice", "sick_severity", "behaviors"):
        assert k in out, k
    assert set(out["weights"]) == set(cfg["personality"]["weights"]), "weights shape differs from personality.json"
    assert out["source_runs"] == [r.name for r in runs]
    assert set(out["models"]) == {"claude-haiku-4-5", "claude-opus-4-1"}
    assert set(out["influence"]) >= {"b", "w_A", "w_E", "w_worry", "w_rel"}
    assert set(out["influence"]["w_rel"]) == set(ca.RELATIONSHIPS)
    for t in ("mask_propensity", "social_scale"):
        assert not out["weights_fitted"][t] and out["weights"][t] == cfg["personality"]["weights"][t], t
    for t in ("compliance", "honesty", "sick_stay_home", "sick_vaden"):
        assert out["weights_fitted"][t], t

    # ---- recovery
    fails = []
    print("recovered vs true:")
    w, se = out["weights"], out["weights_se"]
    for trait, truth in [("compliance", TRUE["comp"]), ("honesty", TRUE["hon"]),
                         ("sick_stay_home", TRUE["sick"]["stay_home"]), ("sick_vaden", TRUE["sick"]["vaden"])]:
        for k, t in T.items():
            check(f"{trait}.{t}", w[trait][t], se[trait][t], truth.get(k, 0.0), 2.5, fails)
    for c in ("stay_home", "vaden"):
        check(f"sick_severity.{c}", out["sick_severity"][c]["w"], out["sick_severity"][c]["se"], TRUE["sick_sev"][c], 1.0, fails)
    check("compliance.worry", out["worry_weights"]["compliance"]["w"], out["worry_weights"]["compliance"]["se"],
          TRUE["comp_worry"], 1.5, fails)
    cm = out["behaviors"]["app_compliance"]["model"]
    ref = cm["kind_reference"]
    for k, v in TRUE["comp_kind"].items():
        if k != ref:
            check(f"compliance.kind[{k}] - [{ref}]", cm["coef"]["1"]["kind:" + k], cm["se"]["1"]["kind:" + k],
                  v - TRUE["comp_kind"][ref], 0.8, fails)
    check("compliance.forced (true 0)", cm["coef"]["1"]["forced"], cm["se"]["1"]["forced"], 0.0, 0.6, fails)
    for r, v in TRUE["hon_rel"].items():
        if r != "friend":
            check(f"honesty.rel[{r}]", out["behaviors"]["disclosure"]["relationship"][r],
                  out["behaviors"]["disclosure"]["model"]["se"]["1"]["rel:" + r], v, 1.0, fails)
    inf = out["influence"]
    for k, v in TRUE["inf_b"].items():
        check(f"influence.b[{k}]", inf["b"][k], inf["se"]["b"][k], v, 0.8, fails)
    check("influence.w_A", inf["w_A"], inf["se"]["w_A"], TRUE["inf_A"], 2.0, fails)
    check("influence.w_E", inf["w_E"], inf["se"]["w_E"], TRUE["inf_E"], 2.0, fails)
    check("influence.w_worry", inf["w_worry"], inf["se"]["w_worry"], TRUE["inf_worry"], 1.0, fails)
    for r, v in TRUE["inf_rel"].items():
        if r != "friend":
            check(f"influence.w_rel[{r}]", inf["w_rel"][r], inf["se"]["w_rel"][r], v, 1.0, fails)
    wo = out["worry"]
    for k, v in TRUE["jump"].items():
        check(f"worry.jump[{k}]", wo["jump"][k], wo["jump_se"][k], v, 0.06, fails)
    check("worry.half_life_days", wo["half_life_days"], wo["half_life_se"], TRUE["half_life"], 0.5, fails)
    check("worry.baseline c0", wo["baseline"]["c0"], wo["baseline"]["c0_se"], TRUE["base_c0"], 0.08, fails)
    check("worry.baseline cN", wo["baseline"]["cN"], wo["baseline"]["cN_se"], TRUE["base_cN"], 0.4, fails)
    for cue, v in TRUE["notice"].items():
        check(f"notice.rate[{cue}]", out["notice"]["rate"][cue], out["notice"]["se"][cue], v, 0.2, fails)
    assert not fails, f"coefficients outside tolerance: {fails}"
    for a, e in out["archetype_check"]["app_compliance"].items():   # fitted mean rates track the observed ones
        assert abs(e["rate"]["fitted"] - e["rate"]["observed"]) < 0.05, (a, e)

    # ---- min rows: behaviors below the minimum keep placeholders, flagged
    hi = ca.main([str(r) for r in runs] + ["--out", str(tmp / "hi.json"), "--min-rows", "700", "--quiet"])
    assert not hi["behaviors"]["notice_reaction"]["fitted"] and not hi["notice"]["fitted"]
    assert hi["behaviors"]["app_compliance"]["fitted"]           # 900 rows
    assert not hi["behaviors"]["sick_response"]["fitted"] and not hi["weights_fitted"]["sick_stay_home"]
    assert hi["weights"]["sick_stay_home"] == cfg["personality"]["weights"]["sick_stay_home"]
    assert not hi["behaviors"]["disclosure"]["fitted"] and hi["weights"]["honesty"] == cfg["personality"]["weights"]["honesty"]
    print("min-rows 700: unfitted ->", [b for b, f in hi["behaviors"].items() if not f["fitted"]])

    # ---- loading in personality
    base = {"run": {"n_agents": 3000, "seed": 11}}
    cal = json.loads(out_path.read_text())
    off = load_config(overrides=base)
    off_with = load_config(overrides=base)
    off_with["behavior_calibrated"] = cal
    assert make_run_id(off) == make_run_id(off_with), "behavior_calibrated changed an off run id"
    b5 = load_config(overrides=base, set_args=["personality.mode=big_five"])
    b5.pop("behavior_calibrated", None)
    b5_with = load_config(overrides=base, set_args=["personality.mode=big_five", "personality.weights_source=config"])
    b5_with["behavior_calibrated"] = cal
    rec = recorded_config(b5_with)
    rec["personality"].pop("weights_source")
    assert rec == recorded_config(b5), "weights_source=config changed the recorded config"
    b5_default = load_config(overrides=base, set_args=["personality.mode=big_five"])
    b5_default["behavior_calibrated"] = cal
    assert make_run_id(b5_default) == make_run_id(b5), "behavior_calibrated changed a big_five run id"
    b5c = load_config(overrides=base, set_args=["personality.mode=big_five", "personality.weights_source=calibrated"])
    b5c["behavior_calibrated"] = cal
    assert make_run_id(b5c) != make_run_id(b5), "calibrated weights should change the run id"

    campus = Campus.build(off["map"], data_dir=ROOT / "data" / "osm")
    build = lambda c: build_population(c, campus, np.random.default_rng(np.random.SeedSequence(11).spawn(9)[1]))  # noqa: E731
    p0, p1 = build(b5_default), build(b5c)
    arch = np.asarray(p0.archetype)
    within = lambda x: x - pd.Series(x).groupby(arch).transform("mean").to_numpy()  # noqa: E731
    k = {t: i for i, t in enumerate(TRAITS)}
    corr = lambda p, t, y: float(np.corrcoef(within(p.big_five[:, k[t]]), within(y))[0, 1])  # noqa: E731
    assert np.array_equal(p0.big_five, p1.big_five)
    print("\ntrait draws, within-archetype corr  config -> calibrated (placeholder vs true weight)")
    for t, trait, up in [("agreeableness", "compliance", True), ("conscientiousness", "compliance", False),
                         ("conscientiousness", "honesty", True), ("agreeableness", "honesty", False)]:
        r0, r1 = corr(p0, t, getattr(p0, trait)), corr(p1, t, getattr(p1, trait))
        print(f"  corr({t}, {trait}): {r0:+.3f} -> {r1:+.3f}")
        assert (r1 > r0 + 0.03) if up else (r1 < r0 - 0.03), (t, trait, r0, r1)
    for trait in ("compliance", "honesty"):
        ab = {a: cfg["population"]["archetypes"][a][f"{trait}_beta"] for a in codes.ARCHETYPES}
        for i, a in enumerate(codes.ARCHETYPES):
            m = arch == i
            assert abs(getattr(p1, trait)[m].mean() - ab[a][0] / sum(ab[a])) < 0.03, (trait, a)
    assert np.array_equal(p0.mask_propensity, p1.mask_propensity), "unfitted trait changed"
    assert np.array_equal(p0.social_scale, p1.social_scale), "unfitted trait changed"
    # file fallback: no behavior_calibrated section -> read configs/behavior_calibrated.json (here a temp dir)
    import campussim.config as cc
    b5f = load_config(overrides=base, set_args=["personality.mode=big_five", "personality.weights_source=calibrated"])
    b5f.pop("behavior_calibrated", None)
    saved = cc.CONFIG_DIR
    cc.CONFIG_DIR = tmp
    try:
        assert np.array_equal(build(b5f).compliance, p1.compliance)
    finally:
        cc.CONFIG_DIR = saved

    # ---- validation report (synthetic published rates, test only)
    fitted = {(r["behavior"], r["context"]): r for r in
              vr.fitted_rates(cal, *vr.population([str(runs[0])], cfg), n_draws=100)}
    comp_all = fitted[("app_compliance", "")]["rate"]
    pub = [
        {"id": "T1", "behavior": "app_compliance", "context": "", "rate": round(comp_all + 0.02, 3), "ci_low": 0.4,
         "ci_high": 0.8, "population": "synthetic", "citation": "Test 2026", "url": "", "notes": "test only", "tolerance": 0.1},
        {"id": "T2", "behavior": "sick_response", "context": "stay_home", "rate": 0.99, "ci_low": 0.98, "ci_high": 1.0,
         "population": "synthetic", "citation": "Test 2026", "url": "https://example.org", "notes": "", "tolerance": 0.05},
        {"id": "T3", "behavior": "app_compliance", "context": "unknown_kind", "rate": 0.5, "ci_low": None, "ci_high": None,
         "population": "synthetic", "citation": "Test", "url": "", "notes": "", "tolerance": None},
    ]
    (tmp / "published_rates.json").write_text(json.dumps(pub))
    vfit, flagged, md_path = vr.main([str(runs[0]), str(runs[1]), "--calibrated", str(tmp / "behavior_calibrated.json"),
                                      "--published", str(tmp / "published_rates.json"), "--out", str(tmp / "validation.md"),
                                      "--draws", "100"])
    md = md_path.read_text()
    assert flagged == 1 and "OUTSIDE TOLERANCE" in md and "| T1 |" in md and "| ok |" in md
    assert "NO FIT" in md and "Unvalidated fitted rates" in md and "influence | invite" in md
    keys = {(r["behavior"], r["context"]) for r in vfit}
    assert {("sick_response", "stay_home"), ("disclosure", "roommate"), ("influence", "warn"),
            ("notice_reaction", "coughing"), ("worry", "app_alert")} <= keys
    for r in vfit:
        assert r["lo"] <= r["rate"] + 1e-9 and r["rate"] <= r["hi"] + 1e-9, r
    print(f"\nOK: coefficients recovered, unfitted traits fall back, calibrated loading moves trait draws, "
          f"config leaves run ids unchanged, validation report written ({md_path})")


if __name__ == "__main__":
    main()
