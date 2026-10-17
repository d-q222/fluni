"""Mock run folder in the exact output schema of simulation_prompt.txt section 7.

10 "boring" agents with near-identical days (dorm -> breakfast -> class -> lunch
-> library -> dinner -> dorm). Positions use real OSM buildings/entrances, but
travel is straight-line door-to-door (no routing graph) and rooms are simple
rectangles. One agent (A0003) gets an off-campus import so the disease /
self-report / test columns are populated. Stdlib only.

  python3 make_mock_run.py [--days 3] [--out runs/mock_boring10]
"""
import argparse, csv, gzip, io, json, math, os, random
from datetime import datetime, timedelta

OSM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "osm")
START = datetime(2026, 1, 5)  # a Monday 00:00
STEP_MIN = 5
LAT0, LON0 = 37.418, -122.182  # local x/y origin (bbox SW corner)
M_PER_DEG_LAT = 110540.0
M_PER_DEG_LON = 111320.0 * math.cos(math.radians(LAT0))

BUILDINGS = {  # key: (osm_id, location_type, ventilation_ach)
    "branner": ("way/232805657", "dorm", 2.0),
    "dining": ("way/333374283", "dining", 4.0),
    "hewlett": ("way/232841892", "lecture_hall", 5.0),
    "gates": ("way/232841885", "classroom", 4.0),
    "lathrop": ("way/232805685", "library", 3.0),
    "vaden": ("way/26250731", "health_center", 6.0),
}
# room key: (building, floor, room_type, w_m, h_m, capacity, ceiling_m)
ROOMS = {
    "branner_201": ("branner", 2, "dorm_double", 4.5, 4.0, 2, 3.0),
    "branner_202": ("branner", 2, "dorm_double", 4.5, 4.0, 2, 3.0),
    "branner_203": ("branner", 2, "dorm_double", 4.5, 4.0, 2, 3.0),
    "branner_204": ("branner", 2, "dorm_double", 4.5, 4.0, 2, 3.0),
    "branner_205": ("branner", 2, "dorm_double", 4.5, 4.0, 2, 3.0),
    "branner_lobby": ("branner", 1, "lobby", 10, 8, 40, 3.0),
    "dining_main": ("dining", 1, "dining_room", 30, 20, 400, 4.0),
    "hewlett_200": ("hewlett", 1, "lecture_hall", 20, 15, 300, 6.0),
    "gates_104": ("gates", 1, "seminar", 8, 6, 20, 3.0),
    "lathrop_read": ("lathrop", 2, "reading_room", 20, 12, 120, 3.0),
    "vaden_exam": ("vaden", 1, "exam_room", 4, 3, 3, 3.0),
}


def to_xy(lon, lat):
    return (lon - LON0) * M_PER_DEG_LON, (lat - LAT0) * M_PER_DEG_LAT


def to_lonlat(x, y):
    return LON0 + x / M_PER_DEG_LON, LAT0 + y / M_PER_DEG_LAT


def load_map():
    bfeat = {f["properties"]["id"]: f for f in json.load(open(f"{OSM}/buildings.geojson"))["features"]}
    efeat = json.load(open(f"{OSM}/entrances.geojson"))["features"]
    buildings, entrances = {}, {}
    for key, (osm_id, ltype, ach) in BUILDINGS.items():
        p = bfeat[osm_id]["properties"]
        floors = int(p["levels"]) if p.get("levels") else 2
        doors = [(i, f) for i, f in enumerate(efeat) if f["properties"]["building_id"] == osm_id]
        buildings[key] = dict(
            location_id=f"bld_{osm_id.split('/')[1]}", osm_id=osm_id, name=p["name"], type=ltype,
            lon=p["centroid"][0], lat=p["centroid"][1], floors=floors, area_m2=p["footprint_m2"],
            ventilation_ach=ach, doors=[f"ent_{i:04d}" for i, _ in doors],
            entrance_sources="|".join(sorted({f["properties"]["source"] for _, f in doors})))
        for i, f in doors:
            lon, lat = f["geometry"]["coordinates"]
            entrances[f"ent_{i:04d}"] = dict(entrance_id=f"ent_{i:04d}", building_id=buildings[key]["location_id"],
                                             lat=lat, lon=lon, source=f["properties"]["source"])
    rooms, offset = {}, {}
    for rkey, (bkey, floor, rtype, w, h, cap, ceil) in ROOMS.items():
        b = buildings[bkey]
        cx, cy = to_xy(b["lon"], b["lat"])
        ox = offset.get((bkey, floor), 0.0)  # lay rooms side by side from the centroid
        offset[(bkey, floor)] = ox + w + 1.0
        x0, y0 = cx - 10 + ox, cy - h / 2
        rooms[rkey] = dict(room_id=f"{b['location_id']}_f{floor}_{rkey.split('_')[1]}", location_id=b["location_id"],
                           building=bkey, floor=floor, room_type=rtype, capacity=cap, area_m2=w * h,
                           volume_m3=w * h * ceil, ventilation_ach=b["ventilation_ach"], x0=x0, y0=y0, w=w, h=h)
    for b in buildings.values():
        b["capacity"] = sum(r["capacity"] for r in rooms.values() if r["location_id"] == b["location_id"])
    return buildings, rooms, entrances


def make_agents(rng):
    agents = []
    for i in range(10):
        agents.append(dict(
            agent_id=f"A{i:04d}", archetype="homebody", class_year=2026 + i % 4, home_dorm="Branner Hall",
            home_room_id=f"branner_20{i // 2 + 1}", class_schedule="SEC_MWF_01|SEC_TTH_01",
            friend_group_id=f"FG{i // 5:02d}", team_id="", transport_mode="bike" if i in (2, 7) else "walk",
            mask_propensity=0.1, compliance=0.8, honesty=0.9, has_app=i < 6, shares_location=i < 3,
            sickness_behavior_profile="visit_vaden_then_isolate", wake_jitter=rng.randint(-6, 6)))
    return agents


def day_plan(agent, day, sick_day, rng):
    """List of (start_min, end_min, room_key, activity, section/event id) for one day."""
    j = agent["wake_jitter"] * 5
    home = agent["home_room_id"]
    if sick_day is not None and day >= sick_day:  # symptomatic: Vaden visit on first day, then isolate
        plan = [(0, 9 * 60, home, "sleep", "")]
        if day == sick_day:
            plan += [(9 * 60 + 30, 10 * 60 + 15, "vaden_exam", "health_visit", ""), (10 * 60 + 30, 1440, home, "isolate", "")]
        else:
            plan += [(9 * 60, 1440, home, "isolate", "")]
        return plan
    mwf = day % 7 in (0, 2, 4)
    cls = ("hewlett_200", "SEC_MWF_01") if mwf else ("gates_104", "SEC_TTH_01")
    return [
        (0, 7 * 60 + 30 + j, home, "sleep", ""),
        (8 * 60 + j, 8 * 60 + 35 + j, "dining_main", "eat", ""),
        (10 * 60, 10 * 60 + 50, cls[0], "class", cls[1]),
        (12 * 60 + rng.randint(0, 3) * 5, 12 * 60 + 45, "dining_main", "eat", ""),
        (13 * 60 + 15, 17 * 60, "lathrop_read", "study", ""),
        (18 * 60 + j, 18 * 60 + 45 + j, "dining_main", "eat", ""),
        (19 * 60 + 15, 1440, home, "relax", ""),
    ]


def seat(room, idx, n_in_room):
    """Plausible fixed position inside a room for this agent."""
    if room["room_type"] == "dorm_double":
        return room["x0"] + (1.0 if idx % 2 == 0 else room["w"] - 1.0), room["y0"] + room["h"] / 2
    spacing = {"lecture_hall": 1.0, "seminar": 1.2, "dining_room": 0.8, "reading_room": 2.5}.get(room["room_type"], 1.5)
    cols = max(1, int((room["w"] - 2) / spacing))
    return room["x0"] + 1 + (idx % cols) * spacing, room["y0"] + 1 + (idx // cols) * spacing


def disease_at(t_min, inf):
    """(state, days_since_infection, infectiousness, symptomatic, severity) for agent with infection record."""
    if inf is None or t_min < inf["t_inf"]:
        return "S", "", 0.0, False, 0.0
    d = (t_min - inf["t_inf"]) / 1440
    if t_min < inf["t_pre"]:
        return "E", round(d, 3), 0.0, False, 0.0
    peak = inf["t_sym"]
    vl = math.exp(-((t_min - peak) / (1.5 * 1440)) ** 2)  # viral-load curve peaking at symptom onset
    if t_min < inf["t_sym"]:
        return "I_pre", round(d, 3), round(vl, 4), False, 0.0
    if t_min < inf["t_rec"]:
        return "I_sym", round(d, 3), round(vl, 4), True, round(min(1.0, 0.4 + 0.3 * vl), 3)
    return "R", round(d, 3), 0.0, False, 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=3)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "runs", "mock_boring10"))
    args = ap.parse_args()
    rng = random.Random(args.seed)
    buildings, rooms, entrances = load_map()
    agents = make_agents(rng)
    n_steps = args.days * 1440 // STEP_MIN
    out = args.out
    os.makedirs(f"{out}/map", exist_ok=True)
    os.makedirs(f"{out}/schedule", exist_ok=True)
    os.makedirs(f"{out}/timeline_by_agent", exist_ok=True)

    # One off-campus import: A0003 infected Monday 09:00.
    infections_rec = {"A0003": dict(t_inf=9 * 60, t_pre=9 * 60 + 1440, t_sym=9 * 60 + 2 * 1440 - 60, t_rec=9 * 60 + 8 * 1440)}
    sick_day = {"A0003": infections_rec["A0003"]["t_sym"] // 1440}

    plans = {}
    for a in agents:
        segs = []
        for day in range(args.days):
            for s, e, rk, act, sid in day_plan(a, day, sick_day.get(a["agent_id"]), rng):
                segs.append((day * 1440 + s, day * 1440 + e, rk, act, sid))
        merged = []  # merge same-room segments across midnight
        for sg in segs:
            if merged and merged[-1][2:] == sg[2:] and merged[-1][1] == sg[0]:
                merged[-1] = (merged[-1][0], sg[1], sg[2], merged[-1][3], merged[-1][4])
            else:
                merged.append(sg)
        plans[a["agent_id"]] = merged

    seat_idx = {}  # (agent, room) -> stable seat index
    for rk in rooms:
        occupants = sorted({a["agent_id"] for a in agents for sg in plans[a["agent_id"]] if sg[2] == rk})
        for k, aid in enumerate(occupants):
            seat_idx[(aid, rk)] = k if rooms[rk]["room_type"] != "dorm_double" else int(aid[1:]) % 2

    def nearest_door(bkey, x, y):
        return min(buildings[bkey]["doors"], key=lambda d: math.dist((x, y), to_xy(entrances[d]["lon"], entrances[d]["lat"])))

    tl_cols = ["t", "timestamp", "agent_id", "lat", "lon", "x_local_m", "y_local_m", "floor", "location_id",
               "location_type", "room_id", "room_type", "entrance_id", "indoor", "off_map", "activity", "event_id",
               "moving", "transport_mode", "disease_state", "days_since_infection", "infectiousness", "symptomatic",
               "symptom_severity", "masked", "self_reported_status", "test_status", "isolating", "intervention_action"]
    timeline, reports = [], []
    status = {a["agent_id"]: ("none", "none") for a in agents}
    events_by_t = {}  # t -> list of (agent, field, value)
    t_sym = infections_rec["A0003"]["t_sym"]
    vaden_t = sick_day["A0003"] * 1440 + 9 * 60 + 30
    for t_min, aid, f, v in [(t_sym + 60, "A0003", "self", "might_be_sick"), (vaden_t, "A0003", "test", "pending"),
                             (vaden_t + 240, "A0003", "test", "positive"), (vaden_t + 250, "A0003", "self", "tested_positive")]:
        events_by_t.setdefault(t_min // STEP_MIN, []).append((aid, f, v))
        if t_min // STEP_MIN < n_steps:
            if f == "self":
                reports.append(dict(t=t_min // STEP_MIN, agent_id=aid, event="self_report", value=v, target_agent_id="", truthful=True))
            else:
                reports.append(dict(t=t_min // STEP_MIN, agent_id=aid, event="test_taken" if v == "pending" else "test_result",
                                    value=v, target_agent_id="", truthful=""))
    if (t_sym + 120) // STEP_MIN < n_steps:  # roommate flags A0003 as possibly sick
        reports.append(dict(t=(t_sym + 120) // STEP_MIN, agent_id="A0002", event="report_other", value="might_be_sick",
                            target_agent_id="A0003", truthful=True))

    for a in agents:
        aid, plan = a["agent_id"], plans[a["agent_id"]]
        speed = 4.5 if a["transport_mode"] == "bike" else 1.3
        selfrep, test = "none", "none"
        prev_room = None
        for t in range(n_steps):
            m = t * STEP_MIN
            for (eid, f, v) in events_by_t.get(t, []):
                if eid == aid:
                    selfrep, test = (v, test) if f == "self" else (selfrep, v)
            i = next((k for k, sg in enumerate(plan) if sg[0] <= m < sg[1]), None)
            entrance_id, moving = "", False
            if i is None:  # in transit between plan[k-1] and plan[k]
                k = next(k for k, sg in enumerate(plan) if sg[0] > m)
                r_from, r_to = rooms[plan[k - 1][2]], rooms[plan[k][2]]
                fx, fy = seat(r_from, seat_idx[(aid, plan[k - 1][2])], 0)
                tx, ty = seat(r_to, seat_idx[(aid, plan[k][2])], 0)
                d_out = nearest_door(r_from["building"], tx, ty)
                d_in = nearest_door(r_to["building"], fx, fy)
                p0 = to_xy(entrances[d_out]["lon"], entrances[d_out]["lat"])
                p1 = to_xy(entrances[d_in]["lon"], entrances[d_in]["lat"])
                travel_min = math.dist(p0, p1) / speed / 60
                depart = max(plan[k - 1][1], plan[k][0] - math.ceil(travel_min / STEP_MIN) * STEP_MIN)  # leave just in time
                el = m - depart
                if el < 0:  # not yet left: linger where the previous block was
                    i, activity = k - 1, "idle"
                elif r_from["building"] != r_to["building"] and el < travel_min:
                    frac = el / travel_min
                    x, y = p0[0] + frac * (p1[0] - p0[0]), p0[1] + frac * (p1[1] - p0[1])
                    lon, lat = to_lonlat(x, y)
                    row = dict(x_local_m=x, y_local_m=y, lat=lat, lon=lon, floor="", location_id="", location_type="outdoor",
                               room_id="", room_type="", indoor=False, activity="commute", event_id="", moving=True)
                    if el == 0:
                        row["entrance_id"] = d_out  # exit step: agent is at the door
                    prev_room = None
                    timeline.append((a, t, row, m, selfrep, test))
                    continue
                else:
                    i, activity = k, "arrived_early"
            else:
                activity = plan[i][3]
            s, e, rk, act, sid = plan[i]
            r = rooms[rk]
            x, y = seat(r, seat_idx[(aid, rk)], 0)
            lon, lat = to_lonlat(x, y)
            b = buildings[r["building"]]
            if prev_room is None and t > 0:
                entrance_id = nearest_door(r["building"], x, y)  # enter step
            prev_room = rk
            row = dict(x_local_m=x, y_local_m=y, lat=lat, lon=lon, floor=r["floor"], location_id=b["location_id"],
                       location_type=b["type"], room_id=r["room_id"], room_type=r["room_type"], indoor=True,
                       activity=activity, event_id=sid, moving=moving, entrance_id=entrance_id)
            timeline.append((a, t, row, m, selfrep, test))

    rows = []
    for a, t, row, m, selfrep, test in timeline:
        st, dsi, inf, sym, sev = disease_at(m, infections_rec.get(a["agent_id"]))
        rows.append(dict(t=t, timestamp=(START + timedelta(minutes=m)).isoformat(), agent_id=a["agent_id"],
                         lat=round(row["lat"], 7), lon=round(row["lon"], 7), x_local_m=round(row["x_local_m"], 2),
                         y_local_m=round(row["y_local_m"], 2), floor=row["floor"], location_id=row["location_id"],
                         location_type=row["location_type"], room_id=row["room_id"], room_type=row["room_type"],
                         entrance_id=row.get("entrance_id", ""), indoor=row["indoor"], off_map=False,
                         activity=row["activity"], event_id=row["event_id"], moving=row["moving"],
                         transport_mode=a["transport_mode"], disease_state=st, days_since_infection=dsi,
                         infectiousness=inf, symptomatic=sym, symptom_severity=sev, masked=False,
                         self_reported_status=selfrep, test_status=test, isolating=row["activity"] == "isolate",
                         intervention_action=""))
    rows.sort(key=lambda r: (r["t"], r["agent_id"]))

    # contacts + room exposure
    by_t = {}
    for r in rows:
        by_t.setdefault(r["t"], []).append(r)
    contacts, exposure, conc = [], [], {}
    room_meta = {r["room_id"]: r for r in rooms.values()}
    for t in range(n_steps):
        cur = by_t.get(t, [])
        for i in range(len(cur)):
            for j in range(i + 1, len(cur)):
                a, b = cur[i], cur[j]
                d = math.dist((a["x_local_m"], a["y_local_m"]), (b["x_local_m"], b["y_local_m"]))
                same_room = a["room_id"] and a["room_id"] == b["room_id"]
                if d < 5 or same_room:
                    tier = 1 if d < 1 else 2 if d < 2 else 3 if d < 5 else 4
                    contacts.append(dict(t=t, agent_a=a["agent_id"], agent_b=b["agent_id"], distance_m=round(d, 2),
                                         distance_tier=tier, duration_s=STEP_MIN * 60,
                                         location_id=a["location_id"] if a["location_id"] == b["location_id"] else "",
                                         room_id=a["room_id"] if same_room else "", indoor=a["indoor"] and b["indoor"]))
        occ = {}
        for r in cur:
            if r["room_id"]:
                occ.setdefault(r["room_id"], []).append(r)
        for rid, meta in room_meta.items():  # well-mixed box: dC/dt = q*I/V - ach*C
            people = occ.get(rid, [])
            q = 25.0 * sum(p["infectiousness"] for p in people)  # quanta/h
            k = meta["ventilation_ach"]
            c_prev = conc.get(rid, 0.0)
            c_ss = q / (k * meta["volume_m3"])
            c = c_ss + (c_prev - c_ss) * math.exp(-k * STEP_MIN / 60)
            conc[rid] = c
            if people or c > 1e-6:
                exposure.append(dict(t=t, room_id=rid, occupants=len(people),
                                     infectious_occupants=sum(p["disease_state"] in ("I_pre", "I_sym", "I_asym") for p in people),
                                     quanta_concentration=round(c, 6)))

    def write(path, recs, cols, gz=False):
        # mtime=0 keeps .gz output byte-identical across runs
        op = (lambda p: io.TextIOWrapper(gzip.GzipFile(p, "wb", mtime=0), newline="")) if gz else (lambda p: open(p, "w", newline=""))
        with op(path) as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(recs)

    write(f"{out}/timeline.csv.gz", rows, tl_cols, gz=True)
    for a in agents:
        write(f"{out}/timeline_by_agent/{a['agent_id']}.csv", [r for r in rows if r["agent_id"] == a["agent_id"]], tl_cols)
    write(f"{out}/contacts.csv.gz", contacts, ["t", "agent_a", "agent_b", "distance_m", "distance_tier", "duration_s",
                                                "location_id", "room_id", "indoor"], gz=True)
    write(f"{out}/room_exposure.csv.gz", exposure, ["t", "room_id", "occupants", "infectious_occupants", "quanta_concentration"], gz=True)
    write(f"{out}/infections.csv", [dict(t=infections_rec["A0003"]["t_inf"] // STEP_MIN, infectee_id="A0003", infector_id="IMPORT",
                                         route="import", location_id="", room_id="", infector_contribution=1.0)],
          ["t", "infectee_id", "infector_id", "route", "location_id", "room_id", "infector_contribution"])
    reports.sort(key=lambda r: (r["t"], r["agent_id"]))
    write(f"{out}/reports_tests.csv", reports, ["t", "agent_id", "event", "value", "target_agent_id", "truthful"])
    static_cols = ["agent_id", "archetype", "class_year", "home_dorm", "home_room_id", "class_schedule", "friend_group_id",
                   "team_id", "transport_mode", "mask_propensity", "compliance", "honesty", "has_app", "shares_location",
                   "sickness_behavior_profile"]
    write(f"{out}/agents_static.csv", [{**{k: a[k] for k in static_cols}, "home_room_id": rooms[a["home_room_id"]]["room_id"]}
                                       for a in agents], static_cols)

    write(f"{out}/map/buildings.csv", [{k: b[k] for k in ["location_id", "osm_id", "name", "type", "lat", "lon", "floors", "area_m2",
                                                          "capacity", "ventilation_ach"]} | {"indoor": True, "entrance_sources": b["entrance_sources"]}
                                       for b in buildings.values()],
          ["location_id", "osm_id", "name", "type", "lat", "lon", "floors", "area_m2", "capacity", "ventilation_ach", "indoor", "entrance_sources"])
    write(f"{out}/map/entrances.csv", list(entrances.values()), ["entrance_id", "building_id", "lat", "lon", "source"])
    room_rows, feats = [], []
    for r in rooms.values():
        ring = [to_lonlat(r["x0"] + dx, r["y0"] + dy) for dx, dy in [(0, 0), (r["w"], 0), (r["w"], r["h"]), (0, r["h"]), (0, 0)]]
        ring = [[round(lo, 7), round(la, 7)] for lo, la in ring]
        props = {k: r[k] for k in ["room_id", "location_id", "floor", "room_type", "capacity", "area_m2", "volume_m3", "ventilation_ach"]}
        room_rows.append(props | {"source": "procedural", "polygon_wkt": "POLYGON((" + ", ".join(f"{lo} {la}" for lo, la in ring) + "))"})
        feats.append({"type": "Feature", "properties": props | {"source": "procedural"}, "geometry": {"type": "Polygon", "coordinates": [ring]}})
    write(f"{out}/map/rooms.csv", room_rows, list(room_rows[0].keys()))
    json.dump({"type": "FeatureCollection", "features": feats}, open(f"{out}/map/rooms.geojson", "w"), indent=1)

    sec_rows = [dict(section_id="SEC_MWF_01", course="CS 106A", room_id=rooms["hewlett_200"]["room_id"], days="MWF", start="10:00", end="10:50",
                     enrolled_agent_ids="|".join(a["agent_id"] for a in agents)),
                dict(section_id="SEC_TTH_01", course="PWR 1", room_id=rooms["gates_104"]["room_id"], days="TTh", start="10:00", end="10:50",
                     enrolled_agent_ids="|".join(a["agent_id"] for a in agents))]
    write(f"{out}/schedule/sections.csv", sec_rows, list(sec_rows[0].keys()))
    write(f"{out}/schedule/events.csv", [], ["event_id", "type", "location_id", "room_id", "start", "end", "attendee_ids"])

    json.dump(dict(run_id=os.path.basename(out), mock=True, seed=args.seed, n_agents=len(agents), days=args.days, step_min=STEP_MIN,
                   start=START.isoformat(), disease="influenza", intervention="none",
                   archetype_fractions={"homebody": 1.0}, map_version="stanford_osm (local extract)", code_version="mock-0.1",
                   local_frame={"origin_lat": LAT0, "origin_lon": LON0, "units": "m", "x": "east", "y": "north"},
                   distance_tiers={"1": "<1 m", "2": "1-2 m", "3": "2-5 m", "4": "same room, >=5 m"}),
              open(f"{out}/config.json", "w"), indent=2)
    daily = [0] * args.days
    daily[0] = 1
    json.dump(dict(mock=True, attack_rate=0.1, peak_day=0, measured_R=0.0, daily_incidence=daily,
                   infections_by_location_type={}, infections_by_archetype={"homebody": 1},
                   infections_by_route={"import": 1}, n_imports=1), open(f"{out}/summary.json", "w"), indent=2)
    print(f"wrote {out}: {len(rows)} timeline rows, {len(contacts)} contacts, {len(exposure)} room_exposure rows")


if __name__ == "__main__":
    main()
