# Fluniversity — PRD (snapshot)

> **Source of truth:** the team planning doc on Google Docs (ask a teammate for the link).
> This file is a snapshot from 2026-10-17 so agents without Docs access can read the spec.
> If the two disagree, the Google Doc wins. Please update this file when it changes.

## Problem

We want to minimize the spread of flu and other diseases on college campuses.

## Issues with existing apps

1. **Too few users.** The community isn't small enough for a large share of people to use the app
   consistently.
   - Address this by pitching it to a smaller community, especially a small university.
2. **Detection is unreliable.** Ultrasound and Bluetooth detection sometimes fail, especially on
   offline phones.
   - Use optional GPS tracking through Find My or Vaden.
3. **No clear advice.** Existing apps don't calculate risk or probability. They show information you
   can't act on (e.g. "one of your degree-one connections has the flu").

## Functionalities

### 1. Proximity alerts (primary)

Notify a person when they come within N feet of someone who is, or might be, infected: "Someone
within N feet is risky. Please leave the premises." The alert could also give the probability of
infection if they stay, or suggest precautions: wear a mask, be careful, eat vitamin C, or other
general health advice.

- This stops diseases from spreading further and lets individuals take precautions.
- Names and locations are not shared. Anonymity leads to more honest records of illness, because
  otherwise people may be too ashamed to say they're sick.
- Detection could use location data, UWB, or rotating keys.

### 2. Infection heat maps on campus (secondary)

Include a warning that the map may be inaccurate, since not everyone shares their status with the
app.

1. Show where infections are concentrated (buildings and locations).
2. Warn users when they enter such a location.
3. Run simulations to generate the heat map. Some agents are altruistic and some are not.
4. Predict future hot spots with a probability model plus the locations of those people.
5. Collect GPS locations from people who opt in.
6. Model it on South Korea's COVID heat maps.
   - Privacy risks:
     https://www.medicalindependent.ie/life/the-dorsal-view/an-embarrassment-of-data-riches-covid-19-tracking-apps-in-south-korea/

### 3. Probability of infection → advice

Use models to estimate each user's probability of infection, then tell them what to do.

1. Record all interactions between people. If person A interacts with person B under certain
   conditions, and A has a certain probability of having the disease, calculate B's probability.
   - Should we treat interactions upstream of an infection differently?
   - Use per-contact probabilities?
   - Weight contacts by duration and proximity?
2. Mark people who have the disease. People can mark themselves as possibly sick.
   - Someone who has been tested is more reliable.
   - A model compares a person's likelihood of being sick with their self-reported status to catch
     false reports. People can also mark someone else as possibly sick.

## Demo

1. **What it looks like**
   - Run the simulation while showing one or more agents' user interfaces (and how each agent acts)
     next to a bird's-eye view of all the agents.
   - Show that Bluetooth, ultrasound, or GPS creates alerts and adjusts probabilities (live demo on
     two phones).
2. **The math behind it**
   - Graph theory
   - Probability models
   - Simulations
