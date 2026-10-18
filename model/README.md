# model: infection probability

Estimates P(person is infected right now) for every agent, using only what a real app could know:
phone-detected contacts, self-reports, reports about others and test results. It never reads
`disease_state`, `infectiousness` or any other ground truth. Implements PRD Functionality 3.

- `infer.js`: ES module, no dependencies, no DOM; runs in the browser and Node.
- `cli.mjs`: Node runner for a sim run folder.
- `test.mjs`: one test per input of Rio's spec, Baker equivalence, calibration, real-run sanity
  (`node model/test.mjs`; results in [TESTS.md](TESTS.md)).
- `compare.mjs`: the same meetings through Rio's `exposure/flu_risk.py`, this port and `alt/`
  (`node model/compare.mjs`; results for Rio in [COMPARISON.md](COMPARISON.md)).
- `alt/`: an independent alternative model (two-zone dose, S/E/I/R), for comparison only.

```
node model/cli.mjs sim/runs/mock_boring10 [out.csv]
```

Prints P at the end of each day, change points for A0005 and A0007, `explain('A0005', Sat 22:00)`
and all flags, and writes `out.csv` (`agent_id,t_iso,p_sick`, change points only; default
`model/out/<run>/p_sick.csv`). It reads `map/rooms.csv` from the run for room size and ventilation.

## API

```js
import { inferRisk } from './infer.js';
const risk = inferRisk({ contacts, reports, rooms, agentIds, stepMin, startMs }, params);
```

Input (`contacts` and `reports` are rows of `contacts.csv` / `reports_tests.csv`, `t` in steps;
`stepMin` and `startMs = Date.parse(start)` come from `config.json`):

- `contacts`: `{ t, agent_a, agent_b, distance_m, distance_tier, duration_s, room_id, indoor }`. Without
  `distance_m` the tier's middle is used; without `indoor`, indoors; without the `room_id` column, Rio's
  default room. An indoor row with an empty `room_id` is a pair across a wall (see below).
- `rooms` (optional): `Map<room_id, { volume_m3, ventilation_ach, room_type }>`, rows of `map/rooms.csv`.
- `reports`: `{ t, agent_id, event, value, target_agent_id }`. Used: `self_report`
  (`might_be_sick`, `tested_positive`, `recovered`), `test_result` (`positive`/`negative`),
  `report_other` (`might_be_sick`). `test_taken` and the sim's `truthful` column are ignored.

Output:

- `pAt(agentId, tMs)`: P(currently infected). Piecewise constant; the prior for unknown agents.
- `changes`: `Map<agentId, [{ tMs, p }]>`, sorted. Only agents whose P ever moved by >= `minDelta`
  appear. This is what a shared file would hold.
- `explain(agentId, tMs, k = 5)`: `{ p, prior, evidence, contributions }`. `evidence` is the log of
  reports/tests about the person up to `tMs` (with `active`); `contributions` are the k contacts that
  raised their risk most: `{ tMs, other, distanceTier, durationMin, distanceM, indoor, roomVolume, roomAch,
  roomLoss, quanta, stage, dose, transmission, pairDose, wall, otherRisk, delta, retro, pieces }`
  (`transmission = 1 - exp(-dose)`; `pairDose` is the pair's total dose so far). Each has `learnedMs`, when the app could know it (later than `tMs` for look-back ones); `explain` only returns contributions with `learnedMs <= tMs`. Contacts with the same person less than 30 min apart are merged into one entry, look-back and live ones separately; each
  agent keeps its 64-128 largest.
- `flags`: `[{ agentId, tMs, kind, detail }]`, sorted by time.
- `params`: the resolved parameters.

## Method

Transmission is Rio's exposure model (`exposure/flu_risk.py`, after Baker et al., PNAS 2021: the
simple mean-field update with a Wells-Riley aerosol dose). Time-ordered single pass over contacts and
reports (evidence first within a step).

1. **Prior.** Everyone starts at `prior`, the campus baseline. It stays constant (new community cases
   replace recoveries), so Rio's `(1 - MU)^days` decay of an earlier infection is not applied to it.
2. **Source risk.** Evidence about j gives a source risk s_j:
   - self-report `might_be_sick`: `selfReport`; each distinct reporter: `reportOther`. Evidence
     combines as a noisy-or, so two reporters give 0.58.
   - positive test, or a `tested_positive` self-report: `posTest`, which overrides the rest.
   - negative test: j's own P is capped at `negTest`, and j is no source. Evidence newer than the test counts again.
   - `recovered` clears j's evidence and exposure, but only if at least `recoverDays` after the last sick report or positive; a sooner claim is flagged and takes effect only once that time has passed.
   - evidence expires after `evidenceDays`; negative tests after `negTestDays`.
3. **Dose (Rio).** For a contact of t hours at distance d:
   `dose = q·B·t·(1/q_near + 1/(V·loss))` indoors, `q·B·t/q_near` outdoors, with
   `q = quanta·stage`, `q_near = nearFieldQ·max(d, 0.3)²` (×`outdoorNearDilution` outdoors),
   V and ventilation (ach) from the contact's room in `map/rooms.csv`, `loss = ach + deposition +
   virus decay(indoor RH)`. `lambda = 1 - exp(-dose)`. Checked against `flu_risk.transmission_probability`
   to 1e-16 on sampled sim contacts.
4. **Stage.** j's onset is unknown to the app, so the earliest evidence about j that still counts
   (self-report, positive, or first report by someone else) stands in for symptom onset:
   stage day = floor((contact - evidence) / 1 day) -> `stageProfile` (0.3 the day before a report,
   0.05 two days before, 0 earlier). This replaces the old `contagiousBeforeH`/`earlyWeight`. A source
   without dated evidence (second-hand risk) gets the profile's mean over -2..7, 0.352.
5. **Update (Rio), per pair.** 5-minute rows are not independent chances: doses add up per pair (i, j),
   and j's s_j is applied once to the pair: i's share from j is `A = s_j · (1 - exp(-total dose))`, and
   x_i <- 1 - (1 - x_i)(1 - A')/(1 - A) as the dose grows. Within a day this is exactly Rio's
   `p_new = (1 - p)·P_other·lambda` with the pair-day's summed dose; across days the dose keeps adding
   instead of chaining daily chances, so contact with j alone never lifts i above s_j. No contact cap
   (the old `xMax` 0.3 is gone). P_i = `1 - (1 - prior)(1 - x_i)`, raised to at least the person's own
   evidence level (positive test: exactly `posTest`), lowered to the cap after a negative test.
6. **Look-back.** When evidence about j rises, j's contacts in the previous `lookbackDays` are
   replayed in time order with their stage (contacts before the onset estimate form the pair's `pre`
   dose; later ones were counted live), applying only the increase.
7. **Second-hand risk, damped.** A contact with j, who has no evidence but has x_j from a source,
   passes `alpha * min(x_j, alphaCap)` as source risk at the average stage. It reads x_j as it was
   **before** the step, goes into a separate channel (`xi`, capped at `xiMax`), and is never passed on
   again, so risk flows one step down the chain, never back up. Effect: 500-agent run mean P at the end
   0.056 with it, 0.049 without; 7,500-agent run median 0.31 vs 0.25.
8. **Recovery (Rio).** Each exposure's share follows Rio's `still_infected(days since that exposure)`
   (Erlang, mean `illnessMeanDays` 7, shape `illnessShape` 4) exactly: x is kept in 4 Erlang
   compartments per person, advanced lazily; look-back adds risk already aged by the time since the
   contact. Recovered probability simply leaves x; there is no separate recovered state (the per-pair
   rule above is what stops re-exposure to the same person from compounding). Change points for
   recovery and evidence expiry are written every `fillHours`.

Changes to Rio's model, from the model review: (a) per-pair dose summing (5); (b) `quietQuanta`
1.5 q/h instead of 10 in dorm rooms (`room_type` starting `dorm`), where people sleep, rest and study
rather than talk. At 10 q/h a roommate of a confirmed case reached 87-98% over one illness; quiet only
23:00-07:00 still gave ~60% in the 10-agent run (roommates are together 14-21 h a day); quiet in the
dorm room all day gives 26% and 17% for A0006's two roommates (household flu attack rates 10-20%);
(c) `wallFactor` 0: the sim lists pairs < 5 m apart across a wall with an empty `room_id`
(`docs/sim-output-format.md`); they share no air. Without this, neighbours in the next dorm room
reached 55%.

### Rio's inputs and where they come from

| Rio's input | in the model |
|---|---|
| my prior | i's current exposure x_i (with the community `prior` on top) |
| P of the other person | s_j: j's evidence level, or damped second-hand risk (never j's full P: that feedback loop sent every P to 1) |
| duration | `duration_s`, summed per pair |
| distance | `distance_m` (tier middle if missing) |
| room size | `volume_m3` and `ventilation_ach` of the contact's `room_id` in `map/rooms.csv`; default 50 m² × 2.7 m, ach 2 |
| indoors / outdoors | the contact's `indoor` column |
| stage of illness | days from j's earliest active evidence, or the illness average 0.352 |
| days since the meeting | the Erlang recovery between contact and now |
| humidity | `outdoorRH` 60% at `outdoorTempC` 10 °C (campus in January) -> 30% indoors -> virus decay 0.59/h |

Reference numbers (per pair-day at peak stage 1; at the average stage 0.352 in brackets): roommate,
dorm quad 102 m³, 16 h at 3.7 m, quiet: 0.068 (0.024), over a whole illness 0.22; classmate, 1 h at
5 m in a 300 m³ classroom (ach 4): 0.010 (0.004); passer-by, 5 min at 1.5 m: 0.001 outdoors, 0.007 in a
360 m³ lobby; close chat, 15 min at 1 m: 0.044.

### Flags (lie and inconsistency detection)

| kind | when |
|---|---|
| `unexpected_report` | `might_be_sick` self-report while the model's P was below `unexpectedBelow`. Either a false report or a case from outside the contact network. |
| `silent_high_risk` | P above `highP` for more than `highHours` from exposure alone, with no self-report or positive test. |
| `suspicious_recovery` | `recovered` self-report less than `recoverDays` after a `might_be_sick` or positive report. The claim is not believed until `recoverDays` have passed, so P keeps its evidence-based level until then. |
| `report_other_unsupported` | report about someone with no reporter -> target contact in the previous `unsupportedHours`. The report still counts, at `unsupportedWeight`. |

## Parameters (`DEFAULTS` in `infer.js`, override via the second argument)

| name | default | rationale |
|---|---|---|
| `prior` | 0.02 | community baseline |
| `selfReport` | 0.6 | symptom guess, often wrong |
| `reportOther` | 0.35 | second-hand, may be mistaken or malicious |
| `unsupportedWeight` | 0.5 | report with no supporting contact counts half |
| `posTest` | 0.97 | test sensitivity/specificity |
| `negTest` | 0.05 | false negatives exist |
| `evidenceDays` | 7 | length of a flu episode |
| `negTestDays` | 3 | a negative test vouches only briefly |
| `quantaPeak`, `breathingRate`, `nearFieldQ`, `outdoorNearDilution`, `deposition` | 10, 0.5, 30, 5, 0.3 | Rio's constants (`exposure/flu_risk.py`) |
| `defaultRoomM2`, `ceilingM`, `defaultAch` | 50, 2.7, 2 | Rio's default room, for contacts without a known room |
| `roomVolume` | `'map'` | `'fixed'`: the default room for every room (room sizes are sim-only, see "Room size"); the phone mirrors `'map'` |
| `outdoorRH`, `outdoorTempC`, `indoorTempC` | 60, 10, 21 | campus in January |
| `stageProfile` | 0.05, 0.3, 1, 0.9, 0.6, 0.35, 0.18, 0.08, 0.04, 0.02 | Rio's `STAGE_PROFILE`, days -2..7 |
| `illnessMeanDays`, `illnessShape` | 7, 4 | Rio's `still_infected` |
| `quietQuanta` | 1.5 | emission in a dorm room (ours, see above) |
| `wallFactor` | 0 | dose across a wall (ours) |
| `lookbackDays` | 3 | how far a report reaches back |
| `alpha`, `alphaCap`, `xiMax` | 0.25, 0.4, 0.08 | second-hand damping and ceiling |
| `fillHours` | 6 | recovery change-point spacing |
| `minDelta` | 0.01 | smaller changes are not written |
| `mergeGapMin`, `contribMin` | 30, 0.001 | `explain` aggregation |
| `recoverDays` | 3 | flu lasts 5-7 days, so a recovery claim sooner than this is doubted |
| `unexpectedBelow`, `highP`, `highHours`, `unsupportedHours` | 0.05, 0.5, 24, 48 | flag thresholds |

## Performance

Linear in contacts: about 0.2 s for the 500-agent run (866k contacts), about 30 s and 3.2 GB RSS for
the 7,500-agent run (28.6M contacts, typed-array loader as in `heatmap/tools/precompute.mjs`; the old
model took 16 s). Contact history is a pruned Int32 buffer per agent of [step, other, contact row];
look-back recomputes the dose from the row. Pair doses live in two Maps of exposed pairs.

## Limitations

- Rio's constants are literature-based but rough; `quietQuanta` and `wallFactor` are our judgement.
- Reports are trusted: the 7,500-agent run has 290 false `report_other`s, which lift the median P to 0.31.
- Look-back only starts from direct evidence. Second-hand risk is not re-applied to a person's earlier
  contacts, and nobody upstream of a sick person (their possible infector) is raised.
- Contacts are assumed to be detected symmetrically and honestly; mask use is unknown to the app.
- Room size and ventilation come from the map, which a real app would need too (the sim's procedural sizes; the
  mean field no longer uses room size, `roomVolume: 'fixed'` does the same here).
- `explain` keeps only each person's largest contributions, and `changes` ends at the last data time.
- Reports are trusted unless flagged; a coordinated false-report campaign is not modelled.
- Change points are written only when P moves by `minDelta` (0.01), so a very weak exposure may not
  show in `pAt`. Recovery is written only up to the last data time.
- Second-hand sources use the illness-average stage, not the time since they were exposed.
- The prior is one global value, held constant (Rio's script lets it decay).

## Mean-field model (`meanfield.js`): Baker et al. PNAS 2021

A second estimate from the same inputs, by the method of Baker et al.,
["Epidemic mitigation by statistical inference from contact tracing data"](https://www.pnas.org/doi/full/10.1073/pnas.2106548118)
(PNAS 118, 2021): the paper's mean-field update `P_S^i(t+1) = P_S^i(t) · Π_j (1 − λ_{j→i}(t) · P_I^j(t))`,
hour by hour, with every agent carrying a distribution over infection age. It is a port of
`exposure/network/mean_field.py` (Rio's), and has feedback: everyone's P feeds everyone else's, not only evidence.
λ_{j→i} depends on:

| Input | How it enters |
|---|---|
| P(j has flu) | transmission = Σ over j's infection ages a of P_j(a) · (1 − exp(−q · stage(a) · D)) |
| P(i has flu) | only i's healthy mass P_S^i can be infected |
| Duration, distance | near-field plume f·B·h / Q(d), Q = 600·d m³/h below 1 m, 600·d² beyond (two-zone near field); adds up over the meeting's 5-min rows |
| Shared room air, ventilation | room air, not a pair term: each room is a well-mixed box dC/dt = Σ shed/V − (ACH + deposition + virus decay)·C, filled by everyone the contacts put in the room that hour and carried over between hours; V = occupants × `perPersonM3` (40 m³), **not the room's size** (see "Room size" below); ACH from `map/rooms.csv` (one value per building type) |
| Room type | f = typical activity there (emission × breathing, `data/room-activity.js`): dorm 0.7, party 2.7, gym 5.4, class 1, … |
| Indoors / outdoors | outdoors: no room term, plume diluted 5×; through a wall: no shared air |
| Stage of flu | `stageProfile` around symptom onset, 2.5 days after infection |
| Time since the meeting | infections age one bin per hour: latent → infectious → over (R) after 10 days |
| Outdoor humidity | that day's weather in `config.json` → indoor RH → virus decay (Noti et al. 2013) |

Reports constrain the marginals as in the paper's SI and reach back in time, so the model reruns from the
earliest hour a report touches:

- positive test: P_I = 1, dated 3 days before the result (the paper's τ);
- symptom report (or one about someone else): P_I set to the Bayesian posterior w = LR·p / (LR·p + 1 − p)
  from the model's current P_I = p, dated 2.5 days back; not stacked on the old infected mass;
- negative test (SI eq. 4): P_S = 1 at every hour from 3 days before the result up to it, which also removes
  what the person was assumed to pass on in that window (the paper: all t ≤ t_obs; the online pass reruns 3 days);
  a later positive overrides it;
- recovered (SI eq. 6): P_R = 1, no longer susceptible;
- one illness, one dating: within 10 days, a repeated report of the same kind, or any report after a positive,
  adds nothing (they describe the same infection, not independent evidence).

On the sim these strict rules cost some ranking in week 2 (day-14 AUC 0.75 → 0.71 on 25fe957a): every negative
test in that run was a false negative (the sim's test has 70% sensitivity), and 5 of 26 "recovered" claims came
from people still infected. The soft negative (infected mass × 0.3 at the result) scores 0.74. The day-14 Σ P
moved from 175 to 156 (136 infected in the last 10 days, the scorer's label). It also returns each agent's expected
infectiousness `shed = Σ_a P(a) · stage(a)`, which the heat map's "Chance of catching flu here" view draws.

```
node model/meanfield-test.mjs                          # each λ input moves the risk the right way
node model/meanfield-cli.mjs sim/runs/<run> [--calibrate]   # scores vs sim truth; writes model/out/<run>/meanfield.csv
```

`lambdaScale` (0.901) is fitted by `--calibrate` on `influenza_none_n1000_d14_s42_25fe957a`: started from the
sim's true seeds, the model's expected on-campus infections match the sim's 167. On that run the top 50
by P hold 35–43 truly infected people from day 7 on (random 50: 6–8), AUC 0.62–0.73, ~20 s in Node.
`--set key=value` overrides any parameter (`--set legacyDose=true --scale 0.135` is the dose before the audit below).

### Room size (October 2026): not an input

Which sizes enter λ_{j→i}: before this change, the shared-air term used each contact room's `volume_m3` from
`map/rooms.csv` (the default 50 m² × 2.7 m room when a room was unknown); building footprint × floors only
shades buildings on the heat map and never entered either model. Now no room or building size enters the
mean field by default (`roomVolume: 'occupancy'`):

- A phone knows at best which building it is in (`proximity/Core/RoomContext.swift`: GPS, never the room;
  for `infer.js`'s room term it already uses one representative room per building, `building_rooms.csv`).
- The `rooms.csv` volumes are not measurements: `sim/campussim/campus.py` builds them from building footprints
  and per-type room programs (`sim/configs/map.json`: capacity × m²/person, dorm double 18 m², ceiling by type).
  `room_id` in `contacts.csv` is the sim's ground truth too; Stanford publishes no room sizes (audit below).
- The sim's aerosol route (`sim/campussim/disease.py` `_aerosol`, 56–64% of its infections) uses exactly these
  volumes, so the room-volume term scores well on sim runs by construction, not because it would in reality.

Replacement: each room's air is sized by the people the contacts put in it that hour,
V = max(1, occupants) × `perPersonM3`. Rooms are built for their occupancy, so this keeps the useful part
(one sick person among 2 roommates exposes more than one among 30 classmates) without knowing any size.
Still from `rooms.csv`: ACH (one documented value per building type) and room type (activity f); and the room
grouping itself relies on the contact's `room_id` (a phone would need to infer "same room", e.g. from BLE).
`roomVolume: 'map'` restores the sim's volumes, `'fixed'` uses the default room everywhere, `'none'` drops the
room term. `infer.js` (the phone's mirror) keeps its room volumes by default; `roomVolume: 'fixed'` there
opts out.

Mean AUC days 3–14 / mean sick in top 50 / dose-only AUC (true seeds, no reports, scored per day like the CLI, so
not the audit table's dose-only number), `lambdaScale` refit per run
and variant:

| variant | 25fe957a | 183f262b | f12e71fa | mean AUC |
|---|---|---|---|---|
| `map` (rooms.csv volume; old default, λ 0.837) | 0.659 / 35.3 / 0.759 | 0.732 / 43.2 / 0.760 | 0.711 / 29.9 / 0.797 | 0.701 |
| **`occupancy`, 40 m³/person** (new default, λ 0.901) | 0.661 / 35.8 / 0.756 | 0.721 / 43.3 / 0.742 | 0.700 / 29.8 / 0.773 | 0.694 |
| `occupancy`, 10 / 20 / 60 / 100 m³ | 0.663 / 0.662 / 0.660 / 0.657 | 0.716 / 0.718 / 0.722 / 0.722 | 0.691 / 0.695 / 0.702 / 0.703 | 0.690–0.695 |
| `fixed` (default room 135 m³) | 0.638 / 32.3 / 0.733 | 0.710 / 41.6 / 0.733 | 0.680 / 28.2 / 0.767 | 0.676 |
| median volume per room type | 0.662 / 35.4 / 0.764 | 0.726 / 43.1 / 0.754 | 0.698 / 29.4 / 0.777 | 0.695 |
| `none` (no room term) | 0.628 / 33.3 / 0.725 | 0.705 / 42.1 / 0.725 | 0.689 / 26.4 / 0.749 | 0.674 |

Occupancy-sized air costs 0.007 mean AUC against the sim's own volumes (an upper bound a real deployment
could not reach) and keeps top-50 the same; one fixed room or no room term costs 0.025–0.027.

### Accuracy audit (October 2026)

What the dose got wrong, measured on run 25fe957a (5.35 M contact rows, 167 on-campus infections):

- **Room sizes were not the problem.** Every same-room contact row has a room in `map/rooms.csv` (0.00% fall back to
  the default room); 4.5% are through-wall pairs, 4.9% outdoors. The sim infects with the same volumes and ACH, so
  they are right for scoring. Against the real campus they are procedural: bedrooms 9 m² per bed (a double 18 m²,
  ~190 ft², plausible), dorm buildings 22–30 m² gross per bed vs 30 m² at Manzanita (40,000 ft², 125 students) and
  Lagunita Court (2 × 33,000 ft², 200) ([McCarthy](https://www.mccarthy.com/projects/stanford-university)); sim bed
  counts are ~2× the real halls (Branner 384 vs 167, [Wikipedia](https://en.wikipedia.org/wiki/Stanford_University_student_housing)).
  Stanford publishes no room-level sizes or ventilation that I could find (R&DE pages show floor plans as images only,
  no EH&S/LBRE ACH data), so ACH stays one documented value per room type (dorm 2, classroom 4, lab 6, … in
  `sim/configs/map.json`), not made-up per-room values.
- **Near field outweighed room air ~10–40×** (biggest error). The old plume 1/(30·d²) made a 0.5 m contact 20× a dorm
  room's air: first 6 days, true seeds, the model put 3 expected infections in dorm rooms (truth 25) and 9.7 outdoors
  (truth 1). Now Q(1 m) = 600 m³/h (two-zone near field, Nicas 1996; face-to-face jet would be 68,
  [Jia et al. 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC9085449/)): dorm 21.9, outdoor 0.8. Party rooms are still
  low (3.6 vs 10).
- **Big rooms.** Rooms with capacity > 150 log only pairs < 5 m; 9 of 167 infections (7 at parties) had no logged
  contact with their infector. Room air now comes from occupancy, so far-apart occupants and later arrivals share it.
- **Activity.** Dorm rooms used quiet quanta 0.15× everywhere; now f per room type from the sim's activity tables
  ([EPA EFH ch. 6](https://www.epa.gov/expobox/exposure-factors-handbook-chapter-6) breathing,
  [Buonanno et al. 2020](https://doi.org/10.1016/j.envint.2020.105794) emission), dorm 0.7.
- Not fixed: the 2% prior < the runs' 5% seeding (Σ P lags truth on days 1–5); the mean field's echo (calibrated
  on 14 days it under-predicts the first generation, over-predicts by day 14: Σ P 175 vs 136); `stageProfile` runs to
  day 7 after onset where the sim's viral load is ~0 after day 4; masks (unknown to a phone); `illnessDays` 10 vs the
  sim's ~7.5-day illness.

| Run (lambdaScale refit per run) | mean AUC, days 3–14, old → new | dose-only AUC (true seeds, no reports) |
|---|---|---|
| 25fe957a (calibration) | 0.619 → 0.664 | 0.570 → 0.690 |
| 183f262b (validation, 395 infected) | 0.690 → 0.726 | 0.622 → 0.693 |
| f12e71fa (validation) | 0.664 → 0.712 | 0.619 → 0.758 |

Sweep on 25fe957a (dose-only AUC): Q(1 m) = 68 / 200 / 600 / 2000 m³/h (∝ d, dorm f 0.36) gave 0.654 / 0.668 /
0.678 / 0.684 — 2000 is past the physical estimate (~570) for little gain, so 600; at 600 (∝ d), dorm f 0.36 / 0.7 / 1
gave 0.678 / 0.687 / 0.691, and ∝ d² beyond 1 m with f 0.7 (the default) 0.690.
The heat map runs it in the page for small runs and reads `meanfield.csv` for big ones. `?model=meanfield`
colours people by it; otherwise `infer.js` stays the app's estimate. No `explain()` yet.

## Use in the heat map

`heatmap/app.js` calls `inferRisk` in the browser (contacts, reports and `map/rooms.csv` of the run)
and reads `risk.pAt(agentId, tMs)`. The heat
is Σ P(sick) of the people near each point. The phone panel's own estimate uses `doseModel()` with
FlUni's on-device rule, matched by `proximity/Tests/Fixtures/xcheck/golden.json`.
