// Simulations section: how the campus simulator works, and app vs no app (demo/data/compare.json).
const RUN = '../sim/runs/influenza_none_n1000_d14_s42_f12e71fa';
const SVGNS = 'http://www.w3.org/2000/svg';
const COL = { none: 'var(--ink-3)', fluni: 'var(--fire)' };
const PROFILE = {
  stay_home: ['Stays home', 'var(--sage)'],
  visit_vaden_then_isolate: ['Vaden, then isolates', '#c9d3a9'],
  carry_on: ['Carries on', 'var(--ember)'],
};
const LOC = {
  dorm: 'Dorm', common_room: 'Common room', party_venue: 'Party', library: 'Library', dining: 'Dining',
  off_campus: 'Off campus', classroom: 'Class', other: 'Other',
};

const CSS = `
#results .rs-how { display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-bottom: 14px; }
#results .rs-how .card { padding: 14px 16px; }
#results .rs-big { font-size: 30px; font-weight: 600; line-height: 1.1; }
#results .rs-how .muted { font-size: 14px; line-height: 1.35; margin-top: 4px; }
#results .rs-beh { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 34px; }
#results .rs-bar { display: flex; height: 34px; border-radius: 8px; overflow: hidden; margin: 8px 0 6px; }
#results .rs-bar span { display: flex; align-items: center; justify-content: center; font-size: 14px; font-weight: 600; color: var(--ink); white-space: nowrap; }
#results .rs-legend { display: flex; flex-wrap: wrap; gap: 4px 14px; font-size: 14px; color: var(--ink-2); }
#results .rs-legend i { display: inline-block; width: 11px; height: 11px; border-radius: 3px; margin-right: 5px; vertical-align: -1px; }
#results h3 { margin: 0 0 4px; font-size: 22px; font-weight: 600; }
#results .rs-setup { margin: 0 0 14px; display: flex; flex-wrap: wrap; gap: 6px; }
#results .rs-charts { display: grid; grid-template-columns: 1.35fr 1fr; gap: 14px; margin-bottom: 14px; }
#results .rs-charts2 { display: grid; grid-template-columns: 1.35fr 1fr; gap: 14px; margin-bottom: 14px; }
#results .card h4 { margin: 0 0 6px; font-size: 16px; font-weight: 600; }
#results svg { display: block; width: 100%; height: auto; font-family: var(--font); }
#results svg text { fill: var(--ink-2); font-size: 12px; }
#results svg .ax { stroke: var(--hairline); }
#results .rs-verdict { display: grid; grid-template-columns: 1fr 1.3fr 1fr; gap: 14px; }
#results .rs-verdict p, #results .rs-verdict li { font-size: 15px; line-height: 1.45; margin: 0 0 6px; }
#results .rs-verdict ul { margin: 0; padding-left: 18px; }
#results .rs-tag { font-size: 12px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--fire-ink); }
#results .rs-alerts { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 14px; }
#results .rs-alerts b { display: block; font-size: 24px; }
#results .rs-alerts span { font-size: 13px; color: var(--ink-3); }
#results .rs-foot { margin-top: 18px; font-size: 15px; }
`;

const fmt = (n) => n.toLocaleString('en-US');
const pct = (x, d = 1) => `${(x * 100).toFixed(d)}%`;
const mean = (a) => a.reduce((s, v) => s + v, 0) / a.length;

function svg(w, h) {
  const s = document.createElementNS(SVGNS, 'svg');
  s.setAttribute('viewBox', `0 0 ${w} ${h}`);
  return s;
}
function add(parent, tag, attrs = {}, text) {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (text != null) e.textContent = text;
  parent.appendChild(e);
  return e;
}

function dailyChart(runs) {
  const W = 620, H = 250, L = 36, R = 92, T = 10, B = 30;
  const s = svg(W, H);
  const days = runs[0].daily_incidence.length;
  // day 0 holds the 30 seeded cases; start the plot at day 1 so the spread is readable
  const maxY = Math.ceil(Math.max(...runs.flatMap((r) => r.daily_incidence.slice(1))) / 10) * 10;
  const x = (d) => L + ((d - 1) / (days - 2)) * (W - L - R);
  const y = (v) => H - B - (v / maxY) * (H - T - B);
  for (let v = 0; v <= maxY; v += 10) {
    add(s, 'line', { x1: L, x2: W - R, y1: y(v), y2: y(v), class: 'ax' });
    add(s, 'text', { x: L - 6, y: y(v) + 4, 'text-anchor': 'end' }, v);
  }
  for (let d = 1; d < days; d += 2) add(s, 'text', { x: x(d), y: H - 10, 'text-anchor': 'middle' }, `d${d}`);
  for (const r of runs) {
    const pts = r.daily_incidence.slice(1).map((v, k) => `${x(k + 1)},${y(v)}`).join(' ');
    add(s, 'polyline', {
      points: pts, fill: 'none', stroke: COL[r.intervention], 'stroke-width': 2.5,
      'stroke-dasharray': r.intervention === 'none' ? '5 4' : '', 'stroke-linejoin': 'round', opacity: 0.9,
    });
    const last = r.daily_incidence[days - 1];
    add(s, 'text', { x: W - R + 6, y: y(last) + 4, style: `fill:${COL[r.intervention]};font-weight:600` },
      `${r.intervention === 'none' ? 'no app' : 'FlUni'} s${r.seed}`);
  }
  // nudge overlapping end labels apart
  const labels = [...s.querySelectorAll('text')].filter((t) => /s\d+$/.test(t.textContent));
  labels.sort((a, b) => a.getAttribute('y') - b.getAttribute('y'));
  for (let k = 1; k < labels.length; k++) {
    const prev = +labels[k - 1].getAttribute('y');
    if (+labels[k].getAttribute('y') < prev + 13) labels[k].setAttribute('y', prev + 13);
  }
  return s;
}

function attackChart(runs) {
  const seeds = [...new Set(runs.map((r) => r.seed))];
  const groups = [...seeds.map((sd) => ({ name: `seed ${sd}`, v: ['none', 'fluni'].map((iv) => runs.find((r) => r.seed === sd && r.intervention === iv).attack_rate) })),
    { name: 'mean', v: ['none', 'fluni'].map((iv) => mean(runs.filter((r) => r.intervention === iv).map((r) => r.attack_rate))) }];
  const W = 420, H = 250, L = 10, T = 22, B = 30, bw = 34;
  const s = svg(W, H);
  const maxY = 0.35;
  const y = (v) => H - B - (v / maxY) * (H - T - B);
  const gw = (W - L * 2) / groups.length;
  add(s, 'line', { x1: L, x2: W - L, y1: y(0), y2: y(0), class: 'ax' });
  groups.forEach((g, k) => {
    const cx = L + gw * (k + 0.5);
    g.v.forEach((v, j) => {
      const bx = cx + (j - 1) * (bw + 4) + 2;
      add(s, 'rect', { x: bx, y: y(v), width: bw, height: y(0) - y(v), rx: 4,
        fill: j ? 'var(--fire)' : 'var(--surface-3)', stroke: j ? 'none' : 'var(--ink-3)', 'stroke-width': j ? 0 : 1 });
      add(s, 'text', { x: bx + bw / 2, y: y(v) - 5, 'text-anchor': 'middle', style: `font-weight:600;fill:${j ? 'var(--fire-ink)' : 'var(--ink-2)'}` }, pct(v));
    });
    add(s, 'text', { x: cx, y: H - 10, 'text-anchor': 'middle', style: k === groups.length - 1 ? 'font-weight:600;fill:var(--ink)' : '' }, g.name);
  });
  return s;
}

function locationChart(runs) {
  const tot = { none: {}, fluni: {} };
  for (const r of runs) {
    for (const [k, v] of Object.entries(r.by_location)) {
      if (k === 'seed') continue; // the 30 seeded cases per run
      const key = LOC[k] ? k : 'other';
      tot[r.intervention][key] = (tot[r.intervention][key] || 0) + v;
    }
  }
  const keys = Object.keys(LOC);
  const W = 620, H = 230, L = 100, R = 60, T = 4, rowH = (H - T) / keys.length;
  const maxV = Math.max(...keys.flatMap((k) => [tot.none[k] || 0, tot.fluni[k] || 0]));
  const x = (v) => L + (v / maxV) * (W - L - R);
  const s = svg(W, H);
  keys.forEach((k, i) => {
    const y0 = T + i * rowH;
    add(s, 'text', { x: L - 8, y: y0 + rowH / 2 + 4, 'text-anchor': 'end', style: 'fill:var(--ink);font-size:13px' }, LOC[k]);
    ['none', 'fluni'].forEach((iv, j) => {
      const v = tot[iv][k] || 0, by = y0 + 3 + j * (rowH / 2 - 2), bh = rowH / 2 - 4;
      add(s, 'rect', { x: L, y: by, width: Math.max(1, x(v) - L), height: bh, rx: 3,
        fill: j ? 'var(--fire)' : 'var(--surface-3)', stroke: j ? 'none' : 'var(--ink-3)', 'stroke-width': j ? 0 : 0.8 });
      add(s, 'text', { x: x(v) + 5, y: by + bh - 1, style: 'font-size:11px' }, v);
    });
  });
  return s;
}

function legend() {
  return `<div class="rs-legend"><span><i style="background:var(--surface-3);border:1px solid var(--ink-3)"></i>No app</span>
    <span><i style="background:var(--fire)"></i>FlUni (60% have it)</span></div>`;
}

async function getText(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return r.text();
}

export async function mount(el) {
  if (!document.getElementById('results-css')) {
    const st = document.createElement('style');
    st.id = 'results-css';
    st.textContent = CSS;
    document.head.appendChild(st);
  }
  el.innerHTML = `<h2>Simulations: a campus with and without FlUni</h2>
    <p class="lede">Before real students use it, we test app policies on 1,000 simulated Stanford students. Here is what it told us so far.</p>
    <div class="rs-body"><p class="muted">Loading runs…</p></div>`;
  const body = el.querySelector('.rs-body');

  let cmp, agents, icfg;
  try {
    const [c, a, i] = await Promise.all([
      getText('data/compare.json'), getText(`${RUN}/agents_static.csv`), getText('../sim/configs/interventions.json'),
    ]);
    cmp = JSON.parse(c); icfg = JSON.parse(i).fluni;
    const lines = a.trim().split(/\r?\n/);
    const head = lines[0].split(',');
    const col = (name) => head.indexOf(name);
    const rows = lines.slice(1).map((l) => l.split(','));
    const prof = {}, n = rows.length;
    for (const r of rows) prof[r[col('sickness_behavior_profile')]] = (prof[r[col('sickness_behavior_profile')]] || 0) + 1;
    const app = rows.filter((r) => r[col('has_app')] === 'True').length;
    agents = { n, prof, app, archetypes: new Set(rows.map((r) => r[col('archetype')])).size };
  } catch (e) {
    body.innerHTML = `<p class="muted">Could not load simulation data (${e.message}). Serve the repo root.</p>`;
    return;
  }

  const runs = cmp.runs;
  const by = (iv) => runs.filter((r) => r.intervention === iv).sort((a, b) => a.seed - b.seed);
  const none = by('none'), fluni = by('fluni');
  const mN = mean(none.map((r) => r.attack_rate)), mF = mean(fluni.map((r) => r.attack_rate));
  const alerts = {};
  for (const r of fluni) for (const [k, v] of Object.entries(r.alerts || {})) alerts[k] = (alerts[k] || 0) + v;
  const sumLoc = (rs, k) => rs.reduce((s, r) => s + (r.by_location[k] || 0), 0);
  const altruistic = (agents.prof.stay_home || 0) + (agents.prof.visit_vaden_then_isolate || 0);
  const cc = icfg.close_contact;

  const bar = Object.entries(PROFILE).map(([k, [label, color]]) => {
    const f = (agents.prof[k] || 0) / agents.n;
    return `<span style="width:${f * 100}%;background:${color}" title="${label}">${pct(f, 0)}</span>`;
  }).join('');
  const barLegend = Object.entries(PROFILE).map(([, [label, color]]) => `<span><i style="background:${color}"></i>${label}</span>`).join('');

  body.innerHTML = `
    <h3>How the simulator works</h3>
    <div class="rs-how">
      <div class="card"><div class="rs-big">${fmt(agents.n)}</div><div class="muted">students, ${agents.archetypes} archetypes (studious, social, athlete, STEM, commuter, homebody)</div></div>
      <div class="card"><div class="rs-big">Stanford</div><div class="muted">real buildings, footpaths, dorms; class schedules from ExploreCourses</div></div>
      <div class="card"><div class="rs-big">5 min</div><div class="muted">per step: walk or bike, sit in class, eat, party, sleep</div></div>
      <div class="card"><div class="rs-big">R ≈ 1.6</div><div class="muted">influenza, calibrated on 7,000-agent runs</div></div>
      <div class="card"><div class="rs-big">Air + 6 ft</div><div class="muted">aerosol per room (humidity-aware) plus close-range spread</div></div>
    </div>
    <div class="rs-beh">
      <div class="card">
        <h4>When they get sick: ${pct(altruistic / agents.n, 0)} act altruistically</h4>
        <div class="rs-bar">${bar}</div>
        <div class="rs-legend">${barLegend}</div>
      </div>
      <div class="card">
        <h4>What they tell the app</h4>
        <p class="muted" style="margin:6px 0 0;font-size:15px">Agents self-report (or hide it), report others, sometimes falsely, and get tested at Vaden.
        ${pct(agents.app / agents.n, 0)} have the app. Shares from run <span class="mono">f12e71fa</span>, <span class="mono">agents_static.csv</span>.</p>
      </div>
    </div>

    <h3>App vs no app</h3>
    <div class="rs-setup">
      <span class="pill">${fmt(runs[0].agents)} agents · ${runs[0].days} days</span>
      <span class="pill">${runs[0].initial_seeds} initial cases</span>
      <span class="pill">transmission ×${runs[0].transmission_scale}</span>
      <span class="pill">seeds ${none.map((r) => r.seed).join(', ')}</span>
      <span class="pill">FlUni: close contact (${cc.minutes} min within 6 ft) → leave + mask ${icfg.close_contact.actions.includes('mask:1') ? '1 day' : ''}</span>
      <span class="pill">P(sick) ≥ ${icfg.risk.p_threshold} → Vaden</span>
      <span class="pill">self-report → isolate ${icfg.self_report.actions[0].split(':')[1]} days</span>
    </div>
    <div class="rs-charts">
      <div class="card"><h4>New infections per day <span class="muted" style="font-weight:400">(day 0 = the ${runs[0].initial_seeds} seeded cases, not shown)</span></h4><div class="rs-c1"></div>
        <div class="rs-legend"><span><i style="background:var(--ink-3)"></i>No app (dashed)</span><span><i style="background:var(--fire)"></i>FlUni</span></div></div>
      <div class="card"><h4>Share of campus infected by day ${runs[0].days}</h4><div class="rs-c2"></div>${legend()}</div>
    </div>
    <div class="rs-charts2">
      <div class="card"><h4>Where people caught it <span class="muted" style="font-weight:400">(3 seeds summed)</span></h4><div class="rs-c3"></div>${legend()}</div>
      <div class="card"><h4>Alerts the app sent <span class="muted" style="font-weight:400">(3 FlUni runs)</span></h4>
        <div class="rs-alerts">
          <div><b>${fmt(alerts.close_contact || 0)}</b><span>close contact → leave + mask</span></div>
          <div><b>${fmt(alerts.risk || 0)}</b><span>P(sick) ≥ ${icfg.risk.p_threshold} → Vaden</span></div>
          <div><b>${fmt(alerts.self_report || 0)}</b><span>self-report → isolate</span></div>
          <div><b>${fmt(alerts.nearby || 0)}</b><span>"risky phone within 6 ft" (info only)</span></div>
        </div>
        <p class="muted" style="font-size:13px;margin:10px 0 0">Every alert is logged; each agent follows it with its own compliance probability.</p>
      </div>
    </div>

    <div class="rs-verdict">
      <div class="card">
        <div class="rs-tag">Result</div>
        <p style="font-size:20px;line-height:1.3;margin:4px 0 8px"><b>FlUni did not reduce infections here.</b></p>
        <p>Mean attack rate ${pct(mN)} without the app vs <b>${pct(mF)}</b> with it; higher in all 3 seeds.</p>
        <p class="muted">3 seeds is a small sample; with behaviour changed, the same seed is no longer the same epidemic.</p>
      </div>
      <div class="card">
        <div class="rs-tag">Hypothesis (not yet tested)</div>
        <p>In the sim, <b>"leave"</b> sends the agent home to their dorm room for the rest of that activity, and 77% of these 1,000 students live in one dorm (Florence Moore).
        So ${fmt(alerts.close_contact || 0)} close-contact alerts move exposed students out of libraries and classes and into the crowded dorm.</p>
        <p>Infections rose most in <b>dorms</b> (${sumLoc(none, 'dorm')} → ${sumLoc(fluni, 'dorm')}), <b>common rooms</b> (${sumLoc(none, 'common_room')} → ${sumLoc(fluni, 'common_room')}) and <b>parties</b> (${sumLoc(none, 'party_venue')} → ${sumLoc(fluni, 'party_venue')}). The alert also comes after the 15 minutes, once exposure has happened, and most spread is through room air, not within 6 ft.</p>
      </div>
      <div class="card">
        <div class="rs-tag">What we test next</div>
        <ul>
          <li>"Leave" → mask / go somewhere open, not back to the dorm</li>
          <li>Residents spread over 53 dorms (spread-housing runs)</li>
          <li>10+ seeds per policy, with confidence intervals</li>
          <li>Earlier alerts: a lower threshold than 15 min</li>
        </ul>
      </div>
    </div>
    <p class="rs-foot muted">Simulation also feeds the heat map: its forecast (<span class="mono">heatmap/forecast.js</span>) multiplies each person's habits (which building, which half hour) by their current P(sick) to predict hot spots 1–3 h ahead.</p>`;

  body.querySelector('.rs-c1').appendChild(dailyChart(runs));
  body.querySelector('.rs-c2').appendChild(attackChart(runs));
  body.querySelector('.rs-c3').appendChild(locationChart(runs));
}
