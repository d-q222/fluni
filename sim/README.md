# Synthetic agent data (sim)

Ground-truth simulation of student life on the Stanford campus: each agent's true position, room
and disease state over time, plus true contacts, room aerosol exposure, the transmission tree, and
self-reports/tests. No sensors are simulated; GPS/Bluetooth/ultrasound are derived downstream.
Owner: @aidenyj (see [WORKSTREAMS.md](../WORKSTREAMS.md)). Output format:
[docs/sim-output-format.md](../docs/sim-output-format.md).

> **Status:** the full simulator (~7,500 agents, 14 days, 5-minute steps) is being built. Until it
> lands, `runs/mock_boring10/` is a **mock run in the final format** so other workstreams can build
> against the real columns.

## Mock run

```bash
python3 sim/make_mock_run.py            # stdlib only; writes sim/runs/mock_boring10/
python3 sim/make_mock_run.py --days 5 --seed 1 --out /tmp/mock
```

10 "boring" agents, Mon–Wed, 5-minute steps. All live in Branner Hall (two per double) and do the
same day: breakfast at Arrillaga Dining → 10:00 class (Hewlett MWF, Gates TTh) → lunch → Lathrop
Library until 17:00 → dinner → dorm. They walk or bike door to door between real OSM entrances.
`A0003` catches flu off campus Monday 09:00, becomes symptomatic Wednesday, visits Vaden, tests
positive and isolates; roommate `A0002` reports them as possibly sick.

Same seed → byte-identical files.

What's fake in the mock (the real sim will do these properly):

- Movement is a straight line between doors, not routed along footpaths.
- Rooms are hand-placed rectangles, not procedurally subdivided footprints.
- Disease numbers (infectiousness, quanta, `summary.json`) are placeholders.
- No Parquet mirror yet (the real sim writes `.parquet` next to each large `.csv.gz`).

## Files

- `make_mock_run.py`: mock generator.
- `data/osm/buildings.geojson`, `data/osm/entrances.geojson`: Stanford buildings and doors
  extracted from OpenStreetMap (© OpenStreetMap contributors, ODbL).
- `runs/mock_boring10/`: the generated mock run. `timeline_by_agent/` holds the same timeline
  rows split into one plain CSV per agent, for easy eyeballing.
