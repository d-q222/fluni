// Checks that each input of lambda_{j->i} moves the mean-field risk the right way (model/meanfield.js).
// Usage: node model/meanfield-test.mjs
// One meeting between A (who reported symptoms) and B, then B's P(flu) a day later. Each case changes one input.

import { meanFieldRisk } from './meanfield.js';

const startMs = Date.parse('2026-01-05T00:00:00'), stepMin = 5, H = 12; // steps per hour
const rooms = new Map([['small', { volume_m3: 60, ventilation_ach: 1 }], ['big', { volume_m3: 2000, ventilation_ach: 1 }],
  ['vented', { volume_m3: 60, ventilation_ach: 8 }]]);
// A reports "might be sick" at hour 48 (onset then); they meet B at `meetH` for `min` minutes.
// crowd: that many other (healthy-looking) people in the room with B during the meeting.
function pB({ meetH = 47, min = 60, dist = 1, room = 'small', indoor = true, rh, report = 'might_be_sick', bSick = false, readH = 72, crowd = 0, params = {} } = {}) {
  const contacts = [], others = Array.from({ length: crowd }, (_, k) => `C${k}`);
  for (let k = 0; k < min / stepMin; k++) {
    contacts.push({ t: meetH * H + k, agent_a: 'A', agent_b: 'B', distance_m: dist, duration_s: 300, room_id: indoor ? room : '', indoor: indoor ? 'True' : 'False' });
    for (const o of others) contacts.push({ t: meetH * H + k, agent_a: o, agent_b: 'B', distance_m: 4, duration_s: 300, room_id: room, indoor: 'True' });
  }
  const reports = report ? [{ t: 48 * H, agent_id: 'A', event: report === 'positive' ? 'test_result' : 'self_report', value: report }] : [];
  if (bSick) reports.push({ t: 40 * H, agent_id: 'B', event: 'self_report', value: 'might_be_sick' }); // B likely has flu already
  const weather = rh == null ? undefined : { outdoor_rh_pct: rh, outdoor_temp_c: 10 };
  const r = meanFieldRisk({ contacts, reports, rooms, agentIds: ['A', 'B', ...others], stepMin, startMs, weather, days: 14 }, params);
  return r.pAt('B', startMs + readH * 3600000);
}

let pass = 0, fail = 0;
const check = (name, a, b) => { const ok = a > b; ok ? pass++ : fail++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: ${a.toFixed(4)} > ${b.toFixed(4)}`); };

check('P(j has flu): positive test beats a symptom report', pB({ report: 'positive' }), pB());
check('P(j has flu): a report beats no report', pB(), pB({ report: null }));
check('P(i has flu): the meeting adds more to a healthy i than to one who likely has flu already',
  pB() - pB({ min: 0 }), pB({ bSick: true }) - pB({ bSick: true, min: 0 }));
check('duration: 2 h beats 20 min', pB({ min: 120 }), pB({ min: 20 }));
check('distance: 0.5 m beats 3 m', pB({ dist: 0.5 }), pB({ dist: 3 }));
// Room size is not an input by default (a phone can't know the room; rooms.csv sizes are the sim's own): the shared
// air is sized by occupancy, so one sick person among many dilutes more. roomVolume 'map' keeps the sim's volumes.
const same = Math.abs(pB({ room: 'small', dist: 4 }) - pB({ room: 'big', dist: 4 })) < 1e-12; same ? pass++ : fail++;
console.log(`${same ? 'ok  ' : 'FAIL'} room size is not an input (default roomVolume 'occupancy'): 60 m³ = 2,000 m³`);
check('shared air: one sick person among 2 beats one among 30 (occupancy-sized room air)', pB({ dist: 4 }), pB({ dist: 4, crowd: 28 }));
check("room size with roomVolume 'map': 60 m³ beats 2,000 m³", pB({ room: 'small', dist: 4, params: { roomVolume: 'map' } }), pB({ room: 'big', dist: 4, params: { roomVolume: 'map' } }));
check('indoor ventilation: 1 ACH beats 8 ACH', pB({ room: 'small', dist: 4 }), pB({ room: 'vented', dist: 4 }));
check('indoors beats outdoors', pB(), pB({ indoor: false }));
check('outdoor humidity: dry (20%) beats humid (90%): dry indoor air keeps the virus alive longer', pB({ rh: 20, dist: 4 }), pB({ rh: 90, dist: 4 }));
check('stage: meeting j at symptom onset beats meeting j the day after they caught it', pB({ meetH: 47 }), pB({ meetH: 2 }));
check('time since meeting: an infection caught shows as P(flu), then the illness ends', pB({ readH: 72 }), pB({ readH: 47 + 24 * 11 }));

// Observations as in the paper (SI: positive, negative, recovered clamps), one illness per dating.
// run(reports, contacts) -> the model; meet(h, a, b) = an hour together, 1 m apart, in the small room.
const meet = (h, a = 'A', b = 'B') => Array.from({ length: 12 }, (_, k) => ({ t: h * H + k, agent_a: a, agent_b: b, distance_m: 1, duration_s: 300, room_id: 'small', indoor: 'True' }));
const rep = (h, who, event, value) => ({ t: h * H, agent_id: who, event, value });
const run = (reports, contacts = [], params = {}) => meanFieldRisk({ contacts, reports, rooms, agentIds: ['A', 'B'], stepMin, startMs, days: 14 }, params);
const at = (m, id, h) => m.pAt(id, startMs + h * 3600000);
{ // 1. a symptom report sets P_I to the posterior once; repeating it the next day adds nothing
  const once = at(run([rep(48, 'A', 'self_report', 'might_be_sick')]), 'A', 60);
  const twice = at(run([rep(48, 'A', 'self_report', 'might_be_sick'), rep(72, 'A', 'self_report', 'might_be_sick')]), 'A', 84);
  const onceLater = at(run([rep(48, 'A', 'self_report', 'might_be_sick')]), 'A', 84);
  check('symptom report: a repeat within the illness adds nothing (|twice - once| < 1e-6)', 1e-6, Math.abs(twice - onceLater));
  check('symptom report: P_I is the posterior, well below certainty', 0.9, once);
}
{ // 2. recovered ends a current infection but doesn't assert one (false sick reports are later "recovered"):
  //    P(ever infected) doesn't jump to 1. With recoveredCertain (the SI's P_R = 1) a later case can't infect.
  const contacts = meet(100), reps = [rep(48, 'B', 'self_report', 'might_be_sick'), rep(60, 'B', 'self_report', 'recovered'), rep(110, 'A', 'test_result', 'positive')];
  const m = run(reps, contacts), before = m.everAt('B', startMs + 59 * 3600000), after = m.everAt('B', startMs + 61 * 3600000);
  check('recovered: P(ever infected) stays put, not 1 (|after - before| < 0.01)', 0.01, Math.abs(after - before));
  check('recovered: P(ever infected) stays below certainty', 0.9, after);
  const certain = at(run(reps, contacts, { recoveredCertain: true }), 'B', 130);
  check('recovered, recoveredCertain: a later meeting with a case leaves P(flu) at 0', 1e-9, certain);
}
{ // 3. negative test. Default: a likelihood (infected mass x negFnr) at the result. negFnr 0: the SI's P_S = 1 back
  //    to 3 days before it, so what A "passed on" then is gone.
  const contacts = meet(40), sick = rep(46, 'A', 'self_report', 'might_be_sick'), neg = rep(50, 'A', 'test_result', 'negative');
  const exposed = at(run([sick], contacts), 'B', 60), alone = at(run([]), 'B', 60);
  const cleared = at(run([sick, neg], contacts, { negFnr: 0 }), 'B', 60);
  check('negative test, negFnr 0: clears the meeting\'s risk back to baseline', exposed - alone, 10 * Math.abs(cleared - alone));
  const pA = at(run([sick], contacts), 'A', 60), pAneg = at(run([sick, neg], contacts), 'A', 60);
  check('negative test (soft): lowers A\'s P', pA, pAneg);
  check('negative test (soft): but not to near zero (false negatives happen)', pAneg, 0.05 * pA);
}
{ // 4. a self-reported positive after the test result doesn't re-date the infection
  const contacts = meet(90);
  const one = at(run([rep(100, 'A', 'test_result', 'positive')], contacts), 'B', 140);
  const both = at(run([rep(100, 'A', 'test_result', 'positive'), rep(110, 'A', 'self_report', 'tested_positive')], contacts), 'B', 140);
  check('duplicate positive: same P for the contact (|diff| < 1e-9)', 1e-9, Math.abs(both - one));
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
