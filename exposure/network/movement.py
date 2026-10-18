#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""
Follow the sim's agents as they move and track each one's P(flu) as they go.

The sim's timeline gives every agent's position, room and floor every 5 min.
This script finds the meetings itself from those tracks, without contacts.csv.
At each 5-min step, two agents meet when they are:

  * in the same room: they share its air (Wells-Riley room term), and the
    exhaled-plume term uses their actual distance apart; or
  * both outdoors (walking between buildings, on a quad) and within 5 m:
    plume term only, diluted 5x more by wind.

Each meeting's dose feeds lambda_{j->i} exactly as in the calculator
(../flu_risk.py), and mean_field.py's Baker et al. (PNAS 2021) update then
tracks every agent's P(flu) hour by hour: P_j and P_i, the duration, distance,
room size, indoors/outdoors, the infector's stage, the time since the meeting
and outdoor humidity all enter as described there.

    uv run exposure/network/movement.py sim/runs/<run_id> --lambda-scale 0.110

Writes exposure/network/out/<run_id>/move.js for map.html: every agent's track,
their hourly P(flu), the campus outline, and the meetings that raised each
agent's risk most.
"""

import argparse
import base64
import csv
import gzip
import json
import math
import os
import re
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mean_field as mf  # noqa: E402

fr = mf.fr
OUTDOOR_RADIUS_M = 5.0   # outdoors, only people this close share an exhaled plume

MOVE_PARAMS = dict(mf.PARAMS, dt_h=1.0, top_k=40)   # hourly steps; map.html shows those up to "now"


class Tracks:
    """Every agent's state at every 5-min step, forward-filled from timeline_changes."""

    def __init__(self, run, ids):
        t0 = time.time()
        idx = {a: i for i, a in enumerate(ids)}
        path = os.path.join(run, "timeline_changes.csv.gz")
        if not os.path.exists(path):
            path = os.path.join(run, "timeline.csv.gz")
        cols = {k: [] for k in ("t", "a", "x", "y", "floor", "room", "loc", "indoor", "off", "act", "moving")}
        self.room_ids, self.loc_ids, self.acts = {}, {}, {}
        code = lambda d, k: -1 if not k else d.setdefault(k, len(d))
        for r in mf.read_csv(path):
            cols["t"].append(int(r["t"]))
            cols["a"].append(idx[r["agent_id"]])
            off = r["off_map"] == "True"
            cols["off"].append(off)
            cols["x"].append(float(r["x_local_m"]) if r["x_local_m"] else np.nan)
            cols["y"].append(float(r["y_local_m"]) if r["y_local_m"] else np.nan)
            cols["floor"].append(int(float(r["floor"])) if r["floor"] else 0)
            cols["room"].append(code(self.room_ids, r["room_id"]))
            cols["loc"].append(code(self.loc_ids, r["location_id"]))
            cols["indoor"].append(r["indoor"] == "True")
            cols["act"].append(code(self.acts, r["activity"]))
            cols["moving"].append(r["moving"] == "True")
        self.rows = {k: np.array(v) for k, v in cols.items()}
        t, a = self.rows["t"], self.rows["a"]
        self.T, self.N = int(t.max()) + 1, len(ids)
        # forward fill: row index of each agent's latest row at or before each step
        at = np.full((self.T, self.N), -1, dtype=np.int64)
        at[t, a] = np.arange(len(t))
        at = np.maximum.accumulate(at, axis=0)
        self.at = at
        print(f"tracks: {len(t):,} timeline rows -> {self.T} steps x {self.N} agents in {time.time() - t0:.0f} s")

    def state(self, step):
        r = self.at[step]
        ok = r >= 0
        g = lambda k, fill: np.where(ok, self.rows[k][np.maximum(r, 0)], fill)
        return {"x": g("x", np.nan), "y": g("y", np.nan), "floor": g("floor", 0), "room": g("room", -1),
                "indoor": g("indoor", False), "off": g("off", True) | ~ok}


class MovementModel(mf.Model):
    """mean_field.Model, with meetings found from the agents' tracks."""

    def _load_contacts(self):
        t0 = time.time()
        self.tracks = tr = Tracks(self.run, self.ids)
        B, Q = fr.BREATHING_RATE, fr.NEAR_FIELD_Q
        hours = self.step_min / 60
        default_room = (self.p["default_room_m2"] * fr.CEILING, fr.DEFAULT_ACH)
        room_names = sorted(tr.room_ids, key=tr.room_ids.get)
        vol = np.array([self.rooms.get(r, default_room)[0] for r in room_names] or [1.0])
        ach = np.array([self.rooms.get(r, default_room)[1] for r in room_names] or [1.0])
        per_step = [[] for _ in range(self.n_steps)]
        n_rows = 0
        iu = None
        for s in range(min(tr.T, self.n_steps * self.W)):
            st = tr.state(s)
            v = np.nonzero(~st["off"] & ~np.isnan(st["x"]))[0]
            if len(v) < 2:
                continue
            x, y, room, ind, fl = st["x"][v], st["y"][v], st["room"][v], st["indoor"][v], st["floor"][v]
            d = np.hypot(x[:, None] - x[None, :], y[:, None] - y[None, :])
            same_room = (room[:, None] == room[None, :]) & (room[:, None] >= 0)
            outdoors = (room < 0) & ~ind
            out_pair = outdoors[:, None] & outdoors[None, :] & (fl[:, None] == fl[None, :])
            in_room = same_room & ind[:, None]
            near_out = (out_pair | (same_room & ~ind[:, None])) & (d < OUTDOOR_RADIUS_M)
            mask = in_room | near_out
            if iu is None or iu[0].shape[0] != len(v) * (len(v) - 1) // 2:
                iu = np.triu_indices(len(v), 1)
            sel = mask[iu]
            ii, jj = iu[0][sel], iu[1][sel]
            if not len(ii):
                continue
            n_rows += len(ii)
            dd = np.maximum(d[ii, jj], 0.3)
            indoor = in_room[ii, jj]
            rm = room[ii]
            day = s * self.step_min // 1440
            loss = ach[np.maximum(rm, 0)] + fr.DEPOSITION + self.weather[day]["decay"]
            D = np.where(indoor,
                         B * hours * (1 / (Q * dd * dd) + 1 / (vol[np.maximum(rm, 0)] * loss)),
                         B * hours / (Q * dd * dd * fr.OUTDOOR_NEAR_DILUTION))
            a, b = v[ii], v[jj]
            lo, hi = np.minimum(a, b), np.maximum(a, b)
            per_step[s // self.W].append((lo.astype(np.int64) * self.N + hi, D, dd, indoor, rm))
        # aggregate per MF step and unordered pair
        all_codes = np.unique(np.concatenate([c for lst in per_step for c, *_ in lst])) if n_rows else np.array([], np.int64)
        self.pairs = []
        for n in range(self.n_steps):
            lst = per_step[n]
            if not lst:
                self.pairs.append(None)
                continue
            codes = np.concatenate([x[0] for x in lst])
            D = np.concatenate([x[1] for x in lst])
            dd = np.concatenate([x[2] for x in lst])
            indoor = np.concatenate([x[3] for x in lst])
            rm = np.concatenate([x[4] for x in lst])
            u, first, inv = np.unique(codes, return_index=True, return_inverse=True)
            k = len(u)
            minutes = np.bincount(inv, minlength=k) * self.step_min
            dmin = np.full(k, np.inf)
            np.minimum.at(dmin, inv, dd)
            self.pairs.append({
                "a": (u // self.N).astype(np.int32), "b": (u % self.N).astype(np.int32),
                "pid": np.searchsorted(all_codes, u),
                "D": np.bincount(inv, weights=D, minlength=k),
                "min": minutes.astype(float),
                "dist": np.bincount(inv, weights=dd, minlength=k) * self.step_min / minutes,
                "dmin": dmin,
                "room": [room_names[r] if r >= 0 else None for r in rm[first]],
                "out_min": np.bincount(inv, weights=~indoor, minlength=k) * self.step_min,
            })
        self.n_pairs = len(all_codes)
        self.n_rows, self.n_wall = n_rows, 0
        print(f"meetings from movement: {n_rows:,} pair x 5-min rows -> "
              f"{sum(len(x['D']) for x in self.pairs if x):,} pair-hours, {self.n_pairs:,} distinct pairs "
              f"in {time.time() - t0:.0f} s")


# ---------------------------------------------------------------- export for map.html
def b64(arr):
    return base64.b64encode(np.ascontiguousarray(arr).tobytes()).decode()


def lonlat_to_local(lon, lat, frame):
    lat0, lon0 = frame["origin_lat"], frame["origin_lon"]
    return ((lon - lon0) * 111320 * math.cos(math.radians(lat0)), (lat - lat0) * 110540)


def campus(run, frame):
    """Building outlines and footpaths in the local metre frame, rounded to 0.5 m."""
    out = {"buildings": [], "paths": []}
    bpath = os.path.join(run, "map", "buildings.csv")
    if os.path.exists(bpath):
        for r in mf.read_csv(bpath):
            ring = re.findall(r"(-?\d+\.\d+) (-?\d+\.\d+)", r.get("footprint_wkt") or "")
            if len(ring) < 3:
                continue
            pts = [lonlat_to_local(float(lo), float(la), frame) for lo, la in ring]
            out["buildings"].append({"id": r["location_id"], "name": r["name"], "type": r["type"],
                                     "p": [round(c * 2) / 2 for xy in pts for c in xy]})
    ppath = os.path.join(run, "map", "paths.geojson")
    if os.path.exists(ppath):
        for f in json.load(open(ppath))["features"]:
            g = f["geometry"]
            lines = [g["coordinates"]] if g["type"] == "LineString" else g["coordinates"] if g["type"] == "MultiLineString" else []
            for ln in lines:
                pts = [lonlat_to_local(lo, la, frame) for lo, la, *_ in ln]
                out["paths"].append([round(c) for xy in pts for c in xy])
    return out


def export(m, params, p_now, p_base, truth, first, top, metrics, out_path):
    tr = m.tracks
    rows = tr.rows
    order = np.lexsort((rows["t"], rows["a"]))
    a_sorted = rows["a"][order]
    starts = np.searchsorted(a_sorted, np.arange(m.N + 1))
    x = np.where(np.isnan(rows["x"]), -32768, np.round(rows["x"] * 2)).astype(np.int16)[order]
    y = np.where(np.isnan(rows["y"]), -32768, np.round(rows["y"] * 2)).astype(np.int16)[order]
    off = rows["off"][order]
    x[off], y[off] = -32768, -32768
    loc_names = sorted(tr.loc_ids, key=tr.loc_ids.get)
    bnames = {}
    bpath = os.path.join(m.run, "map", "buildings.csv")
    if os.path.exists(bpath):
        bnames = {r["location_id"]: r["name"] for r in mf.read_csv(bpath)}
    data = {
        "run_id": os.path.basename(m.run), "start": m.cfg["start"], "step_min": m.step_min,
        "dt_h": params["dt_h"], "n_steps": m.n_steps, "T": int(tr.T), "params": params,
        "ids": m.ids,
        "track": {"start": starts.tolist(), "t": b64(rows["t"][order].astype(np.uint16)),
                  "x": b64(x), "y": b64(y),
                  "loc": b64(rows["loc"][order].astype(np.int16)),
                  "act": b64(rows["act"][order].astype(np.int8)),
                  "indoor": b64(rows["indoor"][order].astype(np.uint8))},
        "locs": [bnames.get(l, l) for l in loc_names],
        "acts": sorted(tr.acts, key=tr.acts.get),
        # hourly P(flu), as the app would show it then, x 10000
        "p": b64(np.round(np.clip(p_now, 0, 1) * 10000).astype(np.uint16)),
        "p_base": b64(np.round(np.clip(p_base, 0, 1) * 10000).astype(np.uint16)),
        "truth": None if truth is None else b64(np.packbits(truth, axis=1)),
        "infected_at": {k: list(v) for k, v in first.items()},
        "evidence": {m.ids[i]: v for i, v in m.evidence.items()},
        "top": top, "metrics": metrics, "weather": m.weather,
        "campus": campus(m.run, m.cfg["local_frame"]),
    }
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        f.write("window.MOVE = ")
        json.dump(data, f, separators=(",", ":"))
        f.write(";\n")
    print(f"wrote {os.path.relpath(out_path)} ({os.path.getsize(out_path) / 1e6:.1f} MB)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run")
    ap.add_argument("--out")
    for k, v in MOVE_PARAMS.items():
        ap.add_argument("--" + k.replace("_", "-"), type=type(v), default=v)
    a = ap.parse_args()
    params = {k: getattr(a, k) for k in MOVE_PARAMS}
    run = a.run.rstrip("/")
    out = a.out or os.path.join(HERE, "out", os.path.basename(run), "move.js")

    m = MovementModel(run, params)
    p_now, p_base, truth, first, top, metrics = mf.run_all(m, params)
    mf.print_metrics(metrics, params)
    export(m, params, p_now, p_base, truth, first, top, metrics, out)


if __name__ == "__main__":
    main()
