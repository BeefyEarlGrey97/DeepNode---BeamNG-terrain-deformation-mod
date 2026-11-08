// DeepNode road look (roads.mode 'shader'): draws the decal roads DeepNode hides over soft
// ground from the road map (#deepnode_road, see roadStampP.hlsl) onto the surface the depth
// buffer shows, so a road follows the ruts dug into it. Two passes per road key (renderPriority
// + material, in the engine's draw order), each only where the map holds an entry of its key,
// so any number of roads may overlap (a texel keeps up to L entries):
//  * colour (dnLook.z 0): colour, opacity and AO maps in slots 3-5, blended over the scene by
//    the road's opacity, lit as the engine's decal colour pass (material/shadergen
//    permutations, BNG_COCONUT):
//      colour = albedo / PI x (diffuse light buffer + SH9 ambient x screen AO x material AO)
//    with the engine's own diffuse light buffer and screen AO (packed into #deepnode_roadLit by
//    roadLitP.hlsl, a < 0 = inside a vehicle box) and its sky SH9 (ambientSH9, set by the engine for every
//    post effect). Measured: the material AO maps matter (mud_water's averages 0.21).
//  * relight (dnLook.z 1): normal and opacity maps in slots 3-4; multiplies the scene (the road
//    and everything under it) by the light of the normal blended towards the road's normal by
//    its opacity over the light of the ground normal. The engine blends decal normals into the
//    G-buffer before lighting, so a decal's relief shows on the ground under it as well.
// A post effect has six texture slots: colour, opacity, normal and AO maps do not fit one pass.
// Only on surfaces at or below the road's own height (the ground before the ruts) plus a
// tolerance (not on kerbs), not on steep faces, not on vehicles (tyres and bodies marked by
// roadLitP.hlsl).
// Runs at PFXBeforeBin ObjTranslucentBin before the rut overlay (tyre prints, glass, particles
// and water draw over it); the light comes packed from ReflectDepthBin (roadLitP.hlsl).
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"
#include "shaders/common/sh.h.hlsl"
#include "dnCommon.h.hlsl"

uniform_sampler2D(depthTex, 0);
uniform_sampler2D(roadMap, 1);
uniform_sampler2D(litTex, 2);
uniform_sampler2D(mapTex3, 3); // colour map (colour pass) / normal map (relight pass)
uniform_sampler2D(opaTex, 4);
uniform_sampler2D(aoTex, 5);   // material AO map (colour pass)

#define DN_MAXL 8

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    uniform float3 sunDirection;
    uniform float4 ambientSH9[9];
    POSTFX_UNIFORMS
    uniform float4 dnWin;    // x0, y0, span, texels per side (W)
    uniform float4 dnZ;      // baseZ, tolerance above the road surface (m), depth below it (m), layers (L)
    uniform float4 dnPass;   // key, opacity map bound (> 0.5), normal map strength (0: none), debug view
    uniform float4 dnTint;   // material colour factor (rgb), opacity (colour factor alpha x opacityFactor)
    uniform float4 dnMat;    // metallic, roughness, relief (relight) strength, alpha gain
    uniform float4 dnLook;   // min ground normal z, window edge fade (m), pass (0 colour, 1 relight), AO map bound
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

// Anisotropic sample with explicit mip levels: SampleGrad on slots 4 and 5 returned the
// texture's smallest mip (its average) in game (2026-11-08) while SampleLevel reads right, and
// the post effect samplers are not anisotropic (one isotropic mip blurred the road at grazing
// angles next to the engine's decals). 4 taps along the footprint's long axis.
float4 sampleAniso(Texture2D t, SamplerState sm, float2 tc, float2 gx, float2 gy)
{
    uint w, h;
    t.GetDimensions(w, h);
    float2 ts = float2(w, h);
    float lx = length(gx * ts), ly = length(gy * ts);
    float2 major = lx > ly ? gx : gy;
    float lmaj = max(lx, ly), lmin = max(min(lx, ly), 1e-6);
    float n = clamp(lmaj / lmin, 1.0, 4.0);
    float lod = max(0.0, log2(max(lmaj / n, 1e-6)));
    float4 acc = 0;
    [unroll] for (int i = 0; i < 4; i++) acc += t.SampleLevel(sm, tc + major * ((i + 0.5) / 4.0 - 0.5) * (n > 1.0 ? 1.0 : 0.0), lod);
    return acc * 0.25;
}

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float dN = tex2Dlod(depthTex, float4(IN.uv0, 0, 0)).r;
    float lin = realToEyeLinearDepth(ndcToRealDepth(dN, projParams.zw), projParams);
    float3 wp = eyePosWorld + IN.wsEyeRay * lin;
    // screen derivatives before any discard
    float3 dpx = ddx(wp), dpy = ddy(wp);
    if (lin >= 0.99999) discard;
    float2 muv = (wp.xy - dnWin.xy) / dnWin.z;
    if (any(muv < 0.0) || any(muv > 1.0)) discard;
    int W = (int)dnWin.w;
    int2 ti = clamp((int2)floor(muv * dnWin.w), 0, W - 1);
    float2 dc = wp.xy - (dnWin.xy + (float2(ti) + 0.5) * (dnWin.z / dnWin.w));
    int L = clamp((int)dnZ.w, 1, DN_MAXL);
    float key = dnPass.x;
    int dbg = (int)(dnPass.w + 0.5);

    // entries of this pass's key at the texel
    // (entries fill from slot 0 without gaps, roadStampP.hlsl: stop at the first empty one)
    int hit[DN_MAXL];
    int nh = 0;
    bool more = true;
    [unroll] for (int j = 0; j < DN_MAXL; j++) {
        hit[j] = -1;
        if (more && j < L) {
            float a = roadMapTex.Load(int3(ti.x + 2 * j * W, ti.y, 0)).a;
            more = a > 0.5;
            if (more && abs(floor(a + 0.01) - key) < 0.5) { hit[nh] = j; nh++; }
        }
    }
    if (nh == 0) discard;
    float4 lit = tex2Dlod(litTex, float4(IN.uv2, 0, 0));
    // a vehicle pixel (tyre, or body above its cut height; roadLitP.hlsl): no road on it
    if (lit.a < 0.0) discard;
    float zTop = dnZ.y;

    float3 V = normalize(eyePosWorld - wp);
    // the face as seen (towards the camera): a face turned down (a bumper or sill underside
    // seen from low) is no ground, whatever its height
    float3 ng = normalize(cross(dpx, dpy));
    if (dot(ng, V) < 0.0) ng = -ng;
    if (ng.z < 0.0) discard;
    float slopeK = smoothstep(dnLook.x - 0.1, dnLook.x + 0.1, ng.z);
    float2 dEdge = min(muv, 1.0 - muv) * dnWin.z;
    float edgeK = saturate(min(dEdge.x, dEdge.y) / max(dnLook.y, 1e-3));
    ColorSH9 sh = getColorSH9(ambientSH9);

    bool relight = dnLook.z > 0.5;
    float3 Lg = lit.rgb + evalSHIrradiance(sh, ng) * lit.a;   // light of the ground (normal ng)
    float sg = saturate(dot(ng, sunDirection));
    float3 accC = 0;
    float accA = 0;
    float3 accM = 1;
    [unroll] for (int k = 0; k < DN_MAXL; k++) {
        if (k < nh) {
            int j = hit[k];
            float4 t0 = roadMapTex.Load(int3(ti.x + 2 * j * W, ti.y, 0));
            float4 t1 = roadMapTex.Load(int3(ti.x + (2 * j + 1) * W, ti.y, 0));
            float u = t0.g + dot(t1.rg, dc);
            float v = t0.r + dot(t1.ba, dc);
            float dz = wp.z - (dnZ.x + t0.b);
            if (u >= 0.0 && u <= 1.0 && dz <= zTop && dz >= -dnZ.z) {
                float fade = saturate((t0.a - floor(t0.a + 0.01)) / 0.49);
                // texture coordinates and their screen derivatives (analytic: no seams where v wraps)
                float2 tc = float2(u, v);
                float2 gx = float2(dot(t1.rg, dpx.xy), dot(t1.ba, dpx.xy));
                float2 gy = float2(dot(t1.rg, dpy.xy), dot(t1.ba, dpy.xy));
                float4 m3 = sampleAniso(mapTex3Tex, mapTex3_sampler_, tc, gx, gy);
                float op = dnPass.y > 0.5 ? sampleAniso(opaTexTex, opaTex_sampler_, tc, gx, gy).r
                                          : (relight ? 1.0 : m3.a);
                float zK = 1.0 - smoothstep(zTop * 0.6, zTop, dz);
                float alpha = saturate(op * dnTint.a * dnMat.w) * fade * slopeK * edgeK * zK;
                // 3: the light on an albedo of dnTint.rgb, opaque (light scale check against the terrain)
                if (dbg >= 3) alpha = 1.0;
                if (alpha > 0.002 && relight) {
                    // the ground normal blended towards the road's normal (u across, v along) by
                    // the road's opacity, as the engine's G-buffer blend
                    float2 nm = (m3.rg * 2.0 - 1.0) * dnPass.z;
                    float2 Tu = t1.rg / max(length(t1.rg), 1e-6);
                    float2 Tv = t1.ba / max(length(t1.ba), 1e-6);
                    float3 nr = normalize(ng + float3(nm.x * Tu + nm.y * Tv, 0.0) * saturate(ng.z));
                    float3 nb = normalize(lerp(ng, nr, alpha * dnMat.z));
                    float sb = saturate(dot(nb, sunDirection));
                    float ratio = sg > 0.02 ? clamp(sb / sg, 0.3, 2.0) : 1.0;
                    float3 Lb = lit.rgb * ratio + evalSHIrradiance(sh, nb) * lit.a;
                    accM *= clamp(Lb / max(Lg, 1e-4), 0.3, 2.0);
                } else if (alpha > 0.002) {
                    float3 alb = m3.rgb * dnTint.rgb;
                    float ao = dnLook.w > 0.5 ? sampleAniso(aoTexTex, aoTex_sampler_, tc, gx, gy).r : 1.0;
                    float3 E = lit.rgb + evalSHIrradiance(sh, ng) * lit.a * ao;
                    float met = saturate(dnMat.x);
                    float3 c = alb * (1.0 - met) / PI * E;
                    // reflection of the sky (SH9) for metallic / smooth roads (the wet mud_water)
                    float rough = saturate(dnMat.y);
                    float3 F0 = lerp(0.04, alb, met);
                    float fres = pow(1.0 - saturate(dot(ng, V)), 5.0);
                    float3 F = F0 + (max(1.0 - rough, F0) - F0) * fres;
                    c += evalSHIrradiance(sh, reflect(-V, ng)) / PI * F * (1.0 - rough) * lit.a * ao;
                    if (dbg == 1) c = float3(frac(u), frac(v), 0.0) * 5.0;
                    if (dbg == 2) c = 0.5 / PI * E;
                    if (dbg == 3) c = dnTint.rgb / PI * Lg;
                    // 4: opacity sample (red), opacity map bound (green)
                    if (dbg == 4) c = float3(op, dnPass.y * 0.2, 0.0);
                    // 6: height over the road's own surface: red < -0.5 m, yellow -0.5..-0.25,
                    // green -0.25..-0.1, blue -0.1..0.1, white above
                    if (dbg == 6) c = dz < -0.5 ? float3(1, 0, 0) : dz < -0.25 ? float3(1, 1, 0) : dz < -0.1 ? float3(0, 1, 0) : dz < 0.1 ? float3(0, 0, 1) : float3(1, 1, 1);
                    // 5: slots 4 / 5 / 3 read with SampleLevel (r, g, b)
                    if (dbg == 5) c = float3(opaTexTex.SampleLevel(opaTex_sampler_, tc, 0).r, aoTexTex.SampleLevel(aoTex_sampler_, tc, 0).r, m3.r);
                    // this layer over what the pass has so far
                    accC = c * alpha + accC * (1.0 - alpha);
                    accA = alpha + accA * (1.0 - alpha);
                }
            }
        }
    }
    // relight: multiplies the scene (blend dest colour x source)
    if (relight) {
        if (all(abs(accM - 1.0) < 0.002) || dbg > 0) discard;
        return float4(accM, 1);
    }
    if (accA <= 0.002) discard;
    return float4(accC / accA, accA);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
