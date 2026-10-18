// model/alt/test.mjs — plain-assert tests for the alt flu model.
//   node model/alt/test.mjs
//
// Calibration targets are stated inline with their sources (see README.md).

import assert from 'node:assert/strict';
import {
  update,
  age,
  updateSequence,
  lambdaForContacts,
  doseForMeeting,
  sheddingFactor,
  stageFactor,
  nearFieldFactor,
  absoluteHumidity,
  rhFromAbsoluteHumidity,
  inactivationRate,
  statesFromPrior,
  STAGE_UNKNOWN_FACTOR,
  C,
} from './flu_alt.mjs';

let passed = 0;
const failures = [];
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`ok   ${name}`);
  } catch (err) {
    failures.push([name, err]);
    console.log(`FAIL ${name}\n     ${err.message}`);
  }
}
const between = (x, lo, hi, what) =>
  assert.ok(x >= lo && x <= hi, `${what}: ${x} not in [${lo}, ${hi}]`);

// Shared, realistic winter weather: 60% RH at 10 C outdoors.
const WX = { humidity: 60, temp: 10 };

// ---------------------------------------------------------------------------
// Calibration
// ---------------------------------------------------------------------------

test('15-min close conversation indoors at peak shedding is ~0.3-3%', () => {
  const r = update({
    prior: 0,
    p: 1,
    duration: 15,
    distance: 1,
    room: 30,
    stage: 0,
    days: 0,
    ...WX,
  });
  between(r.pInfectedByMeeting, 0.003, 0.03, 'per-contact P');
  // Near field should dominate a short close contact.
  assert.ok(r.lambdaNear > 5 * r.lambdaFar, 'near field should dominate at 1 m / 15 min');
});

test('roommate of a confirmed case over the whole illness is 10-25%', () => {
  // Shared dorm room, 15 m^2, 2.7 m ceiling, ACH 2 (residential).
  // Each day: 8 h asleep at 1.5 m (not talking) + 4 h awake at 2 m talking.
  // Their illness runs day -1 .. day 5 relative to symptom onset.
  const room = { room: 15, ceilingHeight: 2.7, ach: 2, ...WX };
  const groups = [];
  for (let day = -1; day <= 5; day++) {
    groups.push({
      p: 1,
      daysUntilNext: 1,
      contacts: [
        { ...room, stage: day, duration: 8 * 60, distance: 1.5, talking: false },
        { ...room, stage: day, duration: 4 * 60, distance: 2.0, talking: true },
      ],
    });
  }
  const r = updateSequence(groups, { prior: 0 });
  const everInfected = 1 - r.states.S;
  between(everInfected, 0.10, 0.25, 'household secondary attack rate');
});

test('1 h lecture at 5 m is small (<1%)', () => {
  const r = update({
    prior: 0,
    p: 1,
    duration: 60,
    distance: 5,
    room: 200,
    ceilingHeight: 3,
    ach: 4,
    stage: 0,
    ...WX,
  });
  assert.equal(r.lambdaNear, 0, 'no near field beyond the 3 m cutoff');
  between(r.pInfectedByMeeting, 0, 0.01, 'lecture P');
  assert.ok(r.pInfectedByMeeting > 0, 'but not exactly zero: the far field is real');
});

test('5 min outdoors at 2 m is negligible (<0.05%)', () => {
  const r = update({
    prior: 0,
    p: 1,
    duration: 5,
    distance: 2,
    outdoors: true,
    stage: 0,
    ...WX,
  });
  assert.equal(r.lambdaFar, 0, 'no far field outdoors');
  between(r.pInfectedByMeeting, 0, 0.0005, 'outdoor P');
});

test('outdoors is strictly safer than the same meeting indoors', () => {
  const base = { p: 1, duration: 30, distance: 1.5, room: 30, stage: 0, ...WX };
  const inside = update({ ...base });
  const outside = update({ ...base, outdoors: true });
  assert.ok(outside.lambda < inside.lambda, 'outdoors should be lower');
});

// ---------------------------------------------------------------------------
// Monotonicity
// ---------------------------------------------------------------------------

test('humidity is monotonically protective', () => {
  const base = { p: 1, duration: 60, distance: 1, room: 30, stage: 0, temp: 10 };
  let prev = Infinity;
  for (const humidity of [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]) {
    const r = update({ ...base, humidity });
    assert.ok(r.lambda < prev, `lambda should fall as humidity rises (at ${humidity}%)`);
    prev = r.lambda;
  }
  // and the effect should be material, not cosmetic
  const dry = update({ ...base, humidity: 15 }).lambda;
  const humid = update({ ...base, humidity: 90 }).lambda;
  assert.ok(dry / humid > 1.1, `dry/humid ratio only ${dry / humid}`);
});

test('dose rises with duration and falls with distance', () => {
  const base = { p: 1, distance: 1, room: 30, stage: 0, ...WX };
  let prev = -1;
  for (const duration of [1, 5, 15, 30, 60, 120]) {
    const l = doseForMeeting({ ...base, duration }).lambda;
    assert.ok(l > prev, 'dose must rise with duration');
    prev = l;
  }
  let last = Infinity;
  for (const distance of [0.5, 1, 1.5, 2, 2.5, 2.99]) {
    const l = doseForMeeting({ ...base, duration: 30, distance }).lambda;
    assert.ok(l < last, `dose must fall with distance (at ${distance} m)`);
    last = l;
  }
  // Past the near-field cutoff only the well-mixed far field remains, so the
  // dose is flat in distance - that is the two-zone model's whole point.
  const at3 = doseForMeeting({ ...base, duration: 30, distance: 3 }).lambda;
  const at10 = doseForMeeting({ ...base, duration: 30, distance: 10 }).lambda;
  assert.ok(at3 < last, 'the cutoff must not create a jump upward');
  assert.ok(Math.abs(at3 - at10) < 1e-15, 'far field does not depend on distance');
});

test('far field is transient: doubling a short meeting more than doubles the far-field dose', () => {
  const base = { p: 1, distance: 5, room: 100, stage: 0, ...WX }; // far field only
  const a = doseForMeeting({ ...base, duration: 10 }).far;
  const b = doseForMeeting({ ...base, duration: 20 }).far;
  assert.ok(b > 2 * a, 'short-meeting far field should be super-linear in time');
  // and over long meetings it becomes linear (steady state)
  const c = doseForMeeting({ ...base, duration: 600 }).far;
  const d = doseForMeeting({ ...base, duration: 1200 }).far;
  assert.ok(d < 2.05 * c, 'long-meeting far field should be ~linear');
});

test('talking defaults to true and raises the dose', () => {
  const base = { p: 1, duration: 30, distance: 1, room: 30, stage: 0, ...WX };
  const dflt = doseForMeeting(base).lambda;
  const talk = doseForMeeting({ ...base, talking: true }).lambda;
  const quiet = doseForMeeting({ ...base, talking: false }).lambda;
  assert.equal(dflt, talk, 'talking must default to true');
  assert.ok(quiet < talk / 5, 'breathing-only should be much lower');
});

test('stage curve peaks at onset, is lower presymptomatically, and dies out', () => {
  assert.ok(sheddingFactor(0) >= sheddingFactor(1));
  assert.ok(sheddingFactor(-1) < sheddingFactor(0));
  assert.ok(sheddingFactor(-1) > 0, 'presymptomatic transmission must be possible');
  assert.ok(sheddingFactor(5) < sheddingFactor(2));
  assert.equal(sheddingFactor(9), 0, 'no shedding well after recovery');
  assert.equal(sheddingFactor(-5), 0, 'no shedding before infection');
  // Unknown stage sits between the peak and the tail.
  between(STAGE_UNKNOWN_FACTOR, 0.3, 0.7, 'illness-average stage factor');
  assert.equal(stageFactor(undefined), STAGE_UNKNOWN_FACTOR);
  assert.equal(stageFactor('unknown'), STAGE_UNKNOWN_FACTOR);
  assert.equal(stageFactor('onset'), sheddingFactor(0));
  assert.equal(stageFactor('recovered'), 0);
});

// ---------------------------------------------------------------------------
// Pair-day summation
// ---------------------------------------------------------------------------

test('ten 5-min rows with one person equal one 50-min meeting', () => {
  const row = { p: 0.9, duration: 5, distance: 1, room: 30, stage: 0, ...WX };
  const rows = Array.from({ length: 10 }, () => ({ ...row }));
  const summed = lambdaForContacts(rows);
  const oneShot = lambdaForContacts([{ ...row, duration: 50 }]);
  // The near field is linear in time, so it matches exactly; the far field is
  // transient, so restarting the clock each row understates it slightly.
  assert.ok(summed.lambda <= oneShot.lambda, 'summing rows must not exceed one long meeting');
  assert.ok(summed.lambda > 0.9 * oneShot.lambda, 'and must be close to it');
  // And the P is applied ONCE, so no amount of exposure can push the chance of
  // being infected past the chance that the other person has flu at all. This
  // is what per-row compounding gets wrong: 1 - (1 - P*lambda)^n -> 1, not P.
  const heavy = { p: 0.5, duration: 60, distance: 0.4, room: 10, ach: 1, stage: 0, ...WX };
  const many = lambdaForContacts(Array.from({ length: 24 }, () => ({ ...heavy })));
  assert.ok(many.lambda > 3, 'this should be a saturating dose');
  between(many.pInfectedByMeeting, 0.49, 0.5, 'saturates at their P, not at 1');
  const compounded = 1 - (1 - update(heavy).pInfectedByMeeting) ** 24;
  assert.ok(
    compounded > 1.5 * many.pInfectedByMeeting,
    `per-row compounding should overstate a saturating exposure (got ${compounded})`
  );
});

test("the other person's P scales the update linearly and P=0 is a no-op", () => {
  const base = { prior: 0.02, duration: 30, distance: 1, room: 30, stage: 0, ...WX };
  const zero = update({ ...base, p: 0 });
  assert.equal(zero.pInfectedByMeeting, 0);
  assert.ok(Math.abs(zero.pNow - 0.02) < 1e-12, 'P=0 must leave my prior alone');
  const half = update({ ...base, p: 0.5 });
  const full = update({ ...base, p: 1 });
  assert.ok(Math.abs(half.pInfectedByMeeting - full.pInfectedByMeeting / 2) < 1e-12);
});

test('a prior of 1 cannot be increased, and nobody is reinfected', () => {
  const r = update({ prior: 1, p: 1, duration: 240, distance: 0.5, room: 10, stage: 0, ...WX });
  assert.equal(r.newlyInfected, 0, 'no susceptible mass left to infect');
  assert.ok(r.pNow <= 1 + 1e-12);
  // Already recovered: also immune here.
  const rec = update({ prior: 0, priorR: 1, p: 1, duration: 240, distance: 0.5, room: 10, stage: 0, ...WX });
  assert.equal(rec.newlyInfected, 0, 'recovered people are not reinfected');
  assert.ok(rec.states.R > 0.999);
});

// ---------------------------------------------------------------------------
// Days since the meeting / state propagation
// ---------------------------------------------------------------------------

test('a fresh infection is latent, then infectious, then recovered', () => {
  const base = { prior: 0, p: 1, duration: 480, distance: 0.5, room: 12, ach: 2, stage: 0, ...WX };
  const d0 = update({ ...base, days: 0 });
  const d1 = update({ ...base, days: 1 });
  const d3 = update({ ...base, days: 3 });
  const d20 = update({ ...base, days: 20 });

  assert.ok(d0.states.I < 1e-9, 'nobody is infectious the instant they are infected');
  assert.ok(d0.states.E > 0, 'they are latent');
  assert.ok(d1.states.I > d0.states.I, 'infectiousness builds');
  assert.ok(d3.states.I > d1.states.E, 'by day 3 the infectious phase dominates');
  assert.ok(d20.states.E + d20.states.I < 0.02 * (d0.states.E + d0.states.I), 'by day 20 it is over');
  assert.ok(d20.states.R > 0, 'the mass ends up in R');
  // pNow is "currently infected", so it must fall away, unlike "ever infected".
  assert.ok(d20.pNow < d3.pNow);
  const everInfected = 1 - d20.states.S;
  assert.ok(everInfected > d20.pNow, 'ever-infected must exceed currently-infected');
});

test('probability mass is conserved at every horizon', () => {
  for (const days of [0, 0.5, 1, 2, 7, 30, 365]) {
    const r = update({ prior: 0.3, priorR: 0.1, p: 0.5, duration: 60, distance: 1, room: 30, days, ...WX });
    const total = r.states.S + r.states.E + r.states.I + r.states.R;
    assert.ok(Math.abs(total - 1) < 1e-9, `mass ${total} at day ${days}`);
    for (const [k, v] of Object.entries(r.states)) {
      assert.ok(v >= -1e-12 && v <= 1 + 1e-12, `${k} = ${v} out of range at day ${days}`);
    }
  }
});

test('ageing with no exposure never raises P(flu now)', () => {
  let prev = age(0.5, 0).pNow;
  for (const days of [0.5, 1, 2, 5, 10, 30]) {
    const now = age(0.5, days).pNow;
    assert.ok(now <= prev + 1e-12, `pNow rose from ${prev} to ${now} at day ${days}`);
    prev = now;
  }
});

test('a scalar prior splits into E and I by mean sojourn time', () => {
  const y = statesFromPrior(0.2);
  const E = y[1] + y[2];
  const I = y[3] + y[4];
  assert.ok(Math.abs(E + I - 0.2) < 1e-12);
  assert.ok(I > E, 'the infectious phase is longer, so more of the prior sits there');
  assert.ok(Math.abs(y[0] - 0.8) < 1e-12);
});

// ---------------------------------------------------------------------------
// Humidity physics
// ---------------------------------------------------------------------------

test('absolute humidity round-trips and winter air is dry indoors', () => {
  const ah = absoluteHumidity(60, 10);
  between(ah, 5, 6.5, 'AH at 60% / 10 C');
  assert.ok(Math.abs(rhFromAbsoluteHumidity(ah, 10) - 60) < 0.1, 'round trip');
  // Same air warmed to 20 C indoors is much drier.
  const indoorRH = rhFromAbsoluteHumidity(ah, 20);
  assert.ok(indoorRH < 40, `heated winter air should be dry indoors, got ${indoorRH}%`);
  assert.ok(indoorRH > 25);
  assert.ok(inactivationRate(20) < inactivationRate(50), 'dry air preserves the virus');
  between(inactivationRate(20), 0.3, 0.6, 'k_inact at 20% RH (Noti 2013 ~0.31/h)');
  between(inactivationRate(50), 1.2, 1.85, 'k_inact at 50% RH (Noti 2013 ~1.7/h)');
});

test('cold dry weather is riskier indoors than mild humid weather', () => {
  const base = { p: 1, duration: 60, distance: 1, room: 30, stage: 0 };
  const winter = update({ ...base, humidity: 50, temp: -5 }).lambda;
  const autumn = update({ ...base, humidity: 80, temp: 18 }).lambda;
  assert.ok(winter > autumn, 'winter should be worse');
});

// ---------------------------------------------------------------------------
// Validation and edge cases
// ---------------------------------------------------------------------------

test('zero duration is a no-op', () => {
  const r = update({ prior: 0.05, p: 1, duration: 0, distance: 1, room: 30, stage: 0, ...WX });
  assert.equal(r.lambda, 0);
  assert.equal(r.pInfectedByMeeting, 0);
  assert.ok(Math.abs(r.pNow - 0.05) < 1e-12);
});

test('bad inputs throw', () => {
  const ok = { p: 1, duration: 10, distance: 1, room: 30, stage: 0, ...WX };
  assert.throws(() => update({ ...ok, duration: -1 }), RangeError, 'negative duration');
  assert.throws(() => update({ ...ok, room: -5 }), RangeError, 'negative area');
  assert.throws(() => update({ ...ok, room: 0 }), RangeError, 'zero area');
  assert.throws(() => update({ ...ok, days: -2 }), RangeError, 'negative days');
  assert.throws(() => update({ ...ok, distance: 0 }), RangeError, 'zero distance');
  assert.throws(() => update({ ...ok, distance: -1 }), RangeError, 'negative distance');
  assert.throws(() => update({ ...ok, ach: -1 }), RangeError, 'negative ACH');
  assert.throws(() => update({ ...ok, humidity: -1 }), RangeError, 'negative humidity');
  assert.throws(() => update({ ...ok, duration: 'ten' }), TypeError, 'non-numeric duration');
  assert.throws(() => update({ ...ok, duration: NaN }), TypeError, 'NaN duration');
  assert.throws(() => update(null), TypeError, 'null inputs');
  assert.throws(() => update({ ...ok, stage: 'floopy' }), RangeError, 'bad stage label');
  assert.throws(() => lambdaForContacts('nope'), TypeError, 'non-array rows');
});

test('probabilities are clamped, not rejected', () => {
  const base = { duration: 30, distance: 1, room: 30, stage: 0, ...WX };
  const hi = update({ ...base, prior: 1.4, p: 3 });
  assert.ok(hi.pOther <= 1);
  assert.ok(hi.states.S >= 0 && hi.pNow <= 1);
  const lo = update({ ...base, prior: -0.5, p: -2 });
  assert.equal(lo.pOther, 0);
  assert.ok(lo.states.S <= 1 + 1e-12);
  assert.equal(lo.pNow, 0);
});

test('extreme but valid inputs stay finite and in range', () => {
  const r = update({
    prior: 0.5,
    p: 1,
    duration: 60 * 24 * 7,
    distance: 0.01,
    room: 0.5,
    ceilingHeight: 0.5,
    ach: 0,
    stage: 0,
    days: 1000,
    humidity: 0,
    temp: -40,
  });
  assert.ok(Number.isFinite(r.lambda) && r.lambda > 0);
  between(r.pNow, 0, 1, 'pNow');
  between(r.states.R, 0, 1, 'R');
  // The inverse-square near field is capped, so absurd closeness cannot blow up.
  assert.ok(nearFieldFactor(0.001) === nearFieldFactor(C.NEAR_MIN_DISTANCE));
});

test('a very large empty room approaches the outdoor case', () => {
  const base = { p: 1, duration: 10, distance: 5, stage: 0, ...WX };
  const huge = doseForMeeting({ ...base, room: 1e7 }).lambda;
  assert.ok(huge < 1e-8, `huge room far field should vanish, got ${huge}`);
});

// ---------------------------------------------------------------------------

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) {
  for (const [name, err] of failures) console.error(`\n--- ${name}\n${err.stack}`);
  process.exit(1);
}
