// Where a seated person's dot is drawn. The sim seats people along room rows and lays procedural rooms
// out in a line across a building, sometimes past its real outline, so dots stood in long rows. For
// display only, everyone indoors and not moving sits at a stable spot INSIDE their room's walls: the sim's
// room clipped to the building's drawn footprint (a zone, zones.js), and its occupants fill a sunflower
// (Vogel) spiral of seats around the zone's anchor, each starting from a seat chosen by a hash of agent +
// zone. Seats are spaced for the room's capacity, so dots don't stack. The person's zone goes on the state
// (s.zone): their heat stays in it (diffuse.js). A seat depends only on who is in the room at that moment, so nothing jitters over time.
// People standing at one of the sim's outdoor places (Lake Lagunita, White Plaza, the Oval, ...) are drawn on
// the nearest footpath (the run's map/paths.geojson) instead: the sim puts them anywhere in the place's box,
// which for the lake is in the water. Each picks a point along the path near them by a hash, so they don't stack.
// The sim's own position stays on the state as simLat/simLon (the phone's distance checks use it).

import { inZone } from './zones.js';

const M_PER_DEG_LAT = 110574;
const SEAT_M = 1.4;          // spiral constant: neighbouring seats sit ~1.8 × this apart
const GOLDEN = Math.PI * (3 - Math.sqrt(5));
const DEFAULT_ROOM_M2 = 40;  // rooms without an outline in map/rooms.csv
const STEPS = [7, 11, 13, 17, 19, 23]; // probe strides; the first one coprime with the seat count is used

// FNV-1a: a stable 32-bit hash of a string.
function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
function rng(seed) { // mulberry32
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function inRing(x, y, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
const PATH_STEP_M = 3, PATH_CELL_M = 30, PATH_NEAR_M = 60, PATH_FAR_M = 300;

// Points every PATH_STEP_M along the footpaths, bucketed in a PATH_CELL_M grid: nearest(lat, lon, id) picks
// a point on the path closest to (lat, lon), among those within a few metres of the closest, by a hash of id.
// water: polygons (GeoJSON geometries) no one is put in, e.g. Lake Lagunita's box (paths cross the dry lake bed).
function pathIndex(paths, water = []) {
  const pts = [], cells = new Map();
  const lat0 = 37.43, kx = 111320 * Math.cos((lat0 * Math.PI) / 180), ky = M_PER_DEG_LAT;
  const wet = water.flatMap((g) => (g.type === 'Polygon' ? [g.coordinates[0]] : g.coordinates.map((p) => p[0])))
    .map((ring) => ring.map(([lon, lat]) => [lon * kx, lat * ky]));
  const cellOf = (x, y) => `${Math.floor(x / PATH_CELL_M)},${Math.floor(y / PATH_CELL_M)}`;
  const add = (x, y) => {
    if (wet.some((ring) => inRing(x, y, ring))) return;
    const c = cellOf(x, y); if (!cells.has(c)) cells.set(c, []); cells.get(c).push(pts.length); pts.push([x, y]);
  };
  for (const f of paths?.features || []) {
    const g = f.geometry, lines = g?.type === 'LineString' ? [g.coordinates] : g?.type === 'MultiLineString' ? g.coordinates : [];
    for (const line of lines) {
      for (let i = 0; i + 1 < line.length; i++) {
        const ax = line[i][0] * kx, ay = line[i][1] * ky, bx = line[i + 1][0] * kx, by = line[i + 1][1] * ky;
        const n = Math.max(1, Math.ceil(Math.hypot(bx - ax, by - ay) / PATH_STEP_M));
        for (let k = 0; k < n; k++) add(ax + ((bx - ax) * k) / n, ay + ((by - ay) * k) / n);
      }
    }
  }
  if (!pts.length) return null;
  function within(x, y, r) {
    const out = [], c0 = Math.floor((x - r) / PATH_CELL_M), c1 = Math.floor((x + r) / PATH_CELL_M);
    const d0 = Math.floor((y - r) / PATH_CELL_M), d1 = Math.floor((y + r) / PATH_CELL_M);
    for (let cx = c0; cx <= c1; cx++) for (let cy = d0; cy <= d1; cy++) {
      for (const i of cells.get(`${cx},${cy}`) || []) { const d = Math.hypot(pts[i][0] - x, pts[i][1] - y); if (d <= r) out.push([d, i]); }
    }
    return out;
  }
  return (lat, lon, id) => {
    const x = lon * kx, y = lat * ky;
    let near = within(x, y, PATH_NEAR_M);
    if (!near.length) near = within(x, y, PATH_FAR_M); // never left standing in the lake
    if (!near.length) return null;
    const best = Math.min(...near.map((n) => n[0]));
    const pick = near.filter((n) => n[0] <= best + 12).sort((a, b) => a[1] - b[1]); // a stretch of path near them
    const [, i] = pick[hash(id) % pick.length];
    return [pts[i][1] / ky, pts[i][0] / kx];
  };
}

// outlines: the drawn GeoJSON (properties.id 'run/<id>' ↔ building 'bld_<id>', as masks.js keys them).
// roomArea(roomId): floor area in m², or undefined. paths: the run's footpaths (GeoJSON), or null.
// water: geometries to keep people out of.
export function makeSeats(Z, paths = null, water = []) {
  const onPath = pathIndex(paths, water), spots = new Map(); // id|sim position -> [lat, lon] on a path
  const rooms = new Map(); // zone index -> { seats: [[lat, lon], ...] inside the zone, n: preferred range }

  // A zone's seats: a sunflower spiral around its anchor, keeping only points inside the zone (its walls),
  // spaced for its capacity so a full dorm room still fits its people.
  function roomFor(zi) {
    if (rooms.has(zi)) return rooms.get(zi);
    const z = Z.zones[zi];
    let r = null;
    if (z) {
      const area = z.area || DEFAULT_ROOM_M2;
      const step = Math.min(SEAT_M, Math.max(0.45, 0.6 * Math.sqrt(area / Math.max(1, z.capacity || area / 6))));
      const spread = Math.min(12, Math.max(1.5, 0.5 * Math.sqrt(area)));
      const [ax, ay] = z.anchor, phase = rng(hash(z.id + z.building))() * 2 * Math.PI, seats = [];
      for (let k = 0; seats.length < 400 && k < 4000; k++) {
        const rad = step * Math.sqrt(k + 0.5), th = phase + k * GOLDEN;
        const x = ax + rad * Math.cos(th), y = ay + rad * Math.sin(th);
        if (inZone(z, x, y)) seats.push([z.lat0 + y / M_PER_DEG_LAT, z.lon0 + x / z.kx]);
      }
      if (!seats.length) seats.push([z.lat0 + ay / M_PER_DEG_LAT, z.lon0 + ax / z.kx]);
      r = { seats, n: Math.max(Math.min(seats.length, z.capacity || 0), Math.min(seats.length, Math.floor((spread / step) ** 2))) || 1 };
    }
    rooms.set(zi, r);
    return r;
  }

  // Moves every seated indoor state to its seat (in place). Walkers and outdoor people keep their route.
  function place(states) {
    const groups = new Map();
    for (const s of states) {
      if (!s.walking && !s.buildingId && s.room && onPath) { // standing at an outdoor place
        const k = `${s.id}|${s.lat}|${s.lon}`;
        if (!spots.has(k)) spots.set(k, onPath(s.lat, s.lon, `${s.id}|${s.room}`));
        const p = spots.get(k);
        if (p) { s.simLat = s.lat; s.simLon = s.lon; [s.lat, s.lon] = p; }
        continue;
      }
      if (s.walking || !s.buildingId) continue;
      const zi = Z.zoneFor(s.buildingId, s.room);
      s.zone = zi;
      const r = zi >= 0 ? roomFor(zi) : null;
      if (!r || !r.seats.length) continue;
      const key = `z${zi}`;
      if (!groups.has(key)) groups.set(key, { r, list: [] });
      groups.get(key).list.push({ s, h: hash(`${s.id}|${key}`) });
    }
    for (const { r, list } of groups.values()) {
      // In a fixed order (by the hash), each takes the first free seat along its own probe sequence. An
      // arrival can only bump people after it in that order, so a room doesn't reshuffle when someone
      // comes or goes.
      list.sort((a, b) => a.h - b.h || (a.s.id < b.s.id ? -1 : 1));
      const taken = new Uint8Array(r.seats.length);
      const probe = (h, n) => { // first free seat among the first n, along this person's own stride
        const step = STEPS.find((p) => n % p) || 1;
        for (let i = 0; i < n; i++) { const j = (h + i * step) % n; if (!taken[j]) return j; }
        return -1;
      };
      for (const { s, h } of list) {
        let k = probe(h, r.n);
        if (k < 0) k = probe(h, r.seats.length); // a crowd past the room's own ring: further out
        if (k < 0) k = h % r.seats.length;       // fuller than the building: share
        taken[k] = 1;
        s.simLat = s.lat; s.simLon = s.lon;
        [s.lat, s.lon] = r.seats[k];
      }
    }
    return states;
  }
  return { place };
}
