# Heat map and probability model: handoff (2026-10-18)

**Owner:** @d-q222 (heat map `heatmap/`; probability model `model/`, which another session is now
extending, see "Model"). Read this with `README.md`, `DEMO.md` (the live-demo run-of-show) and
`WORKSTREAMS.md`.

## What it is now

- **Default run:** `influenza_none_n1000_d4_s42_73b8452c`.
  - 1,000 agents over 4 days, 50 seed cases, transmission ×2.
  - Homes are spread over about 53 dorms (the sim's opt-in `population.housing.assignment=spread`).
  - 4 days keeps the in-page model live (1.5 M contacts, about 5 s to load), so "Why this %?" and the
    phone alerts work.
- **Runs of 2,000+ agents, or agents × days ≥ 8,000,** read precomputed files: `model/out/<run>/p_sick.csv`
  and `heatmap/out/<run>/totals.json.gz`. They load in about 5 s but have no "Why this %?". These
  include the 14-day runs `…_f12e71fa`, `…_183f262b` and `…_25fe957a`.
- **Heat (Room-level view):**
  - One zone per building at every zoom; no rooms, and no rectangles or lines.
  - Each person adds max(0, P − 2%) · exp(−d²/2σ²), where d is the walking distance through their own
    building's cells. Walls, wing gaps and courtyards stop it: links across a wall are cut, so it
    never jumps a gap narrower than a cell.
  - σ is 6 m close up, about 6 screen px zoomed out, and at most 15 m. From zoom 18 it uses a 1.5 m grid
    and a softer σ (8–10 m).
  - The colour scale is fixed: full red at P = 50% above the baseline (`ZONE_VMAX`).
  - Outdoor people make a lighter, tighter heat on Aiden's separate layer.
- **Zoom:** continuous and centred on the cursor (`smoothZoom` in `baseMap()`), with zoomSnap 0 and a
  range of 13–20.
  - Only CSS transforms happen during a gesture.
  - Once it settles (140 ms), there is one heat recompute plus a 280 ms crossfade.
  - An idle warm-up builds each level's grid after load.
- **People:**
  - Every agent is drawn up to 2,000 agents (MAX_DOTS), seated inside their building and sized in
    metres (2 px at campus zoom).
  - The dot fill is the app's estimate; a dark red ring means actually infected (sim truth).
  - Every dot is clickable, nearest wins, and opens that person's phone.
- **Building click:** shows Σ P, the tiers, and **everyone inside** (estimate, truth, why). Clicking a row
  opens that person's phone.
- **Views:**
  - **Room-level:** the above.
  - **What users see:** the user map, the same as FlUni's bundle: building totals, soft shading, tap for
    stats, a minimum of 4 people (privacy), and no ×7 scaling.
  - "Air by room" was removed. The experimental airflow view is still reachable with `?view=airflow`.
- **Phone mock:** mirrors FlUni.
  - It shows the "your day" timeline, Lisa's tissue alert and her tab bar (Today / Map / Me), the
    stay-home card, and night mode.
  - "This phone's estimate" follows the product owner's risk-sharing rule:
    - each phone broadcasts its own score, max(estimate, status floor), with floors of 0.97 for a
      positive test and 0.6 for symptoms;
    - other phones use it but never show it;
    - per peer, s = max(status, score − prior).
- **User map bundle** (`tools/build_app_bundle.mjs` → `out/app-bundle/`, which FlUni ships):
  - totals are thinned to 15-minute steps;
  - outlines shared by two places (a dining hall inside its dorm) are one tap target;
  - every tap answers.
- **Pitch page** `demo/` (Aiden's PR #7) embeds this heat map in an iframe.

## Contracts

- `docs/p-sick-format.md`: `model/out/<run>/p_sick.csv`.
- `docs/building-heat-format.md`: `heatmap/out/<run>/building_heat.csv`.
  - `heat`/`high` = risk above the 2% prior.
  - No scaling from 500 agents (×50 below that).
  - The live clock's rule 3: a weekday the run doesn't cover → the run's **last** day.
  - FlUni reads it and checks 0 malformed rows. precompute reads `buildings.csv` with quoted fields.
- **Phone estimate parity:**
  - FlUni's golden vectors are in `proximity/Tests/Fixtures/xcheck/golden.json`.
  - FlUni's FLU2 additions are NOT yet in the mock: per-source stage, the phone's room, the 2-source cap,
    and the 5-day isolation floor. A parity agent's work is parked uncommitted in the scratch worktree
    `parity`: it passes the goldens but is too slow (115 s on a cold call).
- **Announce** any `model/infer.js` DEFAULTS change to FlUni (fluni-11) and to the sim (Aiden's Python
  port `sim/campussim/psick.py`).

## Model

- **This session's work:** Rio's formula is ported in `model/infer.js`.
  - `model/TESTS.md` (13/13), `COMPARISON.md` (Rio's script vs our port vs `model/alt`) and
    `calibrate.py`.
  - GitHub issue #5 asks Rio 4 questions (λ vs the sim's R ≈ 1.6, corroborated `report_other`, and two
    more). Unanswered.
- **Another session** is now extending `model/`. It uses real hourly Stanford weather
  (`model/data/stanford_weather_hourly.csv`) and has a WORKSTREAMS request to the sim. Stay out of its
  files.
- **Aiden** added `ml/`, a contacts-only ML risk model.

## Open items (product owner's priorities first)

1. **In flight:** the views agent is updating the phone mock to the actual app look.
   - Fonts: Nunito and Fredoka.
   - References: FlUni's fresh screenshots in `/Users/dqi26/fluni-screens/phoneref2/`.
   - The phone's Map tab = the presenter map without dots.
   - Delivery: one local commit for review, then push.
2. **Remaining zoom pop:** from zoom 18, dots switch to see-through in one frame at settle.
3. **Keyboard zoom:** keyboard +/− still uses Leaflet's discrete zoom.
4. **Presenter "What users see":** shared outlines (a dining hall in its dorm) aren't merged into one
   tap target as they are in usermap.js. Not silent, but it can show the dining hall alone.
5. **Phone mock and sick users:** FlUni now shows sick users the stay-home card with no risk %
   (9d1b919). Check that the mock matches; the views agent's task covers it.
6. **Pitch page contrast:** `demo/` has contrast failures, posted for Aiden in WORKSTREAMS Requests.
   The heat map itself passes in light and dark (audit scripts `audit.mjs` and `inpage.js` in the
   scratchpad).

## How to work in this repo (product owner's rules)

- **Commit rarely.** Batch into one reviewed commit; teammates (Aiden, Lisa, FlUni) are disrupted by
  constant pushes. Their PRs take priority: merge them when the product owner asks and build on them.
- **Agents** work in their own git worktrees, commit locally, and never push. Review their screenshots
  and numbers, then cherry-pick onto a fresh `origin/main` worktree and push.
- **Attribution:** Claude-Session trailers are fine in this repo (product owner, 2026-10-18).
- **Shared tree** `/Users/dqi26/fluni`: other sessions edit it.
  - Commit only your own paths (`git commit <paths>`).
  - Never `add -A`, stash or rebase there.
  - To sync it, update every upstream-changed file whose working copy still equals the old commit,
    then run `git reset --soft origin/main && git reset`. Leave real local edits alone; a bare soft
    reset makes upstream changes look like local reverts. The script was `sync.sh` in the session
    scratchpad.
- **Servers** (`python3 heatmap/tools/serve.py <port>`, no cache):
  - 8766 serves the shared tree.
  - 8767 serves a clean origin/main copy kept in sync by a monitor.
- **Launcher:** `heatmap/tools/demo.sh` starts the server and opens the page; see `DEMO.md`.
- **Headless checks:**
  - Chrome needs `--use-angle=swiftshader --enable-unsafe-swiftshader` for MapLibre.
  - Use the GPU (Metal) for real frame times.
  - `window.fluni` exposes the map, `current()`, `select(id)`, `seek(t)`, `now()` and
    `phoneScore(id)`.
  - `window.fluniUserMap` exposes the user map's tap targets.
