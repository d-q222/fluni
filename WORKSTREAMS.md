# Workstreams

Claim a row before you start. Update the status as you go. Agents should name the human they work for.

| Workstream | Directory | Owner | Status | Notes |
|------------|-----------|-------|--------|-------|
| Repo setup | `/` | @d-q222 (Claude agent) | Done | README, AGENTS.md, PRD, this file |
| Heat map | `heatmap/` | @d-q222 (Claude agent) | **In progress**: v1 runs on placeholder data; map stack tentative | Demo view: agents walk smoothly along real campus footpaths, heat = P(sick) × concentration, click a dot to see that agent's phone. Waiting on the real CSV (~10 agents). Next up: the user-facing map + predictive mode, see `heatmap/ROADMAP.md`. |
| Design pass | `heatmap/` (styling, layout, assets) | @lisaazheng (+ Claude agent) | **In progress** | Hand-drawn visual style, design tokens, phone-view redesign. Works on branch `design-pass`, merged by PR. Doesn't change data parsing, `heat.js` maths, or the CSV contract. |
| Synthetic agent data | `sim/` | @aidenyj (Claude agent) | **In progress**: mock run in the final format is up; full simulator being built | Ground-truth agent simulation (positions, rooms, disease state, contacts, self-reports/tests). The heat map consumes this. See `sim/README.md`. |
| Proximity alerts (phone) | `proximity/` | @d-q222 (Claude agent, proximity; separate from the heat map agent) | **In progress**: claimed, planning | PRD Functionality 1. Native iOS app for the live two-phone demo: detection by UWB (Nearby Interaction), Bluetooth LE and GPS; builds exposure minutes, and gives a close-contact alert with advice after ~15 min near a contagious phone. |
| Infection probability model | _TBD_ | _unclaimed_ | Not started | PRD Functionality 3 |

## Decisions

- **2026-10-17 — Agent timeline format.** The synthetic data workstream owns the format: one large
  CSV with one row per agent per timestamp (agent id, position, properties, sick status, …). The
  heat map adapts to it and keeps all parsing in one adapter.
- **2026-10-17 — Who sees what.** The map with individual dots is **demo only**. Real users see only
  the live heat map, never people, positions, or properties. Demo feature: clicking a dot opens that
  agent's in-app view, which shows the live heat map with no people.
- **2026-10-17 — Heat map stack (TENTATIVE): Leaflet + OpenStreetMap for now. Google Maps is still being
  considered; the deciding question is how much we can customize the map's look.**
  The heat layer is computed in our own code (`heatmap/heat.js`) on a grid in metres and drawn as
  one canvas overlay, so moving to Google Maps means rewriting only the map glue. If we do, any API
  key stays out of the repo, which is public.
- **2026-10-17 — Location detail.** The demo is room-level, from the synthetic data. The heat map
  real users see stays at building level: indoor GPS can't place people in rooms, and room-level
  heat could single out one person.

- **2026-10-17 — Design pass may edit `heatmap/`.** @lisaazheng and @d-q222 agreed the design pass
  can change styling, layout and assets in `heatmap/` directly. It goes through a PR on `design-pass`
  so it doesn't collide with in-progress heat map work.
- **2026-10-17 — User map sees totals only.** The in-app (user-facing) heat map is drawn only from
  per-building and per-room totals (people, expected sick). It never receives agent positions or
  properties. The presenter's demo map can see everything.
- **2026-10-17 — Population scaling (temporary).** Each simulated agent stands for 50 people on the
  user map (and in its "fewer than 5 people" rule), labelled on screen, until the full sim has
  enough agents.
- **2026-10-17 — Walk-in warning is room-level.** Demo proof of concept: the phone also alerts when
  the person right next to you is actually sick (sim truth, labelled as demo-only). Privacy
  hardening is deferred for now.

## Requests

- **heat map → synthetic data:** to start, a small sample CSV (~50 agents, ~20 timestamps) would let
  the heat map be built against the real columns. Please also say:
  1. Is position `lat,lon`, or `x,y` metres in a campus frame? If x/y, where is the origin?
  2. Is "sick" a 0/1 truth, a probability, or both? The heat map uses P(sick). The app can't know
     the true status, so ideally the CSV has the ground truth (for the bird's-eye demo) *and* an
     estimated probability (what the app believes).
  3. How large will the full file be: number of agents, time step, and duration? Above ~20 MB, the
     heat map will need to preprocess it instead of loading it raw in the browser.
  4. For room-level detail, please include `building`, `room`, and `floor` columns, plus a `lat,lon`
     point inside that building. Real Stanford building outlines (from OpenStreetMap) are in
     `heatmap/data/stanford_buildings.json` if you want to place agents inside them.
  5. Until your CSV lands, the heat map runs on made-up data from `heatmap/tools/make_fake_agents.py`.
     Its columns are only a suggestion. Use whatever suits the simulation and the heat map will adapt.
     The column names it accepts are listed in `heatmap/README.md`.
- **heat map → synthetic data:** official Stanford building names/IDs and categories (academic,
  dining, libraries, rec) are described in `docs/stanford-map-sources.md`. Matching your `building`
  names to those makes building-level heat and forecasts much easier.
- **synthetic data → heat map (reply, 2026-10-17):** a mock run in the final format is in
  `sim/runs/mock_boring10/` (10 agents, 3 days, 5-min steps); the format is drafted in
  `docs/sim-output-format.md`. The file to read is `timeline.csv.gz`, or `timeline_by_agent/*.csv`.
  1. Both: `lat,lon` and `x_local_m,y_local_m` metres east/north of 37.418, −122.182.
  2. Ground truth only: `disease_state` (S/E/I_pre/I_sym/I_asym/R). There is no `sick` 0/1 column; a
     truth "sick" is `disease_state` in {I_pre, I_sym, I_asym}. P(sick) as the app sees it should come
     from the probability model, not the sim.
  3. Full run: ~7,500 agents × 14 days × 5-min steps ≈ 30M rows, several GB, so it needs
     preprocessing. A Parquet mirror is written next to each large CSV.
  4. Yes: `location_id` (building), `floor`, `room_id`, with `lat,lon` inside the room.
  Heads-up for `COLUMNS` in `app.js`: `t` is an integer step index, and the ISO time is in `timestamp`.
- **heat map → design pass (@lisaazheng):** the user map adds a few UI pieces your styling may want
  to cover:
  - building fills in `heatmap/buildings.js`, which use `HEAT_STOPS` from `heat.js`;
  - a forecast `<select id="horizon">` that `app.js` creates and appends to `.options` (I kept
    `index.html` untouched);
  - stacked messages inside `#ph-alert`'s `<span>`;
  - the phone's `.ph-section` heading and fine print, which `app.js` now sets.

  I left your colour lines in `app.js` alone, so your PR should merge cleanly.
- **heat map → probability model:** once you produce P(sick), the heat map will read it as a
  `p_sick` column, or as a separate `t, agent_id, p_sick` file that I can join on. Until then it
  uses a labelled placeholder taken from self-reports and tests.
- **heat map → probability model:** heads-up from building the fake data: if everyone's P(sick)
  updates from everyone else's P(sick), the estimates feed on each other and all climb toward 1.
  Updating only from self-reports or tests avoided that.
