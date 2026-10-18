"""Synthetic student population (CONTRACT §2).

build_population(cfg, campus, rng) -> Population. All archetype behavior lives in
cfg["population"]["archetypes"][name][param]; other modules read it via pop.param(name).

param() shapes: scalar -> (N,); list -> (N, k); dict -> (N, k) with keys in pop.param_keys(name)
(flex_weights uses Population.FLEX_KEYS). class_year is 1..4 internally (1 = freshman);
output graduation year = GRAD_YEAR_BASE - class_year (2026..2029).
"""
import warnings
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from . import codes

GRAD_YEAR_BASE = 2030          # class_year 1 (freshman) -> 2029, 4 (senior) -> 2026
FLEX_KEYS = ["library", "dorm_study", "common_room", "gym", "outdoor", "lab", "home"]
STATIC_COLUMNS = ["agent_id", "archetype", "class_year", "home_dorm", "home_room_id", "class_schedule",
                  "friend_group_id", "team_id", "transport_mode", "mask_propensity", "compliance", "honesty",
                  "has_app", "shares_location", "sickness_behavior_profile"]


@dataclass
class Population:
    N: int
    agent_id: list
    archetype: np.ndarray
    class_year: np.ndarray
    home_b: np.ndarray
    home_room: np.ndarray
    bed_slot: np.ndarray
    friend_group: np.ndarray
    team_id: np.ndarray
    teams: list
    transport: np.ndarray
    speed_mps: np.ndarray              # speed of the agent's own mode (transport)
    mask_propensity: np.ndarray
    compliance: np.ndarray
    honesty: np.ndarray
    has_app: np.ndarray
    shares_location: np.ndarray
    sick_profile: np.ndarray
    sick_response_p: np.ndarray        # (N, 3) per-episode response probs, order codes.SICK_PROFILES
    entry_e: np.ndarray
    fav_dining: np.ndarray
    fav_library: np.ndarray
    fav_common: np.ndarray
    class_schedule: list
    arch_params: dict                   # cfg["population"]["archetypes"]
    walk_speed: np.ndarray = None       # per-mode speeds (m/s); None -> speed_mps for both
    bike_speed: np.ndarray = None
    big_five: np.ndarray = None         # (N, 5) personality.TRAITS when personality.mode = big_five
    social_scale: np.ndarray = None     # (N,) multiplier on party/event/hangout rates (big_five), else None
    FLEX_KEYS: list = field(default_factory=lambda: list(FLEX_KEYS))
    _param_cache: dict = field(default_factory=dict, repr=False)
    _param_keys: dict = field(default_factory=dict, repr=False)

    # ---------------------------------------------------------------- params
    def param_keys(self, name):
        """Fixed key order for dict-valued params (None for scalars/lists)."""
        self.param(name)
        return self._param_keys.get(name)

    def param(self, name):
        """Per-agent value of archetype param `name`: scalar->(N,), list->(N,k), dict->(N,k)."""
        if name in self._param_cache:
            return self._param_cache[name]
        vals = []
        keys = None
        for a in codes.ARCHETYPES:
            if a not in self.arch_params or name not in self.arch_params[a]:
                raise KeyError(f"archetype {a!r} has no param {name!r}")
            v = self.arch_params[a][name]
            if isinstance(v, dict):
                if keys is None:
                    keys = FLEX_KEYS if name == "flex_weights" else list(v.keys())
                v = [float(v.get(k, 0.0)) for k in keys]
            vals.append(v)
        if all(isinstance(v, bool) for v in vals):
            table = np.array(vals, dtype=bool)
        else:
            table = np.array(vals, dtype=float)
        out = table[self.archetype]
        out.setflags(write=False)
        self._param_cache[name] = out
        if keys is not None:
            self._param_keys[name] = list(keys)
        return out

    @property
    def is_commuter(self):
        return self.home_b < 0

    @property
    def grad_year(self):
        return (GRAD_YEAR_BASE - self.class_year.astype(int)).astype(int)

    # ---------------------------------------------------------------- output
    def _fmt_ids(self, prefix, ids):
        n = int(ids.max()) + 1 if len(ids) and ids.max() >= 0 else 1
        w = max(2, len(str(n - 1)))
        return [f"{prefix}{i:0{w}d}" if i >= 0 else "" for i in ids]

    def team_label(self, k):
        w = max(2, len(str(max(len(self.teams), 1) - 1)))
        return f"TM{k:0{w}d}"

    def to_frame(self, campus, sections=None):
        """agents_static.csv rows, exact d2 columns."""
        bname = campus.buildings["name"].to_numpy()
        room_ids = campus.rooms["room_id"].to_numpy()
        sec_ids = sections["section_id"].to_numpy() if sections is not None and len(sections) else None
        sched = []
        for s in self.class_schedule:
            sched.append("|".join(str(sec_ids[j]) for j in s) if (sec_ids is not None and s) else "")
        home_dorm = np.where(self.home_b >= 0, bname[np.maximum(self.home_b, 0)], "OFF_CAMPUS")
        home_room = np.where(self.home_room >= 0, room_ids[np.maximum(self.home_room, 0)], "")
        df = pd.DataFrame({
            "agent_id": self.agent_id,
            "archetype": np.array(codes.ARCHETYPES)[self.archetype],
            "class_year": self.grad_year,
            "home_dorm": home_dorm,
            "home_room_id": home_room,
            "class_schedule": sched,
            "friend_group_id": self._fmt_ids("FG", self.friend_group),
            "team_id": [self.team_label(k) if k >= 0 else "" for k in self.team_id],
            "transport_mode": np.array(codes.TRANSPORT)[self.transport],
            "mask_propensity": np.round(self.mask_propensity, 3),
            "compliance": np.round(self.compliance, 3),
            "honesty": np.round(self.honesty, 3),
            "has_app": self.has_app.astype(bool),
            "shares_location": self.shares_location.astype(bool),
            "sickness_behavior_profile": np.array(codes.SICK_PROFILES)[self.sick_profile],
        })
        return df[STATIC_COLUMNS]

    def extras_frame(self, campus):
        """Non-d2 per-agent extras (not part of agents_static.csv)."""
        ent = campus.entry_points["entry_id"].to_numpy()
        loc = campus.buildings["location_id"].to_numpy()

        def bl(arr):
            return np.where(arr >= 0, loc[np.maximum(arr, 0)], "")
        return pd.DataFrame({
            "agent_id": self.agent_id,
            "bed_slot": self.bed_slot,
            "speed_mps": np.round(self.speed_mps, 3),
            "entry_id": np.where(self.entry_e >= 0, ent[np.maximum(self.entry_e, 0)], ""),
            "sport": [self.teams[k]["sport"] if k >= 0 else "" for k in self.team_id],
            "fav_dining": bl(self.fav_dining), "fav_library": bl(self.fav_library),
            "fav_common": bl(self.fav_common),
            "p_stay_home": np.round(self.sick_response_p[:, 0], 3),
            "p_visit_vaden": np.round(self.sick_response_p[:, 1], 3),
            "p_carry_on": np.round(self.sick_response_p[:, 2], 3),
        })


# ==================================================================== helpers
def largest_remainder(weights, total):
    """Integer counts summing to `total`, proportional to weights (ties -> lower index)."""
    w = np.asarray(weights, dtype=float)
    if total <= 0 or w.sum() <= 0:
        return np.zeros(len(w), dtype=int)
    q = w / w.sum() * total
    base = np.floor(q).astype(int)
    rem = total - base.sum()
    order = np.lexsort((np.arange(len(w)), -(q - base)))
    base[order[:rem]] += 1
    return base


def _beta(rng, ab, n):
    a, b = ab
    return rng.beta(a, b, size=n)


def _assign_dorms(campus, resident_idx, rng, home_b, home_room, bed_slot, mode="fill"):
    """mode "fill": fill dorms one after another in a random order (a small run lands in 1-3 dorms).
    mode "spread": fill whole bedrooms drawn at random from all dorms (spread ~ dorm capacity)."""
    dorms = np.asarray(campus.buildings_of_type("dorm"), dtype=int)
    bedtypes = set(codes.BEDROOM_TYPES)
    rtype = campus.rooms["room_type"].to_numpy()
    if mode == "spread":
        rooms = [(int(b), int(r)) for b in dorms for r in campus.rooms_of(int(b)) if rtype[r] in bedtypes]
        rooms = [rooms[j] for j in rng.permutation(len(rooms))]
        beds = [(b, r, s) for b, r in rooms for s in range(int(campus.room_cap[r]))]
        _fill_beds(beds, resident_idx, home_b, home_room, bed_slot)
        return
    if mode != "fill":
        raise ValueError(f"population.housing.assignment must be 'fill' or 'spread', not {mode!r}")
    order = dorms[rng.permutation(len(dorms))] if len(dorms) else dorms
    beds_by_dorm = []
    for b in order:
        rr = [int(r) for r in campus.rooms_of(int(b)) if rtype[r] in bedtypes]
        beds = [(int(b), r, s) for r in rr for s in range(int(campus.room_cap[r]))]
        if beds:
            beds_by_dorm.append(beds)
    n_res = len(resident_idx)
    if n_res == 0:
        return
    if not beds_by_dorm:
        raise ValueError("campus has no dorm bedrooms")
    # small-N rule: put the first dorm that can hold everyone (if any) first
    caps = [len(x) for x in beds_by_dorm]
    big = [i for i, c in enumerate(caps) if c >= n_res]
    if big and big[0] != 0:
        beds_by_dorm.insert(0, beds_by_dorm.pop(big[0]))
    _fill_beds([x for d in beds_by_dorm for x in d], resident_idx, home_b, home_room, bed_slot)


def _fill_beds(beds, resident_idx, home_b, home_room, bed_slot):
    n_res = len(resident_idx)
    if n_res and not beds:
        raise ValueError("campus has no dorm bedrooms")
    if n_res > len(beds):
        warnings.warn(f"population: {n_res} residents but only {len(beds)} dorm beds; overfilling cyclically")
    occ = {}
    for k, i in enumerate(resident_idx):
        b, r, _ = beds[k % len(beds)]
        home_b[i], home_room[i] = b, r
        bed_slot[i] = occ.get(r, 0)
        occ[r] = occ.get(r, 0) + 1


def _friend_groups(pcfg, archetype, home_b, rng):
    """Mostly same-dorm, similar-archetype groups; commuters grouped together (home_b=-1)."""
    N = len(archetype)
    sizes_cfg = pcfg["friend_group_size"]
    group = np.full(N, -1, dtype=np.int64)
    noise = rng.random(N)
    order = np.lexsort((noise, archetype, home_b))   # by dorm, then archetype, random within
    g = 0
    k = 0
    last = -1
    keys = home_b[order]
    while k < N:
        dorm = keys[k]
        end_dorm = k
        while end_dorm < N and keys[end_dorm] == dorm:
            end_dorm += 1
        start = k
        while start < end_dorm:
            a = codes.ARCHETYPES[archetype[order[start]]]
            lo, hi = sizes_cfg[a]
            sz = int(rng.integers(lo, hi + 1))
            stop = min(start + sz, end_dorm)
            if stop - start == 1 and last >= 0:      # no singleton leftovers
                group[order[start]] = last
            else:
                group[order[start:stop]] = g
                last = g
                g += 1
            start = stop
        k = end_dorm
    # a block that produced a lone singleton (e.g. 1 commuter at small N) joins its neighbor's group
    if g > 1:
        sizes = np.bincount(group, minlength=g)
        pos = np.empty(N, dtype=np.int64)
        pos[order] = np.arange(N)
        for i in np.flatnonzero(sizes[group] == 1):
            j = pos[i]
            nb = order[j + 1] if j + 1 < N else order[j - 1]
            group[i] = group[nb]
    # cross-dorm / cross-archetype mixing: permute group labels among a random subset
    mix = np.flatnonzero(rng.random(N) < pcfg.get("friend_group_mix_p", 0.0))
    if len(mix) > 1:
        group[mix] = group[mix][rng.permutation(len(mix))]
    # renumber by first appearance in agent order
    _, first = np.unique(group, return_index=True)
    labels = group[np.sort(first)]
    remap = {int(old): new for new, old in enumerate(labels)}
    return np.array([remap[int(x)] for x in group], dtype=np.int32)


def _teams(pcfg, campus, athletes, rng):
    tcfg = pcfg["teams"]
    team_of = {}
    if len(athletes) == 0 or not tcfg:
        return [], team_of
    targets = [int(rng.integers(t["size"][0], t["size"][1] + 1)) for t in tcfg]
    counts = largest_remainder(targets, len(athletes))
    rtype = campus.rooms["room_type"].to_numpy()
    ptypes = set(pcfg.get("practice_room_types", ["practice_gym", "arena", "pool", "outdoor_area"]))
    ftypes = set(pcfg.get("fallback_practice_room_types", list(ptypes) + ["weight_room"]))
    fallback = [int(r) for b in campus.buildings_of_type("gym") for r in campus.rooms_of(int(b))
                if rtype[r] in ftypes]
    if not fallback:
        fallback = [int(r) for b in campus.buildings_of_type("gym") for r in campus.rooms_of(int(b))]
    perm = athletes[rng.permutation(len(athletes))]
    teams = []
    pos = 0
    for t, c in zip(tcfg, counts):
        if c == 0:
            continue
        b = campus.find_building(t["practice_venue"])
        rooms = []
        if b >= 0:
            rooms = [int(r) for r in campus.rooms_of(b) if rtype[r] in ptypes]
        if not rooms:
            rooms = list(fallback)
        k = len(teams)
        teams.append({"name": f"Stanford {t['sport'].replace('_', ' ').title()}", "sport": t["sport"],
                      "venue": t["practice_venue"], "venue_b": int(b) if b >= 0 and rooms != fallback else -1,
                      "practice_rooms": rooms, "members": sorted(int(i) for i in perm[pos:pos + c])})
        for i in perm[pos:pos + c]:
            team_of[int(i)] = k
        pos += c
    return teams, team_of


def _favorites(campus, btype, home_b, pcfg, rng):
    """Nearest building of `btype` to home (straight line), sometimes one of the k nearest; random for commuters."""
    N = len(home_b)
    cand = np.asarray(campus.buildings_of_type(btype), dtype=int)
    if len(cand) == 0:
        return np.full(N, -1, dtype=np.int32)
    k = min(int(pcfg.get("fav_nearest_k", 3)), len(cand))
    bx, by = np.asarray(campus.b_x, float), np.asarray(campus.b_y, float)
    hb = np.maximum(home_b, 0)
    d = np.hypot(bx[hb][:, None] - bx[cand][None, :], by[hb][:, None] - by[cand][None, :])
    near = np.argsort(d, axis=1, kind="stable")[:, :k]
    pick = np.where(rng.random(N) < pcfg.get("fav_random_p", 0.25), rng.integers(0, k, N), 0)
    out = cand[near[np.arange(N), pick]]
    rand = cand[rng.integers(0, len(cand), N)]
    out = np.where(home_b < 0, rand, out)
    return out.astype(np.int32)


# ==================================================================== builder
def build_population(cfg, campus, rng) -> Population:
    pcfg = cfg["population"]
    N = int(cfg["run"]["n_agents"])
    A = codes.ARCHETYPES
    ap = pcfg["archetypes"]

    # archetypes: exact largest-remainder counts, seeded shuffle
    fr = pcfg["archetype_fractions"]
    counts = largest_remainder([fr.get(a, 0.0) for a in A], N)
    archetype = np.repeat(np.arange(len(A)), counts).astype(np.int8)
    archetype = archetype[rng.permutation(N)]

    # class year (1..4) from graduation-year fractions
    cyf = pcfg["class_year_fractions"]
    grad = sorted(int(y) for y in cyf)
    p = np.array([cyf[str(y)] for y in grad], float)
    gy = np.array(grad)[rng.choice(len(grad), size=N, p=p / p.sum())]
    class_year = (GRAD_YEAR_BASE - gy).astype(np.int8)

    # housing
    commuter = np.array([bool(ap[A[a]]["commuter"]) for a in range(len(A))])[archetype]
    home_b = np.full(N, -1, dtype=np.int32)
    home_room = np.full(N, -1, dtype=np.int32)
    bed_slot = np.zeros(N, dtype=np.int8)
    mode = pcfg.get("housing", {}).get("assignment", "fill")   # not in population.json: keeps run ids
    _assign_dorms(campus, np.flatnonzero(~commuter), rng, home_b, home_room, bed_slot, mode)
    n_entry = len(campus.entry_points)
    entry_e = np.full(N, -1, dtype=np.int32)
    if commuter.any():
        if n_entry == 0:
            raise ValueError("campus has no entry points for commuters")
        entry_e[commuter] = rng.integers(0, n_entry, int(commuter.sum()))

    # attributes (beta per archetype)
    mask = np.zeros(N)
    comp = np.zeros(N)
    hon = np.zeros(N)
    for a_i, a in enumerate(A):
        m = archetype == a_i
        n = int(m.sum())
        mask[m] = _beta(rng, ap[a]["mask_propensity_beta"], n)
        comp[m] = _beta(rng, ap[a]["compliance_beta"], n)
        hon[m] = _beta(rng, ap[a]["honesty_beta"], n)
    app_rate = float(pcfg["has_app_rate"])
    p_app = np.clip(app_rate + pcfg.get("has_app_compliance_slope", 0.0) * (comp - comp.mean()), 0.01, 0.99)
    has_app = rng.random(N) < p_app
    share_c = min(1.0, float(pcfg["shares_location_rate"]) / max(app_rate, 1e-9))
    p_share = np.clip(share_c + pcfg.get("shares_location_honesty_slope", 0.0) * (hon - hon.mean()), 0.0, 1.0)
    shares = has_app & (rng.random(N) < p_share)

    # sickness profile: dominant response per agent + per-episode probs shifted toward it
    sp = np.array([ap[a]["sick_profile_p"] for a in A], float)
    sp = sp / sp.sum(axis=1, keepdims=True)
    P = sp[archetype]
    u = rng.random(N)
    sick_profile = np.minimum((u[:, None] > np.cumsum(P, axis=1)).sum(axis=1), P.shape[1] - 1).astype(np.int8)
    w = float(pcfg.get("sick_profile_weight", 0.5))
    sick_response_p = (1 - w) * P + w * np.eye(P.shape[1])[sick_profile]

    # social structure
    friend_group = _friend_groups(pcfg, archetype, home_b.astype(np.int64), rng)
    teams, team_of = _teams(pcfg, campus, np.flatnonzero(archetype == A.index("athlete")), rng)
    team_id = np.full(N, -1, dtype=np.int32)
    for i, k in team_of.items():
        team_id[i] = k

    # transport
    bike_p = np.array([ap[a]["bike_p"] for a in A], float)[archetype]
    transport = (rng.random(N) < bike_p).astype(np.int8)        # codes.TRANSPORT: 0 walk, 1 bike
    base = np.where(transport == 1, pcfg.get("bike_mps", 4.5), pcfg.get("walk_mps", 1.3))
    jit = np.clip(rng.normal(1.0, pcfg.get("speed_jitter_sd", 0.1), N), 0.7, 1.3)
    speed = base * jit
    walk_speed = pcfg.get("walk_mps", 1.3) * jit                # short hops: bike owners walk too
    bike_speed = pcfg.get("bike_mps", 4.5) * jit

    fav_dining = _favorites(campus, "dining", home_b, pcfg, rng)
    fav_library = _favorites(campus, "library", home_b, pcfg, rng)
    fav_common = _favorites(campus, "common_room", home_b, pcfg, rng)

    w_id = max(4, len(str(N - 1)))
    pop = Population(
        N=N, agent_id=[f"A{i:0{w_id}d}" for i in range(N)], archetype=archetype, class_year=class_year,
        home_b=home_b, home_room=home_room, bed_slot=bed_slot, friend_group=friend_group,
        team_id=team_id, teams=teams, transport=transport, speed_mps=speed,
        walk_speed=walk_speed, bike_speed=bike_speed,
        mask_propensity=mask, compliance=comp, honesty=hon, has_app=has_app, shares_location=shares,
        sick_profile=sick_profile, sick_response_p=sick_response_p, entry_e=entry_e,
        fav_dining=fav_dining, fav_library=fav_library, fav_common=fav_common,
        class_schedule=[[] for _ in range(N)], arch_params=ap,
    )
    from . import personality
    if personality.is_on(cfg):
        personality.Personality(cfg).apply(cfg, pop)
    return pop
