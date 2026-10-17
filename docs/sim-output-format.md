# Simulation output format (DRAFT)

> **Draft**, proposed by the synthetic data workstream (`sim/`). Per AGENTS.md rule 3, changes need
> agreement from the workstreams that use it. Example of every file: `sim/runs/mock_boring10/` (mock)
> and `sim/runs/influenza_none_n10_d14_s2_f1f772f6/` (real simulator, 10 agents, 14 days).

A run is a folder `runs/<run_id>/`. Large tables are gzipped CSV; the full sim also writes a Parquet
mirror with the same columns. Booleans are `True`/`False`; missing values are empty.

## Conventions

- **Time:** `t` is the integer step index (step length `step_min` in `config.json`, default 5 min);
  `timestamp` is ISO local time. Runs start Monday 00:00.
- **Position:** `lat`, `lon` (WGS84) **and** `x_local_m`, `y_local_m` = metres east/north of the
  origin 37.418, −122.182 (the map bbox's SW corner; also in `config.json` → `local_frame`).
- **IDs:** agents `A0003`; buildings `bld_<osm way/relation number>` (the number alone, for ways and
  relations alike); places missing from OSM `bld_m_<slug>` (e.g. `bld_m_green_library`, no OSM
  outline: use `footprint_wkt` in `map/buildings.csv`); rooms `bld_<n>_f<floor>_<name>` (the
  simulator numbers them `<floor><nn>`, e.g. `bld_232805657_f2_201`); entrances `ent_<nnnn>` (index in
  `sim/data/osm/entrances.geojson`; manual places continue after the last index).
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
| `infections.csv` | infection | t, infectee_id, infector_id (`IMPORT` for off-campus and seeds), route (`close`/`aerosol`/`import`/`seed`), location_id, room_id, infector_contribution |
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
- In transit (walking/biking between buildings): `location_id`, `room_id`, `room_type`, `floor` empty,
  `location_type` = `outdoor`, `indoor` = False, `moving` = True, `activity` = `commute`.
- `location_type`: `dorm`, `classroom`, `lecture_hall`, `dining`, `library`, `gym`, `lab`,
  `party_venue`, `event_venue`, `common_room`, `outdoor`, `health_center`, `other`.
- `activity`: `sleep`, `relax`, `class`, `lab`, `study`, `eat`, `practice`, `gym`, `party`, `hangout`,
  `event`, `study_group`, `outdoor_leisure`, `commute`, `off_campus`, `isolate`, `health_visit`, `rest`,
  `idle`, `arrived_early`. During `class`/`lab`, `event_id` holds the `section_id`.
- `contacts`: every pair < 5 m apart (different floors excluded), plus same-room pairs at any distance
  (tier 4) in rooms of capacity ≤ 150. Pairs < 5 m across a wall appear with an empty `room_id`.
- `route = seed`: an initial case (`--initial-seeds`), not an off-campus import.
- `off_map = True` means off campus: no position, location or room.
- `self_reported_status`: `none`, `might_be_sick`, `tested_positive`, `recovered`.
  `test_status`: `none`, `pending`, `positive`, `negative`.

## Extras (simulator only; consumers may ignore)

- Extra columns, always **after** the columns above: `map/buildings.csv` + `x_local_m, y_local_m,
  n_rooms, source, footprint_wkt`; `map/rooms.csv` + `x0, y0, x1, y1, layout, indoor`;
  `map/entrances.csv` + `x_local_m, y_local_m`; `schedule/sections.csv` + `kind, location_id`;
  `schedule/events.csv` + `name`; `summary.json` has extra keys after the listed ones.
- Extra files: `timeline_changes.csv.gz` (compact timeline, [timeline-changes-format.md](timeline-changes-format.md)),
  `timeline.parquet`, `contacts.parquet`, `room_exposure.parquet` (same columns),
  `map/paths.geojson` (footpath network), `map/entry_points.csv` (where commuters enter campus).

## Size (full run)

7,500 agents × 4,032 steps ≈ 30M timeline rows: several GB as CSV, far more than a browser can
load. Consumers should read the Parquet mirror or a pre-aggregated extract. Measured for 7,500 agents
× 7 days: `timeline.csv.gz` 288 MB (Parquet 160 MB), `contacts.csv.gz` 657 MB, `timeline_by_agent/`
3.0 GB; 14 days is about double.
