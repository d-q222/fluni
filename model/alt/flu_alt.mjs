// flu_alt.mjs — independent flu-probability update model.
//
// Dependency-free ES module. No imports, runs in Node and in the browser.
//
// What it does, in one sentence: each meeting with a possibly-infectious person
// produces an inhaled *quanta dose* (near-field jet + transient far-field room
// air, humidity-dependent inactivation, stage-dependent emission); the dose
// becomes an infection probability through the Wells-Riley exponential
// dose-response; that probability moves you from S into E in an S/E/I/R state
// vector, which is then propagated forward by "days since the meeting" so that
// P(flu now) means *currently infected*, not *ever infected*.
//
// See README.md for equations, constants and sources.

// ---------------------------------------------------------------------------
// Constants (every value is sourced in README.md)
// ---------------------------------------------------------------------------

export const C = {
  // --- emission ---------------------------------------------------------
  // Quanta/h emitted by one infectious adult, talking, at peak shedding.
  // Calibrated (see README "Calibration"): household/roommate exposure over a
  // whole illness lands at ~20% secondary attack rate.
  EQ_PEAK_TALKING: 1.5,
  // Breathing-only emission as a fraction of talking. Buonanno et al. 2020
  // give 0.36 vs 4.9 quanta/h (ratio 0.073) for SARS-CoV-2 at light activity;
  // we use a slightly conservative 0.12.
  BREATHING_FRACTION: 0.12,

  // --- inhalation -------------------------------------------------------
  BREATHING_RATE: 0.52, // m^3/h, sedentary/light adult (US EPA EFH, ~8.7 L/min)

  // --- room / removal ---------------------------------------------------
  CEILING_HEIGHT: 2.7, // m, default when only a floor area is given
  ACH_DEFAULT: 3.0, // air changes/h, typical mechanically ventilated room
  K_DEPOSITION: 0.3, // /h, gravitational settling of 1-3 um respiratory aerosol

  // Humidity-dependent viral inactivation, /h. Noti et al. 2013: ~73% of
  // infectivity survives 60 min at RH <= 23% (k ~ 0.31/h), ~18% at RH >= 43%
  // (k ~ 1.7/h). Logistic ramp between those two anchors.
  K_INACT_DRY: 0.3,
  K_INACT_HUMID: 1.8,
  K_INACT_RH50: 35, // % RH at the midpoint
  K_INACT_WIDTH: 5, // % RH logistic width

  // Host-susceptibility modifier vs absolute humidity (Shaman & Kohn 2009:
  // low AH raises transmission efficiency beyond what survival alone explains).
  AH_REF: 7.0, // g/m^3, reference absolute humidity
  AH_SUSC_COEFF: 0.02, // per g/m^3
  AH_SUSC_MIN: 0.7,
  AH_SUSC_MAX: 1.5,

  // --- near field -------------------------------------------------------
  // Effective entrained-air dilution flow in the exhaled jet at 1 m, m^3/h.
  // Exhaled minute volume is ~0.5 m^3/h, so 25 m^3/h is a ~50x dilution at 1 m.
  Q_NEAR_1M: 25,
  NEAR_REF_DISTANCE: 1.0, // m
  NEAR_MIN_DISTANCE: 0.3, // m, inverse-square cap (faces cannot overlap)
  NEAR_CUTOFF: 3.0, // m, beyond this the jet is indistinguishable from room air

  // --- outdoors ---------------------------------------------------------
  // Outdoors the far field is gone (unbounded dilution) and the jet itself is
  // broken up by wind and cross-breezes.
  OUTDOOR_NEAR_FACTOR: 0.25,

  // --- natural history (per day) ---------------------------------------
  LATENT_MEAN_DAYS: 1.0, // infection -> infectious (Carrat 2008: shedding at 0.5-1 d)
  INFECTIOUS_MEAN_DAYS: 4.8, // Carrat 2008: mean shedding duration 4.8 d
  INCUBATION_MEAN_DAYS: 1.4, // Lessler 2009, for reference / stage mapping
  ERLANG_SHAPE: 2, // 2 stages each for E and I (less tail than exponential)

  // Indoor air temperature, used to convert outdoor absolute humidity into the
  // indoor RH the aerosol actually experiences.
  INDOOR_TEMP_C: 20,
  OUTDOOR_TEMP_C_DEFAULT: 10,
};

// Relative viral emission vs day of illness (0 = symptom onset day).
// Shape from Carrat 2008 (challenge studies: shedding peaks ~day 2 post
// challenge, mean duration 4.8 d) and Lau 2010 (natural infection: most
// shedding in the first 2-3 days after onset, a small presymptomatic share).
const SHEDDING_KNOTS = [
  [-2, 0.10],
  [-1, 0.45],
  [0, 1.00],
  [1, 0.95],
  [2, 0.70],
  [3, 0.45],
  [4, 0.28],
  [5, 0.15],
  [6, 0.08],
  [7, 0.03],
  [8, 0.0],
];

// Emission averaged over an illness, used when the stage is unknown. This is
// the mean of the knots over days -1..6, i.e. what you get if the contact is
// equally likely to be on any infectious day.
export const STAGE_UNKNOWN_FACTOR = (() => {
  const days = [-1, 0, 1, 2, 3, 4, 5, 6];
  return days.reduce((s, d) => s + sheddingFactor(d), 0) / days.length;
})();

const STAGE_LABELS = {
  unknown: null, // resolved to STAGE_UNKNOWN_FACTOR
  presymptomatic: -1,
  onset: 0,
  early: 1,
  peak: 0,
  mid: 3,
  late: 5,
  recovered: 9,
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const clamp = (x, lo, hi) => (x < lo ? lo : x > hi ? hi : x);
const clampProb = (x) => clamp(Number(x), 0, 1);

function requireFinite(name, v) {
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    throw new TypeError(`${name} must be a finite number, got ${JSON.stringify(v)}`);
  }
  return v;
}

function requireNonNegative(name, v) {
  requireFinite(name, v);
  if (v < 0) throw new RangeError(`${name} must be >= 0, got ${v}`);
  return v;
}

function requirePositive(name, v) {
  requireFinite(name, v);
  if (v <= 0) throw new RangeError(`${name} must be > 0, got ${v}`);
  return v;
}

/** Saturation vapour pressure of water, Pa (Tetens, over liquid water). */
export function satVapPressurePa(tempC) {
  return 610.78 * Math.exp((17.27 * tempC) / (tempC + 237.3));
}

/** Absolute humidity, g/m^3, from relative humidity (%) and temperature (C). */
export function absoluteHumidity(rhPercent, tempC) {
  const e = (clamp(rhPercent, 0, 100) / 100) * satVapPressurePa(tempC);
  return (2.16674 * e) / (tempC + 273.15);
}

/** RH (%) of air with this absolute humidity once warmed to tempC. */
export function rhFromAbsoluteHumidity(ahGramsPerM3, tempC) {
  const e = (ahGramsPerM3 * (tempC + 273.15)) / 2.16674;
  return clamp((100 * e) / satVapPressurePa(tempC), 0, 100);
}

/** Virus inactivation rate, /h, as a function of the RH the aerosol sees. */
export function inactivationRate(rhPercent) {
  const x = (clamp(rhPercent, 0, 100) - C.K_INACT_RH50) / C.K_INACT_WIDTH;
  const s = 1 / (1 + Math.exp(-x));
  return C.K_INACT_DRY + (C.K_INACT_HUMID - C.K_INACT_DRY) * s;
}

/** Host-susceptibility multiplier from absolute humidity (dimensionless). */
export function susceptibilityFactor(ahGramsPerM3) {
  const f = Math.exp(-C.AH_SUSC_COEFF * (ahGramsPerM3 - C.AH_REF));
  return clamp(f, C.AH_SUSC_MIN, C.AH_SUSC_MAX);
}

/** Relative emission for a given day of illness (0 = symptom onset). */
export function sheddingFactor(dayOfIllness) {
  const d = dayOfIllness;
  const k = SHEDDING_KNOTS;
  if (d <= k[0][0]) return d < k[0][0] ? 0 : k[0][1];
  if (d >= k[k.length - 1][0]) return 0;
  for (let i = 0; i < k.length - 1; i++) {
    if (d >= k[i][0] && d <= k[i + 1][0]) {
      const t = (d - k[i][0]) / (k[i + 1][0] - k[i][0]);
      return k[i][1] + t * (k[i + 1][1] - k[i][1]);
    }
  }
  return 0;
}

/** Resolve the `stage` input (number of days, label, or null) to a factor. */
export function stageFactor(stage) {
  if (stage === undefined || stage === null || stage === 'unknown') {
    return STAGE_UNKNOWN_FACTOR;
  }
  if (typeof stage === 'string') {
    const key = stage.trim().toLowerCase();
    if (!(key in STAGE_LABELS)) {
      throw new RangeError(
        `unknown stage "${stage}"; use a day number or one of ${Object.keys(STAGE_LABELS).join(', ')}`
      );
    }
    const day = STAGE_LABELS[key];
    return day === null ? STAGE_UNKNOWN_FACTOR : sheddingFactor(day);
  }
  requireFinite('stage', stage);
  return sheddingFactor(stage);
}

/**
 * Near-field excess, relative to the 1 m reference, from an inverse-square
 * expanding-jet dilution with a smooth cutoff where it joins the far field.
 */
export function nearFieldFactor(distanceM) {
  const d = Math.max(distanceM, C.NEAR_MIN_DISTANCE);
  if (d >= C.NEAR_CUTOFF) return 0;
  const r = C.NEAR_REF_DISTANCE;
  return (r / d) ** 2 - (r / C.NEAR_CUTOFF) ** 2;
}

// ---------------------------------------------------------------------------
// Per-meeting dose
// ---------------------------------------------------------------------------

/**
 * Everything about a meeting except the time integral. Split out so that the
 * pair-day helper can treat several rows as one continuous occupancy of the
 * same room instead of restarting the transient far field for every row.
 */
function meetingTerms(m) {
  const durationMin = requireNonNegative('duration', m.duration ?? 0);
  const durationH = durationMin / 60;
  const distance = requirePositive('distance', m.distance ?? 1);
  const outdoors = Boolean(m.outdoors);
  const talking = m.talking === undefined ? true : Boolean(m.talking);
  const humidity = clamp(requireNonNegative('humidity', m.humidity ?? 50), 0, 100);
  const outdoorTemp = requireFinite('temp', m.temp ?? C.OUTDOOR_TEMP_C_DEFAULT);
  const pb = requirePositive('breathingRate', m.breathingRate ?? C.BREATHING_RATE);
  const indoorTemp = requireFinite('indoorTemp', m.indoorTemp ?? C.INDOOR_TEMP_C);

  // Humidity: the input is *outdoor* RH. Outdoor absolute humidity is what is
  // conserved when air is drawn indoors and heated, so indoors the aerosol sees
  // the RH that outdoor AH gives at indoor temperature (Shaman & Kohn 2009).
  const ah = absoluteHumidity(humidity, outdoorTemp);
  const rhSeen = outdoors ? humidity : rhFromAbsoluteHumidity(ah, indoorTemp);
  const kInact = inactivationRate(rhSeen);
  const susc = susceptibilityFactor(ah);
  const stageF = stageFactor(m.stage);
  const eq = C.EQ_PEAK_TALKING * stageF * (talking ? 1 : C.BREATHING_FRACTION);

  let volume = null;
  let removal = null;
  if (!outdoors) {
    if (m.roomVolume !== undefined) {
      volume = requirePositive('roomVolume', m.roomVolume);
    } else {
      const area = requirePositive('room', m.room ?? 30);
      const h = requirePositive('ceilingHeight', m.ceilingHeight ?? C.CEILING_HEIGHT);
      volume = area * h;
    }
    const ach = requireNonNegative('ach', m.ach ?? C.ACH_DEFAULT);
    removal = ach + C.K_DEPOSITION + kInact;
  }

  // Near field is linear in time, so it needs no special pair-day handling.
  let nearPerHour = (pb * eq * nearFieldFactor(distance)) / C.Q_NEAR_1M;
  if (outdoors) nearPerHour *= C.OUTDOOR_NEAR_FACTOR;

  return {
    durationH, distance, outdoors, talking, pb, eq, stageF,
    ah, rhSeen, kInact, susc, volume, removal, nearPerHour,
  };
}

/**
 * Time integral of the transient well-mixed far field: a step source of `eq`
 * quanta/h into initially clean air of `volume` m^3 with total removal rate
 * `removal` /h, inhaled at `pb` m^3/h for `durationH` hours.
 *   C(t) = eq/(removal*V) * (1 - exp(-removal*t))
 *   dose = pb * integral_0^D C dt
 */
function farFieldDose(eq, durationH, volume, removal, pb) {
  if (!(eq > 0) || !(durationH > 0)) return 0;
  const integral =
    (eq / (removal * volume)) *
    (durationH - (1 - Math.exp(-removal * durationH)) / removal);
  return pb * integral;
}

/**
 * Inhaled quanta dose from one meeting, *conditional on the other person being
 * infectious*. Their P does not enter here; it is applied once per person-day.
 *
 * @param {object} m
 * @param {number} m.duration   minutes of contact
 * @param {number} m.distance   metres between faces
 * @param {number} [m.room]     room floor area, m^2 (ignored outdoors)
 * @param {number} [m.roomVolume] room volume, m^3 (overrides room * height)
 * @param {number} [m.ceilingHeight] m, default 2.7
 * @param {boolean} [m.outdoors] default false
 * @param {number|string} [m.stage] their day of illness (0 = onset) or label
 * @param {number} [m.humidity] outdoor relative humidity, %
 * @param {number} [m.temp]     outdoor air temperature, C
 * @param {boolean} [m.talking] default true (see README)
 * @param {number} [m.ach]      air changes/h override
 * @param {number} [m.breathingRate] my inhalation rate, m^3/h
 * @returns {{lambda:number, near:number, far:number, detail:object}}
 */
export function doseForMeeting(m = {}) {
  const t = meetingTerms(m);
  const near = t.nearPerHour * t.durationH;
  const far = t.outdoors
    ? 0
    : farFieldDose(t.eq, t.durationH, t.volume, t.removal, t.pb);
  return {
    lambda: (near + far) * t.susc,
    near: near * t.susc,
    far: far * t.susc,
    detail: {
      eq: t.eq,
      stageFactor: t.stageF,
      talking: t.talking,
      durationH: t.durationH,
      distance: t.distance,
      outdoors: t.outdoors,
      absoluteHumidity: t.ah,
      rhSeen: t.rhSeen,
      kInact: t.kInact,
      susceptibility: t.susc,
      roomVolume: t.volume,
      removalRate: t.removal,
      nearFieldFactor: nearFieldFactor(t.distance),
    },
  };
}

// ---------------------------------------------------------------------------
// Pair-day aggregation
// ---------------------------------------------------------------------------

/**
 * Sum the dose over several contacts with the SAME person on the SAME day, then
 * apply that person's P once. Summing the dose (rather than compounding
 * 1 - (1 - p)^n per row) is the point: ten 5-minute rows are one 50-minute
 * exposure, and the person is either infectious for all of them or none.
 *
 * @param {Array<object>} rows meetings; `p` is read from the first row that has
 *   one (they are the same person, so they share a P).
 * @returns {{lambda:number, pOther:number, pInfectedIfSusceptible:number,
 *            pInfectedByMeeting:number, near:number, far:number, rows:number}}
 */
export function lambdaForContacts(rows) {
  if (!Array.isArray(rows)) throw new TypeError('lambdaForContacts expects an array of rows');
  let near = 0;
  let pOther = null;
  // Rows that happened in the same room are one continuous occupancy: the
  // transient far field must not restart its clock for every 5-minute row, or
  // a day logged in small slices looks safer than the same day logged whole.
  const rooms = new Map();
  let susc = 1;
  for (const row of rows) {
    const t = meetingTerms(row);
    susc = t.susc;
    near += t.nearPerHour * t.durationH;
    if (!t.outdoors && t.durationH > 0) {
      const key = `${t.volume}|${t.removal}|${t.pb}`;
      const g = rooms.get(key) || {
        volume: t.volume,
        removal: t.removal,
        pb: t.pb,
        hours: 0,
        eqHours: 0,
      };
      g.hours += t.durationH;
      g.eqHours += t.eq * t.durationH; // emission-weighted
      rooms.set(key, g);
    }
    if (pOther === null && row && row.p !== undefined && row.p !== null) {
      pOther = clampProb(row.p);
    }
  }
  if (pOther === null) pOther = 1;
  let far = 0;
  for (const g of rooms.values()) {
    const eqMean = g.hours > 0 ? g.eqHours / g.hours : 0;
    far += farFieldDose(eqMean, g.hours, g.volume, g.removal, g.pb);
  }
  near *= susc;
  far *= susc;
  const lambda = near + far;
  const pIfInfectious = 1 - Math.exp(-lambda);
  return {
    lambda,
    near,
    far,
    pOther,
    pInfectedIfSusceptible: pOther * pIfInfectious,
    pInfectedByMeeting: pOther * pIfInfectious,
    rows: rows.length,
  };
}

// ---------------------------------------------------------------------------
// S / E / I / R state propagation
// ---------------------------------------------------------------------------

// Internal vector: [S, E1, E2, I1, I2, R]
const sigma = C.ERLANG_SHAPE / C.LATENT_MEAN_DAYS; // per day, per E stage
const gamma = C.ERLANG_SHAPE / C.INFECTIOUS_MEAN_DAYS; // per day, per I stage

function deriv(y) {
  const [, e1, e2, i1, i2] = y;
  return [
    0, // no background community hazard in this model (see README)
    -sigma * e1,
    sigma * e1 - sigma * e2,
    sigma * e2 - gamma * i1,
    gamma * i1 - gamma * i2,
    gamma * i2,
  ];
}

function addScaled(a, b, s) {
  return a.map((v, i) => v + s * b[i]);
}

/** Propagate the internal state vector forward `days` days (RK4). */
function propagate(y0, days) {
  requireNonNegative('days', days);
  if (days === 0) return y0.slice();
  const steps = Math.max(1, Math.ceil(days / 0.01));
  const dt = days / steps;
  let y = y0.slice();
  for (let s = 0; s < steps; s++) {
    const k1 = deriv(y);
    const k2 = deriv(addScaled(y, k1, dt / 2));
    const k3 = deriv(addScaled(y, k2, dt / 2));
    const k4 = deriv(addScaled(y, k3, dt));
    y = y.map(
      (v, i) => v + (dt / 6) * (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i])
    );
  }
  // Guard against tiny negative values / drift from round-off.
  y = y.map((v) => (v < 0 ? 0 : v));
  const total = y.reduce((a, b) => a + b, 0);
  return total > 0 ? y.map((v) => v / total) : y;
}

/**
 * Turn a scalar "probability I have the flu" into a state vector. Someone who
 * currently has flu is more likely to be in the longer infectious phase than in
 * the short latent one, so the scalar is split by the mean sojourn times.
 */
export function statesFromPrior(prior, priorR = 0) {
  const p = clampProb(prior);
  const r = clampProb(priorR);
  const infected = Math.min(p, 1);
  const recovered = Math.min(r, Math.max(0, 1 - infected));
  const s = Math.max(0, 1 - infected - recovered);
  const eShare =
    C.LATENT_MEAN_DAYS / (C.LATENT_MEAN_DAYS + C.INFECTIOUS_MEAN_DAYS);
  const e = infected * eShare;
  const i = infected - e;
  return [s, e / 2, e / 2, i / 2, i / 2, recovered];
}

function summarise(y) {
  const [s, e1, e2, i1, i2, r] = y;
  const E = e1 + e2;
  const I = i1 + i2;
  return {
    states: { S: s, E, I, R: r },
    pNow: E + I,
    pInfectious: I,
  };
}

// ---------------------------------------------------------------------------
// Public update
// ---------------------------------------------------------------------------

/**
 * Update the probability that I have the flu after a meeting (or a set of
 * contacts with one person on one day), then age the result by `days`.
 *
 * Inputs (all optional except what a meeting needs):
 *   prior        my previous P(have the flu), 0..1              default 0
 *   priorR       my P(already recovered/immune), 0..1           default 0
 *   priorStates  {S,E,I,R} instead of prior/priorR
 *   p            their P(have the flu), 0..1                   default 1
 *   duration     minutes
 *   distance     metres
 *   room         floor area m^2 (or roomVolume m^3)
 *   outdoors     boolean                                        default false
 *   stage        their day of illness (0 = onset) or label      default unknown
 *   days         days since the meeting                         default 0
 *   humidity     outdoor RH %                                   default 50
 *   temp         outdoor temperature C                          default 10
 *   talking      boolean                                        default TRUE
 *   contacts     array of meeting rows with the same person on the same day
 *
 * @returns {{lambda:number, pInfectedByMeeting:number, pNow:number,
 *            states:{S:number,E:number,I:number,R:number}, ...}}
 */
export function update(inputs = {}) {
  if (inputs === null || typeof inputs !== 'object') {
    throw new TypeError('update() expects an object of inputs');
  }

  const rows = inputs.contacts
    ? inputs.contacts.map((r) => ({ ...inputs, ...r, contacts: undefined }))
    : [{ ...inputs }];
  const agg = lambdaForContacts(rows);
  const pOther = inputs.p === undefined || inputs.p === null ? agg.pOther : clampProb(inputs.p);
  const pIfInfectious = 1 - Math.exp(-agg.lambda);
  const pTransmit = pOther * pIfInfectious; // given I was susceptible

  // Where am I before the meeting?
  let y;
  if (inputs.priorStates) {
    const ps = inputs.priorStates;
    const s = clampProb(ps.S ?? 0);
    const e = clampProb(ps.E ?? 0);
    const i = clampProb(ps.I ?? 0);
    const r = clampProb(ps.R ?? 0);
    const tot = s + e + i + r;
    if (tot <= 0) throw new RangeError('priorStates must contain some probability mass');
    y = [s / tot, e / (2 * tot), e / (2 * tot), i / (2 * tot), i / (2 * tot), r / tot];
  } else {
    y = statesFromPrior(inputs.prior ?? 0, inputs.priorR ?? 0);
  }

  // The meeting moves a fraction of the susceptible mass into E.
  const sBefore = y[0];
  const newlyInfected = sBefore * pTransmit;
  y[0] = sBefore - newlyInfected;
  y[1] += newlyInfected; // enters the first latent stage

  const days = requireNonNegative('days', inputs.days ?? 0);
  const yAfter = propagate(y, days);
  const out = summarise(yAfter);

  return {
    lambda: agg.lambda,
    lambdaNear: agg.near,
    lambdaFar: agg.far,
    pOther,
    pInfectedIfSusceptible: pIfInfectious,
    pInfectedByMeeting: pTransmit,
    newlyInfected,
    pNow: out.pNow,
    pInfectious: out.pInfectious,
    states: out.states,
    days,
    detail: rows.length === 1 ? doseForMeeting(rows[0]).detail : { rows: rows.length },
  };
}

/** Propagate a state vector forward without any new exposure. */
export function age(statesOrPrior, days) {
  const y =
    typeof statesOrPrior === 'number'
      ? statesFromPrior(statesOrPrior)
      : (() => {
          const ps = statesOrPrior;
          const s = clampProb(ps.S ?? 0);
          const e = clampProb(ps.E ?? 0);
          const i = clampProb(ps.I ?? 0);
          const r = clampProb(ps.R ?? 0);
          const tot = s + e + i + r || 1;
          return [s / tot, e / (2 * tot), e / (2 * tot), i / (2 * tot), i / (2 * tot), r / tot];
        })();
  return summarise(propagate(y, days));
}

/**
 * Many person-days in order: `groups` is an array of
 * { contacts: [rows], p, daysUntilNext }, applied in sequence so the state
 * vector carries across days. Returned value is the final summary.
 */
export function updateSequence(groups, opts = {}) {
  if (!Array.isArray(groups)) throw new TypeError('updateSequence expects an array');
  let y = opts.priorStates
    ? (() => {
        const ps = opts.priorStates;
        const tot = (ps.S ?? 0) + (ps.E ?? 0) + (ps.I ?? 0) + (ps.R ?? 0) || 1;
        return [
          (ps.S ?? 0) / tot,
          (ps.E ?? 0) / (2 * tot),
          (ps.E ?? 0) / (2 * tot),
          (ps.I ?? 0) / (2 * tot),
          (ps.I ?? 0) / (2 * tot),
          (ps.R ?? 0) / tot,
        ];
      })()
    : statesFromPrior(opts.prior ?? 0, opts.priorR ?? 0);
  let lambdaTotal = 0;
  const steps = [];
  for (const g of groups) {
    const rows = (g.contacts || []).map((r) => ({ ...(g.defaults || {}), ...r }));
    const agg = lambdaForContacts(rows.map((r) => ({ p: g.p, ...r })));
    const pOther = g.p === undefined ? agg.pOther : clampProb(g.p);
    const pTransmit = pOther * (1 - Math.exp(-agg.lambda));
    const newly = y[0] * pTransmit;
    y[0] -= newly;
    y[1] += newly;
    lambdaTotal += agg.lambda;
    y = propagate(y, g.daysUntilNext ?? 0);
    steps.push({ lambda: agg.lambda, pTransmit, ...summarise(y) });
  }
  return { lambdaTotal, steps, ...summarise(y) };
}

export default { update, lambdaForContacts, doseForMeeting, age, updateSequence, C };
