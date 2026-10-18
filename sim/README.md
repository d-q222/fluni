# Synthetic agent data (sim)

Ground-truth simulation of student life on the Stanford campus: each agent's true position, room
and disease state over time, plus true contacts, room aerosol exposure, the transmission tree, and
self-reports/tests. No sensors are simulated; GPS/Bluetooth/ultrasound are derived downstream.
Owner: @aidenyj (see [WORKSTREAMS.md](../WORKSTREAMS.md)). Output format:
[docs/sim-output-format.md](../docs/sim-output-format.md). Full spec: [docs/SPEC.md](docs/SPEC.md).

> **Status:** the full simulator runs end to end at 10 and 7,500 agents. Influenza is calibrated
> to campus R ≈ 1.6 (target 1.3–2.0; see "Calibration"). `runs/mock_boring10/` (the
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
- Humidity: `configs/weather.json` sets outdoor RH and temperature (default 60%, 10 °C, optionally per
  day via `daily`). For influenza, heated indoor air (~30% RH by default) sets how fast airborne virus
  dies off in each room, using the same formula as `model/` and `exposure/`. Example:
  `--set 'weather.daily=[{"outdoor_rh_pct":80},{"outdoor_rh_pct":40}]'`.
- `--intervention`: `none` (baseline), `self_report_isolate` (acts only on what the app can see),
  `symptomatic_isolate_oracle` (reads ground truth; flagged as an oracle), `fluni` (the FlUni app in
  the loop: phone close-contact alerts, P(sick) advice from a Python port of `model/infer.js`, and
  self-report advice, each with a configurable action list, followed w.p. compliance; settings in
  `configs/interventions.json` → `fluni`, adoption is `population.has_app_rate`). A `fluni` run also
  writes `app_alerts.csv` (`t, agent_id, alert, p_sick, weighted_min`; one row per alert, followed or not).
  `scripts/check_psick.py <run>` checks the Python P(sick) against `model/cli.mjs` on a finished run.
- Housing: by default residents fill dorms one after another, so a run with fewer agents than
  campus lands in 1–3 dorms (1,000 agents: 77% in Florence Moore Hall).
  `--set population.housing.assignment=spread` instead fills whole bedrooms drawn at random from
  every dorm, so residents spread roughly in proportion to dorm capacity (1,000 agents: 53 dorms,
  at most 11% in one). The key is not in `configs/population.json`, so default run ids are unchanged.
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

## Claude-driven agents

By default every agent follows the scheduler's plan (`plans.py`) and a scripted sick response.
`--set llm_agents.n_agents=K` hands K agents (picked from the seed) to Claude, which decides their
day. The rest of the population is unchanged.

```bash
.venv/bin/pip install -r requirements-llm.txt        # anthropic SDK; needs ANTHROPIC_API_KEY
.venv/bin/python simulate.py --agents 100 --days 3 --initial-seeds 5 --set llm_agents.n_agents=10 \
    --set llm_agents.pick=friend_groups
```

- **Daily plan.** At `day_start_h` (4 AM) each agent gets its persona (archetype, dorm, team,
  how often it follows advice, wears masks, is honest, and what it usually does when sick), its diary from
  earlier days, how it feels (symptoms only when symptomatic, so asymptomatic agents feel fine), test results and app
  status, its app notifications, the scheduler's default plan, and a menu of places (home, dining,
  libraries, gyms, outdoor spots, common rooms, friends' dorms, Vaden, today's classes and events).
  It returns timed blocks (activity + place) and a diary line. The blocks replace that agent's plan
  for the next 24 h. Transit is inserted as in `plans.py`, so agents still walk or bike the path network.
- **Re-planning.** Symptom onset, a test result or FlUni app advice re-plans the rest of the day
  (`replan_on`, at most `max_replans_per_day`).
- **They talk to each other.** When two Claude agents are within 3 m (no wall between them), or in
  the same small room such as a dorm room, for 10 minutes, they have a conversation: alternating
  lines, one call per line, each written from the speaker's own prompt. A speaker knows its own
  symptoms, test result and app status (and can hide them), sees only what is visible about the
  other (a mask, coughing), and is told how they know each other (friends, roommate, dormmate,
  teammate, classmate, stranger). Strangers often just nod. Afterwards each one writes a memory and
  says whether the talk changes its day. If it does, the agent re-plans with the transcript in its
  notifications (trigger `conversation`), so a friend can talk it into a party or into getting tested.
  The memories go into later daily plans. Knobs are under `llm_agents.conversations` (`radius_m`,
  `small_room_max_capacity`, `min_minutes`, `max_turns`, `cooldown_h`, `max_per_agent_per_day`).
  Agents picked at random rarely meet, so use `llm_agents.pick=friend_groups`, which hands whole
  friend groups to Claude. Transcripts are written to `llm_conversations.jsonl`.
- **They decide for themselves.** For these agents the scripted response (isolate / Vaden / carry on)
  is off, and intervention actions become notifications instead of being applied (timeline `action`
  = `advised:<kind>`). Going to Vaden in a plan books a test. Self-reports still follow `reports.py`.
- **Output.** `llm_agents.jsonl`: one row per call (`t, agent_id, trigger, applied, prompt, response`).
- **Reproducible.** Each response is cached under `llm_cache/` by request hash. A rerun with the same
  seed and config makes no API calls and is byte-identical. Commit `llm_cache/` with a run so others can
  rebuild it without a key. `llm_agents.offline=true` never calls the API (a cache miss keeps the default plan).
  Without `llm_agents` the run id and output are exactly as before.
- **Cost.** One call per agent per day, plus re-plans, plus up to `max_turns` + 2 calls per conversation. Defaults: `claude-opus-5-5`, effort `low`.
  Change `llm_agents.model` / `llm_agents.effort` to trade cost for quality.
- `scripts/smoke_llm_agents.py` checks the plumbing with a fake client (no key needed).

## Calibration run

The scenario that measures Claude agents' behavior for fitting (step 6 of
[docs/AGENT_FRAMEWORK.md](docs/AGENT_FRAMEWORK.md)): 300 agents for 7 days, 50 of them Claude-driven
(whole friend groups, Big Five, worry on, `claude-sonnet-5-5` at effort low). Settings, prices and the
estimate's assumptions are in `configs/calibration.json`. That file isn't loaded into normal runs, so
their run ids don't change.

```bash
.venv/bin/python scripts/calibration_run.py --dry-run          # cost estimate; fake client, no key, ~20 s
.venv/bin/python scripts/calibration_run.py --budget 20        # real run (ANTHROPIC_API_KEY)
.venv/bin/python scripts/calibration_run.py --budget 25 --opus-subset 10   # 10 agents on claude-opus-5-5
```

- **Oversampling.** Each run makes rare events happen and logs every one to `calibration_forced.csv`
  (`t, agent_id, kind, detail`). `extra_seed` events are extra infections among members of Claude
  agents' friend groups, spread over days 0–3 and made symptomatic. `alert` events are FlUni app alerts
  sent to random Claude agents at random times, each with one advice kind (`isolate_until`,
  `wear_mask`, `leave_location`, `go_to_vaden`). They are added to the intervention's actions, so
  the agent gets them as notifications and re-plans, the same as with real alerts. `severity` events
  record peak severities for infections in those friend groups, drawn from `severity_mix` (mild /
  moderate / severe). All of it comes from its own RNG stream for the seed, so the rest of the sim is
  unchanged and `--opus-subset` doesn't change the forced events.
- **Dry run.** Runs the scenario with a fake client. It records each request's size (tokens ≈ chars/4)
  and gets back minimal responses: plans keep the default plan, and talk turns end after one line.
  It prints calls by type (plan, talk, reflect), input/output tokens and $. Talk calls are scaled
  by `estimate.turns_per_conversation`. Output tokens per call are assumptions, so update them from
  the first real `cost.json`. Today's system prompts (~300 tokens) are under Sonnet 5.5's
  512-token minimum for prompt caching, so the estimate prices them as uncached input.
  The default scenario comes to about $14 on Sonnet 5.5, or about $16 with `--opus-subset 10`.
- **Cost cap.** A real run first prints the dry-run estimate (`--no-estimate` skips it). Then it
  runs with `campussim/budget.py` `BudgetClient`, which prices each response's `usage`. Once the
  spend reaches `--budget` it stops calling the API and prints one warning. Agents then keep their
  default plans and talks end. `cost.json` in the run dir has calls, tokens and $ by model. Calls
  already in flight still finish, so the spend can pass the cap by up to about `max_workers` calls.
- `scripts/smoke_calibration.py` checks the dry run, the forced events and the cap with fake clients.

## Sample run

`runs/influenza_none_n10_d14_s2_bc5cae7a/` is a real 10-agent, 14-day run (one dorm plus one
commuter, two infections seeded at t=0). It has an aerosol infection, withheld self-reports, a
positive Vaden test, report_other events, recoveries and walking and biking trips. Point the heat map
at it with `?data=../sim/runs/influenza_none_n10_d14_s2_bc5cae7a/timeline.csv.gz`.

`runs/influenza_none_n10_d14_s2_f1f772f6/` is the same sample made before the path and biking changes. It is
kept because the heat map loads it by default (`heatmap/app.js` DEFAULT_RUN).

`runs/influenza_none_n500_d2_s42_aea9db72/` is a 500-agent, 2-day run with default settings (no seeded
cases, one import), made after the path and biking changes. `view.py` on it shows agents on paths.

The full-size 7,000-agent, 2-day run (`influenza_none_n7000_d2_s42_5423d1a4`) is archived: it was made
before the `report_other` rate fix, humidity and calibration, so 303 of its 303 `report_other`s are
false. It's kept, with all its parts, at the git tag `archive/sim-n7000-5423d1a4`:
`git checkout archive/sim-n7000-5423d1a4 -- sim/runs/influenza_none_n7000_d2_s42_5423d1a4`, then
`run_parts.py join` it (see "Large runs in git").

Two 1,000-agent, 14-day runs (seed 42, `output.by_agent=false`) have spread boosted above the
calibrated default so more of campus gets infected:

- `runs/influenza_none_n1000_d14_s42_f12e71fa/`: `--initial-seeds 30`, `transmission_scale=1.5`.
  17.9% infected by day 14, measured R 1.04.
- `runs/influenza_none_n1000_d14_s42_183f262b/`: `--initial-seeds 50`, `transmission_scale=2.0`.
  50.3% infected by day 14, measured R 1.32, still growing at the end.

Two 1,000-agent runs (seed 42, `--initial-seeds 50`, `transmission_scale=2.0`,
`output.by_agent=false`) use `--set population.housing.assignment=spread`, so the 900 residents
live in 53 dorms (at most 97 in one, Florence Moore Hall) instead of 77% in one:

- `runs/influenza_none_n1000_d4_s42_73b8452c/`: 4 days, for the live demo. 10.6% infected by day 4
  (50 seeded), new infections by day 52, 13, 17, 24. Files are under 40 MB, so nothing is split.
- `runs/influenza_none_n1000_d14_s42_25fe957a/`: 14 days. 22.3% infected by day 14, measured R
  0.86. Same settings as 183f262b (50.3%), but with residents spread out far fewer people catch it
  in dorms (69 vs 161) and common rooms (15 vs 96).

Except the 4-day spread run, their `contacts.csv.gz` and `timeline.csv.gz` are committed in parts, so run
`scripts/run_parts.py join runs/<run> --no-by-agent` after cloning.

## Calibration

`scripts/calibrate.py` sweeps `disease.transmission_scale` over full-size runs and reports
`measured_R` (mean secondary cases of those infected before day 14 − 7.5). Influenza uses **1.2**:
7,000 agents × 14 days, 40 seeded cases, seeds 1–2 gave R = 1.70 and 1.55 (1.0 → 1.35, 1.4 → 1.92).
At 1.2 the per-encounter checks (`calibration_report`) are roommate 26.8% (target 20–30%), seminar
1.24% (~1%) and party 10.1% (~8%). COVID-19 and norovirus are not calibrated yet.

```bash
.venv/bin/python scripts/calibrate.py --agents 7000 --days 14 --scales 1 1.2 1.4 --seeds 1 2 --jobs 2   # ~25 min
```

## Class schedules

By default (`schedule.sections.source = "explorecourses"`) every class is a real Winter 2025-26
section, with its real days, times and room (`data/courses/`, see "Data"). Each agent takes 3–5
courses:

- **Seats** follow real enrollment × the undergrad share for the course level (92% for courses
  under 100, down to 4% for 300+). They are scaled so all seats = `seat_slack` (1.25) × the courses
  agents want, and a class never seats more than its room holds. CS 106A, MATH 51 and CS 106B are
  the biggest classes, as on campus.
- **Class year** sets course level (`year_level_weight`): freshmen mostly take courses under 100,
  seniors 100–299. COLLEGE 1xx is freshmen only (90% take it), and PWR 1 is for years 1–2.
- **Major**: each agent draws a major group from its archetype (`majors.archetype_mix`), and
  courses in it get 1.5× (freshmen) to 5× (seniors) weight. The group isn't written to the output yet.
- **Labs**: a course's real LAB/LBS section is added when it fits. Discussion sections (DIS) aren't
  simulated.
- GSB, Law, School of Medicine and overseas (OSP) courses are left out.

The real rooms replace the procedural classrooms in their 45 buildings. Other rooms (labs,
libraries, lobbies) are unchanged. `--set schedule.sections.source=synthetic` brings back the old
invented catalog and time grid.

## Large runs in git

`scripts/run_parts.py split runs/<run>` cuts each `.csv.gz` over 40 MB into
`parts/<name>/part-NNN.csv.gz` on row boundaries. Each part is a standalone gzipped CSV with the
header, and `parts/manifest.json` records the sha256 of every original and part. After cloning:

```bash
.venv/bin/python scripts/run_parts.py join runs/<run>   # ~10 s for a 7,000-agent, 2-day run
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
| `campussim/schedule.py` | class sections (real ExploreCourses schedule by default), parties, hangouts, games/large events, study groups |
| `campussim/plans.py` | each agent's intended day: sleep, meals, classes, practice, flex, events, travel |
| `campussim/behavior.py` | actual movement along paths, in-room positions, masks, sickness overrides |
| `campussim/contacts.py` | true contacts per step (KD-tree, distance tiers) |
| `campussim/disease.py` | S→E→I_pre→I_sym/I_asym→R, viral load, close-contact + Wells-Riley aerosol, imports |
| `campussim/reports.py` | sick-behavior choice, Vaden tests, honest/dishonest self-reports, report_other |
| `campussim/interventions.py` | intervention hook (observable state only, unless an oracle) |
| `campussim/app_policy.py` | `fluni` intervention: the FlUni app's alerts and advice |
| `campussim/llm_agents.py` | Claude-driven agents: daily plans and re-plans from the Claude API, cached |
| `campussim/psick.py` | streaming P(sick), a step-by-step port of `model/infer.js` |
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
- `data/courses/`: real class schedules from [ExploreCourses](https://explorecourses.stanford.edu)'s
  public XML feed. `fetch_explorecourses.py` snapshots one quarter (`20252026_winter.csv.gz`: 10,904
  meetings, 254 departments). `build_rooms.py` maps location strings to buildings (numbered Quad
  rooms like `160-322` → Main Quad, `Gates B1` → Gates, `NVIDIA Auditorium` → Huang, …) and writes
  `rooms_20252026_winter.csv`: 338 named rooms in 45 buildings, covering 86% of real enrollment.
  The rest (`Departmental Room`, `School of Medicine Room`, ANKO, Raikes) goes to a generic classroom.
  Runs read only the snapshot, never the network. Refresh with
  `python3 data/courses/fetch_explorecourses.py --year 20252026 --term Winter && python3 data/courses/build_rooms.py`.

## Known issues

- **Calibration is tied to today's contact structure.** Changes to who meets whom (e.g. real class
  schedules) or to the disease model shift R; rerun `scripts/calibrate.py` after them. Real class
  schedules (2026-10-17) came after the R ≈ 1.6 calibration, so it needs a rerun.
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
