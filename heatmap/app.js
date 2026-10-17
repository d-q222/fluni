import { HeatGrid, paint, HEAT_STOPS } from './heat.js';

// Room-level heat for the presenter; coarse, privacy-masked heat for what real users see.
const DEMO = { cellM: 3, sigmaM: 18 };
const PUBLIC = { cellM: 8, sigmaM: 35, minPeople: 5 };
const RISKY = 0.5;          // P(sick) at which the app treats someone as risky for proximity alerts
const NEARBY_M = 3;         // ~10 ft; the PRD's "within N feet" (N still to be decided)
const PAD_M = 120;          // grid margin around the data
const DATA_URL = new URLSearchParams(location.search).get('data') || 'data/fake_agents.csv';

const TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const ATTRIBUTION = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
const COLORS = { healthy: '#2a78d6', infected: '#d03b3b', ring: '#fcfcfb', riskLo: [134, 182, 239], riskHi: [13, 54, 107] };

// ---------- CSV adapter: the only place that knows column names ----------

const COLUMNS = {
  t: ['t', 'time', 'timestamp'],
  id: ['agent_id', 'id', 'agent'],
  lat: ['lat', 'latitude'],
  lon: ['lon', 'lng', 'long', 'longitude'],
  p: ['p_sick', 'p', 'prob_sick', 'risk'],
  sick: ['sick', 'infected', 'is_sick'],
  building: ['building'],
  floor: ['floor'],
  room: ['room'],
};

function toFrames(rows, fields) {
  const lower = Object.fromEntries(fields.map((f) => [f.trim().toLowerCase(), f]));
  const col = Object.fromEntries(
    Object.entries(COLUMNS).map(([k, names]) => [k, names.map((n) => lower[n]).find(Boolean)]),
  );
  for (const k of ['t', 'id', 'lat', 'lon']) {
    if (!col[k]) throw new Error(`CSV needs a "${COLUMNS[k][0]}" column (have: ${fields.join(', ')})`);
  }
  if (!col.p && !col.sick) throw new Error('CSV needs a p_sick or sick column');
  if (!col.p) console.warn('No p_sick column: using ground-truth "sick" as the probability.');

  const byTime = new Map();
  for (const r of rows) {
    const sick = col.sick ? Number(r[col.sick]) === 1 || r[col.sick] === 'true' : null;
    const a = {
      id: r[col.id], lat: Number(r[col.lat]), lon: Number(r[col.lon]),
      p: col.p ? Number(r[col.p]) : Number(sick), sick,
      building: col.building ? r[col.building] : null,
      floor: col.floor ? r[col.floor] : null,
      room: col.room ? r[col.room] : null,
    };
    if (!Number.isFinite(a.lat) || !Number.isFinite(a.lon)) continue;
    const t = r[col.t];
    if (!byTime.has(t)) byTime.set(t, []);
    byTime.get(t).push(a);
  }
  const key = (t) => (Number.isFinite(Number(t)) ? Number(t) : Date.parse(t));
  const times = [...byTime.keys()].sort((a, b) => key(a) - key(b));
  return { times, frames: times.map((t) => byTime.get(t)), hasTruth: Boolean(col.sick), hasRoom: Boolean(col.room) };
}

function loadCsv(url) {
  return new Promise((resolve, reject) =>
    Papa.parse(url, {
      download: true, header: true, skipEmptyLines: true,
      complete: (res) => resolve(res), error: reject,
    }));
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

// Fixed colour scale shared by every frame: the 90th percentile of per-frame peaks (sampled), so a
// single extreme moment doesn't wash out the rest. Anything above it shows as the darkest colour.
function globalMax(grid, frames, sigmaM) {
  const step = Math.max(1, Math.floor(frames.length / 60));
  const peaks = [];
  for (let i = 0; i < frames.length; i += step) peaks.push(grid.compute(frames[i], sigmaM).max());
  peaks.sort((a, b) => a - b);
  return peaks[Math.floor(0.9 * (peaks.length - 1))] || 1;
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

function formatTime(t) {
  const d = new Date(t);
  if (Number.isNaN(d.getTime())) return String(t);
  return d.toLocaleString(undefined, { weekday: 'short', hour: 'numeric', minute: '2-digit' });
}

const pct = (p) => `${Math.round(p * 100)}%`;
const mPerDegLon = (lat) => 111320 * Math.cos((lat * Math.PI) / 180);

// ---------- app ----------

const $ = (id) => document.getElementById(id);

async function main() {
  const res = await loadCsv(DATA_URL);
  const data = toFrames(res.data, res.meta.fields);
  const { times, frames } = data;
  const bounds = dataBounds(frames);
  const sw = [bounds.south, bounds.west], ne = [bounds.north, bounds.east];

  const demoGrid = new HeatGrid(bounds, DEMO.cellM);
  const publicGrid = new HeatGrid(bounds, PUBLIC.cellM);
  const vmax = { demo: globalMax(demoGrid, frames, DEMO.sigmaM), public: globalMax(publicGrid, frames, PUBLIC.sigmaM) };

  const map = baseMap('map', { maxBounds: L.latLngBounds(sw, ne).pad(0.5) });
  // Fit once the map actually has a size; a page opened in a background tab starts at 0×0.
  let fitted = false;
  new ResizeObserver(() => {
    map.invalidateSize();
    if (fitted || !map.getSize().x) return;
    fitted = true;
    map.fitBounds([sw, ne]);
    map.setMinZoom(map.getZoom() - 1);
  }).observe($('map'));
  const heatLayer = new CanvasLayer([sw, ne]).addTo(map);

  const dotRenderer = L.canvas({ padding: 0.5, tolerance: 6 });
  const dotLayer = L.layerGroup().addTo(map);
  const dots = new Map(); // agent id -> circle marker
  let current = new Map(); // agent id -> agent row in the current frame

  let frameIndex = 0, selected = null, timer = null;
  let phoneMap = null, phoneHeat = null, phoneYou = null;

  function dotFor(id) {
    if (dots.has(id)) return dots.get(id);
    const m = L.circleMarker([0, 0], {
      renderer: dotRenderer, radius: 5, weight: 2, color: COLORS.ring, fillOpacity: 1,
    });
    m.bindTooltip(() => {
      const a = current.get(id);
      const where = [a.building, a.room && `room ${a.room}`].filter(Boolean).join(', ');
      const truth = a.sick === null ? '' : ` · ${a.sick ? 'infected' : 'healthy'} (sim)`;
      return `<b>${id}</b>${where ? ` · ${where}` : ''}<br>App estimate ${pct(a.p)}${truth}`;
    });
    m.on('click', () => select(id));
    dots.set(id, m);
    return m;
  }

  // What this agent's phone could know: its own estimate, risky people nearby, and the public heat map.
  function riskyNearby(me) {
    for (const a of current.values()) {
      if (a.id === me.id || a.p < RISKY) continue;
      if (data.hasRoom && (a.building !== me.building || a.room !== me.room)) continue; // walls block
      const dy = (a.lat - me.lat) * 110574, dx = (a.lon - me.lon) * mPerDegLon(me.lat);
      if (Math.hypot(dx, dy) <= NEARBY_M) return true;
    }
    return false;
  }

  function renderPhone() {
    const me = selected && current.get(selected);
    if (!me) { $('phone').hidden = true; return; }
    $('phone').hidden = false;
    $('ph-time').textContent = formatTime(times[frameIndex]);
    $('ph-alert').hidden = !riskyNearby(me);
    $('ph-risk').textContent = pct(me.p);
    $('ph-advice').textContent = advice(me.p);
    $('ph-truth').textContent = `${me.id}${me.sick === null ? '' : me.sick ? ' is infected' : ' is healthy'}${me.building ? ` · ${me.building}` : ''}`;

    if (!phoneMap) {
      phoneMap = baseMap('ph-map', { zoomControl: false, attributionControl: false });
      phoneHeat = new CanvasLayer([sw, ne]).addTo(phoneMap);
      phoneYou = L.circleMarker([me.lat, me.lon], { radius: 6, weight: 3, color: '#fff', fillColor: COLORS.healthy, fillOpacity: 1 }).addTo(phoneMap);
      phoneMap.setView([me.lat, me.lon], 16);
    }
    phoneYou.setLatLng([me.lat, me.lon]);
    paint(publicGrid.compute(current.values(), PUBLIC.sigmaM), phoneHeat.canvas, vmax.public, PUBLIC);
  }

  function render() {
    const frame = frames[frameIndex];
    current = new Map(frame.map((a) => [a.id, a]));
    $('time').textContent = formatTime(times[frameIndex]);
    $('slider').value = frameIndex;

    const view = $('view').value;
    if (view === 'public') paint(publicGrid.compute(frame, PUBLIC.sigmaM), heatLayer.canvas, vmax.public, PUBLIC);
    else paint(demoGrid.compute(frame, DEMO.sigmaM), heatLayer.canvas, vmax.demo);

    const showDots = $('show-dots').checked && view === 'demo';
    const mode = $('dot-mode').value;
    for (const [id, m] of dots) if (!current.has(id)) dotLayer.removeLayer(m);
    for (const a of frame) {
      const m = dotFor(a.id);
      if (!showDots) { dotLayer.removeLayer(m); continue; }
      m.setLatLng([a.lat, a.lon]).setStyle({ fillColor: dotColor(a, mode) });
      dotLayer.addLayer(m);
    }
    renderPhone();
  }

  function select(id) {
    selected = id;
    renderPhone();
    if (phoneMap) {
      phoneMap.invalidateSize();
      const me = current.get(id);
      phoneMap.setView([me.lat, me.lon], 16);
    }
  }

  function renderLegend() {
    const v = $('view').value;
    $('ramp').style.background = `linear-gradient(to right, ${HEAT_STOPS.map(([t, c]) => `rgba(${c[0]},${c[1]},${c[2]},${Math.max(c[3], 40) / 255}) ${t * 100}%`).join(', ')})`;
    $('vmid').textContent = (vmax[v] * 250).toFixed(1); // colour scale is √, so the midpoint is vmax/4
    $('vmax').textContent = `${(vmax[v] * 1000).toFixed(1)}+`;
    const showDots = $('show-dots').checked && v === 'demo';
    const key = (color, label) => `<div class="key"><span class="swatch" style="background:${color}"></span>${label}</div>`;
    $('dot-legend').innerHTML = !showDots ? '' : $('dot-mode').value === 'truth'
      ? key(COLORS.healthy, 'Healthy (sim truth)') + key(COLORS.infected, 'Infected (sim truth)')
      : `<div class="key">App's estimate of P(sick):</div><div class="ramp" style="background:linear-gradient(to right, ${mix(COLORS.riskLo, COLORS.riskHi, 0)}, ${mix(COLORS.riskLo, COLORS.riskHi, 1)})"></div><div class="ramp-labels"><span>0%</span><span>100%</span></div>`;
    $('dot-mode').disabled = !data.hasTruth;
  }

  function setPlaying(on) {
    clearInterval(timer);
    timer = null;
    $('play').textContent = on ? '❚❚' : '▶';
    $('play').setAttribute('aria-label', on ? 'Pause' : 'Play');
    if (!on) return;
    timer = setInterval(() => {
      if (frameIndex >= frames.length - 1) return setPlaying(false);
      frameIndex++;
      render();
    }, 1000 / Number($('speed').value));
  }

  $('slider').max = frames.length - 1;
  $('slider').addEventListener('input', (e) => { frameIndex = Number(e.target.value); render(); });
  $('play').addEventListener('click', () => {
    if (!timer && frameIndex >= frames.length - 1) frameIndex = 0;
    setPlaying(!timer);
  });
  $('speed').addEventListener('change', () => timer && setPlaying(true));
  for (const id of ['view', 'show-dots', 'dot-mode']) $(id).addEventListener('change', () => { renderLegend(); render(); });
  $('ph-close').addEventListener('click', () => { selected = null; renderPhone(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { selected = null; renderPhone(); } });

  $('status').hidden = true;
  renderLegend();
  render();
  window.fluni = { data, map, vmax, select }; // console: fluni.select("a018")
}

main().catch((err) => {
  console.error(err);
  $('status').textContent = `Couldn't load ${DATA_URL}: ${err.message}`;
});
