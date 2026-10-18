// How a building is drawn on the user map: shared by the FlUni bundle (usermap.js) and the presenter's
// "What users see" (buildings.js), so both show the same colours from the same numbers. No imports but heat.js.
import { HEAT_STOPS } from './heat.js';

export const INK = '#33241c';
export const darker = (rgb) => rgb.replace(/\d+/g, (v) => Math.round(v * 0.72));

// Same piecewise-linear interpolation as the LUT in heat.js.
export function heatColor(t) {
  let j = 1;
  while (j < HEAT_STOPS.length - 1 && HEAT_STOPS[j][0] < t) j++;
  const [t0, c0] = HEAT_STOPS[j - 1], [t1, c1] = HEAT_STOPS[j];
  const f = Math.min(1, Math.max(0, (t - t0) / (t1 - t0)));
  const c = c0.map((v, i) => v + f * (c1[i] - v));
  return { color: `rgb(${Math.round(c[0])},${Math.round(c[1])},${Math.round(c[2])})`, alpha: c[3] / 255 };
}

// Colour max: the 90th percentile of each step's busiest building (the busiest step when most are blank).
// peaks: one value per step, any order.
export function colourMax(peaks) {
  const p = [...peaks].sort((a, b) => a - b);
  return p[Math.floor(0.9 * (p.length - 1))] || p[p.length - 1] || 1;
}

// Leaflet path style for one building, or HIDDEN when it shouldn't show.
// n: people there, hot: expected sick above the baseline (the colour), vmax: colour max.
export const HIDDEN = { stroke: false, fill: false };
const RAMP_FROM = 0.12; // where on the heat ramp the coolest shown building starts
export function buildingStyle(n, hot, vmax, { minPeople = 4, forecast = false } = {}) {
  if (n < minPeople) return HIDDEN;
  // (next to) nothing above the baseline: no fill. √ under 0.1 is where the palette is still fading in.
  if (!(hot / vmax >= 0.01)) return HIDDEN;
  // Light and soft like the presenter's room-level heat: the same sun -> fire ramp, translucent (more opaque as
  // it gets hotter, so hot buildings still read clearly warm), a thin stroke in its own darker hue.
  const x = Math.sqrt(Math.min(1, hot / vmax));
  const { color } = heatColor(RAMP_FROM + (1 - RAMP_FROM) * x);
  const alpha = 0.4 + 0.35 * x;
  return { stroke: true, weight: 0.8, color: darker(color), opacity: forecast ? 0.4 : 0.55, dashArray: forecast ? '4 3' : null,
    fill: true, fillColor: color, fillOpacity: forecast ? alpha * 0.6 : alpha };
}

// A hot building's halo has a floor on its on-screen size: radius in CSS px, gone by street zoom.
export const haloRadius = (zoom, minZoom = 0) => Math.max(0, Math.min(9, (17.5 - zoom) * 4));
export const GLOW = 'drop-shadow(0 0 3px rgba(233,149,105,.45))'; // CSS filter on the fill pane (soft)
export const HALO_BLUR = 'blur(2.5px)';                           // CSS filter on the halo pane

// "about 3.4": integers from 10 up, one decimal below.
export const fmt = (x) => (x >= 10 ? String(Math.round(x)) : String(Math.round(x * 10) / 10));
// the gradient behind the legend strip, matching buildingStyle's colours
export const rampCss = () => `linear-gradient(to right, ${[0, 0.25, 0.5, 0.75, 1].map((q) => {
  const m = heatColor(RAMP_FROM + (1 - RAMP_FROM) * q).color.match(/\d+/g); return `rgba(${m[0]},${m[1]},${m[2]},${0.4 + 0.35 * q})`; }).join(', ')})`;
