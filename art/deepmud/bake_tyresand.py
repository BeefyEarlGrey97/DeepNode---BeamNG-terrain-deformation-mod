# Bake the tyre SAND textures for deepmud (same layout as bake_tyremud.py).
# Sand does not cake in blobs like mud: it packs into the tread grooves first, then dusts
# the shoulders and sidewalls as fine grains. So:
# A (coverage order, histogram-equalised: alphaRef = 255 * (1 - coverage) shows exactly
#   that share): tread centre and the groove pattern first, then a fine grain speckle
#   that spreads over the sidewalls (no large blotches).
# RGB: monochrome fine grain (colour from the material's baseColorFactor per kind),
#   slightly darker where packed (covered first).
# normal map: small grain bumps.
# U (width) = across the tyre profile, rim to rim (tread centre at 0.5); V = around, tiles.
import sys, os
import numpy as np
from PIL import Image

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


u = (np.arange(W, dtype=np.float32) + 0.5) / W
v = (np.arange(H, dtype=np.float32) + 0.5) / H
U, V = np.meshgrid(u, v)
du = np.abs(U - 0.5) * 2               # 0 tread centre .. 1 rim
tread = np.clip((0.62 - du) / 0.12, 0, 1)  # 1 on the tread band, 0 on the sidewalls

# groove pattern: chevron lugs across the tread (32 pitches round the tyre)
pitch = 32
ph = V * pitch + du * 1.6
groove = (np.sin(ph * 2 * np.pi) > 0.35).astype(np.float32)
groove = np.asarray(Image.fromarray(groove * 255).convert('L').filter(__import__('PIL.ImageFilter', fromlist=['x']).GaussianBlur(2)), dtype=np.float32) / 255

# coverage clusters of a few cm: per-pixel speckle would average out in the mip
# levels (alpha 0.5 everywhere) and the alpha clip would show nothing beyond a few metres
fine = 0.55 * tile_noise(40, 80, 11) + 0.45 * tile_noise(80, 160, 12)
mid = 0.6 * tile_noise(16, 32, 14) + 0.4 * tile_noise(40, 80, 15)

centre = np.clip(1 - du, 0, 1) ** 1.2
# low coverage already spreads as a fine dusting over the whole tyre (sand), with the
# tread centre and grooves a little ahead
q = 0.18 * centre + 0.05 * groove * tread + 0.22 * mid + 0.55 * fine
q = q - np.clip((du - 0.985) / 0.015, 0, 1) * 0.3

flat = q.ravel()
order = np.argsort(flat, kind='stable')
rank = np.empty_like(order)
rank[order] = np.arange(flat.size)
alpha = (1 + rank / (flat.size - 1) * 254).reshape(H, W)

# grain luminance: mean 0.8, fine per-grain variation, darker where packed first
grain = np.random.default_rng(21).random((H, W)).astype(np.float32)
grain2 = tile_noise(320, 640, 22)
lum = 0.80 + (grain - 0.5) * 0.10 + (grain2 - 0.5) * 0.08 + (mid - 0.5) * 0.05
dark = 0.90 + 0.10 * (1 - alpha / 255)
g = np.clip(lum * dark, 0, 1)

img = np.dstack([(np.dstack([g, g, g]) * 255).astype(np.uint8), alpha.astype(np.uint8)])
Image.fromarray(img, 'RGBA').save(os.path.join(out, 't_tyresand_b.color.png'), optimize=True)
Image.fromarray(alpha.astype(np.uint8), 'L').save(os.path.join(out, 't_tyresand_o.data.png'), optimize=True)

# normal map from a grain height field (tangent space, +z out)
h = 0.6 * grain2 + 0.4 * grain
gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 2.0
gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 2.0
nz = np.ones_like(h)
nl = np.sqrt(gx * gx + gy * gy + nz * nz)
nrm = np.dstack([(-gx / nl) * 0.5 + 0.5, (-gy / nl) * 0.5 + 0.5, (nz / nl) * 0.5 + 0.5])
Image.fromarray((nrm * 255).astype(np.uint8), 'RGB').save(os.path.join(out, 't_tyresand_nm.normal.png'), optimize=True)
print('ok', img.shape, os.path.getsize(os.path.join(out, 't_tyresand_b.color.png')))
