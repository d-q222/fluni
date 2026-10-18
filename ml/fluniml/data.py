"""Load sim runs into the one input every model shares: hourly pair contacts plus the seeds.

What a model may see (see ml/README.md):
  - contacts.parquet, aggregated to (hour, agent a, agent b) with minutes in 9 channels
  - which agents were the initial seeds (route == "seed" in infections.csv)
What a model is scored on:
  - label = 1 if a non-seed agent was infected at any time in the run (any route, incl. imports)

Channels (minutes in that hour; every contact row is one 5-minute step):
  0-2  in_t1, in_t2, in_t3   indoors, same room, tier 1/2/3 (<1 m, 1-2 m, 2-5 m)
  3-5  out_t1, out_t2, out_t3 outdoors, tier 1/2/3
  6    wall                  indoors, < 5 m but no shared room (through a wall)
  7    room_t4               same room, >= 5 m apart (only listed for rooms of capacity <= 150)
  8    room_share            same room (any tier), each 5-minute step divided by the number of
                             people seen in that room at that step. The sim's shared-air dose per
                             pair falls with room volume; occupancy is the contacts table's proxy.
                             Overlaps channels 0-2 and 7 (it is a re-weighting, not a new contact).
"""
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow.parquet as pq

ML = Path(__file__).resolve().parents[1]
CACHE = ML / "data" / "cache"
CHANNELS = ["in_t1", "in_t2", "in_t3", "out_t1", "out_t2", "out_t3", "wall", "room_t4", "room_share"]
STEPS_PER_HOUR = 12


@dataclass
class Run:
    run_id: str
    agent_ids: np.ndarray   # (N,) str
    seed: np.ndarray        # (N,) bool, initial cases (known to the model)
    label: np.ndarray       # (N,) float32, infected during the run (seeds: 1, never scored)
    t_inf: np.ndarray       # (N,) int32, hour infected, -1 if never (ground truth, oracle only)
    route: np.ndarray       # (N,) str, how each agent was infected ("" if never)
    hours: int              # run length in hours
    hour: np.ndarray        # (E,) int32, edge hour
    a: np.ndarray           # (E,) int32, agent index (a < b)
    b: np.ndarray           # (E,) int32
    ch: np.ndarray          # (E, 9) float32, minutes per channel in that hour
    config: dict            # the run's full config.json (disease params etc.)

    @property
    def N(self):
        return len(self.agent_ids)

    @property
    def scored(self):
        """Agents that count for metrics: everyone except the seeds."""
        return ~self.seed


def _day_edges(c: pd.DataFrame, idx, N):
    """Hourly (key, channel minutes) for one batch of contact rows that holds whole steps."""
    a = c.agent_a.map(idx).to_numpy(np.int64)
    b = c.agent_b.map(idx).to_numpy(np.int64)
    a, b = np.minimum(a, b), np.maximum(a, b)
    tier = c.distance_tier.to_numpy(np.int64)
    indoor = c.indoor.to_numpy(bool)
    room = c.room_id.fillna("").to_numpy(str)
    has_room = room != ""
    chan = np.full(len(c), -1, np.int64)
    close = tier <= 3
    chan[indoor & has_room & close] = tier[indoor & has_room & close] - 1
    chan[~indoor & close] = tier[~indoor & close] + 2
    chan[indoor & ~has_room & close] = 6
    chan[tier == 4] = 7
    assert (chan >= 0).all(), "unexpected contact row type"
    t = c.t.to_numpy(np.int64)
    key = ((t // STEPS_PER_HOUR) * N + a) * N + b
    uk, inv = np.unique(key, return_inverse=True)
    ch = np.zeros((len(uk), len(CHANNELS)), np.float32)
    np.add.at(ch, (inv, chan), 5.0)
    # occupancy: distinct agents seen in a room at a step (rows with any room_id, as in the sim)
    occ_df = pd.DataFrame({"t": np.concatenate([t, t]), "r": np.concatenate([room, room]),
                           "g": np.concatenate([a, b])})
    occ_df = occ_df[occ_df.r != ""].drop_duplicates()
    occ = occ_df.groupby(["t", "r"]).size()
    in_room = indoor & has_room
    n_occ = occ.reindex(pd.MultiIndex.from_arrays([t[in_room], room[in_room]])).to_numpy()
    np.add.at(ch[:, 8], inv[in_room], 5.0 / n_occ)
    return uk, ch


def _build(run_dir: Path):
    cfg = json.load(open(run_dir / "config.json"))
    agents = pd.read_csv(run_dir / "agents_static.csv", usecols=["agent_id"]).agent_id
    agents = agents.to_numpy().astype(str)
    idx = {a: i for i, a in enumerate(agents)}
    N = len(agents)
    days = int(cfg["params"]["run"]["days"])
    step_min = float(cfg["params"]["run"]["step_min"])
    assert step_min == 5, "channels assume 5-minute steps"

    # Stream the contacts one row group at a time (the sim writes one per day), so a 7,000-agent
    # run fits in memory. Rows of a batch's last step are held back and joined to the next batch,
    # so a step is never split even if row groups don't line up with days.
    cols = ["t", "agent_a", "agent_b", "distance_tier", "room_id", "indoor"]
    pf = pq.ParquetFile(run_dir / "contacts.parquet")
    keys, chs, carry = [], [], None
    for g in range(pf.num_row_groups):
        c = pf.read_row_group(g, columns=cols).to_pandas()
        if carry is not None:
            c = pd.concat([carry, c], ignore_index=True)
        if g < pf.num_row_groups - 1:
            last = c.t.to_numpy() == c.t.max()
            carry, c = c[last], c[~last]
        if len(c):
            k, ch = _day_edges(c, idx, N)
            keys.append(k)
            chs.append(ch)
    uk, inv = np.unique(np.concatenate(keys), return_inverse=True)
    ch = np.zeros((len(uk), len(CHANNELS)), np.float32)
    np.add.at(ch, inv, np.concatenate(chs))     # an hour can span two batches
    del keys, chs

    inf = pd.read_csv(run_dir / "infections.csv")
    seed = np.zeros(N, bool)
    seed[[idx[x] for x in inf.infectee_id[inf.route == "seed"]]] = True
    label = np.zeros(N, np.float32)
    route = np.full(N, "", object)
    t_inf = np.full(N, -1, np.int32)
    ii = inf.infectee_id.map(idx).to_numpy()
    label[ii] = 1.0
    t_inf[ii] = inf.t.to_numpy() // STEPS_PER_HOUR
    route[ii] = inf.route.to_numpy()
    return dict(agent_ids=agents, seed=seed, label=label, t_inf=t_inf, route=route.astype(str),
                hours=days * 24, hour=(uk // (N * N)).astype(np.int32),
                a=((uk // N) % N).astype(np.int32), b=(uk % N).astype(np.int32), ch=ch,
                config=json.dumps(cfg))


def load_run(run_dir) -> Run:
    run_dir = Path(run_dir)
    CACHE.mkdir(parents=True, exist_ok=True)
    f = CACHE / f"{run_dir.name}.npz"
    if not f.exists():
        np.savez_compressed(f, **_build(run_dir))
    z = np.load(f, allow_pickle=False)
    return Run(run_id=run_dir.name, agent_ids=z["agent_ids"], seed=z["seed"], label=z["label"],
               t_inf=z["t_inf"], route=z["route"], hours=int(z["hours"]), hour=z["hour"],
               a=z["a"], b=z["b"], ch=z["ch"], config=json.loads(str(z["config"])))


REPO = ML.parent
MANIFEST = ML / "runs.json"
SPLITS = ("val", "stop", "train")   # precedence when a run matches more than one split
NEEDED = ["contacts.parquet", "infections.csv", "agents_static.csv", "config.json", "summary.json"]


def _resolve(patterns):
    out = []
    for p in patterns:
        hits = sorted(REPO.glob(p)) if any(ch in p for ch in "*?[") else [REPO / p]
        hits = [d for d in hits if d.is_dir() and all((d / f).exists() for f in NEEDED)]
        if not hits:
            print(f"runs.json: nothing usable matches {p!r}, skipping", file=sys.stderr)
        out += hits
    return out


def splits(manifest=MANIFEST):
    """{split: [run dirs]} from ml/runs.json, each run in exactly one split."""
    m = json.load(open(manifest))
    seen, out = set(), {}
    for sp in SPLITS:
        dirs = []
        for d in _resolve(m.get(sp, [])):
            if d.name not in seen:   # run_id = dir name, also the cache key
                seen.add(d.name)
                dirs.append(d)
        out[sp] = dirs
    return out


def run_dirs(split=None, manifest=MANIFEST):
    s = splits(manifest)
    return [d for sp in SPLITS for d in s[sp]] if split is None else s[split]


def load_split(split, manifest=MANIFEST):
    return [load_run(d) for d in run_dirs(split, manifest)]


def meta(run: Run) -> Run:
    """The run without its edge arrays (labels, seeds and ids only), to keep many runs in memory."""
    e = np.zeros(0, np.int32)
    return Run(run.run_id, run.agent_ids, run.seed, run.label, run.t_inf, run.route, run.hours,
               e, e, e,
               np.zeros((0, len(CHANNELS)), np.float32), run.config)
