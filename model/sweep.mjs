// Model expected sick vs the sim's true infections, with optional parameter overrides:
//   PARAMS='{"reportOther":0.05}' node model/sweep.mjs sim/runs/<run>
// Runs the model in memory, so it suits runs up to ~1,000 agents (bigger: heatmap/tools/precompute.mjs
// writes p_sick.csv, then python3 model/calibrate.py).
// Prints, at noon and 23:00 each day: true infected (E/I) / model expected (sum of P).
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { join } from 'node:path';
import { inferRisk } from './infer.js';

const dir = process.argv[2];
const read = (f) => readFileSync(join(dir, f));
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
const config = JSON.parse(read('config.json'));
const agents = parseCsv(read('agents_static.csv').toString());
const contacts = parseCsv(gunzipSync(read('contacts.csv.gz')).toString());
for (const c of contacts) { c.t = +c.t; c.distance_m = +c.distance_m; c.duration_s = +c.duration_s; }
const reports = parseCsv(read('reports_tests.csv').toString());
for (const r of reports) { r.t = +r.t; r.target_agent_id = r.target_agent_id || null; }
let rooms = null;
try { rooms = new Map(parseCsv(read('map/rooms.csv').toString()).map((r) => [r.room_id, r])); } catch {}
const startMs = Date.parse(config.start);
const PARAMS = JSON.parse(process.env.PARAMS || '{}');
const risk = inferRisk({ contacts, reports, rooms, agentIds: agents.map((a) => a.agent_id), stepMin: config.step_min, startMs }, PARAMS);

const per = 1440 / config.step_min, want = new Set();
for (let d = 0; d < config.days; d++) { want.add(d * per + per / 2); want.add(d * per + per - 12); }
const lines = gunzipSync(read('timeline.csv.gz')).toString().split('\n');
const h = lines[0].split(','), it = h.indexOf('t'), ia = h.indexOf('agent_id'), is = h.indexOf('disease_state');
const states = new Map();
for (let k = 1; k < lines.length; k++) {
  const f = lines[k].split(','), t = +f[it];
  if (!want.has(t)) continue;
  if (!states.has(t)) states.set(t, []);
  states.get(t).push([f[ia], f[is]]);
}
const day = (ms) => ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][(new Date(ms).getDay() + 6) % 7];
const out = [];
for (const [t, rows] of [...states].sort((a, b) => a[0] - b[0])) {
  const ms = startMs + t * config.step_min * 60000;
  let inf = 0, exp = 0;
  for (const [a, s] of rows) { if (s && (s[0] === 'E' || s[0] === 'I')) inf++; exp += risk.pAt(a, ms); }
  out.push(`${day(ms)}${new Date(ms).getHours()} ${inf}/${exp.toFixed(0)}`);
}
console.log(JSON.stringify(PARAMS).padEnd(22), out.join('  '));
