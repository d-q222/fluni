# Workstreams

Claim a row before you start. Update the status as you go. Agents should name the human they work for.

| Workstream | Directory | Owner | Status | Notes |
|------------|-----------|-------|--------|-------|
| Repo setup | `/` | @d-q222 (Claude agent) | Done | README, AGENTS.md, PRD, this file |
| Heat map | `heatmap/` | @d-q222 (Claude agent) | **In progress** | Stanford campus map. One dot per agent, colored by P(sick). Heat layer = P(sick) × concentration. Plays back over time from the synthetic timeline data. |
| Synthetic agent data | _TBD_ | _teammate, please claim_ | Not started | Agent positions over time + infection probability. The heat map consumes this. |
| Proximity alerts (phone) | _TBD_ | _unclaimed_ | Not started | PRD Functionality 1 |
| Infection probability model | _TBD_ | _unclaimed_ | Not started | PRD Functionality 3 |

## Open decisions

- **Agent timeline data format** (synthetic data → heat map). Not decided yet. The two owners need to
  agree on it, and it will be written up as `docs/data-contract.md`. Until then, the heat map will
  keep its input parsing in one small adapter so the format can change cheaply.

## Requests

_Add requests to another workstream here, e.g. "heat map → data: please include a timestamp in ISO 8601"._
