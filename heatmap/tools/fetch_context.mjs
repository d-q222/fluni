// Fetches the map context for the app's user map from OpenStreetMap (ODbL) via Overpass and writes
// data/context.geojson: major roads, rail, retail/hospital/downtown buildings around campus (the
// margin the user can see but not reach) plus parks, fields and water on campus. Simplified, 5 decimals.
//   node heatmap/tools/fetch_context.mjs      (needs network; commit the output)
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const hm = join(dirname(fileURLToPath(import.meta.url)), '..');
const B = JSON.parse(readFileSync(join(hm, 'assets/trace/campus_trace_bounds.json'), 'utf8'));
const padLat = 0.016, padLon = 0.009; // lat: a tall phone shows ~1.5 km past campus at full zoom-out, so the margin is never bare
const ring = [B.south - padLat, B.west - padLon, B.north + padLat, B.east + padLon].join(',');
const campus = [B.south, B.west, B.north, B.east].join(',');
const q = `[out:json][timeout:120];(
 way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|unclassified)$"]["name"](${ring});
 way["railway"="rail"](${ring});
 way["building"]["name"~"Shopping|Hospital|Medical"](${ring});
 way["building"](37.4385,-122.1700,37.4480,-122.1500);
 way["landuse"="retail"](${ring});
 way["leisure"~"^(pitch|park|golf_course|garden|track|playground)$"](${campus});
 way["landuse"~"^(grass|recreation_ground|meadow|village_green)$"](${campus});
 way["natural"~"^(water|grassland)$"](${campus});
 way["highway"~"^(footway|path|pedestrian|steps|cycleway)$"](${campus});
);out geom;`;
let res;
for (const url of Array(6).fill(['https://overpass-api.de/api/interpreter', 'https://overpass.kumi.systems/api/interpreter']).flat()) {
  res = await fetch(url, { method: 'POST', body: new URLSearchParams({ data: q }), headers: { 'User-Agent': 'fluni-hackathon/0.1' } });
  if (res.ok) break;
  console.error(url, res.status);
  await new Promise((r) => setTimeout(r, 8000));
}
if (!res.ok) throw new Error(`overpass ${res.status}`);
const els = (await res.json()).elements.filter((e) => e.type === 'way' && e.geometry && e.geometry.length > 1);

const r5 = (n) => Math.round(n * 1e5) / 1e5;
function simplify(pts, eps) { // Douglas-Peucker on [lon,lat]
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length); keep[0] = keep[pts.length - 1] = 1;
  const st = [[0, pts.length - 1]];
  while (st.length) {
    const [a, b] = st.pop(); let md = 0, mi = -1;
    for (let i = a + 1; i < b; i++) {
      const [x, y] = pts[i], [x1, y1] = pts[a], [x2, y2] = pts[b];
      const dx = x2 - x1, dy = y2 - y1, l = dx * dx + dy * dy;
      const t = l ? Math.max(0, Math.min(1, ((x - x1) * dx + (y - y1) * dy) / l)) : 0;
      const d = Math.hypot(x - (x1 + t * dx), y - (y1 + t * dy));
      if (d > md) { md = d; mi = i; }
    }
    if (md > eps) { keep[mi] = 1; st.push([a, mi], [mi, b]); }
  }
  return pts.filter((_, i) => keep[i]);
}
const inCampus = (g) => g.lat >= B.south && g.lat <= B.north && g.lon >= B.west && g.lon <= B.east;
const MAJOR = /^(motorway|trunk|primary|secondary)$/;
const feats = [];
for (const e of els) {
  const t = e.tags || {}, g = e.geometry;
  const closed = g.length > 3 && g[0].lat === g[g.length - 1].lat && g[0].lon === g[g.length - 1].lon;
  let kind, name = t.name || undefined, eps = 0.00003;
  if (t.highway && /^(footway|path|pedestrian|steps|cycleway)$/.test(t.highway)) continue; // paths come from the run, not here
  else if (t.highway) kind = MAJOR.test(t.highway) || /Campus Dr|Palm Dr|Junipero Serra|Sand Hill|Page Mill|El Camino|Arboretum|Galvez|Serra St|Lasuen|University Ave|Embarcadero|Quarry|Welch|Hanover|Stanford Ave/.test(t.name || '') ? 'road' : 'street';
  else if (t.railway) kind = 'rail';
  else if (t.building) kind = /Hospital|Medical/.test(t.name || '') ? 'hospital' : /Shopping/.test(t.name || '') ? 'shopping' : 'town';
  else if (t.landuse === 'retail') kind = 'shopping';
  else if (t.natural === 'water') kind = 'water';
  else if (t.leisure || t.landuse || t.natural) { kind = 'green'; if (t.leisure === 'pitch') eps = 0.00002; }
  else continue;
  const inside = g.some(inCampus);
  if ((kind === 'water' || kind === 'green') && !inside) continue;
  if (kind === 'street' && inside) continue; // campus streets are in the footpath layer
  if (kind === 'town' && (inside || closed === false)) continue;
  let pts = simplify(g.map((p) => [p.lon, p.lat]), eps).map(([x, y]) => [r5(x), r5(y)]);
  if (closed && pts.length < 4) continue;
  const poly = closed && kind !== 'road' && kind !== 'street' && kind !== 'rail';
  if (poly) { // drop slivers
    let a = 0; for (let i = 0; i < pts.length - 1; i++) a += pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1];
    if (Math.abs(a / 2) < (kind === 'town' ? 4e-8 : 2e-7)) continue;
  }
  feats.push({ type: 'Feature', properties: { k: kind, ...(name && kind !== 'town' ? { n: name } : {}) },
    geometry: poly ? { type: 'Polygon', coordinates: [pts] } : { type: 'LineString', coordinates: pts } });
}
const out = { type: 'FeatureCollection', attribution: '© OpenStreetMap contributors (ODbL)', features: feats };
writeFileSync(join(hm, 'data/context.geojson'), JSON.stringify(out));
const c = {}; for (const f of feats) c[f.properties.k] = (c[f.properties.k] || 0) + 1;
console.log(feats.length, 'features', c, (JSON.stringify(out).length / 1e3).toFixed(0) + ' KB');
