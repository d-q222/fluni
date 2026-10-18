// The presenter's chrome for a live demo: keyboard shortcuts, a clear day/time readout, a scrubber with day
// ticks and a sparkline of the outbreak, "Jump to…" story moments computed from the run, a tidier header,
// a highlighted selected person, a phone that slides in and out without covering them, and a loading bar.
// app.js hands it the few things it needs (see initPresenterUI); nothing here touches the model or the heat.

const DAY = 86400000;
const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, ...kids) => {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...kids);
  return e;
};
const h12 = (d) => d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP])M$/i, (_, c) => ` ${c.toLowerCase()}m`);
const midnight = (ms) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };

// "Day 3 · Wed 1:15 pm" (numeric-time runs have no calendar: "Day 3 · 13:15").
let memo = { m: -1, s: '' };
export function dayTime(ms, t0, numeric) {
  const m = Math.floor(ms / 60000);
  if (m === memo.m) return memo.s; // called every frame; the text changes once a minute
  memo = { m, s: dayTimeText(ms, t0, numeric) };
  return memo.s;
}
function dayTimeText(ms, t0, numeric) {
  if (numeric) {
    const m = Math.floor(ms / 60000);
    return `Day ${Math.floor(m / 1440) + 1} · ${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
  }
  const day = Math.round((midnight(ms) - midnight(t0)) / DAY) + 1;
  return `Day ${day} · ${new Date(ms).toLocaleDateString('en-US', { weekday: 'short' })} ${h12(new Date(ms))}`;
}

// ---------- loading ----------

let barEl = null;
export function progress(message, fraction) {
  const s = $('status');
  if (!s || s.hidden) return;
  if (!barEl) {
    s.textContent = '';
    barEl = el('div', { className: 'load' }, el('div', { className: 'load-msg' }), el('div', { className: 'load-bar' }, el('i')));
    s.append(barEl);
  }
  barEl.firstChild.textContent = message;
  barEl.lastChild.firstChild.style.width = `${Math.round(Math.min(1, fraction) * 100)}%`;
}

const CSS = `
#status .load { width: min(340px, 80vw); text-align: center; }
#status .load-msg { color: var(--ink-2); margin-bottom: 12px; font-size: 14px; }
#status .load-bar { height: 6px; border-radius: 3px; background: var(--surface-3); overflow: hidden; }
#status .load-bar i { display: block; height: 100%; width: 0; background: linear-gradient(90deg, var(--sun), var(--ember), var(--fire)); transition: width 400ms ease-out; }

/* header: three groups, most important first */
header.bar { gap: 10px 18px; }
.playback { flex: 1 1 420px; }
#time { min-width: 140px; color: var(--ink); font-weight: 500; }
#time small { color: var(--ink-3); font-weight: 400; }
.options { flex-wrap: nowrap; gap: 8px; }
.options > * { flex: none; }
.seg { display: inline-flex; background: var(--surface-2); border-radius: 999px; padding: 2px; }
.seg button { font: inherit; font-size: 13px; color: var(--ink-2); border: 0; background: none; border-radius: 999px; padding: 0 18px;
  height: 26px; cursor: pointer; white-space: nowrap; flex: 1 1 0; min-width: 128px; } /* two equal halves */
.seg button[aria-pressed="true"] { background: var(--ink); color: var(--surface); }
.seg button:not([aria-pressed="true"]):hover { background: var(--surface-3); }
.pill { font: inherit; font-size: 13px; color: var(--ink); height: 30px; border: 0; border-radius: 999px; padding: 0 12px;
  background: var(--surface-2); cursor: pointer; white-space: nowrap; }
.pill:hover { background: var(--surface-3); }
.pill[aria-expanded="true"] { background: var(--ink); color: var(--surface); }
.pop-wrap { position: relative; }
.pop { position: absolute; right: 0; top: calc(100% + 8px); z-index: 1200; min-width: 280px; padding: 10px; background: var(--surface);
  border-radius: var(--radius); box-shadow: var(--shadow); display: flex; flex-direction: column; gap: 8px; }
.pop label { display: flex; flex-direction: column; gap: 3px; font-size: 11px; color: var(--ink-3); letter-spacing: .04em; text-transform: uppercase; }
.pop select { width: 100%; }
.pop .item { display: flex; flex-direction: column; align-items: flex-start; gap: 1px; width: 100%; text-align: left; font: inherit; border: 0;
  background: none; padding: 7px 8px; border-radius: 8px; cursor: pointer; color: var(--ink); }
.pop .item:hover:not(:disabled) { background: var(--surface-2); }
.pop .item:disabled { opacity: .5; cursor: default; }
.pop .item b { font-weight: 600; font-size: 13px; }
.pop .item small { color: var(--ink-3); font-size: 12px; }
.pop .item .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; background: var(--fire); }

/* scrubber: sparkline of total expected sick behind the slider, day ticks on top */
.scrub { position: relative; flex: 1; min-width: 120px; height: 38px; }
.scrub svg { position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; pointer-events: none; }
.scrub .area { fill: rgba(219, 108, 89, 0.28); stroke: none; }
.scrub .line { fill: none; stroke: var(--fire); stroke-width: 1.2; vector-effect: non-scaling-stroke; }
.scrub .tick { stroke: var(--hairline); stroke-width: 1; vector-effect: non-scaling-stroke; }
.scrub .daylbl { position: absolute; top: 0; font-size: 9px; color: var(--ink-3); transform: translateX(3px); pointer-events: none; line-height: 1; }
.scrub .mark { position: absolute; bottom: 2px; width: 7px; height: 7px; margin-left: -3.5px; border-radius: 50%; background: var(--ink);
  box-shadow: 0 0 0 2px var(--surface); pointer-events: none; }
.scrub input[type=range] { position: absolute; inset: 0; width: 100%; height: 100%; margin: 0; background: transparent; -webkit-appearance: none; appearance: none; }
.scrub input[type=range]::-webkit-slider-runnable-track { height: 38px; background: transparent; }
.scrub input[type=range]::-moz-range-track { height: 38px; background: transparent; }
.scrub input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; width: 3px; height: 38px; border-radius: 2px; background: var(--ink); border: 0;
  box-shadow: 0 0 0 2px rgba(255, 250, 241, .8); }
.scrub input[type=range]::-moz-range-thumb { width: 3px; height: 38px; border-radius: 2px; background: var(--ink); border: 0; }

/* shortcut hint and toast */
.hint-btn { position: absolute; right: 12px; bottom: 28px; z-index: 600; width: 28px; height: 28px; border-radius: 50%; border: 0;
  background: var(--surface); color: var(--ink-2); box-shadow: var(--shadow); font: 600 14px/1 var(--font); cursor: pointer; opacity: .8; }
.hint-btn:hover { opacity: 1; }
.hint-card { position: absolute; right: 12px; bottom: 64px; z-index: 600; padding: 10px 14px; background: var(--surface); border-radius: var(--radius);
  box-shadow: var(--shadow); font-size: 13px; color: var(--ink-2); }
.hint-card h3 { margin: 0 0 6px; font-size: 12px; letter-spacing: .05em; text-transform: uppercase; color: var(--ink-3); font-weight: 600; }
.hint-card div { display: flex; justify-content: space-between; gap: 18px; padding: 2px 0; }
.hint-card kbd { font: 600 12px var(--font); background: var(--surface-2); border-radius: 5px; padding: 1px 7px; color: var(--ink); }
.toast { position: absolute; left: 50%; top: 16px; transform: translateX(-50%); z-index: 1300; padding: 7px 14px; border-radius: 999px;
  background: var(--ink); color: var(--surface); font-size: 13px; opacity: 0; transition: opacity 160ms; pointer-events: none; }
.toast.on { opacity: .94; }

#phone .phone-frame { position: relative; }
/* notification banner on the phone (FlUni's own notification text) */
.ph-banner { position: absolute; left: 8px; right: 8px; top: 38px; z-index: 30; display: flex; gap: 12px; align-items: flex-start; padding: 12px 14px; border-radius: 26px; color: var(--ink);
  background: rgba(244, 234, 214, .86); backdrop-filter: blur(18px) saturate(1.4); -webkit-backdrop-filter: blur(18px) saturate(1.4);
  box-shadow: 0 10px 28px -8px rgba(51, 36, 28, .4), 0 0 0 1px rgba(51, 36, 28, .08); animation: bannerIn 360ms cubic-bezier(.2, .9, .3, 1.1); cursor: pointer; }
.ph-banner-icon { flex: none; width: 40px; height: 40px; border-radius: 10px; background: var(--sage); padding: 4px; object-fit: contain; }
.ph-banner-body { min-width: 0; flex: 1; }
.ph-banner-head { display: flex; justify-content: space-between; font-size: 16px; color: var(--ink-3); }
.ph-banner-app { font-weight: 600; color: var(--ink); }
.ph-banner p { margin: 1px 0 0; font-size: 16px; line-height: 1.3; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
@keyframes bannerIn { from { transform: translateY(-120%); opacity: 0; } to { transform: none; opacity: 1; } }

/* the selected person */
.sel-ring { pointer-events: none; }
.sel-ring i { position: absolute; left: -22px; top: -22px; width: 44px; height: 44px; border-radius: 50%; border: 3px solid var(--fire-ink);
  box-shadow: 0 0 0 3px rgba(255, 250, 241, .9), 0 0 18px 4px rgba(219, 108, 89, .55); animation: selpulse 1.6s ease-out infinite; }
@keyframes selpulse { 0% { transform: scale(.7); opacity: 1; } 70% { transform: scale(1.15); opacity: .75; } 100% { transform: scale(1.3); opacity: .0; } }

/* the phone slides in and out */
#phone { transition: transform 260ms cubic-bezier(.2, .8, .2, 1), opacity 200ms ease-out; }
#phone.entering, #phone.closing { opacity: 0; }
#phone.entering { transform: translateX(40px); }
#phone.closing { display: flex !important; transform: translateX(40px); transition-duration: 200ms; pointer-events: none; }
.leaflet-fade-anim .leaflet-popup { transition: opacity 120ms linear; }
@media (max-width: 1500px) { .brand span { display: none; } }
/* narrower than that: two rows, brand + controls over a full-width playback + scrubber */
@media (max-width: 1400px) { header.bar .brand { order: 1; margin-right: auto; } header.bar .options { order: 2; } header.bar .playback { order: 3; flex-basis: 100%; } }
@media (prefers-reduced-motion: reduce) { #phone, .sel-ring i { transition: none; animation: none; } }
`;

document.head.append(el('style', { textContent: CSS })); // at import, so the loading bar is styled before the run loads

const SHORT = { demo: 'Room-level', public: 'What users see', airborne: 'Air by room', airflow: 'Airflow (exp.)' };
const KEYS = [['Space', 'Play / pause'], ['← →', 'Back / forward 10 min'], ['[  ]', 'Slower / faster'], ['J', 'Jump to…'], ['Esc', 'Close the phone']];

// api: { map, L, t0, t1, numericTime, getNow(), seek(ms), isPlaying(), togglePlay(), select(id), selected(), current(), steps: [{ t, expected }],
//        peakBuilding(): { id, name, tMs, expected } | null, buildingCenter(id): [lat, lng] | null,
//        firstReport(): Promise<{ tMs, id } | null>, closeContact: null | (() => { id, tMs } | null) }
export function initPresenterUI(api) {
  const { map, L, t0, t1, numericTime } = api;
  const main = document.querySelector('main');

  // ---- toast ----
  const toastEl = main.appendChild(el('div', { className: 'toast', role: 'status' }));
  let toastT;
  const toast = (text) => { toastEl.textContent = text; toastEl.classList.add('on'); clearTimeout(toastT); toastT = setTimeout(() => toastEl.classList.remove('on'), 1100); };

  // ---- view switch: a segmented control; the <select id="view"> stays the source of truth ----
  const view = $('view');
  view.hidden = true;
  const seg = el('div', { className: 'seg', role: 'group', ariaLabel: 'View' });
  const syncSeg = () => { for (const b of seg.children) b.setAttribute('aria-pressed', String(b.dataset.v === view.value)); };
  for (const o of view.options) {
    seg.append(el('button', { type: 'button', textContent: SHORT[o.value] || o.textContent, onclick: () => {
      view.value = o.value; view.dispatchEvent(new Event('change')); syncSeg(); } }));
    seg.lastChild.dataset.v = o.value;
  }
  view.addEventListener('change', syncSeg);
  syncSeg();
  view.after(seg);

  // ---- display settings: colour and base map move into a popover; People stays in the header ----
  const options = document.querySelector('.options');
  const wrap = (btn, panel) => {
    const w = el('div', { className: 'pop-wrap' }, btn, panel);
    panel.hidden = true;
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const open = panel.hidden;
      closePops();
      panel.hidden = !open;
      btn.setAttribute('aria-expanded', String(open));
    });
    return w;
  };
  const closePops = () => { for (const p of document.querySelectorAll('.pop')) { p.hidden = true; p.parentElement.firstChild.setAttribute('aria-expanded', 'false'); } };
  document.addEventListener('click', (e) => { if (!e.target.closest('.pop-wrap')) closePops(); });

  const dispPanel = el('div', { className: 'pop' });
  const labelled = (text, node) => { const l = el('label', {}, text); l.append(node); return l; };
  dispPanel.append(labelled('Colour people by', $('dot-mode')), labelled('Base map', $('basemap')));
  const dispBtn = el('button', { type: 'button', className: 'pill', textContent: 'Display', ariaExpanded: 'false' });

  const jumpPanel = el('div', { className: 'pop' });
  const jumpBtn = el('button', { type: 'button', className: 'pill', textContent: 'Jump to…', ariaExpanded: 'false' });
  options.append(wrap(jumpBtn, jumpPanel), wrap(dispBtn, dispPanel));

  // ---- time readout and scrubber ----
  const slider = $('slider');
  const scrub = el('div', { className: 'scrub' });
  slider.before(scrub);
  scrub.append(slider);
  const span = t1 - t0;
  const svgNS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(svgNS, 'svg');
  svg.setAttribute('viewBox', '0 0 1000 100');
  svg.setAttribute('preserveAspectRatio', 'none');
  scrub.prepend(svg);
  const xOf = (ms) => ((ms - t0) / span) * 1000;
  // sparkline: total expected sick over the run
  const pts = api.steps;
  if (pts.length > 1) {
    const max = Math.max(...pts.map((p) => p.expected)) || 1;
    const every = Math.max(1, Math.floor(pts.length / 500));
    const line = pts.filter((_, i) => i % every === 0).map((p) => `${xOf(p.t).toFixed(1)},${(96 - (p.expected / max) * 80).toFixed(1)}`);
    const mk = (cls, d) => { const p = document.createElementNS(svgNS, 'path'); p.setAttribute('class', cls); p.setAttribute('d', d); svg.append(p); };
    mk('area', `M${line[0].split(',')[0]},100 L${line.join(' L')} L${line.at(-1).split(',')[0]},100 Z`);
    mk('line', `M${line.join(' L')}`);
  }
  // day ticks
  if (!numericTime) {
    for (let d = midnight(t0) + DAY, n = 2; d < t1; d += DAY, n++) {
      const x = xOf(d);
      const l = document.createElementNS(svgNS, 'line');
      l.setAttribute('class', 'tick'); l.setAttribute('x1', x); l.setAttribute('x2', x); l.setAttribute('y1', 0); l.setAttribute('y2', 100);
      svg.append(l);
      scrub.append(el('span', { className: 'daylbl', textContent: `D${n}`, style: `left:${(x / 10).toFixed(2)}%` }));
    }
  } else {
    for (let d = DAY, n = 2; d < t1; d += DAY, n++) {
      const x = xOf(d);
      const l = document.createElementNS(svgNS, 'line');
      l.setAttribute('class', 'tick'); l.setAttribute('x1', x); l.setAttribute('x2', x); l.setAttribute('y1', 0); l.setAttribute('y2', 100);
      svg.append(l);
      scrub.append(el('span', { className: 'daylbl', textContent: `D${n}`, style: `left:${(x / 10).toFixed(2)}%` }));
    }
  }
  const addMark = (ms, title) => scrub.append(el('span', { className: 'mark', title, style: `left:${(xOf(ms) / 10).toFixed(2)}%` }));

  // ---- story moments ----
  const when = (ms) => dayTime(ms, t0, numericTime);
  const go = (ms) => { api.seek(Math.min(t1, Math.max(t0, ms))); };
  const story = [];
  const addItem = (title, sub, run, disabled = false) => {
    const b = el('button', { type: 'button', className: 'item', disabled }, el('b', {}, title), el('small', {}, sub));
    b.addEventListener('click', () => { closePops(); run(); });
    jumpPanel.append(b);
    return b;
  };
  const peakAll = pts.reduce((m, p) => (p.expected > m.expected ? p : m), { expected: -1, t: t0 });
  const flyTo = (id) => {
    const c = api.buildingCenter(id);
    if (c) map.flyTo(c, Math.max(map.getZoom(), 17), { duration: 1.4 });
  };
  addItem('Outbreak peak', `${when(peakAll.t)} · most expected sick`, () => go(peakAll.t));
  if (pts.length > 1) addMark(peakAll.t, 'Outbreak peak');
  const pb = api.peakBuilding();
  if (pb) addItem(`${pb.name || 'Hottest building'} at its peak`, `${when(pb.tMs)} · about ${Math.round(pb.expected)} sick`, () => { go(pb.tMs); flyTo(pb.id); });
  const rep = addItem('First report', 'looking…', () => {}, true);
  api.firstReport().then((r) => {
    if (!r) { rep.querySelector('small').textContent = 'no reports in this run'; return; }
    rep.disabled = false;
    rep.querySelector('small').textContent = `${when(r.tMs)} · ${r.id}`;
    rep.onclick = () => { closePops(); go(r.tMs); };
    addMark(r.tMs, 'First report');
  }).catch(() => { rep.querySelector('small').textContent = 'no reports in this run'; });
  const cc = addItem('First close-contact alert', api.closeContact ? 'opens that person’s phone' : 'needs the full-model run', () => {
    const r = api.closeContact();
    if (!r) { toast('No close-contact alerts in this run'); return; }
    go(r.tMs); api.select(r.id);
  }, !api.closeContact);

  // ---- keyboard ----
  const SPEEDS = ['2 min/s', '10 min/s', '30 min/s', '1 h/s'];
  addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (/^(INPUT|SELECT|TEXTAREA)$/.test(e.target.tagName) && e.key !== 'Escape') return;
    const speed = $('speed');
    const step = (k) => { const i = Math.min(speed.options.length - 1, Math.max(0, speed.selectedIndex + k)); speed.selectedIndex = i; toast(speed.options[i].textContent); };
    if (e.key === ' ' || e.code === 'Space') { if (e.target.tagName === 'BUTTON') return; e.preventDefault(); $('play').click(); toast(api.isPlaying() ? 'Playing' : 'Paused'); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); go(api.getNow() - 10 * 60000); toast('−10 min'); }
    else if (e.key === 'ArrowRight') { e.preventDefault(); go(api.getNow() + 10 * 60000); toast('+10 min'); }
    else if (e.key === '[') step(-1);
    else if (e.key === ']') step(1);
    else if (e.key === 'j' || e.key === 'J') jumpBtn.click();
    else if (e.key === '?') hintBtn.click();
  });

  // ---- "?" hint ----
  const hintCard = main.appendChild(el('div', { className: 'hint-card', hidden: true }, el('h3', {}, 'Shortcuts'),
    ...KEYS.map(([k, t]) => el('div', {}, el('span', {}, t), el('kbd', {}, k)))));
  const hintBtn = main.appendChild(el('button', { type: 'button', className: 'hint-btn', textContent: '?', ariaLabel: 'Keyboard shortcuts', title: 'Keyboard shortcuts' }));
  hintBtn.addEventListener('click', () => { hintCard.hidden = !hintCard.hidden; });
  main.addEventListener('click', (e) => { if (!e.target.closest('.hint-btn, .hint-card')) hintCard.hidden = true; });

  // ---- the selected person: a pulsing ring, and the phone slides in without covering them ----
  const phone = $('phone');
  let ring = null, ringAt = '';
  const frame = () => {
    const id = api.selected(), p = id && api.current().get(id);
    if (!p) { if (ring) { ring.remove(); ring = null; } }
    else {
      if (!ring) ring = L.marker([p.lat, p.lon], { interactive: false, keyboard: false, zIndexOffset: 2000,
        icon: L.divIcon({ className: 'sel-ring', html: '<i></i>', iconSize: [0, 0] }) }).addTo(map);
      const k = `${p.lat},${p.lon}`;
      if (k !== ringAt) { ring.setLatLng([p.lat, p.lon]); ringAt = k; }
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  const keepVisible = () => {
    const id = api.selected(), p = id && api.current().get(id);
    if (!p || phone.hidden) return;
    const left = phone.getBoundingClientRect().left - map.getContainer().getBoundingClientRect().left;
    const pt = map.latLngToContainerPoint([p.lat, p.lon]), size = map.getSize();
    const dx = pt.x > left - 90 ? pt.x - (left - 160) : pt.x < 60 ? pt.x - 160 : 0;
    const dy = pt.y < 90 ? pt.y - 160 : pt.y > size.y - 90 ? pt.y - (size.y - 160) : 0;
    if (dx || dy) map.panBy([dx, dy], { animate: true, duration: 0.5 });
  };
  let wasOpen = false;
  new MutationObserver(() => {
    if (!phone.hidden && !wasOpen) { // opening: slide in, then bring the person clear of it
      wasOpen = true;
      phone.classList.remove('closing');
      phone.classList.add('entering');
      requestAnimationFrame(() => requestAnimationFrame(() => { phone.classList.remove('entering'); keepVisible(); }));
    } else if (phone.hidden && wasOpen) { // closing: stay on screen (CSS) while it slides out
      wasOpen = false;
      phone.classList.add('closing');
      setTimeout(() => phone.classList.remove('closing'), 210);
    }
  }).observe(phone, { attributes: true, attributeFilter: ['hidden'] });

  return { toast };
}
