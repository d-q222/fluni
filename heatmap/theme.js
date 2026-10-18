// Night mode for the phone mock (design pass): Lisa's drawings in their lamp-lit night versions
// (assets/night/, same paths) and the app's colours in a dark, cozy palette (index.html, #phone[data-theme="night"]).
//
// It follows the computer's light/dark setting until the presenter flips the Night button, which is then
// remembered in this browser. Only the phone goes dark: the presenter's map keeps its day colours, so
// the heat reads the same in every demo.
//
// Images are swapped by watching the phone: any <img> under it that points into assets/ is pointed at
// assets/night/ (and back), so screens drawn later by other modules pick it up with no changes there.

const NIGHT_DIRS = ['checkin/', 'containers/', 'icons/', 'illustrations/', 'loading/', 'people/', 'tabbar/', 'tissue-alert/'];
const KEY = 'fluni-night';
const DAY = 'assets/', NIGHT = 'assets/night/';

function swap(src, night) {
  if (!src) return src;
  const i = src.indexOf(DAY);
  if (i < 0) return src;
  const rest = src.slice(i + DAY.length);
  if (night) return NIGHT_DIRS.some((d) => rest.startsWith(d)) ? src.slice(0, i) + NIGHT + rest : src;
  return rest.startsWith('night/') ? src.slice(0, i) + DAY + rest.slice(6) : src;
}

export function initNightMode(phone, button) {
  const media = matchMedia('(prefers-color-scheme: dark)');
  let saved = null;
  try { saved = localStorage.getItem(KEY); } catch { /* private window: follow the system */ }
  let night = saved == null ? media.matches : saved === '1';

  const fix = (img) => { const s = img.getAttribute('src'), t = swap(s, night); if (t !== s) img.setAttribute('src', t); };
  const fixAll = () => phone.querySelectorAll('img').forEach(fix);
  new MutationObserver((muts) => {
    for (const m of muts) {
      if (m.type === 'attributes') { if (m.target.tagName === 'IMG') fix(m.target); continue; }
      for (const n of m.addedNodes) {
        if (n.nodeType !== 1) continue;
        if (n.tagName === 'IMG') fix(n); else n.querySelectorAll?.('img').forEach(fix);
      }
    }
  }).observe(phone, { subtree: true, childList: true, attributes: true, attributeFilter: ['src'] });

  function apply() {
    phone.dataset.theme = night ? 'night' : 'day';
    fixAll();
    phone.dispatchEvent(new Event('fluni-theme')); // canvas layers (the phone's map) restyle themselves
    if (button) {
      button.setAttribute('aria-pressed', String(night));
      button.textContent = night ? '☀︎ Day' : '☾ Night';
    }
  }
  button?.addEventListener('click', () => {
    night = !night;
    try { localStorage.setItem(KEY, night ? '1' : '0'); } catch { /* not remembered, still switches */ }
    apply();
  });
  media.addEventListener('change', (e) => {
    let s = null; try { s = localStorage.getItem(KEY); } catch { /* ignore */ }
    if (s == null) { night = e.matches; apply(); }
  });
  apply();
  return { isNight: () => night };
}
