// frankenstein: run model/infer.js and model/meanfield.js (default parameters) on run 17ed9cd6 from the flat
// binary contacts written by ml/scripts/kl_frankenstein_export.py, and write per-agent predictions.
// Usage: node --max-old-space-size=9000 ml/scripts/kl_frankenstein.mjs infer|meanfield
// meanfield: P(ever infected by the end) = 1 - sFinal (model/meanfield.js returns each agent's final P_S).
// infer: infer.js exposes only P(infected now) (with recovery), so we write max over time of P (all change
//   points; prior if none) and the final P.
import { openSync, readSync, closeSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const HERE = dirname(fileURLToPath(import.meta.url)), REPO = join(HERE, '..', '..');
const { meanFieldRisk } = await import(join(REPO, 'model/meanfield.js'));
const RUN = join(REPO, 'sim/runs/influenza_none_n7500_d14_s42_17ed9cd6');
const BIN = join(REPO, 'ml/out/kl/frankenstein/contacts_frankenstein');
const OUT = join(REPO, 'ml/out/kl/frankenstein');
const which = process.argv[2];

function parseCsv(text) {
  const lines = text.split(/\r?\n/), head = lines[0].split(','), rows = [];
  for (let k = 1; k < lines.length; k++) { if (!lines[k]) continue; const f = lines[k].split(','), r = {}; for (let c = 0; c < head.length; c++) r[head[c]] = f[c]; rows.push(r); }
  return rows;
}
function load(name, T) {
  const f = join(BIN, name + '.bin'), bytes = statSync(f).size, arr = new T(bytes / T.BYTES_PER_ELEMENT);
  const u8 = new Uint8Array(arr.buffer), fd = openSync(f, 'r');
  for (let off = 0; off < bytes;) off += readSync(fd, u8, off, Math.min(1 << 30, bytes - off), off);
  closeSync(fd);
  return arr;
}
const meta = JSON.parse(readFileSync(join(BIN, 'meta.json')));
if (!meta.sorted) throw new Error('contacts not sorted by t');
const n = meta.n, names = meta.agents, rNames = meta.rooms;
const t = load('t', Int32Array), a = load('a', Uint16Array), b = load('b', Uint16Array), dist = load('dist', Float32Array);
const tier = load('tier', Uint8Array), dur = load('dur', Uint16Array), room = load('room', Int32Array), ind = load('ind', Uint8Array);
console.log(`${n} contact rows loaded`);
const row = (i) => ({ t: t[i], agent_a: names[a[i]], agent_b: names[b[i]], distance_tier: tier[i], duration_s: dur[i],
  distance_m: dist[i], room_id: room[i] < 0 ? '' : rNames[room[i]], indoor: ind[i] === 1 });
const target = {
  length: n,
  every(fn) { for (let k = 0; k < n; k++) if (!fn(row(k), k)) return false; return true; },
  *[Symbol.iterator]() { for (let k = 0; k < n; k++) yield row(k); },
};
const contacts = new Proxy(target, { get(o, k) { return typeof k === 'string' && k.charCodeAt(0) <= 57 ? row(+k) : o[k]; } });

const config = JSON.parse(readFileSync(join(RUN, 'config.json')));
const agentIds = parseCsv(readFileSync(join(RUN, 'agents_static.csv')).toString()).map((r) => r.agent_id);
if (agentIds.join() !== names.join()) throw new Error('agent order mismatch');
const reports = parseCsv(readFileSync(join(RUN, 'reports_tests.csv')).toString());
for (const r of reports) { r.t = +r.t; r.target_agent_id = r.target_agent_id || null; }
const rooms = new Map(parseCsv(readFileSync(join(RUN, 'map/rooms.csv')).toString()).map((r) => [r.room_id, r]));
const startMs = Date.parse(config.start), DAY = 86400000;
const t0 = Date.now();
let lines;
if (which === 'meanfield') {
  const risk = meanFieldRisk({ contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs, weather: config.params?.weather, days: config.days }, {});
  const end = startMs + config.days * DAY;
  console.log(`meanfield.js in ${((Date.now() - t0) / 1000).toFixed(0)} s, expected infections ${risk.expectedInfections.toFixed(1)}`);
  lines = ['agent_id,p_ever,p_final_now'];
  agentIds.forEach((id, i) => lines.push(`${id},${1 - risk.sFinal[i]},${risk.pAt(id, end)}`));
} else if (which === 'meanfield_cal') {
  // Calibrated rerun: prior = n_seeds / N; lambdaScale refit like meanfield-cli.mjs --calibrate (true seeds, no
  // reports, prior 0, importPerDay 0, geometric bisection) to a train-agent-only target given on the command line.
  // input.prep reuses the contact preprocessing (dose per pair-step, occupancy) across passes: it does not
  // depend on lambdaScale / prior / importPerDay.
  const target = Number(process.argv[3]), iters = Number(process.argv[4] || 10);
  const infections = parseCsv(readFileSync(join(RUN, 'infections.csv')).toString());
  const seeds = infections.filter((r) => r.route === 'seed').map((r) => r.infectee_id);
  const input = { contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs, weather: config.params?.weather, days: config.days };
  const logf = join(OUT, 'mf_calib_frankenstein.log');
  const log = (m) => { console.log(m); writeFileSync(logf, m + '\n', { flag: 'a' }); };
  writeFileSync(logf, '');
  log(`target ${target} (train-only, scaled to all non-seeds), seeds ${seeds.length}, iters ${iters}, bracket from [0.01, 1], hi grown x3 until it overshoots`);
  const prep = {}; // contact preprocessing, done once for all lambdaScales
  const total = (s) => meanFieldRisk({ ...input, reports: [], seeds, prep }, { lambdaScale: s, prior: 0, importPerDay: 0 }).expectedInfections - seeds.length;
  // Bracket: [0.01, 1] was too narrow (from 5 seeds the model barely spreads at 1), so grow hi x3 until it overshoots.
  let lo = 0.01, hi = 1;
  for (let k = 0; k < 8; k++) { const t1 = Date.now(), e = total(hi); log(`bracket: lambdaScale ${hi.toFixed(5)} expected ${e.toFixed(1)} (${((Date.now() - t1) / 1000).toFixed(0)} s)`); if (e >= target) break; lo = hi; hi *= 3; }
  for (let it = 0; it < iters; it++) {
    const mid = Math.sqrt(lo * hi), t1 = Date.now(), e = total(mid);
    log(`iter ${it}: lambdaScale ${mid.toFixed(5)} expected ${e.toFixed(1)} (${((Date.now() - t1) / 1000).toFixed(0)} s)`);
    if (e < target) lo = mid; else hi = mid;
  }
  const scale = Math.sqrt(lo * hi), prior = seeds.length / agentIds.length;
  log(`fitted lambdaScale ${scale.toFixed(5)} (bracket [${lo.toFixed(5)}, ${hi.toFixed(5)}]); prior ${prior}`);
  const t2 = Date.now();
  const risk = meanFieldRisk(input, { lambdaScale: scale, prior });
  log(`final scored run (reports, prior ${prior}, lambdaScale ${scale.toFixed(5)}): ${((Date.now() - t2) / 1000).toFixed(0)} s, expected infections ${risk.expectedInfections.toFixed(1)}`);
  const end = startMs + config.days * DAY;
  lines = ['agent_id,p_ever,p_final_now'];
  agentIds.forEach((id, i) => lines.push(`${id},${1 - risk.sFinal[i]},${risk.pAt(id, end)}`));
  writeFileSync(join(OUT, 'meanfield_cal_info_frankenstein.json'), JSON.stringify({ target, lambdaScale: scale, prior, iters }));
} else if (which === 'meanfield_fit') {
  // prior = n_seeds / N; lambdaScale fitted WITH reports so mean P(ever infected) over train agents = their attack
  // rate (see kl_mf_fit.mjs). args: <target> <lo> <hi> [<known lambdaScale>:<known mean P(train)>]
  const { fitWithReports } = await import('./kl_mf_fit.mjs');
  const [target, lo, hi] = process.argv.slice(3, 6).map(Number), knownArg = process.argv[6];
  const infections = parseCsv(readFileSync(join(RUN, 'infections.csv')).toString());
  const seedSet = new Set(infections.filter((r) => r.route === 'seed').map((r) => r.infectee_id));
  const val = new Set(JSON.parse(readFileSync(join(OUT, 'val_ids.json'))));
  const trainIdx = agentIds.flatMap((id, i) => (!seedSet.has(id) && !val.has(id) ? [i] : []));
  const prior = seedSet.size / agentIds.length, known = knownArg ? [knownArg.split(':').map(Number)] : [];
  const logf = join(OUT, 'mf_fit_frankenstein.log');
  const log = (m) => { console.log(m); writeFileSync(logf, m + '\n', { flag: 'a' }); };
  log(`${new Date().toISOString()} fit with reports: target mean P(train) ${target}, ${trainIdx.length} train agents, prior ${prior}, bracket [${lo}, ${hi}], known ${JSON.stringify(known)}`);
  const input = { contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs, weather: config.params?.weather, days: config.days };
  const { risk } = fitWithReports({ meanFieldRisk, input, params: { prior }, trainIdx, target, lo, hi, known, maxPasses: 6, tol: 0.03, log });
  const end = startMs + config.days * DAY;
  lines = ['agent_id,p_ever,p_final_now'];
  agentIds.forEach((id, i) => lines.push(`${id},${1 - risk.sFinal[i]},${risk.pAt(id, end)}`));
} else if (which === 'infer') {
  const { inferRisk } = await import(join(REPO, 'model/infer.js'));
  const risk = inferRisk({ contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs }, {});
  console.log(`infer.js in ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  const end = startMs + config.days * DAY, prior = risk.params.prior;
  lines = ['agent_id,p_max,p_final'];
  for (const id of agentIds) {
    const cs = risk.changes.get(id) || [];
    let mx = prior; for (const c of cs) if (c.tMs <= end && c.p > mx) mx = c.p;
    lines.push(`${id},${mx},${risk.pAt(id, end)}`);
  }
} else throw new Error('usage: infer|meanfield|meanfield_cal <target> [iters]|meanfield_fit <target> <lo> <hi> [s:m]');
writeFileSync(join(OUT, `${which}_js_frankenstein.csv`), lines.join('\n') + '\n');
console.log('wrote', join(OUT, `${which}_js_frankenstein.csv`));
