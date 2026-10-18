# `model/alt` — an independent flu-probability update

A second, independently designed answer to the product owner's spec:

> Using the best existing methodologies on updating the probability that I have the flu after every
> time I meet another person who has the flu with probability P, make a prediction algorithm for the
> new probability that I have the flu.

It was built without reading `exposure/` (the other implementation) or `model/infer.js`, so that the
two can be compared as genuinely separate attempts. The comparison is at the bottom.

## Run it

```bash
node model/alt/cli.mjs --prior 0.01 --p 0.8 --duration 15 --distance 1 \
  --room 30 --stage 1 --days 2 --humidity 60 --verbose
node model/alt/cli.mjs --help
node model/alt/test.mjs          # 24 tests, plain asserts, no dependencies
```

As a library (dependency-free ES module, runs in Node and the browser):

```js
import { update, lambdaForContacts } from './model/alt/flu_alt.mjs';

const r = update({ prior: 0.01, p: 0.8, duration: 15, distance: 1,
                   room: 30, stage: 1, days: 2, humidity: 60 });
// → { lambda, pInfectedByMeeting, pNow, states: { S, E, I, R }, ... }
```

## Inputs

| input | meaning | default |
|---|---|---|
| `prior` | my previous P(have the flu) | 0 |
| `priorR` | my P(already had it and recovered) | 0 |
| `priorStates` | `{S,E,I,R}` instead of `prior`/`priorR` | — |
| `p` | their P(have the flu) | 1 |
| `duration` | minutes of contact | 0 |
| `distance` | metres between us | 1 |
| `room` | room **floor area**, m² (or `roomVolume` in m³) | 30 |
| `ceilingHeight`, `ach` | m, air changes/h | 2.7, 3.0 |
| `outdoors` | boolean | false |
| `stage` | their day of illness, 0 = symptom onset (or a label, or `'unknown'`) | `'unknown'` |
| `days` | days since the meeting | 0 |
| `humidity` | **outdoor** relative humidity, % | 50 |
| `temp` | outdoor temperature, °C | 10 |
| `talking` | **defaults to `true`** — see below | true |
| `contacts` | array of rows for one person on one day | — |

**`talking` is an extra input, defaulting to `true`.** Speech emits several times more respiratory
aerosol than quiet breathing, so a model that ignores it either overstates a night of sleeping or
understates a conversation. `true` is the right default for a meeting someone bothered to log; set
it `false` for sleeping, studying, or sitting silently in a lecture. If your contact log cannot tell,
leave it at the default and accept that long quiet exposures will be overstated.

Inputs are validated: negative durations, areas, distances, humidities, ACH and `days` throw
`RangeError`; non-numeric or `NaN` values throw `TypeError`; probabilities are clamped to [0, 1]
rather than rejected.

## Method

Four stages: **dose → infection probability → state update → ageing.**

### 1. Dose (quanta inhaled), two-zone

Dose is in Wells–Riley *quanta*. One quantum is by construction the dose that infects
1 − e⁻¹ = 63.2% of susceptibles, which is why the dose–response below is exponential
(Wells 1955; Riley, Murphy & Riley 1978). A well-mixed single box is known to understate close
contact and overstate short meetings, so the room is split into a near field (the other person's
exhaled jet) and a far field (the room's air), following the two-zone / "two-box" family of models
(Nicas 2005; Fierce et al. 2021; Iddon, Jones et al. 2022).

**Emission.** The other person, *if infectious*, emits

```
E_q = EQ_PEAK_TALKING · f_stage(day) · (talking ? 1 : BREATHING_FRACTION)      [quanta/h]
```

**Near field.** The exhaled jet entrains room air, so its cross-section grows roughly with the
square of distance and the excess concentration falls off as 1/d². Take the dilution flow at 1 m as
`Q_NEAR_1M` and subtract the value at the cutoff so the term joins the far field continuously:

```
g(d)   = (1/max(d, 0.3))² − (1/3)²         for d < 3 m, else 0
n_near = p_b · E_q · g(d) · D / Q_NEAR_1M              [quanta]      (× 0.25 outdoors)
```

Linear in time, which is right for a jet: it reaches its quasi-steady shape in seconds.

**Far field — transient, not steady state.** A steady-state Wells–Riley term assumes the room has
already reached its equilibrium concentration, which badly overstates a 10-minute meeting in an
initially clean room. Integrating the transient instead:

```
C(t)  = E_q / (λ_rem · V) · (1 − e^(−λ_rem·t))
n_far = p_b · ∫₀ᴰ C(t) dt = p_b · E_q/(λ_rem·V) · (D − (1 − e^(−λ_rem·D))/λ_rem)
λ_rem = ACH + k_deposition + k_inactivation(RH)        [1/h]
V     = floor area × ceiling height                    [m³]
```

For short D this grows as D², approaching the steady-state linear form only after ~1/λ_rem.
**Outdoors** the far field is dropped entirely (unbounded dilution) and the near field is cut to a
quarter for wind and cross-breezes.

**Humidity.** The input is *outdoor* RH, but what matters indoors is the RH the aerosol actually
experiences. Absolute humidity is conserved when outdoor air is drawn in and heated, so outdoor RH
and temperature are converted to absolute humidity, then back to RH at 20 °C — which is why cold
weather means dry indoor air and more airborne survival. That is the mechanism behind absolute
humidity's association with influenza seasonality (Shaman & Kohn 2009; Marr et al. 2019).
Inactivation is a logistic ramp between the two anchors in Noti et al. 2013, and a second, milder
multiplier carries the part of the absolute-humidity effect that survival alone does not explain
(host airway defence, Shaman & Kohn 2009):

```
k_inact(RH) = 0.3 + 1.5 / (1 + e^(−(RH − 35)/5))                 [1/h]
susc(AH)    = clamp(exp(−0.02·(AH − 7)), 0.7, 1.5)
λ = (n_near + n_far) · susc(AH)
```

### 2. Dose → infection probability, with their P

The exponential dose–response is intrinsic to quanta units. The other person's P multiplies the
result **once**, because they are either infectious for the whole meeting or not at all:

```
P(infected | susceptible) = p_other · (1 − e^(−λ))
```

Influenza dose–response has also been fitted as beta-Poisson in TCID₅₀ units
(Watanabe et al. 2012: ID₁₀ ≈ 18 TCID₅₀ for wild-type H3N2; Nicas 2005). We did not use it: it
would need a quanta → TCID₅₀ conversion that is itself a free parameter, and over the dose range
this app ever sees (λ ≲ 0.1) the two forms are indistinguishable. The exponential form is the one
with a defined unit, so it is the one implemented.

### 3. Repeated contact with the same person: sum the dose, apply P once

`lambdaForContacts(rows)` takes every row for **one person on one day** and returns a single λ:

- near-field terms add (linear in time);
- far-field terms for rows in the same room are merged into **one** transient integral over the
  summed time, so a day logged as 96 × 5-minute rows gives exactly the λ of one 8-hour row
  (verified in `test.mjs`);
- the person's P multiplies the result once.

This matters because the alternative — updating row by row — lets P(I was infected) climb towards 1
as rows accumulate, when it can never exceed P(they had flu at all). With a saturating exposure at
P = 0.5 (24 h at 0.4 m, dose 5.0 quanta), per-row updating gives 0.90 where the correct answer is
0.50.

### 4. State probabilities S / E / I / R, and "days since the meeting"

`P(I have the flu)` has to mean *currently infected*, not *ever infected*, or the heat map glows
forever and recovered people get reinfected. So the state is a vector, not a scalar:

```
S → E (latent, not yet infectious) → I (infectious) → R (recovered, immune this season)
```

E and I each use two Erlang stages, so sojourn times are gamma-distributed rather than exponential.
That matters here: with exponential stages a person infected ten minutes ago would already be
counted as substantially infectious, which is wrong and would feed straight into the heat map.
Durations: mean latent 1.0 d (shedding detectable 0.5–1 d after challenge, Carrat et al. 2008),
mean infectious 4.8 d (mean shedding duration, Carrat et al. 2008). Incubation to *symptoms* is
~1.4 d (Lessler et al. 2009) and is used only to index the stage curve.

A meeting moves `S · P(infected)` out of S into the first latent stage. Then the whole vector is
propagated forward `days` days by integrating the linear ODE (RK4, mass-conserving). Output:

- `states` — `{S, E, I, R}`,
- `pNow` — `E + I`, P(currently infected),
- `pInfectious` — `I`, P(currently infectious, i.e. a risk to others).

There is no background community hazard in the propagation: `S` only leaves S through a logged
meeting. For a campus-wide product that is a real omission (you can catch flu from someone you
never got within Bluetooth range of), but it belongs to whatever drives the prior, not here.

## Constants and sources

| constant | value | source |
|---|---|---|
| `EQ_PEAK_TALKING` | 1.5 quanta/h | calibrated (below). Stabile & Buonanno report a median of 0.17 quanta/h for seasonal influenza, standing and speaking; that is an illness **median** across a lognormal spread, and our value is a talking **peak-day** rate. |
| `BREATHING_FRACTION` | 0.12 | Buonanno, Stabile & Morawska 2020 give 0.36 (oral breathing, light activity) vs 4.9 (speaking, light activity) quanta/h for SARS-CoV-2, a ratio of 0.073, as tabulated by CDPH; 0.12 is deliberately conservative. |
| `BREATHING_RATE` | 0.52 m³/h | sedentary/light adult inhalation, US EPA *Exposure Factors Handbook* (~8.7 L/min). |
| `ACH_DEFAULT` | 3.0 /h | typical mechanically ventilated room; ASHRAE 62.1 classroom/office rates land at 3–6 /h. Dorm rooms are nearer 2, so pass `ach`. |
| `K_DEPOSITION` | 0.3 /h | gravitational settling of 1–3 µm respiratory aerosol (Nicas, Nazaroff & Hubbard 2005). |
| `K_INACT_DRY/HUMID` | 0.3 / 1.8 /h | Noti et al. 2013: ~70–77% of infectivity survives 60 min at RH ≤ 23% (k ≈ 0.31/h), ~15–22% at RH ≥ 43% (k ≈ 1.7/h). |
| `AH_SUSC_COEFF` | 0.02 per g/m³ | Shaman & Kohn 2009 (absolute humidity modulates survival *and* transmission); kept small so survival carries most of the effect. |
| `Q_NEAR_1M` | 25 m³/h | entrained-air dilution flow in the jet at 1 m. Exhaled minute volume is ~0.5 m³/h, so this is a ~50× dilution at 1 m; calibrated (below). |
| `NEAR_CUTOFF` | 3.0 m | beyond ~2–3 m the jet is no longer distinguishable from room air; Fierce et al. 2021 find near-field enhancement often persists past 2 m, so 3 m is the conservative edge. |
| `OUTDOOR_NEAR_FACTOR` | 0.25 | judgement: wind and cross-breezes break up the jet. No clean literature value; the main outdoor effect is losing the far field. |
| shedding curve | peak at onset, ~0 by day 8 | Carrat et al. 2008 (challenge studies: shedding peaks ~day 2 post-challenge, mean duration 4.8 d) and Lau et al. 2010 (natural infection: most shedding in the first 2–3 days after onset, a small presymptomatic share). |
| unknown-stage factor | 0.51 | mean of the shedding curve over days −1…6, i.e. a contact equally likely to be on any infectious day. This is the **default**, so a contact of unknown stage is treated as an average day of illness, not a peak one. |
| latent / infectious | 1.0 d / 4.8 d mean, Erlang-2 | Carrat et al. 2008. |
| incubation | 1.4 d median | Lessler et al. 2009. |

Not modelled, deliberately: masks, vaccination, prior-season immunity (beyond `priorR`), children
(all the shedding data above is adults), influenza B's different shedding timing, asymptomatic
infection as a separate state (Carrat et al. 2008 found ~67% of infections symptomatic, so roughly a
third of cases never reach a `stage` the app can observe — they show up as a higher prior, not as a
separate compartment).

### Calibration

Two constants (`EQ_PEAK_TALKING`, `Q_NEAR_1M`) are fixed by two literature anchors, both asserted in
`test.mjs`:

1. **A 15-minute close conversation** (1 m, 30 m², ACH 3, peak shedding, winter weather) →
   λ = 0.0073, i.e. a 0.7% chance of infection from one such meeting with a known case. Consistent
   with household attack rates: if a single 15-minute chat were worth several percent, a roommate
   would be infected almost certainly.
2. **A roommate of a confirmed case over the whole illness** (15 m² dorm, ACH 2, 8 h/night asleep at
   1.5 m not talking plus 4 h/day awake at 2 m talking, their day −1 … +5) → **20.7% infected**,
   inside the 10–25% target. Reported household secondary attack rates: 10.3% (ILI) to 20.2% (ARI)
   in Ontario 2009 H1N1, 14.5% in Hong Kong, 3–38% across the 2009 pandemic household literature
   (Tsang et al. 2016 review).

The other test cases follow from those two rather than being tuned: a 1-hour lecture at 5 m is
0.003%, 5 minutes outdoors at 2 m is 0.009%.

### References

- Wells, *Airborne Contagion and Air Hygiene* (1955); Riley, Murphy & Riley, *Am J Epidemiol* 107:421 (1978) — Wells–Riley and the quantum.
- Nicas, Nazaroff & Hubbard, *J Occup Environ Hyg* 2:143 (2005) — aerosol removal and dose–response.
- Fierce et al., *Indoor Air* 31:1795 (2021), [arXiv:2104.01219](https://arxiv.org/abs/2104.01219) — near-field enhancement beyond 2 m.
- Iddon, Jones et al., *Building and Environment* (2022) — far-field mass-balance + dose–response framework.
- Buonanno, Stabile & Morawska, *Environ Int* 141:105794 (2020) — quanta emission from viral load and activity.
- Stabile & Buonanno, comparative quanta-emission analysis — seasonal influenza median 0.17 quanta/h, speaking.
- Watanabe, Bartrand, Omura & Haas, *Risk Analysis* 32(3):555 (2012), [doi:10.1111/j.1539-6924.2011.01680.x](https://doi.org/10.1111/j.1539-6924.2011.01680.x) — influenza A dose–response.
- Noti et al., *PLoS ONE* 8(2):e57485 (2013), [PMID 23460865](https://pubmed.ncbi.nlm.nih.gov/23460865/) — humidity and airborne influenza infectivity.
- Shaman & Kohn, *PNAS* 106(9):3243 (2009), [doi:10.1073/pnas.0806852106](https://doi.org/10.1073/pnas.0806852106) — absolute humidity modulates survival, transmission, seasonality.
- Marr et al., *J R Soc Interface* 16:20180298 (2019) — mechanistic account of the humidity effect.
- Carrat et al., *Am J Epidemiol* 167(7):775 (2008), [PMID 18230677](https://pubmed.ncbi.nlm.nih.gov/18230677/) — shedding and symptom timelines, mean shedding 4.8 d, ~67% symptomatic.
- Lau et al., *J Infect Dis* 201(10):1509 (2010) — shedding in naturally acquired infection; presymptomatic share.
- Lessler et al., *Lancet Infect Dis* 9(5):291 (2009), [PMID 19393959](https://pubmed.ncbi.nlm.nih.gov/19393959/) — incubation 1.4 d (95% CI 1.3–1.5) for influenza A.
- Tsang et al., *Trends Microbiol* 24(2):123 (2016) — household transmission of influenza; secondary attack rates.
- Baker et al., *PNAS* 118(32):e2106548118 (2021) — inference from contact-tracing data (the basis of `exposure/`).
- US EPA, *Exposure Factors Handbook*, ch. 6 — inhalation rates. ASHRAE 62.1 — ventilation rates.

## Comparison with `exposure/flu_risk.py` (Rio's model)

Same spec, same inputs, so the two are directly comparable. Rio's uses the mean-field per-contact
update from Baker et al. 2021 with a Wells–Riley λ; ours uses a two-zone transient dose with an
S/E/I/R state vector. Both were run on the same ten scenarios with `prior = 0.01` and matching room,
ventilation, stage, humidity and temperature. In both models λ = 1 − e^(−dose) is the per-contact
transmission probability *given* that the other person is infectious.

| # | scenario | λ (alt) | λ (Rio) | alt/Rio | P(flu now) alt | P(flu now) Rio |
|---|---|---|---|---|---|---|
| 1 | 15-min chat, 1 m, 30 m², peak, P = 1 | 0.00732 | 0.0446 | 0.16× | 1.72% | 5.42% |
| 2 | the same, their P = 0.3 | 0.00732 | 0.0446 | 0.16× | 1.22% | 2.32% |
| 3 | 5-min queue, 0.5 m, 60 m², day 1 | 0.00984 | 0.0493 | 0.20× | 1.97% | 5.88% |
| 4 | 1 h lecture, 5 m, 200 m², silent | 2.8e-5 | 0.00852 | 0.003× | 1.00% | 1.84% |
| 5 | 2 h dining hall, 1.5 m, 300 m², day 2 | 0.0151 | 0.0868 | 0.17× | 2.50% | 9.59% |
| 6 | 8 h night, roommate 1.5 m, 15 m², asleep | 0.0159 | 0.6069 | 0.03× | 2.57% | 61.09% |
| 7 | 30 min car, 0.8 m, 4 m³ | 0.0328 | 0.1973 | 0.17× | 4.24% | 20.53% |
| 8 | 5 min outdoors, 2 m | 9.3e-5 | 0.00069 | 0.13× | 1.01% | 1.07% |
| 9 | 45 min outdoors, 1 m, day 1 | 0.00506 | 0.0222 | 0.23× | 1.50% | 3.20% |
| 10 | 20 min library, 2.5 m, dry winter, day 4, P = 0.6, 2 days ago | 2.3e-5 | 0.00191 | 0.01× | 0.66% | 0.84% |

Roommate over a week, logged the way a proximity app logs it — 96 five-minute rows per night
(8 h at 1.5 m, 15 m² dorm, ACH 2, their day 0…6):

| their P | model | total dose (quanta) | P(flu now) at day 7 | ever infected |
|---|---|---|---|---|
| 1.0 | alt — dose summed per pair-day, S/E/I/R | 0.058 | 2.83% | 6.56% |
| 1.0 | Rio — applied row by row | 2.94 | 48.9% | — |
| 1.0 | Rio — one λ per pair-day (the review's fix) | 2.94 | 48.9% | — |
| 0.5 | alt | 0.058 | 1.51% | 3.81% |
| 0.5 | Rio — row by row | 2.94 | 36.7% | — |
| 0.5 | Rio — one λ per pair-day | 2.94 | 33.9% | — |

(Night-only exposure, so the alt figure is below the 20.7% full-household calibration above, which
also includes four waking hours of conversation a day.)

### Where the difference comes from

1. **Overall scale (the flat ~0.17× on scenarios 1–3, 5, 7–9).** Rio's `QUANTA_PEAK = 10` quanta/h
   against our 1.5 peak-talking, and Rio's model has no talking/breathing distinction. Rio's README
   is explicit that 10 was picked so a 15-minute chat gives λ ≈ 0.03 to match the 0.02–0.05 range
   Baker et al. used as an *illustrative* input. We calibrated against household attack rates
   instead, and 0.03 per 15-minute chat cannot be reconciled with a 10–20% household SAR. The
   remaining ~1.2× is our unknown-stage default and the humidity susceptibility term.
2. **Long close exposures (scenario 6: 0.03×).** Rio's near field is `Q_near = 30·d²` with **no
   cutoff**, so it keeps a 1/d² term at every distance and never hands over to the room; combined
   with 10 quanta/h and no breathing discount, 8 h asleep at 1.5 m reaches λ = 0.61 per night, and a
   roommate is at 49% within a week. This is exactly the second issue raised in the WORKSTREAMS
   review, and it is the largest disagreement between the two models.
3. **Distance cutoff and the transient far field (scenario 4: 0.003×).** The lecture diverges most
   because Rio's near field, `Q_near = 30·d²` with no cutoff, still credits a 1/d² jet term at 5 m —
   that term is most of Rio's 0.0085 — while ours is zero beyond 3 m and the room air is all that is
   left. Two smaller effects push the same way: Rio has no breathing discount for a silent lecture,
   and Rio's far field is steady-state (`dose = q·p_b·h/(V·loss)`) where ours is the transient
   integral, worth ~1.2× for an hour in a 600 m³ room but ~3× for ten minutes in one.
4. **Pair-day aggregation.** Ours sums dose and applies P once by construction; at P = 1 Rio's
   row-by-row and per-day forms happen to agree (per-row λ is small, so compounding ≈ summing), but
   at P = 0.5 they split (36.7% vs 33.9%) and in general row-by-row updating drifts towards 1
   instead of towards P.
5. **What "P(flu now)" means.** Rio's is scalar: `prior·(1−µ)^days + p_new·Erlang(days)`, with
   µ = 1/7 per day. A newly infected person counts as having flu immediately — no latent period —
   and there is no R state, so the prior decays towards 0 and the same person can be re-infected by
   the next meeting. Ours propagates S/E/I/R, so someone infected ten minutes ago is latent (I ≈ 0),
   someone who has recovered is immune for the season, and `pNow` and `pInfectious` are separate
   numbers. In scenario 1 our `pNow` (1.72%) exceeds our `pInfectedByMeeting` (0.73%) because the
   1% prior is still mostly current; Rio's 5.42% is mostly the larger λ.

Both agree that the outdoor cases are negligible and that dry winter air raises risk, and they agree
to within a factor of ~1.3 on direction and ordering for every scenario. The disagreement is almost
entirely magnitude, and almost entirely about long close exposures.

## Recommendation for the campus heat map

Heat is meant to be Σ P(currently infected) over the people in an area. Use **this model** for that,
for three reasons, in order of importance:

1. **It gives the right quantity.** Heat needs *currently infectious*, which is `states.I` here.
   Rio's scalar has no latent and no recovered state, so it counts someone infected minutes ago as a
   source of heat and lets the same person be re-infected repeatedly. Over a multi-day sim that
   inflates the map and never lets a hotspot cool.
2. **It is pair-day safe by construction.** The sim logs contacts as short rows. `lambdaForContacts`
   sums dose and applies P once, so the map does not depend on how finely the contact log is sliced
   — the test asserts 96 × 5-minute rows equal one 8-hour row exactly. Row-by-row updating has to
   be remembered by every caller, and the review found it had not been.
3. **It is calibrated to attack rates rather than to an illustrative λ.** With Rio's constants a
   roommate reaches ~49% in a week and dorm-heavy areas of the map saturate; the heat map then shows
   building occupancy rather than infection risk.

Caveats, stated plainly: this model is not fitted to data either. The two free constants are pinned
by two aggregate anchors, and everything else is literature values with wide uncertainty — treat
absolute numbers as order-of-magnitude and lean on the *relative* heat between areas, which is what
a map needs. If the product wants a single defensible per-area number, use
`Σ states.I` and label it an estimate.

What is worth taking from Rio's version: the Baker et al. framing is the right one for the harder
problem `model/` actually faces — inferring everyone's P jointly from a contact graph where nobody's
status is known. This model is a better *per-contact λ and per-person state update*; Baker et al.
is a better *network inference scheme*. The natural combination is to feed this λ into that
inference rather than to choose between them.
