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

Agents move along the campus path network: footpaths, mapped sidewalks and crossings, and streets,
from `data/osm/paths.geojson` (`data/osm/build_paths.py --fetch` refreshes it from Overpass).
Each building's door is joined to the nearest walkable edge by a connector that doesn't cross another
building. Paths that run through a footprint cost 5× unless OSM marks them as passages
(covered/tunnel/indoor/layer) or `configs/map.json` lists them in `passage_ways` (the Main Quad
arcades). Courtyards of multipolygon buildings (`data/osm/building_holes.geojson`, from
`build_holes.py`) count as open ground.

**Biking.** `transport_mode` in `agents_static.csv` says whether an agent owns a bike (`bike_p` per
archetype in `configs/population.json`). Bike owners ride trips of at least 300 m
(`map.modes.bike_min_trip_m`) on bike-legal ways (no steps, no `bicycle=no`; cycleways and streets
preferred, sidewalks avoided) at `bike_mps`, and walk shorter hops at `walk_mps`. Per-mode edge
costs are in `configs/map.json` → `modes`. In the timeline, `transport_mode` is the current trip's
mode while moving.

Every run also writes `trips.csv.gz`: one row per trip with its route polyline. `view.py` uses it to
move agents along their route between steps (bikers are drawn as ◆). Without it, the 5-minute rows
would be joined by straight lines that cut through buildings. Turn it off with
`--set output.trips=false`.

Every run also writes `timeline_changes.csv.gz`, the compact timeline the heat map asked for
([docs/timeline-changes-format.md](../docs/timeline-changes-format.md)): only rows where something
changes plus the last row of each stay. It's about 5× smaller than `timeline.csv.gz`.

## Sample run

`runs/influenza_none_n10_d14_s2_bc5cae7a/` is a real 10-agent, 14-day run (one dorm plus one
commuter, two infections seeded at t=0). It has an aerosol infection, withheld self-reports, a
positive Vaden test, report_other events, recoveries and walking and biking trips. Point the heat map
at it with `?data=../sim/runs/influenza_none_n10_d14_s2_bc5cae7a/timeline.csv.gz`.

`runs/influenza_none_n10_d14_s2_f1f772f6/` is the same sample made before the path and biking changes. It is
kept because the heat map loads it by default (`heatmap/app.js` DEFAULT_RUN).

`runs/influenza_none_n500_d2_s42_aea9db72/` is a 500-agent, 2-day run with default settings (no seeded
cases, one import), made after the path and biking changes. `view.py` on it shows agents on paths.

`runs/influenza_none_n7000_d2_s42_5423d1a4/` is a full-size run: 7,000 agents, 2 days, seed 42,
default settings (6 imports, no campus spread yet in 2 days). Its files over GitHub's 100 MB limit
are committed in parts; rebuild them after cloning (see "Large runs in git").

## Large runs in git

`scripts/run_parts.py split runs/<run>` cuts each `.csv.gz` over 40 MB into
`parts/<name>/part-NNN.csv.gz` on row boundaries. Each part is a standalone gzipped CSV with the
header, and `parts/manifest.json` records the sha256 of every original and part. After cloning:

```bash
.venv/bin/python scripts/run_parts.py join runs/influenza_none_n7000_d2_s42_5423d1a4   # ~10 s
```

This rebuilds `contacts.csv.gz` and `timeline.csv.gz` byte-for-byte (checked against the manifest)
and regenerates `timeline_by_agent/`. The `.parquet` mirrors aren't committed or rebuilt; rerun the
sim with the same seed if you need them (output is byte-identical). Add the run's big files to
`sim/.gitignore` so only the parts are committed.

## Code

| Module | Does |
|---|---|
| `campussim/campus.py` | OSM buildings, typed locations, procedural rooms, walk/bike path graphs + routing, door connectors, entry points |
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

- `data/osm/`: OpenStreetMap extract (buildings, entrances, paths, building holes; © OpenStreetMap
  contributors, ODbL). `build.py` made buildings/entrances from an Overpass dump, `build_paths.py`
  makes paths (with access tags), and `build_holes.py` makes courtyards.
- `data/manual_places.json`: places missing from OSM (Green Library, Wilbur/Stern/FloMo dining,
  Frost Amphitheater, White Plaza, Meyer Green, the Oval, Engineering Quad, Main Quad courtyard,
  Lake Lagunita). Their ids are `bld_m_<slug>`.
- `data/location_overrides.json`: hand fixes to building types, capacities and floors.

## Known issues

- **Not calibrated.** At 7,500 agents × 7 days: 50 infections (27 imports); spread rate by day
  infected was about 1.5–1.8 for days 2–4, but `measured_R` needs a 14-day run.
- **Study rooms can still run up to 2× capacity.** Library and common-room flex picks now check
  capacity (`plans.flex.capacity_check`): each block books a place in a room with space for the whole
  block, weighted by free places, so Green Library's big reading rooms take most solo study. When
  everything is full, agents study at home. At 7,000 agents the worst planned room went from 22.5× to
  2× capacity. What's left comes from bookings outside flex (study groups and similar).
- **Large output.** 7,500 agents × 7 days is 4.5 GB, of which 3.0 GB is `timeline_by_agent/` and
  657 MB `contacts.csv.gz`. Turn per-agent files off with `--set output.by_agent=false`.
- **Small residual wall-crossing.** About 0.5 m per trip still runs through a footprint (500 agents,
  2 days). Causes: a few untagged OSM footways through dorms (Lakeside/Admin, Fairclough), and
  hand-placed areas in `data/manual_places.json` (Meyer Green, Engineering Quad, White Plaza) whose
  rectangles overlap real buildings. Also, the leg from an agent's spot in the room to the door is a
  straight line inside the building, since there are no corridors.
- Bikes ignore one-way rules.
- Infections on footpaths are labelled `unknown` in `summary.json` → `infections_by_location_type`.

## Mock run

`make_mock_run.py` writes `runs/mock_boring10/` (stdlib only): 10 near-identical agents for 3 days.
It predates the simulator and is kept for the heat map's default view.
