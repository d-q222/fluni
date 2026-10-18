// Smooth agent movement between timeline samples. An agent stays put, then walks the campus footpath
// network to its next place, leaving when its previous activity ends. Samples that are already close
// together in time (fine-grained data) are interpolated directly, since they trace the path themselves.

const WALK_MPS = 1.35;          // typical walking speed
const SHORT_GAP_MS = 120_000;   // samples ≤ 2 min apart: straight interpolation
const SAME_PLACE_M = 15;        // closer than this counts as staying in place
const M_PER_DEG_LAT = 110574;

const mPerDegLon = (lat) => 111320 * Math.cos((lat * Math.PI) / 180);
const distM = (lat1, lon1, lat2, lon2) =>
  Math.hypot((lat2 - lat1) * M_PER_DEG_LAT, (lon2 - lon1) * mPerDegLon(lat1));
const ease = (u) => u * u * (3 - 2 * u); // gentle start and stop

// ---------- footpath router (A* over the OSM walkway graph) ----------

export class Router {
  constructor({ nodes, edges }) {
    this.lat = Float64Array.from(nodes, (n) => n[0]);
    this.lon = Float64Array.from(nodes, (n) => n[1]);
    this.adj = nodes.map(() => []);
    for (const [i, j] of edges) {
      const d = distM(this.lat[i], this.lon[i], this.lat[j], this.lon[j]);
      this.adj[i].push(j, d);
      this.adj[j].push(i, d);
    }
    // Bucket nodes on a ~50 m grid for nearest-node lookups.
    this.grid = new Map();
    for (let i = 0; i < nodes.length; i++) {
      const k = this.key(this.lat[i], this.lon[i]);
      if (!this.grid.has(k)) this.grid.set(k, []);
      this.grid.get(k).push(i);
    }
    this.cache = new Map();
  }

  key(lat, lon) { return `${Math.floor(lat * 2000)},${Math.floor(lon * 2000)}`; }

  nearest(lat, lon) {
    let best = -1, bestD = Infinity;
    for (let r = 1; r <= 6 && best < 0; r++) {
      const cy = Math.floor(lat * 2000), cx = Math.floor(lon * 2000);
      for (let y = cy - r; y <= cy + r; y++) for (let x = cx - r; x <= cx + r; x++) {
        for (const i of this.grid.get(`${y},${x}`) || []) {
          const d = distM(lat, lon, this.lat[i], this.lon[i]);
          if (d < bestD) { bestD = d; best = i; }
        }
      }
    }
    return best;
  }

  // Polyline from (lat1, lon1) to (lat2, lon2) along footpaths, with cumulative distances.
  route(lat1, lon1, lat2, lon2) {
    const a = this.nearest(lat1, lon1), b = this.nearest(lat2, lon2);
    const k = `${a}>${b}`;
    if (!this.cache.has(k)) this.cache.set(k, a < 0 || b < 0 ? [] : this.astar(a, b));
    const pts = [[lat1, lon1], ...this.cache.get(k).map((i) => [this.lat[i], this.lon[i]]), [lat2, lon2]];
    const cum = [0];
    for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + distM(...pts[i - 1], ...pts[i]));
    return { pts, cum, length: cum[cum.length - 1] };
  }

  astar(start, goal) {
    const h = (i) => distM(this.lat[i], this.lon[i], this.lat[goal], this.lon[goal]);
    const g = new Map([[start, 0]]), prev = new Map();
    const heap = new MinHeap();
    heap.push(h(start), start);
    while (heap.size) {
      const cur = heap.pop();
      if (cur === goal) break;
      const adj = this.adj[cur];
      for (let n = 0; n < adj.length; n += 2) {
        const next = adj[n], cost = g.get(cur) + adj[n + 1];
        if (cost < (g.get(next) ?? Infinity)) {
          g.set(next, cost);
          prev.set(next, cur);
          heap.push(cost + h(next), next);
        }
      }
    }
    if (!prev.has(goal) && start !== goal) return []; // disconnected: walk straight
    const path = [goal];
    while (path[0] !== start) path.unshift(prev.get(path[0]));
    return path;
  }
}

class MinHeap {
  constructor() { this.f = []; this.v = []; }
  get size() { return this.v.length; }
  push(f, v) {
    let i = this.v.length;
    this.f.push(f); this.v.push(v);
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (this.f[p] <= this.f[i]) break;
      [this.f[p], this.f[i]] = [this.f[i], this.f[p]];
      [this.v[p], this.v[i]] = [this.v[i], this.v[p]];
      i = p;
    }
  }
  pop() {
    const top = this.v[0], lastF = this.f.pop(), lastV = this.v.pop();
    if (this.v.length) {
      this.f[0] = lastF; this.v[0] = lastV;
      let i = 0;
      for (;;) {
        const l = 2 * i + 1, r = l + 1;
        let m = i;
        if (l < this.v.length && this.f[l] < this.f[m]) m = l;
        if (r < this.v.length && this.f[r] < this.f[m]) m = r;
        if (m === i) break;
        [this.f[m], this.f[i]] = [this.f[i], this.f[m]];
        [this.v[m], this.v[i]] = [this.v[i], this.v[m]];
        i = m;
      }
    }
    return top;
  }
}

function pointAlong({ pts, cum, length }, d) {
  if (d <= 0 || length === 0) return pts[0];
  if (d >= length) return pts[pts.length - 1];
  let i = 1;
  while (cum[i] < d) i++;
  const f = (d - cum[i - 1]) / (cum[i] - cum[i - 1]);
  return [pts[i - 1][0] + f * (pts[i][0] - pts[i - 1][0]), pts[i - 1][1] + f * (pts[i][1] - pts[i - 1][1])];
}

// ---------- the sim's own routes (trips.csv.gz) ----------
// Mirrors sim/campussim/viewer_template.html: a trip covers steps [t_start-1, t_end]. During the first
// step the agent goes in a line from the room spot to the door (0 -> start_m metres); after that it is
// start_m + speed*(step - t_start) metres along the path, clamped at the end. Later trips win on overlap.

const KY_SIM = 110540;

// rows: trips.csv.gz rows. Returns Map agent_id -> trips sorted by t_start, each with
// { ts, te, sm, v (metres per step), mode, xs, ys, cum (Float64Array, metres), len }.
export function buildTrips(rows, { startMs, stepMs, originLat = 37.418 }) {
  const kx = 111320 * Math.cos((originLat * Math.PI) / 180);
  const byAgent = new Map();
  for (const r of rows) {
    const pts = r.path ? r.path.split(';') : [];
    const n = pts.length;
    if (n < 2) continue;
    const xs = new Float64Array(n), ys = new Float64Array(n), cum = new Float64Array(n);
    for (let q = 0; q < n; q++) {
      const sp = pts[q].indexOf(' ');
      xs[q] = +pts[q].slice(0, sp); ys[q] = +pts[q].slice(sp + 1);
      if (q) cum[q] = cum[q - 1] + Math.hypot((xs[q] - xs[q - 1]) * kx, (ys[q] - ys[q - 1]) * KY_SIM);
    }
    const trip = {
      ts: +r.t_start, te: +r.t_end, sm: +r.start_m || 0, v: +r.speed_mps * (stepMs / 1000),
      mode: r.mode, xs, ys, cum, len: cum[n - 1],
    };
    if (!byAgent.has(r.agent_id)) byAgent.set(r.agent_id, []);
    byAgent.get(r.agent_id).push(trip);
  }
  for (const list of byAgent.values()) list.sort((a, b) => a.ts - b.ts);
  return { byAgent, startMs, stepMs };
}

// Hands each track its agent's trips (tracks are arrays; this only adds properties).
export function attachTrips(tracks, trips) {
  for (const [id, track] of tracks) {
    track.trips = trips.byAgent.get(id) || null;
    track.tripHint = 0;
    track.tripStartMs = trips.startMs;
    track.tripStepMs = trips.stepMs;
  }
}

// Latest trip of the track's agent covering continuous step tau, or null. Checks the cached index first.
function tripAt(track, tau) {
  const L = track.trips;
  const h = track.tripHint;
  if (h < L.length && L[h].ts - 1 <= tau && tau <= L[h].te && (h + 1 >= L.length || L[h + 1].ts - 1 > tau)) return L[h];
  let lo = 0, hi = L.length - 1, best = -1;
  while (lo <= hi) { const m = (lo + hi) >> 1; if (L[m].ts - 1 <= tau) { best = m; lo = m + 1; } else hi = m - 1; }
  for (let j = best; j >= 0 && j > best - 4; j--) if (tau <= L[j].te) { track.tripHint = j; return L[j]; }
  return null;
}

// Distance along the trip at step tau (metres).
const tripDist = (t, tau) => (tau < t.ts ? t.sm * (tau - t.ts + 1) : Math.min(t.len, t.sm + t.v * (tau - t.ts)));

// ---------- tracks ----------

// samples: [{ t (ms), id, lat, lon, p, sick, building, floor, room, moving }] → Map id → time-sorted samples
export function buildTracks(samples) {
  const tracks = new Map();
  for (const s of samples) {
    if (!tracks.has(s.id)) tracks.set(s.id, []);
    tracks.get(s.id).push(s);
  }
  for (const tr of tracks.values()) tr.sort((a, b) => a.t - b.t);
  return tracks;
}

// The latest sample at or before t (no interpolation), or null outside the track's data.
export function sampleAt(track, t) {
  if (!track.length || t < track[0].t || t > track[track.length - 1].t) return null;
  let lo = 0, hi = track.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (track[mid].t <= t) lo = mid; else hi = mid - 1;
  }
  return track[lo];
}

// Where an agent is at time t (ms), or null outside its data. Walking agents have no building/room.
export function stateAt(track, t, router) {
  if (!track.length || t < track[0].t || t > track[track.length - 1].t) return null;
  let lo = 0, hi = track.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (track[mid].t <= t) lo = mid; else hi = mid;
  }
  const a = track[lo], b = track[hi];
  const dt = b.t - a.t;
  const f = dt > 0 ? (t - a.t) / dt : 0;
  const base = { id: a.id, p: a.p + f * (b.p - a.p), sick: f < 1 ? a.sick : b.sick, infectious: f < 1 ? a.infectious : b.infectious };

  // The sim's logged route, when one covers this moment: position exactly as the sim computes it.
  if (track.trips) {
    const tau = (t - track.tripStartMs) / track.tripStepMs;
    const trip = tripAt(track, tau);
    if (trip) {
      const d = tripDist(trip, tau), c = trip.cum;
      let i = 0, j = c.length - 1;
      while (j - i > 1) { const m = (i + j) >> 1; if (c[m] <= d) i = m; else j = m; }
      const seg = c[j] - c[i], u = seg > 0 ? Math.max(0, Math.min(1, (d - c[i]) / seg)) : 0;
      const lon = trip.xs[i] + u * (trip.xs[j] - trip.xs[i]), lat = trip.ys[i] + u * (trip.ys[j] - trip.ys[i]);
      if (d < trip.len || tau < trip.ts) {
        return { ...base, lat, lon, building: null, buildingId: null, floor: null, room: null, walking: true, mode: trip.mode };
      }
      const s = f < 0.5 ? a : b; // arrived: standing at the in-room spot
      return { ...base, lat, lon, building: s.building, buildingId: s.buildingId, floor: s.floor, room: s.room, walking: false };
    }
  }
  const at = (s) => ({
    ...base, lat: s.lat, lon: s.lon, building: s.building, buildingId: s.buildingId, floor: s.floor, room: s.room, walking: false,
  });

  // Samples the data marks as in transit already trace the route: glide through them at constant speed.
  if (a !== b && (a.moving || b.moving)) {
    return {
      ...base, lat: a.lat + f * (b.lat - a.lat), lon: a.lon + f * (b.lon - a.lon),
      building: null, buildingId: null, floor: null, room: null, walking: true,
    };
  }

  if (a === b || distM(a.lat, a.lon, b.lat, b.lon) < SAME_PLACE_M || dt <= SHORT_GAP_MS) {
    const near = f < 0.5 ? a : b;
    return { ...at(near), lat: a.lat + f * (b.lat - a.lat), lon: a.lon + f * (b.lon - a.lon) };
  }

  // A move between places: leave at a.t, walk the footpaths, then wait at b until b.t.
  if (!a.walk) a.walk = router ? router.route(a.lat, a.lon, b.lat, b.lon) : null;
  const length = a.walk ? a.walk.length : distM(a.lat, a.lon, b.lat, b.lon);
  const walkMs = Math.min(dt, (length / WALK_MPS) * 1000);
  const u = (t - a.t) / walkMs;
  if (u >= 1) return at(b);
  const [lat, lon] = a.walk
    ? pointAlong(a.walk, ease(u) * length)
    : [a.lat + ease(u) * (b.lat - a.lat), a.lon + ease(u) * (b.lon - a.lon)];
  return { ...base, lat, lon, building: null, buildingId: null, floor: null, room: null, walking: true };
}
