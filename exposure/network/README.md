# Network mean-field: P(flu) for everyone

The calculator one level up (`../flu_risk.py`) answers "what did this one meeting do to my odds?"
This folder runs the same λ over a whole sim run's contact graph. It tracks every student's
probability of having the flu, using the mean-field (MF) method of Baker et al.,
["Epidemic mitigation by statistical inference from contact tracing data"](https://www.pnas.org/doi/full/10.1073/pnas.2106548118),
PNAS 118 (2021).

## Watch it on the map: P(flu) as agents move

`movement.py` follows the sim's agents along their tracks (`timeline_changes.csv.gz`: position,
room and floor every 5 min). It finds every meeting from those movements itself, without
`contacts.csv`. Two agents meet when they share a room's air, or when they're both outdoors within
5 m. The model then updates everyone's P(flu) every hour. `map.html` plays the run on the
campus: dots walk between buildings, coloured by their live P(flu). Click one to follow them, see
who is sharing their air right now, and see which meetings so far raised their risk, with every
λ input.

```bash
uv run exposure/network/calibrate.py sim/runs/influenza_none_n1000_d14_s42_25fe957a --movement   # -> 0.105
uv run exposure/network/movement.py sim/runs/influenza_none_n1000_d14_s42_25fe957a --lambda-scale 0.105
python3 -m http.server -d exposure/network 8000    # then open http://localhost:8000/map.html
```

It takes about 2 minutes: 9.4 M agent-pair × 5-min co-locations, 336 hourly steps. Scores match
the contact-file version within ±0.01 AUC.

### The risk field: where it is dangerous to stand

The shading under the dots shows, for each spot on the map, the chance you'd catch flu by standing
there for an hour. Each student j leaves a circle of hazard around them that fades exponentially
with distance, h_j(d) = h0_j · exp(−d / L). The circles add up as hazards, giving
P(x) = 1 − exp(−Σ_j h_j). The peak h0_j is λ's near-field dose at 1 m for 1 h
(q · shed_j · B / Q, diluted 5× outdoors). Here shed_j = Σ over infection ages of P_j(age) · stage(age),
so the circle grows with j's P(flu) and with how infectious j's stage is. `movement.py` exports
shed_j every hour. Darkness is proportional to P(x) and saturates at 1%. The fade length L
defaults to 5 m, so circles show beyond the dots, and can be set from 1 to 10 m on the page.
The 1/d² plume itself fades faster than that, and shared room air doesn't fade at all. Hover anywhere off a dot to read P(x).

## Run it (from contacts.csv)

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
