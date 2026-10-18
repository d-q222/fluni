# Agent framework: personalities, interactions, behavior change

Status: **design, not built yet.** Owner: Synthetic agent data (`sim/`). Decisions made with Aiden on
2026-10-17. The build order is at the end.

## Goal

A small set of Claude-driven agents lives inside the normal sim. We measure what they do (how they
handle being sick, whether they follow the app, whether they tell people, whether others sway
them), fit those measurements as rules, and the rule-based population in the large runs (7,500
agents) follows the fitted rules. Claude makes the behavior realistic; the rules make it scale and
reproduce. Every rate in the big runs can be traced back to measured Claude behavior and checked
against published rates.

```
personality (all agents) ──► Claude agents (~50, 7 days) ──► behavior events ──► fit ──► rule-based agents (7,500)
                                                                   │
                                                published rates ───┴──► validation report
```

## 1. Personality (every agent)

**Big Five scores**: openness, conscientiousness, extraversion, agreeableness and neuroticism (O, C,
E, A, N), each in [0, 1]. Each archetype has a Beta prior per trait in `configs/population.json`
(`big_five_beta`). For example, social has high E, studious and stem have high C, homebody has low
E, and athlete has high C and E. Each agent draws its own scores, so two "social" students can
differ.

**Big Five drives the existing traits.** Compliance, mask propensity, honesty, the sick-response
probabilities and social appetite (party / hangout rates) are computed from Big Five, not drawn
separately:

```
logit(trait_i) = intercept[archetype, trait] + Σ_k w[trait, k] · (score_ik − 0.5) + w_worry[trait] · worry_i(t)
```

| Trait | Main drivers (sign) |
|---|---|
| compliance (follows advice) | C (+), A (+), worry (+) |
| mask propensity | C (+), N (+), worry (+) |
| honesty about being sick | A (+), C (+) |
| sick response: stay home / Vaden / carry on | C and N push toward stay home and Vaden; E (+) and low C push toward carry on |
| social appetite (party, hangout, event rates) | E (+), O (+), worry (−) |
| susceptibility to influence | A (+), E (+), C (−) |

The weights `w` start as reasoned directions with small magnitudes. **They are placeholders until
calibration (section 4) replaces them, not published coefficients.** The intercepts are set so
each archetype's mean trait equals today's `*_beta` mean, so the current calibration (influenza
campus R ≈ 1.6) still holds on day one.

**Worry** is the single dynamic state. Its baseline comes from N, and it changes over time (section
3).

Back-compat: all of this is behind `population.personality = "big_five"`, and the default is the
current traits. Existing run ids and sample runs don't change.

## 2. Interactions

Claude agents are the `llm_agents` subset; rule-based agents are everyone else.

| Interaction | Who | Status | Mechanism |
|---|---|---|---|
| **Talk** | Claude ↔ Claude | built | Within 3 m, or in the same small room, for 10 min. Alternating lines, each from the speaker's own private state; a reflection afterwards; can trigger a re-plan. |
| **Notice** | Claude sees rule-based | new | A Claude agent near a visibly sick agent (coughing, flushed) for 5+ min, or in a crowded room, gets an observation in its notifications, e.g. "the person next to you in Green Library has been coughing for 10 minutes". At most 2 observations per agent per day can trigger a re-plan. No extra call unless it re-plans. |
| **Message** | Claude → anyone in its friend group | new | Daily plans, re-plans and reflections can return `messages`: `{to, kind: invite \| warn \| tell_sick, place, time, text}`. Texting needs no proximity. A Claude recipient gets the text in its notifications and decides itself. A rule-based recipient accepts with P(accept) from its influence traits, the relationship and its worry. An accepted invite rewrites its plan; a warning raises its worry and may send it to Vaden. |
| **Group plans** | friend groups | new | An invite sent to the whole group is a group plan, e.g. "dinner at Wilbur 18:30, who's in?". Claude members reply (in their next plan); rule-based members accept by probability. The plan happens if 2 or more people accept. |

Rule-based agents never start interactions; they only respond. That keeps the API cost
proportional to the number of Claude agents, not the population.

## 3. Behavior change over time

Two time scales:

- **Short-term.** Conversations, observations and messages change today's plan (re-plans, capped by
  `max_replans_per_day`).
- **Slow drift in worry.** Every agent's worry relaxes toward its N baseline with a half-life
  (default 3 days). It jumps on events: own symptoms, a friend says they're sick, a friend tests
  positive, a FlUni alert, a warning text, or seeing someone visibly sick. Worry feeds into
  compliance, masks and social appetite (section 1). This is what produces waves of caution
  during an outbreak and relaxation after it.

For Claude agents, worry is measured, not computed: every plan and reflection returns `worry` on a
1–5 scale. Fitting the jump size per event type and the decay from those answers gives the drift
rule for rule-based agents.

## 4. Calibration loop

**Run.** About 50 Claude agents picked as whole friend groups, 7 days, inside a few hundred
rule-based agents. Sonnet- or Haiku-class model for the bulk; Opus on a subset for a
model-sensitivity check. The budget is small (~$20 per run). Before each run, a dry-run estimate
from token counts reports the expected cost, and the run stops at a configured cap.

**Make the events happen.** Fifty agents over a week see few natural sick episodes, so the
calibration scenario oversamples:
- extra initial infections in Claude agents' friend groups;
- forced FlUni alerts at random times;
- a mix of severities.

All are seeded, and each is recorded on the event, so the fit can account for them.

**Measure.** Each decision the agent makes becomes a row in `llm_events.csv`: agent features (Big
Five, archetype, worry, severity, relationship to the other agent) plus a structured outcome.

| Behavior | Outcome recorded | Source |
|---|---|---|
| Sick response | stay home / Vaden / carry on in the next plan after symptom onset; hours out while symptomatic | plan blocks |
| App compliance | followed each advice kind (isolate, mask, leave, get tested) | plan after the alert |
| Disclosure | revealed own symptoms or test in a conversation (`shared_health` flag on each spoken line); honest self-report | talk turns, reports |
| Influence | accepted an invite or warning, by relationship and kind | replies to messages |
| Worry drift | worry before and after each event type, and decay between events | `worry` answers |

**Fit.** One logistic regression per behavior on the features above (in `scripts/calibrate_agents.py`)
gives the intercepts and weights from section 1, written to `configs/behavior_calibrated.json`. The
rule-based population loads that file when `population.personality = "big_five"`. Then the
existing R ≈ 1.6 check is rerun (`scripts/calibrate.py`) and `transmission_scale` adjusted if
behavior shifts the epidemic.

**Validate.** A `validation.md` report compares fitted rates with published ones. Examples are the
share of students who stay home with flu-like illness, presenteeism, contact-tracing app alert
compliance, and disclosure to close contacts. **Each published number gets a citation, collected as
a separate step; none are filled in yet.** Gaps outside a stated tolerance are flagged, not
silently tuned away.

## 5. Outputs

| File | What |
|---|---|
| `llm_agents.jsonl` | every plan call (exists) |
| `llm_conversations.jsonl` | every conversation with reflections (exists) |
| `llm_messages.jsonl` | every text, its recipient's response, and whether an invite happened |
| `llm_events.csv` | one row per measured decision (calibration input) |
| `configs/behavior_calibrated.json` | fitted rules for rule-based agents, with source run ids |
| `validation.md` | fitted vs published rates |

## Build order

1. **Big Five personalities** for all agents, with traits derived from them. Off by default; check
   that the trait means match today's and R is unchanged. **Done** (`campussim/personality.py`,
   `configs/personality.json`, `scripts/smoke_personality.py`).
2. **Worry state and drift** (rule-based jumps and decay), plus the `worry` answer from Claude
   agents.
3. **Structured outcomes and `llm_events.csv`**, including `shared_health` on talk turns.
4. **Notice** (Claude agents observing rule-based agents).
5. **Messages and group plans**, including the P(accept) rule for rule-based recipients.
6. **Calibration scenario**: oversampled events, a cost estimate and a cap.
7. **Fit script** and `behavior_calibrated.json`. **Done** (`scripts/calibrate_agents.py`,
   `personality.weights_source = "calibrated"`, `scripts/smoke_calibrate_agents.py`; the validation
   report from step 8 is `scripts/validation_report.py`, waiting on `configs/published_rates.json`).
8. **Published-rate table** with citations, and the validation report.

## Open questions

- Should Claude agents' behavior also be checked by a second model as a judge, e.g. "is this
  plausible for a student", or only against published rates?
- Group plan quorum: is 2 accepters the right minimum, or should it depend on the event type?
