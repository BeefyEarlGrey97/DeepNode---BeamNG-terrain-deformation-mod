# Bake the tyre MUD textures for deepnode (procedural; same layout as bake_tyresand.py).
# Reference (trucks out of a clay pit): the mud coats the tyre as a smooth clay cake: the
# tread first (filled, the lug pattern still shows as relief under it), then the shoulders,
# then the sidewalls down to the rim; at the edge of the coat it thins out in ragged tongues
# and splashes. Wet clay is smooth with soft lumps and fine pores, not blotchy.
# A (coverage order, histogram-equalised: alphaRef = 255 * (1 - coverage) shows exactly
#   that share of the tyre skin): the profile first, ragged by large soft blobs, radial
#   tongues and a fine splash grain.
# RGB: monochrome clay (colour from the material's baseColorFactor per kind = ground
#   colour), soft lumps; darker where the coat is thin (covered last: rubber shows through).
# normal map: soft lumps, the tread lugs under the mud on the tread band, fine pores.
# Also writes tyremud_order.json (64 x 256 copy of the order: the skin mesh relief).
# U (width) = across the tyre profile, rim to rim (tread centre at 0.5); V = around, tiles.
import sys, os, json
import numpy as np
from PIL import Image, ImageFilter

out = sys.argv[1]
W, H = 1024, 2048


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


u = (np.arange(W, dtype=np.float32) + 0.5) / W
v = (np.arange(H, dtype=np.float32) + 0.5) / H
U, V = np.meshgrid(u, v)
du = np.abs(U - 0.5) * 2                     # 0 tread centre .. 1 rim
tread = np.clip((0.58 - du) / 0.1, 0, 1)     # 1 on the tread band
treadC = np.clip((0.4 - du) / 0.15, 0, 1)    # tread face only (lug relief under the mud)

# lugs: chevrons across the tread (32 pitches round the tyre), soft under the mud
pitch = 32
ph = V * pitch + du * 1.6
lug = (np.sin(ph * 2 * np.pi) > 0.2).astype(np.float32)
lug = blur(lug, 6)

big = tile_noise(6, 12, 31)                  # soft blobs (coat edge, lumps)
mid = 0.6 * tile_noise(16, 32, 32) + 0.4 * tile_noise(40, 80, 33)
fine = 0.55 * tile_noise(60, 120, 34) + 0.45 * tile_noise(120, 240, 35)
tongue = tile_noise(5, 40, 36)               # radial tongues (stretched across u)

# coverage order: profile first, the edge ragged (clusters of cm size: per-pixel speckle
# averages out in the mips and vanishes at a few metres)
prof = np.clip(1 - np.maximum(0, du - 0.25) / 0.75, 0, 1)
q = 0.46 * prof + 0.22 * big + 0.12 * mid + 0.06 * tongue + 0.10 * fine + 0.04 * lug * tread
q = q - np.clip((du - 0.985) / 0.015, 0, 1) * 0.3   # rim strip covered last

flat = q.ravel()
order = np.argsort(flat, kind='stable')
rank = np.empty_like(order)
rank[order] = np.arange(flat.size)
alpha = (1 + rank / (flat.size - 1) * 254).reshape(H, W)

# clay luminance: smooth, soft lumps, fine pores; thin coat darker towards the coat
# edge (a smooth profile term, not the raw order: that carries the tongues and printed
# them as radial stripes over the whole coat)
pores = np.random.default_rng(37).random((H, W)).astype(np.float32)
lum = 0.74 + (mid - 0.5) * 0.07 + (big - 0.5) * 0.05 + (fine - 0.5) * 0.05 + (pores - 0.5) * 0.04
lum = lum - 0.03 * lug * treadC              # a little darker in the lug grooves
edge = np.clip(blur(alpha / 255, 12), 0, 1)
dark = 0.7 + 0.3 * np.clip(edge * 1.6, 0, 1) ** 0.7
g = np.clip(lum * dark, 0, 1)

img = np.dstack([(np.dstack([g, g, g]) * 255).astype(np.uint8), alpha.astype(np.uint8)])
Image.fromarray(img, 'RGBA').save(os.path.join(out, 't_tyremud_b.color.png'), optimize=True)
Image.fromarray(alpha.astype(np.uint8), 'L').save(os.path.join(out, 't_tyremud_o.data.png'), optimize=True)

# normal map (tangent space, +z out) from a height field
h = 0.9 * mid + 0.6 * big + 0.22 * lug * treadC + 0.25 * fine + 0.08 * pores
gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 6.0
gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 6.0
nz = np.ones_like(h)
nl = np.sqrt(gx * gx + gy * gy + nz * nz)
nrm = np.dstack([(-gx / nl) * 0.5 + 0.5, (-gy / nl) * 0.5 + 0.5, (nz / nl) * 0.5 + 0.5])
Image.fromarray((nrm * 255).astype(np.uint8), 'RGB').save(os.path.join(out, 't_tyremud_nm.normal.png'), optimize=True)

# per-vertex lookup for Lua (coverage order 0..255, 64 x 256, u fastest)
lu, lv = 64, 256
small = np.asarray(Image.fromarray(alpha.astype(np.uint8), 'L').resize((lu, lv), Image.BOX), dtype=np.uint8)
json.dump({'w': lu, 'h': lv, 'data': small.ravel().tolist()}, open(os.path.join(out, 'tyremud_order.json'), 'w'), separators=(',', ':'))
print('ok', img.shape, os.path.getsize(os.path.join(out, 't_tyremud_b.color.png')))
