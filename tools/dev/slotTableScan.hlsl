// Probe used 2026-11-11 (docs/ENGINE_FINDINGS.md "GPU height map for the own slot"). Needs a
// PostEffect writing DN_MAGIC into a 64x32 RGBA16F named target. Never set castShadows 1 on it.
// DeepNode probe: own slot (ShaderData "ParallaxInteriorShaderData") scans the legacy per-material
// texture table (materialTexture[32] at t14 materialSpace, as defaultMat.hlsl without MFT_Bindless:
// the slot's cached permutations have no MFT_Bindless) for the magic PostEffect target #dnH
// (64x32, texel 0 = DN_MAGIC). Mesh UV 0..1 is split into DN_GRID x DN_GRID cells; cell
// (cy * DN_GRID + cx) checks table slot DN_BASE + that index (>= 32: grey). Colours: red = magic,
// yellow = a 64x32 texture without the magic, green = some texture, blue = 0x0 (null) slot.
#define SHADERGEN_CUSTOM_MATERIAL_CBUFFER
#define MFT_MATERIAL_LAYER_COUNT 1

#include "shaders/common/material/shadergen/shadergen.h.hlsl"

#if defined(MFT_Bindless)
    #include "shaders/common/material/shadergen/bindlessArena.h.hlsl"
#else
    Texture2D dnTable[32] : REGISTER(t14, materialSpace);
    cspPrimitiveBuffer_t getPrimData() { return cspPrimBuffer; }
#endif

MaterialUniforms getMaterialData() { return (MaterialUniforms)0; }

#include "shaders/common/material/shadergen/materialDrawId.h.hlsl"

#ifndef DN_GRID
#define DN_GRID 8
#endif
#ifndef DN_BASE
#define DN_BASE 0
#endif
#define DN_MAGIC float3(0.875, 0.0625, 0.5625)

#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif

struct vertexVS {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
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
    const float4x4 vtxToCameraPos0 = calculateVtxToCameraPos0(worldToCameraPos0, eyePosWorld, cameraRemainder, objectTrans, localTrans);
    o.pos = mul(cameraToScreen, mul(vtxToCameraPos0, float4(inVtx.pos.xyz, 1)));
    o.uv = inVtx.texCoords.xy;
    return o;
}

PXOutput mainP(vertexVS i) {
    PXOutput OUT;
    const uint2 cell = min((uint2)(saturate(i.uv) * DN_GRID), DN_GRID - 1);
    const float chk = ((cell.x + cell.y) & 1) ? 1.0 : 0.75;
    float3 c = float3(0.5, 0.5, 0.5);
#if !defined(MFT_Bindless)
    const uint idx = DN_BASE + cell.y * DN_GRID + cell.x;
    if (idx < 32) {
        Texture2D t = dnTable[NonUniformResourceIndex(idx)];
        uint w, h;
        t.GetDimensions(w, h);
        c = (w > 0 && h > 0) ? float3(0, 0.6, 0) : float3(0.1, 0.1, 0.8);
        if (w == 64 && h == 32) {
            c = float3(1, 1, 0);
            if (all(abs(t.Load(int3(0, 0, 0)).rgb - DN_MAGIC) < 0.002)) c = float3(1, 0, 0);
        }
    }
#endif
    OUT.out0 = float4(c * chk, 1.0);
    return OUT;
}
