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
- **Rio's PR #22 is merged (3b31e5c).**
  - It added building shading: expected infected above the 2% baseline per 1,000 m² of floor, using
    researched floor counts in `data/building-floors.json`.
  - It added a Baker et al. mean-field model (`model/meanfield.js`, `?model=meanfield`) and a
    "4 days" / "2 weeks" run picker.
  - As merged, shading replaced the Gaussian heat in the default view. The product owner asked for the
    Gaussian heat to be the default again, with Rio's shading kept as a toggle under Display. The model
    session (fluni-01) is making that change. Check main for whether it has landed.
- **Gaussian heat (demo view):**
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
  - Close up they fade to see-through over zoom 17–18.5 (`seeThroughAt`), so the heat shows under them.
  - Every dot is clickable, nearest wins, and opens that person's phone.
- **Building click:** shows Σ P, the tiers, and **everyone inside** (estimate, truth, why). Clicking a row
  opens that person's phone.
- **Views:**
  - **Demo view** (the first switcher button): the above.
  - **What users see:** the user map, the same as FlUni's bundle: building totals, soft shading, tap for
    stats, a minimum of 4 people (privacy), and no ×7 scaling.
  - "Air by room" was removed. The experimental airflow view is still reachable with `?view=airflow`.
- **Phone mock:** mirrors FlUni, in Nunito and Fredoka, with Lisa's tissue alert and her tab bar
  (Today / Map / Me), and night mode.
  - **Today** is FlUni's new home (owner-approved mock v4: `/Users/dqi26/fluni-screens/home-v2/`; the
    real build: `home-built/`):
    - a speech bubble with the tissue;
    - a card with only the big %, the band, and "I don't feel well";
    - an alert strip inside the card during a heads-up or close contact;
    - the f(x) link;
    - "Your day so far", from the agent's real track and contacts (`todayStays()`);
    - sick mode: Day N of 5, Better / The same / Worse, "Your recovery", the Vaden line, and the
      privacy line.
  - The Map tab is the presenter's map without people: same base, landmarks, building heat and moment.
  - **Shown risk:** the campus model's P (`model.risk.pAt`), the same number as the presenter bar (Rio,
    4772dd8, as the product owner ruled).
  - `phoneEstimate` (the on-device dose estimate) is no longer shown. It stays as
    `window.fluni.phoneScore` for proximity's cross-check, and for the broadcast score:
    - each phone broadcasts max(estimate, status floor), with floors of 0.97 for a positive test and
      0.6 for symptoms;
    - per peer, s = max(status, score − prior).
  - Close-contact time is weighted minutes in the last 24 h. FlUni is switching to a 2-h reset
    (`flu-clock`, product owner); the mock doesn't have it yet.
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

1. **Phone mock's Today, v5:** the product owner asked FlUni for a text-light pass on the home screens.
   fluni-11 will send the v5 mock once it's approved; then redo Today to match. Until then, the mock
   matches the v4 build (`/Users/dqi26/fluni-screens/phonecmp3/` side by side), except that the app's
   timelines now sit about 15 pt further left.
2. **Gaussian heat as the default again** (product owner): the model session (fluni-01) is making this
   change, keeping Rio's building shading as a Display toggle. Update "What it is now" once it lands.
   The team takes Rio's edits and solutions over other sessions' versions. The SMF session's
   `model/smf*.js` was dropped.
3. **Pitch page contrast:** `demo/` has contrast failures, posted for Aiden in WORKSTREAMS Requests.
   The heat map itself passes in light and dark (audit scripts `audit.mjs` and `inpage.js` in the
   scratchpad).

Closed by the product owner on 2026-10-18:
- Keyboard +/− zoom staying stepwise is fine.
- The presenter's "What users see" doesn't need shared outlines merged.

Fixed:
- The see-through dot pop at zoom 18 (dots now fade over zoom 17–18.5).

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
