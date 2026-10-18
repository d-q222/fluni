// Input side of the flu-probability engine (model/smf.js): turns a sim run folder into
//   input = { agentIds, startMs, stepMin, nSteps, rows: {t,a,b,dose}, reports }
// where dose is the unit dose (infector stage factor 1) of each 5-minute contact row.
//
// What the dose is built from, all measured from the agents' simulated movements:
//   distance  contacts.csv distance_m          duration  contacts.csv duration_s
//   shared air  each agent's own location at that step (timeline), NOT the contacts.csv indoor/room_id:
//               the sim writes a pair across a wall as indoor=False with an empty room_id, which looks like
//               a real outdoor pair, and some indoor rows have an empty room_id
//   room size   map/rooms.csv volume_m3        outdoor humidity  real hourly weather (data/)
// Ventilation is deliberately NOT used: Stanford publishes no per-building air-change data and the sim's
// ventilation_ach is a guess per building type, so every room gets the one campus-wide DEFAULTS.defaultAch.
// Stage of illness, P(i), P(j) and time since the meeting belong to the engine.
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULTS, doseModel } from './infer.js';

const HOUR = 3600000, DAY = 86400000;
const WEATHER = join(dirname(fileURLToPath(import.meta.url)), 'data', 'stanford_weather_hourly.csv');
const STATES = ['S', 'E', 'I_pre', 'I_sym', 'I_asym', 'R'];
const ROOM = 0, OUTDOOR = 1, WALL = 2; // contact classes
const CLASS_NAMES = ['room', 'outdoor', 'wall'];

// Walk a CSV buffer without making a string per line (4 M-row runs). Calls fn(S, E) per row with the
// byte offsets of the wanted columns, in the order of `names`.
function scanCsv(buf, names, fn) {
  const n = buf.length, nl = buf.indexOf(10);
  const head = buf.latin1Slice(0, nl < 0 ? n : nl).replace('\r', '').split(',');
  const want = new Int32Array(head.length).fill(-1);
  names.forEach((nm, k) => {
    const c = head.indexOf(nm);
    if (c < 0) throw new Error(`column ${nm} missing`);
    want[c] = k;
  });
  const S = new Int32Array(names.length), E = new Int32Array(names.length);
  let p = nl + 1;
  while (p < n) {
    if (buf[p] === 10 || buf[p] === 13) { p++; continue; } // blank line
    let col = 0, fs = p;
    for (; ; p++) {
      const ch = p < n ? buf[p] : 10;
      if (ch !== 44 && ch !== 10) continue;
      let fe = p;
      if (ch === 10 && fe > fs && buf[fe - 1] === 13) fe--; // CRLF run
      const k = want[col];
      if (k >= 0) { S[k] = fs; E[k] = fe; }
      col++; fs = p + 1;
      if (ch === 10) { p++; break; }
    }
    fn(S, E);
  }
}
const str = (buf, s, e) => buf.latin1Slice(s, e);
const int = (buf, s, e) => { let v = 0; for (let i = s; i < e; i++) v = v * 10 + buf[i] - 48; return v; };
const flag = (buf, s, e) => e > s && buf[s] === 84; // 'T'rue
const num = (buf, s, e) => (e > s ? Number(buf.latin1Slice(s, e)) : NaN);

function parseCsv(text) { // small files only (plain commas)
  const lines = text.split(/\r?\n/);
  const head = lines[0].split(',');
  return lines.slice(1).filter(Boolean).map((l) => {
    const f = l.split(','), r = {};
    head.forEach((h, c) => { r[h] = f[c]; });
    return r;
  });
}
const readGz = (dir, f) => gunzipSync(readFileSync(join(dir, f)));

// Hourly weather -> Map(hour start ms -> {rh, temp}). t_local is naive local time; Date.parse reads it in
// machine-local time exactly like config.start, so the two stay on one clock.
function loadWeather(path) {
  const w = new Map();
  for (const r of parseCsv(readFileSync(path, 'utf8'))) {
    w.set(Date.parse(r.t_local), { rh: +r.outdoor_rh_pct, temp: +r.outdoor_temp_c });
  }
  return w;
}

export function loadRun(dir, params = {}) {
  const config = JSON.parse(readFileSync(join(dir, 'config.json'), 'utf8'));
  const startMs = Date.parse(config.start), stepMin = config.step_min, stepMs = stepMin * 60000;
  const nSteps = Math.round((config.days * DAY) / stepMs), perDay = DAY / stepMs;
  const fixedAch = params.fixedAch ?? DEFAULTS.defaultAch;

  const agentIds = parseCsv(readFileSync(join(dir, 'agents_static.csv'), 'utf8')).map((a) => a.agent_id);
  const nA = agentIds.length, agentIdx = new Map(agentIds.map((id, i) => [id, i]));
  const agentOf = (buf, s, e) => {
    const i = agentIdx.get(str(buf, s, e));
    if (i === undefined) throw new Error(`unknown agent ${str(buf, s, e)}`);
    return i;
  };

  // Rooms: volume and type only, no ventilation_ach (see header). polygon_wkt has quoted commas but comes
  // after the columns we need, so a plain split reads them.
  const rooms = new Map();
  try {
    const lines = readFileSync(join(dir, 'map/rooms.csv'), 'utf8').split(/\r?\n/);
    const head = lines[0].split(','), ci = (n) => head.indexOf(n);
    const [iId, iType, iVol] = [ci('room_id'), ci('room_type'), ci('volume_m3')];
    for (let k = 1; k < lines.length; k++) {
      if (!lines[k]) continue;
      const f = lines[k].split(',', 8);
      rooms.set(f[iId], { volume_m3: f[iVol], room_type: f[iType] });
    }
  } catch { console.warn('no map/rooms.csv: every room gets the default size'); }

  // ---- where each agent is at every step: room index (-1 none), place state, disease state ----
  // Prefer timeline_changes.csv.gz (hold each agent's last kept row); fall back to the full timeline.
  let tlFile = 'timeline_changes.csv.gz';
  let tlBuf;
  try { tlBuf = readGz(dir, tlFile); } catch { tlFile = 'timeline.csv.gz'; tlBuf = readGz(dir, tlFile); }
  const roomIdx = new Map(), roomNames = [];
  const cellRoom = new Int32Array(nA * nSteps).fill(-1);
  const cellPlace = new Uint8Array(nA * nSteps).fill(2); // 0 outdoors/in transit, 1 indoors, 2 off campus
  const cellState = new Uint8Array(nA * nSteps);
  const lastT = new Int32Array(nA).fill(-1), cur = new Int32Array(nA * 3); // held room, place, state per agent
  for (let a = 0; a < nA; a++) { cur[a * 3] = -1; cur[a * 3 + 1] = 2; }
  const fill = (a, upTo) => { // hold agent a's current values over (lastT, upTo)
    for (let t = lastT[a] + 1; t < upTo; t++) {
      const c = a * nSteps + t;
      cellRoom[c] = cur[a * 3]; cellPlace[c] = cur[a * 3 + 1]; cellState[c] = cur[a * 3 + 2];
    }
  };
  scanCsv(tlBuf, ['t', 'agent_id', 'room_id', 'indoor', 'off_map', 'disease_state'], (S, E) => {
    const t = int(tlBuf, S[0], E[0]);
    if (t >= nSteps) return;
    const a = agentOf(tlBuf, S[1], E[1]);
    fill(a, t);
    let r = -1;
    if (E[2] > S[2]) {
      const id = str(tlBuf, S[2], E[2]);
      r = roomIdx.get(id);
      if (r === undefined) { r = roomNames.length; roomIdx.set(id, r); roomNames.push(id); }
    }
    cur[a * 3] = r;
    cur[a * 3 + 1] = flag(tlBuf, S[4], E[4]) ? 2 : flag(tlBuf, S[3], E[3]) ? 1 : 0;
    cur[a * 3 + 2] = Math.max(0, STATES.indexOf(str(tlBuf, S[5], E[5])));
    const c = a * nSteps + t;
    cellRoom[c] = cur[a * 3]; cellPlace[c] = cur[a * 3 + 1]; cellState[c] = cur[a * 3 + 2];
    lastT[a] = t;
  });
  for (let a = 0; a < nA; a++) fill(a, nSteps);
  tlBuf = null;

  // truth at each day end: who is currently infected (E, I_*; not S or R)
  const truth = [];
  for (let d = 0; d < config.days; d++) {
    const t = (d + 1) * perDay - 1, infected = new Uint8Array(nA);
    let n = 0;
    for (let a = 0; a < nA; a++) { const s = cellState[a * nSteps + t]; if (s !== 0 && s !== 5) { infected[a] = 1; n++; } }
    truth.push({ day: d, tMs: startMs + (d + 1) * DAY - 1, n, infected });
  }

  // ---- weather -> one doseModel per distinct (RH, temp), picked per step by the local hour ----
  const weather = loadWeather(params.weatherPath || WEATHER);
  const models = new Map(), unitAt = new Array(nSteps);
  const wx = { hours: 0, rh: [Infinity, 0, -Infinity], inRh: [Infinity, 0, -Infinity], decay: [Infinity, 0, -Infinity], temp: [Infinity, 0, -Infinity] };
  const stat = (s, v) => { s[0] = Math.min(s[0], v); s[1] += v; s[2] = Math.max(s[2], v); };
  const seenHours = new Set();
  for (let t = 0; t < nSteps; t++) {
    const hour = Math.floor((startMs + t * stepMs) / HOUR) * HOUR, w = weather.get(hour);
    if (!w || !Number.isFinite(w.rh) || !Number.isFinite(w.temp)) {
      throw new Error(`no weather for ${new Date(hour).toString()} (step ${t}) in ${params.weatherPath || WEATHER}`);
    }
    const key = `${w.rh},${w.temp}`;
    let m = models.get(key);
    if (!m) { m = doseModel({ ...params.doseParams, defaultAch: fixedAch, outdoorRH: w.rh, outdoorTempC: w.temp }, rooms); models.set(key, m); }
    unitAt[t] = m;
    if (!seenHours.has(hour)) {
      seenHours.add(hour); wx.hours++;
      stat(wx.rh, w.rh); stat(wx.temp, w.temp); stat(wx.inRh, m.indoorRH); stat(wx.decay, m.virusDecay);
    }
  }
  for (const k of ['rh', 'temp', 'inRh', 'decay']) wx[k][1] /= wx.hours;
  wx.distinctModels = models.size;

  // ---- contacts: classify by the agents' own locations, then dose ----
  const cBuf = readGz(dir, 'contacts.csv.gz');
  let cap = 0;
  for (let p = cBuf.indexOf(10); p >= 0; p = cBuf.indexOf(10, p + 1)) cap++;
  const rt = new Int32Array(cap), ra = new Int32Array(cap), rb = new Int32Array(cap), rd = new Float64Array(cap);
  const diag = {
    run: dir, timelineSource: tlFile, fixedAch, rows: 0, kept: 0,
    classes: { room: 0, outdoor: 0, wall: 0 }, droppedOffMap: 0, zeroDoseDropped: 0, unknownRoomRows: 0,
    contactsColumnsCrosstab: {}, disagreeRoom: 0, // mine|theirs, theirs = room (room_id set) / indoorNoRoom / outdoor
    weather: wx, sorted: true,
  };
  const row = { distance_m: 0, distance_tier: 4, duration_s: 0, room_id: '', indoor: false };
  const cross = diag.contactsColumnsCrosstab;
  let n = 0, prevT = -1;
  scanCsv(cBuf, ['t', 'agent_a', 'agent_b', 'distance_m', 'distance_tier', 'duration_s', 'room_id', 'indoor'], (S, E) => {
    diag.rows++;
    const t = int(cBuf, S[0], E[0]);
    const a = agentOf(cBuf, S[1], E[1]), b = agentOf(cBuf, S[2], E[2]);
    const ca = a * nSteps + t, cb = b * nSteps + t;
    const pa = cellPlace[ca], pb = cellPlace[cb];
    if (pa === 2 || pb === 2) { diag.droppedOffMap++; return; }
    const ra_ = cellRoom[ca];
    let cls;
    if (pa === 1 && pb === 1 && ra_ >= 0 && ra_ === cellRoom[cb]) cls = ROOM;
    else if (pa === 0 && pb === 0) cls = OUTDOOR;
    else cls = WALL;
    diag.classes[CLASS_NAMES[cls]]++;
    const theirs = E[6] > S[6] ? 'room' : flag(cBuf, S[7], E[7]) ? 'indoorNoRoom' : 'outdoor';
    const k = `${CLASS_NAMES[cls]}|${theirs}`;
    cross[k] = (cross[k] || 0) + 1;
    if ((cls === ROOM) !== (theirs === 'room')) diag.disagreeRoom++;
    if (cls === WALL) { diag.zeroDoseDropped++; return; } // no shared air
    row.distance_m = num(cBuf, S[3], E[3]);
    row.distance_tier = int(cBuf, S[4], E[4]);
    row.duration_s = num(cBuf, S[5], E[5]);
    if (cls === ROOM) {
      row.indoor = true; row.room_id = roomNames[ra_];
      if (!rooms.has(row.room_id)) diag.unknownRoomRows++;
    } else { row.indoor = false; row.room_id = ''; }
    const dose = unitAt[t](row);
    if (!(dose > 0)) { diag.zeroDoseDropped++; return; }
    if (t < prevT) diag.sorted = false;
    prevT = t;
    rt[n] = t; ra[n] = a; rb[n] = b; rd[n] = dose; n++;
  });
  diag.kept = n;
  let t = rt.slice(0, n), a = ra.slice(0, n), b = rb.slice(0, n), d = rd.slice(0, n);
  if (!diag.sorted) { // contacts.csv is written by step, but the engine needs it: sort by t, stable
    const o = Uint32Array.from({ length: n }, (_, i) => i).sort((x, y) => t[x] - t[y] || x - y);
    t = o.map((i) => t[i]); a = o.map((i) => a[i]); b = o.map((i) => b[i]); d = Float64Array.from(o, (i) => d[i]);
  }

  const reports = parseCsv(readFileSync(join(dir, 'reports_tests.csv'), 'utf8')).map((r) => {
    const ix = (id) => { const i = agentIdx.get(id); if (i === undefined) throw new Error(`unknown agent ${id}`); return i; };
    return { tMs: startMs + Number(r.t) * stepMs, agent: ix(r.agent_id), event: r.event, value: r.value, target: r.target_agent_id ? ix(r.target_agent_id) : -1 };
  }).sort((x, y) => x.tMs - y.tMs);

  const input = { agentIds, startMs, stepMin, nSteps, rows: { t, a, b, dose: d }, reports };
  return { input, diag, truth };
}
