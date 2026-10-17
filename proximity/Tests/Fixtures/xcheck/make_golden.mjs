// Golden vectors for proximity/Tests/CrossCheckTests.swift: what the web team's JavaScript computes.
// Run: node proximity/Tests/Fixtures/xcheck/make_golden.mjs   (writes golden.json next to this file)
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { inferRisk, DEFAULTS } from '../../../../model/infer.js'; // the real model

const here = dirname(fileURLToPath(import.meta.url));
const out = { source: 'model/infer.js DEFAULTS + heatmap/app.js', defaults: { beta: DEFAULTS.beta, xMax: DEFAULTS.xMax, prior: DEFAULTS.prior, tierWeight: DEFAULTS.tierWeight } };

// ---------- (a) risk: real inferRisk ----------
// Source A has a positive test at step 0 (posTest overridden to s => source risk s), then B has contacts with A.
// infer.js:204-205 folds each contact: xd = min(xMax, 1-(1-xd)(1-pi*s)), pi = 1-exp(-beta*w*min).
// B's p right after the last contact = pAt(B) with minDelta 0 so no change is dropped.
const STEP_MIN = 5, START = Date.parse('2026-01-05T00:00:00Z');
function exactRisk(s, contacts) {
  const risk = inferRisk({
    agentIds: ['A', 'B'], stepMin: STEP_MIN, startMs: START,
    reports: [{ t: 0, agent_id: 'A', event: 'test_result', value: 'positive', target_agent_id: '' }],
    contacts: contacts.map((c, i) => ({ t: 1 + i, agent_a: 'A', agent_b: 'B', distance_m: 1, distance_tier: c.tier, duration_s: Math.round(c.minutes * 60) })),
  }, { posTest: s, minDelta: 0 });
  return risk.pAt('B', START + (1 + contacts.length) * STEP_MIN * 60000);
}
// Independent copy of the fold (infer.js:204-205, lamOf at :91) as a self-check of the harness above.
function foldCopy(s, contacts) {
  let xd = 0;
  for (const c of contacts) {
    const lam = DEFAULTS.beta * DEFAULTS.tierWeight[c.tier - 1] * (Math.round(c.minutes * 60) / 60);
    const pi = 1 - Math.exp(-lam);
    xd = Math.min(DEFAULTS.xMax, 1 - (1 - xd) * (1 - pi * s));
  }
  return 1 - (1 - DEFAULTS.prior) * (1 - xd);
}
// Our approximation (RiskEstimate.swift): one dose = sum s*w*min, x = min(1-exp(-beta*dose), xMax).
function foldedDose(s, contacts) {
  const dose = contacts.reduce((a, c) => a + s * DEFAULTS.tierWeight[c.tier - 1] * Math.round(c.minutes * 60) / 60, 0);
  return { dose, p: 1 - (1 - DEFAULTS.prior) * (1 - Math.min(1 - Math.exp(-DEFAULTS.beta * dose), DEFAULTS.xMax)) };
}
const single = [];
for (const s of [1, 0.5]) for (const tier of [1, 2, 3, 4]) for (const minutes of [0, 1, 5, 15, 45, 90, 200]) single.push({ s, tier, minutes });
out.risk = [];
const mkCase = (s, contacts) => {
  const exact = exactRisk(s, contacts);
  const copy = foldCopy(s, contacts);
  if (Math.abs(exact - copy) > 1e-12) throw new Error(`harness disagrees with fold copy: ${exact} vs ${copy}`);
  const f = foldedDose(s, contacts);
  return { s, contacts, exactP: exact, foldedDose: f.dose, foldedP: f.p };
};
for (const c of single) out.risk.push({ kind: 'single', ...mkCase(c.s, [{ tier: c.tier, minutes: c.minutes }]) });
const multi = [
  [1, [[1, 15], [1, 15]]], [1, [[1, 15], [2, 30], [3, 60]]], [1, [[1, 5], [1, 5], [1, 5], [1, 5]]],
  [0.5, [[1, 15], [2, 30]]], [0.5, [[2, 20], [2, 20], [3, 120]]], [1, [[4, 200], [4, 200], [4, 200]]],
  [1, [[1, 1], [1, 1], [1, 1], [1, 1], [1, 1], [1, 1], [1, 1], [1, 1], [1, 1], [1, 1]]],
  [0.5, [[1, 45], [1, 45], [1, 45]]], [1, [[1, 60], [1, 60]]], [1, [[2, 10], [3, 40], [4, 100], [1, 3]]],
  [0.5, [[3, 90], [4, 200]]], [1, [[1, 8], [2, 8]]],
];
for (const [s, cs] of multi) out.risk.push({ kind: 'multi', ...mkCase(s, cs.map(([tier, minutes]) => ({ tier, minutes }))) });

// tier weights by distance (metres): infer.js distance_tier 1..4 = <1, 1-2, 2-5, >=5 (DEFAULTS.tierWeight)
out.tierWeights = [[0, 1], [0.5, 1], [0.999, 1], [1, 2], [1.5, 2], [1.999, 2], [2, 3], [4.99, 3], [5, 4], [12, 4]]
  .map(([d, tier]) => ({ distance: d, weight: DEFAULTS.tierWeight[tier - 1] }));

// ---------- (b) tiers and advice: heatmap/app.js:448-466 (copied) ----------
const TIERS = { elevated: 0.1, high: 0.4 };                                                        // app.js:448
const riskTier = (p) => (p >= TIERS.high ? 'high' : p >= TIERS.elevated ? 'elevated' : 'low');     // app.js:449
const advice = (p) => {                                                                            // app.js:463-467
  if (riskTier(p) === 'high') return 'High. Consider getting tested at Vaden and staying home.';
  if (riskTier(p) === 'elevated') return 'Elevated. Wear a mask in crowded rooms and watch for symptoms.';
  return 'Low. No action needed.';
};
out.tiers = [0, 0.0999, 0.10, 0.3999, 0.40, 0.9, 1].map((p) => ({ p, tier: riskTier(p), advice: advice(p) }));

// ---------- (c) p_sick lookup ----------
// pAt copied from model/infer.js:369-379; changes built from the CSV rows as cli.mjs writes them.
const rows = (f) => readFileSync(join(here, f), 'utf8').trim().split('\n').slice(1);
const isoMs = (s) => Date.parse(s + 'Z'); // naive sim time read as UTC, as the Swift side does
const changes = new Map();
for (const r of rows('p_sick.csv')) {
  const [id, t, p] = r.split(',');
  if (!changes.has(id)) changes.set(id, []);
  changes.get(id).push({ tMs: isoMs(t), p: Number(p) });
}
const P = { prior: DEFAULTS.prior };
function pAt(agentId, tMs) {
  const a = changes.get(agentId);
  if (!a || tMs < a[0].tMs) return P.prior;
  let lo = 0, hi = a.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (a[mid].tMs <= tMs) lo = mid; else hi = mid - 1;
  }
  return a[lo].p;
}
const isoOf = (ms) => new Date(ms).toISOString().slice(0, 19);
const ids = [...changes.keys()].sort();
const queries = [];
const q = (agent, ms) => queries.push({ agent, t_iso: isoOf(ms), p: pAt(agent, ms) });
const a0 = changes.get('A0000'), a5 = changes.get('A0005'), a9 = changes.get('A0009');
q('A0000', a0[0].tMs - 1000);            // before first row
q('A0000', a0[0].tMs - 86400000);        // a day before
q('A0000', a0[0].tMs);                   // exactly at first change point
q('A0000', a0[1].tMs);                   // exactly at a later change point
q('A0000', a0[1].tMs - 1000);            // one second before it
q('A0000', a0[1].tMs + 1000);
q('A0005', a5[2].tMs);
q('A0005', a5[2].tMs + 3600000);
q('A0005', a5.at(-1).tMs);               // exactly at the last change
q('A0005', a5.at(-1).tMs + 30 * 86400000); // long after
q('A0009', a9[10].tMs);
q('A0009', (a9[10].tMs + a9[11].tMs) / 2);
q('A0009', a9[0].tMs - 1);
q('nobody', a0[0].tMs);                  // unknown agent -> prior
let seed = 12345; const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
for (const id of ['A0001', 'A0002', 'A0003', 'A0004', 'A0006', 'A0007']) {
  const a = changes.get(id); q(id, a[0].tMs + Math.floor(rnd() * (a.at(-1).tMs - a[0].tMs)));
}
out.psick = queries; if (queries.length < 20) throw new Error('need 20 p_sick queries');

// ---------- (d) building heat ----------
// Web reading rule (docs/building-heat-format.md:25-27): the rows with the latest t_iso <= t; a building
// with no row in that snapshot is NO DATA. Row format written by heatmap/tools/precompute.mjs:461-470.
const snaps = new Map(); // tMs -> Map(bld -> reading)
const bids = new Set();
for (const r of rows('building_heat.csv')) {
  const f = r.match(/("([^"]|"")*"|[^,]*)(,|$)/g).map((x) => x.replace(/,$/, '')); // csvField quoting
  const [t, id, , , , people, sick, heat, high] = f;
  const ms = isoMs(t); bids.add(id);
  if (!snaps.has(ms)) snaps.set(ms, new Map());
  snaps.get(ms).set(id, { people: Number(people), expectedSick: Number(sick), heat: Number(heat), high: high === '1' });
}
const times = [...snaps.keys()].sort((a, b) => a - b);
function heatAt(id, ms) {
  let lo = -1; for (let i = 0; i < times.length; i++) if (times[i] <= ms) lo = i;
  if (lo < 0) return null;
  return snaps.get(times[lo]).get(id) || null;
}
const bq = [];
const hq = (id, ms) => bq.push({ building: id, t_iso: isoOf(ms), reading: heatAt(id, ms) });
const bList = [...bids].sort();
const big = 'bld_232805707';
hq(big, times[0] - 1000);                // before the first snapshot
hq(big, times[0]);                       // exactly first
hq(big, times[1] - 1);                   // just before second
hq(big, times[1] + 7 * 60000);           // between snapshots
hq(big, times.at(-1));                   // exactly last
hq(big, times.at(-1) + 5 * 86400000);    // long after
hq('bld_unknown', times[0]);             // never in the file
hq('bld_26250731', times[0]);            // building seen once, likely absent at t0 -> no data
for (let tries = 0; bq.length < 30 && tries < 5000; tries++) {
  const id = bList[Math.floor(rnd() * bList.length)];
  const ms = times[0] + Math.floor(rnd() * (times.at(-1) - times[0]));
  const r = heatAt(id, ms);
  const nulls = bq.filter((x) => x.reading === null).length;
  if (r === null ? nulls < 12 : true) hq(id, ms);
}
out.heat = bq;
if (bq.filter((x) => x.reading === null).length < 3) throw new Error('need some no-data heat cases');
out.heatQueryCount = bq.length;

writeFileSync(join(here, 'golden.json'), JSON.stringify(out, null, 1) + '\n');
console.log(`golden.json: ${out.risk.length} risk, ${out.tiers.length} tiers, ${out.psick.length} p_sick, ${out.heat.length} heat`);
