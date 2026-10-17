"""Build a self-contained HTML animation viewer for a d2-format run folder.

    python view.py runs/<run_id> [--no-open] [--max-agents N] [--stride K] [--out file]

Reads only the run folder (timeline.parquet or timeline.csv.gz, agents_static.csv, map/*,
infections.csv, config.json) and writes <run>/viewer.html with all data embedded as compact JSON
(works from file://). Large runs are subsampled: a deterministic agent subset (--max-agents,
default 1500) and every K-th step (--stride, auto so agents x frames <= ~3M).

Encoding (decoded by campussim/viewer_template.html):
  * every timeline column except t/timestamp/agent_id/x_local_m/y_local_m is stored per agent as a
    run-length encoded sequence over frames: flat [len, value, len, value, ...] + per-agent offsets.
  * categorical columns -> dictionary codes; numeric columns -> quantized ints whose first
    differences are run-length encoded (stationary/linear stretches collapse). Null -> sentinel.
  * x_local_m / y_local_m are re-derived from lat/lon in the browser (campus-local frame).
"""
import argparse
import json
import math
import os
import re
import sys
import time
import webbrowser

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "campussim", "viewer_template.html")

TIMELINE_COLS = [
    "t", "timestamp", "agent_id", "lat", "lon", "x_local_m", "y_local_m", "floor", "location_id",
    "location_type", "room_id", "room_type", "entrance_id", "indoor", "off_map", "activity",
    "event_id", "moving", "transport_mode", "disease_state", "days_since_infection",
    "infectiousness", "symptomatic", "symptom_severity", "masked", "self_reported_status",
    "test_status", "isolating", "intervention_action",
]
# numeric columns -> quantization scale (values stored as round(v * scale))
NUMERIC = {"lat": 1e6, "lon": 1e6, "days_since_infection": 1e3, "infectiousness": 1e4,
           "symptom_severity": 1e3}
DERIVED = {"t", "timestamp", "agent_id", "x_local_m", "y_local_m"}
NULL = 2_000_000_001          # sentinel for null numeric values (fits in a JS double exactly)
DISEASE_STATES = ["S", "E", "I_pre", "I_sym", "I_asym", "R"]
TARGET_CELLS = 3_000_000
# Defaults of campussim/geo.py, used only if config.json lacks a local frame.
LAT0, LON0 = 37.418, -122.182


def log(msg):
    print(f"[view] {msg}", flush=True)


# ----------------------------------------------------------------------------- small readers
def read_csv_str(path):
    if not os.path.exists(path):
        return None
    return pd.read_csv(path, dtype=str, keep_default_na=False)


def read_json(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def to_str_series(s):
    """Render a typed column the way the d2 CSV writer would (True/False, '' for null, ints w/o .0)."""
    if s.dtype == object or pd.api.types.is_string_dtype(s):
        out = s.astype(object)
        mask = out.isna()
        out = out.where(~mask, "")
        # bool objects inside object columns
        return out.map(lambda v: v if isinstance(v, str) else ("True" if v is True else "False" if v is False else str(v)))
    if pd.api.types.is_bool_dtype(s):
        return s.map({True: "True", False: "False"}).astype(object).fillna("")
    if pd.api.types.is_float_dtype(s):
        v = s.to_numpy()
        isn = np.isnan(v)
        if np.all(np.equal(np.mod(v[~isn], 1), 0)):
            res = np.where(isn, "", np.nan_to_num(v).astype(np.int64).astype(str))
        else:
            res = np.where(isn, "", v.astype(str))
        return pd.Series(res, index=s.index, dtype=object)
    if pd.api.types.is_integer_dtype(s):
        return s.astype("Int64").astype(str).replace("<NA>", "").astype(object)
    return s.astype(str)


def wkt_rings(wkt):
    """POLYGON / MULTIPOLYGON WKT -> list of polygons, each a list of rings [[lon, lat], ...]."""
    if not isinstance(wkt, str) or not wkt.strip():
        return []
    w = wkt.strip().upper()
    polys = []
    if w.startswith("MULTIPOLYGON"):
        body = wkt[wkt.index("(") + 1: wkt.rindex(")")]
        parts = re.findall(r"\(\s*(\(.*?\)(?:\s*,\s*\(.*?\))*)\s*\)", body)
    elif w.startswith("POLYGON"):
        parts = [wkt[wkt.index("(") + 1: wkt.rindex(")")]]
    else:
        return []
    for p in parts:
        rings = []
        for ring in re.findall(r"\(([^()]*)\)", p):
            pts = []
            for pair in ring.split(","):
                xy = pair.split()
                if len(xy) >= 2:
                    pts.append([float(xy[0]), float(xy[1])])
            if len(pts) >= 3:
                rings.append(pts)
        if rings:
            polys.append(rings)
    return polys


def q_ring(ring, scale=1e6):
    """Quantize a ring to micro-degree ints, first point absolute then deltas: [x0,y0,dx,dy,...]."""
    a = np.round(np.asarray(ring, dtype=float) * scale).astype(np.int64)
    d = a.copy()
    d[1:] = a[1:] - a[:-1]
    return d.ravel().tolist()


# ----------------------------------------------------------------------------- map layers
def build_map(run):
    m = {}
    bdf = read_csv_str(os.path.join(run, "map", "buildings.csv"))
    rdf = read_csv_str(os.path.join(run, "map", "rooms.csv"))
    rooms = []
    room_bbox = {}
    if rdf is not None:
        for r in rdf.itertuples(index=False):
            polys = wkt_rings(getattr(r, "polygon_wkt", ""))
            ring = polys[0][0] if polys else None
            rooms.append([r.room_id, r.location_id, r.floor, r.room_type, r.capacity,
                          q_ring(ring) if ring else []])
            if ring:
                a = np.asarray(ring)
                bb = room_bbox.get(r.location_id)
                lo, hi = a.min(0), a.max(0)
                room_bbox[r.location_id] = (np.minimum(bb[0], lo), np.maximum(bb[1], hi)) if bb else (lo, hi)
    elif os.path.exists(os.path.join(run, "map", "rooms.geojson")):
        gj = read_json(os.path.join(run, "map", "rooms.geojson"))
        for f in gj.get("features", []):
            p = f.get("properties", {})
            g = f.get("geometry") or {}
            ring = g.get("coordinates", [[]])[0] if g.get("type") == "Polygon" else None
            rooms.append([p.get("room_id", ""), p.get("location_id", ""), str(p.get("floor", "")),
                          p.get("room_type", ""), str(p.get("capacity", "")), q_ring(ring) if ring else []])
    m["rooms"] = rooms

    blds = []
    bld_cols = []
    if bdf is not None:
        has_fp = "footprint_wkt" in bdf.columns
        info_cols = [c for c in bdf.columns if c != "footprint_wkt"]
        bld_cols = info_cols
        for row in bdf.itertuples(index=False):
            d = row._asdict()
            polys = wkt_rings(d.get("footprint_wkt")) if has_fp else []
            geom = [[q_ring(r) for r in poly] for poly in polys]
            if not geom and d["location_id"] in room_bbox:
                lo, hi = room_bbox[d["location_id"]]
                pad = 2e-5
                ring = [[lo[0] - pad, lo[1] - pad], [hi[0] + pad, lo[1] - pad], [hi[0] + pad, hi[1] + pad],
                        [lo[0] - pad, hi[1] + pad], [lo[0] - pad, lo[1] - pad]]
                geom = [[q_ring(ring)]]
            blds.append({"p": [d[c] for c in info_cols], "g": geom})
    m["buildings"] = blds
    m["building_cols"] = bld_cols

    edf = read_csv_str(os.path.join(run, "map", "entrances.csv"))
    if edf is not None and len(edf):
        m["entrances"] = [[r.entrance_id, r.building_id, round(float(r.lat), 6), round(float(r.lon), 6), r.source]
                          for r in edf.itertuples(index=False) if r.lat and r.lon]
    xdf = read_csv_str(os.path.join(run, "map", "entry_points.csv"))
    if xdf is not None and len(xdf) and {"lat", "lon"} <= set(xdf.columns):
        name_col = "name" if "name" in xdf.columns else xdf.columns[0]
        id_col = "entry_id" if "entry_id" in xdf.columns else xdf.columns[0]
        m["entry_points"] = [[r[id_col], r[name_col], round(float(r["lat"]), 6), round(float(r["lon"]), 6)]
                             for _, r in xdf.iterrows() if r["lat"] and r["lon"]]
    pth = os.path.join(run, "map", "paths.geojson")
    if os.path.exists(pth):
        gj = read_json(pth)
        lines = []
        for f in gj.get("features", []):
            g = f.get("geometry") or {}
            hw = (f.get("properties") or {}).get("highway") or ""
            if g.get("type") == "LineString":
                parts = [g["coordinates"]]
            elif g.get("type") == "MultiLineString":
                parts = g["coordinates"]
            else:
                continue
            for c in parts:
                if len(c) >= 2:
                    lines.append([hw, q_ring([pt[:2] for pt in c])])
        m["paths"] = lines
    return m


# ----------------------------------------------------------------------------- timeline
def timeline_columns(run):
    pq = os.path.join(run, "timeline.parquet")
    if os.path.exists(pq):
        import pyarrow.parquet as pqm
        return "parquet", pq, list(pqm.ParquetFile(pq).schema_arrow.names)
    csv = os.path.join(run, "timeline.csv.gz")
    if not os.path.exists(csv):
        csv = os.path.join(run, "timeline.csv")
    if not os.path.exists(csv):
        sys.exit(f"no timeline.parquet / timeline.csv.gz in {run}")
    return "csv", csv, list(pd.read_csv(csv, nrows=0).columns)


def state_counts_from(t, st, n_steps):
    """Full-population disease-state counts per step: (n_steps, 6) int array."""
    code = pd.Categorical(st, categories=DISEASE_STATES).codes.astype(np.int64)
    ok = (code >= 0) & (t >= 0) & (t < n_steps)
    return np.bincount(t[ok] * 6 + code[ok], minlength=n_steps * 6).reshape(n_steps, 6)


def load_timeline(kind, path, cols, sel_ids, stride, n_steps):
    """Return (df of selected agents' rows at t % stride == 0, all columns as raw values,
    full-population per-step state counts)."""
    sel = set(sel_ids)
    if kind == "parquet":
        import pyarrow.parquet as pqm
        import pyarrow.compute as pc
        pf = pqm.ParquetFile(path)
        counts = np.zeros((n_steps, 6), np.int64)
        parts = []
        sel_arr = None
        import pyarrow as pa
        sel_arr = pa.array(sorted(sel))
        for rg in range(pf.num_row_groups):
            tb = pf.read_row_group(rg)
            t = tb.column("t").to_numpy().astype(np.int64)
            st = tb.column("disease_state").to_pandas().astype(str).to_numpy()
            counts += state_counts_from(t, st, n_steps)
            mask = pc.and_(pc.is_in(tb.column("agent_id").cast(pa.string()), value_set=sel_arr),
                           pa.array((t % stride) == 0))
            sub = tb.filter(mask)
            if sub.num_rows:
                parts.append(sub.to_pandas())
        df = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame(columns=cols)
        return df, counts
    counts = np.zeros((n_steps, 6), np.int64)
    parts = []
    for ch in pd.read_csv(path, dtype=str, keep_default_na=False, chunksize=1_000_000):
        t = ch["t"].astype(np.int64).to_numpy()
        counts += state_counts_from(t, ch["disease_state"].to_numpy(), n_steps)
        keep = ch["agent_id"].isin(sel).to_numpy() & ((t % stride) == 0)
        if keep.any():
            parts.append(ch[keep])
    df = pd.concat(parts, ignore_index=True) if parts else pd.DataFrame(columns=cols)
    return df, counts


def rle(M):
    """Run-length encode each row of int matrix M (K, F). Returns flat [len, val, ...] (int64)
    and per-row offsets into the run list (K+1)."""
    K, F = M.shape
    change = np.ones((K, F), bool)
    if F > 1:
        change[:, 1:] = M[:, 1:] != M[:, :-1]
    flat_change = change.ravel()
    starts = np.flatnonzero(flat_change)
    vals = M.ravel()[starts]
    lens = np.diff(np.append(starts, K * F))
    out = np.empty(2 * len(starts), np.int64)
    out[0::2] = lens
    out[1::2] = vals
    offs = np.concatenate([[0], np.cumsum(change.sum(1))]).astype(np.int64)
    return out, offs


def ints_json(a):
    return "[" + ",".join(map(str, np.asarray(a).tolist())) + "]"


def encode(run, max_agents=1500, stride=None, seed=0):
    t0 = time.time()
    cfg = read_json(os.path.join(run, "config.json"))
    ast = read_csv_str(os.path.join(run, "agents_static.csv"))
    kind, path, cols = timeline_columns(run)
    log(f"timeline: {kind} {os.path.basename(path)}")

    # --- agents + steps
    if ast is not None and len(ast):
        all_ids = ast["agent_id"].tolist()
    else:
        all_ids = None
    step_min = float(cfg.get("step_min") or 5)
    n_steps = None
    if cfg.get("days"):
        n_steps = int(round(float(cfg["days"]) * 1440 / step_min))
    if all_ids is None or n_steps is None:
        if kind == "parquet":
            import pyarrow.parquet as pqm
            tb = pqm.read_table(path, columns=["t", "agent_id"])
            tt = tb.column("t").to_numpy()
            ids = tb.column("agent_id").to_pandas().astype(str)
        else:
            tmp = pd.read_csv(path, usecols=["t", "agent_id"], dtype={"agent_id": str})
            tt, ids = tmp["t"].to_numpy(), tmp["agent_id"]
        n_steps = n_steps or int(tt.max()) + 1
        all_ids = all_ids or sorted(ids.unique().tolist())
    N = len(all_ids)
    K = min(N, max_agents) if max_agents and max_agents > 0 else N
    if K < N:
        rng = np.random.default_rng(seed)
        idx = np.sort(rng.choice(N, K, replace=False))
        sel_ids = [all_ids[i] for i in idx]
    else:
        sel_ids = list(all_ids)
    if not stride:
        stride = max(1, math.ceil(K * n_steps / TARGET_CELLS))
    frames_t = np.arange(0, n_steps, stride, dtype=np.int64)
    F = len(frames_t)
    log(f"agents {K}/{N}, steps {n_steps}, stride {stride} -> {F} frames ({K * F:,} cells)")

    df, counts = load_timeline(kind, path, cols, sel_ids, stride, n_steps)
    log(f"loaded {len(df):,} rows in {time.time() - t0:.1f}s")

    aidx = {a: i for i, a in enumerate(sel_ids)}
    ai = df["agent_id"].astype(str).map(aidx).to_numpy()
    ti = pd.to_numeric(df["t"]).to_numpy().astype(np.int64)
    fi = ti // stride
    ok = ~pd.isna(ai) & (fi >= 0) & (fi < F)
    ai = ai[ok].astype(np.int64)
    fi = fi[ok]
    df = df[ok]
    flat = ai * F + fi
    present = np.zeros(K * F, bool)
    present[flat] = True
    if not present.all():
        log(f"warning: {int((~present).sum())} agent-frames missing (shown as off-map)")

    # timestamps per frame
    ts = [""] * F
    if "timestamp" in df.columns and len(df):
        tsd = pd.Series(to_str_series(df["timestamp"]).to_numpy(), index=fi).groupby(level=0).first()
        for f, v in tsd.items():
            ts[int(f)] = v
    start = cfg.get("start")
    if start and any(v == "" for v in ts):
        base = pd.Timestamp(start)
        for f in range(F):
            if not ts[f]:
                ts[f] = (base + pd.Timedelta(minutes=float(frames_t[f]) * step_min)).strftime("%Y-%m-%dT%H:%M:%S")

    enc_cols = []
    for c in cols:
        if c in DERIVED and c in TIMELINE_COLS:
            enc_cols.append({"name": c, "kind": "derived"})
            continue
        s = df[c]
        if c in NUMERIC or (c not in TIMELINE_COLS and _is_numeric(s)):
            scale = NUMERIC.get(c, 1e4)
            v = pd.to_numeric(s.replace("", np.nan) if s.dtype == object else s, errors="coerce").to_numpy(float)
            q = np.where(np.isnan(v), NULL, np.round(v * scale)).astype(np.int64)
            M = np.full(K * F, NULL, np.int64)
            M[flat] = q
            M = M.reshape(K, F)
            if c in ("lat", "lon"):
                # forward/back fill nulls so deltas stay small; nulls tracked by the 'posnull' mask
                M = _ffill_null(M)
            D = M.copy()
            D[:, 1:] = M[:, 1:] - M[:, :-1]
            runs, offs = rle(D)
            enc_cols.append({"name": c, "kind": "num", "scale": scale, "runs": runs, "offs": offs})
        else:
            sv = to_str_series(s).to_numpy(dtype=object)
            codes, uniq = pd.factorize(sv, sort=True)
            uniq = [str(u) for u in uniq]
            if "" not in uniq:
                uniq.append("")
            miss = uniq.index("")
            if c == "off_map" and "True" not in uniq:
                uniq.append("True")
            if c == "off_map":
                miss = uniq.index("True")
            M = np.full(K * F, miss, np.int64)
            M[flat] = codes
            runs, offs = rle(M.reshape(K, F))
            enc_cols.append({"name": c, "kind": "cat", "dict": uniq, "runs": runs, "offs": offs})

    # null mask for positions (lat null)
    if "lat" in df.columns:
        v = pd.to_numeric(df["lat"].replace("", np.nan) if df["lat"].dtype == object else df["lat"],
                          errors="coerce").to_numpy(float)
        pn = np.ones(K * F, np.int64)
        pn[flat] = np.isnan(v).astype(np.int64)
        pn_runs, pn_offs = rle(pn.reshape(K, F))
    else:
        pn_runs, pn_offs = rle(np.ones((K, F), np.int64))

    # hour-of-day occupancy by location_type (sample, scaled to population)
    occ = None
    if "location_type" in df.columns:
        hours = pd.to_datetime(pd.Series(ts)).dt.hour.to_numpy()
        lt = to_str_series(df["location_type"]).to_numpy(dtype=object)
        om = to_str_series(df["off_map"]).to_numpy(dtype=object) if "off_map" in df.columns else np.array(["False"] * len(df))
        keep = (lt != "") & (om != "True")
        g = pd.DataFrame({"h": hours[fi[keep]], "lt": lt[keep]}).value_counts().reset_index(name="n")
        frames_per_hour = np.bincount(hours, minlength=24).astype(float)
        scale = N / max(K, 1)
        types = sorted(g["lt"].unique().tolist())
        series = {}
        for typ in types:
            arr = np.zeros(24)
            sub = g[g["lt"] == typ]
            arr[sub["h"].to_numpy()] = sub["n"].to_numpy()
            series[typ] = [round(float(x), 1) for x in arr / np.maximum(frames_per_hour, 1) * scale]
        occ = series

    # agents_static rows for the sample + infections involving them
    static_cols, static_rows = [], []
    if ast is not None:
        static_cols = list(ast.columns)
        sidx = ast.set_index("agent_id", drop=False)
        static_rows = [sidx.loc[a].tolist() if a in sidx.index else [a] + [""] * (len(static_cols) - 1)
                       for a in sel_ids]
    inf = read_csv_str(os.path.join(run, "infections.csv"))
    inf_cols, inf_rows = [], []
    if inf is not None and len(inf):
        inf_cols = list(inf.columns)
        sel = set(sel_ids)
        m = inf["infectee_id"].isin(sel) | inf["infector_id"].isin(sel)
        inf_rows = inf[m].values.tolist()

    meta = {
        "run_id": cfg.get("run_id") or os.path.basename(os.path.abspath(run)),
        "disease": cfg.get("disease", ""), "intervention": cfg.get("intervention", ""),
        "n_agents": N, "n_shown": K, "n_steps": n_steps, "stride": stride, "step_min": step_min,
        "start": cfg.get("start", ts[0] if ts else ""), "frames_t": frames_t.tolist(),
        "timestamps": ts, "columns": cols,
        "local_frame": {"origin_lat": (cfg.get("local_frame") or {}).get("origin_lat", LAT0),
                        "origin_lon": (cfg.get("local_frame") or {}).get("origin_lon", LON0)},
        "states": DISEASE_STATES,
        "summary": {k: v for k, v in read_json(os.path.join(run, "summary.json")).items()
                    if not isinstance(v, (list, dict)) or k in ("infections_by_route", "daily_incidence")},
    }
    log(f"encoded in {time.time() - t0:.1f}s")
    return {
        "meta": meta, "agents": sel_ids, "enc_cols": enc_cols, "posnull": (pn_runs, pn_offs),
        "counts": counts, "occ": occ, "static_cols": static_cols, "static_rows": static_rows,
        "inf_cols": inf_cols, "inf_rows": inf_rows,
    }


def _is_numeric(s):
    if s.dtype != object:
        return pd.api.types.is_numeric_dtype(s) and not pd.api.types.is_bool_dtype(s)
    v = pd.to_numeric(s.replace("", np.nan), errors="coerce")
    return v.notna().sum() > 0 and v.notna().sum() == (s != "").sum() and s.str.contains(r"\.", regex=True).any()


def _ffill_null(M):
    K, F = M.shape
    isn = M == NULL
    if not isn.any():
        return M
    idx = np.where(~isn, np.arange(F)[None, :], 0)
    np.maximum.accumulate(idx, axis=1, out=idx)
    out = M[np.arange(K)[:, None], idx]
    # leading nulls: back-fill with first valid value (or 0 for all-null rows)
    first = np.where((~isn).any(1), np.argmax(~isn, axis=1), -1)
    for k in np.flatnonzero(out[:, 0] == NULL):
        out[k, out[k] == NULL] = M[k, first[k]] if first[k] >= 0 else 0
    return out


def to_json(enc, mapdata):
    """Serialize to compact JSON (big int arrays written directly)."""
    parts = ['{"meta":', json.dumps(enc["meta"], separators=(",", ":")),
             ',"agents":', json.dumps(enc["agents"], separators=(",", ":")),
             ',"cols":[']
    for i, c in enumerate(enc["enc_cols"]):
        if i:
            parts.append(",")
        head = {k: v for k, v in c.items() if k not in ("runs", "offs")}
        h = json.dumps(head, separators=(",", ":"))
        if "runs" in c:
            parts.append(h[:-1] + ',"runs":' + ints_json(c["runs"]) + ',"offs":' + ints_json(c["offs"]) + "}")
        else:
            parts.append(h)
    parts.append('],"posnull":{"runs":' + ints_json(enc["posnull"][0]) + ',"offs":' + ints_json(enc["posnull"][1]) + "}")
    parts.append(',"counts":' + ints_json(enc["counts"].ravel()))
    rest = {"occ": enc["occ"], "static_cols": enc["static_cols"], "static_rows": enc["static_rows"],
            "inf_cols": enc["inf_cols"], "inf_rows": enc["inf_rows"], "map": mapdata}
    for k, v in rest.items():
        parts.append(f',"{k}":' + json.dumps(v, separators=(",", ":")))
    parts.append("}")
    return "".join(parts).replace("</", "<\\/")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="run folder (runs/<run_id>)")
    ap.add_argument("--no-open", action="store_true", help="do not open a browser")
    ap.add_argument("--max-agents", type=int, default=1500, help="max agents embedded (0 = all)")
    ap.add_argument("--stride", type=int, default=0, help="keep every K-th step (default auto)")
    ap.add_argument("--seed", type=int, default=0, help="seed for the agent subsample")
    ap.add_argument("--out", default=None, help="output html (default <run>/viewer.html)")
    a = ap.parse_args(argv)
    run = a.run.rstrip("/")
    if not os.path.isdir(run):
        sys.exit(f"not a run folder: {run}")
    t0 = time.time()
    enc = encode(run, a.max_agents, a.stride or None, a.seed)
    mapdata = build_map(run)
    payload = to_json(enc, mapdata)
    with open(TEMPLATE, encoding="utf-8") as f:
        html = f.read()
    html = html.replace("__RUN_TITLE__", str(enc["meta"]["run_id"]))
    html = html.replace("/*__DATA__*/", payload)
    out = a.out or os.path.join(run, "viewer.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(html)
    log(f"wrote {out} ({os.path.getsize(out) / 1e6:.2f} MB, data {len(payload) / 1e6:.2f} MB) in {time.time() - t0:.1f}s")
    if not a.no_open:
        webbrowser.open("file://" + os.path.abspath(out))
    return out


if __name__ == "__main__":
    main()
