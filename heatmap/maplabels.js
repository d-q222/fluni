// Small text labels on a Leaflet map, thinned so they never overlap each other or any rectangle passed in
// `avoid` (the legend, the time chip). Markers are made lazily, only for labels in view and eligible at this zoom.
// Items: { key, lat, lon, html, cls, p (priority: lower places first), minZoom }.
const esc = (x) => String(x).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
export { esc as escapeHtml };

export class LabelLayer {
  constructor(map, { pane = 'labels', avoid = () => [] } = {}) {
    this.map = map;
    this.avoid = avoid;
    if (!map.getPane(pane)) map.createPane(pane);
    const p = map.getPane(pane);
    p.style.zIndex = 450; p.style.pointerEvents = 'none';
    this.pane = pane;
    this.items = [];
    this.live = new Map(); // key -> { marker, item, w, h }
    this._queued = false;
    this._place = () => this.place();
    map.on('moveend zoomend resize', this._place);
  }

  setItems(items) {
    this.items = items;
    const keep = new Set(items.map((i) => i.key));
    for (const [k, l] of this.live) if (!keep.has(k)) { l.marker.remove(); this.live.delete(k); }
    this.schedule();
  }

  schedule() {
    if (this._queued) return;
    this._queued = true;
    requestAnimationFrame(() => { this._queued = false; this.place(); });
  }

  destroy() {
    this.map.off('moveend zoomend resize', this._place);
    for (const l of this.live.values()) l.marker.remove();
    this.live.clear();
  }

  place() {
    const map = this.map;
    if (!map._loaded) return;
    const box = map.getContainer().getBoundingClientRect(), z = map.getZoom(), view = map.getBounds();
    const avoid = this.avoid().filter(Boolean);
    const placed = [];
    const hit = (a, b) => a.l < b.r && a.r > b.l && a.t < b.b && a.b > b.t;
    const rects = avoid.map((r) => ({ l: r.left, r: r.right, t: r.top, b: r.bottom }));
    const todo = this.items.filter((i) => z >= i.minZoom && view.contains([i.lat, i.lon])).sort((a, b) => a.p - b.p);
    const show = new Set();
    for (const item of todo) {
      let l = this.live.get(item.key);
      if (!l) {
        const marker = L.marker([item.lat, item.lon], { interactive: false, keyboard: false, pane: this.pane,
          icon: L.divIcon({ className: `lbl ${item.cls || ''}`, html: `<span>${item.html}</span>`, iconSize: null }) }).addTo(map);
        l = { marker, item, w: 0, h: 0, html: item.html };
        this.live.set(item.key, l);
      } else if (l.html !== item.html) { // e.g. a badge's number changed
        l.marker.getElement().firstChild.innerHTML = item.html; l.html = item.html; l.w = 0;
      }
      const el = l.marker.getElement();
      if (!el) continue;
      if (!l.w) { const s = el.firstChild; l.w = s.offsetWidth + 6; l.h = s.offsetHeight + 4; }
      const pt = map.latLngToContainerPoint([item.lat, item.lon]);
      const r = { l: box.left + pt.x - l.w / 2, r: box.left + pt.x + l.w / 2, t: box.top + pt.y - l.h / 2, b: box.top + pt.y + l.h / 2 };
      const ok = r.l >= box.left + 2 && r.r <= box.right - 2 && r.t >= box.top && r.b <= box.bottom
        && !rects.some((a) => hit(r, a)) && !placed.some((o) => hit(r, o));
      el.style.visibility = ok ? 'visible' : 'hidden';
      if (ok) { placed.push(r); show.add(item.key); }
    }
    for (const [k, l] of this.live) if (!show.has(k)) { const el = l.marker.getElement(); if (el) el.style.visibility = 'hidden'; }
  }
}
