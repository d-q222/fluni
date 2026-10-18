// Lisa's hand-drawn Stanford landmarks (design pass), drawn on the ground under the heat.
//
// assets/landmarks/landmarks.json lists each spot: where it is, how wide the drawing is on the ground
// (metres, so it grows and shrinks with the map like the buildings) and its image. A spot whose image is
// still null is skipped, so drawings can be added one at a time. The pane sits above the base map and
// the buildings but below the heat, the fills and the people: the heat always paints over the art.

const DIR = 'assets/landmarks/';
const M_PER_DEG_LAT = 111320;

export async function addLandmarks(map) {
  let spots;
  try { spots = await fetch(DIR + 'landmarks.json').then((r) => (r.ok ? r.json() : [])); } catch { return; }
  spots = spots.filter((s) => s.image);
  if (!spots.length) return;
  const pane = map.createPane('landmarkPane');
  pane.style.zIndex = 260; // simPane (buildings) is 250, heat and overlays 400
  pane.style.pointerEvents = 'none';
  for (const s of spots) {
    const img = new Image();
    img.onload = () => {
      const wM = s.width_m, hM = wM * (img.naturalHeight / img.naturalWidth);
      const dLat = hM / M_PER_DEG_LAT, dLon = wM / (M_PER_DEG_LAT * Math.cos((s.lat * Math.PI) / 180));
      const [cy, cx] = [s.lat + (s.dy_m || 0) / M_PER_DEG_LAT, s.lon + (s.dx_m || 0) / (M_PER_DEG_LAT * Math.cos((s.lat * Math.PI) / 180))];
      L.imageOverlay(img.src, [[cy - dLat / 2, cx - dLon / 2], [cy + dLat / 2, cx + dLon / 2]],
        { pane: 'landmarkPane', opacity: s.opacity ?? 0.9, interactive: false, alt: s.name, className: 'landmark' }).addTo(map);
    };
    img.onerror = () => console.warn(`Landmark drawing missing: ${DIR + s.image}`);
    img.src = DIR + s.image;
  }
}
