"""Class sections (real Winter sections from ExploreCourses, or synthetic MWF/TTh/lab on the Stanford
grid) and social events (parties, dorm hangouts,
sports games / large events, study groups). Config: configs/schedule.json (cfg["schedule"]).

build_sections(cfg, campus, pop, rng) -> DataFrame (and fills pop.class_schedule)
build_events(cfg, campus, pop, sections, rng) -> DataFrame (absolute minutes since sim start)
sections_frame_for_csv / events_frame_for_csv -> d2 schedule/*.csv frames
"""
import math
import re
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

from . import codes

DAY_CODES = {"M": 0, "T": 1, "W": 2, "Th": 3, "F": 4, "Sa": 5, "Su": 6}
DAY_NAMES = ["M", "T", "W", "Th", "F", "Sa", "Su"]
PATTERN_DAYS = {"MWF": [0, 2, 4], "TTh": [1, 3]}
PATTERN_PREFIX = {"MWF": "MWF", "TTh": "TTH", "LAB": "LAB"}
PATTERN_ORDER = {"MWF": 0, "TTh": 1, "LAB": 2}
SEC_COLUMNS = ["section_id", "course", "kind", "r", "room_id", "location_id", "days", "weekdays",
               "start_min", "end_min", "enrolled", "component", "room_name", "title"]
ROOT = Path(__file__).resolve().parent.parent
EV_COLUMNS = ["event_id", "type", "name", "r", "room_id", "location_id", "day", "start_min",
              "end_min", "attendees"]
EV_TYPE_ORDER = {"sports_game": 0, "large_event": 1, "party": 2, "dorm_hangout": 3, "study_group": 4}


# ----------------------------------------------------------------------------- helpers
def _hm(s):
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def _fmt_hm(m):
    return f"{m // 60:02d}:{m % 60:02d}"


def _mask(weekdays, start, end):
    """Bitmask over (weekday, minute) cells, 1 bit per minute."""
    span = (1 << (end - start)) - 1
    out = 0
    for wd in weekdays:
        out |= span << (wd * 1440 + start)
    return out


def _param(pop, name, default):
    try:
        v = np.asarray(pop.param(name), dtype=float)
    except (KeyError, AttributeError, ValueError, TypeError):
        v = np.full(pop.N, float(default))
    return v


def _dept(course):
    return course.split(" ")[0]


class _RoomIndex:
    """numpy views of campus rooms used for lookups."""

    def __init__(self, campus):
        rooms = campus.rooms
        self.R = len(rooms)
        self.type = rooms["room_type"].to_numpy().astype(str)
        self.b = np.asarray(getattr(campus, "room_b", rooms["b"].to_numpy()), dtype=np.int64)
        self.cap = np.asarray(getattr(campus, "room_cap", rooms["capacity"].to_numpy()), dtype=np.int64)
        self.room_id = rooms["room_id"].to_numpy().astype(str)
        self.loc_id = rooms["location_id"].to_numpy().astype(str)
        if hasattr(campus, "room_layout"):
            lay = np.asarray(campus.room_layout)
            if lay.dtype.kind in "iu":
                self.layout = np.array(campus.LAYOUTS, dtype=object)[lay].astype(str)
            else:
                self.layout = lay.astype(str)
        else:
            self.layout = rooms["layout"].to_numpy().astype(str)
        self.b_type = np.asarray(campus.buildings["type"].to_numpy()).astype(str)
        self._by_b = None

    def of_types(self, types, b_types=None):
        m = np.isin(self.type, list(types))
        if b_types is not None:
            m &= np.isin(self.b_type[self.b], list(b_types))
        return np.flatnonzero(m)

    def in_building(self, b, types):
        if self._by_b is None:
            order = np.argsort(self.b, kind="stable")
            bs = self.b[order]
            self._by_b = (order, bs)
        order, bs = self._by_b
        lo, hi = np.searchsorted(bs, b, "left"), np.searchsorted(bs, b, "right")
        rr = order[lo:hi]
        return np.sort(rr[np.isin(self.type[rr], list(types))])


# ----------------------------------------------------------------------------- sections
def _n_courses(pop, scfg, rng):
    lo, hi = int(scfg["min_courses"]), int(scfg["max_courses"])
    try:
        v = np.asarray(pop.param("n_courses"), dtype=float)
    except (KeyError, AttributeError, ValueError, TypeError):
        v = np.full(pop.N, float(scfg["mean_courses_default"]))
    if v.ndim == 2 and v.shape[1] == 2:  # per-agent [min, max] range
        a = np.clip(v[:, 0], lo, hi).astype(int)
        b = np.clip(v[:, 1], lo, hi).astype(int)
        k = a + np.floor(rng.random(pop.N) * (b - a + 1)).astype(int)
    else:  # per-agent mean: floor + Bernoulli(frac)
        v = v.reshape(pop.N)
        k = np.floor(v).astype(int) + (rng.random(pop.N) < (v - np.floor(v))).astype(int)
    return np.clip(k, lo, hi)


def build_sections(cfg, campus, pop, rng):
    """Generate the course catalog, place sections in rooms, enroll agents."""
    scfg = cfg["schedule"]["sections"]
    if scfg.get("source", "synthetic") == "explorecourses":
        return _build_sections_real(cfg, campus, pop, rng)
    N = pop.N
    ri = _RoomIndex(campus)
    k_target = _n_courses(pop, scfg, rng)
    max_courses = int(scfg["max_courses"])

    mix = scfg["size_mix"]
    mix_p = np.array([m["p"] for m in mix], dtype=float)
    mix_p /= mix_p.sum()
    mean_size = sum(p * np.mean(np.minimum(np.arange(m["min"], m["max"] + 1), N)) for p, m in zip(mix_p, mix))
    n_sections = max(math.ceil(scfg["capacity_slack"] * k_target.sum() / mean_size), 2 * max_courses)

    # --- catalog: size class, size, pattern, slot, course name
    cat = rng.choice(len(mix), size=n_sections, p=mix_p)
    sizes = np.array([rng.integers(mix[c]["min"], mix[c]["max"] + 1) for c in cat], dtype=int)
    sizes = np.minimum(sizes, N)
    pattern = np.where(rng.random(n_sections) < scfg["mwf_frac"], "MWF", "TTh")
    slots = {"MWF": [_hm(s) for s in scfg["mwf_slots"]], "TTh": [_hm(s) for s in scfg["tth_slots"]]}
    durs = {"MWF": int(scfg["mwf_dur_min"]), "TTh": int(scfg["tth_dur_min"])}
    load = {p: np.zeros(len(slots[p]), dtype=int) for p in slots}
    slot_of = np.zeros(n_sections, dtype=int)
    tie = rng.random((n_sections, max(len(v) for v in slots.values())))
    for s in range(n_sections):  # least-loaded slot, random tie-break
        p = pattern[s]
        n = len(slots[p])
        slot_of[s] = int(np.lexsort((tie[s, :n], load[p]))[0])
        load[p][slot_of[s]] += 1
    pools = {name: list(scfg["courses"][name]) for name in scfg["courses"]}
    pool_order = {name: [pools[name][j] for j in rng.permutation(len(pools[name]))] for name in pools}
    pool_ctr = {name: 0 for name in pools}
    course = []
    for c in cat:
        name = mix[c]["name"]
        course.append(pool_order[name][pool_ctr[name] % len(pool_order[name])])
        pool_ctr[name] += 1

    # --- room assignment (largest sections first), no double booking
    room_busy = {}
    excl = set(scfg["fallback_exclude_room_types"])
    seated_all = np.flatnonzero((ri.layout == "seated") & ~np.isin(ri.type, list(excl)))
    seated_all = seated_all[np.lexsort((seated_all, ri.cap[seated_all]))]
    pref = {}
    for name, types in scfg["room_types"].items():
        rr = ri.of_types(types)
        pref[name] = rr[np.lexsort((rr, ri.cap[rr]))]  # by capacity asc, then idx
    n_warn = {"shrunk": 0, "moved_slot": 0, "double_booked": 0, "lab_skipped": 0}

    def pick_room(cands, m, size):
        """Smallest free room with cap >= size (cands sorted by cap asc) -> (r, True);
        else the biggest free smaller room -> (r, False); else (-1, False)."""
        if len(cands) == 0:
            return -1, False
        k0 = int(np.searchsorted(ri.cap[cands], size, side="left"))
        for k in range(k0, len(cands)):
            if not (room_busy.get(int(cands[k]), 0) & m):
                return int(cands[k]), True
        for k in range(k0 - 1, -1, -1):
            if not (room_busy.get(int(cands[k]), 0) & m):
                return int(cands[k]), False
        return -1, False

    sec_rows = []
    order = np.lexsort((np.arange(n_sections), -sizes))
    for s in order:
        p, cname, size = pattern[s], mix[cat[s]]["name"], int(sizes[s])
        cands_pref = pref.get(cname, np.array([], dtype=int))
        tries = [(p, slot_of[s])] + [(pp, j) for pp in (p, "TTh" if p == "MWF" else "MWF")
                                     for j in np.argsort(load[pp], kind="stable") if (pp, j) != (p, slot_of[s])]
        chosen = None
        best_partial = None
        for (pp, j) in tries:
            st = slots[pp][j]
            m = _mask(PATTERN_DAYS[pp], st, st + durs[pp])
            for cands in (cands_pref, seated_all):
                r, ok = pick_room(cands, m, size)
                if ok:
                    chosen = (pp, j, r, size)
                    break
                if r >= 0 and (best_partial is None or ri.cap[r] > best_partial[3]):
                    best_partial = (pp, j, r, int(ri.cap[r]))
            if chosen:
                break
        if chosen is None:
            if best_partial is not None:
                chosen = best_partial
                n_warn["shrunk"] += 1
            else:  # no free seated room anywhere: double-book the biggest preferred room
                big = cands_pref if len(cands_pref) else seated_all
                chosen = (p, slot_of[s], int(big[-1]), min(size, int(ri.cap[big[-1]])))
                n_warn["double_booked"] += 1
        pp, j, r, size = chosen
        if (pp, j) != (p, slot_of[s]):
            n_warn["moved_slot"] += 1
        st = slots[pp][j]
        m = _mask(PATTERN_DAYS[pp], st, st + durs[pp])
        room_busy[r] = room_busy.get(r, 0) | m
        sec_rows.append(dict(src=int(s), pattern=pp, course=course[s], kind=mix[cat[s]]["kind"], r=r,
                             days=pp, weekdays=list(PATTERN_DAYS[pp]), start_min=st, end_min=st + durs[pp],
                             cap=size, mask=m, lab_of=-1))
    sec_rows.sort(key=lambda d: d["src"])

    # --- lab sections for lab-department lectures
    lab_depts = set(scfg["lab_depts"])
    lab_rooms = pref.get("lab", ri.of_types(["lab"]))
    lab_combos = [(d, _hm(t)) for d in scfg["lab_days"] for t in scfg["lab_starts"]]
    lab_dur = int(scfg["lab_dur_min"])
    lab_size = int(scfg["lab_section_size"])
    n_lect = len(sec_rows)
    lab_draw = rng.random(n_lect)
    for li in range(n_lect):
        d = sec_rows[li]
        if _dept(d["course"]) not in lab_depts or d["cap"] < scfg["lab_min_size"] or lab_draw[li] >= scfg["lab_p"]:
            continue
        if len(lab_rooms) == 0:
            n_warn["lab_skipped"] += 1
            continue
        n_lab = math.ceil(d["cap"] / lab_size)
        for _ in range(n_lab):
            first = int(rng.integers(len(lab_combos)))
            placed = False
            for c in range(len(lab_combos)):
                dc, st = lab_combos[(first + c) % len(lab_combos)]
                m = _mask([DAY_CODES[dc]], st, st + lab_dur)
                r, ok = pick_room(lab_rooms, m, lab_size)
                if r < 0:
                    continue
                room_busy[r] = room_busy.get(r, 0) | m
                sec_rows.append(dict(src=len(sec_rows), pattern="LAB", course=d["course"], kind="lab", r=r, days=dc,
                                     weekdays=[DAY_CODES[dc]], start_min=st, end_min=st + lab_dur,
                                     cap=min(lab_size, int(ri.cap[r])), mask=m, lab_of=li))
                placed = True
                break
            if not placed:
                n_warn["lab_skipped"] += 1

    # --- enrollment
    S = len(sec_rows)
    rem = np.array([d["cap"] for d in sec_rows], dtype=float)
    masks = [d["mask"] for d in sec_rows]
    is_lect = np.array([d["lab_of"] < 0 for d in sec_rows])
    labs_of = [[] for _ in range(S)]
    for j, d in enumerate(sec_rows):
        if d["lab_of"] >= 0:
            labs_of[d["lab_of"]].append(j)
    course_names = sorted({d["course"] for d in sec_rows})
    course_code = {c: i for i, c in enumerate(course_names)}
    sec_course = np.array([course_code[d["course"]] for d in sec_rows], dtype=int)
    sec_dept = [_dept(d["course"]) for d in sec_rows]
    bias_cfg = scfg.get("archetype_dept_bias", {})
    bias = np.ones((len(codes.ARCHETYPES), S))
    for a, name in enumerate(codes.ARCHETYPES):
        for dept, f in bias_cfg.get(name, {}).items():
            bias[a, [j for j in range(S) if sec_dept[j] == dept]] = f
    bias[:, ~is_lect] = 0.0
    enrolled = [[] for _ in range(S)]
    schedule = [[] for _ in range(N)]
    arche = np.asarray(pop.archetype, dtype=int)
    max_att = int(scfg["max_pick_attempts"])
    for i in rng.permutation(N):
        i = int(i)
        amask = 0
        avail = bias[arche[i]] > 0
        got = 0
        for _ in range(max_att):
            if got >= k_target[i]:
                break
            w = rem * bias[arche[i]] * avail
            tot = w.sum()
            if tot <= 0:
                break
            j = int(np.searchsorted(np.cumsum(w), rng.random() * tot, side="right"))
            j = min(j, S - 1)
            avail[j] = False
            if amask & masks[j]:
                continue
            lab = -1
            if labs_of[j]:
                ok = [l for l in labs_of[j] if rem[l] > 0 and not ((amask | masks[j]) & masks[l])]
                if not ok:
                    continue
                lab = max(ok, key=lambda l: (rem[l], -l))
            avail &= sec_course != sec_course[j]
            for jj in (j, lab):
                if jj >= 0:
                    rem[jj] -= 1
                    amask |= masks[jj]
                    enrolled[jj].append(i)
                    schedule[i].append(jj)
            got += 1

    # --- final ordering / IDs (drop empty sections)
    keep = [j for j in range(S) if enrolled[j]]
    keep.sort(key=lambda j: (PATTERN_ORDER[sec_rows[j]["pattern"]], sec_rows[j]["weekdays"][0],
                             sec_rows[j]["start_min"], sec_rows[j]["course"], j))
    new_idx = {j: n for n, j in enumerate(keep)}
    ctr = {p: 0 for p in PATTERN_ORDER}
    rows = []
    for j in keep:
        d = sec_rows[j]
        ctr[d["pattern"]] += 1
        r = d["r"]
        rows.append(dict(section_id=f"SEC_{PATTERN_PREFIX[d['pattern']]}_{ctr[d['pattern']]:02d}", course=d["course"],
                         kind=d["kind"], r=r, room_id=ri.room_id[r], location_id=ri.loc_id[r], days=d["days"],
                         weekdays=list(d["weekdays"]), start_min=d["start_min"], end_min=d["end_min"],
                         enrolled=sorted(enrolled[j]), component="", room_name="", title=""))
    pop.class_schedule = [sorted(new_idx[j] for j in schedule[i]) for i in range(N)]
    df = pd.DataFrame(rows, columns=SEC_COLUMNS)
    df.attrs["warnings"] = n_warn
    df.attrs["agent_id"] = list(pop.agent_id)
    return df


# ----------------------------------------------------------------------------- real sections (ExploreCourses)
def _load_catalog(rcfg, run):
    """Meetings from the ExploreCourses snapshot that undergrads can take and that meet during the run."""
    df = pd.read_csv(ROOT / rcfg["catalog"], dtype=str, keep_default_na=False)
    df["num_enrolled"] = pd.to_numeric(df["num_enrolled"], errors="coerce").fillna(0).astype(int)
    t0 = pd.Timestamp(run.get("start_date", "2026-01-05"))
    t1 = t0 + pd.Timedelta(days=int(run["days"]))
    sd = pd.to_datetime(df["start_date"], format="%b %d, %Y", errors="coerce").fillna(t0)
    ed = pd.to_datetime(df["end_date"], format="%b %d, %Y", errors="coerce").fillna(t1)
    excl = set(rcfg.get("exclude_subjects", []))
    pre = tuple(rcfg.get("exclude_subject_prefixes", []))
    keep = ((sd < t1) & (ed >= t0) & ~df["subject"].isin(excl) & ~df["subject"].str.startswith(pre)
            & ~df["location"].isin(rcfg.get("skip_locations", [])) & (df["num_enrolled"] > 0))
    df = df[keep].drop_duplicates(["class_id", "days", "start", "end", "location"])
    # meetings with a room first, so a duplicate slot keeps the row that says where it is
    df = df.assign(_noloc=df["location"] == "").sort_values("_noloc", kind="stable").drop(columns="_noloc")
    return df.reset_index(drop=True)


def _level_band(code, bands):
    m = re.match(r"\d+", code)
    return int(np.searchsorted(bands, int(m.group()), side="right")) if m else 0


def _split_days(days):
    return [DAY_CODES[d] for d in re.findall(r"Th|Sa|Su|M|T|W|F", days)]


def _build_sections_real(cfg, campus, pop, rng):
    """Real sections: ExploreCourses meeting times and rooms, seats scaled to the simulated share of
    undergrads, course picks weighted by popularity, class year (course level) and major."""
    scfg = cfg["schedule"]["sections"]
    rcfg = scfg["explorecourses"]
    N = pop.N
    ri = _RoomIndex(campus)
    k_target = _n_courses(pop, scfg, rng)
    cat = _load_catalog(rcfg, cfg["run"])
    bands = list(rcfg["level_bands"])
    ug_share = np.asarray(rcfg["undergrad_share"], float)
    lab_comp = set(rcfg["lab_components"])
    not_primary = set(rcfg["not_primary"]) | lab_comp
    kind_of = rcfg["kind_by_component"]

    # --- rooms by name; unnamed or unmapped meetings go to a generic seated room
    rname = campus.rooms["room_name"].to_numpy().astype(str) if "room_name" in campus.rooms else np.full(ri.R, "")
    by_name = {n: r for r, n in enumerate(rname) if n}
    loc_room = {loc: by_name[loc] for loc in cat["location"].unique() if loc in by_name}
    excl = set(scfg["fallback_exclude_room_types"])
    seated = np.flatnonzero((ri.layout == "seated") & ~np.isin(ri.type, list(excl)) & (rname == ""))
    seated = seated[np.lexsort((seated, ri.cap[seated]))]
    room_busy = {}
    n_warn = {"fallback_room": 0, "no_room": 0, "unfilled_agents": 0}

    # --- courses -> primary groups (one class_id each, possibly several meetings) and lab groups
    cat["course"] = cat["subject"] + " " + cat["code"]
    cat["band"] = [_level_band(c, bands) for c in cat["code"]]
    groups = []  # dict(course, comp, class_id, meetings=[row idx], seats)
    course_prim, course_labs = {}, {}
    restrict = [(re.compile(q["courses"]), set(q["class_years"])) for q in rcfg.get("restricted", [])]
    for course, cdf in cat.groupby("course", sort=True):
        tot = cdf.groupby("component")["num_enrolled"].sum()
        prim = [c for c in tot.index if c not in not_primary]
        if not prim:
            continue
        pc = max(sorted(prim), key=lambda c: tot[c])
        band = int(cdf["band"].iloc[0])
        for comp, is_lab in ((pc, False),) + tuple((c, True) for c in sorted(set(cdf["component"]) & lab_comp)):
            gdf = cdf[cdf["component"] == comp]
            for cid, mdf in gdf.groupby("class_id", sort=True):
                groups.append(dict(course=course, comp=comp, class_id=cid, meetings=list(mdf.index), is_lab=is_lab,
                                   ug=int(mdf["num_enrolled"].max()) * ug_share[band], band=band,
                                   subject=cdf["subject"].iloc[0], title=cdf["title"].iloc[0]))
    # seats: real undergrad enrollment, scaled so primary seats = seat_slack x the courses agents want
    ug_prim = sum(gr["ug"] for gr in groups if not gr["is_lab"])
    scale = float(rcfg["seat_slack"]) * float(k_target.sum()) / max(ug_prim, 1e-9)
    kept = []
    for gr in groups:
        x = gr["ug"] * scale
        gr["seats"] = int(math.floor(x) + (rng.random() < x - math.floor(x)))
        if gr["seats"] > 0:
            kept.append(gr)
    groups = kept
    for g, gr in enumerate(groups):
        (course_labs if gr["is_lab"] else course_prim).setdefault(gr["course"], []).append(g)
    courses = sorted(course_prim)
    G = len(groups)

    # --- meetings -> sim sections (room, weekdays, minutes); one group's meetings share its enrollees
    sec_rows, g_secs, g_mask = [], [[] for _ in range(G)], np.zeros(G, dtype=object)
    for g, gr in enumerate(groups):
        m_all = 0
        for k, mi in enumerate(gr["meetings"]):
            row = cat.loc[mi]
            wds = _split_days(row["days"])
            st, en = _hm(row["start"]), _hm(row["end"])
            if not wds or en <= st:
                continue
            m = _mask(wds, st, en)
            if m & m_all:  # same class listed twice for one slot (overflow room, duplicate row)
                continue
            r = loc_room.get(row["location"], -1)
            if r < 0:
                k0 = int(np.searchsorted(ri.cap[seated], gr["seats"], side="left"))
                for kk in list(range(k0, len(seated))) + list(range(k0 - 1, -1, -1)):
                    if not (room_busy.get(int(seated[kk]), 0) & m):
                        r = int(seated[kk])
                        break
                n_warn["fallback_room" if r >= 0 else "no_room"] += 1
                if r < 0:
                    continue
            room_busy[r] = room_busy.get(r, 0) | m
            m_all |= m
            sid = re.sub(r"[^A-Za-z0-9&]", "", gr["course"]) + f"_{gr['comp']}{cat.at[mi, 'section'] or gr['class_id']}"
            g_secs[g].append(len(sec_rows))
            sec_rows.append(dict(sid=sid, k=k, course=gr["course"], kind=kind_of.get(gr["comp"], "lecture"), r=r,
                                 days=row["days"], weekdays=wds, start_min=st, end_min=en, component=gr["comp"],
                                 room_name=rname[r], title=gr["title"], g=g))
        g_mask[g] = m_all
    # a class never seats more than its smallest room holds
    rem = np.array([min(gr["seats"], min(int(ri.cap[sec_rows[j]["r"]]) for j in g_secs[g])) if g_secs[g] else 0
                    for g, gr in enumerate(groups)], float)

    # --- per-agent course weights: popularity x level fit x major
    C = len(courses)
    c_idx = {c: i for i, c in enumerate(courses)}
    c_band = np.array([groups[course_prim[c][0]]["band"] for c in courses])
    c_subj = [groups[course_prim[c][0]]["subject"] for c in courses]
    year = np.clip(np.asarray(pop.class_year, int), 1, 4)
    ylw = np.array([rcfg["year_level_weight"][str(y)] for y in range(1, 5)], float)  # (4, bands)
    mj = rcfg["majors"]
    mgroups = sorted(mj["groups"])
    in_major = np.array([[s in mj["groups"][m] for s in c_subj] for m in mgroups], bool)  # (M, C)
    mix = np.array([[mj["archetype_mix"][a].get(m, 0.0) for m in mgroups] for a in codes.ARCHETYPES], float)
    mix /= mix.sum(1, keepdims=True)
    arche = np.asarray(pop.archetype, dtype=int)
    major = np.array([int(np.searchsorted(np.cumsum(mix[a]), u, side="right")) for a, u in
                      zip(arche, rng.random(N))]).clip(0, len(mgroups) - 1)
    pop.major = [mgroups[m] for m in major]
    major_mult = np.asarray(mj["major_mult"], float)
    required = [(re.compile(q["courses"]), set(q["class_years"]), float(q["p"])) for q in rcfg.get("required", [])]
    req_courses = [np.array([bool(rx.match(c)) for c in courses]) for rx, _, _ in required]
    allowed = np.ones((5, C), bool)  # [class_year, course]
    for rx, yrs in restrict:
        hit = np.array([bool(rx.match(c)) for c in courses])
        for y in range(1, 5):
            if y not in yrs:
                allowed[y] &= ~hit

    c_groups = [course_prim[c] for c in courses]
    enrolled = [[] for _ in range(len(sec_rows))]
    schedule = [[] for _ in range(N)]
    max_att = int(scfg["max_pick_attempts"])

    def course_rem():
        return np.array([rem[gs].sum() for gs in c_groups])

    crem = course_rem()

    def take(i, ci, amask):
        """Enroll agent i in a free primary group of course ci (+ a lab group). -> new mask or None."""
        gs = [g for g in c_groups[ci] if rem[g] > 0 and not (amask & g_mask[g])]
        if not gs:
            return None
        w = rem[gs]
        g = gs[min(int(np.searchsorted(np.cumsum(w), rng.random() * w.sum(), side="right")), len(gs) - 1)]
        mask = amask | g_mask[g]
        pick = [g]
        labs = course_labs.get(courses[ci], [])
        if labs:
            ok = [l for l in labs if rem[l] > 0 and g_secs[l] and not (mask & g_mask[l])]
            if ok:
                l = max(ok, key=lambda l: (rem[l], -l))
                pick.append(l)
                mask |= g_mask[l]
        for gg in pick:
            rem[gg] -= 1
            crem[c_idx[groups[gg]["course"]]] = rem[c_groups[c_idx[groups[gg]["course"]]]].sum()
            for s in g_secs[gg]:
                enrolled[s].append(i)
                schedule[i].append(s)
        return mask

    for i in rng.permutation(N):
        i = int(i)
        amask, got = 0, 0
        taken = ~allowed[year[i]]
        for (rx, yrs, p), rc in zip(required, req_courses):
            if year[i] in yrs and rng.random() < p and got < k_target[i]:
                w = crem * rc * ~taken
                if w.sum() > 0:
                    ci = int(np.searchsorted(np.cumsum(w), rng.random() * w.sum(), side="right"))
                    ci = min(ci, C - 1)
                    m = take(i, ci, amask)
                    taken[ci] = True
                    if m is not None:
                        amask, got = m, got + 1
        wi = ylw[year[i] - 1][c_band] * np.where(in_major[major[i]], major_mult[year[i] - 1], 1.0)
        for _ in range(max_att):
            if got >= k_target[i]:
                break
            w = crem * wi * ~taken
            tot = w.sum()
            if tot <= 0:
                break
            ci = min(int(np.searchsorted(np.cumsum(w), rng.random() * tot, side="right")), C - 1)
            taken[ci] = True
            m = take(i, ci, amask)
            if m is not None:
                amask, got = m, got + 1
        if got < k_target[i]:
            n_warn["unfilled_agents"] += 1

    # --- final ordering / IDs (drop empty sections)
    keep = [j for j in range(len(sec_rows)) if enrolled[j]]
    keep.sort(key=lambda j: (sec_rows[j]["course"], sec_rows[j]["sid"], sec_rows[j]["k"], j))
    new_idx = {j: n for n, j in enumerate(keep)}
    seen, rows = {}, []
    for j in keep:
        d = sec_rows[j]
        base = d["sid"] if d["k"] == 0 and d["sid"] not in seen else f"{d['sid']}_{d['k'] + 1}"
        while base in seen:
            base += "x"
        seen[base] = True
        r = d["r"]
        rows.append(dict(section_id=base, course=d["course"], kind=d["kind"], r=r, room_id=ri.room_id[r],
                         location_id=ri.loc_id[r], days=d["days"], weekdays=list(d["weekdays"]),
                         start_min=d["start_min"], end_min=d["end_min"], enrolled=sorted(enrolled[j]),
                         component=d["component"], room_name=d["room_name"], title=d["title"]))
    pop.class_schedule = [sorted(new_idx[j] for j in schedule[i]) for i in range(N)]
    df = pd.DataFrame(rows, columns=SEC_COLUMNS)
    df.attrs["warnings"] = n_warn
    df.attrs["agent_id"] = list(pop.agent_id)
    return df


# ----------------------------------------------------------------------------- events
class _Busy:
    """Per-agent busy intervals (absolute minutes) incl. classes on the day."""

    def __init__(self, N, sections, start_weekday):
        self.ev = [[] for _ in range(N)]
        self.cls = [[[] for _ in range(7)] for _ in range(N)]
        self.sw = start_weekday
        for s, row in enumerate(sections.itertuples(index=False)):
            for wd in row.weekdays:
                for i in row.enrolled:
                    self.cls[i][wd].append((row.start_min, row.end_min))

    def free(self, i, s, e):
        for a, b in self.ev[i]:
            if a < e and s < b:
                return False
        d0 = s // 1440
        for d in range(d0, (e - 1) // 1440 + 1):
            wd = (self.sw + d) % 7
            for a, b in self.cls[i][wd]:
                if d * 1440 + a < e and s < d * 1440 + b:
                    return False
        return True

    def add(self, i, s, e):
        self.ev[i].append((s, e))


def build_events(cfg, campus, pop, sections, rng):
    """Generate all social events for the run (absolute minutes since sim start)."""
    ecfg = cfg["schedule"]["events"]
    run = cfg["run"]
    days, sw, step = int(run["days"]), int(run.get("start_weekday", 0)), int(run.get("step_min", 5))
    N = pop.N
    ri = _RoomIndex(campus)
    busy = _Busy(N, sections, sw)
    room_book = {}
    excl = set(ecfg.get("exclusive_room_types", []))
    events = []

    def q(m):
        return int(round(m / step) * step)

    def room_free(r, s, e):
        if ri.type[r] not in excl:
            return True
        return all(not (a < e and s < b) for a, b in room_book.get(r, []))

    def add_event(typ, name, r, s, e, att):
        att = sorted(int(i) for i in att)
        for i in att:
            busy.add(i, s, e)
        room_book.setdefault(int(r), []).append((s, e))
        events.append(dict(type=typ, name=name, r=int(r), day=s // 1440, start_min=s, end_min=e, attendees=att,
                           ctr=len(events)))

    fg = np.asarray(pop.friend_group, dtype=np.int64)
    groups = [np.flatnonzero(fg == g) for g in np.unique(fg[fg >= 0])]
    party_p = np.clip(_param(pop, "party_p", 0.2), 0, 1)
    event_p = np.clip(_param(pop, "event_p", 0.2), 0, 1)
    hang_rate = np.maximum(_param(pop, "hangout_rate", 0.2), 0)
    sg_rate = np.maximum(_param(pop, "study_group_rate", 0.2), 0)
    if getattr(pop, "social_scale", None) is not None:  # Big Five: extraverts go out more
        party_p = np.clip(party_p * pop.social_scale, 0, 1)
        event_p = np.clip(event_p * pop.social_scale, 0, 1)
        hang_rate = hang_rate * pop.social_scale

    def group_attend(prob, member_p, indiv_mult, s, e, cap, extra=()):
        """Friend-group correlated attendance; returns list of agent idx (capped)."""
        att = [int(i) for i in extra if busy.free(int(i), s, e)]
        taken = set(att)
        go_g = rng.random(len(groups))
        for gi in rng.permutation(len(groups)):
            mem = groups[gi]
            if go_g[gi] >= prob[mem].mean():
                continue
            draw = rng.random(len(mem))
            for i, u in zip(mem, draw):
                i = int(i)
                if u < member_p and i not in taken and busy.free(i, s, e):
                    att.append(i)
                    taken.add(i)
        u = rng.random(N)
        for i in np.flatnonzero(u < prob * indiv_mult):
            i = int(i)
            if i not in taken and busy.free(i, s, e):
                att.append(i)
                taken.add(i)
        return att[:cap]

    # --- sports games / large events
    teams = getattr(pop, "teams", []) or []
    team_id = np.asarray(getattr(pop, "team_id", np.full(N, -1)))
    for ev in ecfg.get("big_events", []):
        if ev["day"] >= days:
            continue
        b = campus.find_building(ev["venue"])
        if b is None or b < 0:
            continue
        rr = ri.in_building(b, ecfg["big_event_room_types"])
        if len(rr) == 0:
            rr = ri.in_building(b, set(ri.type))
        if len(rr) == 0:
            continue
        r = int(rr[np.lexsort((rr, -ri.cap[rr]))][0])
        s = q(ev["day"] * 1440 + ev["start_h"] * 60)
        e = q(s + ev["dur_h"] * 60)
        players = []
        sport = str(ev.get("sport", "")).lower()
        if sport:
            tsports = [str(tm.get("sport", "")).lower() for tm in teams]
            match = [t for t, ts in enumerate(tsports) if ts == sport] or \
                [t for t, ts in enumerate(tsports) if sport in ts]
            for t in match:
                players.extend(np.flatnonzero(team_id == t).tolist())
        cap = int(ri.cap[r] * ecfg["big_event_crowding"])
        prob = np.clip(event_p * ev.get("draw_mult", 1.0), 0, 1)
        att = group_attend(prob, ecfg["big_event_member_p"], ecfg["big_event_individual_mult"], s, e,
                           max(cap, len(players)), extra=players)
        if att:
            add_event(ev["type"], ev["name"], r, s, e, att)

    # --- parties
    pc = ecfg["party"]
    party_rooms = ri.of_types(pc["room_types"], pc["venue_types"])
    if len(party_rooms) == 0:  # fallback: biggest room of each party venue
        fb = []
        for b in np.flatnonzero(np.isin(ri.b_type, pc["venue_types"])):
            rr = ri.in_building(b, set(ri.type))
            if len(rr):
                fb.append(int(rr[np.lexsort((rr, -ri.cap[rr]))][0]))
        party_rooms = np.array(sorted(fb), dtype=int)
    n_party = max(1, int(round(N * pc["parties_per_1000"] / 1000)))
    for d in range(days):
        if (sw + d) % 7 not in pc["weekdays"] or len(party_rooms) == 0:
            continue
        n = min(n_party, len(party_rooms))
        rooms_n = np.sort(rng.choice(party_rooms, size=n, replace=False))
        starts = [q(d * 1440 + pc["start_h"] * 60 + rng.normal(0, pc["start_sd_min"])) for _ in range(n)]
        ends = [q(st + pc["dur_h"] * 60 + rng.normal(0, pc["dur_sd_min"])) for st in starts]
        caps = np.array([max(1, int(ri.cap[r] * pc["crowding"])) for r in rooms_n], dtype=float)
        att = [[] for _ in range(n)]
        taken = set()
        go_g = rng.random(len(groups))

        def place(members):
            remc = caps - np.array([len(a) for a in att])
            if remc.sum() <= 0:
                return
            k = int(rng.choice(n, p=np.maximum(remc, 0) / remc[remc > 0].sum()))
            for i in members:
                if len(att[k]) >= caps[k]:
                    break
                if i not in taken and busy.free(i, starts[k], ends[k]):
                    att[k].append(i)
                    taken.add(i)

        for gi in rng.permutation(len(groups)):
            mem = groups[gi]
            if go_g[gi] >= party_p[mem].mean():
                continue
            draw = rng.random(len(mem))
            place([int(i) for i, u in zip(mem, draw) if u < pc["member_p"]])
        u = rng.random(N)
        for i in np.flatnonzero(u < party_p * pc["individual_mult"]):
            place([int(i)])
        for k in range(n):
            if len(att[k]) >= pc["min_attendees"]:
                add_event("party", "Party", int(rooms_n[k]), starts[k], ends[k], att[k])

    # --- dorm hangouts
    hc = ecfg["dorm_hangout"]
    home_b = np.asarray(pop.home_b)
    home_room = np.asarray(pop.home_room)
    lounge_types = hc["lounge_room_types"]
    for d in range(days):
        wd = (sw + d) % 7
        mult = hc["weekend_mult"] if wd in hc["weekend_weekdays"] else 1.0
        u_g = rng.random(len(groups))
        for gi in range(len(groups)):
            mem = groups[gi]
            if len(mem) < hc["min_attendees"] or u_g[gi] >= min(1.0, hang_rate[mem].mean() * mult):
                continue
            s = q(d * 1440 + hc["start_h"] * 60 + rng.random() * hc["start_jitter_h"] * 60)
            dur = (hc["dur_h_min"] + rng.random() * (hc["dur_h_max"] - hc["dur_h_min"])) * 60
            e = q(min(s + dur, d * 1440 + hc["latest_end_h"] * 60))
            if e <= s:
                continue
            draw = rng.random(len(mem))
            att = [int(i) for i, x in zip(mem, draw) if x < hc["member_p"] and busy.free(int(i), s, e)]
            hosts = [i for i in att if home_b[i] >= 0]
            if len(att) < hc["min_attendees"] or not hosts:
                continue
            host = hosts[int(rng.integers(len(hosts)))]
            use_bed = rng.random() < hc["bedroom_p"]
            r = -1
            bed = int(home_room[host])
            if len(att) <= hc["bedroom_max"] and bed >= 0 and room_free(bed, s, e) and use_bed:
                r = bed
            else:
                lr = [x for x in ri.in_building(int(home_b[host]), lounge_types) if room_free(x, s, e)]
                if lr:
                    r = int(lr[int(rng.integers(len(lr)))])
                elif len(att) <= hc["bedroom_max"] and bed >= 0 and room_free(bed, s, e):
                    r = bed
            if r >= 0:
                add_event("dorm_hangout", "Dorm hangout", r, s, e, att)

    # --- study groups
    gc = ecfg["study_group"]
    exam_days = set(gc["exam_days"])
    boost_days = {e - k for e in exam_days for k in range(1, gc["exam_lead_days"] + 1)}
    lib_b = set(np.flatnonzero(ri.b_type == "library").tolist())
    sr_all = ri.of_types(gc["room_types"])
    sr_lib = np.array([r for r in sr_all if int(ri.b[r]) in lib_b], dtype=int)
    fb_all = ri.of_types(gc["fallback_room_types"])
    fav_lib = np.asarray(getattr(pop, "fav_library", np.full(N, -1)))
    fav_com = np.asarray(getattr(pop, "fav_common", np.full(N, -1)))
    sec_kind = sections["kind"].to_numpy()
    sec_enr = sections["enrolled"].tolist()
    sec_names = sections["course"].tolist()
    for d in range(days):
        wd = (sw + d) % 7
        if wd in gc["no_weekdays"]:
            continue
        mult = gc["exam_mult"] if d in boost_days else 1.0
        u_s = rng.random(len(sections))
        for s_i in range(len(sections)):
            if sec_kind[s_i] == "lab" and not gc["include_labs"]:
                continue
            enr = np.asarray(sec_enr[s_i], dtype=int)
            if len(enr) < gc["min_size"]:
                continue
            if u_s[s_i] >= min(1.0, gc["base_rate"] * sg_rate[enr].mean() * mult):
                continue
            lo_h, hi_h = gc["afternoon_window_h"] if rng.random() < gc["afternoon_p"] else gc["evening_window_h"]
            dur = (gc["dur_h_min"] + rng.random() * (gc["dur_h_max"] - gc["dur_h_min"])) * 60
            dur = min(dur, (hi_h - lo_h) * 60)
            s = q(d * 1440 + lo_h * 60 + rng.random() * ((hi_h - lo_h) * 60 - dur))
            e = q(s + dur)
            size = int(rng.integers(gc["min_size"], gc["max_size"] + 1))
            free = np.array([i for i in enr if busy.free(int(i), s, e)], dtype=int)
            if len(free) < gc["min_size"]:
                continue
            w = sg_rate[free] + 1e-9
            pick = rng.choice(free, size=min(size, len(free)), replace=False, p=w / w.sum())
            lead = int(pick[0])
            r = -1
            cand_lists = []
            if fav_lib[lead] >= 0:
                cand_lists.append(ri.in_building(int(fav_lib[lead]), gc["room_types"]))
            cand_lists += [sr_lib, sr_all]
            if fav_com[lead] >= 0:
                cand_lists.append(ri.in_building(int(fav_com[lead]), gc["fallback_room_types"]))
            cand_lists.append(fb_all)
            for cl in cand_lists:
                ok = [x for x in cl if room_free(int(x), s, e) and ri.cap[x] >= len(pick)]
                if ok:
                    r = int(ok[int(rng.integers(len(ok)))])
                    break
            if r >= 0:
                add_event("study_group", f"Study group: {sec_names[s_i]}", r, s, e, pick.tolist())

    events.sort(key=lambda ev: (ev["start_min"], EV_TYPE_ORDER.get(ev["type"], 9), ev["ctr"]))
    rows = []
    for k, ev in enumerate(events):
        r = ev["r"]
        rows.append(dict(event_id=f"EV{k:05d}", type=ev["type"], name=ev["name"], r=r, room_id=ri.room_id[r],
                         location_id=ri.loc_id[r], day=ev["day"], start_min=ev["start_min"], end_min=ev["end_min"],
                         attendees=ev["attendees"]))
    df = pd.DataFrame(rows, columns=EV_COLUMNS)
    df.attrs["start_date"] = str(run.get("start_date", "2026-01-05"))
    return df


# ----------------------------------------------------------------------------- CSV frames
def _ids(pop, idx):
    return "|".join(pop.agent_id[i] for i in idx)


def sections_frame_for_csv(sections, pop=None):
    """d2 schedule/sections.csv frame (+ appended kind, location_id, component, room_name, title)."""
    aid = list(pop.agent_id) if pop is not None else sections.attrs.get("agent_id")

    def ids(lst):
        return "|".join(aid[i] for i in lst) if aid is not None else "|".join(f"A{i:04d}" for i in lst)
    return pd.DataFrame({
        "section_id": sections["section_id"],
        "course": sections["course"],
        "room_id": sections["room_id"],
        "days": sections["days"],
        "start": [_fmt_hm(int(m)) for m in sections["start_min"]],
        "end": [_fmt_hm(int(m)) for m in sections["end_min"]],
        "enrolled_agent_ids": [ids(l) for l in sections["enrolled"]],
        "kind": sections["kind"],
        "location_id": sections["location_id"],
        "component": sections["component"],
        "room_name": sections["room_name"],
        "title": sections["title"],
    }).reset_index(drop=True)


def events_frame_for_csv(events, pop, start_date=None):
    """d2 schedule/events.csv frame (+ appended name). start_date defaults to the cfg["run"]["start_date"]
    recorded by build_events (events.attrs)."""
    start_date = start_date or events.attrs.get("start_date", "2026-01-05")
    t0 = datetime.fromisoformat(str(start_date))

    def iso(m):
        return (t0 + timedelta(minutes=int(m))).strftime("%Y-%m-%dT%H:%M:%S")
    cols = ["event_id", "type", "location_id", "room_id", "start", "end", "attendee_ids", "name"]
    if len(events) == 0:
        return pd.DataFrame(columns=cols)
    return pd.DataFrame({
        "event_id": events["event_id"],
        "type": events["type"],
        "location_id": events["location_id"],
        "room_id": events["room_id"],
        "start": [iso(m) for m in events["start_min"]],
        "end": [iso(m) for m in events["end_min"]],
        "attendee_ids": [_ids(pop, l) for l in events["attendees"]],
        "name": events["name"],
    }, columns=cols).reset_index(drop=True)
