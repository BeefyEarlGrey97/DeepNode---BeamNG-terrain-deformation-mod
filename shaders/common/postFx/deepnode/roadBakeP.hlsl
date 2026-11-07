// DeepNode baked road layer (roads.mode 'bake', deepnode/roadBake.lua): composites the decal road
// quads of ONE road material over one tile onto the previous result (slot 4), top-down in world XY.
// The bake runs one material per frame into ping-pong accumulators (rutCopyP.hlsl copies back);
// roadBakeResolveP.hlsl turns them into the five images the tile's mud material reads.
// Output A (dnCtl.y = 0): rgb = road colour (linear) premultiplied, a = accumulated opacity.
// Output B (dnCtl.y = 1): rg = 0.5 + 0.5 normal xy (tile tangent frame), b = roughness, a = metallic,
//   all premultiplied by the same road opacity (the opacity itself lives in A).
// Every channel composites as "over": acc = c a + acc (1 - a); A: a + A (1 - a).
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"

uniform_sampler2D(colTex, 0);
uniform_sampler2D(opaTex, 1);
uniform_sampler2D(nrmTex, 2);
uniform_sampler2D(rghTex, 3);
uniform_sampler2D(prevTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnTile;  // x0, y0, tile size (m), bake size (texels per side)
    uniform float4 dnMap;   // tile texture mapping: tc = frac(cu + su (x - x0) / size), frac(cv + sv (y - y0) / size): cu, su, cv, sv
    uniform float4 dnMat;   // tint rgb, opacity factor
    uniform float4 dnMat2;  // alphaRef (-1 none), normal strength, roughness factor, metallic factor
    uniform float4 dnMat3;  // texel size (m), texture length (m per v repeat), tangent x sign, tangent y sign
    uniform float4 dnCtl;   // quad count, output (0 = A, 1 = B), maps present (1 opacity + 2 roughness), clear (> 0.5: output zero)
    // quad i: dnP = left0 xy, right0 xy; dnQ = left1 xy, right1 xy; dnV = v0, v1, road index, road width (m)
    uniform float4 dnP0; uniform float4 dnQ0; uniform float4 dnV0;
    uniform float4 dnP1; uniform float4 dnQ1; uniform float4 dnV1;
    uniform float4 dnP2; uniform float4 dnQ2; uniform float4 dnV2;
    uniform float4 dnP3; uniform float4 dnQ3; uniform float4 dnV3;
    uniform float4 dnP4; uniform float4 dnQ4; uniform float4 dnV4;
    uniform float4 dnP5; uniform float4 dnQ5; uniform float4 dnV5;
    uniform float4 dnP6; uniform float4 dnQ6; uniform float4 dnV6;
    uniform float4 dnP7; uniform float4 dnQ7; uniform float4 dnV7;
    uniform float4 dnP8; uniform float4 dnQ8; uniform float4 dnV8;
    uniform float4 dnP9; uniform float4 dnQ9; uniform float4 dnV9;
    uniform float4 dnP10; uniform float4 dnQ10; uniform float4 dnV10;
    uniform float4 dnP11; uniform float4 dnQ11; uniform float4 dnV11;
    uniform float4 dnP12; uniform float4 dnQ12; uniform float4 dnV12;
    uniform float4 dnP13; uniform float4 dnQ13; uniform float4 dnV13;
    uniform float4 dnP14; uniform float4 dnQ14; uniform float4 dnV14;
    uniform float4 dnP15; uniform float4 dnQ15; uniform float4 dnV15;
    uniform float4 dnP16; uniform float4 dnQ16; uniform float4 dnV16;
    uniform float4 dnP17; uniform float4 dnQ17; uniform float4 dnV17;
    uniform float4 dnP18; uniform float4 dnQ18; uniform float4 dnV18;
    uniform float4 dnP19; uniform float4 dnQ19; uniform float4 dnV19;
    uniform float4 dnP20; uniform float4 dnQ20; uniform float4 dnV20;
    uniform float4 dnP21; uniform float4 dnQ21; uniform float4 dnV21;
    uniform float4 dnP22; uniform float4 dnQ22; uniform float4 dnV22;
    uniform float4 dnP23; uniform float4 dnQ23; uniform float4 dnV23;
    uniform float4 dnP24; uniform float4 dnQ24; uniform float4 dnV24;
    uniform float4 dnP25; uniform float4 dnQ25; uniform float4 dnV25;
    uniform float4 dnP26; uniform float4 dnQ26; uniform float4 dnV26;
    uniform float4 dnP27; uniform float4 dnQ27; uniform float4 dnV27;
    uniform float4 dnP28; uniform float4 dnQ28; uniform float4 dnV28;
    uniform float4 dnP29; uniform float4 dnQ29; uniform float4 dnV29;
    uniform float4 dnP30; uniform float4 dnQ30; uniform float4 dnV30;
    uniform float4 dnP31; uniform float4 dnQ31; uniform float4 dnV31;
    uniform float4 dnP32; uniform float4 dnQ32; uniform float4 dnV32;
    uniform float4 dnP33; uniform float4 dnQ33; uniform float4 dnV33;
    uniform float4 dnP34; uniform float4 dnQ34; uniform float4 dnV34;
    uniform float4 dnP35; uniform float4 dnQ35; uniform float4 dnV35;
    uniform float4 dnP36; uniform float4 dnQ36; uniform float4 dnV36;
    uniform float4 dnP37; uniform float4 dnQ37; uniform float4 dnV37;
    uniform float4 dnP38; uniform float4 dnQ38; uniform float4 dnV38;
    uniform float4 dnP39; uniform float4 dnQ39; uniform float4 dnV39;
    uniform float4 dnP40; uniform float4 dnQ40; uniform float4 dnV40;
    uniform float4 dnP41; uniform float4 dnQ41; uniform float4 dnV41;
    uniform float4 dnP42; uniform float4 dnQ42; uniform float4 dnV42;
    uniform float4 dnP43; uniform float4 dnQ43; uniform float4 dnV43;
    uniform float4 dnP44; uniform float4 dnQ44; uniform float4 dnV44;
    uniform float4 dnP45; uniform float4 dnQ45; uniform float4 dnV45;
    uniform float4 dnP46; uniform float4 dnQ46; uniform float4 dnV46;
    uniform float4 dnP47; uniform float4 dnQ47; uniform float4 dnV47;
    uniform float4 dnP48; uniform float4 dnQ48; uniform float4 dnV48;
    uniform float4 dnP49; uniform float4 dnQ49; uniform float4 dnV49;
    uniform float4 dnP50; uniform float4 dnQ50; uniform float4 dnV50;
    uniform float4 dnP51; uniform float4 dnQ51; uniform float4 dnV51;
    uniform float4 dnP52; uniform float4 dnQ52; uniform float4 dnV52;
    uniform float4 dnP53; uniform float4 dnQ53; uniform float4 dnV53;
    uniform float4 dnP54; uniform float4 dnQ54; uniform float4 dnV54;
    uniform float4 dnP55; uniform float4 dnQ55; uniform float4 dnV55;
    uniform float4 dnP56; uniform float4 dnQ56; uniform float4 dnV56;
    uniform float4 dnP57; uniform float4 dnQ57; uniform float4 dnV57;
    uniform float4 dnP58; uniform float4 dnQ58; uniform float4 dnV58;
    uniform float4 dnP59; uniform float4 dnQ59; uniform float4 dnV59;
    uniform float4 dnP60; uniform float4 dnQ60; uniform float4 dnV60;
    uniform float4 dnP61; uniform float4 dnQ61; uniform float4 dnV61;
    uniform float4 dnP62; uniform float4 dnQ62; uniform float4 dnV62;
    uniform float4 dnP63; uniform float4 dnQ63; uniform float4 dnV63;
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

// inverse bilinear (a, b, c, d = left0, right0, right1, left1): s across the road, t along it
bool invBilinear(float2 p, float2 a, float2 b, float2 c, float2 d, out float2 st)
{
    st = 0;
    float2 e = b - a, f = d - a, g = a - b + c - d, h = p - a;
    float k2 = cross2(g, f), k1 = cross2(e, f) + cross2(h, g), k0 = cross2(h, e);
    float t;
    if (abs(k2) < 1e-7) t = -k0 / k1;
    else {
        float w = k1 * k1 - 4.0 * k0 * k2;
        if (w < 0.0) return false;
        w = sqrt(w);
        t = (-k1 - w) / (2.0 * k2);
        if (t < 0.0 || t > 1.0) t = (-k1 + w) / (2.0 * k2);
    }
    float2 den = e + g * t;
    float s = abs(den.x) > abs(den.y) ? (h.x - f.x * t) / den.x : (h.y - f.y * t) / den.y;
    st = float2(s, t);
    return s >= 0.0 && s <= 1.0 && t >= 0.0 && t <= 1.0;
}

// one road texel for output A (colour, opacity) or B (normal, roughness, metallic); a = opacity
float4 roadSample(float2 uv, float2 rgt, float width, float outB, out float a)
{
    float tw, th;
    colTexTex.GetDimensions(tw, th);
    // mip level of a bake texel on the road texture (texel size over width across, texture length along)
    float lod = max(0.0, log2(max(dnMat3.x * tw / max(width, 0.1), dnMat3.x * th / max(dnMat3.y, 0.1))));
    float4 col = colTexTex.SampleLevel(colTex_sampler_, uv, lod);
    uint maps = (uint)(dnCtl.z + 0.5);
    a = dnMat.w * ((maps & 1u) ? opaTexTex.SampleLevel(opaTex_sampler_, uv, lod).x : col.a);
    if (dnMat2.x >= 0.0 && a < dnMat2.x) a = 0.0;
    a = saturate(a);
    if (outB < 0.5) return float4(col.rgb * dnMat.rgb, a);
    float4 s = nrmTexTex.SampleLevel(nrmTex_sampler_, uv, lod);
    float2 nr = float2(s.r * 2.0 - 1.0, -(s.g * 2.0 - 1.0)) * dnMat2.y;   // decodeNormalRG convention
    float2 r = normalize(rgt);
    float2 fwd = float2(-r.y, r.x);
    float2 w = nr.x * r + nr.y * (-fwd);              // road frame: tangent u = right, bitangent v = -forward
    float2 nt = float2(w.x * dnMap.y * dnMat3.z, w.y * dnMap.w * dnMat3.w);   // tile frame: tangent along su x, bitangent along sv y
    float rough = ((maps & 2u) ? rghTexTex.SampleLevel(rghTex_sampler_, uv, lod).x : 1.0) * dnMat2.z;
    return float4(nt * 0.5 + 0.5, rough, dnMat2.w);
}

#define QUAD(i) \
    if (i < n && abs(dnV##i.z - lastRoad) > 0.5) { \
        float2 st; \
        if (invBilinear(p, dnP##i.xy, dnP##i.zw, dnQ##i.zw, dnQ##i.xy, st)) { \
            lastRoad = dnV##i.z; \
            float2 uv = float2(st.x, lerp(dnV##i.x, dnV##i.y, st.y)); \
            float2 rgt = lerp(dnP##i.zw - dnP##i.xy, dnQ##i.zw - dnQ##i.xy, st.y); \
            float a; \
            float4 c = roadSample(uv, rgt, dnV##i.w, outB, a); \
            if (outB < 0.5) { acc.rgb = c.rgb * a + acc.rgb * (1.0 - a); acc.a = a + acc.a * (1.0 - a); } \
            else acc = c * a + acc * (1.0 - a); \
        } \
    }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    if (dnCtl.w > 0.5) return float4(0, 0, 0, 0);
    int n = (int)dnCtl.x;
    float outB = dnCtl.y;
    int2 px = (int2)IN.hpos.xy;
    float4 acc = prevTexTex.Load(int3(px, 0));
    // texel centre -> the world point the material shows it on (inverse of the tile mapping)
    float2 tc = (float2(px) + 0.5) / dnTile.w;
    float2 p = dnTile.xy + dnTile.z * float2(frac((tc.x - dnMap.x) * dnMap.y), frac((tc.y - dnMap.z) * dnMap.w));
    float lastRoad = -1.0;
    QUAD(0)
    QUAD(1)
    QUAD(2)
    QUAD(3)
    QUAD(4)
    QUAD(5)
    QUAD(6)
    QUAD(7)
    QUAD(8)
    QUAD(9)
    QUAD(10)
    QUAD(11)
    QUAD(12)
    QUAD(13)
    QUAD(14)
    QUAD(15)
    QUAD(16)
    QUAD(17)
    QUAD(18)
    QUAD(19)
    QUAD(20)
    QUAD(21)
    QUAD(22)
    QUAD(23)
    QUAD(24)
    QUAD(25)
    QUAD(26)
    QUAD(27)
    QUAD(28)
    QUAD(29)
    QUAD(30)
    QUAD(31)
    QUAD(32)
    QUAD(33)
    QUAD(34)
    QUAD(35)
    QUAD(36)
    QUAD(37)
    QUAD(38)
    QUAD(39)
    QUAD(40)
    QUAD(41)
    QUAD(42)
    QUAD(43)
    QUAD(44)
    QUAD(45)
    QUAD(46)
    QUAD(47)
    QUAD(48)
    QUAD(49)
    QUAD(50)
    QUAD(51)
    QUAD(52)
    QUAD(53)
    QUAD(54)
    QUAD(55)
    QUAD(56)
    QUAD(57)
    QUAD(58)
    QUAD(59)
    QUAD(60)
    QUAD(61)
    QUAD(62)
    QUAD(63)
    return acc;
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
