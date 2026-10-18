// Run infer.js or meanfield.js (model/meanfield.js, which also returns each agent's final P_S) on a big sim run
// at default parameters, reading contacts from flat binary columns (ml/scripts/export_contacts_fixed.py)
// instead of parsing contacts.csv.gz into 143M JS objects. Rows are built on demand through a Proxy.
//
//   node --max-old-space-size=9000 ml/scripts/kl_fixed.mjs <run_dir> <bin_dir> <infer|meanfield|meanfield_cal> <out.csv>
//   meanfield_cal: prior = n_seeds/N, lambdaScale bisected on train agents (reads val_ids.json next to out.csv;
//   log in mf_calib_fixed.log there), then a final pass with reports.
//
// Output: agent_id,p_ever,p_max,p_final
//   meanfield: p_ever = 1 - P_S at the last step (P(infected at any point, incl. the 2% prior));
//              p_max / p_final = max / last hourly P(infected now).
//   infer:     no P_S exists; p_ever = p_max = max over time of P(infected now) (change points + prior),
//              p_final = P at the end of the run.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { inferRisk } from '../../model/infer.js';
import { meanFieldRisk } from '../../model/meanfield.js';

const [dir, bin, which, out] = process.argv.slice(2);
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
const read = (f) => readFileSync(join(dir, f));
const col = (name, T) => { const b = readFileSync(join(bin, name + '.bin')); return new T(b.buffer, b.byteOffset, b.byteLength / T.BYTES_PER_ELEMENT); };
const meta = JSON.parse(readFileSync(join(bin, 'meta.json')));
const T = col('t', Int32Array), A = col('a', Int16Array), B = col('b', Int16Array), DCM = col('dcm', Uint16Array),
  TIER = col('tier', Int8Array), DUR = col('dur', Int16Array), ROOM = col('room', Int32Array), IND = col('indoor', Uint8Array);
const n = meta.n, ids = meta.agents, roomIds = meta.rooms;
for (let k = 1; k < n; k++) if (T[k] < T[k - 1]) throw new Error('contacts not sorted by t');
const row = (k) => ({ t: T[k], agent_a: ids[A[k]], agent_b: ids[B[k]], distance_m: DCM[k] / 100, distance_tier: TIER[k],
  duration_s: DUR[k], room_id: ROOM[k] < 0 ? '' : roomIds[ROOM[k]], indoor: IND[k] === 1 });
// Not an Array (Array.isArray false: infer.js then skips its string->number pass); index access, length,
// iteration and every() (meanfield.js's sortedness check; checked above) are all the models use.
const contacts = new Proxy({}, {
  get(_, p) {
    if (p === 'length') return n;
    if (p === Symbol.iterator) return function* () { for (let k = 0; k < n; k++) yield row(k); };
    if (p === 'every') return () => true;
    if (typeof p === 'string') { const k = +p; if (Number.isInteger(k) && k >= 0 && k < n) return row(k); }
    return undefined;
  },
});

const config = JSON.parse(read('config.json'));
const agentIds = parseCsv(read('agents_static.csv').toString()).map((a) => a.agent_id);
if (agentIds.join() !== ids.join()) throw new Error('agent order differs from export');
const reports = parseCsv(read('reports_tests.csv').toString());
for (const r of reports) { r.t = +r.t; r.target_agent_id = r.target_agent_id || null; }
const rooms = new Map(parseCsv(read('map/rooms.csv').toString()).map((r) => [r.room_id, r]));
const startMs = Date.parse(config.start), HOUR = 3600000, endMs = startMs + config.days * 24 * HOUR;
console.log(`${which}: ${agentIds.length} agents, ${n.toLocaleString()} contact rows, ${reports.length} reports`);

const t0 = Date.now();
const lines = ['agent_id,p_ever,p_max,p_final'];
if (which === 'meanfield') { // same input as meanfield-cli.mjs
  const risk = meanFieldRisk({ contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs,
    weather: config.params?.weather, days: config.days });
  console.log(`done in ${((Date.now() - t0) / 1000).toFixed(0)} s, expected infections ${risk.expectedInfections.toFixed(1)}`);
  const steps = config.days * 24;
  agentIds.forEach((id, i) => {
    let mx = 0;
    for (let s = 1; s <= steps; s++) mx = Math.max(mx, risk.pAt(id, startMs + s * HOUR));
    lines.push(`${id},${1 - risk.sFinal[i]},${mx},${risk.pAt(id, endMs)}`);
  });
} else if (which === 'infer') { // same input as cli.mjs
  const risk = inferRisk({ contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs });
  console.log(`done in ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  const prior = risk.params.prior;
  for (const id of agentIds) {
    let mx = prior;
    for (const c of risk.changes.get(id) || []) if (c.p > mx) mx = c.p;
    lines.push(`${id},${mx},${mx},${risk.pAt(id, endMs)}`);
  }
} else if (which === 'meanfield_cal') { // prior = n_seeds / N; lambdaScale refit as meanfield-cli.mjs --calibrate, train agents only
  const { appendFileSync } = await import('node:fs');
  const logf = join(dirname(out), 'mf_calib_fixed.log');
  const say = (s) => { console.log(s); appendFileSync(logf, s + '\n'); };
  const inf = parseCsv(read('infections.csv').toString());
  const seeds = [...new Set(inf.filter((r) => r.route === 'seed').map((r) => r.infectee_id))];
  const split = JSON.parse(readFileSync(join(dirname(out), 'val_ids.json')));
  const val = new Set(split.val_ids), seedSet = new Set(seeds);
  const train = new Set(agentIds.filter((id) => !seedSet.has(id) && !val.has(id)));
  const nNonSeed = agentIds.length - seeds.length;
  const trainInf = new Set(inf.filter((r) => r.infector_id !== 'IMPORT' && train.has(r.infectee_id) && !seedSet.has(r.infectee_id)).map((r) => r.infectee_id)).size;
  const target = trainInf / (train.size / nNonSeed);
  const prior = seeds.length / agentIds.length;
  say(`${new Date().toISOString()} seeds ${seeds.length}, prior ${prior}, train agents ${train.size}/${nNonSeed} non-seeds, non-IMPORT train infections ${trainInf}, target ${target.toFixed(2)}`);
  const base = { contacts, reports: [], rooms, agentIds, stepMin: config.step_min, startMs, weather: config.params?.weather, days: config.days, seeds };
  const prep = {}; // contact preprocessing, done once for all lambdaScales
  const total = (s) => meanFieldRisk({ ...base, prep }, { lambdaScale: s, prior: 0, importPerDay: 0 }).expectedInfections - seeds.length;
  // Bracket: [0.01, 1] was too narrow (from 5 seeds the model barely spreads at 1), so grow hi x3 until it overshoots.
  let lo = 0.01, hi = 1, iters = 10;
  for (let k = 0; k < 8; k++) { const t1 = Date.now(), e = total(hi); say(`bracket: lambdaScale ${hi.toFixed(5)} expected on-campus ${e.toFixed(2)} (target ${target.toFixed(2)}) ${((Date.now() - t1) / 1000).toFixed(0)} s`); if (e >= target) break; lo = hi; hi *= 3; }
  for (let it = 0; it < iters; it++) {
    const mid = Math.sqrt(lo * hi), t1 = Date.now(), e = total(mid), sec = (Date.now() - t1) / 1000;
    say(`iter ${it + 1}: lambdaScale ${mid.toFixed(5)} expected on-campus ${e.toFixed(2)} (target ${target.toFixed(2)}) ${sec.toFixed(0)} s${it === 0 ? ' (incl. contact preprocessing)' : ''}`);
    if (e < target) lo = mid; else hi = mid;
    if (it === 1 && sec > 240) { iters = 7; say('no-report pass > 4 min: cutting to 7 iterations'); }
  }
  const scale = Math.sqrt(lo * hi);
  say(`fitted lambdaScale ${scale.toFixed(5)} (bracket [${lo.toFixed(5)}, ${hi.toFixed(5)}], ${iters} iterations)`);
  const t1 = Date.now();
  const risk = meanFieldRisk({ ...base, reports, seeds: undefined }, { lambdaScale: scale, prior });
  say(`final pass (reports, prior ${prior}, lambdaScale ${scale.toFixed(5)}): ${((Date.now() - t1) / 1000).toFixed(0)} s, expected infections ${risk.expectedInfections.toFixed(1)}`);
  const steps = config.days * 24;
  agentIds.forEach((id, i) => {
    let mx = 0;
    for (let s = 1; s <= steps; s++) mx = Math.max(mx, risk.pAt(id, startMs + s * HOUR));
    lines.push(`${id},${1 - risk.sFinal[i]},${mx},${risk.pAt(id, endMs)}`);
  });
} else if (which === 'meanfield_fit') { // prior = n_seeds / N; lambdaScale fitted WITH reports: mean P(train) = train attack rate
  // extra args: <target> <lo> <hi> [<known lambdaScale>:<known mean P(train)>]
  const { appendFileSync } = await import('node:fs');
  const { fitWithReports } = await import('./kl_mf_fit.mjs');
  const [target, lo, hi] = process.argv.slice(6, 9).map(Number), knownArg = process.argv[9];
  const logf = join(dirname(out), 'mf_fit_fixed.log');
  const say = (m) => { console.log(m); appendFileSync(logf, m + '\n'); };
  const inf = parseCsv(read('infections.csv').toString());
  const seedSet = new Set(inf.filter((r) => r.route === 'seed').map((r) => r.infectee_id));
  const val = new Set(JSON.parse(readFileSync(join(dirname(out), 'val_ids.json'))).val_ids);
  const trainIdx = agentIds.flatMap((id, i) => (!seedSet.has(id) && !val.has(id) ? [i] : []));
  const prior = seedSet.size / agentIds.length;
  const known = knownArg ? [knownArg.split(':').map(Number)] : [];
  say(`${new Date().toISOString()} fit with reports: target mean P(train) ${target}, ${trainIdx.length} train agents, prior ${prior}, bracket [${lo}, ${hi}], known ${JSON.stringify(known)}`);
  const input = { contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs, weather: config.params?.weather, days: config.days };
  const { risk } = fitWithReports({ meanFieldRisk, input, params: { prior }, trainIdx, target, lo, hi, known, maxPasses: 6, tol: 0.03, log: say });
  const steps = config.days * 24;
  agentIds.forEach((id, i) => {
    let mx = 0;
    for (let s = 1; s <= steps; s++) mx = Math.max(mx, risk.pAt(id, startMs + s * HOUR));
    lines.push(`${id},${1 - risk.sFinal[i]},${mx},${risk.pAt(id, endMs)}`);
  });
} else throw new Error('which = infer | meanfield | meanfield_cal | meanfield_fit');
writeFileSync(out, lines.join('\n') + '\n');
console.log('wrote', out);
