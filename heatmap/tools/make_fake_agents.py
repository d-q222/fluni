"""Generate a placeholder agent timeline CSV until the synthetic-data workstream delivers the real one.

Agents follow a simple daily schedule between real Stanford buildings, and flu spreads between agents
sharing a room. Columns:
  t          ISO timestamp
  agent_id   e.g. a007
  lat, lon   a point inside the agent's room (rooms are fixed points inside the building outline)
  building, floor, room
  altruistic 1 if the agent self-reports and stays home when sick
  sick       ground truth (0/1): exposed or infectious. Only the simulation knows this.
  p_sick     what the app believes: self-reports plus exposure to people the app thinks are risky

Usage: python3 tools/make_fake_agents.py [--agents 250] [--days 2] [--seed 7]   (run from heatmap/)
"""
import argparse
import csv
import json
import math
import random
from datetime import datetime, timedelta

STEP_MIN = 15
DAY_START, DAY_END = 7, 23
P_ROOM = 0.012          # per-step infection chance from one infectious person in a small room
CROWD = 8              # in rooms larger than this, you're only near ~CROWD of the people
P_APP = 0.08           # app's per-step risk bump for sharing a room with someone who self-reported
INCUBATION_STEPS = 16  # 4 hours exposed before infectious (compressed for a 2-day demo)
REPORT_P = 0.95        # p_sick once someone self-reports
PRIOR = 0.02


def point_in_poly(lat, lon, poly):
    inside = False
    for (a_lat, a_lon), (b_lat, b_lon) in zip(poly, poly[1:] + poly[:1]):
        if (a_lat > lat) != (b_lat > lat) and lon < (b_lon - a_lon) * (lat - a_lat) / (b_lat - a_lat) + a_lon:
            inside = not inside
    return inside


def random_point(poly, rng):
    lats, lons = [p[0] for p in poly], [p[1] for p in poly]
    while True:
        lat, lon = rng.uniform(min(lats), max(lats)), rng.uniform(min(lons), max(lons))
        if point_in_poly(lat, lon, poly):
            return lat, lon


class Building:
    def __init__(self, b, rng, n_rooms, floors):
        self.name, self.kind, self.poly = b["name"], b["kind"], b["polygon"]
        self.rooms = []
        for i in range(n_rooms):
            floor = 1 + i % floors
            self.rooms.append((floor, f"{floor}{i // floors + 1:02d}", random_point(self.poly, rng)))


ROOMS = {"dorm": (60, 3), "class": (6, 3), "library": (3, 2), "dining": (2, 1),
         "social": (3, 2), "gym": (2, 1), "health": (2, 1)}


def schedule(agent, hour, rng):
    """(building, room_index) for this agent at this hour. Sick altruists stay home."""
    home = (agent["dorm"], agent["dorm_room"])
    if agent["state"] == "I" and agent["altruistic"]:
        return (agent["vaden_bldg"], 0) if hour == 10 and not agent["visited_vaden"] else home
    if hour < 8 or hour >= 22:
        return home
    if hour < 9:
        return (agent["dining"], 0) if agent["breakfast"] else home
    if hour < 12:
        return agent["classes"][0] if hour < 10.5 else agent["classes"][1]
    if hour < 13:
        return (agent["dining"], rng.randrange(2))
    if hour < 16:
        return agent["classes"][2]
    if hour < 17:
        return agent["afternoon"]
    if 19 <= hour < 20:
        return (agent["dining"], rng.randrange(2))
    return agent["evening"] if hour >= 20 else home


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agents", type=int, default=250)
    ap.add_argument("--days", type=int, default=2)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--initial-sick", type=int, default=6)
    ap.add_argument("--out", default="data/fake_agents.csv")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    raw = json.load(open("data/stanford_buildings.json"))["buildings"]
    blds = [Building(b, rng, *ROOMS[b["kind"]]) for b in raw]
    by_kind = {k: [b for b in blds if b.kind == k] for k in ROOMS}

    agents = []
    for i in range(args.agents):
        dorm = rng.choice(by_kind["dorm"])
        classes = [(rng.choice(by_kind["class"] + by_kind["library"]), rng.randrange(2)) for _ in range(3)]
        agents.append({
            "id": f"a{i:03d}", "dorm": dorm, "dorm_room": rng.randrange(len(dorm.rooms)),
            "classes": classes, "dining": by_kind["dining"][0], "vaden_bldg": by_kind["health"][0],
            "breakfast": rng.random() < 0.5,
            "afternoon": (rng.choice(by_kind["gym"]), 0) if rng.random() < 0.3 else (rng.choice(by_kind["social"]), rng.randrange(3)),
            "evening": (by_kind["library"][0], rng.randrange(3)) if rng.random() < 0.2 else None,
            "altruistic": rng.random() < 0.6,
            "state": "S", "steps_exposed": 0, "reported": False, "visited_vaden": False, "p": PRIOR,
        })
        if agents[-1]["evening"] is None:
            agents[-1]["evening"] = (dorm, agents[-1]["dorm_room"])
    for a in rng.sample(agents, args.initial_sick):
        a["state"] = "I"

    start = datetime(2026, 10, 19)  # a Monday
    rows = []
    for day in range(args.days):
        t = start + timedelta(days=day, hours=DAY_START)
        while t.hour < DAY_END:
            hour = t.hour + t.minute / 60
            where = {}
            for a in agents:
                b, r = schedule(a, hour, rng)
                if b.kind == "health":
                    a["visited_vaden"] = True
                where.setdefault((b.name, r), []).append(a)
                a["loc"] = (b, r)

            # Transmission (truth) and the app's belief update, both within a room. The app only
            # learns from self-reports, never from the hidden truth.
            for group in where.values():
                closeness = min(1.0, CROWD / len(group))
                infectious = sum(a["state"] == "I" for a in group)
                reported = sum(a["reported"] for a in group)
                for a in group:
                    if a["state"] == "S" and rng.random() < 1 - (1 - P_ROOM * closeness) ** infectious:
                        a["state"] = "E"
                    others_reported = reported - a["reported"]
                    if others_reported and not a["reported"]:
                        a["p"] = 1 - (1 - a["p"]) * (1 - P_APP * closeness) ** others_reported
            for a in agents:
                if a["state"] == "E":
                    a["steps_exposed"] += 1
                    if a["steps_exposed"] >= INCUBATION_STEPS:
                        a["state"] = "I"
                if a["state"] == "I" and a["altruistic"] and not a["reported"]:
                    a["reported"], a["p"] = True, REPORT_P

            for a in agents:
                b, r = a["loc"]
                floor, room, (lat, lon) = b.rooms[r]
                if a.get("spot_key") != (b.name, r):
                    # Pick a spot when the agent arrives and keep it while they stay. Crowded rooms
                    # spread wider (~1.5·√n m) but stay inside the building outline.
                    spread = 1.5 * math.sqrt(len(where[(b.name, r)])) / 111_000
                    for _ in range(20):
                        spot = (lat + rng.gauss(0, spread), lon + rng.gauss(0, spread) / math.cos(math.radians(lat)))
                        if point_in_poly(*spot, b.poly):
                            break
                    else:
                        spot = random_point(b.poly, rng)  # room overflows: anywhere in the building
                    a["spot_key"], a["spot"] = (b.name, r), spot
                rows.append([t.isoformat(timespec="minutes"), a["id"],
                             round(a["spot"][0], 6), round(a["spot"][1], 6),
                             b.name, floor, room, int(a["altruistic"]),
                             int(a["state"] in "EI"), round(a["p"], 4)])
            t += timedelta(minutes=STEP_MIN)

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t", "agent_id", "lat", "lon", "building", "floor", "room", "altruistic", "sick", "p_sick"])
        w.writerows(rows)
    sick_end = sum(a["state"] in "EI" for a in agents)
    print(f"wrote {len(rows)} rows, {args.agents} agents, sick at end: {sick_end}")


if __name__ == "__main__":
    main()
