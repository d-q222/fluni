# `timeline_changes.csv.gz` (compact timeline)

Status: **proposed** by the heat map (decision 2026-10-17, "Option A"). The sim workstream is asked
to write it next to `timeline.csv.gz`. Until it does, `heatmap/tools/precompute.mjs` derives it from
the full timeline.

**Why:** the full run (~7,000 agents × 14 days × 5-min steps ≈ 28 M rows, ~5 GB raw) can't load in
a browser. Most rows repeat the previous row for that agent, so keeping only changes cuts the size
12–15× (~26 MB gzipped for the full run).

**Format:** the header and columns are identical to `timeline.csv.gz`
([sim-output-format.md](sim-output-format.md)). For each agent, a row is kept when:

1. it is the agent's first or last row; or
2. any of these columns differ from that agent's previous row: `lat, lon, location_id, room_id,
   floor, indoor, off_map, moving, disease_state, self_reported_status, test_status, isolating,
   activity`; or
3. the *next* row is a change, i.e. the last row of a stay. Readers interpolate between kept
   rows, so a stay needs its end time, otherwise the agent would appear to start walking the moment
   they arrived.

Rows stay sorted by `t`, then `agent_id`. Expanding back to every step means holding each agent's
last kept row; that reproduces the original values of the columns above.

**Companion file (heat map side):** `totals.json.gz`, from `heatmap/tools/precompute.mjs`. It holds
per-step building totals plus hourly forecasts for the user-facing map.
