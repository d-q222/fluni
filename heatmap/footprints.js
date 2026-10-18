// Building outlines from the sim's map/buildings.csv, cleaned for drawing and for keeping heat indoors.
// The sim adds a few hand-placed ("manual") places with rectangular boxes for footprints:
// - outdoor spaces (Lake Lagunita, White Plaza, the Oval, ...): people there are outdoors and never count
//   towards building totals, so a filled box only looks like a building in a lake. Dropped.
// - indoor places whose box sits on a real OSM building (Stern Dining on Lucie Stern Hall): take that
//   building's outline, so the box isn't drawn twice and heat follows the real walls.
// Boxes with no building under them (Green Library, Wilbur Dining) stay: they are the only shape known.
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

// rows: objects with location_id, footprint_wkt and, when present, source, indoor, lat, lon.
// Returns [{ row, geometry }] for the buildings worth drawing.
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
    const under = osm.find((o) => outerRings(o.geometry).some((ring) => inRing(pt, ring)));
    if (under) item.geometry = under.geometry; // the real building's outline
  }
  return out.map(({ row, geometry }) => ({ row, geometry }));
}
