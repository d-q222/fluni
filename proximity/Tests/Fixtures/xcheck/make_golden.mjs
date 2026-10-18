// Golden vectors for proximity/Tests/CrossCheckTests.swift: what the web team's JavaScript computes.
// Run: node proximity/Tests/Fixtures/xcheck/make_golden.mjs   (writes golden.json next to this file)
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { inferRisk, doseModel, indoorRH, virusDecay, stageFactor, DEFAULTS } from '../../../../model/infer.js'; // the real model

const here = dirname(fileURLToPath(import.meta.url));
const PHONE_KEYS = ['prior', 'selfReport', 'posTest', 'quantaPeak', 'breathingRate', 'nearFieldQ', 'deposition',
  'defaultRoomM2', 'ceilingM', 'defaultAch', 'outdoorRH', 'outdoorTempC', 'indoorTempC', 'stageProfile'];
const out = { source: 'model/infer.js (doseModel, indoorRH, virusDecay, DEFAULTS, inferRisk) + heatmap/app.js',
  defaults: Object.fromEntries(PHONE_KEYS.map((k) => [k, DEFAULTS[k]])) };

// ---------- (a) Rio's dose and the phone's estimate ----------
// The phone rule (heatmap/app.js phoneEstimate, d850081): per peer, doseModel() with no rooms, indoors,
// quantaPeak, summed over 24 h; peers count only within Bluetooth range (d <= 10 m, inclusive);
// stage = mean of stageProfile; p += (1 - p) * s * (1 - e^(-stage * dose)) from the prior.
const D = doseModel(); // no params, no rooms: the default room, as the phone and the web mock-up use
const BT_RANGE_M = 10; // heatmap/app.js BT_RANGE_M (`if (!(d <= BT_RANGE_M)) continue`)
const stageMean = DEFAULTS.stageProfile.reduce((a, b) => a + b, 0) / DEFAULTS.stageProfile.length;
const unit = (d, durS) => D({ distance_m: d, duration_s: durS, indoor: true });
D({ distance_m: 1, duration_s: 60, indoor: true });
const room = D.info.room;
out.derived = { indoorRH: D.indoorRH, virusDecay: D.virusDecay, roomVolume: room.volume, roomLoss: room.loss,
  roomFar: room.far, stage: stageMean, btRangeM: BT_RANGE_M };
// The exported functions agree with what doseModel used.
if (indoorRH(DEFAULTS.outdoorRH, DEFAULTS.outdoorTempC, DEFAULTS.indoorTempC) !== D.indoorRH) throw new Error('indoorRH');
if (virusDecay(D.indoorRH) !== D.virusDecay) throw new Error('virusDecay');
if (inferRisk({ agentIds: ['x'], stepMin: 5, startMs: 0, contacts: [], reports: [] }).params.stageMean !== stageMean) throw new Error('stageMean');
// The functions themselves over their ranges (Swift ports both).
out.virusDecay = [0, 10, 25, 25.5, 29.6, 30, 35, 40, 44.9, 45, 60, 100].map((rh) => ({ rh, decay: virusDecay(rh) }));
out.indoorRH = [[60, 10, 21], [60, -5, 21], [30, 0, 21], [90, 20, 21], [60, 21, 21], [60, 30, 21], [100, -20, 21], [80, 15, 22]]
  .map(([o, t, ti]) => ({ outdoorRH: o, outdoorTempC: t, indoorTempC: ti, rh: indoorRH(o, t, ti) }));

// unitDose at (distance m, seconds). doseModel rounds duration_s to whole seconds, so these are whole.
const pairs = [[0, 60], [0.1, 60], [0.2, 900], [0.29, 1], [0.3, 60], [0.31, 60], [0.5, 1], [0.5, 60], [0.5, 900],
  [1, 60], [1, 3600], [1.5, 300], [1.83, 900], [2, 60], [2.5, 7200], [3, 900], [4, 60], [5, 900], [5, 14400],
  [7.5, 600], [9.99, 60], [10, 60], [0.2, 86400], [1.2, 37], [3.3, 1234]];
out.unitDose = pairs.map(([d, s]) => ({ distance: d, seconds: s, dose: unit(d, s) }));

// p for scenarios, from the REAL inferRisk: the phone's user 'B' meets sources with evidence (a positive
// test -> posTest 0.97, a "might be sick" self-report -> selfReport 0.6) from step 1 on. inferRisk sets a
// source's stage from days since onset and lets exposure recover (Erlang); the phone knows neither, so
// for the cross-check every day of the profile is set to the illness average and recovery is switched
// off (illnessMeanDays Infinity). Everything else is infer.js as shipped.
const STEP_MIN = 5, START = Date.parse('2026-01-05T00:00:00Z');
const phoneP = (sources) => { // the phone rule, in JS (heatmap/app.js phoneEstimate)
  let p = DEFAULTS.prior;
  for (const src of [...sources].sort((a, b) => (a.id < b.id ? -1 : 1))) {
    let dose = 0;
    for (const c of src.contacts) if (c.distance <= BT_RANGE_M) dose += unit(c.distance, c.seconds);
    if (dose > 0) p += (1 - p) * src.s * (1 - Math.exp(-stageMean * dose));
  }
  return p;
};
function inferP(sources) {
  const reports = sources.map((src) => (src.s === DEFAULTS.posTest
    ? { t: 0, agent_id: src.id, event: 'test_result', value: 'positive', target_agent_id: '' }
    : { t: 0, agent_id: src.id, event: 'self_report', value: 'might_be_sick', target_agent_id: '' }));
  const contacts = [];
  let t = 1;
  for (const src of sources) for (const c of src.contacts) {
    contacts.push({ t: t++, agent_a: src.id, agent_b: 'B', distance_m: c.distance, distance_tier: 4, duration_s: c.seconds });
  }
  contacts.sort((a, b) => a.t - b.t);
  const risk = inferRisk({ agentIds: ['B', ...sources.map((s) => s.id)], stepMin: STEP_MIN, startMs: START, reports, contacts },
    { minDelta: 0, stageProfile: DEFAULTS.stageProfile.map(() => stageMean), illnessMeanDays: Infinity });
  return risk.pAt('B', START + t * STEP_MIN * 60000);
}
const S1 = DEFAULTS.posTest, S2 = DEFAULTS.selfReport;
const src = (id, s, ...cs) => ({ id, s, contacts: cs.map(([distance, minutes]) => ({ distance, seconds: Math.round(minutes * 60) })) });
const scenarios = [];
for (const s of [S1, S2]) for (const d of [0.2, 0.5, 1, 1.83, 3, 5]) for (const m of [1, 15, 60, 240]) scenarios.push([src('A', s, [d, m])]);
scenarios.push(
  [src('A', S1, [0.5, 15]), src('C', S2, [2, 60])],
  [src('A', S1, [1, 30]), src('A2', S1, [1, 30])],                // one person seen under two rotating IDs
  [src('A', S1, [1, 60])],                                        // ... and the same time under one ID
  [src('A', S1, [0.2, 5], [3, 100]), src('C', S1, [5, 240]), src('E', S2, [0.4, 20], [0.4, 20])],
  [src('A', S2, [1.5, 10]), src('C', S2, [1.5, 10]), src('E', S2, [1.5, 10]), src('F', S2, [1.5, 10])],
  [src('A', S1, [0.3, 1], [0.3, 1], [0.3, 1], [0.3, 1], [0.3, 1], [0.3, 1], [0.3, 1], [0.3, 1], [0.3, 1], [0.3, 1])],
  [src('A', S1, [2.5, 45]), src('C', S2, [0.25, 3])],
);
out.scenarios = [{ name: 'no contacts', sources: [], p: phoneP([]), inferP: inferP([]) }];
for (const sc of scenarios) {
  const p = phoneP(sc), ip = inferP(sc);
  if (Math.abs(p - ip) > 1e-12) throw new Error(`phone rule disagrees with inferRisk: ${p} vs ${ip} ${JSON.stringify(sc)}`);
  out.scenarios.push({ name: sc.map((x) => `${x.id} s=${x.s} ${x.contacts.map((c) => `${c.distance}m/${c.seconds}s`).join('+')}`).join(', '),
    sources: sc, p, inferP: ip });
}
if (out.scenarios[0].p !== DEFAULTS.prior || out.scenarios[0].inferP !== DEFAULTS.prior) throw new Error('prior');
// Beyond Bluetooth range: the phone adds nothing (inferRisk would still count it, so no inferP here).
for (const d of [9.99, 10, 10.01, 12]) {
  const sc = [src('A', S1, [d, 60])];
  out.scenarios.push({ name: `range ${d} m`, sources: sc, p: phoneP(sc), inferP: null });
}

// The heat map team's reference: A0005 at ?at=5700 on the default run shows "This phone's estimate: 3%".
// heatmap/app.js phoneEstimate (d850081) replayed here on the same files; Swift recomputes p from the
// per-peer contacts and must agree.
{
  const run = join(here, '../../../../sim/runs/influenza_none_n10_d14_s2_bc5cae7a');
  const csv = (text) => { const L = text.split(/\r?\n/), h = L[0].split(','); return L.slice(1).filter(Boolean).map((l) => { const f = l.split(','), r = {}; h.forEach((c, i) => (r[c] = f[i])); return r; }); };
  const rd = (f) => readFileSync(join(run, f));
  const config = JSON.parse(rd('config.json'));
  const contacts = csv(gunzipSync(rd('contacts.csv.gz')).toString());
  const rooms = new Map(csv(rd('map/rooms.csv').toString()).map((r) => [r.room_id, r]));
  const agentIds = csv(rd('agents_static.csv').toString()).map((a) => a.agent_id);
  const startMs = Date.parse(config.start), stepMs = config.step_min * 60000;
  const risk = inferRisk({ contacts, reports: csv(rd('reports_tests.csv').toString()), rooms, agentIds, stepMin: config.step_min, startMs });
  const CONTAGIOUS = 0.9, RISKY = 0.5, WINDOW = 24 * 3600000, me = 'A0005', atMin = 5700, t = startMs + atMin * 60000; // app.js:29,36,38
  const peers = new Map();
  for (const c of contacts) {
    const d = Number(c.distance_m);
    if (!(d <= BT_RANGE_M)) continue;
    const other = c.agent_a === me ? c.agent_b : c.agent_b === me ? c.agent_a : null;
    if (!other) continue;
    const tMs = startMs + Number(c.t) * stepMs, min = Number(c.duration_s) / 60;
    if (tMs > t || tMs < t - WINDOW) continue;
    const pp = risk.pAt(other, tMs), s = pp >= CONTAGIOUS ? DEFAULTS.posTest : pp >= RISKY ? DEFAULTS.selfReport : 0;
    if (!s) continue;
    const k = peers.get(other) || { id: other, s: 0, contacts: [] };
    k.s = Math.max(k.s, s);
    k.contacts.push({ distance: d, seconds: Math.round(60 * Math.min(min, (t - tMs) / 60000)) }); // doseModel rounds
    peers.set(other, k);
  }
  const sources = [...peers.values()];
  out.webReference = { run: 'influenza_none_n10_d14_s2_bc5cae7a', agent: me, atMin, sources, p: phoneP(sources) };
}

// ---------- (a2) shared risk: peer scores, per-source stage, this phone's room ----------
// The phone rule since the product owner's 2026-10-17 ruling (proximity/Core/RiskEstimate.swift):
// per peer s = max(status s, max(0, P_peer - prior)) with P_peer the peer's broadcast score; each contact's
// dose is stageFactor(days since the peer's onset) * unitDose when the peer reports a status and broadcasts
// its days, else stageMean * unitDose; unitDose uses this phone's room (the representative room of the
// building it is in, from FlUni/Resources/building_rooms.csv; outdoors -> indoor = false). Checked against the
// REAL inferRisk: a score source is a self_report whose level is P - prior (params.selfReport), so it carries
// the score's s; recovery is off (the phone has none).
{
  const csv2 = (text) => { const L = text.split(/\r?\n/).filter(Boolean), h = L[0].split(','); return L.slice(1).map((l) => { const f = l.split(','), r = {}; h.forEach((c, i) => (r[c] = f[i])); return r; }); };
  const RUN_MAP = join(here, '../../../../sim/runs/influenza_none_n1000_d4_s42_73b8452c/map');
  const roomsCsv = csv2(readFileSync(join(RUN_MAP, 'rooms.csv'), 'utf8'));
  const rooms = new Map(roomsCsv.map((r) => [r.room_id, r]));
  const placeRows = csv2(readFileSync(join(here, '../../../FlUni/Resources/building_rooms.csv'), 'utf8'));
  const place = new Map(placeRows.map((r) => [r.building_id, r]));
  // building_rooms.csv must carry each room's own rooms.csv values (tools/make_building_rooms.py).
  for (const r of placeRows) {
    const src = rooms.get(r.room_id);
    if (!src || src.volume_m3 !== r.volume_m3 || src.ventilation_ach !== r.ventilation_ach || src.room_type !== r.room_type) throw new Error(`building_rooms ${r.building_id}`);
  }
  const DR = doseModel({}, rooms);
  const OUT = 'outdoors'; // not in any building
  // The contact row infer.js reads for a phone in `building` (null = default room, OUT = outdoors).
  const row = (building) => {
    if (building === null) return { indoor: true };
    if (building === OUT) return { indoor: false, room_id: '' };
    const pl = place.get(building);
    if (!pl) throw new Error(`no place ${building}`);
    return pl.indoor === '1' ? { indoor: true, room_id: pl.room_id } : { indoor: false, room_id: '' };
  };
  const unitR = (d, durS, building) => DR({ distance_m: d, duration_s: durS, ...row(building) });
  const statusS = { none: 0, possible: DEFAULTS.selfReport, contagious: DEFAULTS.posTest };
  const sRule = (status, score) => (score == null ? statusS[status] : Math.max(statusS[status], Math.max(0, score - DEFAULTS.prior)));
  const stageOf = (status, days) => (status !== 'none' && days != null ? stageFactor(days) : stageMean);

  const BLD = { generic: 'bld_1029436493', dorm: 'bld_1040231570', classroom: 'bld_109151789', outdoorPlace: 'bld_m_white_plaza', arena: 'bld_18564360' };
  out.roomDose = [];
  for (const [kind, b] of [['default', null], ['outdoors', OUT], ...Object.entries(BLD)]) {
    for (const [d, sec] of [[0.2, 60], [0.5, 900], [1, 60], [2, 3600], [5, 600], [9.99, 60]]) {
      out.roomDose.push({ kind, building: b, distance: d, seconds: sec, dose: unitR(d, sec, b), info: { indoor: DR.info.indoor, quanta: DR.info.quanta,
        volume: DR.info.room ? DR.info.room.volume : 0, far: DR.info.room ? DR.info.room.far : 0 } });
    }
  }
  if (out.roomDose.find((x) => x.kind === 'dorm').info.quanta !== DEFAULTS.quietQuanta) throw new Error('dorm room must be quiet');
  if (out.roomDose.find((x) => x.kind === 'outdoorPlace').info.indoor !== false) throw new Error('outdoor place');

  // A scenario: sources { id, status, score (null = FLU1 / none broadcast), contacts [{ distance, seconds, day, days, building }] }.
  // `day`: whole days after the source's onset when the contact happens; `days`: what its beacon says then (null = unknown).
  const phoneP2 = (sources) => {
    let p = DEFAULTS.prior;
    for (const src of [...sources].sort((a, b) => (a.id < b.id ? -1 : 1))) {
      const s = sRule(src.status, src.score);
      let w = 0;
      for (const c of src.contacts) if (c.distance <= BT_RANGE_M) w += stageOf(src.status, c.days) * unitR(c.distance, c.seconds, c.building);
      if (s > 0 && w > 0) p += (1 - p) * s * (1 - Math.exp(-w));
    }
    return p;
  };
  // inferRisk: a source with status contagious = a positive test at step 0, otherwise a "might be sick" self-report
  // at step 0 whose level is the scenario's s (params.selfReport). flatStage: every day at stageMean (sources
  // whose phone stage is the average). One selfReport level per scenario.
  function inferP2(sources, flatStage) {
    const lv = [...new Set(sources.filter((x) => x.status !== 'contagious').map((x) => sRule(x.status, x.score)))];
    if (lv.length > 1) throw new Error('one selfReport level per scenario');
    for (const x of sources) if (x.status === 'contagious' && sRule(x.status, x.score) !== DEFAULTS.posTest) throw new Error('contagious s');
    const reports = sources.map((x) => (x.status === 'contagious'
      ? { t: 0, agent_id: x.id, event: 'test_result', value: 'positive', target_agent_id: '' }
      : { t: 0, agent_id: x.id, event: 'self_report', value: 'might_be_sick', target_agent_id: '' }));
    const contacts = [];
    const perDay = new Map();
    for (const x of sources) for (const c of x.contacts) {
      const k = (perDay.get(c.day) || 0) + 1; perDay.set(c.day, k);
      if (k >= 288) throw new Error('too many contacts in a day');
      contacts.push({ t: c.day * 288 + k, agent_a: x.id, agent_b: 'B', distance_m: c.distance, distance_tier: 4, duration_s: c.seconds, ...row(c.building) });
    }
    contacts.sort((a, b) => a.t - b.t);
    const end = contacts.length ? contacts.at(-1).t + 1 : 1;
    const params = { minDelta: 0, illnessMeanDays: Infinity, ...(lv.length ? { selfReport: lv[0] } : {}),
      ...(flatStage ? { stageProfile: DEFAULTS.stageProfile.map(() => stageMean) } : {}) };
    const risk = inferRisk({ agentIds: ['B', ...sources.map((x) => x.id)], stepMin: STEP_MIN, startMs: START, reports, contacts, rooms }, params);
    return risk.pAt('B', START + end * STEP_MIN * 60000);
  }
  const C = (distance, minutes, extra = {}) => ({ distance, seconds: Math.round(minutes * 60), day: 0, days: null, building: null, ...extra });
  const shared = [];
  const add = (name, sources, flatStage) => {
    const p = phoneP2(sources), ip = inferP2(sources, flatStage);
    if (Math.abs(p - ip) > 1e-12) throw new Error(`phone rule disagrees with inferRisk: ${name} ${p} vs ${ip}`);
    shared.push({ name, sources: sources.map((x) => ({ ...x, s: sRule(x.status, x.score) })), p, inferP: ip });
  };
  // s from a peer's score (status none): s = P - 0.02.
  for (const P of [0.02, 0.023, 0.05, 0.1, 0.3, 0.5, 0.85]) for (const [d, m] of [[0.5, 15], [1, 60], [3, 60]]) {
    add(`score ${P} ${d}m/${m}min`, [{ id: 'A', status: 'none', score: P, contacts: [C(d, m)] }], true);
  }
  // Moving closer to a peer with P = 0.3: 3 m, then 1 m, then 0.5 m (cumulative).
  add('P=0.3 at 3m', [{ id: 'A', status: 'none', score: 0.3, contacts: [C(3, 10)] }], true);
  add('P=0.3 at 3m then 1m', [{ id: 'A', status: 'none', score: 0.3, contacts: [C(3, 10), C(1, 10)] }], true);
  add('P=0.3 at 3m then 1m then 0.5m', [{ id: 'A', status: 'none', score: 0.3, contacts: [C(3, 10), C(1, 10), C(0.5, 10)] }], true);
  // Status vs score: the larger wins.
  add('possible, score 0.3 (status wins)', [{ id: 'A', status: 'possible', score: 0.3, contacts: [C(1, 30)] }], true);
  add('possible, score 0.85 (score wins)', [{ id: 'A', status: 'possible', score: 0.85, contacts: [C(1, 30)] }], true);
  add('contagious, score 0.5', [{ id: 'A', status: 'contagious', score: 0.5, contacts: [C(1, 30)] }], true);
  add('score source + positive source', [{ id: 'A', status: 'none', score: 0.4, contacts: [C(0.8, 20)] },
    { id: 'C', status: 'contagious', score: 0.97, contacts: [C(2, 45)] }], true);
  // Per-source stage from the days the peer broadcasts (real stageProfile).
  for (const status of ['contagious', 'possible']) for (const day of [0, 1, 2, 3, 4, 5, 6]) {
    add(`${status} day ${day}`, [{ id: 'A', status, score: null, contacts: [C(1, 30, { day, days: day })] }], false);
  }
  add('contagious days 0..6 in one week', [{ id: 'A', status: 'contagious', score: null,
    contacts: [0, 1, 2, 3, 4, 5, 6].map((day) => C(0.7, 20, { day, days: day })) }], false);
  add('two sources at different stages', [{ id: 'A', status: 'contagious', score: null, contacts: [C(1, 30, { day: 1, days: 1 })] },
    { id: 'C', status: 'contagious', score: 0.9, contacts: [C(2, 60, { day: 4, days: 4 })] }], false);
  // This phone's room.
  for (const [kind, b] of [['outdoors', OUT], ...Object.entries(BLD)]) {
    add(`room ${kind}`, [{ id: 'A', status: 'contagious', score: null, contacts: [C(1, 30, { building: b }), C(3, 120, { building: b })] }], true);
  }
  add('room changes between contacts', [{ id: 'A', status: 'contagious', score: null,
    contacts: [C(1, 30, { building: BLD.classroom }), C(1, 30, { building: OUT }), C(1, 30, { building: BLD.dorm })] }], true);
  add('everything at once', [{ id: 'A', status: 'contagious', score: null, contacts: [C(0.6, 25, { day: 2, days: 2, building: BLD.classroom })] },
    { id: 'C', status: 'possible', score: 0.7, contacts: [C(1.5, 40, { day: 1, days: 1, building: OUT })] }], false);
  out.shared = shared;
  out.stageFactor = [-3, -2, -1, 0, 1, 2, 5, 7, 8, 14].map((day) => ({ day, stage: stageFactor(day) }));
  out.quietQuanta = DEFAULTS.quietQuanta; out.outdoorNearDilution = DEFAULTS.outdoorNearDilution;
}

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
console.log(`golden.json: ${out.unitDose.length} unitDose, ${out.scenarios.length} scenarios, ${out.shared.length} shared-risk scenarios, ${out.roomDose.length} room doses (web reference p ${out.webReference.p}), ${out.tiers.length} tiers, ${out.psick.length} p_sick, ${out.heat.length} heat`);
