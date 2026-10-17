// Heat at a point x = Σ p_i · K(x − x_i): the expected number of infected people per m² near x.
// (Concentration × average P(sick) gives the same sum.) The grid is computed in metres and knows
// nothing about any map library, so it can be drawn on Leaflet, Google Maps, or a static image.

const M_PER_DEG_LAT = 110574;

export class HeatGrid {
  constructor(bounds, cellM) {
    this.bounds = bounds; // { south, west, north, east }
    this.cellM = cellM;
    const lat0 = (bounds.south + bounds.north) / 2;
    this.mPerDegLon = 111320 * Math.cos((lat0 * Math.PI) / 180);
    this.nx = Math.ceil(((bounds.east - bounds.west) * this.mPerDegLon) / cellM);
    this.ny = Math.ceil(((bounds.north - bounds.south) * M_PER_DEG_LAT) / cellM);
    this.heat = new Float32Array(this.nx * this.ny);   // Σ p·K, infected per m²
    this.people = new Float32Array(this.nx * this.ny); // Σ K, people per m² (for privacy masking)
  }

  // Fractional column/row of a point. Row 0 is the north edge, so the grid maps straight onto a canvas.
  cellOf(lat, lon) {
    return [
      ((lon - this.bounds.west) * this.mPerDegLon) / this.cellM,
      ((this.bounds.north - lat) * M_PER_DEG_LAT) / this.cellM,
    ];
  }

  // points: [{ lat, lon, p }]. A Gaussian kernel of width sigmaM, cut off at 3σ.
  compute(points, sigmaM) {
    this.sigmaM = sigmaM;
    this.heat.fill(0);
    this.people.fill(0);
    const s = sigmaM / this.cellM;
    const r = Math.ceil(3 * s);
    const norm = 1 / (2 * Math.PI * sigmaM * sigmaM);
    for (const pt of points) {
      const [cx, cy] = this.cellOf(pt.lat, pt.lon);
      const x0 = Math.max(0, Math.floor(cx - r)), x1 = Math.min(this.nx - 1, Math.ceil(cx + r));
      const y0 = Math.max(0, Math.floor(cy - r)), y1 = Math.min(this.ny - 1, Math.ceil(cy + r));
      for (let y = y0; y <= y1; y++) {
        const dy = y + 0.5 - cy;
        for (let x = x0; x <= x1; x++) {
          const dx = x + 0.5 - cx;
          const k = norm * Math.exp(-(dx * dx + dy * dy) / (2 * s * s));
          const i = y * this.nx + x;
          this.heat[i] += pt.p * k;
          this.people[i] += k;
        }
      }
    }
    return this;
  }

  max() {
    let m = 0;
    for (const v of this.heat) if (v > m) m = v;
    return m;
  }
}

// Single warm hue, light → dark, fading in from transparent so low risk doesn't tint the map.
const STOPS = [
  [0.0, [253, 228, 214, 0]],
  [0.1, [249, 190, 160, 140]],
  [0.35, [242, 140, 92, 190]],
  [0.65, [235, 104, 52, 215]],
  [1.0, [139, 46, 12, 235]],
];
export const HEAT_STOPS = STOPS;

const LUT = (() => {
  const lut = new Uint8ClampedArray(256 * 4);
  for (let i = 0; i < 256; i++) {
    const t = i / 255;
    let j = 1;
    while (STOPS[j][0] < t) j++;
    const [t0, c0] = STOPS[j - 1], [t1, c1] = STOPS[j];
    const f = (t - t0) / (t1 - t0);
    for (let c = 0; c < 4; c++) lut[i * 4 + c] = c0[c] + f * (c1[c] - c0[c]);
  }
  return lut;
})();

// Draw the grid onto a canvas (one pixel per cell). vmax is fixed across frames, so a colour means
// the same thing at every moment. Colour follows √(value / vmax) so a lone sick person still shows;
// the legend's midpoint is therefore vmax / 4. minPeople hides cells with fewer than that many
// people within ~1σ.
export function paint(grid, canvas, vmax, { minPeople = 0 } = {}) {
  canvas.width = grid.nx;
  canvas.height = grid.ny;
  const ctx = canvas.getContext('2d');
  const img = ctx.createImageData(grid.nx, grid.ny);
  const peopleScale = 2 * Math.PI * grid.sigmaM * grid.sigmaM;
  for (let i = 0; i < grid.heat.length; i++) {
    if (grid.people[i] * peopleScale < minPeople) continue;
    const t = Math.sqrt(Math.min(1, grid.heat[i] / vmax));
    if (t < 0.02) continue;
    const k = Math.round(t * 255) * 4;
    img.data.set(LUT.subarray(k, k + 4), i * 4);
  }
  ctx.putImageData(img, 0, 0);
}
