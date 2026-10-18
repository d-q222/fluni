// Live demo: the heat map's presenter view (bird's-eye simulation + one student's phone) in an iframe,
// with story scenes picked from real moments of a simulated run.
//
// Run: influenza_none_n1000_d4_s42_73b8452c (1,000 agents, 4 days, start Mon 2026-01-05 00:00; sim/README.md
// marks it "for the live demo"). It is used instead of the heat map's 14-day default because only runs under
// the heat map's BIG_AGENT_DAYS limit load contacts.csv.gz in the page, which the close-contact alert and the
// "Why this %?" panel need. `at` is minutes from the start.
//
// How the scenes were found: reports_tests.csv (first self-report: A0863 at step 614 = 3,070 min), the heat
// map's "Jump to…" menu (first close-contact alert: A0939, Wed 8:40; hottest building: Breer Library, Thu 14:50),
// and a script over window.fluni.current() for people within 6 ft, same room, of someone at P >= 50%
// (A0337 next to A0863 in the Sapp Center, Thu 10:40). Each scene was then opened and its phone checked.
const RUN = 'influenza_none_n1000_d4_s42_73b8452c';
const SCENES = [
  { name: 'First report', q: 'at=3075&agent=A0863&why=1',
    cap: 'Wed 3:10 am: A0863 reports “might be sick”. Their Campus model jumps to 60%, and “Why this %?” lists the report and flags it: no risky contact on record.' },
  { name: 'Heads-up', q: 'at=4960&agent=A0337&zoom=18',
    cap: 'Thu 10:40 am, Sapp Center: A0337 sits within 6 ft of A0863 (60%). The phone says “Someone within 6 ft may be sick”, with no name and no location.' },
  { name: 'Close contact', q: 'at=3400&agent=A0939&zoom=18',
    cap: 'Wed 8:40 am, at Vaden: A0939 reaches 15 of 15 weighted minutes within 6 ft of someone who may be sick, so the phone shows a close-contact alert with what to do.' },
  { name: 'Hot building', q: 'at=5210&agent=A0126&zoom=17',
    cap: 'Thu 2:50 pm: Breer Library at its peak. A0126 is inside, and their phone warns: “Breer Library has a lot of illness right now.”' },
  { name: 'What users see', q: 'at=5210&view=public&horizon=60',
    cap: 'The same moment as users see it: building totals only (no people, no dots), forecast one hour ahead. Small groups are hidden.' },
  { name: 'Truth vs app', q: 'at=5210&color=truth&agent=A0326',
    cap: 'Dots coloured by the simulation’s truth (red = infected). A0326 is infected but the app says 7%: it only knows what people report.' },
];
const src = (s) => `../heatmap/?run=${RUN}&${s.q}`;

const CSS = `
#live.slide { padding-top: 28px; }
#live > .lede { margin-bottom: 14px; }
#live .bar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 8px; }
#live .bar .btn { font-size: 15px; }
#live .bar .btn .n { display: inline-block; width: 20px; height: 20px; margin-right: 6px; border-radius: 50%; background: var(--surface-3);
  font-size: 12px; line-height: 20px; text-align: center; font-weight: 600; }
#live .bar .btn.primary .n { background: var(--fire); color: var(--paper); }
#live .bar .full { margin-left: auto; font-size: 14px; }
#live .cap { margin: 0 0 10px; font-size: 17px; line-height: 1.5; min-height: 3em; }
#live .stage { position: relative; width: 100%; aspect-ratio: 16 / 9; max-height: calc(100vh - 290px); min-height: 420px;
  border-radius: var(--radius); overflow: hidden; box-shadow: var(--shadow); background: var(--surface-2); }
#live .stage iframe { width: 100%; height: 100%; border: 0; display: block; }
#live .loading { position: absolute; inset: 0; display: grid; place-content: center; justify-items: center; gap: 10px;
  background: var(--surface-2); color: var(--ink-2); font-size: 18px; transition: opacity .3s; }
#live .loading img { width: 120px; height: auto; animation: live-bob 1.2s ease-in-out infinite alternate; }
#live .loading.done { opacity: 0; pointer-events: none; }
@keyframes live-bob { from { transform: translateY(-4px) rotate(-3deg); } to { transform: translateY(4px) rotate(3deg); } }
#live .legend { margin-top: 16px; grid-template-columns: repeat(4, 1fr); }
#live .legend .card { padding: 12px 14px; }
#live .legend b { display: block; font-size: 16px; margin-bottom: 2px; }
#live .legend p { margin: 0; font-size: 14px; color: var(--ink-2); line-height: 1.4; }
#live .legend .dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; vertical-align: 1px; }
#live .note { margin: 10px 0 0; font-size: 14px; }
@media (max-width: 900px) { #live .legend { grid-template-columns: repeat(2, 1fr); } }
`;

const LEGEND = [
  ['var(--sun)', 'Heads-up', 'At once, when someone the app rates at P ≥ 50% is within 6 ft in the same room.'],
  ['var(--fire)', 'Close contact', '15 weighted minutes within 6 ft in 24 h (P ≥ 90% counts 1, P ≥ 50% counts ½).'],
  ['var(--ember)', 'Walk-in warning', 'Entering a building whose totals are high. Uses building totals only.'],
  ['var(--sage)', 'Two numbers', '“Campus model”: P(sick) from all reports and contacts. “This phone’s estimate”: nearby phones only, last 24 h.'],
];

export function mount(el) {
  if (!document.getElementById('live-css')) document.head.append(Object.assign(document.createElement('style'), { id: 'live-css', textContent: CSS }));
  el.innerHTML = `
    <h2>Bird’s-eye view and one student’s phone, at the same time</h2>
    <p class="lede">1,000 simulated students on a real Stanford map, coloured by the app’s P(sick).</p>
    <div class="bar" role="tablist">
      ${SCENES.map((s, i) => `<button class="btn" role="tab" data-i="${i}"><span class="n">${i + 1}</span>${s.name}</button>`).join('')}
      <a class="full" target="_blank" rel="noopener">Open full screen ↗</a>
    </div>
    <p class="cap"></p>
    <div class="stage">
      <iframe title="FlUni heat map, presenter view" allow="fullscreen"></iframe>
      <div class="loading"><img src="../heatmap/assets/people/tissue.png" alt=""><span>Loading 1,000 students…</span>
        <small class="muted">10–20 s the first time</small></div>
    </div>
    <div class="grid legend">
      ${LEGEND.map(([c, t, d]) => `<div class="card"><b><span class="dot" style="background:${c}"></span>${t}</b><p>${d}</p></div>`).join('')}
    </div>
    <p class="note muted">Simulated run (${RUN}). The dots, the true-status colours and the dashed “Presenter only” box are presenter-only;
      users never see other people, only building totals and their own phone. Contacts come from the simulation, standing in for phone detections.</p>`;

  const frame = el.querySelector('iframe'), loading = el.querySelector('.loading'), cap = el.querySelector('.cap');
  const full = el.querySelector('.full'), buttons = [...el.querySelectorAll('.bar .btn')];
  let poll = 0;
  // The page's load event fires before the run's data arrive; it's same-origin, so wait for the heat map's
  // own ready signal (window.fluni.totals), with the load event plus a timeout as a fallback.
  const ready = () => { loading.classList.add('done'); clearInterval(poll); };
  frame.addEventListener('load', () => {
    const t = Date.now();
    clearInterval(poll);
    poll = setInterval(() => {
      let ok = false;
      try { ok = !!frame.contentWindow.fluni?.totals; } catch { ok = true; }
      if (ok || Date.now() - t > 60000) ready();
    }, 250);
  });
  const show = (i) => {
    const s = SCENES[i];
    buttons.forEach((b, j) => { b.classList.toggle('primary', j === i); b.setAttribute('aria-selected', String(j === i)); });
    cap.textContent = s.cap;
    full.href = src(s);
    loading.classList.remove('done');
    frame.src = src(s);
  };
  buttons.forEach((b, i) => b.addEventListener('click', () => show(i)));
  // Load the heavy iframe only when the section comes near the screen.
  let started = false;
  new IntersectionObserver((es, io) => {
    if (started || !es.some((e) => e.isIntersecting)) return;
    started = true; io.disconnect(); show(0);
  }, { rootMargin: '400px' }).observe(el);
}
