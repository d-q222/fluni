"""frankenstein: dump contacts.parquet of run 17ed9cd6 to flat binary columns for the JS models
(ml/scripts/kl_frankenstein.mjs), streaming one row group at a time. Output: ml/out/kl/frankenstein/contacts_frankenstein/"""
import json, sys
from pathlib import Path
import numpy as np, pandas as pd, pyarrow.parquet as pq
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml.data import REPO, ML, _codes
RUN = REPO / "sim/runs/influenza_none_n7500_d14_s42_17ed9cd6"
OUT = ML / "out/kl/frankenstein/contacts_frankenstein"; OUT.mkdir(parents=True, exist_ok=True)
agents = pd.read_csv(RUN / "agents_static.csv", usecols=["agent_id"]).agent_id.astype(str).tolist()
idx = {a: i for i, a in enumerate(agents)}
rooms = {}
pf = pq.ParquetFile(RUN / "contacts.parquet", read_dictionary=["agent_a", "agent_b", "room_id"])
cols = ["t", "agent_a", "agent_b", "distance_m", "distance_tier", "duration_s", "room_id", "indoor"]
fs = {k: open(OUT / f"{k}.bin", "wb") for k in ["t", "a", "b", "dist", "tier", "dur", "room", "ind"]}
n, last_t, sorted_ = 0, -1, True
for g in range(pf.num_row_groups):
    tb = pf.read_row_group(g, columns=cols)
    t = tb["t"].to_numpy().astype(np.int32)
    a, b = _codes(tb["agent_a"], idx), _codes(tb["agent_b"], idx)
    assert len(idx) == len(agents) and (a >= 0).all() and (b >= 0).all()
    dur = tb["duration_s"].to_numpy()
    assert dur.max() < 65536 and dur.min() >= 0
    if len(t):
        sorted_ &= bool((np.diff(t) >= 0).all()) and t[0] >= last_t
        last_t = int(t[-1])
    fs["t"].write(t.tobytes()); fs["a"].write(a.astype(np.uint16).tobytes()); fs["b"].write(b.astype(np.uint16).tobytes())
    fs["dist"].write(tb["distance_m"].to_numpy(zero_copy_only=False).astype(np.float32).tobytes())
    fs["tier"].write(tb["distance_tier"].to_numpy().astype(np.uint8).tobytes())
    fs["dur"].write(dur.astype(np.uint16).tobytes())
    fs["room"].write(_codes(tb["room_id"], rooms).astype(np.int32).tobytes())
    fs["ind"].write(tb["indoor"].to_numpy(zero_copy_only=False).astype(np.uint8).tobytes())
    n += len(t); del tb
    print(g, n, flush=True)
for f in fs.values(): f.close()
names = [None] * len(rooms)
for k, v in rooms.items(): names[v] = k
json.dump({"n": n, "sorted": bool(sorted_), "rooms": names, "agents": agents}, open(OUT / "meta.json", "w"))
print("rows", n, "sorted", sorted_)
