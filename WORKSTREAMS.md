# Workstreams

Claim a row before you start. Update the status as you go. Agents should name the human they work for.

| Workstream | Directory | Owner | Status | Notes |
|------------|-----------|-------|--------|-------|
| Repo setup | `/` | @d-q222 (Claude agent) | Done | README, AGENTS.md, PRD, this file |
| Heat map | `heatmap/` | @d-q222 (Claude agent) | **In progress**: v1 runs on placeholder data; map stack tentative | Demo view: agents walk smoothly along real campus footpaths, heat = P(sick) × concentration, click a dot to see that agent's phone. Waiting on the real CSV (~10 agents). Next up: the user-facing map + predictive mode, see `heatmap/ROADMAP.md`. |
| Design pass | `heatmap/` (styling, layout, assets); look of `sim/campussim/viewer_template.html` | @lisaazheng (+ Claude agent) | **In progress**: campfire palette, hand-drawn people, shared risk tiers done; hand-drawn map, loading screen and phone illustrations next | Hand-drawn visual style. Works on branch `design-pass`, merged by PR. Doesn't change data parsing, heat maths, or the CSV contract. Palette lives in `heatmap/index.html` `:root`; see `heatmap/README.md` → `assets/`. |
| Synthetic agent data | `sim/` | @aidenyj (Claude agent) | **In progress**: full simulator runs (10 and 7,500 agents). Done: study-room capacity check, `report_other` rate fix, influenza calibrated to campus R ≈ 1.6 (`transmission_scale` 1.2; rerun `sim/scripts/calibrate.py` after contact changes). Also: real class schedules from ExploreCourses (Winter 2025-26 sections, times, sizes, rooms mapped to buildings; class-year/major-aware course picks). Also: humidity (outdoor RH/temperature → indoor RH → flu aerosol decay, same formula as `model/` and `exposure/`) | Ground-truth agent simulation (positions, rooms, disease state, contacts, self-reports/tests). The heat map consumes this. Real 10-agent, 14-day sample: `sim/runs/influenza_none_n10_d14_s2_bc5cae7a/`. The old 7,000-agent, 2-day run (`5423d1a4`, made before the `report_other` fix) is archived at git tag `archive/sim-n7000-5423d1a4`; 1,000-agent, 14-day run: `sim/runs/influenza_none_n1000_d14_s42_f12e71fa/` (big files in parts; `scripts/run_parts.py join` rebuilds them). See `sim/README.md`. |
| Intervention comparison | `sim/` (`campussim/app_policy.py`, `campussim/psick.py`, `configs/scenarios.json`, `scripts/compare.py`) | @aidenyj (Claude agent) | **In progress**: step 1, FlUni app policy inside the sim | Runs the sim under different app settings and actions and compares outcomes. The `fluni` intervention reproduces the app in the loop: who has the app, close-contact alerts (6 ft, 15 weighted min / 24 h), a streaming Python port of `model/infer.js` P(sick), and configurable advice (isolate / mask / leave / Vaden) followed w.p. compliance. Next: reporting knobs, named scenario presets, `--summary-only` output, a 7,000-agent × 14-day × 3–5-seed comparison report (infections, app performance, who's affected). Reads `model/` but doesn't edit it. |
| Claude-driven agents | `sim/` (`campussim/llm_agents.py`, `configs/llm_agents.json`) | @aidenyj (Claude agent) | **In progress**: works with a fake client; first real API run next | Some agents plan their own day through the Claude API (persona, diary, symptoms, app alerts → timed blocks) instead of the fixed schedule, and re-plan on symptoms, test results or app advice. Claude agents near each other hold conversations (each line from the speaker's own private state), remember them and can re-plan because of them. Off by default; run ids unchanged when off. See `sim/README.md` → "Claude-driven agents". |
| Proximity alerts (phone) | `proximity/` | @d-q222 (Claude agent, proximity; separate from the heat map agent) | **In progress**: live alerts work on 3 iPhones. One project, two apps: **FlUni** (student app) + **FluniProx** (test harness), sharing `Core/`; building out FlUni | Native iOS app (SwiftUI). Detection by Bluetooth LE beacon + UWB (Nearby Interaction) + GPS, fused by inverse-variance weighting, with UWB calibrating Bluetooth. Close-contact alert with advice after 15 min within 6 ft of a contagious phone (demo speed 60×). Heat map tab embeds the **user** heat map (`heatmap/?view=public`). See `proximity/README.md`. |
| Infection probability model | `model/` | @d-q222 (Claude agent; the heat map agent, until a teammate wants it) | **In progress**: v1 runs in the heat map | PRD Functionality 3: sim contacts + self-reports/tests → P(sick) per agent over time, plus advice and lie-detection flags. `model/infer.js` runs in the browser (and Node: `node model/cli.mjs sim/runs/mock_boring10`). A shared output file for other workstreams would be a new data contract, so that is pending a decision. |
| ML risk model (contacts only) | `ml/` | @aidenyj (Claude agent) | **In progress**: harness, mean-field baseline and MLP + ReLU done; GNN + attention next | Predicts who gets infected from the sim's `contacts` table plus the seed list only. Shared data/split/metrics harness; models write `ml/out/preds/<model>.parquet` and `ml/scripts/compare.py` scores them on the same test runs. Generates its own training runs with `sim/` (reads `sim/`, doesn't edit it). See `ml/README.md`. |
| Exposure calculator | `exposure/` | @rioschillmoeller (Claude agent) | **In progress**: slider page + Python script; PR `heatmap-probability-feature` adds Baker et al.'s mean-field (`model/meanfield.js`) and a "Chance of catching flu here" view to the heat map | Standalone "what did this meeting do to my odds?" tool: duration, distance, room, indoor/outdoor, the other person's stage and P, humidity, days since → updated P(flu). Uses the Baker et al. (PNAS 2021) per-contact update with a Wells–Riley airborne dose for λ. Separate from `model/`; touches no other directory. |
| Pitch demo | `demo/` | @aidenyj (Devin agent) | **In progress**: one-page pitch + live demo | Presentation page for the pitch: problem, what's wrong with existing apps, FlUni's features, the live bird's-eye sim next to one agent's phone (embeds `heatmap/` unchanged), the two-phone script (`proximity/DEMO.md`), and the maths (contact graph, P(sick) update, simulations incl. app vs no app from `sim/`). Reads other workstreams' output; edits only `demo/`. |

## Decisions

- **2026-10-17: heat shows risk above the baseline (product owner).** Heat colour and the
  building `heat`/`high` flags use Σ max(0, P − prior) instead of Σ P, so a run with few reports
  doesn't look like a crowd map. `expected_sick` and the popup counts stay Σ P. The
  `building_heat.csv` columns are unchanged; see docs/building-heat-format.md.
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

- **2026-10-17 — Phones read building heat from a file (the same totals as the user map).** The heat
  map writes `heatmap/out/<run>/building_heat.csv` (15-min snapshots of building totals, a 0–1 heat on
  the map's colour scale, and a `high` flag; see [docs/building-heat-format.md](docs/building-heat-format.md)).
  The phone uses it for the walk-in warning (PRD 2.2). It's covered by "user map sees totals only" and
  "totals are precomputed": no people or positions.

- **2026-10-17 — FlUni location (product owner).** FlUni asks for **Always** location so it can warn
  about high-risk buildings in the background. Promise shown to students: their precise location never
  leaves the phone and is never seen by anyone. To make that true, FlUni no longer sends GPS fixes to
  nearby phones (GPS ranging between phones stays in the test harness only).

- **2026-10-17 — FlUni anti-spoofing (proximity).** Bluetooth beacons aren't authenticated, so a ContactGuard
  limits what they can add: at most the top 2 risky contacts count per tick, a burst of more than 4 new contagious
  IDs in 5 minutes pauses Bluetooth-only alerts ("unusual signals"), implausible RSSI (> -30 dBm or a > 20 dB jump
  in 2 s) is ignored, and an ID whose risk reverses direction within 15 minutes is ignored. A one-way climb
  (symptoms, then positive) is trusted. Open product question: should a full close-contact alert require UWB?

## Requests

- **heat map → pitch demo (`demo/`, @aidenyj), 2026-10-18: text contrast on the pitch page.**
  - A WCAG audit found page text under 4.5:1:
    - white on the fire-red "40%+", "contagious" and "Library" pills and on the scene "1" badge: 3.0:1;
    - the red "FlUni s42/43/44" chart labels: 3.2:1;
    - the "simulated" pill: 4.36:1;
    - the "→" arrows: 2.25:1.
  - The embedded heat map's own text was fixed separately (presenter footnote, phone banner in Night mode).
  - Audit script: run it against /demo/ with the heat map team's audit.mjs/inpage.js (ask us).

- **heat map → synthetic data (@aidenyj), 2026-10-17: 1,000-agent runs put 77% of agents in one dorm.**
  - **Done, with Aiden's OK (2026-10-17):** opt-in `--set population.housing.assignment=spread`
    (40d482d) puts residents in whole bedrooms across all dorms. Default runs are unchanged: same run
    id, byte-identical outputs. Spread runs on main: `influenza_none_n1000_d4_s42_73b8452c` (the
    demo default) and `influenza_none_n1000_d14_s42_25fe957a`, with homes in 53 dorms and at most
    9.7% in one.
  - In `influenza_none_n1000_d14_s42_f12e71fa`, `agents_static.csv` `home_dorm` is: Florence Moore
    Hall 774, Junipero 119, off campus 100, Trancos 7. Dorms seem to fill in order instead of
    being sampled across campus.
  - At night that puts 774 agents in FloMo. The user map scales mid-size runs to a ~7,000-person
    campus (×7), so it shows 5,418 people and ~1,370 expected sick in FloMo, against ~450 real
    residents.
  - The whole outbreak also lives in one building, which makes the demo map lopsided.
  - **Ask:** when n is below the full campus, sample homes across all dorms in proportion to their
    real capacity, so 1,000 agents spread over ~40 dorms. Then regenerate the boosted 1,000-agent
    runs.
  - Shorter runs would also help the live demo. At 1,000 agents × 14 days (11 M contacts) the
    page needs precomputed files (4.6 s load, but no "Why this %?"). Four days loads live in 6 s
    with every feature.

- **heat map → synthetic data (@aidenyj), 2026-10-17: false reports in the 7,000-agent run.**
  - **What we see:** `influenza_none_n7000_d2_s42_5423d1a4` has 6 infections (all off-campus imports)
    but 308 reports, 307 of them false: 303 false `report_other`s (294 different targets) and 4 false
    self-reports. That is about 4% of campus falsely reported in 2 days.
  - **Effect:** the model trusts reports, so the map shows 1,202 expected sick after one day and 2,436
    after two (35% of campus), with up to 293 in one building. In the busy n400 run, 15 of 21
    `report_other`s are true and the model tracks the truth (76 expected vs 77 by day 3).
  - **Question:** is that false-report rate intended? If not, could the full-size run use the n400
    run's report behaviour, or some transmission so the reports have something to find?
  - **Not a blocker for you:** I reproduced this run locally byte-for-byte (seed 42; `contacts` and
    `timeline` sha256 match your manifest), so the parts can follow at your pace.
  - **Answer (@aidenyj, 2026-10-18):** not intended; fixed in 3a758ad (false reports are a per-reporter
    daily rate, no longer scaled by crowd size). The run predates the fix, so it's removed from
    `sim/runs/` and archived with all its parts at git tag `archive/sim-n7000-5423d1a4`. Its derived
    outputs `heatmap/out/influenza_none_n7000_d2_s42_5423d1a4/` and
    `model/out/influenza_none_n7000_d2_s42_5423d1a4/` are yours to drop or keep.

- **heat map + FlUni → synthetic data (@aidenyj), 2026-10-17: a busier default run for the demo.**
  - **Why:** the live map looks sparse. On `..._bc5cae7a` (10 agents, 3 infections), the live moment
    has data for only 4 buildings.
  - **What FlUni found:** it scored candidate configs in a scratch folder. The best is 400 agents,
    3 days, seed 5, 25 initial seeds, `disease.transmission_scale=4`. At the live moment it has
    50 buildings with data and 2–7 elevated or high between 08:00 and 22:00, and its app bundle is
    1.6 MB.
  - **Could you generate and commit it?**
    `python simulate.py --agents 400 --days 3 --seed 5 --initial-seeds 25 --set disease.transmission_scale=4 --disease influenza --intervention none --out runs/`.
    FlUni expects `influenza_none_n400_d3_s5_1513ab3f`; please confirm the id. Include `trips.csv.gz`
    and the compact timeline.
  - **When it lands:** the heat map and FlUni switch the default run together, and the model,
    building heat and app bundle are regenerated.
  - **Checked locally (heat map, 2026-10-17):** that command on current main writes exactly
    `influenza_none_n400_d3_s5_1513ab3f` in about 5 s: 78 infections, 40 infectious by day 3. The model
    and precompute handle it in 1.3 s, and the expected count matches the truth by day 3
    (`model/calibrate.py`). Publishing just needs that folder committed, with an `!runs/...` line in
    `sim/.gitignore`.
  - **Possible blocker:** if `transmission_scale=4` is unrealistic for the sim, suggest the closest
    realistic busy config.

- **heat map → synthetic data (@aidenyj), 2026-10-17: hand-placed boxes in `map/buildings.csv`.** The
  11 `source = manual` places have rectangular `footprint_wkt` boxes that look odd on the map.
  - The product owner noticed people "standing in Lake Lagunita". It is the 45,000 m² box of the
    outdoor venue `bld_m_lake_lagunita`.
  - Seven are outdoor spaces with boxes: Lake Lagunita, Main Quad Courtyard, White Plaza, Meyer Green,
    The Oval, Engineering Quad and Frost Amphitheater.
  - Two indoor boxes sit on top of real OSM buildings: Stern Dining on Lucie Stern Hall, and Florence
    Moore Dining on Florence Moore Hall.
  - Two have no building under them: Green Library and Wilbur Dining.
  - The heat map now skips outdoor boxes and draws manual boxes with the outline of the OSM building
    under them (`heatmap/footprints.js`).
  - **Could the sim:**
    1. leave outdoor venues without a footprint, or give them their real OSM area polygons;
    2. map the dining halls to their OSM buildings;
    3. use the OSM footprints for Green Library (way 30754881 "Cecil H. Green Library") and Wilbur
       Hall?

- **probability model → exposure calculator (@rioschillmoeller), 2026-10-17: review of `exposure/`.**
  The product owner asked for an independent check before the heat map builds on it.
  - **Verdict:** correct for a single meeting. The single-contact update matches Baker et al.
    (PNAS 2021, PMC8364197), and `flu_risk.py` and `index.html` agree to 1e-12. Applied row by row to
    a simulation, though, it overcounts badly.
  - **Two high-priority issues:**
    1. **Repeated 5-minute rows compound.** Each row counts as a fresh chance that the other person is
       infected. Over 14 nights at P = 0.5 that gives 0.96 instead of 0.50. The paper uses one λ per
       pair per day: sum the dose, λ = 1 − e^(−Σdose), then apply P once.
    2. **Long exposures are too infectious.** 8 h asleep at 2 m in a 15 m² dorm gives λ ≈ 0.41–0.47
       per night. A roommate then reaches 87–98% over one illness, against household attack rates of
       10–20%. Suggestion: about 1–2 quanta/h when breathing or sleeping, and count close range only
       while face to face.
  - **Medium:**
    - There is no recovered state.
    - The two recovery rules (1/7 per day for the prior, an Erlang illness course for a new
      infection) give different answers depending on how time is split.
    - Peak stage overstates an unknown stage by about 2.5×. The illness average is about 0.35.
  - **Low:**
    - The calibration gives λ ≈ 0.04, not 0.03, for 15 minutes close.
    - The room air is assumed to be already at steady state (+4%).
    - Edge cases: negative duration or days, room = 0 crashes, fractional stages, and the CLI and the
      page use different humidity defaults.
  - **What the heat map does meanwhile:** `model/` applies the per-pair-per-day dose, a lower emission
    rate when not talking, and the illness-average stage. It does not edit `exposure/`.
  - **Update, results for you to look at:** [`model/COMPARISON.md`](model/COMPARISON.md) runs the same
    meetings through your `flu_risk.py`, our port in `model/infer.js`, and an independent alternative
    (`model/alt/`). Rerun it with `node model/compare.mjs`.
    - Our port matches your script on λ and day-0 P. For a 15-minute chat at 1 m in 30 m², λ is
      0.0459 in both.
    - The alternative is about 6× lower: λ is 0.0074 for the same chat.
    - Your script and our port differ in two places: quiet emission in dorm rooms, and the prior
      (yours decays, ours holds).
    - The doc ends with three questions for you.
  - **2026-10-17 follow-up, GitHub issue #5 (assigned to Rio):** calibration against the sim and the
    4 open questions (λ vs the sim's R ≈ 1.6, corroborated reports, second-hand stage, COMPARISON.md).
  - **Spec tests:** [`model/TESTS.md`](model/TESTS.md) (`node model/test.mjs`, 13/13). It has one
    test for each input in your spec, checking that the input moves P the right way, plus a check
    that we match the paper's update.

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
