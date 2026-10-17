"""Benchmark find_contacts (+ contacts_frame) on a synthetic daytime campus: 7,500 agents,
1,500 rooms with Zipf-ish occupancy incl. a few 200-300 person lecture halls, 800 transit, 200 outdoor.
Run: .venv/bin/python scripts/bench_contacts.py [n_calls]"""
import json
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
from campussim.codes import ROOM_TRANSIT  # noqa: E402
from campussim.contacts import contacts_frame, find_contacts  # noqa: E402
from smoke_contacts import fake_campus  # noqa: E402

CFG = json.loads((ROOT / "configs" / "contacts.json").read_text())


def build(rng, R=1500, B=150, n_transit=800, n_outdoor=200, n_room=6500):
    room_b = rng.integers(0, B, R)
    room_floor = rng.integers(1, 4, R)
    room_indoor = np.ones(R, bool)
    cap = np.clip((rng.pareto(1.2, R) * 6 + 2).astype(int), 2, 120)
    halls = rng.choice(R - 5, 6, replace=False)
    cap[halls] = rng.integers(200, 301, 6)
    out_rooms = np.arange(R - 5, R)                # 5 outdoor areas (quads)
    room_indoor[out_rooms] = False
    room_floor[out_rooms] = 1
    cap[out_rooms] = 400
    bx, by = rng.uniform(0, 2000, B), rng.uniform(0, 2000, B)
    # occupancy: halls 200-300, quads share n_outdoor, rest Zipf over remaining rooms
    occ = np.zeros(R, int)
    occ[halls] = rng.integers(200, 301, 6)
    occ[out_rooms] = n_outdoor // 5
    rest = np.setdiff1d(np.arange(R - 5), halls)
    w = 1.0 / np.arange(1, len(rest) + 1) ** 0.8
    rng.shuffle(w)
    left = n_room - occ[halls].sum()
    occ[rest] = rng.multinomial(left, w / w.sum())
    cap[rest] = np.maximum(cap[rest], occ[rest])   # never over capacity
    side = np.sqrt(cap * 2.5)                      # ~2.5 m^2 per seat
    x0 = bx[room_b] + rng.uniform(-30, 30, R)
    y0 = by[room_b] + rng.uniform(-30, 30, R)
    campus = fake_campus(room_b, cap, room_indoor, room_floor)
    room = np.repeat(np.arange(R), occ).astype(np.int32)
    s = side[room]
    x = x0[room] + rng.uniform(0, 1, len(room)) * s
    y = y0[room] + rng.uniform(0, 1, len(room)) * s
    # transit agents: along a few walkways (dense corridors)
    tx = rng.uniform(0, 2000, n_transit)
    ty = rng.choice(np.linspace(100, 1900, 12), n_transit) + rng.normal(0, 2, n_transit)
    room = np.r_[room, np.full(n_transit, ROOM_TRANSIT, np.int32)]
    x, y = np.r_[x, tx], np.r_[y, ty]
    perm = rng.permutation(len(room))
    return campus, room[perm], x[perm], y[perm]


if __name__ == "__main__":
    n_calls = int(sys.argv[1]) if len(sys.argv) > 1 else 4032
    rng = np.random.default_rng(0)
    campus, room, x, y = build(rng)
    N = len(room)
    fl = np.where(room >= 0, campus.room_floor[np.maximum(room, 0)], np.nan).astype(float)
    ids = [f"A{i:04d}" for i in range(N)]
    c = find_contacts(campus, room, x, y, CFG, floor=fl)
    print(f"N={N} pairs/step={len(c['a'])} tiers={np.bincount(c['tier'], minlength=5)[1:].tolist()} "
          f"same_room={int(c['same_room'].sum())} wall={int(c['wall'].sum())}")
    times, ftimes = [], []
    for k in range(n_calls):
        # jitter positions a little each step so the tree is rebuilt on fresh data
        xj = x + rng.normal(0, 0.3, N)
        yj = y + rng.normal(0, 0.3, N)
        t0 = time.perf_counter()
        c = find_contacts(campus, room, xj, yj, CFG, floor=fl)
        t1 = time.perf_counter()
        if k % 50 == 0:
            contacts_frame(k, c, campus, ids, 300)
            ftimes.append(time.perf_counter() - t1)
        times.append(t1 - t0)
    t = np.array(times) * 1e3
    print(f"find_contacts x{n_calls}: mean {t.mean():.2f} ms, median {np.median(t):.2f} ms, "
          f"p95 {np.percentile(t, 95):.2f} ms, total {t.sum() / 1e3:.1f} s")
    print(f"contacts_frame: mean {np.mean(ftimes) * 1e3:.1f} ms ({len(c['a'])} rows)")
