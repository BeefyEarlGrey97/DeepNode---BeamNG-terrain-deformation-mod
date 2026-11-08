# Bake the tyre LAYER textures for deepnode (clods.tyreLayer): mud / sand / snow drawn as an
# extra layer of the vehicle's own tyre material (SnowRunner-style: a layer of dirt on the
# rubber, the tyre's own relief stays), not as a skin mesh round the tyre.
# Most BeamNG tyre textures (vehicles/common/tires/tire_*) are strips: U = around the tyre
# (tiles), V = across it, sidewall - tread (V ~0.33..0.65) - sidewall. The skin textures
# (bake_tyremud.py) have U across and V around, so these are their transpose:
#   t_tyrelayer_b.color.png  monochrome clay (colour = the layer's baseColorFactor per kind)
#   t_tyrelayer_o<k>.data.png  coverage masks, k = 1..7 for a covered share of LEVELS[k-1]:
#                            the tread first, then the shoulders, then blotches over the
#                            sidewalls (the skin's coverage order). The layer's opacity map is
#                            switched between them (an opacity map is not alpha-clipped in a
#                            layer, so the share cannot come from a threshold).
# Run after bake_tyremud.py:  python -I tools/tyre_textures/bake_tyrelayer.py tools/tyre_textures
# then  python -I tools/dev/tyre_dds.py tools/tyre_textures 0.5 tyrelayer
import os
import sys

import numpy as np
from PIL import Image

LEVELS = (0.12, 0.24, 0.36, 0.48, 0.6, 0.72, 0.84)
EDGE = 0.04  # order range of the soft mask edge

src = sys.argv[1]
order = np.asarray(Image.open(os.path.join(src, 't_tyremud_o.data.png')).convert('L'), np.float32).T / 255
lum = np.asarray(Image.open(os.path.join(src, 't_tyremud_b.color.png')).convert('L')).T
Image.fromarray(np.ascontiguousarray(lum), 'L').convert('RGB').save(os.path.join(src, 't_tyrelayer_b.color.png'), optimize=True)
for k, c in enumerate(LEVELS, 1):
    m = np.clip((order - (1 - c)) / EDGE + 0.5, 0, 1)
    print('level %d: share %.3f (want %.2f)' % (k, m.mean(), c))
    Image.fromarray(np.ascontiguousarray((m * 255).round().astype(np.uint8)), 'L').save(
        os.path.join(src, 't_tyrelayer_o%d.data.png' % k), optimize=True)
print('ok', order.shape)
