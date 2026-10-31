// DeepNode post effect helpers (rutOverlayP.hlsl, tyreWetP.hlsl): hashes, value noise,
// granular crumbs, world gradients from screen derivatives, self-relighting.
#ifndef DN_COMMON_H_HLSL
#define DN_COMMON_H_HLSL

// world xy folded into a 512 m period: keeps hash inputs small (float precision) without a
// seam when the rut map window moves
float2 dnFold(float2 p)
{
    return p - 512.0 * floor(p / 512.0);
}

float dnHash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float2 dnHash22(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

// value noise, 0..1
float dnNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = p - i;
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = dnHash12(i);
    float b = dnHash12(i + float2(1, 0));
    float c = dnHash12(i + float2(0, 1));
    float d = dnHash12(i + float2(1, 1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// granular crumbs: at most one round lump per unit cell (present with probability
// `density`), radius 0.25..0.55 cells, smooth profile rad x (1 - d^2/rad^2)^2 (no hard rim:
// hemispheres read as rings). Returns height (cells) and its gradient d height / d p.
// The highest lump wins where lumps overlap.
float3 dnCrumbs(float2 p, float density)
{
    float2 i = floor(p);
    float2 f = p - i;
    float h = 0.0;
    float2 g = 0.0;
    [unroll] for (int y = -1; y <= 1; y++) {
        [unroll] for (int x = -1; x <= 1; x++) {
            float2 c = float2(x, y);
            float2 r = dnHash22(i + c);
            float pres = dnHash12(i + c + 17.31);
            float rad = 0.25 + 0.3 * frac(pres * 7.13);
            float2 cp = c + 0.2 + 0.6 * r - f; // from p to the lump centre
            float d2 = dot(cp, cp);
            float rr = rad * rad;
            if (pres < density && d2 < rr) {
                float q = 1.0 - d2 / rr;
                float hh = rad * q * q;
                if (hh > h) {
                    h = hh;
                    g = cp * (4.0 * rad * q / rr);
                }
            }
        }
    }
    return float3(h, g);
}

// world xy gradient of a quantity from its screen derivatives (fx, fy) and the screen
// derivatives of the world position (px, py); 0 where the view is edge-on
float2 dnWorldGrad(float fx, float fy, float2 px, float2 py)
{
    float det = px.x * py.y - px.y * py.x;
    if (abs(det) < 1e-12) return float2(0, 0);
    return float2(fx * py.y - fy * px.y, px.x * fy - py.x * fx) / det;
}

float dnLum(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

#endif // DN_COMMON_H_HLSL
