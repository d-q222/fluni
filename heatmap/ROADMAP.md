# Heat map roadmap

There are two separate products here. Keep them apart:

- **Demo view** (presenter only). A bird's-eye map that follows the simulated agents as dots, with
  room-level heat. Clicking a dot shows that agent's phone.
- **User-facing map** (what real users get). Aggregate heat only: no people, no positions, no
  properties. It is building-level, hides areas with fewer than 5 people, and has a predictive mode.

Sizes: S is under 1 h, M is 1–3 h, L is 3 h or more.

## Demo view

| # | Task | Size | Depends on | Done when |
|---|---|---|---|---|
| D1 | Load the teammate's real CSV (about 10 agents): add column aliases and handle the file size | M | real CSV | `?data=` loads it with no console errors |
| D2 | ~~Smooth movement on a sim-time clock~~ **Done**: footpath walking, see README | — | — | — |
| D3 | Rescale the heat for ~10 agents (σ, colour-scale maximum) | S | D1 | One sick agent in a room shows a clear blob, and the legend still makes sense |
| D4 | Fill building outlines by expected infected, and click a building for its count | M | `data/stanford_buildings.json`; CSV building names | Clicking a building shows its numbers |
| D5 | Show the predictive layer (U4) in the demo, with what actually happened overlaid afterwards | M | U4 | Scrub to a time: the forecast for +1 h appears next to the actual result |
| D6 | The phone shows only the user-facing map, plus an alert slot for the proximity workstream | S | U1, U2 | No dots or agent ids inside the phone |

## User-facing map

| # | Task | Size | Depends on | Done when |
|---|---|---|---|---|
| U1 | Building-level heat: fill building outlines instead of Gaussian blobs | M | D1 | The phone map shows only building-shaped fills |
| U2 | Hide buildings with fewer than 5 people, using a real count per building (today's rule is a smoothed density, not a count) | S | U1 | A building with 4 people is grey at every timestamp |
| U3 | Warn the user on entering a hot building, and always show the "may be inaccurate" disclaimer | S–M | U1 | The selected agent walks into a hot building and the banner appears |
| U4 | **Predictive mode** (below) | L | p_sick from the probability model, or the CSV | +1/+2/+3 h forecast with a range, and a backtest |
| U5 | Precompute `public_buildings.json` (t, building, n, expected infected, low, high) with privacy rules applied, and have the user-facing page read only that file | M | D1 | The file contains no agent ids or coordinates |
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
