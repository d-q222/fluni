// P(flu) for every agent by the mean-field (MF) method of Baker et al., "Epidemic mitigation by
// statistical inference from contact tracing data", PNAS 118 (32) e2106548118 (2021). ES module, no
// dependencies, no DOM; runs in the browser and Node. Same inputs as infer.js, only what a phone could know.
//
// The paper's MF update, for a susceptible i and the people j it met during step t:
//
//   P_S^i(t+1) = P_S^i(t) * prod_j (1 - lambda_{j->i}(t) * P_I^j(t))
//
// Each agent carries a distribution over infection age (time since infection, in steps) instead of a
// single I state, so lambda_{j->i} depends on:
//   - P(j has flu) and j's stage: transmission = sum over ages a of P_j(a) * (1 - exp(-q * stage(a) * D))
//   - P(i has flu): only i's healthy mass P_S^i can be infected
//   - duration, distance, room size, ventilation, indoors/outdoors: D, Rio's dose per quantum
//     (infer.js doseModel: exhaled plume 1/(Q d^2) + Wells-Riley room term 1/(V * loss))
//   - outdoor humidity: that day's weather (config.json) -> indoor RH -> virus decay, part of the room's loss
//   - time since the meeting: infections age one bin per step (latent -> infectious -> over, R)
// Observations constrain the marginals as in the paper: a positive test sets P(infected) = 1 from
// tauPosDays before it, a symptom report (or a report by someone else) does the same weighted by a
// likelihood ratio, a negative test multiplies infected mass by the false-negative rate, "recovered" sets
// P_R = 1. A report reaches back in time, so the model reruns from the earliest step it touches and the
// people the reporter met earlier go up too. Port of exposure/network/mean_field.py (without its cavity
// term, which changed little on the 1,000-agent run).
//
// Besides P, it keeps each agent's expected infectiousness shed_j = sum_a P_j(a) * stage(a), which the
// heat map's risk field uses (heatmap/riskfield.js).

import { doseModel, DEFAULTS as RIO } from './infer.js';

export const MF_DEFAULTS = {
  dtH: 1,                 // MF step, hours
  prior: 0.02,            // P(infected) at the start, ages spread evenly (same as infer.js)
  importPerDay: 0.0005,   // community infection hazard (the paper's self-infection term)
  onsetDays: 2.5,         // infection -> symptom onset (sim influenza: latent 1.5 + presymptomatic 1.0)
  illnessDays: 10,        // infection age after which a case is over (R)
  pAsym: 0.3,             // asymptomatic share ...
  asymRel: 0.5,           // ... at this relative infectiousness
  tauPosDays: 3,          // positive test: infected this long before the result
  tauSymDays: 2.5,        // "might be sick": infected this long before the report (onset now)
  lrSym: 20,              // likelihood ratio of a symptom self-report
  lrOther: 4,             // ... of a report by someone else
  fnr: 0.3,               // negative test: infected mass x false-negative rate
  detectDays: 1,          // a test only sees infections at least this old
  lambdaScale: 0.135,     // dose multiplier, fitted by meanfield-cli.mjs --calibrate on influenza_none_n1000_d14_s42_25fe957a
  checkpointSteps: 6,     // state is saved every this many steps, to rerun from when a report reaches back
};

const HOUR = 3600000, DAY = 86400000;

// Relative infectiousness at an infection age, from infer.js's stageProfile (days -2..7 around onset).
function stageCurve(K, dtDays, P, R) {
  const s = new Float64Array(K), prof = R.stageProfile, asym = 1 - P.pAsym + P.pAsym * P.asymRel;
  for (let k = 0; k < K; k++) {
    const d = (k + 0.5) * dtDays - P.onsetDays + 2; // position on the profile, 0 = day -2
    if (d < 0 || d > prof.length - 1) continue;
    const i = Math.min(prof.length - 2, Math.floor(d)), f = d - i;
    s[k] = (prof[i] + (prof[i + 1] - prof[i]) * f) * asym;
  }
  return s;
}

// input: { contacts, reports, rooms, agentIds, stepMin, startMs, weather?, days? } (as inferRisk; weather is
// config.json params.weather; seeds, for calibration only: ids infected at the start). Returns { pAt, shedAt, shedStep, stepOf, changes, explain: null, flags: [], params }.
export function meanFieldRisk(input, params = {}) {
  const P = { ...MF_DEFAULTS, ...params }, R = { ...RIO, ...params };
  const { agentIds, stepMin, startMs } = input;
  const N = agentIds.length, idx = new Map(agentIds.map((id, i) => [id, i]));
  const dtMs = P.dtH * HOUR, dtDays = P.dtH / 24, W = Math.max(1, Math.round((P.dtH * 60) / stepMin)); // sim steps per MF step
  const K = Math.max(1, Math.round(P.illnessDays / dtDays));
  const stage = stageCurve(K, dtDays, P, R);
  const contacts = input.contacts || [], reports = input.reports || [];
  let lastSimStep = 0;
  for (const c of contacts) if (+c.t > lastSimStep) lastSimStep = +c.t;
  for (const r of reports) if (+r.t > lastSimStep) lastSimStep = +r.t;
  const nSteps = input.days ? Math.ceil((input.days * 24) / P.dtH) : Math.floor(lastSimStep / W) + 1;

  // Outdoor humidity by sim day -> one dose model per distinct weather (indoor RH and virus decay differ).
  const w = input.weather || {}, daily = w.daily || [];
  const doseByKey = new Map();
  const doseForDay = (day) => {
    const o = daily.length ? daily[Math.min(day, daily.length - 1)] : {};
    const rh = o.outdoor_rh_pct ?? w.outdoor_rh_pct ?? R.outdoorRH, tc = o.outdoor_temp_c ?? w.outdoor_temp_c ?? R.outdoorTempC;
    const key = `${rh}:${tc}`;
    if (!doseByKey.has(key)) doseByKey.set(key, doseModel({ ...params, outdoorRH: rh, outdoorTempC: tc, indoorTempC: w.indoor_temp_c ?? R.indoorTempC }, input.rooms || null));
    return doseByKey.get(key);
  };

  // Contacts -> dose per quantum D, summed per unordered pair and MF step (Poisson doses add up).
  const agg = Array.from({ length: nSteps }, () => new Map());
  const stepsPerDay = 1440 / stepMin;
  for (const c of contacts) {
    const t = +c.t, n = Math.floor(t / W);
    if (n >= nSteps) continue;
    let a = idx.get(c.agent_a), b = idx.get(c.agent_b);
    if (a === undefined || b === undefined || a === b) continue;
    const unit = doseForDay(Math.floor(t / stepsPerDay))(c); // quanta * B * h * (plume + room); 0 through a wall
    if (!(unit > 0)) continue;
    if (a > b) [a, b] = [b, a];
    const k = a * N + b, m = agg[n];
    m.set(k, (m.get(k) || 0) + unit / R.quantaPeak); // per quantum, so lambda = 1 - exp(-q * stage * D)
  }
  const pairs = agg.map((m) => {
    if (!m.size) return null;
    const a = new Int32Array(m.size), b = new Int32Array(m.size), D = new Float64Array(m.size);
    let i = 0;
    for (const [k, d] of m) { a[i] = Math.floor(k / N); b[i] = k % N; D[i] = d; i++; }
    return { a, b, D };
  });

  // Reports and tests -> observations, at the MF step the app learns them.
  const obs = Array.from({ length: nSteps }, () => []);
  for (const r of reports) {
    const n = Math.floor(+r.t / W);
    if (n >= nSteps) continue;
    const ev = r.event, val = r.value;
    let kind = null, who = r.agent_id;
    if ((ev === 'test_result' && val === 'positive') || (ev === 'self_report' && val === 'tested_positive')) kind = 'pos';
    else if (ev === 'test_result' && val === 'negative') kind = 'neg';
    else if (ev === 'self_report' && val === 'might_be_sick') kind = 'sym';
    else if (ev === 'self_report' && val === 'recovered') kind = 'rec';
    else if (ev === 'report_other' && val === 'might_be_sick') { kind = 'other'; who = r.target_agent_id; }
    if (kind && idx.has(who)) obs[n].push([kind, idx.get(who)]);
  }

  // ---------- dynamics ----------
  const q = R.quantaPeak * P.lambdaScale;
  const hImp = -Math.log1p(-P.importPerDay * dtDays);
  const kDet = Math.round(P.detectDays / dtDays);
  const fresh = () => {
    const S = new Float64Array(N).fill(1 - P.prior), A = new Float64Array(N * K).fill(P.prior / K), Rr = new Float64Array(N);
    for (const id of input.seeds || []) { // calibration only: known cases, just infected at the start
      const i = idx.get(id);
      if (i === undefined) continue;
      S[i] = 0; A.fill(0, i * K, i * K + K); A[i * K] = 1;
    }
    return { S, A, R: Rr };
  };
  const copy = (s) => ({ S: s.S.slice(), A: s.A.slice(), R: s.R.slice() });
  const logq = new Float64Array(N);

  function applyClamp(c, st) {
    const { S, A, R: Rr } = st, i = c[1], o = i * K;
    if (c[0] === 'infect') { // (1 - w) * current + w * infected at age k0
      const k0 = c[2], wgt = c[3];
      S[i] *= 1 - wgt; Rr[i] *= 1 - wgt;
      for (let k = 0; k < K; k++) A[o + k] *= 1 - wgt;
      if (k0 < K) A[o + k0] += wgt; else Rr[i] += wgt;
    } else if (c[0] === 'neg') { // likelihood of a negative test
      for (let k = kDet; k < K; k++) A[o + k] *= P.fnr;
      let z = S[i] + Rr[i];
      for (let k = 0; k < K; k++) z += A[o + k];
      S[i] /= z; Rr[i] /= z;
      for (let k = 0; k < K; k++) A[o + k] /= z;
    } else if (c[0] === 'rec') { // P_R = 1 from now on
      for (let k = 0; k < K; k++) { Rr[i] += A[o + k]; A[o + k] = 0; }
    }
  }

  // An observation learned in step n -> [effect step, clamp].
  function clampFor(kind, i, n, st) {
    if (kind === 'neg' || kind === 'rec') return [n, [kind, i]];
    const back = Math.round((kind === 'pos' ? P.tauPosDays : P.tauSymDays) / dtDays);
    let sEff = n - back, k0 = 0;
    if (sEff < 0) { k0 = -sEff; sEff = 0; }
    let wgt = 1;
    if (kind !== 'pos') {
      const lr = kind === 'sym' ? P.lrSym : P.lrOther, p = Math.max(1 - st.S[i] - st.R[i], P.prior);
      wgt = (lr * p) / (lr * p + 1 - p);
    }
    return [sEff, ['infect', i, k0, wgt]];
  }

  // One MF step, in place: clamps, then P_S <- P_S * prod_j (1 - T_{j->i}) * exp(-import), then ageing.
  function step(s, st, clamps) {
    for (const c of clamps.get(s) || []) applyClamp(c, st);
    const { S, A, R: Rr } = st;
    logq.fill(-hImp);
    const pr = pairs[s];
    if (pr) {
      for (let p = 0; p < pr.D.length; p++) {
        const a = pr.a[p], b = pr.b[p], x = q * pr.D[p], oa = a * K, ob = b * K;
        let tab = 0, tba = 0; // T[a->b], T[b->a]: sum over the source's ages of P(age) * lambda(age)
        for (let k = 0; k < K; k++) {
          if (!stage[k]) continue;
          const e = -Math.expm1(-x * stage[k]);
          tab += A[oa + k] * e; tba += A[ob + k] * e;
        }
        logq[b] += Math.log1p(-Math.min(tab, 1 - 1e-12));
        logq[a] += Math.log1p(-Math.min(tba, 1 - 1e-12));
      }
    }
    for (let i = 0; i < N; i++) {
      const o = i * K, nw = S[i] * -Math.expm1(logq[i]);
      Rr[i] += A[o + K - 1];
      A.copyWithin(o + 1, o, o + K - 1);
      A[o] = nw;
      S[i] -= nw;
    }
  }

  // Online pass: at each step add what was learned; if it reaches back, rerun from the nearest checkpoint.
  // Rows of pNow/shed are what the app would show at the end of each step.
  const pNow = new Float32Array(nSteps * N), shed = new Float32Array(nSteps * N);
  const clamps = new Map(), ckpt = new Map(), CK = P.checkpointSteps;
  const keepBack = Math.round(Math.max(P.tauPosDays, P.tauSymDays) / dtDays) + CK;
  let st = fresh();
  for (let n = 0; n < nSteps; n++) {
    if (n % CK === 0) {
      ckpt.set(n, copy(st));
      for (const k of ckpt.keys()) if (k < n - keepBack) ckpt.delete(k);
    }
    let earliest = n;
    for (const [kind, i] of obs[n]) {
      const [sEff, c] = clampFor(kind, i, n, st);
      if (!clamps.has(sEff)) clamps.set(sEff, []);
      clamps.get(sEff).push(c);
      if (sEff < earliest) earliest = sEff;
    }
    if (earliest < n) { // rerun from the checkpoint at or before the earliest step touched
      const c0 = Math.floor(earliest / CK) * CK;
      st = copy(ckpt.get(c0) || fresh());
      for (let s = c0; s < n; s++) {
        if (s % CK === 0 && s > c0) ckpt.set(s, copy(st));
        step(s, st, clamps);
      }
      if (n % CK === 0) ckpt.set(n, copy(st)); // the one saved above predates the rerun
    }
    step(n, st, clamps);
    const row = n * N;
    for (let i = 0; i < N; i++) {
      let pa = 0, sh = 0;
      for (let k = i * K, e = k + K, a = 0; k < e; k++, a++) { pa += st.A[k]; sh += st.A[k] * stage[a]; }
      pNow[row + i] = pa;
      shed[row + i] = sh;
    }
  }

  // P at t: as known at the end of the step before t's (a report shows within one step).
  const stepOf = (tMs) => Math.min(nSteps, Math.floor((tMs - startMs) / dtMs)) - 1;
  const pAt = (id, tMs) => {
    const i = idx.get(id), n = stepOf(tMs);
    return i === undefined || n < 0 ? P.prior : pNow[n * N + i];
  };
  const shedPrior = (P.prior / K) * stage.reduce((s, x) => s + x, 0);
  const shedAt = (id, tMs) => {
    const i = idx.get(id), n = stepOf(tMs);
    return i === undefined ? 0 : n < 0 ? shedPrior : shed[n * N + i];
  };
  // Everyone's shed at once (indexed like agentIds), for the risk field's per-frame loop.
  const shedStep = (tMs) => { const n = stepOf(tMs); return n < 0 ? null : shed.subarray(n * N, n * N + N); };

  const changes = new Map();
  for (let i = 0; i < N; i++) {
    let last = P.prior, list = null;
    for (let n = 0; n < nSteps; n++) {
      const p = pNow[n * N + i];
      if (Math.abs(p - last) < R.minDelta) continue;
      (list ||= []).push({ tMs: startMs + (n + 1) * dtMs, p });
      last = p;
    }
    if (list) changes.set(agentIds[i], list);
  }
  let ever = 0;
  for (let i = 0; i < N; i++) ever += 1 - st.S[i];
  return {
    expectedInfections: ever, // sum over agents of P(ever infected) by the end
    pAt, shedAt, shedStep, stepOf, index: idx, changes, explain: null, flags: [],
    params: { ...R, ...P, method: 'meanfield' },
    field: { q, breathingRate: R.breathingRate, nearFieldQ: R.nearFieldQ, outdoorNearDilution: R.outdoorNearDilution, quietQuanta: R.quietQuanta / R.quantaPeak },
  };
}
