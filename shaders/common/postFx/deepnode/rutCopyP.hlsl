// DeepNode road map: copies the tmp map back into the map after a road stamp pass
// (roadStampP.hlsl; the rut map is stamped in place, rutStampC.cs.hlsl).
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"

uniform_sampler2D(srcMap, 0);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    return srcMapTex.Load(int3((int2)IN.hpos.xy, 0));
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
