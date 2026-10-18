# Comparison of the three implementations (for Rio)

The same scenarios run through (1) your original `exposure/flu_risk.py`, (2) our port in
`model/infer.js` (what the app and heat map use) and (3) the independent `model/alt/` model.
Re-run with `node model/compare.mjs` (needs python3 for your script). Nothing here was fitted.

Inputs: prior 0.02, P_j 0.97, 15 min, 1 m, 30 m2 room, 2 ACH, stage day 0 (peak), outdoor 60% RH at
10 C, unless the row says otherwise. "lambda" is the transmission probability if j is infected;
"P" is the updated probability for i at the scenario's days-since-meeting (0 unless stated).
Stage is given as a day number so all three profiles are read the same way.

## Output of `node model/compare.mjs`

| scenario | Rio lambda | Rio P | ours lambda | ours P | alt lambda | alt P | note |
|---|---|---|---|---|---|---|---|
| base: 15 min, 1 m, 30 m2, peak, P_j 0.97 | 0.0459 | 0.0636 | 0.0459 | 0.0636 | 0.0074 | 0.0270 |  |
| 2 m instead of 1 m | 0.0156 | 0.0349 | 0.0156 | 0.0349 | 0.0014 | 0.0213 |  |
| 60 min instead of 15 | 0.1714 | 0.1829 | 0.1714 | 0.1829 | 0.0307 | 0.0487 |  |
| outdoors | 0.0083 | 0.0279 | 0.0083 | 0.0279 | 0.0018 | 0.0217 |  |
| lecture hall 300 m2, 75 min, 3 m | 0.0255 | 0.0442 | 0.0255 | 0.0442 | 2.93e-4 | 0.0203 |  |
| dorm roommate 8 h, 2 m, 15 m2 | 0.4906 | 0.4863 | 0.4906 | 0.4863 | 0.0835 | 0.0962 | ours has no talking input; its dorm rule (1.5 quanta/h) applies only via room_type, see row below |
| late stage (day 5) | 0.0038 | 0.0236 | 0.0038 | 0.0236 | 0.0011 | 0.0210 |  |
| P_j 0.35 | 0.0459 | 0.0357 | 0.0459 | 0.0357 | 0.0074 | 0.0225 |  |
| prior 0.3 | 0.0459 | 0.3312 | 0.0459 | 0.3312 | 0.0074 | 0.3050 |  |
| 3 days after the meeting | 0.0459 | 0.0521 | 0.0459 | 0.0595 | 0.0074 | 0.0158 | alt also has an R (recovered) state; Rio and ours do not |
| 7 days after the meeting | 0.0459 | 0.0257 | 0.0459 | 0.0389 | 0.0074 | 0.0052 |  |
| outdoor RH 20% | 0.0465 | 0.0642 | 0.0465 | 0.0642 | 0.0080 | 0.0275 |  |
| outdoor RH 80% | 0.0450 | 0.0628 | 0.0450 | 0.0628 | 0.0071 | 0.0267 |  |
| dorm roommate 8 h, 2 m, 15 m2, ours with room_type=dorm | - | - | 0.0962 | 0.1115 | - | - | ours only: quiet emission 1.5 quanta/h; Rio and alt have no equivalent input |

Sensitivity: ratio to the base scenario. lambda x = lambda / lambda_base; dP x = (P - prior) / (P_base - prior). dP is n/a for the days rows because the methods treat the prior differently over time (Rio decays it, ours holds it, alt moves it into R)

| scenario | Rio lambda x | ours lambda x | alt lambda x | Rio dP x | ours dP x | alt dP x |
|---|---|---|---|---|---|---|
| 2 m instead of 1 m | 0.34 | 0.34 | 0.18 | 0.34 | 0.34 | 0.18 |
| 60 min instead of 15 | 3.73 | 3.73 | 4.16 | 3.74 | 3.73 | 4.12 |
| outdoors | 0.18 | 0.18 | 0.24 | 0.18 | 0.18 | 0.24 |
| lecture hall 300 m2, 75 min, 3 m | 0.56 | 0.56 | 0.04 | 0.56 | 0.56 | 0.04 |
| dorm roommate 8 h, 2 m, 15 m2 | 10.69 | 10.69 | 11.34 | 10.69 | 10.69 | 10.92 |
| late stage (day 5) | 0.08 | 0.08 | 0.15 | 0.08 | 0.08 | 0.15 |
| P_j 0.35 | 1.00 | 1.00 | 1.00 | 0.36 | 0.36 | 0.36 |
| prior 0.3 | 1.00 | 1.00 | 1.00 | 0.72 | 0.71 | 0.71 |
| 3 days after the meeting | 1.00 | 1.00 | 1.00 | n/a | n/a | n/a |
| 7 days after the meeting | 1.00 | 1.00 | 1.00 | n/a | n/a | n/a |
| outdoor RH 20% | 1.01 | 1.01 | 1.08 | 1.01 | 1.01 | 1.08 |
| outdoor RH 80% | 0.98 | 0.98 | 0.96 | 0.98 | 0.98 | 0.96 |

ours: analytic update vs inferRisk, 7/7 scenarios agree within 1e-6 (days = 0 only)

## Reading

**Ours and yours agree to all printed digits on lambda and on P at day 0** in every scenario except
the ones that use an input yours does not have. The port uses the same dose formula
(`q * B * h * (1/qNear + 1/(V * loss))`, qNear = 30 d^2, 5x outdoors, same stage profile and humidity
treatment) and the same update `p + (1 - p) * s * lambda`. The last line of the output also checks our
closed-form against `inferRisk` end to end (7 of 7 within 1e-6). Where the shipped model differs from
your script, it is by additions:

- A quiet-emission rule for dorm rooms (1.5 quanta/h instead of 10, only when the room's `room_type`
  starts with `dorm`). Last row of the table: the 8 h roommate case drops from lambda 0.4906 to 0.0962
  (P 0.4863 to 0.1115). Your script has no input for it, so the dorm row in the main table uses a
  non-dorm room for a like-for-like comparison.
- Doses are summed per pair and the source's risk is applied once, rather than row by row; and
  second-hand risk is damped. These do not show in single-contact scenarios.
- Prior over time: yours decays the prior (`prior * (1 - 1/7)^days`); ours holds the prior fixed as a
  community baseline and decays only the exposure. That is why the 3 and 7 day rows differ between
  Rio (0.0521, 0.0257) and ours (0.0595, 0.0389) while the lambdas match. The Erlang recovery of the
  exposure part is the same function.

**alt differs mainly in scale.** Its lambda is about 6x lower than yours for the base chat (0.0074 vs
0.0459), because alt assumes 1.5 quanta/h while yours assumes 10; the shape (ratios) mostly agrees:

- Duration: 60 min is 3.7x the base for yours and ours, 4.2x for alt. Dorm 8 h: 10.7x vs 11.3x.
- Distance: 2 m vs 1 m is 0.34x for yours, 0.18x for alt (its near-field falls faster, and is zero
  beyond 3 m).
- Large room at 3 m: yours 0.56x of base, alt 0.04x. This is the biggest disagreement in shape. Your
  near-field term `30 d^2` has no cutoff and still dominates at 3 m; alt has none beyond 3 m so only
  the room air contributes.
- Outdoors: 0.18x yours, 0.24x alt. Late stage: 0.08x vs 0.15x (different shedding profiles).
- P_j and the prior behave the same (dP scales with P_j and with 1 - prior in all three).
- Humidity: all three move lambda by only a few percent between 20% and 80% outdoor RH in this
  close-contact scenario (yours and ours 1.01x / 0.98x, alt 1.08x / 0.96x), because the near field
  dominates and humidity only enters the far-field loss rate (all) and a susceptibility term (alt).
- Recovery: alt's P 3 and 7 days later is 0.0158 and 0.0052, below the prior, because it moves people
  into a recovered state and lets the prior drain out; yours and ours stay above the prior. The two
  structures answer different questions (alt separates "ever infected" from "infectious now").

**Open questions for you:**

1. Is 10 quanta/h meant as the chat default? The roommate rows (yours 49% from one 8 h night) are the
   consequence; alt and our dorm rule exist because that looked too high against household attack rates.
2. Should the near-field term have a cutoff, as in alt? The 300 m2 lecture hall row shows what it does.
3. Should the prior decay over time as in your script, or hold as a baseline as in `infer.js`?

Related: `model/TESTS.md` (per-variable tests, calibration and real-run numbers).
