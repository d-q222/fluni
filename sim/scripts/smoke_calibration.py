"""Smoke test for the calibration run (fake clients only, no API key).

1. A small dry run prints a cost estimate (plan/talk/reflect calls, tokens, USD).
2. Forced events land in calibration_forced.csv and reach the Claude agents: every forced alert shows up
   as a FlUni notification in that agent's next prompt (llm_agents.jsonl), extra seeds are infections with
   route 'seed' inside Claude agents' friend groups, and severities follow the configured levels.
3. The budget cap: a fake client that reports usage; once the cap is reached no more calls reach it,
   blocked agents keep their default plan, and cost.json is written.
4. The calibration file doesn't change ordinary configs or run ids.
"""
import json
import shutil
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from calibration_run import build_cfg, dry_run, load_calibration  # noqa: E402
from campussim.budget import BudgetClient  # noqa: E402
from campussim.calibration import Scenario, fmt_estimate  # noqa: E402
from campussim.config import load_config  # noqa: E402
from campussim.engine import run  # noqa: E402
from campussim.llm_agents import ADVICE_TEXT  # noqa: E402


class UsageFake:
    """Returns a valid stay-home plan and fake usage (1000 in, 500 out = $0.007 on Sonnet 5.5)."""

    def __init__(self):
        self.calls = 0
        self.beta = SimpleNamespace(messages=self)

    def create(self, **req):
        self.calls += 1
        user = req["messages"][0]["content"]
        start = user.split("Plan the window ", 1)[1][:5]
        sch = req["output_config"]["format"]["schema"]
        place = sch["properties"]["blocks"]["items"]["properties"]["place"]["enum"][0]  # home, or off_campus
        out = {"thoughts": "", "wear_mask": False, "diary": "stayed in",
               "blocks": [{"start": start, "end": start, "activity": "relax", "place": place}]}
        for k in sch.get("required", []):  # fields other workstreams may add
            out.setdefault(k, 1 if sch["properties"][k].get("type") == "integer" else "")
        return SimpleNamespace(stop_reason="end_turn", model=req["model"],
                               usage=SimpleNamespace(input_tokens=1000, output_tokens=500,
                                                     cache_creation_input_tokens=0, cache_read_input_tokens=0),
                               content=[SimpleNamespace(type="text", text=json.dumps(out))])


def main():
    tmp = Path(tempfile.mkdtemp())
    cal = load_calibration()

    # 4. ordinary configs don't see calibration.json
    assert "calibration" not in load_config(), "calibration.json leaked into the normal config"

    # 1. + 2. small dry run, events forced into a 2-day window
    cal["scenario"]["extra_seeds"].update(n=4, t_days=[0, 1])
    cal["scenario"]["alerts"].update(n=6)
    cfg = build_cfg(cal, run_over={"n_agents": 120, "days": 2, "seed": 3, "out_dir": str(tmp / "runs")},
                    set_args=["llm_agents.n_agents=12"])
    est, run_dir, sc, scratch = dry_run(cal, cfg, keep_dir=tmp / "dry")
    print(fmt_estimate(est))
    bk = est["by_kind"]
    assert bk["plan"]["dry_calls"] >= 12 * 2, bk["plan"]
    assert est["total_usd"] > 0
    if "talk" in bk:
        assert bk["talk"]["calls"] == bk["talk"]["dry_calls"] * est["turns_per_conversation"]

    forced = pd.read_csv(run_dir / "calibration_forced.csv")
    print(forced.to_string(index=False))
    log = [json.loads(x) for x in (run_dir / "llm_agents.jsonl").read_text().splitlines()]
    claude = {r["agent_id"] for r in log}
    alerts = forced[forced.kind == "alert"]
    assert len(alerts) == 6 and set(alerts.agent_id) <= claude, alerts
    checked = 0
    for r in alerts.itertuples():
        kind = r.detail.split(";")[0]
        nxt = [x for x in log if x["agent_id"] == r.agent_id and x["t"] > r.t]
        if not nxt:
            continue  # alert after the agent's last plan of the run
        text = "FlUni app " + ADVICE_TEXT[kind].split("{")[0]
        assert text in nxt[0]["prompt"], (r, nxt[0]["prompt"][:2000])
        checked += 1
    assert checked >= 1, "no forced alert was followed by a prompt"
    print(f"OK: {checked}/{len(alerts)} forced alerts reached the next prompt as notifications")

    seeds = forced[forced.kind == "extra_seed"]
    inf = pd.read_csv(run_dir / "infections.csv")
    ags = pd.read_csv(run_dir / "agents_static.csv").set_index("agent_id")
    groups = set(ags.loc[sorted(claude), "friend_group_id"])
    assert len(seeds) == 4 and set(seeds.agent_id) <= set(ags.index[ags.friend_group_id.isin(groups)])
    seeded = set(inf[inf.route == "seed"].infectee_id if "infectee_id" in inf else inf[inf.route == "seed"].iloc[:, 1])
    assert set(seeds.agent_id) <= seeded, (seeds, seeded)
    sev = forced[forced.kind == "severity"]
    levels = {f"{k}:{v[0]:g}" for k, v in cal["scenario"]["severity_mix"]["levels"].items()}
    assert len(sev) >= 4 and set(sev.detail) <= levels, sev
    assert all("symptomatic=True" in d for d in seeds.detail)
    print(f"OK: {len(seeds)} extra seeds in Claude friend groups, severities {sorted(set(sev.detail))}")

    # dry run is reproducible
    est2, run_dir2, _, scratch2 = dry_run(cal, cfg, keep_dir=tmp / "dry2")
    assert (run_dir / "calibration_forced.csv").read_bytes() == (run_dir2 / "calibration_forced.csv").read_bytes()
    assert abs(est2["total_usd"] - est["total_usd"]) < 1e-9
    shutil.rmtree(scratch, ignore_errors=True)
    shutil.rmtree(scratch2, ignore_errors=True)

    # 3. budget cap
    bc_cal = load_calibration()
    bc_cal["scenario"]["alerts"]["n"] = 0
    cfg3 = build_cfg(bc_cal, run_over={"n_agents": 40, "days": 3, "seed": 5, "out_dir": str(tmp / "runs3")},
                     set_args=["llm_agents.n_agents=4", "llm_agents.conversations.on=false",
                               "llm_agents.max_workers=1", f"llm_agents.cache_dir={tmp / 'cache3'}"])
    fake = UsageFake()
    per_call = (1000 * 2.0 + 500 * 10.0) / 1e6
    client = BudgetClient(fake, budget_usd=5.5 * per_call, pricing=bc_cal["pricing"]["models"])
    sc3 = Scenario(cfg3)
    d3 = run(cfg3, quiet=True, llm_client=client, scenario=sc3)
    client.write(d3 / "cost.json")
    cost = json.loads((d3 / "cost.json").read_text())
    print("cost.json:", cost)
    assert fake.calls == client.calls == 6, (fake.calls, client.calls)   # 5.5 calls' worth -> 6th crosses the cap
    assert cost["capped"] and cost["blocked_calls"] >= 1 and cost["spent_usd"] >= client.budget - 1e-12
    assert cost["tokens"] == {"input": 6000, "output": 3000, "cache_write": 0, "cache_read": 0}
    log3 = [json.loads(x) for x in (d3 / "llm_agents.jsonl").read_text().splitlines()]
    applied = [r["applied"] for r in log3]
    assert applied[:6] == [True] * 6 and not any(applied[6:]), applied
    print(f"OK: cap ${client.budget:.4f} stopped API calls after {client.calls}; "
          f"{cost['blocked_calls']} later calls kept the default plan")
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
