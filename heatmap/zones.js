// Heat zones: the walls heat may not pass. Each building's drawn footprint is a zone; a person's heat stays in
// their building (diffuse.js spreads it cell to cell through the building only: never across an outdoor gap,
// a courtyard or the space between a C's arms) and their dot sits inside it (seats.js).
// Pure data in, plain objects out; no DOM. Shared by app.js and seats.js.

const M_PER_DEG_LAT = 110574;
const SAMPLE = 7; // grid of candidate anchors per side

function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

const ringArea = (r) => { let s = 0; for (let i = 0; i + 1 < r.length; i++) s += r[i][0] * r[i + 1][1] - r[i + 1][0] * r[i][1]; return s / 2; };

export function inRing(x, y, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
// Even-odd over all of a zone's rings (clipped outer rings and clipped courtyards).
export const inZone = (z, x, y) => z.rings.reduce((acc, r) => (inRing(x, y, r) ? !acc : acc), false);
export function wallDist(z, x, y) {
  let best = Infinity;
  for (const r of z.rings) for (let i = 0; i + 1 < r.length; i++) {
    const [ax, ay] = r[i], [bx, by] = r[i + 1], dx = bx - ax, dy = by - ay, l = dx * dx + dy * dy;
    const t = l ? Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / l)) : 0;
    best = Math.min(best, Math.hypot(x - ax - t * dx, y - ay - t * dy));
  }
  return best;
}
// The roomiest of a grid of points inside the zone (an approximate pole of inaccessibility), nudged by a hash.
function anchorOf(z, key) {
  const [x0, y0, x1, y1] = z.box, h = hash(key);
  let best = null;
  for (let i = 0; i < SAMPLE; i++) for (let j = 0; j < SAMPLE; j++) {
    const x = x0 + ((i + 0.5 + ((h >>> (i * 3)) % 7) / 20) / SAMPLE) * (x1 - x0), y = y0 + ((j + 0.5) / SAMPLE) * (y1 - y0);
    if (!inZone(z, x, y)) continue;
    const d = wallDist(z, x, y);
    if (!best || d > best[2]) best = [x, y, d];
  }
  return best ? [best[0], best[1]] : null;
}
function boxOf(rings) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const r of rings) for (const [x, y] of r) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
  return [x0, y0, x1, y1];
}

// outlines: the drawn footprints (GeoJSON, properties.id 'run/<id>' for building 'bld_<id>').
// One zone per building: all of its footprint's parts (a multipolygon's wings) and courtyards. Heat moves only
// through its cells, so wings separated by outdoor space stay separate.
// Returns { zones, zoneFor(buildingId) -> index or -1 }.
// A zone: { id, building, rings (local metres; holes flagged), box, anchor, area, ll (rings as [lon, lat]), llBox, lon0, lat0, kx }.
export function buildZones(outlines) {
  const zones = [], index = new Map();
  for (const f of outlines?.features || []) {
    const id = `bld_${String(f.properties.id).split('/').pop()}`, g = f.geometry;
    const polys = g?.type === 'Polygon' ? [g.coordinates] : g?.type === 'MultiPolygon' ? g.coordinates : [];
    if (index.has(id) || !polys.length) continue;
    const [lon0, lat0] = polys[0][0][0], kx = 111320 * Math.cos((lat0 * Math.PI) / 180);
    const rings = polys.flatMap((p) => p.map((r, k) => {
      const ring = r.map(([lon, lat]) => [(lon - lon0) * kx, (lat - lat0) * M_PER_DEG_LAT]);
      ring.hole = k > 0;
      return ring;
    }));
    const z = { id, building: id, rings, box: boxOf(rings), lon0, lat0, kx };
    z.area = rings.reduce((sum, r) => sum + (r.hole ? -1 : 1) * Math.abs(ringArea(r)), 0);
    z.anchor = anchorOf(z, id);
    if (!z.anchor) continue;
    z.ll = polys.flatMap((p) => p);
    // Each part (a MultiPolygon's polygon: Lucie Stern's wings) with its own courtyards. Heat stays in the part
    // it starts in: wings a metre apart share no air (rasterZone labels cells by part, diffuse.js walks one).
    let k = 0;
    z.parts = polys.map((p) => { const r = rings.slice(k, k + p.length); k += p.length; return { rings: r, ll: p }; });
    const lons = z.ll.flat().map((q) => q[0]), lats = z.ll.flat().map((q) => q[1]);
    z.llBox = [[Math.min(...lats), Math.min(...lons)], [Math.max(...lats), Math.max(...lons)]];
    index.set(id, zones.length);
    zones.push(z);
  }
  return { zones, zoneFor: (b) => index.get(b) ?? -1 };
}

// The zone's cells on a heat grid ({ bounds, nx, ny, cellM, mPerDegLon }) as a patch { x0, y0, w, h, own }, own
// = 1 + the index of the part containing each cell's centre (0 = outside). Cells the outline only grazes are not
// its own (heat would step through them across a gap narrower than a cell); the painter fills them from their
// own neighbours and the clip makes the edge. A building smaller than a cell gets the cells its corners fall in.
// And `cut`: per cell, the links to its neighbours (bits: right, down, down-right, down-left) whose centres a
// wall separates, so heat can't jump a notch narrower than a cell (Lucie Stern's wings are one polygon).
export function rasterZone(z, grid) {
  const { bounds, nx, ny, cellM } = grid, kx = grid.mPerDegLon / cellM, ky = M_PER_DEG_LAT / cellM;
  const toCell = (x, y) => [((z.lon0 + x / z.kx) - bounds.west) * kx, (bounds.north - (z.lat0 + y / M_PER_DEG_LAT)) * ky];
  const [a0, b0] = toCell(z.box[0], z.box[3]), [a1, b1] = toCell(z.box[2], z.box[1]);
  const x0 = Math.max(0, Math.floor(a0)), y0 = Math.max(0, Math.floor(b0)), x1 = Math.min(nx - 1, Math.floor(a1)), y1 = Math.min(ny - 1, Math.floor(b1));
  if (x1 < x0 || y1 < y0) return null;
  const w = x1 - x0 + 1, h = y1 - y0 + 1, own = new Uint16Array(w * h);
  const toLocal = (cx, cy) => [((bounds.west + cx / kx) - z.lon0) * z.kx, ((bounds.north - cy / ky) - z.lat0) * M_PER_DEG_LAT];
  const partAt = (px, py) => z.parts.findIndex((p) => inZone(p, px, py));
  const centre = new Uint8Array(w * h); // 1 = the cell's centre is inside the building
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const [cx, cy] = toLocal(x0 + x + 0.5, y0 + y + 0.5);
    const part = partAt(cx, cy);
    if (part >= 0) { centre[y * w + x] = 1; own[y * w + x] = part + 1; }
  }
  z.parts.forEach((p, k) => { // a part with no cell centre inside (smaller than a cell): its corners' cells
    if (own.includes(k + 1)) return;
    for (const [px, py] of p.rings[0]) {
      const [cx, cy] = toCell(px, py), x = Math.floor(cx) - x0, y = Math.floor(cy) - y0;
      if (x >= 0 && y >= 0 && x < w && y < h && !own[y * w + x]) own[y * w + x] = k + 1;
    }
  });
  // Links between two inside cells whose centres a wall separates (a notch narrower than a cell).
  const cut = new Uint8Array(w * h), LINKS = [[1, 0, 1], [0, 1, 2], [1, 1, 4], [-1, 1, 8]];
  const cross = (ax, ay, bx, by, cx, cy, dx, dy) => {
    const d = (bx - ax) * (dy - cy) - (by - ay) * (dx - cx);
    if (!d) return false;
    const t = ((cx - ax) * (dy - cy) - (cy - ay) * (dx - cx)) / d, u = ((cx - ax) * (by - ay) - (cy - ay) * (bx - ax)) / d;
    return t > 0 && t < 1 && u >= 0 && u <= 1;
  };
  for (const r of z.rings) for (let e = 0; e + 1 < r.length; e++) {
    const [p, q] = [r[e], r[e + 1]], [pa, pb] = toCell(p[0], p[1]), [qa, qb] = toCell(q[0], q[1]);
    const ex0 = Math.max(0, Math.floor(Math.min(pa, qa)) - x0 - 1), ex1 = Math.min(w - 1, Math.floor(Math.max(pa, qa)) - x0 + 1);
    const ey0 = Math.max(0, Math.floor(Math.min(pb, qb)) - y0 - 1), ey1 = Math.min(h - 1, Math.floor(Math.max(pb, qb)) - y0 + 1);
    for (let y = ey0; y <= ey1; y++) for (let x = ex0; x <= ex1; x++) {
      if (!centre[y * w + x]) continue;
      const [ax, ay] = toLocal(x0 + x + 0.5, y0 + y + 0.5);
      for (const [dx, dy, bit] of LINKS) {
        const u = x + dx, v = y + dy;
        if (u < 0 || v < 0 || u >= w || v >= h || !centre[v * w + u]) continue;
        const [bx, by] = toLocal(x0 + u + 0.5, y0 + v + 0.5);
        if (cross(ax, ay, bx, by, p[0], p[1], q[0], q[1])) cut[y * w + x] |= bit;
      }
    }
  }
  return { x0, y0, w, h, own, cut };
}
