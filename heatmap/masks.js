// Rasterizes building outlines onto the heat-map grid so heat can be confined inside buildings.
// Grid convention matches the sim: row 0 is the north edge, i = y*nx + x, a cell is inside a
// polygon if its centre is. Pure data in, typed arrays out; no DOM.

const M_PER_DEG_LAT = 110574;

// Returns { inside: Uint8Array (1 = in a building), building: Int32Array (index into ids, -1 outside), ids }
export function rasterizeBuildings(geojson, grid) {
  const { south, west, north, east } = grid.bounds, { nx, ny, cellM } = grid;
  const mPerDegLon = 111320 * Math.cos(((south + north) / 2) * Math.PI / 180);
  const inside = new Uint8Array(nx * ny), building = new Int32Array(nx * ny).fill(-1), ids = [];
  const sx = mPerDegLon / cellM, sy = M_PER_DEG_LAT / cellM;

  for (const f of geojson.features) {
    const g = f.geometry;
    if (!g) continue;
    const polys = g.type === 'Polygon' ? [g.coordinates] : g.type === 'MultiPolygon' ? g.coordinates : [];
    let idx = -1;
    for (const poly of polys) {
      // rings in grid units (x east, y south)
      const rings = poly.map((r) => r.map(([lon, lat]) => [(lon - west) * sx, (north - lat) * sy]));
      let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
      for (const [x, y] of rings[0]) {
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
      if (maxX < 0 || minX > nx || maxY < 0 || minY > ny) continue;
      if (idx < 0) {
        idx = ids.length;
        ids.push('bld_' + String(f.properties.id).split('/').pop());
      }
      const y0 = Math.max(0, Math.ceil(minY - 0.5)), y1 = Math.min(ny - 1, Math.ceil(maxY - 0.5) - 1);
      for (let y = y0; y <= y1; y++) {
        const cy = y + 0.5, xs = [];
        for (const r of rings) {
          for (let k = 0, n = r.length - 1; k < n; k++) {
            const [ax, ay] = r[k], [bx, by] = r[k + 1];
            if ((ay <= cy) !== (by <= cy)) xs.push(ax + ((cy - ay) / (by - ay)) * (bx - ax));
          }
        }
        xs.sort((a, b) => a - b);
        // even-odd: fill between pairs; holes fall out naturally
        for (let k = 0; k + 1 < xs.length; k += 2) {
          const xa = Math.max(0, Math.ceil(xs[k] - 0.5)), xb = Math.min(nx - 1, Math.ceil(xs[k + 1] - 0.5) - 1);
          for (let x = xa; x <= xb; x++) { inside[y * nx + x] = 1; building[y * nx + x] = idx; }
        }
      }
    }
  }
  return { inside, building, ids };
}
