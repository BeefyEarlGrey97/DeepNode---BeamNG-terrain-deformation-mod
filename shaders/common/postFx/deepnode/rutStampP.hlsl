// DeepNode rut map: paints tyre prints into the world-space map #deepnode_rut.
// One full-target pass per frame while prints are queued (deepnode/overlay.lua): reads the
// map, writes every texel (old value or new print) to #deepnode_rutTmp; rutCopyP.hlsl
// copies it back. A pass that draws into a target does not keep its old content, even
// with PFXTargetClear_None (measured 2026-10-31), hence the copy.
// Texel (u,v) covers world (x0 + u*span, y0 + v*span). Channels:
//   r = print strength (0 = untouched; a berm's intensity outside the tyre),
//   g = along-track coordinate (phase units, overlay.phasePerMetre per m, mod 64),
//   b = undisturbed ground z (the surface before the rut) - baseZ (m),
//   a = position across the tyre (-1..1 inside the print, up to +-2 on the berm beside it)
//       + 4 x surface kind (0 mud, 1 sand, 2 mud carried onto hard ground, 3 sand dust,
//       4 mud splat thrown by a spinning wheel)
// The phase continues from one wheel report to the next (arc length at the segment start
// comes from Lua), so the print pattern continues along curved tracks.
// A newer print replaces what was under it; a berm only covers untouched ground or berms.
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"
#include "dnCommon.h.hlsl"

uniform_sampler2D(prevMap, 0);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnWin;   // x0, y0, span, baseZ
    uniform float4 dnCtl;   // segment count, clear (> 0.5), edge softness (m), phase per metre
    uniform float4 dnShift; // window moved: texel offset x, y into the old map, z base change (m), erase rects
    uniform float4 dnClr0;  // erase rects (x0, y0, x1, y1): rut tiles DeepNode reset
    uniform float4 dnClr1;
    uniform float4 dnClr2;
    uniform float4 dnClr3;
    uniform float4 dnA0;
    uniform float4 dnA1;
    uniform float4 dnA2;
    uniform float4 dnA3;
    uniform float4 dnA4;
    uniform float4 dnA5;
    uniform float4 dnA6;
    uniform float4 dnA7;
    uniform float4 dnA8;
    uniform float4 dnA9;
    uniform float4 dnA10;
    uniform float4 dnA11;
    uniform float4 dnA12;
    uniform float4 dnA13;
    uniform float4 dnA14;
    uniform float4 dnA15;
    uniform float4 dnB0;
    uniform float4 dnB1;
    uniform float4 dnB2;
    uniform float4 dnB3;
    uniform float4 dnB4;
    uniform float4 dnB5;
    uniform float4 dnB6;
    uniform float4 dnB7;
    uniform float4 dnB8;
    uniform float4 dnB9;
    uniform float4 dnB10;
    uniform float4 dnB11;
    uniform float4 dnB12;
    uniform float4 dnB13;
    uniform float4 dnB14;
    uniform float4 dnB15;
    uniform float4 dnC0;
    uniform float4 dnC1;
    uniform float4 dnC2;
    uniform float4 dnC3;
    uniform float4 dnC4;
    uniform float4 dnC5;
    uniform float4 dnC6;
    uniform float4 dnC7;
    uniform float4 dnC8;
    uniform float4 dnC9;
    uniform float4 dnC10;
    uniform float4 dnC11;
    uniform float4 dnC12;
    uniform float4 dnC13;
    uniform float4 dnC14;
    uniform float4 dnC15;
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

// mud splat blob over the stamped capsule: ragged edge, holes where thin (texels outside the
// blob keep what was there, so a berm under a splat's edge stays a berm; a splat over a print
// keeps its along-track phase, ground height and lateral position, so the print relief runs on
// without a seam at the splat's edge)
float splatCover(float2 p, float lat, float strength)
{
    float2 wf = dnFold(p);
    float bn = dnNoise(wf * 9.0 + 4.7) * 0.6 + dnNoise(wf * 23.0 + 1.3) * 0.4;
    return saturate(((1.0 - lat * lat) * strength * 1.3 - bn) * 6.0);
}

// lateral position of a stored texel (the kind is packed on top in steps of 4)
float storedLat(float a)
{
    return a - 4.0 * round(a / 4.0);
}

// segment i: dnA = start xy, end xy; dnB = half width, ground z - baseZ, heading (rad), arc length at
// the start (m); dnC = kind, strength, berm reach (x half width), unused
#define SEG(i)                                                                         \
    if (i < n) {                                                                       \
        float2 a = dnA##i.xy;                                                          \
        float2 ab = dnA##i.zw - a;                                                     \
        float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-6));                   \
        float2 d = p - (a + ab * t);                                                   \
        float dist = length(d);                                                        \
        float hw = dnB##i.x;                                                           \
        float hwB = hw * max(dnC##i.z, 1.0);                                           \
        if (dist < hwB) {                                                              \
            float2 fw = float2(cos(dnB##i.z), sin(dnB##i.z));                          \
            float lat = dot(d, float2(-fw.y, fw.x)) / hw;                              \
            float kind4 = 4.0 * dnC##i.x;                                              \
            bool oldPrint = res.r > 0.0 && abs(storedLat(res.a)) <= 1.0;               \
            if (dnC##i.x > 3.5) {                                                  \
                float sc = dist < hw ? splatCover(p, lat, dnC##i.y) : 0.0;         \
                if (sc > 0.1) res = res.r > 0.0 ? float4(sc, res.g, res.b, storedLat(res.a) + kind4) : float4(sc, 0.0, dnB##i.y, clamp(lat, -1.0, 1.0) + kind4);\
            } else if (dist < hw) {                                                \
                float cov = (1.0 - smoothstep(max(hw - edge, 0.0), hw, dist)) * dnC##i.y; \
                if (!oldPrint || cov >= 0.5 * res.r) {                                 \
                    float ph = (dnB##i.w + dot(p - a, fw)) * ppm;                      \
                    res = float4(max(cov, 0.02), ph - 64.0 * floor(ph / 64.0), dnB##i.y, \
                                 clamp(lat, -1.0, 1.0) + kind4);                       \
                }                                                                      \
            } else if (!oldPrint) {                                                    \
                float bc = (1.0 - smoothstep(hw, hwB, dist)) * dnC##i.y;               \
                if (bc > res.r) res = float4(bc, 0.0, dnB##i.y,                        \
                                             clamp(lat, -1.99, 1.99) + kind4);         \
            }                                                                          \
        }                                                                              \
    }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    if (dnCtl.y > 0.5) return float4(0, 0, 0, 0);
    int n = (int)dnCtl.x;
    float2 p = dnWin.xy + IN.uv0 * dnWin.z;
    // old content, shifted when the window moved (outside the old window: empty)
    int2 src = (int2)IN.hpos.xy + (int2)dnShift.xy;
    uint w, h;
    prevMapTex.GetDimensions(w, h);
    float4 res = 0;
    if (all(src >= 0) && src.x < (int)w && src.y < (int)h) {
        res = prevMapTex.Load(int3(src, 0));
        if (res.r > 0.0) res.b += dnShift.z;
    }
    int nc = (int)dnShift.w;
    if (nc > 0 && all(p >= dnClr0.xy) && all(p <= dnClr0.zw)) res = 0;
    if (nc > 1 && all(p >= dnClr1.xy) && all(p <= dnClr1.zw)) res = 0;
    if (nc > 2 && all(p >= dnClr2.xy) && all(p <= dnClr2.zw)) res = 0;
    if (nc > 3 && all(p >= dnClr3.xy) && all(p <= dnClr3.zw)) res = 0;
    float edge = dnCtl.z;
    float ppm = dnCtl.w;
    SEG(0)
    SEG(1)
    SEG(2)
    SEG(3)
    SEG(4)
    SEG(5)
    SEG(6)
    SEG(7)
    SEG(8)
    SEG(9)
    SEG(10)
    SEG(11)
    SEG(12)
    SEG(13)
    SEG(14)
    SEG(15)
    return res;
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
