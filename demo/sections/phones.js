// Two phones on a table: an in-browser replica of FlUni's proximity pipeline (proximity/Core), for when
// the real 3-iPhone demo (proximity/DEMO.md) isn't available. Sensor readings are simulated with seeded
// noise; everything after the readings (fusion, P(within 6 ft), weighted minutes, alerts, the phone's own
// risk estimate) follows the app's rules, ported in ./phones/core.js.
import * as C from './phones/core.js';

const asset = (p) => new URL(`../../heatmap/assets/${p}`, import.meta.url).href;
const MAX_FT = 30, START_FT = 12, TICK_S = 0.5, TRUE_TX = -61; // field data: best RSSI-at-1 m near -61 dBm (Fusion.swift)
const esc = (x) => String(x).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
const fmtFt = (m) => `${(m / C.FT).toFixed(m / C.FT < 10 ? 1 : 0)} ft`;

const ICON = { // heatmap/app.js ICON (FlUni's SF Symbols, redrawn)
  info: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 11v6" stroke="#faf4e8" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="7.4" r="1.4" fill="#faf4e8"/>',
  alert: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 6.5v6.5" stroke="#faf4e8" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="16.8" r="1.4" fill="#faf4e8"/>',
  walk: '<circle cx="13" cy="4.5" r="1.8" fill="currentColor"/><path d="M10 21l2-6-2-2 1-5 3 2 2 2M9 11l-2 3M12 15l3 2.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
  arrow: '<path d="M4 12h15M13 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
  people: '<circle cx="8" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="1.7"/><circle cx="16.5" cy="9" r="2.5" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M2.5 19c.5-4 3-5.5 5.5-5.5s5 1.5 5.5 5.5M15 14c3 0 5 1.5 6 5" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>',
  check: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M7.5 12.5l3 3 6-6.5" fill="none" stroke="#faf4e8" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
};
const ico = (n, cls = '') => `<svg class="ico ${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICON[n]}</svg>`;
const TABS = {
  today: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/></svg>Today',
  map: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M3 6l6-2 6 2 6-2v14l-6 2-6-2-6 2zM9 4v14M15 6v14"/></svg>Campus',
  me: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="9.5"/><circle cx="12" cy="10" r="3"/><path d="M5.8 18.5c1.5-3 4-4 6.2-4s4.7 1 6.2 4"/></svg>You',
};
const tabbar = (on) => `<nav class="tabbar">${Object.entries(TABS).map(([k, v]) => `<span class="${k === on ? 'on' : ''}">${v}</span>`).join('')}</nav>`;
// MeView options, as FlUni words them.
const OPTIONS = [
  { risk: 0, title: 'I feel fine', detail: 'Phones near you see: healthy.', tint: 'var(--sage)' },
  { risk: 1, title: 'I have symptoms', detail: 'Phones near you see: possibly sick. Time near you counts half toward their close contact.', tint: 'var(--sun)' },
  { risk: 2, title: 'I tested positive', detail: 'Phones near you see: contagious, and may alert their owners.', tint: 'var(--fire)' },
];
const SEES = ['healthy', 'possibly sick', 'contagious'];

const CSS = `
#phones > .lede { margin-bottom: 16px; }
#phones .ph-wrap { display: grid; grid-template-columns: minmax(0, 1fr) 410px; gap: 22px; align-items: start; }
#phones .ph-table { position: relative; }
#phones .ph-stage { position: relative; height: 482px; touch-action: none; }
#phones .ph-six { position: absolute; top: 20px; bottom: -6px; width: 0; border-left: 2px dashed var(--fire); opacity: .7; }
#phones .ph-dev { position: absolute; top: 0; width: 248px; }
#phones .ph-dev.b { cursor: grab; outline: none; }
#phones .ph-dev.b.drag { cursor: grabbing; }
#phones .ph-dev.b:focus-visible .ph-frame { box-shadow: 0 0 0 5px var(--ink), 0 0 0 9px var(--sun), 0 18px 36px -12px rgba(51,36,28,.35); }
#phones .ph-label { height: 22px; font-size: 14px; font-weight: 600; color: var(--ink-2); white-space: nowrap; display: flex; gap: 6px; align-items: center; }
#phones .ph-label .pill { font-size: 11px; font-weight: 500; }
#phones .ph-frame { position: relative; width: 238px; height: 450px; margin: 5px; border-radius: 30px; background: var(--paper); overflow: hidden;
  box-shadow: 0 0 0 5px var(--ink), 0 18px 36px -12px rgba(51,36,28,.35); display: flex; flex-direction: column; user-select: none; }
#phones .ph-bar { display: flex; justify-content: space-between; align-items: center; padding: 6px 14px 0; font: 600 12px/1 ui-rounded, system-ui, sans-serif; font-variant-numeric: tabular-nums; }
#phones .ph-bar i { width: 58px; height: 16px; border-radius: 999px; background: var(--ink); }
#phones .scr { flex: 1; min-height: 0; overflow: hidden; display: flex; flex-direction: column; gap: 7px; padding: 2px 8px 6px;
  font-family: ui-rounded, "SF Pro Rounded", system-ui, sans-serif; font-size: 12px; line-height: 1.25; color: var(--ink); }
#phones .scr p { margin: 0; }
#phones .nav { font-size: 24px; font-weight: 700; margin: 2px 0 0 4px; }
#phones .t2 { font-size: 16px; font-weight: 700; } #phones .th { font-size: 13px; font-weight: 600; }
#phones .ts { font-size: 11.5px; } #phones .tf { font-size: 10px; } #phones .semi { font-weight: 600; }
#phones .tl { font-size: 26px; font-weight: 700; font-variant-numeric: tabular-nums; line-height: 1.05; }
#phones .ink2 { color: var(--ink-2); } #phones .fireink { color: var(--fire-ink); }
#phones .row { display: flex; gap: 7px; align-items: flex-start; } #phones .grow { flex: 1; min-width: 0; }
#phones .vs { display: flex; flex-direction: column; gap: 4px; }
#phones .ico { width: 18px; height: 18px; flex: none; } #phones .ico.big { width: 24px; height: 24px; }
#phones .bul { display: flex; gap: 5px; align-items: baseline; } #phones .bul .ico { width: 9px; height: 9px; }
#phones .tissue { width: 40px; height: 40px; flex: none; }
#phones .prog { height: 5px; border-radius: 3px; background: rgba(51,36,28,.12); overflow: hidden; }
#phones .prog i { display: block; height: 100%; background: var(--ink-2); border-radius: 3px; transition: width .4s linear; }
#phones .prog.done i { background: var(--fire-ink); }
#phones .pc { position: relative; isolation: isolate; padding: 4px 6px 2px 2px; border-style: solid; border-width: 7px 6px 16px 13px;
  border-image: url("${asset('containers/box-paper.png')}") 34 30 80 64 fill / 7px 6px 16px 13px stretch; filter: drop-shadow(0 4px 8px rgba(51,36,28,.08)); }
#phones .pc::before { content: ""; position: absolute; inset: 0; z-index: -1; border-radius: 5px; background: var(--tint, transparent); }
#phones .pc.peach { border-image-source: url("${asset('containers/box-peach.png')}"); }
#phones .tabbar { flex: none; display: flex; justify-content: space-around; padding: 5px 2px 6px; border-top: 1px solid var(--hairline); font: 9.5px ui-rounded, system-ui, sans-serif; color: var(--ink-3); }
#phones .tabbar span { display: flex; flex-direction: column; align-items: center; gap: 1px; min-width: 50px; }
#phones .tabbar span.on { color: var(--ink); font-weight: 600; } #phones .tabbar svg { width: 20px; height: 20px; }
#phones .opt { all: unset; box-sizing: border-box; display: flex; gap: 7px; align-items: flex-start; width: 100%; padding: 7px 8px; border-radius: 12px; cursor: pointer;
  background: var(--surface); border: 1.5px solid var(--hairline); }
#phones .opt:hover { background: var(--surface-3); }
#phones .opt.on { border-color: var(--ink); background: color-mix(in srgb, var(--tint) 30%, var(--paper)); }
#phones .opt .dot { width: 18px; height: 18px; border-radius: 50%; background: var(--tint); flex: none; margin-top: 1px; }
#phones .opt:focus-visible { outline: 3px solid var(--sun); }
#phones .hex { font: 600 11px/1.3 var(--mono); letter-spacing: .02em; word-break: break-all; transition: background .6s; border-radius: 4px; }
#phones .hex.new { background: var(--sun); }
#phones .note { position: absolute; z-index: 2; left: 8px; right: 8px; top: 26px; padding: 8px 10px; border-radius: 14px; background: rgba(255,250,241,.97);
  box-shadow: 0 8px 22px -6px rgba(51,36,28,.45); font: 11px/1.3 ui-rounded, system-ui, sans-serif; transform: translateY(-140%); transition: transform .35s; }
#phones .note.show { transform: none; }
#phones .note b { display: flex; justify-content: space-between; font-size: 10px; letter-spacing: .04em; color: var(--ink-2); margin-bottom: 2px; }
#phones .ph-ruler { position: relative; height: 40px; margin-top: 2px; }
#phones .ph-ruler svg { position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; }
#phones .ph-presets { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; margin-top: 4px; font-size: 13px; }
#phones .ph-presets button.btn { padding: 4px 11px; font-size: 13px; }
#phones .ph-side { display: flex; flex-direction: column; gap: 12px; }
#phones .ph-side .card { padding: 12px 14px; }
#phones .k { font-size: 12px; letter-spacing: .06em; text-transform: uppercase; color: var(--ink-3); font-weight: 600; margin: 0 0 6px; }
#phones .beacon { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; font: 600 13px/1.2 var(--mono); }
#phones .beacon span { padding: 3px 7px; border-radius: 6px; background: var(--surface-3); }
#phones .sens { display: grid; grid-template-columns: auto 1fr auto; gap: 2px 8px; align-items: center; font-size: 14px; }
#phones .sens label { display: flex; gap: 6px; align-items: center; font-weight: 600; cursor: pointer; white-space: nowrap; }
#phones .sens input { width: 16px; height: 16px; accent-color: var(--ink); }
#phones .sens .rule { font-size: 12px; color: var(--ink-3); line-height: 1.25; }
#phones .sens .val { font: 600 14px var(--mono); text-align: right; white-space: nowrap; }
#phones .sens .sub { grid-column: 2 / 4; font-size: 12px; font-weight: 500; }
#phones .sens .sub input { width: 13px; height: 13px; }
#phones .nl { width: 100%; height: 104px; display: block; margin-top: 6px; }
#phones .fused { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; align-items: end; }
#phones .big { font-size: 34px; font-weight: 600; line-height: 1; font-variant-numeric: tabular-nums; }
#phones .big small { font-size: 16px; color: var(--ink-2); font-weight: 500; }
#phones .why { font-size: 12.5px; color: var(--ink-2); margin: 8px 0 0; min-height: 17px; }
#phones .why.warn { color: var(--fire-ink); font-weight: 600; }
#phones .ph-math { font-size: 13.5px; line-height: 1.5; margin: 6px 0 0; color: var(--ink-2); }
#phones .ph-math b { color: var(--ink); font-weight: 600; }
#phones .ctl { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; font-size: 13px; }
#phones .ctl .seg { display: inline-flex; border: 1px solid var(--hairline); border-radius: 999px; overflow: hidden; }
#phones .ctl .seg button { font: inherit; border: 0; background: var(--surface); padding: 5px 10px; cursor: pointer; color: var(--ink); }
#phones .ctl .seg button.on { background: var(--ink); color: var(--paper); }
#phones .ctl .clock { margin-left: auto; font-variant-numeric: tabular-nums; color: var(--ink-2); }
#phones .ph-bottom { margin-top: 26px; grid-template-columns: 1.1fr 1fr; }
#phones .ph-bottom h3 { margin: 0 0 8px; font-size: 18px; font-weight: 600; }
#phones .steps { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; font-size: 15px; }
#phones .steps li { display: grid; grid-template-columns: 44px 1fr auto; gap: 8px; align-items: center; }
#phones .steps .t { font: 600 13px var(--mono); color: var(--ink-3); }
#phones .steps button.btn { padding: 3px 11px; font-size: 13px; }
#phones .rv { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; font-size: 14px; }
#phones .rv ul { margin: 0; padding-left: 18px; display: flex; flex-direction: column; gap: 3px; }
#phones .rv h4 { margin: 0 0 4px; font-size: 13px; letter-spacing: .06em; text-transform: uppercase; }
#phones .tag { font-size: 12.5px; color: var(--ink-3); margin: 10px 0 0; }
@media (max-width: 1100px) { #phones .ph-wrap, #phones .ph-bottom { grid-template-columns: 1fr; } }
@media (prefers-reduced-motion: reduce) { #phones .note, #phones .prog i { transition: none; } }
`;

function initialState() {
  const r = C.rng(20261018), idr = C.rng(1792);
  const newId = () => Array.from({ length: 11 }, () => Math.floor(idr.u() * 256).toString(16).padStart(2, '0')).join('');
  return {
    ft: START_FT, risk: 0, ble: true, uwb: true, gps: true, noU1: false, speed: 60, paused: false,
    t: 0, simT: 0, r, newId, id: newId(), idAt: 0, idFlash: 0, cal: new C.BLECalibrator(),
    nB: 0, gA: [0, 0], gB: [0, 0], rssi: null, uwbR: null, bleR: null, gpsR: null,
    est: null, pClose: 0, exp: new C.Exposure(), notified: 'none', note: null,
  };
}

function step(S) {
  if (S.paused) return;
  const dt = TICK_S, { r } = S;
  S.t += dt; S.simT += dt * S.speed;
  if (S.simT - S.idAt >= C.ROTATE_S) { S.id = S.newId(); S.idAt = S.simT - ((S.simT - S.idAt) % C.ROTATE_S); S.idFlash = S.t; }
  const d = Math.max(S.ft * C.FT, 0.05);
  // Bluetooth: the median-smoothed RSSI (RSSIWindow) wanders a few dB; bounded so the demo never flips.
  S.nB = 0.8 * S.nB + 0.6 * r.g();
  S.rssi = TRUE_TX - 20 * Math.log10(d) + clamp(2 * S.nB, -3.5, 3.5);
  // UWB: ~10 cm. It teaches the Bluetooth model this pair's RSSI at 1 m.
  if (S.uwb && !S.noU1) {
    S.uwbR = { source: 'uwb', distance: Math.max(0, d + clamp(0.04 * r.g(), -0.08, 0.08)), sigma: C.UWB_SIGMA, at: S.t };
    S.cal.observe(S.rssi, S.uwbR.distance);
  }
  S.bleR = S.cal.reading(S.rssi, S.t);
  // GPS (test harness only): each phone's own fix drifts a few metres; accuracy radii ~9 and ~11 m.
  for (const g of [S.gA, S.gB]) { g[0] = 0.95 * g[0] + 1.25 * r.g(); g[1] = 0.95 * g[1] + 1.25 * r.g(); }
  if (S.gps) S.gpsR = C.gpsReading(Math.hypot(d + S.gB[0] - S.gA[0], S.gB[1] - S.gA[1]), 9, 11, S.t);
  const readings = [S.uwb && S.uwbR, S.ble && S.bleR, S.gps && S.gpsR].filter(Boolean);
  S.est = C.fuse(readings, S.t);
  let pc = S.est ? C.exposurePClose(S.est) : 0, dist = S.est ? C.doseDistance(S.est) : null;
  // ContactGuard rule 3: a Bluetooth-only RSSI above -30 dBm is implausible.
  if (S.est && S.est.sources.every((s) => s === 'ble') && S.rssi > -30) { pc = 0; dist = null; }
  S.pClose = pc;
  S.exp.tick({ id: S.id, risk: S.risk, pClose: pc, distance: dist }, S.t, dt, S.speed);
  const rank = { none: 0, nearby: 1, close: 2 };
  if (rank[S.exp.level] > rank[S.notified]) S.note = { kind: S.exp.level, at: S.t };
  S.notified = S.exp.level;
}

const clockText = (S) => {
  const m = 9 * 60 + 41 + Math.floor(S.simT / 60), h = Math.floor(m / 60) % 24;
  return `${((h + 11) % 12) + 1}:${String(m % 60).padStart(2, '0')}`;
};

function phoneA(S) {
  const left = Math.max(0, C.ROTATE_S - (S.simT - S.idAt));
  return `<div class="nav">You</div>
    <p class="th" style="margin:2px 0 0 4px">How are you doing?</p>
    ${OPTIONS.map((o) => `<button class="opt ${S.risk === o.risk ? 'on' : ''}" data-risk="${o.risk}" style="--tint:${o.tint}" aria-pressed="${S.risk === o.risk}">
      <span class="dot"></span><span class="vs" style="gap:2px"><span class="th">${o.title}</span><span class="tf ink2">${o.detail}</span></span></button>`).join('')}
    <div class="pc" style="--tint:rgba(236,223,198,.55)"><div class="vs">
      <p class="tf ink2 semi">Broadcasting now (Bluetooth)</p>
      <p class="hex ${S.t - S.idFlash < 1.5 && S.idFlash ? 'new' : ''}">${S.id.match(/.{1,4}/g).join(' ')}</p>
      <p class="ts">Phones near you see: <b>${SEES[S.risk]}</b></p>
      <p class="tf ink2">New random ID in ${Math.ceil(left / 60)} min</p></div></div>
    <p class="tf ink2" style="padding:0 4px">Only your status and a random ID that changes every 15 minutes are shared. No name, no location.</p>`;
}

function phoneB(S) {
  const e = S.exp, level = e.level, out = [];
  out.push('<div class="nav">Today</div>');
  if (level === 'nearby') out.push(`<div class="pc peach"><div class="row">${ico('walk')}<div class="grow vs" style="gap:2px"><p class="ts semi">${C.ADVICE.nearby.title}</p><p class="tf">${esc(C.ADVICE.nearby.body.join(' '))}</p></div></div></div>`);
  const [title, sub] = C.STATUS[level], lines = level === 'none' ? [] : C.ADVICE[level].body;
  out.push(`<div class="pc ${level === 'none' ? '' : 'peach'}" style="--tint:${level === 'none' ? 'rgba(172,188,139,.45)' : 'transparent'}"><div class="vs" style="gap:6px">
    <div class="row"><div class="grow vs" style="gap:3px"><p class="t2">${title}</p><p class="ts">${sub}</p></div>
    ${level === 'none' ? `<img class="tissue" src="${asset('illustrations/tissue.png')}" alt="">` : ico(level === 'close' ? 'alert' : 'info', 'big')}</div>
    ${level === 'close' ? `<div class="vs" style="gap:3px">${lines.map((l) => `<div class="bul">${ico('arrow')}<span class="tf">${esc(l)}</span></div>`).join('')}</div>` : ''}</div></div>`);
  const b = C.band(e.p), tint = { low: 'rgba(172,188,139,.45)', elevated: 'rgba(235,209,135,.5)', high: 'rgba(219,108,89,.22)' }[b];
  out.push(`<div class="pc" style="--tint:${tint}"><div class="vs ${b === 'high' ? 'fireink' : ''}" style="gap:2px">
    <p class="th">Your risk estimate</p><p class="tl">${C.liveText(e.p)}</p>
    <p class="tf">${C.summary(e.p)}</p><p class="tf ${b === 'high' ? 'fireink' : 'ink2'}">This phone's estimate: time near each phone, how close, room air, their status.</p></div></div>`);
  const mins = e.minutes, goal = C.CLOSE_CONTACT_MIN, done = mins >= goal - 1e-6;
  const cap = done ? `You've reached the ${goal}-minute close-contact mark.` : mins > 0 ? `About ${Math.ceil(goal - mins)} more minutes would make this a close contact.` : 'No time near someone with symptoms or a positive test.';
  out.push(`<div class="pc"><div class="vs" style="gap:4px"><p class="th">Close-contact time</p>
    <div style="display:flex;align-items:baseline;gap:5px"><span class="tl">${Math.floor(Math.min(mins, 99))}</span><span class="ts ink2">of ${goal} min</span></div>
    <div class="prog ${done ? 'done' : ''}"><i style="width:${Math.min(1, mins / goal) * 100}%"></i></div><p class="tf ink2">${cap}</p></div></div>`);
  out.push(`<div class="pc"><div class="row" style="align-items:center"><span class="ink2">${ico('people')}</span><p class="ts semi">1 other FlUni phone nearby</p></div></div>`);
  return out.join('');
}

// Number line, 0-30 ft: each sensor's estimate +/- sigma, the fused one, the 6 ft line and the true distance.
function numberLine(S) {
  const W = 380, L = 44, R = 10, x = (m) => L + clamp(m / C.FT / MAX_FT, 0, 1) * (W - L - R);
  const rows = [['UWB', S.uwb && S.uwbR && S.t - S.uwbR.at <= C.MAX_AGE.uwb ? { ...S.uwbR, sigma: C.agedSigma(S.uwbR, S.t - S.uwbR.at) } : null, '#6f8048'],
    ['BLE', S.ble ? S.bleR : null, '#b08a1e'], ['GPS', S.gps ? S.gpsR : null, '#7a6152'], ['Fused', S.est, '#33241c']];
  let svg = `<svg class="nl" viewBox="0 0 ${W} 104" role="img" aria-label="Distance estimates">`;
  for (let f = 0; f <= MAX_FT; f += 5) svg += `<line x1="${x(f * C.FT)}" x2="${x(f * C.FT)}" y1="4" y2="88" stroke="rgba(51,36,28,.08)"/><text x="${x(f * C.FT)}" y="101" font-size="10" text-anchor="middle" fill="#7a6152">${f}</text>`;
  svg += `<text x="${W - R}" y="101" font-size="10" text-anchor="end" fill="#7a6152" dx="-14">ft</text>`;
  svg += `<line x1="${x(C.CLOSE_M)}" x2="${x(C.CLOSE_M)}" y1="2" y2="90" stroke="#db6c59" stroke-width="2" stroke-dasharray="4 3"/>`;
  rows.forEach(([name, rd, col], i) => {
    const y = 14 + i * 21;
    svg += `<text x="0" y="${y + 4}" font-size="12" font-weight="${name === 'Fused' ? 700 : 600}" fill="${rd ? '#33241c' : '#a8968a'}">${name}</text>`;
    if (!rd) { svg += `<text x="${L}" y="${y + 4}" font-size="11" fill="#a8968a">off / no reading</text>`; return; }
    const a = x(Math.max(0, rd.distance - rd.sigma)), b = x(rd.distance + rd.sigma), over = rd.distance + rd.sigma > MAX_FT * C.FT;
    svg += `<rect x="${a}" y="${y - (name === 'Fused' ? 5 : 3.5)}" width="${Math.max(2, b - a)}" height="${name === 'Fused' ? 10 : 7}" rx="4" fill="${col}" opacity="${name === 'Fused' ? 0.85 : 0.45}"/>`;
    if (over) svg += `<path d="M${W - R + 2} ${y - 5}l6 5-6 5z" fill="${col}"/>`;
    svg += `<circle cx="${x(rd.distance)}" cy="${y}" r="${name === 'Fused' ? 5 : 4}" fill="${col}" stroke="#fffaf1" stroke-width="1.5"/>`;
  });
  svg += `<line x1="${x(S.ft * C.FT)}" x2="${x(S.ft * C.FT)}" y1="2" y2="90" stroke="#33241c" stroke-width="1.5"/>
    <text x="${x(S.ft * C.FT)}" y="0" font-size="10" text-anchor="middle" fill="#33241c" dy="-1">true</text></svg>`;
  return svg;
}

export function mount(el) {
  if (!document.getElementById('phones-css')) {
    const st = document.createElement('style');
    st.id = 'phones-css'; st.textContent = CSS;
    document.head.appendChild(st);
  }
  el.innerHTML = `
    <h2>Two phones: how Bluetooth, UWB and GPS turn into an alert</h2>
    <p class="lede">Drag phone B: each sensor guesses the distance, the phone fuses them into P(within 6 ft), and only then counts minutes and gives advice.</p>
    <div class="ph-wrap">
      <div class="ph-table">
        <div class="ph-stage">
          <div class="ph-six"></div>
          <div class="ph-dev a"><div class="ph-label">Phone A <span class="pill">patient zero</span></div>
            <div class="ph-frame"><div class="ph-bar"><span data-clock></span><i></i><span>5G</span></div><div class="scr" data-a></div>${tabbar('me')}</div></div>
          <div class="ph-dev b" tabindex="0" role="slider" aria-label="Distance from phone A" aria-valuemin="0.5" aria-valuemax="${MAX_FT}">
            <div class="ph-label">Phone B <span class="pill">you</span><span class="muted" style="font-weight:500;font-size:12px">&larr; drag &rarr;</span></div>
            <div class="ph-frame"><div class="note"><b><span>FLUNI</span><span>now</span></b><span data-note></span></div>
              <div class="ph-bar"><span data-clock></span><i></i><span>5G</span></div><div class="scr" data-b></div>${tabbar('today')}</div></div>
        </div>
        <div class="ph-ruler"><svg></svg></div>
        <div class="ph-presets"><span class="muted">Put B at</span>${[1, 3, 8, 15, 30].map((f) => `<button class="btn" data-ft="${f}">${f} ft</button>`).join('')}</div>
      </div>
      <div class="ph-side">
        <div class="card"><p class="k">What B hears over Bluetooth</p>
          <div class="beacon"><span>FLU1</span><span data-rb></span><span data-id></span></div></div>
        <div class="card"><p class="k">Distance, sensor by sensor (B's view of A)</p>
          <div class="sens">
            <label><input type="checkbox" data-s="uwb" checked>UWB</label><span class="rule">±10 cm, U1/U2 iPhones</span><span class="val" data-v="uwb"></span>
            <label class="sub"><input type="checkbox" data-s="noU1"> Phone without U1 chip (or UWB blocked)</label>
            <label><input type="checkbox" data-s="ble" checked>Bluetooth</label><span class="rule" data-rule="ble"></span><span class="val" data-v="ble"></span>
            <label><input type="checkbox" data-s="gps" checked>GPS</label><span class="rule">5–20 m; test harness only</span><span class="val" data-v="gps"></span>
          </div>
          <div data-nl></div>
          <div class="fused">
            <div><p class="k" style="margin:4px 0 2px">Fused (1/σ² weights)</p><div class="big" data-fd></div></div>
            <div><p class="k" style="margin:4px 0 2px">P(within 6 ft)</p><div class="big" data-pc></div></div>
          </div>
          <p class="why" data-why></p>
          <p class="ph-math" data-math></p>
        </div>
        <div class="ctl"><span class="muted">Demo clock</span><span class="seg">${[1, 10, 60].map((s) => `<button data-speed="${s}" class="${s === 60 ? 'on' : ''}">${s}x</button>`).join('')}</span>
          <button class="btn" data-pause>Pause</button><button class="btn primary" data-reset>Reset</button><span class="clock" data-elapsed></span></div>
      </div>
    </div>
    <div class="grid ph-bottom">
      <div class="card"><h3>The live 3-phone script, in 5 steps</h3>
        <ol class="steps">
          <li><span class="t">0:30</span><span>A: Me &rsaquo; <b>"I tested positive"</b>. A shares a random ID + "contagious".</span><button class="btn" data-do="pos">Do it</button></li>
          <li><span class="t">1:00</span><span>Put A within ~1 m of B: <b>"Someone within 6 ft may be sick"</b> in seconds.</span><button class="btn" data-do="near">Do it</button></li>
          <li><span class="t">1:45</span><span>Wait ~15 s at 60x: the bar fills to 15 min, then the <b>close-contact alert</b>.</span><span></span></li>
          <li><span class="t">2:15</span><span>B's risk card: <b>this phone's estimate</b> and how it's worked out.</span><span></span></li>
          <li><span class="t">3:00</span><span>C: "Pretend I'm at..." a red building: <b>walk-in warning</b>, then the Map tab.</span><span class="muted" style="font-size:12px">phones only</span></li>
        </ol></div>
      <div class="card"><h3>Live demo: what's real vs staged</h3>
        <div class="rv">
          <div><h4 class="risk-low">Real, on the iPhones</h4><ul>
            <li>Bluetooth beacons: rotating random ID + 3-level status</li>
            <li>Bluetooth + UWB distance fused into P(within 6 ft); UWB tunes Bluetooth</li>
            <li>15 weighted-minute rule, heads-up, alerts, advice, notifications</li>
            <li>Matching on the phone, no server</li></ul></div>
          <div><h4 class="risk-high">Staged or simulated</h4><ul>
            <li>Time runs 60x (15 min of contact in ~15 s)</li>
            <li>Phones side by side; crowds, pockets and walls are harder</li>
            <li>Campus, map and persona numbers come from the simulated run</li>
            <li>"Pretend I'm at..." replaces location; GPS between phones is test-harness only</li>
            <li>Foreground only; in a 2-person room the status reveals who is sick</li></ul></div>
        </div>
        <p class="tag">This page: sensor readings are simulated (seeded, repeatable noise); fusion, alerts and the estimate use the app's rules from <code>proximity/Core</code>. The ID here rotates every 15 demo-clock minutes.</p>
      </div>
    </div>`;

  const q = (s) => el.querySelector(s), qa = (s) => [...el.querySelectorAll(s)];
  const stage = q('.ph-stage'), devA = q('.ph-dev.a'), devB = q('.ph-dev.b'), six = q('.ph-six'), ruler = q('.ph-ruler svg');
  const scrA = q('[data-a]'), scrB = q('[data-b]'), note = q('.note');
  const fresh = () => { const s = initialState(); step(s); return s; };
  let S = fresh(), lastA = '', lastB = '';
  const geom = () => {
    const w = stage.clientWidth, x0 = devA.offsetWidth;
    return { x0, ppf: Math.max(4, (w - 2 * devA.offsetWidth) / MAX_FT) };
  };

  function layout() {
    const { x0, ppf } = geom();
    devB.style.left = `${x0 + S.ft * ppf}px`;
    six.style.left = `${x0 + 6 * ppf}px`;
    devB.setAttribute('aria-valuenow', S.ft.toFixed(1));
    devB.setAttribute('aria-valuetext', `${S.ft.toFixed(1)} feet`);
    let s = `<line x1="${x0}" x2="${x0 + MAX_FT * ppf}" y1="8" y2="8" stroke="#33241c" stroke-width="1.5"/>`;
    for (let f = 0; f <= MAX_FT; f++) {
      const X = x0 + f * ppf, big = f % 5 === 0;
      s += `<line x1="${X}" x2="${X}" y1="8" y2="${big ? 20 : 14}" stroke="#33241c" stroke-width="${big ? 1.5 : 1}"/>`;
      if (big && f !== 5) s += `<text x="${X}" y="34" font-size="12" text-anchor="middle" fill="#6a5244">${f}${f === MAX_FT ? ' ft' : ''}</text>`;
    }
    s += `<line x1="${x0 + 6 * ppf}" x2="${x0 + 6 * ppf}" y1="0" y2="22" stroke="#db6c59" stroke-width="3"/>
      <text x="${x0 + 6 * ppf}" y="34" font-size="13" font-weight="700" text-anchor="middle" fill="#8e3a28">6 ft</text>
      <rect x="${x0 + S.ft * ppf - 26}" y="-14" width="52" height="18" rx="9" fill="#33241c"/>
      <text x="${x0 + S.ft * ppf}" y="-1" font-size="12" font-weight="600" text-anchor="middle" fill="#faf4e8">${S.ft.toFixed(1)} ft</text>`;
    ruler.innerHTML = s;
  }

  function render() {
    const a = phoneA(S), b = phoneB(S);
    if (a !== lastA) { scrA.innerHTML = a; lastA = a; }
    if (b !== lastB) { scrB.innerHTML = b; lastB = b; }
    qa('[data-clock]').forEach((c) => { c.textContent = clockText(S); });
    const showNote = S.note && S.t - S.note.at < 5;
    if (showNote) q('[data-note]').textContent = C.NOTE[S.note.kind];
    note.classList.toggle('show', !!showNote);
    q('[data-rb]').textContent = `${S.risk} = ${C.RISK_LABEL[S.risk].toLowerCase()}`;
    q('[data-id]').textContent = `ID ${S.id.slice(0, 10)}…`;
    const v = (k, r, on) => { q(`[data-v="${k}"]`).textContent = !on ? 'off' : r ? `${fmtFt(r.distance)} ±${(r.sigma / C.FT).toFixed(1)}` : '—'; };
    const uwbFresh = S.uwbR && S.t - S.uwbR.at <= C.MAX_AGE.uwb ? { ...S.uwbR, sigma: C.agedSigma(S.uwbR, S.t - S.uwbR.at) } : null;
    v('uwb', uwbFresh, S.uwb); v('ble', S.bleR, S.ble); v('gps', S.gpsR, S.gps);
    q('[data-rule="ble"]').textContent = S.cal.isCalibrated ? `σ = 40% + 0.3 m: calibrated by UWB (${S.cal.txPower.toFixed(0)} dBm @1 m)` : `σ = 70% + 0.3 m; RSSI ${S.rssi == null ? '—' : S.rssi.toFixed(0)} dBm`;
    q('[data-nl]').innerHTML = numberLine(S);
    const e = S.est;
    q('[data-fd]').innerHTML = e ? `${(e.distance / C.FT).toFixed(1)}<small> ft ±${(e.sigma / C.FT).toFixed(1)}</small>` : '—';
    q('[data-pc]').innerHTML = `<span class="${S.pClose >= 0.5 ? 'risk-high' : ''}">${Math.round(S.pClose * 100)}%</span>`;
    const why = q('[data-why]');
    const gpsOnly = e && C.isCoarseGPSOnly(e);
    why.classList.toggle('warn', !!gpsOnly);
    why.textContent = !e ? 'No distance sensor on: B still hears the beacon, but nothing counts.'
      : gpsOnly ? 'GPS alone never counts: it can’t tell 3 ft from 30 ft.'
      : `Using ${e.sources.map((s) => s.toUpperCase()).join(' + ')}.${S.uwb && S.noU1 && S.uwbR && S.t - S.uwbR.at <= 6 ? ' UWB fading out (grace period).' : ''}`;
    const w = C.WEIGHT[S.risk], src = S.exp.sources.get(S.id);
    q('[data-math]').innerHTML = `<span class="math">minutes += Δt × P × ${w === 0.5 ? '½' : w}</span> <span class="muted">(${S.risk ? C.RISK_LABEL[S.risk].toLowerCase() : 'healthy: 0'})</span> = <b>${S.exp.minutes.toFixed(1)}</b> of 15<br>
      <span class="math">p = 2% + (1 − p)·s·(1 − e<sup>−0.352·dose</sup>)</span> = <b>${C.liveText(S.exp.p)}</b> <span class="muted">dose ${S.exp.dose.toFixed(3)}${src ? `, s ${src.s}` : ''}</span>`;
    const mm = Math.floor(S.simT / 60);
    q('[data-elapsed]').textContent = `+${Math.floor(mm / 60)}:${String(mm % 60).padStart(2, '0')} demo time`;
    q('[data-pause]').textContent = S.paused ? 'Play' : 'Pause';
    qa('[data-speed]').forEach((bt) => bt.classList.toggle('on', Number(bt.dataset.speed) === S.speed));
    qa('[data-s]').forEach((i) => { i.checked = !!S[i.dataset.s]; });
  }

  const setFt = (f) => { S.ft = clamp(Math.round(f * 2) / 2, 0.5, MAX_FT); layout(); render(); };
  // Dragging phone B.
  let grab = null;
  devB.addEventListener('pointerdown', (ev) => {
    grab = ev.clientX - devB.getBoundingClientRect().left;
    devB.setPointerCapture(ev.pointerId); devB.classList.add('drag');
  });
  devB.addEventListener('pointermove', (ev) => {
    if (grab == null) return;
    const { x0, ppf } = geom();
    setFt((ev.clientX - stage.getBoundingClientRect().left - grab - x0) / ppf);
  });
  const drop = () => { grab = null; devB.classList.remove('drag'); };
  devB.addEventListener('pointerup', drop); devB.addEventListener('pointercancel', drop);
  devB.addEventListener('keydown', (ev) => {
    const d = { ArrowLeft: -0.5, ArrowRight: 0.5, ArrowDown: -0.5, ArrowUp: 0.5 }[ev.key];
    if (d) { ev.preventDefault(); setFt(S.ft + d); }
  });
  scrA.addEventListener('click', (ev) => {
    const b = ev.target.closest('[data-risk]');
    if (b) { S.risk = Number(b.dataset.risk); render(); }
  });
  el.addEventListener('click', (ev) => {
    const t = ev.target.closest('button');
    if (!t || !el.contains(t)) return;
    if (t.dataset.ft) setFt(Number(t.dataset.ft));
    else if (t.dataset.speed) { S.speed = Number(t.dataset.speed); render(); }
    else if ('pause' in t.dataset) { S.paused = !S.paused; render(); }
    else if ('reset' in t.dataset) { S = fresh(); lastA = lastB = ''; layout(); render(); }
    else if (t.dataset.do === 'pos') { S.risk = 2; render(); }
    else if (t.dataset.do === 'near') setFt(3);
  });
  qa('[data-s]').forEach((i) => i.addEventListener('change', () => { S[i.dataset.s] = i.checked; render(); }));

  new ResizeObserver(layout).observe(stage);
  layout(); render();
  setInterval(() => { step(S); render(); }, TICK_S * 1000);
}
