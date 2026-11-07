"""Compare two screenshots inside a pixel box (baked-road calibration, tools/dev/roadbake_rig.lua).

usage: python -I roadbake_compare.py <reference.png> <test.png> [x0 y0 x1 y1]
Prints mean RGB and luminance std of both and the test/reference ratios.
"""
import sys
from PIL import Image, ImageStat


def stats(path, box):
    im = Image.open(path).convert('RGB').crop(box)
    mean = ImageStat.Stat(im).mean
    std = ImageStat.Stat(im.convert('L')).stddev[0]
    return mean, std


def main():
    ref, test = sys.argv[1], sys.argv[2]
    box = tuple(int(v) for v in sys.argv[3:7]) if len(sys.argv) >= 7 else (710, 390, 1210, 690)
    (mr, sr), (mt, st) = stats(ref, box), stats(test, box)
    print('ref  mean %s std %.1f' % ([round(v, 1) for v in mr], sr))
    print('test mean %s std %.1f' % ([round(v, 1) for v in mt], st))
    print('ratio mean %s std %.3f' % ([round(t / max(r, 1e-6), 3) for t, r in zip(mt, mr)], st / max(sr, 1e-6)))


if __name__ == '__main__':
    main()
