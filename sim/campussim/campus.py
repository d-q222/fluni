"""Campus map: OSM buildings -> typed locations, procedural rooms, entrances, path-network routing.

campus = Campus.build(cfg["map"])            # a few seconds; deterministic (cfg["map"]["map_seed"])
campus.route(("b", b0), ("b", b1))         # -> (polyline (K,2) xy meters, length m)
campus.write("runs/<id>/map")              # d2 map files + paths.geojson + entry_points.csv
"""
import csv
import hashlib
import json
import math
import re
import zlib
from collections import OrderedDict
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import connected_components, dijkstra
from scipy.spatial import cKDTree

from . import codes
from .geo import to_ll, to_xy

ROOT = Path(__file__).resolve().parent.parent
LAYOUTS = ["seated", "mingle", "bed", "free"]
MODES = ("walk", "bike")
ROADS = {"residential", "unclassified", "tertiary", "tertiary_link", "secondary", "secondary_link", "primary",
         "primary_link", "living_street"}

BUILDING_COLS = ["location_id", "osm_id", "name", "type", "lat", "lon", "floors", "area_m2", "capacity",
                 "ventilation_ach", "indoor", "entrance_sources"]
BUILDING_EXTRA = ["x_local_m", "y_local_m", "n_rooms", "source", "footprint_wkt"]
ROOM_COLS = ["room_id", "location_id", "floor", "room_type", "capacity", "area_m2", "volume_m3",
             "ventilation_ach", "source", "polygon_wkt"]
ROOM_EXTRA = ["x0", "y0", "x1", "y1", "layout", "indoor"]
ENT_COLS = ["entrance_id", "building_id", "lat", "lon", "source"]
ENT_EXTRA = ["x_local_m", "y_local_m"]


# ----------------------------------------------------------------------------- geometry helpers
def _scanline(rings, yc):
    """Sorted x-intervals [(a, b), ...] where the horizontal line y=yc is inside the union of rings."""
    xs = []
    for r in rings:
        x1, y1, x2, y2 = r[:-1, 0], r[:-1, 1], r[1:, 0], r[1:, 1]
        m = (y1 > yc) != (y2 > yc)
        if m.any():
            xs.append(x1[m] + (yc - y1[m]) * (x2[m] - x1[m]) / (y2[m] - y1[m]))
    if not xs:
        return []
    if len(rings) == 1:
        x = np.sort(xs[0])
        return [(x[i], x[i + 1]) for i in range(0, len(x) - 1, 2)]
    ivs = []
    for r in rings:  # union of per-ring intervals (rings of multipolygons don't overlap in practice)
        ivs += _scanline([r], yc)
    return sorted(ivs)


def point_in_rings(x, y, rings):
    """Even-odd point-in-polygon over the union of rings (each ring (n,2), closed)."""
    for r in rings:
        x1, y1, x2, y2 = r[:-1, 0], r[:-1, 1], r[1:, 0], r[1:, 1]
        m = (y1 > y) != (y2 > y)
        if m.any():
            xi = x1[m] + (y - y1[m]) * (x2[m] - x1[m]) / (y2[m] - y1[m])
            if (np.count_nonzero(x < xi) % 2) == 1:
                return True
    return False


def _is_passage(p):
    """OSM way that legitimately runs through/under a building footprint."""
    return (p.get("tunnel") in ("yes", "building_passage") or p.get("covered") == "yes" or
            p.get("indoor") == "yes" or p.get("highway") == "corridor" or p.get("layer") not in (None, "0"))


def _ring_area(r):
    return 0.5 * abs(np.dot(r[:-1, 0], r[1:, 1]) - np.dot(r[1:, 0], r[:-1, 1]))


def _wkt_ring(ring_ll):
    return "(" + ", ".join(f"{round(float(lo), 7)} {round(float(la), 7)}" for lo, la in ring_ll) + ")"


def _rect_ll(x0, y0, x1, y1):
    xs = np.array([x0, x1, x1, x0, x0])
    ys = np.array([y0, y0, y1, y1, y0])
    lo, la = to_ll(xs, ys)
    return [[round(float(a), 7), round(float(b), 7)] for a, b in zip(lo, la)]


def _shelf_pack(rings, bbox, rooms, gap, step, fill):
    """Place rooms [(w, h), ...] (sorted big-first) as axis-aligned rects into bbox rows.
    A room is placed when it fits horizontally inside the footprint along its center line
    (fallback: center inside). Returns list of (x0, y0) or None per room."""
    bx0, by0, bx1, by1 = bbox
    out = [None] * len(rooms)
    cx, cy, row_h = bx0 + gap * 0.5, by0 + gap * 0.5, 0.0
    failed = []  # (w, h) sizes that could not be placed -> anything >= also fails
    cache = {}

    def ivs_at(y):
        k = round(y, 2)
        if k not in cache:
            cache[k] = _scanline(rings, y)
        return cache[k]

    for i, (w, h) in enumerate(rooms):
        if any(w >= fw - 1e-9 and h >= fh - 1e-9 for fw, fh in failed):
            continue
        x, y, rh = cx, cy, row_h
        placed = None
        while y + h <= by1 + 1e-9:
            ivs = ivs_at(y + h / 2)
            cand = None
            for a, b in ivs:  # strict: whole width inside the scanline interval
                x0 = max(x, a)
                if x0 + w <= b:
                    cand = x0
                    break
            if cand is None:
                for a, b in ivs:  # relaxed: center inside
                    x0 = max(x, a - w / 2)
                    if x0 + w / 2 <= b and x0 + w <= bx1 + 1e-9:
                        cand = x0
                        break
            if cand is not None:
                placed = (cand, y)
                break
            # next row
            y = y + (rh + gap if rh > 0 else min(h, step))
            x, rh = bx0 + gap * 0.5, 0.0
        if placed is None:
            failed.append((w, h))
            continue
        out[i] = placed
        cx, cy, row_h = placed[0] + w + gap, placed[1], max(rh, h)
    return out


# ----------------------------------------------------------------------------- Campus
class Campus:
    LAYOUTS = LAYOUTS

    # ------------------------------------------------------------------ build
    @classmethod
    def build(cls, cfg_map: dict, data_dir=None) -> "Campus":
        self = cls()
        self.cfg = cfg_map
        data_dir = Path(data_dir or cfg_map.get("data_dir", "data/osm"))
        if not data_dir.is_absolute():
            data_dir = ROOT / data_dir
        self.data_dir = data_dir
        files = {n: data_dir / f"{n}.geojson" for n in ("buildings", "entrances", "paths", "building_holes")}
        man_path = ROOT / cfg_map.get("manual_places", "data/manual_places.json")
        ovr_path = ROOT / cfg_map.get("location_overrides", "data/location_overrides.json")
        h = hashlib.sha256()
        for p in [files["buildings"], files["entrances"], files["paths"], man_path, ovr_path] + \
                ([files["building_holes"]] if files["building_holes"].exists() else []):
            h.update(p.read_bytes() if p.exists() else b"")
        h.update(json.dumps(cfg_map, sort_keys=True).encode())
        self.version = h.hexdigest()[:16]

        bgj = json.loads(files["buildings"].read_text())["features"]
        egj = json.loads(files["entrances"].read_text())["features"]
        pgj = json.loads(files["paths"].read_text())["features"]
        manual = json.loads(man_path.read_text()) if man_path.exists() else []
        overrides = json.loads(ovr_path.read_text()) if ovr_path.exists() else {}
        hgj = json.loads(files["building_holes"].read_text())["features"] if files["building_holes"].exists() else []

        self._build_paths(pgj)
        self._build_buildings(bgj, manual, overrides)
        self._build_holes(hgj)
        self._build_entrances(egj, manual)
        self._build_rooms()
        self._build_entry_points()
        self._build_graph()
        return self

    # ------------------------------------------------------------------ classification
    def classify(self, name, tag):
        """Ordered regex rules on name + OSM building tag -> location type (unnamed -> other)."""
        if not name:
            return "other"
        for rule in self._rules:
            if "name" in rule and not rule["name"].search(name):
                continue
            if "tag" in rule and not rule["tag"].search(tag or ""):
                continue
            return rule["type"]
        return "other"

    def _build_buildings(self, bgj, manual, overrides):
        cfg = self.cfg
        self._rules = []
        for r in cfg["rules"]:
            rr = {"type": r["type"]}
            if "name" in r:
                rr["name"] = re.compile(r["name"])
            if "tag" in r:
                rr["tag"] = re.compile(r["tag"])
            self._rules.append(rr)
        types_cfg = cfg["types"]
        rows, self._rings = [], []
        for f in bgj:
            p = f["properties"]
            osm_id = p["id"]
            kind, num = osm_id.split("/")
            loc = f"bld_{num}"  # ways and relations alike (numbers never collide; heatmap relies on it)
            g = f["geometry"]
            polys = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]
            rings_ll = [np.asarray(poly[0], float) for poly in polys]
            rings = []
            for r in rings_ll:
                x, y = to_xy(r[:, 0], r[:, 1])
                rings.append(np.column_stack([x, y]))
            name = p.get("name") or ""
            ov = overrides.get(osm_id) or overrides.get(name) or {}
            ltype = ov.get("type") or self.classify(name, p.get("building"))
            lv = p.get("levels")
            m = re.match(r"\d+", str(lv)) if lv else None
            levels = int(ov.get("levels") or (int(m.group()) if m else types_cfg[ltype]["levels"]))
            wkt = ("POLYGON(" + _wkt_ring(rings_ll[0]) + ")" if len(rings_ll) == 1 else
                   "MULTIPOLYGON(" + ", ".join("(" + _wkt_ring(r) + ")" for r in rings_ll) + ")")
            lon, lat = p["centroid"]
            x, y = to_xy(lon, lat)
            rows.append(dict(location_id=loc, osm_id=osm_id, name=name, type=ltype, lat=lat, lon=lon,
                             x=float(x), y=float(y), footprint_m2=int(p.get("footprint_m2") or round(sum(map(_ring_area, rings)))),
                             levels=max(1, levels), capacity=0,
                             ventilation_ach=float(ov.get("ventilation_ach", types_cfg[ltype]["ventilation_ach"])),
                             indoor=bool(ov.get("indoor", ltype != "outdoor")), footprint_wkt=wkt, n_rooms=0,
                             source="osm", osm_tag=p.get("building") or "", cap_override=ov.get("capacity")))
            self._rings.append(rings)
        for mp in manual:
            ltype = mp["type"]
            x, y = to_xy(mp["lon"], mp["lat"])
            x, y = float(x), float(y)
            w, hh = float(mp.get("w", cfg["manual_default_w_m"])), float(mp.get("h", cfg["manual_default_h_m"]))
            ring = np.array([[x - w / 2, y - hh / 2], [x + w / 2, y - hh / 2], [x + w / 2, y + hh / 2],
                             [x - w / 2, y + hh / 2], [x - w / 2, y - hh / 2]])
            lo, la = to_ll(ring[:, 0], ring[:, 1])
            slug = mp.get("slug") or re.sub(r"[^a-z0-9]+", "_", mp["name"].lower()).strip("_")
            rows.append(dict(location_id=f"bld_m_{slug}", osm_id="", name=mp["name"], type=ltype,
                             lat=round(float(mp["lat"]), 7), lon=round(float(mp["lon"]), 7), x=x, y=y,
                             footprint_m2=int(round(w * hh)), levels=int(mp.get("levels", types_cfg[ltype]["levels"])),
                             capacity=0, ventilation_ach=float(mp.get("ventilation_ach", types_cfg[ltype]["ventilation_ach"])),
                             indoor=bool(mp.get("indoor", ltype != "outdoor")),
                             footprint_wkt="POLYGON(" + _wkt_ring(np.column_stack([lo, la])) + ")", n_rooms=0,
                             source="manual", osm_tag="", cap_override=mp.get("capacity")))
            self._rings.append([ring])
        self.buildings = pd.DataFrame(rows)
        self.B = len(rows)
        self.b_type = np.array([codes.LOCATION_TYPES.index(t) for t in self.buildings["type"]], dtype=np.int8)
        self.b_x = self.buildings["x"].to_numpy(float)
        self.b_y = self.buildings["y"].to_numpy(float)
        self._loc_to_b = {loc: i for i, loc in enumerate(self.buildings["location_id"])}
        self._name_to_b = {}
        for i, n in enumerate(self.buildings["name"]):
            if n and n not in self._name_to_b:
                self._name_to_b[n] = i

    def _build_holes(self, hgj):
        """Courtyards of multipolygon buildings (building_holes.geojson): open ground for routing only."""
        osm_to_b = {o: i for i, o in enumerate(self.buildings["osm_id"]) if o}
        self._holes = {}
        for f in hgj:
            b = osm_to_b.get(f["properties"]["building_id"])
            if b is None:
                continue
            for poly in f["geometry"]["coordinates"]:
                r = np.asarray(poly[0], float)
                x, y = to_xy(r[:, 0], r[:, 1])
                self._holes.setdefault(b, []).append(np.column_stack([x, y]))

    # ------------------------------------------------------------------ entrances
    def _build_entrances(self, egj, manual):
        rows = []
        osm_to_b = {o: i for i, o in enumerate(self.buildings["osm_id"]) if o}
        for i, f in enumerate(egj):
            p = f["properties"]
            b = osm_to_b.get(p["building_id"], -1)
            if b < 0:
                continue
            lon, lat = f["geometry"]["coordinates"]
            x, y = to_xy(lon, lat)
            rows.append(dict(entrance_id=f"ent_{i:04d}", building_id=self.buildings.at[b, "location_id"],
                             lat=lat, lon=lon, source=p["source"], x=float(x), y=float(y), b=b))
        nxt = len(egj)
        man_b = np.flatnonzero(self.buildings["source"].to_numpy() == "manual")
        for b in man_b:  # door at the footprint point nearest the nearest path node
            ring = self._rings[b][0]
            x0, y0, x1, y1 = ring[:, 0].min(), ring[:, 1].min(), ring[:, 0].max(), ring[:, 1].max()
            _, j = self._node_tree.query([self.b_x[b], self.b_y[b]])
            nx, ny = self.node_xy[j]
            px, py = min(max(nx, x0), x1), min(max(ny, y0), y1)
            if x0 < px < x1 and y0 < py < y1:  # node inside the rect -> project to nearest edge
                d = [px - x0, x1 - px, py - y0, y1 - py]
                k = int(np.argmin(d))
                px, py = [(x0, py), (x1, py), (px, y0), (px, y1)][k]
            lon, lat = to_ll(px, py)
            rows.append(dict(entrance_id=f"ent_{nxt:04d}", building_id=self.buildings.at[b, "location_id"],
                             lat=round(float(lat), 7), lon=round(float(lon), 7), source="manual",
                             x=float(px), y=float(py), b=int(b)))
            nxt += 1
        self.entrances = pd.DataFrame(rows)
        eb = self.entrances["b"].to_numpy()
        ex, ey = self.entrances["x"].to_numpy(), self.entrances["y"].to_numpy()
        # buildings without any entrance: synthesize one at the centroid (source "fallback")
        missing = sorted(set(range(self.B)) - set(eb.tolist()))
        if missing:
            extra = []
            for b in missing:
                lon, lat = to_ll(self.b_x[b], self.b_y[b])
                extra.append(dict(entrance_id=f"ent_{nxt:04d}", building_id=self.buildings.at[b, "location_id"],
                                  lat=round(float(lat), 7), lon=round(float(lon), 7), source="fallback",
                                  x=self.b_x[b], y=self.b_y[b], b=b))
                nxt += 1
            self.entrances = pd.concat([self.entrances, pd.DataFrame(extra)], ignore_index=True)
            eb = self.entrances["b"].to_numpy()
            ex, ey = self.entrances["x"].to_numpy(), self.entrances["y"].to_numpy()
        self.ent_b, self.ent_x, self.ent_y = eb.astype(np.int32), ex.astype(float), ey.astype(float)
        order = np.argsort(eb, kind="stable")
        starts = np.searchsorted(eb[order], np.arange(self.B + 1))
        self._b_ents = [order[starts[b]:starts[b + 1]] for b in range(self.B)]
        src = self.entrances.groupby("b")["source"].agg(lambda s: "|".join(sorted(set(s))))
        self.buildings["entrance_sources"] = [src.get(b, "") for b in range(self.B)]
        self.buildings["n_entrances"] = [len(e) for e in self._b_ents]

    def entrances_of(self, b) -> np.ndarray:
        """Entrance indices of building b (sorted)."""
        return self._b_ents[b]

    def nearest_entrance(self, b, x, y) -> int:
        """Entrance idx of building b nearest to (x, y)."""
        e = self._b_ents[b]
        return int(e[np.argmin((self.ent_x[e] - x) ** 2 + (self.ent_y[e] - y) ** 2)])

    # ------------------------------------------------------------------ rooms
    def _program(self, b, rng):
        """List of (floor, room_type, area_m2 | None, capacity | None) desired rooms for building b."""
        bt = self.buildings.iloc[b]
        ltype, fp, name = bt["type"], float(bt["footprint_m2"]), bt["name"]
        tc, rt = self.cfg["types"][ltype], self.cfg["room_types"]
        floors = int(min(bt["levels"], tc.get("max_floors", bt["levels"])))
        prog = []

        def cap_room(rtype, cap=None):
            lo, hi = rt[rtype]["cap_range"]
            c = int(cap if cap is not None else rng.integers(lo, hi + 1))
            return (rtype, c * rt[rtype]["m2_per_person"], c)

        if ltype == "dorm":
            mix = tc["bedroom_mix"]
            kinds = list(mix)
            p = np.array([mix[k] for k in kinds], float)
            p /= p.sum()
            mean_area = float(sum(p[i] * rt[k]["area_m2"] for i, k in enumerate(kinds)))
            n_bed = int(min(tc["max_rooms_per_floor"], fp * tc["bed_fill"] / mean_area))
            for fl in range(1, floors + 1):
                la = float(np.clip(fp * tc["lobby_frac"], tc["lobby_min_m2"], tc["lobby_max_m2"]))
                prog.append((fl, "lobby", la, None))
                ks = rng.choice(len(kinds), size=n_bed, p=p) if n_bed > 0 else []
                for k in ks:
                    prog.append((fl, kinds[k], float(rt[kinds[k]]["area_m2"]), int(rt[kinds[k]]["capacity"])))
        elif ltype == "classroom":
            n_lec = int(min(tc["max_lecture_rooms"], fp // tc["lecture_room_min_footprint_m2"]))
            for k in range(n_lec):
                r = cap_room("lecture_hall")
                prog.append((1 + k % floors, r[0], r[1], r[2]))
            budget = fp * floors * tc["teach_frac"]
            per_floor = [0] * (floors + 1)
            n = 0
            while budget > 0 and n < tc["max_rooms"]:
                fl = 1 + n % floors
                if per_floor[fl] >= tc["max_rooms_per_floor"]:
                    break
                r = cap_room("classroom" if rng.random() < tc["classroom_share"] else "seminar")
                if r[1] > budget and n > 0:
                    break
                prog.append((fl, r[0], r[1], r[2]))
                budget -= r[1]
                per_floor[fl] += 1
                n += 1
        elif ltype == "lecture_hall":
            seats = int(min(tc["max_seats"], fp * tc["hall_frac"] / rt["lecture_hall"]["m2_per_person"]))
            seats = max(seats, 20)
            prog.append((1, "lecture_hall", seats * rt["lecture_hall"]["m2_per_person"], seats))
        elif ltype == "dining":
            area = fp * tc["dining_frac"]
            cap = int(min(tc["max_capacity"], area / rt["dining_room"]["m2_per_person"]))
            prog.append((1, "dining_room", area, max(cap, 10)))
        elif ltype == "library":
            nread = max(1, min(floors, tc["reading_floors"]))
            for fl in range(1, nread + 1):
                prog.append((fl, "reading_room", fp * tc["reading_frac"], None))
            ns = int(min(tc["max_study_rooms_per_floor"], max(1, fp * tc["study_rooms_per_m2"])))
            for fl in range(1, floors + 1):
                for _ in range(ns):
                    r = cap_room("study_room")
                    prog.append((fl, r[0], r[1], r[2]))
        elif ltype == "gym":
            if re.search(r"(?i)\bpool\b|aquatic", name):
                prog.append((1, "pool", min(tc["pool_max_m2"], fp * tc["pool_frac"]), None))
            else:
                prog.append((1, "practice_gym", min(tc["practice_max_m2"], fp * tc["practice_frac"]), None))
            prog.append((1, "weight_room", min(tc["weight_max_m2"], fp * tc["weight_frac"]), None))
        elif ltype == "lab":
            r = cap_room("classroom")
            prog.append((1, r[0], r[1], r[2]))
            for fl in range(1, floors + 1):
                nl = 0
                budget = fp * tc["lab_frac"]
                while nl < tc["max_labs_per_floor"]:
                    r = cap_room("lab")
                    if r[1] > budget and nl > 0:
                        break
                    prog.append((fl, r[0], r[1], r[2]))
                    budget -= r[1]
                    nl += 1
        elif ltype == "party_venue":
            prog.append((1, "party_room", min(tc["party_max_m2"], fp * tc["party_frac"]), None))
            prog.append((1, "lounge", min(tc["lounge_max_m2"], fp * tc["lounge_frac"]), None))
        elif ltype == "event_venue":
            prog.append((1, "arena", fp * tc["arena_frac"], None))
        elif ltype == "common_room":
            cafe = bool(re.search(r"(?i)caf[eé]", name))
            if cafe:
                prog.append((1, "cafe", min(tc["cafe_max_m2"], fp * 0.6), None))
            else:
                prog.append((1, "lounge", min(tc["lounge_max_m2"], fp * tc["lounge_frac"]), None))
                if fp >= tc["cafe_min_footprint_m2"]:
                    prog.append((1, "cafe", min(tc["cafe_max_m2"], fp * tc["cafe_frac"]), None))
        elif ltype == "health_center":
            prog.append((1, "waiting_room", float(tc["waiting_m2"]), None))
            for _ in range(int(tc["n_exam_rooms"])):
                prog.append((1, "exam_room", float(rt["exam_room"]["area_m2"]), int(rt["exam_room"]["capacity"])))
        elif ltype == "outdoor":
            prog.append((1, "outdoor_area", fp, None))
        else:
            prog.append((1, "generic", min(tc["generic_max_m2"], max(10.0, fp * tc["generic_frac"])), None))
        return prog

    def _build_rooms(self):
        cfg, rt = self.cfg, self.cfg["room_types"]
        seed0 = int(cfg.get("map_seed", 0))
        gap, step, fill = float(cfg["room_gap_m"]), float(cfg["row_scan_step_m"]), float(cfg["max_room_fill"])
        rows = []
        n_rooms = np.zeros(self.B, int)
        caps = np.zeros(self.B, int)
        for b in range(self.B):
            bt = self.buildings.iloc[b]
            loc, ltype = bt["location_id"], bt["type"]
            rng = np.random.default_rng(seed0 + zlib.crc32(loc.encode()))
            rings = self._rings[b]
            allp = np.vstack(rings)
            bbox = (allp[:, 0].min(), allp[:, 1].min(), allp[:, 0].max(), allp[:, 1].max())
            bw, bh = bbox[2] - bbox[0], bbox[3] - bbox[1]
            tc = cfg["types"][ltype]
            indoor = bool(bt["indoor"])
            prog = self._program(b, rng)
            # dims (rounded to 0.1 m), clipped to the bbox
            dims = []
            for fl, rtype, area, cap in prog:
                asp = float(rt[rtype].get("aspect", 1.25))
                if rtype == "outdoor_area" or (rtype == "arena" and not indoor):
                    w, h = bw * fill, bh * fill
                else:
                    w, h = math.sqrt(area * asp), math.sqrt(area / asp)
                    if w > bw * fill:
                        w = bw * fill
                        h = min(area / w, bh * fill)
                    if h > bh * fill:
                        h = bh * fill
                        w = min(area / h, bw * fill)
                w = max(1.0, round(w, 1))
                dims.append((w, max(1.0, round(min(area / w, h), 3) if rtype != "outdoor_area" else round(h, 1))))
            placed_rows = []
            for fl in sorted(set(p[0] for p in prog)):
                idx = [i for i, p in enumerate(prog) if p[0] == fl]
                idx.sort(key=lambda i: -dims[i][0] * dims[i][1])  # big rooms first (stable)
                if prog[idx[0]][1] == "outdoor_area" or (prog[idx[0]][1] == "arena" and not indoor):
                    pos = [(bbox[0] + (bw - dims[idx[0]][0]) / 2, bbox[1] + (bh - dims[idx[0]][1]) / 2)]
                else:
                    pos = _shelf_pack(rings, bbox, [dims[i] for i in idx], gap, step, fill)
                for k, i in enumerate(idx):
                    if pos[k] is not None:
                        placed_rows.append((i, pos[k]))
            if not placed_rows and prog:  # guarantee >= 1 room: centered at the centroid, shrunk to fit
                i = 0
                w, h = dims[0]
                placed_rows.append((i, (self.b_x[b] - w / 2, self.b_y[b] - h / 2)))
            placed_rows.sort(key=lambda t: (prog[t[0]][0], t[1][1], t[1][0]))  # floor, then row-major
            k_per_floor = {}
            for i, (x0, y0) in placed_rows:
                fl, rtype, area, cap = prog[i]
                w, h = dims[i]
                a = round(w * h, 2)
                spec = rt[rtype]
                if cap is None or (a < area * 0.98 and "m2_per_person" in spec and rtype not in codes.BEDROOM_TYPES):
                    cap = max(1, int(a / spec["m2_per_person"]))
                room_indoor = indoor
                ceil = float(spec.get("ceiling_m", tc["ceiling_m"]))
                if rtype == "lobby" and ltype == "dorm":
                    ceil = float(tc["ceiling_m"])
                k_per_floor[fl] = k_per_floor.get(fl, 0) + 1
                rid = f"{loc}_f{fl}_{fl * 100 + k_per_floor[fl]:03d}"
                rows.append(dict(room_id=rid, location_id=loc, b=b, room_type=rtype, floor=fl, capacity=int(cap),
                                 area_m2=a, ceiling_m=ceil if room_indoor else float("nan"),
                                 volume_m3=round(a * ceil, 2) if room_indoor else float("nan"),
                                 x0=round(x0, 2), y0=round(y0, 2), x1=round(x0 + w, 2), y1=round(y0 + h, 2),
                                 layout=spec["layout"], indoor=room_indoor,
                                 ventilation_ach=float(bt["ventilation_ach"])))
            # capacity override: adjust the biggest room so the building total matches
            n_new = len(placed_rows)
            if pd.notna(bt["cap_override"]) and n_new:
                mine = rows[len(rows) - n_new:]
                big = max(range(n_new), key=lambda j: mine[j]["area_m2"])
                rest = sum(r["capacity"] for j, r in enumerate(mine) if j != big)
                mine[big]["capacity"] = max(1, int(bt["cap_override"]) - rest)
            n_rooms[b] = n_new
            caps[b] = sum(r["capacity"] for r in rows[len(rows) - n_new:])
        rooms = pd.DataFrame(rows)
        cx = (rooms["x0"] + rooms["x1"]) / 2
        cy = (rooms["y0"] + rooms["y1"]) / 2
        lon, lat = to_ll(cx.to_numpy(), cy.to_numpy())
        rooms["cx"], rooms["cy"] = cx.round(2), cy.round(2)
        rooms["lat"], rooms["lon"] = np.round(lat, 7), np.round(lon, 7)
        rooms["polygon_wkt"] = ["POLYGON((" + ", ".join(f"{lo} {la}" for lo, la in _rect_ll(*r)) + "))"
                                for r in rooms[["x0", "y0", "x1", "y1"]].itertuples(index=False)]
        self.rooms = rooms[["room_id", "location_id", "b", "room_type", "floor", "capacity", "area_m2", "ceiling_m",
                            "volume_m3", "x0", "y0", "x1", "y1", "cx", "cy", "lat", "lon", "polygon_wkt", "layout",
                            "indoor", "ventilation_ach"]]
        self.R = len(rooms)
        self.buildings["n_rooms"] = n_rooms
        self.buildings["capacity"] = caps
        r = self.rooms
        self.room_b = r["b"].to_numpy(np.int32)
        self.room_cap = r["capacity"].to_numpy(np.int32)
        self.room_vol = r["volume_m3"].to_numpy(float)
        self.room_ach = r["ventilation_ach"].to_numpy(float)
        self.room_indoor = r["indoor"].to_numpy(bool)
        self.room_floor = r["floor"].to_numpy(np.int16)
        self.room_x0, self.room_y0 = r["x0"].to_numpy(float), r["y0"].to_numpy(float)
        self.room_x1, self.room_y1 = r["x1"].to_numpy(float), r["y1"].to_numpy(float)
        self.room_layout = np.array([LAYOUTS.index(l) for l in r["layout"]], dtype=np.int8)
        self.room_type_names = sorted(set(r["room_type"]))
        self._rooms_by_b = [np.arange(0)] * self.B
        starts = np.searchsorted(self.room_b, np.arange(self.B + 1))  # rooms are emitted in b order
        self._rooms_by_b = [np.arange(starts[b], starts[b + 1]) for b in range(self.B)]
        bed = np.isin(r["room_type"].to_numpy(), codes.BEDROOM_TYPES)
        self.room_is_bedroom = bed
        self.total_beds = int(self.room_cap[bed].sum())

    # ------------------------------------------------------------------ paths / graph
    def _build_paths(self, pgj):
        excl = set(self.cfg.get("exclude_highways", []))
        dp = int(self.cfg.get("node_round_dp", 7))
        key_to_node, coords, eu, ev, ew = {}, [], [], [], []
        self._ways = []
        for f in pgj:
            hw = f["properties"].get("highway")
            if hw in excl:
                continue
            pts = f["geometry"]["coordinates"]
            ids = []
            for lon, lat in pts:
                k = (round(lon, dp), round(lat, dp))
                j = key_to_node.get(k)
                if j is None:
                    j = key_to_node[k] = len(coords)
                    coords.append(k)
                ids.append(j)
            wi = len(self._ways)
            self._ways.append((f, ids))
            for a, c in zip(ids, ids[1:]):
                if a != c:
                    eu.append(a)
                    ev.append(c)
                    ew.append(wi)
        ll = np.array(coords, float)
        x, y = to_xy(ll[:, 0], ll[:, 1])
        xy = np.column_stack([x, y])
        eu, ev, ew = np.array(eu), np.array(ev), np.array(ew)
        # per-mode cost factor of each way (inf = not allowed); edges no mode may use are dropped
        wf = {m: np.array([self._mode_factor(f["properties"], m) for f, _ in self._ways]) for m in MODES}
        ok = np.zeros(len(eu), bool)
        for m in MODES:
            ok |= np.isfinite(wf[m][ew])
        eu, ev, ew = eu[ok], ev[ok], ew[ok]
        n = len(coords)
        w = np.hypot(*(xy[eu] - xy[ev]).T)
        g = csr_matrix((np.r_[w, w] + 1e-9, (np.r_[eu, ev], np.r_[ev, eu])), shape=(n, n))
        ncomp, lab = connected_components(g, directed=False)
        big = np.bincount(lab[np.r_[eu, ev]]).argmax()
        keep = np.flatnonzero(lab == big)
        remap = -np.ones(n, int)
        remap[keep] = np.arange(len(keep))
        m = (lab[eu] == big)
        self.node_xy = xy[keep]
        self.node_ll = ll[keep]
        self.edges = np.column_stack([remap[eu[m]], remap[ev[m]]])
        self.edge_len = w[m]
        self.edge_way = ew[m]
        self.edge_f = {k: v[self.edge_way] for k, v in wf.items()}
        self._way_in_net = [bool(len(ids) and lab[ids[0]] == big) for _, ids in self._ways]
        self.P = len(keep)
        self._node_tree = cKDTree(self.node_xy)
        self.n_path_components = int(ncomp)

    def _mode_factor(self, p, mode):
        """Cost multiplier (>= ~0.8, inf = forbidden) of a way with OSM tags p for mode (map.json "modes")."""
        mc = self.cfg["modes"][mode]
        hw = p.get("highway")
        f = float(mc["highway"].get(hw, mc["default"]))
        own = p.get("foot" if mode == "walk" else "bicycle")
        if hw in mc.get("forbid", ()) or own in ("no", "use_sidepath"):
            return math.inf
        if p.get("access") in ("private", "no") and own not in ("yes", "designated", "permissive"):
            return math.inf
        if own == "dismount":
            return float(mc.get("dismount", math.inf))
        if own == "designated":
            f = min(f, float(mc["designated"]))
        elif own in ("yes", "permissive"):
            f = min(f, float(mc["allowed"]))
        fw = p.get("footway")
        if fw == "crossing":
            f = min(f, float(mc["crossing"]))
        elif fw == "sidewalk" and "sidewalk" in mc:
            f = max(f, float(mc["sidewalk"]))
        if hw in ROADS and mode == "walk":
            sw = p.get("sidewalk:both") or p.get("sidewalk")
            if sw in ("no", "none"):
                f *= float(mc["no_sidewalk"])
            elif sw == "separate":  # sidewalks are their own ways: walk on those, not the carriageway
                f *= float(mc["separate_sidewalk"])
        return f

    def _build_entry_points(self):
        rows = []
        for e, ep in enumerate(self.cfg["entry_points"]):
            x, y = to_xy(ep["lon"], ep["lat"])
            _, j = self._node_tree.query([float(x), float(y)])
            nx, ny = self.node_xy[j]
            lon, lat = self.node_ll[j]
            rows.append(dict(entry_id=f"entry_{e:02d}", name=ep["name"], x=float(nx), y=float(ny),
                             lat=round(float(lat), 7), lon=round(float(lon), 7), node=int(j)))
        self.entry_points = pd.DataFrame(rows)

    def _build_graph(self):
        """Per-mode directed graphs over path nodes [0,P) + entrance nodes [P,P+E) + src-super [.., +B) +
        dst-super [.., +B). src-super -> entrances (out only), entrances -> dst-super (in only): buildings
        are never tunnels. Each door is joined to the nearest point on a walkable edge whose straight
        connector clears every building (the edge is split there); edges through buildings cost more."""
        self._grid_build()
        self._fix_fallback_doors()
        self._attach_entrances()
        self._penalize_through_buildings()
        P, E, B = self.P, len(self.entrances), self.B
        acc = self.ent_access
        con = np.hypot(self.ent_x - self.node_xy[acc, 0], self.ent_y - self.node_xy[acc, 1])
        self.ent_connector_m = con
        eidx = P + np.arange(E)
        self._off_src, self._off_dst = P + E, P + E + B
        n = P + E + 2 * B
        tiny = 1e-6
        self._G, self._L = {}, {}
        for m in MODES:
            ok = np.isfinite(self.edge_f[m])
            e0, e1, el = self.edges[ok, 0], self.edges[ok, 1], self.edge_len[ok]
            cost = el * self.edge_f[m][ok] * self.edge_pen[ok]
            u = np.concatenate([e0, e1, eidx, acc, self._off_src + self.ent_b, eidx])
            v = np.concatenate([e1, e0, acc, eidx, eidx, self._off_dst + self.ent_b])
            c = np.concatenate([cost, cost, con, con, np.zeros(E), np.zeros(E)]) + tiny
            L = np.concatenate([el, el, con, con, np.zeros(E), np.zeros(E)])
            # parallel ways between the same nodes: keep the cheapest (csr_matrix would sum them)
            key = u.astype(np.int64) * n + v
            o = np.lexsort((c, key))
            first = np.r_[True, key[o][1:] != key[o][:-1]]
            o = o[first]
            self._G[m] = csr_matrix((c[o], (u[o], v[o])), shape=(n, n))
            self._L[m] = csr_matrix((L[o] + tiny, (u[o], v[o])), shape=(n, n))
        self._gxy = np.vstack([self.node_xy, np.column_stack([self.ent_x, self.ent_y]),
                               np.full((2 * B, 2), np.nan)])
        self._sssp_cache = OrderedDict()
        self._row_cache = {}
        self._entry_nodes = set(self.entry_points["node"].tolist())
        self._targets = np.concatenate([self._off_dst + np.arange(B), self.entry_points["node"].to_numpy()])

    # -- footprint raster: which indoor building (if any) covers each 1 m cell
    def _grid_build(self):
        res = float(self.cfg.get("footprint_grid_m", 1.0))
        tags = self.buildings["osm_tag"].to_numpy()
        solid = self.buildings["indoor"].to_numpy(bool) & ~np.isin(tags, list(self.cfg.get("open_building_tags", [])))
        allxy = np.vstack([r for rings in self._rings for r in rings] + [self.node_xy])
        x0, y0 = allxy.min(0) - 10
        x1, y1 = allxy.max(0) + 10
        nx, ny = int((x1 - x0) / res) + 1, int((y1 - y0) / res) + 1
        grid = np.full((ny, nx), -1, np.int32)
        xc = x0 + (np.arange(nx) + 0.5) * res
        for b in np.flatnonzero(solid):
            rings = self._rings[b]
            ry = np.concatenate([r[:, 1] for r in rings])
            j0, j1 = max(0, int((ry.min() - y0) / res)), min(ny - 1, int((ry.max() - y0) / res))
            holes = self._holes.get(b, [])
            for j in range(j0, j1 + 1):
                yc = y0 + (j + 0.5) * res
                for a, c in _scanline(rings, yc):
                    i0, i1 = np.searchsorted(xc, [a, c])
                    grid[j, i0:i1] = b
                for h in holes:
                    for a, c in _scanline([h], yc):
                        i0, i1 = np.searchsorted(xc, [a, c])
                        row = grid[j, i0:i1]
                        row[row == b] = -1
        self._grid, self._grid_o, self._grid_res = grid, (x0, y0), res

    def building_at(self, x, y):
        """Indoor building idx covering each point (-1 = open ground); x, y arrays (m)."""
        x, y = np.asarray(x, float), np.asarray(y, float)
        g, (x0, y0), res = self._grid, self._grid_o, self._grid_res
        i = ((x - x0) / res).astype(np.int64)
        j = ((y - y0) / res).astype(np.int64)
        ok = (i >= 0) & (j >= 0) & (i < g.shape[1]) & (j < g.shape[0])
        out = np.full(x.shape, -1, np.int32)
        out[ok] = g[j[ok], i[ok]]
        return out

    def _clear(self, p, q, skip_m=0.5):
        """True if the straight segment p->q (past its first skip_m meters) stays out of every building."""
        L = math.hypot(q[0] - p[0], q[1] - p[1])
        if L <= skip_m:
            return True
        s = np.arange(skip_m, L, 0.5 * self._grid_res) / L
        return not (self.building_at(p[0] + s * (q[0] - p[0]), p[1] + s * (q[1] - p[1])) >= 0).any()

    def _edge_index(self):
        """KD-tree over points sampled every ~4 m along walkable edges -> candidate edges near a point."""
        walk = np.flatnonzero(np.isfinite(self.edge_f["walk"]))
        a, b = self.node_xy[self.edges[walk, 0]], self.node_xy[self.edges[walk, 1]]
        k = np.maximum(1, np.ceil(self.edge_len[walk] / 4.0)).astype(int)
        rep = np.repeat(np.arange(len(walk)), k + 1)
        f = np.concatenate([np.linspace(0, 1, n + 1) for n in k])
        pts = a[rep] + f[:, None] * (b[rep] - a[rep])
        return cKDTree(pts), walk[rep]

    def _project(self, x, y, eids):
        a, b = self.node_xy[self.edges[eids, 0]], self.node_xy[self.edges[eids, 1]]
        d = b - a
        L2 = np.maximum((d ** 2).sum(1), 1e-12)
        t = np.clip(((x - a[:, 0]) * d[:, 0] + (y - a[:, 1]) * d[:, 1]) / L2, 0, 1)
        q = a + t[:, None] * d
        return q, t, np.hypot(q[:, 0] - x, q[:, 1] - y)

    def _best_attach(self, x, y, tree, owner):
        """(edge, t, q, clear) of the nearest walkable-edge point reachable from (x, y) by a clear line."""
        best = None
        for R in self.cfg.get("connector_search_m", [30, 80, 200, 500]):
            idx = tree.query_ball_point([x, y], R + 4.0)
            if not idx:
                continue
            eids = np.unique(owner[idx])
            q, t, d = self._project(x, y, eids)
            o = np.argsort(d, kind="stable")
            if best is None:
                best = (int(eids[o[0]]), float(t[o[0]]), q[o[0]], False)
            for j in o[:24]:
                if d[j] > R:
                    break
                if self._clear((x, y), q[j]):
                    return int(eids[j]), float(t[j]), q[j], True
        return best

    def _fix_fallback_doors(self):
        """Fallback doors (no tagged door and no footpath within 12 m) and doors of hand-placed buildings
        (data/manual_places.json, often overlapping OSM footprints) move to the outline point with the
        shortest clear connector to a walkable edge."""
        tree, owner = self._edge_index()
        src = self.entrances["source"].to_numpy()
        for e in np.flatnonzero(np.isin(src, ["fallback", "manual"])):
            b = int(self.ent_b[e])
            ring = max(self._rings[b], key=lambda r: abs(_ring_area(r)))
            seg = np.hypot(*np.diff(ring, axis=0).T)
            cum = np.r_[0, np.cumsum(seg)]
            s = np.arange(0, cum[-1], 1.0)
            k = np.clip(np.searchsorted(cum, s, side="right") - 1, 0, len(seg) - 1)
            f = ((s - cum[k]) / np.maximum(seg[k], 1e-9))[:, None]
            pts = ring[k] + f * (ring[k + 1] - ring[k])
            d, _ = tree.query(pts)
            for j in np.argsort(d, kind="stable")[:40]:
                r = self._best_attach(pts[j, 0], pts[j, 1], tree, owner)
                if r and r[3]:
                    x, y = float(pts[j, 0]), float(pts[j, 1])
                    lon, lat = to_ll(x, y)
                    self.ent_x[e], self.ent_y[e] = x, y
                    self.entrances.loc[e, ["x", "y", "lat", "lon"]] = [x, y, round(float(lat), 7), round(float(lon), 7)]
                    break

    def _attach_entrances(self):
        """Join every door to a walkable edge (split at the attachment point); sets ent_access (node idx)."""
        tree, owner = self._edge_index()
        E = len(self.entrances)
        att = [self._best_attach(float(self.ent_x[e]), float(self.ent_y[e]), tree, owner) for e in range(E)]
        self.ent_clear = np.array([bool(a and a[3]) for a in att])
        snap = float(self.cfg.get("split_snap_m", 0.5))
        acc = np.zeros(E, np.int32)
        splits = {}
        for e, (eid, t, q, _) in enumerate(att):
            u, v = self.edges[eid]
            L = self.edge_len[eid]
            if t * L <= snap:
                acc[e] = u
            elif (1 - t) * L <= snap:
                acc[e] = v
            else:
                splits.setdefault(eid, []).append((t, e, q))
        new_xy, new_edges, new_way, drop = [], [], [], []
        nid = self.P
        for eid in sorted(splits):
            u, v = self.edges[eid]
            chain = [int(u)]
            last_t = -1.0
            for t, e, q in sorted(splits[eid], key=lambda r: (r[0], r[1])):
                if (t - last_t) * self.edge_len[eid] <= snap and len(chain) > 1:
                    acc[e] = chain[-1]  # doors attaching (almost) at the same point share a node
                    continue
                new_xy.append(q)
                chain.append(nid)
                acc[e] = nid
                nid += 1
                last_t = t
            chain.append(int(v))
            drop.append(eid)
            for a, c in zip(chain, chain[1:]):
                new_edges.append((a, c))
                new_way.append(self.edge_way[eid])
        if new_xy:
            keep = np.ones(len(self.edges), bool)
            keep[drop] = False
            self.node_xy = np.vstack([self.node_xy, np.asarray(new_xy)])
            self.node_ll = np.vstack([self.node_ll, np.column_stack(to_ll(*np.asarray(new_xy).T))])
            ne = np.asarray(new_edges, np.int64)
            nw = np.asarray(new_way, np.int64)
            fk = {m: f[keep] for m, f in self.edge_f.items()}
            way_f = {m: np.full(len(self._ways), np.nan) for m in self.edge_f}
            for m, f in self.edge_f.items():
                way_f[m][self.edge_way] = f
            self.edges = np.vstack([self.edges[keep], ne])
            self.edge_way = np.concatenate([self.edge_way[keep], nw])
            self.edge_len = np.hypot(*(self.node_xy[self.edges[:, 0]] - self.node_xy[self.edges[:, 1]]).T)
            self.edge_f = {m: np.concatenate([fk[m], way_f[m][nw]]) for m in self.edge_f}
            self.P = len(self.node_xy)
            self._node_tree = cKDTree(self.node_xy)
        self.ent_access = acc

    def _penalize_through_buildings(self):
        """edge_pen: map.json through_building_factor on edges running >= through_building_min_m inside an
        indoor footprint, unless OSM marks the way as a passage (tunnel/covered/indoor/corridor/layer) or
        map.json lists it in passage_ways."""
        pen = float(self.cfg.get("through_building_factor", 1.0))
        min_m = float(self.cfg.get("through_building_min_m", 3.0))
        step = 0.5 * self._grid_res
        k = np.maximum(1, np.ceil(self.edge_len / step)).astype(int)
        rep = np.repeat(np.arange(len(self.edges)), k)
        f = (np.arange(k.sum()) - np.repeat(np.cumsum(k) - k, k) + 0.5) / np.repeat(k, k)
        a, b = self.node_xy[self.edges[rep, 0]], self.node_xy[self.edges[rep, 1]]
        inside = self.building_at(*(a + f[:, None] * (b - a)).T) >= 0
        m_in = np.bincount(rep, weights=inside * (self.edge_len[rep] / k[rep]), minlength=len(self.edges))
        extra = set(self.cfg.get("passage_ways", []))
        passage = np.array([_is_passage(f["properties"]) or f["properties"].get("id") in extra
                            for f, _ in self._ways])[self.edge_way]
        self.edge_passage = passage
        self.edge_inside_m = m_in
        self.edge_pen = np.where((m_in >= min_m) & ~passage, pen, 1.0)

    def _src_node(self, src):
        kind, val = src
        if kind == "b":
            return self._off_src + int(val), None, 0.0
        if kind == "e":
            return int(self.entry_points.at[int(val), "node"]), None, 0.0
        if kind == "xy":
            x, y = float(val[0]), float(val[1])
            d, j = self._node_tree.query([x, y])
            return int(j), (x, y), float(d)
        raise ValueError(f"bad endpoint {src!r}")

    def _dst_node(self, dst):
        kind, val = dst
        if kind == "b":
            return self._off_dst + int(val), None, 0.0
        return self._src_node(dst)

    def _sssp(self, s, mode="walk"):
        """(cost, predecessor, geometric length) from node s over mode's graph; costs pick the route,
        lengths (meters along it) time it."""
        ck = (mode, s)
        c = self._sssp_cache.get(ck)
        if c is not None:
            self._sssp_cache.move_to_end(ck)
            return c
        d, pred = dijkstra(self._G[mode], directed=True, indices=s, return_predecessors=True)
        pred = pred.astype(np.int64)
        has = pred >= 0
        w = np.zeros(len(pred))
        w[has] = np.asarray(self._L[mode][pred[has], np.flatnonzero(has)]).ravel()
        anc = np.where(has, pred, -1)
        while (anc >= 0).any():  # pointer jumping: sum edge lengths up the shortest-path tree
            m = anc >= 0
            w2, a2 = w.copy(), anc.copy()
            w2[m] += w[anc[m]]
            a2[m] = anc[anc[m]]
            w, anc = w2, a2
        w[~np.isfinite(d)] = np.inf
        c = (d.astype(np.float64), pred.astype(np.int32), w)
        self._sssp_cache[ck] = c
        if len(self._sssp_cache) > int(self.cfg.get("route_cache_size", 512)):
            self._sssp_cache.popitem(last=False)
        if s >= self._off_src or s in self._entry_nodes:
            self._row_cache[ck] = w[self._targets]
        return c

    def route(self, src, dst, mode="walk"):
        """Polyline (K,2) xy meters from src to dst along paths (door -> paths -> door) and its length (m).
        src/dst: ("b", b) | ("e", entry idx) | ("xy", (x, y)); mode: "walk" | "bike"."""
        r = self.route_full(src, dst, mode)
        return r["xy"], r["length"]

    def route_full(self, src, dst, mode="walk"):
        """route() plus the entrances used and the mode actually routed (bike falls back to walk when the
        bike network can't connect src and dst): dict(xy, length, src_entrance, dst_entrance, mode)."""
        s, sp, sd = self._src_node(src)
        t, tp, td = self._dst_node(dst)
        if src[0] == "b" and dst[0] == "b" and int(src[1]) == int(dst[1]):
            e = int(self._b_ents[int(src[1])][0])
            return dict(xy=np.array([[self.ent_x[e], self.ent_y[e]]]), length=0.0, src_entrance=e, dst_entrance=e,
                        mode=mode)
        d, pred, glen = self._sssp(s, mode)
        if not np.isfinite(d[t]) and mode != "walk":
            return self.route_full(src, dst, "walk")
        seq = []
        j = t
        while j >= 0:
            seq.append(j)
            if j == s:
                break
            j = pred[j]
        seq.reverse()
        P, E = self.P, len(self.entrances)
        ents = [k - P for k in seq if P <= k < P + E]
        pts = self._gxy[[k for k in seq if k < P + E]]
        if sp is not None:
            pts = np.vstack([[sp], pts])
        if tp is not None:
            pts = np.vstack([pts, [tp]])
        length = float(glen[t]) + sd + td
        se = ents[0] if src[0] == "b" and ents else -1
        de = ents[-1] if dst[0] == "b" and ents else -1
        if len(pts) == 1:
            pts = np.vstack([pts, pts])
        return dict(xy=pts, length=length, src_entrance=se, dst_entrance=de, mode=mode)

    def distance(self, src, dst, mode="walk") -> float:
        """Length (m) of the mode's route between endpoints (inf if that network can't connect them);
        building/entry rows cached for all sources."""
        if src[0] == "b" and dst[0] == "b" and int(src[1]) == int(dst[1]):
            return 0.0
        if src[0] in ("b", "e") and dst[0] in ("b", "e"):
            ti = int(dst[1]) if dst[0] == "b" else self.B + int(dst[1])
            s = self._src_node(src)[0]
            row = self._row_cache.get((mode, s))
            if row is None:  # symmetric network: reuse the reverse row if cached
                si = int(src[1]) if src[0] == "b" else self.B + int(src[1])
                s2 = self._src_node(dst)[0]
                row2 = self._row_cache.get((mode, s2))
                if row2 is None:
                    # compute the destination's row instead: destinations (dining, classes) repeat more
                    self._sssp(s2, mode)
                    row2 = self._row_cache[(mode, s2)]
                return float(row2[si])
            return float(row[ti])
        return self.route_full(src, dst, mode)["length"]

    def trip_mode(self, src, dst, owns_bike):
        """("walk"|"bike", route length m): bike owners ride trips of at least modes.bike_min_trip_m that the
        bike network connects; everyone else, and short hops, walk."""
        dw = self.distance(src, dst, "walk")
        if owns_bike and dw >= float(self.cfg["modes"]["bike_min_trip_m"]):
            db = self.distance(src, dst, "bike")
            if np.isfinite(db):
                return "bike", db
        return "walk", dw

    # ------------------------------------------------------------------ lookups
    def buildings_of_type(self, type_name) -> np.ndarray:
        return np.flatnonzero(self.b_type == codes.LOCATION_TYPES.index(type_name))

    def rooms_of(self, b, room_type=None) -> np.ndarray:
        r = self._rooms_by_b[int(b)]
        if room_type is None:
            return r
        types = self.rooms["room_type"].to_numpy()
        if isinstance(room_type, (list, tuple, set)):
            return r[np.isin(types[r], list(room_type))]
        return r[types[r] == room_type]

    def find_building(self, name) -> int:
        return int(self._name_to_b.get(name, -1))

    # ------------------------------------------------------------------ output
    def write(self, map_dir):
        """Write d2 map files (+ paths.geojson, entry_points.csv) into map_dir."""
        d = Path(map_dir)
        d.mkdir(parents=True, exist_ok=True)

        def wcsv(path, recs, cols):
            with open(path, "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=cols)
                w.writeheader()
                w.writerows(recs)

        def nz(v):
            return "" if v is None or (isinstance(v, float) and math.isnan(v)) else v

        bl = self.buildings
        recs = []
        for i in range(self.B):
            r = bl.iloc[i]
            recs.append(dict(location_id=r["location_id"], osm_id=r["osm_id"], name=r["name"], type=r["type"],
                             lat=round(float(r["lat"]), 7), lon=round(float(r["lon"]), 7), floors=int(r["levels"]),
                             area_m2=int(r["footprint_m2"]), capacity=int(r["capacity"]),
                             ventilation_ach=float(r["ventilation_ach"]), indoor=bool(r["indoor"]),
                             entrance_sources=r["entrance_sources"], x_local_m=round(float(r["x"]), 2),
                             y_local_m=round(float(r["y"]), 2), n_rooms=int(r["n_rooms"]), source=r["source"],
                             footprint_wkt=r["footprint_wkt"]))
        wcsv(d / "buildings.csv", recs, BUILDING_COLS + BUILDING_EXTRA)

        rm = self.rooms
        recs, feats = [], []
        cols = list(zip(*[rm[c].tolist() for c in ["room_id", "location_id", "floor", "room_type", "capacity", "area_m2",
                                                     "volume_m3", "ventilation_ach", "polygon_wkt", "x0", "y0", "x1",
                                                     "y1", "layout", "indoor"]]))
        for (rid, loc, fl, rtype, cap, area, vol, ach, wkt, x0, y0, x1, y1, lay, ind) in cols:
            props = dict(room_id=rid, location_id=loc, floor=int(fl), room_type=rtype, capacity=int(cap),
                         area_m2=float(area), volume_m3=nz(float(vol)), ventilation_ach=float(ach), source="procedural")
            extra = dict(x0=float(x0), y0=float(y0), x1=float(x1), y1=float(y1), layout=lay, indoor=bool(ind))
            recs.append(props | {"polygon_wkt": wkt} | extra)
            gp = props | extra
            if gp["volume_m3"] == "":
                gp["volume_m3"] = None
            feats.append({"type": "Feature", "properties": gp,
                          "geometry": {"type": "Polygon", "coordinates": [_rect_ll(x0, y0, x1, y1)]}})
        wcsv(d / "rooms.csv", recs, ROOM_COLS + ROOM_EXTRA)
        with open(d / "rooms.geojson", "w") as f:
            json.dump({"type": "FeatureCollection", "features": feats}, f, indent=1)

        en = self.entrances
        recs = [dict(entrance_id=r.entrance_id, building_id=r.building_id, lat=round(float(r.lat), 7),
                     lon=round(float(r.lon), 7), source=r.source, x_local_m=round(float(r.x), 2),
                     y_local_m=round(float(r.y), 2)) for r in en.itertuples(index=False)]
        wcsv(d / "entrances.csv", recs, ENT_COLS + ENT_EXTRA)

        feats = []
        for (f, ids), innet in zip(self._ways, self._way_in_net):
            p = f["properties"]
            feats.append({"type": "Feature", "properties": {"id": p.get("id"), "highway": p.get("highway"),
                                                            "name": p.get("name"), "in_network": innet,
                                                            "walk": innet and math.isfinite(self._mode_factor(p, "walk")),
                                                            "bike": innet and math.isfinite(self._mode_factor(p, "bike"))},
                          "geometry": f["geometry"]})
        with open(d / "paths.geojson", "w") as f:
            json.dump({"type": "FeatureCollection", "features": feats}, f)

        ep = self.entry_points
        recs = [dict(entry_id=r.entry_id, name=r.name, lat=r.lat, lon=r.lon, x_local_m=round(r.x, 2),
                     y_local_m=round(r.y, 2)) for r in ep.itertuples(index=False)]
        wcsv(d / "entry_points.csv", recs, ["entry_id", "name", "lat", "lon", "x_local_m", "y_local_m"])
