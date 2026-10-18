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
//   - duration, distance, indoors/outdoors, room type: D, the near-field dose per quantum of a logged pair,
//     f * B * h / Q(d): the exhaled plume, diluted Q(d) = nearQ1 * d (d < 1 m) or nearQ1 * d^2 (d >= 1 m) m^3/h
//     (two-zone near field, see nearQ1), 5x more outdoors; f = activity in that room type (data/room-activity.js)
//   - shared room air, ventilation: the room's air, not a pair term. Each room is a well-mixed box
//     dC/dt = sum_j shed_j / V - loss * C, V = occupants x perPersonM3 (no room size: a phone can't know it),
//     loss = ACH + deposition + virus decay, filled by everyone the contacts put in the room this hour (one 5-min row with anyone is enough) and carried over between hours, so
//     people more than 5 m apart in a big room (capacity > 150: the sim logs no such pair) and someone who
//     arrives after a sick person left still share air. Occupant i breathes q * f * B * h_i * C.
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

import { doseModel, indoorRH, virusDecay, DEFAULTS as RIO } from './infer.js';
import { activityOf } from './data/room-activity.js';

export const MF_DEFAULTS = {
  dtH: 1,                 // MF step, hours
  prior: 0.02,            // P(infected) at the start, ages spread evenly (same as infer.js). Only a fallback: input.initialPrevalence
                          //   (see initialPrevalence(config)) replaces it when given. 2% was 30x the 7,500-agent runs' 5 seeds
                          //   (0.07%), and with R ~ 1.5-2 those phantom cases made mean P ~0.40 vs 4-10% infected.
  importPerDay: 0.0005,   // community infection hazard (the paper's self-infection term)
  onsetDays: 2.5,         // infection -> symptom onset (sim influenza: latent 1.5 + presymptomatic 1.0)
  illnessDays: 10,        // infection age after which a case is over (R)
  pAsym: 0.3,             // asymptomatic share ...
  asymRel: 0.5,           // ... at this relative infectiousness
  tauPosDays: 3,          // positive test: infected this long before the result
  tauSymDays: 2.5,        // "might be sick": infected this long before the report (onset now)
  lrSym: 20,              // likelihood ratio of a symptom self-report
  lrOther: 4,             // ... of a report by someone else
  negDays: 3,             // negative test: P_S = 1 from this long before it up to the result (the paper: all t <= t_obs;
                          //   the online pass can rerun this far back)
  lambdaScale: 0.901,     // dose multiplier, fitted by meanfield-cli.mjs --calibrate on influenza_none_n1000_d14_s42_25fe957a
                          //   (0.836 with roomVolume 'map', 0.135 with legacyDose)
                          //   Refit per run. The 7,500-agent runs: --calibrate (true seeds, no reports) gives 1.128 (fixed) and
                          //   1.401 (frankenstein), but with reports those over-predict; fitted with reports: 0.569 and 0.760
                          //   (ml/scripts/kl_mf_fit.mjs, ml/KL_RESULTS.md).
  // Near field. infer.js's plume, 1/(30 m^3/h * d^2), made a 1 m contact 5x and a 0.5 m one 20x a dorm room's
  // air, so outdoor passers-by and crowded lounges outweighed roommates (the sim's most common infections).
  // A two-zone model (Nicas, Am. Ind. Hyg. Assoc. J. 57:542, 1996) treats the air within d of the source as a
  // near-field box exchanging beta = 1/2 * area * s with the room: a 1 m hemisphere (6.3 m^2) at typical indoor
  // air speeds s ~ 0.05 m/s (Baldwin & Maynard, Ann. Occup. Hyg. 42:303, 1998) gives ~570 m^3/h, growing ~d^2.
  // Facing the speaker, in the jet, dilutes less (Jia et al., Build. Environ. 219:109166, 2022: 94x at 1 m for
  // 0.72 m^3/h exhaled -> 68 m^3/h; https://pmc.ncbi.nlm.nih.gov/articles/PMC9085449/), but phones don't know
  // who faces whom. Q(1 m) = 600, ~d^2 beyond (two-zone shell), ~d inside (jet stage). On run 25fe957a,
  // 600 beat 68 / 200 (AUC, dose-only AUC); see model/README.md.
  nearQ1: 600,            // m^3/h at 1 m
  nearPuffExp: 2,         // Q ~ d^this beyond 1 m
  // Room size. A phone knows at best the building (GPS), never the room, and map/rooms.csv volumes are the sim's
  // own procedural sizes (sim/campussim/campus.py: capacity x m^2/person by room type, footprint fractions), which
  // its aerosol route then uses, so 'map' scores well on sim runs by construction only. 'occupancy' (default) sizes
  // each room's air by the people the contacts put in it that hour: V = max(1, occupants) x perPersonM3, so the
  // room term is the occupants' mean shed / (perPersonM3 x loss), with no room or building size. 'fixed': the
  // default room (defaultRoomM2 x ceilingM) everywhere; 'none': no room term. See model/README.md "Room size".
  roomVolume: 'occupancy',
  perPersonM3: 40,        // m^3 of room air per occupant (~13 m^2 floor at 3 m); 40-100 scored the same on the sim
  roomAir: true,          // room term from each room's occupancy (false: per logged pair, as infer.js)
  legacyDose: false,      // true: infer.js doseModel per pair (plume 1/(30 d^2) + room term), the old dose
  activity: true,         // f by room type (data/room-activity.js; roomActivity: {type: f} overrides); false: 1
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

// Share of people infected at the start, from a sim config (params.run.initial_seeds / n_agents): a count, not who.
// A phone app would use a community prevalence estimate instead. null if the config doesn't say.
export function initialPrevalence(config) {
  const run = config?.params?.run || {}, n = Number(run.n_agents ?? config?.n_agents), k = Number(run.initial_seeds);
  return n > 0 && k >= 0 ? k / n : null;
}

// input: { contacts, reports, rooms, agentIds, stepMin, startMs, weather?, days?, initialPrevalence? } (as inferRisk;
// weather is config.json params.weather; initialPrevalence replaces MF_DEFAULTS.prior unless params.prior is set;
// seeds, for calibration only: ids infected at the start). Returns { pAt, shedAt, shedStep, stepOf, changes, explain: null, flags: [], params }.
export function meanFieldRisk(input, params = {}) {
  const start = input.initialPrevalence != null ? { prior: input.initialPrevalence } : {};
  const P = { ...MF_DEFAULTS, ...start, ...params }, R = { ...RIO, ...params };
  const { agentIds, stepMin, startMs } = input;
  const N = agentIds.length, idx = new Map(agentIds.map((id, i) => [id, i]));
  const dtMs = P.dtH * HOUR, dtDays = P.dtH / 24, W = Math.max(1, Math.round((P.dtH * 60) / stepMin)); // sim steps per MF step
  const K = Math.max(1, Math.round(P.illnessDays / dtDays));
  const stage = stageCurve(K, dtDays, P, R);
  const contacts = input.contacts || [], reports = input.reports || [];
  // input.prep (optional, an object): the contact preprocessing below depends on the contacts, rooms and dose
  // parameters but not on lambdaScale, prior or importPerDay, so a calibration loop can pass the same object to every
  // call and skip it after the first. The caller must keep everything else fixed between those calls.
  const prep = input.prep && input.prep.pairs ? input.prep : null;
  let lastSimStep = 0;
  if (!(prep && input.days)) for (const c of contacts) if (+c.t > lastSimStep) lastSimStep = +c.t;
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

  // Rooms: ventilation and activity from map/rooms.csv (volume only with roomVolume 'map'); an id it lacks gets
  // infer.js's default room.
  const roomRows = input.rooms || null, roomIx = new Map(), rmV = [], rmAch = [], rmF = [];
  const defV = R.defaultRoomM2 * R.ceilingM;
  const roomOf = (id) => {
    let r = roomIx.get(id);
    if (r === undefined) {
      const s = roomRows && roomRows.get(id), v = Number(s?.volume_m3), a = Number(s?.ventilation_ach);
      r = rmV.length; roomIx.set(id, r);
      rmV.push(P.roomVolume === 'map' && v > 0 ? v : defV); rmAch.push(a > 0 ? a : R.defaultAch); rmF.push(P.activity ? (P.roomActivity?.[s?.room_type] ?? activityOf(s?.room_type)) : 1);
    }
    return r;
  };
  // Virus decay by sim day (outdoor humidity -> indoor RH), for each room's loss rate.
  const decayOfDay = (day) => {
    const o = daily.length ? daily[Math.min(day, daily.length - 1)] : {};
    const rh = o.outdoor_rh_pct ?? w.outdoor_rh_pct ?? R.outdoorRH, tc = o.outdoor_temp_c ?? w.outdoor_temp_c ?? R.outdoorTempC;
    return virusDecay(indoorRH(rh, tc, w.indoor_temp_c ?? R.indoorTempC));
  };
  if (prep) for (const [id, r] of prep.roomIx) { roomIx.set(id, r); rmV[r] = prep.rmV[r]; rmAch[r] = prep.rmAch[r]; rmF[r] = prep.rmF[r]; }
  const TIER_M = [0.5, 1.5, 3.5, 6];
  const nearQ = (d) => P.nearQ1 * (d < 1 ? d : Math.pow(d, P.nearPuffExp));

  // Contacts -> near-field dose per quantum D, summed per unordered pair and MF step (Poisson doses add up),
  // and who was in which room for how many sim steps of each MF step (room air below).
  const agg = prep ? [] : Array.from({ length: nSteps }, () => new Map());
  const occ = prep ? [] : Array.from({ length: nSteps }, () => new Map()); // room * N + agent -> sim steps present
  const lastT = new Float64Array(N).fill(-1);
  const stepsPerDay = 1440 / stepMin, stepH = stepMin / 60;
  const sorted = prep || contacts.every((c, k) => k === 0 || +c.t >= +contacts[k - 1].t);
  const rows = prep ? [] : sorted ? contacts : contacts.slice().sort((x, y) => x.t - y.t);
  const legacy = P.legacyDose, roomAir = P.roomAir && !legacy && P.roomVolume !== 'none';
  for (const c of rows) {
    const t = +c.t, n = Math.floor(t / W);
    if (n >= nSteps) continue;
    let a = idx.get(c.agent_a), b = idx.get(c.agent_b);
    if (a === undefined || b === undefined || a === b) continue;
    const iv = c.indoor, indoor = iv == null || iv === '' || iv === true || iv === 1 || iv === 'True' || iv === 'true' || iv === '1';
    if (indoor && c.room_id === '') continue; // through a wall: no shared air (infer.js wallFactor 0)
    let unit;
    if (legacy) unit = doseForDay(Math.floor(t / stepsPerDay))(c) / R.quantaPeak;
    else {
      const r = indoor ? roomOf(c.room_id ?? '') : -1, shared = roomAir && c.room_id != null; // no room id: per pair
      if (shared && r >= 0) for (const x of [a, b]) if (lastT[x] !== t) { // one room per agent per sim step
        lastT[x] = t;
        const k = r * N + x;
        occ[n].set(k, (occ[n].get(k) || 0) + 1);
      }
      const dm = c.distance_m == null || c.distance_m === '' ? NaN : Number(c.distance_m);
      const dist = Math.max(0.3, Number.isFinite(dm) ? dm : TIER_M[Math.min(4, Math.max(1, Number(c.distance_tier) || 4)) - 1]);
      const f = r >= 0 ? rmF[r] : 1;
      unit = (f * R.breathingRate * ((Math.round(Number(c.duration_s)) || 0) / 3600)) / (nearQ(dist) * (indoor ? 1 : R.outdoorNearDilution));
      if (!shared && r >= 0 && P.roomVolume !== 'none') unit += (f * R.breathingRate * ((Math.round(Number(c.duration_s)) || 0) / 3600)) / (rmV[r] * (rmAch[r] + R.deposition + decayOfDay(Math.floor(t / stepsPerDay))));
    }
    if (!(unit > 0)) continue;
    if (a > b) [a, b] = [b, a];
    const k = a * N + b, m = agg[n];
    m.set(k, (m.get(k) || 0) + unit); // per quantum, so lambda = 1 - exp(-q * stage * D)
  }
  const pairs = prep ? prep.pairs : agg.map((m) => {
    if (!m.size) return null;
    const a = new Int32Array(m.size), b = new Int32Array(m.size), D = new Float64Array(m.size);
    let i = 0;
    for (const [k, d] of m) { a[i] = Math.floor(k / N); b[i] = k % N; D[i] = d; i++; }
    return { a, b, D };
  });
  // Occupancy per MF step, grouped by room: room, agent, hours present.
  const occs = prep ? prep.occs : occ.map((m) => {
    if (!m.size) return null;
    const keys = [...m.keys()].sort((x, y) => x - y), r = new Int32Array(keys.length), ag = new Int32Array(keys.length), h = new Float64Array(keys.length);
    keys.forEach((k, i) => { r[i] = Math.floor(k / N); ag[i] = k % N; h[i] = m.get(k) * stepH; });
    return { r, ag, h };
  });
  if (input.prep && !prep) Object.assign(input.prep, { pairs, occs, roomIx: new Map(roomIx), rmV: rmV.slice(), rmAch: rmAch.slice(), rmF: rmF.slice() });
  const nRooms = rmV.length, dayOfStep = (s) => Math.floor((s * P.dtH) / 24);

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
  const negBack = Math.round(P.negDays / dtDays);
  // One illness: a repeated report of the same kind, or a symptom report after a positive, within this many steps of
  // the clamp already applied says nothing new (the paper's observations are about one infection).
  const episode = Math.round(P.illnessDays / dtDays);
  const lastPos = new Int32Array(N).fill(-1e9), lastSym = new Int32Array(N).fill(-1e9), lastOther = new Int32Array(N).fill(-1e9);
  const fresh = () => {
    const S = new Float64Array(N).fill(1 - P.prior), A = new Float64Array(N * K).fill(P.prior / K), Rr = new Float64Array(N);
    for (const id of input.seeds || []) { // calibration only: known cases, just infected at the start
      const i = idx.get(id);
      if (i === undefined) continue;
      S[i] = 0; A.fill(0, i * K, i * K + K); A[i * K] = 1;
    }
    return { S, A, R: Rr, C: new Float64Array(nRooms) }; // C: each room's airborne shed, per m^3
  };
  const copy = (s) => ({ S: s.S.slice(), A: s.A.slice(), R: s.R.slice(), C: s.C.slice() });
  const shedNow = new Float64Array(N), shedStamp = new Int32Array(N).fill(-1);
  const shedOf = (st, j, s) => { // sum over ages of P_j(age) * stage(age), at the start of step s
    if (shedStamp[j] === s) return shedNow[j];
    let x = 0;
    for (let k = 0, o = j * K; k < K; k++) if (stage[k]) x += st.A[o + k] * stage[k];
    shedStamp[j] = s; shedNow[j] = x;
    return x;
  };
  const decayDay = Array.from({ length: dayOfStep(nSteps) + 1 }, (_, d) => decayOfDay(d));
  const logq = new Float64Array(N);

  function applyClamp(c, st) {
    const { S, A, R: Rr } = st, i = c[1], o = i * K;
    if (c[0] === 'infect') { // P_I = w exactly (the posterior), dated at age k0; S and R share the rest pro rata
      const k0 = c[2], wgt = c[3], rest = S[i] + Rr[i], f = rest > 0 ? (1 - wgt) / rest : 0;
      S[i] = rest > 0 ? S[i] * f : 1 - wgt; Rr[i] *= f;
      A.fill(0, o, o + K);
      if (k0 < K) A[o + k0] = wgt; else Rr[i] += wgt;
    } else if (c[0] === 'sus') { // negative test (SI eq. 4): P_S = 1 at this step, so nothing was caught or passed on
      S[i] = 1; Rr[i] = 0; A.fill(0, o, o + K);
    } else if (c[0] === 'rec') { // recovered (SI eq. 6): P_R = 1, no longer susceptible
      S[i] = 0; A.fill(0, o, o + K); Rr[i] = 1;
    }
  }

  // An observation learned in step n -> a list of [effect step, clamp] (empty: nothing new).
  function clampsFor(kind, i, n, st) {
    if (kind === 'rec') return [[n, ['rec', i]]];
    if (kind === 'neg') { // P_S = 1 at every step from negBack before the result up to it
      const out = [];
      for (let s = Math.max(0, n - negBack); s <= n; s++) out.push([s, ['sus', i]]);
      return out;
    }
    // One illness, one dating: a positive isn't re-dated by a later positive or report, nor a report by its repeat.
    if (n - lastPos[i] < episode) return [];
    if (kind === 'sym' && n - lastSym[i] < episode) return [];
    if (kind === 'other' && n - Math.max(lastSym[i], lastOther[i]) < episode) return [];
    (kind === 'pos' ? lastPos : kind === 'sym' ? lastSym : lastOther)[i] = n;
    const back = Math.round((kind === 'pos' ? P.tauPosDays : P.tauSymDays) / dtDays);
    let sEff = n - back, k0 = 0;
    if (sEff < 0) { k0 = -sEff; sEff = 0; }
    if (kind === 'pos') // a positive outweighs an earlier negative: drop that negative's P_S = 1 from the dating on
      for (const [s, list] of clamps) if (s >= sEff) clamps.set(s, list.filter((c) => !(c[0] === 'sus' && c[1] === i)));
    let wgt = 1;
    if (kind !== 'pos') { // Bayes: the posterior P(infected | report) from the model's current P_I
      const lr = kind === 'sym' ? P.lrSym : P.lrOther, p = Math.min(1, Math.max(0, 1 - st.S[i] - st.R[i]));
      wgt = (lr * p) / (lr * p + 1 - p);
    }
    return [[sEff, ['infect', i, k0, wgt]]];
  }

  // One MF step, in place: clamps, then P_S <- P_S * prod_j (1 - T_{j->i}) * exp(-import), then ageing.
  function step(s, st, clamps) {
    for (const c of clamps.get(s) || []) applyClamp(c, st);
    const { S, A, R: Rr, C } = st;
    logq.fill(-hImp);
    // Room air: C' = Css + (C - Css) e^(-loss dt), Css = sum_j shed_j (h_j / dt) / (V loss); occupant i breathes
    // the step's mean C, less its own share (a person does not infect themselves).
    if (roomAir) {
      shedStamp.fill(-1);
      const dec = decayDay[Math.min(dayOfStep(s), decayDay.length - 1)], dt = P.dtH, o = occs[s];
      const touched = o ? new Set() : null;
      for (let p = 0, n = o ? o.r.length : 0; p < n;) {
        const r = o.r[p];
        let e = p, E = 0;
        let hs = 0;
        for (; e < n && o.r[e] === r; e++) { E += shedOf(st, o.ag[e], s) * o.h[e]; hs += o.h[e]; }
        const V = P.roomVolume === 'occupancy' ? Math.max(1, hs / dt) * P.perPersonM3 : rmV[r];
        const loss = rmAch[r] + R.deposition + dec, VL = V * loss, a = Math.exp(-loss * dt), avgf = (1 - a) / (loss * dt);
        const css = E / dt / VL, cavg = css + (C[r] - css) * avgf, g = q * rmF[r] * R.breathingRate;
        for (let k = p; k < e; k++) {
          const own = (shedOf(st, o.ag[k], s) * o.h[k]) / dt / VL;
          const x = g * o.h[k] * Math.max(0, cavg - own);
          if (x > 0) logq[o.ag[k]] -= x;
        }
        C[r] = css + (C[r] - css) * a;
        touched.add(r);
        p = e;
      }
      for (let r = 0; r < nRooms; r++) if (C[r] > 0 && !(touched && touched.has(r))) {
        C[r] *= Math.exp(-(rmAch[r] + R.deposition + dec) * dt);
        if (C[r] < 1e-12) C[r] = 0;
      }
    }
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
  const keepBack = Math.round(Math.max(P.tauPosDays, P.tauSymDays, P.negDays) / dtDays) + CK;
  let st = fresh();
  for (let n = 0; n < nSteps; n++) {
    if (n % CK === 0) {
      ckpt.set(n, copy(st));
      for (const k of ckpt.keys()) if (k < n - keepBack) ckpt.delete(k);
    }
    let earliest = n;
    for (const [kind, i] of obs[n]) {
      for (const [sEff, c] of clampsFor(kind, i, n, st)) {
        if (!clamps.has(sEff)) clamps.set(sEff, []);
        clamps.get(sEff).push(c);
        if (sEff < earliest) earliest = sEff;
      }
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
    sFinal: st.S, // each agent's P(never infected) at the end, indexed like agentIds; 1 - sFinal = P(ever infected)
    pAt, shedAt, shedStep, stepOf, index: idx, changes, explain: null, flags: [],
    params: { ...R, ...P, method: 'meanfield' },
    // for the heat map's risk field: hazard at 1 m for 1 h per unit shed = q * breathingRate / nearFieldQ
    field: legacy ? { q, breathingRate: R.breathingRate, nearFieldQ: R.nearFieldQ, outdoorNearDilution: R.outdoorNearDilution, quietQuanta: R.quietQuanta / R.quantaPeak }
      : { q, breathingRate: R.breathingRate, nearFieldQ: P.nearQ1, outdoorNearDilution: R.outdoorNearDilution, quietQuanta: activityOf('dorm_double') },
  };
}
