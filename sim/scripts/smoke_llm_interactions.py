"""Smoke test for Claude agents' interactions (AGENT_FRAMEWORK.md steps 3-5), with a fake client.

10 agents, 2 days, no random seeds. Friend group A0000, A0005, A0006, A0007, A0009; A0005, A0006 and
A0007 share a dorm triple. A0005 and A0006 are Claude agents; A0006 and A0007 (rule-based) are made
sick early on day 1. Rule-based recipients accept every text (p_accept.b forced high) and a warning
always sends them to Vaden. Worry is on (worry.py, or a stand-in where it does not exist yet).

Checks: Claude agents notice their coughing rule-based roommate (observation in the notifications,
saw_sick bump, a re-plan and a notice_reaction row); A0005's group dinner invite is accepted by
rule-based members and by A0006 (who answers in its next plan) and shows up in the timeline; A0005's
warning sends A0009 to Vaden for a test; A0006 tells A0005 it is sick (disclosure rows, friend_sick
bump); llm_events.csv has exactly the agreed columns; a cached rerun is byte-identical.
"""
import csv
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim import disease as disease_mod  # noqa: E402
from campussim import llm_agents as llm_mod  # noqa: E402
from campussim.config import load_config  # noqa: E402
from campussim.engine import run  # noqa: E402

COLUMNS = ["t", "timestamp", "agent_id", "archetype", "openness", "conscientiousness", "extraversion",
           "agreeableness", "neuroticism", "compliance", "mask_propensity", "honesty", "worry_before",
           "worry_after", "severity", "symptomatic", "behavior", "context", "relationship", "other_agent_id",
           "outcome", "value", "model"]
SENDER, CLAUDE2, SICK_RULE, WARNED = "A0005", "A0006", "A0007", "A0009"
ONSET = {CLAUDE2: 60, SICK_RULE: 2}  # symptom onset step (5-min steps: 05:00 and 00:10 on day 1)
try:  # the real worry state when it exists (the engine then attaches it), else a stand-in
    from campussim import worry as _worry  # noqa: E402,F401
    REAL_WORRY = True
except ImportError:
    REAL_WORRY = False


class FakeWorry:
    def __init__(self, n):
        self.level = np.full(n, 0.2)
        self.baseline = np.full(n, 0.2)
        self.bumps = []

    def bump(self, i, kind, t):
        self.bumps.append((int(i), kind, int(t)))
        self.level[i] = min(1.0, self.level[i] + 0.1)

    def set_measured(self, i, v, t):
        self.level[i] = v


class FakeMessages:
    def __init__(self):
        self.plans = []

    def create(self, **req):
        user = req["messages"][0]["content"]
        props = req["output_config"]["format"]["schema"]["properties"]
        me = re.search(r"\((A\d{4})\)", user.split("\n", 1)[0]).group(1)
        sick = "You feel fine." not in user
        if "say" in props:
            first = "Nobody has said anything yet." in user
            if sick:
                return self._msg({"say": "I've got a fever and a cough, keep your distance", "end": not first,
                                  "shared_health": True})
            return self._msg({"say": "hey, how's it going?", "end": not first, "shared_health": False})
        if "memory" in props:
            return self._msg({"memory": "talked with my roommate", "replan": False, "worry": 4 if sick else 2,
                              "messages": []})
        self.plans.append(user)
        start = re.search(r"Plan the window (\d\d:\d\d)", user).group(1)
        out = {"thoughts": "test", "wear_mask": "noticed" in user or "next to you in" in user,
               "worry": 4 if sick else 2, "diary": "test day"}
        blocks = [{"start": start, "end": start, "activity": "relax", "place": "home"}]
        msgs = []
        if me == SENDER and "Monday January 5, 04:00" in user:
            dining = re.search(r"^- (bld:[^:]+): [^\n]*\(dining\)", user, re.M).group(1)
            blocks = [{"start": start, "end": "18:30", "activity": "relax", "place": "home"},
                      {"start": "18:30", "end": "20:00", "activity": "eat", "place": dining},
                      {"start": "20:00", "end": start, "activity": "relax", "place": "home"}]
            msgs = [{"to": "group", "kind": "invite", "place": dining, "time": "18:30",
                     "text": "dinner 18:30, who's in?"},
                    {"to": WARNED, "kind": "warn", "place": "", "time": "",
                     "text": "flu is going around our dorm, maybe get tested"}]
        out["blocks"] = blocks
        if "messages" in props:
            out["messages"] = msgs
        if "accept" in props:
            out["accept"] = re.findall(r"^- \[(m\d+)\]", user, re.M)
        return self._msg(out)

    @staticmethod
    def _msg(out):
        return SimpleNamespace(stop_reason="end_turn", model="fake",
                               content=[SimpleNamespace(type="text", text=json.dumps(out))])


def patch():
    """Forced early symptoms for ONSET agents, and the stand-in worry object on the Claude agents."""
    d_init = disease_mod.Disease.__init__

    def init(self, cfg, campus, pop, rng):
        d_init(self, cfg, campus, pop, rng)
        ids = list(pop.agent_id)
        idx = np.array(sorted(ids.index(a) for a in ONSET), np.int64)
        self._infect(idx, 0, -1, "seed", -1, -1, 1.0)
        for a, t_on in ONSET.items():
            k = ids.index(a)
            self.t_infectious[k], self.t_onset[k], self.t_end[k] = 1, t_on, t_on + 2 * self.spd
            self.asym[k], self.peak_sev[k] = False, 0.6
    disease_mod.Disease.__init__ = init

    if REAL_WORRY:
        return
    l_init = llm_mod.LLMAgents.__init__

    def linit(self, cfg, campus, pop, *a, **k):
        l_init(self, cfg, campus, pop, *a, **k)
        self.worry = FakeWorry(pop.N)
    llm_mod.LLMAgents.__init__ = linit


def main():
    patch()
    tmp = Path(tempfile.mkdtemp())
    base = {"run": {"n_agents": 10, "days": 2, "seed": 2, "initial_seeds": 0}}
    sets = [f"llm_agents.agent_ids={json.dumps([SENDER, CLAUDE2])}", f"llm_agents.cache_dir={tmp / 'cache'}",
            "llm_agents.messages.p_accept.b.invite=50", "llm_agents.messages.p_accept.b.warn=50",
            "llm_agents.messages.p_vaden.warn=1.0"] + (["worry.mode=on"] if REAL_WORRY else [])
    cfg = load_config(overrides={"run": {**base["run"], "out_dir": str(tmp / "runs")}}, set_args=sets)
    fake = SimpleNamespace(beta=SimpleNamespace(messages=FakeMessages()))
    d1 = run(cfg, quiet=True, llm_client=fake)

    # llm_events.csv: exact columns
    with open(d1 / "llm_events.csv") as f:
        header = next(csv.reader(f))
    assert header == COLUMNS, header
    ev = pd.read_csv(d1 / "llm_events.csv", dtype=str, keep_default_na=False)
    print("llm_events rows by behavior:", ev.behavior.value_counts().to_dict())
    assert (ev.openness == "").all(), "Big Five columns should be empty with personality off"
    assert (ev.worry_after != "").all(), "worry columns should be filled with worry on"

    # notice: the coughing rule-based roommate
    log = [json.loads(x) for x in (d1 / "llm_agents.jsonl").read_text().splitlines()]
    obs = [r for r in log if r["trigger"] == "observation"]
    assert obs, "no re-plan after an observation"
    note = next(ln for ln in obs[0]["prompt"].splitlines() if "next to you in" in ln)
    print("observation:", note)
    assert SICK_RULE in note and ("cough" in note or "sniffle" in note), note
    nr = ev[ev.behavior == "notice_reaction"]
    assert len(nr) and (nr.context == "sick_nearby").all() and (nr.outcome == "1").any(), nr
    assert ((ev.behavior == "worry") & (ev.context == "saw_sick")).any(), "no saw_sick bump"
    per_day = pd.Series([(r["agent_id"], r["t"] // 288) for r in obs]).value_counts()
    assert per_day.max() <= 2, per_day

    # group invite: rule-based members answer at once, A0006 in its next plan; it goes into the timeline
    msgs = [json.loads(x) for x in (d1 / "llm_messages.jsonl").read_text().splitlines()]
    inv = next(m for m in msgs if m["kind"] == "invite")
    print("invite:", {k: inv[k] for k in ("id", "from", "to", "outcome", "accepted")})
    assert inv["outcome"] == "happened" and len(inv["accepted"]) >= 2 and CLAUDE2 in inv["accepted"], inv
    assert any(r["by"] == "rule" and r["accepted"] for r in inv["responses"]), inv["responses"]
    assert any(r["trigger"] == "message" and r["agent_id"] == CLAUDE2 for r in log), "no re-plan after a text"
    tl = pd.read_csv(d1 / "timeline.csv.gz")
    rooms = pd.read_csv(d1 / "map" / "rooms.csv")
    dinner = tl[(tl.timestamp >= "2026-01-05T18:45") & (tl.timestamp < "2026-01-05T19:15")]
    host_room = dinner[dinner.agent_id == SENDER].room_id.mode()[0]
    loc = rooms.set_index("room_id").loc[host_room, "location_id"]
    at = dinner[dinner.room_id == host_room].groupby("agent_id").size()
    rule_there = [a for a in at.index if a not in (SENDER, CLAUDE2) and at[a] >= 5]
    print(f"dinner in {host_room} ({loc}) 18:45-19:15, steps per agent:", at.to_dict())
    assert rule_there, "no rule-based member at the group dinner"
    infl = ev[(ev.behavior == "influence") & (ev.context == "invite")]
    assert len(infl) == len(inv["to"]) and set(infl.model) == {"rule", "fake"}, infl

    # warning -> Vaden
    warn = next(m for m in msgs if m["kind"] == "warn")
    assert warn["responses"][0]["vaden"], warn
    rt = pd.read_csv(d1 / "reports_tests.csv")
    assert ((rt.agent_id == WARNED) & (rt.event == "test_taken")).any(), "warned agent not tested at Vaden"
    print("warn:", warn["responses"][0])

    # disclosure and the sick response
    dc = ev[ev.behavior == "disclosure"]
    print("disclosure rows:", dc[["t", "agent_id", "other_agent_id", "relationship", "outcome"]].to_dict("records"))
    assert ((dc.agent_id == CLAUDE2) & (dc.outcome == "1")).any(), dc
    assert ((ev.behavior == "worry") & (ev.context == "friend_sick") & (ev.agent_id == SENDER)).any()
    sr = ev[ev.behavior == "sick_response"]
    assert list(sr.agent_id) == [CLAUDE2] and sr.outcome.iloc[0] in ("stay_home", "vaden", "carry_on"), sr
    print("sick_response:", sr[["context", "outcome", "value", "severity"]].to_dict("records"))
    convos = [json.loads(x) for x in (d1 / "llm_conversations.jsonl").read_text().splitlines()]
    assert any(ln["shared_health"] for c in convos for ln in c["lines"])

    # cached rerun: byte-identical, no API calls
    cfg2 = load_config(overrides={"run": {**base["run"], "out_dir": str(tmp / "runs2")}}, set_args=sets)
    d2 = run(cfg2, quiet=True, llm_client=SimpleNamespace(beta=None))
    for f in ("timeline.csv.gz", "llm_agents.jsonl", "llm_conversations.jsonl", "llm_messages.jsonl",
              "llm_events.csv", "reports_tests.csv"):
        assert (d1 / f).read_bytes() == (d2 / f).read_bytes(), f"{f} differs on rerun"
    print(f"OK: notice, group invite, warning -> Vaden, disclosure, llm_events.csv ({len(ev)} rows), "
          "cached rerun byte-identical")
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
