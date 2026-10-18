"""Build ml/KL_RESULTS.md from the per-run KL results (ml/out/kl/<run>/results.json, written by
kl_fixed.py / kl_frankenstein.py score), and copy those small files to ml/results/kl/ (ml/out is ignored).

    python3 ml/scripts/kl_summary.py
"""
import json
import shutil
from pathlib import Path

ML = Path(__file__).resolve().parents[1]
RUNS = [("fixed", "influenza_none_n7500_d14_s42_9776284a", "Old rule-based behaviour, sim transmission scale 1.2"),
        ("frankenstein", "influenza_none_n7500_d14_s42_17ed9cd6", "Behaviour calibrated from Claude-driven agents, sim transmission scale 1.446")]

# (key in results.json, label, group)
ROWS = [
    ("mlp_full", "MLP + ReLU (`full` features, 3-seed mean)", "ML, trained on 90%"),
    ("gat_daily", "Simple GAT (`gat_daily`)", "ML, trained on 90%"),
    ("meanfield_js_fit_reports", "`meanfield.js`, true prior + `lambdaScale` fitted with reports on train agents", "P(flu) algorithm"),
    ("meanfield_js_calibrated", "`meanfield.js`, true prior + `lambdaScale` from `--calibrate` (seeds, no reports)", "P(flu) algorithm"),
    ("meanfield_js", "`meanfield.js`, old defaults (2% prior, `lambdaScale` 0.901)", "P(flu) algorithm"),
    ("meanfield_js_raw+isotonic", "old-default `meanfield.js` + isotonic map fitted on train agents (reference)", "P(flu) algorithm"),
    ("const_train_rate", "constant P = train attack rate", "baseline"),
    ("const_val_rate", "constant P = val attack rate (cheats on prevalence)", "baseline"),
    ("uniform_0.5", "constant P = 0.5", "baseline"),
    ("perfect", "P = truth (floor)", "baseline"),
]


def f(x, d=3):
    return "–" if x is None else f"{x:.{d}f}"


def table(res):
    m = res["models"]
    real = [k for k, _, g in ROWS if k in m and g != "baseline" and "reference" not in dict((r[0], r[1]) for r in ROWS)[k]]
    best = min(m[k]["per_agent_kl"] for k in real)  # bold: best real model (not a baseline or reference row)
    out = ["| | Model | Per-agent KL | Aggregate KL | Calibration KL | AUC | AP | Mean P |",
           "|---|---|--:|--:|--:|--:|--:|--:|"]
    for key, label, group in ROWS:
        if key not in m:
            continue
        v = m[key]
        kl = f(v["per_agent_kl"], 4)
        if key in real and v["per_agent_kl"] == best:
            kl = f"**{kl}**"
        out.append(f"| {group} | {label} | {kl} | {f(v['aggregate_kl'], 4)} | {f(v['calib_kl'], 4)} | "
                   f"{f(v.get('auc'))} | {f(v.get('ap'))} | {f(v['mean_p'])} |")
    return "\n".join(out)


def main():
    dst = ML / "results" / "kl"
    dst.mkdir(parents=True, exist_ok=True)
    parts = []
    for name, run, what in RUNS:
        src = ML / "out" / "kl" / name
        res = json.loads((src / "results.json").read_text())
        for fn in ("results.json", "val_ids.json"):
            shutil.copy(src / fn, dst / f"{name}_{fn}")
        notes = [f"- `{k}`: {v['notes']}" for k, v in res["models"].items()
                 if v.get("notes") and k in dict((r[0], 1) for r in ROWS)]
        parts.append(f"## {name}: `{run}`\n\n{what}. Validation: {res['n_val']} agents, {res['n_val_pos']} infected "
                     f"({res['n_val_pos'] / res['n_val']:.1%}).\n\n{table(res)}\n\n<details><summary>Row notes</summary>\n\n"
                     + "\n".join(notes) + "\n\n</details>\n")
    head = (ML / "scripts" / "kl_summary_head.md").read_text()
    (ML / "KL_RESULTS.md").write_text(head + "\n" + "\n".join(parts))
    print("wrote", ML / "KL_RESULTS.md")


if __name__ == "__main__":
    main()
