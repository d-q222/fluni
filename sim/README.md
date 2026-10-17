# Synthetic agent data (sim)

Ground-truth simulation of student life on the Stanford campus: each agent's true position, room
and disease state over time, plus true contacts, room aerosol exposure, the transmission tree, and
self-reports/tests. No sensors are simulated; GPS/Bluetooth/ultrasound are derived downstream.
Owner: @aidenyj (see [WORKSTREAMS.md](../WORKSTREAMS.md)). Output format:
[docs/sim-output-format.md](../docs/sim-output-format.md). Full spec: [docs/SPEC.md](docs/SPEC.md).

> **Status:** the full simulator runs end to end at 10 and 7,500 agents. Transmission is **not yet
> calibrated** to the target campus R of 1.3–2.0 (see "Known issues"). `runs/mock_boring10/` (the
> hand-made mock) is kept because the heat map loads it by default.

## Run it

```bash
cd sim
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt   # numpy, pandas, pyarrow, scipy

.venv/bin/python simulate.py --agents 10 --days 14 --seed 2 --initial-seeds 2      # ~5 s
.venv/bin/python simulate.py --agents 7500 --days 14 --step-min 5 --seed 42 \
    --disease influenza --intervention none --out runs/      # est. ~5 min, ~9 GB (7 days took 2.4 min, 4.5 GB)
.venv/bin/python view.py runs/<run_id>      # writes runs/<run_id>/viewer.html and opens it
```

- `--set key.path=value` overrides any parameter (e.g. `--set disease.transmission_scale=1.5`);
  `--config file.json` deep-merges a JSON file. Parameters live in `configs/*.json`, one file per
  module; disease presets (influenza, covid19, norovirus) are in `configs/diseases.json`.
- `--intervention`: `none` (baseline), `self_report_isolate` (acts only on what the app can see),
  `symptomatic_isolate_oracle` (reads ground truth; flagged as an oracle).
- Same seed + config → byte-identical output. The run id is
  `{disease}_{intervention}_n{N}_d{days}_s{seed}_{confighash}`, with no wall-clock time.

Every run also writes `timeline_changes.csv.gz`, the compact timeline the heat map asked for
([docs/timeline-changes-format.md](../docs/timeline-changes-format.md)): only rows where something
changes plus the last row of each stay. It's about 5× smaller than `timeline.csv.gz`.

## Sample run

`runs/influenza_none_n10_d14_s2_f1f772f6/` is a real 10-agent, 14-day run (one dorm plus one
commuter, two infections seeded at t=0). It has a close-contact infection and an aerosol infection,
a withheld self-report, a positive Vaden test, report_other events and a recovery. Point the heat map
at it with `?data=../sim/runs/influenza_none_n10_d14_s2_f1f772f6/timeline.csv.gz`.

## Code

| Module | Does |
|---|---|
| `campussim/campus.py` | OSM buildings, typed locations, procedural rooms, path graph + routing, entry points |
| `campussim/population.py` | agents and archetypes (studious, social, athlete, stem, commuter, homebody) |
| `campussim/schedule.py` | class sections, parties, hangouts, games/large events, study groups |
| `campussim/plans.py` | each agent's intended day: sleep, meals, classes, practice, flex, events, travel |
| `campussim/behavior.py` | actual movement along paths, in-room positions, masks, sickness overrides |
| `campussim/contacts.py` | true contacts per step (KD-tree, distance tiers) |
| `campussim/disease.py` | S→E→I_pre→I_sym/I_asym→R, viral load, close-contact + Wells-Riley aerosol, imports |
| `campussim/reports.py` | sick-behavior choice, Vaden tests, honest/dishonest self-reports, report_other |
| `campussim/interventions.py` | intervention hook (observable state only, unless an oracle) |
| `campussim/output.py`, `summary.py` | deterministic CSV/gzip/Parquet writers, summary.json |
| `campussim/engine.py`, `simulate.py` | main loop and CLI |
| `view.py` | map animation viewer (MapLibre + OpenFreeMap) |

`docs/CONTRACT.md` pins the interfaces between modules. `scripts/smoke_*.py` are per-module checks
(`for s in scripts/smoke_*.py; do .venv/bin/python $s; done`).

## Data

- `data/osm/`: OpenStreetMap extract (buildings, entrances, paths; © OpenStreetMap contributors,
  ODbL). `build.py` made it from an Overpass dump.
- `data/manual_places.json`: places missing from OSM (Green Library, Wilbur/Stern/FloMo dining,
  Frost Amphitheater, White Plaza, Meyer Green, the Oval, Engineering Quad, Main Quad courtyard,
  Lake Lagunita). Their ids are `bld_m_<slug>`.
- `data/location_overrides.json`: hand fixes to building types, capacities and floors.

## Known issues

- **Not calibrated.** At 7,500 agents × 7 days: 50 infections (27 imports); spread rate by day
  infected was about 1.5–1.8 for days 2–4, but `measured_R` needs a 14-day run.
- **Library study rooms are overfilled.** Plans send solo library study to study rooms with no
  capacity check (up to 114 agents in a room for 4–8), which makes them the main aerosol hotspot.
- **Too many `report_other` events** (about 50 per real self-report at full scale).
- **Large output.** 7,500 agents × 7 days is 4.5 GB, of which 3.0 GB is `timeline_by_agent/` and
  657 MB `contacts.csv.gz`. Turn per-agent files off with `--set output.by_agent=false`.
- Infections on footpaths are labelled `unknown` in `summary.json` → `infections_by_location_type`.

## Mock run

`make_mock_run.py` writes `runs/mock_boring10/` (stdlib only): 10 near-identical agents for 3 days.
It predates the simulator and is kept for the heat map's default view.
