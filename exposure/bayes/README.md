# Exposure calculator: Bayesian variant

A second take on the exposure calculator in the parent folder. It answers the same question, "what
did this meeting do to my chance of having the flu?", but uses "no symptoms yet" as evidence: each
symptom-free day after the meeting lowers your probability.

## Run it

- **Slider page:** open `index.html` in a browser. It has no build step and no server.
  "Use as previous probability" chains meetings and keeps a list of them.
- **Command line:**

  ```bash
  python3 exposure/bayes/flu_update.py --p-contact 0.5 --prior 0.02 --duration 30 --distance 1.5 \
    --room-area 25 --setting indoors --stage 1 --days-since 2 --humidity 45 --temp 5
  ```

  Run `python3 exposure/bayes/flu_update.py --help` to see every option. `--stage` takes days since
  the other person's symptoms started, or one of `incubating`, `presymptomatic`, `early`, `peak`,
  `late`, `recovering`.

## Method

1. **Their infectiousness:** a flu shedding curve (Carrat et al. 2008; Ip et al. 2016) that starts
   about a day before symptoms and peaks on days 0–1.
2. **Dose:** Wells–Riley well-mixed room air (quanta from Rudnick & Milton 2003) plus a close-range
   term from the exhaled jet, which dilutes as 1/distance (Ricou & Spalding). Outdoors drops the
   room term and dilutes the jet further.
3. **Humidity:** the Shaman et al. (2010) absolute-humidity curve, computed from outdoor humidity
   and temperature. Outdoor absolute humidity also sets indoor humidity in heated buildings.
4. **Infection chance if they're sick:** 1 − e^(−dose).
5. **Combine:** p = 1 − (1 − prior)(1 − P · infection chance).
6. **Days since the meeting:** Bayes' rule with a lognormal incubation period (median 1.4 days,
   Lessler et al. 2009) and 67% of infections symptomatic (Carrat et al. 2008).

The defaults give roughly 20–30% for an hour face to face with someone at peak illness. They are
literature values, not fitted to data, so treat results as rough estimates.

## How it differs from the parent calculator

| | Parent (`exposure/`) | This one (`exposure/bayes/`) |
|---|---|---|
| Update rule | Baker et al. (PNAS 2021) mean-field | Bayes with symptom-free days as evidence |
| Days since meeting | Recovery: infection resolves over ~7 days | Each symptom-free day lowers the odds |
| Humidity | Virus survival in dry air (Noti et al. 2013) | Shaman et al. (2010) absolute-humidity curve |
| Close range | Dilutes with distance squared | Dilutes with distance (turbulent jet) |

`index.html` and `flu_update.py` use the same model and constants. If you change one, change the
other.
