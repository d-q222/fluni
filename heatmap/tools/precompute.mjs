// Precompute for large sim runs (~7,000 agents x 14 days x 5 min = 28 M rows, too big for the browser).
// One streaming pass over timeline.csv.gz writes two small files that the map reads instead:
//   timeline_changes.csv.gz  the timeline with repeated rows dropped: per agent, a row is kept when
//                            something tracked changed, plus the row just before each change (motion.js
//                            stateAt needs it: that is when the stay ended and the walk starts), plus
//                            each agent's first and last rows. Same header and columns as the input.
//   totals.json.gz           everything the user-facing map shows, no agent data: per step and
//                            building the people and expected sick, an hourly forecast at +1/+2/+3 h
//                            and its backtest hit rate.
// Per-step totals follow aggregate.js buildTotals fed with app.js toFrames frames (off_map rows skipped;
// moving or outdoor rows count toward no building). P(sick) is the probability model's (model/infer.js)
// when the run has config.json, contacts.csv.gz and reports_tests.csv, else app.js's appBelief rule.
// The forecast is forecast.js reimplemented on streamed per-agent counts: it needs frames for every
// step at once, which is too big at full scale. Same method, same numbers (see the check script).
//
// Usage: node heatmap/tools/precompute.mjs sim/runs/<run> --out <dir>

import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { createGunzip, createGzip, gzipSync } from 'node:zlib';
import { pipeline } from 'node:stream';
import { once } from 'node:events';
import { basename, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { inferRisk } from '../../model/infer.js';

// Same constants as app.js and forecast.js.
const SMALL_RUN_SCALE = 50, SMALL_RUN_AGENTS = 500, MIN_PEOPLE = 4;
const HORIZONS = [60, 120, 180], EVERY_MIN = 60, SLOT_MIN = 30;
const Z80 = 1.2816, HOUR_MS = 3_600_000;
// A kept row is a change when any of these differ from the agent's previous row.
const TRACKED = ['lat', 'lon', 'location_id', 'room_id', 'floor', 'indoor', 'off_map', 'moving', 'disease_state',
  'self_reported_status', 'test_status', 'isolating', 'activity'];
const TRUE = new Set(['1', 'true', 'True', 'TRUE']); // as app.js

// ---------- args ----------

const args = process.argv.slice(2);
const oi = args.indexOf('--out');
const outDir = oi >= 0 ? args.splice(oi, 2)[1] : null;
const runDir = args[0];
if (!runDir || !outDir) { console.error('usage: node heatmap/tools/precompute.mjs <run_dir> --out <dir>'); process.exit(1); }
mkdirSync(outDir, { recursive: true });
const runName = basename(resolve(runDir));
const T0 = performance.now();
const lap = () => Math.round(performance.now() - T0);

// ---------- helpers ----------

// Lines of a (maybe gzipped) text file, in batches per chunk; never the whole file.
async function* lineBatches(file) {
  const raw = createReadStream(file);
  const s = file.endsWith('.gz') ? pipeline(raw, createGunzip(), () => {}) : raw;
  s.setEncoding('utf8');
  let rest = '';
  for await (const chunk of s) {
    const parts = (rest + chunk).split('\n');
    rest = parts.pop();
    yield parts;
  }
  if (rest) yield [rest];
}

// Plain CSV (small files only; no quoted commas).
function parseCsv(text) {
  const lines = text.split('\n');
  const head = lines[0].trim().split(',');
  const rows = [];
  for (let k = 1; k < lines.length; k++) {
    if (!lines[k].trim()) continue;
    const f = lines[k].replace(/\r$/, '').split(',');
    const r = {};
    for (let c = 0; c < head.length; c++) r[head[c]] = f[c];
    rows.push(r);
  }
  return rows;
}

// Split one record, honouring "quotes" (as loader.js). Multi-line quoted fields are not supported.
function splitQuoted(line) {
  const out = [];
  let cur = '', q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c !== '"') cur += c;
      else if (line[i + 1] === '"') { cur += '"'; i++; } else q = false;
    } else if (c === '"') q = true;
    else if (c === ',') { out.push(cur); cur = ''; } else cur += c;
  }
  out.push(cur);
  return out;
}

// app.js's stand-in for P(sick): own self-report and test result only.
function appBelief(reported, test) {
  if (test === 'positive' || reported === 'tested_positive') return 0.95;
  if (reported === 'might_be_sick') return 0.6;
  if (test === 'negative' || reported === 'recovered') return 0.01;
  return 0.02;
}

const dayKey = (d) => d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
const slotOf = (d) => Math.floor((d.getHours() * 60 + d.getMinutes()) / SLOT_MIN);
const N_SLOTS = Math.ceil(1440 / SLOT_MIN);
const round6 = (x) => Math.round(x * 1e6) / 1e6;
const mb = (n) => (n < 1048576 ? (n / 1024).toFixed(0) + ' KB' : (n / 1048576).toFixed(1) + ' MB');

// ---------- 1. probability model (optional) ----------

// Contacts can be tens of millions: keep them in typed arrays and hand inferRisk an array-like that
// builds each contact object on demand (it reads them once, in order).
async function loadContacts(file, ids) {
  const intern = new Map(ids.map((id, i) => [id, i]));
  const names = ids.slice();
  let cap = 1 << 20, n = 0;
  let t = new Int32Array(cap), a = new Int32Array(cap), b = new Int32Array(cap), tier = new Uint8Array(cap), dur = new Int32Array(cap);
  const grow = (x) => { const y = new x.constructor(cap); y.set(x); return y; };
  let head = null, iT, iA, iB, iTier, iDur, sorted = true;
  const id = (s) => {
    let i = intern.get(s);
    if (i === undefined) { i = names.length; names.push(s); intern.set(s, i); }
    return i;
  };
  for await (const batch of lineBatches(file)) {
    for (const line of batch) {
      if (!line) continue;
      const f = line.replace(/\r$/, '').split(',');
      if (!head) {
        head = f;
        [iT, iA, iB, iTier, iDur] = ['t', 'agent_a', 'agent_b', 'distance_tier', 'duration_s'].map((c) => head.indexOf(c));
        continue;
      }
      if (n === cap) { cap *= 2; t = grow(t); a = grow(a); b = grow(b); tier = grow(tier); dur = grow(dur); }
      t[n] = +f[iT]; a[n] = id(f[iA]); b[n] = id(f[iB]); tier[n] = +f[iTier]; dur[n] = +f[iDur];
      if (n && t[n] < t[n - 1]) sorted = false;
      n++;
    }
  }
  let order = null;
  if (!sorted) order = Uint32Array.from({ length: n }, (_, i) => i).sort((x, y) => t[x] - t[y] || x - y);
  return new Proxy({ length: n }, {
    get(target, k) {
      if (typeof k !== 'string' || k.charCodeAt(0) > 57) return target[k]; // 'length' etc.
      const i = order ? order[+k] : +k;
      return { t: t[i], agent_a: names[a[i]], agent_b: names[b[i]], distance_tier: tier[i], duration_s: dur[i] };
    },
  });
}

let config = {}, risk = null, agentIds = [];
const modelFiles = ['config.json', 'contacts.csv.gz', 'reports_tests.csv', 'agents_static.csv'];
if (existsSync(join(runDir, 'config.json'))) config = JSON.parse(readFileSync(join(runDir, 'config.json'), 'utf8'));
if (modelFiles.every((f) => existsSync(join(runDir, f)))) {
  agentIds = parseCsv(readFileSync(join(runDir, 'agents_static.csv'), 'utf8')).map((a) => a.agent_id);
  const contacts = await loadContacts(join(runDir, 'contacts.csv.gz'), agentIds);
  const reports = parseCsv(readFileSync(join(runDir, 'reports_tests.csv'), 'utf8'));
  for (const r of reports) { r.t = +r.t; r.target_agent_id = r.target_agent_id || null; }
  risk = inferRisk({ contacts, reports, agentIds, stepMin: config.step_min, startMs: Date.parse(config.start) });
  console.log(`model: ${contacts.length} contacts, ${reports.length} reports (${lap()} ms)`);
} else {
  console.warn(`Missing ${modelFiles.filter((f) => !existsSync(join(runDir, f))).join(', ')}: using the appBelief fallback for P(sick).`);
}
const tModel = lap();

// Building ids -> index, names from map/buildings.csv (location_id -> name). Unknown ids get appended.
const buildings = [], bIndex = new Map();
const bOf = (id) => {
  let i = bIndex.get(id);
  if (i === undefined) { i = buildings.length; bIndex.set(id, i); buildings.push({ id, name: id }); }
  return i;
};
const bFile = join(runDir, 'map', 'buildings.csv');
if (existsSync(bFile)) {
  for (const b of parseCsv(readFileSync(bFile, 'utf8'))) if (b.location_id && b.name) buildings[bOf(b.location_id)].name = b.name;
}

// ---------- 2. one pass over the timeline ----------

const tlFile = join(runDir, 'timeline.csv.gz');
const out = createWriteStream(join(outDir, 'timeline_changes.csv.gz'));
const gz = createGzip({ level: 6 });
gz.pipe(out);
let outBuf = [];
const flushOut = async (force) => {
  if (!outBuf.length || (!force && outBuf.length < 20000)) return;
  const ok = gz.write(outBuf.join('\n') + '\n');
  outBuf = [];
  if (!ok) await once(gz, 'drain');
};

let col = null;                 // column indexes
const agents = new Map();       // id -> state
const agentList = [];
let rowsIn = 0, rowsKept = 0, usable = 0;

// Per step: raw building tallies { b, n, sp } (building, people, Σp), times, hourly snapshots.
const steps = [], times = [];
let t0 = null, t0ms = 0, cur = null, prevBuf = null, curBuf = null, nextHour = null;
const stepMs = (config.step_min || 5) * 60000;
const cnt = [], sp = [], touched = [];
const hourly = [];              // { tMs, bid: Int16Array (-2 never seen, -1 no building), p: Float64Array }
const dayIdx = new Map();       // dayKey -> index in order of appearance
const prior = risk ? risk.params.prior : 0;

const newBuf = () => ({ lines: [], ag: [], keep: [] });

function agentOf(id) {
  let a = agents.get(id);
  if (!a) {
    a = {
      id, lastT: -1, sig: '', pos: 0, lastB: -2, lastP: 0, seen: false,
      cellKey: -1, cell: [], days: [], ch: risk ? risk.changes.get(id) || null : null, ptr: 0,
    };
    agents.set(id, a);
    agentList.push(a);
  }
  return a;
}

// P(sick) of agent a at time ms: the model's change points are walked in order (same as model.pAt).
function pOf(a, ms, f) {
  if (!risk) return appBelief(f[col.self_reported_status], f[col.test_status]);
  const ch = a.ch;
  if (!ch || ms < ch[0].tMs) return prior;
  let k = a.ptr;
  while (k + 1 < ch.length && ch[k + 1].tMs <= ms) k++;
  a.ptr = k;
  return ch[k].p;
}

// Close the agent's open (day, 30-min slot) cell: its building is the most frequent one, first seen wins ties.
function closeCell(a) {
  if (a.cellKey < 0) return;
  const day = Math.floor(a.cellKey / N_SLOTS), slot = a.cellKey % N_SLOTS;
  let best = -2, bestN = 0;
  const c = a.cell;
  for (let i = 0; i < c.length; i++) {
    let m = 0;
    for (let j = 0; j < c.length; j++) if (c[j] === c[i]) m++;
    if (m > bestN) { best = c[i]; bestN = m; }
  }
  (a.days[day] || (a.days[day] = new Int16Array(N_SLOTS).fill(-2)))[slot] = best;
  a.cell.length = 0;
  a.cellKey = -1;
}

function endStep() {
  const b = [], n = [], s = [];
  for (const k of touched.sort((x, y) => x - y)) { b.push(k); n.push(cnt[k]); s.push(sp[k]); cnt[k] = 0; sp[k] = 0; }
  touched.length = 0;
  const i = cur.step;
  while (steps.length < i) { steps.push({ b: [], n: [], sp: [] }); times.push(t0ms + steps.length * stepMs); }
  steps[i] = { b, n, sp: s };
  times[i] = cur.ms;
  if (nextHour === null || cur.ms >= nextHour) {
    nextHour = cur.ms + HOUR_MS;
    const bid = new Int16Array(agentList.length), p = new Float64Array(agentList.length);
    agentList.forEach((a, k) => { bid[k] = a.lastB; p[k] = a.lastP; });
    hourly.push({ tMs: cur.ms, bid, p });
  }
}

// Write a step's buffer: the flagged rows, plus any agent that has no row in the next step.
async function flushBuf(buf, nextStep, all) {
  for (let i = 0; i < buf.lines.length; i++) {
    if (all || buf.keep[i] || buf.ag[i].lastT !== nextStep) { outBuf.push(buf.lines[i]); rowsKept++; }
  }
  await flushOut(false);
}

let header = null;
for await (const batch of lineBatches(tlFile)) {
  for (const line of batch) { // lines keep any trailing \r, so kept rows are byte-identical
    if (!line || line === '\r') continue;
    if (!header) {
      header = line;
      const h = splitQuoted(line);
      col = {};
      for (const c of [...TRACKED, 't', 'timestamp', 'agent_id']) {
        col[c] = h.indexOf(c);
        if (col[c] < 0) throw new Error(`timeline needs a "${c}" column`);
      }
      outBuf.push(header);
      continue;
    }
    rowsIn++;
    const f = line.includes('"') ? splitQuoted(line) : line.split(',');
    const t = +f[col.t];
    if (t0 === null) { t0 = t; t0ms = Date.parse(f[col.timestamp]); }
    if (!cur || t !== cur.t) {
      if (cur && t < cur.t) throw new Error(`timeline is not sorted by t (${t} after ${cur.t})`);
      if (cur) {
        endStep();
        if (prevBuf) await flushBuf(prevBuf, cur.step, false);
        prevBuf = curBuf;
      }
      const ms = Date.parse(f[col.timestamp]);
      const d = new Date(ms), dk = dayKey(d);
      if (!dayIdx.has(dk)) dayIdx.set(dk, dayIdx.size);
      cur = { t, step: t - t0, ms, cell: dayIdx.get(dk) * N_SLOTS + slotOf(d) };
      curBuf = newBuf();
    }

    // ---- changes-only timeline
    const a = agentOf(f[col.agent_id]);
    let sig = '';
    for (const c of TRACKED) sig += f[col[c]] + '\u0001';
    const first = a.lastT < 0, gap = !first && a.lastT !== cur.step - 1;
    const changed = first || gap || sig !== a.sig;
    if (changed && !first && !gap) prevBuf.keep[a.pos] = true; // the row just before the change
    a.pos = curBuf.lines.length;
    curBuf.lines.push(line);
    curBuf.ag.push(a);
    curBuf.keep.push(changed);
    a.sig = sig;
    a.lastT = cur.step;

    // ---- totals, as app.js toFrames: off_map rows are skipped; moving or not indoor = no building
    if (TRUE.has(f[col.off_map])) continue;
    if (!Number.isFinite(Number(f[col.lat])) || !Number.isFinite(Number(f[col.lon]))) continue;
    if (!a.seen) { a.seen = true; usable++; }
    const outside = TRUE.has(f[col.moving]) || !TRUE.has(f[col.indoor]);
    const bid = !outside && f[col.location_id] ? bOf(f[col.location_id]) : -1;
    const p = pOf(a, cur.ms, f);
    a.lastB = bid;
    a.lastP = p;
    if (bid >= 0) {
      if (!cnt[bid]) { touched.push(bid); cnt[bid] = 0; sp[bid] = 0; }
      cnt[bid]++;
      sp[bid] += p;
    }
    if (a.cellKey !== cur.cell) { closeCell(a); a.cellKey = cur.cell; }
    a.cell.push(bid);
  }
}
if (!header) throw new Error('empty timeline');
endStep();
if (prevBuf) await flushBuf(prevBuf, cur.step, false);
await flushBuf(curBuf, cur.step, true); // last step: every agent's last row
for (const a of agentList) closeCell(a);
await flushOut(true);
gz.end();
await once(out, 'finish');
const tPass = lap();

// ---------- 3. forecast (forecast.js on streamed counts) ----------

const scale = usable < SMALL_RUN_AGENTS ? SMALL_RUN_SCALE : 1;
const nSteps = steps.length;
const nB = buildings.length;

// Expected sick people per building at hourly snapshot h + horizonMin. Returns Map b -> [expected, lo, hi].
function forecast(h, horizonMin) {
  const snap = hourly[h];
  const T = new Date(snap.tMs + horizonMin * 60000);
  const slot = slotOf(T), dT = dayIdx.get(dayKey(T)); // undefined: a day beyond the data
  const q = new Float64Array(nB), v = new Float64Array(nB), has = new Uint8Array(nB);
  const add = (b, x) => {
    if (!(x > 0)) return;
    has[b] = 1;
    q[b] += x;
    v[b] += x * (1 - x);
  };
  const cb = [], cc = []; // distinct buildings in this slot over the days, and how many days each
  for (let i = 0; i < snap.bid.length; i++) {
    const sb = snap.bid[i];
    if (sb === -2) continue; // not seen yet
    const a = agentList[i], p = snap.p[i];
    const own = dT !== undefined && a.days[dT] ? a.days[dT][slot] : -2; // -2: no sample that day
    let total = 0;
    cb.length = 0; cc.length = 0;
    for (const d of a.days) {
      if (!d || d[slot] === -2) continue;
      total++;
      const k = cb.indexOf(d[slot]);
      if (k < 0) { cb.push(d[slot]); cc.push(1); } else cc[k]++;
    }
    const days = total - (own !== -2 ? 1 : 0); // the target day is excluded from the habits
    if (days > 0) {
      for (let k = 0; k < cb.length; k++) {
        const c = cc[k] - (own !== -2 && own === cb[k] ? 1 : 0);
        if (cb[k] >= 0 && c > 0) add(cb[k], (c / days) * p);
      }
    } else if (sb >= 0) add(sb, p); // no history: assume they stay where they are
  }
  const res = new Map();
  for (let b = 0; b < nB; b++) {
    if (!has[b]) continue;
    const e = scale * q[b], sd = Math.sqrt(scale * v[b]);
    res.set(b, [e, Math.max(0, e - Z80 * sd), e + Z80 * sd]);
  }
  return res;
}

const floorIdx = (t) => {
  let lo = 0, hi = nSteps - 1, r = -1;
  while (lo <= hi) {
    const m = (lo + hi) >> 1;
    if (times[m] <= t) { r = m; lo = m + 1; } else hi = m - 1;
  }
  return r;
};
const nearestIdx = (t) => {
  const k = floorIdx(t);
  if (k < 0) return 0;
  return k + 1 < nSteps && times[k + 1] - t < t - times[k] ? k + 1 : k;
};

const at = [], hit = Object.fromEntries(HORIZONS.map((h) => [h, [0, 0]]));
const last = times[nSteps - 1];
hourly.forEach((snap, h) => {
  const byHorizon = {};
  for (const hz of HORIZONS) {
    const fc = forecast(h, hz);
    byHorizon[hz] = [...fc].map(([b, [e, lo, hi]]) => [b, round6(e), round6(lo), round6(hi)]);
    // backtest: does the actual count at t + horizon fall inside the 80% range? (as forecast.js backtest)
    if (snap.tMs + hz * 60000 > last) continue;
    const s = steps[nearestIdx(snap.tMs + hz * 60000)];
    const actual = new Map(s.b.map((b, k) => [b, scale * s.sp[k]]));
    for (const b of new Set([...fc.keys(), ...actual.keys()])) {
      const f = fc.get(b), x = actual.get(b) || 0;
      hit[hz][1]++;
      if (f ? f[1] <= x && x <= f[2] : x === 0) hit[hz][0]++;
    }
  }
  at.push({ tMs: snap.tMs, byHorizon });
});
const backtest = Object.fromEntries(HORIZONS.map((h) => [h, hit[h][1] ? hit[h][0] / hit[h][1] : 0]));

// ---------- 4. totals.json.gz ----------

const totals = {
  version: 1, run: runName, scale, minPeople: MIN_PEOPLE, stepMs, startMs: times[0], nSteps,
  buildings,
  // per step: [buildingIndex, people, expected sick], both scaled by `scale`; occupied buildings only
  steps: steps.map((s) => s.b.map((b, k) => [b, s.n[k] * scale, round6(scale * s.sp[k])])),
  forecast: { horizons: HORIZONS, everyMin: EVERY_MIN, at },
  backtest,
};
const json = JSON.stringify(totals);
const gzJson = gzipSync(json, { level: 9 });
writeFileSync(join(outDir, 'totals.json.gz'), gzJson);

// ---------- 4b. building_heat.csv (phones; docs/building-heat-format.md) ----------

// The user map's building totals as snapshots every HEAT_EVERY_MIN, for the phone's walk-in warning.
// heat uses the map's own colour scale (√ of expected sick over buildingScaleMax), so a building the
// map shows dark is one the phone warns about: high = past the legend's midpoint (heat ≥ 0.5).
const HEAT_EVERY_MIN = 15;
const peaks = steps.map((st) => Math.max(0, ...st.sp.map((x) => x * scale))).sort((a, b) => a - b);
const heatMax = peaks[Math.floor(0.9 * (peaks.length - 1))] || 1;
const where = new Map();
if (existsSync(bFile)) for (const b of parseCsv(readFileSync(bFile, 'utf8'))) where.set(b.location_id, [b.lat, b.lon, b.area_m2 > 0 ? Math.round(Math.sqrt(b.area_m2 / Math.PI) + 10) : '']);
const pad2 = (x) => String(x).padStart(2, '0');
const isoLocal = (ms) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}T${pad2(d.getHours())}:${pad2(d.getMinutes())}:00`;
};
const csvField = (x) => (/[",\n]/.test(x) ? `"${x.replace(/"/g, '""')}"` : x);
// radius_m (last, optional): a circle of the footprint's area plus 10 m of GPS slack, for geofencing.
const heatRows = ['t_iso,building_id,name,lat,lon,people,expected_sick,heat,high,radius_m'];
let nextSnap = -Infinity;
steps.forEach((st, i) => {
  if (!st.b.length || times[i] < nextSnap) return;
  nextSnap = times[i] + HEAT_EVERY_MIN * 60000;
  st.b.forEach((bi, k) => {
    const people = st.n[k] * scale, sick = st.sp[k] * scale, b = buildings[bi];
    if (people < MIN_PEOPLE) return; // hidden on the map too
    const heat = Math.min(1, Math.sqrt(sick / heatMax)), [lat = '', lon = '', radius = ''] = where.get(b.id) || [];
    heatRows.push([isoLocal(times[i]), b.id, csvField(b.name), lat, lon, people, sick.toFixed(2), heat.toFixed(3), heat >= 0.5 ? 1 : 0, radius].join(','));
  });
});
writeFileSync(join(outDir, 'building_heat.csv'), heatRows.join('\n') + '\n');
console.log(`building_heat.csv: ${heatRows.length - 1} rows, every ${HEAT_EVERY_MIN} min; colour max ${heatMax.toFixed(1)} expected sick`);

// ---------- 5. summary ----------

const tlSize = statSync(tlFile).size;
const chSize = statSync(join(outDir, 'timeline_changes.csv.gz')).size;
const rss = process.resourceUsage().maxRSS / 1024; // KB -> MB
console.log(`
run ${runName}: ${agentList.length} agents, ${nSteps} steps, scale x${scale}, model ${risk ? 'on' : 'off (appBelief fallback)'}
rows in ${rowsIn}, kept ${rowsKept} (${(100 * rowsKept / rowsIn).toFixed(2)}%, ${(rowsIn / rowsKept).toFixed(1)}x fewer)
timeline.csv.gz ${mb(tlSize)} -> timeline_changes.csv.gz ${mb(chSize)}; totals.json.gz ${mb(gzJson.length)} (${mb(json.length)} json)
backtest ${HORIZONS.map((h) => `${h}m ${(100 * backtest[h]).toFixed(0)}%`).join(', ')}
time: model ${tModel} ms, timeline pass ${tPass - tModel} ms, forecast+write ${lap() - tPass} ms, total ${lap()} ms
peak RSS ${rss.toFixed(0)} MB`);
