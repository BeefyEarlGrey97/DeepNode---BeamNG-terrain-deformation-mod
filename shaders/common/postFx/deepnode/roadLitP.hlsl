// DeepNode road light: packs the engine's lighting at each pixel for the road passes
// (roadDrawP.hlsl, roads.mode 'shader') into #deepnode_roadLit: rgb = diffuse light
// (#lightinfo, the light pre-pass buffer every lit material reads), a = ambient occlusion
// (#gtaoOutput), as -1 - AO inside a vehicle footprint box (roadDrawP.hlsl leaves the road out
// there only above the road's own surface: the vehicle, not the ground it sank into). One pass instead of three texture
// slots in every road pass (a post effect has six).
// Runs at PFXBeforeBin ReflectDepthBin: #lightinfo holds there (it reads 0 by ObjTranslucentBin,
// where the road passes run, measured 2026-11-08).
// Vehicles: footprint boxes (centre xy, half length, half width; forward xy in dnVehD, two
// per register; lowest point z in dnVehZ, four per register, unused). Testing the height
// against the lowest tyre point cut a box out of the road round a sunk vehicle (2026-11-08).
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"

uniform_sampler2D(lightTex, 0);
uniform_sampler2D(aoTex, 1);
uniform_sampler2D(depthTex, 2);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnVehN;   // vehicle count, AO bound (> 0.5)
    uniform float4 dnVeh0; uniform float4 dnVeh1; uniform float4 dnVeh2; uniform float4 dnVeh3;
    uniform float4 dnVeh4; uniform float4 dnVeh5; uniform float4 dnVeh6; uniform float4 dnVeh7;
    uniform float4 dnVehD0; uniform float4 dnVehD1; uniform float4 dnVehD2; uniform float4 dnVehD3;
    uniform float4 dnVehZ0; uniform float4 dnVehZ1;
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

#define VEH(i, D, Z)                                                                    \
    if (i < nv) {                                                                       \
        float2 c = wp.xy - dnVeh##i.xy;                                                 \
        float2 f = D;                                                                   \
        float2 q = float2(abs(dot(c, f)), abs(dot(c, float2(-f.y, f.x))));              \
        if (q.x < dnVeh##i.z && q.y < dnVeh##i.w) on = 1.0;                              \
    }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float3 light = tex2Dlod(lightTex, float4(IN.uv0, 0, 0)).rgb;
    float ao = dnVehN.y > 0.5 ? tex2Dlod(aoTex, float4(IN.uv1, 0, 0)).r : 1.0;
    float d = tex2Dlod(depthTex, float4(IN.uv2, 0, 0)).r;
    float lin = realToEyeLinearDepth(ndcToRealDepth(d, projParams.zw), projParams);
    float3 wp = eyePosWorld + IN.wsEyeRay * lin;
    int nv = (int)dnVehN.x;
    float on = 0.0;
    VEH(0, dnVehD0.xy, dnVehZ0.x) VEH(1, dnVehD0.zw, dnVehZ0.y) VEH(2, dnVehD1.xy, dnVehZ0.z)
    VEH(3, dnVehD1.zw, dnVehZ0.w) VEH(4, dnVehD2.xy, dnVehZ1.x) VEH(5, dnVehD2.zw, dnVehZ1.y)
    VEH(6, dnVehD3.xy, dnVehZ1.z) VEH(7, dnVehD3.zw, dnVehZ1.w)
    ao = saturate(ao);
    return float4(light, on > 0.5 ? -1.0 - ao : ao);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
