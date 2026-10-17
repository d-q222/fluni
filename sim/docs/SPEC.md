PROMPT: STANFORD CAMPUS DISEASE-SPREAD AGENT SIMULATION (GROUND TRUTH)
=====================================================================

CONTEXT
-------
We are building a campus contact-tracing and risk-alert app. The app warns
users when someone nearby is likely infectious, gives each person a
probability that they are infected along with advice they can act on, and
shows infection heat maps.

This task is ONLY the ground-truth agent simulation of student life on the
Stanford campus. It records each agent's TRUE location and disease state over
time. Our own pipeline will derive GPS, Bluetooth and ultrasound signals from
this output later, so do NOT simulate sensors, phone signal or detection noise.

The output will be used to:
  1. Derive sensor observations downstream and score how accurately different
     detection and alert methods catch real exposures.
  2. Feed a heat-map front end and a per-agent infection-probability model.
     Clicking any agent at any timestep will show the app screen that agent
     would see, so the output must contain every ground-truth field that
     screen needs.
  3. Later, run closed-loop counterfactuals in which interventions change
     agent behavior (only a hook is needed now; see section 6).

SCOPE AND SCALE
---------------
- Duration: 14 simulated days, starting Monday 00:00.
- Timestep: 5 minutes (4,032 steps), configurable.
- Population: ~7,500 agents (all Stanford undergrads), configurable.
- Reproducibility: one random seed fully determines a run. Store the seed and
  the full config with every output. The same seed and config must give
  byte-identical output.
- Language: Python. Use numpy (vectorized) for agent state and pandas/pyarrow
  for output. Keep the code modular so the map, behavior, disease and output
  modules can each be swapped out.
- Performance target: a full 14-day run at 7,500 agents should finish in
  minutes on a laptop, not hours. Use spatial hashing/grids for neighbor
  queries; avoid O(N^2) pairwise checks per step.

1. CAMPUS MAP
-------------
OpenStreetMap (OSM) is the ONLY map data source. The base map data has
ALREADY been extracted from OSM via Overpass (bbox 37.418,-122.182 to
37.437,-122.158: El Camino to Campus Dr East, Sand Hill to Escondido Village).
Do NOT re-download. The files are in sim/data/osm/
(copy them into the project as data/osm/):

  buildings.geojson  827 building polygons (289 named). Properties include
                     id, name, type (OSM building tag), levels, address,
                     centroid [lon, lat], area_m2, entrance count, OSM id.
  entrances.geojson  1,193 entrance points, each with building_id and a
                     `source` field:
                       osm        102 real mapped doors (47 buildings)
                       estimated  597 doors where a footpath comes within
                                  12 m of the outline (max 4 per building)
                       fallback   494 single doors on the side facing the
                                  nearest path (so every building has >= 1)
                     OSM does not separate entrances from exits; treat every
                     door as bidirectional.
  paths.geojson      2,494 footways/paths/steps/cycleways/service roads.
  build.py           script that regenerates the three files from raw.json
                     (the raw Overpass response). Keep both for
                     reproducibility.

1a. Routing network
- Build a routing graph from paths.geojson (snap nearby endpoints, split at
  intersections). Connect every entrance point to the nearest path node with
  a short connector edge.
- Agents travel entrance -> path graph -> entrance. They ALWAYS enter and leave
  buildings through an entrance point of that building (nearest to their
  route, or randomly weighted among the building's doors). Doorways are
  realistic choke points where brief close contacts happen.
- Speeds: walk ~1.3 m/s, bike ~4.5 m/s (bikes use cycleway/service edges where
  possible; steps are walk-only). Interpolate positions along edges every
  timestep so movement looks natural on the map.
- Record the entrance used (entrance_id) on enter/exit timesteps so the
  downstream pipeline can study doorway exposure and model door-based sensors.
- Validation: flag buildings that only have fallback doors, and report how
  many agent trips used osm vs estimated vs fallback doors.

1b. Location typing
- Map OSM building/amenity tags plus name matching to location types:
  dorm, classroom, lecture_hall, dining, library, gym, lab, party_venue
  (row houses / frats), event_venue, common_room, outdoor, health_center
  (Vaden), admin, other.
- Keep a manual override table data/overrides/locations.csv
  (osm_id, name, location_type, capacity, notes) for buildings OSM tags
  wrong, leaves generic or leaves unnamed. KNOWN GAPS: Green Library and
  Memorial Church are not found under those names (probably tagged
  differently or merged into Main Quad). Resolve them in the override table,
  along with dining halls, row houses / frats and Vaden.
- Non-building outdoor areas (Main Quad, White Plaza, Meyer Green, stadium
  field, Frost lawn) are defined as polygons in data/overrides/outdoor.geojson
  and treated as outdoor locations.

1c. Rooms (not in OSM; generated procedurally)
OSM has no Stanford room layouts (only ~13 unnamed indoor items) and Stanford
does not publish floor plans as GIS data, so all rooms are generated:

  Procedural rooms (every building):
  - Floors = OSM `levels` if present, otherwise a per-type default (dorm 3,
    academic 2, house 2, etc.). Usable floor area = area_m2 * floors * ~0.7.
  - A per-type ROOM TEMPLATE decides the room mix, for example:
      dorm          double rooms (~18 m2, 2 beds) + 1 lounge/floor +
                    1 bathroom/floor + 1 kitchen/floor
      lecture_hall  1-2 large halls (100-300 seats) + a few seminar rooms
      classroom     seminar rooms (15-30) + offices + 1 lobby
      library       reading rooms (50-150) + study rooms (4-8) + stacks
      dining        1 dining room (capacity from area) + serving area
      gym           main floor + weight room + locker rooms
      lab           lab rooms (10-20) + offices
      party_venue   main room + kitchen + backyard (outdoor)
      default       generic rooms sized ~25 m2
    Rooms are allocated until the floor area is used up. Capacities come from
    area / m2-per-person by room type (seated lecture ~1 m2, dining ~1.5,
    party standing ~0.7, dorm by beds).
  - Room GEOMETRY: for each floor, subdivide the building footprint polygon
    into room polygons (e.g. a central corridor along the footprint's long
    axis with rooms on both sides, or recursive rectangle splitting for wide
    buildings). The corridor is a room too (type=corridor, transit only).
    Store each polygon in lat/lon so the viewer can draw rooms per floor when
    zoomed in.
  - Ground-floor rooms connect to the building's entrances via the corridor/
    lobby. Upper floors connect via a stair/elevator node. Agents walk
    entrance -> lobby/corridor -> room, so corridor contacts are captured.

  - Procedural rooms are good enough. Do NOT trace real floor plans or
    hand-enter real room data. Rooms only need to be plausible, not accurate.
  - Class sections must only be placed in rooms with type lecture_hall or
    seminar whose capacity >= enrollment.

  Every room gets: room_id, building_id, floor, room_type, capacity,
  area_m2, volume_m3 (area * ceiling height, ~3 m default, ~6 m for
  halls/gyms), ventilation_ach (per type, overridable), polygon, source
  (always "procedural").

- Inside a room, place agents at plausible continuous x/y positions within the
  room polygon (seat grid for lectures, clusters for parties and dining
  tables, beds for dorm rooms) so true inter-agent distances are meaningful
  for the distance tiers in section 4.

2. AGENTS AND ARCHETYPES
------------------------
Each agent has these static attributes:
  agent_id, archetype, class_year, home_dorm, home_room_id,
  class_schedule (list of section_ids), friend_group_id, team_id (athletes),
  transport_mode (walk/bike), mask_propensity, compliance (probability of
  following an app alert), honesty (probability of self-reporting truthfully),
  has_app, shares_location (altruistic GPS opt-in), sickness_behavior_profile.

The sim does NOT use has_app, shares_location or honesty for sensing. They are
stored so the downstream sensor-extraction pipeline can filter by them. Make
their default rates configurable (e.g. 60% has_app, 30% shares_location).

Archetypes (population fractions configurable). Each is defined by
parameters such as schedule density, social rate, mobility, compliance and
sick behavior, NOT by separate code paths.
  - Studious / library: 4-5 classes, long library blocks, study groups, few
    parties, high compliance, usually stays home when sick.
  - Social / Greek life: frequent parties Thu-Sat, large friend groups, attends
    large events, low compliance, often keeps going out when sick.
  - Athlete: daily practice blocks, gym, team dining, tight team contact
    cluster, attends games, medium compliance.
  - STEM / lab: labs in the Science & Engineering Quad, late nights, study
    groups, medium compliance.
  - Commuter / off-campus: arrives in the morning and leaves in the evening via
    an edge-of-campus entry point, few dorm contacts, a main source of
    off-campus infection imports. Off campus = agent is "off_map" (no position).
  - Homebody: mostly dorm and dining hall, low mobility, few contacts.
Draw the other attributes with mild correlations to archetype so the
population is heterogeneous rather than uniform.

3. DAILY BEHAVIOR
-----------------
Use a schedule plus a state machine:
- Class schedules: generate synthetic MWF and TTh course sections placed in
  real classroom and lecture-hall rooms with realistic sizes (seminars of
  10-20, lectures of 100-300). Each agent takes 3-5 courses. Classmates form
  a persistent contact group across both weeks. Class skipping depends on
  archetype.
- Routine: sleep in the home room, eat 2-3 meals at dining halls at
  stochastic times around mealtime peaks, attend classes, study (library,
  dorm, common room), gym, labs, practice.
- Social events, all generated stochastically with configurable rates:
    * Weekend parties: Thu-Sat nights at party venues, attendance driven by
      archetype and friend group, dense indoor crowding, long duration.
    * Dorm hangouts: small evening gatherings in dorm rooms and lounges among
      friend groups.
    * Sports games / large events: occasional big gatherings at the stadium,
      Maples or Frost (mixed indoor/outdoor).
    * Study groups: classmates meeting in library study rooms or common rooms,
      more often before exam-like days.
- Sick behavior (archetype-dependent via sickness_behavior_profile): once
  symptomatic, an agent may (a) stay in their dorm, (b) visit Vaden then
  isolate, or (c) carry on normally, possibly at reduced intensity. Draw this
  per agent per illness episode.
- Weekend schedules differ from weekdays: later wake times, no classes, more
  social activity.

4. DISEASE MODEL (INFLUENZA DEFAULT, PRESETS FOR OTHERS)
--------------------------------------------------------
States: S -> E -> I_pre -> (I_sym | I_asym) -> R
- Defaults for seasonal influenza: latent ~1-2 days, presymptomatic infectious
  ~1 day, infectious ~5-7 days, ~30% asymptomatic with reduced infectiousness.
  Draw durations from distributions (e.g. gamma), not fixed values.
- Infectiousness follows a viral-load curve over time since infection (peaks
  around symptom onset). Store it per timestep.
- Disease presets live in a config file: influenza (default), COVID-19,
  norovirus. Every parameter can be overridden.

Transmission has two routes, both computed every timestep:
  a) Close contact, using DISTANCE TIERS between pairs of agents in the same
     room or nearby outdoors:
       tier 1: < 1 m
       tier 2: 1-2 m
       tier 3: 2-5 m
     Each tier has a per-minute hazard weight. Outdoor contacts have a lower
     multiplier. Masks on either party reduce hazard (from mask_propensity
     and the current masked state).
  b) Room-level aerosol (Wells-Riley style): every infectious agent in a room
     emits quanta that scale with infectiousness. Each susceptible in the same
     room inhales a dose based on room volume, ventilation (ACH), time spent
     and masks. This applies even without close proximity.
  Infection probability per step = 1 - exp(-(hazard_close + hazard_aerosol)).
  Record which route caused each infection, plus the most likely infector.
  For aerosol infections, attribute the infector probabilistically in
  proportion to each source's contribution.

Seeding, using ONGOING IMPORTS:
- No fixed patient zero is required (allow an optional configurable
  initial_seeds = 0 by default).
- Each agent has a small daily probability of off-campus infection that
  depends on archetype: commuters highest, social/Greek elevated (off-campus
  parties), athletes slightly elevated (away games/travel), others low.
  Make the import rate configurable.
- Record imports in the transmission tree with infector_id = "IMPORT".

Calibration: tune default hazard weights so the no-intervention outbreak
produces a campus effective R of roughly 1.3-2.0 for flu. Report the measured
R, attack rate and peak day in the summary.

5. INTERVENTION HOOK (INTERFACE ONLY IN V1)
-------------------------------------------
- Only the "none" baseline is run in v1.
- Provide a clean callback interface that is called every timestep with the
  current OBSERVABLE-safe state (positions, self-reports, and whatever the
  downstream system passes in). It returns behavior modifications per agent,
  e.g. {agent_id: leave_location | wear_mask | isolate_until(t) | go_to_vaden}.
- Agents apply a modification with probability equal to their compliance.
- Include a trivial example intervention (e.g. "all symptomatic agents
  isolate") that proves the hook works and changes outcomes.
- Interventions must never be able to read ground-truth disease state through
  this interface unless explicitly flagged as an oracle baseline.

6. SELF-REPORTS AND TESTS (GROUND-TRUTH EVENTS)
-----------------------------------------------
These are behavioral events, not sensors, so they belong in the sim:
- Self-reports: an agent may set their status to might_be_sick,
  tested_positive or recovered, driven by symptoms and honesty. Include
  dishonest cases (a sick agent hiding illness, a healthy agent falsely
  reporting) and agents reporting someone else as possibly sick.
- Tests: some symptomatic agents visit Vaden and get tested, with configurable
  sensitivity, specificity and result delay.

7. OUTPUT
---------
Write everything to runs/<run_id>/. Write each table as gzipped CSV for
readability and as a Parquet mirror for fast loading (~30M timeline rows at
7,500 agents x 4,032 steps).

- config.json
    Seed, all parameters, disease preset, archetype fractions, map version and
    code version.

- map/buildings.csv, map/rooms.csv, map/rooms.geojson, map/entrances.csv,
  map/routing_graph.graphml
    buildings: location_id, osm_id, name, type, lat, lon, floors, area_m2,
    capacity, ventilation_ach, indoor, entrance_sources.
    rooms: room_id, location_id, floor, room_type, capacity, area_m2,
    volume_m3, ventilation_ach, plus polygon.
    entrances: entrance_id, building_id, lat, lon, source
    (osm|estimated|fallback).

- agents_static.csv
    One row per agent with every static attribute from section 2.

- schedule/sections.csv, schedule/events.csv
    Class sections (section_id, course, room_id, days, start, end, enrolled
    agent ids) and generated social events (event_id, type, location_id,
    room_id, start, end, attendee ids).

- timeline.csv.gz / timeline.parquet
    One row per agent per timestep:
      t, timestamp, agent_id, lat, lon, x_local_m, y_local_m, floor,
      location_id, location_type, room_id, room_type, entrance_id (on
      enter/exit steps), indoor, off_map, activity,
      event_id, moving, transport_mode,
      disease_state, days_since_infection, infectiousness, symptomatic,
      symptom_severity, masked,
      self_reported_status, test_status, isolating,
      intervention_action (null in baseline)

- contacts.csv.gz / contacts.parquet  (true contacts, for scoring)
    t, agent_a, agent_b, distance_m, distance_tier, duration_s, location_id,
    room_id, indoor
    Only pairs within 5 m or in the same room, aggregated per timestep.

- room_exposure.csv.gz
    t, room_id, occupants, infectious_occupants, quanta_concentration
    (supports aerosol-risk heat maps).

- infections.csv  (transmission tree)
    t, infectee_id, infector_id (or IMPORT), route (close/aerosol/import),
    location_id, room_id, infector_contribution

- reports_tests.csv
    t, agent_id, event (self_report/report_other/test_taken/test_result),
    value, target_agent_id, truthful

- summary.json
    Attack rate, peak day, measured R, daily incidence curve, infections by
    location type, by archetype and by route, number of imports.

App-screen requirement: given (agent_id, t), these files must be enough for
the downstream system to rebuild that agent's app screen once sensor
observations are derived: true position and location, own self-report and
test status, history of who was near them (contacts), room exposure and
current activity.

8. MAP ANIMATION VIEWER (ONLY EXTRA DELIVERABLE)
------------------------------------------------
A lightweight viewer built with MapLibre GL + deck.gl. Use the OpenFreeMap
base style (https://tiles.openfreemap.org/styles/positron), which is free and
needs no API key. Do NOT use CARTO tiles; they now need an API key. Extend
the existing index.html map prototype, which already supports building search,
click popups, layer toggles and colored entrance dots by source.
Show the "(c) OpenStreetMap contributors" credit.
Zoom levels:
  - Campus zoom: building outlines and agent dots.
  - z17+: entrance dots and agent dots inside buildings.
  - z19+: room polygons for a selected floor (floor picker), shaded by
    occupancy, with agents drawn inside their rooms.
It reads a run folder and animates agent dots on the real Stanford map, colored by disease state (S/E/I_pre/I_sym/
I_asym/R). It should have a play/pause control, a time scrubber and a speed
control, and clicking an agent should show its timeline row. Use it to check
visually that movement looks natural (classes fill at the top of the hour,
dining halls peak at mealtimes, parties on weekends, commuters come and go).

9. CLI
------
  python simulate.py --agents 7500 --days 14 --step-min 5 --seed 42 \
      --disease influenza --intervention none --out runs/
  python view.py runs/<run_id>

OUT OF SCOPE
------------
- GPS / Bluetooth / ultrasound / UWB sensor simulation (derived downstream
  from this data).
- Heat-map front end, infection-probability inference model, app UI and the
  live phone demo.
- Implementing real interventions (only the hook plus one trivial example).
- Sanity-check plots, unit tests and multi-seed batch runners (may come later;
  keep the code structured so they are easy to add).
