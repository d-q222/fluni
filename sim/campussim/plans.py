"""Intended daily schedules (no sickness) for every agent over the whole run.

build_plans(cfg, campus, pop, sections, events, rng) -> Plans with (N, T) arrays act/room/event/section.

Per agent and day we build "commitments" (classes, practice, lifts, evening labs, events, meals,
home buffers) in absolute minutes, derive the awake window (or commuter on-campus windows), paint
them into a per-agent segment-id row in priority order, fill the remaining awake gaps with flex
blocks (library / dorm study / common room / gym / outdoor / lab / home), then insert transit
("commute") steps before every building change, timed by campus.trip_mode (walk or bike, route length)
at the agent's speed for that mode.
All randomness is pre-drawn in fixed-shape arrays from the handed rng (deterministic).
"""
from dataclasses import dataclass
import math

import numpy as np

from .codes import ACT, ARCHETYPES, ROOM_OFF_MAP

DEFAULT_FLEX_KEYS = ["library", "dorm_study", "common_room", "gym", "outdoor", "lab", "home"]
GAP = -1          # awake but not yet planned (inside a paint row)
BG = 0            # segment 0 = background (sleep at home / off campus)
N_FLEX_POOL = 16  # pre-drawn flex choices per agent-day (wraps around if exhausted)


@dataclass
class Plans:
    act: np.ndarray      # (N, T) int8 codes.ACT
    room: np.ndarray     # (N, T) int32 intended room or ROOM_OFF_MAP; commute -> destination room
    event: np.ndarray    # (N, T) int32 event idx or -1
    section: np.ndarray  # (N, T) int32 section idx or -1


# ----------------------------------------------------------------------------- helpers
def _param(pop, name, default=None):
    try:
        v = pop.param(name)
    except (KeyError, AttributeError, ValueError):
        if default is None:
            raise
        return np.full(pop.N, default, dtype=float)
    return v


def _flex_matrix(pop, keys):
    """(N, len(keys)) float weights from pop.param('flex_weights') (array or dicts)."""
    v = pop.param("flex_weights")
    arr = np.asarray(v)
    if arr.dtype == object or arr.ndim == 1:
        out = np.zeros((pop.N, len(keys)))
        for i in range(pop.N):
            d = v[i]
            if isinstance(d, dict):
                out[i] = [float(d.get(k, 0.0)) for k in keys]
            else:
                out[i] = np.asarray(d, dtype=float)[: len(keys)]
        return out
    return arr.astype(float).reshape(pop.N, -1)[:, : len(keys)]


def _archetype_extra(cfg_p, pop, name):
    """Per-agent value of a plans-owned per-archetype param (configs/plans.json)."""
    default = cfg_p.get("defaults", {}).get(name, 0.0)
    table = cfg_p.get("archetypes", {})
    vals = np.array([float(table.get(a, {}).get(name, default)) for a in ARCHETYPES])
    return vals[np.asarray(pop.archetype, dtype=int)]


def _rooms_typed(campus, rtype_arr, rooms, types):
    rooms = np.asarray(rooms, dtype=np.int64)
    if len(rooms) == 0:
        return rooms
    m = np.isin(rtype_arr[rooms], list(types))
    return rooms[m]


def _pick(pool, u):
    return int(pool[min(int(u * len(pool)), len(pool) - 1)])


class _Rooms:
    """Room pools used for flex / meals."""

    def __init__(self, campus, cfg_p):
        f = cfg_p["flex"]
        self.campus = campus
        self.rtype = campus.rooms["room_type"].to_numpy().astype(str)
        all_r = np.arange(len(self.rtype))
        self._cache = {}
        self.dining_b = np.asarray(campus.buildings_of_type("dining"), dtype=np.int64)
        self.library_b = np.asarray(campus.buildings_of_type("library"), dtype=np.int64)
        self.common_b = np.asarray(campus.buildings_of_type("common_room"), dtype=np.int64)
        self.lib_types = f["library_room_types"]
        self.common_types = f["common_room_types"]
        self.gym = self._global(f["gym_room_types"], "gym")
        self.outdoor = self._global(f["outdoor_room_types"], "outdoor")
        self.lab = self._global(f["lab_room_types"], "lab")
        lib = [self.of_b(b, self.lib_types) for b in self.library_b]
        self.library_all = np.concatenate(lib) if lib else all_r[:0]
        if len(self.library_all) == 0:
            self.library_all = self._global(self.lib_types, "library")
        # capacity-checked flex picks: planned flex occupants per (room, step), allocated lazily
        self.cap_check = bool(f.get("capacity_check", True))
        self.cap = np.maximum(campus.rooms["capacity"].to_numpy().astype(np.int64), 1)
        self._occ = {}

    def occ(self, r, T):
        a = self._occ.get(r)
        if a is None:
            a = self._occ[r] = np.zeros(T, np.int16)
        return a

    def pick_free(self, pools, u, s, e, T):
        """First pool (in order) with a room that has a free place for all of steps [s, e); within it,
        pick a room weighted by free places (big reading rooms take most people). Books the place.
        Returns -1 if every pool is full."""
        for pool in pools:
            if len(pool) == 0:
                continue
            free = np.array([self.cap[r] - (int(self.occ(int(r), T)[s:e].max()) if e > s else 0)
                             for r in pool.tolist()], np.int64)
            w = np.maximum(free, 0)
            if w.sum() == 0:
                continue
            c = np.cumsum(w)
            r = int(pool[min(int(np.searchsorted(c, u * c[-1], side="right")), len(pool) - 1)])
            self.occ(r, T)[s:e] += 1
            return r
        return -1

    def _global(self, types, btype):
        r = np.flatnonzero(np.isin(self.rtype, list(types)))
        if len(r) == 0:
            bs = self.campus.buildings_of_type(btype)
            r = np.concatenate([self.campus.rooms_of(b) for b in bs]) if len(bs) else r
        return np.asarray(r, dtype=np.int64)

    def of_b(self, b, types):
        key = (int(b), tuple(types))
        if key not in self._cache:
            rs = np.asarray(self.campus.rooms_of(int(b)), dtype=np.int64)
            typed = _rooms_typed(self.campus, self.rtype, rs, types)
            self._cache[key] = typed if len(typed) else rs
        return self._cache[key]

    def dining(self, b):
        return self.of_b(b, ("dining_room",))


# ----------------------------------------------------------------------------- main
def build_plans(cfg, campus, pop, sections, events, rng) -> Plans:
    cp = cfg["plans"]
    run = cfg["run"]
    step = int(run["step_min"])
    D = int(run["days"])
    spd = 1440 // step
    T = D * spd
    N = pop.N
    sw = int(run.get("start_weekday", 0))
    step_s = step * 60.0
    prio = cp["priority"]
    rooms = _Rooms(campus, cp)
    room_b = np.asarray(campus.room_b, dtype=np.int64)

    # ---- per-agent params
    wake_h = np.asarray(_param(pop, "wake_h"), float)
    wake_sd = np.asarray(_param(pop, "wake_sd_h"), float)
    wkd_delay = np.asarray(_param(pop, "weekend_wake_delay_h"), float)
    bed_h = np.asarray(_param(pop, "bed_h"), float)
    bed_h = np.where(bed_h < 12, bed_h + 24, bed_h)
    bed_sd = np.asarray(_param(pop, "bed_sd_h"), float)
    meal_p = np.asarray(_param(pop, "meal_p"), float).reshape(N, -1)
    class_skip = np.asarray(_param(pop, "class_skip"), float)
    commuter = np.asarray(_param(pop, "commuter"), bool) | (np.asarray(pop.home_room) < 0)
    arrive_h = np.asarray(_param(pop, "arrive_h", 9.0), float)
    leave_h = np.asarray(_param(pop, "leave_h", 17.0), float)
    lab_p = _archetype_extra(cp, pop, "evening_lab_p")
    lift_p = _archetype_extra(cp, pop, "lift_days_per_week") / 5.0
    keys = list(getattr(pop, "FLEX_KEYS", DEFAULT_FLEX_KEYS))
    W = _flex_matrix(pop, keys)
    K = {k: j for j, k in enumerate(keys)}
    # commuters: dorm_study/home weight -> library/common_room
    for k_from in ("dorm_study", "home"):
        if k_from in K:
            moved = np.where(commuter, W[:, K[k_from]], 0.0)
            W[:, K[k_from]] -= moved
            if "library" in K:
                W[:, K["library"]] += moved / 2
            if "common_room" in K:
                W[:, K["common_room"]] += moved / 2
    if len(rooms.lab) == 0 and "lab" in K:
        W[:, K["lab"]] = 0.0
    W = np.maximum(W, 0)
    W[W.sum(1) == 0, K.get("library", 0)] = 1.0
    Wcum = np.cumsum(W / W.sum(1, keepdims=True), axis=1)

    # ---- per-agent fixed choices
    U0 = rng.random((N, 4))
    gym_room = [(_pick(rooms.gym, U0[i, 0]) if len(rooms.gym) else -1) for i in range(N)]
    lab_room = [(_pick(rooms.lab, U0[i, 1]) if len(rooms.lab) else -1) for i in range(N)]

    def lib_pool(i):
        b = int(pop.fav_library[i]) if pop.fav_library is not None else -1
        if b >= 0:
            return rooms.of_b(b, rooms.lib_types)
        if len(rooms.library_b):
            return rooms.of_b(_pick(rooms.library_b, U0[i, 2]), rooms.lib_types)
        return rooms.library_all

    def common_pool(i):
        b = int(pop.fav_common[i]) if pop.fav_common is not None else -1
        if b < 0 and len(rooms.common_b):
            b = _pick(rooms.common_b, U0[i, 3])
        if b >= 0:
            return rooms.of_b(b, rooms.common_types)
        hb = int(pop.home_b[i])
        return rooms.of_b(hb, ("lobby",)) if hb >= 0 else rooms.library_all

    # ---- sections: agent -> weekday -> [(s_min, e_min, r, sec, is_lab)]
    sec_wd = [s for s in sections["weekdays"]]
    sec_s = sections["start_min"].to_numpy().astype(int)
    sec_e = sections["end_min"].to_numpy().astype(int)
    sec_r = sections["r"].to_numpy().astype(int)
    sec_lab = (sections["kind"].to_numpy().astype(str) == "lab") if "kind" in sections else np.zeros(len(sections), bool)

    # ---- events: agent -> list of (day, s_abs, e_abs, k, act, prio)
    ev_act_map = cp["events"]["act"]
    ev_by_agent = [[] for _ in range(N)]
    if events is not None and len(events):
        att = list(events["attendees"])
        M = sum(len(a) for a in att)
        EU = rng.random((max(M, 1), 2))
        ef_a, ef_l = cp["events"]["arrive_delay_frac"], cp["events"]["leave_early_frac"]
        ev_s = events["start_min"].to_numpy().astype(int)
        ev_e = events["end_min"].to_numpy().astype(int)
        ev_r = events["r"].to_numpy().astype(int)
        ev_t = events["type"].to_numpy().astype(str)
        m = 0
        for k in range(len(events)):
            dur = ev_e[k] - ev_s[k]
            a_name = ev_act_map.get(ev_t[k], "event")
            pr = prio.get(a_name, prio["event"])
            for i in att[k]:
                s = ev_s[k] + EU[m, 0] * ef_a * dur
                e = ev_e[k] - EU[m, 1] * ef_l * dur
                m += 1
                ev_by_agent[int(i)].append((ev_s[k] // 1440, s, e, k, ACT[a_name], pr, int(ev_r[k])))

    # ---- pre-drawn randomness per agent-day
    Z = rng.standard_normal((N, D, 10))
    U = rng.random((N, D, 24))
    US = rng.random((N, D, 16))                    # class skip draws (by meeting order)
    FU = rng.random((N, D, N_FLEX_POOL, 3))        # flex: type, duration, room/act

    sl, hb_cfg, ml, at, lb, cm = cp["sleep"], cp["home_buffer"], cp["meals"], cp["athletes"], cp["labs"], cp["commuter"]
    fx = cp["flex"]
    flex_hours = {k: tuple(v) for k, v in fx.get("allowed_hours", {}).items()}
    lab_skip_mult = cp["classes"]["lab_skip_mult"]
    meal_c = [h * 60 for h in ml["centers_h"]]
    meal_sd = ml["sd_min"]
    meal_win = ml["window_h"]

    act_out = np.empty((N, T), np.int8)
    room_out = np.empty((N, T), np.int32)
    ev_out = np.empty((N, T), np.int32)
    sec_out = np.empty((N, T), np.int32)
    dist_cache = {}
    entry_e = np.asarray(pop.entry_e)
    teams = pop.teams
    A_SLEEP, A_OFF, A_RELAX, A_IDLE, A_COMMUTE = ACT["sleep"], ACT["off_campus"], ACT["relax"], ACT["idle"], ACT["commute"]
    A_CLASS, A_LAB, A_EAT, A_PRACT, A_GYM = ACT["class"], ACT["lab"], ACT["eat"], ACT["practice"], ACT["gym"]
    A_STUDY, A_OUT = ACT["study"], ACT["outdoor_leisure"]
    P_CLASS, P_PRACT, P_LAB, P_MEAL, P_FLEX = prio["class"], prio["practice"], prio["lab"], prio["meal"], prio["flex"]

    min_frag = max(1, int(math.ceil(cp.get("min_fragment_min", 15) / step)))

    def to_step(m):
        return min(max(int(round(m / step)), 0), T)

    for i in range(N):
        is_comm = bool(commuter[i])
        home = int(pop.home_room[i])
        team = int(pop.team_id[i])
        practice_rooms = list(teams[team]["practice_rooms"]) if team >= 0 else []
        sched = list(pop.class_schedule[i]) if pop.class_schedule is not None else []
        by_wd = [[] for _ in range(7)]
        for s in sched:
            for wd in sec_wd[s]:
                by_wd[int(wd)].append(s)
        my_events = ev_by_agent[i]
        fav_d = int(pop.fav_dining[i]) if pop.fav_dining is not None else -1
        lpool, cpool = lib_pool(i), common_pool(i)
        bg_room = ROOM_OFF_MAP if is_comm else home
        # segment table
        s_act, s_room, s_ev, s_sec = [A_OFF if is_comm else A_SLEEP], [bg_room], [-1], [-1]
        row = np.zeros(T, np.int32)
        prev_end = -10 ** 9   # previous day's bed (or last on-campus minute for commuters)
        u_skip_i, z_i, u_i = US[i], Z[i], U[i]

        for d in range(D):
            wd = (sw + d) % 7
            base = d * 1440
            weekday = wd < 5
            z, u = z_i[d], u_i[d]
            C = []  # (s_abs, e_abs, prio, act, room, ev, sec)
            if weekday:
                for j, s in enumerate(by_wd[wd]):
                    p_skip = class_skip[i] * (lab_skip_mult if sec_lab[s] else 1.0)
                    if u_skip_i[d, j % 16] < p_skip:
                        continue
                    C.append((base + sec_s[s], base + sec_e[s], P_CLASS,
                              A_LAB if sec_lab[s] else A_CLASS, int(sec_r[s]), -1, int(s)))
                if team >= 0 and practice_rooms:
                    j = at["practice_jitter_min"]
                    ps = base + at["practice_start_h"] * 60 + z[4] * j / 2
                    pe = base + at["practice_end_h"] * 60 + z[5] * j / 2
                    pr = int(practice_rooms[d % len(practice_rooms)])
                    C.append((ps, pe, P_PRACT, A_PRACT, pr, -1, -1))
                    if u[0] < lift_p[i] and gym_room[i] >= 0:
                        ls = base + at["lift_start_h"] * 60 + z[6] * at["lift_jitter_min"]
                        ld = at["lift_dur_min"][0] + u[1] * (at["lift_dur_min"][1] - at["lift_dur_min"][0])
                        C.append((ls, ls + ld, P_PRACT, A_GYM, gym_room[i], -1, -1))
            if lab_room[i] >= 0 and u[2] < lab_p[i] and (weekday or not lb["weekdays_only"]):
                C.append((base + lb["start_h"] * 60 + z[7] * lb["jitter_min"],
                          base + lb["end_h"] * 60 + z[8] * lb["jitter_min"], P_LAB, A_LAB, lab_room[i], -1, -1))
            for (ed, s, e, k, a, pr, r) in my_events:
                if ed == d:
                    C.append((s, e, pr, a, r, int(k), -1))
            C = [c for c in C if c[1] > c[0] and c[0] > prev_end]

            if not is_comm:
                wake = wake_h[i] * 60 + wake_sd[i] * 60 * z[0] + (wkd_delay[i] * 60 if not weekday else 0)
                wake = min(max(wake, sl["wake_clip_h"][0] * 60), sl["wake_clip_h"][1] * 60) + base
                bed = bed_h[i] * 60 + bed_sd[i] * 60 * z[1] + (sl["fri_sat_bed_delay_h"] * 60 if wd in (4, 5) else 0)
                bed = min(max(bed, sl["bed_clip_h"][0] * 60), sl["bed_clip_h"][1] * 60) + base
                wake = max(wake, prev_end + sl["min_sleep_h"] * 60)
                if C:
                    lead = sl["commit_wake_lead_min"]
                    first = min(c[0] for c in C)
                    wake = min(wake, first - (lead[0] + u[3] * (lead[1] - lead[0])))
                    buf = sl["event_bed_buffer_min"]
                    bed = max(bed, max(c[1] for c in C) + buf[0] + u[4] * (buf[1] - buf[0]))
                wake = max(wake, prev_end + step)
                bed = max(bed, wake + 4 * 60)
                windows = [(wake, bed)]
            else:
                iv = []
                if weekday:
                    a0 = base + arrive_h[i] * 60 + z[0] * cm["arrive_sd_h"] * 60
                    a1 = base + leave_h[i] * 60 + z[1] * cm["leave_sd_h"] * 60
                    iv.append((a0, max(a1, a0 + 60)))
                lead, tail = cm["class_lead_min"], cm["class_tail_min"]
                for c in C:
                    iv.append((c[0] - (lead[0] + u[3] * (lead[1] - lead[0])),
                               c[1] + tail[0] + u[4] * (tail[1] - tail[0])))
                iv.sort()
                windows = []
                for a0, a1 in iv:
                    a0 = max(a0, prev_end + step)
                    if a1 <= a0:
                        continue
                    if windows and a0 <= windows[-1][1] + cm["merge_gap_min"]:
                        windows[-1] = (windows[-1][0], max(windows[-1][1], a1))
                    else:
                        windows.append((a0, a1))
                if not windows:
                    continue
                wake, bed = windows[0][0], windows[-1][1]

            # meals (shifted past conflicting higher-priority commitments, dropped if impossible)
            hard = [(c[0], c[1]) for c in C if c[2] > P_MEAL]
            last_meal_end = None
            for k in range(3):
                if k >= meal_p.shape[1] or u[5 + k] >= meal_p[i, k]:
                    continue
                ms = base + meal_c[k] + z[2 + k if k < 2 else 9] * meal_sd[k]
                ms = min(max(ms, base + meal_win[k][0] * 60), base + meal_win[k][1] * 60)
                if last_meal_end is not None:
                    ms = max(ms, last_meal_end + ml["min_gap_min"])
                if k == 0:
                    ms = max(ms, wake + ml["breakfast_min_after_wake_min"])
                    if ms > base + ml["breakfast_latest_h"] * 60:
                        continue
                dur = ml["dur_min"][0] + u[8 + k] * (ml["dur_min"][1] - ml["dur_min"][0])
                orig = ms
                for _ in range(4):
                    clash = [h for h in hard if h[0] < ms + dur and h[1] > ms]
                    if not clash:
                        break
                    ms = max(h[1] for h in clash)
                else:
                    continue
                if ms - orig > ml["max_shift_min"]:
                    continue
                if not any(w0 <= ms and ms + dur <= w1 for w0, w1 in windows):
                    continue
                if fav_d >= 0 and (u[11 + k] < ml["fav_p"] or len(rooms.dining_b) <= 1):
                    db = fav_d
                elif len(rooms.dining_b):
                    others = rooms.dining_b[rooms.dining_b != fav_d] if fav_d >= 0 else rooms.dining_b
                    db = _pick(others if len(others) else rooms.dining_b, u[14 + k])
                else:
                    continue
                C.append((ms, ms + dur, P_MEAL, A_EAT, _pick(rooms.dining(db), u[17 + k]), -1, -1))
                last_meal_end = ms + dur
            if not is_comm:
                mb, eb = hb_cfg["morning_min"], hb_cfg["evening_min"]
                C.append((wake, wake + mb[0] + u[20] * (mb[1] - mb[0]), P_FLEX, A_RELAX, home, -1, -1))
                C.append((bed - (eb[0] + u[21] * (eb[1] - eb[0])), bed, P_FLEX, A_RELAX, home, -1, -1))

            # paint: windows -> GAP; commitments in descending priority (ties: later wins), each
            # clipped against what is already placed; leftover fragments < min_fragment dropped
            for w0, w1 in windows:
                row[to_step(w0):to_step(w1)] = GAP
            order = sorted(range(len(C)), key=lambda j: (-C[j][2], -j))
            occ = []  # placed step intervals, sorted
            for j in order:
                s, e, pr_, a, r, ev, sc = C[j]
                s0, s1 = to_step(max(s, wake)), to_step(min(e, bed))
                if s1 <= s0:
                    continue
                pieces, cur = [], s0
                for o0, o1 in occ:
                    if o1 <= cur:
                        continue
                    if o0 >= s1:
                        break
                    if o0 > cur:
                        pieces.append((cur, o0))
                    cur = max(cur, o1)
                if cur < s1:
                    pieces.append((cur, s1))
                if len(pieces) > 1 or (pieces and pieces[0] != (s0, s1)):
                    pieces = [q for q in pieces if q[1] - q[0] >= min_frag]
                if not pieces:
                    continue
                sid = len(s_act)
                s_act.append(a); s_room.append(r); s_ev.append(ev); s_sec.append(sc)
                for q0, q1 in pieces:
                    row[q0:q1] = sid
                occ = sorted(occ + pieces)
            prev_end = bed

        # ---- flex fill of GAP runs
        gm = row == GAP
        if gm.any():
            dm = np.diff(np.concatenate(([0], gm.view(np.int8), [0])))
            starts, ends = np.flatnonzero(dm == 1), np.flatnonzero(dm == -1)
            fu_i, wc = FU[i], Wcum[i]
            ptr = {}
            short = max(1, int(math.ceil(fx["short_gap_min"] / step)))
            min_rem = max(short, int(math.ceil(fx["min_remainder_min"] / step)))
            for a0, a1 in zip(starts.tolist(), ends.tolist()):
                L = a1 - a0
                if L < short:
                    prv = int(row[a0 - 1]) if a0 > 0 else BG
                    nxt = int(row[a1]) if a1 < T else BG
                    src = prv if prv > BG else nxt
                    if src > BG:
                        r_ = s_room[src]
                    elif not is_comm:
                        r_ = home
                    else:
                        continue
                    if r_ in rooms._occ:  # staying on in a capacity-checked room holds the place
                        rooms._occ[r_][a0:a1] += 1
                    row[a0:a1] = len(s_act)
                    s_act.append(A_RELAX if r_ == home else A_IDLE); s_room.append(r_); s_ev.append(-1); s_sec.append(-1)
                    continue
                d = min(a0 // spd, D - 1)
                pos = a0
                while pos < a1:
                    p = ptr.get(d, 0)
                    ptr[d] = p + 1
                    fu = fu_i[d, p % N_FLEX_POOL]
                    kname = keys[min(int(np.searchsorted(wc, fu[0], side="right")), len(keys) - 1)]
                    hr = (pos * step) % 1440 / 60.0
                    hr = hr + 24 if hr < 5 else hr
                    lo_h, hi_h = flex_hours.get(kname, (0, 48))
                    if not (lo_h <= hr < hi_h):
                        kname = "common_room" if is_comm else "home"
                        lo_h, hi_h = flex_hours.get(kname, (0, 48))
                    if kname == "gym":
                        lo, hi = fx["gym_min"]
                        r_, a_ = gym_room[i], A_GYM
                    elif kname == "outdoor":
                        lo, hi = fx["outdoor_min"]
                        r_ = _pick(rooms.outdoor, fu[2]) if len(rooms.outdoor) else -1
                        a_ = A_OUT
                    else:
                        lo, hi = fx["block_min"]
                        if kname == "library":
                            r_, a_ = _pick(lpool, fu[2]) if len(lpool) else -1, A_STUDY
                        elif kname == "common_room":
                            r_ = _pick(cpool, fu[2]) if len(cpool) else -1
                            a_ = A_RELAX if fu[2] < fx["common_relax_p"] else A_STUDY
                        elif kname == "lab":
                            r_, a_ = lab_room[i], A_LAB
                        elif kname == "dorm_study":
                            r_, a_ = home, A_STUDY
                        else:
                            r_, a_ = home, A_RELAX
                    if r_ < 0:  # missing pool / commuter home: fall back to library
                        r_ = _pick(rooms.library_all, fu[2]) if len(rooms.library_all) else home
                        a_ = A_STUDY
                        if r_ < 0:
                            r_ = int(s_room[int(row[a0 - 1])]) if a0 > 0 else ROOM_OFF_MAP
                    n = max(1, int(round((lo + fu[1] * (hi - lo)) / step)))
                    if hi_h > hr:  # don't run far past the type's allowed hours
                        n = min(n, max(short, int((hi_h - hr) * 60 / step)))
                    if a1 - (pos + n) < min_rem:
                        n = a1 - pos
                    if rooms.cap_check and kname in ("library", "common_room"):
                        # favourite pool, then any library; all full -> study at home (commuters: lobby/lounge
                        # pool, else the least-full library room)
                        pools = (lpool, rooms.library_all) if kname == "library" else (cpool, rooms.library_all)
                        r_ = rooms.pick_free(pools, fu[2], pos, pos + n, T)
                        if r_ < 0:
                            if not is_comm and home >= 0:
                                r_, a_ = home, A_STUDY
                            elif len(rooms.library_all):
                                la = rooms.library_all
                                load = [rooms.occ(int(r), T)[pos:pos + n].max() / rooms.cap[r] for r in la.tolist()]
                                r_ = int(la[int(np.argmin(load))])
                                rooms.occ(r_, T)[pos:pos + n] += 1
                    row[pos:pos + n] = len(s_act)
                    s_act.append(a_); s_room.append(r_); s_ev.append(-1); s_sec.append(-1)
                    pos += n

        act_r = np.asarray(s_act, np.int8)[row]
        room_r = np.asarray(s_room, np.int32)[row]
        ev_r = np.asarray(s_ev, np.int32)[row]
        sec_r_ = np.asarray(s_sec, np.int32)[row]
        # off-campus act for any off-map step (commuter background)
        # ---- transit insertion
        bc = np.where(room_r >= 0, room_b[np.maximum(room_r, 0)], -1)
        ch = np.flatnonzero(bc[1:] != bc[:-1]) + 1
        if len(ch):
            e_i = int(entry_e[i]) if entry_e[i] >= 0 else 0
            owns_bike = bool(pop.transport[i] == 1)
            spd_w = float((pop.walk_speed if pop.walk_speed is not None else pop.speed_mps)[i])
            spd_b = float((pop.bike_speed if pop.bike_speed is not None else pop.speed_mps)[i])
            run_start = np.concatenate(([0], ch[:-1])).tolist()
            bcl = bc.tolist() if len(ch) > 64 else None
            for c, p0 in zip(ch.tolist(), run_start):
                sb = bcl[c - 1] if bcl is not None else int(bc[c - 1])
                db = bcl[c] if bcl is not None else int(bc[c])
                key = (sb if sb >= 0 else -2 - e_i, db if db >= 0 else -2 - e_i, owns_bike)
                md = dist_cache.get(key)
                if md is None:
                    src = ("b", sb) if sb >= 0 else ("e", e_i)
                    dst = ("b", db) if db >= 0 else ("e", e_i)
                    mode, dist = campus.trip_mode(src, dst, owns_bike)
                    md = dist_cache[key] = (mode == "bike", float(dist))
                dist = md[1]
                speed = spd_b if md[0] else spd_w
                k = int(math.ceil(dist / speed / step_s)) if dist > 0 else 1
                k = min(k, c - p0 - 1)
                if k <= 0:
                    continue
                act_r[c - k:c] = A_COMMUTE
                room_r[c - k:c] = room_r[c]
                ev_r[c - k:c] = -1
                sec_r_[c - k:c] = -1
        act_out[i], room_out[i], ev_out[i], sec_out[i] = act_r, room_r, ev_r, sec_r_

    return Plans(act=act_out, room=room_out, event=ev_out, section=sec_out)
