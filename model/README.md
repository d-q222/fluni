# model: infection probability

Estimates P(person is infected right now) for every agent, using only what a real app could know:
phone-detected contacts, self-reports, reports about others and test results. It never reads
`disease_state`, `infectiousness` or any other ground truth. Implements PRD Functionality 3.

- `infer.js`: ES module, no dependencies, no DOM; runs in the browser and Node.
- `cli.mjs`: Node runner for a sim run folder.

```
node model/cli.mjs sim/runs/mock_boring10 [out.csv]
```

Prints P at the end of each day, change points for A0002 and A0003, `explain('A0002', Wed 22:00)`
and all flags, and writes `out.csv` (`agent_id,t_iso,p_sick`, change points only; default
`<tmpdir>/p_sick.csv`).

## API

```js
import { inferRisk } from './infer.js';
const risk = inferRisk({ contacts, reports, agentIds, stepMin, startMs }, params);
```

Input (`contacts` and `reports` are rows of `contacts.csv` / `reports_tests.csv`, `t` in steps;
`stepMin` and `startMs = Date.parse(start)` come from `config.json`):

- `contacts`: `{ t, agent_a, agent_b, distance_m, distance_tier, duration_s }`
- `reports`: `{ t, agent_id, event, value, target_agent_id }`. Used: `self_report`
  (`might_be_sick`, `tested_positive`, `recovered`), `test_result` (`positive`/`negative`),
  `report_other` (`might_be_sick`). `test_taken` and the sim's `truthful` column are ignored.

Output:

- `pAt(agentId, tMs)`: P(currently infected). Piecewise constant; the prior for unknown agents.
- `changes`: `Map<agentId, [{ tMs, p }]>`, sorted. Only agents whose P ever moved by >= `minDelta`
  appear. This is what a shared file would hold.
- `explain(agentId, tMs, k = 5)`: `{ p, prior, evidence, contributions }`. `evidence` is the log of
  reports/tests about the person up to `tMs` (with `active`); `contributions` are the k contacts that
  raised their risk most: `{ tMs, other, distanceTier, durationMin, transmission, otherRisk, delta,
  retro }`. Each has `learnedMs`, when the app could know it (later than `tMs` for look-back ones); `explain` only returns contributions with `learnedMs <= tMs`. Contacts with the same person less than 30 min apart are merged into one entry, look-back and live ones separately; each
  agent keeps its 64-128 largest.
- `flags`: `[{ agentId, tMs, kind, detail }]`, sorted by time.
- `params`: the resolved parameters.

## Method

Time-ordered single pass over contacts and reports (evidence first within a step).

1. **Prior.** Everyone starts at `prior`.
2. **Source risk.** Evidence about j gives a source risk s_j:
   - self-report `might_be_sick`: `selfReport`; each distinct reporter: `reportOther`. Evidence
     combines as a noisy-or, so two reporters give 0.58.
   - positive test, or a `tested_positive` self-report: `posTest`, which overrides the rest.
   - negative test: j's own P is capped at `negTest`, and j is no source. Evidence newer than the test counts again.
   - `recovered` clears j's evidence and exposure, but only if at least `recoverDays` after the last sick report or positive; a sooner claim is flagged and takes effect only once that time has passed.
   - evidence expires after `evidenceDays`; negative tests after `negTestDays`.
3. **Exposure.** A contact with minutes m at tier k has transmission
   `pi = 1 - exp(-beta * w_k * m)`. Receiver risk x_i becomes `1 - (1 - x_i)(1 - s_j * pi)`, capped
   at `xMax`. P_i = `1 - (1 - prior)(1 - x_i)`, raised to at least the person's own evidence level
   (positive test: exactly `posTest`), lowered to the cap after a negative test.
4. **Look-back.** When evidence about j rises, j's contacts in the previous `lookbackDays` are
   applied retroactively (only the increase, so repeated reports do not double count). Contacts
   older than `contagiousBeforeH` before the report count at `earlyWeight`, since j was probably not
   yet contagious.
5. **Second-hand risk, damped.** A contact with j, who has no evidence but has x_j from a source,
   passes `alpha * min(x_j, alphaCap)` as source risk. It reads x_j as it was **before** the step, goes into a
   separate channel (`xi`, capped at `xiMax`), and is never passed on again.
   This is the upstream/downstream rule: risk starts at evidence and flows one step down the chain,
   never back up, so two people in constant contact cannot raise each other (the earlier version did, and
   every P climbed to 1).
6. **Decay.** Exposure risk holds for `decayAfterDays` after the last new exposure, then halves every
   `halfLifeDays`. Change points for decay and expiry are written every `fillHours`.

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
| `beta` | 0.015 | 15 min under 1 m -> 20%; 15 min at 1-2 m -> 13% (at s = 1) |
| `tierWeight` | 1, 0.6, 0.1, 0.02 | <1 m, 1-2 m, 2-5 m, same room >= 5 m |
| `lookbackDays` | 3 | how far a report reaches back |
| `contagiousBeforeH`, `earlyWeight` | 24, 0.15 | contagious about a day before symptoms |
| `alpha`, `alphaCap` | 0.25, 0.4 | second-hand damping |
| `xMax`, `xiMax` | 0.3, 0.08 | per-person ceiling from contact alone (household flu attack rates are 10-40%) |
| `decayAfterDays`, `halfLifeDays` | 2, 3 | incubation window, then fade |
| `fillHours` | 6 | decay change-point spacing |
| `minDelta` | 0.01 | smaller changes are not written |
| `mergeGapMin`, `contribMin` | 30, 0.001 | `explain` aggregation |
| `recoverDays` | 3 | flu lasts 5-7 days, so a recovery claim sooner than this is doubted |
| `unexpectedBelow`, `highP`, `highHours`, `unsupportedHours` | 0.05, 0.5, 24, 48 | flag thresholds |

## Performance

Linear in contacts: about 2.5 s for 10M synthetic contacts (7,000 agents x 14 days) in Node, about 1.5 GB
RSS, most of it the input objects. Contact history is a pruned Int32 buffer per agent.

## Limitations

- Heuristic constants, not fitted. The contact-level calibration is a single anchor (15 min within 2 m).
- Look-back only starts from direct evidence. Second-hand risk is not re-applied to a person's earlier
  contacts, and nobody upstream of a sick person (their possible infector) is raised.
- Contacts are assumed to be detected symmetrically and honestly; mask use and ventilation are unknown to the app.
- Saturation: with long close contact everything reaches `xMax`, so dense groups (the 10-person mock) all
  land at similar P. P is only as discriminating as the contact data.
- `explain` keeps only each person's largest contributions, and `changes` ends at the last data time.
- Reports are trusted unless flagged; a coordinated false-report campaign is not modelled.

## Use in the heat map

`heatmap/app.js` has a placeholder `appBelief(reported, test)` that looks only at a person's own report
and test. Replace it with `risk.pAt(agentId, tMs)` (or load `changes` / the `p_sick` CSV, which the
loader already accepts as a `p_sick` column). `aggregate.js` then sums P per building and room as it
does now; nothing else changes.
