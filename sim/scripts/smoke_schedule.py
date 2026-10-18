"""Smoke test for campussim/schedule.py.

python scripts/smoke_schedule.py [--n 10 7500] [--fake]
Uses the real Campus / build_population when importable (and --fake not given), else small fakes.
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
from campussim import codes, schedule  # noqa: E402

MOCK = ROOT / "runs/mock_boring10/schedule"


def load_cfg():
    try:
        from campussim.config import load_config
        return load_config()
    except Exception:  # diseases.json missing etc.
        cfg = {}
        for f in sorted((ROOT / "configs").glob("*.json")):
            if f.stem != "diseases":
                cfg[f.stem] = json.loads(f.read_text())
        return cfg


# ----------------------------------------------------------------------------- fakes
class FakeCampus:
    LAYOUTS = ["seated", "mingle", "bed", "free"]

    def __init__(self, scale=1):
        spec = [  # (name, type, [(room_type, count, cap, layout)])
            ("Gates", "classroom", [("seminar", 25 * scale, 20, "seated"), ("classroom", 20 * scale, 60, "seated")]),
            ("Hewlett", "lecture_hall", [("lecture_hall", 4 * scale, 320, "seated"), ("lecture_hall", 6 * scale, 150, "seated")]),
            ("Mudd", "lab", [("lab", 20 * scale, 24, "free")]),
            ("Green Library", "library", [("study_room", 20 * scale, 8, "seated"), ("reading_room", 2, 80, "seated")]),
            ("Stanford Stadium", "event_venue", [("arena", 1, 50000, "mingle")]),
            ("Maples Pavilion", "event_venue", [("arena", 1, 7000, "mingle")]),
            ("Memorial Hall", "event_venue", [("lecture_hall", 1, 1700, "seated")]),
            ("Tresidder", "common_room", [("lounge", 4, 40, "mingle")]),
        ]
        for k in range(4 * scale):
            spec.append((f"Row House {k}", "party_venue", [("party_room", 1, 120, "mingle"), ("lobby", 1, 30, "mingle")]))
        self.n_dorm = 6 * scale
        for k in range(self.n_dorm):
            spec.append((f"Dorm {k}", "dorm", [("lobby", 1, 40, "mingle"), ("lounge", 1, 20, "mingle"),
                                               ("dorm_double", 150, 2, "bed")]))
        b_rows, r_rows = [], []
        for b, (name, typ, rooms) in enumerate(spec):
            b_rows.append(dict(location_id=f"bld_m_{b}", name=name, type=typ))
            k = 0
            for (rt, cnt, cap, lay) in rooms:
                for _ in range(cnt):
                    k += 1
                    r_rows.append(dict(room_id=f"bld_m_{b}_f1_{100 + k:03d}", location_id=f"bld_m_{b}", b=b,
                                       room_type=rt, capacity=cap, layout=lay))
        self.buildings = pd.DataFrame(b_rows)
        self.rooms = pd.DataFrame(r_rows)
        self.room_b = self.rooms["b"].to_numpy()
        self.room_cap = self.rooms["capacity"].to_numpy()
        self.room_layout = np.array([self.LAYOUTS.index(x) for x in self.rooms["layout"]], dtype=np.int8)

    def find_building(self, name):
        m = np.flatnonzero(self.buildings["name"].to_numpy() == name)
        return int(m[0]) if len(m) else -1

    def buildings_of_type(self, t):
        return np.flatnonzero(self.buildings["type"].to_numpy() == t)

    def rooms_of(self, b, room_type=None):
        m = self.room_b == b
        if room_type is not None:
            m &= self.rooms["room_type"].to_numpy() == room_type
        return np.flatnonzero(m)


class FakePop:
    def __init__(self, cfg, campus, N, rng):
        self.N = N
        self.agent_id = [f"A{i:04d}" for i in range(N)]
        self.archetype = rng.integers(0, len(codes.ARCHETYPES), N).astype(np.int8)
        self.arch_params = cfg["population"]["archetypes"]
        dorms = campus.buildings_of_type("dorm")
        beds = np.concatenate([[r for r in campus.rooms_of(b) if campus.rooms.room_type[r] in codes.BEDROOM_TYPES]
                               for b in dorms])
        self.home_room = beds[np.arange(N) // 2 % len(beds)].astype(np.int32)
        self.home_b = campus.room_b[self.home_room].astype(np.int32)
        self.friend_group = (np.arange(N) // 5).astype(np.int32)
        self.teams = [{"name": t["sport"], "sport": t["sport"], "practice_rooms": []} for t in cfg["population"]["teams"]]
        self.team_id = np.where(self.archetype == codes.ARCHETYPES.index("athlete"),
                                rng.integers(0, len(self.teams), N), -1).astype(np.int32)
        self.fav_library = np.full(N, campus.find_building("Green Library"), dtype=np.int32)
        self.fav_common = np.full(N, campus.find_building("Tresidder"), dtype=np.int32)
        self.class_schedule = [[] for _ in range(N)]

    def param(self, name):
        return np.array([self.arch_params[codes.ARCHETYPES[a]][name] for a in self.archetype], dtype=float)


def build_world(cfg, N, fake):
    cfg = copy.deepcopy(cfg)
    cfg["run"]["n_agents"] = N
    ss = np.random.SeedSequence(cfg["run"]["seed"])
    ch = ss.spawn(9)
    if not fake:
        try:
            from campussim.campus import Campus
            from campussim.population import build_population
            t = time.time()
            campus = Campus.build(cfg["map"])
            pop = build_population(cfg, campus, np.random.default_rng(ch[1]))
            print(f"  [real campus+population built in {time.time() - t:.1f}s: B={len(campus.buildings)} R={len(campus.rooms)}]")
            return cfg, campus, pop, ch
        except Exception as e:  # noqa: BLE001
            print(f"  [real modules unavailable ({type(e).__name__}: {e}); using fakes]")
    campus = FakeCampus(scale=1 if N < 1000 else 8)
    pop = FakePop(cfg, campus, N, np.random.default_rng(ch[1]))
    return cfg, campus, pop, ch


def run_once(cfg, campus, pop, ch):
    t = time.time()
    sec = schedule.build_sections(cfg, campus, pop, np.random.default_rng(ch[2]))
    t1 = time.time()
    ev = schedule.build_events(cfg, campus, pop, sec, np.random.default_rng(ch[3]))
    t2 = time.time()
    return sec, ev, t1 - t, t2 - t1


def check(cfg, campus, pop, sec, ev):
    rooms = campus.rooms
    sizes = sec["enrolled"].map(len)
    print("  sections:", len(sec), "by kind:", sec["kind"].value_counts().to_dict(),
          "warnings:", sec.attrs.get("warnings"))
    print("  size histogram:", pd.cut(sizes, [0, 9, 20, 29, 80, 99, 300, 10**6]).value_counts().sort_index().to_dict())
    print("  room types used:", rooms.room_type.iloc[sec["r"]].value_counts().to_dict())
    over = (sizes.to_numpy() > rooms.capacity.to_numpy()[sec["r"]]).sum()
    print("  sections over room capacity:", over)
    # double booking: (r, weekday, minute) overlaps
    # real mode: two sections in the same real room at once come from ExploreCourses (cross-listed
    # courses, shared rooms) and are allowed; rooms the sim picks itself must never overlap
    real = (sec["room_name"] != "").to_numpy() if "room_name" in sec else np.zeros(len(sec), bool)
    dbl = shared = 0
    for r, g in sec.groupby("r"):
        iv = [(wd, s, e, real[j]) for j, wd_l, s, e in zip(g.index, g.weekdays, g.start_min, g.end_min) for wd in wd_l]
        for a in range(len(iv)):
            for b in range(a + 1, len(iv)):
                if iv[a][0] == iv[b][0] and iv[a][1] < iv[b][2] and iv[b][1] < iv[a][2]:
                    if iv[a][3] and iv[b][3]:
                        shared += 1
                    else:
                        dbl += 1
    print("  double-booked section pairs:", dbl, "| shared real-room pairs (cross-listings):", shared)
    assert dbl == 0
    # per-agent counts & conflicts
    lect = [[s for s in cs if sec.kind[s] != "lab"] for cs in pop.class_schedule]
    nc = pd.Series([len(x) for x in lect])
    print("  per-agent courses:", nc.value_counts().sort_index().to_dict(),
          "labs/agent:", pd.Series([len(c) - len(l) for c, l in zip(pop.class_schedule, lect)]).value_counts().sort_index().to_dict())
    conf = 0
    for cs in pop.class_schedule:
        iv = [(wd, sec.start_min[s], sec.end_min[s]) for s in cs for wd in sec.weekdays[s]]
        conf += sum(1 for a in range(len(iv)) for b in range(a + 1, len(iv))
                    if iv[a][0] == iv[b][0] and iv[a][1] < iv[b][2] and iv[b][1] < iv[a][2])
        courses = [sec.course[s] for s in cs if sec.kind[s] != "lab"]
        if not real.any():  # real classes can meet several times a week as separate sections
            assert len(courses) == len(set(courses))
    print("  agent time conflicts:", conf)
    assert conf == 0
    for i, cs in enumerate(pop.class_schedule):
        for s in cs:
            assert i in sec.enrolled[s]
    # labs taken with lecture
    for i, cs in enumerate(pop.class_schedule):
        lab_courses = {sec.course[s] for s in cs if sec.kind[s] == "lab"}
        lec_courses = {sec.course[s] for s in cs if sec.kind[s] != "lab"}
        assert lab_courses <= lec_courses
    # events
    if len(ev):
        print("  events by type:", ev["type"].value_counts().to_dict())
        piv = ev.pivot_table(index="day", columns="type", values="event_id", aggfunc="count", fill_value=0)
        print("  events by day:\n" + "\n".join("    " + l for l in piv.to_string().splitlines()))
        att = ev["attendees"].map(len)
        print("  attendees mean by type:", att.groupby(ev["type"]).mean().round(1).to_dict(),
              "max:", att.groupby(ev["type"]).max().to_dict())
        rt = rooms.room_type.to_numpy()[ev["r"].to_numpy()]
        print("  event room types:", pd.Series(list(zip(ev["type"], rt))).value_counts().sort_index().to_dict())
        # no agent in two overlapping events
        per = {}
        for s, e, a in zip(ev.start_min, ev.end_min, ev.attendees):
            for i in a:
                per.setdefault(i, []).append((s, e))
        ov = sum(1 for l in per.values() for x in range(len(l)) for y in range(x + 1, len(l))
                 if l[x][0] < l[y][1] and l[y][0] < l[x][1])
        print("  agent event overlaps:", ov)
        assert ov == 0
        assert list(ev.event_id) == [f"EV{k:05d}" for k in range(len(ev))]
        assert (ev.end_min > ev.start_min).all()
        ok_sat = not ((ev.type == "study_group") & ((cfg["run"]["start_weekday"] + ev.day) % 7 == 5)).any()
        assert ok_sat
    # CSV headers
    sf = schedule.sections_frame_for_csv(sec)
    ef = schedule.events_frame_for_csv(ev, pop)
    for f, df in (("sections.csv", sf), ("events.csv", ef)):
        mock_cols = open(MOCK / f).readline().strip().split(",")
        assert list(df.columns[:len(mock_cols)]) == mock_cols, (f, list(df.columns))
    print("  CSV header prefixes match mock. sample rows:")
    print("   ", sf.head(2).to_csv(index=False).replace("\n", "\n    ")[:600])
    if len(ef):
        print("   ", ef.head(2).to_csv(index=False).replace("\n", "\n    ")[:600])
    return sf, ef


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, nargs="+", default=[10, 7500])
    ap.add_argument("--fake", action="store_true")
    a = ap.parse_args()
    cfg = load_cfg()
    for N in a.n:
        print(f"=== N={N}")
        cfg2, campus, pop, ch = build_world(cfg, N, a.fake)
        sec, ev, ts, te = run_once(cfg2, campus, pop, ch)
        print(f"  timing: sections {ts:.2f}s events {te:.2f}s")
        sf, ef = check(cfg2, campus, pop, sec, ev)
        sched1 = [list(x) for x in pop.class_schedule]
        sec2, ev2, _, _ = run_once(cfg2, campus, pop, ch)
        same = (schedule.sections_frame_for_csv(sec2).to_csv(index=False) == sf.to_csv(index=False) and
                schedule.events_frame_for_csv(ev2, pop).to_csv(index=False) == ef.to_csv(index=False) and
                sched1 == pop.class_schedule)
        print("  deterministic:", same)
        assert same
    print("OK")


if __name__ == "__main__":
    main()
