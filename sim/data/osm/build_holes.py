"""Inner rings (courtyards) of the multipolygon buildings in buildings.geojson -> building_holes.geojson.

    python build_holes.py

build.py keeps only outer rings, so e.g. the Main Quad's courtyards read as solid building. The sim's
router uses these holes as open ground (campus.Campus._grid_build). One OSM API call per relation.
"""
import json, os, time, urllib.request

here = os.path.dirname(os.path.abspath(__file__))
API = "https://api.openstreetmap.org/api/0.6/relation/%s/full.json"


def rings(way_ids, ways, nodes):
    """Join member ways (node id lists) into closed rings of [lon, lat]."""
    segs = [list(ways[w]) for w in way_ids]
    out = []
    while segs:
        r = segs.pop(0)
        while r[0] != r[-1]:
            for k, s in enumerate(segs):
                if s[0] == r[-1]: r += s[1:]
                elif s[-1] == r[-1]: r += s[::-1][1:]
                elif s[-1] == r[0]: r = s[:-1] + r
                elif s[0] == r[0]: r = s[::-1][:-1] + r
                else: continue
                segs.pop(k)
                break
            else:
                break  # unclosable fragment: drop
        if r[0] == r[-1] and len(r) >= 4:
            out.append([nodes[n] for n in r])
    return out


feats = []
bld = json.load(open(os.path.join(here, "buildings.geojson")))["features"]
for f in bld:
    bid = f["properties"]["id"]
    if not bid.startswith("relation/"):
        continue
    req = urllib.request.Request(API % bid.split("/")[1], headers={"User-Agent": "fluni-sim/1.0"})
    els = json.load(urllib.request.urlopen(req, timeout=60))["elements"]
    nodes = {e["id"]: [e["lon"], e["lat"]] for e in els if e["type"] == "node"}
    ways = {e["id"]: e["nodes"] for e in els if e["type"] == "way"}
    rel = next(e for e in els if e["type"] == "relation")
    inner = [m["ref"] for m in rel["members"] if m["type"] == "way" and m["role"] == "inner" and m["ref"] in ways]
    holes = rings(inner, ways, nodes)
    if holes:
        feats.append({"type": "Feature", "properties": {"building_id": bid, "name": f["properties"].get("name")},
                      "geometry": {"type": "MultiPolygon", "coordinates": [[h] for h in holes]}})
    time.sleep(0.5)
json.dump({"type": "FeatureCollection", "features": feats}, open(os.path.join(here, "building_holes.geojson"), "w"))
print(f"buildings with holes {len(feats)}, holes {sum(len(f['geometry']['coordinates']) for f in feats)}")
