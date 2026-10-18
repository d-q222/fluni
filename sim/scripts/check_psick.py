"""Check campussim/psick.py (streaming) against model/infer.js (batch) on a finished run.

    .venv/bin/python scripts/check_psick.py runs/influenza_none_n10_d14_s2_bc5cae7a

Runs `node model/cli.mjs` on the run, replays the same contacts and reports through OnlineRisk step by
step, and compares P(sick) for every agent at every step where infer.js wrote a change point.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from campussim.psick import OnlineRisk  # noqa: E402


def main(run):
    run = Path(run).resolve()
    cfg = json.loads((run / "config.json").read_text())
    step_min = cfg["step_min"]
    start = datetime.fromisoformat(cfg["start"])

    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "p.csv"
        subprocess.run(["node", str(ROOT.parent / "model" / "cli.mjs"), str(run), str(out)], check=True,
                       stdout=subprocess.DEVNULL)
        js = pd.read_csv(out)

    agents = pd.read_csv(run / "agents_static.csv", usecols=["agent_id"])["agent_id"].tolist()
    aidx = {a: i for i, a in enumerate(agents)}
    rooms = pd.read_csv(run / "map" / "rooms.csv", usecols=["room_id", "room_type", "volume_m3", "ventilation_ach"])
    ridx = {r: i for i, r in enumerate(rooms["room_id"])}
    campus = SimpleNamespace(room_vol=rooms["volume_m3"].to_numpy(float), room_ach=rooms["ventilation_ach"].to_numpy(float),
                             rooms=rooms)
    con = pd.read_csv(run / "contacts.csv.gz", dtype={"room_id": str}, keep_default_na=False)
    rep = pd.read_csv(run / "reports_tests.csv", dtype=str, keep_default_na=False)
    rep["t"] = rep["t"].astype(int)

    js["t"] = [int(round((datetime.fromisoformat(s.replace("Z", "")) - start).total_seconds() / 60 / step_min))
               for s in js["t_iso"]]
    js["i"] = js["agent_id"].map(aidx)
    want = {}
    for t, g in js.groupby("t"):
        want[t] = g
    T = int(max(con["t"].max(), rep["t"].max() if len(rep) else 0, js["t"].max())) + 1

    risk = OnlineRisk(len(agents), campus, step_min)
    cg = dict(tuple(con.groupby("t")))
    rg = dict(tuple(rep.groupby("t")))
    last_js = np.full(len(agents), risk.P["prior"])
    errs = []
    for t in range(T):
        c = cg.get(t)
        if c is None:
            cd = dict(a=np.empty(0, int), b=np.empty(0, int), dist=np.empty(0), r=np.empty(0, int), indoor=np.empty(0, bool))
        else:
            cd = dict(a=c["agent_a"].map(aidx).to_numpy(), b=c["agent_b"].map(aidx).to_numpy(),
                      dist=c["distance_m"].astype(float).to_numpy(),
                      r=np.array([ridx.get(x, -1) for x in c["room_id"]]),
                      indoor=c["indoor"].astype(str).isin(["True", "true", "1"]).to_numpy())
        evs = []
        if t in rg:
            for _, r in rg[t].iterrows():
                evs.append(dict(agent=aidx[r["agent_id"]], event=r["event"], value=r["value"],
                                target=aidx.get(r["target_agent_id"], -1)))
        p = risk.step(t, cd, evs)
        if t in want:
            g = want[t]
            last_js[g["i"].to_numpy()] = g["p_sick"].to_numpy()
            d = np.abs(p[g["i"].to_numpy()] - g["p_sick"].to_numpy())
            errs.append(d)
    d = np.concatenate(errs) if errs else np.zeros(1)
    print(f"{len(d)} change points compared: max |dp| {d.max():.4f}, mean {d.mean():.5f}, "
          f"share within 0.01: {(d <= 0.01).mean():.3f}")
    # end state: py vs last infer.js value per agent
    e = np.abs(risk.p - last_js)
    print(f"end of run: max |dp| {e.max():.4f}, agents off by > 0.02: {(e > 0.02).sum()} / {len(agents)}")


if __name__ == "__main__":
    main(sys.argv[1])
