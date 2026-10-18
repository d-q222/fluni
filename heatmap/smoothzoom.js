// Google-Maps-like zooming for a Leaflet map: smoothZoom(map) replaces Leaflet's wheel zoom (which snaps each
// wheel burst to a step, plays a fixed 250 ms CSS animation and drops every wheel event that arrives during
// it, so fast scrolling and trackpad pinches feel jumpy) with a continuous one, and makes the +/- buttons use it.
//
// - Every wheel event (mouse wheel, trackpad scroll, trackpad pinch = wheel with ctrlKey) moves a goal zoom;
//   each animation frame the map eases toward it (exponential, so it glides and successive notches add up)
//   around the point under the cursor, by map._move(): the same path Leaflet's own touch pinch uses. Leaflet's
//   layers follow every frame by a cheap CSS transform ('zoom' events: tiles, canvas renderers, image
//   overlays, markers; maplibre-gl-leaflet re-renders the vector base), as do this app's CanvasLayers.
// - zoomstart/movestart fire once when a gesture starts and zoomend/moveend once when it settles, so the
//   app's heavy work (heat recompute, dot sizes, labels) runs once per gesture, not per wheel tick.
// - During a long gesture the canvas renderers' content (drawn for the start zoom) would shrink and leave
//   blank edges, or blur; every REFRESH_MS, once the zoom has drifted REFRESH_DZ from what a renderer drew,
//   it is redrawn at the current view (fires 'zoomrefresh' first so on-screen sizes, e.g. dot radii, can follow).
// The final zoom is fractional (no snapping), as in Google Maps.

const TAU_MS = 75; // easing time constant: ~95% of a step in 225 ms
const DONE = 0.004; // close enough to the goal: jump there and end the gesture
const WHEEL_PX_PER_ZOOM = 280; // mouse wheel / trackpad scroll: px of deltaY per zoom level (a notch ~ 1/3 level)
const PINCH_PX_PER_ZOOM = 80; // trackpad pinch (ctrlKey wheel events carry small deltas)
const MAX_STEP = 1.5; // per event, so one huge delta (e.g. a page-mode wheel) can't fly across the campus
const REFRESH_MS = 200, REFRESH_DZ = 0.6;

export function smoothZoom(map) {
  if (map._smoothZoom) return map;
  map.scrollWheelZoom.disable();
  let goal = null, anchorPt = null, anchorLL = null, raf = 0, last = 0, started = false, lastRefresh = 0;

  const clamp = (z) => Math.max(map.getMinZoom(), Math.min(map.getMaxZoom(), z));
  const stop = () => {
    if (raf) cancelAnimationFrame(raf);
    raf = 0; goal = null;
    if (started) { started = false; map._moveEnd(true); } // zoomend + moveend, once per gesture
  };
  const refresh = (now) => { // redraw Leaflet's canvas/SVG renderers at the current view, mid-gesture
    if (now - lastRefresh < REFRESH_MS) return;
    const z = map.getZoom(), stale = Object.values(map._layers).filter((l) => l instanceof L.Renderer && Math.abs(l._zoom - z) >= REFRESH_DZ);
    if (!stale.length) return;
    lastRefresh = now;
    map.fire('zoomrefresh');
    for (const r of stale) {
      r._reset(); // re-project its paths at this zoom
      if (r._redraw) { L.Util.cancelAnimFrame(r._redrawRequest); r._redraw(); } // canvas: draw now, not next frame (no blank frame)
    }
  };
  const frame = (now) => {
    raf = 0;
    if (goal === null) return;
    if (map._animatingZoom) { raf = requestAnimationFrame(frame); return; } // a Leaflet zoom animation (e.g. double-click) finishes first
    const z0 = map.getZoom(), dt = Math.min(64, now - (last || now - 16));
    last = now;
    const z = Math.abs(goal - z0) < DONE ? goal : z0 + (goal - z0) * (1 - Math.exp(-dt / TAU_MS));
    if (!started) { started = true; map._moveStart(true, false); }
    // keep anchorLL under anchorPt: centre = anchor's projection at z, shifted back by its offset from the view centre
    const offset = anchorPt.subtract(map.getSize().divideBy(2));
    const center = map.unproject(map.project(anchorLL, z).subtract(offset), z);
    map._move(center, z);
    if (z === goal) { stop(); return; }
    refresh(now);
    raf = requestAnimationFrame(frame);
  };
  // Zoom by dz (levels) around a container point, adding to a zoom already under way.
  const zoomBy = (dz, pt, snap = 0) => {
    map._stop(); // a pan / flyTo in progress
    const base = goal ?? map.getZoom();
    // buttons: from the whole step at or below (zooming in) / above (out), so 16.4 + 1 -> 17, not 17.4
    const from = snap ? (dz > 0 ? Math.floor(base / snap + 1e-6) : Math.ceil(base / snap - 1e-6)) * snap : base;
    const target = clamp(from + dz);
    if (target === base && goal === null) return;
    goal = target;
    anchorPt = pt;
    anchorLL = map.containerPointToLatLng(pt);
    if (!raf) { last = 0; raf = requestAnimationFrame(frame); }
  };

  const onWheel = (e) => {
    L.DomEvent.preventDefault(e); // no page scroll / browser pinch-zoom
    if (!map._loaded) return;
    const px = e.deltaY * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? map.getSize().y : 1);
    if (!px) return;
    const dz = Math.max(-MAX_STEP, Math.min(MAX_STEP, -px / (e.ctrlKey ? PINCH_PX_PER_ZOOM : WHEEL_PX_PER_ZOOM)));
    zoomBy(dz, map.mouseEventToContainerPoint(e));
  };
  L.DomEvent.on(map.getContainer(), 'wheel', onWheel); // Leaflet adds wheel listeners as non-passive, so preventDefault works
  map.on('dragstart', stop); // the hand takes over
  // +/- (button and keyboard-free API): the same glide, about the centre, to the next whole zoomDelta step,
  // so clicking twice quickly zooms two steps instead of dropping the second click.
  const glide = (sign) => function (delta, options) {
    if (options?.animate === false || !this._loaded) return L.Map.prototype[sign > 0 ? 'zoomIn' : 'zoomOut'].call(this, delta, options);
    zoomBy(sign * (delta || this.options.zoomDelta), this.getSize().divideBy(2), this.options.zoomDelta || 1);
    return this;
  };
  map.zoomIn = glide(1);
  map.zoomOut = glide(-1);
  map._smoothZoom = { stop };
  return map;
}
