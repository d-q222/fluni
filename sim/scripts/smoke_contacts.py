"""Smoke test for campussim/contacts.py.

1. brute-force reference on random small cases (pair set, distances, tiers, flags)
2. reproduce the d2 mock's contacts.csv.gz from its timeline (fake campus from mock map/rooms.csv)
3. realistic check on Campus.build if campussim/campus.py is available
Run: .venv/bin/python scripts/smoke_contacts.py
"""
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from campussim.codes import ROOM_OFF_MAP, ROOM_TRANSIT  # noqa: E402
from campussim.contacts import COLUMNS, KEYS, contacts_frame, find_contacts  # noqa: E402

CFG = json.loads((ROOT / "configs" / "contacts.json").read_text())
MOCK = Path(__file__).resolve().parent.parent / "runs" / "mock_boring10"


def fake_campus(room_b, room_cap, room_indoor, room_floor, loc_ids=None, room_ids=None):
    R = len(room_b)
    B = int(np.max(room_b)) + 1 if R else 0
    loc_ids = loc_ids if loc_ids is not None else [f"bld_{i}" for i in range(B)]
    room_ids = room_ids if room_ids is not None else [f"room_{i}" for i in range(R)]
    return SimpleNamespace(room_b=np.asarray(room_b, np.int32), room_cap=np.asarray(room_cap),
                           room_indoor=np.asarray(room_indoor, bool),
                           room_floor=np.asarray(room_floor, np.int32),
                           buildings=pd.DataFrame({"location_id": loc_ids}),
                           rooms=pd.DataFrame({"room_id": room_ids}))


def brute(campus, room, x, y, cfg):
    N = len(room)
    out = {k: [] for k in KEYS}
    ground = cfg.get("ground_floor", 1)
    for i in range(N):
        for j in range(i + 1, N):
            if not (np.isfinite(x[i]) and np.isfinite(x[j])) or room[i] == ROOM_OFF_MAP or room[j] == ROOM_OFF_MAP:
                continue
            d = float(np.hypot(x[i] - x[j], y[i] - y[j]))
            ri, rj = room[i], room[j]
            ii = ri >= 0 and campus.room_indoor[ri]
            ij = rj >= 0 and campus.room_indoor[rj]
            fi = campus.room_floor[ri] if ri >= 0 else None
            fj = campus.room_floor[rj] if rj >= 0 else None
            same = ri >= 0 and ri == rj
            near = d < cfg["radius_m"]
            if ii and ij and fi != fj:
                near = False
            if not cfg.get("outdoor_any_floor", False) and (ii != ij):
                f_in = fi if ii else fj
                if f_in != ground:
                    near = False
            if not (near or (same and campus.room_cap[ri] <= cfg["same_room_max_capacity"])):
                continue
            bi = campus.room_b[ri] if ri >= 0 else -1
            bj = campus.room_b[rj] if rj >= 0 else -1
            out["a"].append(i); out["b"].append(j); out["dist"].append(d)
            out["tier"].append(1 if d < 1 else 2 if d < 2 else 3 if d < 5 else 4)
            out["same_room"].append(same); out["r"].append(ri if same else -1)
            out["bld"].append(bi if (bi == bj and bi >= 0) else -1)
            out["indoor"].append(ii and ij); out["wall"].append((not same) and (ii or ij))
    return {k: np.asarray(v) for k, v in out.items()}


def random_case(rng, N, R, any_floor):
    B = max(1, R // 3)
    room_b = rng.integers(0, B, R)
    room_floor = rng.integers(1, 4, R)
    room_indoor = rng.random(R) < 0.85
    room_floor[~room_indoor] = 1
    room_cap = rng.choice([2, 10, 40, 150, 151, 300], R)
    campus = fake_campus(room_b, room_cap, room_indoor, room_floor)
    room = rng.integers(0, R, N).astype(np.int32)
    u = rng.random(N)
    room[u < 0.15] = ROOM_TRANSIT
    room[u > 0.92] = ROOM_OFF_MAP
    # cluster positions so many pairs fall within 5 m; some exact-integer coords hit boundaries
    x = rng.uniform(0, 30, N)
    y = rng.uniform(0, 30, N)
    k = rng.random(N) < 0.2
    x[k] = np.round(x[k]); y[k] = np.round(y[k])
    x[room == ROOM_OFF_MAP] = np.nan
    y[room == ROOM_OFF_MAP] = np.nan
    cfg = dict(CFG, outdoor_any_floor=any_floor)
    return campus, room, x, y, cfg


def check_bruteforce(n_cases=300):
    rng = np.random.default_rng(0)
    n_pairs = 0
    for c in range(n_cases):
        N = int(rng.integers(0, 60))
        R = int(rng.integers(1, 12))
        campus, room, x, y, cfg = random_case(rng, N, R, any_floor=bool(c % 2))
        got = find_contacts(campus, room, x, y, cfg)
        ref = brute(campus, room, x, y, cfg)
        assert set(got) == set(KEYS)
        for k in KEYS:
            g, r = got[k], ref[k]
            assert len(g) == len(r), (c, k, len(g), len(r))
            if k == "dist":
                assert np.allclose(g, r, atol=1e-9), (c, k)
            else:
                assert np.array_equal(g.astype(np.int64), r.astype(np.int64)), (c, k)
        assert got["tier"].dtype == np.int8
        n_pairs += len(got["a"])
    # explicit floor array: NaN for transit, room floor otherwise -> identical result
    campus, room, x, y, cfg = random_case(rng, 50, 8, False)
    fl = np.where(room >= 0, campus.room_floor[np.maximum(room, 0)], np.nan).astype(float)
    g1, g2 = find_contacts(campus, room, x, y, cfg), find_contacts(campus, room, x, y, cfg, floor=fl)
    assert all(np.array_equal(g1[k], g2[k]) for k in KEYS)
    e = find_contacts(campus, room[:1], x[:1], y[:1], cfg)
    assert all(len(v) == 0 for v in e.values()) and e["tier"].dtype == np.int8
    f = contacts_frame(0, e, campus, ["A0000"], 300)
    assert list(f.columns) == COLUMNS and len(f) == 0
    print(f"brute-force: {n_cases} random cases OK ({n_pairs} pairs total)")


def check_mock(n_steps=None):
    tl = pd.read_csv(MOCK / "timeline.csv.gz", keep_default_na=False, dtype=str)
    mc = pd.read_csv(MOCK / "contacts.csv.gz", keep_default_na=False, dtype=str)
    rooms = pd.read_csv(MOCK / "map" / "rooms.csv", keep_default_na=False)
    blds = pd.read_csv(MOCK / "map" / "buildings.csv", keep_default_na=False)
    lid = list(blds["location_id"])
    campus = fake_campus([lid.index(l) for l in rooms["location_id"]], rooms["capacity"].to_numpy(),
                         np.ones(len(rooms), bool), rooms["floor"].to_numpy(), lid, list(rooms["room_id"]))
    rindex = {r: i for i, r in enumerate(rooms["room_id"])}
    agent_ids = sorted(tl["agent_id"].unique())
    aidx = {a: i for i, a in enumerate(agent_ids)}
    N = len(agent_ids)
    T = int(tl["t"].astype(int).max()) + 1 if n_steps is None else n_steps
    tl = tl[tl["t"].astype(int) < T]
    # mock rule = no floor separation, every same-room pair regardless of capacity
    variants = {"mock-rule (cap=inf, floors ignored)": dict(CFG, same_room_max_capacity=10**9, floor_separation_m=0.0),
                "contract default": CFG}
    print(f"mock: {T} steps, {N} agents, {len(mc[mc.t.astype(int) < T])} mock contact rows")
    for name, cfg in variants.items():
        frames = []
        for t, g in tl.groupby(tl["t"].astype(int), sort=True):
            room = np.full(N, ROOM_OFF_MAP, np.int32)
            x = np.full(N, np.nan); y = np.full(N, np.nan); fl = np.full(N, np.nan)
            ii = g["agent_id"].map(aidx).to_numpy()
            on = (g["off_map"] != "True").to_numpy()
            rid = g["room_id"].to_numpy()
            room[ii[on]] = [rindex[r] if r else ROOM_TRANSIT for r in rid[on]]
            x[ii[on]] = g["x_local_m"].to_numpy()[on].astype(float)
            y[ii[on]] = g["y_local_m"].to_numpy()[on].astype(float)
            f = g["floor"].to_numpy()[on]
            fl[ii[on]] = [float(v) if v else np.nan for v in f]
            c = find_contacts(campus, room, x, y, cfg, floor=fl)
            frames.append(contacts_frame(t, c, campus, agent_ids, 300))
        ours = pd.concat(frames, ignore_index=True)
        mine_csv = ours.to_csv(index=False, lineterminator="\n").splitlines()[1:]
        ref = mc[mc.t.astype(int) < T]
        ref_csv = ref.to_csv(index=False, lineterminator="\n").splitlines()[1:]
        k_o = set(map(tuple, ours[["t", "agent_a", "agent_b"]].astype(str).to_numpy()))
        k_m = set(map(tuple, ref[["t", "agent_a", "agent_b"]].astype(str).to_numpy()))
        same_rows = len(set(mine_csv) & set(ref_csv))
        print(f"  [{name}] ours={len(ours)} mock={len(ref)} common pairs={len(k_o & k_m)} "
              f"only-ours={len(k_o - k_m)} only-mock={len(k_m - k_o)} byte-identical rows={same_rows} "
              f"identical file={mine_csv == ref_csv}")
        if k_m - k_o:
            miss = ref[[tuple(r) in (k_m - k_o) for r in ref[["t", "agent_a", "agent_b"]].astype(str).to_numpy()]]
            print("    only-mock by (tier, room_id empty, location):",
                  miss.groupby([miss.distance_tier, miss.room_id == "", miss.location_id]).size().to_dict())
    return ours


def check_real_campus():
    try:
        from campussim.campus import Campus
        from campussim.config import load_config
        cfg = load_config()
        campus = Campus.build(cfg["map"])
    except Exception as e:  # campus.py written concurrently
        print(f"real campus: skipped ({type(e).__name__}: {e})")
        return
    rng = np.random.default_rng(1)
    N = 3000
    R = len(campus.room_b)
    room = rng.integers(0, R, N).astype(np.int32)
    x = rng.uniform(campus.room_x0[room], campus.room_x1[room])
    y = rng.uniform(campus.room_y0[room], campus.room_y1[room])
    room[:300] = ROOM_TRANSIT
    x[:300] = rng.uniform(np.min(campus.b_x), np.max(campus.b_x), 300)
    y[:300] = rng.uniform(np.min(campus.b_y), np.max(campus.b_y), 300)
    # also pile 400 agents into a few real rooms (dense rooms)
    some = rng.choice(R, 20)
    room[300:700] = rng.choice(some, 400)
    x[300:700] = rng.uniform(campus.room_x0[room[300:700]], campus.room_x1[room[300:700]])
    y[300:700] = rng.uniform(campus.room_y0[room[300:700]], campus.room_y1[room[300:700]])
    fl = np.where(room >= 0, campus.room_floor[np.maximum(room, 0)], np.nan).astype(float)
    c = find_contacts(campus, room, x, y, cfg["contacts"] if "contacts" in cfg else CFG, floor=fl)
    ids = [f"A{i:04d}" for i in range(N)]
    f = contacts_frame(0, c, campus, ids, 300)
    assert list(f.columns) == COLUMNS
    assert (c["a"] < c["b"]).all() and (np.diff(c["a"].astype(np.int64) * N + c["b"]) > 0).all()
    print(f"real campus: R={R} B={len(campus.b_x)} pairs={len(f)} tiers={np.bincount(c['tier'], minlength=5)[1:].tolist()} "
          f"same_room={int(c['same_room'].sum())} wall={int(c['wall'].sum())} indoor={int(c['indoor'].sum())}")
    print(f.head(5).to_csv(index=False))


if __name__ == "__main__":
    check_bruteforce()
    check_mock()
    check_real_campus()
