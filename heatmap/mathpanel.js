// The maths behind one person's risk, for the presenter: a contact graph, the transmission formula
// with the real numbers filled in, and the evidence on record. Everything comes from the model's
// explain() result (what a phone could know); nothing here reads the simulation's ground truth.
//
// renderMathPanel(container, { agentId, tMs, explain, params, formatTime }) can be called often;
// it rebuilds the panel's contents each time. Styles are injected once, scoped under .mathpanel.

const NS = 'http://www.w3.org/2000/svg';
const W = 280, H = 180, MAX_NODES = 6;
const TIER_LABEL = ['<1 m', '1-2 m', '2-5 m', 'same room'];
// edge look per distance tier: closer = more solid
const TIER_LOOK = [
  { dash: '', op: 1 }, { dash: '', op: 0.7 }, { dash: '5 3', op: 0.6 }, { dash: '1.5 3.5', op: 0.5 },
];

const CSS = `
.mathpanel { font: 13px/1.45 var(--font, system-ui, sans-serif); color: var(--ink, #33241c);
  background: var(--surface, #fffaf1); border-radius: var(--radius, 12px); box-shadow: var(--shadow);
  padding: 14px 16px; }
.mathpanel h3 { margin: 0 0 8px; font-size: 15px; font-weight: 600; }
.mathpanel h4 { margin: 14px 0 4px; font-size: 11px; font-weight: 600; letter-spacing: .05em;
  text-transform: uppercase; color: var(--ink-3, #7a6152); }
.mathpanel svg { display: block; width: 100%; max-width: 280px; height: auto; background: var(--surface-2, #f4ead6);
  border-radius: 8px; }
.mathpanel .mp-edge { stroke: var(--ink-2, #6a5244); stroke-linecap: round; }
.mathpanel .mp-node { fill: var(--surface, #fffaf1); stroke: var(--ink-2, #6a5244); stroke-width: 1.5; }
.mathpanel .mp-self { fill: var(--ink, #33241c); stroke: none; }
.mathpanel .mp-id { font-size: 10px; font-weight: 600; fill: var(--ink, #33241c); }
.mathpanel .mp-risk { font-size: 10px; fill: var(--fire-ink, #8e3a28); font-variant-numeric: tabular-nums; }
.mathpanel .mp-tag { font-size: 8.5px; fill: var(--ink-3, #7a6152); font-style: italic; }
.mathpanel .mp-key { margin: 4px 0 0; font-size: 11px; color: var(--ink-3, #7a6152); }
.mathpanel .mp-f { margin: 2px 0; font-variant-numeric: tabular-nums; }
.mathpanel .mp-f b { color: var(--fire-ink, #8e3a28); font-weight: 600; }
.mathpanel .mp-note { margin: 2px 0 0; font-size: 12px; color: var(--ink-2, #6a5244); }
.mathpanel ul { margin: 0; padding: 0; list-style: none; }
.mathpanel li { padding: 2px 0; color: var(--ink-2, #6a5244); }
.mathpanel li time { color: var(--ink-3, #7a6152); font-variant-numeric: tabular-nums; margin-right: 6px; }
.mathpanel .mp-off { color: var(--ink-3, #7a6152); text-decoration: line-through; }
.mathpanel .mp-truth { margin: 12px -16px -14px; padding: 10px 16px 12px; border-radius: 0 0 var(--radius, 12px) var(--radius, 12px);
  background: var(--surface-2, #f4ead6); font-size: 12px; color: var(--ink-2, #6a5244); }
.mathpanel .mp-truth b { color: var(--ink, #33241c); font-weight: 600; }
.mathpanel .mp-foot { margin: 14px 0 0; font-size: 11.5px; color: var(--ink-3, #7a6152); }
`;

const pct = (x) => `${(x * 100).toFixed(x < 0.1 ? 1 : 0)}%`;
const num = (x, d = 3) => String(+x.toFixed(d));

function el(tag, attrs = {}, kids = []) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) k === 'text' ? (e.textContent = v) : e.setAttribute(k, v);
  for (const c of [].concat(kids)) e.append(c);
  return e;
}
function svg(tag, attrs = {}, text) {
  const e = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (text !== undefined) e.textContent = text;
  return e;
}
const sub = (s) => el('sub', { text: s });
const sup = (s) => el('sup', { text: s });

export function renderMathPanel(container, { agentId, tMs, explain, params, formatTime, flags = [], traits }) {
  if (!document.getElementById('mathpanel-style')) {
    document.head.append(el('style', { id: 'mathpanel-style', text: CSS }));
  }
  const root = el('div', { class: 'mathpanel' });
  root.append(el('h3', { text: `Why ${agentId} is at ${pct(explain.p)}` }));

  const contribs = explain.contributions || [];
  if (!contribs.length) {
    root.append(el('p', { class: 'mp-note', text: (explain.evidence || []).length
      ? `No risky contacts on record: ${pct(explain.p)} comes from the evidence below.`
      : `No risky contacts yet: ${pct(explain.p)} is the community baseline.` }));
  } else {
    root.append(el('h4', { text: 'Contact graph' }), graph(agentId, contribs));
    root.append(el('p', { class: 'mp-key', text: 'Thicker = more minutes. Solid = closer. Red = risk the app knew.' }));
    root.append(el('h4', { text: 'Top contact, with numbers' }), formula(contribs[0], explain, params));
    root.append(el('h4', { text: 'All contacts together' }), combined(contribs, explain, params));
  }

  root.append(el('h4', { text: 'Evidence on record' }), evidenceList(explain.evidence || [], formatTime));
  if (flags.length) root.append(el('h4', { text: 'Doesn’t add up' }), flagList(flags, formatTime));
  root.append(el('p', { class: 'mp-foot', text: 'Only what a phone could know: contacts, reports, tests. Never the simulation’s ground truth.' }));
  if (traits) root.append(traitBox(traits));
  container.replaceChildren(root);
}

// One node per person (contributions merged by `other`), agent in the centre.
function graph(agentId, contribs) {
  const byOther = new Map();
  for (const c of contribs) {
    const m = byOther.get(c.other);
    if (!m) byOther.set(c.other, { ...c });
    else {
      m.durationMin += c.durationMin;
      m.distanceTier = Math.min(m.distanceTier, c.distanceTier);
      m.otherRisk = Math.max(m.otherRisk, c.otherRisk);
      m.retro = m.retro || c.retro;
    }
  }
  const nodes = [...byOther.values()].sort((a, b) => b.durationMin - a.durationMin).slice(0, MAX_NODES);
  const maxMin = Math.max(...nodes.map((n) => n.durationMin), 1);
  const cx = W / 2, cy = H / 2, rx = 98, ry = 52;
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': `Contacts of ${agentId}` });
  const pos = nodes.map((_, i) => {
    const a = -Math.PI / 2 + ((i + 0.5) / nodes.length) * 2 * Math.PI;
    return [cx + rx * Math.cos(a), cy + ry * Math.sin(a)];
  });
  nodes.forEach((n, i) => {
    const look = TIER_LOOK[Math.min(3, Math.max(0, n.distanceTier - 1))];
    const e = svg('line', { class: 'mp-edge', x1: cx, y1: cy, x2: pos[i][0], y2: pos[i][1],
      'stroke-width': (1 + 4 * Math.sqrt(n.durationMin / maxMin)).toFixed(1), 'stroke-opacity': look.op });
    if (look.dash) e.setAttribute('stroke-dasharray', look.dash);
    e.append(svg('title', {}, `${n.other}: ${num(n.durationMin, 0)} min, ${TIER_LABEL[n.distanceTier - 1] || ''}`));
    s.append(e);
  });
  nodes.forEach((n, i) => {
    const [x, y] = pos[i];
    const below = y >= cy; // labels go away from the centre so they don't sit on the edge
    const ly = below ? y + 15 : y - 17;
    s.append(svg('circle', { class: 'mp-node', cx: x, cy: y, r: 5 }));
    s.append(svg('text', { class: 'mp-id', x, y: ly, 'text-anchor': 'middle' }, n.other));
    s.append(svg('text', { class: 'mp-risk', x, y: ly + 10, 'text-anchor': 'middle' }, `risk ${pct(n.otherRisk)}`));
    if (n.retro) s.append(svg('text', { class: 'mp-tag', x, y: ly + (below ? 19 : -10), 'text-anchor': 'middle' }, 'later report'));
  });
  s.append(svg('circle', { class: 'mp-self', cx, cy, r: 7 }));
  return s;
}

function formula(c, explain, params) {
  const beta = params.beta, w = params.tierWeight[c.distanceTier - 1];
  const lam = beta * w * c.durationMin;
  const pi = c.transmission, s = c.otherRisk, base = explain.prior;
  const after = 1 - (1 - base) * (1 - s * pi);
  const f1 = el('p', { class: 'mp-f' }, [
    'π = 1 − e', sup('−β·w·min'), ' = 1 − e',
    sup(`−${num(beta)}·${num(w)}·${num(c.durationMin, 0)}`), ' = ',
    el('b', { text: num(pi) }),
  ]);
  const f2 = el('p', { class: 'mp-f' }, [
    'p ← 1 − (1 − p)(1 − s·π) = 1 − (1 − ', num(base), ')(1 − ',
    num(s), '·', num(pi), ') = ', el('b', { text: num(after) }),
  ]);
  const why = `${c.other}, ${num(c.durationMin, 0)} min at ${TIER_LABEL[c.distanceTier - 1] || 'unknown range'}`
    + `${c.retro ? ', counted after a later report' : ''}. Adds ${pct(c.delta)} to p.`;
  const note = el('p', { class: 'mp-note', text: why });
  const out = [f1, f2, note];
  if (Math.abs(1 - Math.exp(-lam) - pi) > 0.005) {
    out.push(el('p', { class: 'mp-key', text: 'Minutes sum merged contacts; π is the model’s combined value.' }));
  }
  return el('div', {}, out);
}

function evidenceList(evidence, formatTime) {
  if (!evidence.length) return el('p', { class: 'mp-note', text: 'None yet.' });
  const what = (e) => {
    if (e.kind === 'self_report') return e.value === 'tested_positive' ? 'self-reported a positive test'
      : e.value === 'recovered' ? 'reported recovered' : 'self-reported might be sick';
    if (e.kind === 'report_other') return `reported by ${e.by} as might be sick`;
    return `test came back ${e.value}`;
  };
  return el('ul', {}, evidence.map((e) => el('li', e.active === false ? { class: 'mp-off' } : {}, [
    el('time', { text: formatTime(e.tMs) }), what(e), e.active === false ? ' (expired)' : '',
  ])));
}

// Lie detection (model flags): what the app noticed that doesn't fit, in plain words.
const FLAG_LABEL = {
  unexpected_report: 'Reported sick with no risky contact on record',
  report_other_unsupported: 'Reported someone they weren’t near',
  suspicious_recovery: 'Claimed recovery too soon; not believed yet',
  silent_high_risk: 'High risk for hours but hasn’t reported',
};
function flagList(flags, formatTime) {
  return el('ul', {}, flags.map((f) => el('li', { title: f.detail }, [
    el('time', { text: formatTime(f.tMs) }), FLAG_LABEL[f.kind] || f.kind,
  ])));
}

// Presenter only: the simulation's hidden traits for this person, so the audience can check the flags.
function traitBox(t) {
  const n = (x) => num(Number(x), 2);
  const yes = (x) => String(x).toLowerCase() === 'true';
  // Altruistic = stays home when sick (WORKSTREAMS decision); carry_on goes out anyway.
  const sickPlan = t.sickness_behavior_profile;
  const altruism = !sickPlan ? '' : sickPlan === 'carry_on' ? 'Not altruistic: keeps going out when sick. '
    : `Altruistic: ${sickPlan === 'stay_home' ? 'stays home' : 'visits Vaden, then isolates'} when sick. `;
  return el('p', { class: 'mp-truth' }, [
    el('b', { text: 'Presenter only (sim truth): ' }), altruism,
    `${t.archetype || 'student'}, honesty ${n(t.honesty)}, compliance ${n(t.compliance)}, `
      + `${yes(t.has_app) ? 'has the app' : 'no app'}, ${yes(t.shares_location) ? 'shares location' : 'location private'}.`,
  ]);
}

// From one contact to the headline: every contact folds into one exposure x (capped), then the prior.
// x is read back from p, so it is exact whenever exposure (not a report or test) sets p.
function combined(contribs, explain, params) {
  const { p, prior } = explain;
  const evidenceSets = (explain.evidence || []).some((e) => e.active !== false) && p >= 0.35;
  if (evidenceSets) return el('p', { class: 'mp-note', text: `Here the evidence below, not contact, sets ${pct(p)}.` });
  const x = Math.max(0, 1 - (1 - p) / (1 - prior));
  const capped = params.xMax != null && x >= params.xMax - 0.005;
  const people = new Set(contribs.map((c) => c.other)).size;
  return el('div', {}, [
    el('p', { class: 'mp-f' }, ['x = 1 − ∏(1 − s·π) = ', el('b', { text: num(x) }),
      capped ? ` (capped at ${num(params.xMax)})` : '']),
    el('p', { class: 'mp-f' }, ['p = 1 − (1 − ', num(prior), ')(1 − ', num(x), ') = ', el('b', { text: num(p) })]),
    el('p', { class: 'mp-note', text: `${contribs.length} contact${contribs.length > 1 ? 's' : ''} with ${people} `
      + `${people > 1 ? 'people' : 'person'} listed, plus smaller ones and second-hand risk.`
      + (capped ? ' Contact alone never takes anyone past this: household flu attack rates are 10–40%.' : '') }),
  ]);
}
