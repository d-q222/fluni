# Network mean-field: P(flu) for everyone

The calculator one level up (`../flu_risk.py`) answers "what did this one meeting do to my odds?"
This folder runs the same λ over a whole sim run's contact graph. It tracks every student's
probability of having the flu, using the mean-field (MF) method of Baker et al.,
["Epidemic mitigation by statistical inference from contact tracing data"](https://www.pnas.org/doi/full/10.1073/pnas.2106548118),
PNAS 118 (2021).

## Run it

```bash
uv run exposure/network/calibrate.py sim/runs/influenza_none_n1000_d14_s42_25fe957a
uv run exposure/network/mean_field.py sim/runs/influenza_none_n1000_d14_s42_25fe957a --lambda-scale 0.110
python3 -m http.server -d exposure/network 8000    # then open http://localhost:8000
```

`uv` installs numpy. A 1,000-agent, 14-day run takes about 15 s. `mean_field.py --help` lists
every parameter. The page reads `out/<run_id>/data.js`; add `?run=<run_id>` to view another run.

## What updates λ_{j→i}

| Input | Where it comes from | How it enters |
|---|---|---|
| P(j has the flu) | j's own tracked distribution | transmission = Σ over infection ages of P_j(age) · λ(age) |
| P(i has the flu) | i's tracked distribution | only i's healthy (S) mass can be infected: new = P_S^i · (1 − Π_j(1 − transmission)) |
| Duration | each 5-min row of `contacts.csv` | dose adds up over the rows in a step |
| Distance | `distance_m` | exhaled-plume term 1/(Q_near · d²) |
| Room size | `map/rooms.csv` volume and ACH | Wells–Riley room term 1/(V · loss) |
| Indoors / outdoors | `indoor` | outdoors: no room term, plume diluted 5× more. Through-wall pairs are skipped |
| Stage of flu | j's infection age | the calculator's shedding curve, with symptom onset 2.5 d after infection |
| Time since the meeting | infection age advances each step | an infection caught at a meeting goes latent → infectious → over after 10 d |
| Outdoor humidity | `config.json` weather (per day) | → indoor RH (Magnus) → virus decay rate (Noti et al. 2013) in the room's loss |

Observations follow the paper's MF. A positive test sets P(infected) = 1 from 3 d before the
result. A symptom self-report, or a report by someone else, applies the same clamp, weighted by a
likelihood ratio. A negative test multiplies infected mass by the false-negative rate.
"Recovered" sets P(R) = 1. A report reaches back in time, so every agent is rerun from that
point, and the people the reporter met earlier also go up.

The model also leaves out of j → i the infection mass that j caught from i. This is the cavity
step of dynamic message passing, which the paper cites as MF's parent. On this run it changes
little.

## Calibration and results

The calculator's λ isn't fitted to anything. On this run it predicts about 6× the sim's on-campus
infections; most of the gap is that the sim lowers emission and breathing during sleep, and
dorm-night contacts dominate. `calibrate.py` fits a single dose multiplier: started from the
sim's true seeds, the mean-field should reproduce the sim's total infections. The answer is
0.110. Ground truth is used only for this one number and for scoring.

Results on `influenza_none_n1000_d14_s42_25fe957a` (1,000 agents, 14 days, 223 infected).
"Reports only" is the same model with λ = 0.

| Day | Σ P | Truly infected | AUC | AUC, no reports yet | Sick in top 50 | Reports only: AUC / top 50 |
|---|---|---|---|---|---|---|
| 3 | 37 | 75 | 0.62 | 0.54 | 24 | 0.59 / 19 |
| 7 | 72 | 108 | 0.69 | 0.62 | 30 | 0.60 / 26 |
| 10 | 105 | 93 | 0.72 | 0.61 | 31 | 0.64 / 29 |
| 14 | 153 | 101 | 0.73 | 0.63 | 26 | 0.64 / 29 |

Random picks find about 5 sick people in 50. The contact graph is what finds cases nobody has
reported: AUC rises to 0.6 or more, against 0.5 for reports only.

## Limits

- Σ P is low at first, because the 2% prior is below this run's 5% seeding. It then drifts high
  as reports add infection mass. The model can't see that sick people stay home.
- Rooms with capacity over 150 have no same-room pairs beyond 5 m in `contacts.csv`, so their
  room-air dose is undercounted.
- The model ignores masks and activity-specific breathing, because a phone wouldn't know them.
- Echo inside pairs is removed, but repeated contacts between the same people are still treated
  as independent. That is the MF approximation the paper improves on with belief propagation.

This is separate from `model/`, which keeps a single-pass, evidence-driven P(sick) for the app.
