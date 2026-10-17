# Workstreams

Claim a row before you start. Update the status as you go. Agents should name the human they work for.

| Workstream | Directory | Owner | Status | Notes |
|------------|-----------|-------|--------|-------|
| Repo setup | `/` | @d-q222 (Claude agent) | Done | README, AGENTS.md, PRD, this file |
| Heat map | `heatmap/` | @d-q222 (Claude agent) | **In progress** | Stanford campus map. One dot per agent, colored by P(sick). Heat layer = P(sick) × concentration. Plays back over time from the synthetic timeline data. |
| Synthetic agent data | _TBD_ | _teammate, please claim_ | Not started | Agent positions over time + infection probability. The heat map consumes this. |
| Proximity alerts (phone) | _TBD_ | _unclaimed_ | Not started | PRD Functionality 1 |
| Infection probability model | _TBD_ | _unclaimed_ | Not started | PRD Functionality 3 |

## Decisions

- **2026-10-17 — Agent timeline format.** The synthetic data workstream owns the format: one large
  CSV with one row per agent per timestamp (agent id, position, properties, sick status, …). The
  heat map adapts to it and keeps all parsing in one adapter.
- **2026-10-17 — Who sees what.** The map with individual dots is **demo only**. Real users see only
  the live heat map, never people, positions, or properties. Demo feature: clicking a dot opens that
  agent's in-app view, which shows the live heat map with no people.

## Open decisions

- **Heat map stack.** Leaflet, Google Maps, or a static Stanford map image. Waiting on @d-q222.

## Requests

- **heat map → synthetic data:** to start, a small sample CSV (~50 agents, ~20 timestamps) would let
  the heat map be built against the real columns. Please also say:
  1. Is position `lat,lon`, or `x,y` metres in a campus frame? If x/y, where is the origin?
  2. Is "sick" a 0/1 truth, a probability, or both? The heat map uses P(sick). The app can't know
     the true status, so ideally the CSV has the ground truth (for the bird's-eye demo) *and* an
     estimated probability (what the app believes).
  3. How large will the full file be: number of agents, time step, and duration? Above ~20 MB, the
     heat map will need to preprocess it instead of loading it raw in the browser.
