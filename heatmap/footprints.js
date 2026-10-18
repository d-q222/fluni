// Building outlines from the sim's map/buildings.csv, cleaned for drawing and for keeping heat indoors.
// The sim adds a few hand-placed ("manual") places with rectangular boxes for footprints:
// - outdoor spaces (Lake Lagunita, White Plaza, the Oval, ...): people there are outdoors and never count
//   towards building totals, so a filled box only looks like a building in a lake. Dropped.
// - indoor places whose box sits on a real OSM building (Stern Dining on Lucie Stern Hall), or whose
//   point is within NEAR_M of one (Green Library is 1.6 m from Green Library East Wing, Wilbur Dining
//   9 m from Cedro): take that building's outline, so the box isn't drawn twice, doesn't float beside
//   the basemap's building, and heat follows the real walls.
// Boxes with no OSM building near them stay (the only shape known), flagged `box` so they're drawn faintly.
// Shared by app.js (browser) and tools/build_app_bundle.mjs (node).

// WKT POLYGON / MULTIPOLYGON (lon lat) → GeoJSON geometry.
export function wktGeometry(wkt) {
  const body = String(wkt).replace(/^[A-Z ]+/i, '').trim().replace(/^\(+|\)+$/g, '');
  const polys = body.split(/\)\s*\)\s*,\s*\(\s*\(/).map((poly) => poly.split(/\)\s*,\s*\(/)
    .map((ring) => ring.split(',').map((pt) => pt.trim().split(/\s+/).map(Number))));
  return polys.length === 1 ? { type: 'Polygon', coordinates: polys[0] } : { type: 'MultiPolygon', coordinates: polys };
}

const isTrue = (v) => /^(true|1|yes)$/i.test(String(v));

function inRing([x, y], ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
const outerRings = (g) => (g.type === 'Polygon' ? [g.coordinates[0]] : g.coordinates.map((p) => p[0]));
const NEAR_M = 12; // a hand-placed point this close to an OSM building means that building

// Distance in metres from pt to the nearest edge of a ring ([lon, lat]).
function ringDistM([x, y], ring) {
  const kx = 111320 * Math.cos((y * Math.PI) / 180), ky = 110574;
  let best = Infinity;
  for (let i = 0; i + 1 < ring.length; i++) {
    const ax = (ring[i][0] - x) * kx, ay = (ring[i][1] - y) * ky, bx = (ring[i + 1][0] - x) * kx, by = (ring[i + 1][1] - y) * ky;
    const dx = bx - ax, dy = by - ay, l = dx * dx + dy * dy;
    const t = l ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / l)) : 0;
    best = Math.min(best, Math.hypot(ax + t * dx, ay + t * dy));
  }
  return best;
}

// rows: objects with location_id, footprint_wkt and, when present, source, indoor, lat, lon.
// Returns [{ row, geometry, box }] for the buildings worth drawing; box = a hand-placed box kept as is.
export function cleanFootprints(rows) {
  const out = [], osm = [];
  for (const row of rows) {
    if (!row.location_id || !row.footprint_wkt) continue;
    const manual = row.source === 'manual';
    if (manual && row.indoor !== undefined && !isTrue(row.indoor)) continue; // an outdoor space
    const item = { row, geometry: wktGeometry(row.footprint_wkt), manual };
    out.push(item);
    if (!manual) osm.push(item);
  }
  for (const item of out) {
    if (!item.manual) continue;
    const pt = [Number(item.row.lon), Number(item.row.lat)];
    if (!Number.isFinite(pt[0]) || !Number.isFinite(pt[1])) continue;
    let under = osm.find((o) => outerRings(o.geometry).some((ring) => inRing(pt, ring)));
    if (!under) { // else the nearest building edge within NEAR_M
      let best = NEAR_M;
      for (const o of osm) for (const ring of outerRings(o.geometry)) { const d = ringDistM(pt, ring); if (d < best) { best = d; under = o; } }
    }
    if (under) { item.geometry = under.geometry; item.manual = false; } // the real building's outline
  }
  return out.map(({ row, geometry, manual }) => ({ row, geometry, box: manual }));
}
