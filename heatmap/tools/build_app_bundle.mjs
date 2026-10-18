// Builds the offline user map for the FlUni app: one folder with everything the Map tab loads
// (fluni://app/index.html), no network needed. Totals only: no per-person data goes in.
//   node heatmap/tools/build_app_bundle.mjs <run_dir> --out <dir>
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { gunzipSync, gzipSync } from 'node:zlib';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanFootprints } from '../footprints.js';

const here = dirname(fileURLToPath(import.meta.url)), hm = resolve(here, '..');
const args = process.argv.slice(2);
const oi = args.indexOf('--out');
const out = oi >= 0 ? resolve(args.splice(oi, 2)[1]) : null;
const runDir = args[0] && resolve(args[0]);
if (!runDir || !out) { console.error('usage: node heatmap/tools/build_app_bundle.mjs <run_dir> --out <dir>'); process.exit(1); }

const tmp = mkdtempSync(join(tmpdir(), 'usermap-'));
const pre = spawnSync('node', [join(here, 'precompute.mjs'), runDir, '--out', tmp], { stdio: ['ignore', 'ignore', 'inherit'] });
if (pre.status !== 0) { console.error('precompute failed'); process.exit(1); }

rmSync(out, { recursive: true, force: true });
const put = (rel, from) => { mkdirSync(dirname(join(out, rel)), { recursive: true }); cpSync(from, join(out, rel), { recursive: true }); };

put('index.html', join(hm, 'usermap.html'));
for (const f of ['usermap.js', 'heat.js', 'userstyle.js']) put(f, join(hm, f)); // heat.js: the colour stops; userstyle.js: how a building is coloured (shared with the presenter)
put('vendor/leaflet', join(hm, 'vendor/leaflet'));
// (the illustrated assets/trace/campus_trace.webp is no longer bundled: the vector layers read better and save 0.37 MB)
put('assets/trace/campus_trace_bounds.json', join(hm, 'assets/trace/campus_trace_bounds.json'));
put('assets/containers/box-paper.png', join(hm, 'assets/containers/box-paper.png'));
put('data/context.geojson', join(hm, 'data/context.geojson'));
// The app shows "now" and "in 1 hour", so 15-minute steps are enough (as building_heat.csv): a
// 14-day run at 5-minute steps was 6.1 MB of JSON. The presenter keeps the full-resolution file.
const totals = JSON.parse(gunzipSync(readFileSync(join(tmp, 'totals.json.gz'))));
const thin = Math.max(1, Math.round((15 * 60000) / totals.stepMs));
if (thin > 1) {
  totals.steps = totals.steps.filter((_, i) => i % thin === 0);
  if (totals.forecast) totals.forecast.at = totals.forecast.at.filter((a) => Math.round((a.tMs - totals.startMs) / totals.stepMs) % thin === 0);
  totals.stepMs *= thin;
  totals.nSteps = totals.steps.length;
}
// Two decimals is plenty for "about 3.4 sick" and the colours (6 were stored).
const r2 = (x) => (typeof x === 'number' ? Math.round(x * 100) / 100 : x);
totals.steps = totals.steps.map((s) => s.map((r) => r.map((v, k) => (k >= 2 ? r2(v) : v))));
for (const a of totals.forecast?.at || []) for (const h in a.byHorizon) a.byHorizon[h] = a.byHorizon[h].map((r) => r.map(r2));
const totalsJson = JSON.stringify(totals);
writeFileSync(join(out, 'data/totals.json.gz'), gzipSync(totalsJson));
// Plain copy as a fallback for webviews without DecompressionStream (usermap.js tries the .gz first).
writeFileSync(join(out, 'data/totals.json'), totalsJson);

// building outlines, only for buildings that appear in the totals
function parseCsv(text) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
    else if (c !== '\r') f += c;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  const head = rows.shift();
  return rows.filter((r) => r.length === head.length).map((r) => Object.fromEntries(head.map((h, i) => [h, r[i]])));
}
const r6 = (n) => Math.round(n * 1e6) / 1e6;
const round6 = (c) => (typeof c[0] === 'number' ? c.map(r6) : c.map(round6));
const rows = parseCsv(readFileSync(join(runDir, 'map/buildings.csv'), 'utf8'));
// Same cleanup as the presenter map: no boxes for outdoor spaces, manual boxes take a real outline.
// Every mapped building is drawn (neutral paper when it has no data); only those in the totals get heat.
const features = cleanFootprints(rows)
  .map(({ row, geometry }) => ({ type: 'Feature', properties: { id: row.location_id },
    geometry: { type: geometry.type, coordinates: round6(geometry.coordinates) } }));
const wanted = new Set(totals.buildings.map((b) => b.id));
writeFileSync(join(out, 'data/buildings.geojson'), JSON.stringify({ type: 'FeatureCollection', features }));

// footpaths: the run's own network, flattened to one MultiLineString at 5 decimals (~1 m)
const r5 = (n) => Math.round(n * 1e5) / 1e5;
const pg = JSON.parse(readFileSync(join(runDir, 'map/paths.geojson'), 'utf8'));
const lines = [], seen = new Set();
for (const f of pg.features) {
  if (f.geometry?.type !== 'LineString') continue;
  const c = f.geometry.coordinates.map(([x, y]) => [r5(x), r5(y)]).filter((p, i, a) => i === 0 || p[0] !== a[i - 1][0] || p[1] !== a[i - 1][1]);
  const key = JSON.stringify(c);
  if (c.length < 2 || seen.has(key)) continue;
  seen.add(key); lines.push(c);
}
writeFileSync(join(out, 'data/paths.geojson'), JSON.stringify({ type: 'Feature', properties: {}, geometry: { type: 'MultiLineString', coordinates: lines } }));

// anchor labels: p = priority (1 shows first and at every zoom), c = b building / g green or water / x outside campus
const find = (re) => rows.find((r) => re.test(r.name));
const anchors = [
  ['Main Quad', /^Main Quad$/, 1, 'b'], ['Green Library', /^Green Library$/, 1, 'b'], ['The Oval', /^The Oval$/, 1, 'g'],
  ['Lake Lagunita', /^Lake Lagunita$/, 1, 'g'], ['Tresidder', /^Tresidder Memorial Union$/, 2, 'b'],
  ['Memorial Church', null, 2, 'b', 37.42703, -122.17053], ['Cantor', /^Cantor Arts Center$/, 2, 'b'],
  ['Arrillaga Dining', /^Arrillaga Family Dining Commons$/, 3, 'b'], ['Roble', /^Roble Hall$/, 3, 'b'],
  ['Wilbur', /^Wilbur Dining$/, 3, 'b'], ['Stern', /^Stern Dining$/, 3, 'b'], ['Lagunita Ct', null, 3, 'b', 37.4224, -122.1727],
  ['Arrillaga Gym', /^Arrillaga Gymnasium and Weight Room$/, 3, 'b'], ['Engineering Quad', /^Engineering Quad$/, 2, 'g'],
  ['Stanford Shopping Center', null, 2, 'x', 37.4437, -122.1717], ['El Camino Real', null, 3, 'x', 37.4195, -122.1495],
].flatMap(([t, re, p, c, lat, lon]) => {
  const r = re && find(re);
  const la = r ? Number(r.lat) : lat, lo = r ? Number(r.lon) : lon;
  if (!Number.isFinite(la)) { console.warn('no label position for', t); return []; }
  return [{ t, lat: r5(la), lon: r5(lo), p, c }];
});
// every named building, shown only at street zoom (usermap.js creates those labels lazily)
const short = (n) => n.replace(/^(The )/, '').slice(0, 28);
const fine = rows.filter((r) => r.name && !/^(Stanford )?Garage|Parking|Shed|Substation/i.test(r.name) && Number.isFinite(Number(r.lat)))
  .map((r) => [short(r.name), r5(Number(r.lat)), r5(Number(r.lon))]);
writeFileSync(join(out, 'data/labels.json'), JSON.stringify({ anchors, fine }));
rmSync(tmp, { recursive: true, force: true });

let total = 0, count = 0;
(function walk(d) {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, e.name);
    if (e.isDirectory()) walk(p); else { total += statSync(p).size; count++; }
  }
})(out);
console.log(`${out}: ${count} files, ${(total / 1e6).toFixed(2)} MB; ${features.length} building outlines, ${wanted.size} with data, ${lines.length} paths`);
