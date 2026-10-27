# Bake the tyre mud texture for deepmud.
# RGB: mud_large luminance (game asset), monochrome. A: coverage order, histogram-equalised so that
# alphaRef = 255 * (1 - coverage) shows exactly that share of the tyre skin.
# U (width) = across the tyre profile, rim to rim (tread centre at 0.5).
# V (height) = around the circumference, tiles.
import zipfile, io, sys, os
import numpy as np
from PIL import Image

out = sys.argv[1]
z = zipfile.ZipFile(r'C:/Program Files (x86)/Steam/steamapps/common/BeamNG.drive/content/assets/materials/decalroad.zip')
def load(n):
    im = Image.open(io.BytesIO(z.read('assets/materials/decalroad/mud/mud_large/' + n)))
    im.load()
    return im

W, H = 1024, 2048
base = load('t_mud_large_b.color.dds').convert('RGB').resize((W, H), Image.LANCZOS)
opac = np.asarray(load('t_mud_large_o.data.dds').convert('L').resize((W, H), Image.LANCZOS), dtype=np.float32) / 255
rgb = np.asarray(base, dtype=np.float32) / 255

rng = np.random.default_rng(7)
def tile_noise(cells_u, cells_v, seed):
    # value noise, periodic in v (and u), bicubic-smooth via PIL resize of a wrapped grid
    r = np.random.default_rng(seed).random((cells_v, cells_u)).astype(np.float32)
    r = np.pad(r, ((2, 2), (2, 2)), mode='wrap')
    im = Image.fromarray(r, mode='F').resize(((cells_u + 4) * W // cells_u, (cells_v + 4) * H // cells_v), Image.BICUBIC)
    a = np.asarray(im)
    oy, ox = 2 * H // cells_v, 2 * W // cells_u
    return a[oy:oy + H, ox:ox + W]

n = 0.55 * tile_noise(8, 16, 1) + 0.30 * tile_noise(24, 48, 2) + 0.15 * tile_noise(64, 128, 3)

u = (np.arange(W, dtype=np.float32) + 0.5) / W
du = np.abs(u - 0.5) * 2          # 0 tread centre .. 1 rim
# sidewalls (du ~0.55..0.96) get mud early too: weak tread bias, flat over most of the width
centre = np.clip(1 - du, 0, 1) ** 0.6
centre = np.broadcast_to(centre[None, :], (H, W))

# blur the opacity so it orders the inside of blobs too (not one flat white level)
ob = np.asarray(Image.fromarray((opac * 255).astype(np.uint8)).filter(__import__('PIL.ImageFilter', fromlist=['x']).GaussianBlur(6)), dtype=np.float32) / 255
q = 0.12 * centre + 0.50 * (0.6 * opac + 0.4 * ob) + 0.38 * n
# rim strip (outer 1.5 %) not covered first
q = q - np.clip((du - 0.985) / 0.015, 0, 1)[None, :] * 0.3

# histogram equalisation: rank -> 1..255 (0 kept for "never")
flat = q.ravel()
order = np.argsort(flat, kind='stable')
rank = np.empty_like(order)
rank[order] = np.arange(flat.size)
alpha = (1 + rank / (flat.size - 1) * 254).reshape(H, W)

# monochrome: the colour comes from the material (baseColorFactor per soft-ground kind).
# Luminance normalised to mean 0.66, std 0.085, highlights soft-clipped above 0.78 (the
# light stone flecks of mud_large made tyre highlights brighter than the ground);
# darker where the cake is thick (covered first).
lum = rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722
lum = 0.66 + (lum - lum.mean()) / max(1e-6, lum.std()) * 0.085
lum = np.where(lum > 0.78, 0.78 + (lum - 0.78) * 0.35, lum)
dark = 0.88 + 0.12 * (1 - alpha / 255)
g = np.clip(lum * dark, 0, 1)
rgb2 = np.dstack([g, g, g])

img = np.dstack([(rgb2 * 255).astype(np.uint8), alpha.astype(np.uint8)])
Image.fromarray(img, 'RGBA').save(os.path.join(out, 't_tyremud_b.color.png'), optimize=True)
Image.fromarray(alpha.astype(np.uint8), 'L').save(os.path.join(out, 't_tyremud_o.data.png'), optimize=True)

# per-vertex lookup for Lua (coverage order 0..1 = alpha/255, 64 x 256, u fastest)
lu, lv = 64, 256
small = np.asarray(Image.fromarray(alpha.astype(np.uint8), 'L').resize((lu, lv), Image.BOX), dtype=np.uint8)
import json
json.dump({'w': lu, 'h': lv, 'data': small.ravel().tolist()}, open(os.path.join(out, 'tyremud_order.json'), 'w'), separators=(',', ':'))
print('ok', img.shape, os.path.getsize(os.path.join(out, 't_tyremud_b.color.png')))
