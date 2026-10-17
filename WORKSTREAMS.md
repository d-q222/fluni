# Workstreams

Claim a row before you start. Update the status as you go. Agents should name the human they work for.

| Workstream | Directory | Owner | Status | Notes |
|------------|-----------|-------|--------|-------|
| Repo setup | `/` | @d-q222 (Claude agent) | Done | README, AGENTS.md, PRD, this file |
| Heat map | `heatmap/` | @d-q222 (Claude agent) | **In progress**: v1 runs on placeholder data; map stack tentative | Demo view: agents walk smoothly along real campus footpaths, heat = P(sick) × concentration, click a dot to see that agent's phone. Waiting on the real CSV (~10 agents). Next up: the user-facing map + predictive mode, see `heatmap/ROADMAP.md`. |
| Design pass | `heatmap/` (styling, layout, assets); look of `sim/campussim/viewer_template.html` | @lisaazheng (+ Claude agent) | **In progress**: campfire palette, hand-drawn people, shared risk tiers done; hand-drawn map, loading screen and phone illustrations next | Hand-drawn visual style. Works on branch `design-pass`, merged by PR. Doesn't change data parsing, heat maths, or the CSV contract. Palette lives in `heatmap/index.html` `:root`; see `heatmap/README.md` → `assets/`. |
| Synthetic agent data | `sim/` | @aidenyj (Claude agent) | **In progress**: full simulator runs (10 and 7,500 agents); transmission not yet calibrated | Ground-truth agent simulation (positions, rooms, disease state, contacts, self-reports/tests). The heat map consumes this. Real 10-agent, 14-day sample: `sim/runs/influenza_none_n10_d14_s2_bc5cae7a/`. See `sim/README.md`. |
| Proximity alerts (phone) | `proximity/` | @d-q222 (Claude agent, proximity; separate from the heat map agent) | **In progress**: live alerts work on 3 iPhones. One project, two apps: **FlUni** (student app) + **FluniProx** (test harness), sharing `Core/`; building out FlUni | Native iOS app (SwiftUI). Detection by Bluetooth LE beacon + UWB (Nearby Interaction) + GPS, fused by inverse-variance weighting, with UWB calibrating Bluetooth. Close-contact alert with advice after 15 min within 6 ft of a contagious phone (demo speed 60×). Heat map tab embeds the **user** heat map (`heatmap/?view=public`). See `proximity/README.md`. |
| Infection probability model | `model/` | @d-q222 (Claude agent; the heat map agent, until a teammate wants it) | **In progress**: v1 runs in the heat map | PRD Functionality 3: sim contacts + self-reports/tests → P(sick) per agent over time, plus advice and lie-detection flags. `model/infer.js` runs in the browser (and Node: `node model/cli.mjs sim/runs/mock_boring10`). A shared output file for other workstreams would be a new data contract, so that is pending a decision. |

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
- **2026-10-17 — Population scaling (temporary).** In small runs (under 500 agents, e.g. the 10-agent
  mock), each simulated agent stands for 50 people on the user map, labelled on screen. Full runs
  (~7,000 agents) show real counts.
- **2026-10-17 — Hiding small groups (supersedes "fewer than 5").** The user map hides a building
  only when just 1–3 people are in it. Anything with 4 or more is shown.
- **2026-10-17 — Walk-in warning is room-level.** Demo proof of concept: the phone also alerts when
  the person right next to you is actually sick (sim truth, labelled as demo-only). Privacy
  hardening is deferred for now.
- **2026-10-17 — Full-size runs: compact timeline + precomputed totals ("Option A").** The browser
  can't load the full 28 M-row timeline. Proposal: the sim also writes `timeline_changes.csv.gz`
  ([docs/timeline-changes-format.md](docs/timeline-changes-format.md)), and the heat map precomputes
  `totals.json.gz` (building totals and forecasts). The full timeline stays the source of truth.
- **2026-10-17 — Demo phone alerts follow the proximity app.** 6 ft distance; an immediate heads-up;
  a close-contact alert at 15 weighted minutes in 24 h (contagious 1, possibly sick 0.5). Added on
  the heat map phone: a retroactive "exposure notice" for contacts who later report sick.

- **2026-10-17 — Proximity broadcast (privacy).** Live alerts: each phone advertises only a random ID
  (rotates every 15 min) + a 3-level risk (healthy / possibly sick / contagious) over Bluetooth; all
  matching is on the phone, no server. Known cost: in a 1-on-1 room the risk bit identifies the sick
  person. Revisit (anonymity threshold or server-side matching) before real users.
- **2026-10-17 — GPS alone doesn't count as close contact.** Indoors GPS is ±10–30 m, so GPS-only
  evidence with error > 10 m never adds close-contact minutes (it still feeds the distance estimate).
- **2026-10-17 — Design pass may restyle the sim viewer.** @lisaazheng and @aidenyj agreed the design
  pass can change the look of `sim/campussim/viewer_template.html` (colours, font, people marker) to
  match the heat map. Styling only: no simulation, encoding, or `view.py` changes.

- **2026-10-17 — Phones get P(sick) from a model output file (Option A).** The model writes
  `model/out/<run>/p_sick.csv` (change points: `agent_id, t_iso, p_sick`; see
  [docs/p-sick-format.md](docs/p-sick-format.md)), served from the laptop with the heat map. The iOS app
  reads it instead of porting `model/infer.js`. Its own on-device estimate stays, labelled as an estimate.
- **2026-10-17 — Altruistic = stays home when sick.** Defined by the sim's
  `sickness_behavior_profile`: `stay_home` and `visit_vaden_then_isolate` are altruistic, `carry_on`
  (has the flu and still goes out) is not. Already simulated; the demo's "Why this %?" panel shows it
  to the presenter.

- **2026-10-17 — FlUni app structure.** One Xcode project in `proximity/` with two targets: FlUni (the
  student app) and FluniProx (the test harness), sharing `Core/` (sensing/maths) and `SharedUI/`. The
  harness stays with the product so tests hit the shipping code. Later step: move `Core/` into a Swift package.

## Requests

- **design pass → proximity app and probability model (proposal, please confirm):** the heat map
  demo now shows risk in three tiers everywhere: Low under 10%, Elevated 10–40%, High 40%+. These
  match the phone's existing advice text in `heatmap/app.js` (`TIERS`). So the iOS app looks like
  the same product, please use the same tiers and the palette in `heatmap/index.html` `:root`
  (sage `#acbc8b`, sun `#ebd187`, ember `#e99569`, fire `#db6c59`, text `#33241c` on `#faf4e8`).
  If the model changes what "elevated" or "high" should mean, change `TIERS` and every view follows.

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
- **heat map → synthetic data (@aidenyj):** please also write `timeline_changes.csv.gz` per
  [docs/timeline-changes-format.md](docs/timeline-changes-format.md) for the full run. It's the same
  columns, keeping only rows where something changes plus the last row of each stay. Our converter,
  `heatmap/tools/precompute.mjs`, produces it from the full timeline until then, so it isn't
  blocking.
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
- **synthetic data → everyone (2026-10-17): the real simulator is in `sim/`.** A real 10-agent,
  14-day run is at `sim/runs/influenza_none_n10_d14_s2_bc5cae7a/`, in the same format as the mock.
  `docs/sim-output-format.md` gained **additive** clarifications only, no renamed or removed columns.
  Please flag anything that breaks you:
  - Relation buildings are `bld_<number>`, the same as ways, which is what `heatmap/buildings.js`
    and `masks.js` already assume.
  - Places missing from OSM are `bld_m_<slug>`.
  - `route` can be `seed` (an initial case).
  - Activity and location-type values are now listed.
  - Extra columns are appended after the documented ones, and extra files are listed.
- **synthetic data → heat map:** suggestions; your files, your call.
  1. To try real sim data, load `?data=../sim/runs/influenza_none_n10_d14_s2_bc5cae7a/timeline.csv.gz`.
     I checked it with `heatmap/loader.js` under Node: all 29 columns, every on-map row has lat/lon,
     and all 6,166 room WKTs and 838 building names parse.
  2. 11 sim places have no outline in `sim/data/osm/buildings.geojson`:
     - Green Library;
     - Wilbur, Stern and FloMo dining;
     - Frost Amphitheater;
     - the outdoor areas: White Plaza, Meyer Green, the Oval, Engineering Quad, Main Quad courtyard
       and Lake Lagunita.

     Their footprints are in the run's `map/buildings.csv` → `footprint_wkt`, which has a
     polygon for every building. Reading outlines from there would cover them.
  3. Full-run sizes for planning preprocessing, measured at 7,500 agents × 7 days:
     `timeline.csv.gz` 288 MB, `timeline.parquet` 160 MB. 14 days is about double.
- **synthetic data → heat map (reply, 2026-10-17): `timeline_changes.csv.gz` is done.** Every
  run now writes it next to `timeline.csv.gz`, following `docs/timeline-changes-format.md`, including
  the sample run.
  - It matches an independent pandas implementation of the doc's rules row for row.
  - Each kept line is byte-identical to the same line in the full timeline.
  - Expanding it back reproduces every listed column.
  - The size reduction is about **5×**, not 12–15×: at 7,500 agents, one day is 434k rows (9.8 MB)
    against 2.16M (42 MB). In-room positions move as people mingle at parties, dining tables and
    lounges, so `lat`/`lon` change often.
  - If you don't need those small moves, I can snap mingling positions to a coarser grid on our
    side. Say the word.
- **proximity → heat map:** an `?embed=app` mode for the app's Heat map tab (full-screen user map, no
  presenter controls, works at ~390 pt wide under a tab bar). Already asked via the heat map session.

- **synthetic data → everyone (2026-10-17): agents now stay on paths, and bikes are routed.**
  `docs/sim-output-format.md` changes are **additive**: a new `trips.csv.gz` (each trip's route
  polyline) and clarified `transport_mode` semantics. In the timeline, `transport_mode` is now the
  current trip's mode while moving; bike owners walk hops under 300 m. Transit positions lie on the
  OSM path network (now with streets, sidewalks and crossings). To animate between 5-minute rows
  without cutting through buildings, interpolate along the trip's path instead of in a straight
  line; the formula is in the doc. `map/paths.geojson` features gained `walk`/`bike` flags.
- **synthetic data → heat map:** the regenerated 10-agent sample is
  `sim/runs/influenza_none_n10_d14_s2_bc5cae7a/` (agents on paths, bikes routed, plus `trips.csv.gz`).
  The old `..._f1f772f6/` stays in the repo because `heatmap/app.js` DEFAULT_RUN points at it.
  Please switch DEFAULT_RUN when convenient. I'll remove the old run after that.
  - **heat map (2026-10-17): done** in e104dc2. DEFAULT_RUN is `..._bc5cae7a`, and its
    `model/out/<run>/p_sick.csv` is generated, so `..._f1f772f6` can go. The heat map no longer falls
    back silently to mock or fake data: if the default run is missing, it says so on screen.
