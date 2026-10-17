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
  const [totals, geo, bounds] = await Promise.all([
    fetchTotals(),
    fetch('data/buildings.geojson').then((r) => r.json()),
    fetch('assets/trace/campus_trace_bounds.json').then((r) => r.json()).catch(() => null),
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
  const map = L.map('map', { zoomControl: false, attributionControl: false, zoomSnap: 0.25, zoomDelta: 0.5, maxZoom: 20 });
  if (bounds) {
    const b = L.latLngBounds([bounds.south, bounds.west], [bounds.north, bounds.east]);
    L.imageOverlay('assets/trace/campus_trace.webp', b, { pane: 'tilePane' }).addTo(map);
    map.setMaxBounds(b.pad(0.1));
  }
  const items = [];
  const all = L.featureGroup();
  for (const f of geo.features) {
    const idx = ids.get(f.properties.id);
    if (idx === undefined) continue;
    const layer = L.geoJSON(f, { style: () => ({ stroke: false, fill: false }) });
    layer.on('click', (e) => { L.DomEvent.stopPropagation(e); popup(idx, e.latlng); });
    items.push({ idx, layer, key: '' });
    layer.addTo(all);
  }
  all.addTo(map);
  const view = all.getBounds().isValid() ? all.getBounds() : L.latLngBounds([37.417, -122.183], [37.438, -122.156]);
  map.fitBounds(view, { padding: [8, 8] });
  map.setMinZoom(map.getZoom()); // never smaller than the whole campus
  map.setView(view.getCenter(), map.getBoundsZoom(view, true)); // cover the screen: a tall phone shows campus top to bottom

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
    return { stroke: true, weight: 1, color: INK, opacity: 0.45, dashArray: forecast ? '4 3' : null, fill: true, fillColor: color, fillOpacity: op };
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
