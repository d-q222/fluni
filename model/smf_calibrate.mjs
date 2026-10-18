// Fit the single dose multiplier c by maximum likelihood on the sim's ground truth.
// Same daily granularity as the model: for each day d and agent i still susceptible at its start,
//   H_i(d) = sum over true sources j (infected before d) of stage(age_j(d)) * D_ji(d)
// and y_i(d) = 1 if i was infected that day on campus. P(infect) = 1 - exp(-c H).
// Usage: node --max-old-space-size=6000 model/smf_calibrate.mjs <run_dir>...
import { loadRun } from '/Users/dqi26/fluni/model/smf_inputs.mjs';
import { readFileSync } from 'node:fs';

const prof = [0.05, 0.3, 1.0, 0.9, 0.6, 0.35, 0.18, 0.08, 0.04, 0.02];
const stage = (g) => (g >= 0 && g < prof.length ? prof[g] : 0);
const OUTSIDE = new Set(['seed', 'import']);

// Per-run data: observations with H > 0 (H = 0 with y = 0 adds nothing to the likelihood; H = 0 with
// y = 1 is unexplainable by any c, so it is counted separately), plus peak-source pair doses.
function collect(dir) {
  const { input } = loadRun(dir);
  const { t, a, b, dose } = input.rows, n = input.agentIds.length;
  const spd = 1440 / input.stepMin, days = Math.ceil(input.nSteps / spd);
  const idx = new Map(input.agentIds.map((id, i) => [id, i]));
  const infDay = new Float64Array(n).fill(Infinity), route = new Array(n), routes = {};
  const lines = readFileSync(`${dir}/infections.csv`, 'utf8').trim().split('\n').slice(1).map((l) => l.split(','));
  lines.sort((x, y) => x[0] - y[0]);
  for (const [tt, who, , rt] of lines) {
    routes[rt] = (routes[rt] || 0) + 1;
    const i = idx.get(who);
    if (i === undefined || infDay[i] < Infinity) continue; // first infection only
    infDay[i] = rt === 'seed' ? -3 : Math.floor(+tt / spd); // seeds start at peak age 2 on day 0: age = d + 2
    route[i] = rt;
  }
  const H = [], Y = [], peakD = [];
  let noH = 0, peakSourceDays = 0;
  const age = (j, d) => d - infDay[j] - 1;
  const flush = (d, pairs) => {
    const hz = new Map(); // agent -> hazard today
    for (const [k, D] of pairs) {
      const x = Math.floor(k / n), y = k % n;
      for (const [j, i] of [[x, y], [y, x]]) {
        if (!(infDay[j] < d) || infDay[i] < d) continue; // j infected before today, i susceptible at start
        const g = age(j, d);
        hz.set(i, (hz.get(i) || 0) + stage(g) * D);
        if (g === 2) peakD.push(D);
      }
    }
    for (const [i, h] of hz) {
      if (infDay[i] === d && route[i] === 'import') continue; // outside infection: not an outcome
      if (h > 0) { H.push(h); Y.push(infDay[i] === d ? 1 : 0); }
    }
    for (let i = 0; i < n; i++) { // on-campus infections today with no dose at all
      if (infDay[i] === d && !OUTSIDE.has(route[i]) && !(hz.get(i) > 0)) noH++;
    }
    for (let j = 0; j < n; j++) if (age(j, d) === 2) peakSourceDays++;
  };
  let day = 0, pairs = new Map();
  for (let r = 0; r < t.length; r++) {
    const d = Math.floor(t[r] / spd);
    while (d > day) { flush(day, pairs); pairs = new Map(); day++; }
    const k = Math.min(a[r], b[r]) * n + Math.max(a[r], b[r]);
    pairs.set(k, (pairs.get(k) || 0) + dose[r]);
  }
  for (; day < days; day++) { flush(day, pairs); pairs = new Map(); }
  const onCampus = Object.entries(routes).filter(([k]) => !OUTSIDE.has(k)).reduce((s, [, v]) => s + v, 0);
  return { H, Y, peakD, peakSourceDays, noH, routes, onCampus };
}

const ll = (o, c) => { let s = 0; for (let k = 0; k < o.H.length; k++) s += o.Y[k] ? Math.log(-Math.expm1(-c * o.H[k])) : -c * o.H[k]; return s; };
const sumP = (H, c) => { let s = 0; for (const h of H) s -= Math.expm1(-c * h); return s; };
function bisect(f, lo, hi) { for (let i = 0; i < 60; i++) { const m = Math.sqrt(lo * hi); (f(m) > 0 ? (hi = m) : (lo = m)); } return Math.sqrt(lo * hi); }
function golden(f, lo = 0.01, hi = 10) { // maximize over log c (log-likelihood is concave in c)
  const g = (Math.sqrt(5) - 1) / 2; let a = Math.log(lo), b = Math.log(hi);
  for (let i = 0; i < 80; i++) { const x1 = b - g * (b - a), x2 = a + g * (b - a); f(Math.exp(x1)) < f(Math.exp(x2)) ? (a = x1) : (b = x2); }
  return Math.exp((a + b) / 2);
}
function report(label, o) {
  const cMLE = golden((c) => ll(o, c));
  const nY = o.Y.reduce((s, y) => s + y, 0);
  const cCount = bisect((c) => sumP(o.H, c) - nY, 1e-4, 100); // sum of predicted = sum of observed
  const peak = (c) => o.peakD.reduce((s, D) => s - Math.expm1(-c * D), 0) / Math.max(1, o.peakSourceDays);
  const routes = Object.entries(o.routes).map(([k, v]) => `${k}:${v}`).join(' ');
  console.log(`${label}: obs ${o.H.length} (y=1: ${nY}) c_MLE ${cMLE.toFixed(3)} c_count ${cCount.toFixed(3)} H=0 infections ${o.noH}/${o.onCampus} on-campus; peak source infects/day ${peak(cMLE).toFixed(2)} (at c=1: ${peak(1).toFixed(2)}); routes ${routes}`);
}

const t0 = Date.now(), all = { H: [], Y: [], peakD: [], peakSourceDays: 0, noH: 0, routes: {}, onCampus: 0 };
for (const dir of process.argv.slice(2)) {
  let o;
  try { o = collect(dir); } catch (e) { console.log(`${dir}: SKIPPED (${e.message})`); continue; }
  report(dir.split('/').pop(), o);
  for (const k of ['H', 'Y', 'peakD']) for (const v of o[k]) all[k].push(v);
  all.peakSourceDays += o.peakSourceDays; all.noH += o.noH; all.onCampus += o.onCampus;
  for (const [k, v] of Object.entries(o.routes)) all.routes[k] = (all.routes[k] || 0) + v;
}
report('POOLED', all);
console.log(`runtime ${((Date.now() - t0) / 1000).toFixed(1)}s`);
