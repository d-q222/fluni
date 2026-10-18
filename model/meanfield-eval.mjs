// Score the mean-field model (meanfield.js) on sim runs: per-day KL divergence and AUC of P(ever infected).
// Usage: node --max-old-space-size=12000 model/meanfield-eval.mjs <run_dir> [...] [--set key=value ...] [--no-reports]
//          [--prior config|<number>] [--json out.json] [--quiet]
//   <run_dir>: a sim run folder (contacts from model/cache/<run>/ when model/tools/contacts_cache.py made it, else
//   contacts.csv.gz or parts/). Uses reports_tests.csv and map/rooms.csv when the run has them.
//   Label for day d: infected at any time up to the end of day d (infections.csv; seeds count, at t = 0).
//   KL (nats per person): for a 0/1 label y and a prediction p, KL(y || p) = -ln p if y = 1 else -ln(1 - p), i.e.
//   the log loss (p clipped to [1e-6, 1 - 1e-6]). AUC: P(an infected person ranks above an uninfected one).
//   Baselines per day: the best constant (that day's true share infected, an oracle) and the starting prevalence.
//   --prior: the starting prevalence. 'config' = the sim's initial_seeds / n_agents (a count the app wouldn't know);
//   a number fixes it; default: MF_DEFAULTS.
//   --calibrate online: re-fit the starting prevalence and lambdaScale from the reports seen so far
//   (calibrateFromReports) at days --checkpoints (default 2,4,6,8,10,12,14); each day is scored with the latest fit
//   made by then (before the first: priorMean and the default lambdaScale). --calibrate retro: one fit on all reports.
// Ground truth is read only to score; the model sees contacts, reports and tests.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { meanFieldRisk, initialPrevalence, calibrateFromReports, meanFieldCalibrated, MF_DEFAULTS } from './meanfield.js';

const HERE = dirname(fileURLToPath(import.meta.url)), DAY = 86400000;
const args = process.argv.slice(2), runs = [], sets = {};
let useReports = true, priorMode = 'default', jsonOut = null, quiet = false, calMode = 'off', checkpoints = [2, 4, 6, 8, 10, 12, 14];
for (let k = 0; k < args.length; k++) {
  const a = args[k];
  if (a === '--set') { const [key, v] = args[++k].split('='); sets[key] = v === 'true' ? true : v === 'false' ? false : Number.isFinite(Number(v)) ? Number(v) : v; }
  else if (a === '--no-reports') useReports = false;
  else if (a === '--prior') priorMode = args[++k];
  else if (a === '--json') jsonOut = args[++k];
  else if (a === '--quiet') quiet = true;
  else if (a === '--calibrate') calMode = args[++k];
  else if (a === '--checkpoints') checkpoints = args[++k].split(',').map(Number);
  else runs.push(a.replace(/\/$/, ''));
}
if (!runs.length) { console.error('usage: node model/meanfield-eval.mjs <run_dir> [...] [--set k=v] [--no-reports] [--prior config|<p>]'); process.exit(1); }

function parseCsv(text) { // plain CSV; the columns used come before any quoted commas
  const lines = text.split(/\r?\n/), head = lines[0].split(','), rows = [];
  for (let k = 1; k < lines.length; k++) {
    if (!lines[k]) continue;
    const f = lines[k].split(','), r = {};
    for (let c = 0; c < head.length; c++) r[head[c]] = f[c];
    rows.push(r);
  }
  return rows;
}
function readGz(dir, name) {
  if (existsSync(join(dir, name))) return parseCsv(gunzipSync(readFileSync(join(dir, name))).toString());
  const parts = JSON.parse(readFileSync(join(dir, 'parts/manifest.json'))).files[name].parts;
  return parts.flatMap((p) => parseCsv(gunzipSync(readFileSync(join(dir, p.path))).toString()));
}
function loadColumns(run) {
  const dir = join(HERE, 'cache', basename(run));
  if (!existsSync(join(dir, 'meta.json'))) return null;
  const meta = JSON.parse(readFileSync(join(dir, 'meta.json')));
  const arr = (f, T) => { const b = readFileSync(join(dir, f)); return new T(b.buffer, b.byteOffset, b.byteLength / T.BYTES_PER_ELEMENT); };
  return { t: arr('t.i4', Int32Array), a: arr('a.i4', Int32Array), b: arr('b.i4', Int32Array), dist: arr('dist.f4', Float32Array),
    tier: arr('tier.i1', Int8Array), indoor: arr('indoor.u1', Uint8Array), room: arr('room.i4', Int32Array), dur: arr('dur.i4', Int32Array), roomIds: meta.rooms };
}
function auc(score, label) {
  const o = score.map((s, i) => [s, label[i]]).sort((a, b) => a[0] - b[0]);
  let pos = 0, neg = 0, rank = 0;
  for (let i = 0; i < o.length;) {
    let j = i; while (j < o.length && o[j][0] === o[i][0]) j++;
    const r = (i + j + 1) / 2;
    for (let k = i; k < j; k++) if (o[k][1]) { rank += r; pos++; } else neg++;
    i = j;
  }
  return pos && neg ? (rank - (pos * (pos + 1)) / 2) / (pos * neg) : NaN;
}
const kl = (p, y) => { const q = Math.min(1 - 1e-6, Math.max(1e-6, p)); return y ? -Math.log(q) : -Math.log(1 - q); };

const results = [];
for (const run of runs) {
  const id = basename(run), t0 = Date.now();
  const config = JSON.parse(readFileSync(join(run, 'config.json')));
  const agentIds = parseCsv(readFileSync(join(run, 'agents_static.csv')).toString()).map((a) => a.agent_id);
  const columns = loadColumns(run), contacts = columns ? [] : readGz(run, 'contacts.csv.gz');
  if (columns && columns.t.length && JSON.parse(readFileSync(join(HERE, 'cache', id, 'meta.json'))).agents !== agentIds.length) throw new Error(`${id}: cache agent count differs`);
  const reports = useReports && existsSync(join(run, 'reports_tests.csv')) ? parseCsv(readFileSync(join(run, 'reports_tests.csv')).toString()) : [];
  let rooms = null;
  if (existsSync(join(run, 'map/rooms.csv'))) rooms = new Map(parseCsv(readFileSync(join(run, 'map/rooms.csv')).toString()).map((r) => [r.room_id, r]));
  const startMs = Date.parse(config.start), stepMs = config.step_min * 60000, days = config.days;
  const input = { contacts, columns, reports, rooms, agentIds, stepMin: config.step_min, startMs, weather: config.params?.weather, days };
  if (priorMode === 'config') input.initialPrevalence = initialPrevalence(config);
  else if (priorMode !== 'default') input.initialPrevalence = Number(priorMode);
  // models[d]: the model that scores day d (online: the latest checkpoint fit at or before d)
  const models = [], fits = [];
  if (calMode === 'off') { const m = meanFieldRisk(input, sets); for (let d = 1; d <= days; d++) models[d] = m; }
  else {
    const cps = calMode === 'retro' ? [days] : checkpoints.filter((c) => c <= days);
    let cur = calMode === 'retro' ? null : meanFieldRisk({ ...input, initialPrevalence: (sets.priorMean ?? MF_DEFAULTS.priorMean) }, sets);
    for (let d = 1, ci = 0; d <= days; d++) {
      if (ci < cps.length && cps[ci] <= d) {
        const until = startMs + cps[ci] * DAY;
        if (sets.massScale === false) {
          const cal = calibrateFromReports(input, sets, until);
          fits.push({ day: cps[ci], prior: cal.prior, lambdaScale: cal.lambdaScale, reports: cal.reports });
          cur = meanFieldRisk({ ...input, initialPrevalence: cal.prior }, { ...sets, prior: cal.prior, lambdaScale: cal.lambdaScale });
        } else {
          cur = meanFieldCalibrated(input, sets, until);
          fits.push({ day: cps[ci], prior: cur.fit.prior, lambdaScale: cur.fit.lambdaScale, reports: cur.fit.reports });
        }
        ci++;
      }
      models[d] = cur;
    }
    if (calMode === 'retro') for (let d = 1; d <= days; d++) models[d] = cur;
  }
  const risk = models[days];
  // truth: first infection time per agent
  const infAt = new Map();
  for (const r of parseCsv(readFileSync(join(run, 'infections.csv')).toString())) {
    const t = startMs + Number(r.t) * stepMs;
    if (!infAt.has(r.infectee_id) || t < infAt.get(r.infectee_id)) infAt.set(r.infectee_id, t);
  }
  const prior0 = models[1].params.prior, perDay = [];
  for (let d = 1; d <= days; d++) {
    const t = startMs + d * DAY - 1;
    const p = agentIds.map((a) => models[d].everAt(a, t)), y = agentIds.map((a) => (infAt.has(a) && infAt.get(a) <= t ? 1 : 0));
    const prev = y.reduce((s, v) => s + v, 0) / y.length;
    const mean = (f) => agentIds.reduce((s, _, i) => s + f(i), 0) / agentIds.length;
    perDay.push({ day: d, prevalence: prev, expected: p.reduce((s, v) => s + v, 0), actual: y.reduce((s, v) => s + v, 0),
      kl: mean((i) => kl(p[i], y[i])), auc: auc(p, y), klConstOracle: mean((i) => kl(prev, y[i])), klConstPrior: mean((i) => kl(prior0, y[i])) });
  }
  // Final day: where the KL comes from (reported or not, infected or not), with each group's mean P.
  const tEnd = startMs + days * DAY - 1, firstRep = new Map();
  for (const r of reports) {
    const ev = r.event, v = r.value; let who = r.agent_id;
    if (ev === 'report_other' && v === 'might_be_sick') who = r.target_agent_id;
    else if (!((ev === 'self_report' && (v === 'might_be_sick' || v === 'tested_positive')) || (ev === 'test_result' && v === 'positive'))) continue;
    if (!firstRep.has(who)) firstRep.set(who, 1);
  }
  const groups = {};
  for (const a of agentIds) {
    const y = infAt.has(a) && infAt.get(a) <= tEnd ? 1 : 0, g = `${firstRep.has(a) ? 'reported' : 'unreported'} ${y ? 'infected' : 'healthy'}`;
    const p = models[days].everAt(a, tEnd), x = (groups[g] ||= { n: 0, kl: 0, p: 0 });
    x.n++; x.kl += kl(p, y); x.p += p;
  }
  const avg = (k) => perDay.reduce((s, x) => s + x[k], 0) / perDay.length;
  const res = { run: id, agents: agentIds.length, reports: reports.length, prior: risk.params.prior, lambdaScale: risk.params.lambdaScale, fits,
    meanKL: avg('kl'), finalKL: perDay.at(-1).kl, meanAUC: avg('auc'), finalAUC: perDay.at(-1).auc, meanKLOracle: avg('klConstOracle'),
    finalExpected: perDay.at(-1).expected, finalActual: perDay.at(-1).actual, seconds: (Date.now() - t0) / 1000, perDay };
  results.push(res);
  if (!quiet) {
    console.log(`\n${id}: ${agentIds.length} agents, ${reports.length} reports, prior ${risk.params.prior.toPrecision(3)}, lambdaScale ${risk.params.lambdaScale.toPrecision(3)}, ${res.seconds.toFixed(0)} s`);
    for (const f of fits) console.log(`  fit at day ${f.day}: prior ${f.prior.toPrecision(3)}, lambdaScale ${f.lambdaScale.toPrecision(3)} (${f.reports} reporters)`);
    console.log('day  infected  expected   KL     AUC   KL const=truth  KL const=prior');
    for (const x of perDay) console.log(`${String(x.day).padStart(3)} ${String(x.actual).padStart(8)} ${x.expected.toFixed(0).padStart(9)} ${x.kl.toFixed(4).padStart(7)} ${x.auc.toFixed(3).padStart(6)} ${x.klConstOracle.toFixed(4).padStart(10)} ${x.klConstPrior.toFixed(4).padStart(13)}`);
  }
  const fitTxt = fits.length ? ` prior ${risk.params.prior.toPrecision(2)} lam ${risk.params.lambdaScale.toPrecision(3)}` : '';
  if (!quiet) for (const [g, x] of Object.entries(groups).sort()) console.log(`  final day, ${g}: ${x.n} people, mean P ${(x.p / x.n).toFixed(3)}, KL sum ${x.kl.toFixed(1)} (${(x.kl / agentIds.length).toFixed(4)} of the mean)`);
  console.log(`SUMMARY ${id}${fitTxt} meanKL ${res.meanKL.toFixed(4)} finalKL ${res.finalKL.toFixed(4)} meanAUC ${res.meanAUC.toFixed(3)} finalAUC ${res.finalAUC.toFixed(3)} oracleKL ${res.meanKLOracle.toFixed(4)} expected ${res.finalExpected.toFixed(0)} actual ${res.finalActual}`);
}
if (jsonOut) writeFileSync(jsonOut, JSON.stringify(results, null, 1));
