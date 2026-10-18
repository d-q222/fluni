# Heat map and probability model: handoff (2026-10-17)

Owner: @d-q222 (heat map `heatmap/`, probability model `model/`). Read this with `README.md`, `ROADMAP.md`
and `WORKSTREAMS.md`.

## What it is now

- **Built on the sim** (@aidenyj, `sim/`):
  - positions come from the compact timeline;
  - people walk the sim's own routes (`trips.csv.gz`, `motion.js`);
  - the map is the sim viewer's look (`?basemap=sim`, the default): OpenFreeMap Positron plus the run's
    footprints and paths;
  - "Infectious air by room (sim)" draws `room_exposure.csv.gz`;
  - truth heat is weighted by the sim's `infectiousness`.
- **The heat is the expected number of infected people nearby now:** Σ P(sick) through a unit kernel
  (`diffuse.js`), per 1,000 m².
  - The spread follows the zoom: 18 m close up, ~16 px zoomed out, with a colour scale per spread.
  - Heat stays inside building outlines. There is no trail of past positions.
- **P(sick) comes from Rio's exposure formula** (`exposure/`, Baker et al. PNAS 2021), ported into
  `model/infer.js`:
  - dose from the real distance, duration and room volume/ventilation, indoor/outdoor and humidity;
  - λ = 1 − e^(−stage·Σdose), applied per pair;
  - p ← p + (1−p)·s·λ;
  - Erlang recovery.
  - Review fixes are ours, not Rio's: a per-pair summed dose, quiet emission in dorm rooms, no dose
    across walls, and the illness-average stage when onset is unknown. The review is posted for Rio in
    WORKSTREAMS Requests.
  - Roommates of the confirmed case reach 17–26% over the illness.
- **User map:** building totals only.
  - Small runs are ×50; buildings with fewer than 4 people are hidden.
  - Forecasts at +1/+2/+3 h.
  - In-page `view=public`, the offline app bundle `usermap.html` (`tools/build_app_bundle.mjs` →
    `out/app-bundle/`, which FlUni ships), and `?embed=app`.
- **Presenter phone:**
  - mirrors FlUni's Today screen: status, risk ("Campus model" + "This phone's estimate", using
    FlUni's on-device formula), close-contact time, nearby, recent contacts, a tab bar;
  - a fixed 393×852 screen;
  - "Why this %?" (`mathpanel.js`) shows Rio's dose with real numbers;
  - presenter-only sim truth is shown outside the phone.

## Data contracts I own

- `docs/p-sick-format.md`: `model/out/<run>/p_sick.csv` (`node model/cli.mjs sim/runs/<run>`).
- `docs/building-heat-format.md`: `heatmap/out/<run>/building_heat.csv` (`tools/precompute.mjs`),
  including `radius_m` and the "Which moment is 'now'" live-clock rule. FlUni uses both.
- FlUni's phone estimate must match `model/infer.js` (`doseModel()`). Its golden vectors will be in
  `proximity/Tests/Fixtures/xcheck/golden.json`. Bluetooth range ≤ 10 m and 6 ft are both inclusive.
- The phone-side constants are in their message log. Any change to `DEFAULTS` must be announced to the
  FlUni session (fluni-11).

## Runs

- **Default:** `influenza_none_n10_d14_s2_bc5cae7a`: 10 agents, 14 days, 3 infections. It looks sparse
  live.
- **`influenza_none_n500_d2_s42_aea9db72`:** almost no illness.
- **`influenza_none_n7500_d2_s42_2a1d8bfd`:** local only, not in git, and has no trips. Its 290
  reports are all false. The model takes ~31 s on it. The lag agent regenerated it with the current
  sim as **`influenza_none_n7500_d2_s42_cca0fef5`** (gitignored, has trips): use that id.
- **Requested from Aiden (WORKSTREAMS Requests, 8e970c7):** a busier official demo run, using FlUni's
  scored config: `n400 d3`, seed 5 (25 seeds tried), transmission ×4. Expected id
  `influenza_none_n400_d3_s5_1513ab3f`. When it lands:
  - `node model/cli.mjs sim/runs/<run>` → `p_sick.csv`;
  - `node heatmap/tools/precompute.mjs <run>` → `building_heat.csv` and `totals.json.gz`;
  - `node heatmap/tools/build_app_bundle.mjs` → the FlUni bundle;
  - switch `DEFAULT_RUN` in `app.js` (after the product owner agrees) and tell fluni-11.
  - The same command already reproduces that exact id locally in 5 s (78 infections, 40 infectious
    by day 3). Use a scratch venv from `sim/requirements.txt`; the sim has no `.venv` here. It is
    copied to `sim/runs/` (gitignored) with `model/out/<run>/p_sick.csv`. The whole pipeline takes
    1.3 s and the presenter loads it.

## In flight at handoff (background agents)

1. **7,500-agent performance (the lag agent).** ETA ~1.5 h from 17:30.
   - Done: on the 10-agent run, heat costs 1.9 ms and redraws every frame (it was 23 ms every
     ~60 ms); the cloud sits 1–2 m from its dot (p50; it was 5–10 m); load takes 1.0 s.
   - Next: read `p_sick.csv` and `totals.json.gz` for big runs, heat from stay positions for
     non-sampled agents, and ≤600 dots.
   - Product owner direction: show a dot sample, but compute the heat from all 7,500.
   - Use precomputed `p_sick.csv` and `totals.json.gz` for big runs.
   - Its benchmark is `tools/bench.mjs`.
2. **Alternative flu model, `model/alt/` (done, f61ae54; not integrated).** It works from the product
   owner's "best existing methodologies" prompt.
   - Method: a two-zone transient Wells–Riley dose, humidity via absolute humidity, emission scaled by
     the shedding stage, a summed pair-day dose, and S/E/I/R with Erlang phases (so recovered people
     are immune).
   - Calibration: a 15-min close chat gives λ 0.7%; a roommate over an illness reaches 20.7%.
   - Against Rio's formula it gives about 0.17× λ overall and 0.03× for a night asleep as a roommate.
   - Its recommendation: use it for the heat map and sum `states.I`.
   - The product owner decides. Our Rio port with review fixes already gives roommates 17–26%.
3. **A complete user map for FlUni (done: 6de233f, ddc13ae, eabc499, 2aff552; FlUni synced 81c8f50).**
   - The product owner's final ruling: soft Leaflet bounds (campus pad 0.1), min zoom = the first
     view, no hard clamp.
   - Warm heat fills with a halo of at least 9 px, a muted base, a one-line legend with details
     behind (i), and a fade outside campus.
   - Bounded to Stanford, with faint outside context.
   - Every building in neutral paper, plus footpaths, green spaces and labels.
   - Bundle under 3 MB. The agent messages fluni-11 to re-sync when done.
   - FlUni's screenshots of how the map looks in the app are in `/Users/dqi26/fluni-screens/mapdemo/`
     (local). The app overlays a sheet on the bottom ~20% of the screen, so the map needs that much
     bottom padding when fitting campus.
   - Work in progress (uncommitted in the shared tree): `tools/fetch_context.mjs` (Overpass fetch of
     paths, green space and labels) and `data/context.geojson`.
   - The lag agent's uncommitted edits are `tools/bench.mjs` and `tools/precompute.mjs`. Neither is
     mine to commit; let the agents commit their own paths.

## Model results (for Rio: WORKSTREAMS Requests, 905aca5)

- `model/COMPARISON.md` (`node model/compare.mjs`): Rio's script = our port on λ (0.0459 for a
  15-min 1 m chat); `model/alt` is about 6× lower.
- `model/TESTS.md` (`node model/test.mjs`, 13/13): each of the 9 spec inputs moves P the right way,
  and the update matches Baker's product form.
- `model/calibrate.py`: Σ P against the sim's true infections.
  - Busy run: the model lags while the seeds are silent, then reaches 76 vs 77 by day 3. AUC ~0.63.
  - Quiet n500 run: 6 false `report_other`s inflate the expected count to 28 vs 0–1 truly infected.
- The web phone matches FlUni's golden vectors exactly (60/60, Δp = 0).

## Open questions for the product owner

- "Vary the agents": different runs, different-looking people, or more varied sim behaviour?
- Which flu model, Rio's (current) or the alternative, after the comparison?
- Whether to switch the default run once Aiden publishes a busier one.
- Whether to down-weight uncorroborated `report_other`s (they drive the false heat on quiet runs).
- **Colour scale is relative to each run.** The user map's top colour is the 90th percentile of each
  step's busiest building, and the presenter heat scales per spread. A quiet run therefore looks as
  red as a busy one. An absolute scale (fixed expected-sick count), or a blend, would make runs
  comparable but leave quiet runs almost blank.

## How to work in this repo

- **Shared working tree.** Several sessions and agents edit `/Users/dqi26/fluni`.
  - Commit only your own paths (`git commit <paths>`). Never leave anything staged, never
    `git add -A`, never stash or rebase.
  - Push only your commit from a clean worktree: `git worktree add --detach <tmp> origin/main`,
    cherry-pick, push.
  - Then sync the shared tree with the safe sync script (in the session scratchpad as `sync.sh`).
    A bare `git reset --soft origin/main` leaves stale copies of every file that changed upstream, and
    they then look like local reverts of other people's work. This happened once and was repaired.
    The script updates each upstream-changed file whose working copy still equals the old commit,
    and leaves real local edits alone. An ff-merge fails whenever an untracked file collides with an
    incoming one.
- **Servers.**
  - `python3 heatmap/tools/serve.py <port>` serves the repo root with no cache.
  - 8766 serves the shared tree.
  - 8767 serves a clean origin/main copy in the scratch worktree, which the monitor keeps updated.
- **Never merge someone else's PR.** Product-owner decisions go in WORKSTREAMS "Decisions".
