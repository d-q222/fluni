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
        files = {n: data_dir / f"{n}.geojson" for n in ("buildings", "entrances", "paths")}
        man_path = ROOT / cfg_map.get("manual_places", "data/manual_places.json")
        ovr_path = ROOT / cfg_map.get("location_overrides", "data/location_overrides.json")
        h = hashlib.sha256()
        for p in [files["buildings"], files["entrances"], files["paths"], man_path, ovr_path]:
            h.update(p.read_bytes() if p.exists() else b"")
        h.update(json.dumps(cfg_map, sort_keys=True).encode())
        self.version = h.hexdigest()[:16]

        bgj = json.loads(files["buildings"].read_text())["features"]
        egj = json.loads(files["entrances"].read_text())["features"]
        pgj = json.loads(files["paths"].read_text())["features"]
        manual = json.loads(man_path.read_text()) if man_path.exists() else []
        overrides = json.loads(ovr_path.read_text()) if ovr_path.exists() else {}

        self._build_paths(pgj)
        self._build_buildings(bgj, manual, overrides)
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
        key_to_node, coords, eu, ev = {}, [], [], []
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
            self._ways.append((f, ids))
            for a, c in zip(ids, ids[1:]):
                if a != c:
                    eu.append(a)
                    ev.append(c)
        ll = np.array(coords, float)
        x, y = to_xy(ll[:, 0], ll[:, 1])
        xy = np.column_stack([x, y])
        eu, ev = np.array(eu), np.array(ev)
        n = len(coords)
        w = np.hypot(*(xy[eu] - xy[ev]).T)
        g = csr_matrix((np.r_[w, w] + 1e-9, (np.r_[eu, ev], np.r_[ev, eu])), shape=(n, n))
        ncomp, lab = connected_components(g, directed=False)
        big = np.bincount(lab).argmax()
        keep = np.flatnonzero(lab == big)
        remap = -np.ones(n, int)
        remap[keep] = np.arange(len(keep))
        m = (lab[eu] == big)
        self.node_xy = xy[keep]
        self.node_ll = ll[keep]
        self.edges = np.column_stack([remap[eu[m]], remap[ev[m]]])
        self.edge_len = w[m]
        self._way_in_net = [bool(len(ids) and lab[ids[0]] == big) for _, ids in self._ways]
        self.P = len(keep)
        self._node_tree = cKDTree(self.node_xy)
        self.n_path_components = int(ncomp)

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
        """Directed graph: path nodes [0,P) + entrance nodes [P,P+E) + src-super [.., +B) + dst-super [.., +B).
        src-super -> entrances (out only), entrances -> dst-super (in only): buildings are never tunnels."""
        P, E, B = self.P, len(self.entrances), self.B
        _, acc = self._node_tree.query(np.column_stack([self.ent_x, self.ent_y]))
        self.ent_access = acc.astype(np.int32)
        con = np.hypot(self.ent_x - self.node_xy[acc, 0], self.ent_y - self.node_xy[acc, 1])
        eidx = P + np.arange(E)
        self._off_src, self._off_dst = P + E, P + E + B
        tiny = 1e-6
        u = [self.edges[:, 0], self.edges[:, 1], eidx, acc, self._off_src + self.ent_b, eidx]
        v = [self.edges[:, 1], self.edges[:, 0], acc, eidx, eidx, self._off_dst + self.ent_b]
        w = [self.edge_len + tiny, self.edge_len + tiny, con + tiny, con + tiny, np.full(E, tiny), np.full(E, tiny)]
        n = P + E + 2 * B
        self._G = csr_matrix((np.concatenate(w), (np.concatenate(u), np.concatenate(v))), shape=(n, n))
        self._gxy = np.vstack([self.node_xy, np.column_stack([self.ent_x, self.ent_y]),
                               np.full((2 * B, 2), np.nan)])
        self._sssp_cache = OrderedDict()
        self._row_cache = {}
        self._entry_nodes = set(self.entry_points["node"].tolist())
        self._targets = np.concatenate([self._off_dst + np.arange(B), self.entry_points["node"].to_numpy()])

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

    def _sssp(self, s):
        c = self._sssp_cache.get(s)
        if c is not None:
            self._sssp_cache.move_to_end(s)
            return c
        d, pred = dijkstra(self._G, directed=True, indices=s, return_predecessors=True)
        c = (d.astype(np.float64), pred.astype(np.int32))
        self._sssp_cache[s] = c
        if len(self._sssp_cache) > int(self.cfg.get("route_cache_size", 512)):
            self._sssp_cache.popitem(last=False)
        if s >= self._off_src or s in self._entry_nodes:
            self._row_cache[s] = c[0][self._targets]
        return c

    def route(self, src, dst):
        """Polyline (K,2) xy meters from src to dst along paths (door -> paths -> door) and its length (m).
        src/dst: ("b", b) | ("e", entry idx) | ("xy", (x, y))."""
        r = self.route_full(src, dst)
        return r["xy"], r["length"]

    def route_full(self, src, dst):
        """route() plus the entrances used: dict(xy, length, src_entrance, dst_entrance) (entrance idx or -1)."""
        s, sp, sd = self._src_node(src)
        t, tp, td = self._dst_node(dst)
        if src[0] == "b" and dst[0] == "b" and int(src[1]) == int(dst[1]):
            e = int(self._b_ents[int(src[1])][0])
            return dict(xy=np.array([[self.ent_x[e], self.ent_y[e]]]), length=0.0, src_entrance=e, dst_entrance=e)
        d, pred = self._sssp(s)
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
        length = float(d[t]) + sd + td
        se = ents[0] if src[0] == "b" and ents else -1
        de = ents[-1] if dst[0] == "b" and ents else -1
        if len(pts) == 1:
            pts = np.vstack([pts, pts])
        return dict(xy=pts, length=length, src_entrance=se, dst_entrance=de)

    def distance(self, src, dst) -> float:
        """Path distance (m) between endpoints; building/entry rows cached for all sources."""
        if src[0] == "b" and dst[0] == "b" and int(src[1]) == int(dst[1]):
            return 0.0
        if src[0] in ("b", "e") and dst[0] in ("b", "e"):
            ti = int(dst[1]) if dst[0] == "b" else self.B + int(dst[1])
            s = self._src_node(src)[0]
            row = self._row_cache.get(s)
            if row is None:  # symmetric network: reuse the reverse row if cached
                row2 = self._row_cache.get(self._src_node(dst)[0])
                if row2 is not None:
                    return float(row2[int(src[1]) if src[0] == "b" else self.B + int(src[1])])
                # compute the destination's row instead: destinations (dining, classes) repeat more
                s2 = self._src_node(dst)[0]
                self._sssp(s2)
                return float(self._row_cache[s2][int(src[1]) if src[0] == "b" else self.B + int(src[1])])
            return float(row[ti])
        return self.route_full(src, dst)["length"]

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
                                                            "name": p.get("name"), "in_network": innet},
                          "geometry": f["geometry"]})
        with open(d / "paths.geojson", "w") as f:
            json.dump({"type": "FeatureCollection", "features": feats}, f)

        ep = self.entry_points
        recs = [dict(entry_id=r.entry_id, name=r.name, lat=r.lat, lon=r.lon, x_local_m=round(r.x, 2),
                     y_local_m=round(r.y, 2)) for r in ep.itertuples(index=False)]
        wcsv(d / "entry_points.csv", recs, ["entry_id", "name", "lat", "lon", "x_local_m", "y_local_m"])
