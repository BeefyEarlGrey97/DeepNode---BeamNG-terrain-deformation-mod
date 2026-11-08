// DeepNode road map: paints decal road quads into the world-space map #deepnode_road
// (deepnode/overlay.lua, roads.mode 'shader'). The decal roads DeepNode hides over soft ground
// are drawn again by roadDrawP.hlsl from this map, onto whatever surface the depth buffer shows
// there, so they follow the ruts.
// The map covers dnWin.z m around the camera with W x W texels and holds up to L road entries
// per texel (decal roads are translucent and the engine stacks them: up to 7 on one point of the
// gridmap_v2 mud pit). Entry j is two texels: x = (2 j) W + i (T0) and (2 j + 1) W + i (T1).
//   T0: r = v (along the road, texture repeats) at the texel centre, fraction
//       g = u (across: 0 left edge, 1 right edge) at the texel centre
//       b = road surface z (the decal's own height: the ground before any rut) - baseZ
//       a = key + 0.49 x start / end fade (0..1); key = 1 + draw rank of (renderPriority,
//           material); 0 = empty
//   T1: world gradients per metre: du/dx, du/dy, dv/dx, dv/dy
// A pixel takes its texel's entry and extrapolates u, v from the texel centre with the
// gradients: exact on a straight strip, no filtering across neighbouring roads, smooth texture
// derivatives (roadDrawP.hlsl). The gradients come from the quad's inverse bilinear map
// (corners left / right edge points of two neighbouring spline samples, as the engine's strip).
// A texel takes a quad when its centre lies within `margin` m of it (beyond the edges, so the
// texels on an edge carry it). The same road continuing (same key, u and v at the centre and
// direction of their gradients, all nearly equal: the two quads map the same texel centre)
// keeps one entry, the one whose quad holds the centre; looser tests (0.1 in u, v) merged
// different roads of one material (gridmap_v2 has 102 furrow roads at one priority, many
// parallel offset copies) and dropped layers in texel blocks. A full texel drops the entry of least
// weight (margin entries before inside ones, then the lowest key).
// Like rutStampP.hlsl, one full-target pass reads the old map (shifted when the window moved)
// and writes every texel to #deepnode_roadTmp; rutCopyP.hlsl copies it back.
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"

uniform_sampler2D(prevMap, 0);

#define DN_MAXL 8

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnCtl;   // quad count, clear (> 0.5), margin beyond the edges (m), texels per side (W)
    uniform float4 dnShift; // window moved: texel offset x, y into the old map, base z change (m), layers (L)
    uniform float4 dnTex;   // texel size (m), unused x3
    // quad i, corners relative to the window origin: dnQa = left xy, right xy at the start;
    // dnQb = the same at the end; dnQc = v at start, at end (repeats), surface z - baseZ at
    // start, at end; dnQd = fade at start, at end, key, right edge z - left edge z (m)
#define DN_Q(i) uniform float4 dnQa##i; uniform float4 dnQb##i; uniform float4 dnQc##i; uniform float4 dnQd##i;
    DN_Q(0) DN_Q(1) DN_Q(2) DN_Q(3) DN_Q(4) DN_Q(5) DN_Q(6) DN_Q(7)
    DN_Q(8) DN_Q(9) DN_Q(10) DN_Q(11) DN_Q(12) DN_Q(13) DN_Q(14) DN_Q(15)
    DN_Q(16) DN_Q(17) DN_Q(18) DN_Q(19) DN_Q(20) DN_Q(21) DN_Q(22) DN_Q(23)
    DN_Q(24) DN_Q(25) DN_Q(26) DN_Q(27) DN_Q(28) DN_Q(29) DN_Q(30) DN_Q(31)
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

static float4 E0[DN_MAXL];
static float4 E1[DN_MAXL];

float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

// (u, s) of p in the quad a (0,0), b (1,0), c (1,1), d (0,1); outside the quad the root nearest
// to the unit square (extrapolated); x < -1e8: none
float2 invBilinear(float2 p, float2 a, float2 b, float2 c, float2 d)
{
    float2 e = b - a, f = d - a, g = a - b + c - d, h = p - a;
    float k2 = cross2(g, f);
    float k1 = cross2(e, f) + cross2(h, g);
    float k0 = cross2(h, e);
    float s0, s1;
    if (abs(k2) < 1e-6 * max(abs(k1), 1e-6)) {
        if (abs(k1) < 1e-9) return float2(-1e9, 0);
        s0 = s1 = -k0 / k1;
    } else {
        float w = k1 * k1 - 4.0 * k0 * k2;
        if (w < 0.0) return float2(-1e9, 0);
        w = sqrt(w);
        s0 = (-k1 - w) / (2.0 * k2);
        s1 = (-k1 + w) / (2.0 * k2);
    }
    float2 best = float2(-1e9, 0);
    float bd = 1e9;
    [unroll] for (int r = 0; r < 2; r++) {
        float s = r == 0 ? s0 : s1;
        float2 eu = e + g * s;
        float u = dot(h - f * s, eu) / max(dot(eu, eu), 1e-9);
        float2 o = max(max(-float2(u, s), float2(u, s) - 1.0), 0.0);
        float dd = o.x + o.y;
        if (dd < bd) { bd = dd; best = float2(u, s); }
    }
    return best;
}

float entKey(float4 t0) { return floor(t0.a + 0.01); }
float sameDir(float2 a, float2 b) { return dot(a, b) / max(length(a) * length(b), 1e-9); }
// weight against eviction: inside entries before margin ones, then the higher key
float entWeight(float4 t0)
{
    if (t0.a < 0.5) return -1.0;
    return entKey(t0) + ((t0.g >= 0.0 && t0.g <= 1.0) ? 1000.0 : 0.0);
}

void insert(float4 c0, float4 c1, bool inside, int L)
{
    float key = entKey(c0);
    float w = key + (inside ? 1000.0 : 0.0);
    // the same road continuing: keep the entry whose quad holds the centre
    [unroll] for (int j = 0; j < DN_MAXL; j++) {
        if (j < L && E0[j].a > 0.5 && abs(entKey(E0[j]) - key) < 0.5
            && abs(E0[j].g - c0.g) < 0.02 && abs(frac(E0[j].r - c0.r + 0.5) - 0.5) < 0.02
            && sameDir(E1[j].rg, c1.rg) > 0.99 && sameDir(E1[j].ba, c1.ba) > 0.99) {
            if (inside || !(E0[j].g >= 0.0 && E0[j].g <= 1.0)) { E0[j] = c0; E1[j] = c1; }
            return;
        }
    }
    // a free entry, or the one of least weight if lighter than this one
    int lo = -1;
    float lw = 1e9;
    [unroll] for (int k = 0; k < DN_MAXL; k++) {
        if (k < L) {
            float ew = entWeight(E0[k]);
            if (ew < lw) { lw = ew; lo = k; }
        }
    }
    if (lo >= 0 && lw < w) { E0[lo] = c0; E1[lo] = c1; }
}

#define QUAD(i)                                                                            \
    if (i < n) {                                                                           \
        float2 a = dnQa##i.xy, b = dnQa##i.zw, d = dnQb##i.xy, c = dnQb##i.zw;             \
        float2 lo = min(min(a, b), min(c, d)) - margin, hi = max(max(a, b), max(c, d)) + margin; \
        if (all(p >= lo) && all(p <= hi)) {                                                \
            float2 us = invBilinear(p, a, b, c, d);                                        \
            if (us.x > -1e8) {                                                             \
                float2 e = b - a, f = d - a, g = a - b + c - d;                            \
                float2 Pu = e + g * us.y, Ps = f + g * us.x;                               \
                float wd = max(length(Pu), 0.05), ln = max(length(Ps), 0.05);              \
                float mu = margin / wd, ms = margin / ln;                                  \
                if (us.x >= -mu && us.x <= 1.0 + mu && us.y >= -ms && us.y <= 1.0 + ms) {  \
                    float det = cross2(Pu, Ps);                                            \
                    if (abs(det) > 1e-6) {                                                 \
                        float2 gu = float2(Ps.y, -Ps.x) / det;                             \
                        float2 gs = float2(-Pu.y, Pu.x) / det;                             \
                        float v = lerp(dnQc##i.x, dnQc##i.y, us.y);                        \
                        float2 gv = gs * (dnQc##i.y - dnQc##i.x);                          \
                        float fd = saturate(lerp(dnQd##i.x, dnQd##i.y, us.y));             \
                        float4 c0 = float4(frac(v), us.x, lerp(dnQc##i.z, dnQc##i.w, saturate(us.y)) + (saturate(us.x) - 0.5) * dnQd##i.w, \
                                           dnQd##i.z + 0.49 * fd);                          \
                        bool inside = us.x >= 0.0 && us.x <= 1.0 && us.y >= 0.0 && us.y <= 1.0; \
                        insert(c0, float4(gu, gv), inside, L);                             \
                    }                                                                      \
                }                                                                          \
            }                                                                              \
        }                                                                                  \
    }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    if (dnCtl.y > 0.5) return float4(0, 0, 0, 0);
    int n = (int)dnCtl.x;
    float margin = dnCtl.z;
    int W = (int)dnCtl.w;
    int L = clamp((int)dnShift.w, 1, DN_MAXL);
    int2 pix = (int2)IN.hpos.xy;
    int part = pix.x / W;          // 2 j + t
    int2 q = int2(pix.x - part * W, pix.y);
    float2 p = (float2(q) + 0.5) * dnTex.x;
    // old entries, shifted when the window moved (outside the old window: empty)
    int2 src = q + (int2)dnShift.xy;
    bool have = all(src >= 0) && src.x < W && src.y < W;
    [unroll] for (int j = 0; j < DN_MAXL; j++) {
        E0[j] = 0;
        E1[j] = 0;
        if (have && j < L) {
            E0[j] = prevMapTex.Load(int3(src.x + 2 * j * W, src.y, 0));
            E1[j] = prevMapTex.Load(int3(src.x + (2 * j + 1) * W, src.y, 0));
            if (E0[j].a > 0.5) E0[j].b += dnShift.z;
        }
    }
    QUAD(0)  QUAD(1)  QUAD(2)  QUAD(3)  QUAD(4)  QUAD(5)  QUAD(6)  QUAD(7)
    QUAD(8)  QUAD(9)  QUAD(10) QUAD(11) QUAD(12) QUAD(13) QUAD(14) QUAD(15)
    QUAD(16) QUAD(17) QUAD(18) QUAD(19) QUAD(20) QUAD(21) QUAD(22) QUAD(23)
    QUAD(24) QUAD(25) QUAD(26) QUAD(27) QUAD(28) QUAD(29) QUAD(30) QUAD(31)
    int lay = part >> 1;
    if (lay >= L) return float4(0, 0, 0, 0);
    return (part & 1) ? E1[lay] : E0[lay];
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
