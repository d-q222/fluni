// Builds the offline user map for the FlUni app: one folder with everything the Map tab loads
// (fluni://app/index.html), no network needed. Totals only: no per-person data goes in.
//   node heatmap/tools/build_app_bundle.mjs <run_dir> --out <dir>
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

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
for (const f of ['usermap.js', 'heat.js']) put(f, join(hm, f)); // heat.js: the colour stops, no imports
put('vendor/leaflet', join(hm, 'vendor/leaflet'));
put('assets/trace/campus_trace.webp', join(hm, 'assets/trace/campus_trace.webp'));
put('assets/trace/campus_trace_bounds.json', join(hm, 'assets/trace/campus_trace_bounds.json'));
put('assets/containers/box-paper.png', join(hm, 'assets/containers/box-paper.png'));
put('data/totals.json.gz', join(tmp, 'totals.json.gz'));
// Plain copy as a fallback for webviews without DecompressionStream (usermap.js tries the .gz first).
const totalsJson = gunzipSync(readFileSync(join(tmp, 'totals.json.gz')));
writeFileSync(join(out, 'data/totals.json'), totalsJson);
const totals = JSON.parse(totalsJson);

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
function wktGeometry(wkt) {
  const body = String(wkt).replace(/^[A-Z ]+/i, '').trim().replace(/^\(+|\)+$/g, '');
  const polys = body.split(/\)\s*\)\s*,\s*\(\s*\(/).map((poly) => poly.split(/\)\s*,\s*\(/)
    .map((ring) => ring.split(',').map((pt) => pt.trim().split(/\s+/).map(Number).map(r6))));
  return polys.length === 1 ? { type: 'Polygon', coordinates: polys[0] } : { type: 'MultiPolygon', coordinates: polys };
}
const wanted = new Set(totals.buildings.map((b) => b.id));
const features = parseCsv(readFileSync(join(runDir, 'map/buildings.csv'), 'utf8'))
  .filter((b) => wanted.has(b.location_id) && b.footprint_wkt)
  .map((b) => ({ type: 'Feature', properties: { id: b.location_id }, geometry: wktGeometry(b.footprint_wkt) }));
writeFileSync(join(out, 'data/buildings.geojson'), JSON.stringify({ type: 'FeatureCollection', features }));
rmSync(tmp, { recursive: true, force: true });

let total = 0, count = 0;
(function walk(d) {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, e.name);
    if (e.isDirectory()) walk(p); else { total += statSync(p).size; count++; }
  }
})(out);
console.log(`${out}: ${count} files, ${(total / 1e6).toFixed(2)} MB; ${features.length}/${wanted.size} buildings with outlines`);
