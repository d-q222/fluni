// The math: a contact graph with P(sick) on every node, the per-contact formulas, and the trust flags.
// Every number on this slide comes from model/infer.js (inferRisk, doseModel) on a staged ten-person
// story (sections/math/scenario.js). Nothing here re-implements the model.
import {
  PEOPLE, MEETINGS, ROOMS, EVIDENCE, EVIDENCE_LABEL, START_MS, REPORT_MS, END_MS, TIMELINE_END_MS,
  runScenario, calcDose, flagExamples, DEFAULTS, MIN, HOUR, DAY,
} from './math/scenario.js';

const CSS = `
#math h3 { margin: 0 0 4px; font-size: 24px; font-weight: 600; }
#math .m-part { margin: 0 0 44px; }
#math .m-part > .muted { margin: 0 0 14px; font-size: 16px; }
#math .m-tag { font-size: 12px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--ink-3); }
#math .m-g1 { display: grid; grid-template-columns: minmax(0, 1fr) 360px; gap: 16px; align-items: start; }
#math .m-graph { padding: 8px 10px 10px; }
#math svg.m-net { width: 100%; height: auto; display: block; user-select: none; }
#math .m-net text { font-family: var(--font); }
#math .m-node { cursor: pointer; }
#math .m-node circle.body { stroke: var(--ink); stroke-width: 1.5; transition: fill .35s; }
#math .m-node:hover circle.body, #math .m-node:focus-visible circle.body { stroke-width: 3; }
#math .m-node:focus { outline: none; }
#math .m-node.pick circle.body { stroke: var(--fire-ink); stroke-width: 4; }
#math .m-node .nm { font-size: 15px; font-weight: 600; fill: var(--ink); text-anchor: middle; pointer-events: none; }
#math .m-node .pc { font-size: 15px; font-weight: 600; fill: var(--ink); text-anchor: middle; pointer-events: none; font-variant-numeric: tabular-nums;
  paint-order: stroke; stroke: var(--paper); stroke-width: 4px; }
#math .m-node .badge circle { fill: var(--ink); }
#math .m-node .badge text { fill: var(--paper); font-size: 13px; font-weight: 700; text-anchor: middle; }
#math .m-edge { cursor: pointer; }
#math .m-edge .hit { stroke: transparent; stroke-width: 18; }
#math .m-edge .ln { stroke: var(--ink-2); stroke-linecap: round; transition: opacity .3s; }
#math .m-edge.out .ln { stroke-dasharray: 2 6; }
#math .m-edge.future .ln { opacity: .12; }
#math .m-edge.sel .ln { stroke: var(--fire-ink); }
#math .m-edge .lab { font-size: 11.5px; fill: var(--ink-3); text-anchor: middle; pointer-events: none; paint-order: stroke; stroke: var(--paper); stroke-width: 3px; }
#math .m-edge.future .lab { opacity: .35; }
#math .m-edge.sel .lab { fill: var(--fire-ink); font-weight: 600; }
#math .m-flow { fill: none; stroke: var(--fire); stroke-linecap: round; pointer-events: none; stroke-dasharray: 10 8; }
#math .m-flow.second { stroke: var(--ember); stroke-dasharray: 4 7; }
#math .m-flowlab { font-size: 13px; font-weight: 700; fill: var(--fire-ink); text-anchor: middle; pointer-events: none;
  paint-order: stroke; stroke: var(--paper); stroke-width: 4px; }
#math .m-rep { fill: none; stroke: var(--fire-ink); stroke-width: 2.5; stroke-dasharray: 7 5; pointer-events: none; }
#math .m-replab { font-size: 12px; font-weight: 600; fill: var(--fire-ink); text-anchor: middle; paint-order: stroke; stroke: var(--paper); stroke-width: 4px; }
@media (prefers-reduced-motion: no-preference) {
  #math .m-flow { animation: m-dash 1.1s linear infinite; }
}
@keyframes m-dash { to { stroke-dashoffset: -18; } }
#math .m-time { display: flex; align-items: center; gap: 12px; padding: 4px 6px 0; }
#math .m-time input { flex: 1; accent-color: var(--fire); }
#math .m-time .now { font-weight: 600; min-width: 92px; font-variant-numeric: tabular-nums; }
#math .m-ticks { position: relative; height: 18px; margin: 0 6px 0 134px; font-size: 12px; color: var(--ink-3); }
#math .m-ticks span { position: absolute; transform: translateX(-50%); white-space: nowrap; }
#math .m-ticks span.rep { color: var(--fire-ink); font-weight: 600; }
#math .m-side { display: grid; gap: 12px; }
#math .m-side .card { padding: 14px 16px; }
#math .m-btns { display: flex; gap: 8px; flex-wrap: wrap; }
#math button.btn.on { background: var(--fire-ink); border-color: var(--fire-ink); color: var(--paper); }
#math .m-hint { font-size: 14px; color: var(--ink-2); margin: 8px 0 0; }
#math .m-who { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
#math .m-who b { font-size: 20px; }
#math .m-big { font-size: 40px; font-weight: 600; line-height: 1; font-variant-numeric: tabular-nums; }
#math .m-why { margin: 8px 0 0; padding: 0; list-style: none; display: grid; gap: 4px; font-size: 14px; }
#math .m-why li { display: flex; justify-content: space-between; gap: 8px; }
#math .m-why li span:last-child { font-weight: 600; font-variant-numeric: tabular-nums; }
#math .pill.lb { background: var(--sun); } #math .pill.sh { background: var(--surface-3); } #math .pill.fl { background: var(--ember); }
#math .m-flags { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 8px; min-height: 24px; }
#math .m-legend { display: flex; gap: 14px; flex-wrap: wrap; font-size: 13px; color: var(--ink-2); align-items: center; }
#math .m-legend i { display: inline-block; width: 14px; height: 14px; border-radius: 50%; border: 1px solid var(--ink); vertical-align: -2px; margin-right: 5px; }
#math .m-legend s { display: inline-block; width: 26px; border-top: 3px dashed var(--fire); vertical-align: 4px; margin-right: 5px; }
#math .m-g2 { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 16px; align-items: start; }
#math .m-g3 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; margin-top: 16px; }
#math .m-eq { display: grid; grid-template-columns: auto 1fr; gap: 7px 14px; align-items: baseline; font-size: 18px; margin: 10px 0 0; }
#math .m-eq dt { font-size: 14px; color: var(--ink-3); text-align: right; }
#math .m-eq dd { margin: 0; }
#math .m-eq .v { font-family: var(--mono); font-size: 15px; color: var(--ink-2); }
#math .m-eq .res { font-weight: 700; color: var(--fire-ink); font-family: var(--font); font-size: 18px; }
#math .math i { font-style: italic; }
#math .fr { display: inline-flex; flex-direction: column; vertical-align: middle; text-align: center; font-size: .85em; line-height: 1.1; }
#math .fr > span:first-child { border-bottom: 1px solid currentColor; padding: 0 2px; }
#math .m-edgehead { font-size: 17px; font-weight: 600; }
#math .m-note { font-size: 14px; color: var(--ink-2); margin: 10px 0 0; }
#math .m-sl { display: grid; grid-template-columns: 150px 1fr 76px; gap: 8px; align-items: center; font-size: 15px; margin: 6px 0; }
#math .m-sl input[type=range] { accent-color: var(--fire); width: 100%; }
#math .m-sl output { font-weight: 600; text-align: right; font-variant-numeric: tabular-nums; }
#math .m-calcout { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--hairline); }
#math .m-calcout .m-big { color: var(--fire-ink); }
#math .m-bars { display: grid; gap: 6px; margin-top: 10px; font-size: 15px; }
#math .m-bar { display: grid; grid-template-columns: 210px 1fr 54px; gap: 10px; align-items: center; }
#math .m-bar .tr { height: 16px; border-radius: 999px; background: var(--surface-3); overflow: hidden; }
#math .m-bar .tr i { display: block; height: 100%; border-radius: 999px; }
#math .m-bar b { text-align: right; font-variant-numeric: tabular-nums; }
#math svg.m-stage { width: 100%; height: auto; display: block; margin-top: 8px; }
#math .m-stage rect { cursor: pointer; }
#math .m-stage text { font-size: 12px; fill: var(--ink-3); text-anchor: middle; }
#math .m-stage .sel rect { stroke: var(--ink); stroke-width: 2; }
#math .m-flaggrid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 14px; }
#math .m-flag code.k { display: inline-block; font-size: 13px; font-weight: 600; background: var(--ember); color: var(--ink); padding: 2px 8px; border-radius: 6px; }
#math .m-flag .when { font-size: 15px; margin: 8px 0; }
#math .m-flag ol { margin: 0; padding-left: 18px; font-size: 14px; color: var(--ink-2); }
#math .m-flag .out { margin-top: 10px; font-family: var(--mono); font-size: 12.5px; background: var(--surface-2); border-radius: 8px; padding: 8px 10px; color: var(--ink); }
#math .m-flag .why { font-size: 14px; margin: 8px 0 0; color: var(--fire-ink); font-weight: 600; }
#math .m-trust { margin-top: 14px; display: grid; grid-template-columns: 1.2fr 1fr; gap: 16px; align-items: center; }
#math .m-cite { font-size: 13px; color: var(--ink-3); margin-top: 18px; }
`;

const C = { sage: '#acbc8b', sun: '#ebd187', ember: '#e99569', fire: '#db6c59' };
const STOPS = [[0.02, C.sage], [0.1, C.sun], [0.4, C.ember], [0.97, C.fire]];
const hex = (h) => [1, 3, 5].map((k) => parseInt(h.slice(k, k + 2), 16));
function riskColor(p) {
  if (p <= STOPS[0][0]) return STOPS[0][1];
  for (let k = 1; k < STOPS.length; k++) {
    const [p1, c1] = STOPS[k];
    if (p <= p1) {
      const [p0, c0] = STOPS[k - 1], f = (p - p0) / (p1 - p0), a = hex(c0), b = hex(c1);
      return `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * f)).join(',')})`;
    }
  }
  return C.fire;
}
const pct = (p, d = 1) => `${(p * 100).toFixed(d)}%`;
const num = (x, d = 3) => (Math.abs(x) >= 100 ? x.toFixed(0) : Math.abs(x) >= 10 ? x.toFixed(1) : x.toFixed(d));
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const when = (ms) => { const d = new Date(ms); return `${DAYS[d.getUTCDay()]} ${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}`; };
const dur = (m) => (m < 60 ? `${m} min` : `${+(m / 60).toFixed(1)} h`);
const fr = (a, b) => `<span class="fr"><span>${a}</span><span>${b}</span></span>`;
const BADGE = { might_be_sick: '?', positive: '+', negative: '−' };
const pos = Object.fromEntries(PEOPLE.map((p) => [p.id, p]));
const pairKey = (a, b) => (a < b ? `${a}|${b}` : `${b}|${a}`);
const PAIRS = [...new Set(MEETINGS.map((m) => pairKey(m.a, m.b)))].map((k) => {
  const [a, b] = k.split('|');
  return { key: k, a, b, meetings: MEETINGS.filter((m) => pairKey(m.a, m.b) === k) };
});
const FLAG_TEXT = {
  unexpected_report: 'said “might be sick” but the model had them under 5%',
  silent_high_risk: 'over 50% from contacts alone for 24 h, no report or test',
  suspicious_recovery: 'claimed “recovered” under 3 days after reporting sick',
  report_other_unsupported: 'reported someone they had no contact with in 48 h',
};

export function mount(el) {
  if (!document.getElementById('math-css')) {
    const s = document.createElement('style');
    s.id = 'math-css'; s.textContent = CSS;
    document.head.appendChild(s);
  }
  el.innerHTML = `
    <h2>The math: a contact graph and a probability on every node</h2>
    <p class="lede">Every contact is an edge, every person gets a P(sick), and a report updates their contacts, even ones from days earlier.</p>

    <div class="m-part">
      <span class="m-tag">1 · Graph theory</span>
      <h3>Click a person to change what the app knows about them</h3>
      <p class="muted">Staged ten-person story (Mon–Wed), run live through <code>model/infer.js</code>. Reports happen Wed 09:00. Click an edge to see its maths below.</p>
      <div class="m-g1">
        <div class="card m-graph">
          <svg class="m-net" viewBox="0 0 700 405" role="img" aria-label="Contact graph"></svg>
          <div class="m-time">
            <button class="btn" data-act="play">▶ Play</button>
            <span class="now"></span>
            <input type="range" min="${START_MS}" max="${TIMELINE_END_MS}" step="${5 * MIN}" aria-label="Time">
          </div>
          <div class="m-ticks"></div>
        </div>
        <div class="m-side">
          <div class="card">
            <div class="m-btns">
              <button class="btn" data-act="report">Report someone else</button>
              <button class="btn" data-act="reset">Reset</button>
            </div>
            <p class="m-hint"></p>
          </div>
          <div class="card m-info"></div>
          <div class="card">
            <div class="m-legend">
              <span><i style="background:${C.sage}"></i>2%</span><span><i style="background:${C.sun}"></i>10%</span>
              <span><i style="background:${C.ember}"></i>40%</span><span><i style="background:${C.fire}"></i>97%</span>
            </div>
            <div class="m-legend" style="margin-top:6px"><span><s></s>risk flowing</span><span>? self-report · + positive · − negative</span></div>
            <div class="m-flags"></div>
          </div>
        </div>
      </div>
    </div>

    <div class="m-part">
      <span class="m-tag">2 · Probability</span>
      <h3>One contact: aerosol dose → chance of catching it → new P</h3>
      <p class="muted">Rio's exposure model: Baker et al. (PNAS 2021) update with a Wells–Riley aerosol dose.</p>
      <div class="m-g2">
        <div class="card m-formula"></div>
        <div class="card m-calc">
          <div class="m-edgehead">Try it: you meet someone</div>
          <div class="m-sl"><span>Minutes</span><input type="range" data-k="min" min="0" max="1000" value="500"><output></output></div>
          <div class="m-sl"><span>Distance</span><input type="range" data-k="dist" min="0.3" max="6" step="0.1" value="1"><output></output></div>
          <div class="m-sl"><span>Room size <label class="muted" style="font-size:13px"><input type="checkbox" data-k="out"> outside</label></span><input type="range" data-k="room" min="0" max="1000" value="400"><output></output></div>
          <div class="m-sl"><span>Their P(sick)</span><input type="range" data-k="p" min="0" max="100" value="60"><output></output></div>
          <svg class="m-stage" viewBox="0 0 420 92"></svg>
          <div class="m-calcout"></div>
        </div>
      </div>
      <div class="m-g3">
        <div class="card">
          <div class="m-edgehead">What the app knows → source risk <span class="math"><i>s</i></span></div>
          <div class="m-bars m-evbars"></div>
          <p class="m-note">Several reporters combine as a noisy-or: <span class="math"><i>s</i> = 1 − ∏(1 − <i>s</i><sub>k</sub>)</span>, so two reports give ${pct(1 - (1 - DEFAULTS.reportOther) ** 2, 0)}.</p>
        </div>
        <div class="card">
          <div class="m-edgehead">Look-back and the chain</div>
          <p class="m-note" style="font-size:16px">A report makes the last ${DEFAULTS.lookbackDays} days of contacts informative: the sick person was already contagious (stage 0.3 the day before, 0.05 two days before).</p>
          <p class="m-note" style="font-size:16px">Someone exposed but not reported passes on only <span class="math"><i>α</i>·min(<i>x</i>, ${DEFAULTS.alphaCap}), <i>α</i> = ${DEFAULTS.alpha}</span>, and that second-hand risk is <b>never passed on again</b>: risk flows one step down the chain, never back up.</p>
        </div>
      </div>
    </div>

    <div class="m-part">
      <span class="m-tag">3 · Trust</span>
      <h3>Lie and mistake detection: does the story add up?</h3>
      <p class="muted">The model compares what people say with what their contacts imply. Each card ran through <code>inferRisk</code> on a tiny made-up timeline.</p>
      <div class="m-flaggrid"></div>
      <div class="m-trust">
        <div class="card">
          <div class="m-edgehead">Why a test counts more than a claim</div>
          <div class="m-bars m-trustbars"></div>
        </div>
        <p class="m-note" style="font-size:16px">A positive test overrides every report about you. A negative test caps you at ${pct(DEFAULTS.negTest, 0)} for ${DEFAULTS.negTestDays} days and stops you counting as a source. Flags never accuse anyone: they lower the weight of a report or nudge a person to get tested.</p>
      </div>
      <p class="m-cite">Model: <code>model/infer.js</code>, method in <code>model/README.md</code>. After Baker et al., <a href="https://www.pnas.org/doi/full/10.1073/pnas.2106548118">PNAS 118 (2021)</a>, with Rio's dose model (<code>exposure/flu_risk.py</code>). The story and its people are staged.</p>
    </div>`;

  const $ = (s) => el.querySelector(s);
  const svg = $('svg.m-net'), slider = $('.m-time input');
  const NS = 'http://www.w3.org/2000/svg';
  const mk = (tag, attrs = {}, parent) => {
    const n = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
    if (parent) parent.appendChild(n);
    return n;
  };

  const fresh = () => ({ evidence: Object.fromEntries(PEOPLE.map((p) => [p.id, 'none'])), reports: [] });
  let state = fresh();
  state.evidence.Ana = 'might_be_sick';
  let risk = null, contribs = null, tNow = END_MS, focus = 'Cam', selPair = pairKey('Ana', 'Cam'), reportMode = null, timer = null;

  // ---------- graph ----------
  const gEdges = mk('g', {}, svg), gReps = mk('g', {}, svg), gFlows = mk('g', {}, svg), gNodes = mk('g', {}, svg);
  mk('defs', {}, svg).innerHTML = `<marker id="m-arrow" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="${C.fire}"/></marker>
    <marker id="m-arrow-r" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="5" markerHeight="5" orient="auto"><path d="M0 0L10 5L0 10z" fill="#8e3a28"/></marker>`;
  const R = 27;
  const edgeEls = new Map();
  for (const pr of PAIRS) {
    const A = pos[pr.a], B = pos[pr.b];
    const tot = pr.meetings.reduce((s, m) => s + m.min, 0), dmin = Math.min(...pr.meetings.map((m) => m.d));
    const g = mk('g', { class: 'm-edge' + (pr.meetings.every((m) => !m.room) ? ' out' : '') }, gEdges);
    const w = Math.max(1.5, Math.min(9, 1.4 * Math.log2(tot / 10) + 1));
    mk('line', { class: 'hit', x1: A.x, y1: A.y, x2: B.x, y2: B.y }, g);
    mk('line', { class: 'ln', x1: A.x, y1: A.y, x2: B.x, y2: B.y, 'stroke-width': w, 'stroke-opacity': Math.max(0.35, 1 - dmin / 6) }, g);
    const mx = (A.x + B.x) / 2, my = (A.y + B.y) / 2, dx = B.x - A.x, dy = B.y - A.y, L = Math.hypot(dx, dy);
    const nx = -dy / L, ny = dx / L, side = ny > 0 ? -1 : 1;
    pr.side = side;
    const lab = mk('text', { class: 'lab', x: mx + nx * 12 * side, y: my + ny * 12 * side + 4 }, g);
    lab.textContent = `${dur(tot)} · ${dmin} m`;
    g.addEventListener('click', () => { selPair = pr.key; renderAll(); });
    edgeEls.set(pr.key, g);
  }
  const nodeEls = new Map();
  for (const p of PEOPLE) {
    const g = mk('g', { class: 'm-node', transform: `translate(${p.x},${p.y})`, tabindex: 0, role: 'button', 'aria-label': p.id }, gNodes);
    mk('circle', { class: 'body', r: R }, g);
    mk('text', { class: 'nm', y: 5 }, g).textContent = p.id;
    mk('text', { class: 'pc', y: R + 18 }, g);
    const b = mk('g', { class: 'badge', transform: `translate(${R * 0.72},${-R * 0.72})` }, g);
    mk('circle', { r: 10 }, b); mk('text', { y: 5 }, b);
    g.addEventListener('mouseenter', () => { focus = p.id; renderInfo(); });
    g.addEventListener('click', () => clickNode(p.id));
    g.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); clickNode(p.id); } });
    nodeEls.set(p.id, g);
  }

  function clickNode(id) {
    focus = id;
    if (reportMode) {
      if (reportMode === true) { reportMode = id; renderAll(); return; }
      if (reportMode !== id && !state.reports.some((r) => r.by === reportMode && r.target === id)) state.reports.push({ by: reportMode, target: id });
      reportMode = null;
    } else {
      const e = state.evidence[id];
      state.evidence[id] = EVIDENCE[(EVIDENCE.indexOf(e) + 1) % EVIDENCE.length];
    }
    recompute();
  }

  function recompute() {
    risk = runScenario(state);
    contribs = new Map();
    for (const p of PEOPLE) {
      for (const c of risk.explain(p.id, TIMELINE_END_MS, 100).contributions) {
        const k = `${c.other}>${p.id}`;
        (contribs.get(k) || contribs.set(k, []).get(k)).push(c);
      }
    }
    renderAll();
  }
  const flowsAt = (from, to, t) => (contribs.get(`${from}>${to}`) || []).filter((c) => c.learnedMs <= t);
  const hasEvidence = (id) => state.evidence[id] !== 'none' && state.evidence[id] !== 'negative' || state.reports.some((r) => r.target === id);

  function curve(A, B, bend) {
    const mx = (A.x + B.x) / 2, my = (A.y + B.y) / 2, dx = B.x - A.x, dy = B.y - A.y, L = Math.hypot(dx, dy);
    const cx = mx - (dy / L) * bend, cy = my + (dx / L) * bend;
    const sx = A.x + ((cx - A.x) / Math.hypot(cx - A.x, cy - A.y)) * (R + 4), sy = A.y + ((cy - A.y) / Math.hypot(cx - A.x, cy - A.y)) * (R + 4);
    const ex = B.x + ((cx - B.x) / Math.hypot(cx - B.x, cy - B.y)) * (R + 8), ey = B.y + ((cy - B.y) / Math.hypot(cx - B.x, cy - B.y)) * (R + 8);
    const k = 1.7;
    return { d: `M${sx},${sy} Q${cx},${cy} ${ex},${ey}`, lx: mx - (dy / L) * bend * k, ly: my + (dx / L) * bend * k };
  }

  function renderGraph() {
    for (const p of PEOPLE) {
      const g = nodeEls.get(p.id), P = risk.pAt(p.id, tNow), e = state.evidence[p.id];
      g.querySelector('circle.body').setAttribute('fill', riskColor(P));
      g.querySelector('.pc').textContent = pct(P);
      const b = g.querySelector('.badge');
      const shown = tNow >= REPORT_MS && e !== 'none';
      b.style.display = shown ? '' : 'none';
      b.querySelector('text').textContent = BADGE[e] || '';
      g.classList.toggle('pick', reportMode === p.id);
    }
    for (const pr of PAIRS) {
      const g = edgeEls.get(pr.key);
      g.classList.toggle('future', pr.meetings[0].ms > tNow);
      g.classList.toggle('sel', pr.key === selPair);
    }
    gFlows.innerHTML = ''; gReps.innerHTML = '';
    for (const pr of PAIRS) {
      for (const [from, to] of [[pr.a, pr.b], [pr.b, pr.a]]) {
        const fl = flowsAt(from, to, tNow);
        const delta = fl.reduce((s, c) => s + c.delta, 0);
        if (delta < 0.0005) continue;
        const second = !hasEvidence(from);
        const c = curve(pos[from], pos[to], -18 * pr.side * (from === pr.a ? 1 : -1));
        mk('path', { class: 'm-flow' + (second ? ' second' : ''), d: c.d, 'stroke-width': second ? 2.5 : Math.min(7, 2.5 + delta * 40), 'marker-end': 'url(#m-arrow)' }, gFlows);
        mk('text', { class: 'm-flowlab', x: c.lx, y: c.ly + 4 }, gFlows).textContent = `+${(delta * 100).toFixed(delta < 0.01 ? 2 : 1)}`;
      }
    }
    if (tNow >= REPORT_MS) {
      for (const r of state.reports) {
        const c = curve(pos[r.by], pos[r.target], -40);
        mk('path', { class: 'm-rep', d: c.d, 'marker-end': 'url(#m-arrow-r)' }, gReps);
        mk('text', { class: 'm-replab', x: c.lx, y: c.ly }, gReps).textContent = 'reports';
      }
    }
    $('.m-time .now').textContent = when(tNow);
    slider.value = tNow;
  }

  function renderSide() {
    $('[data-act=report]').classList.toggle('on', !!reportMode);
    $('.m-hint').innerHTML = reportMode === true ? '<b>Who is reporting?</b> Click the reporter.'
      : reportMode ? `<b>${reportMode}</b> reports… click the person they think is sick.`
        : 'Click a person: no report → “might be sick” → positive test → negative test.';
    const fl = risk.flags.filter((f) => f.tMs <= tNow);
    $('.m-flags').innerHTML = fl.length ? fl.map((f) => `<span class="pill fl" title="${f.detail}">⚑ ${f.agentId}: ${f.kind}</span>`).join('') : '<span class="muted" style="font-size:13px">No trust flags</span>';
  }

  function renderInfo() {
    const id = focus, P = risk.pAt(id, tNow), e = state.evidence[id];
    const rows = [];
    for (const other of PEOPLE.map((p) => p.id)) {
      const fl = flowsAt(other, id, tNow);
      const d = fl.reduce((s, c) => s + c.delta, 0);
      if (d >= 0.0001) rows.push({ other, d, retro: fl.some((c) => c.retro), second: !hasEvidence(other) });
    }
    rows.sort((a, b) => b.d - a.d);
    const reps = state.reports.filter((r) => r.target === id).map((r) => r.by);
    const ev = tNow < REPORT_MS ? 'nothing reported yet' : [e !== 'none' ? EVIDENCE_LABEL[e] : '', reps.length ? `reported by ${reps.join(', ')}` : ''].filter(Boolean).join(' · ') || 'no report';
    $('.m-info').innerHTML = `
      <div class="m-who"><b>${id}</b><span class="muted">${when(tNow)}</span></div>
      <div class="m-big" style="margin-top:6px">${pct(P)}</div>
      <div class="muted" style="font-size:14px;margin-top:4px">${ev}</div>
      <ul class="m-why">${rows.length ? rows.slice(0, 4).map((r) => `<li><span>from ${r.other} ${r.retro ? '<span class="pill lb">look-back</span>' : ''} ${r.second ? '<span class="pill sh">second-hand</span>' : ''}</span><span>+${(r.d * 100).toFixed(2)} pts</span></li>`).join('')
        : `<li><span class="muted">${P >= DEFAULTS.prior + 0.0005 || P < DEFAULTS.prior - 0.0005 ? 'set by their own evidence' : `campus baseline: ${pct(DEFAULTS.prior, 0)}`}</span></li>`}</ul>`;
  }

  // ---------- part 2: the selected edge's numbers ----------
  function renderFormula() {
    const pr = PAIRS.find((p) => p.key === selPair);
    let best = null;
    for (const [from, to] of [[pr.a, pr.b], [pr.b, pr.a]]) {
      for (const c of contribs.get(`${from}>${to}`) || []) if (!best || c.delta > best.c.delta) best = { c, from, to };
    }
    const box = $('.m-formula');
    const m = best ? pr.meetings.reduce((a, b) => (Math.abs(b.ms - best.c.tMs) < Math.abs(a.ms - best.c.tMs) ? b : a)) : pr.meetings[0];
    const room = m.room ? ROOMS.get(m.room) : null;
    const head = `<div class="m-edgehead">${best ? `${best.from} → ${best.to}` : `${pr.a} – ${pr.b}`} · ${m.what || 'meeting'}, ${when(m.ms)} · ${dur(m.min)} at ${m.d} m · ${room ? `${room.label}, ${room.volume_m3} m³` : 'outdoors'}</div>`;
    if (!best) {
      const { unit, info } = calcDose({ minutes: m.min, distance: m.d, roomM2: room ? room.volume_m3 / DEFAULTS.ceilingM : 50, indoor: !!room, ach: room ? room.ventilation_ach : 2 });
      const q = room && room.room_type.startsWith('dorm') ? DEFAULTS.quietQuanta : DEFAULTS.quantaPeak;
      const dose = unit * q / info.quanta;
      box.innerHTML = `${head}<p class="m-note" style="font-size:17px">Nothing flowed here: neither person had evidence (or a first-hand exposure) at the time. Click someone to report them.</p>
        <dl class="m-eq"><dt>dose at peak</dt><dd class="math"><span class="res">${num(dose)}</span></dd>
        <dt>λ if infectious</dt><dd class="math"><span class="res">${pct(1 - Math.exp(-dose))}</span></dd></dl>`;
      return;
    }
    const c = best.c, t = c.durationMin / 60, d = Math.max(c.distanceM, 0.3), q = c.quanta * c.stage;
    const qNear = DEFAULTS.nearFieldQ * d * d * (c.indoor ? 1 : DEFAULTS.outdoorNearDilution);
    const secondHand = !hasEvidence(best.from);
    const stageTxt = secondHand ? 'stage unknown: illness average' : c.retro ? `${Math.ceil((REPORT_MS - c.tMs) / DAY)} day before the report` : 'after the report';
    const lamPair = 1 - Math.exp(-c.pairDose), A = c.otherRisk * lamPair;
    const P = risk.pAt(best.to, END_MS);
    const ownEv = hasEvidence(best.to) || state.evidence[best.to] === 'negative';
    const sTxt = secondHand ? `${best.from} was only exposed: <i>α</i>·<i>x</i><sub>${best.from}</sub>` : best.from + "'s evidence";
    box.innerHTML = `${head}
      <dl class="m-eq">
        <dt>emission</dt><dd class="math"><i>q</i> = quanta·stage = ${c.quanta} × ${num(c.stage, 2)} = <b>${num(q, 2)}</b>/h <span class="v">(${stageTxt}${c.quanta < DEFAULTS.quantaPeak ? '; quiet in a dorm' : ''})</span></dd>
        <dt>near field</dt><dd class="math"><i>q</i><sub>near</sub> = ${DEFAULTS.nearFieldQ}·<i>d</i>²${c.indoor ? '' : '·5'} = <b>${num(qNear, 1)}</b> m³/h</dd>
        ${c.indoor ? `<dt>room</dt><dd class="math"><i>V</i>·loss = ${num(c.roomVolume, 1)} × (${c.roomAch} + ${DEFAULTS.deposition} + ${num(risk.params.virusDecay, 2)}) = <b>${num(c.roomVolume * c.roomLoss, 0)}</b> m³/h</dd>` : ''}
        <dt>dose</dt><dd class="math"><i>q</i>·<i>B</i>·<i>t</i>·(${fr(1, '<i>q</i><sub>near</sub>')}${c.indoor ? ` + ${fr(1, '<i>V</i>·loss')}` : ''}) = ${num(q, 2)}·${DEFAULTS.breathingRate}·${num(t, 2)}·(${fr(1, num(qNear, 1))}${c.indoor ? ` + ${fr(1, num(c.roomVolume * c.roomLoss, 0))}` : ''}) = <span class="res">${num(c.dose)}</span></dd>
        <dt>infection</dt><dd class="math"><i>λ</i> = 1 − <i>e</i><sup>−dose</sup> = <span class="res">${pct(c.transmission, 2)}</span>${Math.abs(c.pairDose - c.dose) > 1e-6 ? ` <span class="v">(pair total: ${pct(lamPair, 2)})</span>` : ''}</dd>
        <dt>source</dt><dd class="math"><i>s</i> = <b>${num(c.otherRisk, 3)}</b> <span class="v">(${sTxt})</span></dd>
        <dt>pair share</dt><dd class="math"><i>A</i> = <i>s</i>·<i>λ</i><sub>pair</sub> = ${num(c.otherRisk, 3)} × ${num(lamPair, 4)} = <span class="res">${pct(A, 2)}</span></dd>
        <dt>${best.to}'s P</dt><dd class="math"><i>P</i> = 1 − (1 − prior)(1 − <i>x</i>) = <span class="res">${pct(P)}</span></dd>
      </dl>
      <p class="m-note">${c.retro ? `Learned ${when(c.learnedMs)}: the contact was on ${when(c.tMs)}, before the report, so it counts by <b>look-back</b>.` : `Counted live, at ${when(c.tMs)}.`} <i>x</i> sums all of ${best.to}'s exposures and fades as a flu would run its course (mean ${DEFAULTS.illnessMeanDays} days).
      ${ownEv ? ` ${best.to} has evidence of their own, so their P is raised to (or capped at) that level.` : ''}</p>`;
  }

  // ---------- part 2: calculator ----------
  const calc = { min: 500, dist: 1, room: 400, p: 60, stage: 0, out: false };
  const logMap = (v, lo, hi) => lo * (hi / lo) ** (v / 1000);
  const minutesOf = (v) => Math.max(1, Math.round(logMap(v, 1, 480)));
  const roomOf = (v) => Math.round(logMap(v, 5, 1000));
  const stageSvg = $('svg.m-stage');
  function renderStage() {
    const prof = DEFAULTS.stageProfile, w = 38;
    stageSvg.innerHTML = `<text x="210" y="11" style="font-size:12.5px;fill:var(--ink-2)">their stage: days since symptoms (click)</text>` + prof.map((v, k) => {
      const day = k - 2, h = v * 52, x = 20 + k * w;
      return `<g data-day="${day}" class="${day === calc.stage ? 'sel' : ''}"><rect x="${x}" y="${72 - h}" width="${w - 8}" height="${Math.max(h, 2)}" rx="4" fill="${riskColor(0.02 + v * 0.95)}"/>
        <rect x="${x - 2}" y="16" width="${w - 4}" height="62" fill="transparent"/><text x="${x + (w - 8) / 2}" y="88">${day > 0 ? '+' : ''}${day}</text></g>`;
    }).join('');
    stageSvg.querySelectorAll('g[data-day]').forEach((g) => g.addEventListener('click', () => { calc.stage = +g.dataset.day; renderCalc(); }));
  }
  function renderCalc() {
    el.querySelectorAll('.m-calc input[type=range]').forEach((inp) => { calc[inp.dataset.k] = +inp.value; });
    calc.out = $('.m-calc input[data-k=out]').checked;
    const minutes = minutesOf(calc.min), roomM2 = calc.out ? null : roomOf(calc.room), s = calc.p / 100;
    const outs = el.querySelectorAll('.m-calc output');
    outs[0].textContent = dur(minutes); outs[1].textContent = `${calc.dist.toFixed(1)} m`;
    outs[2].textContent = roomM2 ? `${roomM2} m²` : 'outside'; outs[3].textContent = `${calc.p}%`;
    const stage = DEFAULTS.stageProfile[calc.stage + 2];
    const { unit } = calcDose({ minutes, distance: calc.dist, roomM2: roomM2 || 50, indoor: !!roomM2 });
    const dose = stage * unit, lam = 1 - Math.exp(-dose), prior = DEFAULTS.prior;
    const P = 1 - (1 - prior) * (1 - s * lam);
    $('.m-calcout').innerHTML = `<span class="m-big">${pct(P)}</span><span>your P after<br><span class="muted" style="font-size:14px">from ${pct(prior, 0)}: 1 − (1 − ${prior})(1 − ${s.toFixed(2)} × ${num(lam, 4)})</span></span>
      <span class="muted" style="font-size:14px">dose ${num(dose)} · λ ${pct(lam, 2)}${roomM2 ? ' · 2 air changes/h' : ''} · same rule as <code>exposure/</code></span>`;
    renderStage();
  }
  el.querySelectorAll('.m-calc input').forEach((inp) => inp.addEventListener('input', renderCalc));

  // ---------- evidence bars ----------
  const bar = (label, v, col, txt) => `<div class="m-bar"><span>${label}</span><span class="tr"><i style="width:${v * 100}%;background:${col}"></i></span><b>${txt ?? pct(v, v < 0.1 ? 1 : 0)}</b></div>`;
  $('.m-evbars').innerHTML = [
    bar('Nobody knows anything (prior)', DEFAULTS.prior, C.sage),
    bar('Someone reports you', DEFAULTS.reportOther, C.sun),
    bar('… with no contact in 48 h', DEFAULTS.reportOther * DEFAULTS.unsupportedWeight, C.sun),
    bar('“I might be sick”', DEFAULTS.selfReport, C.ember),
    bar('Positive test', DEFAULTS.posTest, C.fire),
    bar('Negative test (cap)', DEFAULTS.negTest, C.sage, `≤ ${pct(DEFAULTS.negTest, 0)}`),
  ].join('');
  $('.m-trustbars').innerHTML = [
    bar('Report about someone', DEFAULTS.reportOther, C.sun),
    bar('Self-report', DEFAULTS.selfReport, C.ember),
    bar('Positive test', DEFAULTS.posTest, C.fire),
  ].join('');

  // ---------- part 3: flags ----------
  const ex = flagExamples();
  const STORY = {
    unexpected_report: ['A sat 3 m from B in one lecture; nobody sick', 'A says “I might be sick”'],
    silent_high_risk: ['A tests positive', 'B spends 8 h at 1 m with A', 'B never reports anything'],
    suspicious_recovery: ['A says “I might be sick”', '24 h later: “I’m recovered”'],
    report_other_unsupported: ['A only ever met C', 'A reports B as sick'],
  };
  const WHY = {
    unexpected_report: 'False report, or caught it off the network',
    silent_high_risk: 'Nudge: you should get tested',
    suspicious_recovery: 'Flu lasts 5–7 days: kept at 60% until day 3',
    report_other_unsupported: 'Report still counts, at half weight',
  };
  $('.m-flaggrid').innerHTML = Object.keys(STORY).map((k) => {
    const f = ex[k].find((x) => x.kind === k);
    return `<div class="card m-flag"><code class="k">${k}</code><div class="when">${FLAG_TEXT[k]}</div>
      <ol>${STORY[k].map((s) => `<li>${s}</li>`).join('')}</ol>
      <div class="out">${f ? `⚑ ${f.agentId}: ${f.detail}` : 'no flag'}</div><p class="why">→ ${WHY[k]}</p></div>`;
  }).join('');

  // ---------- timeline + controls ----------
  const span = TIMELINE_END_MS - START_MS;
  const tick = (ms, txt, cls = '') => `<span class="${cls}" style="left:${((ms - START_MS) / span) * 100}%">${txt}</span>`;
  $('.m-ticks').innerHTML = [0, 1, 3].map((d) => tick(START_MS + d * DAY + (d === 0 ? 2 * HOUR : 0), DAYS[(1 + d) % 7])).join('') + tick(REPORT_MS, 'Wed ▲ reports 09:00', 'rep');
  slider.addEventListener('input', () => { stop(); tNow = +slider.value; renderAll(); });
  const playBtn = $('[data-act=play]');
  function stop() { if (timer) { clearInterval(timer); timer = null; playBtn.textContent = '▶ Play'; } }
  playBtn.addEventListener('click', () => {
    if (timer) return stop();
    if (tNow >= TIMELINE_END_MS) tNow = START_MS;
    playBtn.textContent = '❚❚ Pause';
    timer = setInterval(() => {
      tNow = Math.min(TIMELINE_END_MS, tNow + 20 * MIN);
      renderAll();
      if (tNow >= TIMELINE_END_MS) stop();
    }, 40);
  });
  $('[data-act=report]').addEventListener('click', () => { reportMode = reportMode ? null : true; if (tNow < REPORT_MS) tNow = END_MS; renderAll(); });
  $('[data-act=reset]').addEventListener('click', () => {
    stop(); state = fresh(); state.evidence.Ana = 'might_be_sick'; reportMode = null; tNow = END_MS; focus = 'Cam'; selPair = pairKey('Ana', 'Cam'); recompute();
  });

  function renderAll() { renderGraph(); renderSide(); renderInfo(); renderFormula(); }
  recompute();
  renderCalc();
}
