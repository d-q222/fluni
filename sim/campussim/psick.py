"""Streaming P(sick) for the in-sim FlUni app: a step-by-step Python port of model/infer.js.

infer.js is a batch pass over a finished run's contacts.csv / reports_tests.csv; this class takes the
same evidence one simulation step at a time, so an intervention can act on P(sick) while the run is
going. Same method and parameters (DEFAULTS mirrors infer.js DEFAULTS; keep them in step):

- Evidence about j (self-report, reports by others, tests) gives a source risk s_j and an estimated
  onset (the earliest evidence that still counts).
- Each contact with a source exposes i with Rio's lambda = 1 - exp(-dose) (Wells-Riley near + far
  field dose, stage-weighted), per pair: x_i <- 1 - (1 - x_i)(1 - A')/(1 - A), A = s_j * lambda(pair dose).
- A report looks back over j's contacts of the last `lookbackDays`, at j's stage then.
- Exposure risk sits in K Erlang compartments per agent, so each share fades like Rio's still_infected.
- Second-hand risk (x_j with no evidence of its own) is passed on at alpha, capped, never passed again.

Differences from infer.js (all deliberate, for speed): compartments advance every step for everyone
instead of lazily; same-step exposures of one agent combine as one product (order-independent, same
result); no explain() / contribution lists / change points / flags. Times are in steps, not ms.
"""
import math

import numpy as np

DEFAULTS = {
    "prior": 0.02, "selfReport": 0.6, "reportOther": 0.35, "unsupportedWeight": 0.5,
    "posTest": 0.97, "negTest": 0.05, "evidenceDays": 7, "negTestDays": 3,
    "quantaPeak": 10, "quietQuanta": 1.5, "breathingRate": 0.5, "nearFieldQ": 30,
    "outdoorNearDilution": 5, "deposition": 0.3, "defaultRoomM2": 50, "ceilingM": 2.7, "defaultAch": 2.0,
    "wallFactor": 0, "outdoorRH": 60, "outdoorTempC": 10, "indoorTempC": 21,
    "stageProfile": [0.05, 0.3, 1.0, 0.9, 0.6, 0.35, 0.18, 0.08, 0.04, 0.02],
    "illnessMeanDays": 7, "illnessShape": 4, "lookbackDays": 3,
    "alpha": 0.25, "alphaCap": 0.4, "xiMax": 0.08, "recoverDays": 3, "unsupportedHours": 48,
}
NEG_INF, POS_INF = -math.inf, math.inf


def indoor_rh(out_rh, out_c, in_c=21.0):
    if out_c is None or out_c >= in_c:
        return out_rh
    sat = lambda t: 6.112 * math.exp(17.62 * t / (243.12 + t))  # noqa: E731
    return min(100.0, out_rh * sat(out_c) / sat(in_c))


def virus_decay(rh):
    low, high = math.log(1 / 0.75), math.log(1 / 0.2)
    if rh <= 25:
        return low
    if rh >= 45:
        return high
    return low + (high - low) * (rh - 25) / 20


class PairStore:
    """Per directed pair (i exposed by j): pre / live dose and the share A, keyed i*N+j in a sorted array."""

    def __init__(self):
        self.keys = np.empty(0, np.int64)
        self.pre = np.empty(0)
        self.live = np.empty(0)
        self.A = np.empty(0)

    def index(self, k):
        pos = np.searchsorted(self.keys, k)
        hit = pos < len(self.keys)
        hit[hit] = self.keys[pos[hit]] == k[hit]
        if not hit.all():
            new = np.unique(k[~hit])
            at = np.searchsorted(self.keys, new)
            self.keys = np.insert(self.keys, at, new)
            self.pre = np.insert(self.pre, at, 0.0)
            self.live = np.insert(self.live, at, 0.0)
            self.A = np.insert(self.A, at, 0.0)
            pos = np.searchsorted(self.keys, k)
        return pos


class OnlineRisk:
    def __init__(self, n, campus, step_min, params=None):
        P = {**DEFAULTS, **(params or {})}
        self.P, self.n = P, n
        spd = 1440 // int(step_min)
        self.spd, self.step_s = spd, int(step_min) * 60
        self.ev_s = P["evidenceDays"] * spd
        self.neg_s = P["negTestDays"] * spd
        self.L = int(round(P["lookbackDays"] * spd))
        self.unsup = int(round(P["unsupportedHours"] * 60 / step_min))
        self.keep = max(self.L, self.unsup)
        prof = np.asarray(P["stageProfile"], float)
        self.prof = prof
        self.stage_mean = float(prof.mean())

        # Erlang compartments: co_age[a, k] = e^-x x^k / k!, x = rate * a steps
        K = int(P["illnessShape"])
        self.K = K
        rate = K / (P["illnessMeanDays"] * spd)
        ages = np.arange(self.keep + 1, dtype=float)[:, None] * rate
        kk = np.arange(K)
        self.co_age = np.exp(-ages) * ages ** kk / np.array([math.factorial(k) for k in kk])
        self.co_age[0] = np.r_[1.0, np.zeros(K - 1)]
        co1 = self.co_age[1]
        self.M = np.zeros((K, K))
        for m in range(K):
            for k in range(m, K):
                self.M[m, k] = co1[k - m]
        self.Yd = np.zeros((n, K))
        self.Yi = np.zeros((n, K))

        # rooms: Wells-Riley far field per room, dorm rooms quiet
        decay = virus_decay(indoor_rh(P["outdoorRH"], P["outdoorTempC"], P["indoorTempC"]))
        def_vol = P["defaultRoomM2"] * P["ceilingM"]
        vol = np.asarray(getattr(campus, "room_vol", []), float)   # no campus: every room is the default room
        ach = np.asarray(getattr(campus, "room_ach", []), float)
        vol = np.where(np.isfinite(vol) & (vol > 0), vol, def_vol)
        ach = np.where(np.isfinite(ach) & (ach > 0), ach, P["defaultAch"])
        self.room_far = 1.0 / (vol * (ach + P["deposition"] + decay))
        self.def_far = 1.0 / (def_vol * (P["defaultAch"] + P["deposition"] + decay))
        rt = campus.rooms["room_type"].to_numpy().astype(str) if hasattr(campus, "rooms") else np.empty(0, str)
        self.room_dorm = np.char.startswith(rt, "dorm")

        # evidence (per agent; times in steps)
        self.selfT = np.full(n, NEG_INF)
        self.selfL = np.zeros(n)
        self.posT = np.full(n, NEG_INF)
        self.negT = np.full(n, NEG_INF)
        self.recT = np.full(n, NEG_INF)
        self.recEff = np.full(n, POS_INF)
        self.rep = {}                      # (subject, reporter) -> [t, level]
        self._rep_arr = None               # cached arrays of self.rep
        self.accD, self.accI = PairStore(), PairStore()
        self.hist = []                     # [(t, a int16, b int16, unit dose float32)], oldest first
        self.p = np.full(n, P["prior"])

    # ---------------------------------------------------------------- dose
    def unit_dose(self, c):
        """Rio's dose for a source at stage factor 1, per contact row of this step."""
        P = self.P
        indoor = np.asarray(c["indoor"], bool)
        r = np.asarray(c["r"])
        in_room = indoor & (r >= 0)
        rr = np.where(in_room, r, 0)
        d = np.maximum(np.asarray(c["dist"], float), 0.3)
        q_near = P["nearFieldQ"] * d * d * np.where(indoor, 1.0, P["outdoorNearDilution"])
        if len(self.room_far):
            far = np.where(in_room, self.room_far[rr], np.where(indoor, self.def_far, 0.0))
            quanta = np.where(in_room & self.room_dorm[rr], P["quietQuanta"], P["quantaPeak"])
        else:
            far = np.where(indoor, self.def_far, 0.0)
            quanta = np.full(len(r), float(P["quantaPeak"]))
        wall = indoor & (r < 0)
        u = quanta * P["breathingRate"] * (self.step_s / 3600) * (1 / q_near + far)
        return np.where(wall, u * P["wallFactor"], u)

    def stage(self, on, t):
        """Relative infectiousness of a source `t - on` steps after its estimated onset (0 outside -2..7 days)."""
        day = np.floor((np.asarray(t, float) - on) / self.spd)
        ok = np.isfinite(day) & (day >= -2) & (day <= 7)
        return np.where(ok, self.prof[np.clip(np.nan_to_num(day, nan=0, posinf=0, neginf=0).astype(int) + 2, 0, 9)], 0.0)

    # ---------------------------------------------------------------- evidence
    def _rep_rows(self):
        if self._rep_arr is None:
            if self.rep:
                k = np.array(list(self.rep.keys()), dtype=np.int64)
                v = np.array(list(self.rep.values()), dtype=float)
                self._rep_arr = (k[:, 0], v[:, 0], v[:, 1])
            else:
                self._rep_arr = (np.empty(0, np.int64), np.empty(0), np.empty(0))
        return self._rep_arr

    def evidence(self, t, idx=None):
        """(lvl, cap, on, pos) for agents idx (default all), as infer.js evEval."""
        sl = slice(None) if idx is None else idx
        negT, recT, recEff = self.negT[sl], self.recT[sl], self.recEff[sl]
        selfT, posT = self.selfT[sl], self.posT[sl]
        neg_on = t - negT < self.neg_s
        rc = np.where(t >= recEff, recT, NEG_INF)
        counts = lambda T: (t - T < self.ev_s) & (T > rc) & ((T > negT) | ~neg_on)  # noqa: E731
        pos = (t - posT < self.ev_s) & (posT >= negT) & (posT > rc)
        on = np.where(pos, posT, POS_INF)
        cs = counts(selfT)
        q = np.where(cs, 1 - self.selfL[sl], 1.0)
        on = np.where(cs & (selfT < on), selfT, on)
        subj, rt, rl = self._rep_rows()
        if len(subj):
            if idx is None:
                loc = subj
                keep = np.ones(len(subj), bool)
            else:
                ids = np.atleast_1d(idx)
                m = {int(a): k for k, a in enumerate(ids)}
                loc = np.array([m.get(int(s), -1) for s in subj])
                keep = loc >= 0
            if keep.any():
                lk = loc[keep]
                T = rt[keep]
                ok = (t - T < self.ev_s) & (T > rc[lk]) & ((T > negT[lk]) | ~neg_on[lk])
                if ok.any():
                    np.multiply.at(q, lk[ok], 1 - rl[keep][ok])
                    np.minimum.at(on, lk[ok], T[ok])
        lvl = np.where(pos, self.P["posTest"], 1 - q)
        cap = np.where(~pos & neg_on & (lvl == 0), self.P["negTest"], 1.0)
        return lvl, cap, on, pos

    def _one(self, i, t):
        lvl, cap, on, pos = self.evidence(t, np.array([i]))
        return float(lvl[0]), float(on[0])

    def _had_contact(self, a, b, t0, t1):
        for (tc, ha, hb, _u) in reversed(self.hist):
            if tc < t0:
                break
            if tc <= t1 and np.any(((ha == a) & (hb == b)) | ((ha == b) & (hb == a))):
                return True
        return False

    # ---------------------------------------------------------------- exposure
    def _expose(self, store, i, j, dose_pair, s, age, second):
        """Rio's update for directed pairs (i exposed by j); i unique. dose_pair = the pair's total dose."""
        k = i.astype(np.int64) * self.n + j
        pi = store.index(k)
        A_old = store.A[pi]
        A = np.maximum(A_old, s * (1 - np.exp(-dose_pair)))
        up = A > A_old
        if not up.any():
            return pi
        i, A, A_old, a_age = i[up], A[up], A_old[up], np.broadcast_to(age, up.shape)[up]
        store.A[pi[up]] = A
        Y = self.Yi if second else self.Yd
        x0 = Y[i].sum(1)
        x1 = 1 - (1 - x0) * (1 - A) / (1 - A_old)
        if second:
            x1 = np.minimum(self.P["xiMax"], x1)
        dx = x1 - x0
        g = dx > 0
        if g.any():
            Y[i[g]] += dx[g, None] * self.co_age[np.minimum(a_age[g], self.keep)]
        return pi

    def _look_back(self, j, t, s_new, on):
        pre, run, last = {}, {}, {}
        for (tc, ha, hb, u) in self.hist:
            if tc < t - self.L or tc >= t:
                continue
            m = (ha == j) | (hb == j)
            if not m.any():
                continue
            st = float(self.stage(on, tc))
            if st == 0:
                continue
            others = np.where(ha[m] == j, hb[m], ha[m]).astype(np.int64)
            dose = st * u[m].astype(float)
            r = np.array([run.get(int(o), 0.0) for o in others]) + dose
            for o, d, rv in zip(others.tolist(), dose.tolist(), r.tolist()):
                run[o] = rv
                last[o] = tc
                if tc < on:
                    pre[o] = pre.get(o, 0.0) + d
            self._expose(self.accD, others, np.full(len(others), j, np.int64), r, s_new,
                         np.full(len(others), t - tc), False)
        if not run:
            return
        others = np.array(list(run.keys()), np.int64)
        pi = self.accD.index(others * self.n + j)
        self.accD.pre[pi] = np.maximum(self.accD.pre[pi], np.array([pre.get(int(o), 0.0) for o in others]))
        ages = np.array([t - last[int(o)] for o in others])
        self._expose(self.accD, others, np.full(len(others), j, np.int64),
                     self.accD.pre[pi] + self.accD.live[pi], s_new, ages, False)

    # ---------------------------------------------------------------- step
    def on_report(self, t, i, event, value, target=-1):
        P = self.P
        subject, reporter = i, None
        if event == "report_other":
            if target < 0 or target == i or value != "might_be_sick":
                return
            subject, reporter = target, i
        elif event == "self_report":
            if value not in ("might_be_sick", "tested_positive", "recovered"):
                return
        elif event == "test_result":
            if value not in ("positive", "negative"):
                return
        else:
            return
        e_old, _ = self._one(subject, t)
        if reporter is not None:
            ok = self._had_contact(reporter, subject, t - self.unsup, t)
            self.rep[(subject, reporter)] = [t, P["reportOther"] * (1 if ok else P["unsupportedWeight"])]
            self._rep_arr = None
        elif event == "self_report":
            if value == "might_be_sick":
                self.selfT[subject], self.selfL[subject] = t, P["selfReport"]
            elif value == "tested_positive":
                self.posT[subject] = t
            else:
                sick = max(self.selfT[subject], self.posT[subject])
                if t - sick < P["recoverDays"] * self.spd:
                    self.recT[subject], self.recEff[subject] = t, sick + P["recoverDays"] * self.spd
                else:
                    self.selfT[subject] = self.posT[subject] = self.negT[subject] = NEG_INF
                    for k in [k for k in self.rep if k[0] == subject]:
                        del self.rep[k]
                    self._rep_arr = None
                    self.Yd[subject] = 0
                    self.Yi[subject] = 0
        elif value == "positive":
            self.posT[subject] = t
        else:
            self.negT[subject] = t
        e_new, on = self._one(subject, t)
        if e_new > e_old + 1e-9:
            self._look_back(subject, t, e_new, on)

    def step(self, t, contacts, reports=()):
        """Advance to step t: recovery, then this step's reports (evidence first), then its contacts.
        contacts: dict of arrays (a, b, dist, r, indoor) of app-detected pairs. Returns P(sick) (N,)."""
        P = self.P
        if t > 0:
            self.Yd = self.Yd @ self.M
            self.Yi = self.Yi @ self.M
        for r in reports:
            self.on_report(t, int(r["agent"]), r["event"], r["value"], int(r.get("target", -1)))

        a = np.asarray(contacts["a"], np.int64)
        b = np.asarray(contacts["b"], np.int64)
        u = self.unit_dose(contacts) if len(a) else np.empty(0)
        self.hist.append((t, a.astype(np.int16), b.astype(np.int16), u.astype(np.float32)))
        while self.hist and self.hist[0][0] < t - self.keep:
            self.hist.pop(0)

        lvl, cap, on, pos = self.evidence(t)
        if len(a):
            xd = self.Yd.sum(1)
            blocked = cap < 1
            s1 = np.where(blocked, 0.0, lvl)
            s2 = np.where(blocked | (s1 > 0) | (xd <= 0.005), 0.0, P["alpha"] * np.minimum(xd, P["alphaCap"]))
            st1 = np.where(s1 > 0, self.stage(on, t), 0.0)
            src = (s1 + s2) > 0
            for ii, jj in ((a, b), (b, a)):
                m = src[jj]
                if not m.any():
                    continue
                i, j, uu = ii[m], jj[m], u[m]
                second = ~(s1[j] > 0)
                for sec, store in ((False, self.accD), (True, self.accI)):
                    w = second == sec
                    if not w.any():
                        continue
                    iw, jw = i[w], j[w]
                    stg = np.full(len(iw), self.stage_mean) if sec else st1[jw]
                    dose = stg * uu[w]
                    s = s2[jw] if sec else s1[jw]
                    # one call per batch of unique i (an agent can meet several sources in one step)
                    order = np.argsort(iw, kind="stable")
                    iw, jw, dose, s = iw[order], jw[order], dose[order], s[order]
                    first = np.r_[True, iw[1:] != iw[:-1]]
                    rank = np.arange(len(iw)) - np.flatnonzero(first)[np.cumsum(first) - 1]
                    for rk in range(int(rank.max()) + 1):
                        sel = rank == rk
                        pi = store.index(iw[sel] * self.n + jw[sel])
                        store.live[pi] += dose[sel]
                        self._expose(store, iw[sel], jw[sel], store.pre[pi] + store.live[pi], s[sel],
                                     np.zeros(int(sel.sum()), int), sec)

        xd, xi = self.Yd.sum(1), self.Yi.sum(1)
        p = 1 - (1 - P["prior"]) * (1 - xd) * (1 - xi)
        p = np.where(pos, lvl, np.maximum(p, lvl))
        self.p = np.minimum(p, cap)
        return self.p
