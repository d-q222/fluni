// Building-level view for the user-facing map: each campus building filled by how many sick people are
// expected there, drawn exactly as FlUni's map draws it (userstyle.js is shared with the app bundle):
// warm sun -> fire fills, a halo with a pixel floor so a small hot building registers zoomed out, tap a
// building for "about X sick of Y people" (no count badges: users see only the shading). The presenter adds
// building names. It takes only per-building totals, never agent positions, so nothing finer than a building can be drawn.
import { buildingStyle, HIDDEN, haloRadius, GLOW, HALO_BLUR, fmt } from './userstyle.js';
import { LabelLayer, escapeHtml as esc } from './maplabels.js';

export class BuildingTotalsLayer {
  // avoid: () => [DOMRect, ...] the labels must stay clear of (legend, chip)
  constructor(geojson, { avoid = () => [], badges = true, names = true } = {}) {
    this.geojson = geojson;
    this.names = names;
    this.badges = badges; // the presenter's count badges (FlUni's own map has none)
    this.avoid = avoid;
    this.totals = new Map();
    this.opts = { minPeople: 4, forecast: false };
    this.items = new Map(); // buildingId -> { layer, halo, name, center, shown, key, badge }
    this.added = false;
    this.openId = null;
  }

  _build(map) {
    const pane = (name, z) => { const p = map.getPane(name) || map.createPane(name); p.style.zIndex = z; return { pane: name, renderer: L.canvas({ pane: name }) }; };
    this.P = { halo: pane('ub-halo', 425), fill: pane('ub-fill', 430) };
    map.getPane('ub-halo').style.filter = HALO_BLUR;
    map.getPane('ub-halo').style.pointerEvents = 'none';
    map.getPane('ub-fill').style.filter = GLOW; // hot buildings glow so they read zoomed out
    this.group = L.layerGroup();
    this.haloGroup = L.layerGroup();
    this.pop = L.popup({ closeButton: false, autoPanPadding: [20, 80], className: 'ub-pop' });
    for (const f of this.geojson.features) {
      const id = 'bld_' + String(f.properties.id).split('/')[1];
      const layer = L.geoJSON(f, { ...this.P.fill, style: () => HIDDEN });
      layer.on('click', (e) => { L.DomEvent.stopPropagation(e); this._open(id, e.latlng); });
      this.items.set(id, { layer, halo: null, name: f.properties.name || '', center: layer.getBounds().getCenter(), shown: false, key: '', badge: false, f });
    }
    this.labels = new LabelLayer(map, { pane: 'ub-label', avoid: this.avoid });
    this._zoom = () => { const r = haloRadius(map.getZoom()); for (const it of this.items.values()) if (it.halo) it.halo.setRadius(r); };
    map.on('zoomend', this._zoom);
    map.on('popupclose', (e) => { if (e.popup === this.pop) this.openId = null; });
  }

  addTo(map) {
    if (!this.group) this._build(map);
    this.map = map;
    this.group.addTo(map);
    this.haloGroup.addTo(map);
    this.added = true;
    if (this.last) this.update(...this.last);
    return this;
  }

  remove() {
    this.group?.remove();
    this.haloGroup?.remove();
    this.labels?.setItems([]);
    this.map?.closePopup(this.pop);
    this.map = null;
    this.added = false;
    this._labelsBuilt = false;
  }

  // totals: Map buildingId -> { name, n, expected, excess, lo?, hi? }; vmax: colour max (expected sick above baseline)
  update(totals, vmax, { minPeople = 4, forecast = false } = {}) {
    this.last = [totals, vmax, { minPeople, forecast }];
    if (!this.map) return;
    this.totals = totals;
    this.opts = { minPeople, forecast };
    let labelsDirty = false;
    for (const [id, it] of this.items) {
      const d = totals.get(id);
      if (!d) {
        if (it.shown) { this.group.removeLayer(it.layer); it.shown = false; it.key = ''; }
        if (it.halo) { it.halo.remove(); it.halo = null; }
        if (it.badge) { it.badge = false; labelsDirty = true; }
        continue;
      }
      const style = buildingStyle(d.n, d.excess ?? d.expected, vmax, { minPeople, forecast });
      const key = JSON.stringify(style);
      if (key !== it.key) { it.layer.setStyle(style); it.key = key; }
      if (!it.shown) { this.group.addLayer(it.layer); it.shown = true; }
      // a halo with a floor on its on-screen size, so a small hot building still registers when zoomed out
      if (style.fill) {
        if (!it.halo) it.halo = L.circleMarker(it.center, { interactive: false, stroke: false, radius: haloRadius(this.map.getZoom()), ...this.P.halo }).addTo(this.haloGroup);
        it.halo.setStyle({ fill: true, fillColor: style.fillColor, fillOpacity: style.fillOpacity * 0.55 });
      } else if (it.halo) { it.halo.remove(); it.halo = null; }
      const hot = Boolean(style.fill); // hot buildings get their name a zoom level earlier
      if (hot !== it.badge) { it.badge = hot; labelsDirty = true; }
      it.d = d; it.hot = d.expected;
    }
    if (labelsDirty || !this._labelsBuilt) { this._labelsBuilt = true; this._setLabels(); }
    if (this.openId) { if (this.items.get(this.openId)?.badge !== undefined && this._shown(this.openId)) this.pop.setContent(this._html(this.openId)); else this.map.closePopup(this.pop); }
  }

  _setLabels() {
    const out = [];
    for (const [id, it] of this.items) {
      if (it.name && this.names) out.push({ key: 'n:' + id, lat: it.center.lat, lon: it.center.lng, html: esc(it.name.slice(0, 28)), cls: 'ub-name',
        p: it.badge ? 1 : 2, minZoom: it.badge ? 16 : 17 });
    }
    this.labels.setItems(out);
  }

  _shown(id) {
    const d = this.totals.get(id);
    return d && d.n >= this.opts.minPeople;
  }

  _html(id) {
    const d = this.totals.get(id), name = d.name || this.items.get(id).name || 'Building';
    return this.opts.forecast
      ? `<b>${esc(name)}</b>: about ${fmt(d.expected)} sick expected${d.lo != null && d.hi != null ? ` (${fmt(d.lo)}–${fmt(d.hi)})` : ''}`
      : `<b>${esc(name)}</b>: about ${fmt(d.expected)} sick of ${fmt(d.n)} people`;
  }

  _open(id, latlng) {
    if (!this._shown(id)) return; // hidden buildings show nothing
    this.openId = id;
    this.pop.setLatLng(latlng).setContent(this._html(id)).openOn(this.map);
  }
}
