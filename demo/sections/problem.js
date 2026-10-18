// Pitch section 1: the problem, why existing apps fail, FlUni's three features, and privacy.
// Every claim here is checked against proximity/README.md, proximity/DEMO.md, heatmap/app.js,
// model/README.md and WORKSTREAMS.md "Decisions". Infection locations come from demo/data/compare.json.

const asset = (p) => new URL(`../../heatmap/assets/${p}`, import.meta.url).href;
const KOREA = 'https://www.medicalindependent.ie/life/the-dorsal-view/an-embarrassment-of-data-riches-covid-19-tracking-apps-in-south-korea/';

const CSS = `
#problem { --pb-gap: 20px; }
#problem .pb-hero { display: grid; grid-template-columns: 1.15fr 1fr; gap: var(--pb-gap); align-items: stretch; margin-bottom: 44px; }
#problem .pb-crowd { position: relative; display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; padding: 18px 16px 44px; }
#problem .pb-place { position: relative; height: 210px; border-radius: 10px; background: var(--surface-2); }
#problem .pb-place > b { position: absolute; left: 0; right: 0; bottom: 8px; text-align: center; font-size: 15px; font-weight: 600; color: var(--ink-2); }
#problem .pb-p { position: absolute; width: 36px; height: 36px; border-radius: 50%; background: var(--sage);
  border: 2px solid var(--surface); box-shadow: 0 1px 2px rgba(51,36,28,.18); display: grid; place-items: center;
  transition: background .5s ease, transform .5s ease; }
#problem .pb-p img { width: 26px; height: 26px; }
#problem .pb-p.s1 { background: var(--sun); }
#problem .pb-p.s2 { background: var(--fire); transform: scale(1.12); }
#problem .pb-p.pop { animation: pb-pop .6s ease; }
@keyframes pb-pop { 50% { transform: scale(1.35); } }
#problem .pb-count { position: absolute; left: 18px; bottom: 12px; font-size: 15px; color: var(--ink-2); }
#problem .pb-count b { color: var(--fire-ink); font-size: 20px; }
#problem .pb-tag { position: absolute; right: 14px; bottom: 12px; }
#problem .pb-legend { display: flex; gap: 12px; font-size: 13px; color: var(--ink-3); position: absolute; left: 0; right: 0; bottom: 15px; justify-content: center; }
#problem .pb-legend i { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 4px; vertical-align: -1px; }
#problem .pb-big { font-size: 30px; line-height: 1.2; font-weight: 600; margin: 4px 0 18px; }
#problem .pb-big em { font-style: normal; color: var(--fire-ink); }
#problem .pb-bars { display: grid; gap: 9px; }
#problem .pb-bar { display: grid; grid-template-columns: 150px 1fr 48px; gap: 10px; align-items: center; font-size: 16px; }
#problem .pb-bar .track { display: block; height: 18px; border-radius: 999px; background: var(--surface-3); overflow: hidden; }
#problem .pb-bar .fill { display: block; height: 100%; width: 0; border-radius: 999px; background: var(--ember); transition: width 1.2s ease; }
#problem .pb-bar:first-child .fill { background: var(--fire); }
#problem .pb-bar .v { font-weight: 600; text-align: right; }
#problem .pb-src { font-size: 13px; margin-top: 10px; }
#problem h3 { font-size: 24px; font-weight: 600; margin: 0 0 14px; }
#problem .pb-rows { display: grid; gap: 10px; margin-bottom: 44px; }
#problem .pb-row { display: grid; grid-template-columns: 1fr 40px 1.35fr; align-items: center; gap: 8px; padding: 10px 18px; }
#problem .pb-row .bad { font-size: 18px; color: var(--ink-2); }
#problem .pb-row .bad b { color: var(--ink); display: block; font-size: 19px; }
#problem .pb-row .arrow { font-size: 24px; color: var(--ember); text-align: center; }
#problem .pb-row .good { font-size: 17px; }
#problem .pb-row .good b { font-size: 19px; display: block; }
#problem .pb-row .pill { margin-left: 6px; font-size: 12px; vertical-align: 2px; }
#problem .pill.open { background: var(--sun); }
#problem .pill.sim { background: var(--surface-3); }
#problem .pb-feats { grid-template-columns: repeat(3, 1fr); margin-bottom: 44px; }
#problem .pb-feat { display: flex; flex-direction: column; gap: 12px; }
#problem .pb-feat h4 { margin: 0; font-size: 21px; font-weight: 600; }
#problem .pb-feat .k { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: var(--ink-3); }
#problem .pb-feat .links { margin-top: auto; display: flex; gap: 8px; flex-wrap: wrap; }
#problem .pb-feat .links a { text-decoration: none; }
#problem .pb-feat .links a .pill { background: var(--ink); color: var(--paper); }
#problem .pb-note { border-radius: 14px; background: rgba(255,255,255,.75); border: 1px solid var(--hairline); padding: 10px 12px; font-size: 14px; line-height: 1.35; }
#problem .pb-note .app { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--ink-3); margin-bottom: 3px; }
#problem .pb-note .app img { width: 16px; height: 16px; }
#problem .pb-note b { display: block; font-size: 15px; }
#problem .pb-note.hot { background: rgba(219,108,89,.14); }
#problem .pb-map { display: grid; grid-template-columns: repeat(4, 1fr); gap: 6px; }
#problem .pb-map span { height: 34px; border-radius: 6px; font-size: 11px; display: grid; place-items: center; color: var(--ink); }
#problem .pb-map .h0 { background: var(--sage); } #problem .pb-map .h1 { background: var(--sun); }
#problem .pb-map .h2 { background: var(--ember); } #problem .pb-map .h3 { background: var(--fire); color: var(--paper); }
#problem .pb-map .hid { background: repeating-linear-gradient(45deg, var(--surface-3) 0 5px, var(--surface-2) 5px 10px); color: var(--ink-3); }
#problem .pb-hz { display: flex; gap: 6px; }
#problem .pb-hz .pill { font-size: 12px; } #problem .pb-hz .pill.on { background: var(--ink); color: var(--paper); }
#problem .pb-warn { font-size: 13px; color: var(--ink-3); }
#problem .pb-tiers { display: grid; gap: 6px; }
#problem .pb-tier { display: grid; grid-template-columns: 62px 1fr; gap: 10px; align-items: center; font-size: 14px; line-height: 1.3; }
#problem .pb-tier .pct { font-weight: 600; text-align: center; border-radius: 8px; padding: 6px 0; }
#problem .pb-inputs { font-size: 14px; color: var(--ink-2); line-height: 1.4; }
#problem .pb-priv { display: grid; grid-template-columns: 1.1fr 1fr 1fr 1.1fr; gap: 16px; align-items: start; padding: 20px 22px; }
#problem .pb-priv > div { font-size: 15px; line-height: 1.4; }
#problem .pb-priv b.t { display: block; font-size: 17px; margin-bottom: 4px; }
#problem .pb-id { font-family: var(--mono); font-size: 17px; background: var(--ink); color: var(--paper); border-radius: 8px; padding: 6px 10px;
  display: inline-block; margin: 2px 0 8px; transition: opacity .3s; letter-spacing: .02em; }
#problem .pb-st { display: flex; gap: 6px; flex-wrap: wrap; }
#problem .pb-st .pill { font-size: 12px; }
#problem .pb-vs { border-left: 3px solid var(--fire); padding-left: 12px; }
#problem .pb-gap { margin-top: 12px; padding: 10px 14px; border-radius: 10px; background: rgba(235,209,135,.45); font-size: 15px; }
@media (max-width: 1000px) {
  #problem .pb-hero, #problem .pb-feats, #problem .pb-priv { grid-template-columns: 1fr; }
  #problem .pb-row { grid-template-columns: 1fr; } #problem .pb-row .arrow { display: none; }
}
@media (prefers-reduced-motion: reduce) { #problem .pb-p, #problem .pb-bar .fill { transition: none; } #problem .pb-p.pop { animation: none; } }
`;

// Where infections happened, grouped by what students do there (sim location kinds).
const GROUPS = [
  ['Where they live', ['dorm', 'common_room']],
  ['Where they party', ['party_venue', 'event_venue', 'gym']],
  ['Where they study', ['library', 'classroom', 'lecture_hall', 'lab']],
  ['Where they eat', ['dining']],
];
const NOT_ON_CAMPUS = new Set(['seed', 'off_campus', 'unknown']);

const ROWS = [
  ['Too few people use them', 'A city is too big for enough people to join.',
    'Built for one small university', 'A tight community where most students can join. Our simulations assume 60% of students have the app.', 'sim', 'simulated'],
  ['Bluetooth alone is unreliable', 'Walls, pockets and phone models skew the signal.',
    'Bluetooth + ultra-wideband + GPS, fused', 'Weighted by how precise each one is (1/σ²), giving P(within 6 ft). UWB (~10 cm) also calibrates Bluetooth. No internet needed.'],
  ['No advice you can act on', '"One of your degree-one connections has the flu."',
    'A probability and one next step', '"Elevated. Wear a mask in crowded rooms and watch for symptoms."'],
  ['Battery drain', 'Constant scanning and uploads.',
    'Low-energy Bluetooth, no server', 'UWB only while the app is open; in the background just Bluetooth, at most one read per phone every 20 s. Battery use not measured yet.', 'open', 'open'],
  ['Leaves out people without phones', 'Contact tracing misses whoever has no smartphone.',
    'At a university, students carry phones', 'Today the app is iPhone only (precise distance needs iPhone 11 or later).', 'open', 'iPhone only'],
];

function crowd(root) {
  const places = [['Dorm', 12], ['Dining hall', 12], ['Library', 12]];
  const people = [];
  root.innerHTML = places.map(([name]) => `<div class="pb-place"><b>${name}</b></div>`).join('') +
    `<div class="pb-legend"><span><i style="background:var(--sage)"></i>healthy</span><span><i style="background:var(--sun)"></i>possibly sick</span><span><i style="background:var(--fire)"></i>sick</span></div>
     <div class="pb-count"><b>1</b> sick of 36</div><span class="pill pb-tag">illustration</span>`;
  const img = asset('people/tissue.png');
  [...root.querySelectorAll('.pb-place')].forEach((el, g) => {
    for (let i = 0; i < places[g][1]; i++) {
      const col = i % 3, row = Math.floor(i / 3);
      const jx = ((i * 37 + g * 11) % 9) - 4, jy = ((i * 53 + g * 7) % 9) - 4;
      const d = document.createElement('div');
      d.className = 'pb-p';
      d.style.left = `calc(${10 + col * 30}% + ${jx}px)`;
      d.style.top = `${12 + row * 42 + jy}px`;
      d.innerHTML = `<img src="${img}" alt="">`;
      el.append(d);
      people.push({ el: d, g, s: 0 });
    }
  });
  // A scripted spread: dorm first, then the dining hall, then the library.
  const order = [4, 1, 7, 5, 16, 19, 0, 10, 28, 13, 31, 8, 22, 25, 33];
  const count = root.querySelector('.pb-count b');
  let timer = null;
  const set = (p, s) => { p.s = s; p.el.className = `pb-p s${s}`; if (s) { void p.el.offsetWidth; p.el.classList.add('pop'); } };
  const show = () => { count.textContent = people.filter((p) => p.s === 2).length; };
  const reset = () => { people.forEach((p) => set(p, 0)); people[order[0]].s = 2; people[order[0]].el.className = 'pb-p s2'; show(); };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  function play() {
    clearInterval(timer);
    reset();
    if (reduced) { order.forEach((i) => set(people[i], 2)); show(); return; }
    let k = 1;
    timer = setInterval(() => {
      if (k < order.length) { set(people[order[k]], 1); const prev = people[order[k - 1]]; if (k > 1 && prev.s === 1) set(prev, 2); k++; }
      else if (k === order.length) { set(people[order[k - 1]], 2); k++; }
      else if (k > order.length + 5) { clearInterval(timer); setTimeout(play, 600); return; }
      else k++;
      show();
    }, 650);
  }
  new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) play(); else clearInterval(timer); }), { threshold: 0.4 }).observe(root);
}

async function where(root) {
  try {
    const d = await (await fetch(new URL('../data/compare.json', import.meta.url))).json();
    const runs = d.runs.filter((r) => r.intervention === 'none');
    const sums = Object.fromEntries(GROUPS.map(([name]) => [name, 0]));
    let total = 0;
    for (const r of runs) for (const [loc, n] of Object.entries(r.by_location)) {
      if (NOT_ON_CAMPUS.has(loc)) continue;
      total += n;
      const g = GROUPS.find(([, locs]) => locs.includes(loc));
      if (g) sums[g[0]] += n;
    }
    if (!total) throw new Error('no data');
    const r0 = runs[0];
    root.innerHTML = `<div class="pb-bars">${GROUPS.map(([name]) => {
      const pct = Math.round((100 * sums[name]) / total);
      return `<div class="pb-bar"><span>${name}</span><span class="track"><span class="fill" data-w="${pct}"></span></span><span class="v">${pct}%</span></div>`;
    }).join('')}</div>
      <p class="pb-src muted">Share of on-campus infections. <span class="pill sim">simulated</span> ${r0.agents.toLocaleString()} students × ${r0.days} days, ${runs.length} runs, no app (<code>sim/</code>).</p>`;
    requestAnimationFrame(() => setTimeout(() => root.querySelectorAll('.fill').forEach((f) => { f.style.width = `${f.dataset.w}%`; }), 50));
  } catch {
    root.innerHTML = '';
  }
}

function rotatingId(el) {
  const hex = () => Array.from(crypto.getRandomValues(new Uint8Array(6)), (b) => b.toString(16).padStart(2, '0')).join(' ');
  el.textContent = hex();
  setInterval(() => { el.style.opacity = 0.2; setTimeout(() => { el.textContent = hex(); el.style.opacity = 1; }, 300); }, 3000);
}

export function mount(el) {
  if (!document.getElementById('problem-css')) {
    const s = document.createElement('style');
    s.id = 'problem-css';
    s.textContent = CSS;
    document.head.append(s);
  }
  const icon = asset('illustrations/tissue.png');
  el.innerHTML = `
    <h2>Flu spreads fastest where students live, eat and study together</h2>
    <p class="lede">FlUni warns students the moment someone near them may be sick, and tells them what to do, without sharing who anyone is.</p>

    <div class="pb-hero">
      <div class="card pb-crowd"></div>
      <div>
        <p class="pb-big">Students share rooms, meals and desks all day, so <em>one case quickly becomes many</em>.</p>
        <div class="pb-where"></div>
      </div>
    </div>

    <h3>Why existing apps fail, and what FlUni does instead</h3>
    <div class="pb-rows">${ROWS.map(([bad, badSub, good, goodSub, cls, tag]) => `
      <div class="card pb-row">
        <div class="bad"><b>${bad}</b>${badSub}</div>
        <div class="arrow" aria-hidden="true">→</div>
        <div class="good"><b>${good}${tag ? `<span class="pill ${cls}">${tag}</span>` : ''}</b>${goodSub}</div>
      </div>`).join('')}
    </div>

    <h3>Three things FlUni does</h3>
    <div class="grid pb-feats">
      <div class="card pb-feat">
        <span class="k">1 · Primary</span>
        <h4>Alert within 6 ft</h4>
        <div class="pb-note"><div class="app"><img src="${icon}" alt="">FlUni · now</div>
          <b>Someone within 6 ft may be sick</b>Put 6 ft or more between you, or step outside.</div>
        <div class="pb-note hot"><div class="app"><img src="${icon}" alt="">FlUni · after 15 weighted min</div>
          <b>Close contact</b>Leave the room now, or move well away and put on a mask.</div>
        <div class="links"><a href="#phones"><span class="pill">Two-phone demo →</span></a><a href="#live"><span class="pill">In the sim →</span></a></div>
      </div>
      <div class="card pb-feat">
        <span class="k">2 · Secondary</span>
        <h4>Campus heat map</h4>
        <div class="pb-map" aria-hidden="true">
          <span class="h0">Gym</span><span class="h1">Union</span><span class="h3">Library</span><span class="hid">hidden</span>
          <span class="h2">Dorm A</span><span class="h0">Labs</span><span class="h1">Dining</span><span class="h0">Dorm B</span>
        </div>
        <div class="pb-hz"><span class="pill on">Now</span><span class="pill">In 1 hour</span><span class="pill">2 h</span><span class="pill">3 h</span></div>
        <div class="pb-note hot"><b>Walking in</b>Library has a lot of illness right now. Consider a mask, or a different spot.</div>
        <div class="pb-warn">"May be incomplete because not everyone shares their status." Building totals only.</div>
        <div class="links"><a href="#live"><span class="pill">Live map →</span></a></div>
      </div>
      <div class="card pb-feat">
        <span class="k">3 · The math</span>
        <h4>P(sick) → advice</h4>
        <div class="pb-inputs">Every contact, weighted by distance and time, plus self-reports and tests (a test counts more than symptoms). Reports that don't fit the contacts are flagged.</div>
        <div class="pb-tiers">
          <div class="pb-tier"><span class="pct" style="background:var(--sage)">&lt; 10%</span><span>Low. No action needed.</span></div>
          <div class="pb-tier"><span class="pct" style="background:var(--sun)">10%+</span><span>Elevated. Wear a mask in crowded rooms and watch for symptoms.</span></div>
          <div class="pb-tier"><span class="pct" style="background:var(--fire);color:var(--paper)">40%+</span><span>High. Consider getting tested at Vaden and staying home.</span></div>
        </div>
        <div class="links"><a href="#math"><span class="pill">The math →</span></a><a href="#results"><span class="pill">Simulations →</span></a></div>
      </div>
    </div>

    <h3>Private by design</h3>
    <div class="card pb-priv">
      <div><b class="t">Broadcast: a random ID + a status</b>
        <span class="pb-id" title="Random ID (demo: changes every 3 s)"></span>
        <div class="pb-st"><span class="pill" style="background:var(--sage)">healthy</span><span class="pill" style="background:var(--sun)">possibly sick</span><span class="pill" style="background:var(--fire);color:var(--paper)">contagious</span></div>
        <div class="muted" style="font-size:13px;margin-top:6px">New ID every 15 min (sped up here).</div></div>
      <div><b class="t">Matching on the phone</b>No server, no account. No names, no phone numbers. Your location never leaves your phone.</div>
      <div><b class="t">The map shows totals</b>Only per-building counts, never people or positions. Buildings with 1–3 people are hidden.</div>
      <div class="pb-vs"><b class="t">Not South Korea's approach</b>Its COVID-19 tracking published where patients had been, which put their privacy at risk.
        <a href="${KOREA}" target="_blank" rel="noopener">Read more</a>. Anonymity makes students more willing to report.</div>
    </div>
    <div class="pb-gap"><b>Known gap:</b> in a room with just two people, the status reveals who is sick. To fix before real users (anonymity threshold or server-side matching).</div>
  `;
  crowd(el.querySelector('.pb-crowd'));
  where(el.querySelector('.pb-where'));
  rotatingId(el.querySelector('.pb-id'));
}
