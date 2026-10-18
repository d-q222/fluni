// Run the mean-field model (meanfield.js, Baker et al. PNAS 2021) on a sim run folder, score it against
// the sim's truth, and write what the heat map reads for big runs.
// Usage: node model/meanfield-cli.mjs <run_dir> [--scale 0.12] [--calibrate] [--set key=value ...]
//   --set overrides an MF_DEFAULTS / infer.js DEFAULTS parameter (numbers, true/false, strings), e.g. --set roomVolume=map
//   writes model/out/<run>/meanfield.csv: agent_id,t_iso,p_sick,shed change points (P as in
//   docs/p-sick-format.md, plus shed = expected infectiousness, sum over ages of P(age) * stage(age)).
//   --calibrate fits lambdaScale: started from the sim's true seeds, with no reports, the model's expected
//   number of on-campus infections should match the sim's. Ground truth is used only here and for scoring.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { meanFieldRisk, MF_DEFAULTS } from './meanfield.js';

const args = process.argv.slice(2), dir = args.find((a) => !a.startsWith('--') && !/^\d/.test(a) && !a.includes('='));
if (!dir) { console.error('usage: node model/meanfield-cli.mjs <run_dir> [--scale x] [--calibrate]'); process.exit(1); }
const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
const over = {};
args.forEach((a, i) => { if (a === '--set') { const [k, v] = args[i + 1].split('='); over[k] = v === 'true' ? true : v === 'false' ? false : isNaN(Number(v)) ? v : Number(v); } });
if (Object.keys(over).length) console.log('params', over);
const run = basename(dir.replace(/\/$/, ''));
const out = join(dirname(fileURLToPath(import.meta.url)), 'out', run, 'meanfield.csv');

function parseCsv(text) { // as cli.mjs: plain CSV, the columns used come before any quoted commas
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
// contacts.csv.gz, or its parts (each a standalone gzipped CSV with the header; parts/manifest.json)
function readGz(name) {
  if (existsSync(join(dir, name))) return parseCsv(gunzipSync(read(name)).toString());
  const parts = JSON.parse(read('parts/manifest.json')).files[name].parts;
  return parts.flatMap((p) => parseCsv(gunzipSync(read(p.path)).toString()));
}

const config = JSON.parse(read('config.json'));
const agentIds = parseCsv(read('agents_static.csv').toString()).map((a) => a.agent_id);
const contacts = readGz('contacts.csv.gz');
for (const c of contacts) { c.t = +c.t; c.distance_m = +c.distance_m; c.duration_s = +c.duration_s; }
const reports = parseCsv(read('reports_tests.csv').toString());
let rooms = null;
try { rooms = new Map(parseCsv(read('map/rooms.csv').toString()).map((r) => [r.room_id, r])); } catch { /* default room */ }
const infections = existsSync(join(dir, 'infections.csv')) ? parseCsv(read('infections.csv').toString()) : [];
const startMs = Date.parse(config.start), stepMs = config.step_min * 60000, DAY = 86400000;
const input = { contacts, reports, rooms, agentIds, stepMin: config.step_min, startMs, weather: config.params?.weather, days: config.days };
console.log(`${run}: ${agentIds.length} agents, ${contacts.length.toLocaleString()} contact rows, ${reports.length} reports`);

let scale = Number(opt('--scale')) || MF_DEFAULTS.lambdaScale;
if (args.includes('--calibrate')) {
  const seeds = infections.filter((r) => r.route === 'seed').map((r) => r.infectee_id);
  const target = infections.filter((r) => r.infector_id !== 'IMPORT').length;
  const total = (s) => meanFieldRisk({ ...input, reports: [], seeds }, { ...over, lambdaScale: s, prior: 0, importPerDay: 0 }).expectedInfections - seeds.length;
  let lo = 0.005, hi = 1;
  for (let it = 0; it < 14; it++) { const mid = Math.sqrt(lo * hi); if (total(mid) < target) lo = mid; else hi = mid; }
  scale = Math.sqrt(lo * hi);
  console.log(`from ${seeds.length} true seeds, the model matches the sim's ${target} on-campus infections at lambdaScale = ${scale.toFixed(4)}`);
}

const t0 = Date.now();
const risk = meanFieldRisk(input, { ...over, lambdaScale: scale });
console.log(`mean-field (lambdaScale ${scale}) in ${((Date.now() - t0) / 1000).toFixed(1)} s`);

// Score: AUC of P(flu) against "infected in the last illnessDays" (sim truth), at the end of each day.
const infAt = new Map();
for (const r of infections) if (!infAt.has(r.infectee_id)) infAt.set(r.infectee_id, startMs + +r.t * stepMs);
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
console.log('day   sum P  truly infected   AUC  sick in top 50');
for (let d = 1; d <= config.days; d++) {
  const t = startMs + d * DAY - 1;
  const p = agentIds.map((id) => risk.pAt(id, t));
  const y = agentIds.map((id) => infAt.has(id) && infAt.get(id) <= t && t - infAt.get(id) < MF_DEFAULTS.illnessDays * DAY);
  const top = p.map((x, i) => [x, y[i]]).sort((a, b) => b[0] - a[0]).slice(0, 50).filter((x) => x[1]).length;
  console.log(`${String(d).padStart(3)} ${p.reduce((a, b) => a + b, 0).toFixed(0).padStart(7)} ${String(y.filter(Boolean).length).padStart(15)} ${auc(p, y).toFixed(2).padStart(5)} ${String(top).padStart(15)}`);
}

// Change points: a row when P or shed moved by >= 0.005 since the agent's last row.
const pad = (x) => String(x).padStart(2, '0');
const iso = (ms) => { const d = new Date(ms); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:00`; };
const lines = ['agent_id,t_iso,p_sick,shed'], dtMs = risk.params.dtH * 3600000, nSteps = Math.ceil((config.days * DAY) / dtMs);
for (const id of agentIds) {
  let lp = -1, ls = -1;
  for (let n = 0; n < nSteps; n++) {
    const t = startMs + (n + 1) * dtMs, p = risk.pAt(id, t), s = risk.shedAt(id, t);
    if (Math.abs(p - lp) < 0.005 && Math.abs(s - ls) < 0.005) continue;
    lines.push(`${id},${iso(t)},${p.toFixed(4)},${s.toFixed(4)}`);
    lp = p; ls = s;
  }
}
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, lines.join('\n') + '\n');
console.log(`wrote ${out.replace(process.cwd() + '/', '')} (${lines.length - 1} rows)`);
