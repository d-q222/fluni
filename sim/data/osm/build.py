"""Convert Overpass raw.json -> buildings/entrances/paths GeoJSON for the sim.

Buildings without a tagged OSM entrance get estimated entrances: the points on
their outline closest to nearby footpath vertices (within MAX_DIST_M).
"""
import json, math, sys, os

src = sys.argv[1]
out = os.path.dirname(os.path.abspath(src))
MAX_DIST_M = 12
LAT0 = 37.4275
KX = 111320 * math.cos(math.radians(LAT0))  # meters per degree lon
KY = 110540                                   # meters per degree lat

def xy(lon, lat): return ((lon + 122.17) * KX, (lat - LAT0) * KY)
def ll(x, y): return (round(x / KX - 122.17, 7), round(y / KY + LAT0, 7))

def closest_on_seg(p, a, b):
    ax, ay = a; bx, by = b; px, py = p
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L))
    q = (ax + t * dx, ay + t * dy)
    return q, math.hypot(px - q[0], py - q[1])

def ring_area_centroid(ring):
    a = cx = cy = 0
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        c = x1 * y2 - x2 * y1
        a += c; cx += (x1 + x2) * c; cy += (y1 + y2) * c
    if a == 0: return 0, ring[0]
    return abs(a) / 2, (cx / (3 * a), cy / (3 * a))

def inside(p, ring):
    x, y = p; c = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1: c = not c
    return c

els = json.load(open(src))["elements"]
buildings, entr_nodes, paths = [], [], []
for e in els:
    t = e.get("tags", {})
    if e["type"] == "node" and "entrance" in t:
        entr_nodes.append(e)
    elif e["type"] == "way" and "highway" in t and "geometry" in e:
        paths.append(e)
    elif "building" in t:
        if e["type"] == "way" and "geometry" in e:
            rings = [[(g["lon"], g["lat"]) for g in e["geometry"]]]
        elif e["type"] == "relation":
            rings = [[(g["lon"], g["lat"]) for g in m["geometry"]]
                     for m in e.get("members", []) if m.get("role") == "outer" and "geometry" in m]
        else:
            continue
        rings = [r if r[0] == r[-1] else r + [r[0]] for r in rings if len(r) >= 3]
        if rings: buildings.append((e, rings))

# Grid index of footpath vertices (pedestrian-ish ways only)
PED = {"footway", "path", "pedestrian", "steps", "cycleway"}
grid = {}
for p in paths:
    if p["tags"]["highway"] not in PED: continue
    for g in p["geometry"]:
        x, y = xy(g["lon"], g["lat"])
        grid.setdefault((int(x // 25), int(y // 25)), []).append((x, y))

b_feats, e_feats = [], []
ALLV = []
for e, rings in buildings:
    t = e["tags"]
    bid = f'{e["type"]}/{e["id"]}'
    xrings = [[xy(*p) for p in r] for r in rings]
    main = max(xrings, key=lambda r: ring_area_centroid(r)[0])
    area, (cx, cy) = ring_area_centroid(main)
    ents = []
    # tagged entrances: OSM entrance nodes are vertices on the building outline
    for n in entr_nodes:
        p = xy(n["lon"], n["lat"])
        if min(closest_on_seg(p, a, b)[1] for r in xrings for a, b in zip(r, r[1:])) < 1.0:
            ents.append({"lon": n["lon"], "lat": n["lat"], "source": "osm",
                         "kind": n["tags"].get("entrance"), "osm_id": n["id"]})
    if not ents:
        cands = []
        xs = [x for x, _ in main]; ys = [y for _, y in main]
        for gx in range(int((min(xs) - MAX_DIST_M) // 25), int((max(xs) + MAX_DIST_M) // 25) + 1):
            for gy in range(int((min(ys) - MAX_DIST_M) // 25), int((max(ys) + MAX_DIST_M) // 25) + 1):
                for v in grid.get((gx, gy), []):
                    if inside(v, main): continue
                    q, d = min((closest_on_seg(v, a, b) for a, b in zip(main, main[1:])), key=lambda s: s[1])
                    if d <= MAX_DIST_M: cands.append((d, q))
        cands.sort()
        picked = []
        for d, q in cands:  # keep up to 4 estimated doors, at least 15 m apart
            if all(math.hypot(q[0] - r[0], q[1] - r[1]) > 15 for r in picked):
                picked.append(q)
            if len(picked) == 4: break
        if not picked:  # fallback: outline point facing the nearest path/road vertex
            allv = [xy(g["lon"], g["lat"]) for p in paths for g in p["geometry"]] if not ALLV else ALLV
            ALLV[:] = allv
            v = min(allv, key=lambda v: math.hypot(v[0] - cx, v[1] - cy))
            picked = [min((closest_on_seg(v, a, b) for a, b in zip(main, main[1:])), key=lambda s: s[1])[0]]
        for q in picked:
            lon, lat = ll(*q)
            ents.append({"lon": lon, "lat": lat, "source": "estimated" if len(cands) else "fallback"})
    for i, en in enumerate(ents):
        e_feats.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [en["lon"], en["lat"]]},
                        "properties": {"building_id": bid, "building_name": t.get("name"), "entrance_index": i,
                                       **{k: v for k, v in en.items() if k not in ("lon", "lat")}}})
    clon, clat = ll(cx, cy)
    geom = ({"type": "Polygon", "coordinates": [[list(p) for p in rings[0]]]} if len(rings) == 1 else
            {"type": "MultiPolygon", "coordinates": [[[list(p) for p in r]] for r in rings]})
    b_feats.append({"type": "Feature", "geometry": geom, "properties": {
        "id": bid, "name": t.get("name"), "building": t.get("building"),
        "levels": t.get("building:levels"), "height": t.get("height"),
        "address": " ".join(filter(None, [t.get("addr:housenumber"), t.get("addr:street")])) or None,
        "centroid": [clon, clat], "footprint_m2": round(area), "entrance_count": len(ents)}})

p_feats = [{"type": "Feature", "geometry": {"type": "LineString", "coordinates": [[g["lon"], g["lat"]] for g in p["geometry"]]},
            "properties": {"id": f'way/{p["id"]}', "highway": p["tags"]["highway"], "name": p["tags"].get("name")}}
           for p in paths]

for name, feats in [("buildings", b_feats), ("entrances", e_feats), ("paths", p_feats)]:
    json.dump({"type": "FeatureCollection", "features": feats}, open(f"{out}/{name}.geojson", "w"))
named = [f for f in b_feats if f["properties"]["name"]]
print(f"buildings {len(b_feats)} (named {len(named)}), entrances {len(e_feats)} "
      f"(osm {sum(1 for f in e_feats if f['properties']['source']=='osm')}), paths {len(p_feats)}")
print("buildings with 0 entrances:", sum(1 for f in b_feats if f["properties"]["entrance_count"] == 0),
      "| named with 0:", sum(1 for f in named if f["properties"]["entrance_count"] == 0))
