# Heat map roadmap

There are two separate products here. Keep them apart:

- **Demo view** (presenter only). A bird's-eye map that follows the simulated agents as dots, with
  room-level heat. Clicking a dot shows that agent's phone.
- **User-facing map** (what real users get). Aggregate heat only: no people, no positions, no
  properties. It is building-level, hides buildings with only 1–3 people, and has a predictive mode.

Sizes: S is under 1 h, M is 1–3 h, L is 3 h or more.

## Demo view

| # | Task | Size | Depends on | Done when |
|---|---|---|---|---|
| D1 | **In progress (Option A)**: the streaming loader is done; `tools/precompute.mjs` writes the compact timeline and `totals.json.gz` (validated). Still to do: the app reading `totals.json.gz` and `timeline_changes.csv.gz` when present, and the sim writing the compact file itself | M | — | The full run opens in under 10 s |
| D2 | ~~Smooth movement on a sim-time clock~~ **Done**: footpath walking, see README | — | — | — |
| D7 | ~~Better heat diffusion~~ **Done**: heat stays inside buildings, lingers about 30 min after people leave, and scales to 7,000 agents (`diffuse.js`, `masks.js`). (The old `HeatGrid` was removed after the design pass merged.) | — | — | — |
| D3 | Rescale the heat for ~10 agents (σ, colour-scale maximum) | S | D1 | One sick agent in a room shows a clear blob, and the legend still makes sense |
| D4 | Fill building outlines by expected infected, and click a building for its count | M | `data/stanford_buildings.json`; CSV building names | Clicking a building shows its numbers |
| D5 | Show the predictive layer (U4) in the demo, with what actually happened overlaid afterwards | M | U4 | Scrub to a time: the forecast for +1 h appears next to the actual result |
| D6 | The phone shows only the user-facing map, plus an alert slot for the proximity workstream | S | U1, U2 | No dots or agent ids inside the phone |

## User-facing map

| # | Task | Size | Depends on | Done when |
|---|---|---|---|---|
| U1 | ~~Building-level fills~~ **Done** (`buildings.js`) | | | |
| U2 | ~~Real per-building count, hide tiny groups~~ **Done**: counts come from `aggregate.js`; only 1–3 people are hidden; small runs are scaled ×50 | | | |
| U3 | ~~Walk-in warning and disclaimer~~ **Done**: room-level warning, plus a demo-only "the person next to you is sick" alert | | | |
| U4 | ~~Predictive mode~~ **Done** (`forecast.js`): +1/+2/+3 h, an 80% range, and a backtest (64% coverage on the mock; the ranges are too narrow, so worth revisiting with more days or a correlation-aware model) | | | |
| U5 | **Partly done**: the user map reads only `aggregate.js` totals in the page. Still to do: a precomputed totals file for the full run, which is too big for the browser | M | full sim run | |
| U6 | Privacy note: stop counts leaking individuals (e.g. a count going 4 → 5), and never show live per-person movement | S | U5 | A one-paragraph threat note plus a check script |

## Predictive mode (U4): first version

- **What it forecasts:** expected infected people per building at +1 h, +2 h and +3 h, with a
  low–high range.
- **Method:**
  1. For each agent, estimate the chance of being in each building in each 30-minute slot of the
     day, from earlier days in the CSV. Fall back to class schedules where there's no history.
  2. Multiply that by the agent's P(sick).
  3. Sum over agents for each building.
- **Backtest:** forecast day 2 from day 1, then compare with what actually happened.
- **Inputs:** agent id, time and building from the CSV. P(sick) comes from the probability model,
  which is what the app believes; ground-truth `sick` can stand in until the model is ready.
- **Showing uncertainty:**
  - Each agent counts as an independent coin flip, so run about 200 simulations to get an 80% range.
  - Show the range ("about 1–4 people"), and let it widen with the horizon.
  - Label the layer "Forecast" and draw it hatched.
  - Show a backtest score, not an accuracy claim.
  - Apply the fewer-than-5 rule here too.

## Open questions for the product owner

1. **Tier-1, privacy and architecture.** Should the user-facing map read only a precomputed
   aggregates file and never the agent CSV? *Recommended: yes (U5).*
2. **Tier-1, privacy and data model.** With ~10 agents, the fewer-than-5 rule hides almost
   everything. Should each agent stand for, say, 50 people, with that labelled on screen?
   *Recommended: yes, otherwise the user-facing map is blank.*
3. **Tier-1, data model.** Should P(sick) as the app believes it and the true sick status be two
   separate columns? *Recommended: yes. The forecast uses the belief; the backtest uses the truth.*
4. **Tier-1, privacy.** Should the entry warning be building-level only, based only on the user's
   own device location? *Recommended: yes.*
5. What counts as a "hot" building? *Recommended: expected infected ≥ 2, or ≥ 10% of the people
   there, stated in the legend.*
6. Is the forecast horizon fixed? *Recommended: three buttons, +1 h, +2 h and +3 h.*
7. Final map stack, Leaflet or Google Maps? *Recommended: Leaflet unless a custom style is a must.
   Building fills are the same work either way.*

## Known blockers in the current code

- The phone's heat is computed in-page from every agent's exact position, and `window.fluni`
  exposes all the data. That's fine for the demo, but the user-facing map needs U5.
- The user-facing heat is smoothed points, not buildings (U1). The fewer-than-5 rule is a density
  estimate, not a count (U2).
- The whole CSV is parsed in the browser, so a very large file will freeze the page (D1).
- The colour-scale maximum is computed from whatever data is loaded, so a forecast and the actual
  data won't share a scale.
