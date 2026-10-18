// HTML for the presenter's phone mock, in the shape of the current FlUni app (flu-design2): Today as a "your day"
// timeline narrated by Lisa's tissue, the stay-home track, You, and the report / calculation sheets. Pure
// functions of a plain data object (built in app.js from the sim); no state, no DOM access. Copy is FlUni's own.
// Numbers: the person's risk estimate d.p is the campus model's P (model.risk.pAt, the same number the presenter
// shows for that person), drawn with liveText; plus close-contact minutes.

export const esc = (x) => String(x).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
// "FlUni" in a sentence is set in the wordmark serif, so its "l" never reads as "I".
const brand = (s) => esc(s).replace(/FlUni/g, '<span class="brandname">FlUni</span>');

const ASSET = 'assets/illustrations/';
const PRIOR = 0.02;
export const CLOSE_MIN = 15;

// ---------- FlUni's own wording ----------

export const ADVICE = {
  nearby: { title: 'Someone within 6 ft may be sick', body: ['Put 6 ft or more between you, or step outside.', "Consider wearing a mask while you're here."] },
  close: { title: 'You were close to someone who may be sick', body: ["You've spent about 15 minutes within 6 ft of someone who may be sick.", 'Leave the room now, or move well away and put on a mask.', 'Wash your hands; avoid touching your face.', 'Watch for fever, cough or sore throat over the next 1–4 days.', 'If symptoms start, get tested and report it in FlUni.'] },
};
const MOODS = {
  calm: "Calm day. Nobody near you has said they feel sick, so I'm off duty.",
  careful: 'Nobody sick near you right now. Earlier today still counts, so go easy on yourself.',
  heads: 'Someone close by may be sick. A little space goes a long way.',
  alert: "Okay, eyes up. We'll handle this together, one step at a time.",
  sick: "Rest is the whole job today. I'll keep count of the days.",
};

// RiskEstimate (proximity/Core/RiskEstimate.swift)
export const band = (p) => (p >= 0.4 ? 'high' : p >= 0.1 ? 'elevated' : 'low');
export const liveText = (p) => {
  if (!(p > 0)) return '0%';
  const tenths = Math.round(p * 1000) / 10;
  return tenths < 10 ? `${tenths.toFixed(1)}%` : `${Math.min(100, Math.round(p * 100))}%`;
};
const summary = (p) => ({ low: 'Low. No action needed.', elevated: 'Elevated. Wear a mask in crowded rooms and watch for symptoms.', high: 'High. Consider getting tested at Vaden and staying home.' })[band(p)];
const changeLine = (p) => {
  const from = liveText(PRIOR), to = liveText(p);
  const start = from === to ? `Your risk estimate is ${to}, the everyday baseline.` : `Your risk estimate went from ${from} to ${to}.`;
  return start + ({ low: ' That is still low.', elevated: ' That is elevated, so wear a mask in crowded rooms and watch for symptoms.', high: ' That is high. Consider getting tested at Vaden and staying home.' })[band(p)];
};

// ---------- time formats (TimelineFormat) ----------

export const clock = (ms) => new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }).replace(/\s?([AP])M$/i, (_, c) => ` ${c.toLowerCase()}m`);
const hm = (ms) => { const d = new Date(ms); return `${d.getHours() % 12 || 12}:${String(d.getMinutes()).padStart(2, '0')}`; };
const duration = (min) => { const m = Math.max(1, Math.round(min)); return m < 60 ? `${m} min` : m % 60 === 0 ? `${m / 60} h` : `${Math.floor(m / 60)} h ${m % 60} min`; };
const phones = (n) => (n === 0 ? 'no phones near' : n === 1 ? 'near 1 phone' : `near up to ${n} phones`);
const wkd = (ms) => new Date(ms).toLocaleDateString('en-US', { weekday: 'short' });
const longDate = (ms) => new Date(ms).toLocaleDateString('en-US', { weekday: 'long', month: 'short', day: 'numeric' });

// ---------- pieces ----------

const squiggle = '<svg viewBox="0 0 62 10" aria-hidden="true"><path d="M2 6 Q9 0.5 16 5 T31 5 T46 5 T60 5" fill="none" stroke="#e99569" stroke-width="2.6" stroke-linecap="round"/></svg>';
export const wordmark = (cls = '') => `<span class="wordmark ${cls}">FlUni${squiggle}</span>`;

function tissue(mood, stamp) {
  const bubbleTail = '<svg viewBox="0 0 15 17" aria-hidden="true"><path d="M14.5 1 Q5 3 0.5 11 Q7 9 14.5 14" style="fill: var(--surface); stroke: var(--ink)" stroke-width="1.5" stroke-linejoin="round"/><path d="M15.5 2 V13.5" stroke="#fffaf1" stroke-width="3"/></svg>';
  const marks = (c) => `<svg class="marks" viewBox="0 0 44 26" aria-hidden="true"><path d="M0 9 L10 26 M22 0 L23 24 M44 8 L35 26" fill="none" stroke="${c}" stroke-width="3.5" stroke-linecap="round"/></svg>`;
  let fig;
  if (mood === 'sick') fig = `<img class="sick" src="${ASSET}illo-sick@600.png" alt="">${stamp ? `<img class="stamp" src="${ASSET}stamp-self-reported.png" alt="Self-reported">` : ''}`;
  else {
    const kind = mood === 'heads' ? 'heads' : mood === 'alert' ? 'alert' : 'calm';
    fig = `<img class="t" src="${ASSET}tissue.png" alt="">${kind === 'alert' ? marks('#db6c59') : kind === 'heads' ? marks('#e99569') : ''}`;
  }
  const k = mood === 'careful' ? 'calm' : mood;
  return `<div class="narrator"><div class="tissue-fig ${k}" aria-hidden="true">${fig}</div><div class="bubble">${bubbleTail}${esc(MOODS[mood])}</div></div>`;
}

const node = (kind) => `<span class="nd ${kind}">${kind === 'done' ? '✓' : ''}</span>`;
function railRow({ label, time, kind, tone, ny = 14, content, last }) {
  const line = tone === 'none' ? '' : `<span class="ln ${tone === 'quiet' ? 'dash' : ''}"></span>`;
  return `<div class="rail ${tone ? `tone-${tone}` : ''} ${last ? 'last' : ''}" style="--ny:${ny}px;--ty:${Math.max(0, ny - 9)}px">
    <div class="tm">${label ? `<b>${esc(label)}</b>` : ''}${time ? esc(time) : ''}</div>
    <div class="rl">${line}${node(kind)}</div><div class="ct">${content}</div></div>`;
}

function metrics(d) {
  const filled = Math.min(d.minutes, CLOSE_MIN), reached = d.minutes >= CLOSE_MIN;
  const b = band(d.p), hi = b !== 'low';
  const ticks = Array.from({ length: CLOSE_MIN }, (_, i) => `<i class="${i < filled ? 'on' : ''}"></i>`).join('');
  return `<div class="metrics">
    <div class="mins"><div class="fig" style="${reached ? 'color:var(--fire-ink)' : ''}">${d.minutes}<small>/ ${CLOSE_MIN} min</small></div>
      <div class="ticks ${reached ? 'reached' : ''}" aria-hidden="true">${ticks}</div><div class="fine2">close to someone sick</div></div>
    <div class="vr"></div>
    <div class="rk"><div class="fig ${hi ? 'hi' : ''}" data-live="risk">${esc(liveText(d.p))}<span class="band ${hi ? 'hi' : ''}">${b}</span></div>
      <div class="lbl">risk estimate</div><button class="why" data-act="calc">Why this number</button></div></div>`;
}

function nowBlock(d, ccOpen) {
  const lvl = d.level;
  const word = lvl === 'close' ? ['Close contact', 'var(--fire)', 'var(--fire-ink)'] : lvl === 'nearby' ? ['Heads-up', 'var(--sun)', 'var(--ink)'] : ['All clear', 'var(--sage)', 'var(--ink)'];
  const n = d.peers, near = d.place ? `Here since ${clock(d.place.startMs)}, near ` : 'Near ';
  const detail = lvl === 'none'
    ? (n === 0 ? (d.place ? `Here since ${clock(d.place.startMs)}. No other FlUni phones nearby right now.` : 'No other FlUni phones nearby right now.')
      : `${near}${n} other ${n === 1 ? 'phone' : 'phones'}. None of them sick.`)
    : lvl === 'nearby' ? "They're probably within 6 ft of you right now. About 15 minutes this close makes a close contact." : '';
  const headsUp = lvl === 'nearby'
    ? `<div class="headsup"><p class="lead">${esc(ADVICE.nearby.title)}</p><ul>${ADVICE.nearby.body.map((l) => `<li><span>${esc(l)}</span></li>`).join('')}</ul></div>` : '';
  return `<div class="now-gap">
    <div><h2 class="display ${(d.place?.name || '').length > 20 ? 'long' : ''}">${esc(d.place?.name || 'On campus')}</h2>
      <div class="status"><span class="dot" style="background:${word[1]}"></span><span class="word" style="color:${word[2]}">${word[0]}</span></div></div>
    ${headsUp}${detail ? `<p class="note">${brand(detail)}</p>` : ''}
    ${d.walkIn ? `<div class="walkin"><span>${brand(`${d.walkIn} has a lot of illness right now. Consider a mask, or a different spot.`)}</span></div>` : ''}
    ${metrics(d)}
    ${band(d.p) !== 'low' ? `<p class="advice-line">${esc(summary(d.p))}</p>` : ''}
    ${ccOpen ? '' : `<div><button class="btn" data-act="report">I don't feel well</button><p class="centerfine">Takes about 20 seconds. Nobody sees your symptoms.</p></div>`}</div>`;
}

function placeRow(v) {
  const length = v.minutes < 3 && v.passing ? 'Walked through' : duration(v.minutes), near = phones(v.maxPhones);
  const tail = v.tone === 'close' ? ', close contact here' : v.tone === 'heads' ? ', one heads-up' : v.tone === 'phones' ? ', all healthy' : '';
  return `<h3 class="section">${esc(v.name)}</h3><p class="note pl-detail">${esc(`${length}, ${near}${tail}`)}</p>`;
}
function headsRow(m) {
  return `<p class="strong" style="margin:0">${esc(ADVICE.nearby.title)}</p><p class="note pl-detail">${esc(`Heads-up for about ${duration(m.minutes)}${m.place ? ` at ${m.place}.` : '.'}`)}</p>`;
}
function closeRow(m, open) {
  const title = ADVICE.close.title;
  if (!open) {
    return `<button class="cc-folded" data-act="cc-toggle" data-key="${m.key}"><span class="t">${esc(title)}</span><span class="note">${esc(`About ${m.live ? '15 min' : duration(m.minutes)}${m.place ? ` at ${m.place}` : ''}. Show the steps again.`)}</span></button>`;
  }
  const who = m.contagious ? 'a phone whose owner reported a positive test' : 'a phone whose owner reported symptoms';
  const reason = m.live ? ADVICE.close.body[0]
    : `From ${clock(m.startMs)} to ${clock(m.endMs)} you were within 6 ft of ${who}${m.place ? `, at ${m.place}` : ''}. About ${duration(m.minutes)}.`;
  const steps = ADVICE.close.body.slice(1).map((s, i) => `<div class="step ${i === 0 ? 'first' : ''}"><span class="n">${i + 1}</span><span>${brand(s)}</span></div>`).join('');
  return `<div class="cc-open"><div><p class="lead" style="margin-bottom:8px">${esc(title)}</p><p style="margin:0">${esc(reason)}</p></div><hr>
    <div class="steps">${steps}</div><p class="note" style="color:var(--ink)" data-live="ccrisk">${esc(changeLine(m.p))}</p>
    <div style="display:flex;flex-direction:column;gap:12px"><button class="btn" data-act="got-it" data-key="${m.key}">Got it</button><button class="btn second" data-act="report">I don't feel well</button></div>
    <button class="quiet" data-act="calc">How we worked this out</button></div>`;
}

// ---------- Today ----------

export function todayHtml(d) {
  const sick = d.status !== 'none';
  const mood = sick ? 'sick' : d.level === 'nearby' ? 'heads' : d.level === 'close' ? 'alert' : band(d.p) === 'low' ? 'calm' : 'careful';
  const head = `<div class="p-head">${wordmark()}<span class="p-date">${esc(d.dateText)}</span></div>${tissue(mood, sick && d.stamp)}`;
  if (sick) return head + stayHome(d);

  const entries = d.entries; // newest first: { type: 'place'|'heads'|'close', ... }
  const liveCC = d.level === 'close' && !entries.some((e) => e.type === 'close');
  const nowTone = d.level === 'close' ? 'close' : d.level === 'nearby' ? 'heads' : d.placeTone || (d.peers > 0 ? 'phones' : 'quiet');
  const anyBelow = entries.length > 0 || liveCC;
  const rows = [];
  const ccKey = (e) => e.key;
  const isOpen = (e) => d.openKey === e.key || (d.level === 'close' && !d.seen.has(e.key) && d.openKey !== `x${e.key}`);
  const live = { type: 'close', live: true, key: 'live', startMs: d.now, minutes: 15, p: d.p, place: d.place?.name };
  const ccOpen = d.level === 'close' && (liveCC ? isOpen(live) : entries.some((e) => e.type === 'close' && isOpen(e)));
  rows.push(railRow({ label: 'Now', time: hm(d.now), kind: 'now', tone: anyBelow ? nowTone : 'none', ny: 22, content: nowBlock(d, ccOpen) }));
  const toneOf = (e) => (e.type === 'place' ? e.tone : e.type === 'close' ? 'close' : 'heads');
  const all = liveCC ? [live, ...entries] : entries;
  all.forEach((e, i) => {
    const rowTone = i + 1 < all.length ? toneOf(e) : 'none';
    if (e.type === 'place') rows.push(railRow({ time: hm(e.startMs), kind: 'place', tone: rowTone, content: placeRow(e) }));
    else if (e.type === 'heads') rows.push(railRow({ time: hm(e.startMs), kind: 'heads', tone: rowTone, content: headsRow(e) }));
    else rows.push(railRow({ time: hm(e.startMs), kind: 'close', tone: rowTone, content: closeRow({ ...e, p: d.p, key: ccKey(e) }, isOpen(e)) }));
  });
  const empty = !entries.length && !d.place ? '<p class="fine2" style="margin-top:8px">Places you spend time in today show up here, newest first. Only building names, kept on this phone for 24 hours.</p>' : '';
  const foot = `<hr class="hr-hand"><div class="legend-rail"><span><i style="background:var(--sage)"></i>near phones</span><span><i style="background:var(--sun)"></i>heads-up</span><span><i style="background:var(--fire)"></i>close contact</span></div>
    <p class="privacy">Places here are building names, kept on this phone for 24 hours. Your precise location never leaves this phone and is never seen by anyone.</p>
    <button class="quiet" data-act="how">How it works and what's shared</button>`;
  return head + rows.join('') + empty + foot;
}

// ---------- stay home (self-reported or tested positive) ----------

function stayHome(d) {
  const s = d.stay; // { day, lastMs, startMs, over, positive, days: [{ day, ms }] }
  const risk = d.status === 'contagious' ? 'Nearby phones see you as contagious' : 'Nearby phones see you as possibly sick';
  const heading = `<div class="stay-h"><p class="k">Staying home</p>${s.over
    ? '<h2 class="display">Your 5 days are up</h2>'
    : `<h2 class="day">Day ${s.day} of 5</h2><p class="thru">Home through ${esc(longDate(s.lastMs))}</p>`}
    <div class="seen"><span class="dot" style="background:${d.status === 'contagious' ? 'var(--fire)' : 'var(--sun)'}"></span><span>${risk}</span></div></div>`;
  let track = '';
  if (s.over) {
    track = `<div class="now-gap"><p class="lead">How are you feeling?</p><p class="fine2">Your status stays the same until you change it.</p><button class="btn">Set my status to healthy</button><button class="btn second">I'm still sick</button></div>`;
  } else {
    const rows = s.days.map((x, i) => {
      const isToday = x.day === s.day, past = x.day < s.day, last = x.day === 5;
      const lbl = `${wkd(x.ms)} ${new Date(x.ms).getDate()}`;
      const tone = last ? 'none' : past ? 'recover' : 'quiet';
      let content;
      if (isToday) {
        content = `<div class="now-gap" style="margin-top:0"><div><p class="fine2 strong" style="margin-bottom:4px">${x.day === 0 ? 'Day 0, it started' : `Day ${x.day}`}</p><p class="lead">How are you feeling?</p><p class="note" style="margin-top:4px">Today's check-in. One tap.</p></div>
          <div class="pills"><button class="pill2">Better</button><button class="pill2">The same</button><button class="pill2">Worse</button></div>
          <p class="fine2">Fever-free for 24 h without medicine? Then you can end your stay once day 5 is done.</p></div>`;
      } else if (x.day === 0) {
        content = `<p class="strong" style="margin:0">${s.positive ? 'Day 0, tested positive' : 'Day 0, symptoms started'}</p><p class="note pl-detail">${s.positive ? 'Reported a positive test.' : 'Reported symptoms.'}</p>`;
      } else if (last) {
        content = `<p class="strong" style="margin:0">Day 5, last day home</p><p class="note pl-detail">Out on ${esc(new Date(x.ms + 86400000).toLocaleDateString('en-US', { weekday: 'long' }))}, if you've had no fever for 24 hours.</p>`;
      } else content = `<p class="strong" style="margin:0">Day ${x.day}</p>${past ? '' : '<p class="note pl-detail">Check in</p>'}`;
      return railRow({ label: isToday ? 'Today' : '', time: lbl, kind: isToday ? 'now' : past ? 'done' : last ? 'dlast' : 'ahead', tone, ny: isToday ? 16 : 12, content, last: last });
    });
    track = rows.join('');
  }
  const advice = `<div class="advice"><h3 class="section">While you're home</h3><ul><li><span>Tell your RA and your professors that you're sick and staying home.</span></li><li><span>Use Vaden Health Center for testing and care. Call ahead instead of walking in.</span></li></ul></div>`;
  return heading + track + advice + `<button class="quiet" data-act="report">Tested negative, or feeling well again?</button>`;
}

// ---------- You ----------

export function youHtml(d) {
  const st = d.status, label = st === 'contagious' ? 'Contagious' : st === 'possible' ? 'Possibly sick' : 'Healthy';
  const dot = st === 'contagious' ? 'var(--fire)' : st === 'possible' ? 'var(--sun)' : 'var(--sage)';
  const choice = (title, detail, color, on, chev, dash) => `<div class="choice"><span class="dot ${dash ? 'dash' : ''}" style="${dash ? '' : `background:${color}`}"></span><div class="tx"><b>${title}</b><small>${detail}</small></div>${on ? '<span class="rad on"></span>' : chev ? '<span class="chev">›</span>' : '<span class="rad"></span>'}</div>`;
  const contacts = d.contacts.length
    ? d.contacts.slice(0, 3).map((c) => `<div class="crow"><span class="w">${esc(`${wkd(c.startMs)} ${clock(c.startMs)}`)}</span><div>${esc(c.text)}${c.close ? '<br><span class="cc">Close contact</span>' : ''}</div></div>`).join('')
    : `<div class="contacts-empty"><img src="${ASSET}tissue.png" alt=""><div><b>No one sick nearby lately</b><span class="fine2">No time near someone with symptoms or a positive test in the last 14 days.</span></div></div>`;
  return `<div class="y-head"><h1 class="display">You</h1>${wordmark('small')}</div>
    <div class="y-seen"><p class="note">What nearby phones see about you</p><div class="st"><span class="dot" style="background:${dot}"></span><h2 class="display" style="font-size:34px">${label}</h2></div>
      <p class="note" style="color:var(--ink)">And a random ID that changes every 15 minutes. Nothing else: no name, no symptoms, no location.</p></div>
    <div class="y-block"><h2 class="section">How are you feeling?</h2><div class="choices">
      ${choice('I feel fine', 'Phones near you see: healthy.', 'var(--sage)', st === 'none')}
      ${choice('I have symptoms', 'Phones near you see: possibly sick.', 'var(--sun)', st === 'possible', true)}
      ${choice('I tested positive', 'Phones near you see: contagious.', 'var(--fire)', st === 'contagious', true)}
      ${choice('I tested negative', 'Clears "possibly sick". One rapid test isn\'t conclusive.', '', false, true, true)}</div></div>
    <div class="y-block"><h2 class="section">Recent contacts</h2>${contacts}</div>
    <div class="y-block"><h2 class="section">Detection</h2><p class="note">On. Pausing stops Bluetooth, distance sensing and location for a while, and saves battery.</p>
      <button class="btn second" style="margin-top:12px">Pause detection</button></div>
    <div class="y-block" style="margin-top:24px"><div class="linkrow"><span>Settings</span><span class="chev" style="color:var(--ink-2)">›</span></div>
      <div class="linkrow"><button class="quiet" style="text-decoration:none;color:var(--ink)" data-act="how">How it works and what's shared</button><span style="color:var(--ink-2)">›</span></div>
      <div class="linkrow del">Delete my data</div></div>`;
}

// ---------- sheets ----------

const STICKERS = [['fever', 'Fever'], ['cough', 'Cough'], ['sore-throat', 'Sore throat'], ['aches', 'Aches'], ['fatigue', 'Fatigue'], ['runny-nose', 'Runny nose']];
export function reportSheetHtml(s, d) {
  const days = [['Today', 0], ['Yesterday', 1], [wkd(d.now - 2 * 86400000), 2], ['Earlier', 3]];
  const start = s.when ?? 1, through = d.now + (5 - start) * 86400000;
  return `<div class="sheet" role="dialog" aria-label="Report symptoms"><div class="bar2"><button class="circ dis" aria-label="Back">‹</button><button class="circ" data-act="sheet-close" aria-label="Close">✕</button></div>
    <p class="step-k">Step 2 of 2</p><h1>What's going on?</h1><p class="voice">Tap the stickers that fit. One is plenty.</p>
    <div class="stickers">${STICKERS.map(([k, t]) => `<button class="sticker ${s.picked.has(k) ? 'on' : ''}" data-act="sticker" data-k="${k}"><img src="${ASSET}symptoms/${k}.png" alt="">${t}</button>`).join('')}</div>
    <h3>When did it start?</h3><div class="pills">${days.map(([t, i]) => `<button class="pill2 ${start === i ? 'on' : ''}" data-act="when" data-i="${i}">${esc(t)}</button>`).join('')}</div>
    <p style="margin:12px 0 0">That makes today Day ${start}. Home through ${esc(longDate(through))}.</p>
    <p class="lock">🔒 Nearby phones will only see "possibly sick". Never which stickers you picked.</p>
    <button class="btn" data-act="report-send">Report and start staying home</button>
    ${s.stamped ? `<div class="stampwrap"><img src="${ASSET}stamp-self-reported.png" alt="Self-reported"></div>` : ''}</div>`;
}

export function calcSheetHtml(d) {
  const block = (t, body, num) => `<div class="block"><h2>${esc(t)}</h2><p>${brand(body)}</p>${num ? `<div class="num">${esc(num)}</div>` : ''}</div>`;
  return `<div class="sheet" role="dialog" aria-label="How is this calculated?"><div class="bar2"><span></span><button class="circ" data-act="sheet-close" aria-label="Close">✕</button></div><h1 style="font-size:28px">How is this calculated?</h1>
    ${block('Close contact', `Minutes within 6 ft of someone. They count in full if the person tested positive and half if they have symptoms. At ${CLOSE_MIN} of these in a day, you get a close-contact alert.`, `You: ${d.exactMinutes.toFixed(1)} of ${CLOSE_MIN}`)}
    ${block('What adds to your risk', 'Time near each person, how close you were (closer counts much more), the room air you shared, and how likely each of them is to be sick. Phones up to about 10 m away (Bluetooth range) count.', null)}
    ${block('The estimate', `Each contact becomes a chance that person passed flu on to you, weighted by how likely they are to be sick: from their reports and tests, and from who they were near, so second-hand risk counts too. Your own reports and tests count as well. Those chances are added on top of a ${Math.round(PRIOR * 100)}% everyday baseline and fade as flu runs its course (about a week). It's worked out from everyone's contacts, reports and tests on campus, not just what this phone detected.`, `Your risk estimate: ${liveText(d.p)}`)}
    ${block('What counts', `GPS alone doesn't count, because it's too coarse to tell 3 feet from 30. Bluetooth and precise distance sensing do. The close-contact count uses only the last 24 hours.`, null)}
    <p class="fineprint">This is an estimate to help you decide what to do. It isn't a diagnosis.</p></div>`;
}

export const howSheetHtml = () => {
  const b = (t, body) => `<div class="block"><h2>${esc(t)}</h2><p>${brand(body)}</p></div>`;
  return `<div class="sheet" role="dialog" aria-label="How this works"><div class="bar2"><span></span><button class="circ" data-act="sheet-close" aria-label="Close">✕</button></div><h1 style="font-size:28px">How this works</h1>
    ${b('How it works', "Your phone and other phones running FlUni notice each other over Bluetooth, and with precise distance sensing on newer iPhones. Together they estimate whether you're within 6 feet. If someone with symptoms or who tested positive is close for about 15 minutes in total, you get a heads-up with advice.")}
    ${b('What your phone shares', 'Only a 3-level status (healthy, possibly sick or contagious) and a random ID that changes every 15 minutes. No name, no phone number, no account.')}
    ${b('What stays on your phone', "Your precise location never leaves this phone and is never seen by anyone. Today's timeline keeps building names and times on this phone for 24 hours, then forgets them. Matching happens on your phone, and the map shows building totals, not people.")}
    ${b('Good to know', "It works best while FlUni is open, and keeps checking over Bluetooth in the background, less often. It's a nudge, not a diagnosis. If you feel unwell or are worried, get tested and follow campus health guidance.")}</div>`;
};
