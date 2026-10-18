// model/compare.mjs — the same scenarios through three implementations, printed as markdown.
//   node model/compare.mjs
// Rio's original (python3 exposure/flu_risk.py), our port (model/infer.js: doseModel + the update
// p = prior + (1-prior)*s*lambda + Erlang still-infected), and model/alt/flu_alt.mjs.
// All use outdoor RH 60% at 10 C and 2 ACH unless a scenario says otherwise; stage is a day number
// (0 = onset = peak shedding) so that the stage tables agree.

import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { doseModel, stageFactor, inferRisk } from './infer.js';
import { update as altUpdate } from './alt/flu_alt.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ACH = 2, CEIL = 2.7;
const BASE = { prior: 0.02, p: 0.97, duration: 15, distance: 1, room: 30, outdoors: false, stage: 0, days: 0, rh: 60, temp: 10 };

const S = (name, over, note = '') => ({ name, ...BASE, ...over, note });
const scenarios = [
  S('base: 15 min, 1 m, 30 m2, peak, P_j 0.97', {}),
  S('2 m instead of 1 m', { distance: 2 }),
  S('60 min instead of 15', { duration: 60 }),
  S('outdoors', { outdoors: true }),
  S('lecture hall 300 m2, 75 min, 3 m', { room: 300, duration: 75, distance: 3 }),
  S('dorm roommate 8 h, 2 m, 15 m2', { room: 15, duration: 480, distance: 2 },
    'ours has no talking input; its dorm rule (1.5 quanta/h) applies only via room_type, see row below'),
  S('late stage (day 5)', { stage: 5 }),
  S('P_j 0.35', { p: 0.35 }),
  S('prior 0.3', { prior: 0.3 }),
  S('3 days after the meeting', { days: 3 }, 'alt also has an R (recovered) state; Rio and ours do not'),
  S('7 days after the meeting', { days: 7 }),
  S('outdoor RH 20%', { rh: 20 }),
  S('outdoor RH 80%', { rh: 80 }),
];

// ---- Rio's original ----
function rio(s) {
  const a = ['exposure/flu_risk.py', '--prior', s.prior, '--duration', s.duration, '--distance', s.distance,
    '--room', s.room, '--stage', s.stage, '--p', s.p, '--days', s.days, '--humidity', s.rh, '--temp', s.temp, '--ach', ACH];
  if (s.outdoors) a.push('--outdoors');
  const out = execFileSync('python3', a.map(String), { cwd: ROOT, encoding: 'utf8' });
  const num = (re) => +out.match(re)[1];
  return { lambda: num(/lambda\):\s+([\d.]+)/), p: num(/now, [\d.]+ day\(s\) later:\s+([\d.]+)/) };
}

// ---- our port (infer.js) ----
// Erlang(4, mean 7 d) survival, exactly infer.js's compartments (P.illnessShape / illnessMeanDays).
const stillInfected = (days, K = 4, mean = 7) => { const a = (K / mean) * days; let v = Math.exp(-a), s = 0; for (let k = 0; k < K; k++) { s += v; v *= a / (k + 1); } return s; };
function ours(s, roomType = 'classroom') {
  const rooms = new Map([['r', { volume_m3: s.room * CEIL, ventilation_ach: ACH, room_type: roomType }]]);
  const unit = doseModel({ outdoorRH: s.rh, outdoorTempC: s.temp }, rooms);
  const dose = stageFactor(s.stage) * unit({ distance_m: s.distance, distance_tier: 2, duration_s: s.duration * 60, room_id: 'r', indoor: !s.outdoors });
  const lambda = 1 - Math.exp(-dose);
  const A = s.p * lambda;
  return { lambda, p: s.prior + (1 - s.prior) * A * stillInfected(s.days), A };
}
// Cross-check: the same thing through inferRisk (positive test of J at t=0, one contact right after).
function viaInfer(s) {
  const rooms = new Map([['r', { volume_m3: s.room * CEIL, ventilation_ach: ACH, room_type: 'classroom' }]]);
  const D = 288, t0 = 10 * D, tc = t0 + 1 + Math.round(s.stage * D);
  const rows = [{ t: tc, agent_a: 'J', agent_b: 'I', distance_m: s.distance, distance_tier: 2, duration_s: s.duration * 60, room_id: 'r', indoor: !s.outdoors }];
  const rep = [{ t: t0, agent_id: 'J', event: 'test_result', value: 'positive', target_agent_id: '' }];
  const start = Date.parse('2026-01-05T00:00:00');
  const out = inferRisk({ contacts: rows, reports: rep, rooms, agentIds: ['J', 'I'], stepMin: 5, startMs: start },
    { prior: s.prior, posTest: s.p, outdoorRH: s.rh, outdoorTempC: s.temp });
  return out.pAt('I', start + tc * 5 * 60000);
}

// ---- alt ----
function alt(s) {
  const r = altUpdate({ prior: s.prior, p: s.p, duration: s.duration, distance: s.distance, room: s.room, stage: s.stage,
    days: s.days, humidity: s.rh, temp: s.temp, outdoors: s.outdoors, ach: ACH });
  return { lambda: r.lambda, p: r.pNow };
}

const rows = scenarios.map((s) => ({ s, rio: rio(s), our: ours(s), alt: alt(s) }));
const f = (x) => (x < 0.001 ? x.toExponential(2) : x.toFixed(4));
const r2 = (x) => (Number.isFinite(x) ? x.toFixed(2) : 'n/a');

console.log('| scenario | Rio lambda | Rio P | ours lambda | ours P | alt lambda | alt P | note |');
console.log('|---|---|---|---|---|---|---|---|');
for (const { s, rio: a, our: b, alt: c } of rows) console.log(`| ${s.name} | ${f(a.lambda)} | ${f(a.p)} | ${f(b.lambda)} | ${f(b.p)} | ${f(c.lambda)} | ${f(c.p)} | ${s.note} |`);
{ // dorm rule row: only ours has this input
  const s = scenarios[5], b = ours(s, 'dorm_double');
  console.log(`| dorm roommate 8 h, 2 m, 15 m2, ours with room_type=dorm | - | - | ${f(b.lambda)} | ${f(b.p)} | - | - | ours only: quiet emission 1.5 quanta/h; Rio and alt have no equivalent input |`);
}

console.log('\nSensitivity: ratio to the base scenario. lambda x = lambda / lambda_base; dP x = (P - prior) / (P_base - prior). dP is n/a for the days rows because the methods treat the prior differently over time (Rio decays it, ours holds it, alt moves it into R)\n');
console.log('| scenario | Rio lambda x | ours lambda x | alt lambda x | Rio dP x | ours dP x | alt dP x |');
console.log('|---|---|---|---|---|---|---|');
const B = rows[0];
const inc = (r, k) => r.s.days > 0 ? NaN : (r[k].p - r.s.prior) / (B[k].p - B.s.prior);
for (const r of rows.slice(1)) {
  console.log(`| ${r.s.name} | ${r2(r.rio.lambda / B.rio.lambda)} | ${r2(r.our.lambda / B.our.lambda)} | ${r2(r.alt.lambda / B.alt.lambda)} | ${r2(inc(r, 'rio'))} | ${r2(inc(r, 'our'))} | ${r2(inc(r, 'alt'))} |`);
}

// sanity: our analytic update equals inferRisk where the change is large enough for pAt to record it
let bad = 0, checked = 0;
for (const { s, our } of rows) {
  if (s.days > 0 || our.p - s.prior < 0.02) continue;
  checked++;
  const g = viaInfer(s);
  if (Math.abs(g - our.p) > 1e-6) { bad++; console.error(`mismatch ${s.name}: analytic ${our.p} vs inferRisk ${g}`); }
}
console.log(`\nours: analytic update vs inferRisk, ${checked - bad}/${checked} scenarios agree within 1e-6 (days = 0 only)`);
