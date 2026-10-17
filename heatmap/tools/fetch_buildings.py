"""Fetch outlines of selected Stanford buildings from OpenStreetMap (ODbL) into data/stanford_buildings.json.

Usage: python3 tools/fetch_buildings.py   (run from heatmap/)
"""
import json
import urllib.parse
import urllib.request

OVERPASS = "https://overpass-api.de/api/interpreter"
BBOX = "37.4180,-122.1800,37.4340,-122.1580"  # south, west, north, east

# OSM name -> (short name, kind). Kinds drive the fake schedule in make_fake_agents.py.
BUILDINGS = {
    "Branner Hall": ("Branner", "dorm"),
    "Toyon Hall": ("Toyon", "dorm"),
    "Roble Hall": ("Roble", "dorm"),
    "Kimball Hall": ("Kimball", "dorm"),
    "Arrillaga Family Dining Commons": ("Arrillaga Dining", "dining"),
    "Gates Computer Science": ("Gates", "class"),
    "Huang Engineering Center": ("Huang", "class"),
    "Packard": ("Packard", "class"),
    "James H. Clark Center": ("Clark Center", "class"),
    "Encina Hall West": ("Encina West", "class"),
    "Lathrop Library": ("Lathrop Library", "library"),
    "Tresidder Memorial Union": ("Tresidder", "social"),
    "Old Union": ("Old Union", "social"),
    "Arrillaga Center for Sports and Recreation": ("ACSR Gym", "gym"),
    "Vaden Health Center": ("Vaden", "health"),
}


def main():
    query = f'[out:json][timeout:60];way["building"]["name"]({BBOX});out geom tags;'
    req = urllib.request.Request(
        OVERPASS,
        data=urllib.parse.urlencode({"data": query}).encode(),
        headers={"User-Agent": "fluni-hackathon/0.1", "Accept": "application/json"},
    )
    elements = json.load(urllib.request.urlopen(req, timeout=90))["elements"]

    out = []
    for e in elements:
        name = e["tags"].get("name")
        if name in BUILDINGS and name not in {b["osm_name"] for b in out}:
            short, kind = BUILDINGS[name]
            ring = [[round(p["lat"], 6), round(p["lon"], 6)] for p in e["geometry"]]
            out.append({"name": short, "osm_name": name, "kind": kind, "polygon": ring})

    missing = set(BUILDINGS) - {b["osm_name"] for b in out}
    if missing:
        print("not found in OSM:", ", ".join(sorted(missing)))
    with open("data/stanford_buildings.json", "w") as f:
        json.dump({"attribution": "© OpenStreetMap contributors (ODbL)", "buildings": out}, f, indent=1)
    print(f"wrote {len(out)} buildings")


if __name__ == "__main__":
    main()
