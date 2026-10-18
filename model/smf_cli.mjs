// Run the flu-probability engine (smf.js) on a sim run folder and compare it with the truth.
// Usage: node model/smf_cli.mjs <run_dir> [out.csv]   (out.csv defaults to model/out/<run>/p_sick_smf.csv;
// same format as p_sick.csv, docs/p-sick-format.md)

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inferRisk } from './infer.js';
import { smfRisk } from './smf.js';
import { loadRun } from './smf_inputs.mjs';

const dir = process.argv[2];
if (!dir) { console.error('usage: node model/smf_cli.mjs <run_dir> [out.csv]'); process.exit(1); }
const out = process.argv[3] || join(dirname(fileURLToPath(import.meta.url)), 'out', basename(dir.replace(/\/$/, '')), 'p_sick_smf.csv');

const t0 = Date.now();
const { input, diag, truth } = loadRun(dir);
const t1 = Date.now();
const risk = smfRisk(input);
console.log(`loaded ${diag.rows} contact rows (${diag.kept} with dose) in ${t1 - t0} ms, engine ${Date.now() - t1} ms\n`);
const f1 = (s) => `${s[0].toFixed(2)} / ${s[1].toFixed(2)} / ${s[2].toFixed(2)}`;
const { weather: wx, ...rest } = diag;
console.log('diag', JSON.stringify(rest));
console.log(`weather over ${wx.hours} h (min / mean / max): outdoor RH ${f1(wx.rh)} %, outdoor temp ${f1(wx.temp)} C, ` +
  `indoor RH ${f1(wx.inRh)} %, virus decay ${f1(wx.decay)} /h; fixed ventilation ${diag.fixedAch} ACH everywhere\n`);

// The current model on the same run, for comparison (same loading as model/cli.mjs).
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
const contacts = parseCsv(gunzipSync(read('contacts.csv.gz')).toString());
for (const c of contacts) { c.t = +c.t; c.distance_m = +c.distance_m; c.duration_s = +c.duration_s; }
const reports = parseCsv(read('reports_tests.csv').toString());
for (const r of reports) { r.t = +r.t; r.target_agent_id = r.target_agent_id || null; }
const rooms = new Map(parseCsv(read('map/rooms.csv').toString()).map((r) => [r.room_id, r]));
const old = inferRisk({ contacts, reports, rooms, agentIds: input.agentIds, stepMin: input.stepMin, startMs: input.startMs });

// AUC (Mann-Whitney, ties count half): chance a random infected agent outranks a random non-infected one.
function auc(scores, truthFlags) {
  const idx = scores.map((_, i) => i).sort((x, y) => scores[x] - scores[y]);
  let rankSum = 0, nPos = 0;
  for (let i = 0; i < idx.length;) {
    let j = i;
    while (j < idx.length && scores[idx[j]] === scores[idx[i]]) j++;
    const avg = (i + j + 1) / 2; // mean 1-based rank of the tie group
    for (let k = i; k < j; k++) if (truthFlags[idx[k]]) { rankSum += avg; nPos++; }
    i = j;
  }
  const nNeg = idx.length - nPos;
  return nPos && nNeg ? (rankSum - (nPos * (nPos + 1)) / 2) / (nPos * nNeg) : NaN;
}

console.log('day\ttrue infected\tsmf sum P_I\tinfer.js sum P\tsmf AUC\tinfer.js AUC');
for (const tr of truth) {
  const d = risk.daily[tr.day];
  const ps = input.agentIds.map((id) => risk.pAt(id, tr.tMs)), po = input.agentIds.map((id) => old.pAt(id, tr.tMs));
  const sum = (x) => x.reduce((s, v) => s + v, 0);
  console.log([tr.day + 1, tr.n, (d ? d.sumI : NaN).toFixed(1), sum(po).toFixed(1), auc(ps, tr.infected).toFixed(3), auc(po, tr.infected).toFixed(3)].join('\t'));
}

const pad = (x) => String(x).padStart(2, '0');
const iso = (ms) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
};
const lines = ['agent_id,t_iso,p_sick'];
for (const id of [...risk.changes.keys()].sort()) for (const c of risk.changes.get(id)) lines.push(`${id},${iso(c.tMs)},${c.p.toFixed(4)}`);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, lines.join('\n') + '\n');
console.log(`\nwrote ${out} (${lines.length - 1} change points)`);
