// Risk field: at each spot x, P(you catch flu if you stood there for an hour).
// Each person j leaves a circle of infection hazard that fades exponentially with distance,
//   h_j(d) = h0_j * exp(-d / L),
// and the circles add up as hazards: P(x) = 1 - exp(-sum_j h_j(|x - x_j|)).
// h0_j is lambda's near-field dose at 1 m for 1 h (model/infer.js doseModel: q * B / Q, diluted outdoors),
// times j's expected infectiousness shed_j = sum over infection ages of P_j(age) * stage(age)
// (model/meanfield.js), so the circle grows with j's P(flu) and with how infectious j's stage is.
// Walls bound it (setZones): a circle only lights cells in the person's own space, their building if they're
// inside one, open air if not, so indoor heat stops at the building's walls and outdoor heat stays out.
// Output has the fields heat.js paint() expects; heat holds P^2 / vmax so paint's sqrt colour scale
// becomes linear: darkness proportional to P(x), saturating at vmax.

const M_PER_DEG_LAT = 110574;

export class RiskField {
  constructor(bounds, cellM) {
    this.bounds = bounds;
    this.cellM = cellM;
    this.sigmaM = cellM;
    const lat0 = (bounds.south + bounds.north) / 2;
    this.mPerDegLon = 111320 * Math.cos((lat0 * Math.PI) / 180);
    this.nx = Math.ceil(((bounds.east - bounds.west) * this.mPerDegLon) / cellM);
    this.ny = Math.ceil(((bounds.north - bounds.south) * M_PER_DEG_LAT) / cellM);
    this.heat = new Float32Array(this.nx * this.ny);
    this.people = new Float32Array(this.nx * this.ny).fill(1); // no privacy masking in this view
    this.region = null; // per cell: -1 open air, else the building's zone index
    this.peak = 0;
  }

  // zones: buildZones().zones; rasterZone: zones.js (the same cells the room-level heat stays in).
  setZones(zones, rasterZone) {
    const region = new Int32Array(this.nx * this.ny).fill(-1);
    zones.forEach((z, zi) => {
      const r = rasterZone(z, this);
      if (!r) return;
      for (let y = 0; y < r.h; y++) for (let x = 0; x < r.w; x++) if (r.own[y * r.w + x]) region[(r.y0 + y) * this.nx + r.x0 + x] = zi;
    });
    this.region = region;
  }

  // sources: [{ lat, lon, h0, zone }] (h0: hazard at 1 m for 1 h; zone: the building's zone index, -1 outdoors,
  // undefined = whatever space their cell is in); fadeM: L in metres; vmax: P at full darkness.
  compute(sources, fadeM, vmax) {
    const { nx, ny, cellM, heat, bounds } = this;
    heat.fill(0);
    const L = fadeM / cellM, cut = 6 * L; // exp(-6) < 0.25%: the tail is dropped
    for (const s of sources) {
      if (!(s.h0 > 1e-7)) continue;
      const cx = ((s.lon - bounds.west) * this.mPerDegLon) / cellM, cy = ((bounds.north - s.lat) * M_PER_DEG_LAT) / cellM;
      const x0 = Math.max(0, Math.floor(cx - cut)), x1 = Math.min(nx - 1, Math.floor(cx + cut));
      const y0 = Math.max(0, Math.floor(cy - cut)), y1 = Math.min(ny - 1, Math.floor(cy + cut));
      const ox = Math.floor(cx), oy = Math.floor(cy), reg = this.region;
      const own = !reg ? 0 : s.zone !== undefined ? s.zone : ox >= 0 && oy >= 0 && ox < nx && oy < ny ? reg[oy * nx + ox] : -1;
      for (let y = y0; y <= y1; y++) {
        const dy = y + 0.5 - cy, row = y * nx;
        for (let x = x0; x <= x1; x++) {
          // the person's own cell always gets the peak, so a circle narrower than a cell still shows
          const d = x === ox && y === oy ? 0 : Math.hypot(x + 0.5 - cx, dy);
          if (d <= cut && (!reg || reg[row + x] === own || d === 0)) heat[row + x] += s.h0 * Math.exp(-d / L);
        }
      }
    }
    let peak = 0;
    for (let i = 0; i < heat.length; i++) {
      if (!heat[i]) continue;
      const p = -Math.expm1(-heat[i]);
      if (p > peak) peak = p;
      heat[i] = (p * p) / vmax;
    }
    this.peak = peak;
    return this;
  }
}
