// DeepNode wet tyres: screen-space look of up to 16 wheels (deepnode/overlay.lua sends the
// wheels nearest the camera that are wet or coated). A pixel belongs to a wheel when its
// world position (depth buffer) lies in the wheel's tyre volume (between rim and tread,
// within the tyre width) and its normal faces out of the tyre (tread or sidewall), so the
// ground under a sunk tyre is left alone. Per pixel, in the wheel frame that turns with the
// wheel (e1 = the tread node direction from the hub):
//  * wet: rubber and mud darker, glossy sun highlight with streaks that turn with the tyre;
//  * coat (optional, overlay.tyreCoat): mud coverage grown from the tread to the sidewalls
//    with lumpy relief, coloured like the ground it came from (no meshes, no material flushes).
// Runs after the rut overlay, before fog and translucent objects.
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"
#include "dnCommon.h.hlsl"

uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(shadowTex, 3);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnSun;     // direction to the sun (xyz), ambient share (w)
    uniform float4 dnTy;      // wheel count, wet darkening, wet highlight strength, debug
    uniform float4 dnTyOpt;   // use shadow mask, albedo guess (light level from the scene), coat on, coat lump size (m)
    // per wheel: a = hub centre, tyre radius; b = axle, half width; c = e1 (turns with the
    // wheel), rim radius; d = wetness, coat, coat colour packed (see overlay.lua), seed
#define WHEEL(i) uniform float4 dnWa##i; uniform float4 dnWb##i; uniform float4 dnWc##i; uniform float4 dnWd##i;
    WHEEL(0) WHEEL(1) WHEEL(2) WHEEL(3) WHEEL(4) WHEEL(5) WHEEL(6) WHEEL(7)
    WHEEL(8) WHEEL(9) WHEEL(10) WHEEL(11) WHEEL(12) WHEEL(13) WHEEL(14) WHEEL(15)
#undef WHEEL
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

// colour packed as three 0..1 channels in steps of 1/64 (r + g x 64 + b x 4096, each 0..63)
float3 unpackColor(float v)
{
    float b = floor(v / 4096.0);
    float g = floor((v - b * 4096.0) / 64.0);
    float r = v - b * 4096.0 - g * 64.0;
    return float3(r, g, b) / 63.0;
}

#define TEST(i)                                                                         \
    if (hit < 0 && i < cnt) {                                                           \
        float3 rel = wp - dnWa##i.xyz;                                                  \
        float ax = dot(rel, dnWb##i.xyz);                                               \
        float3 rad = rel - dnWb##i.xyz * ax;                                            \
        float rr = length(rad);                                                         \
        if (abs(ax) < dnWb##i.w * 1.1 && rr < dnWa##i.w * 1.12 && rr > dnWc##i.w * 0.9) { \
            float3 nr = rad / max(rr, 1e-4);                                            \
            if (dot(n, nr) > 0.15 || abs(dot(n, dnWb##i.xyz)) > 0.55) {                 \
                hit = i; wa = dnWa##i; wb = dnWb##i; wc = dnWc##i; wd = dnWd##i;        \
                axW = ax; rrW = rr; nrW = nr;                                           \
            }                                                                           \
        }                                                                               \
    }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float4 g = decodeGBuffer(TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), IN.uv0, projParams);
    if (g.w >= 0.99999) discard;
    float3 wp = eyePosWorld + IN.wsEyeRay * g.w;
    float3 n = g.xyz;
    int cnt = (int)dnTy.x;
    int hit = -1;
    float4 wa = 0, wb = 0, wc = 0, wd = 0;
    float axW = 0, rrW = 0;
    float3 nrW = 0;
    TEST(0) TEST(1) TEST(2) TEST(3) TEST(4) TEST(5) TEST(6) TEST(7)
    TEST(8) TEST(9) TEST(10) TEST(11) TEST(12) TEST(13) TEST(14) TEST(15)
    if (hit < 0) discard;

    float3 scene = tex2Dlod(sceneTex, float4(IN.uv0, 0, 0)).rgb;
    if (dnTy.w > 0.5) return float4(scene * float3(0.4, 0.6, 1.6), 1); // debug: tyre pixels in blue

    float3 axle = wb.xyz;
    float hw = wb.w;
    float R = wa.w;
    float rimR = wc.w;
    float3 e1 = wc.xyz;
    float3 e2 = cross(axle, e1);
    // tyre coordinates: angle (turns with the wheel), across (-1..1), radius share rim..tread
    float ang = atan2(dot(nrW, e2), dot(nrW, e1));
    float across = axW / max(hw, 1e-3);
    float radK = saturate((rrW - rimR) / max(R - rimR, 1e-3));
    float arc = ang * R; // m along the tread
    float2 tc = float2(arc, axW);

    float sh = 1.0;
    if (dnTyOpt.x > 0.5) {
        uint mw, mh;
        shadowTexTex.GetDimensions(mw, mh);
        int2 mp = clamp((int2)(IN.uv0 * float2(mw, mh)), int2(0, 0), int2(mw, mh) - 1);
        sh = saturate(shadowTexTex.Load(int3(mp, 0)).r);
    }
    float3 L = normalize(dnSun.xyz);
    float amb = dnSun.w;
    // light level at the pixel: scene / albedo guess (the light pre-pass G-buffer has no
    // base colour)
    float light = dnLum(scene) / max(dnTyOpt.y, 0.01);
    float seed = wd.w;

    // --- coat (screen-space mud on the tyre) ---------------------------------------
    float coat = wd.y;
    float3 C2 = scene;
    float2 grad = 0;
    float cover = 0;
    if (dnTyOpt.z > 0.5 && coat > 0.0) {
        // coverage order: tread first, then the shoulders, the sidewalls down to the rim
        float side = saturate(abs(across) * 1.1 - 0.35);
        float order = 0.55 * (1.0 - radK) + 0.3 * side
                    + 0.35 * dnNoise(float2(ang * 6.0, across * 2.0) + seed)
                    + 0.2 * dnNoise(tc * 9.0 + seed * 3.1);
        cover = saturate((saturate(coat) * 1.2 - order) * 6.0);
        float3 c1 = dnCrumbs(tc / dnTyOpt.w + seed, 0.8);
        grad = c1.yz * 0.5 * cover;
        C2 = lerp(scene, unpackColor(wd.z) * light, cover);
    }

    // --- wet ---------------------------------------------------------------------------
    float wet = saturate(wd.x);
    float streak = dnNoise(float2(ang * 20.0 / 6.2832 * 6.0, across * 2.5) + seed * 1.7);
    float w = wet * (0.6 + 0.4 * streak);
    C2 *= 1.0 - dnTy.y * w;

    // relight with the coat lumps (tangent frame: along the tread, across)
    float3 tAng = cross(axle, nrW);
    float3 nt = normalize(n - (grad.x * tAng + grad.y * axle));
    float lit0 = amb + sh * saturate(dot(n, L));
    float lit1 = amb + sh * saturate(dot(nt, L));
    float ratio = clamp(lit1 / max(lit0, 1e-3), 0.3, 2.0);

    float3 V = normalize(eyePosWorld - wp);
    float3 H = normalize(L + V);
    float specP = lerp(20.0, 110.0, w);
    float spec = pow(saturate(dot(nt, H)), specP) * (specP + 8.0) / 25.0;
    float sunLight = clamp(light / max(lit0, 0.05), 0.0, 4.0);
    // grazing sheen: a water film mirrors the sky (Schlick, water F0 0.02); sky light taken
    // as the ambient share of the sun light, not shadowed
    float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(nt, V)), 5.0);
    float3 specAdd = sunLight * (sh * spec * dnTy.z * 0.04 + 0.5 * amb * fres) * w * float3(0.95, 0.98, 1.05);

    float3 outC = C2 * ratio + specAdd;
    return float4(outC, 1);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
