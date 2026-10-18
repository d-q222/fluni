# Heat map

> **Status: tentative v1.** It runs on placeholder data, and the base map choice isn't final.

Stanford campus map showing where infections are likely concentrated, played back over time from
the agent timeline CSV. Owner: @d-q222 (see [WORKSTREAMS.md](../WORKSTREAMS.md)).

## Run it

Live demo: `heatmap/tools/demo.sh` starts the server and opens the page; the run-of-show is [DEMO.md](DEMO.md).

Serve the **repo root** (not `heatmap/`), so the page can reach the sim's output in `../sim`.
Caching is off, so a reload always runs the latest code:

```bash
cd fluni && git pull && python3 heatmap/tools/serve.py   # port 8000
```

Open http://localhost:8000/heatmap/. It loads the sim's real 10-agent, 14-day run from GitHub
(`sim/runs/influenza_none_n10_d14_s2_bc5cae7a/`). If that isn't reachable it says so on screen; it no
longer falls back silently to mock or fake data (use `?run=mock_boring10` or `?data=data/fake_agents.csv`
on purpose). Building outlines come from the run's
`map/buildings.csv` footprints, which cover places missing from OSM such as Green Library.

URL options, which can be combined:

- `?run=<name>`: load `sim/runs/<name>/`, e.g. `?run=mock_boring10`.
- `?why=1` (with `?agent=`): open the "Why this %?" panel (the same as the button on the presenter
  bar). It shows the model's contact graph, the formula with that person's numbers, and the
  evidence on record (`mathpanel.js`).
- `?data=path/to/timeline.csv[.gz]`: load another run (relative to `heatmap/`), e.g.
  `?data=../sim/runs/<run>/timeline.csv.gz`.
- `?at=200`: open at a moment, in minutes from the start of the data.
- `?agent=A0008`: open with that agent's phone showing. Handy for demo scenes.
- `?view=public`: open on the user-facing map. Add `&horizon=60` (or 120 or 180) for a forecast.
- `?embed=app`: the Swift app's heat map tab (`proximity/FluniProx/HeatmapView.swift`). Only the
  user-facing map, full screen, playing slowly and looping; the time and forecast picker float on top.
  Serve the repo root and point the tab at `http://<laptop>.local:8000/heatmap/?embed=app`.
- `?zoom=19` (with `?agent=`): open close up on that person. Useful with
  `?view=airflow`, e.g. `?view=airflow&color=truth&at=4200&agent=A0002&zoom=19` to watch a sick
  roommate's air fill a Branner dorm room and leak into the corridor.
- `?view=catch`: "Chance of catching flu here (1 h)". Darkness at a spot is proportional to the
  chance you'd catch flu standing there for an hour (full at 1%). Each person leaves an exponentially
  fading circle of hazard (`riskfield.js`): its peak is λ's near-field dose at 1 m for 1 h, times the
  person's expected infectiousness from the mean-field model (`model/meanfield.js`: P(flu) at each
  infection age × that stage's shedding), diluted 5× outdoors. Circles add up as hazards,
  P = 1 − exp(−Σ). `&fade=5` sets the fade length in metres (default 5). Big runs need
  `node model/meanfield-cli.mjs sim/runs/<run>` first. With `?color=truth` it uses who is actually infectious.
- `?model=meanfield`: people's P(sick) from Baker et al.'s mean-field (`model/meanfield.js`) instead of
  `model/infer.js`. No "Why this %?" panel then.
- `?color=truth`: dots *and* demo heat follow the sim's true status (who is actually infectious)
  instead of the app's estimate. This is the same as choosing "Color: true status (sim)".

Demo scenes on the sim's mock run:

- `?at=2115&agent=A0008`: Tue 11:15. The person next to A0008 in class is sick.
- `?at=4200&agent=A0002`: Wed 22:00. A0002 walks back into the dorm room where their reported-sick
  roommate is isolating, which triggers the walk-in warning.
- `?view=public&horizon=60&at=2115`: the user-facing map with a forecast for one hour ahead.

## Demo map vs. user map

- **Demo map** (presenter): sees everything, including agent dots, room-level heat and true status.
- **Phone mock** (click a person): drawn like the current FlUni app (flu-design2): `phone-views.js` builds Today (a "your day" timeline of
  buildings, Lisa's tissue narrating, a close contact that opens in place, the 5-day stay-home track with the Self-reported stamp for
  anyone who reported symptoms), You, the report sheet with her stickers and "How is this calculated?"; `phone.css` styles it with the
  app's fonts (`assets/fonts/`, OFL). Campus is the user map. Numbers are unchanged: this phone's estimate (doseModel) is the one number
  on Today; the campus-model P is shown only in the presenter bar and in the calculation sheet "for comparison". Taps are visual only.
- **"What users see"** is drawn exactly as FlUni's map is: `userscale.js` (scale rule, MIN_PEOPLE) and `userstyle.js`
  (colours, colour max, halo) are shared with `tools/precompute.mjs` and `usermap.js`, so the same run and moment show the same
  numbers; the presenter adds a count badge on each hot building, building names and tap-for-popup. **Room-level heat (demo)**:
  hover a building for people and expected sick, click it for Σ P, above-baseline, Low/Elevated/High counts and the top 3 people
  driving it (click one to open the phone).
- **User map** (the phone, and "What users see" on the main map): built only from totals in
  `aggregate.js`, i.e. per-building people and expected sick. It never receives agent data.
  - Building outlines (`sim/data/osm/buildings.geojson`) are filled by expected sick people
    (`buildings.js`).
  - Under 500 agents (like the 10-agent mock) each agent stands for 50 people; from 500 agents on the
    counts are the sim's own (no scaling). The rule is `userScale` in `userscale.js`, shared by
    `app.js`, `tools/precompute.mjs` and the app bundle.
  - Buildings with only 1–3 people are shown as outlines only; 4 or more are always shown
    (`MIN_PEOPLE`). The rule applies to the scaled count, so in ×50 small runs it never hides
    anything.
  - **Forecast** ("In 1 / 2 / 3 hours", from `forecast.js`):
    - Method: each person's habits (building per 30-minute slot, learned from the *other* days)
      × their current P(sick), summed per building.
    - Shown with a dashed outline and an 80% range in the tooltip.
    - A backtest on past days reports how often the actual value landed in the range. That rate is
      shown on the phone; it's 64% on the mock run, below the nominal 80%.
- **Phone alerts:**
  - The person next to you (≤ 6 ft) is actually sick. This is a demo proof of concept and uses the
    sim's true status.
  - **Heads-up:** someone the app thinks may be sick (P ≥ 50%) is within 6 ft (1.83 m) in the same
    room right now.
  - **Close contact:** the same rule as the proximity app, i.e. 15 weighted minutes within 6 ft in
    the last 24 h. Contagious contacts (P ≥ 90%) weigh 1, possibly sick ones (P ≥ 50%) weigh 0.5,
    using each contact's risk as the app knew it at the time. Contacts come from the sim's
    `contacts.csv`, standing in for phone detections.
  - **Exposure notice** (retroactive): 15+ minutes within 6 ft in the last 3 days of someone who has
    *since* reported sick. On the mock this is the one that fires, because A0003 reports only after
    the exposures.
  - **Walk-in warning:** you're in a room where the others add up to ≥ 1 expected sick person.
    It reads room totals only.

## Movement

Dots move continuously, with no jumps between CSV rows (`motion.js`):

- Between two samples at the same place, the agent stays put.
- Movement follows the simulator's own logged routes: when the run has `trips.csv.gz`, an agent
  on a trip is placed exactly where the sim puts it (same distance-along-path formula as the sim
  viewer, speed and mode from the trip). Only runs without trips fall back to the rules below.
- Fallback: when the place changes, the agent leaves as soon as the earlier sample ends. They walk at
  1.35 m/s along Stanford's real footpaths (an OpenStreetMap walkway graph, A* routing), then wait
  until the next sample.
- Samples 2 minutes apart or less are interpolated directly, since fine-grained data already traces
  the path.
- P(sick) changes smoothly between samples.
- Overnight stretches with no samples at all are skipped during playback.
- The playback speed is in simulated minutes per real second.

## What's on screen

- **Heat** = Σ P(sick) × kernel, i.e. *expected number of infected people per area*. That's the
  same as concentration × average P(sick). The colour scale is fixed across all timestamps, so a
  colour means the same thing at every moment. It is a square-root scale, so the legend's middle
  label is a quarter of its maximum.
- **Heat → "Room-level (demo)"**: fine detail (σ = 6 m close up), presenter only. How the heat spreads
  (`diffuse.js`, `masks.js`):
  - Indoors, heat spreads only inside the person's building outline, so it no longer spills onto
    streets. Outdoors, it spreads freely.
  - Heat is the expected number of infected people near each point now: Σ P(sick) of the people
    there, spread by a kernel that integrates to 1 (legend: per 1,000 m²). No trail of past
    positions. The spread follows the zoom (6 m close up, ~6 screen px zoomed out, at most 15 m), with a colour
    scale per spread. The heat is recomputed every frame while that costs under 8 ms (it backs off
    above that). To stay under it: with few people only the patches around them are blurred; big
    spreads use a coarser grid (about 5 cells per σ); and only people on the visible map (plus a
    50% margin) count. See "Performance" below.
  - **Airflow heat (experimental)** (`aerosol.js`): an evolving field instead of a snapshot.
    Infectious people emit into their room; the air mixes within the room, leaks through doors
    (walls sit on cell faces, with one door per ~8 m), and is ventilated away (τ 30 min indoors,
    5 min outdoors). It steps forward with the clock. On a jump or a backward scrub it re-warms
    over the previous 90 min. The scale is relative ("strongest so far"). Zoom in to see rooms.
  - People are first binned into the grid, then the grid is smoothed with three box blurs (≈ a
    Gaussian). The cost depends on grid size, not on the number of agents, which is what the
    7,000-agent run needs.
- **Heat is risk above the baseline.** A person counts as max(0, P(sick) − prior), with the model's
  prior (`DEFAULTS.prior`, 2%). With few reports nearly everyone sits at the prior, and Σ P alone
  drew a map of crowds. This applies to the room-level heat, the airflow sources, and the user
  map's building colours (`excess` in the totals; the counts shown stay Σ P). The truth views still
  use the sim's infectiousness.
- **Heat → "What users see"**: the user map (see below). Building fills from totals only, with no
  people shown.
- **People (demo only)**: one per agent, drawn as Lisa's hand-drawn tissue on a round badge.
  The badge colour is the app's estimate of P(sick) in three tiers, the same tiers as the phone's
  advice: Low under 10% (sage), Elevated 10–40% (yellow), High 40%+ (red). Or colour by the
  simulation's true status (sage healthy, red infected).
- **Click a dot** to see that agent's phone: their estimated risk and advice, a proximity alert
  (someone the app thinks is risky, P ≥ 50%, within 6 ft; or 15+ minutes of close contact), and the user map. The dashed box under the phone shows the simulation's truth and is *not* part of the app.
  From the console, `fluni.select("a018")` opens a specific agent.

## Input CSV

One row per agent per timestamp. The sim's format ([docs/sim-output-format.md](../docs/sim-output-format.md))
is read directly. Other column names are matched loosely in `app.js` (`COLUMNS`); to add an alias,
extend that table.

- **Sim specifics:**
  - `timestamp` is used, not the step index `t`.
  - `disease_state` E or I\* counts as infected.
  - Rows with `off_map` are hidden.
  - `moving` rows are glided through at constant speed.
  - Building names come from `map/buildings.csv`, next to the timeline.
- **P(sick):** the sim holds only ground truth. The map runs the probability model
  ([model/](../model/README.md)) in the browser on the run's `contacts.csv.gz`,
  `reports_tests.csv` and `config.json`. The model uses contacts weighted by distance and
  duration, self-reports, reports about others and tests, plus retroactive contact tracing when
  someone reports. If those files are missing, it falls back to a labelled placeholder: a positive
  test gives 95%, a "might be sick" report gives 60%, and anything else gives 2%. A `p_sick` column
  in the CSV, if present, is used as is.

| Needed | Column (aliases) |
|---|---|
| yes | `t` (`time`, `timestamp`): ISO time or a number |
| yes | `agent_id` (`id`, `agent`) |
| yes | `lat`, `lon` (`latitude`, `lng`, `longitude`) |
| one of | `p_sick` (`p`, `prob_sick`, `risk`): what the app believes |
| one of | `sick` (`infected`, `is_sick`): ground truth, 0/1 |
| optional | `building`, `floor`, `room`: enables room-aware alerts and tooltips |

Other columns are ignored for now.

## Placeholder data

Until the real CSV lands, `data/fake_agents.csv` is generated by `tools/make_fake_agents.py`. It has
250 agents over 2 days (Mon–Tue, 07:00–23:00, 15-minute steps), and flu spreads within rooms of
real Stanford buildings. Building outlines come from OpenStreetMap
(`tools/fetch_buildings.py` → `data/stanford_buildings.json`, © OpenStreetMap contributors, ODbL).

```bash
python3 tools/make_fake_agents.py --agents 250 --days 2 --seed 7
```

## Big runs (thousands of agents)

From 2,000 agents (`BIG_RUN` in `app.js`) the page reads precomputed files instead of computing in the
browser. In the page, the model alone downloads tens of millions of contacts: the 7,500-agent run
took 52 s and a 4 GB JS heap to open.

```bash
node --max-old-space-size=12000 heatmap/tools/precompute.mjs sim/runs/<run> --out heatmap/out/<run>
mkdir -p model/out/<run> && mv heatmap/out/<run>/p_sick.csv model/out/<run>/
```

- P(sick) comes from `model/out/<run>/p_sick.csv`. There is no "Why this %?" and no
  contact-based phone alerts then.
- The user map, forecasts and backtest come from `heatmap/out/<run>/totals.json.gz` (or
  `totals.json.gz` next to the timeline). Without it the page builds them itself (slow).
- Dots are a sample (`MAX_DOTS` = 600, plus the selected person). Everyone else only feeds the heat,
  at their latest sample, without walking along the route.
- Files the sim split into parts (`parts/manifest.json`) are read from the parts.

## Performance

`tools/bench.mjs` plays each view at every speed in headless Chrome. It drives Chrome through the
DevTools protocol, with no dependencies. It reports load time, JS heap, frame and per-frame JS time,
a per-function CPU profile, and how far the heat peak trails a moving risky dot ("lag"):

```bash
python3 -m http.server 8766    # at the repo root
node heatmap/tools/bench.mjs --base http://localhost:8766 --basemap streets [--run <run>] [--load]
```

Measured in headless Chrome on an M-series Mac, Oct 2026. "Heat JS" is the work in a frame that
recomputes the heat; the heat is recomputed every frame while that costs under 8 ms, otherwise only
every few frames. "Lag" is the p50/p95 distance in metres from a moving risky dot to the top of its
heat, close up (zoom 18).

| Run | Load | JS heap | Demo heat JS | Lag p50 / p95 | Public view |
|---|---|---|---|---|---|
| 10 agents, before | 2.0 s | | 23 ms (every ~4th frame) | 5–10 / 27–66 m | 0.2 ms |
| 10 agents, now | 0.9 s | 31 MB | 0.9–1.7 ms (every frame) | 1–1.2 / 2–3.5 m | 0.2 ms |
| 500 agents, before | 3.5 s | | 35 ms (every ~3rd frame) | 7–16 / 29–77 m | 0.5 ms |
| 500 agents, now | 3.1 s | 255 MB | 5–8 ms (every frame) | 1.2–4.8 / 2–59 m | 0.2 ms |
| 400 agents (busy), before | 3.4 s | 167 MB | 32 ms (every ~3rd frame) | 8–18 / 36–72 m | 0.4 ms |
| 400 agents (busy), now | 3.2 s | 276 MB | 5–7 ms (every frame) | 1.6–4.3 / 11–21 m | 0.3 ms |
| 7,500 agents (cca0fef5), before | 52 s | 4,017 MB | 48 ms (every ~3rd frame) | | 2.7 ms (older run) |
| 7,500 agents (cca0fef5), now | 6.2 s | 219 MB | 7–8 ms (every frame) | | 0.3 ms |
| 7,000 agents (5423d1a4), before | 44 s | 3,705 MB | 49 ms | | |
| 7,000 agents (5423d1a4), now | 5.9 s | 207 MB | 7–8 ms (every frame) | | 0.3 ms |

What made the difference:
- Few people (up to 64): only the patches around them are blurred. Many people: only their
  bounding box. Big spreads: a coarser grid. Big runs: only the visible map. The blur used to
  cover the whole ~0.7 M-cell grid four times a frame (`diffuse.js`).
- No people field (nothing reads it).
- `paint()` reuses its pixel buffer.
- `max()` scans only the live patches; it made up 20% of the 10-agent load.
- Dots are only touched when they change.
- The user map skips per-agent positions.
- Big runs read precomputed P(sick) and totals.

Still slow:
- Airflow view: about 7–11 ms a frame (the aerosol solver, `aerosol.js`).
- Big-run load is about 6 s: about 2 s parsing the 0.85 M-row compact timeline, about 1.3 s
  computing the colour scale (`scaleMax`, 60 sampled times), about 1 s parsing trips.

## Files

- `heat.js`: heat grid in metres plus colouring.
- `assets/`: design pass (@lisaazheng). `palette/` is the source swatch for the colours in
  `index.html` (`--sage`, `--sun`, `--ember`, `--fire`); `people/` is the people marker;
  `trace/` is the template for the hand-drawn campus map, with the exact bounds it covers.
  The heat ramp in `heat.js` and the colours in `app.js` (`COLORS`) use the same palette, so
  change colours in all three places together. No map library, so it can move to Google Maps.
- `motion.js`: the sim's trip routes (`buildTrips`), per-agent interpolation, and the footpath router (fallback).
- `tools/check_trips.mjs`: checks trip positions against the sim's formula and times `stateAt`.
- `diffuse.js`: heat field (binning plus a fast blur, kept inside buildings).
- `masks.js`: rasterizes building outlines onto the heat grid.
- `mathpanel.js`: the "Why this %?" panel (the PRD's "show the math" demo beat).
- `tools/precompute.mjs`: for full-size runs, writes `timeline_changes.csv.gz` (changes only; see
  [docs/timeline-changes-format.md](../docs/timeline-changes-format.md)) and `totals.json.gz`
  (building totals and hourly forecasts). Usage: `node heatmap/tools/precompute.mjs
  sim/runs/<run> --out <dir>`. It is validated against the in-browser `aggregate.js` and
  `forecast.js` (identical results), and handles 7,000 agents × 14 days in about 80 s.
  It also writes `p_sick.csv` (the model's output, [docs/p-sick-format.md](../docs/p-sick-format.md);
  `model/cli.mjs` can't read a full run's 1.8 GB of contacts) and `building_heat.csv` for the phones' walk-in warning
  ([docs/building-heat-format.md](../docs/building-heat-format.md)); the committed ones are in
  `heatmap/out/<run>/`.
- `precomputed.js`: reads `p_sick.csv` and `totals.json.gz` for big runs (see "Big runs").
- `loader.js`: streaming CSV loader (gunzips on the fly, keeps only the columns the adapter uses).
  When `<name>.csv.gz` is missing it reads the run's parts (`parts/manifest.json`,
  `sim/scripts/run_parts.py`).
  A 7,000-agent day peaks at ~0.44 GB instead of ~4.9 GB. 14-day runs still need a compact format:
  see ROADMAP D1.
- `aggregate.js`: per-building and per-room totals, the only input to the user map.
- `forecast.js`: predictive mode and backtest.
- `buildings.js`: the building-fill layer for the user map.
- `app.js`: CSV adapter, Leaflet map, playback clock, dots, agent phone view.
- `data/stanford_paths.json`: walkway graph (`tools/fetch_paths.py`, © OpenStreetMap contributors, ODbL).
- [ROADMAP.md](ROADMAP.md): what's left, including the user-facing map and predictive mode.
- `index.html`: layout and styles.

Base map (**tentative**, may switch to Google Maps): OpenStreetMap tiles via Leaflet, greyed with CSS
so the heat stands out. Only the map glue in `app.js` would change; `heat.js` is independent of the map.

## User map for the app

The Swift app's Map tab loads a self-contained, offline copy of the user map: no laptop, no internet.

```
node heatmap/tools/build_app_bundle.mjs sim/runs/<run> --out heatmap/out/app-bundle
```

The folder (about 2.2 MB) holds `index.html` (= `usermap.html`), `usermap.js`, `heat.js` (colour stops),
`vendor/leaflet/`, `assets/containers/` and `data/`: `totals.json.gz` (plus a plain `totals.json` fallback),
`buildings.geojson` (every mapped building, drawn as a neutral paper outline; only those in the totals get heat),
`paths.geojson` (the run's footpaths, faint), `labels.json` (anchor places) and `context.geojson` (OSM roads,
rail, parks, water, Shopping Center, hospital, downtown edge; regenerate with `node heatmap/tools/fetch_context.mjs`).
The map is vector only: the illustrated `campus_trace.webp` is no longer bundled (the vectors read better and save
0.37 MB). The first view fits the whole campus between the top chip and the slim legend strip (about 9% of the
height kept clear at the bottom); that is also the furthest zoom out. Panning is held to the campus + 10% by
Leaflet's default soft limit (it rubber-bands back). The margin beyond campus is drawn faint, fading toward paper. `?debug` exposes `window.__map` for tests. Load `index.html?clock=live` from a custom scheme such as
`fluni://app/index.html?clock=live`; relative URLs only, no network. Other flags: `?at=<minutes from run
start>` (fixed moment, for screenshots), `?horizon=60` (start on "In 1 hour"). Which moment "live" shows is
defined in `docs/building-heat-format.md`.

Privacy: only per-building totals (people, expected sick, forecast) go in; never agent ids, positions,
contacts or the model. Browsers refuse ES modules from `file://`; serve the folder
(`python3 -m http.server` inside it) or use the app's scheme handler.
