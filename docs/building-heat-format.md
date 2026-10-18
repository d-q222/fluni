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
| `people` | People inside, scaled the same way as the user map: each agent counts as 50 in runs under 500 agents, else as 1 (the sim's own count) |
| `expected_sick` | Σ P(sick) of the people inside, scaled the same way. The plain count, for popups and messages |
| `heat` | 0–1, the map's own colour scale, from risk **above the model's baseline**: excess = Σ max(0, P(sick) − prior) of the people inside (prior = `DEFAULTS.prior` in `model/infer.js`, 2%), scaled the same way; heat = √(excess / colour max), capped at 1. The colour max is the 90th percentile of each snapshot's highest building excess (the highest of all when that is 0). A crowd at the baseline is not heat |
| `high` | `1` if `heat ≥ 0.5`, i.e. past the legend's midpoint, the buildings the map shows dark; else `0` |
| `radius_m` | Optional, for geofencing: √(footprint area / π) + 10 m of GPS slack, rounded; empty if the area is unknown. Added after the first version, so it is the last column |

- Rows are **snapshots every 15 minutes**: all rows with the same `t_iso` describe campus at that
  moment. To read the state at time t, take the rows with the latest `t_iso ≤ t`.
- A building with no row in a snapshot has fewer than 4 people (hidden on the map too) or is empty.
  Treat it as "no data", not as safe.
- P(sick) comes from the probability model (`model/infer.js`), the same values as `p_sick.csv`.
- Since 2026-10-17 `heat` and `high` use the excess over the prior, not `expected_sick`: with few
  reports everyone sits at the prior, and Σ P alone just measured crowds. The columns are unchanged.
- A building is only as "high" as the run's own scale: the colour max is per run.

## Which moment is "now"

The user map and the phone's walk-in warning must read the same snapshot, so both use this rule to turn
the device's clock into a moment in the run:

1. Take the device's current **local** weekday and time of day.
2. Find the **first run day with the same weekday**, and use that day at the same time of day.
3. If the run has no such weekday (e.g. a 2-day Mon-Tue run on a Saturday), use run day
   `daysSinceMonday mod runDays`, where `daysSinceMonday` is 0 for Monday to 6 for Sunday and
   `runDays` is the number of days the run covers. Same time of day.
4. Clamp to the run's first and last step.

Run days start at the local midnight of the run's first step (all times are local, as in `t_iso`).
Then read the snapshot at or before that time: the latest `t_iso ≤ t` in `building_heat.csv`
(snapshots every **15 minutes**), or the step containing t in the map bundle's `totals.json`
(**5-minute** steps). The map re-reads as the clock advances (1 s per s). Example: the default run starts
Monday 2026-01-05, so a Saturday 4:55 pm device shows 2026-01-10 16:55, i.e. the 16:55 step
(the 16:45 row of `building_heat.csv`).
