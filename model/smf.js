// Simple Mean-Field (SMF) flu probability: Baker et al., PNAS 2021, "Epidemic mitigation by statistical
// inference from contact tracing data" (doi:10.1073/pnas.2106548118), SI Appendix section 3.
// Each person is S, I or R. Their risk is P_I(t), propagated a day at a time with the product form
//   P_S,j(t+1) = P_S,j(t) * prod_k (1 - P_I,k(t) * lambda_kj(t))            (SI eq. 1)
// and recovery P_R += mu * P_I (SI eq. 2). Transmission and recovery depend on the time since infection
// (the paper's non-Markovian case), so I is split into infection-age compartments I[g], g = days.
// lambda for a source at age g over a day's contact rows = 1 - exp(-stage(g) * sum of unit doses).
//
// Observations (SI eqs. 4-6) clamp a person's state: a positive test or symptoms put them in I back to
// tau days before the report, a negative test caps them (=> S), "recovered" moves them to R. As in the
// paper, every output day D is a fresh run over the window [D - tMF, D] from the i.i.d. prior, using only
// evidence known by then, so a report reaches back to the reporter's earlier contacts at the next midnight
// (retroactive tracing) and the output never uses evidence before it was known.
//
// Pair mode (default; our change to the paper): the daily product treats every day with the same person
// as an independent chance, so roommates (16 h/day, every day) compound past P(j was ever infected) and
// the campus total explodes. Instead each source j keeps inf_j[tau] = P(j's infection reached age 0 on
// day tau), and each pair keeps its window-long exposure E_tau = sum over contact rows on day d of
// stage(d - tau) * dose. Then P(j infected i over the window) = A_ji = sum_tau inf_j[tau](1 - exp(-E_tau)),
// one chance per infection of j, and S_i = S_i(0) * prod_j (1 - A_ji) keeps the paper's product across
// different sources. j's infectiousness is stage(age) only; Erlang survival only splits P_I from P_R.
// pairMode: false is the pure per-day SMF above, for comparison.
//
// Cavity (default in pair mode): mean-field lets i's infection, caught from j, flow back to j's remaining S
// and then to i again (echo), so a roommate of a "might be sick" (0.6) person lifted that person to 0.91.
// As in dynamic message passing (Lokhov, Mezard & Zdeborova, PRE 91, 012811 (2015); the Baker SI calls
// SMF its small-lambda limit), the mass j passes to i is inf_j[tau] - rec(j <- i)[tau], where rec is the
// part of j's infection on day tau that came through this pair. Rows are applied one pair at a time, so
// each drop in S has exactly one source. Clamps and community infections are attributed to no one.

import { DEFAULTS, stageFactor } from './infer.js';

export const SMF_DEFAULTS = {
  prior: DEFAULTS.prior,        // P_I at the window start: a few percent of a campus is sick at any time
  priorR: 0,                    // P(already had this season's flu / immune) at the window start
  community: null,              // daily S -> I hazard from off-campus (our addition, not in the paper);
                                //   null = computed so a contact-free campus stays at `prior`
  selfReport: DEFAULTS.selfReport,   // P(flu | "might be sick"): the SI's P(infected | same syndromes)
  reportOther: DEFAULTS.reportOther, // per distinct reporter, noisy-or with the self-report
  posTest: DEFAULTS.posTest,    // P(I | positive), from test sensitivity/specificity (paper's P[O|q])
  negTest: DEFAULTS.negTest,    // P(I | negative) ceiling: false negatives happen
  recoverDays: DEFAULTS.recoverDays, // a "recovered" claim sooner than this after sick evidence is deferred
  stageProfile: DEFAULTS.stageProfile, // infectiousness by days since symptom onset -2..7; incubation is
                                //   ~2 d, so index g = days since infection; peak at g = 2 (Carrat 2008)
  illnessMeanDays: DEFAULTS.illnessMeanDays, illnessShape: DEFAULTS.illnessShape, // Erlang illness length
  ages: 14,                     // G: infection-age compartments (days); everyone left at G-1 recovers
  tauDays: 2,                   // infection -> report/test (flu incubation ~2 d): how far a report reaches back
  windowDays: 10,               // tMF: each day's run starts this many days back, from the prior
  minDelta: 0.005,              // change points are written when P_I moved at least this much
  pairMode: true,               // one chance per infection of the source per pair (see above); false = paper
  cavity: true,                 // pair mode: j's message to i leaves out what j caught from i (DMP cavity)
  doseScale: 1,                 // multiplies every row's unit dose (calibration against the sim; see smf_calibrate)
  probe: null,                  // tests only: probe(phase 'start'|'end', D, d, {S, R, I, pend, G, inf, T, base})
};

const MIN = 60000, DAY = 86400000;
const CAP = 0, RAISE = 1, REC = 2;

// Erlang survival: P(illness lasts longer than t days).
function erlangSurv(t, mean, k) {
  const x = (k / mean) * t;
  let term = 1, sum = 1;
  for (let i = 1; i < k; i++) { term *= x / i; sum += term; }
  return Math.exp(-x) * sum;
}

export function smfRisk(input, params = {}) {
  const P = { ...SMF_DEFAULTS, ...params };
  const { agentIds, startMs, stepMin, nSteps, rows, reports = [] } = input;
  const n = agentIds.length, G = P.ages, tau = P.tauDays, stepMs = stepMin * MIN;
  const nDays = Math.max(1, Math.ceil((nSteps * stepMin) / 1440));
  const dayOf = (t) => Math.floor((t - startMs) / DAY);

  // ---- disease constants: stage(g), removal hazard h[g], prior age mix, community hazard ----
  const st = new Float64Array(G);
  for (let g = 0; g < G; g++) st[g] = stageFactor(g - 2, P.stageProfile) || 0;
  let GS = G; while (GS > 0 && st[GS - 1] === 0) GS--; // ages past the profile do not transmit
  const surv = Array.from({ length: G + 1 }, (_, g) => erlangSurv(g, P.illnessMeanDays, P.illnessShape));
  const h = new Float64Array(G);
  for (let g = 0; g < G; g++) h[g] = g === G - 1 ? 1 : 1 - surv[g + 1] / surv[g];
  let sumSurv = 0;
  for (let g = 0; g < G; g++) sumSurv += surv[g];
  const priorS = 1 - P.prior - P.priorR;
  // stationary: I[g] = prior * Surv(g) / sumSurv, so the daily inflow c * S must equal prior / sumSurv
  const comm = P.community ?? (priorS > 0 ? P.prior / (sumSurv * priorS) : 0);
  const resolved = { ...P, community: comm };

  // ---- evidence per agent: raises {t, L}, negatives [t], recoveries {t, te} ----
  const items = Array.from({ length: n }, () => []);
  const ok = (i) => Number.isInteger(i) && i >= 0 && i < n;
  for (const r of reports) {
    const { tMs: t, agent: a, event: e, value: v, target: tg } = r;
    if (e === 'self_report' && ok(a)) {
      if (v === 'might_be_sick') items[a].push({ t, k: 'sym' });
      else if (v === 'tested_positive') items[a].push({ t, k: 'pos' });
      else if (v === 'recovered') items[a].push({ t, k: 'rec' });
    } else if (e === 'test_result' && ok(a)) {
      if (v === 'positive') items[a].push({ t, k: 'pos' });
      else if (v === 'negative') items[a].push({ t, k: 'neg' });
    } else if (e === 'report_other' && v === 'might_be_sick' && ok(tg) && tg !== a) {
      items[tg].push({ t, k: 'oth', who: a });
    }
  }
  const ev = [];
  for (let i = 0; i < n; i++) {
    if (!items[i].length) continue;
    const raises = [], negs = [], recs = [];
    let pos = false, sym = false, lastSick = -Infinity;
    const who = new Set();
    for (const it of items[i]) {
      if (it.k === 'neg' || it.k === 'rec') {
        if (it.k === 'neg') negs.push(it.t);
        else recs.push({ t: it.t, te: Math.max(it.t, lastSick + P.recoverDays * DAY) });
        pos = sym = false; who.clear(); // a test or recovery starts a new episode
        continue;
      }
      if (it.k === 'pos') pos = true; else if (it.k === 'sym') sym = true; else who.add(it.who);
      const L = pos ? P.posTest : 1 - (sym ? 1 - P.selfReport : 1) * (1 - P.reportOther) ** who.size;
      raises.push({ t: it.t, L });
      lastSick = it.t;
    }
    ev.push({ i, raises, negs, recs });
  }

  // ---- rows: day ranges, and a slot for each unordered pair: per day (paper) or per run (pair mode) ----
  const { t: rt, a: ra, b: rb, dose } = rows;
  const pair = P.pairMode;
  const nRows = rt.length, stepsPerDay = 1440 / stepMin;
  const dayR0 = new Int32Array(nDays + 1), slot = new Int32Array(nRows), daySlots = new Int32Array(nDays);
  {
    let r = 0;
    const m = new Map();
    for (let d = 0; d < nDays; d++) {
      dayR0[d] = r;
      if (!pair) m.clear();
      for (; r < nRows && Math.floor(rt[r] / stepsPerDay) <= d; r++) {
        const a = ra[r], b = rb[r], key = a < b ? a * n + b : b * n + a;
        let s = m.get(key);
        if (s === undefined) { s = m.size; m.set(key, s); }
        slot[r] = s;
      }
      daySlots[d] = m.size;
    }
    dayR0[nDays] = r; // rows past the run are ignored
  }
  let maxSlots = 0;
  for (let d = 0; d < nDays; d++) maxSlots = Math.max(maxSlots, daySlots[d]);
  const sD = new Float64Array(pair ? 0 : maxSlots), sAlo = new Float64Array(maxSlots), sAhi = new Float64Array(maxSlots);
  // pair mode: infection days tau = base .. base + T - 1 with base = w - (G - 1) (the prior's oldest age)
  const T = pair ? P.windowDays + G + 1 : 0;
  const pE = new Float64Array(maxSlots * T), pQ = new Float64Array(maxSlots * T); // E_tau, 1 - exp(-E_tau)
  // cavity: rLo[tau] = lo's infection on day tau attributed to hi, rHi the other way round
  const cav = pair && P.cavity;
  const rLo = new Float64Array(cav ? maxSlots * T : 0), rHi = new Float64Array(cav ? maxSlots * T : 0);
  const pRun = new Int32Array(maxSlots).fill(-1);  // run that last zeroed the slot (lazy reset)

  // ---- state ----
  const I = new Float64Array(n * G), I0 = new Float64Array(n * G);
  const S = new Float64Array(n), R = new Float64Array(n), pend = new Float64Array(n);
  const inf = new Float64Array(n * T), inf0 = new Float64Array(n * T); // pair mode: inf_j[tau], snapshot
  let base = 0, dCur = 0;
  const pI = (i) => { let s = pend[i]; for (let g = 0, o = i * G; g < G; g++) s += I[o + g]; return s; };
  const wI = surv.slice(0, G).map((s) => (P.prior * s) / sumSurv);
  function reset() {
    inf.fill(0);
    for (let i = 0; i < n; i++) {
      S[i] = priorS; R[i] = P.priorR; pend[i] = 0;
      for (let g = 0; g < G; g++) {
        I[i * G + g] = wI[g];
        if (pair) inf[i * T + G - 1 - g] = wI[g]; // prior mass at age g on day w: tau = w - g
      }
    }
  }
  // clamps (SI eqs. 4-6)
  function raise(i, L, g0) { // P_I >= L, new mass at age g0, taken from S and R in proportion
    const p = pI(i), avail = S[i] + R[i];
    if (p >= L || avail <= 0) return;
    const take = Math.min(L - p, avail), f = 1 - take / avail;
    // only the part taken from S is a new infection; mass back from R is already in inf (or was immune)
    if (pair) inf[i * T + dCur - g0 - base] += take * (S[i] / avail);
    S[i] *= f; R[i] *= f; I[i * G + g0] += take;
  }
  function cap(i, L) { // P_I <= L, the removed mass becomes S (tested negative => susceptible)
    const p = pI(i);
    if (p <= L) return;
    const f = L / p;
    for (let g = 0, o = i * G; g < G; g++) {
      if (pair) inf[i * T + dCur - g - base] -= I[o + g] * (1 - f); // removed from current infections only
      I[o + g] *= f;
    }
    pend[i] *= f; S[i] += p - L;
  }
  function recover(i) { // certainly R from here on
    R[i] = 1; S[i] = 0; pend[i] = 0;
    for (let g = 0, o = i * G; g < G; g++) I[o + g] = 0;
  }
  const act = (x) => (x.k === CAP ? cap(x.i, P.negTest) : x.k === RAISE ? raise(x.i, x.L, x.g0) : recover(x.i));
  const lambdaSum = (o, D) => { // A = sum_g I_src[g] * (1 - exp(-stage(g) * D)), source snapshot at offset o
    let A = 0;
    for (let g = 0; g < GS; g++) { const x = I0[o + g]; if (x > 0) A -= x * Math.expm1(-st[g] * D); }
    return A;
  };

  // ---- output ----
  const ch = Array.from({ length: n }, () => []), lastW = new Float64Array(n);
  const note = (i, t) => {
    const p = pI(i);
    if (Math.abs(p - lastW[i]) < P.minDelta) return;
    const c = ch[i], last = c[c.length - 1];
    if (last && last.tMs === t) last.p = p; else c.push({ tMs: t, p });
    lastW[i] = p;
  };
  const daily = [];

  // ---- the causal daily re-run ----
  for (let D = 0; D < nDays; D++) {
    const cut = startMs + D * DAY, endD = cut + DAY, w = Math.max(0, D - P.windowDays);
    const dayAct = Array.from({ length: D - w + 1 }, () => []), timed = Array.from({ length: D - w + 1 }, () => []);
    for (const { i, raises, negs, recs } of ev) {
      for (const { t, te } of recs) {
        if (t >= endD) break;
        if (te < startMs + w * DAY) dayAct[0].push({ k: REC, i, t: -Infinity });
        else if (te < endD) timed[dayOf(te) - w].push({ k: REC, i, t: te });
      }
      for (const tn of negs) {
        if (tn >= endD) break;
        const dn = dayOf(tn);
        if (tn < cut) for (let d = w; d <= dn; d++) dayAct[d - w].push({ k: CAP, i, t: tn });
        // a newer raise reaching back over the test's day wins over it (it is applied after the caps)
        const beaten = tn < cut && raises.some((r) => r.t > tn && r.t < cut && dayOf(r.t) - tau <= dn);
        if (dn >= w && !beaten) timed[dn - w].push({ k: CAP, i, t: tn });
      }
      for (const { t, L } of raises) {
        if (t >= endD) break;
        if (t >= cut) { timed[D - w].push({ k: RAISE, i, t, L, g0: Math.min(tau, G - 1) }); continue; }
        const dr = dayOf(t);
        for (let d = Math.max(w, dr - tau); d <= dr; d++) {
          if (negs.some((tn) => tn > t && tn < cut && dayOf(tn) >= d)) continue; // a newer negative wins
          dayAct[d - w].push({ k: RAISE, i, t, L, g0: Math.min(d - (dr - tau), G - 1) });
        }
      }
    }
    // day start: recoveries, then caps, then raises (each in time order)
    for (const l of dayAct) l.sort((x, y) => (x.k === y.k ? x.t - y.t : x.k === REC ? -1 : y.k === REC ? 1 : x.k - y.k));
    for (const l of timed) l.sort((x, y) => x.t - y.t);

    base = w - (G - 1);
    reset();
    for (let d = w; d <= D; d++) {
      const out = d === D, dMs = startMs + d * DAY;
      dCur = d;
      for (const x of dayAct[d - w]) act(x);
      if (out) for (let i = 0; i < n; i++) {
        if (D === 0) { lastW[i] = pI(i); ch[i].push({ tMs: startMs, p: lastW[i] }); } else note(i, dMs);
      }
      // sources use the day-start state: today's infections transmit from tomorrow
      if (pair) inf0.set(inf); else I0.set(I);
      if (P.probe) P.probe('start', D, d, { S, R, I, pend, G, inf, T, base });
      const acts = timed[d - w], r0 = dayR0[d], r1 = dayR0[d + 1], dk = d - base;
      if (!pair) { sD.fill(0, 0, daySlots[d]); sAlo.fill(0, 0, daySlots[d]); sAhi.fill(0, 0, daySlots[d]); }
      let ai = 0, nextAct = acts.length ? acts[0].t : Infinity;
      for (let r = r0; r < r1; r++) {
        const rowMs = startMs + rt[r] * stepMs;
        while (nextAct <= rowMs) {
          const x = acts[ai++]; act(x); if (out) note(x.i, x.t);
          nextAct = ai < acts.length ? acts[ai].t : Infinity;
        }
        const a = ra[r], b = rb[r];
        if (a === b) continue;
        const lo = a < b ? a : b, hi = a < b ? b : a, s = slot[r];
        let Alo, Ahi;
        const o = s * T, x = dose[r] * P.doseScale;
        if (pair) {
          // window-long exposure per infection day tau; only ages with stage > 0 grow
          if (pRun[s] !== D) {
            pRun[s] = D; pE.fill(0, o, o + T); pQ.fill(0, o, o + T); sAlo[s] = sAhi[s] = 0;
            if (cav) { rLo.fill(0, o, o + T); rHi.fill(0, o, o + T); }
          }
          for (let g = 0; g < GS && g <= dk; g++) {
            const k = o + dk - g, e = pE[k] + st[g] * x;
            pE[k] = e; pQ[k] = -Math.expm1(-e);
          }
          Alo = 0; Ahi = 0;
          if (cav) for (let k = 0, ol = lo * T, oh = hi * T; k <= dk; k++) {
            // cavity: what lo passes to hi leaves out lo's infection that came from hi (and back)
            const q = pQ[o + k];
            if (q > 0) {
              const ml = inf0[ol + k] - rLo[o + k], mh = inf0[oh + k] - rHi[o + k];
              if (ml > 0) Alo += ml * q;
              if (mh > 0) Ahi += mh * q;
            }
          }
          else for (let k = 0, ol = lo * T, oh = hi * T; k <= dk; k++) {
            const q = pQ[o + k];
            if (q > 0) { Alo += inf0[ol + k] * q; Ahi += inf0[oh + k] * q; }
          }
        } else {
          const Dn = sD[s] + x;
          sD[s] = Dn; Alo = lambdaSum(lo * G, Dn); Ahi = lambdaSum(hi * G, Dn);
        }
        // lo -> hi: S_hi *= (1 - A_new) / (1 - A_old); what leaves S is today's infection (pend), infected
        // day tau = d + 1, and with the cavity it is attributed to this source (rHi: hi's mass from lo).
        // A only counts up (a cap on the source later in the window does not hand S back).
        let Ao = sAlo[s];
        if (Alo > Ao && Ao < 1) {
          const s1 = (S[hi] * (1 - Alo)) / (1 - Ao), dS = S[hi] - s1;
          pend[hi] += dS; S[hi] = s1; sAlo[s] = Alo;
          if (cav) rHi[o + dk + 1] += dS;
        }
        Ao = sAhi[s];
        if (Ahi > Ao && Ao < 1) {
          const s1 = (S[lo] * (1 - Ahi)) / (1 - Ao), dS = S[lo] - s1;
          pend[lo] += dS; S[lo] = s1; sAhi[s] = Ahi;
          if (cav) rLo[o + dk + 1] += dS;
        }
        if (out) { note(lo, rowMs); note(hi, rowMs); }
      }
      for (; ai < acts.length; ai++) { act(acts[ai]); if (out) note(acts[ai].i, acts[ai].t); }
      if (P.probe) P.probe('end', D, d, { S, R, I, pend, G, inf, T, base });
      // day end: community infections, then age everyone by a day (SI eq. 2 with mu = h[g])
      for (let i = 0; i < n; i++) {
        const lost = S[i] * comm, o = i * G;
        S[i] -= lost; pend[i] += lost;
        if (pair) inf[i * T + dk + 1] += pend[i]; // infected today: age 0 tomorrow

        for (let g = G - 1; g >= 0; g--) {
          R[i] += I[o + g] * h[g];
          if (g + 1 < G) I[o + g + 1] = I[o + g] * (1 - h[g]);
        }
        I[o] = pend[i]; pend[i] = 0;
      }
    }
    let sumI = 0, sumR = 0, sumS = 0;
    for (let i = 0; i < n; i++) { sumI += pI(i); sumR += R[i]; sumS += S[i]; }
    daily.push({ day: D, tMs: startMs + (D + 1) * DAY, sumI, sumR, sumS });
  }

  const changes = new Map();
  for (let i = 0; i < n; i++) changes.set(agentIds[i], ch[i]);
  function pAt(id, tMs) {
    const c = changes.get(id);
    if (!c || !c.length || tMs < c[0].tMs) return P.prior;
    let lo = 0, hi = c.length - 1;
    while (lo < hi) { const m = (lo + hi + 1) >> 1; if (c[m].tMs <= tMs) lo = m; else hi = m - 1; }
    return c[lo].p;
  }
  return { pAt, changes, daily, params: resolved };
}
