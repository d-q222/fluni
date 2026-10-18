// Playback benchmark: drives headless Chrome over the DevTools protocol (Node's built-in WebSocket,
// no dependencies), plays the map at each speed in each view, and reports load time, frame times and
// where the time goes (a sampled CPU profile, per function, inclusive).
//
// Usage (serve the repo root first, e.g. python3 -m http.server 8766):
//   node heatmap/tools/bench.mjs [--base http://localhost:8766] [--run <sim run>] [--at 2115]
//        [--secs 4] [--views demo,phone,zoom,public,airflow,embed] [--speeds 0,1,2,3] [--agent A0008]
//        [--top 12] [--json out.json] [--shot dir] [--tiles] [--basemap streets|sim|drawn] [--load]
//
// frame = time between animation frames (16.7 ms is a smooth 60 fps); work = JavaScript run inside
// requestAnimationFrame callbacks that frame (the app's tick plus Leaflet's canvas redraws).
// Map tiles are blocked by default so network noise doesn't skew runs (--tiles to allow them).
// --load prints where load time goes (inclusive ms per function); the JS heap is measured after a GC.
// --shot dir saves a screenshot of each view at --at, for before/after comparisons.

import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true]);
  return acc;
}, []));
const BASE = args.base || 'http://localhost:8766';
const AT = Number(args.at || 2115);           // minutes from the start (default: Tue 11:15, a busy moment)
const SECS = Number(args.secs || 4);
const VIEWS = (args.views || 'demo,phone,zoom,public,airflow,embed').split(',');
const SPEEDS = (args.speeds || '0,1,2,3').split(',').map(Number);
const TOP = Number(args.top || 12);
const AGENT = args.agent || 'A0008';
const run = (args.run ? `&run=${args.run}` : '') + (args.basemap ? `&basemap=${args.basemap}` : '');
const DESKTOP = { width: 1400, height: 900, deviceScaleFactor: 2, mobile: false };
const PHONE = { width: 390, height: 844, deviceScaleFactor: 3, mobile: true };
const SCENES = {
  demo: { q: '', screen: DESKTOP },
  phone: { q: `&agent=${AGENT}`, screen: DESKTOP }, // demo view with an agent's phone open
  zoom: { q: `&agent=${AGENT}&zoom=18`, screen: DESKTOP }, // close up: the heat canvas is scaled way up
  public: { q: '&view=public', screen: DESKTOP },
  airflow: { q: '&view=airflow', screen: DESKTOP },
  airborne: { q: '&view=airborne', screen: DESKTOP },
  embed: { q: '&embed=app', screen: PHONE },
};

// Times every requestAnimationFrame callback, grouped by frame. Installed before Leaflet loads, so
// its canvas redraws (which go through requestAnimationFrame) are counted too.
const RAF_PROBE = `(() => {
  const raf = window.requestAnimationFrame.bind(window);
  const B = window.__bench = { frames: [], cur: null };
  window.requestAnimationFrame = (cb) => raf((ts) => {
    if (!B.cur || B.cur.ts !== ts) { B.cur = { ts, work: 0 }; B.frames.push(B.cur); }
    const s = performance.now();
    try { cb(ts); } finally { B.cur.work += performance.now() - s; }
  });
})();`;

// Lag: how far the top of the heat hill a moving risky dot stands on is from the dot, in metres,
// sampled every frame while __bench.gaps is an array. Steepest ascent from the dot's cell (up to
// 300 m), so a stale cloud, or a trail it's still attached to, shows up as distance.
const GAP_PROBE = `(function loop() {
  requestAnimationFrame(loop);
  const g = __bench.gaps, f = g && fluni.heatField();
  if (!f || !f.nx) return;
  let me = null;
  for (const a of fluni.current().values()) if (a.walking && a.p >= 0.3 && (!me || a.p > me.p)) me = a;
  if (!me) return;
  const cx = ((me.lon - f.bounds.west) * f.mPerDegLon) / f.cellM - 0.5, cy = ((f.bounds.north - me.lat) * 110574) / f.cellM - 0.5;
  let x = Math.round(cx), y = Math.round(cy);
  const at = (x, y) => (x < 0 || y < 0 || x >= f.nx || y >= f.ny ? -1 : f.heat[y * f.nx + x]);
  for (let k = 0; k < 100; k++) {
    let bx = x, by = y;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) if (at(x + dx, y + dy) > at(bx, by)) { bx = x + dx; by = y + dy; }
    if (bx === x && by === y) break;
    x = bx; y = by;
  }
  if (at(x, y) > 0) g.push(Math.hypot(x - cx, y - cy) * f.cellM);
})();`;
// First step at or after the start with someone risky (p ≥ 0.3) on the move, as minutes from t0.
const GAP_START = `(() => {
  const { frames, times } = fluni.data, t0 = times[0];
  for (let k = 0; k < frames.length; k++) {
    if (times[k] >= t0 + ${AT} * 60000 && frames[k].some((a) => a.moving && a.p >= 0.3)) return (times[k] - t0) / 60000;
  }
  return null;
})()`;

// ---------- DevTools protocol ----------

async function launch() {
  const dir = mkdtempSync(join(tmpdir(), 'fluni-bench-'));
  const proc = spawn(CHROME, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${dir}`, '--no-first-run',
    '--no-default-browser-check', '--window-size=1400,900', '--disable-background-timer-throttling',
    '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', 'about:blank',
  ], { stdio: 'ignore' });
  const portFile = join(dir, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !existsSync(portFile); i++) await sleep(100);
  const port = readFileSync(portFile, 'utf8').split('\n')[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
  let id = 0;
  const pending = new Map(), errors = [], state = { crashed: false };
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.method === 'Inspector.targetCrashed') { state.crashed = true; errors.push('renderer crashed (out of memory?)'); }
    if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') errors.push(m.params.args.map((a) => a.value ?? a.description).join(' '));
    if (m.id && pending.has(m.id)) {
      const { ok, fail } = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) fail(new Error(`${m.error.message}`)); else ok(m.result);
    }
  };
  const send = (method, params = {}) => new Promise((ok, fail) => {
    pending.set(++id, { ok, fail });
    ws.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  };
  const close = () => { ws.close(); proc.kill(); setTimeout(() => rmSync(dir, { recursive: true, force: true }), 500); };
  return { send, evaluate, close, errors, state };
}

// ---------- stats ----------

const pctl = (xs, q) => {
  if (!xs.length) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * s.length))];
};
const f1 = (x) => (Number.isFinite(x) ? x.toFixed(1) : '–');

// CPU profile → inclusive ms per function (each function counted once per sample, however deep).
function breakdown(profile) {
  const nodes = new Map(profile.nodes.map((n) => [n.id, n]));
  const parent = new Map();
  for (const n of profile.nodes) for (const c of n.children || []) parent.set(c, n.id);
  const label = (n) => {
    const { functionName, url, lineNumber } = n.callFrame;
    if (/leaflet/.test(url)) return 'Leaflet (all)';
    if (!url) return functionName || '(native)';
    return `${functionName || '(anonymous)'} ${url.split('/').slice(-2).join('/').replace(/\?.*/, '')}:${lineNumber + 1}`;
  };
  const incl = new Map();
  let busy = 0;
  profile.samples.forEach((sid, i) => {
    const dt = (profile.timeDeltas[i] || 0) / 1000;
    const leaf = label(nodes.get(sid));
    if (leaf === '(idle)' || leaf === '(program)') return;
    busy += dt;
    const seen = new Set();
    for (let id = sid; id !== undefined; id = parent.get(id)) {
      const l = label(nodes.get(id));
      if (l === '(root)' || seen.has(l)) continue;
      seen.add(l);
      incl.set(l, (incl.get(l) || 0) + dt);
    }
  });
  return { busy, incl };
}

// ---------- one view ----------

async function benchView(name) {
  const cdp = await launch(); // a fresh browser per view: a 7,500-agent page holds GBs
  try { return await benchIn(cdp, name); } finally { cdp.close(); }
}

async function benchIn(cdp, name) {
  const scene = SCENES[name];
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Profiler.enable');
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: RAF_PROBE });
  if (!args.tiles) {
    await cdp.send('Network.enable');
    await cdp.send('Network.setBlockedURLs', { urls: ['*tile.openstreetmap.org*'] });
  }
  await cdp.send('Emulation.setDeviceMetricsOverride', scene.screen);
  const url = `${BASE}/heatmap/?at=${AT}${run}${scene.q}`;
  // Load: profiled from navigation until window.fluni appears (1 ms samples keep a long load small).
  await cdp.send('Profiler.setSamplingInterval', { interval: 1000 });
  await cdp.send('Profiler.start');
  await cdp.send('Page.navigate', { url });
  let load = 0;
  await cdp.send('Inspector.enable');
  const crashed = () => cdp.state.crashed;
  for (let i = 0; i < 6000 && !load && !crashed(); i++) {
    await sleep(50);
    load = await cdp.evaluate('window.fluni ? performance.now() : 0').catch(() => 0);
  }
  if (crashed()) throw new Error(`${name}: renderer crashed while loading (${url})`);
  const loadProfile = (await cdp.send('Profiler.stop')).profile;
  if (!load) throw new Error(`${name}: page never became ready (${url})\n${cdp.errors.join('\n')}`);
  const loadTop = [...breakdown(loadProfile).incl].sort((a, b) => b[1] - a[1]).slice(0, TOP).map(([fn, ms]) => ({ fn, ms }));
  await cdp.send('HeapProfiler.collectGarbage');
  const heapMB = (await cdp.send('Runtime.getHeapUsage')).usedSize / 1e6;
  await cdp.send('Profiler.setSamplingInterval', { interval: 200 });
  const agents = await cdp.evaluate('new Set(fluni.data.samples.map((a) => a.id)).size');
  const grid = await cdp.evaluate('(() => { const f = fluni.heatField?.(); return f && f.nx ? `${f.nx}×${f.ny} cells of ${f.cellM} m, σ ${f.sigmaM} m` : ""; })()');
  await sleep(500); // let the first paint settle
  if (args.shot) {
    mkdirSync(args.shot, { recursive: true });
    const { data } = await cdp.send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(join(args.shot, `${name}.png`), Buffer.from(data, 'base64'));
  }
  const rows = [];
  const incl = new Map();
  let busy = 0, frameCount = 0;
  for (const speed of SPEEDS) {
    await cdp.evaluate(`(() => {
      const $ = (id) => document.getElementById(id);
      $('speed').value = '${speed}';
      fluni.seek(fluni.data.times[0] + ${AT} * 60000);
      if ($('play').dataset.playing !== 'true') $('play').click();
      __bench.frames.length = 0; __bench.cur = null;
    })()`);
    await cdp.send('Profiler.start');
    await sleep(SECS * 1000);
    const { profile } = await cdp.send('Profiler.stop');
    const frames = await cdp.evaluate(`(() => {
      const f = __bench.frames.map((x) => [x.ts, x.work]);
      if (document.getElementById('play').dataset.playing === 'true') document.getElementById('play').click();
      return f;
    })()`);
    const gaps = frames.slice(1).map((f, i) => f[0] - frames[i][0]);
    const work = frames.map((f) => f[1]);
    rows.push({ view: name, speed, frames: frames.length, frameP50: pctl(gaps, 0.5), frameP95: pctl(gaps, 0.95), workP50: pctl(work, 0.5), workP95: pctl(work, 0.95), workMax: Math.max(...work) });
    const b = breakdown(profile);
    busy += b.busy;
    frameCount += frames.length;
    for (const [k, v] of b.incl) incl.set(k, (incl.get(k) || 0) + v);
  }
  // Lag of the heat behind a moving risky person, per speed (heat views only).
  const lag = [];
  const gapAt = ['demo', 'zoom', 'airflow'].includes(name) ? await cdp.evaluate(GAP_START) : null;
  if (gapAt !== null) {
    await cdp.evaluate(GAP_PROBE);
    for (const speed of SPEEDS) {
      await cdp.evaluate(`(() => {
        const $ = (id) => document.getElementById(id);
        $('speed').value = '${speed}';
        fluni.seek(fluni.data.times[0] + ${gapAt - 1} * 60000);
        if ($('play').dataset.playing !== 'true') $('play').click();
        __bench.gaps = [];
      })()`);
      await sleep(3000);
      const g = await cdp.evaluate(`(() => {
        const g = __bench.gaps; __bench.gaps = null;
        if (document.getElementById('play').dataset.playing === 'true') document.getElementById('play').click();
        return g;
      })()`);
      lag.push({ speed, n: g.length, p50: pctl(g, 0.5), p95: pctl(g, 0.95), max: g.length ? Math.max(...g) : NaN });
    }
  }
  const top = [...incl].sort((a, b) => b[1] - a[1]).slice(0, TOP).map(([fn, ms]) => ({ fn, msPerFrame: ms / frameCount }));
  return { name, load, heapMB, loadTop, agents, grid, rows, busyPerFrame: busy / frameCount, top, gapAt, lag, errors: [...new Set(cdp.errors)] };
}

// ---------- main ----------

const results = [];
for (const v of VIEWS) {
  let r;
  try { r = await benchView(v); } catch (err) { console.log(`\n${v}: FAILED: ${err.message.split('\n').slice(0, 6).join('\n  ')}`); results.push({ name: v, error: err.message }); continue; }
  {
    results.push(r);
    console.log(`\n${v}: ready in ${f1(r.load)} ms, JS heap ${f1(r.heapMB)} MB, ${r.agents} agents, JS ${f1(r.busyPerFrame)} ms/frame`);
    if (r.grid) console.log(`  heat grid at load: ${r.grid}`);
    if (args.load) for (const t of r.loadTop) console.log(`    load ${String(Math.round(t.ms)).padStart(6)} ms  ${t.fn}`);
    console.log('  speed  frames  frame p50  p95   work p50  p95   max');
    for (const x of r.rows) {
      console.log(`  ${String(x.speed).padEnd(5)}  ${String(x.frames).padStart(6)}  ${f1(x.frameP50).padStart(9)}  ${f1(x.frameP95).padStart(5)}  ${f1(x.workP50).padStart(8)}  ${f1(x.workP95).padStart(5)}  ${f1(x.workMax).padStart(5)}`);
    }
    console.log('  inclusive ms/frame (all speeds):');
    for (const t of r.top) console.log(`    ${f1(t.msPerFrame).padStart(6)}  ${t.fn}`);
    for (const e of r.errors) console.log(`  page error: ${e.split('\n')[0]}`);
    if (r.lag.length) {
      console.log(`  heat peak → moving risky dot, metres (from minute ${r.gapAt - 1}):`);
      for (const x of r.lag) console.log(`    speed ${x.speed}: p50 ${f1(x.p50)}  p95 ${f1(x.p95)}  max ${f1(x.max)}  (${x.n} frames)`);
    }
  }
}
if (args.json) writeFileSync(args.json, JSON.stringify(results, null, 2));
