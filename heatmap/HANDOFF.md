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
- **Wanted:** a busier official run from Aiden (~500 agents, 7 days, several seeds). The FlUni
  session is exploring configs in scratch.

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
3. **A complete user map for FlUni.**
   - Bounded to Stanford, with faint outside context.
   - Every building in neutral paper, plus footpaths, green spaces and labels.
   - Bundle under 3 MB. The agent messages fluni-11 to re-sync when done.

## Open questions for the product owner

- "Vary the agents": different runs, different-looking people, or more varied sim behaviour?
- Which flu model, Rio's (current) or the alternative, after the comparison?
- Whether to switch the default run once Aiden publishes a busier one.

## How to work in this repo

- **Shared working tree.** Several sessions and agents edit `/Users/dqi26/fluni`.
  - Commit only your own paths (`git commit <paths>`). Never leave anything staged, never
    `git add -A`, never stash or rebase.
  - Push only your commit from a clean worktree: `git worktree add --detach <tmp> origin/main`,
    cherry-pick, push.
  - Then move the shared branch pointer: `git reset --soft origin/main && git reset` when local main
    is an ancestor of origin.
- **Servers.**
  - `python3 heatmap/tools/serve.py <port>` serves the repo root with no cache.
  - 8766 serves the shared tree.
  - 8767 serves a clean origin/main copy in the scratch worktree, which the monitor keeps updated.
- **Never merge someone else's PR.** Product-owner decisions go in WORKSTREAMS "Decisions".
