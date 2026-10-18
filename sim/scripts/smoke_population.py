"""Smoke test for campussim.population.

python scripts/smoke_population.py [--fake]   (uses the real Campus when available unless --fake)
"""
import io
import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from campussim import codes  # noqa: E402
from campussim.population import build_population, FLEX_KEYS  # noqa: E402

MOCK = Path(__file__).resolve().parent.parent / "runs/mock_boring10/agents_static.csv"


def load_cfg():
    try:
        from campussim.config import load_config
        return load_config()
    except Exception as e:  # diseases.json etc. may not exist yet
        print(f"[cfg] load_config failed ({e!r}); reading json files directly")
        cfg = {}
        for f in sorted((ROOT / "configs").glob("*.json")):
            if f.stem != "diseases":
                cfg[f.stem] = json.loads(f.read_text())
        return cfg


class FakeCampus:
    """Minimal stand-in exposing the contract attributes population.py uses."""

    def __init__(self, n_dorms=30, rooms_per_dorm=120, seed=0):
        r = np.random.default_rng(seed)
        b_rows, rooms = [], []
        types = (["dorm"] * n_dorms + ["dining"] * 8 + ["library"] * 5 + ["common_room"] * 4 + ["gym"] * 3)
        names = {n_dorms + 8 + 5 + 4: "Arrillaga Family Sports Center", n_dorms + 8 + 5 + 4 + 1: "Maples Pavilion"}
        for b, t in enumerate(types):
            b_rows.append(dict(location_id=f"bld_{1000 + b}", name=names.get(b, f"{t.title()} {b}"), type=t,
                               x=r.uniform(0, 3000), y=r.uniform(0, 3000)))
            if t == "dorm":
                for k in range(rooms_per_dorm):
                    rt = codes.BEDROOM_TYPES[k % 3]
                    rooms.append(dict(room_id=f"bld_{1000 + b}_f1_{101 + k:03d}", b=b, room_type=rt,
                                      capacity={"dorm_single": 1, "dorm_double": 2, "dorm_triple": 3}[rt]))
                rooms.append(dict(room_id=f"bld_{1000 + b}_f1_900", b=b, room_type="lobby", capacity=30))
            elif t == "gym":
                for k, rt in enumerate(["practice_gym", "weight_room", "pool"]):
                    rooms.append(dict(room_id=f"bld_{1000 + b}_f1_{101 + k}", b=b, room_type=rt, capacity=60))
            else:
                rooms.append(dict(room_id=f"bld_{1000 + b}_f1_101", b=b, room_type="generic", capacity=50))
        self.buildings = pd.DataFrame(b_rows)
        self.rooms = pd.DataFrame(rooms)
        self.room_b = self.rooms["b"].to_numpy()
        self.room_cap = self.rooms["capacity"].to_numpy()
        self.b_x = self.buildings["x"].to_numpy()
        self.b_y = self.buildings["y"].to_numpy()
        self.b_type = np.array([codes.LOCATION_TYPES.index(t) for t in self.buildings["type"]])
        self.entry_points = pd.DataFrame(dict(entry_id=[f"entry_{i:02d}" for i in range(6)],
                                              name=[f"E{i}" for i in range(6)], x=np.arange(6) * 500.0, y=0.0))

    def buildings_of_type(self, t):
        return np.flatnonzero(self.buildings["type"].to_numpy() == t)

    def rooms_of(self, b, room_type=None):
        m = self.room_b == b
        if room_type is not None:
            m &= self.rooms["room_type"].to_numpy() == room_type
        return np.flatnonzero(m)

    def find_building(self, name):
        hit = np.flatnonzero(self.buildings["name"].to_numpy() == name)
        return int(hit[0]) if len(hit) else -1


def get_campus(cfg, force_fake):
    if not force_fake:
        try:
            from campussim.campus import Campus
            c = Campus.build(cfg["map"])
            print(f"[campus] real Campus: {len(c.buildings)} buildings, {len(c.rooms)} rooms, "
                  f"{len(c.entry_points)} entry points, {len(c.buildings_of_type('dorm'))} dorms")
            return c, False
        except Exception as e:
            print(f"[campus] real Campus unavailable ({e!r}); using FakeCampus")
    return FakeCampus(), True


def fake_sections(pop, rng, n_sec=40):
    sec = pd.DataFrame({"section_id": [f"SEC_MWF_{i + 1:02d}" for i in range(n_sec)]})
    for i in range(pop.N):
        pop.class_schedule[i] = sorted(rng.choice(n_sec, size=3, replace=False).tolist())
    return sec


def csv_bytes(df):
    buf = io.StringIO()
    df.to_csv(buf, index=False, lineterminator="\n")
    return buf.getvalue()


def run(cfg, campus, n, seed=42, verbose=True):
    cfg = json.loads(json.dumps(cfg))
    cfg.setdefault("run", {})["n_agents"] = n
    ss = np.random.SeedSequence(seed).spawn(9)
    t0 = time.perf_counter()
    pop = build_population(cfg, campus, np.random.default_rng(ss[1]))
    dt = time.perf_counter() - t0
    sec = fake_sections(pop, np.random.default_rng(ss[2]))
    df = pop.to_frame(campus, sec)
    return pop, df, dt


def report(pop, df, dt, campus):
    A = np.array(codes.ARCHETYPES)
    print(f"  build time {dt:.3f}s  N={pop.N}")
    print("  archetype counts:", dict(pd.Series(A[pop.archetype]).value_counts().sort_index()))
    res = pop.home_b >= 0
    dorm_counts = pd.Series(pop.home_b[res]).value_counts()
    print(f"  residents {res.sum()} in {len(dorm_counts)} dorms (top: {dorm_counts.head(3).to_dict()}); "
          f"commuters {(~res).sum()} entry pts used {len(set(pop.entry_e[~res]))}")
    occ = pd.Series(pop.home_room[res]).value_counts()
    over = (occ.values > campus.room_cap[occ.index.values]).sum()
    print(f"  bedrooms used {len(occ)}, overfilled rooms {over}, max bed_slot {pop.bed_slot.max()}")
    gs = pd.Series(pop.friend_group).value_counts()
    same = pd.DataFrame({"g": pop.friend_group, "b": pop.home_b, "a": pop.archetype})
    dom_dorm = same.groupby("g")["b"].agg(lambda s: s.value_counts().iloc[0] / len(s)).mean()
    dom_arch = same.groupby("g")["a"].agg(lambda s: s.value_counts().iloc[0] / len(s)).mean()
    print(f"  friend groups {len(gs)} size min/mean/max {gs.min()}/{gs.mean():.1f}/{gs.max()}  "
          f"same-dorm share {dom_dorm:.2f} same-archetype share {dom_arch:.2f}")
    for a_i, a in enumerate(A):
        m = pop.archetype == a_i
        if m.any():
            print(f"    {a:9s} grp={pd.Series(pop.friend_group[m]).map(gs).mean():4.1f} "
                  f"mask={pop.mask_propensity[m].mean():.2f} comp={pop.compliance[m].mean():.2f} "
                  f"hon={pop.honesty[m].mean():.2f} app={pop.has_app[m].mean():.2f} "
                  f"share={pop.shares_location[m].mean():.2f} bike={pop.transport[m].mean():.2f} "
                  f"prof={np.bincount(pop.sick_profile[m], minlength=3) / m.sum()}")
    print(f"  has_app {pop.has_app.mean():.3f} shares_location {pop.shares_location.mean():.3f} "
          f"(share|no app = {pop.shares_location[~pop.has_app].sum()})")
    print(f"  teams {len(pop.teams)}: " + ", ".join(f"{t['sport']}={len(t['members'])}({len(t['practice_rooms'])}r)"
                                                  for t in pop.teams))
    print(f"  speed walk {pop.speed_mps[pop.transport == 0].mean():.2f} bike "
          f"{pop.speed_mps[pop.transport == 1].mean() if (pop.transport == 1).any() else float('nan'):.2f}")
    print(f"  fav_dining -1: {(pop.fav_dining < 0).sum()}, fav_library -1: {(pop.fav_library < 0).sum()}, "
          f"fav_common -1: {(pop.fav_common < 0).sum()}")


def main():
    force_fake = "--fake" in sys.argv
    cfg = load_cfg()
    campus, _ = get_campus(cfg, force_fake)
    mock_header = MOCK.read_text().splitlines()[0]

    for n in (10, 7500):
        print(f"== N={n}")
        pop, df, dt = run(cfg, campus, n)
        report(pop, df, dt, campus)
        assert csv_bytes(df).splitlines()[0] == mock_header, "header mismatch vs mock"
        assert len(df) == n and df["agent_id"].is_unique
        assert set(df["sickness_behavior_profile"]) <= set(codes.SICK_PROFILES)
        assert df["class_year"].between(2026, 2029).all()
        # param shapes
        for name in ["n_courses", "class_skip", "wake_h", "bed_h", "meal_p", "flex_weights", "party_p",
                     "import_daily_p", "sick_profile_p", "commuter", "arrive_h", "leave_h", "carry_on_intensity"]:
            v = pop.param(name)
            assert v.shape[0] == n, name
        assert pop.param("flex_weights").shape == (n, len(FLEX_KEYS))
        assert pop.param_keys("flex_weights") == FLEX_KEYS
        assert pop.param("commuter").dtype == bool
        assert ((pop.home_b < 0) == pop.param("commuter")).all()
        assert np.allclose(pop.sick_response_p.sum(1), 1)
        if n <= 10:
            print(df.to_string())
        if n == 7500:
            assert dt < 5, f"too slow: {dt:.2f}s"
        # determinism
        _, df2, _ = run(cfg, campus, n)
        assert csv_bytes(df) == csv_bytes(df2), "non-deterministic"
        _, df3, _ = run(cfg, campus, n, seed=7)
        assert csv_bytes(df) != csv_bytes(df3)
        print("  header OK, determinism OK")
    print("== N=1000 housing.assignment=spread")
    scfg = json.loads(json.dumps(cfg))
    scfg["population"]["housing"] = {"assignment": "spread"}
    pop, df, dt = run(scfg, campus, 1000)
    report(pop, df, dt, campus)
    res = pop.home_b >= 0
    per_dorm = pd.Series(pop.home_b[res]).value_counts()
    occ = pd.Series(pop.home_room[res]).value_counts()
    full = occ.values == campus.room_cap[occ.index.values]
    assert per_dorm.iloc[0] / res.sum() < 0.25, f"spread: {per_dorm.iloc[0]} of {res.sum()} in one dorm"
    assert len(per_dorm) >= min(10, len(campus.buildings_of_type("dorm")))
    assert (~full).sum() <= 1, f"spread: {(~full).sum()} partly filled bedrooms"   # only the last room drawn
    _, df2, _ = run(scfg, campus, 1000)
    assert csv_bytes(df) == csv_bytes(df2), "spread non-deterministic"
    print(f"  {len(per_dorm)} dorms, max share {per_dorm.iloc[0] / res.sum():.2f}, rooms full, determinism OK")
    print("ALL OK")


if __name__ == "__main__":
    main()
