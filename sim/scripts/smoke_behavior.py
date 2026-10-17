"""Smoke test for campussim.behavior.

python scripts/smoke_behavior.py            # real pipeline if campus/population/schedule/plans import, else fakes
python scripts/smoke_behavior.py --fake     # force small fakes
python scripts/smoke_behavior.py --n 7500 --days 1   # timing at scale (real pipeline)
"""
import argparse
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from campussim import codes  # noqa: E402
from campussim.behavior import Behavior  # noqa: E402
from campussim.codes import ACT, ROOM_OFF_MAP, ROOM_TRANSIT  # noqa: E402


# ---------------------------------------------------------------------------- fakes
class FakeCampus:
    LAYOUTS = ["seated", "mingle", "bed", "free"]

    def __init__(self):
        types = ["dorm", "lecture_hall", "dining", "library", "health_center", "outdoor"]
        bx = np.array([0.0, 300.0, 150.0, 400.0, 600.0, 200.0])
        by = np.array([0.0, 100.0, 250.0, 300.0, 0.0, 120.0])
        self.buildings = pd.DataFrame({"location_id": [f"bld_{k}" for k in range(6)], "type": types,
                                       "x": bx, "y": by})
        self.b_type = np.array([codes.LOCATION_TYPES.index(t) for t in types])
        self.b_x, self.b_y = bx, by
        rows = []
        def add(b, rt, w, h, lay, fl=1):
            x0, y0 = bx[b] + 2 + 15 * sum(1 for r in rows if r["b"] == b), by[b] + 2
            rows.append(dict(room_id=f"r{len(rows)}", b=b, room_type=rt, floor=fl, x0=x0, y0=y0,
                             x1=x0 + w, y1=y0 + h, layout=lay, indoor=rt != "outdoor_area"))
        for k in range(5):
            add(0, "dorm_double", 4.0, 5.0, "bed", fl=1 + k // 3)
        add(0, "lobby", 10, 8, "mingle")
        add(1, "lecture_hall", 12, 10, "seated")
        add(1, "seminar", 6, 5, "seated", fl=2)
        add(2, "dining_room", 14, 12, "mingle")
        add(3, "reading_room", 10, 10, "seated")
        add(4, "waiting_room", 6, 6, "seated")
        add(5, "outdoor_area", 30, 30, "free")
        self.rooms = pd.DataFrame(rows)
        R = self.rooms
        self.room_b = R["b"].to_numpy(np.int32)
        self.room_floor = R["floor"].to_numpy(float)
        self.room_indoor = R["indoor"].to_numpy(bool)
        self.room_x0, self.room_y0 = R["x0"].to_numpy(float), R["y0"].to_numpy(float)
        self.room_x1, self.room_y1 = R["x1"].to_numpy(float), R["y1"].to_numpy(float)
        self.room_layout = np.array([self.LAYOUTS.index(v) for v in R["layout"]])
        self.entry_points = pd.DataFrame({"entry_id": ["E0", "E1"], "x": [-200.0, 800.0], "y": [-100.0, 400.0]})
        self.access = np.column_stack([bx + 1, by + 1])

    def buildings_of_type(self, t):
        return np.flatnonzero(self.buildings["type"].to_numpy() == t)

    def rooms_of(self, b, room_type=None):
        m = self.room_b == b
        if room_type:
            m &= self.rooms["room_type"].to_numpy() == room_type
        return np.flatnonzero(m)

    def _pt(self, p):
        k, v = p
        if k == "b":
            return self.access[v]
        if k == "e":
            return self.entry_points[["x", "y"]].to_numpy()[v]
        return np.asarray(v, float)

    def route(self, src, dst):
        a, b = self._pt(src), self._pt(dst)
        mid = np.array([a[0], b[1]])
        poly = np.vstack([a, mid, b])
        return poly, float(np.abs(a - b).sum())

    def distance(self, src, dst):
        return self.route(src, dst)[1]

    def nearest_entrance(self, b, x, y):
        return 2 * int(b)


def fake_world(n=10, days=2, step_min=5):
    cp = FakeCampus()
    spd = 1440 // step_min
    T = days * spd
    beds = cp.rooms_of(0, "dorm_double")
    home = np.array([beds[i // 2 % len(beds)] for i in range(n)], np.int32)
    commuter = np.arange(n) == n - 1
    home[commuter] = -1
    pop = SimpleNamespace(N=n, home_room=home, bed_slot=(np.arange(n) % 2).astype(np.int8),
                          friend_group=(np.arange(n) // 3).astype(np.int32),
                          speed_mps=np.where(np.arange(n) % 3 == 0, 4.5, 1.3),
                          mask_propensity=np.linspace(0.1, 0.9, n),
                          entry_e=np.where(commuter, 0, -1).astype(np.int32))
    act = np.zeros((n, T), np.int8)
    room = np.zeros((n, T), np.int32)
    ev = np.full((n, T), -1, np.int32)
    sec = np.full((n, T), -1, np.int32)
    hall, dining, read, out = cp.rooms_of(1, "lecture_hall")[0], cp.rooms_of(2)[0], cp.rooms_of(3)[0], cp.rooms_of(5)[0]
    for i in range(n):
        h = home[i] if home[i] >= 0 else ROOM_OFF_MAP
        blocks = [(0, 8, h, "sleep" if h >= 0 else "off_campus"), (8, 9, dining, "eat"), (9, 10.5, hall, "class"),
                  (10.5, 12, out, "outdoor_leisure"), (12, 13, dining, "eat"), (13, 17, read, "study"),
                  (17, 18, dining, "eat"), (18, 21, h, "relax" if h >= 0 else "off_campus"),
                  (21, 24, h, "sleep" if h >= 0 else "off_campus")]
        for d in range(days):
            prev = h
            for s, e, r, a in blocks:
                t0, t1 = d * spd + int(s * 60 / step_min), d * spd + int(e * 60 / step_min)
                act[i, t0:t1], room[i, t0:t1] = ACT[a], r
                if a == "class":
                    sec[i, t0:t1] = 0
                if r != prev and t0 > 0:  # 2 transit steps before each building change
                    act[i, t0 - 2:t0], room[i, t0 - 2:t0] = ACT["commute"], r
                    sec[i, t0 - 2:t0] = -1
                prev = r
    plans = SimpleNamespace(act=act, room=room, event=ev, section=sec)
    cfg = {"behavior": json.loads((ROOT / "configs/behavior.json").read_text()),
           "run": {"step_min": step_min, "seed": 1}}
    return cfg, cp, pop, plans


# ---------------------------------------------------------------------------- real pipeline
def real_world(n, days, seed=42):
    from campussim.campus import Campus
    from campussim.population import build_population
    from campussim.schedule import build_sections, build_events
    from campussim.plans import build_plans
    try:
        from campussim.config import load_config
        cfg = load_config(overrides={"run": {"n_agents": n, "days": days, "seed": seed}})
    except Exception:
        cfg = {f.stem: json.loads(f.read_text()) for f in sorted((ROOT / "configs").glob("*.json")) if f.stem != "diseases"}
        cfg["run"].update(n_agents=n, days=days, seed=seed)
    ss = np.random.SeedSequence(seed)
    kids = ss.spawn(9)
    rngs = {k: np.random.default_rng(c) for k, c in zip(
        ["map", "population", "sections", "events", "plans", "behavior", "disease", "reports", "intervention"], kids)}
    t0 = time.time()
    campus = Campus.build(cfg["map"], data_dir=str(ROOT / "data/osm"))
    pop = build_population(cfg, campus, rngs["population"])
    sections = build_sections(cfg, campus, pop, rngs["sections"])
    events = build_events(cfg, campus, pop, sections, rngs["events"])
    plans = build_plans(cfg, campus, pop, sections, events, rngs["plans"])
    print(f"world built in {time.time() - t0:.1f}s  N={pop.N} T={plans.act.shape[1]} R={len(campus.rooms)}")
    return cfg, campus, pop, plans, rngs["behavior"]


# ---------------------------------------------------------------------------- run + checks
def run(cfg, campus, pop, plans, rng, hooks=None, record=True):
    beh = Behavior(cfg, campus, pop, plans, rng)
    T = plans.act.shape[1]
    keys = ["room", "b", "x", "y", "floor", "indoor", "moving", "off_map", "act", "event", "section",
            "entrance", "masked", "isolating", "trip_dist"]
    buf = {k: [] for k in keys}
    sym = np.zeros(pop.N, bool)
    t0 = time.time()
    for t in range(T):
        beh.step(t, sym)
        if hooks and t in hooks:
            hooks[t](beh)
        if record:
            for k in keys:
                buf[k].append(getattr(beh, k).copy())
    el = time.time() - t0
    return beh, {k: np.array(v) for k, v in buf.items()} if record else None, el


def checks(cfg, campus, pop, plans, H, beh):
    step_s = cfg["run"]["step_min"] * 60
    room, x, y = H["room"], H["x"], H["y"]
    ok = True
    def chk(name, cond, info=""):
        nonlocal ok
        print(f"  [{'OK' if cond else 'FAIL'}] {name} {info}")
        ok &= bool(cond)
    on = room != ROOM_OFF_MAP
    chk("no NaN x/y on map", np.isfinite(x[on]).all() and np.isfinite(y[on]).all())
    chk("NaN x/y off map", np.isnan(x[~on]).all())
    inr = room >= 0
    r = np.where(inr, room, 0)
    m = 1e-6
    inside = ((x >= campus.room_x0[r] - m) & (x <= campus.room_x1[r] + m) &
              (y >= campus.room_y0[r] - m) & (y <= campus.room_y1[r] + m))
    chk("positions inside room rects", inside[inr].all(), f"({(~inside[inr]).sum()} outside)")
    chk("floor NaN unless in room", np.isnan(H["floor"][~inr]).all() and np.isfinite(H["floor"][inr]).all())
    chk("transit: b=-1, moving, commute", (H["b"][room == ROOM_TRANSIT] == -1).all() and
        H["moving"][room == ROOM_TRANSIT].all() and (H["act"][room == ROOM_TRANSIT] == ACT["commute"]).all())
    # speeds: arc length advanced on consecutive transit steps (trip_dist), excluding re-routes
    td = H["trip_dist"]
    tr = (room[1:] == ROOM_TRANSIT) & (room[:-1] == ROOM_TRANSIT) & (np.diff(td, axis=0) > 0)
    adv = np.diff(td, axis=0) / step_s
    ratio = adv[tr] / np.broadcast_to(pop.speed_mps, adv.shape)[tr]
    chk("transit arc speed == pop.speed_mps", np.allclose(ratio, 1.0) if tr.any() else True,
        f"ratio min/max {ratio.min():.4f}/{ratio.max():.4f} (n={tr.sum()})" if tr.any() else "")
    late = (room == ROOM_TRANSIT) & (plans.act.T != ACT["commute"])
    early = H["act"] == ACT["arrived_early"]
    print(f"  transit steps {int((room == ROOM_TRANSIT).sum())}, of which past plan commute window {int(late.sum())}; "
          f"arrived_early steps {int(early.sum())}")
    # entrances
    exit_steps = (room[1:] == ROOM_TRANSIT) & (room[:-1] >= 0)
    entry_steps = (room[1:] >= 0) & (room[:-1] == ROOM_TRANSIT)
    E = H["entrance"][1:]
    chk("entrance set on exit steps", (E[exit_steps] >= 0).mean() > 0.99 if exit_steps.any() else True,
        f"{(E[exit_steps] >= 0).mean() if exit_steps.any() else 1:.3f}")
    chk("entrance set on entry steps", (E[entry_steps] >= 0).mean() > 0.99 if entry_steps.any() else True,
        f"{(E[entry_steps] >= 0).mean() if entry_steps.any() else 1:.3f}")
    chk("entrance -1 elsewhere", (E[~(exit_steps | entry_steps)] == -1).all())
    # commuters off map at 03:00
    spd = 1440 // cfg["run"]["step_min"]
    comm = np.asarray(pop.home_room) < 0
    if comm.any():
        ts = np.arange(3 * spd // 24, room.shape[0], spd)
        chk("commuters off map at 03:00", (room[np.ix_(ts, np.flatnonzero(comm))] == ROOM_OFF_MAP).mean() > 0.95,
            f"{(room[np.ix_(ts, np.flatnonzero(comm))] == ROOM_OFF_MAP).mean():.3f}")
    # plan adherence
    match = (room == plans.room.T) | (room == ROOM_TRANSIT)
    print(f"  plan room adherence (room==plan or transit): {match.mean():.3f}; trips={beh.n_trips} reroutes={beh.n_reroutes}")
    acts = pd.Series(H["act"].ravel()).map(dict(enumerate(codes.ACTIVITIES))).value_counts()
    print("  activity counts:", dict(acts.head(12)))
    print(f"  masked share {H['masked'].mean():.3f}, indoor share {H['indoor'].mean():.3f}")
    return ok


def override_tests(cfg, campus, pop, plans, mkrng):
    spd = 1440 // cfg["run"]["step_min"]
    T = plans.act.shape[1]
    res = []
    dorm = np.flatnonzero(np.asarray(pop.home_room) >= 0)
    i = int(dorm[0])
    t_iso = 11 * spd // 24
    beh, H, _ = run(cfg, campus, pop, plans, mkrng(), {t_iso: lambda b: b.set_isolation(i, t_iso + spd)})
    seg = H["room"][t_iso + 1:min(t_iso + spd, T), i]
    home_i = np.flatnonzero(seg == pop.home_room[i])
    res.append(("isolate (11:00) -> goes home and stays", len(home_i) > 0 and (seg[home_i[0]:] == pop.home_room[i]).all()
                and set(seg[:home_i[0]].tolist()) <= {ROOM_TRANSIT} and H["isolating"][t_iso + 1:t_iso + spd, i].all()
                and (H["act"][t_iso + 1 + home_i[0]:t_iso + spd, i] == ACT["isolate"]).all()))
    comm = np.flatnonzero(np.asarray(pop.home_room) < 0)
    if len(comm):
        c_ = int(comm[0])
        beh, H, _ = run(cfg, campus, pop, plans, mkrng(), {t_iso: lambda b: b.set_isolation(c_, t_iso + spd)})
        seg = H["room"][t_iso + 1:min(t_iso + spd, T), c_]
        res.append(("commuter isolate -> off map", seg[-1] == ROOM_OFF_MAP and
                    (seg[np.argmax(seg == ROOM_OFF_MAP):] == ROOM_OFF_MAP).all()))
    j = int(dorm[min(1, len(dorm) - 1)])
    tv = 9 * spd // 24
    beh, H, _ = run(cfg, campus, pop, plans, mkrng(), {tv: lambda b: b.schedule_vaden(j, tv + 1, 18)})
    vr = beh.vaden_room
    reached = (H["room"][tv + 1:tv + 19, j] == vr).any()
    after = (H["room"][tv + 25:tv + 40, j] != vr).all() if vr >= 0 else True
    res.append((f"schedule_vaden -> reaches Vaden room {vr}", vr >= 0 and reached and after))
    beh, H, _ = run(cfg, campus, pop, plans, mkrng(), {tv: lambda b: b.schedule_vaden(j, tv + 1, 1)})
    res.append(("schedule_vaden (1-step window) still reaches Vaden", (H["room"][tv + 1:tv + 40, j] == vr).sum() >= 2))
    k = j
    tl = 10 * spd // 24
    beh, H, _ = run(cfg, campus, pop, plans, mkrng(), {tl: lambda b: b.leave_location(k)})
    pr = plans.room[k, tl]
    blk = np.flatnonzero(plans.room[k, tl:] != pr)
    end = tl + (blk[0] if len(blk) else T - tl)
    home = pop.home_room[k]
    tgt = home if home >= 0 else ROOM_OFF_MAP
    res.append(("leave_location -> heads home during block", pr == tgt or tgt in H["room"][tl + 1:end + 1, k]
                or ROOM_TRANSIT in H["room"][tl + 1:end, k]))
    m = int(dorm[0])
    beh, H, _ = run(cfg, campus, pop, plans, mkrng(), {0: lambda b: b.force_mask(m, spd)})
    res.append(("force_mask", H["masked"][1:spd, m].all()))
    beh, H, _ = run(cfg, campus, pop, plans, mkrng(), {0: lambda b: [b.set_carry_on(q, 0.0) for q in range(pop.N)]})
    opt = np.isin(H["act"], list(codes.OPTIONAL_ACTIVITIES))
    res.append(("carry_on(0) drops all optional acts", not opt[2:].any()))
    for name, okk in res:
        print(f"  [{'OK' if okk else 'FAIL'}] {name}")
    return all(o for _, o in res)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("--n", type=int, default=10)
    ap.add_argument("--days", type=int, default=2)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--skip-overrides", action="store_true")
    a = ap.parse_args()
    if not a.fake:
        try:
            cfg, campus, pop, plans, _ = real_world(a.n, a.days, a.seed)
            def mkrng():
                return np.random.default_rng(np.random.SeedSequence(a.seed).spawn(9)[5])
        except ImportError as e:
            print("real pipeline unavailable:", e, "-> fakes")
            a.fake = True
    if a.fake:
        cfg, campus, pop, plans = fake_world(a.n, a.days)
        def mkrng():
            return np.random.default_rng(7)
    beh, H, el = run(cfg, campus, pop, plans, mkrng(), record=True)
    T = plans.act.shape[1]
    print(f"behavior: N={pop.N} T={T}: {el:.2f}s ({el / T * 1000:.2f} ms/step; "
          f"14d x 4032 steps est {el / T * 4032:.0f}s)")
    ok = checks(cfg, campus, pop, plans, H, beh)
    beh2, H2, _ = run(cfg, campus, pop, plans, mkrng())
    det = all(np.array_equal(H[k], H2[k], equal_nan=True) for k in H)
    print(f"  [{'OK' if det else 'FAIL'}] determinism")
    ok &= det
    if not a.skip_overrides:
        ok &= override_tests(cfg, campus, pop, plans, mkrng)
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
