// DeepNode test: own slot (ShaderData "ParallaxInteriorShaderData") + texture input.
// VS lifts each vertex by texture R (1.2 m), PS shows texture G as a green/grey checker.
#define SHADERGEN_CUSTOM_MATERIAL_CBUFFER
#define MFT_MATERIAL_LAYER_COUNT 1

#include "shaders/common/material/shadergen/shadergen.h.hlsl"

#if defined(MFT_Bindless)
    #include "shaders/common/material/shadergen/bindlessArena.h.hlsl"
#else
    cspPrimitiveBuffer_t getPrimData() { return cspPrimBuffer; }
#endif

MaterialUniforms getMaterialData() { return (MaterialUniforms)0; }

#include "shaders/common/material/shadergen/materialDrawId.h.hlsl"

uniform_sampler2D(dnTex, 0);

#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif

struct vertexVS {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
    float h : TEXCOORD1;
};

struct PXOutput {
    float4 out0 : SV_Target0;
};

float4x4 calculateVtxToCameraPos0(float4x4 worldToCamPos0, float3 camOffset, float3 camRemainder, float4x4 localToWorld, float4x4 vtxToLocal) {
    const float4x4 localToWorldPos0 = subMatrixPosition(subMatrixPosition(localToWorld, camOffset), camRemainder);
    const float4x4 localToCameraPos0 = mul(worldToCamPos0, localToWorldPos0);
    return mul(localToCameraPos0, vtxToLocal);
}

vertexVS mainV(vertexIARAW vtxRaw_, svInstanceData instanceData, uint vertexID : SV_VertexID) {
    vertexVS o;
    const uint2 instanceMeshId = getInstanceMeshId(instanceData);
    const float4x4 objectTrans = getInstanceTransform(instanceMeshId.x);
    const VertexIa inVtx = getVertexIA(vtxRaw_, vertexID);
    const float4x4 localTrans = getPrimData().localTrans;
    const float2 uv = inVtx.texCoords.xy;
    const float h = dnTexTex.SampleLevel(dnTex_sampler_, uv, 0).r;
    float3 pos = inVtx.pos.xyz;
    pos.z += 1.2 * h;
    const float4x4 vtxToCameraPos0 = calculateVtxToCameraPos0(worldToCameraPos0, eyePosWorld, cameraRemainder, objectTrans, localTrans);
    o.pos = mul(cameraToScreen, mul(vtxToCameraPos0, float4(pos, 1)));
    o.uv = uv;
    o.h = h;
    return o;
}

PXOutput mainP(vertexVS i) {
    PXOutput OUT;
    const float3 t = dnTexTex.Sample(dnTex_sampler_, i.uv).rgb;
    // blue = no texture data (both channels 0), else checker from G plus red where lifted
    const float3 c = (t.g + t.r) < 0.01 ? float3(0.1, 0.2, 1.0) : float3(0.3 + 0.7 * i.h, t.g, 0.15);
    OUT.out0 = float4(c, 1.0);
    return OUT;
}
