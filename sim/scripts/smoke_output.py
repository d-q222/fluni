"""Smoke test for campussim/output.py + summary.py.

1. Re-runs the d2 mock generator (sim/make_mock_run.py) with `round` disabled to get
   the RAW (unrounded) values behind every mock row, feeds them through timeline_frame + RunWriter,
   and asserts timeline.csv.gz / timeline_by_agent / contacts / room_exposure / infections /
   reports_tests are byte-identical (decompressed) to the mock run.
2. Off-map / transit row rules, parquet round trip, determinism (sha256 of every file, two runs,
   different thread counts / open-vs-buffered by-agent mode), gzip validity.
3. Throughput benchmark: 1M fake timeline rows at N=7500, extrapolated to 30M.

  .venv/bin/python scripts/smoke_output.py [--bench-rows 1000000] [--no-bench]
"""
import argparse
import csv
import gzip
import hashlib
import importlib.util
import io
import math
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from campussim import codes  # noqa: E402
from campussim.output import (RunWriter, STREAM_SCHEMAS, TIMELINE_COLUMNS, csv_lines,  # noqa: E402
                              format_column, timeline_frame)
from campussim.summary import compute_summary  # noqa: E402

MOCK_DIR = ROOT  # sim/: make_mock_run.py + runs/mock_boring10
MOCK_RUN = MOCK_DIR / "runs" / "mock_boring10"


def read_csv_rows(path):
    op = gzip.open if str(path).endswith(".gz") else open
    with op(path, "rt", newline="") as f:
        return list(csv.DictReader(f))


def file_text(path):
    with open(path, "rb") as f:
        b = f.read()
    return gzip.decompress(b) if str(path).endswith(".gz") else b


def raw_mock(out):
    """Run the mock generator with round(., 2|6|7) as identity -> raw values (repr round-trips exactly)."""
    spec = importlib.util.spec_from_file_location("mockgen", MOCK_DIR / "make_mock_run.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    # keep 3/4 dp rounding: the mock feeds rounded infectiousness into its aerosol model
    m.round = lambda v, k=None, _r=round: v if k in (2, 6, 7) else _r(v, k)
    argv = sys.argv
    sys.argv = ["mock", "--out", str(out)]
    try:
        import contextlib
        with contextlib.redirect_stdout(io.StringIO()):
            m.main()
    finally:
        sys.argv = argv


def fake_world(mock_run):
    rooms = pd.DataFrame(read_csv_rows(mock_run / "map" / "rooms.csv"))
    blds = pd.DataFrame(read_csv_rows(mock_run / "map" / "buildings.csv"))
    ents = pd.DataFrame(read_csv_rows(mock_run / "map" / "entrances.csv"))
    b_of = {lid: i for i, lid in enumerate(blds["location_id"])}
    rooms["b"] = rooms["location_id"].map(b_of)
    rooms["floor"] = rooms["floor"].astype(int)
    campus = SimpleNamespace(rooms=rooms, buildings=blds, entrances=ents)
    agents = read_csv_rows(mock_run / "agents_static.csv")
    pop = SimpleNamespace(N=len(agents), agent_id=[a["agent_id"] for a in agents],
                          transport=np.array([codes.TRANSPORT.index(a["transport_mode"]) for a in agents], np.int8),
                          archetype=np.array([codes.ARCHETYPES.index(a["archetype"]) for a in agents], np.int8))
    sections = pd.DataFrame({"section_id": ["SEC_MWF_01", "SEC_TTH_01"]})
    return campus, pop, sections


def buffers_from_raw(raw_rows, campus, pop, sections, T):
    N = pop.N
    rid = {r: i for i, r in enumerate(campus.rooms["room_id"])}
    eid = {e: i for i, e in enumerate(campus.entrances["entrance_id"])}
    sid = {s: i for i, s in enumerate(sections["section_id"])}
    aidx = {a: i for i, a in enumerate(pop.agent_id)}
    B = {k: np.zeros((T, N), dt) for k, dt in [
        ("room", np.int32), ("b", np.int32), ("x", float), ("y", float), ("floor", float), ("indoor", bool),
        ("off_map", bool), ("act", np.int8), ("event", np.int32), ("section", np.int32), ("entrance", np.int32),
        ("moving", bool), ("state", np.int8), ("dsi", float), ("inf", float), ("symptomatic", bool),
        ("severity", float), ("masked", bool), ("self_status", np.int8), ("test_status", np.int8),
        ("isolating", bool)]}
    B["action"] = np.full((T, N), None, dtype=object)
    tf = {"True": True, "False": False}
    for r in raw_rows:
        t, i = int(r["t"]), aidx[r["agent_id"]]
        room = rid[r["room_id"]] if r["room_id"] else codes.ROOM_TRANSIT
        B["room"][t, i] = room
        B["b"][t, i] = campus.rooms["b"][room] if room >= 0 else -1
        B["x"][t, i], B["y"][t, i] = float(r["x_local_m"]), float(r["y_local_m"])
        B["floor"][t, i] = float(r["floor"]) if r["floor"] else np.nan
        B["indoor"][t, i] = tf[r["indoor"]]
        B["off_map"][t, i] = tf[r["off_map"]]
        B["act"][t, i] = codes.ACT[r["activity"]]
        B["event"][t, i] = -1
        B["section"][t, i] = sid.get(r["event_id"], -1)
        B["entrance"][t, i] = eid[r["entrance_id"]] if r["entrance_id"] else -1
        B["moving"][t, i] = tf[r["moving"]]
        B["state"][t, i] = codes.DISEASE_STATES.index(r["disease_state"])
        B["dsi"][t, i] = float(r["days_since_infection"]) if r["days_since_infection"] else np.nan
        B["inf"][t, i] = float(r["infectiousness"])
        B["symptomatic"][t, i] = tf[r["symptomatic"]]
        B["severity"][t, i] = float(r["symptom_severity"])
        B["masked"][t, i] = tf[r["masked"]]
        B["self_status"][t, i] = codes.SELF_STATUS.index(r["self_reported_status"])
        B["test_status"][t, i] = codes.TEST_STATUS.index(r["test_status"])
        B["isolating"][t, i] = tf[r["isolating"]]
    return B


def typed_frame(rows, ints=(), floats=(), bools=()):
    df = pd.DataFrame(rows)
    for c in ints:
        df[c] = df[c].astype(np.int64)
    for c in floats:
        df[c] = df[c].astype(float)
    for c in bools:
        df[c] = df[c].map({"True": True, "False": False})
    return df


def write_run(out, campus, pop, sections, B, T, raw_c, raw_e, cfg, spd=288):
    w = RunWriter(out, cfg)
    ts = [(pd.Timestamp("2026-01-05") + pd.Timedelta(minutes=5 * t)).isoformat() for t in range(T)]
    for t0 in range(0, T, spd):
        t1 = min(T, t0 + spd)
        day = {k: v[t0:t1] for k, v in B.items()}
        w.append("timeline", timeline_frame(t0, t1, day, campus, pop, None, sections, ts))
        c = raw_c[(raw_c["t"] >= t0) & (raw_c["t"] < t1)]
        w.append("contacts", c)
        e = raw_e[(raw_e["t"] >= t0) & (raw_e["t"] < t1)]
        w.append("room_exposure", e)
    inf = typed_frame(read_csv_rows(MOCK_RUN / "infections.csv"), ints=["t"], floats=["infector_contribution"])
    w.write_table("infections.csv", inf)
    rep = pd.DataFrame(read_csv_rows(MOCK_RUN / "reports_tests.csv"))
    rep["t"] = rep["t"].astype(int)
    rep["truthful"] = rep["truthful"].map({"True": True, "False": False, "": None}).astype(object)
    w.write_table("reports_tests.csv", rep)
    w.write_config({"run": {"seed": 42, "n_agents": 10, "days": 3, "step_min": 5, "start_date": "2026-01-05",
                            "intervention": "none"}, "disease": {"preset": "influenza"}, **cfg},
                   "mock_boring10", "stanford_osm (local extract)", "mock-0.1", {"homebody": 1.0})
    inf_df = pd.DataFrame({"t": [108], "infectee": [3], "infector": [-1], "route": ["import"], "r": [-1],
                           "b": [-1], "contribution": [1.0]})
    summ = compute_summary({"run": {"n_agents": 10, "days": 3, "step_min": 5},
                            "disease": {"latent_days": {"mean": 1.0}, "infectious_days": {"mean": 5.0}}},
                           campus, pop, inf_df, T)
    w.write_json("summary.json", summ)
    w.close()
    return summ


def sha_tree(d):
    out = {}
    for p in sorted(Path(d).rglob("*")):
        if p.is_file():
            out[str(p.relative_to(d))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def check_mock(tmp):
    raw_dir = tmp / "mockraw"
    raw_mock(raw_dir)
    campus, pop, sections = fake_world(MOCK_RUN)
    raw_rows = read_csv_rows(raw_dir / "timeline.csv.gz")
    T = 3 * 288
    B = buffers_from_raw(raw_rows, campus, pop, sections, T)
    raw_c = typed_frame(read_csv_rows(raw_dir / "contacts.csv.gz"), ints=["t", "distance_tier", "duration_s"],
                        floats=["distance_m"], bools=["indoor"])
    raw_e = typed_frame(read_csv_rows(raw_dir / "room_exposure.csv.gz"),
                        ints=["t", "occupants", "infectious_occupants"], floats=["quanta_concentration"])
    cfg = {"output": {"by_agent_max_open": 512}}
    out1 = tmp / "run1"
    summ = write_run(out1, campus, pop, sections, B, T, raw_c, raw_e, cfg)

    for rel in ["timeline.csv.gz", "contacts.csv.gz", "room_exposure.csv.gz", "infections.csv", "reports_tests.csv"] + \
            [f"timeline_by_agent/{a}.csv" for a in pop.agent_id]:
        mine, ref = file_text(out1 / rel), file_text(MOCK_RUN / rel)
        if rel == "room_exposure.csv.gz":  # mock lists rooms in dict order; CONTRACT says (t, room_id)
            ls = ref.split(b"\r\n")
            body = sorted(ls[1:-1], key=lambda l: (int(l.split(b",")[0]), l.split(b",")[1]))
            ref = b"\r\n".join([ls[0]] + body + [b""])
        if mine != ref:
            ml, rl = mine.split(b"\r\n"), ref.split(b"\r\n")
            bad = next(i for i in range(max(len(ml), len(rl))) if i >= len(ml) or i >= len(rl) or ml[i] != rl[i])
            raise AssertionError(f"{rel} differs at line {bad}:\n mine {ml[bad] if bad < len(ml) else None}\n "
                                 f"mock {rl[bad] if bad < len(rl) else None}")
        print(f"  OK byte-identical: {rel} ({len(ref)} bytes)")
    # gzip header like gzip.GzipFile(mtime=0) and valid for the gzip CLI
    for rel in ["timeline.csv.gz", "contacts.csv.gz", "room_exposure.csv.gz"]:
        h = (out1 / rel).read_bytes()[:10 + len(rel) - 2]
        assert h[:8] == b"\x1f\x8b\x08\x08\x00\x00\x00\x00" and h[10:].startswith(rel[:-3].encode()), h
        subprocess.run(["gzip", "-t", str(out1 / rel)], check=True)
    print("  OK gzip headers (mtime=0, FNAME) + gzip -t")

    import json
    mc = json.loads((MOCK_RUN / "config.json").read_text())
    mc.pop("mock")
    my = json.loads((out1 / "config.json").read_text())
    assert list(my)[:len(mc)] == list(mc) and list(my)[-1] == "params", list(my)
    for k in mc:
        assert my[k] == mc[k], (k, my[k], mc[k])
    ms = json.loads((MOCK_RUN / "summary.json").read_text())
    ms.pop("mock")
    assert list(summ)[:len(ms)] == list(ms), list(summ)
    print("  OK config.json / summary.json key order; summary:", {k: summ[k] for k in list(ms)})

    # parquet round trip: parquet values re-formatted == csv lines
    import pyarrow.parquet as pq
    for name in ["timeline", "contacts", "room_exposure"]:
        tbl = pq.read_table(out1 / f"{name}.parquet").to_pandas()
        kinds = {c: k for c, k, _ in STREAM_SCHEMAS[name]}
        lines = csv_lines(tbl, kinds)
        ref = file_text(out1 / f"{name}.csv.gz").decode().split("\r\n")[1:-1]
        assert lines == ref, (name, next((a, b) for a, b in zip(lines, ref) if a != b))
        print(f"  OK parquet round trip: {name} ({len(tbl)} rows, schema {pq.read_schema(out1 / f'{name}.parquet').types[:4]}...)")

    # determinism: different thread count / forced buffered by-agent mode -> same bytes
    out2 = tmp / "run2"
    write_run(out2, campus, pop, sections, B, T, raw_c, raw_e,
              {"output": {"by_agent_max_open": 3, "gzip_threads": 1, "by_agent_buffer_mb": 0.01, "chunk_rows": 1000}})
    h1, h2 = sha_tree(out1), sha_tree(out2)
    h1.pop("config.json"), h2.pop("config.json")  # params differ (output settings) by design
    assert h1 == h2, [k for k in h1 if h1.get(k) != h2.get(k)]
    print(f"  OK determinism: {len(h1)} files identical (sha256) across thread counts / by-agent modes / chunking")
    out3 = tmp / "run3"
    write_run(out3, campus, pop, sections, B, T, raw_c, raw_e, cfg)
    assert sha_tree(out1) == sha_tree(out3)
    print("  OK determinism: identical config -> identical sha256 for every file incl. config.json")
    return campus, pop, sections, B


def check_rules(campus, pop, sections, B):
    """Off-map + transit rows, NaN/None formatting, value formatting vs csv module."""
    T = 2
    b = {k: v[:T].copy() for k, v in B.items()}
    b["room"][0, 0] = codes.ROOM_OFF_MAP
    b["off_map"][0, 0] = True
    b["x"][0, 0] = b["y"][0, 0] = np.nan
    b["floor"][0, 0] = np.nan
    b["act"][0, 0] = codes.ACT["off_campus"]
    b["room"][0, 1] = codes.ROOM_TRANSIT
    b["x"][0, 1], b["y"][0, 1] = 1669.94, 788.81
    b["act"][0, 1] = codes.ACT["commute"]
    b["entrance"][0, 1] = 0
    b["state"][1, 2] = codes.E
    b["dsi"][1, 2] = 0.1234567
    b["action"][1, 3] = "isolate_until:1234"
    df = timeline_frame(0, T, b, campus, pop, None, sections, ["2026-01-05T00:00:00", "2026-01-05T00:05:00"])
    kinds = {c: k for c, k, _ in STREAM_SCHEMAS["timeline"]}
    lines = csv_lines(df, kinds)
    assert lines[0] == ("0,2026-01-05T00:00:00,A0000,,,,,,,,,,,False,True,off_campus,,False,walk,S,,0.0,False,"
                        "0.0,False,none,none,False,"), lines[0]
    e0 = campus.entrances["entrance_id"][0]
    assert lines[1] == (f"0,2026-01-05T00:00:00,A0001,37.425136,-122.1631121,1669.94,788.81,,,outdoor,,,{e0},"
                        "False,False,commute,,True,walk,S,,0.0,False,0.0,False,none,none,False,"), lines[1]
    assert ",E,0.123,0.0," in lines[pop.N + 2], lines[pop.N + 2]
    assert lines[pop.N + 3].endswith(",isolate_until:1234"), lines[pop.N + 3]
    # value formatting identical to csv module on random values
    rng = np.random.default_rng(0)
    vals = np.concatenate([rng.random(20000) * 10.0 ** rng.integers(-8, 5, 20000), [0.0, -0.0, 1e-6, 2.5e-5, 1.0, 2.0, 1e-4]])
    for k in (2, 3, 4, 6, 7):
        got = format_column(vals, k)[0].tolist()
        buf = io.StringIO()
        csv.writer(buf).writerows([[round(v, k) + 0.0] for v in vals.tolist()])
        assert got == buf.getvalue().split("\r\n")[:-1], k
    buf = io.StringIO()
    obj = np.array(["a,b", 'q"x', None, "", 3, True, 2.5, float("nan")], dtype=object)
    csv.writer(buf).writerow(["a,b", 'q"x', "", "", 3, True, 2.5, ""])
    assert ",".join(format_column(obj)[0]) == buf.getvalue()[:-2], format_column(obj)[0]
    print("  OK off-map/transit rows, dsi/action, float/str/quoting formatting == csv module")


def bench(tmp, n_rows, N=7500):
    steps = max(1, n_rows // N)
    R, Bn = 3000, 300
    rng = np.random.default_rng(1)
    rooms = pd.DataFrame({"room_id": [f"bld_{1000000 + r // 10}_f{1 + r % 3}_{100 + r % 10:03d}" for r in range(R)],
                          "room_type": rng.choice(["dorm_double", "seminar", "dining_room"], R),
                          "floor": 1 + np.arange(R) % 3, "b": np.arange(R) // 10})
    blds = pd.DataFrame({"location_id": [f"bld_{1000000 + b}" for b in range(Bn)],
                         "type": rng.choice(codes.LOCATION_TYPES, Bn)})
    ents = pd.DataFrame({"entrance_id": [f"ent_{i:04d}" for i in range(900)]})
    campus = SimpleNamespace(rooms=rooms, buildings=blds, entrances=ents)
    pop = SimpleNamespace(N=N, agent_id=[f"A{i:04d}" for i in range(N)], transport=rng.integers(0, 2, N))
    sections = pd.DataFrame({"section_id": [f"SEC_MWF_{i:02d}" for i in range(400)]})
    events = pd.DataFrame({"event_id": [f"EV{i:05d}" for i in range(200)]})
    home = rng.integers(0, R, N)
    room = np.tile(home, (steps, 1)).astype(np.int32)
    mv = rng.random((steps, N)) < 0.05
    room[mv] = codes.ROOM_TRANSIT
    room[rng.random((steps, N)) < 0.03] = codes.ROOM_OFF_MAP
    x = np.tile(rng.random(N) * 2000, (steps, 1)) + mv * rng.random((steps, N)) * 50
    y = np.tile(rng.random(N) * 2000, (steps, 1)) + mv * rng.random((steps, N)) * 50
    state = np.tile(rng.choice(6, N, p=[.8, .04, .04, .04, .04, .04]), (steps, 1)).astype(np.int8)
    B = {"room": room, "b": room // 10, "x": x, "y": y, "floor": np.full((steps, N), np.nan),
         "indoor": room >= 0, "off_map": room == codes.ROOM_OFF_MAP,
         "act": rng.integers(0, len(codes.ACTIVITIES), (steps, N)).astype(np.int8),
         "event": np.where(rng.random((steps, N)) < .02, rng.integers(0, 200, (steps, N)), -1),
         "section": np.where(rng.random((steps, N)) < .1, rng.integers(0, 400, (steps, N)), -1),
         "entrance": np.where(rng.random((steps, N)) < .02, rng.integers(0, 900, (steps, N)), -1),
         "moving": mv, "state": state, "dsi": np.where(state > 0, rng.random((steps, N)) * 10, np.nan),
         "inf": np.where(state > 1, rng.random((steps, N)), 0.0), "symptomatic": state == 3,
         "severity": np.where(state == 3, rng.random((steps, N)), 0.0), "masked": rng.random((steps, N)) < .1,
         "self_status": np.zeros((steps, N), np.int8), "test_status": np.zeros((steps, N), np.int8),
         "isolating": np.zeros((steps, N), bool), "action": np.full((steps, N), None, dtype=object)}
    ts = [(pd.Timestamp("2026-01-05") + pd.Timedelta(minutes=5 * t)).isoformat() for t in range(steps)]
    res = {}
    for label, oc in [("csv.gz only", {"by_agent": False, "parquet": False}),
                      ("csv.gz + parquet", {"by_agent": False, "parquet": True}),
                      ("all (csv.gz + parquet + by_agent)", {})]:
        out = tmp / f"bench_{len(res)}"
        t_start = time.perf_counter()
        w = RunWriter(out, {"output": oc})
        t_frame = 0.0
        for t0 in range(0, steps, 288):
            t1 = min(steps, t0 + 288)
            a = time.perf_counter()
            df = timeline_frame(t0, t1, {k: v[t0:t1] for k, v in B.items()}, campus, pop, events, sections, ts)
            t_frame += time.perf_counter() - a
            w.append("timeline", df)
        w.close()
        el = time.perf_counter() - t_start
        rows = steps * N
        res[label] = el
        print(f"  {label:36s}: {rows:,} rows in {el:6.2f}s (timeline_frame {t_frame:.2f}s) "
              f"= {rows / el / 1e6:.2f} M rows/s -> 30.24M rows ~ {30.24e6 / rows * el / 60:.1f} min; "
              f"timeline.csv.gz {(out / 'timeline.csv.gz').stat().st_size / 1e6:.1f} MB")
        shutil.rmtree(out)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench-rows", type=int, default=1_000_000)
    ap.add_argument("--no-bench", action="store_true")
    args = ap.parse_args()
    tmp = Path(tempfile.mkdtemp(prefix="smoke_output_"))
    try:
        print("[1] mock byte-for-byte")
        campus, pop, sections, B = check_mock(tmp)
        print("[2] row rules / formatting")
        check_rules(campus, pop, sections, B)
        if not args.no_bench:
            print(f"[3] benchmark ({args.bench_rows:,} rows, N=7500)")
            bench(tmp, args.bench_rows)
        print("smoke_output: ALL OK")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
