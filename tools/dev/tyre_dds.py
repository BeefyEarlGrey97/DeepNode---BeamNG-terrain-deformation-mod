"""Tyre textures for release: halve the baked PNGs and compress them to DDS with NVIDIA
Texture Tools (nvcompress), in BeamNG's own formats (as the game's decal-road set):
  *_b.color   -> BC7, DXGI 99 (BC7_UNORM_SRGB), full mip chain
  *_nm.normal -> BC5 (BC5U)
  *_o.data    -> BC7 linear (DXGI 98), grey in RGB, mips without gamma correction (BC4, the
                 game's own data format, is clipped everywhere by the object shader)

Sources: tools/tyre_textures (bake_*.py write the full-size PNGs there; bake_tyremud.py
also writes tyremud_order.json, which the mod reads: copy it to art/deepnode). This script
writes the DDS into art/deepnode/tyre (the mod ships only those; a new folder, because the
engine's texture cache holds cooked art/deepnode/t_tyre*.dds from the old PNGs and would be
loaded instead of same-named files there).

  python -I tools/dev/tyre_dds.py tools/tyre_textures [scale] [name filter]   (scale default 0.5)

Downscaling: Lanczos; normal maps renormalised; coverage-order maps (mud/sand _o.data:
histogram-equalised, alphaRef = 255 - 254 x coverage) re-ranked after the resize so the
coverage stays exactly linear in alphaRef. The film opacity is a plain amount: resized only.
"""
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

NVC = r'C:\Program Files\NVIDIA Corporation\NVIDIA Texture Tools\nvcompress.exe'
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'art', 'deepnode', 'tyre')
RANKED = ('t_tyremud_o.data', 't_tyresand_o.data')
# kept at full size (none: a halved sand normal map loses ~30 % of its finest detail by
# std, but in game at 0.7 m it looked the same as the full one)
FULL = ()


def half(im, scale):
    w, h = im.size
    return im.resize((max(4, round(w * scale)), max(4, round(h * scale))), Image.LANCZOS)


def rerank(a):
    flat = a.reshape(-1).astype(np.float64)
    order = np.argsort(flat, kind='stable')
    rank = np.empty(flat.size, np.float64)
    rank[order] = np.arange(flat.size)
    return np.round(1 + rank / (flat.size - 1) * 254).astype(np.uint8).reshape(a.shape)


def nvcompress(src, dst, args):
    subprocess.run([NVC, '-silent', '-production', *args, src, dst], check=True)


def set_dxgi(path, fmt):
    with open(path, 'r+b') as f:
        hdr = f.read(148)
        assert hdr[84:88] == b'DX10', path
        f.seek(128)
        f.write(int(fmt).to_bytes(4, 'little'))


def main():
    src = sys.argv[1]
    scale = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5
    only = sys.argv[3] if len(sys.argv) > 3 else ''
    tmp = tempfile.mkdtemp()
    for name in sorted(os.listdir(src)):
        if not name.startswith('t_tyre') or not name.endswith('.png') or only not in name:
            continue
        base = name[:-4]
        im = Image.open(os.path.join(src, name))
        if base not in FULL:
            im = half(im, scale)
        dst = os.path.join(OUT, base + '.dds')
        t = os.path.join(tmp, name)
        if base.endswith('.normal'):
            n = np.asarray(im.convert('RGB'), np.float32) / 255 * 2 - 1
            n /= np.maximum(1e-6, np.linalg.norm(n, axis=2, keepdims=True))
            Image.fromarray(np.round((n + 1) * 127.5).clip(0, 255).astype(np.uint8), 'RGB').save(t)
            nvcompress(t, dst, ['-normal', '-bc5'])
        elif base.endswith('.data'):
            a = np.asarray(im.convert('L'))
            if base in RANKED:
                a = rerank(a)
            Image.fromarray(a, 'L').convert('RGB').save(t)
            # grey in R, G and B (BC7, linear): the object shader's alpha clip does not read
            # the red channel alone (BC4 = red only clipped every pixel, measured)
            nvcompress(t, dst, ['-noalpha', '-no-mip-gamma-correct', '-bc7'])
            set_dxgi(dst, 98)  # BC7_UNORM
        else:
            im.save(t)
            nvcompress(t, dst, ['-color', '-noalpha', '-bc7'])
            set_dxgi(dst, 99)  # BC7_UNORM_SRGB, like the game's *.color.dds
        print('%-32s %s -> %d KB' % (base + '.dds', im.size, os.path.getsize(dst) // 1024))


if __name__ == '__main__':
    main()
