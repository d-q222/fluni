# P(sick) output format

The probability model (`model/`) writes one file per sim run. The iOS app and anyone else who needs the
app's belief that a person is sick read it from here. The heat map computes the same numbers in the
browser from `model/infer.js`.

**Path:** `model/out/<run_id>/p_sick.csv`. Regenerate it with `node model/cli.mjs sim/runs/<run_id>`.
For a demo it is served from the laptop with the rest of the repo, at
`http://<laptop>.local:8000/model/out/<run_id>/p_sick.csv`.

| Column | Meaning |
|---|---|
| `agent_id` | Sim agent id, e.g. `A0005` |
| `t_iso` | When the value changed, sim time, ISO 8601 without a zone (same clock as `timestamp` in the timeline) |
| `p_sick` | The app's P(sick) from that moment on, 0–1, 4 decimals |

- Rows are **change points**, sorted by agent and then time. To read P for an agent at time t, take
  that agent's last row with `t_iso ≤ t`. Before an agent's first row, P is the prior (0.02).
- Built only from what a phone could know (contacts, self-reports, reports about others, tests),
  never from the sim's true disease state. It includes retroactive tracing: a row can raise P at the
  moment a later report arrived, never before.
- Changes to the model's parameters (`DEFAULTS` in `model/infer.js`: Rio's exposure constants, the
  dorm-room `quietQuanta`, humidity defaults, the 0.02 prior) are announced to the proximity workstream so the phone's own estimate
  matches.
