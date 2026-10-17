"""Per-step ground-truth contacts (CONTRACT section 6, d2 rule).

Pairs reported each step:
  (A) every pair of on-map agents with 2D distance < radius_m (5 m), EXCEPT pairs where both are
      indoors on different floors. Transit and outdoor agents are included; pairs across walls
      (same building but different room, or indoor vs outdoor) are kept and flagged wall=True.
  (B) every same-room pair at any distance (tier 4 when >= 5 m) for rooms with
      capacity <= same_room_max_capacity.

Implementation of (A): one cKDTree over (x, y, z) with z = (floor - ground_floor) * floor_separation_m
for indoor agents and z = 0 for outdoor / transit agents. Indoor agents on different floors are
>= 1000 m apart in 3D and never pair. Outdoor/transit agents sit at ground-floor level, so they pair
(across a wall) with ground-floor indoor agents but NOT with agents on upper floors / basements.
Set "outdoor_any_floor": true in configs/contacts.json to also pair outdoor/transit agents with
indoor agents on every floor (literal reading of the contract; extra 2D query).
(B) is emitted fully vectorized (sort by room, repeat/cumsum), then unioned with (A) and deduped.
"""
import numpy as np
import pandas as pd
from scipy.spatial import cKDTree

from .codes import ROOM_OFF_MAP, ROOM_TRANSIT, TIER_SAME_ROOM_FAR  # noqa: F401  (sentinel docs)

KEYS = ("a", "b", "dist", "tier", "same_room", "r", "bld", "indoor", "wall")
COLUMNS = ["t", "agent_a", "agent_b", "distance_m", "distance_tier", "duration_s",
           "location_id", "room_id", "indoor"]


def empty_contacts():
    return dict(a=np.empty(0, np.int32), b=np.empty(0, np.int32), dist=np.empty(0, np.float64),
                tier=np.empty(0, np.int8), same_room=np.empty(0, bool), r=np.empty(0, np.int32),
                bld=np.empty(0, np.int32), indoor=np.empty(0, bool), wall=np.empty(0, bool))


def _same_room_pairs(idx, room_of):
    """All unordered pairs (a<b) of agents `idx` (ascending) sharing a room id in `room_of`."""
    if len(idx) < 2:
        return np.empty(0, np.int64), np.empty(0, np.int64)
    order = np.argsort(room_of, kind="stable")      # stable: agent idx ascending inside each room
    s = idx[order]
    rs = room_of[order]
    M = len(s)
    starts = np.flatnonzero(np.r_[True, rs[1:] != rs[:-1]])
    sizes = np.diff(np.r_[starts, M])
    g_start = np.repeat(starts, sizes)
    g_end = np.repeat(starts + sizes, sizes)
    pos = np.arange(M)
    cnt = g_end - pos - 1                            # partners after this one in its room
    total = int(cnt.sum())
    if total == 0:
        return np.empty(0, np.int64), np.empty(0, np.int64)
    a_pos = np.repeat(pos, cnt)
    first = np.cumsum(cnt) - cnt
    off = np.arange(total) - np.repeat(first, cnt) + 1
    return s[a_pos].astype(np.int64), s[a_pos + off].astype(np.int64)


def find_contacts(campus, room, x, y, cfg_contacts, floor=None):
    """Contacts this step. room (N,) int (r | ROOM_OFF_MAP | ROOM_TRANSIT); x, y (N,) meters (NaN off
    map); floor (N,) optional (NaN when not in a room; otherwise campus.room_floor is used).
    Returns dict of arrays (KEYS), sorted by (a, b)."""
    room = np.asarray(room)
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    N = len(room)
    radius = float(cfg_contacts.get("radius_m", 5.0))
    tiers = np.asarray(cfg_contacts.get("tiers_m", [1.0, 2.0, 5.0]), dtype=np.float64)
    max_cap = cfg_contacts.get("same_room_max_capacity", 150)
    ground = float(cfg_contacts.get("ground_floor", 1))
    fsep = float(cfg_contacts.get("floor_separation_m", 1000.0))
    any_floor = bool(cfg_contacts.get("outdoor_any_floor", False))

    on = np.isfinite(x) & np.isfinite(y) & (room != ROOM_OFF_MAP)
    on_idx = np.flatnonzero(on)
    if len(on_idx) < 2:
        return empty_contacts()
    in_room = on & (room >= 0)
    rr = np.where(in_room, room, 0)
    room_indoor = np.asarray(campus.room_indoor, dtype=bool)
    indoor = in_room & room_indoor[rr]
    fl = np.asarray(campus.room_floor, dtype=np.float64)[rr]
    if floor is not None:
        f_in = np.asarray(floor, dtype=np.float64)
        fl = np.where(np.isfinite(f_in), f_in, fl)
    z = np.where(indoor, (fl - ground) * fsep, 0.0)

    # (A) radius pairs
    xo, yo, zo = x[on_idx], y[on_idx], z[on_idx]
    tree = cKDTree(np.column_stack([xo, yo, zo]))
    p = tree.query_pairs(radius, output_type="ndarray")
    pa = [on_idx[p[:, 0]].astype(np.int64)]
    pb = [on_idx[p[:, 1]].astype(np.int64)]
    if any_floor:
        out_i = np.flatnonzero(on & ~indoor)
        up_i = np.flatnonzero(indoor & (z != 0.0))
        if len(out_i) and len(up_i):
            t_out = cKDTree(np.column_stack([x[out_i], y[out_i]]))
            t_up = cKDTree(np.column_stack([x[up_i], y[up_i]]))
            sdm = t_out.sparse_distance_matrix(t_up, radius, output_type="ndarray")
            pa.append(out_i[sdm["i"]].astype(np.int64))
            pb.append(up_i[sdm["j"]].astype(np.int64))

    # (B) same-room pairs in small rooms
    room_cap = np.asarray(campus.room_cap)
    elig = in_room & (room_cap[rr] <= max_cap)
    e_idx = np.flatnonzero(elig)
    sa, sb = _same_room_pairs(e_idx, room[e_idx].astype(np.int64))
    pa.append(sa)
    pb.append(sb)

    A = np.concatenate(pa)
    B = np.concatenate(pb)
    lo, hi = np.minimum(A, B), np.maximum(A, B)
    key = np.unique(lo * N + hi)
    a = key // N
    b = key % N
    dist = np.hypot(x[a] - x[b], y[a] - y[b])
    rm_a, rm_b = room[a], room[b]
    same_room = (rm_a == rm_b) & in_room[a]
    # drop (A) pairs that are exactly at the radius boundary (query_pairs uses <=)
    keep = (dist < radius) | (same_room & elig[a])
    if not keep.all():
        a, b, dist, rm_a, rm_b, same_room = a[keep], b[keep], dist[keep], rm_a[keep], rm_b[keep], same_room[keep]
    if len(a) == 0:
        return empty_contacts()
    tier = (np.searchsorted(tiers, dist, side="right") + 1).astype(np.int8)
    room_b_arr = np.asarray(campus.room_b)
    ba = np.where(in_room[a], room_b_arr[rr[a]], -1)
    bb = np.where(in_room[b], room_b_arr[rr[b]], -1)
    bld = np.where((ba == bb) & (ba >= 0), ba, -1).astype(np.int32)
    ind_a, ind_b = indoor[a], indoor[b]
    both_in = ind_a & ind_b
    both_out = ~ind_a & ~ind_b
    return dict(a=a.astype(np.int32), b=b.astype(np.int32), dist=dist, tier=tier,
                same_room=same_room, r=np.where(same_room, rm_a, -1).astype(np.int32), bld=bld,
                indoor=both_in, wall=~same_room & ~both_out)


def _id_arrays(campus):
    cache = getattr(campus, "_contacts_id_cache", None)
    if cache is None:
        cache = (np.asarray(campus.buildings["location_id"].to_numpy(), dtype=object),
                 np.asarray(campus.rooms["room_id"].to_numpy(), dtype=object))
        try:
            campus._contacts_id_cache = cache
        except AttributeError:
            pass
    return cache


def contacts_frame(t, c, campus, agent_ids, step_s):
    """d2 contacts rows for step t (columns exactly COLUMNS, sorted by (agent_a, agent_b))."""
    n = len(c["a"])
    if n == 0:
        return pd.DataFrame({k: pd.Series(dtype=d) for k, d in
                             zip(COLUMNS, ["int64", object, object, "float64", "int64", "int64",
                                           object, object, bool])})
    lid, rid = _id_arrays(campus)
    ids = np.asarray(agent_ids, dtype=object)
    bld, r = c["bld"], c["r"]
    loc = np.full(n, "", dtype=object)
    m = bld >= 0
    loc[m] = lid[bld[m]]
    room_s = np.full(n, "", dtype=object)
    m = c["same_room"]
    room_s[m] = rid[r[m]]
    return pd.DataFrame({
        "t": np.full(n, int(t), dtype=np.int64),
        "agent_a": ids[c["a"]],
        "agent_b": ids[c["b"]],
        "distance_m": np.round(c["dist"], 2),
        "distance_tier": c["tier"].astype(np.int64),
        "duration_s": np.full(n, int(step_s), dtype=np.int64),
        "location_id": loc,
        "room_id": room_s,
        "indoor": c["indoor"].astype(bool),
    }, columns=COLUMNS)
