"""Disease natural history + transmission (close-contact tiers and Wells-Riley room aerosol).

States S -> E -> I_pre -> (I_sym | I_asym) -> R. Durations are gamma draws (configs/diseases.json,
cfg["disease"] = selected preset). All per-step work is vectorized; Python loops only over the
handful of agents newly infected in a step.

Viral-load curve (relative to the peak at symptom onset = 1.0):
  I_pre : presym_start_level ** (1 - frac)            exponential ramp up to 1.0 at onset
  after : end_level ** frac                            exponential decay to end_level at t_end
  x asym_rel_infectiousness (asymptomatic) x individual multiplier (gamma, mean 1).

Aerosol: each indoor room is a well-mixed box, dC/dt = E/V - (ACH + decay) C (quanta/m^3).
decay is either aerosol.decay_per_hour, or (aerosol.inactivation = "humidity") deposition_per_hour +
humidity-dependent inactivation, recomputed each sim day from configs/weather.json.
A per-room per-source ledger (lazily decayed, sorted int64 keys r*N+s) attributes aerosol
infections to sources, including sources that already left the room.
"""
import math

import numpy as np
import pandas as pd

from . import codes
from .codes import S, E, I_PRE, I_SYM, I_ASYM, R

_INF = np.array(codes.INFECTIOUS_STATES)


def _act_table(d, default_key="default"):
    """dict activity-name -> value (with 'default') -> float array indexed by codes.ACT."""
    default = float(d.get(default_key, 1.0))
    out = np.full(len(codes.ACTIVITIES), default)
    for k, v in d.items():
        if k in codes.ACT:
            out[codes.ACT[k]] = float(v)
    return out


def _gamma(rng, spec, n):
    """Gamma draws (days) from {"dist":"gamma","mean","sd"}."""
    m, sd = float(spec["mean"]), float(spec["sd"])
    if sd <= 0:
        return np.full(n, m)
    k = (m / sd) ** 2
    return rng.gamma(k, sd * sd / m, n)


def indoor_rh(outdoor_rh, outdoor_temp_c=None, indoor_temp_c=21.0):
    """Heated outdoor air keeps its water content, so indoor RH is lower than outdoor in cold weather."""
    if outdoor_temp_c is None or outdoor_temp_c >= indoor_temp_c:
        return float(outdoor_rh)

    def sat(t):  # saturation vapour pressure, hPa (Magnus)
        return 6.112 * math.exp(17.62 * t / (243.12 + t))
    return min(100.0, outdoor_rh * sat(outdoor_temp_c) / sat(indoor_temp_c))


def flu_inactivation(rh):
    """1/h airborne influenza inactivation vs RH (Noti et al. 2013: ~75% infectious after 1 h at
    RH < 25%, ~20% at RH > 43%), linear in between."""
    low, high = math.log(1 / 0.75), math.log(1 / 0.20)
    return low + (high - low) * min(max((rh - 25.0) / 20.0, 0.0), 1.0)


def weather_on_day(cfg, day):
    """(outdoor_rh_pct, outdoor_temp_c, indoor_temp_c) for sim day `day`."""
    w = cfg.get("weather") or {}
    rh, temp = float(w.get("outdoor_rh_pct", 60.0)), w.get("outdoor_temp_c", 10.0)
    daily = w.get("daily") or []
    if daily:
        d = daily[min(day, len(daily) - 1)]
        rh, temp = float(d.get("outdoor_rh_pct", rh)), d.get("outdoor_temp_c", temp)
    return rh, (None if temp is None else float(temp)), float(w.get("indoor_temp_c", 21.0))


def aerosol_decay(cfg, day=0):
    """(decay 1/h, indoor RH % or None) for sim day `day` under the preset's aerosol settings."""
    ae = cfg["disease"]["aerosol"]
    if ae.get("inactivation") != "humidity":
        return float(ae["decay_per_hour"]), None
    rh = indoor_rh(*weather_on_day(cfg, day))
    return float(ae["deposition_per_hour"]) + flu_inactivation(rh), rh


class Disease:
    def __init__(self, cfg, campus, pop, rng):
        self.cfg = cfg
        self.dc = dc = cfg["disease"]
        self.campus = campus
        self.pop = pop
        self.rng = rng
        self.N = N = int(pop.N)
        self.step_min = float(cfg["run"]["step_min"])
        self.spd = int(round(1440 / self.step_min))
        self.dt_h = self.step_min / 60.0

        self.state = np.zeros(N, np.int8)
        self.t_infected = np.full(N, -1, np.int64)
        self.t_infectious = np.full(N, -1, np.int64)
        self.t_onset = np.full(N, -1, np.int64)
        self.t_end = np.full(N, -1, np.int64)
        self.asym = np.zeros(N, bool)
        self.mult = np.ones(N)
        self.peak_sev = np.zeros(N)
        self.infectiousness = np.zeros(N)
        self.severity = np.zeros(N)
        self.infections = []

        # parameters
        vl = dc["viral_load"]
        self.vl_start = float(vl["presym_start_level"])
        self.vl_end = float(vl["end_level"])
        self.asym_rel = float(dc["asym_rel_infectiousness"])
        self.p_asym = float(dc["p_asym"])
        self.mult_shape = float(dc["individual_infectiousness_gamma_shape"])
        self.mult_max = float(dc.get("individual_infectiousness_max", 1e9))
        sv = dc["severity"]
        self.sev_a, self.sev_b = float(sv["beta_a"]), float(sv["beta_b"])
        self.sev_rise = float(sv.get("rise_days", 0.5)) * self.spd
        self.sev_onset_frac = float(sv.get("onset_fraction", 0.3))
        self.sev_end_frac = float(sv.get("end_fraction", 0.1))
        ch = dc["close_hazard_per_min"]
        self.w_tier = np.array([0.0, ch["tier1"], ch["tier2"], ch["tier3"], 0.0, 0.0])
        self.outdoor_mult = float(dc["outdoor_multiplier"])
        self.src_eff = float(dc["masks"]["source_eff"])
        self.wear_eff = float(dc["masks"]["wearer_eff"])
        ae = dc["aerosol"]
        self.q_peak = float(ae["quanta_per_hour_peak"])
        self.breath = _act_table(ae["breathing_m3_per_h"])
        self.emis_act = _act_table(ae.get("emission_multiplier_by_activity", {"default": 1.0}))
        self.scale = float(dc["transmission_scale"])
        self.import_scale = float(dc.get("import_scale", 1.0))
        self.conc_thr = float(dc.get("concentration_report_threshold", 1e-6))
        self.ledger_prune = float(ae.get("ledger_prune_level", 1e-10))
        imp = pop.param("import_daily_p") if self.import_scale > 0 else np.zeros(N)
        pd_ = np.clip(np.asarray(imp, float) * self.import_scale, 0.0, 1.0)
        self.import_p_step = 1.0 - (1.0 - pd_) ** (1.0 / self.spd)

        # rooms
        self.R = R_ = len(campus.room_vol)
        self.room_vol = np.maximum(np.asarray(campus.room_vol, float), 1.0)
        self.room_indoor = np.asarray(campus.room_indoor, bool)
        self.room_ach = np.asarray(campus.room_ach, float)
        self.decay, self.indoor_rh, self._decay_day = None, None, -1
        self._set_decay(0)
        self.room_conc = np.zeros(R_)
        self._cavg = np.zeros(R_)
        self._led_key = np.zeros(0, np.int64)
        self._led_val = np.zeros(0)   # contribution at end of step _led_t
        self._led_avg = np.zeros(0)   # step-average contribution during step _led_t
        self._led_t = np.zeros(0, np.int64)
        self._prune_every = max(1, self.spd // 24)

        f_imm = float(dc.get("initial_immune_fraction", 0.0))
        if f_imm > 0:
            self.state[rng.random(N) < f_imm] = R

    # ------------------------------------------------------------------ helpers
    def _set_decay(self, day):
        """Room loss rates for sim day `day` (weather may change daily)."""
        self._decay_day = day
        decay, self.indoor_rh = aerosol_decay(self.cfg, day)
        if decay == self.decay:
            return
        # Ledger entries decay lazily with the current lam, so a gap spanning a weather change uses
        # the new day's rate for the whole gap (exact while the weather is constant).
        self.decay = decay
        self.lam = np.maximum(self.room_ach + decay, 1e-6)  # 1/h
        self.room_a = np.exp(-self.lam * self.dt_h)
        self.room_avgf = (1.0 - self.room_a) / (self.lam * self.dt_h)  # mean of decay over a step

    @property
    def symptomatic(self):
        return self.state == I_SYM

    def days_since_infection(self, t):
        out = (t - self.t_infected) * (self.step_min / 1440.0)
        return np.where(self.t_infected >= 0, out, np.nan)

    def _infect(self, idx, t, infector, route, r, b, contribution):
        """Infect agents idx (sorted, distinct, currently S) at step t; append tree rows."""
        idx = np.asarray(idx, np.int64)
        n = len(idx)
        if n == 0:
            return
        rng, dc, spd = self.rng, self.dc, self.spd
        lat = np.maximum(1, np.rint(_gamma(rng, dc["latent_days"], n) * spd)).astype(np.int64)
        pre = np.maximum(1, np.rint(_gamma(rng, dc["presym_days"], n) * spd)).astype(np.int64)
        post = np.maximum(1, np.rint(_gamma(rng, dc["infectious_days"], n) * spd)).astype(np.int64)
        asym = rng.random(n) < self.p_asym
        k = self.mult_shape
        mult = rng.gamma(k, 1.0 / k, n) if k > 0 else np.ones(n)
        sev = rng.beta(self.sev_a, self.sev_b, n)
        self.state[idx] = E
        self.t_infected[idx] = t
        self.t_infectious[idx] = t + lat
        self.t_onset[idx] = t + lat + pre
        self.t_end[idx] = t + lat + pre + post
        self.asym[idx] = asym
        self.mult[idx] = np.minimum(mult, self.mult_max)
        self.peak_sev[idx] = np.where(asym, 0.0, sev)
        infector = np.broadcast_to(np.asarray(infector, np.int64), (n,))
        r = np.broadcast_to(np.asarray(r, np.int64), (n,))
        b = np.broadcast_to(np.asarray(b, np.int64), (n,))
        contribution = np.broadcast_to(np.asarray(contribution, float), (n,))
        route = np.broadcast_to(np.asarray(route, object), (n,))
        for j in range(n):
            self.infections.append(dict(t=int(t), infectee=int(idx[j]), infector=int(infector[j]),
                                        route=str(route[j]), r=int(r[j]), b=int(b[j]),
                                        contribution=float(contribution[j])))

    def seed_initial(self, n, t=0):
        """Infect n random susceptibles at step t (route 'seed', state E)."""
        sus = np.flatnonzero(self.state == S)
        n = min(int(n), len(sus))
        if n <= 0:
            return np.zeros(0, np.int64)
        idx = np.sort(self.rng.choice(sus, n, replace=False))
        self._infect(idx, t, -1, "seed", -1, -1, 1.0)
        return idx

    # ------------------------------------------------------------------ progression
    def _progress(self, t):
        st = self.state
        m = (st == E) & (t >= self.t_infectious)
        st[m] = I_PRE
        m = (st == I_PRE) & (t >= self.t_onset)
        onset = np.flatnonzero(m & ~self.asym)
        st[m] = np.where(self.asym[m], I_ASYM, I_SYM).astype(np.int8)
        m = ((st == I_SYM) | (st == I_ASYM)) & (t >= self.t_end)
        recovered = np.flatnonzero(m)
        st[recovered] = R
        self._update_curves(t)
        return onset, recovered

    def _update_curves(self, t):
        self.infectiousness[:] = 0.0
        self.severity[:] = 0.0
        inf = np.flatnonzero(np.isin(self.state, _INF))
        if len(inf) == 0:
            return
        t0, t1, t2 = self.t_infectious[inf], self.t_onset[inf], self.t_end[inf]
        pre = t < t1
        fpre = np.clip((t - t0) / np.maximum(t1 - t0, 1), 0, 1)
        fpost = np.clip((t - t1) / np.maximum(t2 - t1, 1), 0, 1)
        vl = np.where(pre, self.vl_start ** (1.0 - fpre), self.vl_end ** fpost)
        vl = vl * np.where(self.asym[inf], self.asym_rel, 1.0) * self.mult[inf]
        self.infectiousness[inf] = vl
        sym = inf[self.state[inf] == I_SYM]
        if len(sym):
            x = (t - self.t_onset[sym]).astype(float)
            dur = np.maximum(self.t_end[sym] - self.t_onset[sym], 1).astype(float)
            rise = np.minimum(self.sev_rise, 0.5 * dur)
            up = self.sev_onset_frac + (1 - self.sev_onset_frac) * np.clip(x / np.maximum(rise, 1), 0, 1)
            down = 1.0 - (1.0 - self.sev_end_frac) * np.clip((x - rise) / np.maximum(dur - rise, 1), 0, 1)
            self.severity[sym] = self.peak_sev[sym] * np.where(x < rise, up, down)

    # ------------------------------------------------------------------ aerosol
    def _aerosol(self, t, beh):
        room = np.asarray(beh.room)
        onmap = (room >= 0) & ~np.asarray(beh.off_map, bool)
        rr = np.where(onmap, room, 0)
        in_room = onmap & self.room_indoor[rr]
        masked = np.asarray(beh.masked, bool)
        act = np.asarray(beh.act, np.int64)
        src = np.flatnonzero(in_room & (self.infectiousness > 0))
        c_old = self.room_conc
        if len(src):
            e = self.q_peak * self.infectiousness[src] * self.emis_act[act[src]]
            e = np.where(masked[src], e * (1 - self.src_eff), e)  # quanta/h
            sr = room[src].astype(np.int64)
            Er = np.bincount(sr, e, self.R)
        else:
            Er = np.zeros(self.R)
        css = Er / (self.lam * self.room_vol)
        self._cavg = css + (c_old - css) * self.room_avgf
        c_new = css + (c_old - css) * self.room_a
        c_new[c_new < 1e-15] = 0.0
        self.room_conc = c_new
        if len(src):
            self._ledger_update(t, sr, src, e / (self.lam[sr] * self.room_vol[sr]))
        if t % self._prune_every == 0:
            self._ledger_prune(t)
        sus = np.flatnonzero(in_room & (self.state == S))
        H = np.zeros(self.N)
        if len(sus):
            rs = room[sus]
            cav = self._cavg[rs]
            nz = cav > 0
            sus, rs, cav = sus[nz], rs[nz], cav[nz]
            dose = self.breath[act[sus]] * cav * self.dt_h
            dose = np.where(masked[sus], dose * (1 - self.wear_eff), dose)
            H[sus] = self.scale * dose
        return H

    def _ledger_update(self, t, sr, src, css_s):
        """Advance ledger entries (room sr, source src) by step t with source steady-state css_s."""
        keys = sr * self.N + src
        order = np.argsort(keys, kind="stable")
        keys, sr, css_s = keys[order], sr[order], css_s[order]
        pos = np.searchsorted(self._led_key, keys)
        exists = (pos < len(self._led_key)) & (self._led_key[np.minimum(pos, len(self._led_key) - 1)] == keys) \
            if len(self._led_key) else np.zeros(len(keys), bool)
        if (~exists).any():
            newk = keys[~exists]
            allk = np.concatenate([self._led_key, newk])
            o = np.argsort(allk, kind="stable")
            self._led_key = allk[o]
            self._led_val = np.concatenate([self._led_val, np.zeros(len(newk))])[o]
            self._led_avg = np.concatenate([self._led_avg, np.zeros(len(newk))])[o]
            self._led_t = np.concatenate([self._led_t, np.full(len(newk), t - 1, np.int64)])[o]
            pos = np.searchsorted(self._led_key, keys)
        lam = self.lam[sr]
        gap = (t - 1 - self._led_t[pos]).astype(float)
        prev = self._led_val[pos] * np.exp(-lam * gap * self.dt_h)  # value at end of step t-1
        self._led_avg[pos] = css_s + (prev - css_s) * self.room_avgf[sr]
        self._led_val[pos] = css_s + (prev - css_s) * self.room_a[sr]
        self._led_t[pos] = t

    def _ledger_prune(self, t):
        if len(self._led_key) == 0:
            return
        r = self._led_key // self.N
        cur = self._led_val * np.exp(-self.lam[r] * (t - self._led_t) * self.dt_h)
        keep = cur > self.ledger_prune
        if not keep.all():
            self._led_key, self._led_val = self._led_key[keep], self._led_val[keep]
            self._led_avg, self._led_t = self._led_avg[keep], self._led_t[keep]

    def ledger_contrib(self, t, r):
        """(sources, step-average concentration contributions) in room r during step t."""
        lo, hi = np.searchsorted(self._led_key, [r * self.N, (r + 1) * self.N])
        if hi <= lo:
            return np.zeros(0, np.int64), np.zeros(0)
        src = self._led_key[lo:hi] - r * self.N
        lt = self._led_t[lo:hi]
        prev = self._led_val[lo:hi] * np.exp(-self.lam[r] * (t - 1 - lt) * self.dt_h)
        contrib = np.where(lt == t, self._led_avg[lo:hi], prev * self.room_avgf[r])
        return src, contrib

    # ------------------------------------------------------------------ close contact
    def _close(self, beh, contacts):
        N = self.N
        H = np.zeros(N)
        empty = (np.zeros(0, np.int64),) * 2 + (np.zeros(0),) + (np.zeros(0, np.int64),) * 2
        if contacts is None or len(contacts.get("a", ())) == 0:
            return H, empty
        a = np.asarray(contacts["a"], np.int64)
        b = np.asarray(contacts["b"], np.int64)
        tier = np.asarray(contacts["tier"], np.int64)
        ok = ~np.asarray(contacts["wall"], bool) & (tier >= 1) & (tier <= 3)
        inf = self.infectiousness
        sus = (self.state == S) & ~np.asarray(beh.off_map, bool)
        ok &= ((inf[a] > 0) & sus[b]) | ((inf[b] > 0) & sus[a])
        if not ok.any():
            return H, empty
        sel = np.flatnonzero(ok)
        a, b, tier = a[sel], b[sel], tier[sel]
        indoor = np.asarray(contacts["indoor"], bool)[sel]
        pr = np.asarray(contacts["r"], np.int64)[sel]
        pb = np.asarray(contacts["bld"], np.int64)[sel]
        masked = np.asarray(beh.masked, bool)
        sf = np.where(masked, 1 - self.src_eff, 1.0)
        wf = np.where(masked, 1 - self.wear_eff, 1.0)
        base = self.scale * self.w_tier[tier] * self.step_min * np.where(indoor, 1.0, self.outdoor_mult)
        h1 = base * inf[a] * sf[a] * wf[b] * sus[b]   # a -> b
        h2 = base * inf[b] * sf[b] * wf[a] * sus[a]   # b -> a
        tgt = np.concatenate([b, a])
        srcs = np.concatenate([a, b])
        h = np.concatenate([h1, h2])
        rr = np.concatenate([pr, pr])
        bb = np.concatenate([pb, pb])
        nz = h > 0
        tgt, srcs, h, rr, bb = tgt[nz], srcs[nz], h[nz], rr[nz], bb[nz]
        H += np.bincount(tgt, h, N)
        return H, (tgt, srcs, h, rr, bb)

    # ------------------------------------------------------------------ main step
    def step(self, t, beh, contacts):
        if t // self.spd != self._decay_day:
            self._set_decay(t // self.spd)
        onset, recovered = self._progress(t)
        new = []
        # imports (all susceptibles, on or off map)
        sus = np.flatnonzero(self.state == S)
        if len(sus):
            hit = sus[self.rng.random(len(sus)) < self.import_p_step[sus]]
            if len(hit):
                self._infect(hit, t, -1, "import", -1, -1, 1.0)
                new.append(hit)
        Ha = self._aerosol(t, beh)
        Hc, pairs = self._close(beh, contacts)
        Ht = Ha + Hc
        cand = np.flatnonzero((Ht > 0) & (self.state == S))
        if len(cand):
            p = -np.expm1(-Ht[cand])
            u = self.rng.random(len(cand))
            inf_idx = cand[u < p]
            if len(inf_idx):
                self._attribute(t, beh, inf_idx, Hc, Ha, pairs)
                new.append(inf_idx)
        infected = np.sort(np.concatenate(new)) if new else np.zeros(0, np.int64)
        return {"onset": onset, "recovered": recovered, "infected": infected}

    def _attribute(self, t, beh, idx, Hc, Ha, pairs):
        tgt, srcs, h, rr, bb = pairs
        u_route = self.rng.random(len(idx))
        room = np.asarray(beh.room)
        infector = np.full(len(idx), -1, np.int64)
        route = np.empty(len(idx), object)
        r_out = np.full(len(idx), -1, np.int64)
        b_out = np.full(len(idx), -1, np.int64)
        contrib = np.zeros(len(idx))
        for j, i in enumerate(idx):
            Htot = Hc[i] + Ha[i]
            if u_route[j] * Htot < Hc[i]:
                m = np.flatnonzero(tgt == i)
                k = m[np.argmax(h[m])]  # first max: pairs sorted by (a,b) -> deterministic
                infector[j], route[j], contrib[j] = srcs[k], "close", h[k] / Htot
                r_out[j], b_out[j] = rr[k], bb[k]
                if r_out[j] < 0 and b_out[j] < 0 and room[i] >= 0:
                    r_out[j] = room[i]
                if r_out[j] >= 0 and b_out[j] < 0:
                    b_out[j] = self.campus.room_b[r_out[j]]
            else:
                r = int(room[i])
                s, c = self.ledger_contrib(t, r)
                tot = c.sum()
                route[j], r_out[j], b_out[j] = "aerosol", r, self.campus.room_b[r]
                if tot > 0:
                    cum = np.cumsum(c)
                    k = min(int(np.searchsorted(cum, self.rng.random() * tot, side="right")), len(c) - 1)
                    infector[j] = s[k]
                    contrib[j] = Ha[i] * (c[k] / tot) / Htot
        self._infect(idx, t, infector, route, r_out, b_out, contrib)

    # ------------------------------------------------------------------ output
    def room_exposure_rows(self, t, beh):
        room = np.asarray(beh.room)
        on = room >= 0
        occ = np.bincount(room[on], minlength=self.R)
        infm = on & np.isin(self.state, _INF)
        iocc = np.bincount(room[infm], minlength=self.R)
        r = np.flatnonzero((occ > 0) | (self.room_conc > self.conc_thr))
        return {"r": r, "occupants": occ[r], "infectious_occupants": iocc[r],
                "quanta_concentration": self.room_conc[r]}


# ---------------------------------------------------------------------- d2 frames
INFECTION_COLUMNS = ["t", "infectee_id", "infector_id", "route", "location_id", "room_id", "infector_contribution"]
EXPOSURE_COLUMNS = ["t", "room_id", "occupants", "infectious_occupants", "quanta_concentration"]


def infections_frame(dis, campus, pop):
    """d2 infections.csv frame, rows sorted by (t, infectee_id)."""
    if not dis.infections:
        return pd.DataFrame({c: pd.Series(dtype=object if c not in ("t", "infector_contribution") else
                                          (np.int64 if c == "t" else float)) for c in INFECTION_COLUMNS})
    df = pd.DataFrame(dis.infections)
    aid = np.asarray(pop.agent_id, dtype=object)
    loc = campus.buildings["location_id"].to_numpy(dtype=object)
    rid = campus.rooms["room_id"].to_numpy(dtype=object)
    b, r, inf = df["b"].to_numpy(), df["r"].to_numpy(), df["infector"].to_numpy()
    out = pd.DataFrame({
        "t": df["t"].astype(np.int64),
        "infectee_id": aid[df["infectee"].to_numpy()],
        "infector_id": np.where(inf >= 0, aid[np.maximum(inf, 0)], "IMPORT"),
        "route": df["route"].astype(str),
        "location_id": np.where(b >= 0, loc[np.maximum(b, 0)], ""),
        "room_id": np.where(r >= 0, rid[np.maximum(r, 0)], ""),
        "infector_contribution": df["contribution"].astype(float).round(4),
    })
    return out.sort_values(["t", "infectee_id"], kind="stable").reset_index(drop=True)


def room_exposure_frame(t, rows, campus):
    """d2 room_exposure rows for step t, sorted by room_id."""
    rid = campus.rooms["room_id"].to_numpy(dtype=object)
    r = np.asarray(rows["r"], np.int64)
    df = pd.DataFrame({
        "t": np.full(len(r), int(t), np.int64),
        "room_id": rid[r] if len(r) else np.zeros(0, object),
        "occupants": np.asarray(rows["occupants"], np.int64),
        "infectious_occupants": np.asarray(rows["infectious_occupants"], np.int64),
        "quanta_concentration": np.round(np.asarray(rows["quanta_concentration"], float), 6),
    })
    return df.sort_values("room_id", kind="stable").reset_index(drop=True)


# ---------------------------------------------------------------------- calibration
CAL_SCENARIOS = {
    # Room geometry/ventilation follow the d2 mock map (dorm_double 54 m^3 @ 2 ACH, seminar 144 m^3 @ 4 ACH).
    "roommate": dict(vol=54.0, ach=2.0, hours_per_day={"sleep": 8.0, "relax": 2.0}, tier=3),
    "seminar": dict(vol=144.0, ach=4.0, hours=1.0, act="class",
                    tier_frac={1: 0.0, 2: 0.15, 3: 0.40}),  # share of the hour at each tier (avg seat)
    "party": dict(vol=300.0, ach=2.0, hours=3.0, act="party", tier_frac={1: 0.25, 2: 0.50, 3: 0.25}),
}


def _mean_curve(dc, spd):
    """Mean viral-load curve per step from start of infectiousness (mean durations, symptomatic)."""
    pre = max(1, round(dc["presym_days"]["mean"] * spd))
    post = max(1, round(dc["infectious_days"]["mean"] * spd))
    s0, e1 = dc["viral_load"]["presym_start_level"], dc["viral_load"]["end_level"]
    f = np.concatenate([s0 ** (1 - np.arange(pre) / pre), e1 ** (np.arange(post) / post)])
    return f


def _gamma_avg(H, k):
    """E[1-exp(-H m)] with m ~ Gamma(k, 1/k)."""
    return 1 - (1 + H / k) ** (-k) if k > 0 else 1 - math.exp(-H)


def calibration_report(cfg, verbose=True):
    """Analytic infection probabilities for reference scenarios using the preset's formulas."""
    dc = cfg["disease"]
    step_min = float(cfg["run"]["step_min"])
    spd = int(round(1440 / step_min))
    dt_h = step_min / 60
    ae = dc["aerosol"]
    br, em = _act_table(ae["breathing_m3_per_h"]), _act_table(ae.get("emission_multiplier_by_activity", {"default": 1}))
    q, sc = ae["quanta_per_hour_peak"], dc["transmission_scale"]
    dec, rh = aerosol_decay(cfg, 0)
    ch = dc["close_hazard_per_min"]
    w = {1: ch["tier1"], 2: ch["tier2"], 3: ch["tier3"]}
    k = dc["individual_infectiousness_gamma_shape"]
    out = {}

    # roommate: co-located in bedroom hours_per_day; concentration from source's emission in steady state
    s = CAL_SCENARIOS["roommate"]
    lam = s["ach"] + dec
    curve = _mean_curve(dc, spd)
    peak_days = curve.sum() / spd
    aero_per_peakday = sum(hh * q * em[codes.ACT[a]] / (lam * s["vol"]) * br[codes.ACT[a]]
                           for a, hh in s["hours_per_day"].items())
    hrs = sum(s["hours_per_day"].values())
    close_per_peakday = w[s["tier"]] * hrs * 60
    res = {}
    for label, rel in (("sym", 1.0), ("asym", dc["asym_rel_infectiousness"])):
        Ha, Hc = sc * aero_per_peakday * peak_days * rel, sc * close_per_peakday * peak_days * rel
        res[label] = (Ha, Hc, _gamma_avg(Ha + Hc, k), 1 - math.exp(-(Ha + Hc)))
    pa = dc["p_asym"]
    sar = (1 - pa) * res["sym"][2] + pa * res["asym"][2]
    sar_nohet = (1 - pa) * res["sym"][3] + pa * res["asym"][3]
    out["roommate_SAR"] = sar
    out["roommate_SAR_no_overdispersion"] = sar_nohet
    out["roommate_H_aero_sym"], out["roommate_H_close_sym"] = res["sym"][0], res["sym"][1]
    out["peak_equivalent_infectious_days_sym"] = peak_days

    for name in ("seminar", "party"):
        s = CAL_SCENARIOS[name]
        lam = s["ach"] + dec
        a = br[codes.ACT[s["act"]]]
        e = q * em[codes.ACT[s["act"]]]
        css = e / (lam * s["vol"])
        n = int(round(s["hours"] / dt_h))
        c, dose = 0.0, 0.0
        avgf, aa = (1 - math.exp(-lam * dt_h)) / (lam * dt_h), math.exp(-lam * dt_h)
        for _ in range(n):  # room starts clean, source present from start, peak infectiousness
            dose += a * (css + (c - css) * avgf) * dt_h
            c = css + (c - css) * aa
        Ha = sc * dose
        Hc = sc * sum(w[tt] * f * s["hours"] * 60 for tt, f in s["tier_frac"].items())
        out[f"{name}_H_aero"], out[f"{name}_H_close"] = Ha, Hc
        out[f"{name}_p"] = 1 - math.exp(-(Ha + Hc))
    if verbose:
        print(f"[{dc.get('preset', '?')}] peak-equivalent infectious days (sym, mean curve): {peak_days:.2f}")
        print(f"  aerosol decay {dec:.3f}/h" + ("" if rh is None else f" (day-0 indoor RH {rh:.1f}%)"))
        print(f"  roommate SAR/episode: {sar:.3f} (no overdispersion {sar_nohet:.3f}); "
              f"sym H_aero={res['sym'][0]:.3f} H_close={res['sym'][1]:.3f}")
        for name in ("seminar", "party"):
            print(f"  {name}: p={out[name + '_p']:.4f} (H_aero={out[name + '_H_aero']:.4f}, "
                  f"H_close={out[name + '_H_close']:.4f})")
    return out
