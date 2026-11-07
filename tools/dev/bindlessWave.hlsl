// Probe: custom mesh shader on the bindless path (recipe of shaders/common/vehicle/ghost.hlsl).
// Opaque magenta, N.L shaded, vertices moved by a sine wave (accumTime) in the VS. Runs only under
// an engine-registered material name (docs/ENGINE_FINDINGS.md "Custom shaders").
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

#ifndef DN_WAVE
#define DN_WAVE 0.3
#endif

#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif

struct vertexVS {
    float4 pos : SV_POSITION;
    float3 normal : NORMAL;
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
    vertexVS outVtx;
    const uint2 instanceMeshId = getInstanceMeshId(instanceData);
    const float4x4 objectTrans = getInstanceTransform(instanceMeshId.x);
    const VertexIa inVtx = getVertexIA(vtxRaw_, vertexID);
    const float4x4 localTrans = getPrimData().localTrans;
    const float ph = accumTime * 2.0 + inVtx.pos.x * 2.0;
    float3 pos = inVtx.pos.xyz;
    pos.z += DN_WAVE * sin(ph);
    // wave normal (d z / d x = DN_WAVE * 2 cos)
    const float3 n = normalize(float3(-DN_WAVE * 2.0 * cos(ph), 0, 1));
    outVtx.normal = mul((float3x3)mul(objectTrans, localTrans), n);
    const float4x4 vtxToCameraPos0 = calculateVtxToCameraPos0(worldToCameraPos0, eyePosWorld, cameraRemainder, objectTrans, localTrans);
    outVtx.pos = mul(cameraToScreen, mul(vtxToCameraPos0, float4(pos, 1)));
    return outVtx;
}

PXOutput mainP(vertexVS inPxl) {
    PXOutput OUT;
    const float3 N = normalize(inPxl.normal);
    const float l = 0.35 + 0.65 * saturate(dot(N, normalize(float3(0.4, -0.3, 0.85))));
    OUT.out0 = float4(float3(1.0, 0.1, 0.8) * l, 1.0);
    return OUT;
}
