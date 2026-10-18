"""Smoke test for Claude-driven agents, with a fake client (no API key, no network).

Two LLM agents in a 10-agent, 2-day run: the first stays home all day, the second goes to Green
Library 10:00-16:00. Checks the timeline follows those plans, the default run id is unchanged when
llm_agents is off, and a rerun from the cache (offline) is byte-identical.

Then two roommates who both stay in: they talk (each line written from the speaker's side, seeing the
other's earlier lines), remember it, re-plan because of it, and a cached rerun is byte-identical.
"""
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim.config import load_config  # noqa: E402
from campussim.engine import make_run_id, run  # noqa: E402


class FakeMessages:
    def __init__(self):
        self.calls = 0
        self.talk = []

    def create(self, **req):
        user = req["messages"][0]["content"]
        props = req["output_config"]["format"]["schema"]["properties"]
        if "say" in props:
            self.talk.append(user)
            first = "Nobody has said anything yet." in user
            out = {"say": "hey, you ok?" if first else "tested positive, staying in", "end": not first}
            return self._msg(out)
        if "memory" in props:
            return self._msg({"memory": "roommate tested positive", "replan": True})
        self.calls += 1
        start = re.search(r"Plan the window (\d\d:\d\d)", user).group(1)
        places = req["output_config"]["format"]["schema"]["properties"]["blocks"]["items"]["properties"]["place"]["enum"]
        if not FakeMessages.homebody or f"({FakeMessages.homebody})," in user.split("\n", 1)[0]:
            blocks = [{"start": start, "end": start, "activity": "relax", "place": "home"}]
        else:
            lib = next(p for p in places if p == "bld:bld_m_green_library")
            blocks = [{"start": start, "end": "10:00", "activity": "sleep", "place": "home"},
                      {"start": "10:00", "end": "16:00", "activity": "study", "place": lib},
                      {"start": "16:00", "end": start, "activity": "relax", "place": "home"}]
        return self._msg({"thoughts": "test", "wear_mask": False, "blocks": blocks, "diary": "test day"})

    @staticmethod
    def _msg(out):
        return SimpleNamespace(stop_reason="end_turn", model="fake",
                               content=[SimpleNamespace(type="text", text=json.dumps(out))])


def main():
    tmp = Path(tempfile.mkdtemp())
    base = {"run": {"n_agents": 10, "days": 2, "seed": 2, "initial_seeds": 2, "out_dir": str(tmp / "runs")}}
    assert make_run_id(load_config(overrides=base)) == make_run_id(
        load_config(overrides=base, set_args=["llm_agents.n_agents=0"])), "run id changed with llm off"

    sets = ["llm_agents.n_agents=2", f"llm_agents.cache_dir={tmp / 'cache'}", "llm_agents.conversations.on=false"]
    cfg = load_config(overrides=base, set_args=sets)
    fake = SimpleNamespace(beta=SimpleNamespace(messages=FakeMessages()))
    from campussim.population import build_population  # resolve which agents get picked
    import numpy as np
    from campussim.campus import Campus
    from campussim.config import ROOT
    campus = Campus.build(cfg["map"], data_dir=ROOT / "data" / "osm")
    rngs = np.random.SeedSequence(2).spawn(9)
    pop = build_population(cfg, campus, np.random.default_rng(rngs[1]))
    rng = np.random.default_rng([2, __import__("zlib").crc32(b"llm_agents")])
    idx = sorted(rng.choice(pop.N, size=2, replace=False).tolist())
    FakeMessages.homebody = pop.agent_id[idx[0]]
    lib_agent = pop.agent_id[idx[1]]

    d1 = run(cfg, quiet=True, llm_client=fake)
    print("fake API calls:", fake.beta.messages.calls)
    assert fake.beta.messages.calls == 2 * 2, fake.beta.messages.calls
    tl = pd.read_csv(d1 / "timeline.csv.gz")
    rooms = pd.read_csv(d1 / "map" / "rooms.csv")
    ags = pd.read_csv(d1 / "agents_static.csv")

    home_room = ags.set_index("agent_id").loc[FakeMessages.homebody]
    h = tl[(tl.agent_id == FakeMessages.homebody) & (tl.timestamp >= "2026-01-05T04:00")]
    print(FakeMessages.homebody, "rooms after 04:00:", h.room_id.value_counts().to_dict())
    assert h.room_id.nunique() == 1, "homebody left their room"

    lib_rooms = set(rooms[rooms.location_id == "bld_m_green_library"].room_id)
    g = tl[(tl.agent_id == lib_agent) & (tl.timestamp.str[11:16] >= "10:30") & (tl.timestamp.str[11:16] < "15:30")]
    share = g.room_id.isin(lib_rooms).mean()
    print(lib_agent, "share of 10:30-15:30 in Green Library:", round(share, 3))
    assert share > 0.95, share

    log = [json.loads(x) for x in (d1 / "llm_agents.jsonl").read_text().splitlines()]
    assert all(r["applied"] for r in log), "a plan was not applied"
    print("sample prompt:\n" + log[0]["prompt"][:1500])

    # rerun from cache: byte-identical (a cache miss would hit the dead client and fail)
    cfg2 = load_config(overrides={"run": {**base["run"], "out_dir": str(tmp / "runs2")}}, set_args=sets)
    d2 = run(cfg2, quiet=True, llm_client=SimpleNamespace(beta=None))
    for f in ("timeline.csv.gz", "llm_agents.jsonl", "contacts.csv.gz", "infections.csv"):
        assert (d1 / f).read_bytes() == (d2 / f).read_bytes(), f"{f} differs on rerun"
    print("OK: plans followed, run id unchanged when off, cached rerun byte-identical")

    # conversations: two roommates, both stay in all day
    hr = np.asarray(pop.home_room)
    pair = next([pop.agent_id[a], pop.agent_id[b]] for a in range(pop.N) for b in range(a + 1, pop.N)
                if hr[a] >= 0 and hr[a] == hr[b])
    FakeMessages.homebody = ""  # every plan: the homebody plan below
    sets3 = [f"llm_agents.agent_ids={json.dumps(pair)}", f"llm_agents.cache_dir={tmp / 'cache3'}"]
    cfg3 = load_config(overrides={"run": {**base["run"], "out_dir": str(tmp / "runs3")}}, set_args=sets3)
    fake3 = SimpleNamespace(beta=SimpleNamespace(messages=FakeMessages()))
    d3 = run(cfg3, quiet=True, llm_client=fake3)
    convos = [json.loads(x) for x in (d3 / "llm_conversations.jsonl").read_text().splitlines()]
    print("roommates", pair, "conversations:", len(convos), "at t =", [c["t"] for c in convos])
    assert len(convos) >= 2, convos
    assert all(len(c["lines"]) == 2 and len(c["reflections"]) == 2 for c in convos), convos[0]
    assert all(c["lines"][0]["speaker"] != c["lines"][1]["speaker"] for c in convos)
    assert '"hey, you ok?"' in fake3.beta.messages.talk[1], "second speaker did not hear the first line"
    print("second speaker's prompt:\n" + fake3.beta.messages.talk[1][-700:])
    log3 = [json.loads(x) for x in (d3 / "llm_agents.jsonl").read_text().splitlines()]
    re_ = [r for r in log3 if r["trigger"] == "conversation"]
    assert re_ and "tested positive, staying in" in re_[0]["prompt"], "no re-plan after a conversation"
    assert any("Recent conversations:" in r["prompt"] for r in log3 if r["trigger"] == "day"), "memory not carried over"
    cfg4 = load_config(overrides={"run": {**base["run"], "out_dir": str(tmp / "runs4")}}, set_args=sets3)
    d4 = run(cfg4, quiet=True, llm_client=SimpleNamespace(beta=None))
    for f in ("timeline.csv.gz", "llm_agents.jsonl", "llm_conversations.jsonl"):
        assert (d3 / f).read_bytes() == (d4 / f).read_bytes(), f"{f} differs on rerun"
    print(f"OK: {len(convos)} conversations, {len(re_)} re-plans after talking, cached rerun byte-identical")
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
