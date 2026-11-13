// DeepNode rut map: paints tyre prints into the world-space map #deepnode_rut.
// Compute pass, in place: a compute PostEffect keeps its named target between frames
// (measured 2026-11-13), so texels away from this frame's prints (outside dnBox) return
// without touching memory. Full frames (dnMode.x: clear, window move, dry pass) visit every
// texel.
// The map wraps: texel (i, j) holds world x = i*texel + k*span (y alike), the k that puts it
// inside the window, so a window move needs no copy: texels that were outside the old window
// (dnShift.xy, dnMode.y) are cleared, the others keep their prints, ground z rebased.
// Channels:
//   r = print strength (0 = untouched; a berm's intensity outside the tyre),
//   g = along-track coordinate (phase units, overlay.phasePerMetre per m, mod 64),
//   b = undisturbed ground z (the surface before the rut) - baseZ (m),
//   a = position across the tyre (-1..1 inside the print, up to +-2 on the berm beside it)
//       + 4 x surface kind (0 mud, 1 sand, 2 mud carried onto hard ground, 3 sand dust,
//       4 mud splat thrown by a spinning wheel, 5 grass track, 6 dirt track, 7 wet track,
//       11 pre-rutted road wheel line: wet trench floor and pools, no print pattern;
//       a wet track keeps its paint time (s, mod 64) in g instead of the phase and is erased
//       here once older than the drying time)
// Pooled water (overlay.lua pools, puddleMode 'fill'): a mud print texel under a pool keeps
// r, b and a and stores -1 - (water surface depth below its undisturbed ground, m) in g
// (g < -0.5: water; the print phase is lost there, the water hides the pattern).
// The phase continues from one wheel report to the next (arc length at the segment start
// comes from Lua), so the print pattern continues along curved tracks.
// A newer print replaces what was under it; a berm only covers untouched ground or berms.
#define PFX_COMPUTE 1

#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"
#include "dnCommon.h.hlsl"

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnWin;   // x0, y0, span, baseZ
    uniform float4 dnCtl;   // segment count, clear (> 0.5), edge softness (m), phase per metre
    uniform float4 dnShift; // old window x0, y0 (window moved, dnMode.y), z base change (m), erase rects
    uniform float4 dnClr0;  // erase rects (x0, y0, x1, y1): rut tiles DeepNode reset
    uniform float4 dnClr1;
    uniform float4 dnClr2;
    uniform float4 dnClr3;
    uniform float4 dnTime;  // time (s, mod 64), drying time of wet tracks (s)
    uniform float4 dnBox;   // world x0, y0, x1, y1 around this frame's prints and erase rects
    uniform float4 dnMode;  // x: full frame (> 0.5), y: window moved
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
#include "shaders/common/postFx/postFxCompute.h.hlsl"

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
// kind 8 (water) / 9 (dry): dnA = rect x0, y0, x1, y1; dnB.y = water surface z - baseZ. Water
// marks the mud print texels in the rect; dry takes the water off the rect's texels.
#define SEG(i)                                                                         \
    if (i < n && dnC##i.x > 7.5 && dnC##i.x < 9.5) {                                   \
        if (all(p >= dnA##i.xy) && all(p <= dnA##i.zw) && res.r > 0.0                  \
            && (round(res.a / 4.0) == 0.0 || round(res.a / 4.0) == 11.0)) {            \
            if (dnC##i.x < 8.5) {                                                      \
                if (abs(storedLat(res.a)) <= 1.0)                                      \
                    res.g = -1.0 - max(res.b - dnB##i.y, 0.0);                         \
            } else if (res.g < -0.5) {                                                 \
                res.g = 0.0;                                                           \
            }                                                                          \
        }                                                                              \
    } else if (i < n) {                                                                \
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
            if (dnC##i.x > 6.5 && dnC##i.x < 7.5) {                                \
                bool wetOk = res.r <= 0.0 || round(res.a / 4.0) == 7.0;            \
                float cw = (1.0 - smoothstep(max(hw - edge, 0.0), hw, dist)) * dnC##i.y;\
                if (dist < hw && wetOk && cw >= res.r * 0.5)                       \
                    res = float4(max(cw, 0.02), dnTime.x, dnB##i.y, clamp(lat, -1.0, 1.0) + kind4);\
            } else if (dnC##i.x > 3.5 && dnC##i.x < 6.5) {                         \
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

PFX_NUMTHREADS
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 sp;
    if (!postFxComputeThread(dispatchThreadID, sp)) return;
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) return;
    uint w, h;
    pfxOut.GetDimensions(w, h);
    float span = dnWin.z;
    if (dnCtl.y > 0.5) { pfxOut[sp] = float4(0, 0, 0, 0); return; }
    int n = (int)dnCtl.x;
    // the world position this texel stands for inside the window (the map repeats every span m)
    float2 q = (float2(sp) + 0.5) / float2(w, h) * span - dnWin.xy;
    float2 p = dnWin.xy + q - span * floor(q / span);
    if (dnMode.x < 0.5 && (any(p < dnBox.xy) || any(p > dnBox.zw))) return;
    float4 res = pfxOut[sp];
    float4 old = res;
    if (dnMode.y > 0.5) {
        // window moved: a texel outside the old window held prints from span m away
        if (any(p < dnShift.xy) || any(p >= dnShift.xy + span)) res = 0;
        else if (res.r > 0.0) res.b += dnShift.z;
    }
    // wet tracks dry: erase them once older than the drying time
    if (res.r > 0.0 && round(res.a / 4.0) == 7.0) {
        float age = dnTime.x - res.g;
        age -= 64.0 * floor(age / 64.0);
        if (age > dnTime.y) res = 0;
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
    if (any(res != old)) pfxOut[sp] = res;
}
