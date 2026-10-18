// The user map for the FlUni app. Reads ONLY precomputed per-building totals (data/totals.json[.gz]):
// no agent timeline, contacts or model, so nothing finer than a building can be drawn. Works offline
// from file:// or a custom URL scheme: relative URLs only, no tile servers, no http(s) requests.
//
//   ?clock=live (default)   map the device's local weekday + time of day onto the run (docs/building-heat-format.md)
//   ?at=<minutes>           show that many minutes after the run's start instead (for screenshots)
//   ?horizon=60             start on the "In 1 hour" forecast
import { HEAT_STOPS } from './heat.js';

const P = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
const DAY = 86400000;
const MAX_FILL = 0.75, FORECAST_FILL = 0.5, INK = '#33241c';

async function fetchTotals() {
  if (typeof DecompressionStream === 'function') {
    try {
      const r = await fetch('data/totals.json.gz');
      if (r.ok) return await new Response(r.body.pipeThrough(new DecompressionStream('gzip'))).json();
    } catch { /* fall through to the plain copy */ }
  }
  const r = await fetch('data/totals.json');
  if (!r.ok) throw new Error('no totals');
  return r.json();
}

// ---------- which moment is "now" (docs/building-heat-format.md, "Which moment is 'now'") ----------

function makeClock(totals) {
  const { startMs, stepMs, nSteps } = totals;
  const runDays = Math.max(1, Math.ceil((nSteps * stepMs) / DAY - 1e-9));
  const day0 = new Date(startMs); day0.setHours(0, 0, 0, 0);
  const runDay = (d) => new Date(day0.getFullYear(), day0.getMonth(), day0.getDate() + d);
  const endMs = startMs + (nSteps - 1) * stepMs;
  const clamp = (t) => Math.min(endMs, Math.max(startMs, t));
  // Run time (ms) that corresponds to the device's wall-clock moment `d`.
  return function runTime(d) {
    const at = Number(P.get('at'));
    if (P.get('at') !== null && Number.isFinite(at)) return clamp(startMs + at * 60000);
    let k = -1;
    for (let i = 0; i < runDays; i++) if (runDay(i).getDay() === d.getDay()) { k = i; break; }
    if (k < 0) k = ((d.getDay() + 6) % 7) % runDays; // daysSinceMonday mod runDays
    const base = runDay(k);
    return clamp(new Date(base.getFullYear(), base.getMonth(), base.getDate(), d.getHours(), d.getMinutes(), d.getSeconds()).getTime());
  };
}

// ---------- colour (same scale as the presenter page's "What users see") ----------

function heatColor(t) {
  let j = 1;
  while (j < HEAT_STOPS.length - 1 && HEAT_STOPS[j][0] < t) j++;
  const [t0, c0] = HEAT_STOPS[j - 1], [t1, c1] = HEAT_STOPS[j];
  const f = Math.min(1, Math.max(0, (t - t0) / (t1 - t0)));
  const c = c0.map((v, i) => v + f * (c1[i] - v));
  return { color: `rgb(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])})`, alpha: c[3] / 255 };
}
const fmt = (x) => (x >= 10 ? String(Math.round(x)) : String(Math.round(x * 10) / 10));
const clock12 = (d) => d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP])M$/i, (_, c) => ` ${c.toLowerCase()}m`);

async function main() {
  const getJson = (u) => fetch(u).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  const [totals, geo, bounds, ctx, paths, labels] = await Promise.all([
    fetchTotals(),
    fetch('data/buildings.geojson').then((r) => r.json()),
    getJson('assets/trace/campus_trace_bounds.json'),
    getJson('data/context.geojson'), getJson('data/paths.geojson'), getJson('data/labels.json'),
  ]);
  const { stepMs, startMs, minPeople, scale } = totals;
  const names = totals.buildings.map((b) => b.name || '');
  const ids = new Map(totals.buildings.map((b, i) => [b.id, i]));
  const runTime = makeClock(totals);

  // colour max: 90th percentile of each step's busiest building
  const peaks = totals.steps.map((s) => s.reduce((m, r) => Math.max(m, r[2]), 0)).sort((a, b) => a - b);
  const vmax = peaks[Math.floor(0.9 * (peaks.length - 1))] || 1;

  // ---- legend ----
  $('ramp').style.background = `linear-gradient(to right, ${HEAT_STOPS.map(([t, c]) => `rgba(${c[0]},${c[1]},${c[2]},${Math.max(c[3], 40) / 255}) ${t * 100}%`).join(', ')})`;
  $('vmid').textContent = (vmax / 4).toFixed(1);
  $('vmax').textContent = `${vmax.toFixed(1)}+`;
  $('fine').textContent = `Buildings with fewer than ${minPeople} people are hidden${scale > 1 ? `; each counted person stands for ${scale}` : ''}. May be incomplete because not everyone shares their status.`;

  // ---- map ----
  // Bounded to the campus extent + 250 m. Beyond that the user never goes, but a few roads, the Shopping
  // Center and downtown are drawn faintly in the margin (data/context.geojson, from OSM).
  const map = L.map('map', { zoomControl: false, attributionControl: false, zoomSnap: 0.25, zoomDelta: 0.5, maxZoom: 19,
    preferCanvas: true, maxBoundsViscosity: 1.0, worldCopyJump: false, inertia: true });
  const pane = (name, z, events) => { const p = map.createPane(name); p.style.zIndex = z; if (!events) p.style.pointerEvents = 'none'; return { pane: name, renderer: L.canvas({ pane: name }) }; };
  const PCTX = pane('ctx', 410), PPATH = pane('paths', 415), PNEU = pane('neutral', 420), PHEAT = pane('heat', 430, true), PVIG = pane('vig', 440);
  const lblPane = map.createPane('labels'); lblPane.style.zIndex = 450; lblPane.style.pointerEvents = 'none';
  const NEUTRAL = { stroke: true, color: INK, weight: 0.8, opacity: 0.32, fill: true, fillColor: '#faf4e8', fillOpacity: 1 };
  const CTX = {
    green: { stroke: false, fill: true, fillColor: '#c3cf9c', fillOpacity: 0.5 },
    water: { stroke: false, fill: true, fillColor: '#adc9cc', fillOpacity: 0.7 },
    road: { color: INK, weight: 1.4, opacity: 0.3, fill: false },
    street: { color: INK, weight: 0.7, opacity: 0.16, fill: false },
    rail: { color: INK, weight: 1.2, opacity: 0.3, dashArray: '5 4', fill: false },
    town: { color: INK, weight: 0.7, opacity: 0.22, fill: false },
    shopping: { color: INK, weight: 0.8, opacity: 0.3, fill: true, fillColor: INK, fillOpacity: 0.05 },
    hospital: { color: INK, weight: 0.8, opacity: 0.3, fill: false },
  };
  const B = bounds || { south: 37.417142, west: -122.183335, north: 37.437912, east: -122.156460 };
  const campus = L.latLngBounds([B.south, B.west], [B.north, B.east]);
  if (ctx) for (const k of ['green', 'water', 'street', 'road', 'rail', 'town', 'shopping', 'hospital']) { // fills first, lines on top
    L.geoJSON({ type: 'FeatureCollection', features: ctx.features.filter((f) => f.properties.k === k) },
      { style: () => CTX[k], interactive: false, ...PCTX }).addTo(map);
  }
  if (paths) L.geoJSON(paths, { style: () => ({ color: INK, weight: 0.8, opacity: 0.2, fill: false }), interactive: false, ...PPATH }).addTo(map);
  L.geoJSON(geo, { style: () => NEUTRAL, interactive: false, ...PNEU }).addTo(map);

  const items = [];
  for (const f of geo.features) {
    const idx = ids.get(f.properties.id);
    if (idx === undefined) continue;
    const layer = L.geoJSON(f, { style: () => ({ stroke: false, fill: false }), ...PHEAT });
    layer.on('click', (e) => { L.DomEvent.stopPropagation(e); popup(idx, e.latlng); });
    items.push({ idx, layer, key: '' });
    layer.addTo(map);
  }

  // anchor labels, thinned by priority, zoom and collision with each other, the legend and the top chip
  const lbls = (labels || []).map((l) => {
    const m = L.marker([l.lat, l.lon], { interactive: false, keyboard: false, pane: 'labels',
      icon: L.divIcon({ className: `lbl lbl-${l.c}`, html: `<span>${l.t}</span>`, iconSize: null }) }).addTo(map);
    return { ...l, m, w: 0, h: 0 };
  });
  const rectOf = (el) => el.getBoundingClientRect();
  function placeLabels() {
    const mapBox = rectOf($('map')), avoid = [rectOf(document.querySelector('.legend')), rectOf(document.querySelector('.chip'))];
    const mb = map.options.maxBounds, z = map.getZoom(), z0 = map.getMinZoom();
    const placed = [];
    for (const l of lbls.slice().sort((a, b) => a.p - b.p)) {
      const el = l.m.getElement();
      if (!el) continue;
      const span = el.firstChild;
      if (!l.w) { l.w = span.offsetWidth + 6; l.h = span.offsetHeight + 4; }
      const pt = map.latLngToContainerPoint([l.lat, l.lon]);
      const r = { l: mapBox.left + pt.x - l.w / 2, t: mapBox.top + pt.y - l.h / 2, r: mapBox.left + pt.x + l.w / 2, b: mapBox.top + pt.y + l.h / 2 };
      const hit = (o) => r.l < o.right && r.r > o.left && r.t < o.bottom && r.b > o.top;
      const ok = z >= z0 + (l.p - 1) * 0.75 && (!mb || mb.contains([l.lat, l.lon]))
        && r.l >= mapBox.left + 4 && r.r <= mapBox.right - 4 && r.t >= mapBox.top && r.b <= mapBox.bottom
        && !avoid.some(hit) && !placed.some((o) => hit({ left: o.l, right: o.r, top: o.t, bottom: o.b }));
      el.style.visibility = ok ? 'visible' : 'hidden';
      if (ok) placed.push(r);
    }
  }

  // the bounded view: on load the whole campus fits between the top chip and the legend; that zoom is
  // also the furthest out the user can go, and the pan limit is campus + 250 m (grown only as much as the
  // screen needs to stay filled, never leaving a void)
  const vig = L.layerGroup().addTo(map);
  const pad = (b, dLat, dLon) => L.latLngBounds([b.getSouth() - dLat, b.getWest() - dLon], [b.getNorth() + dLat, b.getEast() + dLon]);
  const padded = pad(campus, 0.00225, 0.0028);
  let shiftY = 0;
  // Pan limit at the current zoom: campus + 250 m, grown only where the screen itself is bigger (zoomed all
  // the way out on a tall phone), so zoomed in the user can never reach the margin.
  function limits() {
    const z = map.getZoom(), size = map.getSize();
    const c = map.project(campus.getCenter(), z).add([0, shiftY]);
    const box = L.bounds(map.project(padded.getSouthWest(), z), map.project(padded.getNorthEast(), z))
      .extend(c.subtract(size.divideBy(2).add([1, 1]))).extend(c.add(size.divideBy(2).add([1, 1])));
    map.setMaxBounds(L.latLngBounds(map.unproject(box.min, z), map.unproject(box.max, z)));
    vignette();
  }
  function vignette() { // soft paper vignette over the last ~250 m before the edge
    const mb = map.options.maxBounds;
    vig.clearLayers();
    const ring = (b) => [b.getNorthWest(), b.getNorthEast(), b.getSouthEast(), b.getSouthWest()];
    for (const m of [30, 70, 120, 190]) {
      const d = m * 0.000009, h = pad(mb, -d, -d * 1.26);
      L.polygon([ring(mb), ring(h)], { stroke: false, fillColor: '#faf4e8', fillOpacity: 0.16, interactive: false, ...PVIG }).addTo(vig);
    }
  }
  function frame() {
    const size = map.getSize(), top = 56, bottom = Math.round(size.y * 0.2);
    const z = map.getBoundsZoom(campus, false, L.point(16, top + bottom));
    shiftY = (bottom - top) / 2;
    map.setMinZoom(z);
    map.setMaxBounds(null);
    map.setView(map.unproject(map.project(campus.getCenter(), z).add([0, shiftY]), z), z, { animate: false });
    limits();
    placeLabels();
  }
  frame();
  if (P.get('debug') !== null) window.__map = map; // for the bounds test
  map.on('zoomend', () => { limits(); map.panInsideBounds(map.options.maxBounds, { animate: false }); });
  map.on('moveend zoomend', placeLabels);
  let rt; window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { map.invalidateSize(); frame(); }, 150); });

  // ---- state ----
  let step = -1, horizon = Number(P.get('horizon')) > 0 ? 60 : 0, cur = new Map(), shown = new Map(), openIdx = -1;
  const hasForecast = totals.forecast && totals.forecast.at.length && totals.forecast.horizons.includes(60);
  if (!hasForecast) horizon = 0;
  $('horizon').hidden = !hasForecast;

  function snapshot() {
    const t = runTime(new Date());
    const s = Math.min(totals.nSteps - 1, Math.max(0, Math.floor((t - startMs) / stepMs)));
    return { s, t: startMs + s * stepMs };
  }

  function forecastAt(t) {
    const at = totals.forecast.at;
    let lo = 0, hi = at.length - 1, r = 0;
    while (lo <= hi) { const m = (lo + hi) >> 1; if (at[m].tMs <= t) { r = m; lo = m + 1; } else hi = m - 1; }
    return new Map((at[r].byHorizon['60'] || []).map((x) => [x[0], x[1]]));
  }

  function styleFor(n, sick, forecast) {
    if (n < minPeople) return { stroke: false, fill: false };
    const { color, alpha } = heatColor(Math.sqrt(Math.min(1, sick / vmax)));
    const op = alpha * MAX_FILL * (forecast ? FORECAST_FILL : 1);
    return { stroke: true, weight: 1.5, color: INK, opacity: 0.6, dashArray: forecast ? '4 3' : null, fill: true, fillColor: color, fillOpacity: op };
  }

  function render(force) {
    const { s, t } = snapshot();
    if (!force && s === step) return;
    step = s;
    const now = new Map(totals.steps[s].map((r) => [r[0], r]));
    const fc = horizon ? forecastAt(t) : null;
    shown = new Map();
    for (const it of items) {
      const r = now.get(it.idx);
      const style = r ? styleFor(r[1], fc ? fc.get(it.idx) || 0 : r[2], !!fc) : styleFor(0, 0, false);
      const key = JSON.stringify(style);
      if (key !== it.key) { it.layer.setStyle(style); it.key = key; }
      if (r && r[1] >= minPeople) shown.set(it.idx, { people: r[1], sick: fc ? fc.get(it.idx) || 0 : r[2] });
    }
    // "Now · updated 4:30 pm": the snapshot's time of day, today
    const d = new Date(), snap = new Date(startMs + s * stepMs);
    d.setHours(snap.getHours(), snap.getMinutes(), 0, 0);
    $('time').innerHTML = horizon
      ? `<b>In 1 hour</b> · around ${clock12(new Date(d.getTime() + 3600000))}`
      : `<b>Now</b> · updated ${clock12(d)}`;
    if (openIdx >= 0) { if (shown.has(openIdx)) setPopupText(); else map.closePopup(); }
  }

  const pop = L.popup({ closeButton: false, autoPanPadding: [20, 80] });
  function setPopupText() {
    const d = shown.get(openIdx);
    const name = names[openIdx] || 'Building';
    pop.setContent(horizon
      ? `<b>${esc(name)}</b>: about ${fmt(d.sick)} sick expected in 1 hour`
      : `<b>${esc(name)}</b>: about ${fmt(d.sick)} sick of ${fmt(d.people)} people`);
  }
  function popup(idx, latlng) {
    if (!shown.has(idx)) return; // hidden buildings show nothing
    openIdx = idx;
    setPopupText();
    pop.setLatLng(latlng).openOn(map);
  }
  const esc = (x) => x.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  map.on('popupclose', () => { openIdx = -1; });

  for (const b of $('horizon').querySelectorAll('button')) {
    b.setAttribute('aria-pressed', String(Number(b.dataset.h) === horizon));
    b.addEventListener('click', () => {
      horizon = Number(b.dataset.h);
      for (const o of $('horizon').querySelectorAll('button')) o.setAttribute('aria-pressed', String(o === b));
      render(true);
    });
  }

  render(true);
  $('status').hidden = true;
  if (P.get('at') === null) {
    setInterval(() => render(false), 1000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) render(false); });
  }
}

main().catch((err) => {
  console.error(err);
  $('status').textContent = "Couldn't load the map.";
});
