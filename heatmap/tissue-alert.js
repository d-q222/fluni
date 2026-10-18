// Lisa's tissue alert (design pass; art in assets/tissue-alert/, made from her frames).
//
// Normally the tissue box in the tab bar is empty. When the phone raises an alert (someone within 6 ft
// may be sick, or a close contact), a tissue pops out of the box and wiggles. Tapping it pulls the
// tissue out frame by frame (her drawings, hard cuts like hand animation) until it becomes a sheet of
// paper with the alert on it. "Got it" puts it away until the next, different alert.
//
// Every layer is the same size as the phone screen above and including the tab bar, so they all
// line up with the box drawn in the tab bar. The layers only hold what differs from the empty box.
// The alert itself also stays on the Today screen as text, so nothing depends on finding the tissue.

const ART = 'assets/tissue-alert/';
const PULL = [1, 2, 3, 4, 5, 6].map((i) => `${ART}pull-${i}.png`);
const FRAME_MS = 120; // per frame of the pull (Lisa: a little slower)

export function mountTissueAlert(frame) {
  const root = document.createElement('div');
  root.className = 'tissue-alert';
  root.hidden = true;
  root.innerHTML = `
    <img class="ta-rim" alt="" src="${ART}pull-0-rim.png">
    <img class="ta-art" alt="" src="${ART}pull-0-tissue.png">
    <button type="button" class="ta-pop" aria-label="New alert. Tap the tissue to read it."><span class="ta-hint">Pull me</span></button>
    <div class="ta-note" role="alertdialog" aria-modal="false" hidden><div class="ta-text"></div>
      <button type="button" class="ta-ok">Got it</button></div>
    <button type="button" class="ta-x" aria-label="Close alert" hidden><img src="assets/icons/close.png" alt=""></button>`;
  frame.appendChild(root);
  // Preload so the pull never stutters on first tap.
  for (const src of [...PULL, `${ART}sheet.png`]) { const i = new Image(); i.src = src; }

  const art = root.querySelector('.ta-art'), pop = root.querySelector('.ta-pop');
  const note = root.querySelector('.ta-note'), text = root.querySelector('.ta-text');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  let state = 'idle'; // idle | popped | pulling | open
  let level = 'none', readLevel = null, message = null, timer = 0;

  function show(s) {
    state = s;
    root.hidden = s === 'idle';
    root.dataset.state = s;
    pop.hidden = s !== 'popped';
    note.hidden = s !== 'open';
    root.querySelector('.ta-x').hidden = s !== 'open'; // Lisa's hand-drawn X, the same as Got it
    // Popped: only the tissue wiggles; the box rim it pokes out of is its own still layer (the whole
    // layer used to rotate, shaking the back of the box).
    if (s === 'popped') art.src = `${ART}pull-0-tissue.png`;
    if (s === 'open') { art.src = `${ART}sheet.png`; root.querySelector('.ta-ok').focus({ preventScroll: true }); }
  }

  function render() {
    if (!message) return;
    text.innerHTML = `<p class="ta-kicker">${message.kicker}</p><h3>${message.title}</h3><ul>${message.lines.map((l) => `<li>${l}</li>`).join('')}</ul>`;
  }

  pop.addEventListener('click', () => {
    if (state !== 'popped') return;
    if (reduce.matches) { show('open'); return; }
    state = 'pulling'; root.dataset.state = 'pulling'; pop.hidden = true;
    let i = 0;
    const step = () => {
      if (i < PULL.length) { art.src = PULL[i++]; timer = setTimeout(step, FRAME_MS); }
      else show('open');
    };
    step();
  });
  const putAway = () => { readLevel = level; clearTimeout(timer); show('idle'); };
  root.querySelector('.ta-ok').addEventListener('click', putAway);
  root.querySelector('.ta-x').addEventListener('click', putAway);

  return {
    /** level: 'none' | 'nearby' | 'close'; visible: the Today tab is showing; msg: { kicker, title, lines } (escaped HTML). */
    update({ level: lv, visible, msg }) {
      if (lv === 'none') readLevel = null;        // the next alert, whenever it comes, pops again
      const changed = lv !== level;
      level = lv; message = msg;
      if (state === 'open' || state === 'pulling') { render(); if (!visible || lv === 'none') { clearTimeout(timer); show('idle'); } return; }
      const want = visible && lv !== 'none' && lv !== readLevel;
      if (want && (state === 'idle' || changed)) { render(); show('popped'); }
      else if (!want && state !== 'idle') show('idle');
      else if (want) render();
    },
  };
}
