// Predictive mode: expected sick people per building at +1/+2/+3 h, with an 80% range, plus a backtest.
// Each agent's habits (which building at which 30-min slot of the day) come from the other days of the
// timeline; multiplied by the app's current P(sick) for that agent and summed per building. Each simulated
// agent stands for `scale` people, so counts are a sum of binomials. The target day is excluded from the
// habits, and only the belief at the forecast time is used, so a forecast never peeks at its answer.

const Z80 = 1.2816; // two-sided 80% normal quantile
const HOUR_MS = 3_600_000;

const dayKey = (d) => d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();

export function buildForecaster(frames, times, { scale = 50, slotMin = 30 } = {}) {
  const n = times.length;
  const nSlots = Math.ceil(1440 / slotMin);
  const slotOf = (d) => Math.floor((d.getHours() * 60 + d.getMinutes()) / slotMin);
  const names = new Map(); // buildingId -> display name

  // per-agent series by frame index: bid[k] (undefined = no sample), p[k]
  const agents = new Map();
  frames.forEach((frame, k) => {
    for (const a of frame) {
      let s = agents.get(a.id);
      if (!s) agents.set(a.id, (s = { bid: new Array(n), p: new Array(n), cell: new Map() }));
      const b = a.buildingId ?? null;
      s.bid[k] = b;
      s.p[k] = a.p;
      if (b != null && a.building && !names.has(b)) names.set(b, a.building);
      // tally this sample into its (day, slot) cell
      const d = new Date(times[k]);
      const key = dayKey(d) * 1000 + slotOf(d);
      let c = s.cell.get(key);
      if (!c) s.cell.set(key, (c = new Map()));
      c.set(b, (c.get(b) || 0) + 1);
    }
  });

  // habits: per agent and slot, how many days in each building, and each day's choice
  for (const s of agents.values()) {
    s.count = Array.from({ length: nSlots }, () => new Map());
    s.total = new Array(nSlots).fill(0);
    s.dayBid = Array.from({ length: nSlots }, () => new Map());
    for (const [key, c] of s.cell) {
      const day = Math.floor(key / 1000), slot = key % 1000;
      let best = null, bestN = -1;
      for (const [b, m] of c) if (m > bestN) { best = b; bestN = m; }
      s.count[slot].set(best, (s.count[slot].get(best) || 0) + 1);
      s.total[slot]++;
      s.dayBid[slot].set(day, best);
    }
    delete s.cell;
  }

  // last frame index with times[k] <= t (-1 if none)
  const floorIdx = (t) => {
    let lo = 0, hi = n - 1, r = -1;
    while (lo <= hi) {
      const m = (lo + hi) >> 1;
      if (times[m] <= t) { r = m; lo = m + 1; } else hi = m - 1;
    }
    return r;
  };
  const nearestIdx = (t) => {
    const k = floorIdx(t);
    if (k < 0) return 0;
    return k + 1 < n && times[k + 1] - t < t - times[k] ? k + 1 : k;
  };
  // latest sample of an agent at or before frame k
  const lastSeen = (s, k) => {
    for (; k >= 0; k--) if (s.bid[k] !== undefined) return k;
    return -1;
  };

  function forecast(tMs, horizonMin) {
    const T = new Date(tMs + horizonMin * 60000);
    const slot = slotOf(T), dT = dayKey(T);
    const kNow = floorIdx(tMs);
    const sum = new Map(); // buildingId -> [Σq, Σq(1−q)]
    const add = (b, q) => {
      if (!(q > 0)) return;
      let v = sum.get(b);
      if (!v) sum.set(b, (v = [0, 0]));
      v[0] += q;
      v[1] += q * (1 - q);
    };
    for (const s of agents.values()) {
      const k = lastSeen(s, kNow);
      if (k < 0) continue;
      const p = s.p[k];
      // habits from days other than the target day
      const own = s.dayBid[slot].get(dT);
      const days = s.total[slot] - (own !== undefined ? 1 : 0);
      if (days > 0) {
        for (const [b, c] of s.count[slot]) {
          const cnt = c - (own !== undefined && own === b ? 1 : 0);
          if (b != null && cnt > 0) add(b, (cnt / days) * p);
        }
      } else if (s.bid[k] != null) {
        add(s.bid[k], p); // no history: assume they stay where they are
      }
    }
    const out = new Map();
    for (const [b, [q, v]] of sum) {
      const expected = scale * q, sd = Math.sqrt(scale * v);
      out.set(b, {
        name: names.get(b) ?? b,
        expected,
        lo: Math.max(0, expected - Z80 * sd),
        hi: expected + Z80 * sd,
      });
    }
    return out;
  }

  // roll forward hourly; how often does the actual count fall inside the 80% range?
  function backtest(horizonMin) {
    let covered = 0, total = 0;
    const last = times[n - 1];
    let next = times[0];
    for (let i = 0; i < n; i++) {
      const t = times[i];
      if (t < next) continue;
      next = t + HOUR_MS;
      const T = t + horizonMin * 60000;
      if (T > last) break;
      const fc = forecast(t, horizonMin);
      const kT = nearestIdx(T);
      const actual = new Map();
      for (const s of agents.values()) {
        const b = s.bid[kT];
        if (b != null) actual.set(b, (actual.get(b) || 0) + scale * s.p[kT]);
      }
      for (const b of new Set([...fc.keys(), ...actual.keys()])) {
        const f = fc.get(b), a = actual.get(b) || 0;
        total++;
        if (f && f.lo <= a && a <= f.hi) covered++;
        else if (!f && a === 0) covered++;
      }
    }
    return { covered, total, rate: total ? covered / total : 0 };
  }

  return { forecast, backtest };
}
