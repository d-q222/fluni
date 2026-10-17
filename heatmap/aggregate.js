// Totals are all the user-facing map may see: for each time step, per building and per room, how
// many people are there and how many of them are expected to be sick (Σ P(sick)). No agent ids,
// positions or properties leave this module.
//
// Buildings are scaled (each simulated agent stands for `scale` people) so the map reads like a full
// campus. Rooms are not scaled: the walk-in warning is about the actual people in that room.

export function buildTotals(frames, times, { scale = 50 } = {}) {
  const steps = frames.map((frame) => {
    const buildings = new Map(), rooms = new Map();
    for (const a of frame) {
      if (!a.buildingId) continue; // outdoors or walking
      add(buildings, a.buildingId, a.building, a.p, scale);
      if (a.room) add(rooms, a.room, a.building, a.p, 1);
    }
    return { buildings, rooms };
  });
  return { times, steps, scale };
}

function add(map, key, name, p, scale) {
  const cur = map.get(key) || { name, n: 0, expected: 0 };
  cur.n += scale;
  cur.expected += scale * p;
  map.set(key, cur);
}

// Totals of the latest step at or before t.
export function totalsAt(totals, t) {
  const { times, steps } = totals;
  let lo = 0, hi = times.length - 1;
  if (t <= times[0]) return steps[0];
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (times[mid] <= t) lo = mid; else hi = mid;
  }
  return steps[times[hi] <= t ? hi : lo];
}

// Fixed colour scale for building fills: 90th percentile of each step's busiest building.
export function buildingScaleMax(totals) {
  const peaks = totals.steps.map((s) => Math.max(0, ...[...s.buildings.values()].map((b) => b.expected))).sort((a, b) => a - b);
  return peaks[Math.floor(0.9 * (peaks.length - 1))] || 1;
}
