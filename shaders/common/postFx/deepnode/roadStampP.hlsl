// DeepNode road map: paints decal road quads into the world-space map #deepnode_road
// (deepnode/overlay.lua, overlay.roads). The decal roads DeepNode hides over soft ground
// (roads.hideOnMud) are drawn again by roadDrawP.hlsl from this map, onto whatever surface the
// depth buffer shows there, so they follow the ruts.
// The map covers dnWin.z m around the camera with W x W texels per layer and holds two layers
// side by side (2W x W): x < W the top road of each texel, x >= W the road under it (decal
// roads are translucent: the engine stacks them, e.g. the wet mud_water over mud_large).
// Like rutStampP.hlsl, one full-target pass reads the old map (shifted when the window moved)
// and writes every texel to #deepnode_roadTmp; rutCopyP.hlsl copies it back.
// Texel channels (r, g, b linear-filtered by the draw pass, a point-sampled):
//   r = v: position along the road in texture repeats, fraction (the draw pass takes the point
//       value next to the wrap)
//   g = road surface z (the decal road's own height, i.e. the ground before any rut) - baseZ
//   b = u, across the road: 0 at the left edge, 1 at the right edge (painted a margin beyond
//       both edges, so the filtered value runs on past them)
//   a = road id + 0.49 x start / end fade (0..1): id = 1 + material slot (0..7) + 8 x draw
//       rank (0..6), at most 56 so the fade keeps 1/32 steps in half floats; 0 = no road.
// A road goes on top when it ranks at least as high as the top one (which moves down unless it
// is the same road id), else under it when it ranks at least as high as the lower one. Higher
// renderPriority numbers rank higher (drawn on top, as the engine does). The margin beyond a
// road's edges never displaces another road's inside (it pushed real cover out of the two
// layers: hard stair-step edges along the texel grid).
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"

uniform_sampler2D(prevMap, 0);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnWin;   // x0, y0, span, baseZ
    uniform float4 dnCtl;   // quad count, clear (> 0.5), margin beyond the edges (m), texels per layer side (W)
    uniform float4 dnShift; // window moved: texel offset x, y into the old map, z base change (m)
    // quad i: dnA = middle start xy, middle end xy; dnB = half width at start, at end, v at the
    // start (repeats, 0..1), v per metre x side (+: right edge on the clockwise side of
    // start -> end); dnC = fade at start, at end, surface z at start, at end - baseZ
    uniform float4 dnId0; uniform float4 dnId1; uniform float4 dnId2; uniform float4 dnId3;
    uniform float4 dnId4; uniform float4 dnId5;  // road ids of quads 0-23, four per register
    uniform float4 dnA0;  uniform float4 dnB0;  uniform float4 dnC0;
    uniform float4 dnA1;  uniform float4 dnB1;  uniform float4 dnC1;
    uniform float4 dnA2;  uniform float4 dnB2;  uniform float4 dnC2;
    uniform float4 dnA3;  uniform float4 dnB3;  uniform float4 dnC3;
    uniform float4 dnA4;  uniform float4 dnB4;  uniform float4 dnC4;
    uniform float4 dnA5;  uniform float4 dnB5;  uniform float4 dnC5;
    uniform float4 dnA6;  uniform float4 dnB6;  uniform float4 dnC6;
    uniform float4 dnA7;  uniform float4 dnB7;  uniform float4 dnC7;
    uniform float4 dnA8;  uniform float4 dnB8;  uniform float4 dnC8;
    uniform float4 dnA9;  uniform float4 dnB9;  uniform float4 dnC9;
    uniform float4 dnA10; uniform float4 dnB10; uniform float4 dnC10;
    uniform float4 dnA11; uniform float4 dnB11; uniform float4 dnC11;
    uniform float4 dnA12; uniform float4 dnB12; uniform float4 dnC12;
    uniform float4 dnA13; uniform float4 dnB13; uniform float4 dnC13;
    uniform float4 dnA14; uniform float4 dnB14; uniform float4 dnC14;
    uniform float4 dnA15; uniform float4 dnB15; uniform float4 dnC15;
    uniform float4 dnA16; uniform float4 dnB16; uniform float4 dnC16;
    uniform float4 dnA17; uniform float4 dnB17; uniform float4 dnC17;
    uniform float4 dnA18; uniform float4 dnB18; uniform float4 dnC18;
    uniform float4 dnA19; uniform float4 dnB19; uniform float4 dnC19;
    uniform float4 dnA20; uniform float4 dnB20; uniform float4 dnC20;
    uniform float4 dnA21; uniform float4 dnB21; uniform float4 dnC21;
    uniform float4 dnA22; uniform float4 dnB22; uniform float4 dnC22;
    uniform float4 dnA23; uniform float4 dnB23; uniform float4 dnC23;
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float roadId(float4 t) { return floor(t.a + 0.01); }
// inside its road (not in the margin painted beyond the edges)
bool onRoad(float4 t) { return t.a > 0.5 && t.b >= 0.0 && t.b <= 1.0; }
float roadRank(float4 t)
{
    float id = roadId(t);
    return id > 0.5 ? floor((id - 1.0) / 8.0) : -1.0;
}

// quad i over the texel (with the margin beyond the edges, a few cm beyond its ends so
// neighbouring quads meet without a crack): sorted into the two layers by rank
#define QUAD(i, ID)                                                                        \
    if (i < n) {                                                                           \
        float2 a = dnA##i.xy;                                                              \
        float2 ab = dnA##i.zw - a;                                                         \
        float L = max(length(ab), 1e-4);                                                   \
        float2 fw = ab / L;                                                                \
        float t = dot(p - a, fw);                                                          \
        if (t >= -0.03 && t <= L + 0.03) {                                                 \
            float tt = saturate(t / L);                                                    \
            float hw = max(lerp(dnB##i.x, dnB##i.y, tt), 0.05);                            \
            float side = dnB##i.w < 0.0 ? -1.0 : 1.0;                                      \
            float lat = dot(p - a, float2(fw.y, -fw.x)) * side;                            \
            if (abs(lat) <= hw + margin) {                                                 \
                float id = ID;                                                             \
                float rank = floor((id - 1.0) / 8.0);                                      \
                float v = dnB##i.z + t * abs(dnB##i.w);                                    \
                float f = saturate(lerp(dnC##i.x, dnC##i.y, tt));                          \
                float4 c = float4(v - floor(v), lerp(dnC##i.z, dnC##i.w, tt),              \
                                  0.5 + lat / (2.0 * hw), id + 0.49 * f);                  \
                bool cin = abs(lat) <= hw;                                                 \
                if (rank >= roadRank(top) && (cin || !onRoad(top))) {                     \
                    if (abs(roadId(top) - id) > 0.5 && top.a > 0.5) sec = top;             \
                    top = c;                                                               \
                } else if (abs(roadId(top) - id) > 0.5 && rank >= roadRank(sec)            \
                           && (cin || !onRoad(sec))) {                                     \
                    sec = c;                                                               \
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
    int2 pix = (int2)IN.hpos.xy;
    bool lower = pix.x >= W;
    int2 q = int2(lower ? pix.x - W : pix.x, pix.y);
    float2 p = dnWin.xy + (float2(q) + 0.5) / float(W) * dnWin.z;
    // old content of both layers, shifted when the window moved (outside the old window: empty)
    int2 src = q + (int2)dnShift.xy;
    float4 top = 0;
    float4 sec = 0;
    if (all(src >= 0) && src.x < W && src.y < W) {
        top = prevMapTex.Load(int3(src, 0));
        sec = prevMapTex.Load(int3(src.x + W, src.y, 0));
        if (top.a > 0.5) top.g += dnShift.z;
        if (sec.a > 0.5) sec.g += dnShift.z;
    }
    QUAD(0, dnId0.x)  QUAD(1, dnId0.y)  QUAD(2, dnId0.z)  QUAD(3, dnId0.w)
    QUAD(4, dnId1.x)  QUAD(5, dnId1.y)  QUAD(6, dnId1.z)  QUAD(7, dnId1.w)
    QUAD(8, dnId2.x)  QUAD(9, dnId2.y)  QUAD(10, dnId2.z) QUAD(11, dnId2.w)
    QUAD(12, dnId3.x) QUAD(13, dnId3.y) QUAD(14, dnId3.z) QUAD(15, dnId3.w)
    QUAD(16, dnId4.x) QUAD(17, dnId4.y) QUAD(18, dnId4.z) QUAD(19, dnId4.w)
    QUAD(20, dnId5.x) QUAD(21, dnId5.y) QUAD(22, dnId5.z) QUAD(23, dnId5.w)
    return lower ? sec : top;
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
