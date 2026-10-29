# Bake the tyre WATER FILM texture for deepnode (procedural).
# Reference (trucks driving out of brown flood water): the wet tyre is dark and glossy with a
# thin muddy film that is uneven: streaks where the water runs off across the sidewall,
# heavier along the tread and the rim edge, thin in between.
# RGB: monochrome film density 0.45..1 (colour = baseColorFactor: the muddy water tint).
# A: film opacity share (x opacityFactor of the material = filmOpacity x wetness).
# U (width) = across the tyre profile, rim to rim (tread centre at 0.5); V = once around.
import sys, os
import numpy as np
from PIL import Image

out = sys.argv[1]
W, H = 512, 1024


def tile_noise(cells_u, cells_v, seed):
    r = np.random.default_rng(seed).random((cells_v, cells_u)).astype(np.float32)
    r = np.pad(r, ((2, 2), (2, 2)), mode='wrap')
    im = Image.fromarray(r, mode='F').resize(((cells_u + 4) * W // cells_u, (cells_v + 4) * H // cells_v), Image.BICUBIC)
    a = np.asarray(im)
    oy, ox = 2 * H // cells_v, 2 * W // cells_u
    return a[oy:oy + H, ox:ox + W]


u = (np.arange(W, dtype=np.float32) + 0.5) / W
v = (np.arange(H, dtype=np.float32) + 0.5) / H
U, V = np.meshgrid(u, v)
du = np.abs(U - 0.5) * 2                     # 0 tread centre .. 1 rim
streak = tile_noise(3, 180, 41)              # run-off streaks across the sidewall (radial)
streak2 = tile_noise(6, 90, 42)
blot = tile_noise(10, 40, 43)
tread = np.clip((0.5 - du) / 0.12, 0, 1)
rim = np.clip((du - 0.86) / 0.1, 0, 1)

dens = 0.35 + 0.30 * streak + 0.15 * streak2 + 0.15 * blot + 0.25 * tread + 0.25 * rim
dens = np.clip(dens, 0, 1)
lum = np.clip(0.55 + 0.45 * (0.6 * streak + 0.4 * blot), 0, 1)
alpha = np.clip(0.35 + 0.65 * dens, 0, 1)

img = np.dstack([(np.dstack([lum, lum, lum]) * 255).astype(np.uint8), (alpha * 255).astype(np.uint8)])
Image.fromarray(img, 'RGBA').save(os.path.join(out, 't_tyrefilm_b.color.png'), optimize=True)
Image.fromarray((alpha * 255).astype(np.uint8), 'L').save(os.path.join(out, 't_tyrefilm_o.data.png'), optimize=True)
print('ok', img.shape)
