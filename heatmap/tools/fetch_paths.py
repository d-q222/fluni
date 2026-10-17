"""Fetch Stanford's walkable network from OpenStreetMap (ODbL) into data/stanford_paths.json.

Agents walk along this graph between buildings. Output:
  nodes: [[lat, lon], ...]
  edges: [[i, j], ...]  (undirected; lengths are computed in the browser)

Usage: python3 tools/fetch_paths.py   (run from heatmap/)
"""
import json
import urllib.parse
import urllib.request

OVERPASS = "https://overpass-api.de/api/interpreter"
BBOX = "37.4140,-122.1850,37.4380,-122.1530"  # a bit larger than the buildings, so routes can detour
WALKABLE = "footway|path|pedestrian|steps|cycleway|living_street|residential|service|unclassified|tertiary|secondary"


def main():
    query = f'[out:json][timeout:90];way["highway"~"^({WALKABLE})$"]["access"!~"private|no"]({BBOX});(._;>;);out skel qt;'
    req = urllib.request.Request(
        OVERPASS,
        data=urllib.parse.urlencode({"data": query}).encode(),
        headers={"User-Agent": "fluni-hackathon/0.1", "Accept": "application/json"},
    )
    elements = json.load(urllib.request.urlopen(req, timeout=120))["elements"]

    coords = {e["id"]: (e["lat"], e["lon"]) for e in elements if e["type"] == "node"}
    index, nodes, edges = {}, [], set()
    for way in (e for e in elements if e["type"] == "way"):
        ids = [i for i in way["nodes"] if i in coords]
        for osm_id in ids:
            if osm_id not in index:
                index[osm_id] = len(nodes)
                lat, lon = coords[osm_id]
                nodes.append([round(lat, 6), round(lon, 6)])
        for a, b in zip(ids, ids[1:]):
            i, j = sorted((index[a], index[b]))
            if i != j:
                edges.add((i, j))

    with open("data/stanford_paths.json", "w") as f:
        json.dump({"attribution": "© OpenStreetMap contributors (ODbL)", "nodes": nodes,
                   "edges": sorted(edges)}, f, separators=(",", ":"))
    print(f"wrote {len(nodes)} nodes, {len(edges)} edges")


if __name__ == "__main__":
    main()
