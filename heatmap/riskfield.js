// Risk field: at each spot x, P(you catch flu if you stood there for an hour).
// Each person j leaves a circle of infection hazard that fades exponentially with distance,
//   h_j(d) = h0_j * exp(-d / L),
// and the circles add up as hazards: P(x) = 1 - exp(-sum_j h_j(d_j(x))).
// h0_j is lambda's near-field dose at 1 m for 1 h (model/infer.js doseModel: q * B / Q, diluted outdoors),
// times j's expected infectiousness shed_j = sum over infection ages of P_j(age) * stage(age)
// (model/meanfield.js), so the circle grows with j's P(flu) and with how infectious j's stage is.
// Walls stop it (setZones): d is the walking distance through the person's own space, cell to cell. Someone
// indoors reaches only their building (that wing, never across a courtyard or a notch a wall separates),
// someone outdoors only open air. Without zones, d is the straight-line distance.
// Output has the fields heat.js paint() expects; heat holds P^2 / vmax so paint's sqrt colour scale
// becomes linear: darkness proportional to P(x), saturating at vmax.

const M_PER_DEG_LAT = 110574;
// 8 neighbours: dx, dy, step length, and the `cut` bit (zones.js rasterZone) on the cell the link starts from:
// right 1, down 2, down-right 4, down-left 8; the reverse links read the bit on the neighbour.
const NB = [[1, 0, 1, 1, 0], [-1, 0, 1, 1, 1], [0, 1, 1, 2, 0], [0, -1, 1, 2, 1],
  [1, 1, Math.SQRT2, 4, 0], [-1, -1, Math.SQRT2, 4, 1], [-1, 1, Math.SQRT2, 8, 0], [1, -1, Math.SQRT2, 8, 1]];

export class RiskField {
  constructor(bounds, cellM) {
    this.bounds = bounds;
    this.cellM = cellM;
    this.sigmaM = cellM;
    const lat0 = (bounds.south + bounds.north) / 2;
    this.mPerDegLon = 111320 * Math.cos((lat0 * Math.PI) / 180);
    const nx = (this.nx = Math.ceil(((bounds.east - bounds.west) * this.mPerDegLon) / cellM));
    const ny = (this.ny = Math.ceil(((bounds.north - bounds.south) * M_PER_DEG_LAT) / cellM));
    this.heat = new Float32Array(nx * ny);
    this.people = new Float32Array(nx * ny).fill(1); // no privacy masking in this view
    this.region = null;  // per cell: -1 open air, else one id per building part
    this.cut = null;     // per cell: links a wall separates (zones.js)
    this.dist = new Float32Array(nx * ny).fill(Infinity);
    this.heapD = new Float32Array(1024); this.heapI = new Int32Array(1024);
    this.peak = 0;
  }

  // zones: buildZones().zones; rasterZone: zones.js. Each building part becomes its own region.
  setZones(zones, rasterZone) {
    const { nx } = this, region = new Int32Array(this.nx * this.ny).fill(-1), cut = new Uint8Array(this.nx * this.ny);
    let next = 0;
    zones.forEach((z) => {
      const r = rasterZone(z, this);
      if (!r) return;
      const ids = new Map();
      for (let y = 0; y < r.h; y++) for (let x = 0; x < r.w; x++) {
        const own = r.own[y * r.w + x];
        if (!own) continue;
        if (!ids.has(own)) ids.set(own, next++);
        const i = (r.y0 + y) * nx + r.x0 + x;
        region[i] = ids.get(own);
        cut[i] = r.cut[y * r.w + x];
      }
    });
    this.region = region;
    this.cut = cut;
  }

  // sources: [{ lat, lon, h0, indoor }] (h0: hazard at 1 m for 1 h); fadeM: L in metres; vmax: P at full darkness.
  compute(sources, fadeM, vmax) {
    const { nx, ny, cellM, heat, bounds } = this;
    heat.fill(0);
    const L = fadeM / cellM, cut = 6 * L; // exp(-6) < 0.25%: the tail is dropped
    for (const s of sources) {
      if (!(s.h0 > 1e-7)) continue;
      const cx = ((s.lon - bounds.west) * this.mPerDegLon) / cellM, cy = ((bounds.north - s.lat) * M_PER_DEG_LAT) / cellM;
      const ox = Math.floor(cx), oy = Math.floor(cy);
      if (ox < 0 || oy < 0 || ox >= nx || oy >= ny) continue;
      if (this.region) this.spread(oy * nx + ox, s.h0, L, cut, s.indoor);
      else this.disc(cx, cy, s.h0, L, cut);
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

  // No walls: a plain disc. The person's own cell always gets the peak, so a circle narrower than a cell still shows.
  disc(cx, cy, h0, L, cut) {
    const { nx, ny, heat } = this, ox = Math.floor(cx), oy = Math.floor(cy);
    const x0 = Math.max(0, Math.floor(cx - cut)), x1 = Math.min(nx - 1, Math.floor(cx + cut));
    const y0 = Math.max(0, Math.floor(cy - cut)), y1 = Math.min(ny - 1, Math.floor(cy + cut));
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
      const d = x === ox && y === oy ? 0 : Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
      if (d <= cut) heat[y * nx + x] += h0 * Math.exp(-d / L);
    }
  }

  // Walls: Dijkstra from the person's cell through cells of the same region (their building part, or open air),
  // never across a link a wall cuts; the hazard falls with that walking distance. A person whose cell isn't in
  // their kind of space (a seat a little past the raster) lights only that cell.
  spread(start, h0, L, cut, indoor) {
    const { nx, ny, heat, region, dist } = this, own = region[start];
    heat[start] += h0;
    if ((own >= 0) !== Boolean(indoor)) return;
    const touched = [start];
    dist[start] = 0;
    let hd = this.heapD, hi = this.heapI, n = 0;
    const push = (d, i) => {
      if (n === hd.length) { const a = new Float32Array(n * 2), b = new Int32Array(n * 2); a.set(hd); b.set(hi); hd = this.heapD = a; hi = this.heapI = b; }
      let k = n++;
      while (k > 0) { const p = (k - 1) >> 1; if (hd[p] <= d) break; hd[k] = hd[p]; hi[k] = hi[p]; k = p; }
      hd[k] = d; hi[k] = i;
    };
    push(0, start);
    while (n) {
      const d = hd[0], i = hi[0];
      n--; // pop: sift the last entry down from the root
      const ld = hd[n], li = hi[n];
      let k = 0;
      for (;;) { let c = 2 * k + 1; if (c >= n) break; if (c + 1 < n && hd[c + 1] < hd[c]) c++; if (hd[c] >= ld) break; hd[k] = hd[c]; hi[k] = hi[c]; k = c; }
      hd[k] = ld; hi[k] = li;
      if (d > dist[i]) continue; // stale entry
      if (i !== start) heat[i] += h0 * Math.exp(-d / L);
      const x = i % nx, y = (i - x) / nx;
      for (const [dx, dy, len, bit, rev] of NB) {
        const u = x + dx, v = y + dy;
        if (u < 0 || v < 0 || u >= nx || v >= ny) continue;
        const j = v * nx + u;
        if (region[j] !== own) continue;
        if (dx && dy && (region[y * nx + u] !== own || region[v * nx + x] !== own)) continue; // no squeezing past a corner
        if (own >= 0 && (this.cut[rev ? j : i] & bit)) continue; // a wall between the two centres
        const nd = d + len;
        if (nd > cut || nd >= dist[j]) continue;
        if (dist[j] === Infinity) touched.push(j);
        dist[j] = nd;
        push(nd, j);
      }
    }
    for (const i of touched) dist[i] = Infinity;
  }
}
