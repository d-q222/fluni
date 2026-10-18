// HTML for the presenter's phone mock, in the shape of the current FlUni app (proximity/FlUni: TodayView, RiskCardView,
// AtHomeCard, MeView, ReportSheet and the how / calculation sheets): cards in Lisa's drawn boxes, Fredoka titles and big
// numbers, Nunito text. Pure functions of a plain data object (built in app.js from the sim); no state, no DOM access.
// Copy is FlUni's own. Numbers: the person's risk estimate d.p is the campus model's P (model.risk.pAt, the same number
// the presenter shows for that person), drawn with liveText; plus close-contact minutes.

export const esc = (x) => String(x).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

const ASSET = 'assets/illustrations/';
const PRIOR = 0.02;
export const CLOSE_MIN = 15;

// ---------- FlUni's own wording (Core/Exposure.swift, RiskEstimate.swift) ----------

export const ADVICE = {
  nearby: { title: 'Someone within 6 ft may be sick', body: ['Put 6 ft or more between you, or step outside.', "Consider wearing a mask while you're here."] },
  close: { title: 'You were close to someone who may be sick', body: ["You've spent about 15 minutes within 6 ft of someone who may be sick.", 'Leave the room now, or move well away and put on a mask.', 'Wash your hands; avoid touching your face.', 'Watch for fever, cough or sore throat over the next 1–4 days.', 'If symptoms start, get tested and report it in FlUni.'] },
};
const STATUS = {
  none: ['All clear', 'Nobody nearby has reported symptoms or a positive test.'],
  nearby: ['Someone nearby may be sick', 'A few things that help right now.'],
  close: ['Close contact', 'You spent about 15 minutes near someone who may be sick.'],
};
const AT_HOME_STEPS = [
  "Tell your RA and your professors that you're sick and staying home.",
  'Use Vaden Health Center for testing and care. Call ahead instead of walking in.',
  'If you have to go out, wear a mask and keep it short.',
  'Skip the dining halls. Ask a friend to bring food, or order takeout.',
];

// RiskEstimate (proximity/Core/RiskEstimate.swift)
export const band = (p) => (p >= 0.4 ? 'high' : p >= 0.1 ? 'elevated' : 'low');
export const liveText = (p) => {
  if (!(p > 0)) return '0%';
  const tenths = Math.round(p * 1000) / 10;
  return tenths < 10 ? `${tenths.toFixed(1)}%` : `${Math.min(100, Math.round(p * 100))}%`;
};
const percentText = (p) => (p <= 0 ? '0%' : Math.round(p * 100) < 1 ? '<1%' : `${Math.min(100, Math.round(p * 100))}%`);
const summary = (p) => ({ low: 'Low. No action needed.', elevated: 'Elevated. Wear a mask in crowded rooms and watch for symptoms.', high: 'High. Consider getting tested at Vaden and staying home.' })[band(p)];

export const clock = (ms) => new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP])M$/i, (_, c) => ` ${c.toLowerCase()}m`);
const wkd = (ms) => new Date(ms).toLocaleDateString('en-US', { weekday: 'short' });
const longDate = (ms) => new Date(ms).toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' });
const stamp = (ms) => new Date(ms).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + ', ' + clock(ms);

const ICON = {
  info: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 11v6" stroke="#faf4e8" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="7.4" r="1.4" fill="#faf4e8"/>',
  alert: '<circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 6.5v6.5" stroke="#faf4e8" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="16.8" r="1.4" fill="#faf4e8"/>',
  building: '<circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M8 17V8l5-1.500v10M13 10l3 1v6M6.500 17h11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>',
  walk: '<circle cx="13" cy="4.500" r="1.800" fill="currentColor"/><path d="M10 21l2-6-2-2 1-5 3 2 2 2M9 11l-2 3M12 15l3 2.500" fill="none" stroke="currentColor" stroke-width="1.800" stroke-linecap="round" stroke-linejoin="round"/>',
  arrow: '<path d="M4 12h15M13 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
  chevron: '<path d="M9 5l7 7-7 7" fill="none" stroke="currentColor" stroke-width="2.500" stroke-linecap="round" stroke-linejoin="round"/>',
  fn: '<path d="M15 4c-3-1-4 1-4.500 4L9 18c-.5 2.500-1.500 3-4 2M6 11h9M13 14l5 6M18 14l-5 6" fill="none" stroke="currentColor" stroke-width="1.800" stroke-linecap="round" stroke-linejoin="round"/>',
  people: '<circle cx="8" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="1.700"/><circle cx="16.500" cy="9" r="2.500" fill="none" stroke="currentColor" stroke-width="1.700"/><path d="M2.500 19c.5-4 3-5.500 5.500-5.500s5 1.500 5.500 5.500M15 14c3 0 5 1.500 6 5" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linecap="round"/>',
  info2: '<circle cx="12" cy="12" r="9.500" fill="none" stroke="currentColor" stroke-width="1.700"/><path d="M12 11v6" stroke="currentColor" stroke-width="1.900" stroke-linecap="round"/><circle cx="12" cy="7.500" r="1.200" fill="currentColor"/>',
  house: '<path d="M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z" fill="currentColor"/>',
  smile: '<circle cx="12" cy="12" r="9.500" fill="none" stroke="currentColor" stroke-width="1.700"/><path d="M8 14c1 1.800 2.500 2.500 4 2.500s3-.7 4-2.500" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linecap="round"/><circle cx="9" cy="9.500" r="1" fill="currentColor"/><circle cx="15" cy="9.500" r="1" fill="currentColor"/>',
  therm: '<path d="M10 4a2 2 0 0 1 4 0v9.200a4 4 0 1 1-4 0z" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linejoin="round"/><path d="M12 8v7" stroke="currentColor" stroke-width="1.700" stroke-linecap="round"/>',
  cross: '<rect x="3" y="7" width="18" height="13" rx="2.500" fill="none" stroke="currentColor" stroke-width="1.700"/><path d="M9 7V5.500A1.500 1.500 0 0 1 10.500 4h3A1.500 1.500 0 0 1 15 5.500V7M12 10.500v6M9 13.500h6" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linecap="round"/>',
  shield: '<path d="M12 3l7.500 3v5.500c0 4.500-3 8-7.500 9.500-4.500-1.500-7.500-5-7.500-9.500V6z" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linejoin="round"/><path d="M8.500 12l2.500 2.500 4.500-5" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linecap="round" stroke-linejoin="round"/>',
};
const ico = (name, cls = '') => `<svg class="ico ${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICON[name]}</svg>`;
const card = (cls, tint, inner) => `<div class="card ${cls}"${tint ? ` style="--tint:${tint}"` : ''}>${inner}</div>`;

// ---------- Today ----------

function statusCard(d) {
  const [title, subtitle] = STATUS[d.level];
  const lines = d.level === 'none' ? [] : ADVICE[d.level].body;
  const mark = d.level === 'none' ? '<img class="tissue" src="assets/illustrations/tissue.png" alt="">'
    : `<button class="ibtn" data-act="how" aria-label="How alerts work">${ico(d.level === 'close' ? 'alert' : 'info', 'big')}</button>`;
  return card(d.level === 'none' ? '' : 'peach', d.level === 'none' ? 'rgba(172,188,139,.45)' : '', `
    <div class="vstack" style="gap:12px"><div class="row"><div class="grow vstack" style="gap:6px"><p class="t-title2">${esc(title)}</p><p class="t-sub">${esc(subtitle)}</p></div>${mark}</div>
      ${lines.length ? `<div class="vstack" style="gap:8px">${lines.map((l) => `<div class="bullet">${ico('arrow')}<span class="t-sub">${esc(l)}</span></div>`).join('')}</div>` : ''}</div>`);
}

function riskCard(d) {
  const b = band(d.p), hi = b === 'high';
  const tint = { low: 'rgba(172,188,139,.45)', elevated: 'rgba(235,209,135,.5)', high: 'rgba(219,108,89,.22)' }[b];
  const note = hi ? 'fireink' : 'ink2';
  return card('', tint, `<div class="vstack ${hi ? 'fireink' : ''}" style="gap:8px">
    <p class="t-head">Your risk estimate</p>
    <p class="t-large" data-live="risk">${esc(liveText(d.p))}</p>
    <p class="t-sub">${esc(summary(d.p))}</p>
    <p class="t-foot ${note}">Based on the last 24 hours: time near each person, how close (closer counts much more), shared room air, and whether they reported symptoms or a positive test. It's an estimate, not a diagnosis.</p>
    <button class="link ${note}" data-act="calc">${ico('fn')}See how this is worked out</button></div>`);
}

function minutesCard(d) {
  const mins = d.minutes, done = mins >= CLOSE_MIN;
  const caption = done ? `You've reached the ${CLOSE_MIN}-minute close-contact mark.`
    : mins > 0 ? `About ${Math.ceil(CLOSE_MIN - d.exactMinutes)} more minutes would make this a close contact.` : 'No time near someone with symptoms or a positive test.';
  return card('', '', `<div class="vstack" style="gap:10px"><p class="t-head">Close-contact time</p>
    <div style="display:flex;align-items:baseline;gap:6px"><span class="t-large">${mins}</span><span class="t-sub ink2">of ${CLOSE_MIN} min</span></div>
    <div class="progress ${done ? 'done' : ''}" role="progressbar" aria-valuenow="${Math.min(d.exactMinutes, CLOSE_MIN).toFixed(0)}" aria-valuemax="${CLOSE_MIN}"><i style="width:${Math.min(1, d.exactMinutes / CLOSE_MIN) * 100}%"></i></div>
    <p class="t-foot ink2">${esc(caption)}</p></div>`);
}

function historyCard(d) {
  const rows = d.contacts.slice(0, 3).map((c) => `<div class="crow"><span class="w">${esc(`${wkd(c.startMs)} ${clock(c.startMs)}`)}</span><div>${esc(c.text)}${c.close ? '<br><span class="cc">Close contact</span>' : ''}</div></div>`).join('');
  return `<div class="vstack" style="gap:10px"><p class="t-title3">Recent contacts</p>${d.contacts.length
    ? `${rows}<span class="link between">See the last 14 days${ico('chevron')}</span>`
    : `<div class="contacts-empty"><img src="${ASSET}tissue.png" alt=""><div><b>No one sick nearby lately</b><span class="t-foot ink2">No time near someone with symptoms or a positive test in the last 14 days.</span></div></div>`}</div>`;
}

// the stay-home card (AtHomeCard): shown instead of the status, risk and minutes cards while someone is sick
function atHomeCard(d) {
  const s = d.stay;
  const day = s ? Math.min(s.day, 5) : 0;
  const over = s && s.over;
  const stampImg = d.stamp ? `<img class="stamp" src="${ASSET}stamp-self-reported.png" alt="Self-reported">` : '';
  const head = `<div class="row" style="align-items:center;justify-content:space-between"><span class="t-head" style="display:flex;gap:8px;align-items:center">${ico('house')}At home</span>${over ? '' : `<span class="t-sub semi">Day ${day} of 5</span>`}</div>
    <div class="sickfig"><img src="${ASSET}illo-sick@600.png" alt="">${stampImg}</div>`;
  const intro = over ? '' : `<div class="progress" aria-hidden="true"><i style="width:${(day / 5) * 100}%"></i></div>
    <p class="t-foot ink2">Stay home through ${esc(longDate(s.lastMs))}, and until you've had no fever for 24 hours without fever-reducing medicine. Day 0 is the day your symptoms started or you tested positive.</p>`;
  const action = over
    ? `<div class="vstack" style="gap:8px"><p class="t-sub semi" style="font-size:17px">Your 5 days are up. How are you feeling?</p><p class="t-foot ink2">Your status stays the same until you change it.</p>
        <button class="btn">Set my status to healthy</button><button class="btn second">I'm still sick</button></div>`
    : `<div class="vstack" style="gap:8px"><p class="t-sub semi" style="font-size:17px">Do you still have symptoms?</p>
        <button class="btn second">Yes, still sick</button><button class="btn second">Yes, and I have a fever</button><button class="btn second">No, I feel better</button></div>`;
  const steps = `<div class="vstack" style="gap:6px"><p class="t-sub semi">What to do</p>${AT_HOME_STEPS.map((l) => `<div class="bullet2"><span>•</span><span class="t-foot ink2">${esc(l)}</span></div>`).join('')}</div>`;
  return card('', 'rgba(244,234,214,1)', `<div class="vstack" style="gap:12px">${head}${intro}${action}${steps}</div>`)
    + `<p class="t-foot ink2" style="margin:0">${d.status === 'contagious' ? 'Phones near you see: tested positive.' : 'Phones near you see: possibly sick.'}</p>`;
}

export function todayHtml(d) {
  const out = [];
  const sick = d.status !== 'none';
  if (d.walkIn) out.push(card('peach', '', `<div class="row">${ico('building')}<p class="grow t-sub semi">${esc(d.walkIn)} has a lot of illness right now. Consider a mask, or a different spot.</p></div>`));
  if (sick) out.push(atHomeCard(d));
  else {
    if (d.level === 'nearby') out.push(card('peach', '', `<div class="row">${ico('walk')}<div class="grow"><p class="t-sub semi">${esc(ADVICE.nearby.title)}</p><p class="t-foot">${esc(ADVICE.nearby.body.join(' '))}</p></div></div>`));
    out.push(statusCard(d), riskCard(d), minutesCard(d));
    out.push(card('', '', `<div class="row" style="align-items:center"><span class="ink2">${ico('people')}</span><p class="grow t-body semi">${d.peers === 0 ? 'No other FlUni phones nearby' : d.peers === 1 ? '1 other FlUni phone nearby' : `${d.peers} other FlUni phones nearby`}</p></div>`));
    out.push(historyCard(d));
  }
  out.push(`<button class="link how" data-act="how">${ico('info2')}How FlUni works and what it shares</button>`);
  return out.join('');
}

// ---------- Me ----------

export function meHtml(d) {
  const st = d.status;
  const row = (icon, tint, title, detail, on, chev) => `<div class="card mrow"><div class="row" style="align-items:center"><span class="circle" style="background:${tint}">${ico(icon)}</span><div class="grow"><p class="t-body semi">${title}</p><p class="t-foot ink2">${detail}</p></div>
    ${on ? '<span class="mk on">✓</span>' : `<span class="mk">${chev ? '›' : '○'}</span>`}</div></div>`;
  const since = d.statusSetMs != null ? `Status set ${stamp(d.statusSetMs)}` : `You haven't set a status yet. Phones near you see "healthy".`;
  return `${st !== 'none' ? atHomeCard(d) : ''}
    <p class="t-title3 bold">How are you doing?</p>
    ${row('smile', 'rgba(172,188,139,.45)', 'I feel fine', 'Phones near you see: healthy.', st === 'none', false)}
    ${row('therm', 'rgba(235,209,135,.45)', 'I have symptoms', 'Phones near you see: possibly sick. Time near you counts half toward their close contact.', st === 'possible', true)}
    ${row('cross', 'rgba(219,108,89,.45)', 'I tested positive', 'Phones near you see: contagious, and may alert their owners.', st === 'contagious', true)}
    ${row('shield', 'rgba(172,188,139,.45)', 'I tested negative', "Sets you back to healthy if you were possibly sick. One rapid negative test isn't conclusive.", false, true)}
    <p class="t-foot ink2">${esc(since)}</p>
    <p class="t-foot ink2" style="margin-top:4px">Only your status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes are shared with phones nearby. Symptoms, test details and dates stay on this phone. No name, no location.</p>
    <p class="t-body semi" style="display:flex;gap:8px;align-items:center;margin:0">⚙︎ Settings</p>`;
}

// ---------- sheets ----------

const STICKERS = [['fever', 'Fever'], ['cough', 'Cough'], ['sore-throat', 'Sore throat'], ['aches', 'Aches'], ['fatigue', 'Fatigue'], ['runny-nose', 'Runny nose']];

export function reportSheetHtml(s, d) {
  const dayMs = d.now - (s.when ?? 0) * 86400000;
  const when = s.when ? (s.when === 1 ? 'Yesterday' : `${s.when} days ago`) : 'Today';
  return `<div class="sheet" role="dialog" aria-label="I have symptoms"><div class="navbar"><button class="navbtn" data-act="sheet-close">Cancel</button><b>I have symptoms</b><span></span></div>
    <div class="vstack" style="gap:14px;padding:6px 0 0">
    <img class="figsick" src="${ASSET}illo-sick@600.png" alt="">
    <p class="t-head">What are you feeling?</p><p class="t-sub ink2">Tap every sticker that fits.</p>
    <div class="stickers">${STICKERS.map(([k, t]) => `<button class="card sticker ${s.picked.has(k) ? 'on peach' : ''}" data-act="sticker" data-k="${k}"><img src="${ASSET}symptoms/${k}.png" alt=""><span>${t}</span></button>`).join('')}</div>
    <div class="row" style="align-items:center;justify-content:space-between;min-height:44px"><span class="t-body">When did it start?</span><button class="datepill" data-act="when" data-i="${((s.when ?? 0) + 1) % 4}">${esc(when)} · ${esc(new Date(dayMs).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }))}</button></div>
    <p class="lock">🔒 Any one symptom is enough. Phones near you will only see "possibly sick". Your symptoms, the date and your name are never shared. They stay on this phone.</p>
    <button class="btn sun ${s.picked.size ? '' : 'off'}" data-act="report-send">Set status to possibly sick</button></div>
    ${s.stamped ? `<div class="stampwrap"><img src="${ASSET}stamp-self-reported.png" alt="Self-reported"></div>` : ''}</div>`;
}

const block = (t, body, num) => `<div class="block"><h2>${esc(t)}</h2><p>${esc(body)}</p>${num ? `<div class="num">${esc(num)}</div>` : ''}</div>`;
const sheet = (title, inner) => `<div class="sheet" role="dialog" aria-label="${esc(title)}"><div class="navbar"><span></span><b>${esc(title)}</b><button class="navbtn" data-act="sheet-close">Done</button></div>${inner}</div>`;

export function calcSheetHtml(d) {
  return sheet('How is this calculated?',
    block('Close contact', `Minutes within 6 ft of someone. They count in full if the person tested positive and half if they have symptoms. At ${CLOSE_MIN} of these in a day, FlUni tells you it's a close contact.`, `You: ${d.exactMinutes.toFixed(1)} of ${CLOSE_MIN}`)
    + block('What adds to your risk', 'Time near each person, how close you were (closer counts much more), the room air you shared, and how likely each of them is to be sick. Phones up to about 10 m away (Bluetooth range) count.', null)
    + block('The estimate', `Each contact becomes a chance that person passed flu on to you, weighted by how likely they are to be sick: from their reports and tests, and from who they were near, so second-hand risk counts too. Your own reports and tests count as well. Those chances are added on top of a ${Math.round(PRIOR * 100)}% everyday baseline and fade as flu runs its course (about a week). It's worked out from everyone's contacts, reports and tests on campus, not just what this phone detected.`, `Your risk estimate: ${liveText(d.p)}`)
    + block('What counts', "GPS alone doesn't count, because it's too coarse to tell 3 feet from 30. Bluetooth and precise distance sensing do. The close-contact count uses only the last 24 hours.", null)
    + '<p class="fineprint">This is an estimate to help you decide what to do. It isn\'t a diagnosis.</p>');
}

export const howSheetHtml = () => sheet('How this works',
  block('How it works', "Your phone and other phones running FlUni notice each other over Bluetooth, and with precise distance sensing on newer iPhones. Together they estimate whether you're within 6 feet. If someone with symptoms or who tested positive is close for about 15 minutes in total, you get a heads-up with advice.")
  + block('What your phone shares', 'A 3-level status (healthy, possibly sick or contagious), how many days ago your symptoms or positive test began, this phone\'s risk estimate and a random ID that changes every 15 minutes. Other FlUni phones use them for their own estimate and never show them, but a Bluetooth scanner can read them. No name, no phone number, no account.')
  + block("What it doesn't share", 'Your location is never sent to other people or to a server. Matching happens on your phone, and the map shows building totals, not people.')
  + block('Good to know', "FlUni works best while the app is open, and keeps checking over Bluetooth in the background, less often. It's a nudge, not a diagnosis. If you feel unwell or are worried, get tested and follow campus health guidance."));
