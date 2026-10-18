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
- Room size and ventilation come from the map, which a real app would need too.
- `explain` keeps only each person's largest contributions, and `changes` ends at the last data time.
- Reports are trusted unless flagged; a coordinated false-report campaign is not modelled.
- Change points are written only when P moves by `minDelta` (0.01), so a very weak exposure may not
  show in `pAt`. Recovery is written only up to the last data time.
- Second-hand sources use the illness-average stage, not the time since they were exposed.
- The prior is one global value, held constant (Rio's script lets it decay).

## Use in the heat map

`heatmap/app.js` calls `inferRisk` in the browser (contacts, reports and `map/rooms.csv` of the run)
and reads `risk.pAt(agentId, tMs)`; big runs load the precomputed `model/out/<run>/p_sick.csv`. The heat
is Σ P(sick) of the people near each point. The phone panel's own estimate uses `doseModel()` with
FlUni's on-device rule, matched by `proximity/Tests/Fixtures/xcheck/golden.json`.
