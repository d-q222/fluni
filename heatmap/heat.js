// Heat at a point x = Σ p_i · K(x − x_i): the expected number of infected people per m² near x.
// (Concentration × average P(sick) gives the same sum.) diffuse.js builds the grid in metres; this
// file only colours it, so it can be drawn on Leaflet, Google Maps, or a static image.

// The design palette's campfire colours: sun → ember → fire → charred red. Lightness falls the
// whole way, so "darker = hotter" still holds for colour-blind viewers and in greyscale. Fades in
// from transparent so low risk doesn't tint the map.
const STOPS = [
  [0.0, [235, 209, 135, 0]],
  [0.1, [235, 209, 135, 150]],   // --sun
  [0.35, [233, 149, 105, 190]],  // --ember
  [0.65, [219, 108, 89, 215]],   // --fire
  [1.0, [142, 58, 40, 235]],     // --fire-ink
];
export const HEAT_STOPS = STOPS;

const LUT = (() => {
  const lut = new Uint8ClampedArray(256 * 4);
  for (let i = 0; i < 256; i++) {
    const t = i / 255;
    let j = 1;
    while (STOPS[j][0] < t) j++;
    const [t0, c0] = STOPS[j - 1], [t1, c1] = STOPS[j];
    const f = (t - t0) / (t1 - t0);
    for (let c = 0; c < 4; c++) lut[i * 4 + c] = c0[c] + f * (c1[c] - c0[c]);
  }
  return lut;
})();
const LUT32 = new Uint32Array(LUT.buffer); // one RGBA pixel per entry, same byte order as ImageData
// The same ramp, but from STRONG_FROM of the colour max on at least STRONG_ALPHA opaque, so a building that
// is clearly above the baseline reads at campus zoom (heat sits on beige footprints of a similar hue).
const STRONG_FROM = 0.1, STRONG_ALPHA = 215;
const LUT32_STRONG = LUT32.map((px, i) => (i >= Math.round(Math.sqrt(STRONG_FROM) * 255) && px >>> 24 < STRONG_ALPHA
  ? ((px & 0x00ffffff) | (STRONG_ALPHA << 24)) >>> 0 : px));

// Draw the grid onto a canvas (one pixel per cell). vmax is fixed across frames, so a colour means
// the same thing at every moment. Colour follows √(value / vmax) so a lone sick person still shows;
// the legend's midpoint is therefore vmax / 4. minPeople hides cells with fewer than that many
// people within ~1σ.
// Runs every frame, so the canvas size (setting it clears and reallocates) and the pixel buffer are
// kept between calls, and pixels are written whole (no per-pixel subarray).
// One heat value's pixel (RGBA as a little-endian Uint32, as paint() writes), or 0 below the visible floor.
export function heatPixel(value, vmax, strong = false) {
  if (!(value > 0)) return 0;
  const t = Math.sqrt(Math.min(1, value / vmax));
  return t < 0.02 ? 0 : (strong ? LUT32_STRONG : LUT32)[Math.round(t * 255)];
}

export function paint(grid, canvas, vmax, { minPeople = 0, strong = false } = {}) {
  if (canvas.width !== grid.nx) canvas.width = grid.nx;
  if (canvas.height !== grid.ny) canvas.height = grid.ny;
  const ctx = canvas.getContext('2d');
  if (canvas.img?.width !== grid.nx || canvas.img?.height !== grid.ny) {
    canvas.img = ctx.createImageData(grid.nx, grid.ny);
    canvas.px = new Uint32Array(canvas.img.data.buffer);
  }
  const px = canvas.px, { heat, people } = grid, lut = strong ? LUT32_STRONG : LUT32;
  px.fill(0);
  const peopleScale = 2 * Math.PI * grid.sigmaM * grid.sigmaM;
  for (let i = 0; i < heat.length; i++) {
    if (!(heat[i] > 0)) continue; // t would be 0 (or NaN): transparent; most of the grid is empty
    if (people[i] * peopleScale < minPeople) continue;
    const t = Math.sqrt(Math.min(1, heat[i] / vmax));
    if (t < 0.02) continue;
    px[i] = lut[Math.round(t * 255)];
  }
  ctx.putImageData(canvas.img, 0, 0);
}
