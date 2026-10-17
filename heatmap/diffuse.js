// Heat as a diffusion field: splat each person once onto a grid (O(1) per person), then blur the
// whole grid with three box blurs, which approximate a Gaussian. Cost depends on the grid size,
// not on how many people there are. Indoor people are blurred separately and divided by the blurred
// building mask (normalized convolution), so their heat fills the building and never leaks outside.
// Edges reflect, so no mass is lost at the grid border. The output matches HeatGrid's fields.

const M_PER_DEG_LAT = 110574;

// Box widths (odd) whose 3 successive passes have the variance of a Gaussian with std sigma (cells).
function boxWidths(sigma, n = 3) {
  const ideal = Math.sqrt((12 * sigma * sigma) / n + 1);
  let wl = Math.floor(ideal);
  if (wl % 2 === 0) wl--;
  const wu = wl + 2;
  const m = Math.round((12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4));
  return Array.from({ length: n }, (_, i) => (i < m ? wl : wu));
}

const reflect = (i, n) => (i < 0 ? -i - 1 : i >= n ? 2 * n - 1 - i : i);

// Running-sum box blur of radius r along rows (src -> dst).
function blurRows(src, dst, nx, ny, r) {
  const inv = 1 / (2 * r + 1);
  for (let y = 0; y < ny; y++) {
    const o = y * nx;
    let s = 0;
    for (let k = -r; k <= r; k++) s += src[o + reflect(k, nx)];
    for (let x = 0; x < nx; x++) {
      dst[o + x] = s * inv;
      s += src[o + reflect(x + r + 1, nx)] - src[o + reflect(x - r, nx)];
    }
  }
}

// Same along columns, a whole row at a time so memory access stays contiguous.
function blurCols(src, dst, nx, ny, r, acc) {
  const inv = 1 / (2 * r + 1);
  acc.fill(0);
  for (let k = -r; k <= r; k++) {
    const o = reflect(k, ny) * nx;
    for (let x = 0; x < nx; x++) acc[x] += src[o + x];
  }
  for (let y = 0; y < ny; y++) {
    const o = y * nx, a = reflect(y + r + 1, ny) * nx, b = reflect(y - r, ny) * nx;
    for (let x = 0; x < nx; x++) {
      dst[o + x] = acc[x] * inv;
      acc[x] += src[a + x] - src[b + x];
    }
  }
}

export class DiffusionField {
  // mask: Uint8Array(nx*ny), 1 = inside a building, or null (everything is outdoors).
  constructor(bounds, cellM, { mask = null } = {}) {
    this.bounds = bounds;
    this.cellM = cellM;
    const lat0 = (bounds.south + bounds.north) / 2;
    this.mPerDegLon = 111320 * Math.cos((lat0 * Math.PI) / 180);
    this.nx = Math.ceil(((bounds.east - bounds.west) * this.mPerDegLon) / cellM);
    this.ny = Math.ceil(((bounds.north - bounds.south) * M_PER_DEG_LAT) / cellM);
    const n = this.nx * this.ny;
    this.mask = mask;
    this.heat = new Float32Array(n);   // infected per m²
    this.people = new Float32Array(n); // people per m²
    this.sigmaM = 0;
    // Deposits (mass per cell) and scratch space, allocated once.
    this.depOut = new Float32Array(n); this.depOutP = new Float32Array(n);
    this.depIn = mask ? new Float32Array(n) : null;
    this.depInP = mask ? new Float32Array(n) : null;
    this.tmp = new Float32Array(n);
    this.work = new Float32Array(n);
    this.acc = new Float64Array(this.nx);
    this.maskBlur = null; // blurred mask, cached per sigma
    this.maskSigma = -1;
  }

  clear() {
    this.depOut.fill(0); this.depOutP.fill(0);
    if (this.depIn) { this.depIn.fill(0); this.depInP.fill(0); }
  }

  // points: iterable of { lat, lon, p, indoor }. Bilinear splat of weight·p and weight.
  deposit(points, weight = 1) {
    const { nx, ny, cellM, mPerDegLon, bounds } = this;
    const kx = mPerDegLon / cellM, ky = M_PER_DEG_LAT / cellM;
    for (const pt of points) {
      // Cell centres sit at index + 0.5, so shift by half a cell; clamp to the grid.
      const fx = Math.min(nx - 1, Math.max(0, (pt.lon - bounds.west) * kx - 0.5));
      const fy = Math.min(ny - 1, Math.max(0, (bounds.north - pt.lat) * ky - 0.5));
      if (fx !== fx || fy !== fy) continue; // NaN
      const x0 = Math.min(nx - 2 < 0 ? 0 : nx - 2, Math.floor(fx)), y0 = Math.min(ny - 2 < 0 ? 0 : ny - 2, Math.floor(fy));
      const tx = fx - x0, ty = fy - y0;
      const x1 = Math.min(nx - 1, x0 + 1), y1 = Math.min(ny - 1, y0 + 1);
      const heat = pt.indoor && this.depIn ? this.depIn : this.depOut;
      const ppl = pt.indoor && this.depIn ? this.depInP : this.depOutP;
      const m = weight * pt.p;
      const w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
      const i00 = y0 * nx + x0, i10 = y0 * nx + x1, i01 = y1 * nx + x0, i11 = y1 * nx + x1;
      heat[i00] += m * w00; heat[i10] += m * w10; heat[i01] += m * w01; heat[i11] += m * w11;
      ppl[i00] += weight * w00; ppl[i10] += weight * w10; ppl[i01] += weight * w01; ppl[i11] += weight * w11;
    }
  }

  // Blur src into dst with 3 box passes (src is left untouched).
  blur(src, dst, radii) {
    const { nx, ny, tmp, acc } = this;
    let from = src;
    for (const r0 of radii) {
      const r = Math.min(r0, nx - 1, ny - 1);
      blurRows(from, tmp, nx, ny, r);
      blurCols(tmp, dst, nx, ny, r, acc);
      from = dst;
    }
  }

  // Blur a deposit and add it to out (per-cell mass -> per-m² density happens in the caller).
  addOutdoor(dep, out, radii) {
    this.blur(dep, this.work, radii);
    const w = this.work;
    for (let i = 0; i < out.length; i++) out[i] += w[i];
  }

  // Indoor: blur(dep) / blur(mask), kept only where mask = 1, rescaled so total mass is preserved.
  addIndoor(dep, out, radii) {
    const { mask, work, maskBlur } = this;
    let total = 0, got = 0;
    for (let i = 0; i < dep.length; i++) total += dep[i];
    if (total === 0) return;
    this.blur(dep, work, radii);
    for (let i = 0; i < out.length; i++) {
      if (!mask[i]) continue;
      const v = work[i] / maskBlur[i];
      work[i] = v;
      got += v;
    }
    if (got === 0) return; // deposits all fell where the blurred mask is empty
    const k = total / got;
    for (let i = 0; i < out.length; i++) if (mask[i]) out[i] += work[i] * k;
  }

  diffuse(sigmaM) {
    this.sigmaM = sigmaM;
    const radii = boxWidths(Math.max(sigmaM / this.cellM, 0.3)).map((w) => (w - 1) >> 1);
    const { heat, people, mask } = this;
    heat.fill(0);
    people.fill(0);
    if (mask && this.maskSigma !== sigmaM) {
      if (!this.maskBlur) this.maskBlur = new Float32Array(mask.length);
      const m = new Float32Array(mask); // one-off per sigma
      this.blur(m, this.maskBlur, radii);
      for (let i = 0; i < m.length; i++) if (this.maskBlur[i] < 1e-6) this.maskBlur[i] = 1e-6;
      this.maskSigma = sigmaM;
    }
    this.addOutdoor(this.depOut, heat, radii);
    this.addOutdoor(this.depOutP, people, radii);
    if (mask) {
      this.addIndoor(this.depIn, heat, radii);
      this.addIndoor(this.depInP, people, radii);
    }
    const inv = 1 / (this.cellM * this.cellM);
    for (let i = 0; i < heat.length; i++) { heat[i] *= inv; people[i] *= inv; }
    return this;
  }

  max() {
    let m = 0;
    for (const v of this.heat) if (v > m) m = v;
    return m;
  }
}
