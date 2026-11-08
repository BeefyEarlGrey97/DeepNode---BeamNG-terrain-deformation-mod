// DeepNode road light: packs the engine's lighting at each pixel for the road passes
// (roadDrawP.hlsl, roads.mode 'shader') into #deepnode_roadLit: rgb = diffuse light
// (#lightinfo, the light pre-pass buffer every lit material reads), a = ambient occlusion
// (#gtaoOutput), as -1 - AO inside a vehicle footprint box (roadDrawP.hlsl leaves the road out
// there only above the road's own surface: the vehicle, not the ground it sank into). One pass instead of three texture
// slots in every road pass (a post effect has six).
// Runs at PFXBeforeBin ReflectDepthBin: #lightinfo holds there (it reads 0 by ObjTranslucentBin,
// where the road passes run, measured 2026-11-08).
// Vehicles (2026-11-08b): a pixel inside a tyre (a cylinder round the hub along the axle, from
// its hub nodes, 4 cm margin) is marked (a = -1 - AO) and gets no road. Footprint boxes (first with a
// height cap over the road, then a plane under the hubs) cut the road out in a rectangle where
// the ground in the box stood higher; vehicle bodies are left to roadDrawP's face tests.
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
    uniform float4 dnVehN;   // unused, AO bound (> 0.5), tyre count
    // tyres near the camera: hub xyz + radius (dnWh), unit axle xyz + half width (dnWa)
    uniform float4 dnWh0; uniform float4 dnWa0;
    uniform float4 dnWh1; uniform float4 dnWa1;
    uniform float4 dnWh2; uniform float4 dnWa2;
    uniform float4 dnWh3; uniform float4 dnWa3;
    uniform float4 dnWh4; uniform float4 dnWa4;
    uniform float4 dnWh5; uniform float4 dnWa5;
    uniform float4 dnWh6; uniform float4 dnWa6;
    uniform float4 dnWh7; uniform float4 dnWa7;
    uniform float4 dnWh8; uniform float4 dnWa8;
    uniform float4 dnWh9; uniform float4 dnWa9;
    uniform float4 dnWh10; uniform float4 dnWa10;
    uniform float4 dnWh11; uniform float4 dnWa11;
    uniform float4 dnWh12; uniform float4 dnWa12;
    uniform float4 dnWh13; uniform float4 dnWa13;
    uniform float4 dnWh14; uniform float4 dnWa14;
    uniform float4 dnWh15; uniform float4 dnWa15;
    uniform float4 dnWh16; uniform float4 dnWa16;
    uniform float4 dnWh17; uniform float4 dnWa17;
    uniform float4 dnWh18; uniform float4 dnWa18;
    uniform float4 dnWh19; uniform float4 dnWa19;
    uniform float4 dnWh20; uniform float4 dnWa20;
    uniform float4 dnWh21; uniform float4 dnWa21;
    uniform float4 dnWh22; uniform float4 dnWa22;
    uniform float4 dnWh23; uniform float4 dnWa23;
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

#define WHL(i)                                                                        \
    if (i < nw) {                                                                 \
        float3 c = wp - dnWh##i.xyz;                                                  \
        float a = dot(c, dnWa##i.xyz);                                                \
        float r = length(c - a * dnWa##i.xyz);                                        \
        if (abs(a) < dnWa##i.w + 0.04 && r < dnWh##i.w + 0.04) on = 1.0;            \
    }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float3 light = tex2Dlod(lightTex, float4(IN.uv0, 0, 0)).rgb;
    float ao = dnVehN.y > 0.5 ? tex2Dlod(aoTex, float4(IN.uv1, 0, 0)).r : 1.0;
    float d = tex2Dlod(depthTex, float4(IN.uv2, 0, 0)).r;
    float lin = realToEyeLinearDepth(ndcToRealDepth(d, projParams.zw), projParams);
    float3 wp = eyePosWorld + IN.wsEyeRay * lin;
    float on = 0.0;
    int nw = (int)dnVehN.z;
    WHL(0) WHL(1) WHL(2) WHL(3) WHL(4) WHL(5)
    WHL(6) WHL(7) WHL(8) WHL(9) WHL(10) WHL(11)
    WHL(12) WHL(13) WHL(14) WHL(15) WHL(16) WHL(17)
    WHL(18) WHL(19) WHL(20) WHL(21) WHL(22) WHL(23)
    ao = saturate(ao);
    return float4(light, on > 0.5 ? -1.0 - ao : ao);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
