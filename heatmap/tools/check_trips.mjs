// Checks motion.js trip positions against an independent re-implementation of the sim viewer's formula
// (sim/campussim/viewer_template.html tripAt/tripLL) and times stateAt on a run.
// Usage: node heatmap/tools/check_trips.mjs [sim/runs/<run>]
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { buildTracks, buildTrips, attachTrips, stateAt } from '../motion.js';

const dir = process.argv[2] || 'sim/runs/influenza_none_n500_d2_s42_aea9db72';
const cfg = JSON.parse(readFileSync(`${dir}/config.json`, 'utf8'));
const [head, ...lines] = gunzipSync(readFileSync(`${dir}/trips.csv.gz`)).toString().trim().split(/\r?\n/);
const cols = head.split(',');
const rows = lines.map((l) => Object.fromEntries(l.split(',').map((v, i) => [cols[i], v])));
const startMs = Date.parse(cfg.start), stepMs = cfg.step_min * 60000;
const trips = buildTrips(rows, { startMs, stepMs, originLat: cfg.local_frame.origin_lat });

// Reference: straight from the spec, linear scan, later trip wins.
const KX = 111320 * Math.cos(cfg.local_frame.origin_lat * Math.PI / 180), KY = 110540;
function ref(agent, tau) {
  let hit = null;
  for (const r of rows) {
    if (r.agent_id !== agent || tau < +r.t_start - 1 || tau > +r.t_end) continue;
    if (!hit || +r.t_start >= +hit.t_start) hit = r; // rows are in start order; later wins
  }
  if (!hit) return null;
  const pts = hit.path.split(';').map((p) => p.split(' ').map(Number));
  const cum = [0];
  for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + Math.hypot((pts[i][0] - pts[i - 1][0]) * KX, (pts[i][1] - pts[i - 1][1]) * KY));
  const tot = cum.at(-1), ts = +hit.t_start;
  const d = tau < ts ? +hit.start_m * (tau - ts + 1) : Math.min(tot, +hit.start_m + +hit.speed_mps * cfg.step_min * 60 * (tau - ts));
  let i = 1; while (i < pts.length - 1 && cum[i] < d) i++;
  const f = cum[i] > cum[i - 1] ? Math.min(1, Math.max(0, (d - cum[i - 1]) / (cum[i] - cum[i - 1]))) : 0;
  return [pts[i - 1][0] + f * (pts[i][0] - pts[i - 1][0]), pts[i - 1][1] + f * (pts[i][1] - pts[i - 1][1])];
}

const ids = [...trips.byAgent.keys()];
const T1 = startMs + cfg.days * 86400000;
const samples = ids.map((id) => [0, 1].map((k) => ({ t: k ? T1 : startMs, id, p: 0, lat: 0, lon: 0, sick: false })).flat()).flat();
const tracks = buildTracks(samples);
attachTrips(tracks, trips);

let maxErr = 0, checked = 0;
const rnd = (() => { let s = 7; return () => (s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32; })();
const m = (dlon, dlat) => Math.hypot(dlon * KX, dlat * KY);
for (let n = 0; n < 4000; n++) {
  const r = rows[Math.floor(rnd() * rows.length)];
  const tau = +r.t_start - 1 + rnd() * (+r.t_end - +r.t_start + 3); // around the trip, incl. ramp
  const want = ref(r.agent_id, tau);
  const got = stateAt(tracks.get(r.agent_id), startMs + tau * stepMs);
  if (!want) continue;
  maxErr = Math.max(maxErr, m(got.lon - want[0], got.lat - want[1]));
  checked++;
}
console.log(`${checked} positions checked, max error ${maxErr.toExponential(2)} m`);

// Timing: every agent at many times, like a frame loop.
const list = ids.map((id) => tracks.get(id));
for (let w = 0; w < 3; w++) for (let t = startMs; t < startMs + 86400000; t += 20000) for (const tr of list) stateAt(tr, t);
const t0 = performance.now(); let calls = 0;
for (let t = startMs + 8 * 3600000; t < startMs + 20 * 3600000; t += 16000) for (const tr of list) { stateAt(tr, t); calls++; }
const ms = performance.now() - t0;
console.log(`${list.length} agents: ${(ms / calls * 1000).toFixed(2)} us/call, ${(ms / calls * list.length).toFixed(2)} ms per frame`);
