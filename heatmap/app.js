import { paint, HEAT_STOPS } from './heat.js';
import { DiffusionField } from './diffuse.js';
import { rasterizeBuildings } from './masks.js';
import { AerosolField, buildWalls } from './aerosol.js';
import { loadCsv } from './loader.js';
import { inferRisk } from '../model/infer.js';
import { renderMathPanel } from './mathpanel.js';
import { Router, buildTracks, buildTrips, attachTrips, stateAt } from './motion.js';
import { buildTotals, totalsAt, buildingScaleMax } from './aggregate.js';
import { buildForecaster } from './forecast.js';
import { BuildingTotalsLayer } from './buildings.js';

// Room-level heat for the presenter (the user map gets building totals instead).
const DEMO = { cellM: 3, sigmaM: 18 };
// Heat is the expected number of infected people near each point right now: Σ P(sick) of the people
// there, spread by the diffusion kernel (which integrates to 1, so a cloud holds exactly its people's
// expected count). No trail of past positions: that counted people who had already left. Infectious
// air that lingers after people leave is the sim's own room view ("Infectious air by room").
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
const DEFAULT_RUN = 'influenza_none_n10_d14_s2_bc5cae7a';
const PARAMS = new URLSearchParams(location.search);
// ?embed=app: the Swift app's heat map tab. Only the user-facing map fills the screen: no presenter
// controls, no people. Styled from here so index.html stays the design pass's.
const EMBED = PARAMS.get('embed') === 'app';
if (EMBED) {
  document.documentElement.classList.add('embed');
  document.head.append(Object.assign(document.createElement('style'), { textContent: `
    html.embed body { grid-template-rows: 1fr; }
    html.embed header.bar, html.embed #phone { display: none; }
    html.embed .embed-chip { position: absolute; z-index: 500; top: calc(10px + env(safe-area-inset-top)); left: 10px; right: 10px;
      display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 6px 6px 12px;
      background: var(--surface); border-radius: var(--radius); box-shadow: var(--shadow); font-size: 13px; }
    html.embed .embed-chip #time { min-width: 0; font-variant-numeric: tabular-nums; }
    html.embed .embed-chip select { font: inherit; max-width: 50%; }
    html.embed .leaflet-top { top: 52px; }
    html.embed .legend { left: 10px; right: 10px; width: auto; bottom: calc(10px + env(safe-area-inset-bottom)); }
  ` }));
}
// Prefer the run's compact timeline (only rows where something changes; docs/timeline-changes-format.md).
const runUrls = (run) => [`../sim/runs/${run}/timeline_changes.csv.gz`, `../sim/runs/${run}/timeline.csv.gz`];
const DATA_URLS = PARAMS.get('data') ? [PARAMS.get('data')]
  : PARAMS.get('run') ? runUrls(PARAMS.get('run'))
    : runUrls(DEFAULT_RUN); // no silent fallback to mock or fake data: a failure must be visible

const TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const ATTRIBUTION = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
// Palette tokens from index.html (--sage, --sun, --fire, --surface). People run sage → sun → fire by
// estimated risk, so the middle of the scale is a clear yellow instead of a muddy green-red mix.
const COLORS = { healthy: '#acbc8b', infected: '#db6c59', ring: '#fffaf1', risk: [[172, 188, 139], [235, 209, 135], [219, 108, 89]] };

// People are drawn as @lisaazheng's hand-drawn tissue (assets/people/tissue.png) on a round badge in
// their risk colour. It's still a canvas circle marker underneath, so clicks, tooltips and speed are
// unchanged; only the drawing step adds the image. Until the image loads, the plain badge shows.
const PERSON = { radius: 13, img: new Image(), size: 22, onload: null }; // image stays inside the badge so canvas redraws leave no trails
PERSON.img.onload = () => PERSON.onload && PERSON.onload();
PERSON.img.src = 'assets/people/tissue.png';
const PersonMarker = L.CircleMarker.extend({
  _updatePath() {
    this._renderer._updateCircle(this);
    const ctx = this._renderer._ctx, p = this._point, s = PERSON.size;
    if (!ctx || this._empty() || !PERSON.img.complete || !PERSON.img.naturalWidth) return;
    ctx.drawImage(PERSON.img, p.x - s / 2, p.y - s / 2 - 1, s, s);
  },
});

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
  shed: ['infectiousness'], // the sim's per-person shedding rate (0 when not infectious)
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
      // How infectious, from the sim when it says (I_pre ~0.04, I_asym ~0.4, I_sym up to ~2.9); else 0/1.
      infectious: col.shed && r[col.shed] !== '' ? Number(r[col.shed]) : col.sick ? Number(INFECTIOUS.has(r[col.sick])) : null,
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
    // Sim truth about each person (honesty, compliance, ...), shown to the presenter only.
    const traits = await loadCsv(new URL('agents_static.csv', base), ['agent_id', 'archetype', 'honesty', 'compliance', 'has_app', 'shares_location', 'sickness_behavior_profile'])
      .then((r) => new Map(r.data.map((a) => [a.agent_id, a])), () => new Map());
    return { risk, contacts: contacts.data, startMs, stepMs, traits };
  } catch (err) {
    console.warn(`No probability model for this run (${err}); using the placeholder estimate.`);
    return null;
  }
}

// The sim's logged routes next to the timeline (trips.csv.gz, docs/sim-output-format.md); null if missing.
async function loadTrips(dataUrl) {
  try {
    const base = new URL(dataUrl, location.href);
    const config = await fetch(new URL('config.json', base)).then((r) => (r.ok ? r.json() : Promise.reject(r.status)));
    const { data } = await loadCsv(new URL('trips.csv.gz', base),
      ['agent_id', 't_start', 't_end', 'mode', 'speed_mps', 'start_m', 'path']);
    return buildTrips(data, { startMs: Date.parse(config.start), stepMs: config.step_min * 60000, originLat: config.local_frame?.origin_lat });
  } catch (err) {
    console.warn(`No trips for this run (${err}); routing walkers with the footpath graph.`);
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
    const { data } = await loadCsv(new URL('map/buildings.csv', new URL(dataUrl, location.href)), ['location_id', 'name', 'type', 'footprint_wkt']);
    const names = new Map(data.filter((b) => b.location_id && b.name).map((b) => [b.location_id, b.name]));
    const features = data.filter((b) => b.location_id && b.footprint_wkt).map((b) => ({
      type: 'Feature',
      // buildings.js / masks.js key features by 'bld_' + the part after the slash.
      properties: { id: `run/${b.location_id.replace(/^bld_/, '')}`, name: b.name, type: b.type },
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

// Base maps (?basemap=sim|streets|drawn):
// - sim: the sim viewer's look (@aidenyj): OpenFreeMap's Positron vector map, with the run's own map on
//   top (its building footprints and the path network people walk). Loaded on first use. Default.
// - streets: OSM raster tiles, greyed.
// - drawn: the design pass's illustrated campus (assets/trace/), an image on a canvas that maps exactly
//   onto its bounds file; a hand-drawn version can replace the same image. Needs no tile server.
const DRAWN = { image: 'assets/trace/campus_trace.webp', bounds: 'assets/trace/campus_trace_bounds.json' };
const GL = {
  style: 'https://tiles.openfreemap.org/styles/positron',
  css: 'https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css',
  js: 'https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js',
  leaflet: 'https://unpkg.com/@maplibre/maplibre-gl-leaflet@0.1.3/leaflet-maplibre-gl.js',
};
// Buildings in one neutral tint: the viewer colours them by type, but here warm tints would read as heat.
const SIM_BUILDING = { fillColor: '#e7dfd0', fillOpacity: 0.75, color: '#a8988a', weight: 0.7, opacity: 0.8 };
const STYLES = ['sim', 'streets', 'drawn'];
const bases = new Map(); // map -> { streets, drawn, sim } layers, made on first use
let baseStyle = STYLES.includes(PARAMS.get('basemap')) ? PARAMS.get('basemap') : 'sim';
let drawnBounds = null, glReady = null, simMap = null; // simMap: { buildings, paths } from the run

function baseMap(el, options) {
  const map = L.map(el, { preferCanvas: true, zoomSnap: 0.5, ...options });
  map.createPane('simPane').style.zIndex = 250; // above base tiles, below heat, fills and people
  bases.set(map, {});
  applyBase(map);
  return map;
}

const loadScript = (src) => new Promise((ok, fail) => document.head.append(
  Object.assign(document.createElement('script'), { src, onload: ok, onerror: () => fail(new Error(`couldn't load ${src}`)) })));
function loadGl() {
  glReady ||= (async () => {
    document.head.append(Object.assign(document.createElement('link'), { rel: 'stylesheet', href: GL.css }));
    await loadScript(GL.js);
    await loadScript(GL.leaflet);
  })();
  return glReady;
}

// The run's own map for the sim style; called once the run is loaded.
function setSimMap(data) {
  simMap = data;
  if (baseStyle === 'sim') for (const map of bases.keys()) applyBase(map);
}

async function setBaseStyle(style) {
  baseStyle = style;
  try {
    if (style === 'drawn' && !drawnBounds) {
      const b = await fetch(DRAWN.bounds).then((r) => r.json());
      drawnBounds = [[b.south, b.west], [b.north, b.east]];
    }
    if (style === 'sim') await loadGl();
  } catch (err) {
    console.warn(`Base map "${style}" unavailable (${err.message}); using street tiles.`);
    baseStyle = 'streets';
  }
  for (const map of bases.keys()) applyBase(map);
}

function layerFor(map, base, style) {
  if (style === 'streets') return (base.streets ||= L.tileLayer(TILES, { attribution: ATTRIBUTION, maxZoom: 19, className: 'muted-tiles' }));
  if (style === 'drawn') return drawnBounds && (base.drawn ||= L.imageOverlay(DRAWN.image, drawnBounds, { pane: 'tilePane', attribution: ATTRIBUTION }));
  if (!window.L.maplibreGL) return null;
  if (!base.sim) {
    base.sim = L.layerGroup([L.maplibreGL({ style: GL.style })]);
    base.simData = null;
  }
  if (simMap && base.simData !== simMap) { // the run's buildings and paths, drawn like the sim viewer
    base.simData = simMap;
    const renderer = L.canvas({ pane: 'simPane' });
    const attribution = '<a href="https://openfreemap.org">OpenFreeMap</a> ' + ATTRIBUTION;
    if (simMap.paths) base.sim.addLayer(L.geoJSON(simMap.paths, { pane: 'simPane', renderer, interactive: false, attribution,
      style: { color: '#8aa39b', weight: 1.2, opacity: 0.55 } }));
    if (simMap.buildings) base.sim.addLayer(L.geoJSON(simMap.buildings, { pane: 'simPane', renderer, interactive: false,
      attribution: simMap.paths ? undefined : attribution, style: SIM_BUILDING }));
  }
  return base.sim;
}

function applyBase(map) {
  const base = bases.get(map);
  const layer = layerFor(map, base, baseStyle);
  if (!layer) { setBaseStyle(baseStyle); return; } // not loaded yet (first use, or ?basemap=)
  for (const style of STYLES) { const l = base[style]; if (l && l !== layer) l.remove(); }
  if (!map.hasLayer(layer)) layer.addTo(map);
  map.getContainer().style.background = baseStyle === 'drawn' ? '#fff' : ''; // the illustration's own paper colour
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

// What to fit on screen at load: the middle 96% of positions, so a few trips far off campus (a
// commuter's home) don't zoom the map out to all of Palo Alto. The heat grid still uses dataBounds.
function viewBounds(frames) {
  const lats = [], lons = [];
  const every = Math.max(1, Math.floor(frames.length / 400));
  for (let k = 0; k < frames.length; k += every) for (const a of frames[k]) { lats.push(a.lat); lons.push(a.lon); }
  if (!lats.length) return null;
  const q = (v, f) => v.sort((x, y) => x - y)[Math.floor(f * (v.length - 1))];
  return [[q(lats, 0.02), q(lons, 0.02)], [q(lats, 0.98), q(lons, 0.98)]];
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
    yield { lat: s.lat, lon: s.lon, p: truth ? Number(s.infectious) || 0 : s.p, indoor: Boolean(s.buildingId) };
  }
}

const mix = (a, b, t) => `rgb(${a.map((v, i) => Math.round(v + t * (b[i] - v))).join(',')})`;
// One set of risk tiers for everything the presenter and user see: the phone's advice, the risk card's
// colour, the people badges and the legend. Low < 10% (sage), Elevated 10–40% (sun), High ≥ 40% (fire).
const TIERS = { elevated: 0.1, high: 0.4 };
const riskTier = (p) => (p >= TIERS.high ? 'high' : p >= TIERS.elevated ? 'elevated' : 'low');
// Blends only near each threshold, so a colour always matches its tier's advice.
const riskColor = (p) => {
  const [lo, mid, hi] = COLORS.risk, e = TIERS.elevated, h = TIERS.high;
  if (p < e) return mix(lo, mid, Math.max(0, (p - 0.7 * e) / (0.3 * e)));
  if (p < h) return mix(mid, hi, Math.max(0, (p - (h - 0.08)) / 0.08));
  return mix(hi, hi, 0);
};

function dotColor(a, mode) {
  if (mode === 'truth') return a.sick ? COLORS.infected : COLORS.healthy;
  return riskColor(Math.min(1, a.p));
}

function advice(p) {
  if (riskTier(p) === 'high') return 'High. Consider getting tested at Vaden and staying home.';
  if (riskTier(p) === 'elevated') return 'Elevated. Wear a mask in crowded rooms and watch for symptoms.';
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
  setSimMap({ buildings: runBuildings.outlines,
    paths: await fetch(new URL('map/paths.geojson', new URL(dataUrl, location.href))).then((r) => r.json()).catch(() => null) });
  const data = toFrames(res.data, res.fields, runBuildings.names);
  // Replace the placeholder P(sick) with the model's, before tracks, totals and forecasts are built.
  const model = data.beliefFrom === 'column' ? null : await loadModel(dataUrl, [...new Set(data.samples.map((a) => a.id))]);
  if (model) {
    for (const a of data.samples) a.p = model.risk.pAt(a.id, a.t);
    data.beliefFrom = 'column'; // a real estimate now, not a placeholder (legend wording)
  }
  const tracks = buildTracks(data.samples);
  // Walk the sim's own logged routes (trips.csv.gz) when the run has them; the Router is the fallback.
  const trips = await loadTrips(dataUrl);
  if (trips) attachTrips(tracks, trips);
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
  // No people field: nothing masks by it.
  // The spread follows the zoom: 18 m (room-level) close up, about 16 screen pixels when zoomed out, so a
  // cloud never shrinks to a dot. Set by the map's zoom (see sigmaForZoom below).
  let sigmaM = DEMO.sigmaM;
  const heatAt = (t, nowStates = null, truth = false) => {
    field.clear();
    field.deposit(asPoints(nowStates || statesAt(t), truth), 1);
    return field.diffuse(sigmaM, { people: false });
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

  // Infectious air by room, straight from the simulator: room_exposure.csv.gz has the sim's own
  // quanta concentration for every occupied room and step (Wells-Riley, with each room's volume and
  // ventilation). Nothing is re-estimated here; each room is filled with its value. Loaded on first use.
  const simStart = model ? model.startMs : t0, simStepMs = model ? model.stepMs : (times[1] - times[0]) || 300000;
  let roomAir = null, roomAirLoading = null;
  const loadRoomAir = () => (roomAirLoading ||= (async () => {
    const { data: rows } = await loadCsv(new URL('room_exposure.csv.gz', new URL(dataUrl, location.href)),
      ['t', 'room_id', 'infectious_occupants', 'quanta_concentration']);
    const steps = new Map(), lit = new Set(), peak = new Map();
    for (const r of rows) {
      const q = Number(r.quanta_concentration), t = Number(r.t);
      if (!(q > 0)) continue;
      if (!steps.has(t)) steps.set(t, []);
      steps.get(t).push([r.room_id, q]);
      lit.add(r.room_id);
      peak.set(t, Math.max(peak.get(t) || 0, q));
    }
    const peaks = [...peak.values()].sort((a, b) => a - b);
    const renderer = L.canvas({ padding: 0.2 }), shapes = new Map(), layer = L.layerGroup();
    for (const id of lit) {
      const i = rooms.index.get(id);
      if (i === undefined) continue;
      const shape = L.geoJSON(wktGeometry(rooms.wkts[i]), { renderer, interactive: false,
        style: { color: '#a8988a', weight: 0.5, opacity: 0.5, fillOpacity: 0 } });
      shapes.set(id, shape);
      layer.addLayer(shape);
    }
    roomAir = { steps, shapes, layer, vmax: peaks[Math.floor(0.9 * (peaks.length - 1))] || 1, on: new Set(), shown: null };
    renderLegend();
    heatDirty = true;
    render(performance.now()); // also when paused
  })().catch((err) => console.warn(`No room exposure for this run (${err.message})`)));
  const rampColor = (x) => { // HEAT_STOPS at x in 0..1, opaque
    let k = 1;
    while (k < HEAT_STOPS.length - 1 && HEAT_STOPS[k][0] < x) k++;
    const [ta, a] = HEAT_STOPS[k - 1], [tb, b] = HEAT_STOPS[k], f = Math.min(1, Math.max(0, (x - ta) / (tb - ta || 1)));
    return `rgb(${a.slice(0, 3).map((c, j) => Math.round(c + f * (b[j] - c))).join(',')})`;
  };
  function showRoomAir(t) {
    const k = Math.floor((t - simStart) / simStepMs); // the sim step on screen
    if (!roomAir || roomAir.shown === k) return;
    roomAir.shown = k;
    for (const id of roomAir.on) roomAir.shapes.get(id).setStyle({ fillOpacity: 0 });
    roomAir.on.clear();
    for (const [id, q] of roomAir.steps.get(k) || []) {
      const shape = roomAir.shapes.get(id);
      if (!shape) continue;
      shape.setStyle({ fillColor: rampColor(Math.min(1, Math.sqrt(q / roomAir.vmax))), fillOpacity: 0.85 });
      roomAir.on.add(id);
    }
  }

  const vmax = { demo: scaleMax(heatAt, times), public: buildingScaleMax(totals), truth: null };
  // "True status (sim)" colouring also switches the demo heat to actual infections.
  const truthMode = () => data.hasTruth && $('dot-mode').value === 'truth';
  const scales = new Map([[`false:${sigmaM}`, vmax.demo]]); // "truth:sigma" -> colour max
  const demoScale = () => {
    const truth = truthMode(), key = `${truth}:${sigmaM}`;
    if (!scales.has(key)) scales.set(key, scaleMax((t) => heatAt(t, null, truth), times)); // on first use
    vmax[truth ? 'truth' : 'demo'] = scales.get(key);
    return scales.get(key);
  };
  if (!outlines) console.warn('No building outlines (serve from the repo root): the user map will be empty.');

  const map = baseMap('map', { maxBounds: L.latLngBounds(sw, ne).pad(0.5) });
  const sigmaForZoom = () => {
    const mPerPx = 156543.03 * Math.cos(map.getCenter().lat * Math.PI / 180) / 2 ** map.getZoom();
    return Math.min(120, Math.max(DEMO.sigmaM, Math.round(16 * mPerPx / 6) * 6)); // 6 m steps: few cached scales
  };
  map.on('zoomend', () => {
    const next = sigmaForZoom();
    if (next === sigmaM) return;
    sigmaM = next;
    heatDirty = true;
    renderLegend();
    render(performance.now());
  });
  // Fit once the map actually has a size; a page opened in a background tab starts at 0×0.
  let fitted = false;
  new ResizeObserver(() => {
    map.invalidateSize();
    if (fitted || !map.getSize().x || !map.getSize().y) return; // wait for real width *and* height
    fitted = true;
    map.fitBounds(viewBounds(frames) || [sw, ne]);
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
  const dots = new Map(); // agent id -> person marker
  PERSON.onload = () => { for (const m of dots.values()) if (m._map) m.redraw(); };
  let current = new Map(); // agent id -> interpolated state at the current time

  // ?at=<minutes from the start> opens at a specific moment (handy for demos and screenshots).
  // Otherwise open on the first day's busiest walking moment (a class change), not a sleeping campus.
  const at = Number(new URLSearchParams(location.search).get('at'));
  let now = at ? Math.min(t1, t0 + at * 60000) : busiestMoment(), playing = false, selected = null, lastHeat = -Infinity, heatDirty = true, heatInterval = 0;
  let phoneMap = null, phoneBuildings = null, phoneYou = null, airflowTruth = false;

  function busiestMoment() {
    const sample = [...tracks.values()].slice(0, 500), DAY = 24 * 3600000;
    // Total P at each day's noon; open on the first day with at least half the highest total.
    const totals = [];
    for (let d = t0; d < t1; d += DAY) totals.push(sample.reduce((sum, tr) => sum + (stateNow(tr, d + DAY / 2)?.p || 0), 0));
    const day = Math.max(0, totals.findIndex((x) => x >= 0.5 * Math.max(...totals)));
    const dayStart = t0 + day * DAY, dayEnd = Math.min(t1, dayStart + DAY);
    let best = Math.max(dayStart, firstMove(tracks, dayStart) - 10 * 60000), most = 0;
    for (let t = dayStart; t < dayEnd; t += 5 * 60000) {
      let walking = 0;
      for (const track of sample) if (stateAt(track, t)?.walking) walking++;
      if (walking > most) { most = walking; best = t - 5 * 60000; } // a moment before, so they set off on Play
    }
    return best;
  }

  function dotFor(id) {
    if (dots.has(id)) return dots.get(id);
    const m = new PersonMarker([0, 0], {
      renderer: dotRenderer, radius: PERSON.radius, weight: 2, color: COLORS.ring, fillOpacity: 1,
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
      flags: model.risk.flags.filter((f) => f.agentId === selected && f.tMs <= now), traits: model.traits.get(selected),
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
    $('ph-risk').closest('.risk').dataset.tier = riskTier(me.p);
    const where = me.walking ? 'walking' : me.building;
    $('ph-truth').textContent = `${me.id}${me.sick === null ? '' : me.sick ? ' is infected' : ' is healthy'}${where ? ` · ${where}` : ''}`;

    if (!phoneMap) {
      phoneMap = baseMap('ph-map', { zoomControl: false, attributionControl: false });
      if (outlines) phoneBuildings = new BuildingTotalsLayer(outlines).addTo(phoneMap);
      phoneYou = L.circleMarker([me.lat, me.lon], { radius: 6, weight: 3, color: COLORS.ring, fillColor: '#33241c', fillOpacity: 1 }).addTo(phoneMap);
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
    const view = $('view').value;
    current = new Map();
    // The user map (and the app's embed) reads totals only: skip everyone's position (2 ms a frame at
    // 7,500 agents) unless a phone is open, which needs who is near.
    if (view !== 'public' || selected) {
      for (const [id, track] of tracks) {
        const s = stateNow(track, now);
        if (s) current.set(id, s);
      }
    }
    $('time').textContent = formatTime(now, data.numericTime);
    $('slider').value = (now - t0) / 60000;

    const heatDue = heatDirty || realNow - lastHeat >= heatInterval;
    if (heatDue) {
      const started = performance.now();
      heatLayer.canvas.style.display = view === 'public' || view === 'airborne' ? 'none' : '';
      if (view === 'airborne') {
        if (!roomAir) loadRoomAir();
        else { if (!map.hasLayer(roomAir.layer)) roomAir.layer.addTo(map); showRoomAir(now); }
      } else if (roomAir && map.hasLayer(roomAir.layer)) roomAir.layer.remove();
      if (publicLayer) {
        if (view === 'public') { if (!publicLayer.added) { publicLayer.addTo(map); publicLayer.added = true; } updateUserLayer(publicLayer); }
        else if (publicLayer.added) { publicLayer.remove(); publicLayer.added = false; }
      }
      if (view === 'airflow') {
        const st = [...current.values()];
        paint(airflowAt(now, st, truthMode()), heatLayer.canvas, aeroMax);
        if (truthMode() !== airflowTruth) { airflowTruth = truthMode(); aeroT = null; } // source changed: re-warm
      } else if (view !== 'public' && view !== 'airborne') paint(heatAt(now, current.values(), truthMode()), heatLayer.canvas, demoScale());
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
        // Only touch dots that changed: each update makes Leaflet repaint the canvas around that dot.
        const ll = m.getLatLng(), fill = dotColor(a, mode);
        if (ll.lat !== a.lat || ll.lng !== a.lon) m.setLatLng([a.lat, a.lon]);
        if (m.options.fillColor !== fill) m.setStyle({ fillColor: fill });
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
      if (now >= t1 && EMBED) { now = t0; heatDirty = true; } // the app tab loops the run
      else if (now >= t1) { now = t1; setPlaying(false); }
      try { render(realNow); } catch (err) { console.error(err); } // one bad frame must not stop playback
    }
    requestAnimationFrame(tick);
  }

  function select(id) {
    selected = id;
    if (!current.size) render(performance.now()); // the user map skipped positions until now
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
    if (v === 'airborne') {
      $('vmid').textContent = roomAir ? (roomAir.vmax / 4).toPrecision(2) : '';
      $('vmax').textContent = roomAir ? `${roomAir.vmax.toPrecision(2)}+` : 'loading…';
    }
    document.querySelector('.legend h2').innerHTML = v === 'airborne'
      ? 'Infectious air by room <span>quanta per m³, from the simulation</span>'
      : v === 'airflow'
      ? `Infectious air <span>relative, experimental${truthMode() ? ' (sim truth)' : ''}</span>`
      : v === 'public'
      ? `Expected sick people <span>per building${scale > 1 ? ` (each sim agent = ${scale})` : ''}</span>`
      : truthMode() ? 'Infectiousness <span>per 1,000 m², from the simulation (truth)</span>' : 'Expected infected <span>per 1,000 m²</span>';
    const showDots = $('show-dots').checked && v !== 'public';
    const key = (color, label) => `<div class="key"><span class="swatch" style="background:${color}"></span>${label}</div>`;
    $('dot-legend').innerHTML = !showDots ? '' : $('dot-mode').value === 'truth'
      ? key(COLORS.healthy, 'Healthy (sim truth)') + key(COLORS.infected, 'Infected (sim truth)')
      : `<div class="key">App's estimate of P(sick)${data.beliefFrom === 'column' ? '' : data.beliefFrom === 'reports' ? ' (placeholder: from self-reports and tests)' : ' (placeholder: true status)'}:</div><div class="tiers"><span style="--c:${riskColor(0)}">Low<small>&lt;${TIERS.elevated * 100}%</small></span><span style="--c:${riskColor(TIERS.elevated)}">Elevated<small>${TIERS.elevated * 100}–${TIERS.high * 100}%</small></span><span style="--c:${riskColor(TIERS.high)}">High<small>${TIERS.high * 100}%+</small></span></div>`;
    const isPublic = v === 'public';
    $('dot-mode').disabled = !data.hasTruth || isPublic;
    $('show-dots').disabled = isPublic; // the user map never shows people
    $('horizon').hidden = !isPublic;    // forecasts are a user-map feature
    if (!EMBED) document.querySelector('.legend .fine').textContent = isPublic
      ? 'Totals only: no people. May be incomplete because not everyone shares their status.'
      : 'May be incomplete: not everyone shares their status. Click a person to see their app.';
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
  $('view').append(new Option('Infectious air by room (sim)', 'airborne'));
  if (PARAMS.get('view') === 'airflow') $('view').append(new Option('Airflow heat (experimental)', 'airflow'));

  // Forecast picker for the user-facing map, built here so the page markup stays the design pass's.
  const horizon = Object.assign(document.createElement('select'), { id: 'horizon', ariaLabel: 'Forecast' });
  horizon.append(...HORIZONS.map(([m, label]) => new Option(label, m)));
  document.querySelector('.options').append(horizon);
  const basePick = Object.assign(document.createElement('select'), { id: 'basemap', ariaLabel: 'Map style' });
  basePick.append(new Option('Sim map', 'sim'), new Option('Street map', 'streets'), new Option('Illustrated campus', 'drawn'));
  basePick.value = baseStyle;
  basePick.addEventListener('change', () => setBaseStyle(basePick.value).then(() => { basePick.value = baseStyle; }));
  document.querySelector('.options').append(basePick);
  // ?view=public&horizon=60 open straight into the user-facing map / a forecast.
  const params = new URLSearchParams(location.search);
  if (params.get('view')) $('view').value = params.get('view');
  if (params.get('horizon')) horizon.value = params.get('horizon');
  if (params.get('color')) $('dot-mode').value = params.get('color'); // ?color=truth: heat + dots from sim truth
  document.querySelector('#phone .screen .fine').textContent =
    `Buildings with fewer than ${MIN_PEOPLE} people are hidden${scale > 1 ? `; each simulated person stands for ${scale}` : ''}. May be incomplete because not everyone shares their status.`
    + (Number.isFinite(backtestRate) ? ` Forecasts landed in their range ${Math.round(backtestRate * 100)}% of the time when tested on past days.` : '');
  if (EMBED) {
    // User map only, slowest speed, playing; the time and forecast picker float over the map.
    $('view').value = 'public';
    $('speed').value = '0';
    const chip = Object.assign(document.createElement('div'), { className: 'embed-chip' });
    chip.append($('time'), horizon);
    document.querySelector('main').append(chip);
    document.querySelector('.legend .fine').textContent = document.querySelector('#phone .screen .fine').textContent;
    setPlaying(true);
  }

  for (const id of ['view', 'show-dots', 'dot-mode', 'horizon']) {
    $(id).addEventListener('change', () => { renderLegend(); heatDirty = true; render(performance.now()); });
  }
  if (model) {
    const why = Object.assign(document.createElement('button'), { textContent: 'Why this %?' });
    why.style.whiteSpace = 'nowrap';
    $('ph-close').before(why);
    why.addEventListener('click', () => { mathOpen = !mathOpen; mathKey = ''; renderMath(); });
  }
  // Short windows: the phone scrolls inside its frame instead of running off the bottom.
  Object.assign($('phone').style, { maxHeight: 'calc(100% - 32px)', overflowY: 'auto' });
  $('ph-close').addEventListener('click', () => { selected = null; renderPhone(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { selected = null; renderPhone(); } });

  $('status').hidden = true;
  renderLegend();
  render(performance.now());
  requestAnimationFrame(tick);
  const agentParam = new URLSearchParams(location.search).get('agent'); // ?agent=a018 opens that phone
  if (agentParam) select(agentParam);
  if (PARAMS.get('why') && model) { mathOpen = true; renderMath(); } // ?why=1 opens the explanation
  window.fluni = {
    data, map, vmax, totals, forecaster, model, select, seek: (t) => { now = t; heatDirty = true; render(performance.now()); },
    current: () => current, heatField: () => ($('view').value === 'airflow' ? aero : field), // for tools/bench.mjs
  };
}

main().catch((err) => {
  console.error(err);
  $('status').textContent = `Couldn't load the sim run (${err.message}). Serve the repo root, not heatmap/: `
    + 'cd fluni && python3 heatmap/tools/serve.py, then open http://localhost:8000/heatmap/';
});
