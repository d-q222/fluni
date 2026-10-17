# Exposure calculator

Answers "what did this meeting do to my chance of having the flu?" You describe one meeting with
someone who might be sick and get back your updated probability. You can chain meetings by using
each result as the next starting point.

## Run it

- **Slider page:** open `index.html` in a browser. It has no build step and no server.
- **Command line:**

  ```bash
  python3 exposure/flu_risk.py --prior 0.01 --duration 15 --distance 1 --room 30 \
    --stage peak --p 0.8 --days 2 --humidity 60 --temp 0
  ```

  Run `python3 exposure/flu_risk.py --help` to see every option. Add `--outdoors` for outdoor
  meetings, and `--ach` to set ventilation in air changes per hour.

## Inputs

Your previous probability · duration · distance · room floor area · indoors or outdoors · the
other person's stage of illness (days since their symptoms started) and the probability P that
they have the flu · days since the meeting · outdoor humidity (plus an optional outdoor
temperature, used to estimate indoor humidity in heated rooms).

## Method

The update rule comes from Baker et al., ["Epidemic mitigation by statistical inference from contact
tracing data"](https://www.pnas.org/doi/full/10.1073/pnas.2106548118), PNAS 118 (2021). It is the
paper's simple mean-field update, applied to one contact:

- new infection = (1 − prior) · P · λ
- right after the meeting: prior + new infection
- recovery: an earlier infection resolves at 1/7 per day; a new one follows a ~7-day illness
  (Erlang, shape 4)

The paper leaves the per-contact transmission probability λ as an input. Here it is
λ = 1 − e^(−dose), where the dose adds two terms:

- **close range:** the exhaled plume, which dilutes with distance squared (and 5× more outdoors);
- **the room (indoors only):** well-mixed air (Wells–Riley). It depends on room volume,
  ventilation, settling, and how fast the virus dies off in the air. Flu survives longer in dry
  air (Noti et al. 2013).

The other person's infectiousness follows a flu shedding curve that peaks around the day their
symptoms start. The constants are rough literature values, set so that a 15-minute close
conversation gives λ ≈ 0.03 (the paper used 0.02–0.05). They are not fitted to data, so treat
the results as order-of-magnitude estimates.

`index.html` and `flu_risk.py` use the same model and constants. If you change one, change the
other.

This is separate from `model/`, which infers P(sick) for every agent from the sim's contact graph.

A second version, which treats symptom-free days after the meeting as evidence, is in
[`bayes/`](bayes/README.md).
