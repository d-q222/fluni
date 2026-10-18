"""Smoke test for Big Five personalities (campussim/personality.py).

- mode off: run id and population are exactly as without personality.json.
- mode big_five, 7,500 agents: dorms / friend groups / teams unchanged; each archetype's mean
  compliance, mask propensity, honesty and sick-response shares match population.json; social_scale
  averages 1 per archetype; derived traits move with their Big Five drivers.
- a short run writes personality.csv, and Claude personas mention personality.
"""
import sys
import tempfile
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim import codes  # noqa: E402
from campussim.campus import Campus  # noqa: E402
from campussim.config import ROOT, load_config  # noqa: E402
from campussim.engine import make_run_id, run  # noqa: E402
from campussim.personality import TRAITS  # noqa: E402
from campussim.population import build_population  # noqa: E402


def build(cfg, campus):
    rngs = np.random.SeedSequence(int(cfg["run"]["seed"])).spawn(9)
    return build_population(cfg, campus, np.random.default_rng(rngs[1]))


def main():
    base = {"run": {"n_agents": 7500, "seed": 42}}
    off = load_config(overrides=base)
    no_section = load_config(overrides=base)
    no_section.pop("personality")
    assert make_run_id(off) == make_run_id(no_section), "run id changed with personality off"

    campus = Campus.build(off["map"], data_dir=ROOT / "data" / "osm")
    p0 = build(off, campus)
    p1 = build(load_config(overrides=base, set_args=["personality.mode=big_five"]), campus)
    assert p0.big_five is None and p0.social_scale is None
    for f in ("archetype", "home_room", "friend_group", "team_id", "transport"):
        assert np.array_equal(getattr(p0, f), getattr(p1, f)), f"{f} changed with big_five"

    ap = off["population"]["archetypes"]
    arch = np.asarray(p1.archetype)
    print(f"{'archetype':10} {'trait':16} {'target':>7} {'off':>7} {'big5':>7}  sd off/big5")
    for a_i, a in enumerate(codes.ARCHETYPES):
        m = arch == a_i
        for t in ("compliance", "mask_propensity", "honesty"):
            ab = ap[a][f"{t}_beta"]
            tgt = ab[0] / sum(ab)
            v0, v1 = getattr(p0, t)[m], getattr(p1, t)[m]
            print(f"{a:10} {t:16} {tgt:7.3f} {v0.mean():7.3f} {v1.mean():7.3f}  {v0.std():.3f}/{v1.std():.3f}")
            assert abs(v1.mean() - tgt) < 0.03, (a, t, v1.mean(), tgt)
        sp = np.array(ap[a]["sick_profile_p"]) / sum(ap[a]["sick_profile_p"])
        share = np.bincount(p1.sick_profile[m], minlength=3) / m.sum()
        print(f"{a:10} {'sick profile':16} {np.round(sp, 2)} -> {np.round(share, 2)}; social_scale mean "
              f"{p1.social_scale[m].mean():.2f} (range {p1.social_scale[m].min():.2f}-{p1.social_scale[m].max():.2f})")
        assert np.abs(share - sp).max() < 0.05, (a, share, sp)
        assert abs(p1.social_scale[m].mean() - 1) < 0.08, (a, p1.social_scale[m].mean())

    k = {t: i for i, t in enumerate(TRAITS)}
    within = lambda x: x - pd.Series(x).groupby(arch).transform("mean").to_numpy()  # noqa: E731
    corr = lambda t, y: float(np.corrcoef(within(p1.big_five[:, k[t]]), within(y))[0, 1])  # noqa: E731
    wsp = float(off["population"].get("sick_profile_weight", 0.5))  # undo the mix toward the drawn profile
    carry_p = (p1.sick_response_p[:, 2] - wsp * (p1.sick_profile == 2)) / (1 - wsp)
    checks = [("conscientiousness", p1.compliance, +1), ("agreeableness", p1.honesty, +1),
              ("neuroticism", p1.mask_propensity, +1), ("extraversion", p1.social_scale, +1),
              ("extraversion", carry_p, +1)]
    for t, y, sign in checks:
        r = corr(t, y)
        print(f"within-archetype corr({t}, ...) = {r:+.2f}")
        assert r * sign > 0.1, (t, r)

    tmp = Path(tempfile.mkdtemp())
    cfg = load_config(overrides={"run": {"n_agents": 30, "days": 1, "seed": 3, "out_dir": str(tmp)}},
                      set_args=["personality.mode=big_five"])
    d = run(cfg, quiet=True)
    pc = pd.read_csv(d / "personality.csv")
    assert list(pc.columns) == ["agent_id"] + TRAITS + ["social_scale"] and len(pc) == 30
    from campussim.llm_agents import LLMAgents
    pop = build(cfg, campus)
    fake = LLMAgents.__new__(LLMAgents)
    fake.pop, fake.bname = pop, campus.buildings["name"].to_numpy().astype(str)
    fake.rtype, fake.room_b = campus.rooms["room_type"].to_numpy().astype(str), np.asarray(campus.room_b)
    persona = fake._persona(0)
    print("persona:", persona)
    assert "In personality you" in persona
    print("OK: off unchanged, archetype means kept, Big Five drives the traits, personality.csv written")


if __name__ == "__main__":
    main()
