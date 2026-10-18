# ml/ — learned P(sick) from contacts only

Can a model that sees **only who was near whom** (the sim's `contacts` table) and **who the initial
cases were** predict who else gets infected? This directory holds a shared harness and the models
that compete on it:

| Model | What it is | Code |
|---|---|---|
| `meanfield` | Simple probabilistic update: hour-by-hour P(infected) propagation with the sim's own infectiousness curve and tier hazards; 3 fitted numbers | `fluniml/meanfield.py` |
| `mlp_full` | MLP + ReLU on 224 hand-built per-agent features (activity, minutes with seeds per day, 2- and 3-hop exposure in time order) | `fluniml/mlp.py`, `fluniml/features.py` |
| `mlp_seed`, `mlp_activity` | Same MLP with fewer feature groups (ablations) | same |
| `oracle_true_states` | **Reference, not a competitor.** Uses everyone's true infection times, so it shows how much is predictable at all | `fluniml/meanfield.py` (`oracle=True`) |
| `gat_daily` | Simple time-ordered GAT: GATv2-style sigmoid-gated edge attention + MLPs, unrolled one step per day (each day reads the previous day's states), survival loss on the infection day. Only tried within one 7k run so far (`train_gat_agent_split.py`, 90/10 agent split); after 8 steps it was no better than "no information" | `fluniml/gat_daily.py`, `scripts/train_gat_agent_split.py` |

**Within-run KL comparison (7,500-agent runs):** MLP, simple GAT and `model/meanfield.js` scored by KL divergence on
a held-out 10% of agents, with baselines: [`KL_RESULTS.md`](KL_RESULTS.md).

## The task

- **Input**: `contacts.parquet` aggregated to (hour, agent a, agent b) with minutes in 9 channels
  (indoor tiers 1–3, outdoor tiers 1–3, through-a-wall, same room ≥ 5 m, and same-room minutes
  divided by room occupancy). Plus the list of seeds. See `fluniml/data.py`.
- **Label**: 1 if a non-seed agent is infected at any point in the 14-day run (any route,
  including off-campus imports, which no contact model can predict).
- **Runs and splits** live in `runs.json` (globs, relative to the repo root):
  - `train`: the "slop training data" 1k run (`sim/runs/..._s42_a986df0a`) and its 7k run
    (`sim/runs/influenza_none_n7000_d14_s42_*`, once it's moved there), plus the extra 1k runs from
    `scripts/gen_runs.py` in `data/runs/`.
  - `stop`: 11 of the generated runs, used only for early stopping (never scored).
  - `val`: a second 1k run with the same settings as the slop 1k but sim seed 43
    (`data/val_runs/`). This is what `compare.py` scores.
  1k and 7k runs mix freely: each run is one graph and the loader streams `contacts.parquet` one
  day at a time, so a 7,000-agent run fits in 16 GB. Add frankenstein's runs by adding their paths.
- **Distribution shift**: the slop and val runs use the default transmission scale 1.2 with 30
  seeds; the generated extras use 1.5–3.0 with 10–40 seeds (bigger outbreaks).
- **Metrics** (`fluniml/metrics.py`): the headline numbers are per-run means (AUC, average
  precision, precision@k with k = true number infected), because pooled metrics also reward
  guessing which runs are big. Pooled AUC/AP, log loss, Brier and calibration error are reported too.

## Run it

```bash
# 1. runs: point ml/runs.json at them. Optional extra 1k training runs (varied seed, scale, seeds):
sim/.venv/bin/python ml/scripts/gen_runs.py --n 120 --start-seed 1000 --jobs 4   # ~45 min

# 2. models (ml/.venv: torch, numpy, pandas, pyarrow, scikit-learn, scipy, tabulate)
ml/.venv/bin/python ml/scripts/fit_meanfield.py
ml/.venv/bin/python ml/scripts/fit_meanfield.py --oracle
ml/.venv/bin/python ml/scripts/train_mlp.py --features full      # also: seed, activity

# 3. score everything in out/preds/ on the val runs
ml/.venv/bin/python ml/scripts/compare.py
```

Set up the venv with `uv venv ml/.venv --python 3.12 && uv pip install --python ml/.venv/bin/python
torch numpy pandas pyarrow scikit-learn tabulate`. `data/` and `out/` are not committed; the
first load of a run builds `data/cache/<run_id>.npz` (~6 s for 1k agents).

## Caveats

- **Behaviour leaks into contacts.** Sick agents rest, isolate or go to Vaden, so their contacts
  drop after symptom onset. Every model here sees whole-run contacts, so a learned model can pick
  up "this person went quiet" as a sign of illness. The MLP features use whole-run totals rather
  than per-day activity to limit this, but hop and seed features are per day. For a leak-free test,
  generate runs with sickness behaviour turned off.
- **What the contacts table can't show.** An agent alone in a room produces no rows, so the
  lingering-air dose after a sick person leaves is invisible. Rooms over 150 capacity only list
  pairs within 5 m, so their occupancy is undercounted.
- **Imports** (~0.5% of agents per run) are unpredictable from contacts and count as misses for
  every model.
