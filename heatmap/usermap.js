// The user map for the FlUni app. Reads ONLY precomputed per-building totals (data/totals.json[.gz]):
// no agent timeline, contacts or model, so nothing finer than a building can be drawn. Works offline
// from file:// or a custom URL scheme: relative URLs only, no tile servers, no http(s) requests.
//
//   ?clock=live (default)   map the device's local weekday + time of day onto the run (docs/building-heat-format.md)
//   ?at=<minutes>           show that many minutes after the run's start instead (for screenshots)
//   ?horizon=60             start on the "In 1 hour" forecast
import { smoothZoom } from './smoothzoom.js';
import { INK, heatColor, buildingStyle, colourMax, haloRadius, GLOW, HALO_BLUR, fmt, rampCss } from './userstyle.js';

const P = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
const DAY = 86400000;

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
    if (k < 0) k = runDays - 1; // no such weekday in the run: its last day, the most developed outbreak
    const base = runDay(k);
    return clamp(new Date(base.getFullYear(), base.getMonth(), base.getDate(), d.getHours(), d.getMinutes(), d.getSeconds()).getTime());
  };
}

// ---------- colour: userstyle.js, shared with the presenter's "What users see" ----------

const esc = (x) => String(x).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const clock12 = (d) => d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP])M$/i, (_, c) => ` ${c.toLowerCase()}m`);

async function main() {
  const getJson = (u) => fetch(u).then((r) => { if (r.ok) return r.json(); console.warn(`usermap: ${u} failed: HTTP ${r.status}`); return null; }).catch((e) => { console.warn(`usermap: ${u} failed:`, e); return null; });
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

  // Colour is expected sick above the model's baseline (r[3]; older totals lack it: r[2]), so a crowd at
  // the baseline isn't drawn as risk. Colour max: 90th percentile of each step's busiest building, or
  // the busiest step when most are blank.
  const hot = (r) => r[3] ?? r[2];
  const vmax = colourMax(totals.steps.map((s) => s.reduce((m, r) => Math.max(m, hot(r)), 0)));

  // ---- legend ----
  $('ramp').style.background = rampCss();
  $('vmid').textContent = (vmax / 4).toFixed(1);
  $('vmax').textContent = `${vmax.toFixed(1)}+`;
  $('fine').textContent = `Buildings with fewer than ${minPeople} people are hidden${scale > 1 ? `; each counted person stands for ${scale}` : ''}. May be incomplete because not everyone shares their status.`;
  $('info').addEventListener('click', () => {
    const open = $('more').hidden;
    $('more').hidden = !open;
    $('info').setAttribute('aria-expanded', String(open));
    if (typeof placeLabels === 'function') placeLabels();
  });

  // ---- map ----
  // Bounded to the campus extent + 250 m. Beyond that the user never goes, but a few roads, the Shopping
  // Center and downtown are drawn faintly in the margin (data/context.geojson, from OSM).
  const map = smoothZoom(L.map('map', { zoomControl: false, attributionControl: false, zoomSnap: 0.25, zoomDelta: 0.5, maxZoom: 19,
    preferCanvas: true, worldCopyJump: false, inertia: true })); // smooth wheel / pinch zoom (smoothzoom.js)
  const pane = (name, z, events) => { const p = map.createPane(name); p.style.zIndex = z; if (!events) p.style.pointerEvents = 'none'; return { pane: name, renderer: L.canvas({ pane: name }) }; };
  const PCTX = pane('ctx', 410), PPATH = pane('paths', 415), PNEU = pane('neutral', 420), PHEAT = pane('heat', 430, true), PVIG = pane('vig', 440), PHALO = pane('halo', 425);
  map.getPane('halo').style.filter = HALO_BLUR;
  map.getPane('heat').style.filter = GLOW; // hot buildings glow so they read zoomed out
  const lblPane = map.createPane('labels'); lblPane.style.zIndex = 450; lblPane.style.pointerEvents = 'none';
  const NEUTRAL = { stroke: true, color: INK, weight: 0.7, opacity: 0.17, fill: true, fillColor: '#faf4e8', fillOpacity: 1 };
  const CTX = {
    green: { stroke: false, fill: true, fillColor: '#c3cf9c', fillOpacity: 0.5 },
    water: { stroke: false, fill: true, fillColor: '#adc9cc', fillOpacity: 0.7 },
    road: { color: INK, weight: 1.2, opacity: 0.2, fill: false },
    street: { color: INK, weight: 0.6, opacity: 0.11, fill: false },
    rail: { color: INK, weight: 1.1, opacity: 0.2, dashArray: '5 4', fill: false },
    town: { color: INK, weight: 0.6, opacity: 0.15, fill: false },
    shopping: { color: INK, weight: 0.7, opacity: 0.2, fill: true, fillColor: INK, fillOpacity: 0.05 },
    hospital: { color: INK, weight: 0.7, opacity: 0.2, fill: false },
  };
  const B = bounds || { south: 37.417142, west: -122.183335, north: 37.437912, east: -122.156460 };
  const campus = L.latLngBounds([B.south, B.west], [B.north, B.east]);
  if (ctx) for (const k of ['green', 'water', 'street', 'road', 'rail', 'town', 'shopping', 'hospital']) { // fills first, lines on top
    L.geoJSON({ type: 'FeatureCollection', features: ctx.features.filter((f) => f.properties.k === k) },
      { style: () => CTX[k], interactive: false, ...PCTX }).addTo(map);
  }
  const pathStyle = () => ({ color: INK, weight: 0.7 + Math.max(0, map.getZoom() - 15) * 0.3, opacity: 0.12, fill: false });
  let pathLayer = null;
  if (paths) pathLayer = L.geoJSON(paths, { style: () => pathStyle(), interactive: false, ...PPATH }).addTo(map);
  L.geoJSON(geo, { style: () => NEUTRAL, interactive: false, ...PNEU }).addTo(map);

  // One tap target per outline. Some sim places share their building's outline exactly (a dining hall
  // inside its dorm: footprints.js gives a hand-placed box the real building's outline), so they're one
  // shape on the map: their totals add up under the real building's name, and the hall is never hidden.
  const items = [], byShape = new Map();
  const shapeKey = (g) => JSON.stringify(g.coordinates, (k, v) => (typeof v === 'number' ? Math.round(v * 1e5) : v));
  for (const f of geo.features) {
    const idx = ids.get(f.properties.id);
    if (idx === undefined) continue;
    const k = shapeKey(f.geometry);
    const it = byShape.get(k);
    if (it) { it.idxs.push(idx); continue; }
    const layer = L.geoJSON(f, { style: () => ({ stroke: false, fill: false }), ...PHEAT });
    const item = { idxs: [idx], layer, key: '' };
    layer.on('click', (e) => { L.DomEvent.stopPropagation(e); popup(item, e.latlng); });
    byShape.set(k, item);
    items.push(item);
    layer.addTo(map);
  }
  // Name a shared shape after its busiest place over the run (Florence Moore Hall, not its dining hall;
  // Green Library, not "East Wing"), listing the rest.
  const busy = new Float64Array(totals.buildings.length);
  for (const st of totals.steps) for (const r of st) busy[r[0]] += r[1];
  for (const it of items) {
    it.idxs.sort((a, b) => busy[b] - busy[a]);
    it.name = names[it.idxs[0]] || 'Building';
    it.also = it.idxs.slice(1).map((i) => names[i]).filter((n) => n && n !== it.name);
  }

  // anchor labels, thinned by priority, zoom and collision with each other, the legend and the top chip
  const mkLabel = (l) => ({ ...l, w: 0, h: 0, m: L.marker([l.lat, l.lon], { interactive: false, keyboard: false, pane: 'labels',
    icon: L.divIcon({ className: `lbl lbl-${l.c}`, html: `<span>${esc(l.t)}</span>`, iconSize: null }) }).addTo(map) });
  const lbls = [];
  const anchors = (labels && labels.anchors) || [];
  for (const l of anchors) lbls.push(mkLabel(l));
  // every named building: a marker is only made once it scrolls into view at street zoom (z >= 16.5)
  const fine = ((labels && labels.fine) || []).map(([t, lat, lon]) => ({ t, lat, lon, p: 4, c: 'f' }));
  const rectOf = (el) => el.getBoundingClientRect();
  function placeLabels() {
    const mapBox = rectOf($('map')), z = map.getZoom(), z0 = map.getMinZoom();
    const avoid = [rectOf(document.querySelector('.legend')), rectOf(document.querySelector('.chip')),
      { left: mapBox.left, right: mapBox.right, top: mapBox.bottom - map.getSize().y * 0.09, bottom: mapBox.bottom }]; // FlUni's sheet
    if (z >= 16.5) {
      const view = map.getBounds(), have = new Set(lbls.map((l) => l.t + l.lat));
      for (const f of fine) if (view.contains([f.lat, f.lon]) && !have.has(f.t + f.lat) && !anchors.some((a) => a.t === f.t)) lbls.push(mkLabel(f));
    }
    const placed = [];
    for (const l of lbls.slice().sort((a, b) => a.p - b.p)) {
      const el = l.m.getElement();
      if (!el) continue;
      const span = el.firstChild;
      if (!l.w) { l.w = span.offsetWidth + 6; l.h = span.offsetHeight + 4; }
      const pt = map.latLngToContainerPoint([l.lat, l.lon]);
      const r = { l: mapBox.left + pt.x - l.w / 2, t: mapBox.top + pt.y - l.h / 2, r: mapBox.left + pt.x + l.w / 2, b: mapBox.top + pt.y + l.h / 2 };
      const hit = (o) => r.l < o.right && r.r > o.left && r.t < o.bottom && r.b > o.top;
      const ok = (l.p === 4 ? z >= 16.5 : z >= z0 + (l.p - 1) * 0.75)
        && r.l >= mapBox.left + 4 && r.r <= mapBox.right - 4 && r.t >= mapBox.top && r.b <= mapBox.bottom
        && !avoid.some(hit) && !placed.some((o) => hit({ left: o.l, right: o.r, top: o.t, bottom: o.b }));
      el.style.visibility = ok ? 'visible' : 'hidden';
      if (ok) placed.push(r);
    }
  }

  // the view: on load the whole campus fits between the top chip and the legend strip, that zoom is also
  // the furthest out, and panning is held to campus + 10% by Leaflet's default (soft, rubber-band) limit
  const vig = L.layerGroup().addTo(map); // (filled below)
  const pad = (b, dLat, dLon) => L.latLngBounds([b.getSouth() - dLat, b.getWest() - dLon], [b.getNorth() + dLat, b.getEast() + dLon]);
  // Everything outside the campus extent fades toward paper: six translucent masks, each with a hole that
  // starts a little further out, so the margin gets paler the further it is from campus.
  const outer = pad(campus, 0.05, 0.06);
  const ringOf = (b) => [b.getNorthWest(), b.getNorthEast(), b.getSouthEast(), b.getSouthWest()];
  for (const m of [0, 60, 130, 230, 380, 600]) {
    L.polygon([ringOf(outer), ringOf(pad(campus, m * 0.000009, m * 0.0000113))],
      { stroke: false, fillColor: '#faf4e8', fillOpacity: 0.14, interactive: false, ...PVIG }).addTo(vig);
  }
  function frame() {
    const size = map.getSize(), top = 56, bottom = Math.round(size.y * 0.09); // the slim legend strip + tab bar
    const z = map.getBoundsZoom(campus, false, L.point(16, top + bottom));
    map.setMinZoom(z - 1);
    map.setMaxBounds(campus.pad(0.6));
    map.setView(map.unproject(map.project(campus.getCenter(), z).add([0, (bottom - top) / 2]), z), z, { animate: false });
    placeLabels();
  }
  frame();
  if (P.get('debug') !== null) window.__map = map; // for the bounds test
  map.on('zoomend', () => { if (pathLayer) pathLayer.setStyle(pathStyle()); });
  map.on('moveend zoomend', placeLabels);
  let rt; window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => { map.invalidateSize(); frame(); }, 150); });

  // ---- state ----
  let step = -1, horizon = Number(P.get('horizon')) > 0 ? 60 : 0, cur = new Map(), shown = new Map(), openItem = null;
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
    return new Map((at[r].byHorizon['60'] || []).map((x) => [x[0], [x[1], x[4] ?? x[1]]])); // [expected, colour]
  }

  const styleFor = (n, hotSick, forecast) => buildingStyle(n, hotSick, vmax, { minPeople, forecast });

  const haloR = () => haloRadius(map.getZoom()); // px; gone by street zoom
  map.on('zoomend zoomrefresh', () => { const r = haloR(); for (const it of items) if (it.halo) it.halo.setRadius(r); });
  function render(force) {
    const { s, t } = snapshot();
    if (!force && s === step) return;
    step = s;
    const now = new Map(totals.steps[s].map((r) => [r[0], r]));
    const fc = horizon ? forecastAt(t) : null;
    shown = new Map();
    for (const it of items) {
      let n = 0, sick = 0, heat = 0, any = false;
      for (const idx of it.idxs) {
        const r = now.get(idx);
        if (!r) continue;
        any = true; n += r[1];
        sick += fc ? fc.get(idx)?.[0] || 0 : r[2];
        heat += fc ? fc.get(idx)?.[1] || 0 : hot(r);
      }
      const style = any ? styleFor(n, heat, !!fc) : styleFor(0, 0, false);
      const key = JSON.stringify(style);
      if (key !== it.key) {
        it.layer.setStyle(style); it.key = key;
        // a halo with a floor on its on-screen size, so a small hot building still registers when zoomed out
        if (style.fill) {
          if (!it.halo) it.halo = L.circleMarker(it.layer.getBounds().getCenter(), { interactive: false, stroke: false, radius: haloR(), ...PHALO }).addTo(map);
          it.halo.setStyle({ fill: true, fillColor: style.fillColor, fillOpacity: style.fillOpacity * 0.55 });
        } else if (it.halo) { it.halo.remove(); it.halo = null; }
      }
      shown.set(it, { people: n, sick });
    }
    // "Now · updated 4:30 pm": the snapshot's time of day, today
    const d = new Date(), snap = new Date(startMs + s * stepMs);
    d.setHours(snap.getHours(), snap.getMinutes(), 0, 0);
    $('time').innerHTML = horizon
      ? `<b>In 1 hour</b> · around ${clock12(new Date(d.getTime() + 3600000))}`
      : `<b>Now</b> · updated ${clock12(d)}`;
    if (openItem) setPopupText();
  }

  const pop = L.popup({ closeButton: false, autoPanPadding: [20, 80] });
  // Every tap answers: the totals, or that too few people are there to show (the privacy rule).
  function setPopupText() {
    const d = shown.get(openItem) || { people: 0, sick: 0 };
    const name = `<b>${esc(openItem.name)}</b>`, also = openItem.also.length ? `<br><small>includes ${esc(openItem.also.join(', '))}</small>` : '';
    pop.setContent(d.people < minPeople
      ? `${name}: fewer than ${minPeople} people here right now${also}`
      : horizon
        ? `${name}: about ${fmt(d.sick)} sick expected in 1 hour${also}`
        : `${name}: about ${fmt(d.sick)} sick of ${fmt(d.people)} people${also}`);
  }
  function popup(item, latlng) {
    openItem = item;
    setPopupText();
    pop.setLatLng(latlng).openOn(map);
  }
  map.on('popupclose', () => { openItem = null; });
  window.fluniUserMap = { items, popup, popupText: () => pop.getContent() }; // for tests: tap every building

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
