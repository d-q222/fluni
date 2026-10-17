// Run the infection probability model on a sim run folder and print what it concluded.
// Usage: node model/cli.mjs <run_dir> [out.csv]   (out.csv defaults to model/out/<run>/p_sick.csv;
// format in docs/p-sick-format.md)

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inferRisk } from './infer.js';

const dir = process.argv[2];
if (!dir) { console.error('usage: node model/cli.mjs <run_dir> [out.csv]'); process.exit(1); }
const out = process.argv[3] || join(dirname(fileURLToPath(import.meta.url)), 'out', basename(dir.replace(/\/$/, '')), 'p_sick.csv');

// Plain CSV (no quoted commas in these files); numbers stay strings except where converted below.
function parseCsv(text) {
  const lines = text.split('\n');
  const head = lines[0].split(',');
  const rows = [];
  for (let k = 1; k < lines.length; k++) {
    if (!lines[k]) continue;
    const f = lines[k].split(',');
    const r = {};
    for (let c = 0; c < head.length; c++) r[head[c]] = f[c];
    rows.push(r);
  }
  return rows;
}
const read = (f) => readFileSync(join(dir, f));

const config = JSON.parse(read('config.json'));
const agents = parseCsv(read('agents_static.csv').toString());
const contacts = parseCsv(gunzipSync(read('contacts.csv.gz')).toString());
for (const c of contacts) { c.t = +c.t; c.distance_m = +c.distance_m; c.duration_s = +c.duration_s; }
const reports = parseCsv(read('reports_tests.csv').toString());
for (const r of reports) { r.t = +r.t; r.target_agent_id = r.target_agent_id || null; }

const startMs = Date.parse(config.start);
const DAY = 86400000, HOUR = 3600000;
const t0 = Date.now();
const risk = inferRisk({
  contacts, reports, agentIds: agents.map((a) => a.agent_id), stepMin: config.step_min, startMs,
});
console.log(`${contacts.length} contacts, ${reports.length} reports -> inferred in ${Date.now() - t0} ms\n`);

const pad = (x) => String(x).padStart(2, '0');
const day = (ms) => ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][(new Date(ms).getDay() + 6) % 7];
const clock = (ms) => `${day(ms)} ${pad(new Date(ms).getHours())}:${pad(new Date(ms).getMinutes())}`;
const iso = (ms) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
};

console.log('P(sick) at end of each day');
const days = [...Array(config.days).keys()];
console.log(['agent', ...days.map((d) => day(startMs + d * DAY))].join('\t'));
for (const a of agents) {
  console.log([a.agent_id, ...days.map((d) => risk.pAt(a.agent_id, startMs + (d + 1) * DAY - 1).toFixed(3))].join('\t'));
}

for (const id of ['A0002', 'A0003']) {
  console.log(`\nchange points ${id}`);
  for (const c of risk.changes.get(id) || []) console.log(`  ${clock(c.tMs)}  ${c.p.toFixed(3)}`);
}

const wed22 = startMs + 2 * DAY + 22 * HOUR;
console.log(`\nexplain A0002 at ${clock(wed22)}`);
console.log(JSON.stringify(risk.explain('A0002', wed22), (k, v) => (k === 'tMs' ? clock(v) : typeof v === 'number' ? +v.toFixed(3) : v), 2));

console.log('\nflags');
for (const f of risk.flags) console.log(`  ${clock(f.tMs)}  ${f.agentId}  ${f.kind}  ${f.detail}`);
if (!risk.flags.length) console.log('  none');

const lines = ['agent_id,t_iso,p_sick'];
for (const [id, cs] of risk.changes) for (const c of cs) lines.push(`${id},${iso(c.tMs)},${c.p.toFixed(4)}`);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, lines.join('\n') + '\n');
console.log(`\nwrote ${out} (${lines.length - 1} change points)`);
