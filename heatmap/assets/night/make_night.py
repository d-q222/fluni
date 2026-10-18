# Night versions of Lisa's drawings: lamp-lit, not inverted. In OKLab, lightness is compressed toward the
# middle (fills dim like paper under a lamp, dark ink lifts to a warm rust so it reads on a dark
# background), chroma eased off a little, everything nudged warm. Hue is kept, so her colours stay hers.
import numpy as np, sys
from PIL import Image

def srgb_to_lin(c): return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def lin_to_srgb(c): c = np.clip(c, 0, 1); return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)
M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566], [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099], [0.0259040371, 0.7827717662, -0.8086757660]])
def to_lab(rgb):
    lms = srgb_to_lin(rgb) @ M1.T
    return np.cbrt(lms) @ M2.T
def from_lab(lab):
    lms = (lab @ np.linalg.inv(M2).T) ** 3
    return lin_to_srgb(lms @ np.linalg.inv(M1).T)

def night(rgb, lo=0.30, span=0.54, chroma=1.0, warm=(0.014, 0.012)):
    lab = to_lab(rgb)
    lab[..., 0] = lo + span * lab[..., 0]
    lab[..., 1:] *= chroma
    lab[..., 1] += warm[0]; lab[..., 2] += warm[1]
    return from_lab(lab)

CARD_FILL = {'box-paper.png': (50, 39, 33), 'box-peach.png': (70, 45, 36)}  # night --surface and a dim peach

def run(src, dst, mode='art'):
    im = Image.open(src).convert('RGBA')
    a = np.asarray(im).astype(np.float64) / 255
    rgb, al = a[..., :3], a[..., 3:]
    out = night(rgb)
    if mode == 'card':  # containers hold text: the paper inside goes dark, the inked frame stays lamp-lit
        lab = to_lab(rgb); L = lab[..., 0:1]
        dark = np.broadcast_to(np.array(CARD_FILL[src.split('/')[-1]]) / 255, rgb.shape)
        t = np.clip((L - 0.62) / 0.2, 0, 1)  # light paper → dark; ink and hatching keep the art mapping
        out = out * (1 - t) + dark * t
    res = np.concatenate([out, al], -1)
    img = Image.fromarray((np.clip(res, 0, 1) * 255 + 0.5).astype(np.uint8), 'RGBA')
    if dst.endswith('.jpg'): img.convert('RGB').save(dst, quality=88)
    else: img.save(dst, optimize=True)

if __name__ == '__main__':
    run(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'art')
