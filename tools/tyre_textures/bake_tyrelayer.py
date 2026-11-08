# Bake the tyre LAYER textures for deepnode (clods.tyreLayer): mud / sand / snow drawn as an
# extra layer of the vehicle's own tyre material (SnowRunner-style: a layer of dirt on the
# rubber, the tyre's own relief stays), not as a skin mesh round the tyre.
# Most BeamNG tyre textures (vehicles/common/tires/tire_*) are strips: U = around the tyre
# (tiles), V = across it, sidewall - tread (V ~0.33..0.65) - sidewall. The skin textures
# (bake_tyremud.py) have U across and V around; the masks here are their order transposed.
#   t_tyrelayer_b.color.png    dirt (monochrome; colour = the layer's baseColorFactor = the
#                              ground colour): wet and dry patches, clods, grit, smears round
#                              the tyre; linear mean MEAN like the skin (same colour factor)
#   t_tyrelayer_nm.normal.png  its relief (the layer's detail normal map; the tyre's own
#                              normal map stays the layer's main one)
#   t_tyrelayer_o<k>.data.png  coverage masks, k = 1..7 for a covered share of LEVELS[k-1]:
#                              the tread first, then the shoulders, then blotches over the
#                              sidewalls (the skin's coverage order). The layer's opacity map is
#                              switched between them (an opacity map is not alpha-clipped in a
#                              layer, so the share cannot come from a threshold).
# Run after bake_tyremud.py:  python -I tools/tyre_textures/bake_tyrelayer.py tools/tyre_textures
# then  python -I tools/dev/tyre_dds.py tools/tyre_textures 0.5 tyrelayer
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

LEVELS = (0.12, 0.24, 0.36, 0.48, 0.6, 0.72, 0.84)
EDGE = 0.04   # order range of the soft mask edge
MEAN = 0.4767  # linear mean of the skin's mud texture (clods.kinds.mud.texMean)
W, H = 2048, 1024  # U around (tiles), V across

src = sys.argv[1]


def tile_noise(cells_u, cells_v, seed):
    # value noise, periodic in u and v, bicubic-smooth
    r = np.random.default_rng(seed).random((cells_v, cells_u)).astype(np.float32)
    r = np.pad(r, ((2, 2), (2, 2)), mode='wrap')
    im = Image.fromarray(r, mode='F').resize(((cells_u + 4) * W // cells_u, (cells_v + 4) * H // cells_v), Image.BICUBIC)
    a = np.asarray(im)
    oy, ox = 2 * H // cells_v, 2 * W // cells_u
    return a[oy:oy + H, ox:ox + W]


def blur(a, r):
    lo, hi = float(a.min()), float(a.max())
    im = Image.fromarray(((a - lo) / max(1e-6, hi - lo) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))
    return np.asarray(im, dtype=np.float32) / 255 * (hi - lo) + lo


# --- coverage masks (the skin's order, transposed) ---------------------------------------
order = np.asarray(Image.open(os.path.join(src, 't_tyremud_o.data.png')).convert('L'), np.float32).T / 255
for k, c in enumerate(LEVELS, 1):
    m = np.clip((order - (1 - c)) / EDGE + 0.5, 0, 1)
    print('level %d: share %.3f (want %.2f)' % (k, m.mean(), c))
    Image.fromarray(np.ascontiguousarray((m * 255).round().astype(np.uint8)), 'L').save(
        os.path.join(src, 't_tyrelayer_o%d.data.png' % k), optimize=True)

# --- dirt ---------------------------------------------------------------------------------
patch = tile_noise(10, 4, 51)                       # wet (dark) / dry (light) patches
mid = 0.6 * tile_noise(40, 20, 52) + 0.4 * tile_noise(90, 45, 53)
smear = tile_noise(16, 70, 54)                      # faint smears round the tyre (long in U)
blot = np.clip((tile_noise(28, 14, 57) - 0.5) / 0.12 + 0.5, 0, 1)  # thick wet cake spots
grit = np.random.default_rng(55).random((H, W)).astype(np.float32)
speck = blur((grit < 0.03).astype(np.float32), 0.8) * 1.6  # dark grains
grit = blur(grit, 1.2)

# clods: round lumps, ~1..4 cm on a ~3.5 m circumference (2048 px)
rng = np.random.default_rng(56)
clod = np.zeros((H, W), np.float32)
for _ in range(1100):
    cx, cy = rng.random() * W, rng.random() * H
    r = 4 + rng.random() ** 2.5 * 22
    x0, x1 = int(cx - r - 1), int(cx + r + 2)
    y0, y1 = max(0, int(cy - r - 1)), min(H, int(cy + r + 2))
    if y1 <= y0:
        continue
    xs = np.arange(x0, x1) % W
    dx = (np.arange(x0, x1) - cx)[None, :]
    dy = (np.arange(y0, y1) - cy)[:, None]
    # lumpy outline: radius varies with the angle
    ang = np.arctan2(dy, dx)
    rr = r * (1 + 0.25 * np.sin(3 * ang + rng.random() * 6.3) + 0.12 * np.sin(5 * ang + rng.random() * 6.3))
    q = np.clip(1 - (dx * dx + dy * dy) / (rr * rr), 0, 1)
    sub = clod[y0:y1][:, xs]
    clod[y0:y1, xs] = np.maximum(sub, (r / 26) * np.sqrt(q))

h = 0.5 * mid + 0.12 * smear + 1.0 * clod + 0.08 * grit + 0.35 * blot + 0.2 * patch
lum = (0.6 + (patch - 0.5) * 0.22 + (mid - 0.5) * 0.14 + (smear - 0.5) * 0.04 + (grit - 0.5) * 0.12
       - 0.07 * blot + 0.10 * clod - 0.18 * speck)
lum = np.clip(lum, 0.05, 1.0)
# srgb -> linear mean to MEAN (the colour factor assumes the skin texture's mean)
lin = lum ** 2.2
lin *= MEAN / lin.mean()
srgb = np.clip(lin, 0, 1) ** (1 / 2.2)
g = (srgb * 255).round().astype(np.uint8)
Image.fromarray(np.dstack([g, g, g]), 'RGB').save(os.path.join(src, 't_tyrelayer_b.color.png'), optimize=True)
print('dirt: linear mean %.4f, sRGB std %.3f' % (float(((g.astype(np.float32) / 255) ** 2.2).mean()), float(srgb.std())))

# normal map (tangent space, +z out) from the height field; wraps in U
gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 4.0
gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 4.0
nz = np.ones_like(h)
nl = np.sqrt(gx * gx + gy * gy + nz * nz)
nrm = np.dstack([(-gx / nl) * 0.5 + 0.5, (-gy / nl) * 0.5 + 0.5, (nz / nl) * 0.5 + 0.5])
Image.fromarray((nrm * 255).astype(np.uint8), 'RGB').save(os.path.join(src, 't_tyrelayer_nm.normal.png'), optimize=True)
print('ok', order.shape)
