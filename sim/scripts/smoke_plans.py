"""Smoke test for campussim/plans.py.

  .venv/bin/python scripts/smoke_plans.py [--fake] [--big N] [--days D]

Builds Campus -> Population -> sections -> events -> plans (real modules; --fake uses a small
synthetic campus), prints readable day timelines for 2 agents (weekday + Saturday), times a big
run, prints aggregates and checks determinism.
"""
import argparse
import copy
import json
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from campussim import codes  # noqa: E402
from campussim.codes import ACTIVITIES, ACT, ROOM_OFF_MAP  # noqa: E402


def load_cfg(n, days):
    try:
        from campussim.config import load_config
        cfg = load_config()
    except Exception:  # diseases.json may not exist yet
        cfg = {}
        for f in sorted((ROOT / "configs").glob("*.json")):
            if f.stem != "diseases":
                cfg[f.stem] = json.loads(f.read_text())
    cfg["run"]["n_agents"] = n
    cfg["run"]["days"] = days
    return cfg


class FakeCampus:
    """Tiny synthetic campus implementing the parts of the Campus API used upstream."""
    LAYOUTS = ["seated", "mingle", "bed", "free"]

    def __init__(self):
        spec = [  # name, type, x, y, rooms [(type, n, cap)]
            ("Dorm A", "dorm", 0, 0, [("dorm_double", 40, 2), ("dorm_single", 20, 1), ("lobby", 1, 40)]),
            ("Dorm B", "dorm", 300, 0, [("dorm_double", 40, 2), ("dorm_quad", 10, 4), ("lobby", 1, 40)]),
            ("Dining", "dining", 150, 200, [("dining_room", 1, 400)]),
            ("Dining 2", "dining", 500, 300, [("dining_room", 1, 300)]),
            ("Library", "library", 400, 500, [("reading_room", 2, 120), ("study_room", 4, 8)]),
            ("Hall", "lecture_hall", 600, 600, [("lecture_hall", 3, 300)]),
            ("Classrooms", "classroom", 700, 400, [("classroom", 6, 40), ("seminar", 6, 20)]),
            ("Lab Bldg", "lab", 900, 700, [("lab", 6, 24)]),
            ("Gym", "gym", 200, 900, [("weight_room", 1, 60), ("practice_gym", 2, 80)]),
            ("Stanford Stadium", "event_venue", 100, 1200, [("arena", 1, 5000)]),
            ("Maples Pavilion", "gym", 300, 1100, [("arena", 1, 3000), ("practice_gym", 1, 60)]),
            ("Frat", "party_venue", -200, 300, [("party_room", 2, 120)]),
            ("Union", "common_room", 450, 250, [("lounge", 2, 80), ("cafe", 1, 60)]),
            ("Oval", "outdoor", 500, 700, [("outdoor_area", 1, 2000)]),
            ("Vaden", "health_center", 800, 100, [("waiting_room", 1, 20), ("exam_room", 4, 3)]),
        ]
        brows, rrows = [], []
        for b, (name, typ, x, y, rs) in enumerate(spec):
            brows.append(dict(location_id=f"bld_m_{b}", name=name, type=typ, x=float(x), y=float(y),
                              lat=0.0, lon=0.0, capacity=0, levels=3, indoor=typ != "outdoor",
                              ventilation_ach=3.0, footprint_m2=1000.0))
            k = 0
            for rt, n, cap in rs:
                for _ in range(n):
                    k += 1
                    rrows.append(dict(room_id=f"bld_m_{b}_f1_{100 + k:03d}", location_id=f"bld_m_{b}", b=b,
                                      room_type=rt, floor=1, capacity=cap, area_m2=cap * 3.0,
                                      cx=float(x), cy=float(y), layout="bed" if rt.startswith("dorm_") else "seated"))
        self.buildings = pd.DataFrame(brows)
        self.rooms = pd.DataFrame(rrows)
        self.room_b = self.rooms["b"].to_numpy()
        self.room_cap = self.rooms["capacity"].to_numpy()
        self.room_layout = np.array([self.LAYOUTS.index(v) for v in self.rooms["layout"]])
        self.b_x, self.b_y = self.buildings["x"].to_numpy(), self.buildings["y"].to_numpy()
        self.b_type = np.array([codes.LOCATION_TYPES.index(t) for t in self.buildings["type"]])
        self.entry_points = pd.DataFrame(dict(entry_id=["E0", "E1"], name=["n", "s"], x=[-500.0, 1500.0],
                                              y=[-500.0, 1500.0], lat=[0.0, 0.0], lon=[0.0, 0.0]))
        self.version = "fake"

    def buildings_of_type(self, t):
        return np.flatnonzero(self.buildings["type"].to_numpy() == t)

    def rooms_of(self, b, room_type=None):
        m = self.room_b == b
        if room_type is not None:
            m &= self.rooms["room_type"].to_numpy() == room_type
        return np.flatnonzero(m)

    def find_building(self, name):
        h = np.flatnonzero(self.buildings["name"].to_numpy() == name)
        return int(h[0]) if len(h) else -1

    def _xy(self, p):
        if p[0] == "b":
            return self.b_x[p[1]], self.b_y[p[1]]
        if p[0] == "e":
            return self.entry_points.x[p[1]], self.entry_points.y[p[1]]
        return p[1]

    def distance(self, s, d):
        (x0, y0), (x1, y1) = self._xy(s), self._xy(d)
        return float(np.hypot(x1 - x0, y1 - y0) * 1.3)


def build_all(cfg, fake, campus=None):
    from campussim.population import build_population
    from campussim.schedule import build_sections, build_events
    from campussim.plans import build_plans
    ss = np.random.SeedSequence(cfg["run"]["seed"])
    ch = dict(zip(["map", "population", "sections", "events", "plans"], ss.spawn(9)[:5]))
    if campus is None:
        if fake:
            campus = FakeCampus()
        else:
            from campussim.campus import Campus
            campus = Campus.build(cfg["map"])
    t0 = time.time()
    pop = build_population(cfg, campus, np.random.default_rng(ch["population"]))
    sections = build_sections(cfg, campus, pop, np.random.default_rng(ch["sections"]))
    events = build_events(cfg, campus, pop, sections, np.random.default_rng(ch["events"]))
    t1 = time.time()
    plans = build_plans(cfg, campus, pop, sections, events, np.random.default_rng(ch["plans"]))
    t2 = time.time()
    return campus, pop, sections, events, plans, t1 - t0, t2 - t1


def timeline(campus, pop, sections, events, plans, i, day, step):
    spd = 1440 // step
    rid = campus.rooms["room_id"].to_numpy()
    rt = campus.rooms["room_type"].to_numpy()
    bname = campus.buildings["name"].to_numpy()
    a, r, e, s = (x[i, day * spd:(day + 1) * spd] for x in (plans.act, plans.room, plans.event, plans.section))
    key = list(zip(a.tolist(), r.tolist(), e.tolist(), s.tolist()))
    out, j = [], 0
    while j < spd:
        k = j
        while k + 1 < spd and key[k + 1] == key[j]:
            k += 1
        act, room, ev, sec = key[j]
        if room == ROOM_OFF_MAP:
            where = "OFF_MAP"
        else:
            where = f"{bname[campus.room_b[room]]} / {rt[room]} ({rid[room]})"
        tag = f" ev={events['event_id'].iloc[ev]}:{events['type'].iloc[ev]}" if ev >= 0 else ""
        tag += f" sec={sections['section_id'].iloc[sec]}" if sec >= 0 else ""
        fm = lambda m: f"{m // 60:02d}:{m % 60:02d}"
        out.append(f"  {fm(j * step)}-{fm((k + 1) * step)} {ACTIVITIES[act]:<16} {where}{tag}")
        j = k + 1
    return "\n".join(out)


def aggregates(campus, pop, events, plans, cfg):
    step = cfg["run"]["step_min"]
    spd = 1440 // step
    D = cfg["run"]["days"]
    sw = cfg["run"].get("start_weekday", 0)
    N = pop.N
    act = plans.act
    hours = np.arange(act.shape[1]) * step // 60 % 24
    print("\nactivity share over run:")
    vals, cnt = np.unique(act, return_counts=True)
    print("  " + ", ".join(f"{ACTIVITIES[v]}={c / act.size:.3f}" for v, c in zip(vals, cnt)))
    wdmask = np.array([((sw + t // spd) % 7) < 5 for t in range(act.shape[1])])
    for name in ("class", "eat", "sleep", "commute"):
        m = (act == ACT[name])[:, wdmask].mean(0)
        byh = np.bincount(hours[wdmask], weights=m, minlength=24) / np.bincount(hours[wdmask], minlength=24)
        print(f"weekday {name:<8} by hour: " + " ".join(f"{int(h):02d}:{v * 100:4.1f}" for h, v in enumerate(byh)))
    party = (act == ACT["party"])
    print("party agent-steps by weekday-night (start day of evening, 18:00-04:00):")
    for d in range(D):
        lo, hi = d * spd + 18 * 60 // step, min((d + 1) * spd + 4 * 60 // step, act.shape[1])
        print(f"  day {d} ({'MTWTFSS'[(sw + d) % 7]}): {int(party[:, lo:hi].sum())}", end="")
    print()
    comm = np.asarray(pop.param("commuter"), bool)
    if comm.any():
        h3 = hours == 3
        h12 = (hours == 12) & wdmask
        off = plans.room == ROOM_OFF_MAP
        print(f"commuters off-map at 03:00: {off[comm][:, h3].mean():.3f}; weekday 12:00: {off[comm][:, h12].mean():.3f}")
        print(f"non-commuters ever off-map: {off[~comm].any()}")
    # consistency checks
    sec_steps = plans.section >= 0
    assert np.all(np.isin(act[sec_steps], [ACT["class"], ACT["lab"]])), "section set outside class/lab"
    com = act == ACT["commute"]
    assert np.all(plans.event[com] == -1) and np.all(plans.section[com] == -1)
    assert np.all((plans.room >= 0) | (act == ACT["off_campus"]) | com)
    print("checks OK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("--big", type=int, default=7500)
    ap.add_argument("--days", type=int, default=14)
    args = ap.parse_args()
    cfg = load_cfg(10, args.days)
    step = cfg["run"]["step_min"]
    campus, pop, sections, events, plans, tb, tp = build_all(cfg, args.fake)
    print(f"N=10: build {tb:.2f}s plans {tp:.2f}s shapes {plans.act.shape} {plans.act.dtype} {plans.room.dtype}")
    sw = cfg["run"].get("start_weekday", 0)
    sat = (5 - sw) % 7
    arch = np.asarray(pop.archetype)
    picks = [0, int(np.flatnonzero(arch != arch[0])[0]) if (arch != arch[0]).any() else 1]
    for i in picks:
        print(f"\nAgent {pop.agent_id[i]} ({codes.ARCHETYPES[arch[i]]}, team={pop.team_id[i]}) day 0 (weekday):")
        print(timeline(campus, pop, sections, events, plans, i, 0, step))
        print(f"Agent {pop.agent_id[i]} day {sat} (Saturday):")
        print(timeline(campus, pop, sections, events, plans, i, sat, step))
    aggregates(campus, pop, events, plans, cfg)
    _, _, _, _, plans2, _, _ = build_all(copy.deepcopy(cfg), args.fake, campus)
    same = all(np.array_equal(getattr(plans, f), getattr(plans2, f)) for f in ("act", "room", "event", "section"))
    print(f"determinism (N=10 rebuild identical): {same}")
    assert same

    if args.big:
        cfgb = load_cfg(args.big, args.days)
        _, popb, secb, evb, plansb, tb, tp = build_all(cfgb, args.fake, campus)
        print(f"\nN={args.big} days={args.days}: upstream build {tb:.1f}s, build_plans {tp:.1f}s, "
              f"plans MB={sum(getattr(plansb, f).nbytes for f in ('act', 'room', 'event', 'section')) / 1e6:.0f}")
        aggregates(campus, popb, evb, plansb, cfgb)


if __name__ == "__main__":
    main()
