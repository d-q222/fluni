"""Overpass highway ways -> paths.geojson for the sim (walk + bike network).

    python build_paths.py --fetch            # query Overpass, write ways.json + paths.geojson here
    python build_paths.py ways.json          # rebuild paths.geojson from a saved Overpass response

Keeps every highway way in BBOX with the tags the router reads (foot/bicycle access, sidewalks,
covered/tunnel/indoor passages, layer). buildings.geojson and entrances.geojson come from build.py.
"""
import json, os, sys, urllib.parse, urllib.request

BBOX = (37.4170, -122.1850, 37.4395, -122.1515)  # S, W, N, E
QUERY = '[out:json][timeout:120];way["highway"](%s,%s,%s,%s);out tags geom;' % BBOX
URL = "https://overpass-api.de/api/interpreter"
KEEP_TAGS = ["foot", "bicycle", "access", "sidewalk", "sidewalk:both", "footway", "service", "covered",
             "tunnel", "indoor", "layer", "area", "segregated", "oneway", "oneway:bicycle"]

here = os.path.dirname(os.path.abspath(__file__))
if sys.argv[1:] == ["--fetch"]:
    req = urllib.request.Request(URL, data=urllib.parse.urlencode({"data": QUERY}).encode(),
                                 headers={"User-Agent": "fluni-sim/1.0"})
    raw = urllib.request.urlopen(req, timeout=180).read()
    src = os.path.join(here, "ways.json")
    open(src, "wb").write(raw)
else:
    src = sys.argv[1]

els = sorted((e for e in json.load(open(src))["elements"] if e["type"] == "way" and "geometry" in e),
             key=lambda e: e["id"])
feats = []
for e in els:
    t = e["tags"]
    props = {"id": f'way/{e["id"]}', "highway": t["highway"], "name": t.get("name")}
    props.update({k: t[k] for k in KEEP_TAGS if k in t})
    feats.append({"type": "Feature", "properties": props, "geometry": {
        "type": "LineString", "coordinates": [[g["lon"], g["lat"]] for g in e["geometry"]]}})
json.dump({"type": "FeatureCollection", "features": feats}, open(os.path.join(here, "paths.geojson"), "w"))
print(f"paths {len(feats)}")
