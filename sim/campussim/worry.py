"""Worry state and drift (docs/AGENT_FRAMEWORK.md, section 3). Off unless worry.mode = "on".

Every agent has a worry level in [0, 1] that relaxes toward its baseline with a half-life (sim time)
and jumps on events:

  level += jumps[kind] * (1 - level)          kind in KINDS
  level  = baseline + (level - baseline) * 0.5 ** (dt / half_life)

The baseline comes from neuroticism when Big Five is on (pop.big_five), else a per-archetype constant.
Claude agents report worry directly (set_measured). Rule-based effects (compliance in apply_actions,
mask propensity and dropping optional activities in behavior.py) scale with level - baseline, so an
agent at its baseline behaves exactly as without worry. Draws use their own RNG stream.
"""
import zlib

import numpy as np
import pandas as pd

from . import codes
from .personality import TRAITS

KINDS = ("own_symptoms", "friend_sick", "friend_positive", "app_alert", "warning_text", "saw_sick")
COLUMNS = ["t", "agent_id", "worry", "cause"]


def is_on(cfg):
    return cfg.get("worry", {}).get("mode", "off") == "on"


def _shift_logit(p, d):
    """sigmoid(logit(p) + d); p is returned unchanged where d == 0."""
    p = np.asarray(p, float)
    q = np.clip(p, 1e-6, 1 - 1e-6)
    out = 1.0 / (1.0 + np.exp(-(np.log(q / (1 - q)) + d)))
    return np.where(d == 0, p, out)


class Worry:
    def __init__(self, cfg, pop):
        c = self.c = cfg["worry"]
        self.pop, self.N = pop, pop.N
        self.step_min = int(cfg["run"]["step_min"])
        self.spd = 1440 // self.step_min
        self.f = 0.5 ** (self.step_min / (float(c["half_life_days"]) * 1440))   # decay per step
        self.jumps = {k: float(c["jumps"][k]) for k in KINDS}
        self.w = {k: float(v) for k, v in c["effects"].items()}
        self.drop_p_max = float(c["drop_p_max"])
        self.drop_min = float(c.get("drop_min_excess", 0.0))
        self.drop_acts = np.zeros(len(codes.ACTIVITIES), bool)
        self.drop_acts[[codes.ACT[a] for a in c["drop_acts"]]] = True
        self.drop_to_act = codes.ACT[c["drop_to_act"]]
        self.rng = np.random.default_rng([int(cfg["run"]["seed"]), zlib.crc32(b"worry")])
        if getattr(pop, "big_five", None) is not None:
            lo, hi = (float(v) for v in c["neuroticism_baseline"])
            self.baseline = np.clip(lo + (hi - lo) * pop.big_five[:, TRAITS.index("neuroticism")], 0.0, 1.0)
        else:
            ba = np.array([float(c["baseline_archetype"][a]) for a in codes.ARCHETYPES])
            self.baseline = ba[np.asarray(pop.archetype, np.int64)]
        self.level = self.baseline.copy()
        self._t = 0
        self._logged = self.level.copy()
        self._log_eps = float(c["log_min_change"])
        self._hour = max(1, 60 // self.step_min)
        self.log = [(0, i, float(v), "baseline") for i, v in enumerate(self.level)]

    # ---------------------------------------------------------------- state
    def step(self, t):
        """Decay toward baseline up to step t (vectorized); hourly rows for agents that moved."""
        t = int(t)
        self._decay(t)
        if t % self._hour == 0:
            idx = np.flatnonzero(np.abs(self.level - self._logged) > self._log_eps)
            self._note(t, idx, "decay")

    def _decay(self, t):
        if t > self._t:
            self.level = self.baseline + (self.level - self.baseline) * self.f ** (t - self._t)
            self._t = t

    def bump(self, i, kind, t):
        """Jump of jumps[kind] * (1 - level) for agent i (int or array of ints)."""
        if kind not in self.jumps:
            raise ValueError(f"unknown worry kind {kind!r}; have {KINDS}")
        idx = np.unique(np.atleast_1d(np.asarray(i, np.int64)))
        if not len(idx):
            return
        self._decay(int(t))
        self.level[idx] += self.jumps[kind] * (1.0 - self.level[idx])
        self._note(t, idx, kind)

    def set_measured(self, i, value01, t):
        """Claude agents report worry directly: overwrite level (clipped to [0, 1])."""
        self._decay(int(t))
        self.level[int(i)] = float(np.clip(value01, 0.0, 1.0))
        self._note(t, np.array([int(i)]), "measured")

    def _note(self, t, idx, cause):
        if len(idx):
            self._logged[idx] = self.level[idx]
            self.log.extend((int(t), int(i), float(v), cause) for i, v in zip(idx.tolist(), self.level[idx].tolist()))

    # ---------------------------------------------------------------- effects
    def excess(self, idx=slice(None)):
        """level - baseline (0 at baseline)."""
        return self.level[idx] - self.baseline[idx]

    def compliance(self, comp):
        """Effective compliance for all agents: logit shift by effects.compliance * excess."""
        return _shift_logit(comp, self.w["compliance"] * self.excess())

    def mask_propensity(self, idx, p):
        """Effective mask propensity of agents idx (before the activity context factor)."""
        return _shift_logit(p, self.w["mask_propensity"] * self.excess(idx))

    def drop_p(self, idx):
        """P(dropping a planned optional activity) for agents idx."""
        return np.clip(self.w["drop_optional"] * self.excess(idx), 0.0, self.drop_p_max)

    # ---------------------------------------------------------------- output
    def frame(self):
        """worry.csv.gz: t, agent_id, worry, cause (baseline / decay / measured / a bump kind)."""
        df = pd.DataFrame(self.log, columns=["t", "agent", "worry", "cause"])
        df.insert(1, "agent_id", np.asarray(self.pop.agent_id)[df.pop("agent").to_numpy(np.int64)])
        df["worry"] = df["worry"].round(4)
        return df.sort_values(["t", "agent_id"], kind="mergesort").reset_index(drop=True)[COLUMNS]
