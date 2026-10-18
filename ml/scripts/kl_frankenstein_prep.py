"""frankenstein: build the hourly-edge cache for run 17ed9cd6 with fluniml.data's streaming builder,
saved under ml/out/kl/frankenstein/ (not the shared cache)."""
import os, sys, time
os.environ.setdefault("OMP_NUM_THREADS", "4")
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import data
RUN = data.REPO / "sim/runs/influenza_none_n7500_d14_s42_17ed9cd6"
OUT = data.ML / "out/kl/frankenstein"
t = time.time()
d = data._build(RUN)
print("built in", round(time.time() - t), "s; E =", len(d["hour"]), flush=True)
np.savez(OUT / "cache_frankenstein.npz", **d)
print("saved", flush=True)
