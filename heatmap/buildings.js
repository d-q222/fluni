// Building-level view for the user-facing map: each campus building outline filled by how many sick
// people are expected there. It takes only per-building totals, never agent positions, so nothing
// finer than a building can be drawn. Colours come from the shared heat palette.

import { HEAT_STOPS } from './heat.js';

const MAX_FILL = 0.75;       // fill opacity at the palette's most opaque stop
const FORECAST_FILL = 0.5;   // forecasts are drawn lighter than measurements
const INK = '#33241c';       // --ink from the design palette; warm dark outline, never pure black
const MUTED = '#a8988a';     // outline when too few people to show anything
const HIDDEN = { stroke: false, fill: false, interactive: false };

// Same piecewise-linear interpolation as the LUT in heat.js.
function heatColor(t) {
  let j = 1;
  while (j < HEAT_STOPS.length - 1 && HEAT_STOPS[j][0] < t) j++;
  const [t0, c0] = HEAT_STOPS[j - 1], [t1, c1] = HEAT_STOPS[j];
  const f = Math.min(1, Math.max(0, (t - t0) / (t1 - t0)));
  const c = c0.map((v, i) => v + f * (c1[i] - v));
  return { color: `rgb(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])})`, alpha: c[3] / 255 };
}

// Integers from 10 up, one decimal below.
const fmt = (x) => (x >= 10 ? String(Math.round(x)) : String(Math.round(x * 10) / 10));

export class BuildingTotalsLayer {
  constructor(geojson, { renderer } = {}) {
    this.group = L.layerGroup();
    this.totals = new Map();
    this.opts = { minPeople: 4, forecast: false };
    this.items = new Map(); // buildingId → { layer, shown, key }
    for (const f of geojson.features) {
      const id = 'bld_' + String(f.properties.id).split('/')[1];
      const layer = L.geoJSON(f, { renderer, style: () => HIDDEN });
      layer.bindTooltip(() => this._tip(id), { sticky: true, className: 'bld-tip' });
      this.items.set(id, { layer, shown: false, key: '' });
    }
  }

  addTo(map) {
    this.map = map;
    this.group.addTo(map);
    return this;
  }

  remove() {
    this.group.remove();
    this.map = null;
  }

  update(totals, vmax, { minPeople = 4, forecast = false } = {}) {
    this.totals = totals;
    this.opts = { minPeople, forecast };
    for (const [id, it] of this.items) {
      const d = totals.get(id);
      if (!d) {
        if (it.shown) { this.group.removeLayer(it.layer); it.shown = false; it.key = ''; }
        continue;
      }
      const style = this._style(d, vmax, minPeople, forecast);
      const key = JSON.stringify(style);
      if (key !== it.key) { it.layer.setStyle(style); it.key = key; }
      if (!it.shown) { this.group.addLayer(it.layer); it.shown = true; }
      if (it.layer.isTooltipOpen()) it.layer.setTooltipContent(this._tip(id));
    }
  }

  _style(d, vmax, minPeople, forecast) {
    const base = { stroke: true, weight: 1, interactive: true, dashArray: forecast ? '4 3' : null };
    if (d.n < minPeople) return { ...base, color: MUTED, opacity: 0.45, fill: false };
    const t = Math.sqrt(Math.min(1, (d.excess ?? d.expected) / vmax)); // colour: risk above the baseline
    const { color, alpha } = heatColor(t);
    const op = alpha * MAX_FILL * (forecast ? FORECAST_FILL : 1);
    return { ...base, color: INK, opacity: 0.45, fill: op > 0.01, fillColor: color, fillOpacity: op };
  }

  _tip(id) {
    const d = this.totals.get(id);
    if (!d) return '';
    const name = d.name || 'Building';
    if (d.n < this.opts.minPeople) return `${name} · Not enough people to show safely`;
    if (this.opts.forecast) {
      const range = d.lo != null && d.hi != null ? ` (${fmt(d.lo)}–${fmt(d.hi)})` : '';
      return `${name} · ~${fmt(d.expected)} expected sick${range}`;
    }
    return `${name} · ~${fmt(d.n)} people · ~${fmt(d.expected)} expected sick`;
  }
}
