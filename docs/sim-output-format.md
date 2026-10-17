# Simulation output format (DRAFT)

> **Draft**, proposed by the synthetic data workstream (`sim/`). Per AGENTS.md rule 3, changes need
> agreement from the workstreams that use it. Example of every file: `sim/runs/mock_boring10/`.

A run is a folder `runs/<run_id>/`. Large tables are gzipped CSV; the full sim also writes a Parquet
mirror with the same columns. Booleans are `True`/`False`; missing values are empty.

## Conventions

- **Time:** `t` is the integer step index (step length `step_min` in `config.json`, default 5 min);
  `timestamp` is ISO local time. Runs start Monday 00:00.
- **Position:** `lat`, `lon` (WGS84) **and** `x_local_m`, `y_local_m` = metres east/north of the
  origin 37.418, −122.182 (the map bbox's SW corner; also in `config.json` → `local_frame`).
- **IDs:** agents `A0003`; buildings `bld_<osm way/relation number>`; rooms
  `bld_<n>_f<floor>_<name>`; entrances `ent_<nnnn>`.
- **Truth only:** the timeline holds ground truth (`disease_state`). The app's estimated P(sick)
  is not produced here; it belongs to the probability-model workstream.

## Files

| File | One row per | Columns |
|---|---|---|
| `config.json` | run | seed, all parameters, disease preset, archetype fractions, map/code version, local frame, distance tiers |
| `agents_static.csv` | agent | agent_id, archetype, class_year, home_dorm, home_room_id, class_schedule (`\|`-separated section ids), friend_group_id, team_id, transport_mode, mask_propensity, compliance, honesty, has_app, shares_location, sickness_behavior_profile |
| `timeline.csv.gz` | agent × step | t, timestamp, agent_id, lat, lon, x_local_m, y_local_m, floor, location_id, location_type, room_id, room_type, entrance_id, indoor, off_map, activity, event_id, moving, transport_mode, disease_state, days_since_infection, infectiousness, symptomatic, symptom_severity, masked, self_reported_status, test_status, isolating, intervention_action |
| `contacts.csv.gz` | pair × step | t, agent_a, agent_b, distance_m, distance_tier, duration_s, location_id, room_id, indoor |
| `room_exposure.csv.gz` | occupied room × step | t, room_id, occupants, infectious_occupants, quanta_concentration |
| `infections.csv` | infection | t, infectee_id, infector_id (`IMPORT` for off-campus), route (`close`/`aerosol`/`import`), location_id, room_id, infector_contribution |
| `reports_tests.csv` | event | t, agent_id, event (`self_report`/`report_other`/`test_taken`/`test_result`), value, target_agent_id, truthful |
| `schedule/sections.csv` | class section | section_id, course, room_id, days, start, end, enrolled_agent_ids |
| `schedule/events.csv` | social event | event_id, type, location_id, room_id, start, end, attendee_ids |
| `map/buildings.csv` | building | location_id, osm_id, name, type, lat, lon, floors, area_m2, capacity, ventilation_ach, indoor, entrance_sources |
| `map/rooms.csv` (+ `rooms.geojson`) | room | room_id, location_id, floor, room_type, capacity, area_m2, volume_m3, ventilation_ach, source, polygon_wkt |
| `map/entrances.csv` | door | entrance_id, building_id, lat, lon, source (`osm`/`estimated`/`fallback`) |
| `summary.json` | run | attack_rate, peak_day, measured_R, daily_incidence, infections by location type / archetype / route, n_imports |

## Value sets

- `disease_state`: `S`, `E`, `I_pre`, `I_sym`, `I_asym`, `R`. Infectious = `I_pre`, `I_sym`, `I_asym`.
- `distance_tier`: `1` < 1 m, `2` 1–2 m, `3` 2–5 m, `4` same room but ≥ 5 m apart.
- `entrance_id` is set only on the step an agent leaves (at the door) or enters a building.
- `off_map = True` means off campus: no position, location or room.
- `self_reported_status`: `none`, `might_be_sick`, `tested_positive`, `recovered`.
  `test_status`: `none`, `pending`, `positive`, `negative`.

## Size (full run)

7,500 agents × 4,032 steps ≈ 30M timeline rows: several GB as CSV, far more than a browser can
load. Consumers should read the Parquet mirror or a pre-aggregated extract.
