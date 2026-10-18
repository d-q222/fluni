// Aerosol field: infectious air that evolves over time, ∂C/∂t = ∇·(k∇C) − C/τ + S on the metre grid.
// Infectious people emit into the cell they stand in; the air mixes, is stopped by walls, leaks
// through doors and out of buildings, and is ventilated away (fast outdoors, slowly indoors).
// Walls sit on cell faces, not in cells: a dorm room is ~4.5 × 4 m, so at 3 m cells a wall of whole
// cells would fill the room. Each face has an openness: 1 open, 0 wall, doorWidth/cellM for a door.
// Rooms are well mixed: open indoor faces get a high k. Door faces pass air at a low k, so a sick
// person's room fills, then slowly leaks into the corridor and outside.
// Time stepping, per sub-step: add sources, decay exactly, then an implicit (backward Euler) solve
// along rows and then along columns (LOD splitting). Each line is a tridiagonal solve: unconditionally
// stable, never negative, and mass-conserving, so sub-steps are capped for accuracy, not stability.
// Output fields match diffuse.js, so heat.js paint() draws it.

import { rasterizeBuildings } from './masks.js';

const M_PER_DEG_LAT = 110574;

export class AerosolField {
  // faces: { e, s } from buildWalls (e[i]: face between cell i and i+1, s[i]: between i and i+nx),
  // or null (no walls). indoor: Uint8Array, 1 = inside a building. region: Int32Array from buildWalls,
  // lets a source with a room index land in that room's cells. Diffusivities in m²/s.
  constructor(bounds, cellM, {
    faces = null, indoor = null, region = null,
    diffusivity = 0.05, indoorDiffusivity = 1, doorDiffusivity = 0.01,
    tauMin = 30, outdoorTauMin = 5, maxStepSec = 120,
  } = {}) {
    this.bounds = bounds;
    this.cellM = cellM;
    const lat0 = (bounds.south + bounds.north) / 2;
    this.mPerDegLon = 111320 * Math.cos((lat0 * Math.PI) / 180);
    const nx = (this.nx = Math.ceil(((bounds.east - bounds.west) * this.mPerDegLon) / cellM));
    const ny = (this.ny = Math.ceil(((bounds.north - bounds.south) * M_PER_DEG_LAT) / cellM));
    const n = nx * ny;
    this.faces = faces;
    this.indoor = indoor;
    this.region = region;
    this.tauIn = tauMin * 60;
    this.tauOut = outdoorTauMin * 60;
    this.maxStepSec = maxStepSec;
    this.heat = new Float32Array(n);             // quanta per m²
    this.people = new Float32Array(n).fill(1);   // no privacy masking in this mode
    this.sigmaM = cellM;
    // Face conductances k·open/h² (1/s). Open indoor faces mix fast (well-mixed rooms); outdoors uses
    // the base k; doors a low k, so a one-cell room leaks into the corridor over ~30 min, like a mostly
    // closed door, and a room's air fades by ventilation and leakage together.
    const h2 = cellM * cellM;
    const g = (i, j, open) => {
      if (!open) return 0;
      const inside = indoor && indoor[i] && indoor[j];
      return ((open < 1 ? doorDiffusivity : inside ? indoorDiffusivity : diffusivity) * open) / h2;
    };
    this.gx = new Float32Array(n);
    this.gy = new Float32Array(n);
    for (let y = 0; y < ny; y++) {
      for (let x = 0; x < nx; x++) {
        const i = y * nx + x;
        if (x < nx - 1) this.gx[i] = g(i, i + 1, faces ? faces.e[i] : 1);
        if (y < ny - 1) this.gy[i] = g(i, i + nx, faces ? faces.s[i] : 1);
      }
    }
    this.src = new Float32Array(n);  // emission per m² per second, rebuilt each step
    this.cp = new Float64Array(n);   // Thomas scratch
    this.dp = new Float64Array(n);
  }

  reset() { this.heat.fill(0); }

  // True if a and b (neighbours, incl. diagonal) share air without crossing a wall or door.
  linked(a, b) {
    const f = this.faces;
    if (!f || a === b) return true;
    const nx = this.nx, lo = Math.min(a, b), d = Math.abs(a - b);
    if (d === 1) return f.e[lo] === 1;
    if (d === nx) return f.s[lo] === 1;
    // diagonal: either L-shaped path through a neighbour
    const ax = a % nx, bx = b % nx, ay = (a - ax) / nx, by = (b - bx) / nx;
    // Not neighbours (emit() can move the own cell up to 2 cells into the person's room): keep the
    // weight in the own cell. Recursing here never ended (stack overflow on the default run).
    if (Math.abs(ax - bx) > 1 || Math.abs(ay - by) > 1) return false;
    const c1 = ay * nx + bx, c2 = by * nx + ax;
    return (this.linked(a, c1) && this.linked(c1, b)) || (this.linked(a, c2) && this.linked(c2, b));
  }

  // Bilinear splat of rate (per s) into src; weight that would cross a wall stays in the own cell.
  // A room is only a cell or two wide, so a person standing in it can be nearest to a corridor cell:
  // with s.room set, the own cell moves to the nearest cell of that room (within 2 cells).
  emit(sources) {
    const { nx, ny, cellM, mPerDegLon, bounds, src } = this;
    const kx = mPerDegLon / cellM, ky = M_PER_DEG_LAT / cellM, inv = 1 / (cellM * cellM);
    src.fill(0);
    for (const s of sources) {
      const rate = s.rate * inv;
      if (!(rate > 0)) continue;
      const fx = Math.min(nx - 1, Math.max(0, (s.lon - bounds.west) * kx - 0.5));
      const fy = Math.min(ny - 1, Math.max(0, (bounds.north - s.lat) * ky - 0.5));
      if (fx !== fx || fy !== fy) continue; // NaN
      const x0 = Math.min(Math.max(nx - 2, 0), Math.floor(fx)), y0 = Math.min(Math.max(ny - 2, 0), Math.floor(fy));
      const tx = fx - x0, ty = fy - y0;
      const x1 = Math.min(nx - 1, x0 + 1), y1 = Math.min(ny - 1, y0 + 1);
      let own = (ty < 0.5 ? y0 : y1) * nx + (tx < 0.5 ? x0 : x1);
      if (s.room != null && this.region && this.region[own] !== s.room) own = this.nearest(fx, fy, s.room, own);
      const cells = [y0 * nx + x0, y0 * nx + x1, y1 * nx + x0, y1 * nx + x1];
      const w = [(1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty];
      for (let k = 0; k < 4; k++) src[this.linked(own, cells[k]) ? cells[k] : own] += rate * w[k];
    }
  }

  nearest(fx, fy, room, own) {
    const { nx, ny, region } = this;
    let best = own, bd = Infinity;
    for (let y = Math.max(0, Math.round(fy) - 2); y <= Math.min(ny - 1, Math.round(fy) + 2); y++) {
      for (let x = Math.max(0, Math.round(fx) - 2); x <= Math.min(nx - 1, Math.round(fx) + 2); x++) {
        const d = (x - fx) ** 2 + (y - fy) ** 2;
        if (region[y * nx + x] === room && d < bd) { bd = d; best = y * nx + x; }
      }
    }
    return best;
  }

  // Advance by dtSec of simulated time. sources: iterable of
  // { lat, lon, rate, room? }: rate is emission per second, room an index into buildWalls' roomWkts.
  step(dtSec, sources = []) {
    if (!(dtSec > 0)) return this;
    this.emit(sources);
    const steps = Math.ceil(dtSec / this.maxStepSec), dt = dtSec / steps;
    for (let k = 0; k < steps; k++) this.substep(dt);
    return this;
  }

  substep(dt) {
    const { nx, ny, heat, src, gx, gy, cp, dp, indoor } = this;
    const fIn = Math.exp(-dt / this.tauIn), fOut = Math.exp(-dt / this.tauOut);
    const eIn = dt * Math.sqrt(fIn), eOut = dt * Math.sqrt(fOut); // new emission decays half a step
    // Rows: sources + decay feed the right-hand side, then (1 − dt·Lx) C = d.
    for (let y = 0; y < ny; y++) {
      const o = y * nx;
      let cPrev = 0, cpPrev = 0, dpPrev = 0;
      for (let x = 0; x < nx; x++) {
        const i = o + x;
        const d = indoor && indoor[i] ? heat[i] * fIn + src[i] * eIn : heat[i] * fOut + src[i] * eOut;
        const a = cPrev, c = dt * gx[i];
        const w = 1 / (1 + a + c - a * cpPrev);
        cp[i] = cpPrev = c * w;
        dp[i] = dpPrev = (d + a * dpPrev) * w;
        cPrev = c;
      }
      let next = dp[o + nx - 1];
      heat[o + nx - 1] = next;
      for (let x = nx - 2; x >= 0; x--) heat[o + x] = next = dp[o + x] + cp[o + x] * next;
    }
    // Columns, a whole row at a time so memory access stays contiguous.
    for (let x = 0; x < nx; x++) {
      const c = dt * gy[x], w = 1 / (1 + c);
      cp[x] = c * w;
      dp[x] = heat[x] * w;
    }
    for (let y = 1; y < ny; y++) {
      const o = y * nx;
      for (let x = 0; x < nx; x++) {
        const i = o + x, j = i - nx;
        const a = dt * gy[j], c = dt * gy[i];
        const w = 1 / (1 + a + c - a * cp[j]);
        cp[i] = c * w;
        dp[i] = (heat[i] + a * dp[j]) * w;
      }
    }
    const last = (ny - 1) * nx;
    for (let x = 0; x < nx; x++) heat[last + x] = dp[last + x];
    for (let y = ny - 2; y >= 0; y--) {
      const o = y * nx;
      for (let x = 0; x < nx; x++) heat[o + x] = dp[o + x] + cp[o + x] * heat[o + nx + x];
    }
  }

  max() {
    const { heat } = this;
    let m = 0;
    for (let i = 0; i < heat.length; i++) if (heat[i] > m) m = heat[i]; // indexed: for-of is ~10x slower
    return m;
  }
}

// 'POLYGON((lon lat, ...), (...))' -> rings of [lon, lat]. All rings go into one polygon; the
// even-odd fill in masks.js turns inner rings into holes.
function parseWkt(wkt) {
  return [...String(wkt).matchAll(/\(([^()]+)\)/g)].map((m) =>
    m[1].split(',').map((p) => p.trim().split(/\s+/).map(Number)));
}

// Walls on cell faces from building outlines and room polygons (WKT, e.g. a run's map/rooms.csv).
// Faces between different rooms, or a room and its corridor, or a building and the outside, are
// walls, except doors: one per doorEveryM metres along room edges (outerDoorEveryM on outer walls),
// and at least one per room. Returns { faces: { e, s }, indoor, region } where region is the room
// index, rooms.length + building index, or -1 outdoors.
export function buildWalls(grid, buildingsGeojson, roomWkts = [], {
  doorEveryM = 8, doorWidthM = 1.5, outerDoorEveryM = 20,
} = {}) {
  const { nx, ny, cellM } = grid, n = nx * ny, R = roomWkts.length;
  const bld = rasterizeBuildings(buildingsGeojson, grid).building;
  const rings = roomWkts.map(parseWkt);
  // Biggest first, so a small room on another floor isn't painted over by a big one (floors are flattened).
  const area = (r) => (r[0] || []).reduce((a, p, k, ring) => (k ? a + (ring[k - 1][0] - p[0]) * (ring[k - 1][1] + p[1]) : 0), 0);
  const feats = rings.map((r, k) => ({ geometry: { type: 'Polygon', coordinates: r }, properties: { id: k } }))
    .sort((a, b) => Math.abs(area(b.geometry.coordinates)) - Math.abs(area(a.geometry.coordinates)));
  const rr = rasterizeBuildings({ features: feats }, grid);
  const roomOf = rr.ids.map((id) => Number(id.slice(4))); // 'bld_<k>' -> k
  const region = new Int32Array(n).fill(-1), seen = new Uint8Array(R);
  for (let i = 0; i < n; i++) {
    if (rr.building[i] >= 0) { region[i] = roomOf[rr.building[i]]; seen[region[i]] = 1; }
    else if (bld[i] >= 0) region[i] = R + bld[i];
  }
  // Rooms smaller than a cell still get the cell under their vertex average.
  const { west, north } = grid.bounds;
  const mPerDegLon = 111320 * Math.cos(((grid.bounds.south + north) / 2) * Math.PI / 180);
  rings.forEach((r, k) => {
    if (seen[k] || !r.length) return;
    const pts = r[0].slice(0, -1);
    const lon = pts.reduce((s, p) => s + p[0], 0) / pts.length, lat = pts.reduce((s, p) => s + p[1], 0) / pts.length;
    const x = Math.floor(((lon - west) * mPerDegLon) / cellM), y = Math.floor(((north - lat) * M_PER_DEG_LAT) / cellM);
    if (x >= 0 && x < nx && y >= 0 && y < ny) region[y * nx + x] = k;
  });
  const indoor = new Uint8Array(n);
  for (let i = 0; i < n; i++) indoor[i] = region[i] >= 0 ? 1 : 0;

  const e = new Float32Array(n), s = new Float32Array(n);
  const door = Math.min(1, doorWidthM / cellM);
  // spare: a wall face to open if a room got no door; id 2i (e) or 2i+1 (s). Prefer one to a corridor.
  const hasDoor = new Uint8Array(R), spare = new Int32Array(R).fill(-1), spareIn = new Uint8Array(R);
  const isRoom = (r) => r >= 0 && r < R;
  const face = (i, j, t, f, id) => {
    const a = region[i], b = region[j];
    if (a === b) { f[i] = 1; return; }
    if (isRoom(a) && isRoom(b)) return; // room to room: solid
    const every = a < 0 || b < 0 ? outerDoorEveryM : doorEveryM;
    const open = Math.floor(t / every) !== Math.floor((t - cellM) / every);
    if (open) f[i] = door;
    for (const [r, other] of [[a, b], [b, a]]) {
      if (!isRoom(r)) continue;
      if (open) hasDoor[r] = 1;
      else if (spare[r] < 0 || (!spareIn[r] && other >= 0)) { spare[r] = id; spareIn[r] = other >= 0 ? 1 : 0; }
    }
  };
  for (let y = 0; y < ny; y++) {
    for (let x = 0; x < nx; x++) {
      const i = y * nx + x;
      if (x < nx - 1) face(i, i + 1, y * cellM, e, 2 * i);
      if (y < ny - 1) face(i, i + nx, x * cellM, s, 2 * i + 1);
    }
  }
  for (let r = 0; r < R; r++) if (!hasDoor[r] && spare[r] >= 0) (spare[r] & 1 ? s : e)[spare[r] >> 1] = door;
  return { faces: { e, s }, indoor, region };
}
