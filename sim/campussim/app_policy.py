"""The FlUni app as an intervention (configs/interventions.json "fluni").

Non-oracle: sees only what the app could know. Only agents with the app (pop.has_app) are alerted,
and only contacts where both phones have it are detected. Each step:

1. Self-report advice: a new "might be sick" / "tested positive" status -> self_report.actions.
2. Phone alerts (proximity/Core/Exposure.swift): each phone broadcasts a 3-level risk from its own
   self-report (might_be_sick -> possibly sick, weight 0.5; tested_positive -> contagious, weight 1).
   Minutes within `distance_m` (6 ft) of risky phones, weighted, summed over a rolling 24 h:
   - nearby: a risky phone within 6 ft right now -> nearby.actions
   - close contact: weighted minutes >= `minutes` (15) -> close_contact.actions
3. Risk advice: P(sick) from the streaming port of model/infer.js (campussim/psick.py) crosses
   risk.p_threshold, with no report or test of the agent's own -> risk.actions.

Actions are strings: "isolate:<days>", "mask:<days>", "leave", "vaden". Each kind of alert has a
cooldown so a phone doesn't re-advise every 5 minutes. Every alert is logged (app_alerts.csv) whether or
not the agent follows it; following is decided in apply_actions (w.p. compliance * compliance_scale).
"""
import numpy as np
import pandas as pd

from . import codes
from .interventions import Action, Intervention
from .psick import OnlineRisk

ALERT_KINDS = ("self_report", "nearby", "close_contact", "risk")


def parse_actions(specs, t, spd):
    out = []
    for s in specs or []:
        kind, _, arg = str(s).partition(":")
        if kind == "isolate":
            out.append(Action("isolate_until", t + int(round(float(arg or 5) * spd))))
        elif kind == "mask":
            out.append(Action("wear_mask", t + int(round(float(arg or 1) * spd))))
        elif kind == "leave":
            out.append(Action("leave_location"))
        elif kind == "vaden":
            out.append(Action("go_to_vaden"))
        else:
            raise ValueError(f"unknown FlUni action {s!r} (isolate:<days>, mask:<days>, leave, vaden)")
    return out


class FluniApp(Intervention):
    name = "fluni"

    def reset(self, ctx):
        super().reset(ctx)
        f = self.icfg["fluni"]
        self.f = f
        pop, campus = ctx.get("pop"), ctx.get("campus")
        n = pop.N if pop is not None else int(ctx["n_agents"])
        self.has_app = np.asarray(pop.has_app, bool) if pop is not None else np.ones(n, bool)
        self.compliance_scale = float(f.get("compliance_scale", 1.0))
        w = f.get("broadcast_weight", {})
        self.bweight = np.zeros(len(codes.SELF_STATUS))
        for name, v in w.items():
            self.bweight[codes.SELF_STATUS.index(name)] = float(v)
        cc, nb = f["close_contact"], f["nearby"]
        self.cc_dist, self.nb_dist = float(cc["distance_m"]), float(nb["distance_m"])
        self.cc_min = float(cc["minutes"])
        win = int(round(float(cc.get("window_h", 24)) * 60 / (1440 / self.spd)))
        self.ring = np.zeros((win, n), np.float32)   # weighted minutes per step, rolling window
        self.minutes = np.zeros(n)
        step_min = 1440 // self.spd
        self.step_min = step_min
        self.next_ok = {k: np.zeros(n, np.int64) for k in ALERT_KINDS}
        self.cool = {k: int(round(float(f[k].get("cooldown_h", 0)) * 60 / step_min)) for k in ALERT_KINDS}
        ss = f["self_report"].get("statuses", ["might_be_sick", "tested_positive"])
        self.sr_trigger = np.array([codes.SELF_STATUS.index(s) for s in ss], np.int8)
        self.sr_prev = np.zeros(n, np.int8)
        r = f["risk"]
        self.p_thr = float(r["p_threshold"]) if r.get("p_threshold") is not None else None
        self.risk = OnlineRisk(n, campus, step_min, f.get("psick")) if self.p_thr is not None else None
        self.own_t = np.full(n, -np.inf)             # last report/test of the agent's own (risk advice is moot)
        self.own_s = float(f.get("psick", {}).get("evidenceDays", 7)) * self.spd
        self.p = np.zeros(n)
        self.log = []

    def _alert(self, out, t, idx, kind, extra=None):
        idx = idx[self.has_app[idx] & (self.next_ok[kind][idx] <= t)]
        if not len(idx):
            return
        self.next_ok[kind][idx] = t + max(self.cool[kind], 1)
        acts = parse_actions(self.f[kind].get("actions"), t, self.spd)
        for i in idx.tolist():
            if acts:
                out.setdefault(i, []).extend(acts)
            self.log.append((t, i, kind, float(self.p[i]), float(self.minutes[i])))

    def step(self, obs):
        t = obs.t
        out = {}
        c = obs.contacts or {"a": np.empty(0, int), "b": np.empty(0, int), "dist": np.empty(0),
                             "r": np.empty(0, int), "indoor": np.empty(0, bool)}
        ss = np.asarray(obs.self_status)

        # 1. self-report advice
        new = np.flatnonzero(np.isin(ss, self.sr_trigger) & (ss != self.sr_prev))
        self.sr_prev = ss.copy()
        self._alert(out, t, new, "self_report")

        # 2. phone alerts
        a, b, d = (np.asarray(c[k]) for k in ("a", "b", "dist"))
        bw = self.bweight[ss]
        k = t % len(self.ring)
        self.minutes -= self.ring[k]
        self.ring[k] = 0
        near = d < self.cc_dist
        for i, j in ((a[near], b[near]), (b[near], a[near])):
            np.add.at(self.ring[k], i, self.step_min * bw[j])
        self.minutes += self.ring[k]
        self.minutes[self.minutes < 1e-6] = 0
        nb = d < self.nb_dist
        risky_near = np.zeros(len(ss), bool)
        risky_near[a[nb][bw[b[nb]] > 0]] = True
        risky_near[b[nb][bw[a[nb]] > 0]] = True
        cc = self.minutes >= self.cc_min - 1e-6
        self._alert(out, t, np.flatnonzero(cc), "close_contact")
        self._alert(out, t, np.flatnonzero(risky_near & ~cc), "nearby")

        # 3. P(sick) advice
        if self.risk is not None:
            self.p = self.risk.step(t, c, obs.reports)
            for r in obs.reports:
                if r["event"] in ("self_report", "test_result", "test_taken"):
                    self.own_t[int(r["agent"])] = t
            hi = np.flatnonzero((self.p >= self.p_thr) & (t - self.own_t >= self.own_s))
            self._alert(out, t, hi, "risk")
        return out

    def log_frame(self, agent_id):
        df = pd.DataFrame(self.log, columns=["t", "agent", "alert", "p_sick", "weighted_min"])
        df.insert(1, "agent_id", np.asarray(agent_id)[df.pop("agent").to_numpy(int)])
        return df.round({"p_sick": 4, "weighted_min": 1})
