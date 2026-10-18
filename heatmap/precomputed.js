// Big runs (thousands of agents) read precomputed files instead of computing in the browser:
// - model/out/<run>/p_sick.csv (docs/p-sick-format.md): the model's P(sick), instead of downloading
//   tens of millions of contacts and running model/infer.js in the page.
// - totals.json.gz next to the timeline (tools/precompute.mjs): the user map's per-step building totals,
//   hourly forecasts and backtest, instead of expanding every agent at every step.
// Both return the same shapes app.js gets from the in-browser versions; null when the file is missing.

import { loadCsv } from './loader.js';

const PRIOR = 0.02; // P before an agent's first change point (docs/p-sick-format.md)

// A stand-in for inferRisk()'s result with pAt only: no explain() ("Why this %?") and no flags.
export async function loadPSick(url) {
  try {
    const { data } = await loadCsv(url, ['agent_id', 't_iso', 'p_sick']);
    const changes = new Map(); // id -> { t: Float64Array, p: Float32Array }, rows are sorted by agent, time
    for (let k = 0; k < data.length;) {
      const id = data[k].agent_id;
      let j = k;
      while (j < data.length && data[j].agent_id === id) j++;
      const t = new Float64Array(j - k), p = new Float32Array(j - k);
      for (let i = k; i < j; i++) { t[i - k] = Date.parse(data[i].t_iso); p[i - k] = Number(data[i].p_sick); }
      changes.set(id, { t, p });
      k = j;
    }
    const pAt = (id, tMs) => {
      const c = changes.get(id);
      if (!c || tMs < c.t[0]) return PRIOR;
      let lo = 0, hi = c.t.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (c.t[mid] <= tMs) lo = mid; else hi = mid - 1;
      }
      return c.p[lo];
    };
    return { pAt, explain: null, flags: [], params: { prior: PRIOR } };
  } catch {
    return null;
  }
}

// totals.json.gz -> { totals, forecaster } shaped like aggregate.js buildTotals() / forecast.js.
// Rooms aren't in the file (the phone's walk-in warning uses building totals).
export async function loadTotals(url) {
  let j;
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const body = res.headers.get('content-encoding') ? res.body : res.body.pipeThrough(new DecompressionStream('gzip'));
    j = await new Response(body).json();
  } catch {
    return null;
  }
  const b = j.buildings;
  const times = Array.from({ length: j.nSteps }, (_, k) => j.startMs + k * j.stepMs);
  // r[3] / forecast x[4]: expected sick above the prior (the colour); older files lack it.
  const steps = j.steps.map((rows) => ({
    buildings: new Map(rows.map(([i, n, expected, excess = expected]) => [b[i].id, { name: b[i].name, n, expected, excess }])),
    rooms: new Map(),
  }));
  // Forecasts are hourly: use the latest one made at or before t.
  const at = j.forecast.at;
  const forecast = (tMs, h) => {
    let lo = 0, hi = at.length - 1;
    if (!at.length || tMs < at[0].tMs) return new Map();
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (at[mid].tMs <= tMs) lo = mid; else hi = mid - 1;
    }
    const rows = at[lo].byHorizon[h] || [];
    return new Map(rows.map(([i, expected, lo80, hi80, excess = expected]) => [b[i].id, { name: b[i].name, expected, excess, lo: lo80, hi: hi80 }]));
  };
  const backtest = (h) => ({ rate: j.backtest[h] ?? NaN });
  return { totals: { times, steps, scale: j.scale }, forecaster: { forecast, backtest } };
}

// close_minutes.csv.gz (tools/precompute.mjs): raw minutes within 6 ft of anyone, per agent and hour since the
// run start. Returns (id, tMs) => minutes in the 24 h before tMs, or null when the file is missing.
// Approximation: whole hours inside the window are exact; the hour containing tMs counts by the elapsed
// fraction f of that hour, and the hour 24 h earlier by the remaining 1 - f (minutes assumed spread evenly in an hour).
export async function loadCloseMinutes(url, startMs) {
  const HOUR = 3600000;
  let rows;
  try { rows = (await loadCsv(url, ['agent_id', 'hour', 'minutes'])).data; } catch { return null; }
  if (!rows.length) return null;
  const by = new Map(); // id -> Map(hour -> minutes)
  for (const r of rows) {
    if (!by.has(r.agent_id)) by.set(r.agent_id, new Map());
    by.get(r.agent_id).set(Number(r.hour), Number(r.minutes));
  }
  return (id, tMs) => {
    const m = by.get(id);
    if (!m) return 0;
    const x = (tMs - startMs) / HOUR, h = Math.floor(x), f = x - h;
    let sum = (m.get(h) || 0) * f + (m.get(h - 24) || 0) * (1 - f);
    for (let k = h - 23; k < h; k++) sum += m.get(k) || 0;
    return sum;
  };
}
