#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""
P(flu) for every agent in a sim run, by the mean-field method of
Baker et al., "Epidemic mitigation by statistical inference from contact
tracing data", PNAS 118 (32) e2106548118 (2021).

The paper's mean-field (MF) update, for a susceptible i and its contacts j
during step t:

    P_S^i(t+1) = P_S^i(t) * prod_j (1 - lambda_{j->i}(t) * P_I^j(t))

with infected people recovering, and observations (tests, symptoms) imposed
as constraints on the marginals: a positive test at t_obs sets P_I = 1 on
[t_obs - tau, t_obs], a recovery sets P_R = 1 afterwards. Every agent's
marginals are rerun from the earliest step a new observation touches, so a
report today also raises the risk of people the reporter met days ago.

Two refinements the paper allows but leaves open:

* lambda_{j->i} comes from the exposure calculator (../flu_risk.py): an
  exhaled-plume plus Wells-Riley room dose set by the meeting's duration,
  distance, room size and ventilation, indoors or outdoors, and the virus's
  decay at the indoor humidity implied by outdoor humidity.
* "Stage of flu": instead of a single I state, each agent carries a
  distribution over infection age (time since infection, in steps). j's
  infectiousness follows the flu shedding curve of flu_risk.STAGE_PROFILE at
  each age, so the transmission term is sum_a P_j(age a) * lambda_{j->i}(a).
  Infections age deterministically, which is how "time since the meeting"
  enters: an infection picked up at a meeting is latent, then infectious,
  then over (R) after ILLNESS_DAYS.

The model only uses what a phone could know: contacts (distance, duration,
room), self-reports, reports about others and test results. Ground truth
(disease_state) is read only to score the result.

Run (uv installs numpy):

    uv run exposure/network/mean_field.py sim/runs/<run_id>

Writes exposure/network/out/<run_id>/data.js for index.html, and prints a
summary with ranking quality (AUC) against the sim's ground truth.
"""

import argparse
import csv
import gzip
import json
import math
import os
import sys
import time
from collections import defaultdict

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import flu_risk as fr  # noqa: E402  (same constants as the calculator)

# ---------------------------------------------------------------- parameters
PARAMS = {
    "dt_h": 6.0,              # MF step (the paper uses 1 day; 6 h keeps meetings in order)
    "prior": 0.02,            # P(infected) at t = 0, ages spread evenly (campus baseline)
    "import_per_day": 0.0005, # community infection hazard (the paper's self-infection gamma)
    "onset_days": 2.5,        # infection -> symptom onset (sim influenza: latent 1.5 + presym 1.0)
    "illness_days": 10.0,     # infection age after which a case is over (R)
    "p_asym": 0.3,            # asymptomatic share ...
    "asym_rel": 0.5,          # ... at this relative infectiousness
    "tau_pos_days": 3.0,      # positive test: infected this long before the result
    "tau_sym_days": 2.5,      # "might be sick": infected this long before the report (onset now)
    "lr_sym": 20.0,           # likelihood ratio of a self-report of symptoms
    "lr_other": 4.0,          # ... of a report by someone else
    "fnr": 0.3,               # negative test: infected mass x false-negative rate
    "detect_days": 1.0,       # a test can only see infections at least this old
    "default_room_m2": 50.0,  # rooms missing from map/rooms.csv
    "top_k": 8,               # meetings kept per agent for "why this %?"
    "lambda_scale": 1.0,      # dose multiplier; calibrate.py fits it to a sim run
    "cavity": 1,              # 1: leave out of j -> i what j caught from i (message passing)
}


# ---------------------------------------------------------------- inputs
def read_csv(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", newline="") as f:
        yield from csv.DictReader(f)


def contacts_path(run):
    p = os.path.join(run, "contacts.csv.gz")
    if os.path.exists(p):
        return [p]
    man = json.load(open(os.path.join(run, "parts", "manifest.json")))
    return [os.path.join(run, part["path"]) for part in man["files"]["contacts.csv.gz"]["parts"]]


def iter_contacts(run):
    paths = contacts_path(run)
    if len(paths) == 1:
        yield from read_csv(paths[0])
        return
    # parts are byte slices of one gzip stream
    import io
    buf = b"".join(open(p, "rb").read() for p in paths)
    with gzip.open(io.BytesIO(buf), "rt", newline="") as f:
        yield from csv.DictReader(f)


def humidity_by_day(cfg):
    """Outdoor RH and temperature per sim day -> indoor RH -> airborne flu decay (1/h)."""
    w = cfg["params"].get("weather", {})
    daily = w.get("daily") or []
    out = []
    for d in range(cfg["days"] + 1):
        o = daily[min(d, len(daily) - 1)] if daily else {}
        rh = o.get("outdoor_rh_pct", w.get("outdoor_rh_pct", 60.0))
        tc = o.get("outdoor_temp_c", w.get("outdoor_temp_c"))
        rh_in = fr.indoor_rh(rh, tc, w.get("indoor_temp_c", 21.0))
        out.append({"outdoor_rh": rh, "outdoor_temp_c": tc, "indoor_rh": rh_in,
                    "decay": fr.virus_decay(rh_in)})
    return out


# ---------------------------------------------------------------- model
class Model:
    def __init__(self, run, params):
        self.p = params
        self.run = run
        self.cfg = json.load(open(os.path.join(run, "config.json")))
        self.step_min = self.cfg["step_min"]
        self.W = int(round(params["dt_h"] * 60 / self.step_min))      # sim steps per MF step
        self.dt_days = params["dt_h"] / 24
        self.n_steps = math.ceil(self.cfg["days"] * 24 / params["dt_h"])
        self.K = int(round(params["illness_days"] / self.dt_days))    # infection-age bins
        self.ids = [r["agent_id"] for r in read_csv(os.path.join(run, "agents_static.csv"))]
        self.idx = {a: i for i, a in enumerate(self.ids)}
        self.N = len(self.ids)
        self.weather = humidity_by_day(self.cfg)

        # Stage: relative infectiousness at each infection age (bin centre).
        age = (np.arange(self.K) + 0.5) * self.dt_days
        days = sorted(fr.STAGE_PROFILE)
        prof = np.interp(age - params["onset_days"], days,
                         [fr.STAGE_PROFILE[d] for d in days], left=0.0, right=0.0)
        self.stage = prof * (1 - params["p_asym"] + params["p_asym"] * params["asym_rel"])
        self.age_days = age

        self._load_rooms()
        self._load_contacts()
        self._load_reports()
        self.attr = [None] * self.n_steps
        self._pos = np.full(self.n_pairs, -1, dtype=np.int64)

    def _load_rooms(self):
        self.rooms = {}
        path = os.path.join(self.run, "map", "rooms.csv")
        if os.path.exists(path):
            for r in read_csv(path):
                vol = float(r["volume_m3"] or 0) or self.p["default_room_m2"] * fr.CEILING
                ach = float(r["ventilation_ach"] or 0) or fr.DEFAULT_ACH
                self.rooms[r["room_id"]] = (vol, ach)

    def _load_contacts(self):
        """Every 5-min contact row -> dose per quantum D (so dose = q * D), summed per
        unordered pair and MF step. Poisson doses add, so lambda for the step is
        1 - exp(-q * sum D) whatever the order of the rows."""
        t0 = time.time()
        B, Q = fr.BREATHING_RATE, fr.NEAR_FIELD_Q
        default_room = (self.p["default_room_m2"] * fr.CEILING, fr.DEFAULT_ACH)
        agg = [defaultdict(lambda: [0.0, 0.0, 0.0, 9e9, None, False, 0.0]) for _ in range(self.n_steps)]
        skipped_wall = 0
        rows = 0
        for r in iter_contacts(self.run):
            rows += 1
            n = int(r["t"]) // self.W
            if n >= self.n_steps:
                continue
            indoor = r["indoor"] == "True"
            room = r["room_id"]
            if indoor and not room:
                skipped_wall += 1     # within 5 m but through a wall: no shared air
                continue
            hours = float(r["duration_s"]) / 3600
            d = max(float(r["distance_m"]), 0.3)
            if indoor:
                vol, ach = self.rooms.get(room, default_room)
                day = int(r["t"]) * self.step_min // 1440
                loss = ach + fr.DEPOSITION + self.weather[day]["decay"]
                D = B * hours * (1 / (Q * d * d) + 1 / (vol * loss))
            else:
                D = B * hours / (Q * d * d * fr.OUTDOOR_NEAR_DILUTION)
            a, b = self.idx[r["agent_a"]], self.idx[r["agent_b"]]
            if a > b:
                a, b = b, a
            e = agg[n][(a, b)]
            e[0] += D
            e[1] += hours * 60                  # minutes together
            e[2] += hours * 60 * d              # for the time-weighted mean distance
            e[3] = min(e[3], d)
            if e[4] is None:
                e[4] = room
            e[5] = e[5] or indoor
            e[6] += hours * 60 * (not indoor)   # minutes outdoors
        self.pairs = []
        pid_of = {}
        for n in range(self.n_steps):
            items = agg[n]
            if not items:
                self.pairs.append(None)
                continue
            keys = np.array(list(items.keys()), dtype=np.int32)
            vals = list(items.values())
            self.pairs.append({
                "a": keys[:, 0], "b": keys[:, 1],
                "pid": np.array([pid_of.setdefault(k, len(pid_of)) for k in items], dtype=np.int64),
                "D": np.array([v[0] for v in vals]),
                "min": np.array([v[1] for v in vals]),
                "dist": np.array([v[2] / v[1] for v in vals]),
                "dmin": np.array([v[3] for v in vals]),
                "room": [v[4] for v in vals],
                "out_min": np.array([v[6] for v in vals]),
            })
        self.n_pairs = len(pid_of)
        self.n_rows, self.n_wall = rows, skipped_wall
        print(f"contacts: {rows:,} rows -> {sum(len(x['D']) for x in self.pairs if x):,} "
              f"pair-steps ({skipped_wall:,} through-wall rows skipped) in {time.time() - t0:.0f} s")

    def _load_reports(self):
        """Reports and tests -> observations, each with the MF step the app learns it."""
        self.obs = defaultdict(list)
        self.evidence = defaultdict(list)
        for r in read_csv(os.path.join(self.run, "reports_tests.csv")):
            t = int(r["t"])
            n = t // self.W
            if n >= self.n_steps:
                continue
            ev, val = r["event"], r["value"]
            who = r["agent_id"]
            kind = None
            if (ev == "test_result" and val == "positive") or (ev == "self_report" and val == "tested_positive"):
                kind = "pos"
            elif ev == "test_result" and val == "negative":
                kind = "neg"
            elif ev == "self_report" and val == "might_be_sick":
                kind = "sym"
            elif ev == "self_report" and val == "recovered":
                kind = "rec"
            elif ev == "report_other" and val == "might_be_sick":
                kind, who = "other", r["target_agent_id"]
            if kind is None or who not in self.idx:
                continue
            i = self.idx[who]
            self.obs[n].append((kind, i))
            self.evidence[i].append({"t": t, "kind": kind})

    # ------------------------------------------------------------ dynamics
    def init_state(self):
        p0 = self.p["prior"]
        S = np.full(self.N, 1 - p0)
        A = np.full((self.N, self.K), p0 / self.K)
        R = np.zeros(self.N)
        return S, A, R

    def transmission(self, n, A):
        """T[a->b], T[b->a] for every pair in step n: sum over j's infection ages of
        P_j(age) * lambda_{j->i}(age), with lambda = 1 - exp(-q(age) * D).

        Cavity (dynamic message passing, the paper's ref. [10]): j's infection mass
        that came from i itself is left out of j -> i, so risk can't echo back and
        forth inside a pair (roommates, friends) and snowball."""
        pr = self.pairs[n]
        q = fr.QUANTA_PEAK * self.p["lambda_scale"]
        E = -np.expm1(-q * pr["D"][:, None] * self.stage[None, :])
        Aa, Ab = A[pr["a"]], A[pr["b"]]
        if self.p["cavity"]:
            Ca, Cb = self.cavity(n, pr)          # mass a got from b, mass b got from a
            Aa = np.maximum(Aa - Ca, 0)
            Ab = np.maximum(Ab - Cb, 0)
        return (Aa * E).sum(1), (Ab * E).sum(1), E

    def cavity(self, n, pr):
        """Infection mass, by current age, that each side of the step's pairs caught
        from the other in earlier steps (from the attributions step() recorded)."""
        m = len(pr["pid"])
        Ca, Cb = np.zeros((m, self.K)), np.zeros((m, self.K))
        pos = self._pos
        pos[pr["pid"]] = np.arange(m)
        for s in range(max(0, n - self.K), n):
            at = self.attr[s]
            if at is None:
                continue
            pid, to_b, mass = at
            k = pos[pid]
            ok = k >= 0
            age = n - s - 1
            np.add.at(Cb[:, age], k[ok & to_b], mass[ok & to_b])
            np.add.at(Ca[:, age], k[ok & ~to_b], mass[ok & ~to_b])
        pos[pr["pid"]] = -1
        return Ca, Cb

    def step(self, n, state, clamps, record=True):
        """One MF step. Also records which pair each bit of new infection came from
        (split in proportion to each contact's hazard) for the cavity term."""
        S, A, R = (x.copy() for x in state)
        for c in clamps:
            self.apply_clamp(c, S, A, R)
        logq = np.zeros(self.N)
        h_imp = -math.log1p(-self.p["import_per_day"] * self.dt_days)
        pr = self.pairs[n]
        if pr is not None:
            Tab, Tba, _ = self.transmission(n, A)
            hab = -np.log1p(-np.minimum(Tab, 1 - 1e-12))
            hba = -np.log1p(-np.minimum(Tba, 1 - 1e-12))
            np.add.at(logq, pr["b"], -hab)
            np.add.at(logq, pr["a"], -hba)
        escape = np.exp(logq - h_imp)
        new = S * (1 - escape)
        if record:
            if pr is None:
                self.attr[n] = None
            else:
                per_h = new / (h_imp - logq)       # new infection mass per unit hazard
                mass = np.concatenate([hab * per_h[pr["b"]], hba * per_h[pr["a"]]])
                keep = mass > 1e-7
                pid = np.concatenate([pr["pid"], pr["pid"]])
                to_b = np.concatenate([np.ones(len(hab), bool), np.zeros(len(hba), bool)])
                self.attr[n] = (pid[keep], to_b[keep], mass[keep])
        A2 = np.empty_like(A)
        A2[:, 1:] = A[:, :-1]
        A2[:, 0] = new
        return (S - new, A2, R + A[:, -1]), (S, A, R)

    def apply_clamp(self, c, S, A, R):
        kind, i = c[0], c[1]
        if kind == "infect":                 # (1-w) * current + w * infected at age k0
            _, _, k0, w = c
            S[i] *= 1 - w
            R[i] *= 1 - w
            A[i] *= 1 - w
            if k0 < self.K:
                A[i, k0] += w
            else:
                R[i] += w
        elif kind == "neg":                  # likelihood of a negative test
            k_det = int(round(self.p["detect_days"] / self.dt_days))
            A[i, k_det:] *= self.p["fnr"]
            z = S[i] + A[i].sum() + R[i]
            S[i] /= z
            A[i] /= z
            R[i] /= z
        elif kind == "rec":                  # P_R = 1 from now on
            R[i] += A[i].sum()
            A[i] = 0

    def clamp_for(self, kind, i, n, state):
        """Turn an observation learned in step n into a clamp at an effect step."""
        S, A, R = state
        if kind in ("neg", "rec"):
            return n, (kind, i)
        tau = self.p["tau_pos_days"] if kind == "pos" else self.p["tau_sym_days"]
        back = int(round(tau / self.dt_days))
        s_eff, k0 = n - back, 0
        if s_eff < 0:
            s_eff, k0 = 0, -s_eff
        if kind == "pos":
            w = 1.0
        else:
            lr = self.p["lr_sym"] if kind == "sym" else self.p["lr_other"]
            p = max(1 - S[i] - R[i], self.p["prior"])
            w = lr * p / (lr * p + 1 - p)
        return s_eff, ("infect", i, k0, w)

    def run_model(self):
        """Online pass: at each step, add newly learned observations; if they reach back
        in time, rerun every agent from the earliest step they touch. Records P(flu)
        as the app would show it at the end of each step."""
        t0 = time.time()
        ckpt = [None] * (self.n_steps + 1)
        ckpt[0] = self.init_state()
        clamps = defaultdict(list)
        now = np.zeros((self.n_steps, self.N), dtype=np.float32)
        ever = np.zeros((self.n_steps, self.N), dtype=np.float32)
        reruns = 0
        for n in range(self.n_steps):
            earliest = n
            for kind, i in self.obs.get(n, []):
                s_eff, c = self.clamp_for(kind, i, n, ckpt[n])
                clamps[s_eff].append(c)
                earliest = min(earliest, s_eff)
            reruns += n - earliest
            for s in range(earliest, n + 1):
                ckpt[s + 1], _ = self.step(s, ckpt[s], clamps.get(s, []))
            S, A, R = ckpt[n + 1]
            now[n] = A.sum(1)
            ever[n] = 1 - S
        self.ckpt, self.clamps = ckpt, clamps
        self.p_now, self.p_ever = now, ever
        print(f"mean-field: {self.n_steps} steps of {self.p['dt_h']:g} h, {self.K} age bins, "
              f"{reruns} look-back steps rerun, {time.time() - t0:.1f} s")

    # ------------------------------------------------------------ explain
    def explain(self):
        """The meetings that raised each agent's risk most, from the final pass
        (everything known by the end of the run)."""
        k = self.p["top_k"]
        best = [[] for _ in range(self.N)]
        for n in range(self.n_steps):
            pr = self.pairs[n]
            if pr is None:
                continue
            # state at the start of step n after its clamps, as step() used it
            _, (S, A, R) = self.step(n, self.ckpt[n], self.clamps.get(n, []), record=False)
            Tab, Tba, E = self.transmission(n, A)
            day = int(n * self.p["dt_h"] // 24)
            for src, dst, T in ((pr["a"], pr["b"], Tab), (pr["b"], pr["a"], Tba)):
                contrib = S[dst] * T
                for m in np.nonzero(contrib > 1e-4)[0]:
                    i, j = int(dst[m]), int(src[m])
                    pj = float(A[j].sum())
                    lam = float((A[j] * E[m]).sum() / pj) if pj > 0 else 0.0
                    stage = (float((A[j] * self.age_days).sum() / pj) - self.p["onset_days"]) if pj > 0 else None
                    room = pr["room"][m]
                    vol, ach = self.rooms.get(room, (None, None)) if room else (None, None)
                    entry = (float(contrib[m]), {
                        "n": n, "other": self.ids[j],
                        "min": round(float(pr["min"][m]), 1),
                        "dist": round(float(pr["dist"][m]), 2),
                        "dmin": round(float(pr["dmin"][m]), 2),
                        "outdoor_min": round(float(pr["out_min"][m]), 1),
                        "room": room or None,
                        "room_m3": vol, "ach": ach,
                        "rh_out": self.weather[day]["outdoor_rh"],
                        "rh_in": round(self.weather[day]["indoor_rh"], 1),
                        "p_other": round(pj, 4),
                        "p_self_s": round(float(S[i]), 4),
                        "stage": None if stage is None else round(stage, 1),
                        "lam": round(lam, 5),
                        "lam_peak": round(float(-math.expm1(-fr.QUANTA_PEAK * self.p["lambda_scale"]
                                                         * pr["D"][m] * self.stage.max())), 5),
                        "contrib": round(float(contrib[m]), 5),
                    })
                    lst = best[i]
                    if len(lst) < k:
                        lst.append(entry)
                        lst.sort(key=lambda e: -e[0])
                    elif entry[0] > lst[-1][0]:
                        lst[-1] = entry
                        lst.sort(key=lambda e: -e[0])
        return [[e[1] for e in lst] for lst in best]

    # ------------------------------------------------------------ truth
    def truth(self):
        """Ground truth for scoring only: infected (E or I_*) at the end of each step."""
        path = os.path.join(self.run, "timeline_changes.csv.gz")
        inf = np.zeros((self.n_steps, self.N), dtype=bool)
        if not os.path.exists(path):
            return None, {}
        last = {}
        changes = defaultdict(list)          # agent -> [(t, infected)]
        for r in read_csv(path):
            i = self.idx[r["agent_id"]]
            s = r["disease_state"] not in ("S", "R")
            if last.get(i) != s:
                changes[i].append((int(r["t"]), s))
                last[i] = s
        ends = (np.arange(self.n_steps) + 1) * self.W - 1
        for i, ch in changes.items():
            for (t, s), nxt in zip(ch, ch[1:] + [(10**9, None)]):
                if s:
                    inf[(ends >= t) & (ends < nxt[0]), i] = True
        first = {}
        for r in read_csv(os.path.join(self.run, "infections.csv")):
            first.setdefault(r["infectee_id"], (int(r["t"]), r["route"], r["infector_id"]))
        return inf, first


def auc(score, label):
    pos, neg = label.sum(), (~label).sum()
    if pos == 0 or neg == 0:
        return None
    order = np.argsort(score, kind="mergesort")
    ranks = np.empty(len(score))
    s = score[order]
    # average ranks for ties
    i = 0
    r = np.arange(1, len(s) + 1, dtype=float)
    while i < len(s):
        j = i
        while j + 1 < len(s) and s[j + 1] == s[i]:
            j += 1
        r[i:j + 1] = (i + j + 2) / 2
        i = j + 1
    ranks[order] = r
    return float((ranks[label].sum() - pos * (pos + 1) / 2) / (pos * neg))


def run_all(m, params):
    """Model pass, explanations, the reports-only baseline, and scores against truth."""
    m.run_model()
    top = m.explain()
    p_now, p_ever = m.p_now, m.p_ever
    # Baseline: the same model with lambda = 0, i.e. only what people reported about
    # themselves or were reported for. The gap is what the contact graph adds.
    m.p["lambda_scale"] = 0.0
    m.run_model()
    p_base = m.p_now
    m.p["lambda_scale"] = params["lambda_scale"]
    m.p_now, m.p_ever = p_now, p_ever
    truth, first = m.truth()

    metrics = []
    if truth is not None:
        reported = np.zeros(m.N, dtype=bool)
        for n in range(m.n_steps):
            for _, i in m.obs.get(n, []):
                reported[i] = True
            x = {"n": n, "expected": float(p_now[n].sum()), "actual": int(truth[n].sum()),
                 "random50": round(50 * truth[n].mean(), 1)}
            for name, P in (("", p_now[n]), ("base_", p_base[n])):
                x[name + "auc"] = auc(P, truth[n])
                # people with nothing reported yet: only contacts can point at them
                x[name + "auc_unreported"] = auc(P[~reported], truth[n][~reported])
                # of the 50 highest P(flu), how many are infected (the paper's test-allocation view)?
                x[name + "top50_hits"] = int(truth[n][np.argsort(-P, kind="stable")[:50]].sum())
            x["unreported_infected"] = int(truth[n][~reported].sum())
            metrics.append(x)
    return p_now, p_base, truth, first, top, metrics


def print_metrics(metrics, params):
    if not metrics:
        return
    print("\n                         contacts + reports   |  reports only")
    print("day  sum P  infected   AUC  AUC-unrep  top50  |  AUC  AUC-unrep  top50  (random 50)")
    per_day = int(round(24 / params["dt_h"]))
    f = lambda v: "  -  " if v is None else f"{v:.3f}"
    for x in metrics[per_day - 1::per_day]:
        print(f"{(x['n'] + 1) // per_day:>3}  {x['expected']:>5.0f}  {x['actual']:>8}  {f(x['auc'])}  "
              f"{f(x['auc_unreported']):>9}  {x['top50_hits']:>5}  |  {f(x['base_auc'])}  "
              f"{f(x['base_auc_unreported']):>9}  {x['base_top50_hits']:>5}  ({x['random50']})")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run", help="sim run folder, e.g. sim/runs/<run_id>")
    ap.add_argument("--out", help="output folder (default exposure/network/out/<run_id>)")
    for k, v in PARAMS.items():
        ap.add_argument("--" + k.replace("_", "-"), type=type(v), default=v)
    a = ap.parse_args()
    params = {k: getattr(a, k) for k in PARAMS}
    run = a.run.rstrip("/")
    run_id = os.path.basename(run)
    out = a.out or os.path.join(HERE, "out", run_id)

    m = Model(run, params)
    p_now, p_base, truth, first, top, metrics = run_all(m, params)
    p_ever = m.p_ever

    os.makedirs(out, exist_ok=True)
    data = {
        "run_id": run_id,
        "start": m.cfg["start"],
        "dt_h": params["dt_h"],
        "n_steps": m.n_steps,
        "params": params,
        "constants": {k: getattr(fr, k) for k in
                      ("BREATHING_RATE", "QUANTA_PEAK", "DEFAULT_ACH", "DEPOSITION", "CEILING",
                       "NEAR_FIELD_Q", "OUTDOOR_NEAR_DILUTION")},
        "stage_curve": [round(float(x), 4) for x in m.stage],
        "age_days": [round(float(x), 3) for x in m.age_days],
        "weather": m.weather,
        "ids": m.ids,
        "p_now": [[round(float(x), 4) for x in row] for row in p_now.T],
        "p_ever": [[round(float(x), 4) for x in row] for row in p_ever.T],
        "p_base": [[round(float(x), 4) for x in row] for row in p_base.T],
        "truth": None if truth is None else ["".join("1" if v else "0" for v in col) for col in truth.T],
        "infected_at": {k: list(v) for k, v in first.items()},
        "evidence": {m.ids[i]: v for i, v in m.evidence.items()},
        "step_min": m.step_min,
        "top": top,
        "metrics": metrics,
        "counts": {"contact_rows": m.n_rows, "wall_rows": m.n_wall},
    }
    with open(os.path.join(out, "data.js"), "w") as f:
        f.write("window.NET_DATA = ")
        json.dump(data, f, separators=(",", ":"))
        f.write(";\n")

    print(f"\nwrote {os.path.relpath(os.path.join(out, 'data.js'))}")
    print_metrics(metrics, params)


if __name__ == "__main__":
    main()
