# Building heat format

The heat map writes one file per sim run with the user map's building totals, so the phone can warn
when someone walks into a building with a lot of illness (PRD 2.2). The numbers are the same totals the
user map shows, so the map and the phone agree. The file holds totals only, never people or positions.

**Path:** `heatmap/out/<run_id>/building_heat.csv`. Regenerate it with
`node heatmap/tools/precompute.mjs sim/runs/<run_id> --out heatmap/out/<run_id>`. For a demo it is
served from the laptop with the rest of the repo, at
`http://<laptop>.local:8000/heatmap/out/<run_id>/building_heat.csv`.

| Column | Meaning |
|---|---|
| `t_iso` | Snapshot time, sim time, ISO 8601 without a zone (same clock as `p_sick.csv`) |
| `building_id` | Sim `location_id`, e.g. `bld_232805707` |
| `name` | Building name, quoted if it contains a comma |
| `lat`, `lon` | Building centre, from the run's `map/buildings.csv` (empty if unknown) |
| `people` | People inside, scaled the same way as the user map: each agent counts as 50 in runs under 500 agents |
| `expected_sick` | Σ P(sick) of the people inside, scaled the same way |
| `heat` | 0–1, the map's own colour scale: √(expected_sick / colour max), capped at 1. The colour max is the 90th percentile of each snapshot's hottest building |
| `high` | `1` if `heat ≥ 0.5`, i.e. past the legend's midpoint, the buildings the map shows dark; else `0` |
| `radius_m` | Optional, for geofencing: √(footprint area / π) + 10 m of GPS slack, rounded; empty if the area is unknown. Added after the first version, so it is the last column |

- Rows are **snapshots every 15 minutes**: all rows with the same `t_iso` describe campus at that
  moment. To read the state at time t, take the rows with the latest `t_iso ≤ t`.
- A building with no row in a snapshot has fewer than 4 people (hidden on the map too) or is empty.
  Treat it as "no data", not as safe.
- P(sick) comes from the probability model (`model/infer.js`), the same values as `p_sick.csv`.
- A building is only as "high" as the run's own scale: the colour max is per run.
