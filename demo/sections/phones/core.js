// FlUni's on-phone proximity rules, ported from proximity/Core (Fusion.swift, Exposure.swift,
// RiskEstimate.swift, ContactGuard.swift, BackgroundAccrual.swift) for the in-browser two-phone demo.
// Pure functions and small state objects; no DOM. Constants are the Swift ones, in metres and seconds.
import { doseModel, DEFAULTS } from '../../../model/infer.js';

export const FT = 0.3048;
export const CLOSE_M = 1.83;            // Fusion.closeDistance: 6 ft
export const MAX_AGE = { uwb: 6, ble: 6, gps: 20 };  // Source.maxAge
const UWB_FULL_TRUST = 3, UWB_GRACE_GROWTH = 1.0;     // Fusion.uwbFullTrust, uwbGraceGrowth
const MAX_GPS_ONLY_SIGMA = 10;                        // Fusion.maxGPSOnlySigma
export const UWB_SIGMA = 0.1;                         // ProximityModel: UWB readings carry sigma 0.1 m
export const DEFAULT_TX = -59;                        // BLECalibrator.defaultTxPower
export const CLOSE_CONTACT_MIN = 15;                  // ExposureTracker.closeContactMinutes
export const DOSE_RANGE_M = 10;                       // RiskEstimate.doseRange (Bluetooth range)
export const ROTATE_S = 15 * 60;                      // ProximityModel.rotationInterval
export const WEIGHT = [0, 0.5, 1];                    // Risk.weight: healthy, possibly sick, contagious
export const RISK_LABEL = ['Healthy', 'Possibly sick', 'Contagious'];
export const EVIDENCE = [0, DEFAULTS.selfReport, DEFAULTS.posTest];   // RiskEstimate.evidence
export const PRIOR = DEFAULTS.prior;
export const STAGE = DEFAULTS.stageProfile.reduce((a, b) => a + b, 0) / DEFAULTS.stageProfile.length; // 0.352
const UNIT_DOSE = doseModel();
const DOSE_PER_S = (d) => UNIT_DOSE({ distance_m: d, duration_s: 3600, indoor: true }) / 3600; // linear in time; avoids infer.js rounding sub-second ticks

const erfc = (x) => { // Numerical Recipes erfc, |error| < 1.2e-7
  const z = Math.abs(x), t = 1 / (1 + 0.5 * z);
  const r = t * Math.exp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806
    + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
  return x >= 0 ? r : 2 - r;
};
export const normalCDF = (z) => 0.5 * erfc(-z / Math.SQRT2);

export const agedSigma = (r, age) => (r.source !== 'uwb' || age <= UWB_FULL_TRUST ? r.sigma : r.sigma + UWB_GRACE_GROWTH * (age - UWB_FULL_TRUST));

// Fusion.fuse: inverse-variance weighted mean of the fresh readings.
export function fuse(readings, now) {
  const fresh = readings.filter((r) => {
    const age = now - r.at;
    return age >= -1 && age <= MAX_AGE[r.source] && r.distance >= 0 && r.distance <= 1e5 && r.sigma >= 0 && r.sigma <= 1e5;
  });
  if (!fresh.length) return null;
  let wSum = 0, dSum = 0;
  for (const r of fresh) {
    const s = Math.max(agedSigma(r, now - r.at), 1e-9), w = 1 / (s * s);
    wSum += w; dSum += w * r.distance;
  }
  return { distance: Math.max(0, dSum / wSum), sigma: Math.sqrt(1 / wSum), sources: fresh.map((r) => r.source) };
}
export const isCoarseGPSOnly = (e) => e.sources.length > 0 && e.sources.every((s) => s === 'gps') && e.sigma > MAX_GPS_ONLY_SIGMA;
export const pClose = (e) => normalCDF((CLOSE_M - e.distance) / Math.max(e.sigma, 1e-6));
export const exposurePClose = (e) => (isCoarseGPSOnly(e) ? 0 : pClose(e));
export const doseDistance = (e) => (isCoarseGPSOnly(e) ? null : e.distance);

// BLECalibrator: log-distance path loss, txPower learned from UWB.
export class BLECalibrator {
  constructor() { this.txPower = DEFAULT_TX; this.n = 2; this.samples = 0; }
  get isCalibrated() { return this.samples >= 5; }
  distance(rssi) { return 10 ** ((this.txPower - rssi) / (10 * this.n)); }
  reading(rssi, at) {
    const d = this.distance(rssi), rel = this.isCalibrated ? 0.4 : 0.7;
    return { source: 'ble', distance: d, sigma: rel * d + 0.3, at };
  }
  observe(rssi, trueDistance) {
    if (!(rssi >= -110 && rssi <= 0) || !(trueDistance > 0.05)) return;
    const implied = rssi + 10 * this.n * Math.log10(trueDistance);
    if (implied < -100 || implied > -20) return;
    this.txPower += (this.samples < 5 ? 0.5 : 0.1) * (implied - this.txPower);
    this.samples++;
  }
}

// gpsReading: distance between two fixes; error combines both accuracy radii.
export const gpsReading = (d, myAcc, peerAcc, at) => ({ source: 'gps', distance: d, sigma: Math.max(3, Math.hypot(myAcc, peerAcc)), at });

// ExposureTracker + RiskEstimate.probability for one listening phone (no 24 h expiry: the demo is shorter).
export class Exposure {
  constructor() { this.minutes = 0; this.sources = new Map(); this.level = 'none'; this.p = PRIOR; this.dose = 0; this.lastCredited = new Map(); }
  // contact: { id, risk, pClose, distance|null }; wall: real seconds; speed: demo speed-up.
  tick(contact, now, wall, speed) {
    const sim = wall * speed;
    if (contact && contact.risk > 0) {
      const last = this.lastCredited.get(contact.id); // SightingAccrual: a new ID's first sighting credits nothing
      this.lastCredited.set(contact.id, now);
      if (last !== undefined && now - last <= 300) {
        this.minutes += (sim / 60) * Math.min(1, Math.max(0, contact.pClose)) * WEIGHT[contact.risk];
        const d = contact.distance;
        if (d != null && d >= 0 && d <= DOSE_RANGE_M && sim > 0) {
          const src = this.sources.get(contact.id) || { dose: 0, s: 0 };
          src.dose += DOSE_PER_S(d) * sim;
          src.s = Math.max(src.s, EVIDENCE[contact.risk]);
          this.sources.set(contact.id, src);
        }
      }
    }
    let p = PRIOR, dose = 0;
    for (const id of [...this.sources.keys()].sort()) {
      const s = this.sources.get(id);
      dose += s.dose;
      p += (1 - p) * Math.min(s.s, 1) * (1 - Math.exp(-STAGE * s.dose));
    }
    this.p = p; this.dose = dose;
    // Hysteresis: warn at P >= 0.5, clear only below 0.3.
    const threshold = this.level === 'nearby' ? 0.3 : 0.5;
    const riskyNearby = !!contact && contact.risk > 0 && contact.pClose >= threshold;
    this.level = this.minutes >= CLOSE_CONTACT_MIN - 1e-6 ? 'close' : riskyNearby ? 'nearby' : 'none';
  }
}

// FlUni's Advice (Exposure.swift), Today status styles (TodayView), and RiskEstimate display helpers.
export const ADVICE = {
  nearby: { title: 'Someone within 6 ft may be sick', body: ['Put 6 ft or more between you, or step outside.', "Consider wearing a mask while you're here."] },
  close: { title: 'You were close to someone who may be sick', body: ["You've spent about 15 minutes within 6 ft of someone who may be sick.", 'Leave the room now, or move well away and put on a mask.', 'Wash your hands; avoid touching your face.', 'Watch for fever, cough or sore throat over the next 1–4 days.', 'If symptoms start, get tested and report it in FlUni.'] },
};
export const STATUS = {
  none: ['All clear', 'Nobody nearby has reported symptoms or a positive test.'],
  nearby: ['Someone nearby may be sick', 'A few things that help right now.'],
  close: ['Close contact', 'You spent about 15 minutes near someone who may be sick.'],
};
export const band = (p) => (p >= 0.4 ? 'high' : p >= 0.1 ? 'elevated' : 'low');
export const summary = (p) => ({ high: 'High. Consider getting tested at Vaden and staying home.', elevated: 'Elevated. Wear a mask in crowded rooms and watch for symptoms.', low: 'Low. No action needed.' })[band(p)];
export const liveText = (p) => {
  if (!(p > 0)) return '0%';
  const tenths = Math.round(p * 1000) / 10;
  return tenths < 10 ? `${tenths.toFixed(1)}%` : `${Math.min(100, Math.round(p * 100))}%`;
};
// NotificationRoute.fit: whole sentences while they fit in 180 characters.
export function noteFit(sentences, budget = 180, more = 'Tap for more details.') {
  if (sentences.join(' ').length <= budget) return sentences.join(' ');
  const kept = [];
  for (const s of sentences) {
    if (kept.length && [...kept, s, more].join(' ').length > budget) break;
    kept.push(s);
  }
  return [...kept, more].join(' ');
}
export const NOTE = {
  nearby: noteFit([`${ADVICE.nearby.title}.`, ...ADVICE.nearby.body]),
  close: noteFit(ADVICE.close.body),
};

// Seeded noise so every run (and every Reset) plays out the same way.
export function rng(seed) {
  let a = seed >>> 0;
  const u = () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const g = () => Math.sqrt(-2 * Math.log(1 - u())) * Math.cos(2 * Math.PI * u());
  return { u, g };
}
