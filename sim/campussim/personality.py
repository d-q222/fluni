"""Big Five personalities (docs/AGENT_FRAMEWORK.md, section 1). Off unless personality.mode = "big_five".

Each agent draws openness, conscientiousness, extraversion, agreeableness and neuroticism in [0, 1]
from a Beta per archetype (mean `big_five_mean[archetype][trait]`, concentration `concentration`).
The existing traits are then derived from those scores instead of their own Betas:

  logit(trait_i) = b[archetype, trait] + sum_k w[trait, k] * (score_ik - mean[archetype, k]) + noise_sd * eps_i

for compliance, mask_propensity and honesty. Sick response is a softmax over (stay home, Vaden,
carry on) with log(sick_profile_p[archetype]) as the base, and `social_scale` (a per-agent multiplier
on party / event / hangout rates) is exp(w . (score - mean)). Intercepts are solved per archetype on a
fixed quadrature sample, so each archetype's mean trait equals today's (the *_beta means and
sick_profile_p in population.json): the archetype sets the average, Big Five sets who varies around it.

The weights are reasoned directions (placeholders), to be replaced by fitted ones from the
calibration loop. Draws use their own RNG stream, so dorms, friend groups, teams and schedules are
the same as with personality off.
"""
import zlib

import numpy as np
import pandas as pd

from . import codes

TRAITS = ["openness", "conscientiousness", "extraversion", "agreeableness", "neuroticism"]
LEVEL_WORDS = {
    "openness": ("prefer the familiar", "are fairly open to new things", "love new ideas and experiences"),
    "conscientiousness": ("are disorganized and spontaneous", "are reasonably organized", "are very organized and disciplined"),
    "extraversion": ("are introverted and recharge alone", "are neither very outgoing nor shy", "are very outgoing and get energy from people"),
    "agreeableness": ("are blunt and skeptical of others", "are generally easygoing", "are warm and eager to keep people happy"),
    "neuroticism": ("are calm and rarely worry", "worry now and then", "are anxious and worry a lot"),
}
_QUAD_N = 4000


def is_on(cfg):
    return cfg.get("personality", {}).get("mode", "off") == "big_five"


def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def _logit(p):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return np.log(p / (1 - p))


def _lin(w, dz):
    """w . dz for weights {trait: weight} and dz (n, 5) centered scores."""
    return sum(float(w.get(t, 0.0)) * dz[:, k] for k, t in enumerate(TRAITS))


def _solve_intercept(target, lin):
    """b with mean(sigmoid(b + lin)) == target (bisection; lin is a fixed sample)."""
    lo, hi = -20.0, 20.0
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        if _sigmoid(mid + lin).mean() < target:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


class Personality:
    def __init__(self, cfg):
        self.c = cfg["personality"]
        ap = cfg["population"]["archetypes"]
        self.mu = np.array([[float(self.c["big_five_mean"][a][t]) for t in TRAITS] for a in codes.ARCHETYPES])
        self.kappa = float(self.c["concentration"])
        self.noise = float(self.c["noise_sd"])
        self.w = self.c["weights"]
        mean = lambda ab: ab[0] / (ab[0] + ab[1])  # noqa: E731
        self.target = {t: np.array([mean(ap[a][f"{t}_beta"]) for a in codes.ARCHETYPES])
                       for t in ("compliance", "mask_propensity", "honesty")}
        sp = np.array([ap[a]["sick_profile_p"] for a in codes.ARCHETYPES], float)
        self.sick_p = sp / sp.sum(axis=1, keepdims=True)
        self._solve()

    def _draw(self, rng, a, n):
        m = np.clip(self.mu[a], 0.02, 0.98)
        return rng.beta(m * self.kappa, (1 - m) * self.kappa, size=(n, len(TRAITS)))

    def _solve(self):
        """Per-archetype intercepts on a fixed sample (the same for every run and seed)."""
        q = np.random.default_rng(zlib.crc32(b"personality-quadrature"))
        self.b, self.sick_b, self.social_norm = {}, [], []
        for t in self.target:
            self.b[t] = np.zeros(len(codes.ARCHETYPES))
        for a in range(len(codes.ARCHETYPES)):
            dz = self._draw(q, a, _QUAD_N) - self.mu[a]
            eps = q.standard_normal(_QUAD_N)
            for t in self.target:
                self.b[t][a] = _solve_intercept(self.target[t][a], _lin(self.w[t], dz) + self.noise * eps)
            # sick response: shift the base log-probs so the archetype's mean probabilities match
            base = np.log(np.clip(self.sick_p[a], 1e-6, None))
            lin = np.stack([_lin(self.w["sick_stay_home"], dz), _lin(self.w["sick_vaden"], dz), np.zeros(_QUAD_N)], 1)
            for _ in range(200):
                P = self._softmax(base + lin)
                base += np.log(np.clip(self.sick_p[a], 1e-9, None)) - np.log(P.mean(0))
            self.sick_b.append(base)
            self.social_norm.append(float(np.exp(_lin(self.w["social_scale"], dz)).mean()))
        self.sick_b = np.array(self.sick_b)

    @staticmethod
    def _softmax(x):
        e = np.exp(x - x.max(axis=1, keepdims=True))
        return e / e.sum(axis=1, keepdims=True)

    def apply(self, cfg, pop):
        """Draws Big Five and overwrites pop's traits (and has_app / shares_location, which depend on them)."""
        N, arch = pop.N, np.asarray(pop.archetype, np.int64)
        pcfg = cfg["population"]
        rng = np.random.default_rng([int(cfg["run"]["seed"]), zlib.crc32(b"personality")])
        scores = np.zeros((N, len(TRAITS)))
        for a in range(len(codes.ARCHETYPES)):
            m = np.flatnonzero(arch == a)
            scores[m] = self._draw(rng, a, len(m))
        dz = scores - self.mu[arch]
        eps = rng.standard_normal((N, 3))
        for k, t in enumerate(("compliance", "mask_propensity", "honesty")):
            setattr(pop, t, _sigmoid(self.b[t][arch] + _lin(self.w[t], dz) + self.noise * eps[:, k]))
        lin = np.stack([_lin(self.w["sick_stay_home"], dz), _lin(self.w["sick_vaden"], dz), np.zeros(N)], 1)
        P = self._softmax(self.sick_b[arch] + lin)
        u = rng.random(N)
        pop.sick_profile = np.minimum((u[:, None] > np.cumsum(P, axis=1)).sum(axis=1), P.shape[1] - 1).astype(np.int8)
        wsp = float(pcfg.get("sick_profile_weight", 0.5))
        pop.sick_response_p = (1 - wsp) * P + wsp * np.eye(P.shape[1])[pop.sick_profile]
        smax = float(self.c["social_scale_max"])
        pop.social_scale = np.clip(np.exp(_lin(self.w["social_scale"], dz)) / np.array(self.social_norm)[arch],
                                   1 / smax, smax)
        # app ownership and location sharing, as in build_population but from the derived traits
        comp, hon = pop.compliance, pop.honesty
        app_rate = float(pcfg["has_app_rate"])
        p_app = np.clip(app_rate + pcfg.get("has_app_compliance_slope", 0.0) * (comp - comp.mean()), 0.01, 0.99)
        pop.has_app = rng.random(N) < p_app
        share_c = min(1.0, float(pcfg["shares_location_rate"]) / max(app_rate, 1e-9))
        p_share = np.clip(share_c + pcfg.get("shares_location_honesty_slope", 0.0) * (hon - hon.mean()), 0.0, 1.0)
        pop.shares_location = pop.has_app & (rng.random(N) < p_share)
        pop.big_five = scores
        return pop


def describe(scores):
    """One sentence about a Big Five score vector, for Claude agents' personas."""
    words = [LEVEL_WORDS[t][0 if s < 0.35 else 1 if s < 0.65 else 2] for t, s in zip(TRAITS, scores)]
    return "In personality you " + ", ".join(words[:-1]) + ", and " + words[-1] + "."


def frame(pop):
    """personality.csv: agent_id, the five scores and the derived social_scale."""
    df = pd.DataFrame(np.round(pop.big_five, 4), columns=TRAITS)
    df.insert(0, "agent_id", pop.agent_id)
    df["social_scale"] = np.round(pop.social_scale, 4)
    return df
