// model/smf_test.mjs — tests for the Simple Mean-Field engine (smf.js). Plain node, no dependencies.
//   node model/smf_test.mjs
// Synthetic inputs only: each test builds a few agents, contact rows and reports, and checks one part of
// Baker et al. PNAS 2021 SI section 3 (eq. 1 product, clamps, causal re-run). Exits non-zero on failure.

import assert from 'node:assert/strict';
import { smfRisk, SMF_DEFAULTS } from './smf.js';

const MIN = 60000, HOUR = 3600000, DAY = 86400000;
const START = Date.parse('2026-01-05T00:00:00');
const STEP = 5, SPD = 1440 / STEP; // minutes per step, steps per day

let passed = 0;
const failures = [];
function test(name, fn) {
  try { fn(); passed++; console.log(`PASS ${name}`); }
  catch (err) { failures.push([name, err]); console.log(`FAIL ${name}\n     ${err.message}`); }
}
const near = (a, b, tol, what) => assert.ok(Math.abs(a - b) <= tol, `${what}: ${a} vs ${b} (tol ${tol})`);

// contacts: [[step, a, b, dose]]; reports: [{day, h, agent, event, value, target}]
function input(n, days, contacts = [], reports = []) {
  contacts = [...contacts].sort((x, y) => x[0] - y[0]);
  return {
    agentIds: Array.from({ length: n }, (_, i) => `A${i}`), startMs: START, stepMin: STEP, nSteps: days * SPD,
    rows: { t: Int32Array.from(contacts, (c) => c[0]), a: Int32Array.from(contacts, (c) => c[1]),
      b: Int32Array.from(contacts, (c) => c[2]), dose: Float64Array.from(contacts, (c) => c[3]) },
    reports: reports.map((r) => ({ tMs: START + r.day * DAY + (r.h ?? 0) * HOUR, agent: r.agent, event: r.event,
      value: r.value, target: r.target ?? -1 })).sort((x, y) => x.tMs - y.tMs),
  };
}
const step = (day, h = 0) => day * SPD + Math.round((h * 60) / STEP);
const pos = (agent, day, h = 0) => ({ day, h, agent, event: 'test_result', value: 'positive' });
const stage = (g) => SMF_DEFAULTS.stageProfile[g] ?? 0;
const lam = (Ij, D) => Ij.reduce((s, x, g) => s - x * Math.expm1(-stage(g) * D), 0); // sum_g I_j[g](1-e^-stage D)
// probe that keeps copies of the state of run D at day d ('start' and 'end' phases)
function grab(D, d) {
  const got = {};
  const probe = (ph, D_, d_, s) => {
    if (D_ !== D || d_ !== d) return;
    got[ph] = { S: Float64Array.from(s.S), R: Float64Array.from(s.R), I: Float64Array.from(s.I), pend: Float64Array.from(s.pend), G: s.G };
  };
  return { got, probe, Ij: (ph, j) => Array.from(got[ph].I.subarray(j * got[ph].G, (j + 1) * got[ph].G)) };
}

test('1 no contacts, no reports: P_I stays at the prior for 14 days (community calibration)', () => {
  const out = smfRisk(input(5, 14));
  for (const x of out.daily) near(x.sumI / 5, SMF_DEFAULTS.prior, 0.002, `day ${x.day} mean P_I`);
  for (let d = 0; d < 14; d++) near(out.pAt('A0', START + d * DAY + 12 * HOUR), SMF_DEFAULTS.prior, 0.002, `pAt day ${d}`);
  const last = out.daily[13];
  console.log(`     community=${out.params.community.toFixed(6)}/day  day-13 mean P_I=${(last.sumI / 5).toFixed(5)}  R=${(last.sumR / 5).toFixed(4)}`);
});

test('2 SI eq. 1: one pair, one day, dose D: S_i(end) = S0 (1 - sum_g I_j[g](1 - e^-stage(g) D)); P_I monotone', () => {
  const D = 1.5, k = grab(3, 2);
  // j (0) positive on day 1 (known before day 2); i (1) meets j in 6 rows on day 2 summing to D
  const rows = [8, 9, 10, 14, 15, 20].map((h) => [step(2, h), h % 2 ? 0 : 1, h % 2 ? 1 : 0, D / 6]);
  const out = smfRisk(input(2, 4, rows, [pos(0, 1, 9)]), { probe: k.probe, minDelta: 0 });
  const S0 = k.got.start.S[1], A = lam(k.Ij('start', 0), D);
  near(k.got.end.S[1], S0 * (1 - A), 1e-12, 'S_i at day end');
  // monotone within day 2, from the run whose output is day 2
  let prev = -1;
  for (let m = 0; m < 1440; m += 5) {
    const p = out.pAt('A1', START + 2 * DAY + m * MIN);
    assert.ok(p >= prev - 1e-15, `P_I fell at minute ${m}: ${prev} -> ${p}`); prev = p;
  }
  console.log(`     S0=${S0.toFixed(6)}  A=${A.toFixed(6)}  S_end=${k.got.end.S[1].toFixed(6)}`);
});

test('3 mean-field product: two independent sources give S0 (1 - A1)(1 - A2)', () => {
  const k = grab(3, 2), D1 = 0.8, D2 = 2.2;
  const rows = [[step(2, 9), 0, 2, D1], [step(2, 11), 2, 1, D2 / 2], [step(2, 13), 1, 2, D2 / 2]];
  smfRisk(input(3, 4, rows, [pos(0, 1, 9), pos(1, 0, 15)]), { probe: k.probe });
  const want = k.got.start.S[2] * (1 - lam(k.Ij('start', 0), D1)) * (1 - lam(k.Ij('start', 1), D2));
  near(k.got.end.S[2], want, 1e-12, 'S_i at day end');
});

test('4 immunity: after a "recovered" report, contacts with an infected person do not raise P_I', () => {
  const rows = [];
  for (let d = 1; d < 5; d++) for (let h = 9; h < 17; h++) rows.push([step(d, h), 0, 1, 1.0]);
  const out = smfRisk(input(2, 6, rows, [{ day: 0, h: 1, agent: 1, event: 'self_report', value: 'recovered' }, pos(0, 2, 9)]));
  let max = 0;
  for (let t = START + 2 * HOUR; t < START + 6 * DAY; t += HOUR) max = Math.max(max, out.pAt('A1', t));
  assert.ok(max < 1e-9, `recovered person reached P_I=${max}`);
  // control: without the recovery report the same contacts infect
  const ctl = smfRisk(input(2, 6, rows, [pos(0, 2, 9)]));
  assert.ok(ctl.pAt('A1', START + 5 * DAY + 12 * HOUR) > 0.3, 'control should be infected');
});

test('5 back-propagation and causality: a report on day 3 reaches a day-1 contact from day 4 00:00', () => {
  const rows = [[step(1, 10), 0, 1, 3], [step(1, 11), 0, 1, 3]];
  const withRep = smfRisk(input(2, 6, rows, [pos(0, 3, 10)])), without = smfRisk(input(2, 6, rows));
  for (let t = START; t < START + 4 * DAY; t += 30 * MIN)
    near(withRep.pAt('A1', t), without.pAt('A1', t), 1e-12, `i before the report was known (${(t - START) / HOUR} h)`);
  const p4 = withRep.pAt('A1', START + 4 * DAY), b4 = without.pAt('A1', START + 4 * DAY);
  assert.ok(p4 > b4 + 0.01, `day 4 00:00: ${p4} should exceed ${b4}`);
  assert.ok(withRep.pAt('A0', START + 3 * DAY + 10 * HOUR) >= SMF_DEFAULTS.posTest - 1e-12, 'j at 10:00 on day 3');
  assert.ok(withRep.pAt('A0', START + 3 * DAY + 10 * HOUR - MIN) < 0.5, 'j just before the report');
  console.log(`     i at day 4 00:00: ${p4.toFixed(4)} (without report ${b4.toFixed(4)})`);
});

test('6 negative test caps P_I at the test time', () => {
  const out = smfRisk(input(2, 4, [], [{ day: 0, h: 9, agent: 0, event: 'self_report', value: 'might_be_sick' },
    { day: 1, h: 12, agent: 0, event: 'test_result', value: 'negative' }]));
  const before = out.pAt('A0', START + DAY + 11 * HOUR), at = out.pAt('A0', START + DAY + 12 * HOUR);
  assert.ok(before >= 0.5, `before the test P_I=${before}`);
  assert.ok(at <= SMF_DEFAULTS.negTest + 1e-12, `at the test P_I=${at}`);
  assert.ok(out.pAt('A0', START + 2 * DAY) <= SMF_DEFAULTS.negTest + 1e-12, 'next day (back-capped)');
});

test('7 stage: the same dose from a source at infection age 2 transmits more than at age 6', () => {
  // prior ~0 and no community, so j's mass sits at one age; j positive day 4 => infected day 2
  const p = { prior: 1e-12, community: 0 };
  const lamAt = (day) => {
    const k = grab(day + 1, day);
    smfRisk(input(2, day + 2, [[step(day, 12), 0, 1, 1.0]], [pos(0, 4, 9)]), { ...p, probe: k.probe });
    const Pj = k.Ij('start', 0).reduce((a, b) => a + b, 0);
    return (1 - k.got.end.S[1] / k.got.start.S[1]) / Pj; // lambda per unit of j's P_I
  };
  const l2 = lamAt(4), l6 = lamAt(8);
  near(l2, -Math.expm1(-stage(2)), 1e-9, 'lambda at age 2');
  near(l6, -Math.expm1(-stage(6)), 1e-9, 'lambda at age 6');
  assert.ok(l2 > l6, `age 2 ${l2} vs age 6 ${l6}`);
  console.log(`     lambda age 2=${l2.toFixed(4)}  age 6=${l6.toFixed(4)}`);
});

test('8 recovery: an infection at day 0 decays per Erlang survival (no contacts, no community)', () => {
  const out = smfRisk(input(1, 9, [], [pos(0, 0, 0)]), { prior: 0, tauDays: 0, minDelta: 0 });
  const k = SMF_DEFAULTS.illnessShape, x = (k / SMF_DEFAULTS.illnessMeanDays) * 7;
  let surv7 = 0, term = 1;
  for (let i = 0; i < k; i++) { surv7 += term; term *= x / (i + 1); }
  surv7 *= Math.exp(-x);
  const p7 = out.pAt('A0', START + 7 * DAY + HOUR);
  near(p7, SMF_DEFAULTS.posTest * surv7, 1e-6, 'P_I at day 7');
  console.log(`     P_I day 7 = ${p7.toFixed(6)} = 0.97 x Surv(7) ${surv7.toFixed(6)}`);
});

test('9 time since meeting: P_I of an exposed person rises, then falls as the infection runs out', () => {
  const out = smfRisk(input(2, 14, [[step(4, 12), 0, 1, 3]], [pos(0, 4, 8)]));
  const at = (d) => out.pAt('A1', START + d * DAY + 23 * HOUR);
  const series = Array.from({ length: 14 }, (_, d) => at(d));
  const peak = Math.max(...series), dPeak = series.indexOf(peak);
  assert.ok(peak > SMF_DEFAULTS.prior + 0.1, `peak ${peak}`);
  assert.ok(dPeak >= 5 && dPeak < 13, `peak day ${dPeak}`);
  assert.ok(series[13] < peak - 0.05, `day 13 ${series[13]} vs peak ${peak}`);
  console.log(`     P_I by day: ${series.map((p) => p.toFixed(3)).join(' ')}`);
});

test('10 performance: 1,000 agents, 4 days, 1.5 M rows in < 10 s', () => {
  const n = 1000, days = 4, N = 1500000;
  let seed = 7;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296);
  const t = new Int32Array(N), a = new Int32Array(N), b = new Int32Array(N), dose = new Float64Array(N);
  for (let r = 0; r < N; r++) {
    t[r] = Math.floor((r / N) * days * SPD); a[r] = Math.floor(rnd() * n);
    b[r] = (a[r] + 1 + Math.floor(rnd() * 30)) % n; dose[r] = rnd() * 0.02;
  }
  const reports = [];
  for (let k = 0; k < 20; k++) reports.push({ tMs: START + rnd() * days * DAY, agent: Math.floor(rnd() * n),
    event: ['self_report', 'test_result', 'report_other'][k % 3], value: ['might_be_sick', 'positive', 'might_be_sick'][k % 3],
    target: Math.floor(rnd() * n) });
  reports.sort((x, y) => x.tMs - y.tMs);
  const t0 = Date.now();
  const out = smfRisk({ agentIds: Array.from({ length: n }, (_, i) => `A${i}`), startMs: START, stepMin: STEP,
    nSteps: days * SPD, rows: { t, a, b, dose }, reports });
  const ms = Date.now() - t0;
  for (const x of out.daily) assert.ok(Math.abs(x.sumI + x.sumR + x.sumS - n) < 1e-6, `mass not conserved day ${x.day}`);
  let pts = 0;
  for (const c of out.changes.values()) pts += c.length;
  console.log(`     ${ms} ms; ${pts} change points; day-3 mean P_I=${(out.daily[3].sumI / n).toFixed(4)}`);
  assert.ok(ms < 10000, `${ms} ms`);
});

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);
