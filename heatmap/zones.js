// Heat zones: the walls heat may not pass. Each of the sim's rooms (map/rooms.csv), clipped to its building's
// drawn footprint, is a zone; a person's heat stays in their zone (diffuse.js spreads it cell to cell through
// the zone only), their dot sits inside it (seats.js) and the presenter draws its outline close up.
// Rooms that lie mostly outside their footprint (the sim lays procedural rooms out in a line) share the
// footprint by a Voronoi split around anchors inside it. A building with no rooms is one zone.
// Pure data in, plain objects out; no DOM. Shared by app.js and seats.js.

import { wktGeometry } from './footprints.js';

const M_PER_DEG_LAT = 110574;
const FIT = 0.5;  // a room at least this much inside its footprint keeps its own walls; else the Voronoi fallback
const SAMPLE = 7; // grid of candidate anchors per side

function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

// Sutherland-Hodgman: keep the part of ring (closed, [x, y]) where a·x + b·y <= c.
function clipHalf(ring, a, b, c) {
  const pts = ring.slice(0, -1), out = [];
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i], q = pts[(i + 1) % pts.length];
    const fp = a * p[0] + b * p[1] - c, fq = a * q[0] + b * q[1] - c;
    if (fp <= 0) out.push(p);
    if ((fp <= 0) !== (fq <= 0)) { const t = fp / (fp - fq); out.push([p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])]); }
  }
  return out.length >= 3 ? [...out, out[0]] : null;
}
const clipAll = (ring, halves) => halves.reduce((r, [a, b, c]) => r && clipHalf(r, a, b, c), ring);
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
function wallDist(z, x, y) {
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
// rooms: rows with room_id, location_id, polygon_wkt, capacity (map/rooms.csv), or [].
// Returns { zones, zoneFor(buildingId, roomId) -> index or -1, fallback: rooms on the Voronoi fallback }.
// A zone: { id, building, rings (local metres), box, anchor, area, capacity, ll (rings as [lon, lat]), lon0, lat0, kx }.
export function buildZones(outlines, rooms = []) {
  const zones = [], index = new Map(), feet = new Map();
  for (const f of outlines?.features || []) {
    const id = `bld_${String(f.properties.id).split('/').pop()}`, g = f.geometry;
    const polys = g?.type === 'Polygon' ? [g.coordinates] : g?.type === 'MultiPolygon' ? g.coordinates : [];
    if (feet.has(id) || !polys.length) continue;
    const [lon0, lat0] = polys[0][0][0], kx = 111320 * Math.cos((lat0 * Math.PI) / 180);
    const local = polys.map((p) => p.map((r) => r.map(([lon, lat]) => [(lon - lon0) * kx, (lat - lat0) * M_PER_DEG_LAT])));
    feet.set(id, { lon0, lat0, kx, polys: local });
  }
  const byB = new Map();
  for (const r of rooms) if (r.room_id && r.location_id && feet.has(r.location_id)) {
    if (!byB.has(r.location_id)) byB.set(r.location_id, []);
    byB.get(r.location_id).push(r);
  }
  const add = (b, id, rings, ft, capacity, floor = 1) => {
    const z = { id, building: b, rings, box: boxOf(rings), lon0: ft.lon0, lat0: ft.lat0, kx: ft.kx, capacity };
    z.area = areaOf(rings);
    z.anchor = anchorOf(z, id);
    if (!z.anchor) return;
    z.ll = rings.map((r) => r.map(([x, y]) => [ft.lon0 + x / ft.kx, ft.lat0 + y / M_PER_DEG_LAT]));
    const lons = z.ll.flat().map((q) => q[0]), lats = z.ll.flat().map((q) => q[1]);
    z.llBox = [[Math.min(...lats), Math.min(...lons)], [Math.max(...lats), Math.max(...lons)]];
    z.floor = floor;
    index.set(`${b}|${id}`, zones.length);
    zones.push(z);
  };
  // Every ring of a footprint (outer rings and courtyards) clipped to some half-planes; holes flagged.
  const clipFoot = (ft, halves) => ft.polys.flatMap((p) => p.map((r, k) => { const c = clipAll(r, halves); if (c) c.hole = k > 0; return c; }).filter(Boolean));
  const areaOf = (rings) => rings.reduce((s, r) => s + (r.hole ? -1 : 1) * Math.abs(ringArea(r)), 0);
  let fallback = 0;
  for (const [b, ft] of feet) {
    const list = byB.get(b) || [], loose = [];
    for (const r of list) {
      let rect;
      try { rect = wktGeometry(r.polygon_wkt).coordinates[0].map(([lon, lat]) => [(lon - ft.lon0) * ft.kx, (lat - ft.lat0) * M_PER_DEG_LAT]); } catch { loose.push(r); continue; }
      const [x0, y0, x1, y1] = boxOf([rect]);
      const rings = clipFoot(ft, [[-1, 0, -x0], [1, 0, x1], [0, -1, -y0], [0, 1, y1]]);
      const share = areaOf(rings) / Math.max(1e-6, (x1 - x0) * (y1 - y0));
      if (rings.length && share >= FIT) add(b, r.room_id, rings, ft, Number(r.capacity) || 0, Number(r.floor) || 1);
      else loose.push(r);
    }
    if (!list.length) { add(b, '', clipFoot(ft, []), ft, 0); continue; } // no rooms: the building is one zone
    fallback += loose.length;
    // Voronoi among the loose rooms, around anchors spread over the footprint.
    const whole = { rings: clipFoot(ft, []) };
    whole.box = boxOf(whole.rings);
    const seeds = loose.map((r) => anchorOf(whole, r.room_id) || [(whole.box[0] + whole.box[2]) / 2, (whole.box[1] + whole.box[3]) / 2]);
    loose.forEach((r, i) => {
      const halves = [];
      seeds.forEach((s, j) => {
        if (j === i || (s[0] === seeds[i][0] && s[1] === seeds[i][1])) return;
        const [ax, ay] = seeds[i], [bx, by] = s; // closer to a than b: (b - a)·p <= (|b|² - |a|²) / 2
        halves.push([bx - ax, by - ay, (bx * bx + by * by - ax * ax - ay * ay) / 2]);
      });
      add(b, r.room_id, clipFoot(ft, halves), ft, Number(r.capacity) || 0, Number(r.floor) || 1);
    });
  }
  // Walls drawn close up are each building's lowest floor (upper floors would draw over it).
  const ground = new Map();
  for (const z of zones) ground.set(z.building, Math.min(ground.get(z.building) ?? Infinity, z.floor));
  for (const z of zones) z.ground = z.floor === ground.get(z.building);
  const zoneFor = (b, room) => index.get(`${b}|${room || ''}`) ?? index.get(`${b}|`) ?? -1;
  return { zones, zoneFor, fallback };
}

// The zone's cells on a heat grid ({ bounds, nx, ny, cellM, mPerDegLon }): every cell the zone touches (3 x 3
// samples per cell, plus the cells its corners fall in), as a patch { x0, y0, w, h, own: Uint8Array(w*h) }.
export function rasterZone(z, grid) {
  const { bounds, nx, ny, cellM } = grid, kx = grid.mPerDegLon / cellM, ky = M_PER_DEG_LAT / cellM;
  const toCell = (x, y) => [((z.lon0 + x / z.kx) - bounds.west) * kx, (bounds.north - (z.lat0 + y / M_PER_DEG_LAT)) * ky];
  const [a0, b0] = toCell(z.box[0], z.box[3]), [a1, b1] = toCell(z.box[2], z.box[1]);
  const x0 = Math.max(0, Math.floor(a0)), y0 = Math.max(0, Math.floor(b0)), x1 = Math.min(nx - 1, Math.floor(a1)), y1 = Math.min(ny - 1, Math.floor(b1));
  if (x1 < x0 || y1 < y0) return null;
  const w = x1 - x0 + 1, h = y1 - y0 + 1, own = new Uint8Array(w * h);
  const toLocal = (cx, cy) => [((bounds.west + cx / kx) - z.lon0) * z.kx, ((bounds.north - cy / ky) - z.lat0) * M_PER_DEG_LAT];
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let hit = false;
    for (let s = 0; s < 9 && !hit; s++) { const [px, py] = toLocal(x0 + x + ((s % 3) + 0.5) / 3, y0 + y + (Math.floor(s / 3) + 0.5) / 3); hit = inZone(z, px, py); }
    if (hit) own[y * w + x] = 1;
  }
  for (const r of z.rings) for (const [px, py] of r) {
    const [cx, cy] = toCell(px, py), x = Math.floor(cx) - x0, y = Math.floor(cy) - y0;
    if (x >= 0 && y >= 0 && x < w && y < h) own[y * w + x] = 1;
  }
  return { x0, y0, w, h, own };
}
