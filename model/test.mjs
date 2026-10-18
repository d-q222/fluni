// model/test.mjs — tests for the flu probability model (infer.js). Plain node, no dependencies.
//   node model/test.mjs
// One test per variable of the product spec (Baker et al. PNAS 2021), a mean-field equivalence check,
// a calibration print and two real-run summaries. Exits non-zero if any test fails.

import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inferRisk, doseModel, DEFAULTS, stageFactor, indoorRH, virusDecay } from './infer.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const MIN = 60000, HOUR = 3600000, DAY = 86400000;
const START = Date.parse('2026-01-05T00:00:00');
const STEP = 5;                       // minutes per step
const stepsPerDay = DAY / (STEP * MIN);

let passed = 0, skipped = 0;
const failures = [];
function test(name, fn) {
  try { fn(); passed++; console.log(`ok   ${name}`); }
  catch (err) { failures.push([name, err]); console.log(`FAIL ${name}\n     ${err.message}`); }
}
const gt = (a, b, what) => assert.ok(a > b, `${what}: expected ${a} > ${b}`);

// ---------- scenario builder ----------
// J is the source, I the exposed person, K a second source. Each source has one report; I has one
// contact with each source. All numbers are P(I) read from the model's pAt().
const rooms = new Map([
  ['small', { volume_m3: 50, ventilation_ach: 2, room_type: 'classroom' }],
  ['big', { volume_m3: 2000, ventilation_ach: 2, room_type: 'hall' }],
]);
const ids = ['J', 'I', 'K'];

// opts: contact {distance_m, duration_s, room_id, indoor}, report {event,value}, reportDay (default 0),
// contactDay (days after the report; may be negative = contact before the report), queryDays (after contact)
function run(o = {}, params = {}) {
  const reportT = 10 * stepsPerDay;                                   // day 10, so a lookback has history
  const cT = reportT + Math.round((o.contactDay ?? 0.1) * stepsPerDay);
  const c = { t: cT, agent_a: 'J', agent_b: 'I', distance_m: 1, distance_tier: 2, duration_s: 900,
    room_id: 'small', indoor: true, ...(o.contact || {}) };
  const rep = { t: reportT, agent_id: 'J', event: 'test_result', value: 'positive', target_agent_id: '', ...(o.report || {}) };
  // A late, irrelevant report (K, negative test) moves the run's end time out, so that recovery change
  // points for I are written up to there: pAt() after the last event otherwise returns the last change.
  const late = { t: cT + 8 * stepsPerDay, agent_id: 'K', event: 'test_result', value: 'negative', target_agent_id: '' };
  const out = inferRisk({ contacts: [c], reports: [rep, late], rooms, agentIds: ids, stepMin: STEP, startMs: START }, params);
  const tc = START + cT * STEP * MIN;
  return out.pAt('I', tc + (o.queryDays ?? 0) * DAY);
}

// ---------- the nine variables ----------
// pAt() only records changes of at least minDelta (0.01), so weak exposures are invisible to it; tests
// that need a visible effect from a weak source (late stage, humidity) use a long, close contact.
const LONG = { distance_m: 0.5, duration_s: 4 * 3600 };


test('1 P_j: a stronger report about j raises P(i)', () => {
  const selfWeak = run({ report: { event: 'self_report', value: 'might_be_sick' } }, { selfReport: 0.3 });
  const selfStrong = run({ report: { event: 'self_report', value: 'might_be_sick' } }, { selfReport: 0.6 });
  const test_ = run();                                                // positive test, 0.97
  gt(selfStrong, selfWeak, 'selfReport 0.6 vs 0.3');
  gt(test_, selfStrong, 'positive test (0.97) vs self-report (0.6)');
  console.log(`     P(i): self 0.3=${selfWeak.toFixed(4)}  self 0.6=${selfStrong.toFixed(4)}  positive test=${test_.toFixed(4)}`);
});

test('2 P_i prior: higher prior -> higher P(i) but a smaller increase (1 - P_i factor)', () => {
  const lo = run({}, { prior: 0.02 }), hi = run({}, { prior: 0.5 });
  gt(hi, lo, 'P(i) with prior 0.5 vs 0.02');
  gt(lo - 0.02, hi - 0.5, 'increase over the prior');
  // increase = (1 - prior) * s * lambda exactly
  const r = (hi - 0.5) / (1 - 0.5), r2 = (lo - 0.02) / (1 - 0.02);
  assert.ok(Math.abs(r - r2) < 1e-6, `increase/(1-prior) should be constant: ${r} vs ${r2}`);
  console.log(`     increase 0.02 prior: ${(lo - 0.02).toFixed(4)}; 0.5 prior: ${(hi - 0.5).toFixed(4)}; s*lambda=${r.toFixed(4)}`);
});

test('3 duration: longer meeting -> higher (doseModel and end to end)', () => {
  const d = doseModel({}, rooms);
  const u = (s) => d({ distance_m: 1, distance_tier: 2, duration_s: s, room_id: 'small', indoor: true });
  assert.ok(u(1800) > u(900) && u(900) > u(300));
  assert.ok(Math.abs(u(1800) / u(900) - 2) < 1e-9, 'dose is linear in duration');
  gt(run({ contact: { duration_s: 1800 } }), run({ contact: { duration_s: 300 } }), 'P(i) 30 min vs 5 min');
});

test('4 distance: closer -> higher (doseModel and end to end)', () => {
  const d = doseModel({}, rooms);
  const u = (m) => d({ distance_m: m, distance_tier: 2, duration_s: 900, room_id: 'small', indoor: true });
  assert.ok(u(0.5) > u(1) && u(1) > u(2) && u(2) > u(5));
  gt(run({ contact: { distance_m: 0.5 } }), run({ contact: { distance_m: 3 } }), 'P(i) 0.5 m vs 3 m');
});

test('5 room size: bigger room -> lower (same distance, ventilation)', () => {
  const d = doseModel({}, rooms);
  const u = (id) => d({ distance_m: 3, distance_tier: 3, duration_s: 3600, room_id: id, indoor: true });
  gt(u('small'), u('big'), 'dose small vs big room');
  gt(run({ contact: { room_id: 'small', distance_m: 3 } }), run({ contact: { room_id: 'big', distance_m: 3 } }), 'P(i) small vs big');
  // roomVolume 'fixed' (opt-in; the phone mirrors the default 'map'): every room is the default room
  const f = doseModel({ roomVolume: 'fixed' }, rooms), uf = (id) => f({ distance_m: 3, distance_tier: 3, duration_s: 3600, room_id: id, indoor: true });
  if (Math.abs(uf('small') - uf('big')) > 1e-15) throw new Error(`roomVolume fixed: small ${uf('small')} != big ${uf('big')}`);
});

test('6 indoors vs outdoors: outdoors lower', () => {
  const d = doseModel({}, rooms);
  const base = { distance_m: 1, distance_tier: 2, duration_s: 900, room_id: 'small' };
  gt(d({ ...base, indoor: true }), d({ ...base, indoor: false }), 'dose indoor vs outdoor');
  gt(run({ contact: { indoor: true } }), run({ contact: { indoor: false } }), 'P(i) indoor vs outdoor');
});

test('7 stage of j: onset day 0 > day 6 > outside window (0)', () => {
  assert.equal(stageFactor(0), 1.0);
  gt(stageFactor(0), stageFactor(6), 'profile day 0 vs 6');
  assert.equal(stageFactor(8), 0); assert.equal(stageFactor(-3), 0);
  const prior = DEFAULTS.prior;
  const peak = run({ contactDay: 0.1, contact: LONG });                              // report day 0 -> stage day 0
  const late = run({ contactDay: 6.2, contact: LONG });                              // day 6 (report still within 7 d)
  const none = run({ contactDay: -3.5, contact: LONG });                             // 3.5 d before the report: stage 0
  gt(peak, late, 'peak vs day 6'); gt(late, none, 'day 6 vs outside window');
  assert.ok(Math.abs(none - prior) < 1e-9, `outside window should leave P at the prior, got ${none}`);
  console.log(`     P(i): day0=${peak.toFixed(4)}  day6=${late.toFixed(4)}  outside=${none.toFixed(4)}`);
});

test('8 time since meeting: later query -> lower (recovery, Erlang mean 7 d)', () => {
  // pAt() is a step function: recovery points are only written when P moved by >= 0.01 (minDelta),
  // so the steps are about 2 days apart here and the query days are chosen after them.
  const t0 = run({ queryDays: 0 }), t3 = run({ queryDays: 5 }), t7 = run({ queryDays: 7 }), t21 = run({ queryDays: 7.9 });
  gt(t0, t3, '0 d vs 5 d'); gt(t3, t7, '5 d vs 7 d'); assert.ok(t7 >= t21, '7 d vs 7.9 d');
  gt(t0 - DEFAULTS.prior, 0.03, 'there is a visible exposure at t=0');
  console.log(`     P(i) at +0/5/7/7.9 d: ${[t0, t3, t7, t21].map((x) => x.toFixed(4)).join(' / ')}`);
});

test('9 outdoor humidity: drier outdoor air -> higher indoor dose', () => {
  const c = { distance_m: 1, distance_tier: 2, duration_s: 900, room_id: 'big', indoor: true };
  const dry = doseModel({ outdoorRH: 30 }, rooms), wet = doseModel({ outdoorRH: 90 }, rooms);
  const a = dry(c), b = wet(c);
  gt(a, b, 'dose at outdoor RH 30 vs 90');
  gt(dry.indoorRH < wet.indoorRH ? 1 : 0, 0, 'indoor RH follows outdoor RH');
  const far = { room_id: 'small', distance_m: 3, duration_s: 4 * 3600 }; // far field dominates
  gt(run({ contact: far }, { outdoorRH: 30 }), run({ contact: far }, { outdoorRH: 90 }), 'P(i) dry vs humid (end to end)');
  // outdoors the humidity term is absent: no far-field air, so no decay
  assert.equal(dry({ ...c, indoor: false }), wet({ ...c, indoor: false }));
  console.log(`     dose dry(30%)=${a.toFixed(5)} humid(90%)=${b.toFixed(5)}; indoor RH ${dry.indoorRH.toFixed(1)} vs ${wet.indoorRH.toFixed(1)}`);
});

// ---------- Baker mean-field equivalence ----------

test('Baker equivalence: two sources -> 1-(1-p0)(1-s*lam_j)(1-s*lam_k)', () => {
  const reportT = 10 * stepsPerDay, cT = reportT + 24;                 // 2 h after both positives, day 0
  const contacts = [
    { t: cT, agent_a: 'J', agent_b: 'I', distance_m: 1, distance_tier: 2, duration_s: 900, room_id: 'small', indoor: true },
    { t: cT, agent_a: 'K', agent_b: 'I', distance_m: 1, distance_tier: 2, duration_s: 1800, room_id: 'small', indoor: true },
  ];
  const mk = (a) => ({ t: reportT, agent_id: a, event: 'test_result', value: 'positive', target_agent_id: '' });
  const out = inferRisk({ contacts, reports: [mk('J'), mk('K')], rooms, agentIds: ids, stepMin: STEP, startMs: START });
  const unit = doseModel({}, rooms), s = DEFAULTS.posTest, stage = stageFactor(0);
  const lam = (c) => 1 - Math.exp(-stage * unit(c));
  const lj = lam(contacts[0]), lk = lam(contacts[1]);
  const expect = 1 - (1 - DEFAULTS.prior) * (1 - s * lj) * (1 - s * lk);
  const got = out.pAt('I', START + cT * STEP * MIN);
  console.log(`     lambda_j=${lj.toFixed(5)} lambda_k=${lk.toFixed(5)} expected=${expect.toFixed(8)} got=${got.toFixed(8)}`);
  assert.ok(Math.abs(got - expect) < 1e-6, `|${got} - ${expect}| >= 1e-6`);
});

// ---------- calibration ----------

test('Calibration: 15-min chat, 1 m, indoors, peak stage -> lambda 0.02-0.10', () => {
  const u = doseModel({}); // default room 50 m2 x 2.7 m, ACH 2
  const dose = u({ distance_m: 1, distance_tier: 2, duration_s: 900, room_id: '', indoor: true });
  // room_id '' means "wall" in infer.js; use undefined so the default room applies
  const dose2 = u({ distance_m: 1, distance_tier: 2, duration_s: 900, indoor: true });
  const lam = 1 - Math.exp(-stageFactor(0) * dose2);
  const rh = indoorRH(DEFAULTS.outdoorRH, DEFAULTS.outdoorTempC, DEFAULTS.indoorTempC);
  console.log(`     lambda=${lam.toFixed(5)} (dose ${dose2.toFixed(5)}; with empty room_id wall factor dose=${dose}); indoor RH=${rh.toFixed(2)}% (outdoor ${DEFAULTS.outdoorRH}% at ${DEFAULTS.outdoorTempC} C), virus decay=${virusDecay(rh).toFixed(4)} /h`);
  assert.ok(lam >= 0.02 && lam <= 0.10, `lambda ${lam}`);
});

// ---------- real runs ----------

function parseCsv(text) {
  const lines = text.split(/\r?\n/), head = lines[0].split(','), rows = [];
  for (let k = 1; k < lines.length; k++) {
    if (!lines[k]) continue;
    const f = lines[k].split(','), r = {};
    for (let c = 0; c < head.length; c++) r[head[c]] = f[c];
    rows.push(r);
  }
  return rows;
}
function runDir(name) {
  const dir = join(ROOT, 'sim', 'runs', name);
  const need = ['config.json', 'agents_static.csv', 'contacts.csv.gz', 'reports_tests.csv'];
  if (!need.every((f) => existsSync(join(dir, f)))) return null;
  const rd = (f) => readFileSync(join(dir, f));
  const config = JSON.parse(rd('config.json'));
  const agents = parseCsv(rd('agents_static.csv').toString());
  const contacts = parseCsv(gunzipSync(rd('contacts.csv.gz')).toString());
  for (const c of contacts) { c.t = +c.t; c.distance_m = +c.distance_m; c.duration_s = +c.duration_s; }
  const reports = parseCsv(rd('reports_tests.csv').toString());
  for (const r of reports) { r.t = +r.t; r.target_agent_id = r.target_agent_id || null; }
  let rm = null;
  try { rm = new Map(parseCsv(rd('map/rooms.csv').toString()).map((r) => [r.room_id, r])); } catch { /* defaults */ }
  const startMs = Date.parse(config.start);
  const risk = inferRisk({ contacts, reports, rooms: rm, agentIds: agents.map((a) => a.agent_id), stepMin: config.step_min, startMs });
  return { dir, config, agents, contacts, reports, risk, startMs };
}
function summarize(name, extra) {
  const t0 = Date.now();
  const r = runDir(name);
  if (!r) { skipped++; console.log(`skip ${name}: run files not found`); return; }
  test(`Real run ${name}`, () => {
    const endMs = r.startMs + r.config.days * DAY - 1;
    const final = r.agents.map((a) => r.risk.pAt(a.agent_id, endMs));
    const peak = r.agents.map((a) => Math.max(r.risk.pAt(a.agent_id, r.startMs), ...(r.risk.changes.get(a.agent_id) || []).map((c) => c.p)));
    for (const p of [...final, ...peak]) assert.ok(Number.isFinite(p) && p >= 0 && p <= 1, `bad P ${p}`);
    const mean = (x) => x.reduce((a, b) => a + b, 0) / x.length;
    console.log(`     ${r.agents.length} agents, ${r.contacts.length} contacts, ${r.reports.length} reports, ${Date.now() - t0} ms`);
    console.log(`     end of run:  mean P=${mean(final).toFixed(4)}  max P=${Math.max(...final).toFixed(4)}  agents > 0.1: ${final.filter((p) => p > 0.1).length}`);
    console.log(`     peak in run: mean P=${mean(peak).toFixed(4)}  max P=${Math.max(...peak).toFixed(4)}  agents > 0.1: ${peak.filter((p) => p > 0.1).length}`);
    if (extra) extra(r, peak);
  });
}

summarize('influenza_none_n10_d14_s2_bc5cae7a', (r, peak) => {
  const pos = r.reports.filter((x) => x.event === 'test_result' && x.value === 'positive').map((x) => x.agent_id);
  const caseId = pos[0];
  if (!caseId) return console.log('     no positive test in this run');
  const room = (id) => r.agents.find((a) => a.agent_id === id).home_room_id;
  const mates = r.agents.filter((a) => a.agent_id !== caseId && a.home_room_id && a.home_room_id === room(caseId)).map((a) => a.agent_id);
  const pk = (id) => peak[r.agents.findIndex((a) => a.agent_id === id)];
  console.log(`     confirmed case ${caseId} (peak P ${pk(caseId).toFixed(3)}); roommates (same room ${room(caseId)}): ` +
    mates.map((m) => `${m} peak P=${pk(m).toFixed(3)}`).join(', '));
  const inf = join(r.dir, 'infections.csv');
  if (existsSync(inf)) console.log('     sim ground truth (infections.csv): ' + parseCsv(readFileSync(inf).toString()).map((x) => `${x.infectee_id}<-${x.infector_id}@t${x.t}`).join(' '));
});
summarize('influenza_none_n500_d2_s42_aea9db72');

console.log(`\n${passed} passed, ${failures.length} failed${skipped ? `, ${skipped} skipped` : ''}`);
if (failures.length) process.exit(1);
