#!/usr/bin/env python3
"""
Flu-risk updater after a contact, following the framework of
Baker et al., "Epidemic mitigation by statistical inference from contact
tracing data", PNAS 118 (32) e2106548118 (2021).

The paper's model (agent-based SIR, daily steps, simple mean-field "SMF"):

    P(i infected at t+1 | S at t) = 1 - prod_j (1 - lambda_{j->i}(t) * P[q_j(t) = I])
    P(I -> R per day)             = mu  (may depend on time since infection)

where lambda_{j->i} is the transmission probability of a contact and
"accounts for contact duration, distance, protective measures, ..." and may
depend on the infector's time since infection. The paper leaves lambda as an
input. This script fills in lambda with a standard aerosol dose-response
(Wells-Riley) model for influenza, so your inputs (duration, distance, room,
indoor/outdoor, humidity, stage) set lambda. The paper's update rule is then
applied as written.

All physical constants below are literature-based but rough; treat the
output as an order-of-magnitude estimate, not a diagnosis.
"""

import argparse
import math

# ---------------------------------------------------------------- constants
BREATHING_RATE = 0.5      # m^3/h, inhalation of a seated/talking adult
QUANTA_PEAK = 10.0        # infectious quanta/h emitted by a flu case at peak
                          # (published flu estimates span ~10-130 q/h; low end
                          #  chosen so a 15-min close chat gives lambda ~ 0.03,
                          #  matching the paper's lambda = 0.02-0.05)
DEFAULT_ACH = 2.0         # air changes per hour, typical indoor space
DEPOSITION = 0.3          # 1/h, particle settling
CEILING = 2.7             # m, default ceiling height
NEAR_FIELD_Q = 30.0       # m^3/h effective dilution flow of the exhaled plume at 1 m
OUTDOOR_NEAR_DILUTION = 5 # wind dilutes the plume ~5x more outdoors
MU = 1 / 7                # per-day recovery rate (paper's mu; flu illness ~ 1 week)

# Relative infectiousness vs. the infector's days since symptom onset
# (flu viral shedding peaks around symptom onset and is low after ~day 5).
STAGE_PROFILE = {-2: 0.05, -1: 0.3, 0: 1.0, 1: 0.9, 2: 0.6, 3: 0.35,
                 4: 0.18, 5: 0.08, 6: 0.04, 7: 0.02}
STAGE_NAMES = {"presymptomatic": -1, "onset": 0, "peak": 1, "early": 1,
               "mid": 3, "late": 5, "recovering": 7}


def stage_factor(stage):
    """Stage as days since the other person's symptoms began, or a name."""
    if isinstance(stage, str) and not stage.lstrip("-").isdigit():
        stage = STAGE_NAMES[stage.lower()]
    day = int(stage)
    if day < -2 or day > 7:
        return 0.0
    return STAGE_PROFILE[day]


def indoor_rh(outdoor_rh, outdoor_temp_c=None, indoor_temp_c=21.0):
    """Outdoor air heated indoors keeps its water content, so in cold weather
    indoor relative humidity is far lower than outdoor. Without a temperature,
    the given humidity is used as-is."""
    if outdoor_temp_c is None or outdoor_temp_c >= indoor_temp_c:
        return outdoor_rh

    def sat(t):  # saturation vapour pressure, hPa (Magnus formula)
        return 6.112 * math.exp(17.62 * t / (243.12 + t))
    return min(100.0, outdoor_rh * sat(outdoor_temp_c) / sat(indoor_temp_c))


def virus_decay(rh):
    """1/h airborne inactivation of influenza vs relative humidity.
    Noti et al. 2013: ~75% infectivity retained after 1 h at RH<25%,
    ~20% retained at RH>43%."""
    low, high = math.log(1 / 0.75), math.log(1 / 0.20)   # ~0.29, ~1.61
    if rh <= 25:
        return low
    if rh >= 45:
        return high
    return low + (high - low) * (rh - 25) / 20


def transmission_probability(duration_min, distance_m, room_m2, indoors,
                             stage, humidity_pct, outdoor_temp_c=None,
                             ach=DEFAULT_ACH, ceiling_m=CEILING):
    """lambda_{j->i}: probability the meeting infects you, given they ARE infected."""
    hours = duration_min / 60
    q = QUANTA_PEAK * stage_factor(stage)
    d = max(distance_m, 0.3)

    # Near field: the exhaled plume dilutes roughly with distance squared.
    q_near = NEAR_FIELD_Q * d ** 2 * (1 if indoors else OUTDOOR_NEAR_DILUTION)
    dose = q * BREATHING_RATE * hours / q_near

    # Far field: the well-mixed room (Wells-Riley); none outdoors.
    if indoors:
        rh = indoor_rh(humidity_pct, outdoor_temp_c)
        volume = room_m2 * ceiling_m
        loss = ach + DEPOSITION + virus_decay(rh)
        dose += q * BREATHING_RATE * hours / (volume * loss)

    return 1 - math.exp(-dose)


def still_infected(days, mean=7.0, shape=4):
    """P(an infection that began `days` ago has not yet resolved);
    Erlang-distributed illness length (incubation + infectious period)."""
    x = days / (mean / shape)
    return math.exp(-x) * sum(x ** n / math.factorial(n) for n in range(shape))


def update(prior, their_p, duration_min, distance_m, room_m2, indoors,
           stage, days_since, humidity_pct, outdoor_temp_c=None,
           ach=DEFAULT_ACH):
    """Returns a dict with lambda, the probability you were infected right after
    the meeting, and the probability you have the flu now."""
    lam = transmission_probability(duration_min, distance_m, room_m2, indoors,
                                   stage, humidity_pct, outdoor_temp_c, ach)

    # The paper's SMF update for one contact: you are still susceptible only if
    # you were before AND this contact didn't infect you.
    p_new = (1 - prior) * their_p * lam
    after_meeting = prior + p_new

    # Days elapse: an earlier infection of unknown age recovers at rate mu
    # (the paper's I->R step); the new one follows its illness course.
    now = prior * (1 - MU) ** days_since + p_new * still_infected(days_since)
    return {"lambda": lam, "p_infected_by_meeting": p_new,
            "p_after_meeting": after_meeting, "p_now": now}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--prior", type=float, required=True,
                    help="your previous probability of having the flu (0-1)")
    ap.add_argument("--duration", type=float, required=True, help="minutes")
    ap.add_argument("--distance", type=float, required=True, help="metres")
    ap.add_argument("--room", type=float, default=50,
                    help="room floor area in m^2 (ignored outdoors)")
    ap.add_argument("--outdoors", action="store_true")
    ap.add_argument("--stage", required=True,
                    help="their days since symptom onset (-2..7) or one of "
                         + ", ".join(STAGE_NAMES))
    ap.add_argument("--p", type=float, required=True,
                    help="probability the other person has the flu (0-1)")
    ap.add_argument("--days", type=float, default=0, help="days since the meeting")
    ap.add_argument("--humidity", type=float, required=True,
                    help="outdoor relative humidity in %%")
    ap.add_argument("--temp", type=float, default=None,
                    help="outdoor temperature in C (optional; refines indoor humidity)")
    ap.add_argument("--ach", type=float, default=DEFAULT_ACH,
                    help="ventilation, air changes per hour (optional)")
    a = ap.parse_args()

    r = update(a.prior, a.p, a.duration, a.distance, a.room, not a.outdoors,
               a.stage, a.days, a.humidity, a.temp, a.ach)
    print(f"Transmission probability if they are infected (lambda): {r['lambda']:.4f}")
    print(f"Chance this meeting infected you:                     {r['p_infected_by_meeting']:.4f}")
    print(f"P(flu) right after the meeting:                        {r['p_after_meeting']:.4f}")
    print(f"P(flu) now, {a.days:g} day(s) later:                          {r['p_now']:.4f}")
    print("Use the last number as --prior for your next meeting.")


if __name__ == "__main__":
    main()
