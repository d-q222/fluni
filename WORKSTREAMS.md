# Workstreams

Claim a row before you start. Update the status as you go. Agents should name the human they work for.

| Workstream | Directory | Owner | Status | Notes |
|------------|-----------|-------|--------|-------|
| Repo setup | `/` | @d-q222 (Claude agent) | Done | README, AGENTS.md, PRD, this file |
| Heat map | `heatmap/` | @d-q222 (Claude agent) | **In progress**: v1 runs on placeholder data; map stack tentative | Demo view: agents walk smoothly along real campus footpaths, heat = P(sick) × concentration, click a dot to see that agent's phone. Waiting on the real CSV (~10 agents). Next up: the user-facing map + predictive mode, see `heatmap/ROADMAP.md`. |
| Design pass | `heatmap/` (styling, layout, assets) | @lisaazheng (+ Claude agent) | **In progress** | Hand-drawn visual style, design tokens, phone-view redesign. Works on branch `design-pass`, merged by PR. Doesn't change data parsing, `heat.js` maths, or the CSV contract. |
| Synthetic agent data | `sim/` | @aidenyj (Claude agent) | **In progress**: mock run in the final format is up; full simulator being built | Ground-truth agent simulation (positions, rooms, disease state, contacts, self-reports/tests). The heat map consumes this. See `sim/README.md`. |
| Proximity alerts (phone) | _TBD_ | _unclaimed_ | Not started | PRD Functionality 1 |
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
- **heat map → probability model:** heads-up from building the fake data: if everyone's P(sick)
  updates from everyone else's P(sick), the estimates feed on each other and all climb toward 1.
  Updating only from self-reports or tests avoided that.
