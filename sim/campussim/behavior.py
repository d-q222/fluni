"""Runtime movement: turn intended Plans into actual per-step state (CONTRACT §5).

Per step: desired (room, act, event) = plan, then overrides (isolation > Vaden > leave_location >
carry-on drops > plan). Room changes inside a building are instant; building changes are trips along
campus.route at pop.speed_mps. In-room positions follow the room layout and stay fixed during a visit
(mingle offsets are re-sampled periodically). Masks are drawn per visit / activity change.
The common path (stationary agents) is vectorized; Python loops only touch travelers, room changers,
mingle re-samples and override agents.
"""
import zlib
from bisect import bisect_right

import numpy as np

from . import codes
from .codes import ACT, ROOM_OFF_MAP, ROOM_TRANSIT

A_COMMUTE = ACT["commute"]
A_OFF = ACT["off_campus"]
A_ISOLATE = ACT["isolate"]
A_HEALTH = ACT["health_visit"]
A_EARLY = ACT["arrived_early"]
A_CLASS, A_LAB = ACT["class"], ACT["lab"]
BEDS = {"dorm_single": 1, "dorm_double": 2, "dorm_triple": 3, "dorm_quad": 4}
_OPT = np.zeros(len(codes.ACTIVITIES), bool)
_OPT[list(codes.OPTIONAL_ACTIVITIES)] = True


class Behavior:
    def __init__(self, cfg, campus, pop, plans, rng):
        self.c = cfg["behavior"]
        self.campus, self.pop, self.plans, self.rng = campus, pop, plans, rng
        self.step_s = cfg["run"]["step_min"] * 60
        self.spd = 1440 // cfg["run"]["step_min"]
        N = self.N = pop.N
        self.T = plans.act.shape[1]
        c = self.c

        # --- public per-step state ---
        self.room = np.full(N, ROOM_OFF_MAP, np.int32)
        self.b = np.full(N, -1, np.int32)
        self.x = np.full(N, np.nan)
        self.y = np.full(N, np.nan)
        self.floor = np.full(N, np.nan)
        self.indoor = np.zeros(N, bool)
        self.moving = np.zeros(N, bool)
        self.off_map = np.ones(N, bool)
        self.masked = np.zeros(N, bool)
        self.isolating = np.zeros(N, bool)
        self.act = np.full(N, A_OFF, np.int8)
        self.event = np.full(N, -1, np.int32)
        self.section = np.full(N, -1, np.int32)
        self.entrance = np.full(N, -1, np.int32)
        self.trip_dist = np.full(N, np.nan)   # extra: meters traveled along the current trip polyline
        self.t = -1
        self._t0_done = False
        self._mdraw_val = np.zeros(N, bool)

        # --- internal state ---
        self._at = np.full(N, ROOM_OFF_MAP, np.int32)   # room where the agent is (when not traveling)
        self._trav = np.zeros(N, bool)
        self._dest = np.full(N, ROOM_OFF_MAP, np.int32)  # trip destination room (valid when _trav)
        self._route_cache = {}
        self._trips = {}                                 # i -> [xs, ys, cum(list), total, traveled, dx, dy]
        self._seat = np.full(N, -1, np.int64)            # global seat index held, -1 none
        self._mask_draw = np.zeros(N, bool)
        self._mc = np.full((N, 2), np.nan)               # mingle cluster center of current visit
        self._iso_until = np.full(N, -1, np.int64)
        self._force_until = np.full(N, -1, np.int64)
        self._vaden = {}       # i -> [start, end, steps spent in waiting room]
        self._leave = {}       # i -> plan room being left
        self._carry = {}       # i -> intensity
        self._carry_dec = {}   # i -> (block key, keep)

        # --- room geometry / layout ---
        cp = campus
        self.r_b = np.asarray(cp.room_b, np.int32)
        self.r_x0, self.r_y0 = np.asarray(cp.room_x0, float), np.asarray(cp.room_y0, float)
        self.r_x1, self.r_y1 = np.asarray(cp.room_x1, float), np.asarray(cp.room_y1, float)
        self.r_floor = np.asarray(cp.room_floor, float)
        self.r_indoor = np.asarray(cp.room_indoor, bool).copy()
        rtypes = cp.rooms["room_type"].to_numpy()
        self.r_indoor &= rtypes != "outdoor_area"
        L = list(cp.LAYOUTS)
        lay = np.asarray(cp.room_layout)
        self.L_SEAT, self.L_MINGLE, self.L_BED, self.L_FREE = (L.index(n) for n in ("seated", "mingle", "bed", "free"))
        self.r_lay = lay
        self._build_seats(rtypes)

        # mask context factor per activity code
        cf = c["mask_context_factor"]
        self._cf = np.array([float(cf.get(a, 0.0)) for a in codes.ACTIVITIES])
        self._bed_act = np.zeros(len(codes.ACTIVITIES), bool)
        self._bed_act[[ACT[a] for a in c["bed_acts"]]] = True
        self._leave_act = ACT[c["leave_location_act"]]
        self._drop_act = ACT[c["carry_on_drop_act"]]

        # home bed / desk spots (bed layout home rooms only)
        self.home = np.asarray(pop.home_room, np.int32)
        self._build_bed_spots(rtypes)

        # Vaden waiting room
        self.vaden_room = -1
        hb = cp.buildings_of_type("health_center")
        if len(hb):
            rr = cp.rooms_of(int(hb[0]), "waiting_room")
            if not len(rr):
                rr = cp.rooms_of(int(hb[0]))
            if len(rr):
                self.vaden_room = int(rr[0])

        ep = cp.entry_points
        self._ep_xy = np.column_stack([ep["x"].to_numpy(float), ep["y"].to_numpy(float)])
        self._entry_e = np.asarray(pop.entry_e, np.int64).copy()
        self.speed = np.asarray(pop.speed_mps, float)
        # stats for validation
        self.n_trips = 0
        self.n_reroutes = 0

    # ------------------------------------------------------------------ setup helpers
    def _build_seats(self, rtypes):
        c = self.c
        sp_cfg = c["seat_spacing_m"]
        R = len(self.r_b)
        edge = c["seat_edge_m"]
        w = np.maximum(self.r_x1 - self.r_x0, 0.0)
        h = np.maximum(self.r_y1 - self.r_y0, 0.0)
        sp = np.array([float(sp_cfg.get(rt, sp_cfg["default"])) for rt in rtypes]) if R else np.zeros(0)
        cols = np.maximum(1, np.floor((w - 2 * edge) / np.maximum(sp, 1e-6)).astype(np.int64) + 1)
        rows = np.maximum(1, np.floor((h - 2 * edge) / np.maximum(sp, 1e-6)).astype(np.int64) + 1)
        n = np.where(self.r_lay == self.L_SEAT, cols * rows, 0)
        self.s_n, self.s_cols, self.s_sp = n, cols, sp
        self.s_off = np.concatenate([[0], np.cumsum(n)[:-1]]).astype(np.int64) if R else np.zeros(0, np.int64)
        self.s_ox = self.r_x0 + (w - (cols - 1) * sp) / 2   # grid centered in the rect
        self.s_oy = self.r_y0 + (h - (rows - 1) * sp) / 2
        self.s_occ = np.zeros(int(n.sum()), bool)

    def _build_bed_spots(self, rtypes):
        c = self.c
        N, home = self.N, self.home
        self.bed_xy = np.full((N, 2), np.nan)
        self.desk_xy = np.full((N, 2), np.nan)
        ok = home >= 0
        ok[ok] &= self.r_lay[home[ok]] == self.L_BED
        self._home_bed = ok
        if not ok.any():
            return
        idx = np.flatnonzero(ok)
        r = home[idx]
        k = np.asarray(self.pop.bed_slot)[idx].astype(int)
        nb = np.array([BEDS.get(rt, 2) for rt in rtypes[r]])
        off, doff = c["bed_wall_offset_m"], c["desk_wall_offset_m"]
        x0, x1, y0, y1 = self.r_x0[r], self.r_x1[r], self.r_y0[r], self.r_y1[r]
        side = k % 2
        row = (k // 2) % 2
        bx = np.where(nb == 1, x0 + off, np.where(side == 0, x0 + off, x1 - off))
        by = np.where(nb <= 2, (y0 + y1) / 2, np.where(row == 0, y0 + off, y1 - off))
        dy = np.where(row == 0, y1 - doff, y0 + doff)
        self.bed_xy[idx] = self._clip(np.column_stack([bx, by]), r)
        self.desk_xy[idx] = self._clip(np.column_stack([bx, dy]), r)

    def _clip(self, xy, r):
        m = self.c["room_margin_m"]
        x0, x1, y0, y1 = self.r_x0[r], self.r_x1[r], self.r_y0[r], self.r_y1[r]
        lo_x, hi_x = x0 + m, x1 - m
        lo_y, hi_y = y0 + m, y1 - m
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        lo_x, hi_x = np.where(lo_x > hi_x, cx, lo_x), np.where(lo_x > hi_x, cx, hi_x)
        lo_y, hi_y = np.where(lo_y > hi_y, cy, lo_y), np.where(lo_y > hi_y, cy, hi_y)
        return np.column_stack([np.clip(xy[:, 0], lo_x, hi_x), np.clip(xy[:, 1], lo_y, hi_y)])

    # ------------------------------------------------------------------ override API
    def set_isolation(self, i, until_t):
        self._iso_until[i] = int(until_t)

    def end_isolation(self, i):
        self._iso_until[i] = -1

    def schedule_vaden(self, i, start_t, n_steps):
        """Go to Vaden's waiting room during [start_t, start_t+n_steps); if travel ate the window, the visit
        is extended until vaden_min_stay_steps were spent there (at most vaden_max_extend_steps)."""
        if self.vaden_room >= 0:
            self._vaden[int(i)] = [int(start_t), int(start_t) + int(n_steps), 0]

    def set_carry_on(self, i, intensity):
        i = int(i)
        if intensity is None:
            self._carry.pop(i, None)
            self._carry_dec.pop(i, None)
        else:
            self._carry[i] = float(intensity)

    def leave_location(self, i):
        t = max(self.t, 0)
        self._leave[int(i)] = int(self.plans.room[i, t])

    def force_mask(self, i, until_t):
        self._force_until[i] = int(until_t)

    # ------------------------------------------------------------------ small helpers
    def _entry(self, i, x=np.nan, y=np.nan):
        e = self._entry_e[i]
        if e >= 0:
            return int(e)
        if not np.isfinite(x):
            h = self.home[i]
            x, y = (self.campus.b_x[self.r_b[h]], self.campus.b_y[self.r_b[h]]) if h >= 0 else (0.0, 0.0)
        e = int(np.argmin((self._ep_xy[:, 0] - x) ** 2 + (self._ep_xy[:, 1] - y) ** 2))
        self._entry_e[i] = e
        return e

    def _door(self, b, x, y):
        try:
            e = self.campus.nearest_entrance(int(b), float(x), float(y))
        except (KeyError, IndexError, ValueError):
            return -1
        return -1 if e is None else int(e)

    def _home_of(self, i):
        h = self.home[i]
        return int(h) if h >= 0 else ROOM_OFF_MAP

    def _eff_block(self, i, t):
        """(act, room, event) of the plan block at t; commute steps look ahead to their block."""
        pa = self.plans.act[i]
        k = t
        while k < self.T and pa[k] == A_COMMUTE:
            k += 1
        if k >= self.T:
            k = t
        return int(pa[k]), int(self.plans.room[i, k]), int(self.plans.event[i, k])

    def _release_seats(self, idx):
        s = self._seat[idx]
        s = s[s >= 0]
        if len(s):
            self.s_occ[s] = False
        self._seat[idx] = -1

    # ------------------------------------------------------------------ positions
    def _draw_positions(self, idx, rooms, t, event):
        """In-room positions for agents idx entering rooms (vectorized by layout). Reserves seats."""
        rng, c = self.rng, self.c
        n = len(idx)
        xy = np.empty((n, 2))
        if n == 0:
            return xy
        lay = self.r_lay[rooms]
        x0, y0 = self.r_x0[rooms], self.r_y0[rooms]
        w, h = self.r_x1[rooms] - x0, self.r_y1[rooms] - y0
        # uniform default (free layout, visitors in bedrooms, seatless rooms)
        u = rng.random((n, 2))
        m = c["room_margin_m"]
        xy[:, 0] = x0 + m + u[:, 0] * np.maximum(w - 2 * m, 0)
        xy[:, 1] = y0 + m + u[:, 1] * np.maximum(h - 2 * m, 0)
        self._mc[idx] = np.nan

        # seated
        sel = np.flatnonzero((lay == self.L_SEAT) & (self.s_n[rooms] > 0))
        if len(sel):
            r = rooms[sel]
            s = self._pick_seats(r)
            self._seat[idx[sel]] = s
            got = s >= 0                  # seatless (room over capacity) agents keep the uniform spot
            sel, r, s = sel[got], r[got], s[got]
            k = s - self.s_off[r]
            cols = self.s_cols[r]
            xy[sel, 0] = self.s_ox[r] + (k % cols) * self.s_sp[r]
            xy[sel, 1] = self.s_oy[r] + (k // cols) * self.s_sp[r]

        # bed: own room -> bed spot (desk/bed chosen each step); visitors keep uniform
        sel = np.flatnonzero((lay == self.L_BED) & (rooms == self.home[idx]))
        if len(sel):
            xy[sel] = self.bed_xy[idx[sel]]

        # mingle: friend-group cluster center + gaussian offset
        sel = np.flatnonzero(lay == self.L_MINGLE)
        if len(sel):
            cm = c["mingle_center_margin_m"]
            fg = self.pop.friend_group
            day = t // self.spd
            cen = np.empty((len(sel), 2))
            for j, q in enumerate(sel):
                i, r, ev = idx[q], rooms[q], event[q]
                key = f"{fg[i]}|{r}|{'e%d' % ev if ev >= 0 else 'd%d' % day}"
                ux = zlib.crc32(key.encode()) / 4294967296.0
                uy = zlib.crc32((key + "|y").encode()) / 4294967296.0
                cen[j, 0] = self.r_x0[r] + cm + ux * max(self.r_x1[r] - self.r_x0[r] - 2 * cm, 0.0)
                cen[j, 1] = self.r_y0[r] + cm + uy * max(self.r_y1[r] - self.r_y0[r] - 2 * cm, 0.0)
            self._mc[idx[sel]] = cen
            xy[sel] = cen + rng.normal(0.0, c["mingle_sigma_m"], (len(sel), 2))
        return self._clip(xy, rooms)

    def _pick_seats(self, r):
        rng, occ = self.rng, self.s_occ
        off, n = self.s_off[r], self.s_n[r]
        s = off + np.minimum((rng.random(len(r)) * n).astype(np.int64), n - 1)
        for _ in range(self.c["seat_retry_rounds"]):
            bad = occ[s] | _dup(s)
            if not bad.any():
                break
            b = np.flatnonzero(bad)
            s[b] = off[b] + np.minimum((rng.random(len(b)) * n[b]).astype(np.int64), n[b] - 1)
        bad = occ[s] | _dup(s)
        occ[s[~bad]] = True
        for j in np.flatnonzero(bad):  # rare: linear probe for a free seat; full room -> -1 (stand)
            o, nn = off[j], n[j]
            free = np.flatnonzero(~occ[o:o + nn])
            if len(free):
                s[j] = o + free[np.searchsorted(free, s[j] - o) % len(free)]
                occ[s[j]] = True
            else:
                s[j] = -1
        return s

    # ------------------------------------------------------------------ trips
    def _start_trips(self, idx, t, des, from_xy):
        """Begin (from_xy=False: leaving room/off-map) or re-route (from_xy=True) trips of agents idx to
        des[idx]. Destination in-room positions (and seats) are drawn up front, vectorized."""
        self._release_seats(idx)
        d = des[idx]
        on = np.flatnonzero(d >= 0)
        dxy = np.full((len(idx), 2), np.nan)
        if len(on):
            ev = np.array([self._eff_block(int(i), t)[2] for i in idx[on]], np.int32)
            dxy[on] = self._draw_positions(idx[on], d[on], t, ev)
        for j, i in enumerate(idx.tolist()):
            self._start_trip(i, t, int(d[j]), from_xy, dxy[j])

    def _start_trip(self, i, t, des, from_xy, dxy):
        at = self._at[i]
        if from_xy:
            p0 = (float(self.x[i]), float(self.y[i]))
            src = ("xy", p0)
        elif at >= 0:
            p0 = (float(self.x[i]), float(self.y[i]))
            src = ("b", int(self.r_b[at]))
        else:
            e = self._entry(i)
            p0 = (float(self._ep_xy[e, 0]), float(self._ep_xy[e, 1]))
            src = ("e", e)
        if des >= 0:
            dst = ("b", int(self.r_b[des]))
        else:
            e = self._entry(i, p0[0], p0[1])
            dst = ("e", e)
            dxy = self._ep_xy[e]
        poly, se, de = self._route(src, dst)
        pts = np.vstack([np.asarray(p0)[None], poly, np.asarray(dxy, float)[None]])
        seg = np.hypot(np.diff(pts[:, 0]), np.diff(pts[:, 1]))
        cum = np.concatenate([[0.0], np.cumsum(seg)])
        traveled = 0.0
        if not from_xy and at >= 0:  # exit step: agent stands at the door
            traveled = float(cum[1]) if len(poly) else 0.0
            dx, dy = (poly[0] if len(poly) else p0)
            self.entrance[i] = se if se >= 0 else self._door(self.r_b[at], dx, dy)
        self._trips[i] = [pts[:, 0], pts[:, 1], cum.tolist(), float(cum[-1]), traveled, de]
        self._trav[i] = True
        self._dest[i] = des
        self.n_trips += 1
        self._set_trip_pos(i)

    def _route(self, src, dst):
        """(polyline (K,2), src entrance, dst entrance); building/entry-point pairs cached."""
        key = None if src[0] == "xy" else (src[0], int(src[1]), dst[0], int(dst[1]))
        hit = self._route_cache.get(key) if key else None
        if hit is not None:
            return hit
        cp = self.campus
        if hasattr(cp, "route_full"):
            rf = cp.route_full(src, dst)
            poly, se, de = rf["xy"], int(rf.get("src_entrance", -1)), int(rf.get("dst_entrance", -1))
        else:
            poly, _ = cp.route(src, dst)
            se = de = -1
        res = (np.asarray(poly, float).reshape(-1, 2), se, de)
        if key:
            self._route_cache[key] = res
        return res

    def _set_trip_pos(self, i):
        xs, ys, cum, total, d = self._trips[i][:5]
        k = min(max(bisect_right(cum, d) - 1, 0), len(cum) - 2)
        seg = cum[k + 1] - cum[k]
        f = (d - cum[k]) / seg if seg > 0 else 0.0
        self.x[i] = xs[k] + f * (xs[k + 1] - xs[k])
        self.y[i] = ys[k] + f * (ys[k + 1] - ys[k])
        self.trip_dist[i] = d

    # ------------------------------------------------------------------ main step
    def step(self, t, symptomatic=None):
        N, P = self.N, self.plans
        self.t = t
        pr = P.room[:, t].astype(np.int32)
        pa = P.act[:, t].astype(np.int8)
        pe = P.event[:, t]
        ps = P.section[:, t]
        des = pr.copy()
        dact = pa.copy()
        ovr = np.zeros(N, bool)
        self.entrance[:] = -1
        self._apply_overrides(t, des, dact, ovr, pr)

        if not self._t0_done:
            self._place_initial(t, des, pe)
        else:
            target = np.where(self._trav, self._dest, self._at)
            chg = np.flatnonzero(target != des)
            if len(chg):
                trav_chg = chg[self._trav[chg]]
                stat_chg = chg[~self._trav[chg]]
                a_ = self._at[stat_chg]
                d_ = des[stat_chg]
                same_b = (a_ >= 0) & (d_ >= 0)
                same_b[same_b] = self.r_b[a_[same_b]] == self.r_b[d_[same_b]]
                inst = stat_chg[same_b]
                trips = stat_chg[~same_b]
                # instant switches (new visit)
                if len(inst):
                    self._release_seats(inst)
                    self._at[inst] = des[inst]
                    xy = self._draw_positions(inst, des[inst], t, pe[inst])
                    self.x[inst], self.y[inst] = xy[:, 0], xy[:, 1]
                    self._mask_draw[inst] = True
                # advance existing travelers first (re-routed ones restart from their current xy)
                moving_old = np.flatnonzero(self._trav)
                if len(trav_chg):
                    self.n_reroutes += len(trav_chg)
                    self._start_trips(trav_chg, t, des, True)
                self._advance(moving_old, t)
                if len(trips):
                    self._start_trips(trips, t, des, False)
            else:
                self._advance(np.flatnonzero(self._trav), t)

        self._finalize(t, des, dact, ovr, pa, pe, ps, symptomatic)

    def _place_initial(self, t, des, pe):
        self._t0_done = True
        self._release_seats(np.arange(self.N))
        self._trav[:] = False
        self._trips.clear()
        self._at[:] = des
        on = np.flatnonzero(des >= 0)
        xy = self._draw_positions(on, des[on], t, pe[on])
        self.x[:] = np.nan
        self.y[:] = np.nan
        self.x[on], self.y[on] = xy[:, 0], xy[:, 1]
        self._mask_draw[:] = True

    def _advance(self, idx, t):
        """Move travelers idx one step; handle arrivals."""
        if len(idx) == 0:
            return
        ds = self.speed[idx] * self.step_s
        for i, d in zip(idx.tolist(), ds.tolist()):
            tr = self._trips[i]
            tr[4] += d
            if tr[4] >= tr[3]:
                self._arrive(i)
            else:
                self._set_trip_pos(i)

    def _arrive(self, i):
        xs, ys, cum, total, _, de = self._trips.pop(i)
        des = self._dest[i]
        self._trav[i] = False
        self._at[i] = des
        self._mask_draw[i] = True
        if des >= 0:
            self.x[i], self.y[i] = xs[-1], ys[-1]
            dx, dy = (xs[-2], ys[-2]) if len(xs) > 2 else (xs[-1], ys[-1])
            self.entrance[i] = de if de >= 0 else self._door(self.r_b[des], dx, dy)
        else:
            self.x[i] = self.y[i] = np.nan

    def _apply_overrides(self, t, des, dact, ovr, pr):
        iso_on = self._iso_until > t
        voi = self.c["vaden_overrides_isolation"]
        min_stay, max_ext = self.c["vaden_min_stay_steps"], self.c["vaden_max_extend_steps"]
        keys = set(self._vaden) | set(self._leave) | set(self._carry)
        keys.update(np.flatnonzero(iso_on).tolist())
        for i in sorted(keys):
            if i in self._vaden:
                v = self._vaden[i]
                s, e = v[0], v[1]
                if t >= s and (voi or not iso_on[i]):
                    if self._at[i] == self.vaden_room and not self._trav[i]:
                        v[2] += 1   # steps already spent in the waiting room
                    if t < e or (v[2] < min_stay and t < e + max_ext):
                        des[i], dact[i], ovr[i] = self.vaden_room, A_HEALTH, True
                        continue
                    del self._vaden[i]
                elif t >= e:
                    del self._vaden[i]
            if iso_on[i]:
                des[i], dact[i], ovr[i] = self._home_of(i), A_ISOLATE, True
                continue
            if i in self._leave:
                if pr[i] == self._leave[i]:
                    h = self._home_of(i)
                    des[i], dact[i], ovr[i] = h, (self._leave_act if h >= 0 else A_OFF), True
                    continue
                del self._leave[i]
            if i in self._carry:
                a, r, ev = self._eff_block(i, t)
                if _OPT[a]:
                    key = (a, r, ev)
                    dec = self._carry_dec.get(i)
                    if dec is None or dec[0] != key:
                        dec = (key, bool(self.rng.random() < self._carry[i]))
                        self._carry_dec[i] = dec
                    if not dec[1]:
                        h = self._home_of(i)
                        des[i], dact[i], ovr[i] = h, (self._drop_act if h >= 0 else A_OFF), True

    def _finalize(self, t, des, dact, ovr, pa, pe, ps, symptomatic):
        trav = self._trav
        at = self._at
        stat_on = ~trav & (at >= 0)
        off = ~trav & (at < 0)
        # bedroom residents: bed when sleeping/resting/isolating, desk otherwise
        hb = stat_on & self._home_bed & (at == self.home)
        if hb.any():
            bed = hb & self._bed_act[dact]
            desk = hb & ~bed
            self.x[bed], self.y[bed] = self.bed_xy[bed, 0], self.bed_xy[bed, 1]
            self.x[desk], self.y[desk] = self.desk_xy[desk, 0], self.desk_xy[desk, 1]
        # mingle re-sampling
        mg = np.flatnonzero(stat_on & np.isfinite(self._mc[:, 0]) & ~self._mask_draw)
        if len(mg):
            pick = mg[self.rng.random(len(mg)) < self.c["mingle_resample_p"]]
            if len(pick):
                xy = self._mc[pick] + self.rng.normal(0.0, self.c["mingle_sigma_m"], (len(pick), 2))
                xy = self._clip(xy, at[pick])
                self.x[pick], self.y[pick] = xy[:, 0], xy[:, 1]
        self.x[off] = np.nan
        self.y[off] = np.nan

        room = np.where(trav, ROOM_TRANSIT, at).astype(np.int32)
        self.room[:] = room
        rr = np.where(stat_on, at, 0)
        self.b[:] = np.where(stat_on, self.r_b[rr], -1)
        self.floor[:] = np.where(stat_on, self.r_floor[rr], np.nan)
        self.indoor[:] = stat_on & self.r_indoor[rr]
        self.moving[:] = trav
        self.trip_dist[~trav] = np.nan
        self.off_map[:] = off

        act = dact.copy()
        act[stat_on & (dact == A_COMMUTE)] = A_EARLY
        act[off & (dact != A_ISOLATE)] = A_OFF
        act[trav] = A_COMMUTE
        plan_ok = stat_on & ~ovr & (act == pa)
        self.event[:] = np.where(plan_ok, pe, -1)
        self.section[:] = np.where(plan_ok & ((act == A_CLASS) | (act == A_LAB)), ps, -1)
        early = np.flatnonzero(stat_on & ~ovr & (act == A_EARLY))
        if len(early):
            self._lookahead_early(t, early, at)
        self.isolating[:] = self._iso_until > t

        # masks: redraw on new visit or activity change
        redraw = self._mask_draw | (act != self.act)
        self.act[:] = act
        idx = np.flatnonzero(redraw)
        if len(idx):
            ctx_act = act[idx]
            p = self.pop.mask_propensity[idx] * self._cf[ctx_act]
            if symptomatic is not None:
                p = np.where(np.asarray(symptomatic)[idx], p * self.c["mask_symptomatic_boost"], p)
            p = np.clip(p, 0.0, self.c["mask_p_max"])
            self._mdraw_val[idx] = self.rng.random(len(idx)) < p
        self._mask_draw[:] = False
        self.masked[:] = self._mdraw_val | (self._force_until > t)

    def _lookahead_early(self, t, idx, at):
        """arrived_early agents carry the upcoming block's event/section (mock behavior)."""
        P = self.plans
        k = t
        todo = idx
        while len(todo) and k + 1 < self.T:
            k += 1
            a = P.act[todo, k]
            done = a != A_COMMUTE
            if done.any():
                d = todo[done]
                same = P.room[d, k] == at[d]
                d = d[same]
                self.event[d] = P.event[d, k]
                cl = (P.act[d, k] == A_CLASS) | (P.act[d, k] == A_LAB)
                self.section[d[cl]] = P.section[d[cl], k]
            todo = todo[~done]


def _dup(s):
    """Boolean mask: entries equal to an earlier entry in s."""
    if len(s) < 2:
        return np.zeros(len(s), bool)
    o = np.argsort(s, kind="stable")
    ss = s[o]
    d = np.zeros(len(s), bool)
    d[o[1:]] = ss[1:] == ss[:-1]
    return d
