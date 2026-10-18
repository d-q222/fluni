#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""
Fit --lambda-scale for mean_field.py to a sim run.

The calculator's lambda (../flu_risk.py) is not fitted to anything, and the
sim's own transmission differs from it (low emission while sleeping, masks,
sick people staying home). This script uses ground truth only to fit one
number: it starts the mean-field from the sim's true seed cases, with no prior
and no reports, and bisects the dose multiplier until the model's expected
cumulative infections at the end of the run match the sim's.

It also prints the cruder check: lambda summed over every contact between a
truly infected and a truly susceptible person, against the sim's count.

    uv run exposure/network/calibrate.py sim/runs/<run_id>
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mean_field as mf  # noqa: E402


def naive_ratio(m, ti, actual):
    expected = 0.0
    for n in range(m.n_steps):
        pr = m.pairs[n]
        if pr is None:
            continue
        mid = n * m.W + m.W // 2
        k = np.floor((mid - ti) * m.step_min / 1440 / m.dt_days).astype(int)
        stage = np.where((k >= 0) & (k < m.K), m.stage[np.clip(k, 0, m.K - 1)], 0.0)
        susceptible = ti > mid
        for src, dst in ((pr["a"], pr["b"]), (pr["b"], pr["a"])):
            lam = -np.expm1(-mf.fr.QUANTA_PEAK * pr["D"] * stage[src])
            expected += float((lam * susceptible[dst]).sum())
    return expected


def seeded_run(m, seeds, scale):
    m.p["lambda_scale"] = scale
    S, A, R = m.init_state()
    for i in seeds:
        S[i], A[i], A[i, 0] = 0, 0, 1
    st = (S, A, R)
    for n in range(m.n_steps):
        st, _ = m.step(n, st, [])
    return float((1 - st[0]).sum())


def main():
    run = sys.argv[1].rstrip("/")
    params = dict(mf.PARAMS, prior=0.0)
    m = mf.Model(run, params)
    rows = list(mf.read_csv(os.path.join(run, "infections.csv")))
    seeds = [m.idx[r["infectee_id"]] for r in rows if r["route"] == "seed"]
    ti = np.full(m.N, 10**9, dtype=np.int64)
    for r in rows:
        i = m.idx[r["infectee_id"]]
        ti[i] = min(ti[i], int(r["t"]))
    on_campus = sum(r["route"] in ("close", "aerosol") for r in rows)
    total = len({r["infectee_id"] for r in rows})

    naive = naive_ratio(m, ti, on_campus)
    print(f"sim: {total} infected, {len(seeds)} seeds, {on_campus} on campus")
    print(f"lambda summed over true infected-susceptible contacts: {naive:.1f} "
          f"(ratio {on_campus / naive:.3f})")

    lo, hi = 0.0, 1.0
    for _ in range(20):
        mid = (lo + hi) / 2
        if seeded_run(m, seeds, mid) < total:
            lo = mid
        else:
            hi = mid
    scale = (lo + hi) / 2
    print(f"mean-field from the true seeds matches {total} infections at lambda_scale = {scale:.4f}")
    print(f"\n    uv run exposure/network/mean_field.py {run} --lambda-scale {scale:.3f}")


if __name__ == "__main__":
    main()
