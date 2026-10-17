import { HeatGrid, paint, HEAT_STOPS } from './heat.js';
import { Router, buildTracks, stateAt } from './motion.js';

// Room-level heat for the presenter; coarse, privacy-masked heat for what real users see.
const DEMO = { cellM: 3, sigmaM: 18 };
const PUBLIC = { cellM: 8, sigmaM: 35, minPeople: 5 };
const RISKY = 0.5;          // P(sick) at which the app treats someone as risky for proximity alerts
const NEARBY_M = 3;         // ~10 ft; the PRD's "within N feet" (N still to be decided)
const PAD_M = 120;          // grid margin around the data
const HEAT_EVERY_MS = 100;   // heat is recomputed at most this often; dots move every frame
const QUIET_GAP_MS = 2 * 3600_000; // playback skips stretches with no samples at all (e.g. overnight)
const SPEEDS = [2, 10, 30, 60];    // simulated minutes per real second
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
    a.t = toMs(t);
    if (!byTime.has(t)) byTime.set(t, []);
    byTime.get(t).push(a);
  }
  const times = [...byTime.keys()].sort((a, b) => toMs(a) - toMs(b));
  const frames = times.map((t) => byTime.get(t));
  return {
    frames, times: times.map(toMs), samples: frames.flat(), numericTime: Number.isFinite(Number(times[0])),
    hasTruth: Boolean(col.sick), hasRoom: Boolean(col.room),
  };
}

// ISO timestamps → epoch ms. Plain numbers are taken as seconds since the start of the simulation.
const toMs = (t) => (Number.isFinite(Number(t)) ? Number(t) * 1000 : Date.parse(t));

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
  const [res, paths] = await Promise.all([
    loadCsv(DATA_URL),
    fetch('data/stanford_paths.json').then((r) => r.json()).catch(() => null),
  ]);
  const data = toFrames(res.data, res.meta.fields);
  const { frames, times } = data;
  const tracks = buildTracks(data.samples);
  const router = paths ? new Router(paths) : null; // without it, agents walk in straight lines
  const bounds = dataBounds(frames);
  const sw = [bounds.south, bounds.west], ne = [bounds.north, bounds.east];
  const t0 = times[0], t1 = times[times.length - 1];

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
  let current = new Map(); // agent id -> interpolated state at the current time

  // ?at=<minutes from the start> opens at a specific moment (handy for demos and screenshots).
  const at = Number(new URLSearchParams(location.search).get('at'));
  let now = at ? Math.min(t1, t0 + at * 60000) : t0, playing = false, selected = null, lastHeat = -Infinity, heatDirty = true;
  let phoneMap = null, phoneHeat = null, phoneYou = null;

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

  // What this agent's phone could know: its own estimate, risky people nearby, and the public heat map.
  // Indoors, walls block (same room only); outdoors, distance alone.
  function riskyNearby(me) {
    for (const a of current.values()) {
      if (a.id === me.id || a.p < RISKY) continue;
      if (data.hasRoom && !me.walking && (a.building !== me.building || a.room !== me.room)) continue;
      const dy = (a.lat - me.lat) * 110574, dx = (a.lon - me.lon) * mPerDegLon(me.lat);
      if (Math.hypot(dx, dy) <= NEARBY_M) return true;
    }
    return false;
  }

  function renderPhone(withHeat) {
    const me = selected && current.get(selected);
    if (!me) { $('phone').hidden = true; return; }
    $('phone').hidden = false;
    $('ph-time').textContent = data.numericTime
      ? formatTime(now, true).split(', ')[1]
      : new Date(now).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    $('ph-alert').hidden = !riskyNearby(me);
    $('ph-risk').textContent = pct(me.p);
    $('ph-advice').textContent = advice(me.p);
    const where = me.walking ? 'walking' : me.building;
    $('ph-truth').textContent = `${me.id}${me.sick === null ? '' : me.sick ? ' is infected' : ' is healthy'}${where ? ` · ${where}` : ''}`;

    if (!phoneMap) {
      phoneMap = baseMap('ph-map', { zoomControl: false, attributionControl: false });
      phoneHeat = new CanvasLayer([sw, ne]).addTo(phoneMap);
      phoneYou = L.circleMarker([me.lat, me.lon], { radius: 6, weight: 3, color: '#fff', fillColor: COLORS.healthy, fillOpacity: 1 }).addTo(phoneMap);
      phoneMap.setView([me.lat, me.lon], 16);
      withHeat = true;
    }
    phoneYou.setLatLng([me.lat, me.lon]);
    if (withHeat) paint(publicGrid.compute(current.values(), PUBLIC.sigmaM), phoneHeat.canvas, vmax.public, PUBLIC);
  }

  // Move every dot to its interpolated position; repaint heat at most every HEAT_EVERY_MS.
  function render(realNow) {
    current = new Map();
    for (const [id, track] of tracks) {
      const s = stateAt(track, now, router);
      if (s) current.set(id, s);
    }
    $('time').textContent = formatTime(now, data.numericTime);
    $('slider').value = (now - t0) / 60000;

    const view = $('view').value;
    const heatDue = heatDirty || realNow - lastHeat >= HEAT_EVERY_MS;
    if (heatDue) {
      const pts = current.values();
      if (view === 'public') paint(publicGrid.compute(pts, PUBLIC.sigmaM), heatLayer.canvas, vmax.public, PUBLIC);
      else paint(demoGrid.compute(pts, DEMO.sigmaM), heatLayer.canvas, vmax.demo);
      lastHeat = realNow;
      heatDirty = false;
    }

    const showDots = $('show-dots').checked && view === 'demo';
    const mode = $('dot-mode').value;
    for (const [id, m] of dots) if (!showDots || !current.has(id)) dotLayer.removeLayer(m);
    if (showDots) {
      for (const a of current.values()) {
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
  for (const id of ['view', 'show-dots', 'dot-mode']) {
    $(id).addEventListener('change', () => { renderLegend(); heatDirty = true; render(performance.now()); });
  }
  $('ph-close').addEventListener('click', () => { selected = null; renderPhone(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { selected = null; renderPhone(); } });

  $('status').hidden = true;
  renderLegend();
  render(performance.now());
  requestAnimationFrame(tick);
  const agentParam = new URLSearchParams(location.search).get('agent'); // ?agent=a018 opens that phone
  if (agentParam) select(agentParam);
  window.fluni = { data, map, vmax, select, seek: (t) => { now = t; heatDirty = true; render(performance.now()); } };
}

main().catch((err) => {
  console.error(err);
  $('status').textContent = `Couldn't load ${DATA_URL}: ${err.message}`;
});
