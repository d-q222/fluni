"""Smoke test for worry state and drift (campussim/worry.py).

- mode off: run id and every output file are byte-identical to a config without worry.json.
- unit: baselines (archetype / neuroticism), bump sizes, set_measured, decay half-life, no effect at baseline.
- mode on, 300 agents, 7 days, 5 initial seeds, fluni app: on agent-steps where an agent is worried
  (excess > 0.1) and neither sick nor isolating in either run, it masks more and spends fewer steps in
  droppable optional activities than the same agent-step with worry off (same seed). Attack rates of
  both runs are printed.
"""
import copy
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim import codes  # noqa: E402
from campussim.config import load_config  # noqa: E402
from campussim.engine import make_run_id, run  # noqa: E402
from campussim.personality import TRAITS  # noqa: E402
from campussim.worry import KINDS, Worry  # noqa: E402


def files(d):
    return {p.relative_to(d).as_posix(): p.read_bytes() for p in sorted(d.rglob("*")) if p.is_file()}


def check_off(tmp):
    over = {"run": {"n_agents": 30, "days": 1, "seed": 5, "initial_seeds": 2, "intervention": "fluni"}}
    off = load_config(overrides=copy.deepcopy(over))
    none = load_config(overrides=copy.deepcopy(over))
    none.pop("worry")
    assert make_run_id(off) == make_run_id(none), "run id changed with worry off"
    off["run"]["out_dir"], none["run"]["out_dir"] = str(tmp / "off"), str(tmp / "none")
    a, b = files(run(off, quiet=True)), files(run(none, quiet=True))
    assert a.keys() == b.keys(), set(a) ^ set(b)
    diff = [k for k in a if a[k] != b[k]]
    assert not diff, f"outputs differ with worry off: {diff}"
    assert not any("worry" in k for k in a)
    print(f"off: run id {make_run_id(off)} unchanged, {len(a)} files byte-identical")


def check_unit():
    cfg = load_config(overrides={"run": {"step_min": 5}})
    c = cfg["worry"]
    arch = np.arange(12) % len(codes.ARCHETYPES)
    pop = SimpleNamespace(N=12, archetype=arch, big_five=None, agent_id=np.array([f"A{i:04d}" for i in range(12)]))
    w = Worry(cfg, pop)
    exp = np.array([c["baseline_archetype"][codes.ARCHETYPES[a]] for a in arch])
    assert np.allclose(w.baseline, exp) and np.allclose(w.level, exp)
    comp = np.linspace(0.1, 0.9, 12)
    assert np.array_equal(w.compliance(comp), comp), "compliance changed at baseline"
    assert np.array_equal(w.mask_propensity(np.arange(12), comp), comp) and not w.drop_p(np.arange(12)).any()

    l0 = w.level[0]
    w.bump(0, "own_symptoms", 0)
    j = c["jumps"]["own_symptoms"]
    assert np.isclose(w.level[0], l0 + j * (1 - l0)), w.level[0]
    l1 = w.level[1]
    w.bump([1, 1], "saw_sick", 0)   # duplicates count once
    assert np.isclose(w.level[1], l1 + c["jumps"]["saw_sick"] * (1 - l1))
    for k in KINDS:
        w.bump(2, k, 0)
    try:
        w.bump(3, "rumor", 0)
        raise AssertionError("unknown kind accepted")
    except ValueError:
        pass
    ex0 = w.excess(0)
    hl = int(round(c["half_life_days"] * 1440 / 5))
    for t in range(1, hl + 1):
        w.step(t)
    print(f"decay: excess {ex0:.4f} -> {w.excess(0):.4f} after {c['half_life_days']} days ({hl} steps)")
    assert np.isclose(w.excess(0), ex0 / 2, rtol=1e-9)
    w.step(2 * hl)   # skipped steps decay too
    assert np.isclose(w.excess(0), ex0 / 4, rtol=1e-9)
    assert w.compliance(comp)[0] > comp[0] and w.mask_propensity(np.array([0]), comp[:1])[0] > comp[0]
    w.set_measured(4, 0.9, 2 * hl)
    assert w.level[4] == 0.9
    w.set_measured(4, 1.7, 2 * hl)
    assert w.level[4] == 1.0
    df = w.frame()
    assert list(df.columns) == ["t", "agent_id", "worry", "cause"]
    assert (df.cause == "baseline").sum() == 12 and (df.cause == "measured").sum() == 2
    assert set(KINDS) <= set(df.cause) and (df.cause == "decay").any()

    b5 = np.full((12, len(TRAITS)), 0.5)
    b5[:, TRAITS.index("neuroticism")] = np.linspace(0, 1, 12)
    lo, hi = c["neuroticism_baseline"]
    w5 = Worry(cfg, SimpleNamespace(**{**vars(pop), "big_five": b5}))
    assert np.allclose(w5.baseline, lo + (hi - lo) * np.linspace(0, 1, 12))
    print(f"bumps: own_symptoms {l0:.3f} -> {l0 + j * (1 - l0):.3f}; neuroticism baseline {lo}-{hi}; frame {len(df)} rows")



def outbreak(tmp):
    over = {"run": {"n_agents": 300, "days": 7, "seed": 42, "initial_seeds": 5, "intervention": "fluni"}}
    off = load_config(overrides=copy.deepcopy(over))
    on = load_config(overrides=copy.deepcopy(over), set_args=["worry.mode=on"])
    off["run"]["out_dir"] = on["run"]["out_dir"] = str(tmp / "outbreak")
    d_off, d_on = run(off, quiet=True), run(on, quiet=True)
    assert d_off != d_on
    cols = ["t", "agent_id", "activity", "masked", "symptomatic", "isolating"]
    m = pd.read_parquet(d_on / "timeline.parquet", columns=cols).merge(
        pd.read_parquet(d_off / "timeline.parquet", columns=cols), on=["t", "agent_id"], suffixes=("_on", "_off"))
    w = pd.read_csv(d_on / "worry.csv.gz")
    base = w[w.cause == "baseline"].set_index("agent_id").worry
    w["excess"] = w.worry - w.agent_id.map(base)
    w["t"] = w.t.astype(np.int64)
    m["t"] = m.t.astype(np.int64)
    m = pd.merge_asof(m.sort_values("t"), w[["t", "agent_id", "excess"]].sort_values("t"), on="t", by="agent_id")
    well = ~(m.symptomatic_on | m.symptomatic_off | m.isolating_on | m.isolating_off)
    wor = m[(m.excess > 0.1) & well]
    drop = on["worry"]["drop_acts"]
    opt_on, opt_off = int(wor.activity_on.isin(drop).sum()), int(wor.activity_off.isin(drop).sum())
    same = wor[wor.activity_on == wor.activity_off]
    mask_on, mask_off = same.masked_on.mean(), same.masked_off.mean()
    s_on, s_off = (pd.read_json(d / "summary.json", typ="series") for d in (d_on, d_off))
    print(f"outbreak: {w.agent_id[~w.cause.isin(['baseline', 'decay'])].nunique()} agents bumped "
          f"({', '.join(f'{k} {v}' for k, v in w.cause.value_counts().items() if k != 'baseline')})")
    print(f"  worried, well agent-steps: {len(wor)} ({wor.agent_id.nunique()} agents)")
    print(f"  optional-activity steps: on {opt_on}, off {opt_off}")
    print(f"  masked (same activity): on {mask_on:.3f}, off {mask_off:.3f} ({len(same)} steps)")
    print(f"  attack rate: on {s_on['attack_rate']}, off {s_off['attack_rate']}")
    assert len(wor) > 500, "too few worried agent-steps to compare"
    assert opt_on < opt_off and mask_on > mask_off
    assert 0 < s_on["attack_rate"] <= s_off["attack_rate"] + 0.05


def main():
    tmp = Path(tempfile.mkdtemp())
    check_off(tmp)
    check_unit()
    outbreak(tmp)
    print("OK: off unchanged, bumps and half-life right, worried agents mask more and drop optional activities")


if __name__ == "__main__":
    main()
