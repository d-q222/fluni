"""Export a run's contacts.parquet to flat binary columns for the JS models (kl_fixed node wrappers).

    ml/.venv/bin/python ml/scripts/export_contacts_fixed.py sim/runs/<run> ml/out/kl/fixed/contacts_bin

Row order is kept (same as contacts.csv.gz). Columns (little-endian):
  t.i32, a.i16, b.i16 (index into agents_static.csv order), dcm.u16 (distance_m * 100, rounded: the CSV
  has 2 decimals), tier.i8, dur.i16 (duration_s), room.i32 (index into rooms.json; -1 = empty room_id),
  indoor.u8. Streams one row group at a time.
"""
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow.parquet as pq

run, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
agents = pd.read_csv(run / "agents_static.csv", usecols=["agent_id"]).agent_id.astype(str).to_numpy()
aidx = {a: i for i, a in enumerate(agents)}
assert len(agents) < 32767
rooms = {}
pf = pq.ParquetFile(run / "contacts.parquet", read_dictionary=["agent_a", "agent_b", "room_id"])
files = {k: open(out / f"{k}.bin", "wb") for k in ["t", "a", "b", "dcm", "tier", "dur", "room", "indoor"]}


def codes(col, table, grow):
    col = col.combine_chunks()
    cats = col.dictionary.to_pylist()
    look = np.empty(len(cats) + 1, np.int64)
    for i, v in enumerate(cats):
        if v is None or v == "":
            look[i] = -1
        elif grow:
            look[i] = table.setdefault(v, len(table))
        else:
            look[i] = table[v]
    look[-1] = -1
    idx = col.indices.to_numpy(zero_copy_only=False)
    idx = np.where(col.indices.is_null().to_numpy(zero_copy_only=False), len(cats), idx)
    return look[idx.astype(np.int64)]


n = 0
for g in range(pf.num_row_groups):
    tb = pf.read_row_group(g, columns=["t", "agent_a", "agent_b", "distance_m", "distance_tier",
                                       "duration_s", "room_id", "indoor"])
    a, b = codes(tb["agent_a"], aidx, False), codes(tb["agent_b"], aidx, False)
    assert (a >= 0).all() and (b >= 0).all()
    d = tb["distance_m"].to_numpy()
    assert np.isfinite(d).all() and d.max() < 655
    dur = tb["duration_s"].to_numpy()
    assert dur.max() < 32767 and dur.min() >= 0
    files["t"].write(tb["t"].to_numpy().astype("<i4").tobytes())
    files["a"].write(a.astype("<i2").tobytes())
    files["b"].write(b.astype("<i2").tobytes())
    files["dcm"].write(np.round(d * 100).astype("<u2").tobytes())
    files["tier"].write(tb["distance_tier"].to_numpy().astype("i1").tobytes())
    files["dur"].write(dur.astype("<i2").tobytes())
    files["room"].write(codes(tb["room_id"], rooms, True).astype("<i4").tobytes())
    files["indoor"].write(tb["indoor"].to_numpy(zero_copy_only=False).astype("u1").tobytes())
    n += len(tb)
    print(f"row group {g}: {n:,} rows", flush=True)
    del tb
for f in files.values():
    f.close()
json.dump({"n": n, "agents": agents.tolist(), "rooms": sorted(rooms, key=rooms.get)},
          open(out / "meta.json", "w"))
print("done", n)
