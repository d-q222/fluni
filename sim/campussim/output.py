"""Run-folder writer (d2 output format) + timeline frame builder.

CSV text is byte-identical to what Python's csv module writes for the d2 mock rows
(`sim/make_mock_run.py`): `\\r\\n` line ends, QUOTE_MINIMAL, booleans True/False,
None/NaN -> "", floats = str(round(x, k)) (so 0.0, 1684.44, 6e-05), ints without ".0".
Values are formatted per *unique* value (pd.factorize) and rows joined with str.join, which keeps
30M timeline rows to a few minutes. .csv.gz = one standard gzip member (mtime=0, FNAME like
gzip.GzipFile) deflated in parallel pigz-style (fixed-size blocks, 32 KiB dictionary priming,
sync flush), so bytes depend only on content + gzip_level + gzip_block_mb.
"""
import json
import math
import struct
import threading
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pandas as pd

from . import codes, geo

DEFAULTS = {
    "by_agent": True, "parquet": True, "by_agent_max_open": 512, "by_agent_buffer_mb": 512,
    "gzip_level": 6, "gzip_threads": 8, "gzip_block_mb": 8, "chunk_rows": 262144,
    "parquet_compression": "zstd",
}

TIMELINE_COLUMNS = [
    "t", "timestamp", "agent_id", "lat", "lon", "x_local_m", "y_local_m", "floor", "location_id",
    "location_type", "room_id", "room_type", "entrance_id", "indoor", "off_map", "activity", "event_id",
    "moving", "transport_mode", "disease_state", "days_since_infection", "infectiousness", "symptomatic",
    "symptom_severity", "masked", "self_reported_status", "test_status", "isolating", "intervention_action"]
CONTACT_COLUMNS = ["t", "agent_a", "agent_b", "distance_m", "distance_tier", "duration_s", "location_id",
                   "room_id", "indoor"]
EXPOSURE_COLUMNS = ["t", "room_id", "occupants", "infectious_occupants", "quanta_concentration"]

# Column-name formatting rules (all tables). kind: "int", "bool", "str", "float" (str(x)), or an int k
# = decimals (str(round(x, k))).
ROUND_RULES = {"lat": 7, "lon": 7, "x_local_m": 2, "y_local_m": 2, "distance_m": 2,
               "days_since_infection": 3, "infectiousness": 4, "symptom_severity": 3,
               "quanta_concentration": 6}
INT_COLUMNS = {"t", "floor", "distance_tier", "duration_s", "occupants", "infectious_occupants"}
BOOL_COLUMNS = {"indoor", "off_map", "moving", "symptomatic", "masked", "isolating"}

# Fixed stream schemas: (column, kind, arrow type name)
STREAM_SCHEMAS = {
    "timeline": [(c, ROUND_RULES.get(c, "int" if c in INT_COLUMNS else "bool" if c in BOOL_COLUMNS else "str"),
                  {"t": "int32", "floor": "int16"}.get(c, "float64" if c in ROUND_RULES else
                                                       "bool" if c in BOOL_COLUMNS else "string"))
                 for c in TIMELINE_COLUMNS],
    "contacts": [("t", "int", "int32"), ("agent_a", "str", "string"), ("agent_b", "str", "string"),
                 ("distance_m", 2, "float64"), ("distance_tier", "int", "int8"), ("duration_s", "int", "int32"),
                 ("location_id", "str", "string"), ("room_id", "str", "string"), ("indoor", "bool", "bool")],
    "room_exposure": [("t", "int", "int32"), ("room_id", "str", "string"), ("occupants", "int", "int32"),
                      ("infectious_occupants", "int", "int32"), ("quanta_concentration", 6, "float64")],
}
STREAM_SCHEMAS["timeline_changes"] = STREAM_SCHEMAS["timeline"]
STREAM_SORT = {"timeline": ["t", "agent_id"], "timeline_changes": ["t", "agent_id"],
               "contacts": ["t", "agent_a", "agent_b"], "room_exposure": ["t", "room_id"]}
NO_PARQUET_STREAMS = {"timeline_changes"}  # docs/timeline-changes-format.md asks for csv.gz only
# docs/timeline-changes-format.md: a row is kept when any of these differ from the agent's previous row
CHANGE_COLUMNS = ["lat", "lon", "location_id", "room_id", "floor", "indoor", "off_map", "moving",
                  "disease_state", "self_reported_status", "test_status", "isolating", "activity"]
TABLE_SORT = {"infections.csv": ["t", "infectee_id"], "reports_tests.csv": ["t", "agent_id"]}

_EMPTY = np.array([""], dtype=object)
_BOOL_STR = np.array(["False", "True"], dtype=object)
_QUOTE_CHARS = (",", '"', "\r", "\n")


# ----------------------------------------------------------------------------- value formatting
def _needs_quote(s):
    return any(c in s for c in _QUOTE_CHARS)


def _quote(s):
    return '"' + s.replace('"', '""') + '"' if _needs_quote(s) else s


def _str_of(v, k=None):
    """csv-module text of one python value (k = round decimals for floats)."""
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    if isinstance(v, (bool, np.bool_)):
        return "True" if v else "False"
    if isinstance(v, (float, np.floating)):
        v = float(v)
        if math.isnan(v):
            return ""
        if k == "int":
            return str(int(v))
        if isinstance(k, int):
            v = round(v, k) + 0.0  # + 0.0 turns -0.0 into 0.0
        return repr(v)
    if isinstance(v, (int, np.integer)):
        return str(int(v))
    try:
        if pd.isna(v):
            return ""
    except (TypeError, ValueError):
        pass
    return str(v)


def _round_val(v, k):
    """Typed (parquet) value matching the CSV text."""
    if v is None:
        return np.nan
    v = float(v)
    if math.isnan(v):
        return v
    return round(v, k) + 0.0 if isinstance(k, int) else v


def format_column(values, kind=None, want_typed=False):
    """1-D values -> (object array of csv field strings, typed array or None).
    kind: None (infer from dtype), "int", "bool", "str", "float", or int decimals."""
    a = np.asarray(values) if not isinstance(values, pd.Series) else values.to_numpy()
    n = len(a)
    if n == 0:
        return np.zeros(0, dtype=object), (np.zeros(0) if want_typed else None)
    if a.dtype == bool:
        return _BOOL_STR[a.view(np.uint8)], (a if want_typed else None)
    if a.dtype.kind in "US":
        a = a.astype(object)
    codes_, uniq = pd.factorize(a, use_na_sentinel=True)
    uniq = uniq.tolist() if not isinstance(uniq, list) else uniq
    if a.dtype.kind == "f" and kind is None:
        kind = "float"
    if a.dtype.kind == "f" and kind == "str":
        kind = "float"
    strs = [_quote(_str_of(u, kind)) for u in uniq]
    table = np.array(strs + [""], dtype=object)
    out = table[codes_]
    typed = None
    if want_typed:
        if isinstance(kind, int) or kind == "float":
            if a.dtype.kind in "fiu":
                tv = np.array([_round_val(u, kind) for u in uniq] + [np.nan], dtype=np.float64)
            else:
                tv = np.array([_round_val(_to_float(u), kind) for u in uniq] + [np.nan], dtype=np.float64)
            typed = tv[codes_]
        elif kind == "int":
            tv = np.array([_to_float(u) for u in uniq] + [np.nan], dtype=np.float64)
            typed = tv[codes_]
        elif kind == "bool":
            tv = np.array([_to_bool(u) for u in uniq] + [None], dtype=object)
            typed = tv[codes_]
        else:
            typed = out if not any(_needs_quote(_str_of(u)) for u in uniq) else \
                np.array([_str_of(u) for u in uniq] + [""], dtype=object)[codes_]
    return out, typed


def _to_float(u):
    if isinstance(u, str):
        try:
            return float(u) if u != "" else np.nan
        except ValueError:
            return np.nan
    if u is None:
        return np.nan
    return float(u)


def _to_bool(u):
    if isinstance(u, str):
        return {"True": True, "False": False, "true": True, "false": False}.get(u)
    if u is None:
        return None
    try:
        if isinstance(u, float) and math.isnan(u):
            return None
    except TypeError:
        pass
    return bool(u)


def _infer_kind(name, series):
    if name in ROUND_RULES:
        return ROUND_RULES[name]
    if name in INT_COLUMNS:
        return "int"
    return None


def csv_lines(df, kinds=None):
    """DataFrame -> list of csv row strings (no line terminator), header excluded."""
    cols = []
    for c in df.columns:
        k = (kinds or {}).get(c, _infer_kind(c, df[c]))
        cols.append(format_column(df[c], k)[0].tolist())
    if not cols:
        return []
    return list(map(",".join, zip(*cols)))


def _header(columns):
    return ",".join(_quote(str(c)) for c in columns)


# ----------------------------------------------------------------------------- parallel gzip
class GzipStream:
    """Deterministic single-member gzip writer; deflate runs in worker threads (zlib drops the GIL).
    Equivalent decompressed bytes to gzip.GzipFile(path, 'wb', mtime=0)."""

    def __init__(self, path, level=6, threads=8, block_bytes=8 << 20, pool=None):
        self.path = Path(path)
        self.f = open(self.path, "wb")
        self.level, self.block = level, block_bytes
        self.pool = pool or ThreadPoolExecutor(max_workers=max(1, threads))
        self._own_pool = pool is None
        self.max_pending = max(2, 2 * max(1, threads))
        fname = self.path.name[:-3] if self.path.name.endswith(".gz") else self.path.name
        xfl = b"\002" if level == 9 else (b"\004" if level == 1 else b"\000")
        self.f.write(b"\037\213\010\010" + struct.pack("<L", 0) + xfl + b"\377" +
                     fname.encode("latin-1") + b"\000")
        self.crc, self.size = 0, 0
        self.buf = bytearray()
        self.prev_tail = b""
        self.pending = []

    @staticmethod
    def _deflate(data, zdict, level):
        c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, zlib.Z_DEFAULT_STRATEGY, zdict=zdict) \
            if zdict else zlib.compressobj(level, zlib.DEFLATED, -15, 9)
        return c.compress(data) + c.flush(zlib.Z_SYNC_FLUSH)

    def _submit(self, data):
        self.crc = zlib.crc32(data, self.crc)
        self.size += len(data)
        self.pending.append(self.pool.submit(self._deflate, data, self.prev_tail, self.level))
        self.prev_tail = data[-32768:]
        while len(self.pending) > self.max_pending:
            self.f.write(self.pending.pop(0).result())

    def write(self, data: bytes):
        self.buf += data
        while len(self.buf) >= self.block:
            chunk = bytes(self.buf[:self.block])
            del self.buf[:self.block]
            self._submit(chunk)

    def close(self):
        if self.f is None:
            return
        if self.buf:
            self._submit(bytes(self.buf))
            self.buf = bytearray()
        for fu in self.pending:
            self.f.write(fu.result())
        self.pending = []
        self.f.write(b"\003\000")  # empty final fixed-Huffman block
        self.f.write(struct.pack("<LL", self.crc & 0xFFFFFFFF, self.size & 0xFFFFFFFF))
        self.f.close()
        self.f = None
        if self._own_pool:
            self.pool.shutdown()


# ----------------------------------------------------------------------------- by-agent files
class ByAgentWriter:
    """timeline_by_agent/<agent_id>.csv: open handles for small N, else memory buffer + append."""

    def __init__(self, dirpath, header, max_open=512, buffer_bytes=512 << 20):
        self.dir = Path(dirpath)
        self.dir.mkdir(parents=True, exist_ok=True)
        for f in self.dir.glob("*.csv"):  # stale files from a previous run in the same folder
            f.unlink()
        self.header = header + "\r\n"
        self.max_open, self.buffer_bytes = max_open, buffer_bytes
        self.handles = {}
        self.created = set()
        self.buf, self.buf_bytes = {}, 0
        self.mode_open = None

    def write_groups(self, groups):
        """groups: list of (agent_id, text) in agent order; text already '\\r\\n'-terminated."""
        if self.mode_open is None:
            self.mode_open = len(groups) <= self.max_open
        if self.mode_open and len(self.handles) + sum(1 for a, _ in groups if a not in self.handles) > self.max_open:
            self._close_handles()
            self.mode_open = False
        if self.mode_open:
            for aid, text in groups:
                h = self.handles.get(aid)
                if h is None:
                    h = self.handles[aid] = open(self.dir / f"{aid}.csv", "w", newline="", encoding="utf-8")
                    h.write(self.header)
                    self.created.add(aid)
                h.write(text)
        else:
            for aid, text in groups:
                self.buf.setdefault(aid, []).append(text)
                self.buf_bytes += len(text)
            if self.buf_bytes >= self.buffer_bytes:
                self.flush()

    def flush(self):
        for aid in sorted(self.buf):
            mode = "a" if aid in self.created else "w"
            with open(self.dir / f"{aid}.csv", mode, newline="", encoding="utf-8") as h:
                if mode == "w":
                    h.write(self.header)
                    self.created.add(aid)
                h.write("".join(self.buf[aid]))
        self.buf, self.buf_bytes = {}, 0

    def _close_handles(self):
        for h in self.handles.values():
            h.close()
        self.handles = {}

    def close(self):
        self._close_handles()
        self.flush()


# ----------------------------------------------------------------------------- run writer
def _pa_type(ty):
    import pyarrow as pa
    return pa.bool_() if ty == "bool" else getattr(pa, ty)()


def _json_default(o):
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.floating):
        return float(o)
    if isinstance(o, np.bool_):
        return bool(o)
    if isinstance(o, np.ndarray):
        return o.tolist()
    if isinstance(o, (set, frozenset)):
        return sorted(o)
    if isinstance(o, Path):
        return str(o)
    raise TypeError(f"not JSON serializable: {type(o)}")


def _is_sorted(df, keys):
    if len(df) < 2:
        return True
    eq = np.ones(len(df) - 1, dtype=bool)
    for k in keys:
        a = df[k].to_numpy()
        lt, same = a[:-1] < a[1:], a[:-1] == a[1:]
        if np.any(eq & ~lt & ~same):
            return False
        eq &= same
    return True


class RunWriter:
    def __init__(self, run_dir, cfg):
        self.dir = Path(run_dir)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.cfg = cfg
        self.ocfg = {**DEFAULTS, **(cfg.get("output") or {})}
        self.streams = {}
        self._pool = ThreadPoolExecutor(max_workers=max(1, int(self.ocfg["gzip_threads"])))
        self.by_agent = None

    # -- json
    def write_json(self, name, obj):
        """indent 2, keys in the order given (d2 order), no trailing newline (like the mock)."""
        p = self.dir / name
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "w") as f:
            json.dump(obj, f, indent=2, default=_json_default)

    def write_config(self, cfg, run_id, campus_version, code_version, archetype_fractions):
        rc = cfg["run"]
        start = str(rc.get("start_date", "2026-01-05"))
        if "T" not in start:
            start += "T00:00:00"
        obj = {
            "run_id": run_id, "seed": rc["seed"], "n_agents": rc["n_agents"], "days": rc["days"],
            "step_min": rc["step_min"], "start": start,
            "disease": cfg.get("disease", {}).get("preset", ""), "intervention": rc.get("intervention", "none"),
            "archetype_fractions": archetype_fractions, "map_version": campus_version,
            "code_version": code_version,
            "local_frame": {"origin_lat": geo.LAT0, "origin_lon": geo.LON0, "units": "m", "x": "east", "y": "north"},
            "distance_tiers": {"1": "<1 m", "2": "1-2 m", "3": "2-5 m", "4": "same room, >=5 m"},
            "params": cfg,
        }
        self.write_json("config.json", obj)

    # -- static tables
    def write_table(self, rel_path, df, parquet=False, gz=False, kinds=None):
        """Deterministic csv (gz: + .gz, mtime=0) of df; optional parquet mirror next to it."""
        p = self.dir / rel_path
        p.parent.mkdir(parents=True, exist_ok=True)
        keys = TABLE_SORT.get(Path(rel_path).name)
        if keys and all(k in df.columns for k in keys) and not _is_sorted(df, keys):
            df = df.sort_values(keys, kind="stable")
        text = _header(df.columns) + "\r\n" + "".join(s + "\r\n" for s in csv_lines(df, kinds))
        data = text.encode("utf-8")
        if gz or str(rel_path).endswith(".gz"):
            if not str(p).endswith(".gz"):
                p = p.with_name(p.name + ".gz")
            g = GzipStream(p, self.ocfg["gzip_level"], pool=self._pool,
                           block_bytes=int(self.ocfg["gzip_block_mb"] * (1 << 20)))
            g.write(data)
            g.close()
        else:
            with open(p, "wb") as f:
                f.write(data)
        if parquet and self.ocfg["parquet"]:
            import pyarrow as pa
            import pyarrow.parquet as pq
            stem = p.name.split(".")[0]
            pq.write_table(pa.Table.from_pandas(df, preserve_index=False).replace_schema_metadata(None),
                           p.with_name(stem + ".parquet"), compression=self.ocfg["parquet_compression"])

    # -- streams
    def open_stream(self, name, columns_schema=None):
        """columns_schema: optional [(column, kind, arrow_type)] (default STREAM_SCHEMAS[name])."""
        schema = columns_schema or STREAM_SCHEMAS[name]
        st = {"schema": schema, "rows": 0}
        st["gz"] = GzipStream(self.dir / f"{name}.csv.gz", self.ocfg["gzip_level"], pool=self._pool,
                              block_bytes=int(self.ocfg["gzip_block_mb"] * (1 << 20)))
        st["gz"].write((_header([c for c, _, _ in schema]) + "\r\n").encode())
        st["pq"] = None
        if self.ocfg["parquet"] and name not in NO_PARQUET_STREAMS:
            import pyarrow as pa
            import pyarrow.parquet as pq
            fields = [pa.field(c, _pa_type(ty)) for c, _, ty in schema]
            st["pa_schema"] = pa.schema(fields)
            st["pq"] = pq.ParquetWriter(self.dir / f"{name}.parquet", st["pa_schema"],
                                        compression=self.ocfg["parquet_compression"])
        if name == "timeline" and self.ocfg["by_agent"]:
            self.by_agent = ByAgentWriter(self.dir / "timeline_by_agent", _header([c for c, _, _ in schema]),
                                          int(self.ocfg["by_agent_max_open"]),
                                          int(self.ocfg["by_agent_buffer_mb"] * (1 << 20)))
        self.streams[name] = st
        return st

    def append(self, name, df):
        """Append rows (already in d2 order, else sorted here) to <name>.csv.gz (+ .parquet,
        + timeline_by_agent for the timeline)."""
        st = self.streams.get(name) or self.open_stream(name)
        if df is None or len(df) == 0:
            return
        schema = st["schema"]
        cols = [c for c, _, _ in schema]
        missing = [c for c in cols if c not in df.columns]
        if missing:
            raise ValueError(f"{name}: missing columns {missing}")
        keys = STREAM_SORT.get(name)
        if keys and not _is_sorted(df, keys):
            df = df.sort_values(keys, kind="stable")
        want_typed = st["pq"] is not None
        step = int(self.ocfg["chunk_rows"])
        tables = []
        for s in range(0, len(df), step):
            part = df.iloc[s:s + step]
            fcols, tcols = [], []
            for c, kind, _ in schema:
                f, tv = format_column(part[c], kind, want_typed)
                fcols.append(f)
                tcols.append(tv)
            lists = [f.tolist() for f in fcols]
            rows = list(map(",".join, zip(*lists)))
            st["gz"].write(("\r\n".join(rows) + "\r\n").encode("utf-8"))
            if name == "timeline" and self.by_agent is not None:
                self._by_agent(part["agent_id"].to_numpy(), rows)
            if want_typed:
                tables.append(self._arrow(st, tcols))
            st["rows"] += len(part)
        if tables:  # one row group per append() call -> parquet bytes independent of chunk_rows
            import pyarrow as pa
            st["pq"].write_table(pa.concat_tables(tables), row_group_size=1 << 30)

    def _by_agent(self, agent_ids, rows):
        cod, uniq = pd.factorize(agent_ids, sort=True)
        order = np.argsort(cod, kind="stable")
        bounds = np.searchsorted(cod[order], np.arange(len(uniq) + 1))
        rows_arr = np.array(rows, dtype=object)[order]
        groups = [(uniq[k], "\r\n".join(rows_arr[bounds[k]:bounds[k + 1]].tolist()) + "\r\n")
                  for k in range(len(uniq))]
        self.by_agent.write_groups(groups)

    def _arrow(self, st, tcols):
        import pyarrow as pa
        arrays = []
        for (c, kind, ty), tv in zip(st["schema"], tcols):
            pt = _pa_type(ty)
            if ty == "string":
                arrays.append(pa.array(tv, type=pt, from_pandas=True))
            elif ty == "bool":
                tv = np.asarray(tv)
                if tv.dtype == bool:
                    arrays.append(pa.array(tv, type=pt))
                else:
                    arrays.append(pa.array(tv.tolist(), type=pt))
            elif ty.startswith("int"):
                tv = np.asarray(tv, dtype=np.float64)
                mask = np.isnan(tv)
                arrays.append(pa.array(np.where(mask, 0, tv).astype(ty), type=pt, mask=mask if mask.any() else None))
            else:
                tv = np.asarray(tv, dtype=np.float64)
                mask = np.isnan(tv)
                arrays.append(pa.array(tv, type=pt, mask=mask if mask.any() else None))
        return pa.Table.from_arrays(arrays, schema=st["pa_schema"])

    def close(self):
        for name in ("timeline", "contacts", "room_exposure"):  # d2 run folder always has all three
            if name not in self.streams:
                self.open_stream(name)
        for st in self.streams.values():
            st["gz"].close()
            if st["pq"] is not None:
                st["pq"].close()
                st["pq"] = None
        if self.by_agent is not None:
            self.by_agent.close()
            self.by_agent = None
        self._pool.shutdown()


# ----------------------------------------------------------------------------- timeline frame
def _vocab(series_or_list, n_extra=1):
    a = np.asarray(list(series_or_list), dtype=object)
    return np.concatenate([a, np.full(n_extra, "", dtype=object)])


def _by_index(df, col, n_hint=None):
    """df[col] as an object array indexed by df.index (0..max), '' where absent, plus trailing ''."""
    if df is None or len(df) == 0 or col not in df.columns:
        return np.array([""], dtype=object)
    idx = np.asarray(df.index, dtype=np.int64)
    out = np.full(int(idx.max()) + 2, "", dtype=object)
    out[idx] = df[col].astype(str).to_numpy(dtype=object)
    return out


_TL_CACHE = {}


def _campus_vocab(campus):
    key = id(campus)
    v = _TL_CACHE.get(key)
    if v is not None and v["campus"] is campus:
        return v
    rooms = campus.rooms.sort_index()
    blds = campus.buildings.sort_index()
    R = len(rooms)
    room_b = np.asarray(rooms["b"], dtype=np.int64)
    loc = blds["location_id"].to_numpy(dtype=object)
    btype = blds["type"].to_numpy(dtype=object)
    ents = getattr(campus, "entrances", None)
    v = {
        "campus": campus, "R": R,
        "room_id": _vocab(rooms["room_id"]), "room_type": _vocab(rooms["room_type"]),
        "room_floor": np.concatenate([np.asarray(rooms["floor"], dtype=np.float64), [np.nan]]),
        "room_loc": np.concatenate([loc[room_b], [""]]).astype(object),
        "room_ltype": np.concatenate([btype[room_b], [""]]).astype(object),
        "ent": _vocab(ents["entrance_id"]) if ents is not None and len(ents) else np.array([""], dtype=object),
    }
    _TL_CACHE.clear()
    _TL_CACHE[key] = v
    return v


def timeline_frame(t0, t1, buffers, campus, pop, events, sections, step_timestamps):
    """(steps, N) buffers for steps t0..t1-1 -> d2 timeline DataFrame (typed; RunWriter formats/rounds).
    Rows ordered by (t, agent_id)."""
    steps = t1 - t0
    room = np.asarray(buffers["room"])[:steps]
    N = room.shape[1]
    ids = np.asarray(pop.agent_id, dtype=object)
    order = np.argsort(ids.astype(str), kind="stable")
    perm = None if np.array_equal(order, np.arange(N)) else order

    def g(name, default=None):
        a = buffers.get(name)
        if a is None:
            return default
        a = np.asarray(a)[:steps]
        if perm is not None:
            a = a[:, perm]
        return a.reshape(-1)

    if perm is not None:
        room = room[:, perm]
    room = room.reshape(-1)
    n = room.size
    cv = _campus_vocab(campus)
    R = cv["R"]
    in_room = room >= 0
    transit = room == codes.ROOM_TRANSIT
    off = g("off_map", np.zeros(n, bool)).astype(bool) | (room == codes.ROOM_OFF_MAP)
    in_room &= ~off
    transit &= ~off
    ridx = np.where(in_room, room, R)

    x = g("x").astype(np.float64)
    y = g("y").astype(np.float64)
    x = np.where(off, np.nan, x)
    y = np.where(off, np.nan, y)
    lon, lat = geo.to_ll(x, y)

    fl = g("floor", np.full(n, np.nan))
    fl = np.asarray(fl, dtype=np.float64)
    rf = cv["room_floor"][ridx]
    floor = np.where(in_room, np.where(np.isfinite(fl), fl, rf), np.nan)

    loc_type = cv["room_ltype"][ridx]
    loc_type[transit] = "outdoor"

    ent = g("entrance", np.full(n, -1)).astype(np.int64)
    ent_v = cv["ent"]
    ent_s = ent_v[np.where((ent >= 0) & (ent < len(ent_v) - 1), ent, len(ent_v) - 1)]

    sec_v = _by_index(sections, "section_id")
    ev_v = _by_index(events, "event_id")
    sec = g("section", np.full(n, -1)).astype(np.int64)
    ev = g("event", np.full(n, -1)).astype(np.int64)
    sec_ok = (sec >= 0) & (sec < len(sec_v) - 1)
    ev_ok = (ev >= 0) & (ev < len(ev_v) - 1)
    event_id = np.where(sec_ok, sec_v[np.where(sec_ok, sec, len(sec_v) - 1)],
                        ev_v[np.where(ev_ok, ev, len(ev_v) - 1)]).astype(object)

    act_v = np.asarray(codes.ACTIVITIES, dtype=object)
    st_v = np.asarray(codes.DISEASE_STATES, dtype=object)
    state = g("state").astype(np.int64)
    dsi = np.asarray(g("dsi", np.full(n, np.nan)), dtype=np.float64)
    dsi = np.where(state == codes.S, np.nan, dsi)

    ts = list(step_timestamps)
    ts_arr = np.asarray(ts[t0:t1] if len(ts) >= t1 else ts[:steps], dtype=object)
    tr_v = np.asarray(codes.TRANSPORT, dtype=object)[np.asarray(pop.transport, dtype=np.int64)]
    ids_sorted = ids[order]

    action = g("action")
    if action is None:
        action = np.full(n, "", dtype=object)
    else:
        action = np.asarray(action, dtype=object)
        action = np.where(pd.isna(action), "", action).astype(object)

    cols = {
        "t": np.repeat(np.arange(t0, t1, dtype=np.int64), N),
        "timestamp": np.repeat(ts_arr, N),
        "agent_id": np.tile(ids_sorted, steps),
        "lat": lat, "lon": lon, "x_local_m": x, "y_local_m": y,
        "floor": floor,
        "location_id": cv["room_loc"][ridx],
        "location_type": loc_type,
        "room_id": cv["room_id"][ridx],
        "room_type": cv["room_type"][ridx],
        "entrance_id": ent_s,
        "indoor": g("indoor", np.zeros(n, bool)).astype(bool) & in_room,
        "off_map": off,
        "activity": act_v[g("act").astype(np.int64)],
        "event_id": event_id,
        "moving": g("moving", np.zeros(n, bool)).astype(bool) | transit,
        "transport_mode": np.tile(tr_v[order], steps),
        "disease_state": st_v[state],
        "days_since_infection": dsi,
        "infectiousness": np.asarray(g("inf", np.zeros(n)), dtype=np.float64),
        "symptomatic": g("symptomatic", np.zeros(n, bool)).astype(bool),
        "symptom_severity": np.asarray(g("severity", np.zeros(n)), dtype=np.float64),
        "masked": g("masked", np.zeros(n, bool)).astype(bool),
        "self_reported_status": np.asarray(codes.SELF_STATUS, dtype=object)[g("self_status", np.zeros(n, np.int8)).astype(np.int64)],
        "test_status": np.asarray(codes.TEST_STATUS, dtype=object)[g("test_status", np.zeros(n, np.int8)).astype(np.int64)],
        "isolating": g("isolating", np.zeros(n, bool)).astype(bool),
        "intervention_action": action,
    }
    return pd.DataFrame(cols, columns=TIMELINE_COLUMNS, copy=False)


# ----------------------------------------------------------------------------- compact timeline
def _neq(a, b):
    """Elementwise a != b with missing == missing."""
    out = a != b
    na = pd.isna(a) & pd.isna(b)
    return out & ~na


class TimelineChanges:
    """timeline_changes.csv.gz (docs/timeline-changes-format.md): an agent's row is kept if it is the
    agent's first or last row, differs from its previous row in CHANGE_COLUMNS, or the next row does
    (the last row of a stay). Fed the same day frames as the timeline; the last step of each frame is
    held back until the next frame shows whether it ends a stay."""

    def __init__(self, writer, n_agents, n_steps):
        self.w, self.N, self.T = writer, n_agents, n_steps
        self.prev = None          # CHANGE_COLUMNS values of the last step seen, each (N,)
        self.pending = None       # last step's rows, waiting for the next frame
        self.pending_keep = None

    def add(self, df):
        N = self.N
        steps = len(df) // N
        if steps * N != len(df):
            raise ValueError("timeline frame must hold every agent at every step")
        # compare at written precision: frames hold unrounded floats that may print identically
        vals = [(np.round(df[c].to_numpy(dtype=float), ROUND_RULES[c]) if c in ROUND_RULES
                 else df[c].to_numpy()).reshape(steps, N) for c in CHANGE_COLUMNS]
        changed = np.zeros((steps, N), dtype=bool)  # differs from the agent's previous row
        for k, v in enumerate(vals):
            changed[1:] |= _neq(v[1:], v[:-1])
            if self.prev is not None:
                changed[0] |= _neq(v[0], self.prev[k])
        if self.prev is None:
            changed[0] = True  # first row
        keep = changed.copy()
        keep[:-1] |= changed[1:]  # last row of a stay
        t = df["t"].to_numpy().reshape(steps, N)[:, 0]
        keep[t == self.T - 1] = True  # last row
        parts = []
        if self.pending is not None:
            parts.append(self.pending[self.pending_keep | changed[0]])
        parts.append(df.iloc[: (steps - 1) * N][keep[:-1].ravel()])
        last = df.iloc[(steps - 1) * N:]
        if t[-1] == self.T - 1:
            parts.append(last[keep[-1]])
            self.pending = None
        else:
            # copy: frame columns may be views of the engine's day buffers, which get reused
            self.pending, self.pending_keep = last.copy(deep=True), keep[-1]
        self.prev = [v[-1].copy() for v in vals]
        self.w.append("timeline_changes", pd.concat(parts, ignore_index=True))

    def close(self):
        if self.pending is not None:  # run ended mid-frame: these are every agent's last rows
            self.w.append("timeline_changes", self.pending)
            self.pending = None
