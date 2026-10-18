# /// script
# requires-python = ">=3.10"
# dependencies = ["pyarrow", "numpy"]
# ///
"""Contacts of a sim run as compact binary columns for model/meanfield-eval.mjs (Node has no parquet reader).

    uv run model/tools/contacts_cache.py sim/runs/<run> [...]

Reads <run>/contacts.parquet (or contacts.csv.gz / parts/) and writes model/cache/<run>/ with t.i32, a.i32, b.i32
(agent indexes in agents_static.csv order), dist.f32, tier.i8, indoor.u8, room.i32 (-1: no room id), dur.i32 and
meta.json {rows, rooms}. model/cache/ is not committed.
"""
import csv, json, os, sys
import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.csv as pacsv
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
COLS = ["t", "agent_a", "agent_b", "distance_m", "distance_tier", "duration_s", "room_id", "indoor"]


def read_contacts(run):
    p = os.path.join(run, "contacts.parquet")
    if os.path.exists(p):
        return pq.read_table(p, columns=COLS)
    paths = [os.path.join(run, "contacts.csv.gz")]
    if not os.path.exists(paths[0]):
        man = json.load(open(os.path.join(run, "parts", "manifest.json")))
        paths = [os.path.join(run, x["path"]) for x in man["files"]["contacts.csv.gz"]["parts"]]
    opts = pacsv.ConvertOptions(include_columns=COLS, column_types={"room_id": pa.string(), "indoor": pa.string()},
                                strings_can_be_null=False)
    t = pa.concat_tables([pacsv.read_csv(x, convert_options=opts) for x in paths])
    return t.set_column(t.schema.get_field_index("indoor"), "indoor", pc.equal(t["indoor"], "True"))


def main():
    for run in sys.argv[1:]:
        run = run.rstrip("/")
        ids = [r["agent_id"] for r in csv.DictReader(open(os.path.join(run, "agents_static.csv")))]
        ix = {a: i for i, a in enumerate(ids)}
        t = read_contacts(run)
        out = os.path.join(HERE, "..", "cache", os.path.basename(run))
        os.makedirs(out, exist_ok=True)
        a = np.array([ix[x] for x in t["agent_a"].to_pylist()], np.int32)
        b = np.array([ix[x] for x in t["agent_b"].to_pylist()], np.int32)
        rooms = t["room_id"].fill_null("").to_pylist()
        names = sorted(set(rooms) - {""})
        rix = {r: i for i, r in enumerate(names)}
        room = np.array([rix.get(r, -1) for r in rooms], np.int32)
        cols = {"t": (t["t"], np.int32), "dist": (t["distance_m"], np.float32), "tier": (t["distance_tier"], np.int8),
                "indoor": (t["indoor"], np.uint8), "dur": (t["duration_s"], np.int32)}
        for k, (col, dt) in cols.items():
            np.asarray(col.to_numpy(zero_copy_only=False), dtype=dt).tofile(os.path.join(out, f"{k}.{np.dtype(dt).str[1:]}"))
        a.tofile(os.path.join(out, "a.i4")); b.tofile(os.path.join(out, "b.i4")); room.tofile(os.path.join(out, "room.i4"))
        json.dump({"rows": len(a), "rooms": names, "agents": len(ids)}, open(os.path.join(out, "meta.json"), "w"))
        print(f"{os.path.basename(run)}: {len(a):,} rows, {len(names)} rooms -> {os.path.relpath(out)}")


if __name__ == "__main__":
    main()
