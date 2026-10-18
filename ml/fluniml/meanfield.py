"""Simple probabilistic baseline: mean-field forward propagation of P(infected), hour by hour.

For every agent i it tracks p_i(s) = P(i newly infected in hour s), starting from p = 1 at hour 0
for the seeds. Each hour h:

    iota_j(h) = sum_{s<=h} p_j(s) * f(h - s)            expected infectiousness of j
    H_i(h)    = sum_{contacts (i,j) in hour h} iota_j(h) * rate_ij(h)  +  theta_imp
    rate_ij   = theta_close * sum_k w_k (in_k + 0.2 out_k)  +  theta_room * room_share_minutes
    p_i(h+1)  = S_i(h) * (1 - exp(-H_i(h))),   S_i(h+1) = S_i(h) * exp(-H_i(h))

f(lag) is the sim's mean infectiousness curve (latent/presym/post-onset gammas, viral-load ramp,
asymptomatic share, individual multiplier), and w_k are the sim's per-minute tier hazards, both read
from the run's config. That is the "known physics" part. Three numbers are fitted on the training
runs by maximum likelihood: theta_close (the unknown transmission scale), theta_room (stands in for
the shared-air route, which the contacts table only shows as co-presence; room_share divides each
step by the room's occupancy as a stand-in for volume) and theta_imp (imports).

"Mean-field" = it treats agents' infection states as independent, so risk can echo between two
people who meet often (A raises B, B raises A back). That's the known weakness of this baseline.
"""
import numpy as np
from scipy.optimize import minimize

from .data import Run


def infectiousness_kernel(cfg, hours, n=200_000, rng=0):
    """f[lag] = E[infectiousness at lag + 0.5 h after infection], lag = 0..hours-1."""
    dc = cfg["params"]["disease"]
    r = np.random.default_rng(rng)

    def gam(d):
        m, s = d["mean"], d["sd"]
        return r.gamma((m / s) ** 2, s * s / m, n) * 24.0  # hours

    t_inf = gam(dc["latent_days"])
    t_on = t_inf + gam(dc["presym_days"])
    t_end = t_on + gam(dc["infectious_days"])
    k = dc["individual_infectiousness_gamma_shape"]
    mult = np.minimum(r.gamma(k, 1.0 / k, n), dc.get("individual_infectiousness_max", 1e9))
    rel = np.where(r.random(n) < dc["p_asym"], dc["asym_rel_infectiousness"], 1.0) * mult
    vl = dc["viral_load"]
    f = np.zeros(hours)
    for h in range(hours):
        t = h + 0.5
        pre = (t >= t_inf) & (t < t_on)
        post = (t >= t_on) & (t < t_end)
        v = np.zeros(n)
        v[pre] = vl["presym_start_level"] ** (1 - (t - t_inf[pre]) / (t_on - t_inf)[pre])
        v[post] = vl["end_level"] ** ((t - t_on[post]) / (t_end - t_on)[post])
        f[h] = np.mean(v * rel)
    return f


class Compact:
    """The per-run arrays mean-field needs, with edges grouped by hour."""

    def __init__(self, run: Run, w_tier, outdoor_mult):
        ch = run.ch
        cw = (ch[:, 0:3] + outdoor_mult * ch[:, 3:6]) @ w_tier       # close hazard per unit scale
        rm = ch[:, 8]                                                # same-room minutes / occupancy
        keep = (cw > 0) | (rm > 0)
        order = np.argsort(run.hour[keep], kind="stable")
        self.a, self.b = run.a[keep][order], run.b[keep][order]
        self.cw = cw[keep][order].astype(np.float32)
        self.rm = rm[keep][order].astype(np.float32)
        self.offsets = np.searchsorted(run.hour[keep][order], np.arange(run.hours + 1))
        self.hours, self.N, self.seed = run.hours, run.N, run.seed
        self.label, self.scored, self.t_inf = run.label, run.scored, run.t_inf


class MeanField:
    """oracle=True is a reference ceiling, not a competitor: instead of propagating probabilities it
    uses everyone's true infection hours (hidden from real models), so H_i is the hazard i actually
    faced while susceptible and P_i = 1 - exp(-sum H_i). What's left is the sim's coin flips."""

    def __init__(self, cfg, hours, oracle=False):
        self.oracle = oracle
        dc = cfg["params"]["disease"]
        ch = dc["close_hazard_per_min"]
        self.w_tier = np.array([ch["tier1"], ch["tier2"], ch["tier3"]])
        self.outdoor_mult = float(dc["outdoor_multiplier"])
        self.f = infectiousness_kernel(cfg, hours)
        # starting guesses: scale ~2, aerosol ~2e-4 per pair-minute, ~6 imports per 1000 per run
        self.log_theta = np.log([2.0, 2e-4, 2e-5])

    def compact(self, run):
        return Compact(run, self.w_tier, self.outdoor_mult)

    def forward(self, c: Compact, log_theta=None):
        th_c, th_r, th_i = np.exp(self.log_theta if log_theta is None else log_theta)
        H, N = c.hours, c.N
        P = np.zeros((H + 1, N))
        P[0, c.seed] = 1.0
        S = (~c.seed).astype(float)
        if self.oracle:
            inf = np.flatnonzero(c.t_inf >= 0)
            P[np.minimum(c.t_inf[inf] + (~c.seed[inf]), H), inf] = 1.0
            P[0, c.seed] = 1.0
            susceptible_until = np.where(c.t_inf >= 0, c.t_inf, H)
            cum = np.zeros(N)
        rate = th_c * c.cw + th_r * c.rm
        f = self.f
        for h in range(H):
            iota = f[h::-1] @ P[: h + 1]                 # sum_s P[s] * f[h - s]
            lo, hi = c.offsets[h], c.offsets[h + 1]
            a, b, r = c.a[lo:hi], c.b[lo:hi], rate[lo:hi]
            haz = np.bincount(b, iota[a] * r, N) + np.bincount(a, iota[b] * r, N) + th_i
            if self.oracle:
                cum += haz * (h < susceptible_until)
                continue
            q = np.exp(-haz)
            P[h + 1] = S * (1 - q)
            S = S * q
        if self.oracle:
            S = np.exp(-cum)
        return np.where(c.seed, 1.0, 1.0 - S)

    def nll(self, compacts, log_theta):
        tot, n = 0.0, 0
        for c in compacts:
            p = np.clip(self.forward(c, log_theta)[c.scored], 1e-6, 1 - 1e-6)
            y = c.label[c.scored]
            tot += -np.sum(y * np.log(p) + (1 - y) * np.log(1 - p))
            n += len(y)
        return tot / n

    def fit(self, runs, verbose=True):
        return self.fit_compacts([self.compact(r) for r in runs], verbose)

    def fit_compacts(self, compacts, verbose=True):
        it = [0]

        def obj(x):
            v = self.nll(compacts, x)
            it[0] += 1
            if verbose and it[0] % 10 == 0:
                print(f"  eval {it[0]}: nll {v:.4f} theta {np.exp(x)}", flush=True)
            return v

        res = minimize(obj, self.log_theta, method="Nelder-Mead",
                       options=dict(xatol=1e-3, fatol=1e-5, maxfev=200))
        self.log_theta = res.x
        return res

    def predict(self, run):
        return self.forward(self.compact(run))
