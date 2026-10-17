import { paint, HEAT_STOPS } from './heat.js';
import { DiffusionField } from './diffuse.js';
import { rasterizeBuildings } from './masks.js';
import { AerosolField, buildWalls } from './aerosol.js';
import { loadCsv } from './loader.js';
import { inferRisk } from '../model/infer.js';
import { renderMathPanel } from './mathpanel.js';
import { Router, buildTracks, stateAt } from './motion.js';
import { buildTotals, totalsAt, buildingScaleMax } from './aggregate.js';
import { buildForecaster } from './forecast.js';
import { BuildingTotalsLayer } from './buildings.js';

// Room-level heat for the presenter (the user map gets building totals instead).
const DEMO = { cellM: 3, sigmaM: 18 };
// Heat is mostly the present: current positions at full weight, plus a faint trail of where people
// were over the last half hour, so a room still reads warm just after people leave. (An hour-long
// average made the heat lag far behind moving dots.)
const MEMORY = { stepMin: 10, steps: 4, tauMin: 15, trail: 0.35 };
const MEMORY_W = Array.from({ length: MEMORY.steps },
  (_, k) => (k === 0 ? 1 : MEMORY.trail * Math.exp((-k * MEMORY.stepMin) / MEMORY.tauMin)));
// The user-facing map sees only per-building totals. Small runs (the mock has 10 agents) are scaled
// so each agent stands for SMALL_RUN_SCALE people; full runs (thousands of agents) show real counts.
const SMALL_RUN_SCALE = 50;
const SMALL_RUN_AGENTS = 500;
const MIN_PEOPLE = 4;
const MAX_DOTS = 600;       // above this, draw a fixed sample of dots; heat and totals still use everyone       // buildings with only 1–3 people are hidden; 4 or more are always shown
const HORIZONS = [[0, 'Now'], [60, 'In 1 hour'], [120, 'In 2 hours'], [180, 'In 3 hours']];
const ADJACENT_M = 1.83;    // "the person next to you" (demo proof of concept, uses sim truth); 6 ft
const ROOM_HOT = 1;         // walk-in warning when the others in the room add up to ≥ 1 expected sick person
const RISKY = 0.5;          // P(sick) at which the app treats someone as risky for proximity alerts
const NEARBY_M = 1.83;      // 6 ft, matching the proximity app (proximity/README.md)
const PAD_M = 120;          // grid margin around the data
const HEAT_BUDGET_MS = 8;   // recompute heat every frame while it costs less than this, else back off
// Phone exposure clock, matching the proximity app: minutes within 6 ft of a risky person over the
// last 24 h, weighted 1 for contagious and 0.5 for possibly sick; close-contact alert at 15 min.
const CLOSE_CONTACT_MIN = 15;
const EXPOSURE_WINDOW_MS = 24 * 3600000;
const NOTICE_WINDOW_MS = 3 * 24 * 3600000; // retroactive exposure notice: contacts who later report sick
const CONTAGIOUS = 0.9;     // P(sick) the app treats as "contagious" (≈ a positive test)
const QUIET_GAP_MS = 2 * 3600_000; // playback skips stretches with no samples at all (e.g. overnight)
const SPEEDS = [2, 10, 30, 60];    // simulated minutes per real second
// Default: the sim's run (needs the server started at the repo root), else the local placeholder.
// ?data=<csv> or ?run=<sim run name>; default: the sim's real sample run, then the mock, then the
// local placeholder.
const DEFAULT_RUN = 'influenza_none_n10_d14_s2_f1f772f6';
const PARAMS = new URLSearchParams(location.search);
// Prefer the run's compact timeline (only rows where something changes; docs/timeline-changes-format.md).
const runUrls = (run) => [`../sim/runs/${run}/timeline_changes.csv.gz`, `../sim/runs/${run}/timeline.csv.gz`];
const DATA_URLS = PARAMS.get('data') ? [PARAMS.get('data')]
  : PARAMS.get('run') ? runUrls(PARAMS.get('run'))
    : [...runUrls(DEFAULT_RUN), ...runUrls('mock_boring10'), 'data/fake_agents.csv'];

const TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const ATTRIBUTION = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
const COLORS = { healthy: '#2a78d6', infected: '#d03b3b', ring: '#fcfcfb', riskLo: [134, 182, 239], riskHi: [13, 54, 107] };

// ---------- CSV adapter: the only place that knows column names ----------

const COLUMNS = {
  t: ['timestamp', 'time', 't'],
  id: ['agent_id', 'id', 'agent'],
  lat: ['lat', 'latitude'],
  lon: ['lon', 'lng', 'long', 'longitude'],
  p: ['p_sick', 'p', 'prob_sick', 'risk'],
  sick: ['sick', 'infected', 'is_sick', 'disease_state'],
  building: ['building', 'building_name', 'location_id'],
  floor: ['floor'],
  room: ['room', 'room_id'],
  moving: ['moving'],
  indoor: ['indoor'],
  offMap: ['off_map'],
  reported: ['self_reported_status'],
  test: ['test_status'],
};

const TRUE = new Set(['1', 'true', 'True', 'TRUE']);
// Truth: 0/1, true/false, or the sim's disease states (exposed or infectious counts as infected).
const INFECTED = new Set([...TRUE, 'E', 'I_pre', 'I_sym', 'I_asym']);
const INFECTIOUS = new Set([...TRUE, 'I_pre', 'I_sym', 'I_asym']); // can pass it on right now

// Stand-in for the probability model's P(sick) until it ships: only what a real app could know,
// i.e. the person's own self-report and test result. Never the hidden disease state.
function appBelief(reported, test) {
  if (test === 'positive' || reported === 'tested_positive') return 0.95;
  if (reported === 'might_be_sick') return 0.6;
  if (test === 'negative' || reported === 'recovered') return 0.01;
  return 0.02;
}

function toFrames(rows, fields, buildingNames) {
  const lower = Object.fromEntries(fields.map((f) => [f.trim().toLowerCase(), f]));
  const col = Object.fromEntries(
    Object.entries(COLUMNS).map(([k, names]) => [k, names.map((n) => lower[n]).find(Boolean)]),
  );
  for (const k of ['t', 'id', 'lat', 'lon']) {
    if (!col[k]) throw new Error(`CSV needs a "${COLUMNS[k][0]}" column (have: ${fields.join(', ')})`);
  }
  const beliefFrom = col.p ? 'column' : col.reported || col.test ? 'reports' : col.sick ? 'truth' : null;
  if (!beliefFrom) throw new Error('CSV needs a p_sick, self-report/test, or sick column');
  if (col.t === lower.t && lower.disease_state) {
    throw new Error('sim CSV without a "timestamp" column: its "t" is a step index, not a time');
  }
  if (beliefFrom !== 'column') console.warn(`No p_sick column: estimating it from ${beliefFrom}.`);

  const byTime = new Map();
  for (const r of rows) {
    if (col.offMap && TRUE.has(r[col.offMap])) continue; // off campus: not on the map
    const sick = col.sick ? INFECTED.has(r[col.sick]) : null;
    const b = col.building ? r[col.building] || null : null;
    const moving = col.moving ? TRUE.has(r[col.moving]) : null;
    const outside = moving || (col.indoor && !TRUE.has(r[col.indoor]));
    const a = {
      id: r[col.id], lat: Number(r[col.lat]), lon: Number(r[col.lon]),
      p: beliefFrom === 'column' ? Number(r[col.p])
        : beliefFrom === 'reports' ? appBelief(r[col.reported], r[col.test]) : Number(sick),
      sick,
      infectious: col.sick ? INFECTIOUS.has(r[col.sick]) : null,
      buildingId: outside ? null : b, // what totals group by; null = outdoors or in transit
      building: (b && buildingNames.get(b)) || b,
      floor: col.floor ? r[col.floor] : null,
      room: col.room ? r[col.room] || null : null,
      moving,
    };
    if (!Number.isFinite(a.lat) || !Number.isFinite(a.lon)) continue;
    const t = r[col.t];
    a.t = toMs(t);
    if (!byTime.has(t)) byTime.set(t, []);
    byTime.get(t).push(a);
  }
  const times = [...byTime.keys()].sort((a, b) => toMs(a) - toMs(b));
  const frames = times.map((t) => byTime.get(t));
  return {
    frames, times: times.map(toMs), samples: frames.flat(), numericTime: Number.isFinite(Number(times[0])),
    hasTruth: Boolean(col.sick), hasRoom: Boolean(col.room), beliefFrom,
  };
}

// ISO timestamps → epoch ms. Plain numbers are taken as seconds since the start of the simulation.
// Guard: the sim's own `t` is a step index, not seconds; COLUMNS prefers its ISO `timestamp`.
const toMs = (t) => (Number.isFinite(Number(t)) ? Number(t) * 1000 : Date.parse(t));

// The probability model (model/infer.js) estimates P(sick) from what a real app could know: contacts
// as phones detect them, self-reports, reports about others, and tests. It needs the run's
// config.json, contacts.csv.gz and reports_tests.csv next to the timeline; null if they're missing.
async function loadModel(dataUrl, agentIds) {
  try {
    const base = new URL(dataUrl, location.href);
    const config = await fetch(new URL('config.json', base)).then((r) => (r.ok ? r.json() : Promise.reject(r.status)));
    const [contacts, reports] = await Promise.all([
      loadCsv(new URL('contacts.csv.gz', base), ['t', 'agent_a', 'agent_b', 'distance_m', 'distance_tier', 'duration_s']),
      loadCsv(new URL('reports_tests.csv', base), ['t', 'agent_id', 'event', 'value', 'target_agent_id']),
    ]);
    const startMs = Date.parse(config.start), stepMs = config.step_min * 60000;
    const risk = inferRisk({ contacts: contacts.data, reports: reports.data, agentIds, stepMin: config.step_min, startMs });
    return { risk, contacts: contacts.data, startMs, stepMs };
  } catch (err) {
    console.warn(`No probability model for this run (${err}); using the placeholder estimate.`);
    return null;
  }
}

// Room outlines for the airflow mode (map/rooms.csv next to the timeline): ids in order + WKT polygons.
async function loadRooms(dataUrl) {
  try {
    const { data } = await loadCsv(new URL('map/rooms.csv', new URL(dataUrl, location.href)), ['room_id', 'polygon_wkt']);
    const rows = data.filter((r) => r.room_id && r.polygon_wkt);
    return { index: new Map(rows.map((r, i) => [r.room_id, i])), wkts: rows.map((r) => r.polygon_wkt) };
  } catch {
    return { index: new Map(), wkts: [] };
  }
}

// The sim keeps building names next to the timeline in map/buildings.csv (location_id → name).
// Also returns building outlines when the run has footprints (footprint_wkt covers every building,
// including places missing from OSM like bld_m_green_library); otherwise null.
async function loadBuildings(dataUrl) {
  try {
    const { data } = await loadCsv(new URL('map/buildings.csv', new URL(dataUrl, location.href)), ['location_id', 'name', 'footprint_wkt']);
    const names = new Map(data.filter((b) => b.location_id && b.name).map((b) => [b.location_id, b.name]));
    const features = data.filter((b) => b.location_id && b.footprint_wkt).map((b) => ({
      type: 'Feature',
      // buildings.js / masks.js key features by 'bld_' + the part after the slash.
      properties: { id: `run/${b.location_id.replace(/^bld_/, '')}`, name: b.name },
      geometry: wktGeometry(b.footprint_wkt),
    }));
    return { names, outlines: features.length ? { type: 'FeatureCollection', features } : null };
  } catch {
    return { names: new Map(), outlines: null };
  }
}

// WKT POLYGON / MULTIPOLYGON (lon lat) → GeoJSON geometry.
function wktGeometry(wkt) {
  const body = String(wkt).replace(/^[A-Z ]+/i, '').trim().replace(/^\(+|\)+$/g, '');
  const polys = body.split(/\)\s*\)\s*,\s*\(\s*\(/).map((poly) => poly.split(/\)\s*,\s*\(/)
    .map((ring) => ring.split(',').map((pt) => pt.trim().split(/\s+/).map(Number))));
  return polys.length === 1 ? { type: 'Polygon', coordinates: polys[0] } : { type: 'MultiPolygon', coordinates: polys };
}

// ---------- Leaflet glue ----------

// A canvas pinned to geographic bounds, scaled with the map (same approach as L.ImageOverlay).
const CanvasLayer = L.Layer.extend({
  initialize(bounds) {
    this.bounds = L.latLngBounds(bounds);
    this.canvas = L.DomUtil.create('canvas', 'heat-canvas leaflet-zoom-animated');
  },
  onAdd(map) {
    map.getPane('overlayPane').appendChild(this.canvas);
    map.on('zoomanim', this.animate, this);
    map.on('viewreset zoomend', this.reset, this);
    this.reset();
  },
  onRemove(map) {
    this.canvas.remove();
    map.off('zoomanim', this.animate, this);
    map.off('viewreset zoomend', this.reset, this);
  },
  reset() {
    const tl = this._map.latLngToLayerPoint(this.bounds.getNorthWest());
    const br = this._map.latLngToLayerPoint(this.bounds.getSouthEast());
    L.DomUtil.setPosition(this.canvas, tl);
    this.canvas.style.width = `${br.x - tl.x}px`;
    this.canvas.style.height = `${br.y - tl.y}px`;
  },
  animate(e) {
    const scale = this._map.getZoomScale(e.zoom);
    const offset = this._map._latLngBoundsToNewLayerBounds(this.bounds, e.zoom, e.center).min;
    L.DomUtil.setTransform(this.canvas, offset, scale);
  },
});

function baseMap(el, options) {
  const map = L.map(el, { preferCanvas: true, zoomSnap: 0.5, ...options });
  L.tileLayer(TILES, { attribution: ATTRIBUTION, maxZoom: 19, className: 'muted-tiles' }).addTo(map);
  return map;
}

// ---------- helpers ----------

function dataBounds(frames) {
  let s = 90, w = 180, n = -90, e = -180;
  for (const f of frames) for (const a of f) {
    s = Math.min(s, a.lat); n = Math.max(n, a.lat); w = Math.min(w, a.lon); e = Math.max(e, a.lon);
  }
  const dLat = PAD_M / 110574, dLon = PAD_M / (111320 * Math.cos(((s + n) / 2) * Math.PI / 180));
  return { south: s - dLat, west: w - dLon, north: n + dLat, east: e + dLon };
}

// The compact timeline keeps only rows where something changes. Totals and forecasts need every agent
// at every step, so expand it back (holding each agent's last row; rows are shared, not copied).
// Fine for small runs; full-size runs should read precomputed totals instead (ROADMAP D1).
function expandSteps(tracks, times, pAt = null) {
  const ts = [...new Set(times)].sort((a, b) => a - b);
  let step = Infinity;
  for (let i = 1; i < ts.length; i++) step = Math.min(step, ts[i] - ts[i - 1]);
  const t0 = ts[0], n = Number.isFinite(step) ? Math.round((ts[ts.length - 1] - t0) / step) + 1 : 1;
  const frames = Array.from({ length: n }, () => []);
  for (const tr of tracks.values()) {
    let j = 0;
    const first = Math.round((tr[0].t - t0) / step), last = Math.round((tr[tr.length - 1].t - t0) / step);
    for (let k = first; k <= last; k++) {
      const t = t0 + k * step;
      while (j + 1 < tr.length && tr[j + 1].t <= t) j++;
      frames[k].push(pAt ? { ...tr[j], p: pAt(tr[j].id, t) } : tr[j]); // risk can change mid-stay
    }
  }
  return { frames, times: Array.from({ length: n }, (_, k) => t0 + k * step) };
}

// Earliest time any agent changes position (or t0 if nobody moves).
function firstMove(tracks, t0) {
  let first = Infinity;
  for (const tr of tracks.values()) {
    for (let i = 1; i < tr.length && tr[i].t < first; i++) {
      if (tr[i].lat !== tr[i - 1].lat || tr[i].lon !== tr[i - 1].lon) { first = tr[i - 1].t; break; }
    }
  }
  return Number.isFinite(first) ? first : t0;
}

// Fixed colour scale shared by every frame: the 90th percentile of peaks at ~60 sampled times, so a
// single extreme moment doesn't wash out the rest. Anything above it shows as the darkest colour.
function scaleMax(heatAt, times) {
  const step = Math.max(1, Math.floor(times.length / 60));
  const peaks = [];
  for (let i = 0; i < times.length; i += step) peaks.push(heatAt(times[i]).max());
  peaks.sort((a, b) => a - b);
  return peaks[Math.floor(0.9 * (peaks.length - 1))] || 1;
}

// Diffusion input: indoor people's heat is confined to buildings, outdoor people's spreads freely.
// truth = heat from who is actually infectious (sim), instead of the app's estimate.
function* asPoints(states, truth) {
  for (const s of states) {
    yield { lat: s.lat, lon: s.lon, p: truth ? Number(Boolean(s.infectious)) : s.p, indoor: Boolean(s.buildingId) };
  }
}

const mix = (a, b, t) => `rgb(${a.map((v, i) => Math.round(v + t * (b[i] - v))).join(',')})`;

function dotColor(a, mode) {
  if (mode === 'truth') return a.sick ? COLORS.infected : COLORS.healthy;
  return mix(COLORS.riskLo, COLORS.riskHi, Math.min(1, a.p));
}

function advice(p) {
  if (p >= 0.4) return 'High. Consider getting tested at Vaden and staying home.';
  if (p >= 0.1) return 'Elevated. Wear a mask in crowded rooms and watch for symptoms.';
  return 'Low. No action needed.';
}

function formatTime(ms, numeric) {
  if (numeric) {
    const m = Math.floor(ms / 60000);
    return `Day ${Math.floor(m / 1440) + 1}, ${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
  }
  return new Date(ms).toLocaleString(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' });
}

const pct = (p) => `${Math.round(p * 100)}%`;
const mPerDegLon = (lat) => 111320 * Math.cos((lat * Math.PI) / 180);

// ---------- app ----------

const $ = (id) => document.getElementById(id);

async function main() {
  let res, dataUrl;
  for (dataUrl of DATA_URLS) {
    // Streamed, gunzipped on the fly, keeping only columns the adapter knows: a 7,000-agent day fits.
    try { res = await loadCsv(dataUrl, Object.values(COLUMNS).flat()); break; } catch (err) { console.warn(`Couldn't load ${dataUrl}: ${err.message}`); }
  }
  if (!res) throw new Error(`couldn't load ${DATA_URLS.join(' or ')}`);
  const [paths, runBuildings, osmOutlines, rooms] = await Promise.all([
    fetch('data/stanford_paths.json').then((r) => r.json()).catch(() => null),
    loadBuildings(dataUrl),
    fetch('../sim/data/osm/buildings.geojson').then((r) => r.json()).catch(() => null),
    loadRooms(dataUrl),
  ]);
  const outlines = runBuildings.outlines || osmOutlines; // the run's own footprints when it has them
  const data = toFrames(res.data, res.fields, runBuildings.names);
  // Replace the placeholder P(sick) with the model's, before tracks, totals and forecasts are built.
  const model = data.beliefFrom === 'column' ? null : await loadModel(dataUrl, [...new Set(data.samples.map((a) => a.id))]);
  if (model) {
    for (const a of data.samples) a.p = model.risk.pAt(a.id, a.t);
    data.beliefFrom = 'column'; // a real estimate now, not a placeholder (legend wording)
  }
  const tracks = buildTracks(data.samples);
  if (/timeline_changes\.csv(\.gz)?$/.test(dataUrl)) {
    Object.assign(data, expandSteps(tracks, data.times, model && model.risk.pAt));
  }
  // Positions interpolate between samples, but risk comes straight from the model when there is one
  // (a compact stay is two rows hours apart; a report mid-stay must show up when it happens).
  const stateNow = (track, t) => {
    const st = stateAt(track, t, router);
    if (st && model) st.p = model.risk.pAt(st.id, t);
    return st;
  };
  const { frames, times } = data;
  const router = paths ? new Router(paths) : null; // without it, agents walk in straight lines
  const bounds = dataBounds(frames);
  const sw = [bounds.south, bounds.west], ne = [bounds.north, bounds.east];
  const t0 = times[0], t1 = times[times.length - 1];

  // Room-level demo heat: deposit people over the last hour, then diffuse within building outlines.
  const probe = new DiffusionField(bounds, DEMO.cellM);
  const mask = outlines ? rasterizeBuildings(outlines, probe).inside : null;
  const field = new DiffusionField(bounds, DEMO.cellM, { mask });
  const statesAt = (t) => {
    const out = [];
    for (const track of tracks.values()) { const st = stateNow(track, t); if (st) out.push(st); }
    return out;
  };
  const heatAt = (t, nowStates = null, truth = false) => {
    field.clear();
    MEMORY_W.forEach((w, k) => {
      field.deposit(asPoints(k === 0 && nowStates ? nowStates : statesAt(t - k * MEMORY.stepMin * 60000), truth), w);
    });
    return field.diffuse(DEMO.sigmaM);
  };
  // Everything the user-facing map gets is computed here, from totals only.
  const scale = tracks.size < SMALL_RUN_AGENTS ? SMALL_RUN_SCALE : 1;
  const totals = buildTotals(frames, times, { scale });
  const forecaster = buildForecaster(frames, times, { scale });
  const backtestRate = forecaster.backtest(60).rate;
  // Airflow (experimental): infectious air that builds up in rooms, leaks through doors and is
  // ventilated away (aerosol.js). Stateful, so it steps forward with the clock; a backward scrub or a
  // big jump resets it and warms it up over the previous AIRFLOW_WARMUP_MS.
  const AIRFLOW_WARMUP_MS = 90 * 60000, AIRFLOW_STEP_MS = 10 * 60000;
  let aero = null, aeroT = null, aeroMax = 1e-9;
  const airSources = function* (states, truth) {
    for (const st of states) {
      const rate = truth ? Number(Boolean(st.infectious)) : st.p;
      if (rate > 0) yield { lat: st.lat, lon: st.lon, rate, room: st.walking ? undefined : rooms.index.get(st.room) };
    }
  };
  const airflowAt = (t, nowStates, truth) => {
    if (!aero) {
      const walls = outlines ? buildWalls(probe, outlines, rooms.wkts) : null;
      aero = new AerosolField(bounds, DEMO.cellM, walls ? { faces: walls.faces, indoor: walls.indoor, region: walls.region } : {});
    }
    if (aeroT === null || t < aeroT || t - aeroT > 3 * 3600000) { aero.reset(); aeroT = t - AIRFLOW_WARMUP_MS; }
    while (aeroT < t) {
      const dt = Math.min(AIRFLOW_STEP_MS, t - aeroT);
      aeroT += dt;
      aero.step(dt / 1000, airSources(aeroT === t && nowStates ? nowStates : statesAt(aeroT), truth));
    }
    aeroMax = Math.max(aeroMax, aero.max()); // relative scale: the strongest seen so far
    return aero;
  };

  const vmax = { demo: scaleMax(heatAt, times), public: buildingScaleMax(totals), truth: null };
  // "True status (sim)" colouring also switches the demo heat to actual infections.
  const truthMode = () => data.hasTruth && $('dot-mode').value === 'truth';
  const demoScale = () => {
    if (!truthMode()) return vmax.demo;
    if (vmax.truth === null) vmax.truth = scaleMax((t) => heatAt(t, null, true), times); // computed on first use
    return vmax.truth;
  };
  if (!outlines) console.warn('No building outlines (serve from the repo root): the user map will be empty.');

  const map = baseMap('map', { maxBounds: L.latLngBounds(sw, ne).pad(0.5) });
  // Fit once the map actually has a size; a page opened in a background tab starts at 0×0.
  let fitted = false;
  new ResizeObserver(() => {
    map.invalidateSize();
    if (fitted || !map.getSize().x || !map.getSize().y) return; // wait for real width *and* height
    fitted = true;
    map.fitBounds([sw, ne]);
    map.setMinZoom(map.getZoom() - 1);
    // ?zoom=19 (with ?agent=…) opens close up on that person, e.g. to watch airflow in their room.
    const zoom = Number(new URLSearchParams(location.search).get('zoom'));
    const me = selected && current.get(selected);
    if (zoom && me) map.setView([me.lat, me.lon], zoom);
  }).observe($('map'));
  const heatLayer = new CanvasLayer([sw, ne]).addTo(map);
  const publicLayer = outlines ? new BuildingTotalsLayer(outlines) : null; // shown in "What users see"

  // Every k-th agent (by id) gets a dot when there are too many to draw smoothly.
  const ids = [...tracks.keys()].sort();
  const dotSample = ids.length > MAX_DOTS ? new Set(ids.filter((_, i) => i % Math.ceil(ids.length / MAX_DOTS) === 0)) : null;
  if (dotSample) {
    document.querySelector('.legend .fine').prepend(`Dots: ${dotSample.size} of ${ids.length.toLocaleString()} people (sample). `);
  }
  const dotRenderer = L.canvas({ padding: 0.5, tolerance: 6 });
  const dotLayer = L.layerGroup().addTo(map);
  const dots = new Map(); // agent id -> circle marker
  let current = new Map(); // agent id -> interpolated state at the current time

  // ?at=<minutes from the start> opens at a specific moment (handy for demos and screenshots).
  // Otherwise start shortly before the first movement, so playback doesn't open on a sleeping campus.
  const at = Number(new URLSearchParams(location.search).get('at'));
  let now = at ? Math.min(t1, t0 + at * 60000) : Math.max(t0, firstMove(tracks, t0) - 10 * 60000), playing = false, selected = null, lastHeat = -Infinity, heatDirty = true, heatInterval = 0;
  let phoneMap = null, phoneBuildings = null, phoneYou = null, airflowTruth = false;

  function dotFor(id) {
    if (dots.has(id)) return dots.get(id);
    const m = L.circleMarker([0, 0], {
      renderer: dotRenderer, radius: 5, weight: 2, color: COLORS.ring, fillOpacity: 1,
    });
    m.bindTooltip(() => {
      const a = current.get(id);
      if (!a) return id;
      const where = a.walking ? 'walking' : [a.building, a.room && `room ${a.room}`].filter(Boolean).join(', ');
      const truth = a.sick === null ? '' : ` · ${a.sick ? 'infected' : 'healthy'} (sim)`;
      return `<b>${id}</b>${where ? ` · ${where}` : ''}<br>App estimate ${pct(a.p)}${truth}`;
    });
    m.on('click', () => select(id));
    dots.set(id, m);
    return m;
  }

  // Is anyone within radiusM of me who matches `test`? Indoors, walls block (same room only).
  function someoneNear(me, radiusM, test) {
    for (const a of current.values()) {
      if (a.id === me.id || !test(a)) continue;
      if (data.hasRoom && !me.walking && (a.building !== me.building || a.room !== me.room)) continue;
      const dy = (a.lat - me.lat) * 110574, dx = (a.lon - me.lon) * mPerDegLon(me.lat);
      if (Math.hypot(dx, dy) <= radiusM) return true;
    }
    return false;
  }

  // Contacts within 6 ft per person, as phones would log them: { tMs, other, min }, by time.
  const exposureLog = new Map();
  if (model) {
    const log = (id, e) => { if (!exposureLog.has(id)) exposureLog.set(id, []); exposureLog.get(id).push(e); };
    for (const c of model.contacts) {
      if (Number(c.distance_m) > NEARBY_M) continue;
      const tMs = model.startMs + Number(c.t) * model.stepMs, min = Number(c.duration_s) / 60;
      log(c.agent_a, { tMs, other: c.agent_b, min });
      log(c.agent_b, { tMs, other: c.agent_a, min });
    }
    for (const list of exposureLog.values()) list.sort((a, b) => a.tMs - b.tMs);
  }
  // Weighted exposure minutes within `windowMs` before t. Live: each contact's risk as the app knew it
  // at the time. Retro: their risk as known now, i.e. people who have since reported sick.
  function exposureMinutes(id, t, windowMs, retro) {
    let total = 0;
    for (const e of exposureLog.get(id) || []) {
      if (e.tMs > t) break;
      if (e.tMs < t - windowMs) continue;
      const p = model.risk.pAt(e.other, retro ? t : e.tMs);
      const w = p >= CONTAGIOUS ? 1 : p >= RISKY ? 0.5 : 0;
      total += w * Math.min(e.min, (t - e.tMs) / 60000);
    }
    return total;
  }

  // What the phone tells this person right now. Proximity uses nearby phones (an immediate heads-up,
  // then a close-contact alert at 15 weighted minutes); the walk-in warning uses room totals only.
  function phoneAlerts(me) {
    const msgs = [];
    if (data.hasTruth && someoneNear(me, ADJACENT_M, (a) => a.infectious)) {
      msgs.push('The person next to you is sick. (Demo: uses the simulation\'s true status.)');
    } else if (someoneNear(me, NEARBY_M, (a) => a.p >= RISKY)) {
      msgs.push('Heads-up: someone within 6 ft may be sick.');
    }
    const live = model ? exposureMinutes(me.id, now, EXPOSURE_WINDOW_MS, false) : 0;
    const later = model ? exposureMinutes(me.id, now, NOTICE_WINDOW_MS, true) : 0;
    if (live >= CLOSE_CONTACT_MIN) {
      msgs.push(`Close contact: about ${Math.round(live)} min within 6 ft of someone who may be sick in the last 24 h. Wear a mask and consider a test at Vaden.`);
    } else if (later >= CLOSE_CONTACT_MIN) {
      msgs.push(`Exposure notice: in the last 3 days you spent about ${Math.round(later)} min within 6 ft of someone who has since reported being sick. Watch for symptoms; a test at Vaden is a good idea.`);
    }
    const room = !me.walking && me.room && totalsAt(totals, now).rooms.get(me.room);
    const others = room ? room.expected - me.p : 0;
    if (others >= ROOM_HOT) {
      msgs.push(`You walked into a room where someone is likely sick (about ${others.toFixed(1)} expected). A mask or another room would be safer.`);
    }
    return msgs;
  }

  // The user-facing map's input: totals now, or a forecast. Never agent data.
  function userTotals() {
    const h = Number($('horizon').value);
    return h ? forecaster.forecast(now, h) : totalsAt(totals, now).buildings;
  }
  const updateUserLayer = (layer) =>
    layer.update(userTotals(), vmax.public, { minPeople: MIN_PEOPLE, forecast: Number($('horizon').value) > 0 });

  // "Why this %?": the model's explanation for the selected person, beside the phone (presenter only).
  const mathBox = Object.assign(document.createElement('aside'), { id: 'math', hidden: true });
  mathBox.setAttribute('aria-label', 'Why this risk');
  mathBox.style.cssText = 'position:absolute;top:16px;right:328px;z-index:1100;width:340px;max-height:calc(100% - 32px);overflow:auto';
  document.querySelector('main').append(mathBox);
  let mathOpen = false, mathKey = '';
  function renderMath() {
    const show = mathOpen && model && selected && current.has(selected);
    mathBox.hidden = !show;
    if (!show) return;
    const key = `${selected}@${Math.floor(now / (5 * 60000))}`; // re-render once per 5 sim-minutes
    if (key === mathKey) return;
    mathKey = key;
    renderMathPanel(mathBox, {
      agentId: selected, tMs: now, explain: model.risk.explain(selected, now), params: model.risk.params,
      formatTime: (ms) => formatTime(ms, data.numericTime),
    });
  }

  function renderPhone(withHeat) {
    const me = selected && current.get(selected);
    renderMath();
    if (!me) { $('phone').hidden = true; return; }
    $('phone').hidden = false;
    $('ph-time').textContent = data.numericTime
      ? formatTime(now, true).split(', ')[1]
      : new Date(now).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    const alerts = phoneAlerts(me);
    $('ph-alert').hidden = !alerts.length;
    $('ph-alert').querySelector('span').replaceChildren(...alerts.map((t) => Object.assign(document.createElement('div'), { textContent: t })));
    $('ph-risk').textContent = pct(me.p);
    $('ph-advice').textContent = advice(me.p);
    const where = me.walking ? 'walking' : me.building;
    $('ph-truth').textContent = `${me.id}${me.sick === null ? '' : me.sick ? ' is infected' : ' is healthy'}${where ? ` · ${where}` : ''}`;

    if (!phoneMap) {
      phoneMap = baseMap('ph-map', { zoomControl: false, attributionControl: false });
      if (outlines) phoneBuildings = new BuildingTotalsLayer(outlines).addTo(phoneMap);
      phoneYou = L.circleMarker([me.lat, me.lon], { radius: 6, weight: 3, color: '#fff', fillColor: COLORS.healthy, fillOpacity: 1 }).addTo(phoneMap);
      phoneMap.setView([me.lat, me.lon], 16);
      withHeat = true;
    }
    phoneYou.setLatLng([me.lat, me.lon]);
    if (withHeat && phoneBuildings) updateUserLayer(phoneBuildings);
    const h = Number($('horizon').value);
    document.querySelector('#phone .ph-section').textContent = h
      ? `Forecast for ${new Date(now + h * 60000).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`
      : 'Around campus now';
  }

  // Move every dot to its interpolated position; repaint heat every frame while it's cheap enough.
  function render(realNow) {
    current = new Map();
    for (const [id, track] of tracks) {
      const s = stateNow(track, now);
      if (s) current.set(id, s);
    }
    $('time').textContent = formatTime(now, data.numericTime);
    $('slider').value = (now - t0) / 60000;

    const view = $('view').value;
    const heatDue = heatDirty || realNow - lastHeat >= heatInterval;
    if (heatDue) {
      const started = performance.now();
      heatLayer.canvas.style.display = view === 'public' ? 'none' : '';
      if (publicLayer) {
        if (view === 'public') { if (!publicLayer.added) { publicLayer.addTo(map); publicLayer.added = true; } updateUserLayer(publicLayer); }
        else if (publicLayer.added) { publicLayer.remove(); publicLayer.added = false; }
      }
      if (view === 'airflow') {
        const st = [...current.values()];
        paint(airflowAt(now, st, truthMode()), heatLayer.canvas, aeroMax);
        if (truthMode() !== airflowTruth) { airflowTruth = truthMode(); aeroT = null; } // source changed: re-warm
      } else if (view !== 'public') paint(heatAt(now, current.values(), truthMode()), heatLayer.canvas, demoScale());
      lastHeat = realNow;
      heatDirty = false;
      const cost = performance.now() - started;
      heatInterval = cost <= HEAT_BUDGET_MS ? 0 : Math.min(250, cost * 3); // keep frames smooth on big runs
    }

    const showDots = $('show-dots').checked && view !== 'public';
    const mode = $('dot-mode').value;
    for (const [id, m] of dots) if (!showDots || !current.has(id) || (dotSample && !dotSample.has(id) && id !== selected)) dotLayer.removeLayer(m);
    if (showDots) {
      for (const a of current.values()) {
        if (dotSample && !dotSample.has(a.id) && a.id !== selected) continue;
        const m = dotFor(a.id);
        m.setLatLng([a.lat, a.lon]).setStyle({ fillColor: dotColor(a, mode) });
        if (!dotLayer.hasLayer(m)) dotLayer.addLayer(m);
      }
    }
    renderPhone(heatDue);
  }

  // Jump over stretches where nobody has a sample (e.g. 23:00 → 07:00).
  function skipQuietGap(t) {
    let i = times.findIndex((x) => x > t);
    if (i > 0 && times[i] - times[i - 1] > QUIET_GAP_MS) return times[i];
    return t;
  }

  let lastFrame = performance.now();
  function tick(realNow) {
    const dt = realNow - lastFrame;
    lastFrame = realNow;
    if (playing) {
      now = skipQuietGap(now + dt * SPEEDS[$('speed').value] * 60);
      if (now >= t1) { now = t1; setPlaying(false); }
      render(realNow);
    }
    requestAnimationFrame(tick);
  }

  function select(id) {
    selected = id;
    renderPhone(true);
    if (phoneMap) {
      phoneMap.invalidateSize();
      const me = current.get(id);
      if (me) phoneMap.setView([me.lat, me.lon], 16);
    }
  }

  function renderLegend() {
    const v = $('view').value;
    $('ramp').style.background = `linear-gradient(to right, ${HEAT_STOPS.map(([t, c]) => `rgba(${c[0]},${c[1]},${c[2]},${Math.max(c[3], 40) / 255}) ${t * 100}%`).join(', ')})`;
    // Colour scale is √, so the midpoint is a quarter of the maximum.
    const unit = v === 'public' ? 1 : 1000; // public: sick people per building; demo: per 1,000 m²
    const top = v === 'public' ? vmax.public : demoScale();
    $('vmid').textContent = v === 'airflow' ? '' : (top * unit / 4).toFixed(1);
    $('vmax').textContent = v === 'airflow' ? 'strongest so far' : `${(top * unit).toFixed(1)}+`;
    document.querySelector('.legend h2').innerHTML = v === 'airflow'
      ? `Infectious air <span>relative, experimental${truthMode() ? ' (sim truth)' : ''}</span>`
      : v === 'public'
      ? `Expected sick people <span>per building${scale > 1 ? ` (each sim agent = ${scale})` : ''}</span>`
      : truthMode() ? 'Actually infectious <span>per 1,000 m² (sim truth)</span>' : 'Expected infected <span>per 1,000 m²</span>';
    const showDots = $('show-dots').checked && v !== 'public';
    const key = (color, label) => `<div class="key"><span class="swatch" style="background:${color}"></span>${label}</div>`;
    $('dot-legend').innerHTML = !showDots ? '' : $('dot-mode').value === 'truth'
      ? key(COLORS.healthy, 'Healthy (sim truth)') + key(COLORS.infected, 'Infected (sim truth)')
      : `<div class="key">App's estimate of P(sick)${data.beliefFrom === 'column' ? '' : data.beliefFrom === 'reports' ? ' (placeholder: from self-reports and tests)' : ' (placeholder: true status)'}:</div><div class="ramp" style="background:linear-gradient(to right, ${mix(COLORS.riskLo, COLORS.riskHi, 0)}, ${mix(COLORS.riskLo, COLORS.riskHi, 1)})"></div><div class="ramp-labels"><span>0%</span><span>100%</span></div>`;
    $('dot-mode').disabled = !data.hasTruth;
  }

  function setPlaying(on) {
    playing = on;
    $('play').dataset.playing = on;
    $('play').setAttribute('aria-label', on ? 'Pause' : 'Play');
  }

  $('slider').max = (t1 - t0) / 60000;
  $('slider').addEventListener('input', (e) => {
    now = t0 + Number(e.target.value) * 60000;
    heatDirty = true;
    render(performance.now());
  });
  $('play').addEventListener('click', () => {
    if (!playing && now >= t1) now = t0;
    setPlaying(!playing);
  });
  // Experimental airflow heat (aerosol.js); added here so the page markup stays the design pass's.
  $('view').append(new Option('Airflow heat (experimental)', 'airflow'));

  // Forecast picker for the user-facing map, built here so the page markup stays the design pass's.
  const horizon = Object.assign(document.createElement('select'), { id: 'horizon', ariaLabel: 'Forecast' });
  horizon.append(...HORIZONS.map(([m, label]) => new Option(label, m)));
  document.querySelector('.options').append(horizon);
  // ?view=public&horizon=60 open straight into the user-facing map / a forecast.
  const params = new URLSearchParams(location.search);
  if (params.get('view')) $('view').value = params.get('view');
  if (params.get('horizon')) horizon.value = params.get('horizon');
  if (params.get('color')) $('dot-mode').value = params.get('color'); // ?color=truth: heat + dots from sim truth
  document.querySelector('#phone .screen .fine').textContent =
    `Buildings with fewer than ${MIN_PEOPLE} people are hidden${scale > 1 ? `; each simulated person stands for ${scale}` : ''}. May be incomplete because not everyone shares their status.`
    + (Number.isFinite(backtestRate) ? ` Forecasts landed in their range ${Math.round(backtestRate * 100)}% of the time when tested on past days.` : '');

  for (const id of ['view', 'show-dots', 'dot-mode', 'horizon']) {
    $(id).addEventListener('change', () => { renderLegend(); heatDirty = true; render(performance.now()); });
  }
  if (model) {
    const why = Object.assign(document.createElement('button'), { textContent: 'Why this %?' });
    $('ph-close').before(why);
    why.addEventListener('click', () => { mathOpen = !mathOpen; mathKey = ''; renderMath(); });
  }
  $('ph-close').addEventListener('click', () => { selected = null; renderPhone(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { selected = null; renderPhone(); } });

  $('status').hidden = true;
  renderLegend();
  render(performance.now());
  requestAnimationFrame(tick);
  const agentParam = new URLSearchParams(location.search).get('agent'); // ?agent=a018 opens that phone
  if (agentParam) select(agentParam);
  if (PARAMS.get('why') && model) { mathOpen = true; renderMath(); } // ?why=1 opens the explanation
  window.fluni = { data, map, vmax, totals, forecaster, model, select, seek: (t) => { now = t; heatDirty = true; render(performance.now()); } };
}

main().catch((err) => {
  console.error(err);
  $('status').textContent = `Couldn't load the agent data: ${err.message}`;
});
