"""Smoke test for campussim.disease with fake campus/population/behavior objects (numpy only).

~/campus-sim/.venv/bin/python scripts/smoke_disease.py [--preset influenza]
"""
import argparse
import copy
import math
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim import codes  # noqa: E402
from campussim.config import load_config  # noqa: E402
from campussim.disease import Disease, calibration_report, infections_frame, room_exposure_frame, \
    INFECTION_COLUMNS, EXPOSURE_COLUMNS  # noqa: E402


class FakeCampus:
    def __init__(self, vol, ach, indoor):
        R = len(vol)
        self.room_vol = np.asarray(vol, float)
        self.room_ach = np.asarray(ach, float)
        self.room_indoor = np.asarray(indoor, bool)
        self.room_b = np.arange(R) // 4
        B = int(self.room_b.max()) + 1
        self.buildings = pd.DataFrame({"location_id": [f"bld_{b}" for b in range(B)]})
        self.rooms = pd.DataFrame({"room_id": [f"bld_{b}_f1_{100 + r:03d}" for r, b in enumerate(self.room_b)]})


class FakePop:
    def __init__(self, N, import_p=0.0):
        self.N = N
        self.agent_id = [f"A{i:04d}" for i in range(N)]
        self._imp = np.full(N, import_p)

    def param(self, name):
        assert name == "import_daily_p"
        return self._imp


class FakeBeh:
    def __init__(self, N):
        self.room = np.full(N, codes.ROOM_OFF_MAP, np.int32)
        self.b = np.full(N, -1, np.int32)
        self.masked = np.zeros(N, bool)
        self.off_map = np.ones(N, bool)
        self.act = np.full(N, codes.ACT["class"], np.int8)

    def put(self, idx, r, campus, act=None):
        self.room[idx] = r
        self.b[idx] = campus.room_b[r]
        self.off_map[idx] = False
        if act is not None:
            self.act[idx] = codes.ACT[act]


def no_contacts():
    z = np.zeros(0, np.int64)
    return dict(a=z, b=z, dist=np.zeros(0), tier=z, same_room=np.zeros(0, bool), r=z, bld=z,
                indoor=np.zeros(0, bool), wall=np.zeros(0, bool))


def make_peak_source(dis, i, t):
    """Force agent i to be symptomatic at peak (infectiousness ~1 for a long time)."""
    dis.state[i] = codes.I_SYM
    dis.t_infected[i] = t - 10
    dis.t_infectious[i] = t - 5
    dis.t_onset[i] = t
    dis.t_end[i] = t + 10 ** 7
    dis.mult[i] = 1.0
    dis.asym[i] = False
    dis.peak_sev[i] = 0.6


def test_timeline(cfg):
    print("\n== single infected agent timeline ==")
    campus = FakeCampus([54.0], [2.0], [True])
    dis = Disease(cfg, campus, FakePop(1), np.random.default_rng(1))
    dis.seed_initial(1, 0)
    beh = FakeBeh(1)
    beh.put([0], 0, campus, "relax")
    spd = dis.spd
    print(f"  t_infectious={dis.t_infectious[0] / spd:.2f}d onset={dis.t_onset[0] / spd:.2f}d "
          f"end={dis.t_end[0] / spd:.2f}d asym={dis.asym[0]} mult={dis.mult[0]:.2f} peak_sev={dis.peak_sev[0]:.2f}")
    events = []
    for t in range(12 * spd):
        ev = dis.step(t, beh, no_contacts())
        if len(ev["onset"]):
            events.append(("onset", t))
        if len(ev["recovered"]):
            events.append(("recovered", t))
        if t % (spd // 2) == 0:
            print(f"  day {t / spd:4.1f}: {codes.DISEASE_STATES[dis.state[0]]:6s} inf={dis.infectiousness[0]:.4f} "
                  f"sev={dis.severity[0]:.3f} dsi={dis.days_since_infection(t)[0]:.3f} conc={dis.room_conc[0]:.5f}")
    print("  events:", events)
    assert dis.state[0] == codes.R
    assert np.isnan(Disease(cfg, campus, FakePop(1), np.random.default_rng(1)).days_since_infection(5)[0])


def test_aerosol(cfg, n_sus=4000):
    print("\n== aerosol: 1 peak source + susceptibles in a 1-h seminar (144 m3, 4 ACH) ==")
    cfg = copy.deepcopy(cfg)
    campus = FakeCampus([144.0], [4.0], [True])
    N = 1 + n_sus
    dis = Disease(cfg, campus, FakePop(N), np.random.default_rng(2))
    beh = FakeBeh(N)
    beh.put(np.arange(N), 0, campus, "class")
    make_peak_source(dis, 0, 0)
    Hsum = 0.0
    steps = int(round(60 / dis.step_min))
    for t in range(steps):
        dis._progress(t)
        Hsum += dis._aerosol(t, beh)[1]  # deterministic hazard of a susceptible
    analytic = calibration_report(cfg, verbose=False)["seminar_H_aero"]
    print(f"  integrated H_aero={Hsum:.5f} analytic={analytic:.5f}")
    assert abs(Hsum - analytic) < 1e-5 * analytic
    # Monte Carlo with draws
    dis = Disease(cfg, campus, FakePop(N), np.random.default_rng(3))
    make_peak_source(dis, 0, 0)
    for t in range(steps):
        dis.step(t, beh, no_contacts())
    frac = (dis.state[1:] != codes.S).mean()
    p = 1 - math.exp(-analytic)
    se = math.sqrt(p * (1 - p) / n_sus)
    print(f"  MC attack={frac:.4f} expected={p:.4f} (+-{se:.4f})")
    assert abs(frac - p) < 4 * se + 1e-9
    routes = {r["route"] for r in dis.infections}
    assert routes <= {"aerosol"} and all(r["infector"] == 0 for r in dis.infections)
    assert all(abs(r["contribution"] - 1.0) < 1e-9 for r in dis.infections)
    # masks
    dis = Disease(cfg, campus, FakePop(N), np.random.default_rng(3))
    make_peak_source(dis, 0, 0)
    beh.masked[:] = True
    Hm = 0.0
    for t in range(steps):
        dis._progress(t)
        Hm += dis._aerosol(t, beh)[1]
    beh.masked[:] = False
    m = cfg["disease"]["masks"]
    print(f"  masked both: H ratio={Hm / Hsum:.4f} expected={(1 - m['source_eff']) * (1 - m['wearer_eff']):.4f}")
    assert abs(Hm / Hsum - (1 - m["source_eff"]) * (1 - m["wearer_eff"])) < 1e-9


def test_close(cfg, n_sus=4000):
    print("\n== close contact: 1 peak source, susceptibles at tier 2 for 1 h (aerosol off) ==")
    cfg = copy.deepcopy(cfg)
    cfg["disease"]["aerosol"]["quanta_per_hour_peak"] = 0.0
    cfg["disease"]["transmission_scale"] = 10.0
    for indoor in (True, False):
        campus = FakeCampus([144.0], [4.0], [indoor])
        N = 1 + n_sus
        dis = Disease(cfg, campus, FakePop(N), np.random.default_rng(4))
        beh = FakeBeh(N)
        beh.put(np.arange(N), 0, campus, "class")
        make_peak_source(dis, 0, 0)
        nb = np.arange(1, N)
        con = dict(a=np.zeros(n_sus, np.int64), b=nb, dist=np.full(n_sus, 1.5), tier=np.full(n_sus, 2),
                   same_room=np.ones(n_sus, bool), r=np.zeros(n_sus, np.int64), bld=np.zeros(n_sus, np.int64),
                   indoor=np.full(n_sus, indoor), wall=np.zeros(n_sus, bool))
        steps = int(round(60 / dis.step_min))
        for t in range(steps):
            dis.step(t, beh, con)
        dc = cfg["disease"]
        H = dc["transmission_scale"] * dc["close_hazard_per_min"]["tier2"] * 60 * (1 if indoor else dc["outdoor_multiplier"])
        p = 1 - math.exp(-H)
        frac = (dis.state[1:] != codes.S).mean()
        se = math.sqrt(p * (1 - p) / n_sus)
        print(f"  indoor={indoor}: MC attack={frac:.4f} expected={p:.4f} (+-{se:.4f})")
        assert abs(frac - p) < 4 * se
        assert all(r["route"] == "close" and r["infector"] == 0 and abs(r["contribution"] - 1) < 1e-9
                   for r in dis.infections)
    # wall pairs and tier 4 ignored
    con["wall"][:] = True
    dis = Disease(cfg, campus, FakePop(N), np.random.default_rng(4))
    make_peak_source(dis, 0, 0)
    dis._progress(0)
    assert dis._close(beh, con)[0].sum() == 0
    con["wall"][:] = False
    con["tier"][:] = 4
    assert dis._close(beh, con)[0].sum() == 0
    print("  wall=True / tier 4 pairs ignored: ok")


def test_attribution(cfg):
    print("\n== aerosol attribution: ledger vs dense totals, departed sources ==")
    cfg = copy.deepcopy(cfg)
    cfg["disease"]["transmission_scale"] = 30.0  # get many infections
    campus = FakeCampus([60.0, 200.0, 30.0, 80.0], [1.0, 3.0, 0.5, 2.0], [True, True, True, False])
    N = 3 + 3000
    dis = Disease(cfg, campus, FakePop(N), np.random.default_rng(5))
    beh = FakeBeh(N)
    beh.put(np.arange(N), 0, campus, "relax")
    for i, m in enumerate([1.0, 0.5, 2.0]):
        make_peak_source(dis, i, 0)
        dis.mult[i] = m
    steps = 36
    max_err = 0.0
    for t in range(steps):
        if t == 12:  # source 2 (strongest) leaves to room 1; source 1 goes outdoors
            beh.put([2], 1, campus)
            beh.put([1], 3, campus)
        dis.step(t, beh, no_contacts())
        for r in range(campus.room_vol.size):
            s, c = dis.ledger_contrib(t, r)
            max_err = max(max_err, abs(c.sum() - dis._cavg[r]))
    print(f"  max |sum(ledger) - dense mean conc| = {max_err:.2e}")
    assert max_err < 1e-9
    aer = [r for r in dis.infections if r["route"] == "aerosol"]
    late = [r for r in aer if r["t"] >= 12 and r["r"] == 0]
    from collections import Counter
    print(f"  aerosol infections={len(aer)}; after t=12 in room 0 by infector: {dict(Counter(r['infector'] for r in late))}")
    assert any(r["infector"] == 2 for r in late), "departed source should still get attributed"
    assert all(r["r"] != 3 for r in aer), "no aerosol in outdoor room"
    assert all(0 < r["contribution"] <= 1 + 1e-9 for r in dis.infections)
    # contributions: single route -> sum over sources of shares = 1
    t, r = 20, 0
    s, c = dis.ledger_contrib(t, r)
    print(f"  room 0 shares at t={t}: " + ", ".join(f"src{a}={b / c.sum():.3f}" for a, b in zip(s, c)))
    fr = infections_frame(dis, campus, FakePop(N))
    assert list(fr.columns) == INFECTION_COLUMNS
    rows = dis.room_exposure_rows(steps - 1, beh)
    ex = room_exposure_frame(steps - 1, rows, campus)
    assert list(ex.columns) == EXPOSURE_COLUMNS and ex["room_id"].is_monotonic_increasing
    print(fr.head(4).to_csv(index=False), end="")
    print(ex.to_csv(index=False), end="")


def test_imports(cfg):
    print("\n== imports ==")
    campus = FakeCampus([50.0], [2.0], [True])
    N = 20000
    p_day = 0.01
    dis = Disease(cfg, campus, FakePop(N, p_day), np.random.default_rng(6))
    beh = FakeBeh(N)
    for t in range(dis.spd):
        dis.step(t, beh, no_contacts())
    frac = (dis.state != codes.S).mean()
    se = math.sqrt(p_day * (1 - p_day) / N)
    print(f"  1-day import fraction={frac:.4f} expected={p_day} (+-{se:.4f})")
    assert abs(frac - p_day) < 4 * se
    fr = infections_frame(dis, campus, FakePop(N))
    assert (fr["infector_id"] == "IMPORT").all() and (fr["route"] == "import").all()
    assert (fr["location_id"] == "").all() and (fr["room_id"] == "").all()


def build_big(cfg, seed, N=7500, R=3000, n_inf=300, n_pairs=5000):
    campus = FakeCampus(np.random.default_rng(0).uniform(30, 2000, R), np.full(R, 3.0),
                        np.arange(R) % 20 != 0)
    dis = Disease(cfg, campus, FakePop(N, 0.002), np.random.default_rng(seed))
    g = np.random.default_rng(seed + 100)
    src = g.choice(N, n_inf, replace=False)
    for i in src:
        make_peak_source(dis, i, 0)
        dis.t_end[i] = 10 ** 6
        dis.mult[i] = g.gamma(1.0)
    beh = FakeBeh(N)
    beh.put(np.arange(N), g.integers(0, R, N), campus, "class")
    beh.off_map[g.random(N) < 0.1] = True
    beh.room[beh.off_map] = codes.ROOM_OFF_MAP
    beh.masked[:] = g.random(N) < 0.2

    def contacts_at(t):
        gg = np.random.default_rng(1000 + t)
        a = gg.integers(0, N, n_pairs)
        b = gg.integers(0, N, n_pairs)
        lo, hi = np.minimum(a, b), np.maximum(a, b)
        keep = lo != hi
        lo, hi = lo[keep], hi[keep]
        n = len(lo)
        tier = gg.integers(1, 5, n)
        return dict(a=lo, b=hi, dist=gg.uniform(0, 6, n), tier=tier, same_room=np.ones(n, bool),
                    r=beh.room[lo].astype(np.int64), bld=beh.b[lo].astype(np.int64),
                    indoor=gg.random(n) < 0.9, wall=gg.random(n) < 0.1)
    return dis, beh, contacts_at, campus


def test_perf_and_determinism(cfg):
    print("\n== perf (N=7500, ~300 infectious, 5000 pairs/step) + determinism ==")
    steps = 288
    outs = []
    for rep in range(2):
        dis, beh, contacts_at, campus = build_big(cfg, seed=7)
        cons = [contacts_at(t) for t in range(steps)]
        g = np.random.default_rng(77)
        moves = [g.integers(0, campus.room_vol.size, 300) for _ in range(steps)]
        movers = [g.choice(7500, 300, replace=False) for _ in range(steps)]
        tt = 0.0
        tex = 0.0
        for t in range(steps):
            on = ~beh.off_map[movers[t]]
            beh.room[movers[t][on]] = moves[t][on]
            t0 = time.perf_counter()
            dis.step(t, beh, cons[t])
            t1 = time.perf_counter()
            room_exposure_frame(t, dis.room_exposure_rows(t, beh), campus)
            tex += time.perf_counter() - t1
            tt += t1 - t0
        n_inf = int(np.isin(dis.state, codes.INFECTIOUS_STATES).sum())
        print(f"  rep {rep}: step {1000 * tt / steps:.2f} ms/step, exposure rows+frame {1000 * tex / steps:.2f} ms/step; "
              f"infections={len(dis.infections)} infectious_now={n_inf} ledger={len(dis._led_key)}")
        outs.append((infections_frame(dis, campus, FakePop(7500)).to_csv(index=False), dis.state.tobytes(),
                     dis.room_conc.tobytes()))
    assert outs[0] == outs[1], "non-deterministic"
    print("  determinism: identical infections.csv, state, room_conc")
    assert 1000 * tt / steps < 10, "too slow"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", default="influenza")
    args = ap.parse_args()
    for p in ("influenza", "covid19", "norovirus"):
        print()
        calibration_report(load_config(p))
    cfg = load_config(args.preset)
    test_timeline(cfg)
    test_aerosol(cfg)
    test_close(cfg)
    test_attribution(cfg)
    test_imports(cfg)
    test_perf_and_determinism(cfg)
    print("\nOK")


if __name__ == "__main__":
    main()
