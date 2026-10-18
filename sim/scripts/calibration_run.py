"""Calibration run (docs/AGENT_FRAMEWORK.md section 4): ~300 agents for 7 days, 50 of them driven by
Claude (whole friend groups, Big Five, worry on), with oversampled events and a spend cap.

    .venv/bin/python scripts/calibration_run.py --dry-run                 # cost estimate, no API key
    .venv/bin/python scripts/calibration_run.py --budget 20               # real run (ANTHROPIC_API_KEY)
    .venv/bin/python scripts/calibration_run.py --budget 25 --opus-subset 10

Settings: configs/calibration.json. A real run first does the dry run and prints its estimate (skip it
with --no-estimate), then runs with a BudgetClient (campussim/budget.py) that stops calling the API at
--budget and writes cost.json. Every run writes calibration_forced.csv (t, agent_id, kind, detail):
kind = extra_seed | severity | alert | model.
"""
import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim.calibration import DryRunClient, Scenario, estimate, fmt_estimate  # noqa: E402
from campussim.config import CONFIG_DIR, deep_update, load_config  # noqa: E402
from campussim.engine import run  # noqa: E402


def load_calibration(path=None):
    return json.loads(Path(path or CONFIG_DIR / "calibration.json").read_text())


def build_cfg(cal, disease="influenza", run_over=None, set_args=(), opus_subset=None, model=None):
    over = deep_update(json.loads(json.dumps(cal["overrides"])), {"run": {**cal["run"], **(run_over or {})}})
    if model:
        over["llm_agents"]["model"] = model
    cfg = load_config(disease=disease, overrides=over, set_args=set_args)
    sc = json.loads(json.dumps(cal["scenario"]))
    if opus_subset is not None:
        sc["opus_subset"] = int(opus_subset)
    if sc.get("opus_subset"):
        sc["opus_model"] = cal.get("opus_model", "claude-opus-5-5")
    cfg["calibration"] = sc  # hashed into the run id
    return cfg


def dry_run(cal, cfg, quiet=True, keep_dir=None):
    """Runs the scenario with DryRunClient in a scratch cache + out dir; returns (estimate dict, run_dir, scenario)."""
    tmp = Path(tempfile.mkdtemp(prefix="calib_dry_"))
    c = json.loads(json.dumps(cfg))
    c["llm_agents"]["cache_dir"] = str(tmp / "cache")  # never read or pollute the real cache
    c["llm_agents"]["offline"] = False
    c["run"]["out_dir"] = str(keep_dir or tmp / "runs")
    client, sc = DryRunClient(), Scenario(c)
    run_dir = run(c, quiet=quiet, llm_client=client, scenario=sc)
    sc.write(run_dir)
    n_convos = sum(1 for _ in open(run_dir / "llm_conversations.jsonl")) if (run_dir / "llm_conversations.jsonl").exists() else 0
    est = estimate(client.records, cal, n_llm=int(c["llm_agents"]["n_agents"]),
                   opus_subset=int(c["calibration"].get("opus_subset") or 0), opus_applied=sc.opus_applied,
                   n_convos=n_convos)
    (run_dir / "cost_estimate.json").write_text(json.dumps(est, indent=1, sort_keys=True) + "\n")
    shutil.rmtree(tmp / "cache", ignore_errors=True)
    return est, run_dir, sc, tmp


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="estimate the cost with a fake client; no API calls")
    ap.add_argument("--keep", action="store_true", help="keep the dry run's output (default: deleted)")
    ap.add_argument("--no-estimate", action="store_true", help="real run without the dry run first")
    ap.add_argument("--budget", type=float, help="spend cap in USD (default: calibration.json budget_usd)")
    ap.add_argument("--opus-subset", type=int, help="K Claude agents on the Opus model (model-sensitivity check)")
    ap.add_argument("--model", help="model for the bulk of the Claude agents")
    ap.add_argument("--agents", type=int)
    ap.add_argument("--days", type=int)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--disease", default="influenza")
    ap.add_argument("--out", help="output dir (default: run.out_dir)")
    ap.add_argument("--calibration", help="alternative calibration.json")
    ap.add_argument("--set", action="append", default=[], metavar="key.path=value")
    a = ap.parse_args(argv)

    cal = load_calibration(a.calibration)
    run_over = {k: v for k, v in (("n_agents", a.agents), ("days", a.days), ("seed", a.seed), ("out_dir", a.out))
                if v is not None}
    cfg = build_cfg(cal, a.disease, run_over, a.set, a.opus_subset, a.model)
    budget = float(a.budget if a.budget is not None else cal.get("budget_usd", 20.0))
    cal["budget_usd"] = budget
    lc = cfg["llm_agents"]
    print(f"calibration: {cfg['run']['n_agents']} agents, {cfg['run']['days']} days, seed {cfg['run']['seed']}, "
          f"{lc['n_agents']} Claude agents ({lc['pick']}, {lc['model']}, effort {lc['effort']}), "
          f"opus subset {cfg['calibration'].get('opus_subset') or 0}, budget ${budget:.2f}", flush=True)

    if a.dry_run or not a.no_estimate:
        est, run_dir, sc, tmp = dry_run(cal, cfg, keep_dir=Path(a.out) if (a.keep and a.out) else None)
        print(fmt_estimate(est))
        print(f"forced events: {sc.frame().kind.value_counts().to_dict()}")
        if a.dry_run:
            if a.keep:
                print(f"dry run kept at {run_dir}")
            else:
                shutil.rmtree(tmp, ignore_errors=True)
            return est
        shutil.rmtree(tmp, ignore_errors=True)
        if est["total_usd"] > budget:
            print(f"warning: estimate ${est['total_usd']:.2f} is above the cap; the run will stop calling the "
                  f"API at ${budget:.2f} and the rest of the agents keep their default plans", flush=True)

    import anthropic
    from campussim.budget import BudgetClient
    client = BudgetClient(anthropic.Anthropic(), budget, cal["pricing"]["models"])
    sc = Scenario(cfg)
    run_dir = run(cfg, llm_client=client, scenario=sc)
    sc.write(run_dir)
    client.write(run_dir / "cost.json")
    s = client.summary()
    print(f"cost: ${s['spent_usd']:.2f} over {s['calls']} calls ({s['blocked_calls']} blocked by the cap); "
          f"wrote {run_dir / 'cost.json'} and calibration_forced.csv")
    return run_dir


if __name__ == "__main__":
    main()
