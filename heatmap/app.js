import { paint, heatPixel, HEAT_STOPS } from './heat.js';
import { DiffusionField } from './diffuse.js';
import { rasterizeBuildings } from './masks.js';
import { AerosolField, buildWalls } from './aerosol.js';
import { loadCsv } from './loader.js';
import { inferRisk, doseModel, DEFAULTS as MODEL } from '../model/infer.js';
import { renderMathPanel } from './mathpanel.js';
import { mountTissueAlert } from './tissue-alert.js';
import { Router, buildTracks, buildTrips, attachTrips, stateAt, sampleAt } from './motion.js';
import { buildTotals, totalsAt, buildingScaleMax } from './aggregate.js';
import { buildForecaster } from './forecast.js';
import { BuildingTotalsLayer, BuildingShadeLayer } from './buildings.js';
import { addLandmarks } from './landmarks.js';
import { initNightMode } from './theme.js';
import { loadPSick, loadTotals, loadMeanField } from './precomputed.js';
import { meanFieldRisk } from '../model/meanfield.js';
import { wktGeometry, cleanFootprints } from './footprints.js';
import { MIN_PEOPLE, userScale } from './userscale.js';
import { rampCss, fmt as fmtSick, NEUTRAL_BUILDING, CONTEXT_STYLE, CONTEXT_ORDER } from './userstyle.js';
import { LabelLayer } from './maplabels.js';
import { initPresenterUI, progress, dayTime } from './presenter-ui.js';
import * as PV from './phone-views.js';
import { makeSeats } from './seats.js';
import { smoothZoom } from './smoothzoom.js';
import { buildZones, rasterZone } from './zones.js';

// Room-level heat for the presenter (the user map gets building totals instead).
const DEMO = { cellM: 3, sigmaM: 6 }; // heat spread around each person close up (product owner: tight)
// Heat is the expected number of infected people near each point right now: Σ P(sick) of the people
// there, spread by the diffusion kernel (which integrates to 1, so a cloud holds exactly its people's
// expected count). No trail of past positions: that counted people who had already left. Infectious
// air that lingers after people leave is the sim's own room view ("Infectious air by room").
// The user-facing map sees only per-building totals, counted by userscale.js (the same rule precompute.mjs and
// FlUni's bundle use): small runs are scaled so each agent stands for several people, full runs count as themselves.
// From this many agents, read the precomputed P(sick) and user-map totals when the run has them
// (precomputed.js): the model in the page and per-step totals take minutes and gigabytes there.
const BIG_RUN = 2000;
// Long runs too: 1,000 agents x 14 days is 11 M contacts (21 s and 3.6 GB in the page); 4 days loads in 6 s.
const BIG_AGENT_DAYS = 8000;
let bigRun = false; // set by loadModel: this run uses the precomputed files
const MAX_DOTS = 2000;      // above this, draw a fixed sample of dots (heat and totals still use everyone). Every agent of a 1,000-agent run is drawn, so no heat without a dot       // buildings with only 1–3 people are hidden; 4 or more are always shown
let viewCountText = ''; // the demo legend's "≈ N expected sick", kept across legend re-renders
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
const SEAT_EASE_MS = 400;   // a dot glides this long (real time) between its route and its seat (seats.js)
const SPEEDS = [2, 10, 30, 60];    // simulated minutes per real second
const roomNames = new Map();       // room_id -> registrar room name, when the run has real class rooms
// Default: the sim's run (needs the server started at the repo root), else the local placeholder.
// ?data=<csv> or ?run=<sim run name>; default: the sim's real sample run, then the mock, then the
// local placeholder.
const DEFAULT_RUN = 'influenza_none_n1000_d4_s42_73b8452c';
const PARAMS = new URLSearchParams(location.search);
// ?model=meanfield: people's P(sick) from Baker et al.'s mean-field (model/meanfield.js) instead of infer.js.
// No "Why this %?" panel then (meanfield.js has no explain()).
const MEAN_FIELD = PARAMS.get('model') === 'meanfield';
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
// Zoomed out to the campus, smaller badges so the heat in the buildings under them shows through.
// People are drawn at a fixed size on the ground (PERSON_M metres), so they're tiny at campus zoom and grow as
// you zoom in, like the buildings (2 px at campus zoom, 3 px at 17, 13 px at 19).
const PERSON_M = 3, M_PER_PX_Z0 = 156543.03 * Math.cos((37.43 * Math.PI) / 180);
const SEE_THROUGH = 0.45, SEE_THROUGH_ZOOM = 18; // people markers close up in the room-level view
let hoverDot = null; // the person under the pointer: drawn solid
const personRing = (r) => (r < 4 ? 0.75 : r < 8 ? 1.25 : 2); // outline width for a dot of radius r
const personRadius = (zoom) => (Number.isFinite(zoom) ? Math.min(16, Math.max(2, (PERSON_M * 2 ** zoom) / M_PER_PX_Z0)) : PERSON.radius);
PERSON.img.src = 'assets/people/tissue.png';
// People's canvas renderer: a click or hover goes to the NEAREST dot within reach (its radius + the tolerance),
// not the one drawn last, so a click between two close dots never opens the neighbour's phone.
const NearestCanvas = L.Canvas.extend({
  _nearest(point, e) {
    let best = null, bd = Infinity;
    for (let o = this._drawFirst; o; o = o.next) {
      const l = o.layer;
      if (!l.options.interactive || !l._containsPoint(point)) continue;
      if (e && (e.type === 'click' || e.type === 'preclick') && this._map._draggableMoved(l)) continue;
      const d = point.distanceTo(l._point);
      if (d <= bd) { bd = d; best = l; } // a tie goes to the one on top
    }
    return best;
  },
  _onClick(e) {
    const l = this._nearest(this._map.mouseEventToLayerPoint(e), e);
    this._fireEvent(l ? [l] : false, e);
  },
  _handleMouseHover(e, point) {
    if (this._mouseHoverThrottled) return;
    const l = this._nearest(point);
    if (l !== this._hoveredLayer) {
      this._handleMouseOut(e);
      if (l) { L.DomUtil.addClass(this._container, 'leaflet-interactive'); this._fireEvent([l], e, 'mouseover'); this._hoveredLayer = l; }
    }
    this._fireEvent(this._hoveredLayer ? [this._hoveredLayer] : false, e);
    this._mouseHoverThrottled = true;
    setTimeout(() => { this._mouseHoverThrottled = false; }, 32);
  },
});
const PersonMarker = L.CircleMarker.extend({
  _updatePath() {
    this._renderer._updateCircle(this);
    const ctx = this._renderer._ctx, p = this._point, s = (PERSON.size * this._radius) / PERSON.radius;
    // Only inside the renderer's redraw pass (as _updateCircle): a moved dot's update also lands here, and
    // drawing then put a stray badge-less tissue on screen until the next redraw cleared it.
    if (!ctx || !this._renderer._drawing || this._empty() || !PERSON.img.complete || !PERSON.img.naturalWidth) return;
    if (this._radius < 5) return; // too small for the tissue to read: just the coloured dot
    ctx.globalAlpha = this.options.fillOpacity; // see-through close up, like the badge
    ctx.drawImage(PERSON.img, p.x - s / 2, p.y - s / 2 - 1, s, s);
    ctx.globalAlpha = 1;
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
    bigRun = agentIds.length >= BIG_RUN || agentIds.length * (config.days || 1) >= BIG_AGENT_DAYS;
    if (bigRun) { // no "Why this %?" and no contact-based phone alerts then
      let risk = await loadPSick(new URL(`../../../model/out/${config.run_id}/p_sick.csv`, base));
      // ?model=meanfield: Baker et al.'s mean-field (model/meanfield.js), precomputed by model/meanfield-cli.mjs
      const mf = MEAN_FIELD ? await loadMeanField(new URL(`../../../model/out/${config.run_id}/meanfield.csv`, base)) : null;
      if (MEAN_FIELD && !mf) console.warn(`No model/out/${config.run_id}/meanfield.csv (node model/meanfield-cli.mjs sim/runs/${config.run_id}): using infer.js.`);
      if (mf) risk = mf;
      if (risk) return { risk, mf: mf && (() => mf), contacts: [], startMs: Date.parse(config.start), stepMs: config.step_min * 60000, traits: new Map() };
      console.warn(`No model/out/${config.run_id}/p_sick.csv: running the model in the page (slow on big runs).`);
    }
    const [contacts, reports, rooms] = await Promise.all([
      loadCsv(new URL('contacts.csv.gz', base), ['t', 'agent_a', 'agent_b', 'distance_m', 'distance_tier', 'duration_s', 'room_id', 'indoor']),
      loadCsv(new URL('reports_tests.csv', base), ['t', 'agent_id', 'event', 'value', 'target_agent_id']),
      // Room volume and ventilation for Rio's room-air term (model/README.md); default room without it.
      loadCsv(new URL('map/rooms.csv', base), ['room_id', 'volume_m3', 'ventilation_ach', 'room_type', 'room_name'])
        .then((r) => new Map(r.data.map((x) => [x.room_id, x])), () => null),
    ]);
    roomNames.clear(); // registrar names (ExploreCourses runs) for the people tooltips
    for (const [id, r] of rooms || []) if (r.room_name) roomNames.set(id, r.room_name);
    const startMs = Date.parse(config.start), stepMs = config.step_min * 60000;
    let risk = inferRisk({ contacts: contacts.data, reports: reports.data, rooms, agentIds, stepMin: config.step_min, startMs });
    // ?model=meanfield: Baker et al.'s mean-field over the same contacts and reports colours people (and so the
    // buildings) instead. Computed on first use (~3 s for 1,000 agents over 4 days), so only then.
    let mfRisk = null;
    const mf = () => (mfRisk ||= meanFieldRisk({ contacts: contacts.data, reports: reports.data, rooms, agentIds, stepMin: config.step_min, startMs,
      weather: config.params?.weather, days: config.days }));
    if (MEAN_FIELD) risk = mf();
    // Sim truth about each person (honesty, compliance, ...), shown to the presenter only.
    const traits = await loadCsv(new URL('agents_static.csv', base), ['agent_id', 'archetype', 'honesty', 'compliance', 'has_app', 'shares_location', 'sickness_behavior_profile'])
      .then((r) => new Map(r.data.map((a) => [a.agent_id, a])), () => new Map());
    return { risk, mf, contacts: contacts.data, reports: reports.data, startMs, stepMs, traits };
  } catch (err) {
    console.warn(`No probability model for this run (${err}); using the placeholder estimate.`);
    return null;
  }
}

// Footprint area (m²) of each building outline, keyed like people's buildingId ('bld_' + the OSM id's number):
// shoelace in local metres, holes (courtyards) subtracted, MultiPolygon parts added.
function footprintAreas(geojson) {
  const out = new Map();
  for (const f of geojson?.features || []) {
    const g = f.geometry, polys = g.type === 'Polygon' ? [g.coordinates] : g.type === 'MultiPolygon' ? g.coordinates : [];
    let area = 0;
    for (const rings of polys) rings.forEach((ring, k) => {
      const kx = 111320 * Math.cos((ring[0][1] * Math.PI) / 180);
      let s = 0;
      for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) s += (ring[j][0] * kx) * (ring[i][1] * 110574) - (ring[i][0] * kx) * (ring[j][1] * 110574);
      area += (k ? -1 : 1) * Math.abs(s / 2);
    });
    if (area > 0) out.set('bld_' + String(f.properties.id).split('/')[1], area);
  }
  return out;
}

// What each person told the app (reports_tests.csv, a few KB): agent id -> events by time.
async function loadReportEvents(dataUrl) {
  const by = new Map();
  try {
    const base = new URL(dataUrl, location.href);
    const cfg = await fetch(new URL('config.json', base)).then((r) => r.json());
    const { data: rows } = await loadCsv(new URL('reports_tests.csv', base), ['t', 'agent_id', 'event', 'value']);
    for (const r of rows) {
      if (!by.has(r.agent_id)) by.set(r.agent_id, []);
      by.get(r.agent_id).push({ ms: Date.parse(cfg.start) + Number(r.t) * cfg.step_min * 60000, event: r.event, value: r.value });
    }
    for (const l of by.values()) l.sort((a, b) => a.ms - b.ms);
  } catch { /* no reports: nobody is sick on their phone */ }
  return by;
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
    const { data } = await loadCsv(new URL('map/rooms.csv', new URL(dataUrl, location.href)), ['room_id', 'location_id', 'floor', 'capacity', 'polygon_wkt']);
    const rows = data.filter((r) => r.room_id && r.polygon_wkt);
    return { index: new Map(rows.map((r, i) => [r.room_id, i])), wkts: rows.map((r) => r.polygon_wkt), rows };
  } catch {
    return { index: new Map(), wkts: [], rows: [] };
  }
}

// The sim keeps building names next to the timeline in map/buildings.csv (location_id → name).
// Also returns building outlines when the run has footprints (footprint_wkt covers every building,
// including places missing from OSM like bld_m_green_library); otherwise null.
async function loadBuildings(dataUrl) {
  try {
    const { data } = await loadCsv(new URL('map/buildings.csv', new URL(dataUrl, location.href)),
      ['location_id', 'name', 'type', 'source', 'indoor', 'lat', 'lon', 'footprint_wkt']);
    const names = new Map(data.filter((b) => b.location_id && b.name).map((b) => [b.location_id, b.name]));
    // No boxes for outdoor spaces; manual boxes on a real building take its outline (footprints.js).
    const features = cleanFootprints(data).map(({ row: b, geometry, box }) => ({
      type: 'Feature',
      // buildings.js / masks.js key features by 'bld_' + the part after the slash.
      properties: { id: `run/${b.location_id.replace(/^bld_/, '')}`, name: b.name, type: b.type, box },
      geometry,
    }));
    // The sim's outdoor places on water (Lake Lagunita): nobody is drawn standing in them (seats.js).
    const water = data.filter((b) => b.source === 'manual' && !/^(true|1)$/i.test(b.indoor) && /lake|lagunita|pond|reservoir/i.test(b.name) && b.footprint_wkt)
      .map((b) => wktGeometry(b.footprint_wkt));
    return { names, outlines: features.length ? { type: 'FeatureCollection', features } : null, water };
  } catch {
    return { names: new Map(), outlines: null, water: [] };
  }
}


// ---------- Leaflet glue ----------

// The heat on screen, on a canvas the size of the map view (plus a margin), redrawn when the view moves.
// - Room-level heat (setZones): each building's patch (diffuse.js: a Gaussian around each person through the
//   building) is drawn clipped to that building's own outline, so heat edges are crisp and exactly on its
//   walls at any zoom.
// - Airflow (setGrid): a whole grid painted by paint(), scaled onto the view, unclipped.
const VIEW_PAD = 0.15;
const CanvasLayer = L.Layer.extend({
  initialize(bounds) {
    this.bounds = L.latLngBounds(bounds);
    this.grid = document.createElement('canvas'); // paint() target for the airflow view
    this.atlas = document.createElement('canvas'); // the zones' patches, packed
    this.canvas = L.DomUtil.create('canvas', 'heat-canvas leaflet-zoom-animated');
    this.mode = null;
    this.paths = new Map(); // zone index -> Path2D in canvas pixels, for this.pathKey
    this.pathKey = '';
  },
  onAdd(map) {
    map.getPane('overlayPane').appendChild(this.canvas);
    map.on('zoomanim', this.animate, this);
    // Smooth zoom (smoothzoom.js, and touch pinch) moves the map by 'zoom' events with no zoomanim: follow
    // them with the same cheap CSS transform; redraw mid-gesture on 'zoomrefresh', crisply on moveend.
    map.on('zoom', this.follow, this);
    map.on('moveend viewreset resize zoomrefresh', this.draw, this);
    this.draw();
  },
  onRemove(map) {
    this.canvas.remove();
    map.off('zoomanim', this.animate, this);
    map.off('zoom', this.follow, this);
    map.off('moveend viewreset resize zoomrefresh', this.draw, this);
  },
  setBounds(bounds) { this.bounds = L.latLngBounds(bounds); },
  setGrid() { this.mode = 'grid'; this.draw(); },
  // field: the DiffusionField after diffuse() (field.zoneOut); zones: buildZones().zones; vmax: colour max.
  setZones(field, zones, vmax) {
    this.mode = 'zones';
    this.field = field; this.zones = zones;
    // One tile per building part with heat (a wing), padded by a cell, packed into one image (shelves); a tile's
    // cells outside its part get the part's own neighbours' colour, so the clip to that part's outline, not a
    // fade or the next wing's heat, makes the edge at the wall.
    const list = [], W = 1024;
    for (const z of field.zoneOut) {
      const parts = new Set();
      for (let i = 0; i < z.u.length; i++) if (z.u[i] > 0) parts.add(z.own[i]);
      for (const part of parts) list.push({ ...z, part });
    }
    this.tiles = list;
    let x = 0, y = 0, rowH = 0;
    for (const p of list) {
      const w = p.w + 2, h = p.h + 2;
      if (x + w > W) { x = 0; y += rowH; rowH = 0; }
      p.ax = x; p.ay = y; x += w; rowH = Math.max(rowH, h);
    }
    const H = Math.max(1, y + rowH), a = this.atlas;
    if (a.width !== W || a.height < H) { a.width = W; a.height = Math.max(H, a.height); }
    const ctx = a.getContext('2d');
    const img = ctx.createImageData(W, H), px = new Uint32Array(img.data.buffer);
    for (const p of list) {
      const { w, h, own, u, part } = p, val = (i, j) => (i >= 0 && j >= 0 && i < w && j < h && own[j * w + i] === part ? u[j * w + i] : -1);
      for (let j = -1; j <= h; j++) for (let i = -1; i <= w; i++) {
        let v = val(i, j);
        if (v < 0) { // outside the zone's cells: the mean of its own neighbours (for the edge between centre and wall)
          let s = 0, n = 0;
          for (const [di, dj] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]]) { const q = val(i + di, j + dj); if (q >= 0) { s += q; n++; } }
          v = n ? s / n : 0;
        }
        px[(p.ay + j + 1) * W + p.ax + i + 1] = heatPixel(v, vmax, true);
      }
    }
    ctx.putImageData(img, 0, 0);
    this.draw();
  },
  draw() {
    const map = this._map;
    if (!map || map._animatingZoom || !map._loaded) return;
    const size = map.getSize(), min = map.containerPointToLayerPoint(size.multiplyBy(-VIEW_PAD)).round();
    const w = Math.round(size.x * (1 + 2 * VIEW_PAD)), h = Math.round(size.y * (1 + 2 * VIEW_PAD)), dpr = window.devicePixelRatio || 1;
    const c = this.canvas;
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
      c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
      c.style.width = `${w}px`; c.style.height = `${h}px`;
    }
    L.DomUtil.setPosition(c, min);
    this.zoom = map.getZoom();
    this.view = L.latLngBounds(map.layerPointToLatLng(min), map.layerPointToLatLng(min.add([w, h])));
    const ctx = c.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    const toPx = (lat, lon) => map.latLngToLayerPoint([lat, lon]).subtract(min);
    if (this.mode === 'grid' && this.grid.width) {
      const tl = toPx(this.bounds.getNorth(), this.bounds.getWest()), br = toPx(this.bounds.getSouth(), this.bounds.getEast());
      ctx.drawImage(this.grid, tl.x, tl.y, br.x - tl.x, br.y - tl.y);
      return;
    }
    if (this.mode !== 'zones' || !this.field) return;
    const key = `${this.zoom}:${min.x}:${min.y}`;
    if (key !== this.pathKey) { this.paths.clear(); this.pathKey = key; }
    const pathOf = (zi, part) => { // one part of a building: its outer ring and courtyards
      const k = `${zi}:${part}`;
      let p = this.paths.get(k);
      if (!p) {
        p = new Path2D();
        for (const ring of this.zones[zi].parts[part - 1].ll) ring.forEach(([lon, lat], i) => { const q = toPx(lat, lon); i ? p.lineTo(q.x, q.y) : p.moveTo(q.x, q.y); });
        this.paths.set(k, p);
      }
      return p;
    };
    const f = this.field, b = f.bounds, kx = f.cellM / f.mPerDegLon, ky = f.cellM / 110574;
    for (const z of this.tiles || []) {
      // The patch's cell (i, j) covers lon west + i·kx .. , lat north - j·ky ..; plus its one-cell pad.
      const tl = toPx(b.north - (z.y0 - 1) * ky, b.west + (z.x0 - 1) * kx), br = toPx(b.north - (z.y0 + z.h + 1) * ky, b.west + (z.x0 + z.w + 1) * kx);
      if (br.x < 0 || br.y < 0 || tl.x > w || tl.y > h) continue;
      ctx.save();
      ctx.clip(pathOf(z.z, z.part), 'evenodd');
      ctx.drawImage(this.atlas, z.ax, z.ay, z.w + 2, z.h + 2, tl.x, tl.y, br.x - tl.x, br.y - tl.y);
      ctx.restore();
    }
  },
  animate(e) {
    if (!this.view) return;
    const scale = this._map.getZoomScale(e.zoom, this.zoom);
    const offset = this._map._latLngBoundsToNewLayerBounds(this.view, e.zoom, e.center).min;
    L.DomUtil.setTransform(this.canvas, offset, scale);
  },
  follow() {
    const map = this._map;
    if (map._animatingZoom) return; // a CSS zoom animation: animate() set its end transform
    this.animate({ zoom: map.getZoom(), center: map.getCenter() });
  },
});

// Base maps (?basemap=sim|streets|drawn):
// - sim: the sim viewer's look (@aidenyj): OpenFreeMap's Positron vector map, with the run's own map on
//   top (its building footprints and the path network people walk). Loaded on first use. Default.
//   Positron's own buildings are left out: the run's footprints are the only buildings, so the shapes
//   people stand in and the heat clipped to them are exactly what's drawn (no doubled outlines).
//   Offline (no unpkg or OpenFreeMap) it still shows the run's buildings and paths, which are local.
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
// Buildings in pale washes of Lisa's palette, by what they're for (design pass). Heat owns the warm
// colours (sun → ember → fire), so building fills stay on the cool side: sage washes, deeper for housing.
// The palette's warm colours appear only in the thin inked outlines (study sun, food and social ember,
// health fire), which never read as heat. Unlabelled kinds stay plain warm paper.
const SIM_BUILDING = { fillColor: '#e6e0d3', fillOpacity: 0.95, color: '#ad9e8b', weight: 1, opacity: 0.95 };
const TINT = {
  housing: { fillColor: '#cfdcb6', color: '#869c63' },  // --sage wash, sage ink
  study: { fillColor: '#dbe3c8', color: '#c4a552' },    // faint sage wash, --sun ink
  social: { fillColor: '#e1e5d2', color: '#d27f55' },   // faintest sage wash, --ember ink
  care: { fillColor: '#e1e5d2', color: '#c9604d' },     // faintest sage wash, --fire ink
};
const TINT_OF = { dorm: 'housing', classroom: 'study', lab: 'study', lecture_hall: 'study', library: 'study',
  dining: 'social', common_room: 'social', party_venue: 'social', event_venue: 'social', gym: 'social', health_center: 'care' };
const buildingStyle = (f) => ({ ...SIM_BUILDING, ...TINT[TINT_OF[f.properties.type]] });
// A hand-placed box with no OSM building near it (footprints.js): only an approximate shape, so drawn faintly.
const SIM_BOX_FAINT = { fillOpacity: 0.35, opacity: 0.5, dashArray: '3 3' };
const SIM_BACKGROUND = '#f6f4f0'; // Positron's land colour, so the sim map looks the same before (or without) its tiles
const STYLES = ['sim', 'streets', 'drawn'];
const bases = new Map(); // map -> { streets, drawn, sim } layers, made on first use
let baseStyle = STYLES.includes(PARAMS.get('basemap')) ? PARAMS.get('basemap') : 'sim';
let drawnBounds = null, glReady = null, simMap = null; // simMap: { buildings, paths } from the run

function baseMap(el, options) {
  // Zoom stops at room scale (20: ~15 cm a pixel, people at full size) and at the whole campus (13);
  // the vector base would otherwise let you zoom in forever.
  // zoomSnap 0: zoom is continuous (smoothZoom's wheel / pinch / buttons end where they stop, as in Google Maps).
  const map = smoothZoom(L.map(el, { preferCanvas: true, zoomSnap: 0, minZoom: 13, maxZoom: 20, ...options }));
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
    const style = fetch(GL.style).then((r) => (r.ok ? r.json() : Promise.reject(new Error(`style: HTTP ${r.status}`))));
    style.catch(() => {}); // reported below, once
    await loadScript(GL.js);
    await loadScript(GL.leaflet);
    const json = await style;
    json.layers = json.layers.filter((l) => l['source-layer'] !== 'building'); // the run's footprints are the buildings
    GL.json = json;
  })().then(() => { for (const map of bases.keys()) applyBase(map); },
    (err) => console.warn(`Vector base map unavailable (${err.message}); showing the run's own buildings and paths.`));
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
  } catch (err) {
    console.warn(`Base map "${style}" unavailable (${err.message}); using street tiles.`);
    baseStyle = 'streets';
  }
  for (const map of bases.keys()) applyBase(map);
}

function layerFor(map, base, style) {
  if (style === 'streets') return (base.streets ||= L.tileLayer(TILES, { attribution: ATTRIBUTION, maxZoom: 19, className: 'muted-tiles' }));
  if (style === 'drawn') return drawnBounds && (base.drawn ||= L.imageOverlay(DRAWN.image, drawnBounds, { pane: 'tilePane', attribution: ATTRIBUTION }));
  if (!base.sim) {
    base.sim = L.layerGroup();
    base.simData = null;
  }
  if (GL.json && !base.gl) base.sim.addLayer(base.gl = L.maplibreGL({ style: GL.json }));
  if (simMap && base.simData !== simMap) { // the run's buildings and paths, drawn like the sim viewer
    base.simData = simMap;
    const renderer = L.canvas({ pane: 'simPane' });
    const attribution = '<a href="https://openfreemap.org">OpenFreeMap</a> ' + ATTRIBUTION;
    if (simMap.paths) base.sim.addLayer(L.geoJSON(simMap.paths, { pane: 'simPane', renderer, interactive: false, attribution,
      style: { color: '#8aa39b', weight: 1.2, opacity: 0.55 } }));
    if (simMap.buildings) base.sim.addLayer(L.geoJSON(simMap.buildings, { pane: 'simPane', renderer, interactive: false,
      attribution: simMap.paths ? undefined : attribution, style: (f) => (f.properties.box ? { ...buildingStyle(f), ...SIM_BOX_FAINT } : buildingStyle(f)) }));
  }
  return base.sim;
}

function applyBase(map) {
  const base = bases.get(map);
  const layer = layerFor(map, base, baseStyle);
  if (!layer) { setBaseStyle(baseStyle); return; } // not loaded yet (first use, or ?basemap=)
  if (baseStyle === 'sim' && !GL.json) loadGl(); // the vector tiles join the run's own map when they arrive
  for (const style of STYLES) { const l = base[style]; if (l && l !== layer) l.remove(); }
  if (!map.hasLayer(layer)) layer.addTo(map);
  // The illustration's own paper colour; Positron's land colour under the sim map.
  map.getContainer().style.background = baseStyle === 'drawn' ? '#fff' : baseStyle === 'sim' ? SIM_BACKGROUND : '';
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

// Colour max from typical moments: per sampled moment the 90th percentile of the warm cells, then the median
// moment. Typical hot spots reach the dark end; the extreme ones simply max out.
function scaleMax(heatAt, times) {
  const step = Math.max(1, Math.floor(times.length / 60));
  const levels = [];
  for (let i = 0; i < times.length; i += step) {
    const g = heatAt(times[i]), warm = [];
    for (let k = 0; k < g.heat.length; k += 2) if (g.heat[k] > 0) warm.push(g.heat[k]);
    if (!warm.length) continue;
    warm.sort((x, y) => x - y);
    levels.push(warm[Math.floor(0.9 * (warm.length - 1))]);
  }
  levels.sort((x, y) => x - y);
  return levels[Math.floor(0.5 * (levels.length - 1))] || 1;
}

// Diffusion input: indoor people's heat is confined to buildings, outdoor people's spreads freely.
// truth = heat from who is actually infectious (sim), instead of the app's estimate.
// The model's heat is risk above the baseline: max(0, P - prior), so a crowd at the prior is blank.
// only: 'indoor' or 'outdoor' keeps just those people (outdoor heat is drawn on its own layer).
// zoneOf(state): the heat zone the person's heat stays in (their room close up, else their building).
function* asPoints(states, truth, only = null, zoneOf = (s) => s.zone) {
  for (const s of states) {
    const indoor = Boolean(s.buildingId);
    if ((only === 'indoor' && !indoor) || (only === 'outdoor' && indoor)) continue;
    yield { lat: s.lat, lon: s.lon, p: truth ? Number(s.infectious) || 0 : Math.max(0, s.p - MODEL.prior), indoor, zone: zoneOf(s) };
  }
}

// Outdoors there is no shared room air, only the near-field plume, which wind dilutes and which falls off
// as 1/d² (model/infer.js doseModel: at 6 ft outdoors gets 16% of the indoor dose, at 6 m 5%). So outdoor
// heat is tighter (half the indoor spread) and lighter: on the rooms' colour scale (expected sick count),
// a person outdoors peaks at that 6 ft ratio of what they'd show as the only one in a room. No time decay:
// the heat is a snapshot.
const OUTDOOR_SIGMA = 0.5;
const OUTDOOR_WEIGHT = (() => {
  const dose = doseModel(), c = { distance_m: ADJACENT_M, duration_s: 3600 };
  return dose({ ...c, indoor: false }) / dose({ ...c, indoor: true });
})();

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

// Ground truth on top of the app's estimate: the sim's actually infected people (E or I) get a dark red
// ring, thicker so it shows even on a 2 px dot. Presenter only; in truth colouring the fill says it already.
const TRUTH_RING = '#6d1f16';
const ringWeight = (r, infected) => (infected ? Math.max(1.75, personRing(r) + 1) : personRing(r));

function dotColor(a, mode) {
  if (mode === 'truth') return a.sick ? COLORS.infected : COLORS.healthy;
  return riskColor(Math.min(1, a.p));
}

function advice(p) { // FlUni RiskEstimate.summary
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
// FlUni's RiskEstimate.percentText: whole percent, "<1%" for small non-zero values, "0%" only for exactly zero.
// FlUni's RiskEstimate.liveText: the live on-screen number, one decimal below 10% so it visibly moves, whole percent from 10%.
const liveText = PV.liveText;
// FlUni's NotificationRoute.fit: whole sentences in order while they fit in 180 characters, "Tap for more details." if any are left out.
const NOTE_BUDGET = 180, NOTE_MORE = 'Tap for more details.';
function noteFit(sentences) {
  if (sentences.join(' ').length <= NOTE_BUDGET) return sentences.join(' ');
  const kept = [];
  for (const s of sentences) {
    if (kept.length && [...kept, s, NOTE_MORE].join(' ').length > NOTE_BUDGET) break;
    kept.push(s);
  }
  return [...kept, NOTE_MORE].join(' ');
}
const percentText = (p) => (p <= 0 ? '0%' : Math.round(p * 100) < 1 ? '<1%' : `${Math.min(100, Math.round(p * 100))}%`);
// The phone's own estimate, as FlUni computes it on the device (Rio's formula with what a phone can know):
// per peer, Rio's dose summed over the last 24 h with quantaPeak, the default room and indoor = true;
// lambda = 1 - e^(-0.352 * dose) (illness-average stage: a phone never knows onset); s = max(the peer's status,
// the peer's broadcast score above the prior) (product owner 2026-10-17; see phoneEstimate); p += (1 - p) * s * lambda.
// No second-hand term, no recovery.
const PHONE_DOSE = doseModel(), PHONE_STAGE = 0.352, BT_RANGE_M = 10;
const esc = (x) => String(x).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
// FlUni's Advice strings (proximity/Core/Exposure.swift).
const ADVICE = {
  nearby: { title: 'Someone within 6 ft may be sick', body: ['Put 6 ft or more between you, or step outside.', 'Consider wearing a mask while you\'re here.'] },
  close: { title: 'You were close to someone who may be sick', body: ["You've spent about 15 minutes within 6 ft of someone who may be sick.", 'Leave the room now, or move well away and put on a mask.', 'Wash your hands; avoid touching your face.', 'Watch for fever, cough or sore throat over the next 1–4 days.', 'If symptoms start, get tested and report it in FlUni.'] },
};
const STATUS = {
  none: ['All clear', 'Nobody nearby has reported symptoms or a positive test.'],
  nearby: ['Someone nearby may be sick', 'A few things that help right now.'],
  close: ['Close contact', 'You spent about 15 minutes near someone who may be sick.'],
};
const ICON = {
  info: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 11v6" stroke="#faf4e8" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="7.4" r="1.4" fill="#faf4e8"/>',
  alert: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 6.5v6.5" stroke="#faf4e8" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="16.8" r="1.4" fill="#faf4e8"/>',
  building: '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M8 17V8l5-1.500v10M13 10l3 1v6M6.500 17h11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>',
  walk: '<circle cx="13" cy="4.500" r="1.800" fill="currentColor"/><path d="M10 21l2-6-2-2 1-5 3 2 2 2M9 11l-2 3M12 15l3 2.500" fill="none" stroke="currentColor" stroke-width="1.800" stroke-linecap="round" stroke-linejoin="round"/>',
  arrow: '<path d="M4 12h15M13 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
  chevron: '<path d="M9 5l7 7-7 7" fill="none" stroke="currentColor" stroke-width="2.500" stroke-linecap="round" stroke-linejoin="round"/>',
  fn: '<path d="M15 4c-3-1-4 1-4.500 4L9 18c-.5 2.500-1.500 3-4 2M6 11h9M13 14l5 6M18 14l-5 6" fill="none" stroke="currentColor" stroke-width="1.800" stroke-linecap="round" stroke-linejoin="round"/>',
  people: '<circle cx="8" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="1.700"/><circle cx="16.500" cy="9" r="2.500" fill="none" stroke="currentColor" stroke-width="1.700"/><path d="M2.500 19c.5-4 3-5.500 5.500-5.500s5 1.500 5.500 5.500M15 14c3 0 5 1.500 6 5" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linecap="round"/>',
  info2: '<circle cx="12" cy="12" r="9.500" fill="none" stroke="currentColor" stroke-width="1.700"/><path d="M12 11v6" stroke="currentColor" stroke-width="1.900" stroke-linecap="round"/><circle cx="12" cy="7.500" r="1.200" fill="currentColor"/>',
};
const ico = (name, cls = '') => `<svg class="ico ${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICON[name]}</svg>`;
const mPerDegLon = (lat) => 111320 * Math.cos((lat * Math.PI) / 180);
// Distance between two people where the sim has them (not their display seats, seats.js), in metres.
const simDistM = (a, b) => {
  const la = a.simLat ?? a.lat, lb = b.simLat ?? b.lat;
  return Math.hypot((la - lb) * 110574, ((a.simLon ?? a.lon) - (b.simLon ?? b.lon)) * mPerDegLon(lb));
};

// ---------- app ----------

const $ = (id) => document.getElementById(id);

async function main() {
  let res, dataUrl;
  progress('Reading the run…', 0.06);
  for (dataUrl of DATA_URLS) {
    // Streamed, gunzipped on the fly, keeping only columns the adapter knows: a 7,000-agent day fits.
    try { res = await loadCsv(dataUrl, Object.values(COLUMNS).flat()); break; } catch (err) { console.warn(`Couldn't load ${dataUrl}: ${err.message}`); }
  }
  if (!res) throw new Error(`couldn't load ${DATA_URLS.join(' or ')}`);
  progress('Loading the campus map…', 0.4);
  const [paths, runBuildings, osmOutlines, rooms] = await Promise.all([
    fetch('data/stanford_paths.json').then((r) => r.json()).catch(() => null),
    loadBuildings(dataUrl),
    fetch('../sim/data/osm/buildings.geojson').then((r) => r.json()).catch(() => null),
    loadRooms(dataUrl),
  ]);
  progress('Loading risk estimates…', 0.55);
  const outlines = runBuildings.outlines || osmOutlines; // the run's own footprints when it has them
  // Heat zones: one per building footprint (zones.js). People sit inside their building, clustered by room
  // (seats.js), and their heat spreads only through it (diffuse.js).
  const Z = buildZones(outlines), zoneHeat = Z.zones.length > 0;
  const simPaths = await fetch(new URL('map/paths.geojson', new URL(dataUrl, location.href))).then((r) => r.json()).catch(() => null);
  const roomAreas = new Map(); // room id -> floor area in m² (map/rooms.csv), for how far its people spread
  const roomArea = (id) => {
    const i = rooms.index.get(id);
    if (i === undefined) return undefined;
    if (!roomAreas.has(id)) {
      const g = wktGeometry(rooms.wkts[i]), ring = g.type === 'Polygon' ? g.coordinates[0] : g.coordinates[0][0];
      let a = 0;
      for (let k = 0; k + 1 < ring.length; k++) a += (ring[k][0] * ring[k + 1][1] - ring[k + 1][0] * ring[k][1]) * mPerDegLon(ring[0][1]) * 110574;
      roomAreas.set(id, Math.abs(a) / 2);
    }
    return roomAreas.get(id);
  };
  const seats = makeSeats(Z, roomArea, simPaths, runBuildings.water);
  setSimMap({ buildings: runBuildings.outlines, paths: simPaths });
  const data = toFrames(res.data, res.fields, runBuildings.names);
  // Replace the placeholder P(sick) with the model's, before tracks, totals and forecasts are built.
  const model = data.beliefFrom === 'column' ? null : await loadModel(dataUrl, [...new Set(data.samples.map((a) => a.id))]);
  if (model) {
    for (const a of data.samples) a.p = model.risk.pAt(a.id, a.t);
    data.beliefFrom = 'column'; // a real estimate now, not a placeholder (legend wording)
  }
  const reportsBy = await loadReportEvents(dataUrl);
  progress('Placing everyone…', 0.75);
  const tracks = buildTracks(data.samples);
  // Walk the sim's own logged routes (trips.csv.gz) when the run has them; the Router is the fallback.
  const trips = await loadTrips(dataUrl);
  if (trips) attachTrips(tracks, trips);
  // Big runs: the user map's totals from tools/precompute.mjs, kept in heatmap/out/<run>/ (or next to the timeline).
  const runDir = new URL('.', new URL(dataUrl, location.href)), run = runDir.pathname.split('/').filter(Boolean).at(-1);
  const pre = tracks.size < BIG_RUN && !bigRun ? null
    : (await loadTotals(new URL(`out/${run}/totals.json.gz`, location.href))) || (await loadTotals(new URL('totals.json.gz', runDir)));
  if (!pre && /timeline_changes\.csv(\.gz)?$/.test(dataUrl)) { // with precomputed totals, nothing needs every step
    Object.assign(data, expandSteps(tracks, data.times, model && model.risk.pAt));
  }
  // Positions interpolate between samples, but risk comes straight from the model when there is one
  // (a compact stay is two rows hours apart; a report mid-stay must show up when it happens).
  const stateNow = (track, t) => {
    const st = stateAt(track, t, router);
    if (st && model) st.p = model.risk.pAt(st.id, t);
    return st;
  };
  // Every k-th agent (by id) gets a dot when there are too many to draw smoothly.
  const ids = [...tracks.keys()].sort();
  const dotSample = ids.length > MAX_DOTS ? new Set(ids.filter((_, i) => i % Math.ceil(ids.length / MAX_DOTS) === 0)) : null;
  // Everyone without a dot only feeds the heat: their latest sample, not walked along the route, with
  // the model's P now. Several times cheaper than stateNow, which matters at 7,500 agents.
  const stayNow = (track, t) => {
    const r = sampleAt(track, t);
    return r && { id: r.id, lat: r.lat, lon: r.lon, p: model ? model.risk.pAt(r.id, t) : r.p, sick: r.sick, infectious: r.infectious,
      building: r.building, buildingId: r.buildingId, floor: r.floor, room: r.room, walking: Boolean(r.moving) };
  };
  const { frames, times } = data;
  const router = paths ? new Router(paths) : null; // without it, agents walk in straight lines
  const bounds = dataBounds(frames);
  const sw = [bounds.south, bounds.west], ne = [bounds.north, bounds.east];
  const t0 = times[0], t1 = times[times.length - 1];

  // Room-level demo heat: deposit people over the last hour, then diffuse within building outlines.
  const probe = new DiffusionField(bounds, DEMO.cellM);
  const zoneRaster = zoneHeat ? (zi, grid) => rasterZone(Z.zones[zi], grid) : null;
  const field = new DiffusionField(bounds, DEMO.cellM, { zones: zoneRaster });
  // Zoomed out, the spread grows to 120 m: 40 cells of 3 m per σ, where ~5 look the same and cost far
  // less (the blur's cost is the grid's). So big spreads use a coarser grid (and its own building mask).
  const fields = new Map([[DEMO.cellM, field]]);
  const coarseCell = (sigma) => DEMO.cellM * Math.max(1, Math.round(sigma / (6 * DEMO.cellM)));
  // Building heat close up (zoom >= FINE_ZOOM) on a 1.5 m grid, so a person's glow is smooth at street zoom.
  const FINE_ZOOM = 18, FINE_CELL_M = 1.5;
  let fine = false;
  const fieldFor = (sigma) => {
    const cell = zoneHeat && fine ? FINE_CELL_M : coarseCell(sigma);
    if (!fields.has(cell)) fields.set(cell, new DiffusionField(bounds, cell, { zones: zoneRaster }));
    return fields.get(cell);
  };
  const zoneOf = (s) => (s.buildingId ? Z.zoneFor(s.buildingId) : -1);
  // The geographic extent a grid covers (whole cells, so a little past the data bounds).
  const gridBounds = (g) => [[g.bounds.north - (g.ny * g.cellM) / 110574, g.bounds.west],
    [g.bounds.north, g.bounds.west + (g.nx * g.cellM) / g.mPerDegLon]];
  let lastField = field;
  const statesAt = (t) => {
    const out = [];
    for (const [id, track] of tracks) {
      const st = !dotSample || dotSample.has(id) ? stateNow(track, t) : stayNow(track, t);
      if (st) out.push(st);
    }
    return seats.place(out);
  };
  // No people field: nothing masks by it.
  // The spread follows the zoom: 18 m (room-level) close up, about 16 screen pixels when zoomed out, so a
  // cloud never shrinks to a dot. Set by the map's zoom (see sigmaForZoom below).
  let sigmaM = DEMO.sigmaM;
  // area (optional): only people inside it count, e.g. the visible map plus a margin. Blurs only cover
  // where people were deposited, so close up on a big run this is a fraction of the campus.
  const heatAt = (t, nowStates = null, truth = false, area = null) => {
    const f = (lastField = fieldFor(sigmaM));
    f.clear();
    const states = nowStates || statesAt(t);
    f.deposit(asPoints(area ? [...states].filter((s) => area.contains([s.lat, s.lon])) : states, truth, outlines ? 'indoor' : null, zoneOf), 1);
    return f.diffuse(sigmaM, { people: false });
  };
  // People outdoors (only when indoor heat is kept to outlines): a plain grid of their own, drawn unclipped.
  // Half the indoor cell: the outdoor spread is half the indoor one, and at ~1 cell per σ the box blurs
  // give each person a 3×3 square, so overlapping people show blocky seams instead of smooth blobs.
  const outFields = new Map();
  const outdoorAt = (t, nowStates = null, truth = false, area = null) => {
    const cell = coarseCell(sigmaM) / 2;
    if (!outFields.has(cell)) outFields.set(cell, new DiffusionField(bounds, cell));
    const f = outFields.get(cell);
    f.clear();
    const states = nowStates || statesAt(t);
    f.deposit(asPoints(area ? [...states].filter((s) => area.contains([s.lat, s.lon])) : states, truth, 'outdoor'), OUTDOOR_WEIGHT);
    return f.diffuse(sigmaM * OUTDOOR_SIGMA, { people: false });
  };
  // Peak density of one person's outdoor heat (per grid and spread, measured once): dividing by it turns
  // the field into expected sick at the brightest cell, the unit the rooms are coloured in.
  const outPeaks = new Map();
  const outdoorPeak = (f) => {
    const key = `${f.cellM}:${f.sigmaM}`;
    if (!outPeaks.has(key)) {
      const probe = new DiffusionField(bounds, f.cellM), cx = Math.floor(probe.nx / 2), cy = Math.floor(probe.ny / 2);
      probe.deposit([{ lat: bounds.north - ((cy + 0.5) * f.cellM) / 110574, lon: bounds.west + ((cx + 0.5) * f.cellM) / probe.mPerDegLon, p: 1, indoor: false }]);
      outPeaks.set(key, probe.diffuse(f.sigmaM, { people: false }).max() || 1);
    }
    return outPeaks.get(key);
  };
  // Everything the user-facing map gets is computed here, from totals only.
  const scale = userScale(tracks.size);
  const totals = pre ? pre.totals : buildTotals(frames, times, { scale, prior: MODEL.prior });
  const forecaster = pre ? pre.forecaster : buildForecaster(frames, times, { scale, prior: MODEL.prior });
  const backtestRate = forecaster.backtest(60).rate;
  // Airflow (experimental): infectious air that builds up in rooms, leaks through doors and is
  // ventilated away (aerosol.js). Stateful, so it steps forward with the clock; a backward scrub or a
  // big jump resets it and warms it up over the previous AIRFLOW_WARMUP_MS.
  const AIRFLOW_WARMUP_MS = 90 * 60000, AIRFLOW_STEP_MS = 10 * 60000;
  let aero = null, aeroT = null, aeroMax = 1e-9;
  const airSources = function* (states, truth) {
    for (const st of states) {
      const rate = truth ? Number(Boolean(st.infectious)) : Math.max(0, st.p - MODEL.prior); // above the baseline
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

  // Building shading (the default presenter view, when the run has outlines): each building's darkness is linear in
  // the expected number of infected people in it now, Σ P(infected) over everyone inside (the dots' P, model.risk.pAt),
  // divided by the building's footprint area: expected infected per 1,000 m², so a crowded small building reads darker
  // than the same count spread through a big one. truth: the number actually infected (sim), per 1,000 m².
  // People outdoors or walking count nowhere; empty buildings stay plain.
  const shading = zoneHeat;
  const areaM2 = footprintAreas(outlines); // buildingId -> footprint m² (one floor's outline; floors aren't known)
  const buildingSums = (states, truth = false) => {
    const out = new Map();
    for (const s of states) if (s.buildingId && !s.walking) out.set(s.buildingId, (out.get(s.buildingId) || 0) + (truth ? Number(Boolean(s.sick)) : s.p));
    return out;
  };
  const buildingDensity = (states, truth = false) => {
    const out = new Map();
    for (const [id, e] of buildingSums(states, truth)) { const a = areaM2.get(id); if (a) out.set(id, (1000 * e) / a); }
    return out;
  };
  // Fixed scale, the same at every moment: the 95th percentile of every occupied building's sum over ~100 moments
  // of the run (everyone at their latest sample, cheap), so the busiest buildings saturate and the rest spread out.
  const shadeMax = (() => {
    if (!shading) return 1;
    const all = [], N = 100;
    for (let k = 0; k < N; k++) {
      const t = t0 + ((t1 - t0) * (k + 0.5)) / N, states = [];
      for (const track of tracks.values()) { const s = stayNow(track, t); if (s) states.push(s); }
      for (const e of buildingDensity(states).values()) all.push(e);
    }
    all.sort((a, b) => a - b);
    const q = all[Math.floor(0.95 * (all.length - 1))] || 1;
    return q >= 2 ? Math.ceil(q) : Number(q.toPrecision(1)) < q ? Number((q * 1.05).toPrecision(2)) : Number(q.toPrecision(1)); // a round number for the legend
  })();

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

  const ZONE_VMAX = 0.5;
  const vmax = { demo: zoneHeat ? ZONE_VMAX : scaleMax(heatAt, times), public: buildingScaleMax(totals), truth: null };
  // "True status (sim)" colouring also switches the demo heat to actual infections.
  const truthMode = () => data.hasTruth && $('dot-mode').value === 'truth';
  const scales = new Map([[`false:${sigmaM}`, vmax.demo]]); // "truth:sigma" -> colour max
  const demoScale = () => {
    const truth = truthMode(), key = `${truth}:${sigmaM}`;
    // Building heat is each person's chance above the baseline, peaking at them: a fixed scale (dark at 50%), so
    // a likely-sick person's peak reads dark and fades around them instead of saturating a wide disc.
    if (!scales.has(key)) scales.set(key, zoneHeat && !truth ? ZONE_VMAX : scaleMax((t) => heatAt(t, null, truth), times)); // on first use
    vmax[truth ? 'truth' : 'demo'] = scales.get(key);
    return scales.get(key);
  };
  if (!outlines) console.warn('No building outlines (serve from the repo root): the user map will be empty.');

  const map = baseMap('map', { maxBounds: L.latLngBounds(sw, ne).pad(1.5) });
  addLandmarks(map); // Lisa's drawings under the heat (assets/landmarks/)
  const sigmaForZoom = (z = map.getZoom()) => {
    const mPerPx = 156543.03 * Math.cos(map.getCenter().lat * Math.PI / 180) / 2 ** z;
    // ~6 screen px zoomed out, in 3 m steps (few cached scales), at most 15 m: a tight cloud around each person.
    // Close up a softer glow: 8 m at zoom 18 up to 10 m at 20 (building heat only; whole metres, few scales).
    if (zoneHeat && z >= FINE_ZOOM) return Math.min(10, 8 + Math.round(z - FINE_ZOOM));
    return Math.min(15, Math.max(DEMO.sigmaM, Math.round(6 * mPerPx / 3) * 3));
  };
  // People are sized on the ground: resize them at the end of every zoom and, during a long smooth zoom, when
  // smoothzoom.js redraws (zoomrefresh). Set directly, not with setRadius and setStyle (each reprojects and
  // queues a repaint per dot): the dots' renderer reprojects and redraws them all once anyway.
  const resizeDots = () => {
    const r = personRadius(map.getZoom()), mode = $('dot-mode').value;
    for (const [id, m] of dots) if (m._radius !== r) {
      m.options.radius = m._radius = r;
      m.options.weight = ringWeight(r, mode !== 'truth' && Boolean(current.get(id)?.sick));
    }
  };
  map.on('zoomend', resizeDots);
  map.on('zoomrefresh', resizeDots);
  // The heat covers only the visible map (plus a margin) at a spread set by the zoom, so a zoom or pan
  // redoes it, but once the gesture settles, not at every wheel step (a 50-100 ms stall each). Meanwhile
  // the heat canvases keep their last heat, scaled with the map and redrawn crisp at each step.
  const SETTLE_MS = 140;
  let zooming = false, settleTimer = 0;
  map.on('zoomstart', () => { zooming = true; clearTimeout(settleTimer); });
  map.on('moveend', () => {
    clearTimeout(settleTimer);
    settleTimer = setTimeout(() => {
      zooming = false;
      const next = sigmaForZoom(), nextFine = map.getZoom() >= FINE_ZOOM;
      if (next !== sigmaM || nextFine !== fine) { sigmaM = next; fine = nextFine; renderLegend(); }
      heatDirty = true;
      if (!playing) render(performance.now()); // playing: the next frame does it
    }, SETTLE_MS);
  });
  // Smooth zooming: the first zoom to a new spread or grid built that grid and its kernels on the spot
  // (a visible stall at zoom 16 and 18). Build every zoom level's once, in idle time after the page loads.
  const warmLevels = [];
  const planWarm = () => { // once the map has a view (sigmaForZoom reads its centre)
    for (let z = 13; z <= 20; z += 0.25) { // quarter steps: zoom is continuous now (smoothzoom.js)
      const lv = { sigma: sigmaForZoom(z), fine: zoneHeat && z >= FINE_ZOOM };
      if (!warmLevels.some((w) => w.sigma === lv.sigma && w.fine === lv.fine)) warmLevels.push(lv);
    }
  };
  const idle = window.requestIdleCallback || ((fn) => setTimeout(fn, 200));
  const warmNext = () => {
    const lv = warmLevels.shift();
    if (!lv) return;
    if (lv.sigma !== sigmaM || lv.fine !== fine) {
      const keep = [sigmaM, fine, lastField];
      [sigmaM, fine] = [lv.sigma, lv.fine];
      try { heatAt(now, current.values()); } finally { [sigmaM, fine, lastField] = keep; }
    }
    idle(warmNext);
  };
  setTimeout(() => { if (!map._loaded || shading) return; planWarm(); idle(warmNext); }, 1500); // after the first frames are on screen; shading needs no grids
  // Fit once the map actually has a size; a page opened in a background tab starts at 0×0.
  let fitted = false;
  new ResizeObserver(() => {
    map.invalidateSize();
    if (fitted || !map.getSize().x || !map.getSize().y) return; // wait for real width *and* height
    fitted = true;
    map.fitBounds(viewBounds(frames) || [sw, ne]);
    map.setMinZoom(map.getZoom() - 2);
    // ?zoom=19 (with ?agent=…) opens close up on that person, e.g. to watch airflow in their room.
    const zoom = Number(new URLSearchParams(location.search).get('zoom'));
    const me = selected && current.get(selected);
    if (zoom && me) map.setView([me.lat, me.lon], zoom);
  }).observe($('map'));
  const outdoorLayer = outlines ? new CanvasLayer([sw, ne]).addTo(map) : null; // outdoor heat, under the rooms' heat
  const heatLayer = new CanvasLayer([sw, ne]).addTo(map);
  const shadeLayer = new BuildingShadeLayer(outlines); // the default view's building shading
  const publicLayer = outlines ? new BuildingTotalsLayer(outlines, { avoid: () => [$('ulegend')?.getBoundingClientRect(), document.querySelector('.embed-chip')?.getBoundingClientRect()] }) : null; // shown in "What users see"

  if (dotSample) {
    document.querySelector('.legend .fine').prepend(`Dots: ${dotSample.size} of ${ids.length.toLocaleString()} people (sample). `);
  }
  // 8 px of reach beyond each dot, so the 2 px dots at campus zoom are easy to hit (the nearest wins).
  const dotRenderer = new NearestCanvas({ padding: 0.5, tolerance: 8 });
  const dotLayer = L.layerGroup().addTo(map);
  const dots = new Map(); // agent id -> person marker
  PERSON.onload = () => { for (const m of dots.values()) if (m._map) m.redraw(); };
  let current = new Map(); // agent id -> interpolated state at the current time

  // ?at=<minutes from the start> opens at a specific moment (handy for demos and screenshots).
  // Otherwise open on the first day's busiest walking moment (a class change), not a sleeping campus.
  const at = Number(new URLSearchParams(location.search).get('at'));
  let now = at ? Math.min(t1, t0 + at * 60000) : busiestMoment(), playing = false, selected = null, lastHeat = -Infinity, heatDirty = true, heatInterval = 0;
  let tissueAlert = null; // design pass: the tissue-box alert on the phone mock
  let phoneMap = null, phoneBuildings = null, phoneTab = new URLSearchParams(location.search).get('tab') || 'today', airflowTruth = false;

  function busiestMoment() {
    const sample = [...tracks.values()].slice(0, 500), DAY = 24 * 3600000;
    // Risk above the baseline (what the heat shows) at each day's noon; open on the first day with at least
    // a quarter of the highest: heat on screen, and in a growing outbreak days left to play (half opened the
    // 4-day run on its last day). Plain Σ P counted everyone's 2% prior, so a quiet first day opened blank.
    const totals = [];
    for (let d = t0; d < t1; d += DAY) totals.push(sample.reduce((sum, tr) => sum + Math.max(0, (stateNow(tr, d + DAY / 2)?.p || 0) - MODEL.prior), 0));
    const day = Math.max(0, totals.findIndex((x) => x >= 0.25 * Math.max(...totals)));
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
      renderer: dotRenderer, radius: personRadius(map.getZoom()), weight: personRing(personRadius(map.getZoom())), color: COLORS.ring, fillOpacity: 1,
      bubblingMouseEvents: false, // a click on a person opens their phone, not the building under them
    });
    m.bindTooltip(() => {
      const a = current.get(id);
      if (!a) return id;
      const where = a.walking ? 'walking' : [a.building, a.room && (roomNames.get(a.room) || `room ${a.room}`)].filter(Boolean).join(', ');
      const truth = a.sick === null ? '' : ` · ${a.sick ? 'infected' : 'healthy'} (sim)`;
      return `<b>${id}</b>${where ? ` · ${where}` : ''}<br>App estimate ${pct(a.p)}${truth}`;
    });
    m.on('click', () => select(id));
    m.on('mouseover', () => { hoverDot = id; if (m.options.fillOpacity !== 1) m.setStyle({ fillOpacity: 1, opacity: 1 }); });
    m.on('mouseout', () => { if (hoverDot === id) hoverDot = null; });
    dots.set(id, m);
    return m;
  }

  // Is anyone within radiusM of me who matches `test`? Indoors, walls block (same room only).
  function someoneNear(me, radiusM, test) {
    for (const a of current.values()) {
      if (a.id === me.id || !test(a)) continue;
      if (data.hasRoom && !me.walking && (a.building !== me.building || a.room !== me.room)) continue;
      if (simDistM(a, me) <= radiusM) return true;
    }
    return false;
  }

  // Contacts within Bluetooth range per person, as phones would log them: { tMs, other, min, d }, by time.
  // Close-contact minutes only count those within 6 ft (NEARBY_M).
  const exposureLog = new Map();
  if (model) {
    const log = (id, e) => { if (!exposureLog.has(id)) exposureLog.set(id, []); exposureLog.get(id).push(e); };
    for (const c of model.contacts) {
      const d = Number(c.distance_m);
      if (!(d <= BT_RANGE_M)) continue;
      const tMs = model.startMs + Number(c.t) * model.stepMs, min = Number(c.duration_s) / 60;
      log(c.agent_a, { tMs, other: c.agent_b, min, d });
      log(c.agent_b, { tMs, other: c.agent_a, min, d });
    }
    for (const list of exposureLog.values()) list.sort((a, b) => a.tMs - b.tMs);
  }
  // The earliest close-contact alert anyone gets (15 weighted minutes within 6 ft over 24 h): { id, tMs } | null.
  function firstCloseContact() {
    let best = null;
    for (const [id, list] of exposureLog) {
      const q = []; let sum = 0;
      for (const e of list) {
        if (e.d > NEARBY_M || (best && e.tMs >= best.tMs)) continue;
        const p = model.risk.pAt(e.other, e.tMs), w = p >= CONTAGIOUS ? 1 : p >= RISKY ? 0.5 : 0;
        if (!w) continue;
        q.push([e.tMs, w * e.min]); sum += w * e.min;
        while (q[0][0] < e.tMs - EXPOSURE_WINDOW_MS) sum -= q.shift()[1];
        if (sum >= CLOSE_CONTACT_MIN) { best = { id, tMs: e.tMs + e.min * 60000 }; break; } // the alert lands when that contact has fully counted
      }
    }
    return best;
  }
  // Weighted exposure minutes within `windowMs` before t. Live: each contact's risk as the app knew it
  // at the time. Retro: their risk as known now, i.e. people who have since reported sick.
  function exposureMinutes(id, t, windowMs, retro) {
    let total = 0;
    for (const e of exposureLog.get(id) || []) {
      if (e.tMs > t) break;
      if (e.tMs < t - windowMs || e.d > NEARBY_M) continue;
      const p = model.risk.pAt(e.other, retro ? t : e.tMs);
      const w = p >= CONTAGIOUS ? 1 : p >= RISKY ? 0.5 : 0;
      total += w * Math.min(e.min, (t - e.tMs) / 60000);
    }
    return total;
  }
  // Each person's own status as their phone knows it (product owner, 2026-10-17): 0.97 after a positive
  // test, 0.6 after reporting symptoms, for 7 days; a negative test or "recovered" clears it.
  const statusLog = new Map();
  for (const r of model?.reports || []) {
    const v = r.event === 'test_result' ? ({ positive: 0.97, negative: 0 })[r.value]
      : r.event === 'self_report' ? ({ tested_positive: 0.97, might_be_sick: 0.6, recovered: 0 })[r.value] : undefined;
    if (v === undefined) continue;
    if (!statusLog.has(r.agent_id)) statusLog.set(r.agent_id, []);
    statusLog.get(r.agent_id).push([model.startMs + Number(r.t) * model.stepMs, v]);
  }
  for (const list of statusLog.values()) list.sort((a, b) => a[0] - b[0]);
  const statusFloor = (id, t) => {
    let v = 0, at = -Infinity;
    for (const [tt, x] of statusLog.get(id) || []) { if (tt > t) break; v = x; at = tt; }
    return t - at <= 7 * 86400000 ? v : 0;
  };
  // What a phone broadcasts: its own score, max(phone estimate, status floor), as of one step earlier (the
  // lag breaks the self-loop), quantised to a byte as round(255·sqrt(p)). Other phones use it, never show it.
  const quantScore = (p) => (Math.round(255 * Math.sqrt(Math.min(1, Math.max(0, p)))) / 255) ** 2;
  const scoreMemo = new Map();
  function broadcastScore(id, t, depth) {
    const key = `${id}|${Math.floor(t / model.stepMs)}|${depth}`;
    let v = scoreMemo.get(key);
    if (v === undefined) {
      const tb = t - model.stepMs;
      v = quantScore(Math.max(phoneEstimate(id, tb, depth), statusFloor(id, tb)));
      scoreMemo.set(key, v);
    }
    return v;
  }
  // This phone's estimate (see PHONE_DOSE): peers in Bluetooth range over the last 24 h. Per peer
  // s = max(their status, their broadcast score above the prior): Rio's P_j as the phone can know it, so
  // getting closer to anyone who may be sick raises it. depth: how many hops of shared scores to follow
  // (peers' own scores use their status only; the loop gain is small).
  let lastPhoneDose = 0; // the dose behind the last phoneEstimate, for "How is this calculated?"
  function phoneEstimate(id, t, depth = 1) {
    const dose = new Map();
    for (const e of exposureLog.get(id) || []) {
      if (e.tMs > t) break;
      if (e.tMs < t - EXPOSURE_WINDOW_MS) continue;
      const floor = statusFloor(e.other, e.tMs);
      const s = depth > 0 ? Math.max(floor, broadcastScore(e.other, e.tMs, depth - 1) - MODEL.prior) : floor;
      if (!(s > 0)) continue;
      const durS = 60 * Math.min(e.min, (t - e.tMs) / 60000);
      const k = dose.get(e.other) || { s: 0, dose: 0 };
      k.dose += PHONE_DOSE({ distance_m: e.d, duration_s: durS, indoor: true });
      k.s = Math.max(k.s, s);
      dose.set(e.other, k);
    }
    let p = MODEL.prior;
    let total = 0;
    for (const { s, dose: x } of dose.values()) { p += (1 - p) * s * (1 - Math.exp(-PHONE_STAGE * x)); total += x; }
    if (depth === 1) lastPhoneDose = total; // the top-level call, not a peer's nested score
    return p;
  }

  // What the phone tells this person right now, as FlUni's Today computes it. Proximity uses nearby phones
  // (a heads-up, then a close-contact alert at 15 weighted minutes); the walk-in warning uses building
  // totals only (the building's high flag: heat = sqrt(expected / colour max) >= 0.5).
  function phoneState(me) {
    const live = model ? exposureMinutes(me.id, now, EXPOSURE_WINDOW_MS, false) : 0;
    const later = model ? exposureMinutes(me.id, now, NOTICE_WINDOW_MS, true) : 0;
    const near = (data.hasTruth && someoneNear(me, ADJACENT_M, (a) => a.infectious)) || someoneNear(me, NEARBY_M, (a) => a.p >= RISKY);
    // As FlUni: "Close contact" means 15 weighted minutes in the last 24 h. People who were near someone
    // who reported sick later show up under Recent contacts and in the campus-model risk, not here.
    const level = live >= CLOSE_CONTACT_MIN ? 'close' : near ? 'nearby' : 'none';
    let walkIn = null;
    const b = !me.walking && me.buildingId && totalsAt(totals, now).buildings.get(me.buildingId);
    if (b && b.n >= MIN_PEOPLE && Math.sqrt(Math.min(1, (b.excess ?? b.expected) / vmax.public)) >= 0.5) walkIn = b.name || me.building || 'This building';
    // Other phones within Bluetooth range (~10 m, same room indoors) that run the app.
    let peers = 0;
    for (const a of current.values()) {
      if (a.id === me.id) continue;
      const hasApp = model && model.traits.get(a.id)?.has_app;
      if (hasApp !== undefined && /^(0|false|no)$/i.test(String(hasApp))) continue;
      if (data.hasRoom && !me.walking && (a.building !== me.building || a.room !== me.room)) continue;
      if (simDistM(a, me) <= 10) peers++;
    }
    return { live, later, level, walkIn, peers };
  }

  // "Recent contacts": risky-contact episodes in the last 14 days, as FlUni's exposure history groups them.
  const episodeCache = { key: '', list: [] };
  function recentEpisodes(id) {
    const key = `${id}@${Math.floor(now / (5 * 60000))}`;
    if (episodeCache.key === key) return episodeCache.list;
    const list = [];
    for (const e of model ? exposureLog.get(id) || [] : []) {
      if (e.tMs > now) break;
      if (e.tMs < now - 14 * 24 * 3600000 || e.d > NEARBY_M) continue;
      const p = model.risk.pAt(e.other, e.tMs), w = p >= CONTAGIOUS ? 1 : p >= RISKY ? 0.5 : 0;
      if (!w) continue;
      const last = list[list.length - 1];
      if (last && e.tMs - last.end <= 30 * 60000) { last.min += e.min; last.weighted += w * e.min; last.end = e.tMs; last.contagious ||= w === 1; }
      else list.push({ start: e.tMs, end: e.tMs, min: e.min, weighted: w * e.min, contagious: w === 1 });
    }
    episodeCache.key = key;
    return (episodeCache.list = list.reverse());
  }
  const episodeText = (ep) => {
    const when = data.numericTime ? formatTime(ep.start, true).split(', ')[1] // no sim dates on the phone
      : new Date(ep.start).toLocaleString('en-US', { weekday: 'short', hour: 'numeric', minute: '2-digit' }).replace(' AM', ' am').replace(' PM', ' pm').replace(',', '');
    return `${when} · about ${Math.max(1, Math.round(ep.min))} min near ${ep.contagious ? 'someone who tested positive' : 'someone with symptoms'}${ep.weighted >= CLOSE_CONTACT_MIN ? ' · close contact' : ''}`;
  };

  // ---- The phone mock's data: what FlUni's Today / You show for the selected person, from the sim ----
  // (views in phone-views.js; same numbers as before: campus model P, this phone's estimate, close-contact minutes)
  const ph = { for: null, openKey: null, seen: new Set(), sheet: null, picked: new Set(['fever', 'cough']), when: 1, stamped: false, html: { today: '', you: '', sheet: '' } };
  const DAYMS = 24 * 3600000;
  const cache = { key: '', v: null };
  // Where this person was over the last 24 h: building visits from their timeline, newest first.
  function visitsFor(id) {
    const key = `${id}@${Math.floor(now / (5 * 60000))}`;
    if (cache.key === key) return cache.v;
    const out = [], tr = tracks.get(id) || [];
    let cur = null;
    for (const s of tr) {
      if (s.t > now) break;
      if (cur && cur.id === s.buildingId) continue;
      if (cur) { cur.endMs = s.t; out.push(cur); cur = null; }
      if (s.buildingId) cur = { id: s.buildingId, name: s.building || 'On campus', startMs: s.t };
    }
    if (cur) { cur.endMs = now; cur.current = true; out.push(cur); }
    const eps = recentEpisodes(id).filter((e) => e.start > now - DAYMS).map((e) => ({
      type: e.weighted >= CLOSE_CONTACT_MIN ? 'close' : 'heads', key: `m${e.start}`, startMs: e.start, endMs: e.end,
      minutes: Math.max(e.min, 1), contagious: e.contagious,
      place: out.find((v) => v.startMs - 60000 <= e.start && e.start <= v.endMs + 60000)?.name || null }));
    const places = out.filter((v) => v.endMs > now - DAYMS && !v.current).map((v) => {
      const minutes = (v.endMs - v.startMs) / 60000;
      let maxPhones = 0;
      for (const f of [0.2, 0.5, 0.8]) { // phones in the same building at three moments of the visit
        const t = v.startMs + f * (v.endMs - v.startMs);
        let n = 0;
        for (const [oid, otr] of tracks) if (oid !== id && sampleAt(otr, t)?.buildingId === v.id) n++;
        maxPhones = Math.max(maxPhones, n);
      }
      const hit = eps.filter((e) => e.startMs <= v.endMs + 60000 && e.endMs >= v.startMs - 60000);
      const tone = hit.some((e) => e.type === 'close') ? 'close' : hit.length ? 'heads' : maxPhones > 0 ? 'phones' : 'quiet';
      return { type: 'place', startMs: Math.max(v.startMs, now - DAYMS), name: v.name, minutes, maxPhones, tone, passing: minutes < 3 };
    });
    const entries = [...places, ...eps].sort((a, b) => b.startMs - a.startMs);
    const current = out.find((v) => v.current) || null;
    const curHit = current && eps.some((e) => e.endMs >= current.startMs - 60000);
    cache.key = key;
    return (cache.v = { entries, current, eps, placeTone: curHit ? 'heads' : null });
  }

  // Self-reports (reports_tests.csv): what this person told the app, up to now.
  function selfStatus(id) {
    let status = 'none', startMs = null, positive = false;
    for (const e of reportsBy.get(id) || []) {
      if (e.ms > now) break;
      if (e.event === 'self_report' && e.value === 'might_be_sick') { status = 'possible'; startMs = e.ms; positive = false; }
      else if ((e.event === 'self_report' && e.value === 'tested_positive') || (e.event === 'test_result' && e.value === 'positive')) { status = 'contagious'; startMs = startMs ?? e.ms; positive = true; }
      else if ((e.event === 'self_report' && e.value === 'recovered') || (e.event === 'test_result' && e.value === 'negative')) { status = 'none'; startMs = null; positive = false; }
    }
    return { status, startMs, positive };
  }
  const midnight = (ms) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };

  function phoneData(me, st) {
    const v = visitsFor(me.id);
    const sr = selfStatus(me.id);
    const phoneP = model ? Math.max(phoneEstimate(me.id, now), statusFloor(me.id, now)) : MODEL.prior; // never low when they're sick
    const dayNo = sr.startMs == null ? 0 : Math.round((midnight(now) - midnight(sr.startMs)) / DAYMS);
    const stay = sr.startMs == null ? null : {
      day: dayNo, over: dayNo > 5, positive: sr.positive, startMs: sr.startMs, lastMs: midnight(sr.startMs) + 5 * DAYMS + 12 * 3600000,
      days: Array.from({ length: 6 }, (_, i) => ({ day: i, ms: midnight(sr.startMs) + i * DAYMS + 12 * 3600000 })),
    };
    return {
      now, dateText: data.numericTime ? `Day ${Math.floor((now - t0) / DAYMS) + 1}` : new Date(now).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' }),
      place: v.current ? { name: v.current.name, startMs: v.current.startMs } : (me.building ? { name: me.building, startMs: now } : null),
      level: st.level, peers: st.peers, walkIn: st.walkIn, minutes: Math.min(99, Math.floor(st.live)), exactMinutes: st.live,
      p: phoneP, campusP: me.p, dose: lastPhoneDose, posTest: MODEL.posTest, selfReport: MODEL.selfReport,
      entries: v.entries, placeTone: v.placeTone, openKey: ph.openKey, seen: ph.seen,
      status: sr.status, stamp: sr.status === 'possible', stay,
      contacts: recentEpisodes(me.id).map((e) => ({ startMs: e.start, close: e.weighted >= CLOSE_CONTACT_MIN,
        text: `About ${Math.max(1, Math.round(e.min))} min near ${e.contagious ? 'someone who tested positive' : 'someone with symptoms'}` })),
    };
  }
  const setHtml = (el, key, html) => { if (ph.html[key] !== html) { ph.html[key] = html; el.innerHTML = html; } };
  function renderSheet(d) {
    const sh = $('ph-sheet');
    if (!ph.sheet) { sh.hidden = true; ph.html.sheet = ''; return; }
    const html = ph.sheet === 'report' ? PV.reportSheetHtml(ph, d) : ph.sheet === 'calc' ? PV.calcSheetHtml(d) : PV.howSheetHtml();
    sh.hidden = false;
    if (ph.html.sheet !== html) { const top = sh.querySelector('.sheet')?.scrollTop || 0; ph.html.sheet = html; sh.innerHTML = html; const el = sh.querySelector('.sheet'); if (el) { el.style.animation = top ? 'none' : ''; el.scrollTop = top; } }
  }
  // Taps inside the phone: sheets, the close contact folding, the stickers. Visual only: the sim never changes.
  $('phone').addEventListener('click', (e) => {
    const b = e.target.closest('[data-act]');
    if (!b) { if (e.target.id === 'ph-sheet') { ph.sheet = null; renderPhone(); } return; }
    const act = b.dataset.act, key = b.dataset.key;
    if (act === 'calc' || act === 'how') ph.sheet = act;
    else if (act === 'report') { ph.sheet = 'report'; ph.stamped = false; }
    else if (act === 'sheet-close') ph.sheet = null;
    else if (act === 'sticker') { ph.picked.has(b.dataset.k) ? ph.picked.delete(b.dataset.k) : ph.picked.add(b.dataset.k); }
    else if (act === 'when') ph.when = Number(b.dataset.i);
    else if (act === 'report-send') { ph.stamped = true; renderPhone(); setTimeout(() => { ph.sheet = null; ph.stamped = false; renderPhone(); }, 1500); return; }
    else if (act === 'got-it') { ph.seen.add(key); ph.openKey = `x${key}`; }
    else if (act === 'cc-toggle') ph.openKey = ph.openKey === key ? `x${key}` : key;
    renderPhone();
  });

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
  mathBox.style.cssText = 'position:absolute;top:16px;right:445px;z-index:1100;width:340px;max-height:calc(100% - 32px);overflow:auto';
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

  function setPhoneTab(tab) {
    phoneTab = tab;
    for (const t of ['today', 'map', 'me']) $(`ph-tab-${t}`).hidden = t !== tab;
    for (const b of document.querySelectorAll('.tabbar button')) b.setAttribute('aria-selected', String(b.dataset.tab === tab));
    renderPhone(true);
    if (tab === 'map' && phoneMap) {
      phoneMap.invalidateSize();
      fitPhoneMap();
    }
  }

  // A lock-screen style banner, with FlUni's own notification text, when this person newly crosses into a
  // heads-up, a close contact, or a busy building (not for the state they were already in when opened).
  let noticeFor = null, noticeSeen = { level: 'none', walkIn: null }, noticeTimer = null, noticeT = -Infinity;
  function phoneNotice(me, st) {
    // A new person, or time went backwards (a scrub back): start over, and drop a banner from the later moment.
    if (noticeFor !== me.id || now < noticeT) {
      if (now < noticeT) document.querySelector('#phone .ph-banner')?.remove();
      noticeFor = me.id; noticeSeen = { level: st.level, walkIn: st.walkIn }; noticeT = now;
      return;
    }
    noticeT = now;
    const rank = { none: 0, nearby: 1, close: 2 };
    let text = null;
    if (rank[st.level] > rank[noticeSeen.level]) {
      text = st.level === 'close' ? noteFit(ADVICE.close.body) : noteFit([`${ADVICE.nearby.title}.`, ...ADVICE.nearby.body]);
    } else if (st.walkIn && st.walkIn !== noticeSeen.walkIn) {
      text = noteFit([`${st.walkIn} has a lot of illness right now. Consider a mask, or a different spot.`]);
    }
    noticeSeen = { level: st.level, walkIn: st.walkIn };
    if (!text) return;
    const frame = document.querySelector('#phone .phone-frame');
    frame.querySelector('.ph-banner')?.remove();
    const b = Object.assign(document.createElement('div'), { className: 'ph-banner', role: 'alert' });
    b.innerHTML = `<img class="ph-banner-icon" src="assets/illustrations/tissue.png" alt=""><div class="ph-banner-body"><div class="ph-banner-head"><span class="ph-banner-app">FlUni</span><span>now</span></div><p>${esc(text)}</p></div>`;
    frame.append(b);
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => b.remove(), 7000);
  }

  // The phone's Campus tab: FlUni's own user map look (usermap.js): paper, pale outlines, faint roads, soft green and water,
  // anchor labels; no tiles. Heat comes from the same BuildingTotalsLayer as "What users see".
  let phoneAnchors = null;
  const NIGHT_INK = '#f1e2c6';
  const NIGHT_CONTEXT = { green: { fillColor: '#5f6e45', fillOpacity: 0.55 }, water: { fillColor: '#4d6a70', fillOpacity: 0.75 },
    road: { color: NIGHT_INK, opacity: 0.22 }, street: { color: NIGHT_INK, opacity: 0.12 }, rail: { color: NIGHT_INK, opacity: 0.2 },
    town: { color: NIGHT_INK, opacity: 0.15 }, shopping: { color: NIGHT_INK, fillColor: NIGHT_INK, opacity: 0.2 }, hospital: { color: NIGHT_INK, opacity: 0.2 } };
  const NIGHT_NEUTRAL = { color: NIGHT_INK, opacity: 0.2, fillColor: '#33281f' };
  const PHONE_BOUNDS = [[37.4171, -122.1833], [37.4379, -122.1565]]; // the sim's campus extent
  function fitPhoneMap() { phoneMap.fitBounds(PHONE_BOUNDS, { paddingTopLeft: [4, 56], paddingBottomRight: [4, 70], animate: false }); }
  function buildPhoneMap() {
    const map = smoothZoom(L.map('ph-map', { zoomControl: false, attributionControl: false, preferCanvas: true, zoomSnap: 0.25, zoomDelta: 0.5, maxZoom: 19 }));
    const pane = (name, z) => { const p = map.createPane(name); p.style.zIndex = z; p.style.pointerEvents = 'none'; return { pane: name, renderer: L.canvas({ pane: name }) }; };
    const PC = pane('pctx', 410), PN = pane('pneu', 420);
    // Night mode (theme.js): the same map in Lisa's night palette, cream lines on cocoa; heat keeps its colours.
    const ctxLayers = {};
    let neutral = null;
    const styleMap = () => {
      const night = $('phone').dataset.theme === 'night';
      map.getContainer().style.background = night ? '#2a211c' : '#f4ead6';
      for (const [k, l] of Object.entries(ctxLayers)) l.setStyle(night ? { ...CONTEXT_STYLE[k], ...NIGHT_CONTEXT[k] } : CONTEXT_STYLE[k]);
      neutral?.setStyle(night ? { ...NEUTRAL_BUILDING, ...NIGHT_NEUTRAL } : NEUTRAL_BUILDING);
    };
    $('phone').addEventListener('fluni-theme', styleMap);
    styleMap();
    fetch('data/context.geojson').then((r) => (r.ok ? r.json() : null)).then((ctx) => {
      if (!ctx) return;
      for (const k of CONTEXT_ORDER) ctxLayers[k] = L.geoJSON({ type: 'FeatureCollection', features: ctx.features.filter((f) => f.properties.k === k) }, { style: () => CONTEXT_STYLE[k], interactive: false, ...PC }).addTo(map);
      styleMap();
    }).catch(() => {});
    if (outlines) neutral = L.geoJSON(outlines, { style: () => NEUTRAL_BUILDING, interactive: false, ...PN }).addTo(map);
    styleMap();
    phoneBuildings = new BuildingTotalsLayer(outlines || { features: [] }, { badges: false, names: false }).addTo(map);
    const labels = new LabelLayer(map, { pane: 'ph-labels', avoid: () => [document.querySelector('#phone .cchip')?.getBoundingClientRect(), document.querySelector('#phone .cleg')?.getBoundingClientRect()] });
    fetch('out/app-bundle/data/labels.json').then((r) => (r.ok ? r.json() : null)).then((j) => {
      if (!j?.anchors) return;
      phoneAnchors = j.anchors;
      const z0 = map.getZoom();
      labels.setItems(j.anchors.map((l) => ({ key: l.t, lat: l.lat, lon: l.lon, html: esc(l.t), cls: `lbl-${l.c}`, p: l.p, minZoom: z0 + (l.p - 1) * 0.75 - 0.01 })));
    }).catch(() => {});
    phoneMap = map;
    fitPhoneMap();
    return map;
  }

  function renderPhone(withHeat) {
    const me = selected && current.get(selected);
    renderMath();
    if (!me) { $('phone').hidden = true; return; }
    $('phone').hidden = false;
    $('ph-time').textContent = data.numericTime
      ? formatTime(now, true).split(', ')[1]
      : new Date(now).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    if (ph.for !== me.id) { ph.for = me.id; ph.openKey = null; ph.seen = new Set(); ph.sheet = null; }
    const st = phoneState(me);
    phoneNotice(me, st);
    const d = phoneData(me, st);
    // Lisa's tissue alert: a tissue pops out of the tab-bar box for a new alert on Today (tissue-alert.js).
    tissueAlert ??= mountTissueAlert(document.querySelector('#phone .phone-frame'));
    const taLevel = d.status !== 'none' ? 'none' : d.level === 'close' ? 'close' : d.level === 'nearby' ? 'nearby' : 'none';
    const taAdvice = taLevel === 'none' ? null : PV.ADVICE[taLevel];
    tissueAlert.update({ level: taLevel, visible: phoneTab === 'today', msg: taAdvice && {
      kicker: taLevel === 'close' ? 'Close contact' : 'Heads-up',
      title: PV.esc(taAdvice.title), lines: taAdvice.body.map(PV.esc) } });
    if (phoneTab === 'today') setHtml($('ph-today'), 'today', PV.todayHtml(d));
    else if (phoneTab === 'me') setHtml($('ph-you'), 'you', PV.youHtml(d));
    renderSheet(d);
    const where = me.walking ? 'walking' : me.building;
    $('ph-truth').textContent = `${me.id}${me.sick === null ? '' : me.sick ? ' is infected' : ' is healthy'}${where ? ` · ${where}` : ''} · campus model ${liveText(me.p)} (everyone's contacts and reports)`;

    if (!phoneMap && phoneTab === 'map') {
      phoneMap = buildPhoneMap();
      withHeat = true;
    }
    if (phoneMap && withHeat && phoneBuildings) updateUserLayer(phoneBuildings);
    const h = Number($('horizon').value);
    if (phoneMap) {
      const clock = (ms) => (data.numericTime ? formatTime(ms, true).split(', ')[1] : new Date(ms).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP])M$/i, (_, c) => ` ${c.toLowerCase()}m`));
      $('ph-ctime').innerHTML = h ? `<b>In 1 hour</b> · around ${clock(now + h * 60000)}` : `<b>Now</b> · updated ${clock(now)}`;
      $('ph-ramp').style.background = rampCss();
  for (const x of document.querySelectorAll('#ph-hseg button')) x.setAttribute('aria-pressed', String(Number(x.dataset.h) === (h ? 60 : 0)));
    }
  }

  // ---- Room-level demo: hover or click a building for the numbers behind its heat ----
  // Computed on demand (when the pointer enters a building, then twice a second), never every frame.
  const hitShapes = (outlines ? outlines.features : []).map((f) => {
    const rings = f.geometry.type === 'Polygon' ? [f.geometry.coordinates[0]] : f.geometry.coordinates.map((p) => p[0]);
    const xs = rings.flat().map((c) => c[0]), ys = rings.flat().map((c) => c[1]);
    return { id: 'bld_' + String(f.properties.id).split('/')[1], name: f.properties.name || '', rings,
      bb: [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)] };
  });
  const inRing = (x, y, ring) => {
    let inside = false;
    for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      const [xi, yi] = ring[i], [xj, yj] = ring[j];
      if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  };
  const buildingAt = (ll) => hitShapes.find((h) => ll.lng >= h.bb[0] && ll.lat >= h.bb[1] && ll.lng <= h.bb[2] && ll.lat <= h.bb[3]
    && h.rings.some((r) => inRing(ll.lng, ll.lat, r)));
  // Why is this person's P what it is: an active report, else their biggest contact (the model's own explain()).
  function whyText(id) {
    if (!model?.risk.explain) return '';
    const e = model.risk.explain(id, now, 1);
    const ev = [...e.evidence].reverse().find((x) => x.active);
    if (ev) return `${ev.kind === 'test' ? 'tested' : 'reported'} ${String(ev.value).replace(/_/g, ' ')}`;
    const c = e.contributions[0];
    if (c) return `${Math.max(1, Math.round(c.durationMin))} min near ${c.other}${c.distanceM != null ? ` (${c.distanceM < 10 ? c.distanceM.toFixed(1) : Math.round(c.distanceM)} m${c.indoor === false ? ', outdoors' : ''})` : ''}`;
    return 'at the baseline';
  }
  function buildingInfo(h) {
    const here = [...current.values()].filter((a) => a.buildingId === h.id && !a.walking);
    const tiers = { low: 0, elevated: 0, high: 0 };
    let expected = 0, excess = 0;
    for (const a of here) { tiers[riskTier(a.p)]++; expected += a.p; excess += Math.max(0, a.p - MODEL.prior); }
    here.sort((a, b) => b.p - a.p || (a.id < b.id ? -1 : 1));
    const top = here.filter((a) => a.p > MODEL.prior).slice(0, 3);
    const area = areaM2.get(h.id);
    return { name: h.name || here[0]?.building || 'Building', n: here.length, expected, excess, tiers, top, here, area, density: area ? (1000 * expected) / area : null };
  }
  const pct = (p) => `${Math.round(p * 100)}%`;
  function buildingCard(h, full) {
    const i = buildingInfo(h);
    const per = i.density == null ? '' : ` · ${i.density.toPrecision(2)} per 1,000 m²`;
    if (!full) return `<b>${esc(i.name)}</b><br>≈ ${fmtSick(i.expected)} expected infected${per} · ${i.n} ${i.n === 1 ? 'person' : 'people'}`;
    const tier = (k, label) => `<span style="--c:${riskColor(k === 'low' ? 0 : TIERS[k])}">${i.tiers[k]} ${label}</span>`;
    return `<div class="bld-pop"><h3>${esc(i.name)}</h3>
      <div class="row"><span>Expected infected (Σ P)</span><b>${fmtSick(i.expected)}</b></div>
      ${i.density == null ? '' : `<div class="row"><span>Per 1,000 m² (footprint ${Math.round(i.area).toLocaleString()} m²)</span><b>${i.density.toPrecision(2)}</b></div>`}
      <div class="row"><span>Above the ${Math.round(MODEL.prior * 100)}% baseline</span><b>${fmtSick(i.excess)}</b></div>
      <div class="row"><span>People here now</span><b>${i.n}</b></div>
      <div class="tiers3">${tier('low', 'Low')}${tier('elevated', 'Elevated')}${tier('high', 'High')}</div>
      ${i.top.length ? '' : '<p style="margin:6px 0 0;color:var(--ink-3)">Nobody here is above the baseline.</p>'}
      ${i.n ? `<h4>Everyone here${i.top.length ? ' · top drivers first' : ''}</h4><div class="bld-list">${i.here.map((a, k) => personRow(a, k < i.top.length)).join('')}</div>` : ''}</div>`;
  }
  // One row per person: tier chip, id, the app's estimate, the sim's truth (as the dot's dark ring), and why.
  function personRow(a, top) {
    const truth = a.sick == null ? '' : a.sick ? '<span class="truth"><i class="truth-ring"></i>infected</span>' : '<span class="truth">healthy</span>';
    return `<button class="who${top ? ' top' : ''}" data-id="${esc(a.id)}"><span class="line"><i class="chip" style="background:${riskColor(Math.min(1, a.p))}"></i>`
      + `<span class="id">${esc(a.id)}</span><b>${pct(a.p)}</b>${truth}</span><small>${esc(whyText(a.id))}</small></button>`;
  }
  let hover = null, hoverAt = 0, openBld = null, openAt = 0, rowDot = null;
  const demoPop = L.popup({ closeButton: false, autoPanPadding: [20, 80], maxWidth: 320 });
  // Hovering a row rings that person's dot on the map.
  const rowRing = L.circleMarker([0, 0], { renderer: L.svg({ pane: 'markerPane' }), interactive: false, radius: 11, weight: 3, fill: false });
  function ringRow(id) {
    rowDot = id;
    const a = id && current.get(id);
    if (!a) { rowRing.remove(); return; }
    rowRing.setLatLng([a.lat, a.lon]).setStyle({ color: getComputedStyle(document.documentElement).getPropertyValue('--ink').trim() || '#000' });
    if (!map.hasLayer(rowRing)) rowRing.addTo(map);
  }
  function setBuildingCard(h) { // keeps the list's scroll; skips the DOM when nothing changed (paused)
    const html = buildingCard(h, true);
    if (html === demoPop.getContent()) return;
    const list = demoPop.getElement()?.querySelector('.bld-list'), top = list ? list.scrollTop : 0;
    demoPop.setContent(html);
    const next = demoPop.getElement()?.querySelector('.bld-list');
    if (next) next.scrollTop = top;
    if (rowDot) ringRow(rowDot);
  }
  const hoverTip = L.tooltip({ direction: 'top', offset: [0, -6], className: 'bld-tip' });
  function refreshBuilding(realNow) {
    if (hover && realNow - hoverAt > 500) { hoverAt = realNow; hoverTip.setContent(buildingCard(hover, false)); }
    if (openBld && realNow - openAt > 1000) { openAt = realNow; setBuildingCard(openBld); }
  }
  let moveQueued = false;
  map.on('mousemove', (e) => {
    if ($('view').value !== 'demo' || moveQueued) return;
    moveQueued = true;
    requestAnimationFrame(() => {
      moveQueued = false;
      if (hoverDot) { if (hover) { map.closeTooltip(hoverTip); hover = null; } return; } // over a person: their tooltip only
      const h = buildingAt(e.latlng);
      if (!h) { if (hover) { map.closeTooltip(hoverTip); hover = null; } return; }
      if (h !== hover) { hover = h; hoverAt = performance.now(); hoverTip.setContent(buildingCard(h, false)); }
      hoverTip.setLatLng(e.latlng); if (!map.hasLayer(hoverTip)) map.openTooltip(hoverTip);
    });
  });
  // The "expected sick in view" count follows the map as it moves (~1,000 bounds checks, once a frame),
  // on its own: never the legend's redraw or the heat's recompute.
  let viewCountQueued = false;
  map.on('move', () => {
    if (viewCountQueued) return;
    viewCountQueued = true;
    requestAnimationFrame(() => { viewCountQueued = false; updateViewCount(performance.now(), true); });
  });
  map.on('mouseout', () => { if (hover) { map.closeTooltip(hoverTip); hover = null; } });
  map.on('click', (e) => {
    if ($('view').value !== 'demo') return;
    const h = buildingAt(e.latlng);
    if (!h) { map.closePopup(demoPop); return; }
    openBld = h; openAt = performance.now();
    demoPop.setLatLng(e.latlng).setContent(buildingCard(h, true)).openOn(map);
  });
  map.on('popupclose', (e) => { if (e.popup === demoPop) { openBld = null; ringRow(null); } });
  map.getContainer().addEventListener('mouseover', (e) => {
    const b = e.target.closest?.('.bld-pop .who');
    if (b && b.dataset.id !== rowDot) ringRow(b.dataset.id);
  });
  map.getContainer().addEventListener('mouseout', (e) => {
    if (rowDot && !e.relatedTarget?.closest?.('.bld-pop .who')) ringRow(null);
  });
  map.getContainer().addEventListener('click', (e) => { // a person in the popup opens their phone
    const b = e.target.closest?.('.bld-pop .who');
    if (b) { map.closePopup(demoPop); select(b.dataset.id); }
  });
  // Legend count: Σ P(sick) of everyone in view (cheap loop, a few times a second).
  let viewCountAt = 0;
  function updateViewCount(realNow, force = false) {
    if ((!force && realNow - viewCountAt < 300) || $('view').value !== 'demo') return;
    viewCountAt = realNow;
    const el = $('view-count');
    if (!el || !map._loaded) return;
    const b = map.getBounds();
    let sum = 0;
    for (const a of current.values()) if (b.contains([a.lat, a.lon])) sum += a.p;
    el.textContent = viewCountText = `≈ ${fmtSick(sum)} expected infected`;
  }

  // Playing, a dot glides from its route to its seat (and back) instead of jumping; the heat follows the
  // dots. Scrubbing or a paused jump moves it straight there.
  const shown = new Map(), eases = new Map(); // id -> { lat, lon (drawn), tLat, tLon (target), key, frame }; id -> { lat, lon, start }
  let easeFrame = 0;
  function easeSeats(realNow) {
    if (!playing) eases.clear();
    easeFrame++;
    for (const a of current.values()) {
      const key = a.walking || !a.buildingId ? '' : `${a.buildingId}|${a.room}`, was = shown.get(a.id);
      // Glide when someone sits down, gets up, or is moved to another seat in the room (seats.js), from where
      // the dot was drawn last frame, over a short distance (not someone back from off campus).
      const jump = was && Math.hypot((a.lat - was.tLat) * 110574, (a.lon - was.tLon) * mPerDegLon(a.lat)); // target moved
      if (playing && was && was.frame === easeFrame - 1 && (was.key !== key || key) && jump > 0.5 && jump < 80) {
        eases.set(a.id, { lat: was.lat, lon: was.lon, start: realNow });
      }
      const tLat = a.lat, tLon = a.lon, e = eases.get(a.id);
      if (e) {
        const u = (realNow - e.start) / SEAT_EASE_MS;
        if (u >= 1) eases.delete(a.id);
        else { const k = u * u * (3 - 2 * u); a.lat = e.lat + k * (a.lat - e.lat); a.lon = e.lon + k * (a.lon - e.lon); }
      }
      if (was) Object.assign(was, { lat: a.lat, lon: a.lon, tLat, tLon, key, frame: easeFrame }); // reused: thousands a frame
      else shown.set(a.id, { lat: a.lat, lon: a.lon, tLat, tLon, key, frame: easeFrame });
    }
  }

  // Move every dot to its interpolated position; repaint heat every frame while it's cheap enough.
  function render(realNow) {
    const view = $('view').value;
    current = new Map();
    // The user map (and the app's embed) reads totals only: skip everyone's position (2 ms a frame at
    // 7,500 agents) unless a phone is open, which needs who is near.
    if (view !== 'public' || selected) {
      for (const [id, track] of tracks) {
        const s = !dotSample || dotSample.has(id) || id === selected ? stateNow(track, now) : stayNow(track, now);
        if (s) current.set(id, s);
      }
      seats.place(current.values());
      easeSeats(realNow);
    }
    $('time').textContent = dayTime(now, t0, data.numericTime);
    $('slider').value = (now - t0) / 60000;

    const heatDue = !zooming && (heatDirty || realNow - lastHeat >= heatInterval); // zooming: when it settles
    if (heatDue) {
      const started = performance.now();
      const shade = shading && view === 'demo';
      heatLayer.canvas.style.display = view === 'public' || view === 'airborne' || shade ? 'none' : '';
      if (outdoorLayer) outdoorLayer.canvas.style.display = view === 'public' || view === 'airborne' || view === 'airflow' || shade ? 'none' : '';
      if (shade) { if (!shadeLayer.map) shadeLayer.addTo(map); shadeLayer.update(buildingDensity(current.values(), truthMode()), shadeMax); }
      else if (shadeLayer.map) shadeLayer.remove();
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
        heatLayer.setBounds([sw, ne]);
        paint(airflowAt(now, st, truthMode()), heatLayer.grid, aeroMax);
        heatLayer.setGrid();
        if (truthMode() !== airflowTruth) { airflowTruth = truthMode(); aeroT = null; } // source changed: re-warm
      } else if (view !== 'public' && view !== 'airborne' && !shade) { // no outlines: the diffused room-level heat
        const g = heatAt(now, current.values(), truthMode(), map._loaded ? map.getBounds().pad(0.5) : null); // no view yet: all
        if (g.zoneOut) heatLayer.setZones(g, Z.zones, demoScale());
        else { heatLayer.setBounds(g.cellM === DEMO.cellM ? [sw, ne] : gridBounds(g)); paint(g, heatLayer.grid, demoScale(), { strong: true }); heatLayer.setGrid(); }
        if (outdoorLayer) {
          const o = outdoorAt(now, current.values(), truthMode(), map._loaded ? map.getBounds().pad(0.5) : null);
          outdoorLayer.setBounds(o.cellM === DEMO.cellM ? [sw, ne] : gridBounds(o));
          paint(o, outdoorLayer.grid, demoScale() * outdoorPeak(o), { soft: true });
          outdoorLayer.setGrid();
        }
      }
      lastHeat = realNow;
      heatDirty = false;
      const cost = performance.now() - started;
      heatInterval = cost <= HEAT_BUDGET_MS ? 0 : Math.min(250, cost * 3); // keep frames smooth on big runs
    }

    const showDots = $('show-dots').checked && view !== 'public';
    // People step back in "Air by room" (the rooms are the subject). Zoomed out they're already small
    // (sized on the ground, PERSON_M), so no fading is needed there.
    const look = view === 'airborne' ? '0.2' : '';
    if (dotRenderer._container && dotRenderer._container.style.opacity !== look) dotRenderer._container.style.opacity = look;
    const mode = $('dot-mode').value;
    const seeThrough = view === 'demo' && map.getZoom() >= SEE_THROUGH_ZOOM;
    for (const [id, m] of dots) if (!showDots || !current.has(id) || (dotSample && !dotSample.has(id) && id !== selected)) dotLayer.removeLayer(m);
    if (showDots) {
      for (const a of current.values()) {
        if (dotSample && !dotSample.has(a.id) && a.id !== selected) continue;
        const m = dotFor(a.id);
        // Only touch dots that changed: each update makes Leaflet repaint the canvas around that dot.
        const ll = m.getLatLng(), fill = dotColor(a, mode);
        if (ll.lat !== a.lat || ll.lng !== a.lon) m.setLatLng([a.lat, a.lon]);
        if (m.options.fillColor !== fill) m.setStyle({ fillColor: fill });
        const infected = mode !== 'truth' && Boolean(a.sick), ring = infected ? TRUTH_RING : COLORS.ring, w = ringWeight(m.getRadius(), infected);
        if (m.options.color !== ring || m.options.weight !== w) m.setStyle({ color: ring, weight: w });
        // Close up in the room-level view, see-through so the room's colour shows (not the selected or hovered person).
        const look = seeThrough && a.id !== selected && a.id !== hoverDot ? SEE_THROUGH : 1;
        if (m.options.fillOpacity !== look) m.setStyle({ fillOpacity: look, opacity: look === 1 ? 1 : 0.6 });
        if (!dotLayer.hasLayer(m)) dotLayer.addLayer(m);
      }
    }
    renderPhone(heatDue);
    refreshBuilding(realNow);
    updateViewCount(realNow);
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
    setPhoneTab(phoneTab);
  }

  // The app's slim legend for "What users see": a gradient strip, with the counting rules behind (i).
  function userLegend() {
    let el = $('ulegend');
    if (el) return el;
    el = Object.assign(document.createElement('section'), { id: 'ulegend', hidden: true, ariaLabel: 'Legend' });
    el.innerHTML = `<div class="strip"><span>Fewer</span><div class="ramp" role="img" aria-label="Fewer to more expected sick people per building"></div><span>More sick</span>
      <button type="button" class="info" aria-expanded="false" aria-label="About this map">i</button></div>
      <div class="more" hidden><div class="scale"><span>0</span><span class="mid"></span><span class="max"></span></div><p class="fine"></p></div>`;
    el.querySelector('.ramp').style.background = rampCss();
    el.querySelector('.info').addEventListener('click', (e) => {
      const more = el.querySelector('.more');
      more.hidden = !more.hidden;
      e.currentTarget.setAttribute('aria-expanded', String(!more.hidden));
      publicLayer?.labels?.schedule();
    });
    document.querySelector('main').append(el);
    return el;
  }

  function renderLegend() {
    const v = $('view').value;
    map.getContainer().classList.toggle('muted-base', v === 'public'); // heat is the strongest colour on screen
    $('ramp').style.background = `linear-gradient(to right, ${HEAT_STOPS.map(([t, c]) => `rgba(${c[0]},${c[1]},${c[2]},${Math.max(c[3], 40) / 255}) ${t * 100}%`).join(', ')})`;
    // Colour scale is √, so the midpoint is a quarter of the maximum.
    const unit = v === 'public' || zoneHeat ? 1 : 1000; // sick people per building / P above baseline at a person; else per 1,000 m²
    const top = v === 'public' ? vmax.public : demoScale();
    const num = (x) => (x >= 1 ? x.toFixed(1) : x.toPrecision(2)); // a building's count can be a fraction of a person
    $('vmid').textContent = v === 'airflow' ? '' : num(top * unit / 4);
    $('vmax').textContent = v === 'airflow' ? 'strongest so far' : `${num(top * unit)}+`;
    const shade = shading && v === 'demo';
    if (shade) { // linear: darkness proportional to the building's expected infected per 1,000 m²
      $('vmid').textContent = num(shadeMax / 2);
      $('vmax').textContent = `${num(shadeMax)}+`;
    }
    if (v === 'airborne') {
      $('vmid').textContent = roomAir ? (roomAir.vmax / 4).toPrecision(2) : '';
      $('vmax').textContent = roomAir ? `${roomAir.vmax.toPrecision(2)}+` : 'loading…';
    }
    document.querySelector('.legend h2').innerHTML = shade
      ? `<span id="view-count"></span> people in view <span>Shade: ${truthMode() ? 'people actually infected (simulation truth)' : 'expected infected people (Σ P of everyone inside)'} per 1,000 m² of the building's footprint</span>`
      : v === 'airborne'
      ? 'Infectious air by room <span>quanta per m³, from the simulation</span>'
      : v === 'airflow'
      ? `Infectious air <span>relative, experimental${truthMode() ? ' (sim truth)' : ''}</span>`
      : v === 'public'
      ? `Expected sick people <span>per building${scale > 1 ? ` (each sim agent = ${scale})` : ''}</span>`
      : truthMode() ? `Infectiousness <span>${zoneHeat ? 'at each person, fading through the building' : 'per 1,000 m²'}, from the simulation (truth)</span>`
      : zoneHeat ? `<span id="view-count"></span> people in view <span>Colour: chance of being sick above the ${Math.round(MODEL.prior * 100)}% baseline at each person, fading through the building; people add up</span>`
      : `<span id="view-count"></span> people in view <span>Colour: expected infected above the ${Math.round(MODEL.prior * 100)}% baseline, per 1,000 m²</span>`;
    if ($('view-count')) $('view-count').textContent = viewCountText;
    const showDots = $('show-dots').checked && v !== 'public';
    const key = (color, label) => `<div class="key"><span class="swatch" style="background:${color}"></span>${label}</div>`;
    $('dot-legend').innerHTML = !showDots ? '' : $('dot-mode').value === 'truth'
      ? key(COLORS.healthy, 'Healthy (sim truth)') + key(COLORS.infected, 'Infected (sim truth)')
      : `<div class="key">App's estimate of P(sick)${data.beliefFrom === 'column' ? '' : data.beliefFrom === 'reports' ? ' (placeholder: from self-reports and tests)' : ' (placeholder: true status)'}:</div><div class="tiers"><span style="--c:${riskColor(0)}">Low<small>&lt;${TIERS.elevated * 100}%</small></span><span style="--c:${riskColor(TIERS.elevated)}">Elevated<small>${TIERS.elevated * 100}–${TIERS.high * 100}%</small></span><span style="--c:${riskColor(TIERS.high)}">High<small>${TIERS.high * 100}%+</small></span></div>${data.hasTruth ? `<div class="key truth-key"><span class="truth-ring"></span>Dark ring: actually infected (simulation truth)</div>` : ''}`;
    const isPublic = v === 'public';
    const ul = userLegend();
    ul.hidden = !isPublic;
    document.querySelector('.legend').hidden = isPublic;
    ul.querySelector('.mid').textContent = (vmax.public / 4).toFixed(1);
    ul.querySelector('.max').textContent = `${vmax.public.toFixed(1)}+`;
    ul.querySelector('.fine').textContent = `Buildings with fewer than ${MIN_PEOPLE} people are hidden${scale > 1 ? `; each counted person stands for ${scale}` : ''}. May be incomplete because not everyone shares their status.`
      + (Number.isFinite(backtestRate) ? ` Forecasts landed in their range ${Math.round(backtestRate * 100)}% of the time when tested on past days.` : '');
    try { updateViewCount(performance.now(), true); } catch { /* the legend is drawn before the map exists */ }
    $('dot-mode').disabled = !data.hasTruth || isPublic;
    $('show-dots').disabled = isPublic; // the user map never shows people
    // Forecasts are a user-map feature. Hidden but keeping its slot, so the header doesn't shift between views.
    $('horizon').style.visibility = isPublic ? '' : 'hidden';
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
  // Experimental airflow heat (aerosol.js), only with ?view=airflow. ("Air by room" was dropped by the product owner.)
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
  if ([...$('view').options].some((o) => o.value === params.get('view'))) $('view').value = params.get('view'); // (an old ?view=catch: the default)
  if (params.get('horizon')) horizon.value = params.get('horizon');
  if (params.get('color')) $('dot-mode').value = params.get('color'); // ?color=truth: heat + dots from sim truth
  const mapNote =
    `Buildings with fewer than ${MIN_PEOPLE} people are hidden${scale > 1 ? `; each simulated person stands for ${scale}` : ''}. May be incomplete because not everyone shares their status.`
    + (Number.isFinite(backtestRate) ? ` Forecasts landed in their range ${Math.round(backtestRate * 100)}% of the time when tested on past days.` : '');
  if (EMBED) {
    // User map only, slowest speed, playing; the time and forecast picker float over the map.
    $('view').value = 'public';
    $('speed').value = '0';
    const chip = Object.assign(document.createElement('div'), { className: 'embed-chip' });
    chip.append($('time'), horizon);
    document.querySelector('main').append(chip);
    document.querySelector('.legend .fine').textContent = mapNote;
    setPlaying(true);
  }

  for (const id of ['view', 'show-dots', 'dot-mode', 'horizon']) {
    $(id).addEventListener('change', () => { renderLegend(); heatDirty = true; render(performance.now()); });
  }
  if (model?.risk.explain) {
    const why = Object.assign(document.createElement('button'), { textContent: 'Why this %?' });
    why.style.whiteSpace = 'nowrap';
    $('ph-close').before(why);
    why.addEventListener('click', () => { mathOpen = !mathOpen; mathKey = ''; renderMath(); });
  }
  // Short windows: the phone scrolls inside its frame instead of running off the bottom.
  // The phone is a fixed 393 x 852 pt screen; only scaled down (never reflowed) to fit short windows.
  function fitPhone() {
    const room = (document.querySelector('main').clientHeight || innerHeight) - 24;
    const sc = Math.min(1, room / ($('phone').offsetHeight || 960));
    $('phone').style.transform = sc < 1 ? `scale(${sc})` : '';
    mathBox.style.right = `${16 + 417 * sc + 12}px`;
  }
  addEventListener('resize', fitPhone);
  new ResizeObserver(fitPhone).observe($('phone'));
  for (const b of document.querySelectorAll('.tabbar button')) b.addEventListener('click', () => setPhoneTab(b.dataset.tab));
  for (const x of document.querySelectorAll('#ph-hseg button')) x.addEventListener('click', () => { $('horizon').value = x.dataset.h; $('horizon').dispatchEvent(new Event('change')); });
  $('ph-close').addEventListener('click', () => { selected = null; renderPhone(); });
  initNightMode($('phone'), $('ph-night')); // Lisa's night palette and drawings for the phone
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { selected = null; renderPhone(); } });

  progress('Almost there…', 0.95);
  $('status').hidden = true;
  renderLegend();
  render(performance.now());
  requestAnimationFrame(tick);
  const agentParam = new URLSearchParams(location.search).get('agent'); // ?agent=a018 opens that phone
  if (agentParam) select(agentParam);
  if (PARAMS.get('why') && model?.risk.explain) { mathOpen = true; renderMath(); } // ?why=1 opens the explanation
  initPresenterUI({
    map, L, t0, t1, numericTime: data.numericTime,
    getNow: () => now, seek: (t) => { now = t; heatDirty = true; render(performance.now()); },
    isPlaying: () => playing, select, selected: () => selected, current: () => current,
    steps: totals.steps.map((st, i) => ({ t: totals.times[i], expected: [...st.buildings.values()].reduce((a, b) => a + b.expected, 0) })),
    peakBuilding() { // the building-moment with the most expected sick above baseline
      let best = null;
      totals.steps.forEach((st, i) => { for (const [id, b] of st.buildings) { const v = b.excess ?? b.expected; if (b.n >= MIN_PEOPLE && (!best || v > best.v)) best = { v, id, name: b.name, tMs: totals.times[i], expected: b.expected }; } });
      return best;
    },
    buildingCenter: (id) => { const h = hitShapes.find((x) => x.id === id); return h && [(h.bb[1] + h.bb[3]) / 2, (h.bb[0] + h.bb[2]) / 2]; },
    async firstReport() {
      const base = new URL(dataUrl, location.href);
      const cfg = await fetch(new URL('config.json', base)).then((r) => r.json());
      const { data: rows } = await loadCsv(new URL('reports_tests.csv', base), ['t', 'agent_id', 'event', 'value']);
      const r = rows.filter((x) => /might_be_sick|tested_positive|positive/.test(x.value)).sort((a, b) => a.t - b.t)[0];
      return r && { tMs: Date.parse(cfg.start) + Number(r.t) * cfg.step_min * 60000, id: r.agent_id };
    },
    closeContact: model && exposureLog.size ? firstCloseContact : null,
  });
  window.fluni = {
    data, map, vmax, totals, forecaster, model, select, seek: (t) => { now = t; heatDirty = true; render(performance.now()); },
    publicLayer, now: () => now, current: () => current, phoneScore: (id, t = now) => (model ? Math.max(phoneEstimate(id, t), statusFloor(id, t)) : null), heatField: () => ($('view').value === 'airflow' ? aero : lastField), // for tools/bench.mjs
  };
}

main().catch((err) => {
  console.error(err);
  $('status').textContent = `Couldn't load the sim run (${err.message}). Serve the repo root, not heatmap/: `
    + 'cd fluni && python3 heatmap/tools/serve.py, then open http://localhost:8000/heatmap/';
});
