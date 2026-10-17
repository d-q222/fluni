// Infection probability model: P(person is infected right now), from what a phone app could know.
// Inputs are phone-detected contacts, self-reports, reports about others and test results. Never the
// simulator's disease state. One chronological pass over contacts and reports.
//
// Evidence about a person j (self-report, report by others, test) gives j a "source risk" s_j.
// Each contact with j then exposes the other person i with transmission pi = 1 - exp(-beta*w*min),
// where w falls with distance tier, and i's risk grows as 1 - (1-x_i)(1-s_j*pi). A report also looks
// back over j's recent contacts, since it makes them informative after the fact.
//
// No feedback loop: only evidence creates risk. Second-hand risk (what j caught from a source) is
// passed on at damped strength alpha, read from j's state just before the contact, and never passed
// on again. So risk flows downstream only, and two people in constant contact cannot lift each other.

export const DEFAULTS = {
  prior: 0.02,            // community baseline: a few percent of a campus is sick at any time
  selfReport: 0.6,        // "might be sick" is a symptom guess, often wrong
  reportOther: 0.35,      // second-hand and may be mistaken or malicious: weaker than a self-report
  unsupportedWeight: 0.5, // a report with no contact reporter -> target in 48 h counts half
  posTest: 0.97,          // test sensitivity/specificity: positives are almost always real
  negTest: 0.05,          // a negative caps risk (false negatives happen); also lifts no one else
  evidenceDays: 7,        // a flu episode lasts about a week; older evidence says nothing about now
  negTestDays: 3,         // a negative test only vouches for a few days
  beta: 0.015,            // per weighted minute: 15 min under 1 m gives 20%, 15 min at 1-2 m gives 13%
  tierWeight: [1, 0.6, 0.1, 0.02], // <1 m, 1-2 m, 2-5 m, same room >=5 m (droplets fall off fast)
  lookbackDays: 3,        // a report makes contacts up to this long before it informative
  contagiousBeforeH: 24,  // sick people spread ~1 day before symptoms; contacts earlier than this
  earlyWeight: 0.15,       //   count at this fraction of the source risk
  alpha: 0.25,            // damping of second-hand risk
  alphaCap: 0.4,          // second-hand source risk never reads more than alpha * this
  xMax: 0.3,              // household flu attack rates are 10-40%: contact alone never exceeds this
  xiMax: 0.08,           // second-hand risk ceiling
  decayAfterDays: 2,      // exposure risk holds through the incubation window ...
  halfLifeDays: 3,        // ... then halves every 3 days with no new evidence
  fillHours: 6,           // decay/expiry change points are written at most this often
  minDelta: 0.01,         // changes smaller than this are not written (keeps change lists compact)
  mergeGapMin: 30,        // contacts with one person this close in time form one explain() entry
  contribMin: 0.001,      // explain() skips contributions that moved p less than this
  unexpectedBelow: 0.05,  // flag a "might be sick" self-report when the model gave less than this
  highP: 0.5,             // flag silent_high_risk above this ...
  highHours: 24,          // ... for longer than this, with no report or test of their own
  recoverDays: 3,         // a "recovered" claim sooner than this after a sick report/positive is not believed
  unsupportedHours: 48,   // report_other needs a reporter -> target contact within this window
};

const MIN = 60000, HOUR = 3600000, DAY = 86400000;
const LN2 = Math.LN2;

export function inferRisk(input, params = {}) {
  const P = { ...DEFAULTS, ...params };
  const { agentIds, stepMin, startMs } = input;
  const stepMs = stepMin * MIN;
  const n = agentIds.length;
  const idx = new Map(agentIds.map((id, i) => [id, i]));
  const evMs = P.evidenceDays * DAY, negMs = P.negTestDays * DAY, fillMs = P.fillHours * HOUR;
  const halfMs = P.halfLifeDays * DAY, decayAfter = P.decayAfterDays * DAY;
  const L = Math.round((P.lookbackDays * DAY) / stepMs);        // lookback, in steps
  const unsupSteps = Math.round((P.unsupportedHours * HOUR) / stepMs);
  const keep = Math.max(L, unsupSteps);                          // contact history kept per agent
  const earlySteps = Math.round((P.contagiousBeforeH * HOUR) / stepMs);
  const mergeMs = P.mergeGapMin * MIN;

  // exposure risk: xd from sources with evidence, xi second-hand; both decay with the same clock
  const xd = new Float64Array(n), xi = new Float64Array(n);
  const xT = new Float64Array(n).fill(startMs);       // time the stored x values are valid for
  const dF = new Float64Array(n).fill(-Infinity);     // decay starts here (last new exposure + 2 d)
  const stepT = new Float64Array(n).fill(-1);         // snapshot so same-step contacts read "before"
  const xdPrev = new Float64Array(n);
  const lastT = new Float64Array(n).fill(startMs), lastP = new Float64Array(n).fill(P.prior);
  const lastEvT = new Float64Array(n).fill(-Infinity);
  const hiSince = new Float64Array(n).fill(-1), hiFlagged = new Uint8Array(n);
  const ev = new Array(n).fill(null);                 // own/other evidence about each agent
  const chT = new Array(n).fill(null), chP = new Array(n).fill(null); // change points
  const contribs = new Array(n).fill(null), open = new Array(n).fill(null);
  const flags = [];

  // recent contacts per agent: Int32 triples [step, other, durS*8 + tier], oldest first
  const cb = new Array(n).fill(null), ch = new Int32Array(n), cn = new Int32Array(n);
  function pushContact(i, t, o, pk) {
    let b = cb[i], h = ch[i], m = cn[i];
    if (!b) b = cb[i] = new Int32Array(48);
    while (h < m && b[h] < t - keep) h += 3;
    if (m + 3 > b.length) {
      const live = m - h;
      if (h >= live) b.copyWithin(0, h, m);
      else { const nb = new Int32Array(b.length * 2); nb.set(b.subarray(h, m)); b = cb[i] = nb; }
      m = live; h = 0;
    }
    b[m] = t; b[m + 1] = o; b[m + 2] = pk;
    ch[i] = h; cn[i] = m + 3;
  }
  const lamOf = (pk) => P.beta * P.tierWeight[pk & 7] * (pk >> 3) / 60; // beta * w * minutes

  // ---------- evidence ----------

  const newEv = () => ({
    selfT: -Infinity, selfL: 0, posT: -Infinity, negT: -Infinity,
    rep: new Map(), log: [], lvl: 0, cap: 1, own: false, pos: false,
    recT: -Infinity, recEff: Infinity, // a recovery claim at recT takes effect from recEff
  });
  const getEv = (i) => ev[i] || (ev[i] = newEv());

  // Evidence level at time t: sets e.lvl (lifted risk), e.cap (ceiling) and e.own (self-evidence).
  function evEval(e, t) {
    const negOn = t - e.negT < negMs;
    const rc = t >= e.recEff ? e.recT : -Infinity; // evidence at or before an accepted recovery is void
    e.pos = t - e.posT < evMs && e.posT >= e.negT && e.posT > rc;
    e.own = e.pos;
    if (e.pos) { e.cap = 1; return (e.lvl = P.posTest); }
    const counts = (T) => t - T < evMs && T > rc && (T > e.negT || !negOn); // newer than a negative test
    let q = 1;
    if (counts(e.selfT)) { q *= 1 - e.selfL; e.own = true; }
    for (const r of e.rep.values()) if (counts(r.t)) q *= 1 - r.l;
    e.lvl = 1 - q;
    e.cap = negOn && e.lvl === 0 ? P.negTest : 1;
    return e.lvl;
  }

  // ---------- risk state ----------

  const fac = (i, t) => {
    const dt = t - Math.max(xT[i], dF[i]);
    return dt > 0 ? Math.exp((-LN2 * dt) / halfMs) : 1;
  };
  let lastOwn = false;
  function pOf(i, t) {
    const f = fac(i, t);
    const xt = 1 - (1 - xd[i] * f) * (1 - xi[i] * f);
    let p = 1 - (1 - P.prior) * (1 - xt);
    const e = ev[i];
    lastOwn = false;
    if (e) {
      const l = evEval(e, t);
      lastOwn = e.own;
      if (e.pos) p = l; else if (l > p) p = l;
      if (e.cap < p) p = e.cap;
    }
    return p;
  }

  function pushChange(i, t, p, force) {
    if (!force && Math.abs(p - lastP[i]) < P.minDelta) return;
    if (!chT[i]) { chT[i] = []; chP[i] = []; }
    const k = chT[i].length - 1;
    if (k >= 0 && chT[i][k] === t) chP[i][k] = p; else { chT[i].push(t); chP[i].push(p); }
    lastP[i] = p;
  }

  // silent_high_risk: exposure alone keeps p high for a long time
  function watchHigh(i, t, p) {
    if (p > P.highP && !lastOwn) {
      if (hiSince[i] < 0) hiSince[i] = t;
      else if (!hiFlagged[i] && t - hiSince[i] > P.highHours * HOUR) {
        hiFlagged[i] = 1;
        flags.push({ agentId: agentIds[i], tMs: t, kind: 'silent_high_risk',
          detail: `p=${p.toFixed(2)} since ${Math.round((t - hiSince[i]) / HOUR)} h ago, no self-report or test` });
      }
    } else { hiSince[i] = -1; hiFlagged[i] = 0; }
  }

  const active = (i, t) => (xd[i] + xi[i]) * fac(i, t) > 1e-4 || (ev[i] !== null && t - lastEvT[i] < evMs + DAY);

  // Write decay / expiry change points for the quiet stretch (lastT, t).
  function fill(i, t) {
    let u = lastT[i] + fillMs;
    while (u < t && active(i, u)) {
      const p = pOf(i, u);
      watchHigh(i, u, p);
      pushChange(i, u, p, false);
      u += fillMs;
    }
    if (t > lastT[i]) lastT[i] = t;
  }
  function settle(i, t, force) {
    fill(i, t);
    const p = pOf(i, t);
    watchHigh(i, t, p);
    pushChange(i, t, p, force);
  }

  // Move stored x to time t (apply decay) and take the before-this-step snapshot of xd.
  function touch(i, t) {
    fill(i, t); // write decay points for the past first: state is about to change
    const f = fac(i, t);
    if (f < 1) { xd[i] *= f; xi[i] *= f; }
    xT[i] = t;
    if (stepT[i] !== t) { stepT[i] = t; xdPrev[i] = xd[i]; }
  }

  // Source risk of j at time t: s1 from its own evidence, else s2 = damped second-hand risk.
  let s1 = 0, s2 = 0;
  function source(j, t) {
    s1 = 0; s2 = 0;
    const e = ev[j];
    if (e) { s1 = evEval(e, t); if (e.cap < 1) return; }
    if (s1 > 0) return;
    const x = stepT[j] === t ? xdPrev[j] : xd[j] * fac(j, t);
    if (x > 0.005) s2 = P.alpha * Math.min(x, P.alphaCap);
  }

  // Expose i to j: nowMs = when i learns it, cMs = when the contact happened, sOld = already applied.
  function expose(i, j, nowMs, cMs, lam, tier, durMin, a1, a2, sOld) {
    touch(i, nowMs);
    const before = 1 - (1 - xd[i]) * (1 - xi[i]);
    const pi = 1 - Math.exp(-lam);
    if (a1 > 0) xd[i] = Math.min(P.xMax, 1 - (1 - xd[i]) * (1 - pi * a1) / (1 - pi * sOld));
    if (a2 > 0) xi[i] = Math.min(P.xiMax, 1 - (1 - xi[i]) * (1 - pi * a2));
    dF[i] = Math.max(dF[i], nowMs + decayAfter);
    const delta = 1 - (1 - xd[i]) * (1 - xi[i]) - before;
    if (delta >= P.contribMin) addContrib(i, j, cMs, nowMs, tier, durMin, pi, Math.max(a1, a2), delta, nowMs !== cMs);
  }

  // learnedMs = when the app knew about this contribution (later than the contact for retro ones), so
  // explain() never shows risk that wasn't known yet. Only entries learned together are merged.
  function addContrib(i, j, cMs, learnedMs, tier, durMin, pi, risk, delta, retro) {
    const m = open[i] || (open[i] = new Map()), list = contribs[i] || (contribs[i] = []);
    let c = m.get(j);
    const sameBatch = c && c.retro === retro && (retro ? c.learnedMs === learnedMs : true);
    if (sameBatch && cMs - c.tMs <= mergeMs && cMs >= c.tMs) {
      if (!retro) c.learnedMs = learnedMs;
      c.tMs = cMs; c.durationMin += durMin; c.delta += delta;
      c.transmission = 1 - (1 - c.transmission) * (1 - pi);
      if (tier < c.distanceTier) c.distanceTier = tier;
      if (risk > c.otherRisk) c.otherRisk = risk;
      return;
    }
    c = { tMs: cMs, learnedMs, other: agentIds[j], distanceTier: tier, durationMin: durMin, transmission: pi,
      otherRisk: risk, delta, retro };
    m.set(j, c); list.push(c);
    if (list.length > 128) { // keep the 64 most influential
      list.sort((a, b) => b.delta - a.delta);
      list.length = 64;
    }
  }

  // ---------- reports ----------

  // Evidence about j just rose from eOld to eNew: re-examine j's recent contacts.
  const mark = new Int32Array(n);
  let markId = 0;
  function lookBack(j, step, nowMs, eNew, eOld) {
    const b = cb[j];
    if (!b) return;
    const touched = [];
    markId++;
    for (let k = ch[j]; k < cn[j]; k += 3) {
      const t = b[k];
      if (t >= step) break;
      if (t < step - L) continue;
      const w = t >= step - earlySteps ? 1 : P.earlyWeight;
      const i = b[k + 1], pk = b[k + 2], tier = (pk & 7) + 1;
      expose(i, j, nowMs, startMs + t * stepMs, lamOf(pk), tier, (pk >> 3) / 60, eNew * w, 0, eOld * w);
      if (mark[i] !== markId) { mark[i] = markId; touched.push(i); }
    }
    for (const i of touched) settle(i, nowMs, false);
  }

  function hadContact(a, b, fromStep, toStep) {
    const buf = cb[a];
    if (!buf) return false;
    for (let k = ch[a]; k < cn[a]; k += 3) if (buf[k + 1] === b && buf[k] >= fromStep && buf[k] <= toStep) return true;
    return false;
  }

  function onReport(r) {
    const tMs = startMs + r.t * stepMs;
    const who = idx.get(r.agent_id);
    if (who === undefined) return;
    let subject = who, kind = r.event, by = null, level = 0;
    if (r.event === 'report_other') {
      const target = idx.get(r.target_agent_id);
      if (target === undefined || target === who || r.value !== 'might_be_sick') return;
      subject = target; by = r.agent_id;
    } else if (r.event === 'self_report') {
      if (r.value !== 'might_be_sick' && r.value !== 'tested_positive' && r.value !== 'recovered') return;
    } else if (r.event === 'test_result') {
      if (r.value !== 'positive' && r.value !== 'negative') return;
    } else return;

    const e = getEv(subject);
    fill(subject, tMs);
    const eOld = evEval(e, tMs);
    if (r.event === 'self_report' && r.value === 'might_be_sick') {
      const p = pOf(subject, tMs);
      if (!lastOwn && p < P.unexpectedBelow) {
        flags.push({ agentId: r.agent_id, tMs, kind: 'unexpected_report',
          detail: `self-reported might_be_sick but model p=${p.toFixed(3)}: false report or unseen source` });
      }
    }
    if (r.event === 'report_other') {
      const supported = hadContact(who, subject, r.t - unsupSteps, r.t);
      if (!supported) {
        flags.push({ agentId: r.agent_id, tMs, kind: 'report_other_unsupported',
          detail: `reported ${r.target_agent_id} with no contact in the previous ${P.unsupportedHours} h` });
      }
      level = P.reportOther * (supported ? 1 : P.unsupportedWeight);
      e.rep.set(who, { t: tMs, l: level });
    } else if (r.event === 'self_report') {
      if (r.value === 'might_be_sick') { e.selfT = tMs; e.selfL = level = P.selfReport; }
      else if (r.value === 'tested_positive') { e.posT = tMs; level = P.posTest; }
      else { // recovered
        const sick = Math.max(e.selfT, e.posT);
        if (tMs - sick < P.recoverDays * DAY) { // too soon: evidence stays until recEff, then it is void
          e.recT = tMs; e.recEff = sick + P.recoverDays * DAY;
          flags.push({ agentId: r.agent_id, tMs, kind: 'suspicious_recovery',
            detail: `claimed recovered ${((tMs - sick) / HOUR).toFixed(0)} h after reporting sick; not believed until ${P.recoverDays} d` });
        } else { // believed: clear everything
          e.selfT = e.posT = e.negT = -Infinity; e.rep.clear();
          touch(subject, tMs); xd[subject] = 0; xi[subject] = 0;
        }
      }
    } else if (r.value === 'positive') { e.posT = tMs; level = P.posTest; }
    else { e.negT = tMs; level = P.negTest; }
    e.log.push({ tMs, kind, value: r.value, by, level });
    lastEvT[subject] = tMs;
    const eNew = evEval(e, tMs);
    if (eNew > eOld + 1e-9) lookBack(subject, r.t, tMs, eNew, eOld);
    settle(subject, tMs, true);
  }

  // ---------- contacts ----------

  function onContact(c) {
    const a = idx.get(c.agent_a), b = idx.get(c.agent_b);
    if (a === undefined || b === undefined || a === b) return;
    const tier = Math.min(4, Math.max(1, Number(c.distance_tier) || 4));
    const dur = Math.round(Number(c.duration_s)) || 0;
    const t = c.t, tMs = startMs + t * stepMs;
    const pk = dur * 8 + (tier - 1);
    pushContact(a, t, b, pk); pushContact(b, t, a, pk);
    source(b, tMs); const b1 = s1, b2 = s2;
    source(a, tMs); const a1 = s1, a2 = s2;
    if (b1 + b2 + a1 + a2 === 0) return;
    const lam = lamOf(pk), mins = dur / 60;
    if (b1 + b2 > 0) { expose(a, b, tMs, tMs, lam, tier, mins, b1, b2, 0); settle(a, tMs, false); }
    if (a1 + a2 > 0) { expose(b, a, tMs, tMs, lam, tier, mins, a1, a2, 0); settle(b, tMs, false); }
  }

  // ---------- run ----------

  let contacts = input.contacts, reports = input.reports || [];
  // CSV rows carry t as a string: compared as strings, "1060" < "941" and reports ran out of order.
  // (Plain arrays only: precompute.mjs passes a numeric, build-on-demand array-like.)
  if (Array.isArray(contacts)) for (const r of contacts) r.t = Number(r.t);
  for (const r of reports) r.t = Number(r.t);
  const byT = (x, y) => x.t - y.t;
  const sorted = (a) => { for (let k = 1; k < a.length; k++) if (a[k].t < a[k - 1].t) return false; return true; };
  if (!sorted(contacts)) contacts = contacts.slice().sort(byT);
  if (!sorted(reports)) reports = reports.slice().sort(byT);
  let ci = 0, ri = 0, endT = startMs;
  const nc = contacts.length, nr = reports.length;
  while (ci < nc || ri < nr) {
    // evidence goes first within a step, so same-step contacts already see it
    if (ri < nr && (ci >= nc || reports[ri].t <= contacts[ci].t)) onReport(reports[ri++]);
    else onContact(contacts[ci++]);
  }
  if (nc) endT = Math.max(endT, startMs + contacts[nc - 1].t * stepMs);
  if (nr) endT = Math.max(endT, startMs + reports[nr - 1].t * stepMs);
  for (let i = 0; i < n; i++) if (chT[i] && active(i, endT)) settle(i, endT, false); // finish decays

  // ---------- output ----------

  const changes = new Map();
  for (let i = 0; i < n; i++) {
    if (!chT[i]) continue;
    changes.set(agentIds[i], chT[i].map((tMs, k) => ({ tMs, p: chP[i][k] })));
  }
  flags.sort((x, y) => x.tMs - y.tMs);

  function pAt(agentId, tMs) {
    const a = changes.get(agentId);
    if (!a || tMs < a[0].tMs) return P.prior;
    let lo = 0, hi = a.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (a[mid].tMs <= tMs) lo = mid; else hi = mid - 1;
    }
    return a[lo].p;
  }

  // Why is p what it is at tMs: the evidence on record and the k biggest exposure contributions.
  function explain(agentId, tMs, k = 5) {
    const i = idx.get(agentId);
    const e = i === undefined ? null : ev[i];
    const evidence = (e ? e.log : []).filter((x) => x.tMs <= tMs).map((x) => ({
      ...x, active: tMs - x.tMs < (x.value === 'negative' ? negMs : evMs),
    }));
    const list = (i === undefined ? null : contribs[i]) || [];
    const contributions = list.filter((c) => c.learnedMs <= tMs).sort((x, y) => y.delta - x.delta).slice(0, k)
      .map((c) => ({ ...c }));
    return { p: pAt(agentId, tMs), prior: P.prior, evidence, contributions };
  }

  return { pAt, changes, explain, flags, params: P };
}
