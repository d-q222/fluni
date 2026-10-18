// Infection probability model: P(person is infected right now), from what a phone app could know.
// Inputs are phone-detected contacts, self-reports, reports about others and test results. Never the
// simulator's disease state. One chronological pass over contacts and reports.
//
// Evidence about a person j (self-report, report by others, test) gives j a "source risk" s_j.
// Each contact with j then exposes the other person i with Rio's transmission probability
// lambda = 1 - exp(-dose) (exposure/flu_risk.py: Baker et al. PNAS 2021 with a Wells-Riley aerosol dose
// from distance, minutes, the room's volume and ventilation, indoor/outdoor and j's illness stage), and
// i's risk grows by Rio's update p_new = (1 - x_i) * s_j * lambda. A report also looks back over j's
// recent contacts, since it makes them informative after the fact. Each exposure's share then fades as
// the illness runs its course (Rio's still_infected: Erlang, mean 7 days, shape 4).
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
  // Rio's exposure model (exposure/flu_risk.py; keep these in step with it)
  quantaPeak: 10,         // infectious quanta/h a flu case emits at peak (talking-level)
  quietQuanta: 1.5,       // our change, not Rio's: in a dorm room (sleeping, resting, studying) a case
                          //   barely talks. 10 q/h there gave a roommate 87-98% over one illness; quiet at
                          //   night only still ~60%; quiet in the dorm room all day gives ~20% (household
                          //   flu attack rates are 10-20%)
  breathingRate: 0.5,     // m^3/h inhaled
  nearFieldQ: 30,         // m^3/h dilution of the exhaled plume at 1 m (scales with distance^2)
  outdoorNearDilution: 5, // wind dilutes the plume 5x more outdoors
  deposition: 0.3,        // 1/h particle settling
  defaultRoomM2: 50, ceilingM: 2.7, defaultAch: 2.0, // room when the contact has no known room
  wallFactor: 0,          // our addition: an indoor pair with an empty room_id is < 5 m apart across a
                          //   wall (docs/sim-output-format.md) and shares no air; dose x this
  outdoorRH: 60, outdoorTempC: 10, indoorTempC: 21,  // campus in January: heated indoor air is dry (~30% RH)
  // relative infectiousness by the source's days since symptom onset, -2..7 (0 outside)
  stageProfile: [0.05, 0.3, 1.0, 0.9, 0.6, 0.35, 0.18, 0.08, 0.04, 0.02],
  illnessMeanDays: 7, illnessShape: 4, // still_infected(): Erlang illness length
  lookbackDays: 3,        // a report makes contacts up to this long before it informative
  alpha: 0.25,            // damping of second-hand risk
  alphaCap: 0.4,          // second-hand source risk never reads more than alpha * this
  xiMax: 0.08,            // second-hand risk ceiling
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
const TIER_M = [0.5, 1.5, 3.5, 6]; // distance for a contact row that has only its tier

// ---------- Rio's dose model (exposure/flu_risk.py) ----------

// Heated outdoor air keeps its water, so indoor RH is lower than outdoor in cold weather (Magnus).
export function indoorRH(outdoorRH, outdoorTempC, indoorTempC = 21) {
  if (outdoorTempC == null || outdoorTempC >= indoorTempC) return outdoorRH;
  const sat = (t) => 6.112 * Math.exp((17.62 * t) / (243.12 + t));
  return Math.min(100, (outdoorRH * sat(outdoorTempC)) / sat(indoorTempC));
}
// 1/h airborne inactivation of influenza vs relative humidity (Noti et al. 2013).
export function virusDecay(rh) {
  const low = Math.log(1 / 0.75), high = Math.log(1 / 0.2);
  if (rh <= 25) return low;
  if (rh >= 45) return high;
  return low + ((high - low) * (rh - 25)) / 20;
}
// stage_factor(): relative infectiousness `day` days after the source's symptom onset.
export const stageFactor = (day, profile = DEFAULTS.stageProfile) => (day < -2 || day > 7 ? 0 : profile[day + 2]);

// unitDose(contact) = Rio's dose for a source at stage factor 1, so lambda = 1 - exp(-stage * unitDose).
// rooms: Map room_id -> { volume_m3, ventilation_ach, room_type } (map/rooms.csv); unknown rooms get
// Rio's default. After each call, unitDose.info holds the inputs it used (for explain()).
export function doseModel(params = {}, rooms = null) {
  const P = { ...DEFAULTS, ...params };
  const rh = indoorRH(P.outdoorRH, P.outdoorTempC, P.indoorTempC), decay = virusDecay(rh);
  const mkRoom = (volume, ach, dorm = false) => {
    const loss = ach + P.deposition + decay;
    return { volume, ach, loss, far: 1 / (volume * loss), dorm };
  };
  const defRoom = mkRoom(P.defaultRoomM2 * P.ceilingM, P.defaultAch);
  const cache = new Map();
  const roomOf = (id) => {
    if (!id || !rooms) return defRoom;
    let r = cache.get(id);
    if (!r) {
      const s = rooms.get(id), v = Number(s?.volume_m3), a = Number(s?.ventilation_ach);
      r = s ? mkRoom(v > 0 ? v : defRoom.volume, a > 0 ? a : P.defaultAch, String(s.room_type || '').startsWith('dorm')) : defRoom;
      cache.set(id, r);
    }
    return r;
  };
  const info = { distanceM: 0, indoor: true, room: defRoom, durS: 0, tier: 4, quanta: P.quantaPeak };
  function unitDose(c) {
    const tier = Math.min(4, Math.max(1, Number(c.distance_tier) || 4));
    const dm = c.distance_m == null || c.distance_m === '' ? NaN : Number(c.distance_m);
    const dist = Number.isFinite(dm) ? dm : TIER_M[tier - 1];
    const iv = c.indoor; // missing -> indoors (most contacts are in rooms)
    const indoor = iv == null || iv === '' || iv === true || iv === 1 || iv === 'True' || iv === 'true' || iv === '1';
    const room = indoor ? roomOf(c.room_id) : null;
    const durS = Math.round(Number(c.duration_s)) || 0;
    const wall = indoor && c.room_id === ''; // undefined room_id (column not loaded) = unknown room instead
    const d = Math.max(dist, 0.3);
    const qNear = P.nearFieldQ * d * d * (indoor ? 1 : P.outdoorNearDilution);
    const quanta = room && room.dorm ? P.quietQuanta : P.quantaPeak;
    info.distanceM = dist; info.indoor = indoor; info.room = room; info.durS = durS; info.tier = tier;
    info.quanta = quanta; info.wall = wall;
    return (wall ? P.wallFactor : 1) * quanta * P.breathingRate * (durS / 3600) * (1 / qNear + (indoor ? room.far : 0));
  }
  unitDose.info = info;
  unitDose.indoorRH = rh;
  unitDose.virusDecay = decay;
  return unitDose;
}

export function inferRisk(input, params = {}) {
  const P = { ...DEFAULTS, ...params };
  const { agentIds, stepMin, startMs } = input;
  const stepMs = stepMin * MIN;
  const n = agentIds.length;
  const idx = new Map(agentIds.map((id, i) => [id, i]));
  const evMs = P.evidenceDays * DAY, negMs = P.negTestDays * DAY, fillMs = P.fillHours * HOUR;
  const L = Math.round((P.lookbackDays * DAY) / stepMs);        // lookback, in steps
  const unsupSteps = Math.round((P.unsupportedHours * HOUR) / stepMs);
  const keep = Math.max(L, unsupSteps);                          // contact history kept per agent
  const mergeMs = P.mergeGapMin * MIN;
  const unitDose = doseModel(P, input.rooms || null), cInfo = unitDose.info;
  // Stage of a source without dated evidence (second-hand risk): the mean of the profile over -2..7.
  const stageMean = P.stageProfile.reduce((a, b) => a + b, 0) / P.stageProfile.length;
  const stageAt = (onMs, cMs) => stageFactor(Math.floor((cMs - onMs) / DAY), P.stageProfile);

  let contacts = input.contacts, reports = input.reports || [];

  // Exposure risk lives in Erlang compartments (K per person), so each exposure's share follows Rio's
  // still_infected(days since that exposure) exactly: new risk enters stage 0, and stage k moves on
  // at rate K/mean. Yd holds risk from sources with evidence, Yi second-hand risk; both valid at xT.
  const K = P.illnessShape, rate = K / (P.illnessMeanDays * DAY);
  const Yd = new Float64Array(n * K), Yi = new Float64Array(n * K);
  const co = new Float64Array(K); // co[k] = e^-a a^k / k!, a = rate * dt
  const coef = (dt) => { const a = rate * dt; let v = Math.exp(-a); for (let k = 0; k < K; k++) { co[k] = v; v *= a / (k + 1); } };
  const sum = (Y, i) => { let s = 0; for (let k = i * K; k < i * K + K; k++) s += Y[k]; return s; };
  const xT = new Float64Array(n).fill(startMs);
  function totAt(Y, i, t) { // risk still infectious at t
    const s0 = sum(Y, i), dt = t - xT[i];
    if (s0 === 0 || dt <= 0) return s0;
    coef(dt);
    let s = 0, cum = 0;
    for (let m = K - 1; m >= 0; m--) { cum += co[K - 1 - m]; s += Y[i * K + m] * cum; }
    return s;
  }
  function advance(Y, i) { // in place by the co[] of the last coef()
    const o = i * K;
    for (let k = K - 1; k >= 0; k--) { let v = 0; for (let m = 0; m <= k; m++) v += Y[o + m] * co[k - m]; Y[o + k] = v; }
  }
  function addRisk(Y, i, dx, age) { // dx caught `age` ms ago: only the part not yet recovered remains
    if (!(dx > 0)) return;
    if (age <= 0) { Y[i * K] += dx; return; }
    coef(age);
    for (let k = 0; k < K; k++) Y[i * K + k] += dx * co[k];
  }

  const stepT = new Float64Array(n).fill(-1);         // snapshot so same-step contacts read "before"
  const xdPrev = new Float64Array(n);
  const lastT = new Float64Array(n).fill(startMs), lastP = new Float64Array(n).fill(P.prior);
  const lastEvT = new Float64Array(n).fill(-Infinity);
  const hiSince = new Float64Array(n).fill(-1), hiFlagged = new Uint8Array(n);
  const ev = new Array(n).fill(null);                 // own/other evidence about each agent
  const chT = new Array(n).fill(null), chP = new Array(n).fill(null); // change points
  const contribs = new Array(n).fill(null), open = new Array(n).fill(null);
  const flags = [];

  // recent contacts per agent: Int32 triples [step, other, contact index], oldest first. The index
  // gives the contact's row, from which look-back recomputes Rio's dose per unit stage (unitDose).
  const cb = new Array(n).fill(null), ch = new Int32Array(n), cn = new Int32Array(n);
  function pushContact(i, t, o, ci) {
    let b = cb[i], h = ch[i], m = cn[i];
    if (!b) b = cb[i] = new Int32Array(48);
    while (h < m && b[h] < t - keep) h += 3;
    if (m + 3 > b.length) {
      const live = m - h;
      if (h >= live) b.copyWithin(0, h, m);
      else { const nb = new Int32Array(b.length * 2); nb.set(b.subarray(h, m)); b = cb[i] = nb; }
      m = live; h = 0;
    }
    b[m] = t; b[m + 1] = o; b[m + 2] = ci;
    ch[i] = h; cn[i] = m + 3;
  }

  // ---------- evidence ----------

  const newEv = () => ({
    selfT: -Infinity, selfL: 0, posT: -Infinity, negT: -Infinity,
    rep: new Map(), log: [], lvl: 0, cap: 1, own: false, pos: false, on: Infinity,
    recT: -Infinity, recEff: Infinity, // a recovery claim at recT takes effect from recEff
  });
  const getEv = (i) => ev[i] || (ev[i] = newEv());

  // Evidence level at time t: sets e.lvl (lifted risk), e.cap (ceiling), e.own (self-evidence) and
  // e.on, the estimated symptom onset: the earliest evidence that still counts.
  function evEval(e, t) {
    const negOn = t - e.negT < negMs;
    const rc = t >= e.recEff ? e.recT : -Infinity; // evidence at or before an accepted recovery is void
    const counts = (T) => t - T < evMs && T > rc && (T > e.negT || !negOn); // newer than a negative test
    e.pos = t - e.posT < evMs && e.posT >= e.negT && e.posT > rc;
    e.own = e.pos;
    let q = 1, on = e.pos ? e.posT : Infinity;
    if (counts(e.selfT)) { q *= 1 - e.selfL; e.own = true; if (e.selfT < on) on = e.selfT; }
    for (const r of e.rep.values()) if (counts(r.t)) { q *= 1 - r.l; if (r.t < on) on = r.t; }
    e.on = on;
    if (e.pos) { e.cap = 1; return (e.lvl = P.posTest); }
    e.lvl = 1 - q;
    e.cap = negOn && e.lvl === 0 ? P.negTest : 1;
    return e.lvl;
  }

  // ---------- risk state ----------

  let lastOwn = false;
  function pOf(i, t) {
    const xt = 1 - (1 - totAt(Yd, i, t)) * (1 - totAt(Yi, i, t));
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

  const active = (i, t) => totAt(Yd, i, t) + totAt(Yi, i, t) > 1e-4 || (ev[i] !== null && t - lastEvT[i] < evMs + DAY);

  // Write recovery / expiry change points for the quiet stretch (lastT, t).
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

  // Move the compartments to time t (recovery) and take the before-this-step snapshot of x_d.
  function touch(i, t) {
    fill(i, t); // write recovery points for the past first: state is about to change
    if (t > xT[i]) {
      if (sum(Yd, i) + sum(Yi, i) > 0) { coef(t - xT[i]); advance(Yd, i); advance(Yi, i); }
      xT[i] = t;
    }
    if (stepT[i] !== t) { stepT[i] = t; xdPrev[i] = sum(Yd, i); }
  }

  // Source risk of j at time t: s1 and its stage from j's own evidence, else s2 = damped second-hand risk.
  let s1 = 0, s2 = 0, st1 = 0;
  function source(j, t) {
    s1 = 0; s2 = 0; st1 = 0;
    const e = ev[j];
    if (e) { s1 = evEval(e, t); if (e.cap < 1) return; }
    if (s1 > 0) { st1 = stageAt(e.on, t); return; }
    const x = stepT[j] === t ? xdPrev[j] : totAt(Yd, j, t);
    if (x > 0.005) s2 = P.alpha * Math.min(x, P.alphaCap);
  }

  // Doses add up per pair, not per 5-minute row: a pair (i, j) has one transmission probability
  // lambda = 1 - exp(-(pre + live)) over all its contacts, and j's source risk s is applied to it once:
  // the pair's share of x_i is A = s * lambda, so contact alone never lifts i above s. As the dose
  // grows, the previous share is swapped for the new one: x <- 1 - (1 - x)(1 - A')/(1 - A).
  // live = dose from contacts while j had evidence (or x_j, for second-hand); pre = dose from j's
  // contacts before its evidence, recomputed by look-back. accD: evidence sources, accI: second-hand.
  const accD = new Map(), accI = new Map();
  const pair = (acc, i, j) => {
    const k = i * n + j;
    let e = acc.get(k);
    if (!e) acc.set(k, (e = { pre: 0, live: 0, A: 0 }));
    return e;
  };

  // Expose i to j: nowMs = when i learns it, cMs = when the contact happened, ci = contact row,
  // dose = its dose (stage * unit dose), pairDose = the pair's dose up to and including it,
  // s = j's source risk. Rio's update: x <- x + (1 - x) * s * lambda, lambda from the pair's dose.
  function expose(i, j, nowMs, cMs, ci, dose, stage, s, pr, pairDose, second) {
    touch(i, nowMs);
    const xd0 = sum(Yd, i), xi0 = sum(Yi, i);
    const A = Math.max(pr.A, s * (1 - Math.exp(-pairDose)));
    if (A > pr.A) {
      const grow = (x0) => 1 - ((1 - x0) * (1 - A)) / (1 - pr.A);
      if (second) addRisk(Yi, i, Math.min(P.xiMax, grow(xi0)) - xi0, nowMs - cMs);
      else addRisk(Yd, i, grow(xd0) - xd0, nowMs - cMs);
      pr.A = A;
    }
    const delta = (1 - xd0) * (1 - xi0) - (1 - sum(Yd, i)) * (1 - sum(Yi, i));
    if (delta > 0) addContrib(i, j, cMs, nowMs, stage, dose, s, delta, nowMs !== cMs, pairDose);
  }

  // learnedMs = when the app knew about this contribution (later than the contact for retro ones), so
  // explain() never shows risk that wasn't known yet. Only entries learned together are merged.
  // Each entry carries the inputs of Rio's lambda; a merged entry keeps those of its biggest piece and
  // sums minutes and dose (so transmission = 1 - exp(-dose) still holds).
  // cInfo must describe this contact (unitDose was just called on it). Small pieces are kept so that
  // 5-minute rows add up; explain() drops entries below contribMin.
  function addContrib(i, j, cMs, learnedMs, stage, dose, risk, delta, retro, pairDose) {
    const lam = 1 - Math.exp(-dose);
    const durMin = cInfo.durS / 60, room = cInfo.room;
    const m = open[i] || (open[i] = new Map()), list = contribs[i] || (contribs[i] = []);
    let c = m.get(j);
    const sameBatch = c && c.retro === retro && (retro ? c.learnedMs === learnedMs : true);
    if (sameBatch && cMs - c.tMs <= mergeMs && cMs >= c.tMs) {
      if (!retro) c.learnedMs = learnedMs;
      c.tMs = cMs; c.durationMin += durMin; c.delta += delta; c.dose += dose; c.pieces++; c.pairDose = pairDose;
      c.transmission = 1 - (1 - c.transmission) * (1 - lam);
      if (cInfo.tier < c.distanceTier) c.distanceTier = cInfo.tier;
      if (risk > c.otherRisk) c.otherRisk = risk;
      if (dose > c.topDose) {
        c.topDose = dose; c.wall = cInfo.wall; c.distanceM = cInfo.distanceM; c.indoor = cInfo.indoor; c.stage = stage; c.quanta = cInfo.quanta;
        c.roomVolume = room ? room.volume : null; c.roomAch = room ? room.ach : null; c.roomLoss = room ? room.loss : null;
      }
      return;
    }
    c = { tMs: cMs, learnedMs, other: agentIds[j], distanceTier: cInfo.tier, durationMin: durMin,
      distanceM: cInfo.distanceM, indoor: cInfo.indoor, roomVolume: room ? room.volume : null,
      roomAch: room ? room.ach : null, roomLoss: room ? room.loss : null, quanta: cInfo.quanta, stage, dose,
      transmission: lam, pairDose, wall: cInfo.wall, otherRisk: risk, delta, retro, pieces: 1, topDose: dose };
    m.set(j, c); list.push(c);
    if (list.length > 128) { // keep the 64 most influential
      list.sort((a, b) => b.delta - a.delta);
      list.length = 64;
    }
  }

  // ---------- reports ----------

  // Evidence about j just rose from eOld to eNew: re-examine j's recent contacts, each at j's stage
  // then (days from the estimated onset: 0.3 the day before a report, 0.05 two days before).
  // Contacts after the onset estimate were already counted live (pair.live); earlier ones form the
  // pair's `pre` dose, recomputed here from scratch. The window is replayed in time order with a running
  // dose, so explain() credits each contact with the risk it added.
  const mark = new Int32Array(n), pre = new Float64Array(n), run = new Float64Array(n), lastC = new Int32Array(n);
  let markId = 0;
  function lookBack(j, step, nowMs, eNew) {
    const b = cb[j];
    if (!b) return;
    const on = ev[j].on;
    const touched = [];
    markId++;
    for (let k = ch[j]; k < cn[j]; k += 3) {
      const t = b[k];
      if (t >= step) break;
      if (t < step - L) continue;
      const cMs = startMs + t * stepMs, stage = stageAt(on, cMs);
      if (stage === 0) continue;
      const i = b[k + 1], ci = b[k + 2];
      if (mark[i] !== markId) { mark[i] = markId; touched.push(i); pre[i] = 0; run[i] = 0; }
      const dose = stage * unitDose(contacts[ci]);
      if (cMs < on) pre[i] += dose;
      run[i] += dose; lastC[i] = k;
      expose(i, j, nowMs, cMs, ci, dose, stage, eNew, pair(accD, i, j), run[i], false);
    }
    for (const i of touched) { // live contacts older than the window, if any: credited to the last one
      const pr = pair(accD, i, j), k = lastC[i];
      if (pre[i] > pr.pre) pr.pre = pre[i];
      unitDose(contacts[b[k + 2]]);
      expose(i, j, nowMs, startMs + b[k] * stepMs, b[k + 2], 0, 0, eNew, pr, pr.pre + pr.live, false);
      settle(i, nowMs, false);
    }
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
          touch(subject, tMs); Yd.fill(0, subject * K, subject * K + K); Yi.fill(0, subject * K, subject * K + K);
        }
      }
    } else if (r.value === 'positive') { e.posT = tMs; level = P.posTest; }
    else { e.negT = tMs; level = P.negTest; }
    e.log.push({ tMs, kind, value: r.value, by, level });
    lastEvT[subject] = tMs;
    const eNew = evEval(e, tMs);
    if (eNew > eOld + 1e-9) lookBack(subject, r.t, tMs, eNew);
    settle(subject, tMs, true);
  }

  // ---------- contacts ----------

  function onContact(c, ci) {
    const a = idx.get(c.agent_a), b = idx.get(c.agent_b);
    if (a === undefined || b === undefined || a === b) return;
    const t = c.t, tMs = startMs + t * stepMs;
    pushContact(a, t, b, ci); pushContact(b, t, a, ci);
    source(b, tMs); const b1 = s1, b2 = s2, bSt = st1;
    source(a, tMs); const a1 = s1, a2 = s2, aSt = st1;
    if (b1 + b2 + a1 + a2 === 0) return;
    const D = unitDose(c);
    const meet = (i, j, s1, st, s2) => {
      const second = !(s1 > 0), stage = second ? stageMean : st, dose = stage * D;
      const pr = pair(second ? accI : accD, i, j);
      pr.live += dose;
      expose(i, j, tMs, tMs, ci, dose, stage, second ? s2 : s1, pr, pr.pre + pr.live, second);
      settle(i, tMs, false);
    };
    if (b1 + b2 > 0) meet(a, b, b1, bSt, b2);
    if (a1 + a2 > 0) meet(b, a, a1, aSt, a2);
  }

  // ---------- run ----------

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
    else { onContact(contacts[ci], ci); ci++; }
  }
  if (nc) endT = Math.max(endT, startMs + contacts[nc - 1].t * stepMs);
  if (nr) endT = Math.max(endT, startMs + reports[nr - 1].t * stepMs);
  for (let i = 0; i < n; i++) if (chT[i] && active(i, endT)) settle(i, endT, false); // finish recoveries

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
    const contributions = list.filter((c) => c.learnedMs <= tMs && c.delta >= P.contribMin).sort((x, y) => y.delta - x.delta).slice(0, k)
      .map(({ topDose, ...c }) => c);
    return { p: pAt(agentId, tMs), prior: P.prior, evidence, contributions };
  }

  return { pAt, changes, explain, flags,
    params: { ...P, indoorRH: unitDose.indoorRH, virusDecay: unitDose.virusDecay, stageMean } };
}
