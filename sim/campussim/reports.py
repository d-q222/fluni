"""Illness response, self-reports and tests (ground-truth behavioral events, SPEC §3/§6, CONTRACT §8).

Engine calls `Reports.step(t, disease, beh, contacts, disease_events)` after `disease.step`.
Calls into behavior affect steps > t. Everything here is driven by the `reports` RNG stream and
iterates agents in sorted order, so output is deterministic.
"""
import numpy as np
import pandas as pd

from . import codes

STAY_HOME, VADEN, CARRY_ON = range(3)            # codes.SICK_PROFILES order
SS_NONE, SS_SICK, SS_POS, SS_REC = range(4)      # codes.SELF_STATUS order
TS_NONE, TS_PENDING, TS_POS, TS_NEG = range(4)   # codes.TEST_STATUS order
INFECTED_STATES = (codes.E, codes.I_PRE, codes.I_SYM, codes.I_ASYM)
REPORT_COLUMNS = ["t", "agent_id", "event", "value", "target_agent_id", "truthful"]


def _daily_to_step(p_day, spd):
    """Per-step probability equivalent to a daily probability."""
    p_day = np.clip(np.asarray(p_day, dtype=float), 0.0, 1.0)
    return 1.0 - (1.0 - p_day) ** (1.0 / spd)


def _thin_draw(rng, idx, p_each, p_max):
    """Bernoulli(p_each) for each candidate in idx via binomial thinning (cheap when p small).
    Returns the selected subset of idx (sorted, original order)."""
    n = len(idx)
    if n == 0 or p_max <= 0:
        return idx[:0]
    k = rng.binomial(n, p_max)
    if k == 0:
        return idx[:0]
    pick = np.sort(rng.choice(n, size=k, replace=False))
    keep = rng.random(k) < (np.asarray(p_each, dtype=float)[pick] / p_max)
    return idx[pick[keep]]


class Reports:
    """Per-agent illness response + app self-reports + Vaden tests."""

    def __init__(self, cfg, campus, pop, rng):
        self.cfg = cfg["reports"]
        self.rng = rng
        self.pop = pop
        self.N = N = pop.N
        rc = cfg["run"]
        self.step_min = rc["step_min"]
        self.spd = 1440 // self.step_min
        self.start_weekday = rc.get("start_weekday", 0)

        self.self_status = np.zeros(N, dtype=np.int8)
        self.test_status = np.zeros(N, dtype=np.int8)
        self.events = []

        # per-agent attributes
        app = np.asarray(pop.has_app, dtype=bool)
        self.app_ok = app if self.cfg.get("require_app", True) else np.ones(N, dtype=bool)
        self.honesty = np.asarray(pop.honesty, dtype=float)
        if getattr(pop, "sick_response_p", None) is not None:
            p = np.asarray(pop.sick_response_p, dtype=float)
        else:
            p = np.asarray(pop.param("sick_profile_p"), dtype=float)
        if p.ndim == 1:
            p = np.tile(p, (N, 1))
        self.response_p = p / p.sum(axis=1, keepdims=True)
        try:
            self.carry_on_intensity = np.asarray(pop.param("carry_on_intensity"), dtype=float)
        except Exception:  # noqa: BLE001 - population without that param
            self.carry_on_intensity = np.full(N, 0.7)

        # episode state
        self.episode = np.zeros(N, dtype=bool)
        self.response = np.full(N, -1, dtype=np.int8)       # response of current/last episode
        self.iso_owned = np.zeros(N, dtype=bool)            # isolation set by us (not an intervention)
        self.intervention_iso_until = np.full(N, -1, dtype=np.int64)
        self.false_sick = np.zeros(N, dtype=bool)           # current might_be_sick is a false report
        self.pending = {}          # t -> list of (agent, kind, payload), appended in sorted agent order
        self.vaden = {}            # agent -> [start, end, tested(bool), via_episode(bool)]
        self.other_last = {}       # (reporter, target) -> last report t
        self.n_missed_tests = 0

        vc = self.cfg["vaden"]
        self.vaden_b = set()
        if campus is not None and vc.get("test_requires_presence", True):
            try:
                self.vaden_b = {int(b) for b in campus.buildings_of_type("health_center")}
            except Exception:  # noqa: BLE001
                self.vaden_b = set()
        self.grace = int(round(vc.get("presence_grace_min", 30) / self.step_min))

        sr, ro = self.cfg["self_report"], self.cfg["report_other"]
        self.p_false_sick = _daily_to_step(sr["false_sick_daily_p"], self.spd)
        self.p_early_rec = _daily_to_step(sr["early_recovered_daily_p"], self.spd)
        self.ro_cooldown = int(ro["cooldown_days"] * self.spd)
        self.ro_max_tier = int(ro.get("max_tier", 2))
        self.p_ro_false = _daily_to_step(ro.get("false_daily_p", 0.0), self.spd)
        self.ro_app = (np.asarray(pop.has_app, dtype=bool) if ro.get("require_app", True)
                       else np.ones(N, dtype=bool))

    # ---------- helpers ----------
    def _h(self, hours):
        return max(1, int(round(hours * 60 / self.step_min)))

    def _uh(self, lo_hi):
        lo, hi = lo_hi
        return self._h(self.rng.uniform(lo, hi))

    def _schedule(self, t_at, i, kind, payload=None):
        self.pending.setdefault(int(t_at), []).append((int(i), kind, payload))

    def _emit(self, t, i, event, value, target=-1, truthful=None):
        self.events.append(dict(t=int(t), agent=int(i), event=event, value=value,
                                target=int(target), truthful=truthful))

    def next_vaden_slot(self, t0, n_steps):
        """First step >= t0 such that [start, start+n_steps] lies inside Vaden opening hours."""
        vc = self.cfg["vaden"]
        hours = vc["open_hours"]
        spm = 60 / self.step_min
        d0 = t0 // self.spd
        for d in range(d0, d0 + int(vc.get("search_days", 8)) + 1):
            oh = hours[(self.start_weekday + d) % 7]
            if not oh:
                continue
            day0 = d * self.spd
            o, c = day0 + int(np.ceil(oh[0] * spm)), day0 + int(np.floor(oh[1] * spm))
            s = max(t0, o)
            if s + n_steps <= c:
                return int(s)
        return int(t0)  # no slot found in range: go immediately

    def _iso_end(self, disease, i, t):
        cap = t + int(self.cfg["isolation_max_days"] * self.spd)
        for name in ("t_end", "t_recover", "t_recovered", "t_symptom_end"):
            arr = getattr(disease, name, None)
            if arr is not None:
                try:
                    v = int(arr[i])
                except Exception:  # noqa: BLE001
                    continue
                if v > t:
                    return min(v, cap)
        return cap

    def register_vaden_visit(self, i, start, end, via_episode=False):
        """Track a Vaden visit (also used by interventions.apply_actions for go_to_vaden)."""
        self.vaden[int(i)] = [int(start), int(end), False, bool(via_episode)]

    def _take_test(self, t, i, disease):
        self._emit(t, i, "test_taken", "pending")
        self.test_status[i] = TS_PENDING
        tc = self.cfg["test"]
        infected = int(disease.state[i]) in INFECTED_STATES
        u = self.rng.random()
        pos = u < tc["sensitivity"] if infected else u < (1.0 - tc["specificity"])
        self._schedule(t + self._h(tc["result_delay_h"]), i, "test_result", bool(pos))

    # ---------- main ----------
    def step(self, t, disease, beh, contacts, disease_events):
        rng, cfg = self.rng, self.cfg
        de = disease_events or {}
        state = np.asarray(disease.state)

        # 1) symptom onset -> illness response (+ self-report scheduling)
        onset = np.sort(np.asarray(de.get("onset", []), dtype=np.int64))
        if len(onset):
            u = rng.random(len(onset))
            cum = np.cumsum(self.response_p[onset], axis=1)
            resp = np.minimum((u[:, None] >= cum).sum(axis=1), 2)
            for i, r in zip(onset.tolist(), resp.tolist()):
                self._onset(t, i, r, disease, beh)

        # 2) recovery
        rec = np.sort(np.asarray(de.get("recovered", []), dtype=np.int64))
        for i in rec.tolist():
            self._recover(t, i, beh)

        # 3) scheduled items due now
        for i, kind, payload in self.pending.pop(int(t), []):
            self._due(t, i, kind, payload, disease, beh)

        # 4) Vaden presence -> test
        if self.vaden:
            for i in sorted(self.vaden):
                v = self.vaden[i]
                start, end, tested, via = v
                if t < start:
                    continue
                if not tested:
                    present = (not self.vaden_b) or int(beh.b[i]) in self.vaden_b
                    if present:
                        v[2] = True
                        self._take_test(t, i, disease)
                if t >= end + self.grace:
                    if not v[2]:
                        self.n_missed_tests += 1
                    del self.vaden[i]

        # 5) spontaneous app reports (vectorized, thinned)
        infectious = np.isin(state, codes.INFECTIOUS_STATES)
        dis_honest = 1.0 - self.honesty
        ss = self.self_status
        # dishonest early "recovered" while still infectious
        elig = np.flatnonzero(self.app_ok & ((ss == SS_SICK) | (ss == SS_POS)) & infectious & ~self.false_sick)
        for i in _thin_draw(rng, elig, self.p_early_rec * dis_honest[elig], self.p_early_rec).tolist():
            self._emit(t, i, "self_report", "recovered", truthful=False)
            ss[i] = SS_REC
        # false sick report by a healthy agent
        healthy = (state == codes.S) | (state == codes.R)
        elig = np.flatnonzero(self.app_ok & ((ss == SS_NONE) | (ss == SS_REC)) & healthy & ~self.episode)
        for i in _thin_draw(rng, elig, self.p_false_sick * dis_honest[elig], self.p_false_sick).tolist():
            self._emit(t, i, "self_report", "might_be_sick", truthful=False)
            ss[i] = SS_SICK
            self.false_sick[i] = True
            sr = cfg["self_report"]
            if rng.random() < sr["false_report_clear_p"]:
                self._schedule(t + self._uh(np.asarray(sr["false_report_clear_days"]) * 24), i, "false_clear")

        # 6) report_other from same-room contacts
        if contacts is not None and len(contacts.get("a", ())):
            self._report_other(t, disease, contacts, infectious)

    def _onset(self, t, i, r, disease, beh):
        cfg = self.cfg
        self.episode[i] = True
        self.response[i] = r
        iso_until = self._iso_end(disease, i, t)
        if r == STAY_HOME:
            beh.set_isolation(i, iso_until)
            self.iso_owned[i] = True
        elif r == VADEN:
            vc = cfg["vaden"]
            n = max(1, int(round(self.rng.uniform(*vc["visit_min"]) / self.step_min)))
            start = self.next_vaden_slot(t + self._uh(vc["delay_h"]), n)
            beh.schedule_vaden(i, start, n)
            self.register_vaden_visit(i, start, start + n, via_episode=True)
            pre = cfg.get("pre_visit_carry_on_intensity")
            if pre is not None:
                beh.set_carry_on(i, float(pre))
            self._schedule(start + n, i, "isolate_after_visit", iso_until)
        else:
            beh.set_carry_on(i, float(self.carry_on_intensity[i]))
        if r != VADEN and self.rng.random() < cfg["test"]["p_test_non_vaden"]:
            self._schedule(t + self._uh(cfg["test"]["non_vaden_delay_h"]), i, "home_test")
        if self.app_ok[i]:
            self._schedule(t + self._uh(cfg["self_report"]["onset_delay_h"]), i, "report_sick")

    def _recover(self, t, i, beh):
        if self.episode[i]:
            self.episode[i] = False
            r = int(self.response[i])
            if r in (CARRY_ON, VADEN):
                beh.set_carry_on(i, None)
            if self.iso_owned[i]:
                beh.end_isolation(i)
                self.iso_owned[i] = False
                if self.intervention_iso_until[i] > t:
                    beh.set_isolation(i, int(self.intervention_iso_until[i]))
        sr = self.cfg["self_report"]
        if self.app_ok[i] and self.self_status[i] in (SS_SICK, SS_POS) and not self.false_sick[i]:
            if self.rng.random() < sr["p_report_recovered"]:
                self._schedule(t + self._uh(sr["recovered_delay_h"]), i, "report_recovered")

    def _due(self, t, i, kind, payload, disease, beh):
        ss = self.self_status
        if kind == "report_sick":
            if ss[i] in (SS_SICK, SS_POS) and not self.false_sick[i]:
                return  # already reported
            if self.rng.random() < self.honesty[i]:
                self._emit(t, i, "self_report", "might_be_sick", truthful=True)
                if ss[i] != SS_POS:
                    ss[i] = SS_SICK
                self.false_sick[i] = False
            else:
                self._emit(t, i, "self_report", "withheld", truthful=False)
        elif kind == "test_result":
            pos = bool(payload)
            self._emit(t, i, "test_result", "positive" if pos else "negative")
            self.test_status[i] = TS_POS if pos else TS_NEG
            if pos and self.app_ok[i]:
                self._schedule(t + self._uh(np.asarray(self.cfg["self_report"]["positive_delay_min"]) / 60),
                               i, "report_positive")
        elif kind == "report_positive":
            if self.rng.random() < self.honesty[i]:
                self._emit(t, i, "self_report", "tested_positive", truthful=True)
                ss[i] = SS_POS
                self.false_sick[i] = False
            else:
                self._emit(t, i, "self_report", "withheld", truthful=False)
        elif kind == "report_recovered":
            if ss[i] in (SS_SICK, SS_POS):
                self._emit(t, i, "self_report", "recovered", truthful=True)
                ss[i] = SS_REC
        elif kind == "false_clear":
            if self.false_sick[i] and ss[i] == SS_SICK:
                self._emit(t, i, "self_report", "recovered",
                           truthful=bool(int(disease.state[i]) not in codes.INFECTIOUS_STATES))
                ss[i] = SS_REC
            self.false_sick[i] = False
        elif kind == "isolate_after_visit":
            if self.episode[i] and self.response[i] == VADEN:
                beh.set_carry_on(i, None)
                beh.set_isolation(i, max(int(payload), t + 1))
                self.iso_owned[i] = True
        elif kind == "home_test":
            if self.test_status[i] != TS_PENDING:
                self._take_test(t, i, disease)

    def _report_other(self, t, disease, contacts, infectious):
        ro = self.cfg["report_other"]
        a = np.asarray(contacts["a"], dtype=np.int64)
        b = np.asarray(contacts["b"], dtype=np.int64)
        sr = np.asarray(contacts["same_room"], dtype=bool)
        tier = np.asarray(contacts["tier"], dtype=np.int64)
        a, b, tier = a[sr], b[sr], tier[sr]
        if not len(a):
            return
        rep = np.concatenate([a, b])
        tgt = np.concatenate([b, a])
        near = np.concatenate([tier, tier]) <= self.ro_max_tier
        state = np.asarray(disease.state)
        sev = np.asarray(disease.severity, dtype=float)
        visible = (state == codes.I_SYM) & (sev > ro["severity_threshold"])
        sick_truth = infectious | (sev > 0)
        ok = self.ro_app[rep]
        # true-ish reports on visibly symptomatic targets, only from people close enough to notice
        cand = np.flatnonzero(ok & near & visible[tgt])
        hits_true = cand[self.rng.random(len(cand)) < ro["p_per_step"]] if len(cand) else cand
        # rare false reports: a per-reporter daily rate (scaled by dishonesty), aimed at one healthy
        # same-room contact, so it doesn't grow with crowd size
        cand = np.flatnonzero(ok & ~sick_truth[tgt])
        hits_false = cand[:0]
        if len(cand) and self.p_ro_false > 0:
            o = np.lexsort((tgt[cand], rep[cand]))
            cand = cand[o]
            first = np.flatnonzero(np.r_[True, rep[cand][1:] != rep[cand][:-1]])
            starts = np.r_[first, len(cand)]
            r_ids = rep[cand[first]]
            sel = self.rng.random(len(r_ids)) < self.p_ro_false * (1.0 - self.honesty[r_ids])
            if sel.any():
                k = np.flatnonzero(sel)
                n_each = starts[k + 1] - starts[k]
                hits_false = cand[starts[k] + (self.rng.random(len(k)) * n_each).astype(np.int64)]
        hits = np.concatenate([hits_true, hits_false])
        if not len(hits):
            return
        order = np.lexsort((tgt[hits], rep[hits]))
        for h in hits[order].tolist():
            i, j = int(rep[h]), int(tgt[h])
            last = self.other_last.get((i, j))
            if last is not None and t - last < self.ro_cooldown:
                continue
            self.other_last[(i, j)] = int(t)
            self._emit(t, i, "report_other", "might_be_sick", target=j, truthful=bool(sick_truth[j]))


def _tf(v):
    return "" if v is None else ("True" if v else "False")


def reports_frame(events, pop):
    """events (list of dicts t, agent, event, value, target, truthful) -> d2 reports_tests.csv frame."""
    if not events:
        return pd.DataFrame({c: pd.Series(dtype=object if c != "t" else np.int64) for c in REPORT_COLUMNS})
    ids = pop.agent_id
    rows = {
        "t": [int(e["t"]) for e in events],
        "agent_id": [ids[e["agent"]] for e in events],
        "event": [e["event"] for e in events],
        "value": ["" if e.get("value") is None else str(e["value"]) for e in events],
        "target_agent_id": [ids[e["target"]] if e.get("target", -1) is not None and e.get("target", -1) >= 0
                            else "" for e in events],
        "truthful": [_tf(e.get("truthful")) for e in events],
    }
    df = pd.DataFrame(rows, columns=REPORT_COLUMNS)
    return df.sort_values(["t", "agent_id"], kind="mergesort").reset_index(drop=True)
