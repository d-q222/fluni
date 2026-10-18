// Heat as a diffusion field: splat each person once onto a grid (O(1) per person), then blur the
// whole grid with three box blurs, which approximate a Gaussian. Cost depends on the grid size,
// not on how many people there are. Indoor people are blurred separately and divided by the blurred
// building mask (normalized convolution), so their heat fills the building and never leaks outside.
// Edges reflect, so no mass is lost at the grid border.
// With zones (rooms clipped to their building, zones.js), each indoor person's heat stays in their own zone and
// spreads only cell to cell through it (diffuseZones): never across a wall, an outdoor gap, a courtyard or the
// space between the arms of a C-shaped building. Rooms don't share air (the model's wallFactor 0). The output has the fields paint() in heat.js expects.
// With few people (the 10-agent demo), only patches around them are blurred: a blur can't move mass
// further than the sum of its radii, so disjoint patches blurred apart give the same field.

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
const emptyBox = () => ({ x0: Infinity, y0: Infinity, x1: -1, y1: -1 });
const SPARSE_MAX = 64;
const MAX_STEPS = 60; // geodesic diffusion steps per zone (σ 15 m on 3 m cells needs 50)

// Index of the own cell nearest (x, y) in a patch, or -1 (a person standing just past their room's raster).
function nearestOwn(own, w, h, x, y) {
  let best = -1, bd = Infinity;
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) {
    if (!own[j * w + i]) continue;
    const d = (i - x) ** 2 + (j - y) ** 2;
    if (d < bd) { bd = d; best = j * w + i; }
  }
  return best;
} // above this many deposited points, blur the whole grid (patches stop paying)

// Running-sum box blur of radius r along rows (src -> dst).
function blurRows(src, dst, nx, ny, r) {
  const inv = 1 / (2 * r + 1);
  for (let y = 0; y < ny; y++) {
    const o = y * nx;
    let s = 0;
    for (let k = -r; k <= r; k++) s += src[o + reflect(k, nx)];
    for (let x = 0; x < nx; x++) {
      dst[o + x] = s * inv;
      const a = x + r + 1, b = x - r; // reflect(), inlined: this is the hottest loop
      s += src[o + (a < nx ? a : 2 * nx - 1 - a)] - src[o + (b >= 0 ? b : -b - 1)];
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
  // zones: (zoneIndex, grid) -> { x0, y0, w, h, own } (zones.js rasterZone), or null; with zones, indoor points
  // need `zone` (their zone index) and mask is not used.
  constructor(bounds, cellM, { mask = null, zones = null } = {}) {
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
    this.crop = new Float32Array(n); // a patch of a deposit, for sparse blurs
    this.vIn = mask ? new Float32Array(n) : null; // indoor heat before the mass rescale
    // Top-left cell of each deposited point, [x, y, ...], per deposit kind; null = too many to track.
    // And the bounding box of all of them (for big runs: people rarely span the whole grid).
    this.cellsOut = []; this.cellsIn = [];
    this.boxOut = emptyBox(); this.boxIn = emptyBox();
    this.acc = new Float64Array(this.nx);
    this.maskBlur = null; // blurred mask, cached per sigma
    this.maskSigma = -1;
    this.live = [];
    if (zones) {
      this.zoneRaster = zones;
      this.rasters = new Map(); // zone index -> its patch on this grid
      this.byZ = new Map();     // zone index -> [fx, fy, mass, ...] deposited this frame
      this.zoneOut = [];        // per zone diffused this frame: { z, x0, y0, w, h, own, u (per m²) }
    }
  }

  // Zeroes only the cells deposited into: tracked ones, else their bounding box.
  clear() {
    const { nx } = this;
    for (const [cells, box, a, b] of [[this.cellsOut, this.boxOut, this.depOut, this.depOutP], [this.cellsIn, this.boxIn, this.depIn, this.depInP]]) {
      if (!a) continue;
      if (!cells) {
        for (let y = box.y0; y <= box.y1 + 1; y++) {
          a.fill(0, y * nx + box.x0, y * nx + box.x1 + 2);
          b.fill(0, y * nx + box.x0, y * nx + box.x1 + 2);
        }
        continue;
      }
      for (let k = 0; k < cells.length; k += 2) {
        const i = cells[k + 1] * nx + cells[k];
        a[i] = a[i + 1] = a[i + nx] = a[i + nx + 1] = 0;
        b[i] = b[i + 1] = b[i + nx] = b[i + nx + 1] = 0;
      }
    }
    this.cellsOut = []; this.cellsIn = [];
    this.boxOut = emptyBox(); this.boxIn = emptyBox();
    if (this.byZ) this.byZ.clear();
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
      if (this.zoneRaster && pt.indoor) { // kept to the person's own zone (diffuseZones)
        if (!(pt.zone >= 0)) continue;
        if (!this.byZ.has(pt.zone)) this.byZ.set(pt.zone, []);
        this.byZ.get(pt.zone).push(fx, fy, weight * pt.p);
        continue;
      }
      const x0 = Math.min(nx - 2 < 0 ? 0 : nx - 2, Math.floor(fx)), y0 = Math.min(ny - 2 < 0 ? 0 : ny - 2, Math.floor(fy));
      const tx = fx - x0, ty = fy - y0;
      const x1 = Math.min(nx - 1, x0 + 1), y1 = Math.min(ny - 1, y0 + 1);
      const inside = pt.indoor && this.depIn;
      const heat = inside ? this.depIn : this.depOut;
      const ppl = inside ? this.depInP : this.depOutP;
      const cells = inside ? this.cellsIn : this.cellsOut, box = inside ? this.boxIn : this.boxOut;
      if (x0 < box.x0) box.x0 = x0; if (x0 > box.x1) box.x1 = x0; if (y0 < box.y0) box.y0 = y0; if (y0 > box.y1) box.y1 = y0;
      if (cells) {
        if (cells.length < 2 * SPARSE_MAX) cells.push(x0, y0);
        else if (inside) this.cellsIn = null; else this.cellsOut = null;
      }
      const m = weight * pt.p;
      const w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
      const i00 = y0 * nx + x0, i10 = y0 * nx + x1, i01 = y1 * nx + x0, i11 = y1 * nx + x1;
      heat[i00] += m * w00; heat[i10] += m * w10; heat[i01] += m * w01; heat[i11] += m * w11;
      ppl[i00] += weight * w00; ppl[i10] += weight * w10; ppl[i01] += weight * w01; ppl[i11] += weight * w11;
    }
  }

  // Blur src into dst with 3 box passes (src is left untouched). nx, ny: src's size (a patch's).
  blur(src, dst, radii, nx = this.nx, ny = this.ny) {
    const { tmp, acc } = this;
    let from = src;
    for (const r0 of radii) {
      const r = Math.min(r0, this.nx - 1, this.ny - 1);
      blurRows(from, tmp, nx, ny, r);
      blurCols(tmp, dst, nx, ny, r, acc);
      from = dst;
    }
  }

  // Patches to blur: each deposited cell padded by the blur's reach, overlapping ones merged until
  // all are disjoint. When untracked, or when patches would cover much of the grid anyway, the
  // bounding box of all deposits, padded the same way.
  patches(cells, box, reach) {
    const { nx, ny } = this;
    if (box.x1 < 0) return []; // nothing deposited
    const all = [{ x0: Math.max(0, box.x0 - reach), y0: Math.max(0, box.y0 - reach), x1: Math.min(nx - 1, box.x1 + 1 + reach), y1: Math.min(ny - 1, box.y1 + 1 + reach) }];
    if (!cells) return all;
    const boxes = [];
    for (let k = 0; k < cells.length; k += 2) {
      const x = cells[k], y = cells[k + 1];
      boxes.push({ x0: Math.max(0, x - reach), y0: Math.max(0, y - reach), x1: Math.min(nx - 1, x + 1 + reach), y1: Math.min(ny - 1, y + 1 + reach) });
    }
    for (let i = 0; i < boxes.length; i++) {
      const a = boxes[i];
      for (let j = i + 1; j < boxes.length; j++) {
        const b = boxes[j];
        if (b.x0 > a.x1 || b.x1 < a.x0 || b.y0 > a.y1 || b.y1 < a.y0) continue;
        a.x0 = Math.min(a.x0, b.x0); a.y0 = Math.min(a.y0, b.y0); a.x1 = Math.max(a.x1, b.x1); a.y1 = Math.max(a.y1, b.y1);
        boxes[j] = boxes[boxes.length - 1];
        boxes.pop();
        j = i; // a grew: check it against all the others again
      }
    }
    let area = 0;
    for (const b of boxes) area += (b.x1 - b.x0 + 1) * (b.y1 - b.y0 + 1);
    return area > (nx * ny) / 6 ? all : boxes;
  }

  // Blur dep within patch g into this.work, laid out as the patch (w × h).
  blurPatch(dep, g, radii) {
    const { nx, ny } = this, w = g.x1 - g.x0 + 1, h = g.y1 - g.y0 + 1;
    if (w === nx && h === ny) { this.blur(dep, this.work, radii); return; }
    for (let y = 0; y < h; y++) {
      const o = (g.y0 + y) * nx + g.x0;
      this.crop.set(dep.subarray(o, o + w), y * w);
    }
    this.blur(this.crop, this.work, radii, w, h);
  }

  // Blur a deposit and add it to out (per-cell mass -> per-m² density happens in the caller).
  addOutdoor(dep, out, radii, patches) {
    const { nx, work } = this;
    for (const g of patches) {
      this.blurPatch(dep, g, radii);
      const w = g.x1 - g.x0 + 1;
      for (let y = g.y0, l = 0; y <= g.y1; y++) {
        for (let i = y * nx + g.x0, end = i + w; i < end; i++, l++) out[i] += work[l];
      }
    }
  }

  // Indoor: blur(dep) / blur(mask), kept only where mask = 1, rescaled so total mass is preserved.
  addIndoor(dep, out, radii, patches) {
    const { nx, mask, work, maskBlur, vIn } = this;
    let total = 0, got = 0;
    for (const g of patches) {
      for (let y = g.y0; y <= g.y1; y++) for (let i = y * nx + g.x0, end = y * nx + g.x1; i <= end; i++) total += dep[i];
    }
    if (total === 0) return;
    for (const g of patches) {
      this.blurPatch(dep, g, radii);
      const w = g.x1 - g.x0 + 1;
      for (let y = g.y0, l = 0; y <= g.y1; y++) {
        for (let i = y * nx + g.x0, end = i + w; i < end; i++, l++) {
          if (!mask[i]) continue;
          const v = work[l] / maskBlur[i];
          vIn[i] = v;
          got += v;
        }
      }
    }
    if (got === 0) return; // deposits all fell where the blurred mask is empty
    const k = total / got;
    for (const g of patches) {
      for (let y = g.y0; y <= g.y1; y++) {
        for (let i = y * nx + g.x0, end = y * nx + g.x1; i <= end; i++) if (mask[i]) out[i] += vIn[i] * k;
      }
    }
  }

  // people: false skips the people field (only paint()'s minPeople masking reads it): half the work.
  diffuse(sigmaM, { people: withPeople = true } = {}) {
    this.sigmaM = sigmaM;
    const radii = boxWidths(Math.max(sigmaM / this.cellM, 0.3)).map((w) => (w - 1) >> 1);
    const reach = radii.reduce((sum, r) => sum + Math.min(r, this.nx - 1, this.ny - 1), 0);
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
    const outside = this.patches(this.cellsOut, this.boxOut, reach);
    this.live = [...outside]; // where heat can be non-zero (for max())
    this.addOutdoor(this.depOut, heat, radii, outside);
    if (withPeople) this.addOutdoor(this.depOutP, people, radii, outside);
    if (this.zoneRaster) this.diffuseZones(sigmaM, heat);
    else if (mask) {
      const inside = this.patches(this.cellsIn, this.boxIn, reach);
      this.live.push(...inside);
      this.addIndoor(this.depIn, heat, radii, inside);
      if (withPeople) this.addIndoor(this.depInP, people, radii, inside);
    }
    const inv = 1 / (this.cellM * this.cellM);
    for (let i = 0; i < heat.length; i++) { heat[i] *= inv; people[i] *= inv; }
    return this;
  }

  // Each zone with deposits on its own, by explicit heat-equation steps on its own cells: a cell exchanges
  // only with its 4 neighbours in the same zone (zero flux through walls and outdoor cells), so heat travels
  // around a C-shape, never across it. Each step moves D·(difference) both ways, so the mass (expected sick)
  // is exactly conserved. Variance grows 2·D cells² per step: steps = (σ/cell)² / (2·D), ≤ MAX_STEPS.
  diffuseZones(sigmaM, out) {
    const { nx } = this, D = 0.25, steps = Math.min(MAX_STEPS, Math.max(1, Math.round((sigmaM / this.cellM) ** 2 / (2 * D))));
    this.zoneOut = [];
    for (const [z, pts] of this.byZ) {
      let r = this.rasters.get(z);
      if (r === undefined) { r = this.zoneRaster(z, this) || null; this.rasters.set(z, r); }
      if (!r) continue;
      const { x0, y0, w, h, own } = r, n = w * h;
      let u = new Float32Array(n), v = new Float32Array(n), total = 0;
      for (let k = 0; k < pts.length; k += 3) { // bilinear splat onto the zone's own cells (else its nearest own cell)
        const fx = pts[k] - x0, fy = pts[k + 1] - y0, m = pts[k + 2];
        const cx = Math.floor(fx), cy = Math.floor(fy), tx = fx - cx, ty = fy - cy;
        const parts = [[cx, cy, (1 - tx) * (1 - ty)], [cx + 1, cy, tx * (1 - ty)], [cx, cy + 1, (1 - tx) * ty], [cx + 1, cy + 1, tx * ty]];
        for (const [x, y, wt] of parts) {
          if (!wt) continue;
          let i = x >= 0 && y >= 0 && x < w && y < h && own[y * w + x] ? y * w + x : -1;
          if (i < 0) i = nearestOwn(own, w, h, x, y);
          if (i >= 0) { u[i] += m * wt; total += m * wt; }
        }
      }
      if (!(total > 0)) continue;
      for (let s = 0; s < steps; s++) {
        v.set(u);
        for (let y = 0; y < h; y++) for (let x = 0, i = y * w; x < w; x++, i++) {
          if (!own[i]) continue;
          if (x + 1 < w && own[i + 1]) { const f = D * (u[i + 1] - u[i]); v[i] += f; v[i + 1] -= f; }
          if (y + 1 < h && own[i + w]) { const f = D * (u[i + w] - u[i]); v[i] += f; v[i + w] -= f; }
        }
        [u, v] = [v, u];
      }
      const inv = 1 / (this.cellM * this.cellM);
      for (let y = 0, l = 0; y < h; y++) for (let i = (y0 + y) * nx + x0, end = i + w; i < end; i++, l++) if (u[l]) { u[l] *= inv; out[i] += u[l] / inv; }
      this.zoneOut.push({ z, x0, y0, w, h, own, u });
      this.live.push({ x0, y0, x1: x0 + w - 1, y1: y0 + h - 1 });
    }
  }

  // Heat is zero outside the last diffuse()'s patches, so only those are scanned.
  max() {
    const { heat, nx } = this;
    let m = 0;
    for (const g of this.live) {
      for (let y = g.y0; y <= g.y1; y++) {
        for (let i = y * nx + g.x0, end = y * nx + g.x1; i <= end; i++) if (heat[i] > m) m = heat[i];
      }
    }
    return m;
  }
}
