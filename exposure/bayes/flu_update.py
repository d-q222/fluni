#!/usr/bin/env python3
"""
Bayesian flu-risk updater: after each encounter with someone who has flu
with probability P, compute your new probability of having flu.

Pipeline (each step is a standard, published method):

  1. Infectiousness of the contact vs. their illness stage
       -> viral-shedding curve (Carrat et al. 2008, Am J Epidemiol;
          Ip et al. 2016, Clin Infect Dis): shedding starts ~1 day before
          symptoms, peaks day 0-1, falls off by day 5-7.
  2. Airborne dose
       -> far-field: Wells-Riley well-mixed room model (Riley et al. 1978;
          influenza quanta from Rudnick & Milton 2003, 15-128 quanta/h)
       -> near-field: turbulent-jet dilution of exhaled air with distance
          (Ricou & Spalding 1961 entrainment; Chen et al. 2020 short-range
          exposure framing), plus outdoor dispersion.
  3. Humidity
       -> absolute-humidity modulation of transmission (Shaman & Kohn 2009,
          PNAS; Shaman et al. 2010, PLoS Biol). Outdoor absolute humidity
          also sets indoor humidity in heated buildings.
  4. Dose -> infection probability
       -> exponential dose-response, P(inf | infected contact) = 1 - exp(-dose).
  5. Combine with your prior
       -> P_new = 1 - (1 - prior) * (1 - P * P_inf)
  6. Days since meeting (Bayesian evidence from "no symptoms yet")
       -> incubation period lognormal, median 1.4 d, dispersion 1.51
          (Lessler et al. 2009, Lancet Infect Dis); ~67% of infections are
          symptomatic (Carrat et al. 2008).

All constants are in CONFIG so you can recalibrate. Outputs are estimates
with wide uncertainty (quanta rates alone vary ~10x); not medical advice.
"""

import argparse
import math

CONFIG = {
    # Emission / inhalation
    "quanta_per_hour_peak": 20.0,   # infectious quanta/h at peak shedding (low end of Rudnick & Milton)
    "breathing_m3_per_hour": 0.5,   # sedentary adult
    # Room
    "ceiling_height_m": 2.5,
    "air_changes_per_hour": 1.0,    # typical home/office without strong ventilation
    "deposition_per_hour": 0.3,     # particle settling loss
    "inactivation_per_hour": 0.6,   # airborne influenza decay
    # Near-field jet
    "mouth_diameter_m": 0.02,
    "jet_entrainment": 0.32,        # Ricou & Spalding round-jet coefficient
    "face_to_face_fraction": 0.15,  # share of time you're in their exhaled plume
    "outdoor_nearfield_factor": 0.3,  # wind/plume meander dilution outdoors
    # Humidity (Shaman et al. 2010 form: R0(q) = exp(a*q + ln(R0max-R0min)) + R0min)
    "shaman_a": -180.0,
    "shaman_r0max": 3.52,
    "shaman_r0min": 1.12,
    "shaman_reference_q": 0.005,    # kg/kg, multiplier = 1 here
    "default_outdoor_temp_c": 10.0,
    # Incubation / symptoms
    "incubation_median_days": 1.4,
    "incubation_dispersion": 1.51,
    "p_symptomatic": 0.67,
}

# Relative infectiousness vs. days since the contact's symptom onset
# (negative = before symptoms). Normalised so the peak = 1.
SHEDDING_CURVE = [
    (-3, 0.0), (-2, 0.05), (-1, 0.3), (0, 0.9), (1, 1.0), (2, 0.8),
    (3, 0.5), (4, 0.3), (5, 0.15), (6, 0.08), (7, 0.04), (10, 0.0),
]

STAGE_ALIASES = {
    "incubating": -2, "presymptomatic": -1, "early": 0, "peak": 1,
    "late": 3, "recovering": 5, "recovered": 10,
}


def stage_infectiousness(stage):
    """stage: days since contact's symptom onset (float) or a named stage."""
    if isinstance(stage, str):
        key = stage.strip().lower()
        if key in STAGE_ALIASES:
            stage = STAGE_ALIASES[key]
        else:
            stage = float(key)
    pts = SHEDDING_CURVE
    if stage <= pts[0][0] or stage >= pts[-1][0]:
        return 0.0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if x0 <= stage <= x1:
            return y0 + (y1 - y0) * (stage - x0) / (x1 - x0)
    return 0.0


def specific_humidity(rh_percent, temp_c, pressure_hpa=1013.25):
    """Relative humidity + temperature -> specific humidity (kg/kg), Magnus formula."""
    e_sat = 6.112 * math.exp(17.67 * temp_c / (temp_c + 243.5))
    e = rh_percent / 100.0 * e_sat
    return 0.622 * e / (pressure_hpa - 0.378 * e)


def humidity_multiplier(rh_percent, temp_c, c=CONFIG):
    def r0(q):
        return math.exp(c["shaman_a"] * q + math.log(c["shaman_r0max"] - c["shaman_r0min"])) + c["shaman_r0min"]
    return r0(specific_humidity(rh_percent, temp_c)) / r0(c["shaman_reference_q"])


def inhaled_dose(duration_min, distance_m, room_area_m2, indoors, infectiousness, hum_mult, c=CONFIG):
    """Expected inhaled quanta, given the contact IS infected."""
    hours = duration_min / 60.0
    q = c["quanta_per_hour_peak"] * infectiousness * hum_mult
    B = c["breathing_m3_per_hour"]

    # Far field: Wells-Riley steady state, C = q / (V * total loss rate)
    far = 0.0
    if indoors:
        volume = room_area_m2 * c["ceiling_height_m"]
        loss = c["air_changes_per_hour"] + c["deposition_per_hour"] + c["inactivation_per_hour"]
        far = q / (volume * loss) * B * hours

    # Near field: jet volume flow grows linearly with distance -> concentration ~ 1/d
    d = max(distance_m, 0.1)
    dilution = max(1.0, c["jet_entrainment"] * d / c["mouth_diameter_m"])
    near = c["face_to_face_fraction"] * q / (B * dilution) * B * hours
    if not indoors:
        near *= c["outdoor_nearfield_factor"]

    return far + near


def incubation_cdf(days, c=CONFIG):
    """P(symptoms would have started by `days` | infected and symptomatic)."""
    if days <= 0:
        return 0.0
    mu = math.log(c["incubation_median_days"])
    sigma = math.log(c["incubation_dispersion"])
    return 0.5 * (1 + math.erf((math.log(days) - mu) / (sigma * math.sqrt(2))))


def update_flu_probability(
    p_contact, prior, duration_min, distance_m, room_area_m2, indoors,
    contact_stage, days_since_meeting, outdoor_rh_percent,
    outdoor_temp_c=None, symptoms_so_far=False, c=CONFIG,
):
    """Return (new_probability, details dict). Feed new_probability back in as `prior` next time."""
    temp = c["default_outdoor_temp_c"] if outdoor_temp_c is None else outdoor_temp_c
    infectiousness = stage_infectiousness(contact_stage)
    hum = humidity_multiplier(outdoor_rh_percent, temp, c)
    dose = inhaled_dose(duration_min, distance_m, room_area_m2, indoors, infectiousness, hum, c)
    p_transmit = 1 - math.exp(-dose)                 # given contact infected
    p_from_meeting = p_contact * p_transmit           # unconditional
    p_after_meeting = 1 - (1 - prior) * (1 - p_from_meeting)

    # Evidence from time elapsed without symptoms (applies to the new-infection branch only;
    # `prior` is assumed to already reflect your symptom status).
    if symptoms_so_far:
        posterior = p_after_meeting  # symptoms are non-specific: get tested rather than trust a model
        likelihood_no_sx = None
    else:
        likelihood_no_sx = 1 - c["p_symptomatic"] * incubation_cdf(days_since_meeting, c)
        new_branch = (1 - prior) * p_from_meeting * likelihood_no_sx
        not_infected = (1 - prior) * (1 - p_from_meeting)
        posterior = (prior + new_branch) / (prior + new_branch + not_infected)

    details = {
        "contact_infectiousness_rel": infectiousness,
        "specific_humidity_g_per_kg": specific_humidity(outdoor_rh_percent, temp) * 1000,
        "humidity_multiplier": hum,
        "inhaled_quanta_if_contact_infected": dose,
        "p_transmit_if_contact_infected": p_transmit,
        "p_infected_by_this_meeting": p_from_meeting,
        "p_before_symptom_evidence": p_after_meeting,
        "p_no_symptoms_yet_if_infected_here": likelihood_no_sx,
    }
    return posterior, details


def main():
    ap = argparse.ArgumentParser(description="Update your probability of having flu after a meeting.")
    ap.add_argument("--p-contact", type=float, required=True, help="P: probability the other person has flu (0-1)")
    ap.add_argument("--prior", type=float, required=True, help="your previous probability of flu (0-1)")
    ap.add_argument("--duration", type=float, required=True, help="meeting duration, minutes")
    ap.add_argument("--distance", type=float, required=True, help="typical distance between you, metres")
    ap.add_argument("--room-area", type=float, default=30.0, help="room floor area, m^2 (ignored outdoors)")
    ap.add_argument("--setting", choices=["indoors", "outdoors"], required=True)
    ap.add_argument("--stage", required=True,
                    help="contact's days since symptom onset (e.g. -1, 0, 2.5) or one of: "
                         + ", ".join(STAGE_ALIASES))
    ap.add_argument("--days-since", type=float, required=True, help="days since the meeting")
    ap.add_argument("--humidity", type=float, required=True, help="outdoor relative humidity, %%")
    ap.add_argument("--temp", type=float, default=None, help="outdoor temperature, C (default 10)")
    ap.add_argument("--symptoms", action="store_true", help="you already have flu-like symptoms")
    a = ap.parse_args()

    p, d = update_flu_probability(
        a.p_contact, a.prior, a.duration, a.distance, a.room_area, a.setting == "indoors",
        a.stage, a.days_since, a.humidity, a.temp, a.symptoms,
    )
    for k, v in d.items():
        print(f"  {k:38s} {v if v is None else round(v, 4)}")
    print(f"\nNew probability you have flu: {p:.2%}")
    if a.symptoms:
        print("(You reported symptoms: the model can't distinguish flu from other illness - consider a test.)")


if __name__ == "__main__":
    main()
