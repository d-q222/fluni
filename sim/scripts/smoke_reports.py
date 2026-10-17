"""Smoke test for campussim/reports.py + campussim/interventions.py using fake pop/beh/disease.

Run: .venv/bin/python scripts/smoke_reports.py
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim import codes  # noqa: E402
from campussim.config import load_config  # noqa: E402
from campussim.interventions import (REGISTRY, Action, apply_actions, build_observable)  # noqa: E402
from campussim.reports import REPORT_COLUMNS, Reports, reports_frame  # noqa: E402

VADEN_B = 7


class FakeCampus:
    def buildings_of_type(self, name):
        return np.array([VADEN_B] if name == "health_center" else [], dtype=int)


class FakePop:
    def __init__(self, N, honesty=0.8, has_app=True, compliance=0.8, resp_p=(0.5, 0.3, 0.2)):
        self.N = N
        self.agent_id = [f"A{i:04d}" for i in range(N)]
        self.honesty = np.full(N, honesty)
        self.has_app = np.full(N, has_app)
        self.compliance = np.full(N, compliance)
        self._resp = np.tile(np.asarray(resp_p, float), (N, 1))

    def param(self, name):
        if name == "sick_profile_p":
            return self._resp
        if name == "carry_on_intensity":
            return np.full(self.N, 0.5)
        raise KeyError(name)


class FakeBeh:
    """Records override calls; 'goes' to Vaden during scheduled windows."""
    def __init__(self, N):
        self.N = N
        self.calls = []
        self.x = np.zeros(N)
        self.y = np.zeros(N)
        self.room = np.zeros(N, dtype=np.int32)
        self.b = np.zeros(N, dtype=np.int32)
        self.off_map = np.zeros(N, dtype=bool)
        self.vaden = {}

    def set_isolation(self, i, until_t): self.calls.append(("iso", i, until_t))
    def end_isolation(self, i): self.calls.append(("end_iso", i))
    def set_carry_on(self, i, x): self.calls.append(("carry", i, x))
    def leave_location(self, i): self.calls.append(("leave", i))
    def force_mask(self, i, until_t): self.calls.append(("mask", i, until_t))

    def schedule_vaden(self, i, start, n):
        self.calls.append(("vaden", i, start, n))
        self.vaden[i] = (start, start + n)

    def step(self, t):
        self.b[:] = 0
        for i, (s, e) in self.vaden.items():
            if s <= t < e:
                self.b[i] = VADEN_B


class FakeDisease:
    def __init__(self, N):
        self.state = np.zeros(N, dtype=np.int8)
        self.severity = np.zeros(N)
        self.infectiousness = np.zeros(N)

    @property
    def symptomatic(self):
        return self.state == codes.I_SYM


def no_contacts():
    e = np.zeros(0, dtype=np.int64)
    return {"a": e, "b": e, "same_room": e.astype(bool)}


def run_scripted(N=2000, T=None, seed=1, honesty=0.8, sens_override=None, contacts_fn=None,
                 infect_frac=0.5, false_daily=None):
    cfg = load_config()
    spd = 1440 // cfg["run"]["step_min"]
    T = T or 6 * spd
    if sens_override:
        cfg["reports"]["test"].update(sens_override)
    if false_daily is not None:
        cfg["reports"]["self_report"]["false_sick_daily_p"] = false_daily
    pop, beh, dis = FakePop(N, honesty=honesty), FakeBeh(N), FakeDisease(N)
    rep = Reports(cfg, FakeCampus(), pop, np.random.default_rng(seed))
    sick = np.arange(int(N * infect_frac))
    onset_t, rec_t = 10, 4 * spd
    for t in range(T):
        beh.step(t)
        ev = {"onset": np.array([], int), "recovered": np.array([], int)}
        if t == onset_t:
            dis.state[sick] = codes.I_SYM
            dis.severity[sick] = 0.6
            ev["onset"] = sick
        if t == rec_t:
            dis.state[sick] = codes.R
            dis.severity[sick] = 0
            ev["recovered"] = sick
        c = contacts_fn(t, dis) if contacts_fn else no_contacts()
        rep.step(t, dis, beh, c, ev)
    return cfg, pop, beh, dis, rep


def main():
    ok = True

    def check(cond, msg):
        nonlocal ok
        print(("PASS " if cond else "FAIL ") + msg)
        ok &= bool(cond)

    # 1) response distribution
    cfg, pop, beh, dis, rep = run_scripted()
    n = int(pop.N * 0.5)
    resp = rep.response[:n]
    frac = np.bincount(resp, minlength=3) / n
    check(np.allclose(frac, [0.5, 0.3, 0.2], atol=0.04), f"response distribution {frac.round(3)} ~ [0.5,0.3,0.2]")
    kinds = {c[0] for c in beh.calls}
    check({"iso", "vaden", "carry", "end_iso"} <= kinds, f"beh calls used: {sorted(kinds)}")
    # Vaden slots inside opening hours (start Monday)
    spd = 1440 // cfg["run"]["step_min"]
    bad = 0
    for c in beh.calls:
        if c[0] == "vaden":
            d, m = divmod(c[2], spd)
            wd = (cfg["run"]["start_weekday"] + d) % 7
            oh = cfg["reports"]["vaden"]["open_hours"][wd]
            mins = m * cfg["run"]["step_min"]
            bad += (not oh) or mins < oh[0] * 60 or mins + c[3] * cfg["run"]["step_min"] > oh[1] * 60
    check(bad == 0, "all Vaden visits within opening hours")

    # 2) tests: sensitivity / specificity
    df = reports_frame(rep.events, pop)
    tr = df[df.event == "test_result"]
    taken = df[df.event == "test_taken"]
    check((taken.value == "pending").all() and (tr.truthful == "").all(), "test_taken pending, truthful '' for tests")
    pos_rate = (tr.value == "positive").mean()
    check(abs(pos_rate - 0.7) < 0.06, f"empirical sensitivity {pos_rate:.3f} ~ 0.7 (n={len(tr)})")
    delay = (tr.set_index("agent_id").t - taken.set_index("agent_id").t).dropna()
    check((delay == 4 * 60 // cfg["run"]["step_min"]).all(), "test result delay = 4 h")
    check(rep.n_missed_tests == 0, "no missed Vaden tests with presence")
    # specificity: healthy agents forced to Vaden via intervention go_to_vaden
    cfg2 = load_config()
    N = 4000
    pop2, beh2, dis2 = FakePop(N, compliance=1.0), FakeBeh(N), FakeDisease(N)
    rep2 = Reports(cfg2, FakeCampus(), pop2, np.random.default_rng(5))
    acts = {i: [Action("go_to_vaden")] for i in range(N)}
    strs = apply_actions(acts, beh2, pop2, np.random.default_rng(6), 0, reports=rep2)
    check(all(s == "go_to_vaden" for s in strs), "go_to_vaden applied")
    for t in range(3 * spd):
        beh2.step(t)
        rep2.step(t, dis2, beh2, no_contacts(), {})
    tr2 = reports_frame(rep2.events, pop2)
    tr2 = tr2[tr2.event == "test_result"]
    fp = (tr2.value == "positive").mean()
    check(len(tr2) == N and abs(fp - 0.02) < 0.01, f"empirical false-positive rate {fp:.4f} ~ 0.02 (n={len(tr2)})")
    ts = np.bincount(rep2.test_status, minlength=4)
    check(ts[1] == 0 and ts[2] + ts[3] == N, f"test_status pending->positive/negative {ts.tolist()}")

    # 3) honesty extremes
    _, popH, _, _, repH = run_scripted(N=600, honesty=1.0, false_daily=0.5)
    dH = reports_frame(repH.events, popH)
    sr = dH[dH.event == "self_report"]
    check((sr.value == "withheld").sum() == 0, "honesty=1: no withheld reports")
    check((sr.truthful == "False").sum() == 0, "honesty=1: no false self-reports")
    _, popL, _, _, repL = run_scripted(N=600, honesty=0.0, false_daily=0.5)
    dL = reports_frame(repL.events, popL)
    sr = dL[dL.event == "self_report"]
    sick_ids = set(popL.agent_id[:300])
    wh = sr[sr.value == "withheld"]
    check(len(wh) >= 300 and set(wh.agent_id) == sick_ids and (wh.truthful == "False").all(),
          f"honesty=0: every sick agent withholds ({len(wh)} withheld)")
    fs = sr[(sr.value == "might_be_sick") & (sr.truthful == "False")]
    check(len(fs[~fs.agent_id.isin(sick_ids)]) > 50,
          f"honesty=0: false sick reports by healthy agents ({len(fs)})")
    check((sr[(sr.value == "might_be_sick") & sr.agent_id.isin(sick_ids)].truthful != "True").all(),
          "honesty=0: no truthful sick reports")
    statuses = sorted(set(sr.value))
    print("   self_report values (honesty=0):", statuses)
    print("   self_report values (honesty=1):", sorted(set(dH[dH.event == 'self_report'].value)))

    # 4) report_other via same-room contacts (agent 1 roommate of sick agent 0; 3 roommate of healthy 2)
    def contacts_fn(t, dis):
        return {"a": np.array([0, 2]), "b": np.array([1, 3]), "same_room": np.array([True, True])}
    cfgR = load_config()
    cfgR["reports"]["report_other"].update(p_per_step=0.05, false_p_per_step=0.01)
    popR, behR, disR = FakePop(4, honesty=0.0), FakeBeh(4), FakeDisease(4)
    repR = Reports(cfgR, FakeCampus(), popR, np.random.default_rng(3))
    for t in range(4 * spd):
        ev = {}
        if t == 5:
            disR.state[0] = codes.I_SYM
            disR.severity[0] = 0.8
            ev = {"onset": np.array([0])}
        repR.step(t, disR, behR, contacts_fn(t, disR), ev)
    dR = reports_frame(repR.events, popR)
    ro = dR[dR.event == "report_other"]
    print(ro.to_string(index=False))
    check(((ro.agent_id == "A0001") & (ro.target_agent_id == "A0000") & (ro.truthful == "True")).any(),
          "report_other: roommate flags symptomatic agent, truthful True")
    check((ro[ro.target_agent_id.isin(["A0002", "A0003"])].truthful == "False").all()
          and ro.target_agent_id.isin(["A0002", "A0003"]).any(), "report_other: false reports on healthy targets")

    # 5) d2 header + formatting
    check(list(df.columns) == REPORT_COLUMNS, f"d2 header {list(df.columns)}")
    check(set(df.truthful) <= {"True", "False", ""}, "truthful values True/False/''")
    check(df.equals(df.sort_values(["t", "agent_id"], kind="mergesort").reset_index(drop=True)), "sorted (t, agent_id)")
    check(list(reports_frame([], pop).columns) == REPORT_COLUMNS, "empty frame has d2 header")
    print(df.head(8).to_csv(index=False))

    # 6) oracle guard
    beh3, dis3 = FakeBeh(10), FakeDisease(10)
    dis3.state[2] = codes.I_SYM
    rep3 = Reports(load_config(), FakeCampus(), FakePop(10), np.random.default_rng(0))
    ctx = {"cfg": load_config(), "n_agents": 10, "step_min": 5}
    for name, cls in REGISTRY.items():
        iv = cls()
        iv.reset(ctx)
        obs = build_observable(0, "2026-01-05T00:00:00", beh3, rep3, dis3, iv, {"k": 1})
        if cls.oracle:
            check(obs.truth is not None and obs.truth.symptomatic[2], f"{name}: oracle sees truth")
        else:
            check(obs.truth is None, f"{name}: non-oracle obs.truth is None")
        ro_ok = all(not getattr(obs, f).flags.writeable for f in ("x", "y", "room", "b", "off_map", "self_status"))
        check(ro_ok, f"{name}: observable arrays read-only")
        check(not any(v is dis3 for v in vars(obs).values()), f"{name}: disease object not exposed")
        try:
            obs.x[0] = 1
            check(False, "write to obs.x must fail")
        except ValueError:
            pass
        out = iv.step(obs)
        strs = apply_actions(out, beh3, FakePop(10, compliance=1.0), np.random.default_rng(0), 0, reports=rep3)
        print(f"   {name}: actions {out} -> {[s for s in strs if s]}")
    # self_report_isolate fires once per report
    iv = REGISTRY["self_report_isolate"]()
    iv.reset(ctx)
    rep3.self_status[4] = codes.SELF_STATUS.index("might_be_sick")
    a1 = iv.step(build_observable(1, "", beh3, rep3, dis3, iv, {}))
    a2 = iv.step(build_observable(2, "", beh3, rep3, dis3, iv, {}))
    check(list(a1) == [4] and a1[4][0].until_t == 1 + 5 * 288 and a2 == {}, "self_report_isolate: once per report")
    strs = apply_actions({1: [Action("wear_mask"), Action("leave_location")], 3: [Action("isolate_until", 99)]},
                         beh3, FakePop(10, compliance=0.0), np.random.default_rng(0), 0)
    check(strs[1] == "declined:wear_mask|declined:leave_location" and strs[3] == "declined:isolate_until"
          and strs[0] == "" and len(strs) == 10, f"declined strings {strs}")

    # 7) determinism
    a = reports_frame(run_scripted(N=500, seed=9)[4].events, FakePop(500))
    b = reports_frame(run_scripted(N=500, seed=9)[4].events, FakePop(500))
    c = reports_frame(run_scripted(N=500, seed=10)[4].events, FakePop(500))
    check(a.to_csv(index=False) == b.to_csv(index=False), "deterministic: same seed -> identical reports")
    check(a.to_csv(index=False) != c.to_csv(index=False), "different seed -> different reports")

    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
