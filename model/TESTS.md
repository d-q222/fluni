# Model tests

See also [COMPARISON.md](COMPARISON.md) for the side-by-side of Rio's script, `infer.js` and `model/alt`.

## How to run

```bash
node model/compare.mjs     # the three implementations side by side
node model/test.mjs        # plain node, no dependencies, exits non-zero on failure
node model/alt/test.mjs    # the separate alt model's own tests (not part of this file)
```

`model/test.mjs` builds tiny synthetic scenarios for `inferRisk` (source J with a positive test or
self-report, one contact with I) and checks that each variable of the spec (Baker et al., PNAS 2021)
moves P(I) the right way. The two real-run checks read `sim/runs/...` and are skipped if the run
folders are missing. Last run: 13 passed, 0 failed.

## The nine spec variables

All formulas are in `model/infer.js`. "Result" is what `model/test.mjs` showed.

| # | Variable | Where it enters | Result |
|---|---|---|---|
| 1 | P(j has flu) | `onReport` sets j's source risk s (selfReport 0.6, reportOther 0.35, posTest 0.97); `expose` applies `s * (1 - e^-pairDose)` | Higher s gives higher P(i): self 0.3 / self 0.6 / positive test = 0.0344 / 0.0488 / 0.0666 |
| 2 | P(i) prior | `pOf`: `p = 1 - (1 - prior)(1 - x)`; `expose` multiplies by `(1 - x_i)` | Prior 0.02 gives +0.0466, prior 0.5 gives +0.0238; increase / (1 - prior) is identical (0.0476 = s*lambda) |
| 3 | Duration | `doseModel` `unitDose`: dose is linear in `duration_s` | Dose doubles with duration; 30 min > 5 min end to end |
| 4 | Distance | `unitDose`: `qNear = 30 * max(d, 0.3)^2` | Dose falls with distance (0.5, 1, 2, 5 m); 0.5 m > 3 m end to end |
| 5 | Room size | `doseModel` `mkRoom`: far-field term `1 / (volume * loss)` | 2000 m3 room < 50 m3 room, dose and end to end |
| 6 | Indoor / outdoor | `unitDose`: outdoors drops the far-field term and multiplies qNear by 5 | Outdoor < indoor, dose and end to end |
| 7 | Stage of j | `stageFactor` / `stageAt` from j's estimated onset (earliest evidence); `lookBack` re-scores earlier contacts | Day 0 = 0.9131, day 6 = 0.1209, outside window (3.5 d before the report) = 0.0200 (the prior, no effect) |
| 8 | Time since meeting | `addRisk` / `totAt`: Erlang compartments, mean 7 d, shape 4 | P(i) at +0 / 5 / 7 / 7.9 d = 0.0666 / 0.0560 / 0.0457 / 0.0457 |
| 9 | Outdoor humidity | `indoorRH` (Magnus) then `virusDecay` (Noti 2013), added to the room loss | Outdoor RH 30% (indoor 14.8%) gives more dose than 90% (indoor 44.5%), but only 0.04191 vs 0.04183 for a 1 m chat, since the near field dominates. No effect outdoors (no far field) |

## Baker mean-field equivalence

Two independent sources J and K, one contact each with I, both positive tests, contacts after the test
at stage day 0. Prior handling in `infer.js` is `p = 1 - (1 - prior)(1 - x)` with
`x = 1 - (1 - s*lam_j)(1 - s*lam_k)`, so the result is exactly the Baker form:

```
lambda_j=0.04906 lambda_k=0.09571 expected=0.15328593 got=0.15328593
```

Match to 1e-6. This holds for evidence-based sources. Pairs are combined by summing dose per pair
(one lambda per pair, then `s` applied once), not row by row.

## Calibration

15-minute chat at 1 m, indoors, default 50 m2 room, ACH 2, peak stage:

```
lambda=0.04387 (dose 0.04486); indoor RH=29.65% (outdoor 60% at 10 C), virus decay=0.5951 /h
```

This is inside the 0.02-0.10 target. Note that a contact row with `room_id` equal to the empty string
is treated as "across a wall" and gets dose 0 (`wallFactor`); an undefined `room_id` uses the default room.

## Real runs

Model run directly from the sim run folders (end of run = last simulated second; peak = maximum over
the run's change points):

```
influenza_none_n10_d14_s2_bc5cae7a   10 agents, 30193 contacts, 8 reports
  end of run:  mean P=0.0912  max P=0.3500  agents > 0.1: 2
  peak in run: mean P=0.1840  max P=0.9700  agents > 0.1: 3
  confirmed case A0006 (peak 0.970); roommates (same room): A0005 peak 0.244, A0007 peak 0.350
  sim ground truth: A0006 and A0009 imported at t0; A0005 infected by A0006 at t520

influenza_none_n500_d2_s42_aea9db72  500 agents, 865917 contacts, 6 reports
  end of run:  mean P=0.0561  max P=0.3500  agents > 0.1: 39
  peak in run: mean P=0.0561  max P=0.3500  agents > 0.1: 39
```

The roommate peaks (24% and 35%) match the earlier review's 17-26% only roughly; A0007's 35% is the
second-hand cap/report-other level rather than a dose-driven value, which I did not trace. The sim
infected A0005 but not A0007 by the end, so both are plausible. The tests print these numbers and only
fail on NaN or P outside [0, 1].

## Rio's model vs `model/alt`

Summarised from `model/alt/README.md` (the alt model was written without reading `infer.js` and
`exposure/`). Both use lambda = 1 - e^-dose, and both agree on direction and ordering in all ten test
scenarios. The difference is magnitude:

- Overall scale: Rio's peak emission is 10 quanta/h, alt uses 1.5 (talking) calibrated to household
  attack rates; alt's lambda is roughly 0.17x Rio's on ordinary conversations (alt 0.0073 vs Rio 0.0446
  for a 15 min chat at 1 m).
- Long close exposures: Rio's near field `30*d^2` has no cutoff, so an 8 h night with a roommate at
  1.5 m gives lambda 0.61 (alt 0.016). Over a week a roommate reaches about 49% in Rio's original form
  versus about 3-7% for night-only exposure in alt (alt's full-household calibration is 20.7%).
- Distance cutoff and room transient: Rio's 1 h lecture at 5 m is 0.0085, alt's is 2.8e-5.
- State: Rio's P is a scalar with an Erlang recovery and no latent or recovered state; alt keeps S/E/I/R.
- alt recommends itself for the heat map; its README states that neither model is fitted to data.

`infer.js` has since changed from Rio's original: quiet dorm emission (1.5 quanta/h), one lambda per
pair instead of row by row, a damped one-hop second-hand risk, and a wall factor. So the roommate
figures above (24-35% peak) are lower than the 49% shown in alt's comparison against the original.

## Known gaps

- Second-hand sources (no evidence of their own) use the illness-average stage (`stageMean`, about
  0.36), not the time since they were exposed, and their risk is damped (alpha 0.25), capped, and not
  passed on again.
- Prior is a single global parameter (`DEFAULTS.prior`), not a per-person P(i) input; a different
  per-person prior is only possible by changing the parameter.
- `pAt` is a step function: a change is stored only if P moved by at least `minDelta` (0.01). Weak
  exposures (late stage, small dose, a second small source in the same step) can be missing from
  `pAt` entirely, and recovery shows up in steps of about 0.01.
- Recovery points are written only up to the end time of the run (the last contact or report). A
  query long after the last event returns the last stored value; the test adds a later report to avoid this.
- Evidence expires after 7 days (`evidenceDays`), and contacts earlier than 2 days before the report
  get stage 0, so late look-back exposures are ignored.
- Humidity changes dose by well under 1% for a close indoor chat; it matters only for far-field
  dominated exposures (long, distant, indoors), and not at all outdoors.
- A positive test sets P to 0.97 for 7 days regardless of what the contacts predicted.

## Calibration against the sim's truth

`python3 model/calibrate.py sim/runs/<run>` compares, at noon and 23:00 each day:
- how many agents the sim says are infected (E or I);
- how many the model expects (Σ P);
- the mean P of each group;
- AUC, where 0.5 means no better than chance.

**Busy run** (`influenza_none_n400_d3_s5_1513ab3f`, the config requested from the sim; generated
locally, not yet committed):

| moment | infected | expected | P(infected) | P(susceptible) | AUC |
|---|---|---|---|---|---|
| Mon 12:00 | 25 | 9.1 | 0.022 | 0.023 | 0.51 |
| Mon 23:00 | 29 | 13.3 | 0.028 | 0.034 | 0.52 |
| Tue 12:00 | 36 | 16.7 | 0.048 | 0.041 | 0.52 |
| Tue 23:00 | 48 | 28.4 | 0.096 | 0.068 | 0.60 |
| Wed 12:00 | 66 | 44.7 | 0.169 | 0.100 | 0.64 |
| Wed 23:00 | 77 | 76.4 | 0.278 | 0.170 | 0.63 |

- **The totals start low and catch up.** The 25 seed cases are invisible to an app until someone
  reports, so day 1 sits at the 2% prior. By Wednesday night the expected count matches the truth
  (76 vs 77).
- **Total heat is about right; telling people apart is modest.** AUC rises from 0.5 to about 0.63 as
  reports arrive. Most infected people are incubating or presymptomatic and have no signal yet.
- **At 17% prevalence, most people are above 10%.** That is the "Elevated" tier, and it is correct,
  not inflation.

**Quiet run** (`influenza_none_n500_d2_s42_aea9db72`):
- 0–1 people are truly infected, but the model expects 28 by the end of day 2.
- All 6 reports in it are false `report_other`s.
- Each one sets its target to 0.35 and looks back over the target's contacts, adding about 3 expected
  infections per false report.

**10-agent default** (`influenza_none_n10_d14_s2_bc5cae7a`): 2–3 infected while the model still
expects 0.2, because nobody has reported yet.

**What follows:**
- Total heat (Σ P) is trustworthy once reports flow.
- It underestimates a silent outbreak and overestimates when reports are false.
- Down-weighting `report_other` with no corroboration is the lever for the second problem, and is
  Rio's and the product owner's call.

## Trust in `report_other` (`model/sweep.mjs`)

These numbers are true infected / model expected at each moment. `reportOther` is the source risk given
to someone another person reported; the default is 0.35.

| run | reportOther | Mon 12 | Mon 23 | Tue 12 | Tue 23 | Wed 12 | Wed 23 |
|---|---|---|---|---|---|---|---|
| busy n400 (old sim code) | 0.35 | 25/9 | 29/13 | 36/17 | 48/28 | 66/45 | 77/76 |
| | 0.15 | 25/8 | 29/9 | 36/11 | 48/16 | 66/28 | 77/52 |
| | 0.05 | 25/8 | 29/8 | 36/8 | 48/9 | 66/18 | 77/35 |
| quiet n500 | 0.35 | 0/10 | 0/10 | 0/17 | 1/28 | | |
| | 0.15 | 0/10 | 0/10 | 0/12 | 1/16 | | |
| | 0.05 | 0/10 | 0/10 | 0/10 | 1/11 | | |

- **A uniform discount trades one error for another.** It removes the false heat from the quiet run
  (all 6 of its reports are false), but undercounts the busy run, where 15 of 21 reports are true.
- **The better lever is corroboration.** Full weight would apply only when something backs the report
  up: a second independent reporter, the target's own report, or a test.

## Full-size and new-sim-code runs

| run | sim code | reports (true / false) | true infected (end) | model expected (end) |
|---|---|---|---|---|
| `influenza_none_n7000_d2_s42_5423d1a4` (committed) | before 3a758ad | 1 / 307 (303 false `report_other`) | 6 | 2,436 |
| `influenza_none_n7000_d2_s42_08f28644` (local) | after 3a758ad | 0 / 14 | 7 | 283 |
| `influenza_none_n7000_d3_s5_24263596` (local, 100 seeds) | after | 24 / 19 | 181 | 426 |
| `influenza_none_n400_d3_s5_60464ee3` (local, busy config) | after | 10 / 3 | 54 | 20 |

**Committed run.** For `5423d1a4`, `model/out/<run>/p_sick.csv` and
`heatmap/out/<run>/{building_heat.csv,totals.json.gz}` are committed for inspection. They are not the
demo run: the heat there is false reports.

**What the newer runs show:**
- **Few reports leave the model at its prior.** The heat is then about 2% of the crowd, which is a
  crowd map: 140 expected at 7,000 agents with nothing known.
- **Many reports in big lecture halls make it overshoot.** On the seeded run it reaches 2.3× the
  truth by day 3, with AUC about 0.6. Each report raises dozens of classmates a little.
- **Our λ may be stronger than the sim's per-contact transmission.** The sim is now calibrated to
  campus R ≈ 1.6 (f6bd268). A single dose scale fitted to that would align them.
- **The same scale must change everywhere at once:** `exposure/flu_risk.py`, `model/infer.js`, the
  FlUni phone, and the sim's Python port `campussim/psick.py`.
