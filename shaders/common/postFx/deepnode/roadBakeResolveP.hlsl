// DeepNode baked road layer: accumulators of roadBakeP.hlsl -> the five images of one tile, each
// saved to PNG by a named-buffer screenshot (deepnode/roadBake.lua). The mud material reads them as a
// detail-only layer, which doubles every value (colour = saturate(2 x), opacity = saturate(2 x), ...),
// so the images hold value / 2.
// mode 0: colour = sRGB(C / A / 2)        (*.color.png: the engine cooks it to BC7 sRGB)
// mode 1: opacity = A / 2
// mode 2: normal = (n.x, -n.y, z) encoded (the generic normal decode flips y back)
// mode 3: roughness = R / A / 2; mode 4: metallic = M / A / 2
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"

uniform_sampler2D(accA, 0);
uniform_sampler2D(accB, 1);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnCtl;  // mode
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float3 toSrgb(float3 c) { return select(c <= 0.0031308, c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055); }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    int3 q = int3((int2)IN.hpos.xy, 0);
    float4 a = accATex.Load(q);
    float4 b = accBTex.Load(q);
    float A = a.a;
    float inv = A > 1e-4 ? 1.0 / A : 0.0;
    float mode = dnCtl.x;
    if (mode < 0.5) return float4(toSrgb(saturate(a.rgb * inv * 0.5)), 1);
    if (mode < 1.5) return float4(A.xxx * 0.5, 1);
    if (mode < 2.5) {
        // accumulated over zero: n = (enc - 0.5 A) / A
        float2 n = (b.rg - 0.5 * A) * inv * 2.0;
        float z = sqrt(saturate(1.0 - dot(n, n)));
        return float4(n.x * 0.5 + 0.5, -n.y * 0.5 + 0.5, z * 0.5 + 0.5, 1);
    }
    if (mode < 3.5) return float4(saturate(b.bbb * inv * 0.5), 1);
    return float4(saturate(b.aaa * inv * 0.5), 1);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
