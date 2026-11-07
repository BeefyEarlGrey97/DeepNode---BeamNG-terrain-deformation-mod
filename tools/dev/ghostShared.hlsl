// Shares the engine's `vehicleGhost` custom-material slot (the only Lua-usable custom mesh shader
// slot, see docs/ENGINE_FINDINGS.md "Custom shaders") without changing the x-ray ghost: every
// vertex runs the stock shaders/common/vehicle/ghost.hlsl unchanged, except vertices whose first
// UV u is below DN_MARK_U (only DeepNode meshes write that), which take the DeepNode path.
#define main dn_ghost_main
#include "shaders/common/vehicle/ghost.hlsl"
#undef main

#define DN_MARK_U -500.0

#ifndef DN_WAVE
#define DN_WAVE 0.3
#endif

struct dnVS {
    float4 pos : SV_POSITION;
    float3 normal : NORMAL;
    float4 dn : TEXCOORD0; // w = 1 on DeepNode vertices
};

#ifdef SHADER_STAGE_VS
dnVS main(vertexIARAW vtxRaw_, svInstanceData instanceData, uint vertexID : SV_VertexID) {
    dnVS o;
    const uint2 instanceMeshId = getInstanceMeshId(instanceData);
    const VertexIa inVtx = getVertexIA(vtxRaw_, vertexID);
    [branch]
    if (inVtx.texCoords.x >= DN_MARK_U) {
        const vertexVS g = dn_ghost_main(vtxRaw_, instanceData, vertexID);
        o.pos = g.pos;
        o.normal = g.normal;
        o.dn = 0;
        return o;
    }
    const float4x4 objectTrans = getInstanceTransform(instanceMeshId.x);
    const float4x4 localTrans = getPrimData().localTrans;
    const float ph = accumTime * 2.0 + inVtx.pos.x * 2.0;
    float3 pos = inVtx.pos.xyz;
    pos.z += DN_WAVE * sin(ph);
    const float3 n = normalize(float3(-DN_WAVE * 2.0 * cos(ph), 0, 1));
    o.normal = mul((float3x3)mul(objectTrans, localTrans), n);
    const float4x4 vtxToCameraPos0 = calculateVtxToCameraPos0(worldToCameraPos0, eyePosWorld, cameraRemainder, objectTrans, localTrans);
    o.pos = mul(cameraToScreen, mul(vtxToCameraPos0, float4(pos, 1)));
    o.dn = float4(inVtx.texCoords.x - DN_MARK_U * 2.0, inVtx.texCoords.y, 0, 1);
    return o;
}
#else
PXOutput main(dnVS i) {
    [branch]
    if (i.dn.w < 0.5) {
        vertexVS g;
        g.pos = i.pos;
        g.normal = i.normal;
        return dn_ghost_main(g);
    }
    PXOutput OUT;
    const float3 N = normalize(i.normal);
    const float l = 0.35 + 0.65 * saturate(dot(N, normalize(float3(0.4, -0.3, 0.85))));
    OUT.out0 = float4(float3(1.0, 0.1, 0.8) * l, 1.0);
    return OUT;
}
#endif
