"""Resolve ExploreCourses location strings to campus buildings and named rooms.

    python3 data/courses/build_rooms.py data/courses/20252026_winter.csv.gz

Writes data/courses/rooms_<snapshot>.csv: one row per real teaching room (location string, building
location_id, room name, floor, capacity) and prints how much enrollment it covers. Capacity is the
largest class the room holds this quarter: ExploreCourses has no room capacities, so 1.1 x the
biggest real enrollment (at most MAX_CAP) stands in for one. Locations that name no place we can map
("Departmental Room", "Remote", off-campus venues) are left out; the sim puts those sections in a
generic classroom.
"""
import csv
import gzip
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.dirname(os.path.dirname(HERE))

# (regex on the location string, building name in data/osm or data/manual_places). The first group,
# if any, is the room number. Order matters: the first match wins.
ALIASES = [
    (r"^(?:0?[1-9]|[1-9]\d|[1-3]\d\d|4[0-6]\d)-(\w+)$", "Main Quad"),  # numbered Quad buildings, e.g. 160-322
    (r"^5[0-5]\d-(\w+)$", "Peterson Laboratory"),                     # 500-550: Engineering corner
    (r"^NVIDIA Auditorium$", "Huang Engineering Center"),
    (r"^Huang Engineering Center\s*(\w+)$", "Huang Engineering Center"),
    (r"^Hewlett Teaching Center (?:Rm )?(\w+)$", "Hewlett Teaching Center"),
    (r"^Gates\s*(\w+)$", "Gates Computer Science"),
    (r"^CODA\s*(\w+)$", "Computing & Data Science"),
    (r"^(?:STLC|SAPP)\s*(\w+)$", "Sapp Center for Science Teaching and Learning"),
    (r"^Shriram\s*(\w+)$", "Shriram Center for Bioengineering & Chemical Engineering"),
    (r"^Y2E2\s*(\w+)$", "Yang & Yamazaki Environment & Energy Building"),
    (r"^Bishop Auditorium$", "Lathrop Library"),
    (r"^Lathrop\s*(\w+)$", "Lathrop Library"),
    (r"^Turing Auditorium$", "Polya Hall"),
    (r"^Thornton\s*(\w+)$", "Thornton Center"),
    (r"^Skilling Auditorium$", "Skilling Building"),
    (r"^Packrd\s*(\w+)$", "Packard"),
    (r"^Littlefield\s*(\w+)$", "Littlefield Center"),
    (r"^McCullough\s*(\w+)$", "McCullough"),
    (r"^Sequoia Hall\s*(\w+)$", "Sequoia Hall"),
    (r"^Econ\s*(\w+)$", "Landau Economics Building"),
    (r"^Encina West\s*(\w+)$", "Encina Hall West"),
    (r"^Encina Center\s*(\w+)$", "Encina Hall Center"),
    (r"^Green Earth Sciences\s*(\w+)$", "Green Earth Sciences Building"),
    (r"^Mitchell Earth Sciences\s*([\w/]+)$", "Mitchell Earth Sciences Building"),
    (r"^Knoll\s*(\w+)$", "The Knoll"),
    (r"^(?:LAW|William H. Neukom)\s*(\w+)$", "William H. Neukom Building"),
    (r"^Sweet\s*(\w+)$", "Sweet Hall"),
    (r"^EDWRDS\w*?(\d\w*)$", "Edwards Building"),
    (r"^Spilker\D*(\d\w*)$", "Spilker Engineering and Applied Sciences"),
    (r"^Cemex Auditorium$", "Lorenzo H. Zambrano Hall"),
    (r"^GSB Zambrano\s*(\w+)$", "Lorenzo H. Zambrano Hall"),
    (r"^GSB McClelland\s*(\w+)$", "W. Carter McClelland Building"),
    (r"^GSB Gunn\s*(\w+)$", "John A. & Cynthia Fry Gunn Building"),
    (r"^GSB Class of 1968\s*(\w+)$", "MBA Class of 1968 Building"),
    (r"^GSB Patterson\s*(\w+)$", "William J. Patterson Building"),
    (r"^GSB Faculty East\s*(\w+)$", "Faculty Building East"),
    (r"^GSB Faculty West\s*(\w+)$", "Faculty Building West"),
    (r"^GSB [\w-]+\s*(\w+)$", "Lorenzo H. Zambrano Hall"),   # other Knight Management Center rooms
    (r"^Alway Building, Room\s*(\w+)$", "Alway Building"),
    (r"^Li Ka Shing Center, room\s*(\w+)$", "Li Ka Shing Center"),
    (r"^Beckman Center\s*(\w+)$", "Beckman Center for Molecular and Genetic Medicine"),
    (r"^Gilbert Biological Science\s*(\w+)$", "Gilbert Hall"),
    (r"^McMurtry Art Building\s*(\w+)$", "McMurtry Art"),
    (r"^BARNUM\s*(\w+)$", "Barnum Center"),
    (r"^(?:Braun|Campbell Recital Hall)\s*(\w*)$", "Braun Music Center"),
    (r"^Braun Rehearsal Hall$", "Braun Music Center"),
    (r"^(?:Dinkelspiel Auditorium|DINKG\w*)$", "Dinkelspiel Memorial Music Auditorium"),
    (r"^Bing Concert Hall", "Bing Concert Hall"),
    (r"^Roble Gymnasium\s*(\w*)$", "Roble Gymnasium"),
    (r"^AOERC", "Arrillaga Outdoor Education and Recreation Center"),
    (r"^CUBB\w*\s*(\w*)$", "Cubberly Education Building"),
    (r"^Cubberley\s*(\w*)$", "Cubberly Education Building"),
    (r"^Old Union\s*(\w*)$", "Old Union"),
    (r"^Tresidder\s*(\w*)$", "Tresidder Memorial Union"),
    (r"^Clark(?: Center)?\s*(S?\d\w*)$", "James H. Clark Center"),
    (r"^Mudd\s*(\w+)$", "Mudd Hall"),
    (r"^Durand\s*(\w+)$", "Durand Building"),
    (r"^Green Library\s*(\w*)$", "Green Library"),
]
ALIASES = [(re.compile(p, re.I), b) for p, b in ALIASES]
MAX_CAP = 500  # big lectures overflow their room (many watch recordings); no Stanford room seats more
FLOOR_NUM = re.compile(r"^[A-Z]?(\d+)")


def buildings():
    """name -> location_id (first OSM feature wins, matching campus.py's ids)."""
    out = {}
    for f in json.load(open(os.path.join(SIM, "data/osm/buildings.geojson")))["features"]:
        p = f["properties"]
        if p.get("name") and p["name"] not in out:
            out[p["name"]] = "bld_" + p["id"].split("/")[1]
    for mp in json.load(open(os.path.join(SIM, "data/manual_places.json"))):
        slug = mp.get("slug") or re.sub(r"[^a-z0-9]+", "_", mp["name"].lower()).strip("_")
        out.setdefault(mp["name"], f"bld_m_{slug}")
    return out


def floor_of(room):
    """'322' -> 3, 'B40' / '002' -> 1 (basements and ground share floor 1), else 1."""
    if not room or room[0] in "Bb":
        return 1
    m = FLOOR_NUM.match(room)
    if not m or len(m.group(1)) < 3:
        return 1
    return max(1, int(m.group(1)) // 100)


def resolve(loc, names):
    for rx, bname in ALIASES:
        m = rx.match(loc)
        if m:
            return names.get(bname), bname, (m.group(1) if m.groups() else "") or ""
    return None, None, None


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "20252026_winter.csv.gz")
    names = buildings()
    rows = list(csv.DictReader(gzip.open(src, "rt", encoding="utf-8")))
    rooms, missing, tot, hit = {}, {}, 0, 0
    for r in rows:
        n = int(r["num_enrolled"] or 0)
        tot += n
        loc = r["location"]
        lid, bname, num = resolve(loc, names) if loc else (None, None, None)
        if not lid:
            missing[loc or "(none)"] = missing.get(loc or "(none)", 0) + n
            continue
        hit += n
        cap = min(MAX_CAP, max(8, round(1.1 * n)))
        rm = rooms.setdefault(loc, dict(location=loc, location_id=lid, building=bname, room_name=loc,
                                        floor=floor_of(num), capacity=0))
        rm["capacity"] = max(rm["capacity"], cap)
    if any(rx.match("") for rx, _ in ALIASES):
        raise SystemExit("an alias matches the empty string")
    base = os.path.basename(src).split(".")[0]
    out = os.path.join(HERE, f"rooms_{base}.csv")
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["location", "location_id", "building", "room_name", "floor", "capacity"],
                           lineterminator="\n")
        w.writeheader()
        w.writerows(sorted(rooms.values(), key=lambda d: (d["location_id"], d["location"])))
    print(f"{len(rooms)} rooms in {len({r['location_id'] for r in rooms.values()})} buildings -> {out}")
    print(f"enrollment covered: {hit}/{tot} = {hit / max(tot, 1):.1%}")
    print("top unmapped:", "; ".join(f"{k} ({v})" for k, v in sorted(missing.items(), key=lambda kv: -kv[1])[:25]))


if __name__ == "__main__":
    main()
