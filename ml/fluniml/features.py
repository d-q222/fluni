"""Per-agent feature vectors for the MLP, built only from the contacts table and the seed list.

An MLP sees one agent at a time, so anything about the network has to be written into the
features. No sim formulas are used here (no tier hazards, no infectiousness curve); the MLP has
to learn how much each channel, day and hop matters.

Feature groups (minutes are log1p-transformed):
  activity  total minutes per channel (9); distinct close / same-room partners (2)
  seed      minutes with seeds per channel per day (9 x D); distinct seeds met (1)
  hop2      minutes with "people who had met a seed at least a day earlier", weighted by how much
            seed contact they'd had by then; per day, split close (tiers 1-3) / same room /
            occupancy-weighted same room (3 x D)
  hop3      the same one step further out: contacts' accumulated hop-2 exposure (3 x D)
  run       fraction of agents that are seeds; mean minutes per agent in the run (2)
"""
import numpy as np

from .data import CHANNELS, Run

CLOSE = [0, 1, 2, 3, 4, 5]
ROOM = [0, 1, 2, 7]
SHARE = [8]
HOP_GROUPS = {"close": CLOSE, "room": ROOM, "share": SHARE}
NONWALL = [0, 1, 2, 3, 4, 5, 7]
LAG_H = 24
GROUPS = ("activity", "seed", "hop2", "hop3", "run")
FEATURE_SETS = {
    "activity": ("activity", "run"),
    "seed": ("activity", "seed", "run"),
    "full": GROUPS,
}


def _per_day(run, vals_a, vals_b, D):
    """Scatter per-edge values (E, G) to agents a and b by day -> (N, G * D)."""
    N, G = run.N, vals_a.shape[1]
    day = run.hour // 24
    out = np.zeros((N, D, G))
    np.add.at(out, (run.a, day), vals_a)
    np.add.at(out, (run.b, day), vals_b)
    return out.transpose(0, 2, 1).reshape(N, G * D)


def _cum_lagged(run, per_hour_edge_a, per_hour_edge_b):
    """Cumulative per-agent exposure up to hour h - LAG_H, as an (H, N) table."""
    H, N = run.hours, run.N
    X = np.zeros((H, N))
    np.add.at(X, (run.hour, run.a), per_hour_edge_a)
    np.add.at(X, (run.hour, run.b), per_hour_edge_b)
    C = np.cumsum(X, axis=0)
    L = np.zeros_like(C)
    L[LAG_H:] = C[:-LAG_H]
    return L


def _hop(run, L, D):
    """Contact minutes with each partner, weighted by the partner's lagged exposure table L."""
    cg = np.stack([run.ch[:, g].sum(1) for g in HOP_GROUPS.values()], 1)
    wa = L[run.hour, run.b][:, None] * cg      # exposure arriving at a from b
    wb = L[run.hour, run.a][:, None] * cg
    return _per_day(run, wa, wb, D), wa.sum(1), wb.sum(1)


def agent_features(run: Run, groups=GROUPS):
    D = run.hours // 24
    N = run.N
    ch, a, b, seed = run.ch, run.a, run.b, run.seed.astype(float)
    parts, names = [], []

    if "activity" in groups:
        tot = np.zeros((N, len(CHANNELS)))
        np.add.at(tot, a, ch)
        np.add.at(tot, b, ch)
        close = ch[:, :6].sum(1) > 0
        room = ch[:, ROOM].sum(1) > 0
        pairs_c = np.unique(np.stack([a[close], b[close]], 1), axis=0)
        pairs_r = np.unique(np.stack([a[room], b[room]], 1), axis=0)
        deg = np.zeros((N, 2))
        for k, pr in enumerate([pairs_c, pairs_r]):
            deg[:, k] = np.bincount(pr[:, 0], minlength=N) + np.bincount(pr[:, 1], minlength=N)
        parts += [np.log1p(tot), np.log1p(deg)]
        names += [f"act_{c}" for c in CHANNELS] + ["deg_close", "deg_room"]

    if any(g in groups for g in ("seed", "hop2", "hop3")):
        # minutes with a seed, per edge, credited to the non-seed end
        sa = seed[b][:, None] * ch      # a's minutes with seed b
        sb = seed[a][:, None] * ch

    if "seed" in groups:
        parts.append(np.log1p(_per_day(run, sa, sb, D)))
        names += [f"seed_{c}_d{d}" for c in CHANNELS for d in range(D)]
        met = (ch[:, NONWALL].sum(1) > 0)
        pr = np.unique(np.stack([a[met], b[met]], 1), axis=0)
        n_seeds = (np.bincount(pr[:, 0], seed[pr[:, 1]], N) + np.bincount(pr[:, 1], seed[pr[:, 0]], N))
        parts.append(np.log1p(n_seeds)[:, None])
        names.append("n_seeds_met")

    if "hop2" in groups or "hop3" in groups:
        L1 = _cum_lagged(run, sa[:, NONWALL].sum(1), sb[:, NONWALL].sum(1))
        h2, h2a, h2b = _hop(run, L1, D)
        if "hop2" in groups:
            parts.append(np.log1p(h2))
            names += [f"hop2_{g}_d{d}" for g in HOP_GROUPS for d in range(D)]
        if "hop3" in groups:
            L2 = _cum_lagged(run, h2a, h2b)
            h3, _, _ = _hop(run, L2, D)
            parts.append(np.log1p(h3))
            names += [f"hop3_{g}_d{d}" for g in HOP_GROUPS for d in range(D)]

    if "run" in groups:
        tot_min = ch[:, NONWALL].sum() * 2 / N
        parts.append(np.tile([seed.mean(), np.log1p(tot_min)], (N, 1)))
        names += ["run_seed_frac", "run_mean_minutes"]

    return np.concatenate(parts, 1).astype(np.float32), names
