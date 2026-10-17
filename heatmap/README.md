# Heat map

> **Status: tentative v1.** It runs on placeholder data, and the base map choice isn't final.

Stanford campus map showing where infections are likely concentrated, played back over time from
the agent timeline CSV. Owner: @d-q222 (see [WORKSTREAMS.md](../WORKSTREAMS.md)).

## Run it

Serve the **repo root**, so the page can reach the sim's output in `../sim`:

```bash
python3 -m http.server 8765
```

Open http://localhost:8765/heatmap/. By default it loads the sim's run
(`sim/runs/mock_boring10/timeline.csv.gz`, gunzipped in the browser). If that isn't reachable, it
falls back to the placeholder `data/fake_agents.csv`.

URL options, which can be combined:

- `?data=path/to/timeline.csv[.gz]`: load another run (relative to `heatmap/`), e.g.
  `?data=../sim/runs/<run>/timeline.csv.gz`.
- `?at=200`: open at a moment, in minutes from the start of the data.
- `?agent=A0008`: open with that agent's phone showing. Handy for demo scenes.
- `?view=public`: open on the user-facing map. Add `&horizon=60` (or 120 or 180) for a forecast.

Demo scenes on the sim's mock run:

- `?at=2115&agent=A0008`: Tue 11:15. The person next to A0008 in class is sick.
- `?at=4200&agent=A0002`: Wed 22:00. A0002 walks back into the dorm room where their reported-sick
  roommate is isolating, which triggers the walk-in warning.
- `?view=public&horizon=60&at=2115`: the user-facing map with a forecast for one hour ahead.

## Demo map vs. user map

- **Demo map** (presenter): sees everything, including agent dots, room-level heat and true status.
- **User map** (the phone, and "What users see" on the main map): built only from totals in
  `aggregate.js`, i.e. per-building people and expected sick. It never receives agent data.
  - Building outlines (`sim/data/osm/buildings.geojson`) are filled by expected sick people
    (`buildings.js`).
  - In small runs (under 500 agents, like the 10-agent mock), each agent stands for 50 people.
    Full runs (the sim's ~7,000 agents) show real counts. See `SMALL_RUN_*` in `app.js`.
  - Buildings with only 1–3 people are shown as outlines only; 4 or more are always shown
    (`MIN_PEOPLE`).
  - **Forecast** ("In 1 / 2 / 3 hours", from `forecast.js`):
    - Method: each person's habits (building per 30-minute slot, learned from the *other* days)
      × their current P(sick), summed per building.
    - Shown with a dashed outline and an 80% range in the tooltip.
    - A backtest on past days reports how often the actual value landed in the range. That rate is
      shown on the phone; it's 64% on the mock run, below the nominal 80%.
- **Phone alerts:**
  - The person next to you (≤ 2 m) is actually sick. This is a demo proof of concept and uses the
    sim's true status.
  - Someone the app thinks is risky (P ≥ 50%) is within 3 m in the same room.
  - **Walk-in warning:** you're in a room where the others add up to ≥ 0.5 expected sick people.
    It reads room totals only.

## Movement

Dots move continuously, with no jumps between CSV rows (`motion.js`):

- Between two samples at the same place, the agent stays put.
- When the place changes, the agent leaves as soon as the earlier sample ends. They walk at
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
- **Heat → "Room-level (demo)"**: fine detail (σ = 18 m), presenter only.
- **Heat → "What users see"**: the user map (see below). Building fills from totals only, with no
  people shown.
- **Dots (demo only)**: one per agent. Colour by the app's estimate of P(sick), or by the
  simulation's true status.
- **Click a dot** to see that agent's phone: their estimated risk and advice, a proximity alert
  (someone the app thinks is risky, P ≥ 50%, in the same room within 3 m), and the user map. The dashed box under the phone shows the simulation's truth and is *not* part of the app.
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
- **P(sick):** the sim holds only ground truth. Until the probability model ships a `p_sick`, the
  map estimates it from what a real app could know: a positive test gives 95%, a "might be sick"
  report gives 60%, and anything else gives 2%. The legend labels this as a placeholder.

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

## Files

- `heat.js`: heat grid in metres plus colouring. No map library, so it can move to Google Maps.
- `motion.js`: footpath router and per-agent interpolation.
- `aggregate.js`: per-building and per-room totals, the only input to the user map.
- `forecast.js`: predictive mode and backtest.
- `buildings.js`: the building-fill layer for the user map.
- `app.js`: CSV adapter, Leaflet map, playback clock, dots, agent phone view.
- `data/stanford_paths.json`: walkway graph (`tools/fetch_paths.py`, © OpenStreetMap contributors, ODbL).
- [ROADMAP.md](ROADMAP.md): what's left, including the user-facing map and predictive mode.
- `index.html`: layout and styles.

Base map (**tentative**, may switch to Google Maps): OpenStreetMap tiles via Leaflet, greyed with CSS
so the heat stands out. Only the map glue in `app.js` would change; `heat.js` is independent of the map.
