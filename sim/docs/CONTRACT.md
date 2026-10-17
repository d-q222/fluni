# Module contract (v0.1)

Full product spec: `docs/SPEC.md`. **Output format is BINDING: it must match the "d2" reference
run at `sim/runs/mock_boring10/` (generator: `sim/make_mock_run.py`)
— same files, same column names and order, same ID formats, value vocabularies and formatting.
See "OUTPUT FORMAT (d2)" at the bottom. Extra columns may only be APPENDED after the mock's
columns, and only in files other than timeline/contacts/room_exposure.** This file pins the interfaces between modules so they can be
built in parallel. **Do not change a signature or attribute name listed here without telling the
integrator.** You may add extra helpers/attributes freely.

Python: `sim/.venv/bin/python` (numpy, pandas, pyarrow, scipy installed). No other
third-party deps. Run everything from `sim/`.

## Global rules

- **Determinism**: same seed + config => byte-identical output. Only use the `numpy.random.Generator`
  you are handed (never `np.random.*` globals, `random`, `hash()` of str, wall-clock time, or
  iteration over a `set`/unordered dict when the order affects RNG draws or output). For stable
  per-key seeds use `zlib.crc32(key.encode())`.
- **Indices, not strings**, in hot arrays: agents are `0..N-1`, buildings `b` = `0..B-1`, rooms
  `r` = `0..R-1`. Strings (`location_id`, `room_id`, `agent_id`) only at output time.
- Shared enums live in `campussim/codes.py` (archetypes, disease states, activities, location types,
  statuses, sentinels `ROOM_OFF_MAP=-1`, `ROOM_TRANSIT=-2`). Use them; don't redefine.
- Coordinates: campus-local meters via `campussim/geo.py` (`to_xy(lon, lat)`, `to_ll(x, y)`),
  origin 37.418, -122.182 (SW corner, same as the mock). `x_local_m/y_local_m` = these coords.
- Time: integer step `t` in `0..T-1`, `T = days*24*60/step_min`; `steps_per_day = 1440/step_min`.
  Day `d = t // steps_per_day`, weekday `(start_weekday + d) % 7` (Mon=0). Never hard-code 5 min.
- Activity names follow the mock: `eat` (meals), `relax` (at home awake), `commute` (transit),
  `idle`/`arrived_early` (lingering); see codes.ACTIVITIES. Bedrooms: room_type in codes.BEDROOM_TYPES.
- Config: each module owns **its own** `configs/<section>.json` (read as `cfg["<section>"]`).
  Every tunable number goes there, not in code. `cfg["run"]` holds seed/n_agents/days/step_min/
  start_date/start_weekday/initial_seeds/intervention. Disease presets: `configs/diseases.json`
  (`cfg["disease"]` = selected preset). Loader: `campussim/config.py`.
- Must work at **N=10** (current target) and scale to **N=7,500, 4,032 steps in minutes**: vectorize
  per-step work; per-step Python loops only over small subsets (infectious, traveling, events).
- Style: plain modules, numpy/pandas, short docstrings, no unit-test framework required, but each
  module should have a `if __name__ == "__main__":` smoke test or a `scripts/smoke_<module>.py`.

## RNG streams (created by engine)

`ss = np.random.SeedSequence(seed)`; children in this fixed order:
`map, population, sections, events, plans, behavior, disease, reports, intervention`.
Each module receives `rng = np.random.default_rng(child)`. Map layout must NOT depend on the run
seed: campus uses `cfg["map"]["map_seed"]` (fixed, default 0).

---

## 1. `campussim/campus.py` — Campus map   (config: `configs/map.json`)

```python
class Campus:
    @classmethod
    def build(cls, cfg_map: dict, data_dir="data/osm") -> "Campus"
    buildings: pd.DataFrame   # index = b; columns: location_id, name, type, lat, lon, x, y,
                              #   footprint_m2, levels, capacity, ventilation_ach, indoor(bool),
                              #   footprint_wkt (lon/lat WKT), n_rooms, source ("osm"/"manual")
    rooms: pd.DataFrame       # index = r; columns: room_id, location_id, b, room_type, floor,
                              #   capacity, area_m2, ceiling_m, volume_m3, x0, y0, x1, y1, cx, cy,
                              #   lat, lon, polygon_wkt, layout ("seated"|"mingle"|"bed"|"free")
    # fast numpy mirrors (len R): room_b, room_cap, room_vol, room_ach, room_indoor(bool),
    #   room_floor, room_x0, room_y0, room_x1, room_y1, room_layout (int code into LAYOUTS)
    # (len B): b_type (int code into codes.LOCATION_TYPES), b_x, b_y
    LAYOUTS = ["seated", "mingle", "bed", "free"]
    entry_points: pd.DataFrame  # index = e; entry_id, name, x, y, lat, lon (edge-of-campus)
    version: str                 # sha of input data + map config
    def buildings_of_type(self, type_name) -> np.ndarray[int]          # b indices, sorted
    def rooms_of(self, b, room_type=None) -> np.ndarray[int]            # r indices, sorted
    def find_building(self, name) -> int                               # exact name, else -1
    def route(self, src, dst) -> tuple[np.ndarray, float]   # polyline (K,2) xy meters, length m
    def distance(self, src, dst) -> float                    # meters, cached
    #   src/dst are ("b", b_idx) | ("e", entry_idx) | ("xy", (x, y))
    def write(self, map_dir)  # d2 files: map/buildings.csv, map/rooms.csv, map/rooms.geojson,
                              #   map/entrances.csv; plus SPEC extras map/paths.geojson,
                              #   map/entry_points.csv (columns: see OUTPUT FORMAT)
```
IDs (d2 format): `location_id = "bld_<osm way or relation number>"` (manual places
`"bld_m_<slug>"`), `osm_id = "way/<n>"` ("" for manual). `room_id = f"{location_id}_f{floor}_{floor*100+k:03d}"`
(e.g. `bld_232805657_f2_201`; k = 1.. per floor). `entrance_id = f"ent_{i:04d}"` where i = feature
index in data/osm/entrances.geojson (manual-place entrances continue after the last index).
Room types (exact strings; mock names first): `dorm_single, dorm_double, dorm_triple, dorm_quad`
(bedrooms = codes.BEDROOM_TYPES), `lobby` (dorm common/lounge), `dining_room, lecture_hall,
seminar, reading_room, exam_room` (mock), plus `lounge, classroom, study_room, lab, weight_room,
practice_gym, pool, party_room, arena, waiting_room, cafe, outdoor_area, generic`.
Expose `entrances` DataFrame (entrance_id, building_id, lat, lon, source, x, y, b) and
`nearest_entrance(b, x, y) -> entrance idx` (the timeline `entrance_id` uses it).
Every non-"other" building has >=1 room; "outdoor" locations have one `outdoor_area` room with
`indoor=False`. Routing uses the OSM path network (scipy.sparse.csgraph), multi-entrance,
cached; polylines start/end at the building access points (callers add the in-room leg).

## 2. `campussim/population.py`   (config: `configs/population.json`, incl. archetype params)

```python
@dataclass
class Population:
    N: int
    agent_id: list[str]            # "A0000".. zero-padded to 4+ digits
    archetype: np.ndarray[int8]    # index into codes.ARCHETYPES
    class_year: np.ndarray[int8]   # 1..4
    home_b: np.ndarray[int32]      # dorm building, -1 for commuters
    home_room: np.ndarray[int32]   # bedroom r, -1 for commuters
    bed_slot: np.ndarray[int8]     # 0.. index among roommates
    friend_group: np.ndarray[int32]
    team_id: np.ndarray[int32]     # -1 if not athlete
    teams: list[dict]              # team_id -> {"name","sport","practice_rooms":[r..]}
    transport: np.ndarray[int8]    # index into codes.TRANSPORT
    speed_mps: np.ndarray[float]
    mask_propensity, compliance, honesty: np.ndarray[float]   # 0..1
    has_app, shares_location: np.ndarray[bool]
    sick_profile: np.ndarray[int8] # index into codes.SICK_PROFILES
    entry_e: np.ndarray[int32]     # commuters' entry point e, else -1
    fav_dining, fav_library, fav_common: np.ndarray[int32]   # building b
    class_schedule: list[list[int]]   # section indices; filled by schedule.build_sections
    def param(self, name) -> np.ndarray  # per-agent value of archetype param `name`
    def to_frame(self, campus, sections) -> pd.DataFrame   # agents_static.csv, d2 columns exactly
def build_population(cfg, campus, rng) -> Population
```
Small-N rule: fill dorms in a seeded order so a 10-agent run lives in 1-2 dorms (agents meet).
Archetype parameters (`cfg["population"]["archetypes"][name][param]`) are the single source of
truth for archetype behavior; other modules read them through `pop.param(...)`. Required params
(others may be added by their consumers): `n_courses`, `class_skip`, `wake_h`, `wake_sd_h`,
`weekend_wake_delay_h`, `bed_h`, `bed_sd_h`, `meal_p` ([breakfast,lunch,dinner]),
`flex_weights` ({library, dorm_study, common_room, gym, outdoor, lab, home}), `party_p`,
`event_p`, `hangout_rate`, `study_group_rate`, `import_daily_p`, `sick_profile_p`
([cautious,moderate,carefree]), `carry_on_intensity`, `commuter` (bool), `arrive_h`, `leave_h`.

## 3. `campussim/schedule.py`   (config: `configs/schedule.json`)

```python
def build_sections(cfg, campus, pop, rng) -> pd.DataFrame
    # index = section idx s. columns: section_id, course, kind ("seminar"|"lecture"|"lab"),
    #   r (room idx), room_id, location_id, days ("MWF"/"TTh"/"W"...), weekdays (list[int]),
    #   start_min, end_min (minutes after midnight), enrolled (list[int] agent idx)
    # side effect: pop.class_schedule[i] = sorted section indices
def build_events(cfg, campus, pop, sections, rng) -> pd.DataFrame
    # index = event idx k. columns: event_id, type ("party"|"dorm_hangout"|"sports_game"|
    #   "large_event"|"study_group"), name, r, room_id, location_id, day,
    #   start_min, end_min  (ABSOLUTE minutes since sim start; may cross midnight),
    #   attendees (list[int])
def sections_frame_for_csv(sections) / events_frame_for_csv(events, pop) -> pd.DataFrame
    # d2 columns (see OUTPUT FORMAT): lists `|`-joined agent_ids; sections HH:MM, events ISO
```

## 4. `campussim/plans.py`   (config: `configs/plans.json`)

```python
@dataclass
class Plans:
    act: np.ndarray[int8]     # (N, T) activity code (codes.ACT)
    room: np.ndarray[int32]   # (N, T) intended room r, or ROOM_OFF_MAP. During "commute" (transit) steps
                              #   room = the DESTINATION room (or ROOM_OFF_MAP when leaving campus)
    event: np.ndarray[int32]  # (N, T) event idx or -1; section idx is NOT stored here
    section: np.ndarray[int32]  # (N, T) section idx or -1 (class/lab steps)
def build_plans(cfg, campus, pop, sections, events, rng) -> Plans
```
Plans are the intended schedule only (no sickness). Includes sleep, meals, classes (with skips),
practice, labs, flex study/gym/outdoor, events (with per-agent arrival/departure jitter),
commuter arrivals/departures, weekend differences, and transit steps inserted before each
building change using `campus.distance(...) / pop.speed_mps`.

## 5. `campussim/behavior.py` — runtime movement   (config: `configs/behavior.json`)

```python
class Behavior:
    def __init__(self, cfg, campus, pop, plans, rng)
    entrance: np.ndarray[int32]   # entrance idx this step, -1 otherwise: set on the step an agent
                                  #   exits a building (at the door) and the first step in a room
                                  #   after a trip (d2 timeline entrance_id)
    # --- per-agent current state (len N), valid after step(t) ---
    room: np.ndarray[int32]       # current room r | ROOM_OFF_MAP | ROOM_TRANSIT
    b: np.ndarray[int32]          # current building b, -1 when off map / in transit
    x, y: np.ndarray[float]       # campus meters; NaN when off map
    floor: np.ndarray[float]      # NaN when not in a room
    indoor, moving, off_map, masked, isolating: np.ndarray[bool]
    act: np.ndarray[int8]         # actual activity this step
    event: np.ndarray[int32]      # event idx or -1
    # --- override API (called by engine / reports / interventions) ---
    def set_isolation(self, i, until_t)          # stay in home room (commuters: off map)
    def end_isolation(self, i)
    def schedule_vaden(self, i, start_t, n_steps)# go to Vaden waiting room in that window
    def set_carry_on(self, i, intensity | None)  # sick but going out; drop optional acts w.p. 1-intensity
    def leave_location(self, i)                  # go home for the rest of the current plan block
    def force_mask(self, i, until_t)
    def step(self, t, symptomatic: np.ndarray[bool]) -> None
```
Movement: room change inside the same building = instant; different building = trip along
`campus.route`, interpolated each step at `pop.speed_mps`; arriving off-map via
`pop.entry_e`. In-room position by room layout (seated grid / mingle clusters keyed by friend
group, re-sampled periodically / bed slot / free uniform), kept stable during a visit. Mask drawn
per visit from `mask_propensity` x context factor (x boost when symptomatic). Override precedence:
isolation > Vaden visit > leave_location > carry-on drops > plan.

## 6. `campussim/contacts.py`   (config: `configs/contacts.json`)

```python
def find_contacts(campus, room, x, y, cfg_contacts) -> dict[str, np.ndarray]
    # keys: a, b (agent idx, a<b), dist (m, 2D), tier (1:<1m, 2:1-2m, 3:2-5m, 4: same room >=5m),
    #       same_room (bool), r (shared room idx or -1), bld (shared building idx or -1),
    #       indoor (bool: both indoor), wall (bool: True when NOT same room and NOT both outdoor —
    #       disease ignores wall=True pairs for close-contact hazard)
    # d2 rule (mock): every pair with 2D distance < 5 m (same floor if both indoor; floors differ ->
    #   skip), PLUS every same-room pair at any distance (tier 4) for rooms with capacity <=
    #   same_room_max_capacity (bigger rooms: only < 5 m). Transit/outdoor agents included in the
    #   5 m search. KD-tree / grid; never O(N^2) over the population. Sorted by (a, b).
```

## 7. `campussim/disease.py`   (config: `configs/diseases.json` presets)

```python
class Disease:
    def __init__(self, cfg, campus, pop, rng)   # cfg = full config; uses cfg["disease"], cfg["run"]
    state: np.ndarray[int8]                 # codes.DISEASE_STATES
    t_infected: np.ndarray[int]             # -1 if never
    infectiousness: np.ndarray[float]       # current, 0..~2 (viral-load curve x individual mult)
    severity: np.ndarray[float]             # current symptom severity 0..1 (0 if not I_sym)
    room_conc: np.ndarray[float]            # (R,) quanta/m^3 after this step
    infections: list[dict]                  # transmission tree rows (see SPEC §7 infections.csv),
                                            #   with indices: t, infectee, infector (-1 = IMPORT),
                                            #   route, r, b, contribution
    def seed_initial(self, n, t=0)
    def step(self, t, beh, contacts) -> dict  # returns {"onset": idx array of new I_sym,
                                              #   "recovered": idx array, "infected": idx array}
    # step order: progress states -> imports -> aerosol update -> close-contact hazard ->
    #   infection draws + attribution. Masks from beh.masked; positions/rooms from beh.
    def room_exposure_rows(self, t, beh) -> dict[str, np.ndarray]  # r, occupants,
                                              #   infectious_occupants, quanta_concentration
                                              #   (rooms occupied or conc > threshold)
```

## 8. `campussim/reports.py` + `campussim/interventions.py`  (configs: `reports.json`, `interventions.json`)

```python
class Reports:      # illness response + self-reports + tests (ground-truth behavioral events)
    def __init__(self, cfg, campus, pop, rng)
    self_status: np.ndarray[int8]   # codes.SELF_STATUS (what the agent's app shows)
    test_status: np.ndarray[int8]   # codes.TEST_STATUS
    events: list[dict]              # t, agent (idx), event, value, target (idx|-1), truthful
    def step(self, t, disease, beh, contacts, disease_events) -> None
    # on symptom onset: draw response per episode from pop.sick_profile -> call
    #   beh.set_isolation / beh.schedule_vaden(+then isolate) / beh.set_carry_on.
    # tests at Vaden (sensitivity/specificity/delay), self-reports with honesty,
    # withheld reports (value="withheld", truthful=False), false reports, report_other.

# interventions.py
@dataclass(frozen=True)
class Action: kind: str ("leave_location"|"wear_mask"|"isolate_until"|"go_to_vaden"); until_t: int = -1
class ObservableState: t, timestamp, x, y, room, b, off_map (read-only copies), self_status,
    external (dict from downstream), truth (None unless intervention.oracle)
class Intervention:
    name = "none"; oracle = False
    def step(self, obs: ObservableState) -> dict[int, list[Action]]
REGISTRY: dict[str, type[Intervention]]  # "none", "self_report_isolate", "symptomatic_isolate_oracle"
def build_observable(t, timestamp, beh, reports, disease, intervention, external) -> ObservableState
def apply_actions(actions, beh, pop, rng, t) -> list[str | None]  # per agent intervention_action
    # string for the timeline, e.g. "isolate_until:1234" or "declined:wear_mask"; applied w.p.
    # pop.compliance[i]; iterate agents in sorted order.
```

## 9. `campussim/output.py` + `campussim/summary.py`   (config: `configs/output.json`)

```python
class RunWriter:
    def __init__(self, run_dir, cfg)
    def write_json(self, name, obj)                      # sorted keys, indent 2
    def write_table(self, rel_path, df, parquet=False, gz=False)   # deterministic csv(.gz) [+parquet]
    def open_stream(self, name, columns_schema)          # name in {"timeline","contacts","room_exposure"}
    def append(self, name, df)                           # appends to <name>.csv.gz AND <name>.parquet
    def close(self)
def timeline_frame(t0, t1, buffers, campus, pop, events, step_timestamps) -> pd.DataFrame
    # buffers: dict of (steps, N) arrays named: room, b, x, y, floor, indoor, off_map, act,
    #   event, moving, state, dsi, inf, symptomatic, severity, masked, self_status, test_status,
    #   isolating, action (object array, None in baseline). Produces SPEC §7 timeline columns,
    #   rows ordered by (t, agent_id).
def compute_summary(cfg, campus, pop, infections_df, n_steps) -> dict   # summary.py
```
Formatting/IDs: follow OUTPUT FORMAT (d2) at the bottom of this file.

## 10. `view.py` + `campussim/viewer_template.html`
Reads only a run folder (the SPEC §7 files) -> self-contained `runs/<id>/viewer.html`
(MapLibre GL from unpkg, OSM raster basemap, building footprints, agent dots by disease state,
play/pause, scrubber, speed, click agent -> its timeline row). Subsamples agents/steps for
large runs. `python view.py runs/<run_id> [--no-open] [--max-agents N] [--stride K]`.

## Engine (integrator)
`campussim/engine.py` + `simulate.py`: build everything, loop steps:
`beh.step(t, symptomatic) -> contacts = find_contacts(...) -> dis.step(t, beh, contacts) ->
reports.step(...) -> obs/intervention/apply_actions -> buffer + stream outputs`, per-day flush.
Run id: `{disease}_{intervention}_n{N}_d{days}_s{seed}_{confighash8}` (no wall-clock).


---

## OUTPUT FORMAT (d2) — binding
Reference: `sim/runs/mock_boring10/`. CSV via csv/pandas with header, `newline=""`,
gzip `mtime=0`. Booleans `True`/`False`. Missing/null = empty string. Lists joined with `|`.
Rounding: lat/lon 7 dp, x/y/distance 2 dp, days_since_infection 3 dp, infectiousness 4 dp,
symptom_severity 3 dp, quanta_concentration 6 dp. Rows sorted by (t, agent_id) (contacts by
(t, agent_a, agent_b); room_exposure by (t, room_id); reports by (t, agent_id)).

run folder:
```
config.json  summary.json  agents_static.csv  infections.csv  reports_tests.csv
timeline.csv.gz  contacts.csv.gz  room_exposure.csv.gz
timeline_by_agent/<agent_id>.csv          (same columns as timeline)
map/buildings.csv map/rooms.csv map/rooms.geojson map/entrances.csv
schedule/sections.csv schedule/events.csv
# SPEC extras (allowed): timeline.parquet contacts.parquet room_exposure.parquet
#   map/paths.geojson map/entry_points.csv
```
- **timeline** columns (exact): `t,timestamp,agent_id,lat,lon,x_local_m,y_local_m,floor,location_id,
  location_type,room_id,room_type,entrance_id,indoor,off_map,activity,event_id,moving,transport_mode,
  disease_state,days_since_infection,infectiousness,symptomatic,symptom_severity,masked,
  self_reported_status,test_status,isolating,intervention_action`
  timestamp ISO `2026-01-05T00:05:00`. In transit: location_id "", location_type "outdoor",
  room_id/room_type/floor "", indoor False, moving True, activity "commute". Off map: lat/lon/x/y/
  floor/location_id/location_type/room_id/room_type "", indoor False, off_map True, activity
  "off_campus" (or "isolate"). event_id = section_id during class/lab (mock does this) else event
  id or "". days_since_infection "" when S. intervention_action "" in baseline.
- **contacts**: `t,agent_a,agent_b,distance_m,distance_tier,duration_s,location_id,room_id,indoor`
  location_id = shared building's location_id else ""; room_id = shared room else "";
  indoor = both indoor; duration_s = step seconds.
- **room_exposure**: `t,room_id,occupants,infectious_occupants,quanta_concentration` (rows for rooms
  occupied or conc > 1e-6).
- **infections**: `t,infectee_id,infector_id,route,location_id,room_id,infector_contribution`
  (infector "IMPORT", route import/close/aerosol/seed; location/room "" for imports).
- **reports_tests**: `t,agent_id,event,value,target_agent_id,truthful` (event self_report /
  report_other / test_taken (value "pending") / test_result (positive/negative); truthful "" for tests).
- **agents_static**: `agent_id,archetype,class_year,home_dorm,home_room_id,class_schedule,
  friend_group_id,team_id,transport_mode,mask_propensity,compliance,honesty,has_app,
  shares_location,sickness_behavior_profile` — agent_id `A0000`; class_year = graduation year
  (2026..2029); home_dorm = building NAME ("OFF_CAMPUS" for commuters, home_room_id ""); class_schedule
  `SEC_..|SEC_..`; friend_group_id `FG00`; team_id `TM00` or ""; profile in codes.SICK_PROFILES.
- **map/buildings.csv**: `location_id,osm_id,name,type,lat,lon,floors,area_m2,capacity,ventilation_ach,
  indoor,entrance_sources` (+ appended extras allowed, e.g. footprint_wkt, source). entrance_sources
  = sorted `|`-joined set of entrance sources.
- **map/rooms.csv**: `room_id,location_id,floor,room_type,capacity,area_m2,volume_m3,ventilation_ach,
  source,polygon_wkt` (source "procedural"; polygon_wkt `POLYGON((lon lat, ...))` closed ring, 7 dp)
  (+ appended extras allowed: x0,y0,x1,y1,layout). rooms.geojson: same props minus polygon_wkt.
- **map/entrances.csv**: `entrance_id,building_id,lat,lon,source`.
- **schedule/sections.csv**: `section_id,course,room_id,days,start,end,enrolled_agent_ids`
  (section_id `SEC_MWF_01`/`SEC_TTH_03`/`SEC_LAB_02`, days MWF/TTh/M..., start/end `HH:MM`)
  (+ appended extras: kind, location_id).
- **schedule/events.csv**: `event_id,type,location_id,room_id,start,end,attendee_ids` (event_id
  `EV00012`, start/end ISO timestamps) (+ appended: name).
- **config.json**: keys run_id, seed, n_agents, days, step_min, start, disease, intervention,
  archetype_fractions, map_version, code_version, local_frame {origin_lat, origin_lon, units, x, y},
  distance_tiers {"1":"<1 m","2":"1-2 m","3":"2-5 m","4":"same room, >=5 m"}, plus "params" = full cfg.
- **summary.json**: attack_rate, peak_day, measured_R, daily_incidence, infections_by_location_type,
  infections_by_archetype, infections_by_route, n_imports (+ extras allowed).
