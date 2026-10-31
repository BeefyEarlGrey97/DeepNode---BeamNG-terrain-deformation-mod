// DeepNode road look: draws the decal roads DeepNode hides over soft ground from the road map
// (#deepnode_road, see roadStampP.hlsl) onto the surface the depth buffer shows, so a road
// follows the mud ruts dug into it. One pass per road material (deepnode/overlay.lua): the
// material's colour, opacity and normal maps sit in slots 3-5 (a post effect has 6 slots), and
// the pass only touches pixels whose map texel holds a road of its slot.
// Runs after the opaque scene is lit (PFXBeforeBin ObjTranslucentBin), before the rut overlay
// (rutOverlayP.hlsl), so tyre prints draw over the road. The road colour replaces the ground
// colour on the lit scene colour: light = scene / ground albedo (the ground under the roads,
// from Lua), relit with the road's normal map against the depth-buffer normal.
// Only on surfaces at or below the road's own height (the ground before the ruts) plus a
// tolerance: not on kerbs, walkways or vehicles standing over the road (vehicle footprint
// boxes above the tyre bottoms are left out as well), nor on steep faces.
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"
#include "dnCommon.h.hlsl"

uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(depthTex, 1);
uniform_sampler2D(roadMap, 2);
uniform_sampler2D(colTex, 3);
uniform_sampler2D(opaTex, 4);
uniform_sampler2D(nrmTex, 5);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnWin;    // x0, y0, span, texels per layer side (W; the map is 2W x W: top layer, lower layer)
    uniform float4 dnZ;      // baseZ, tolerance above the road surface (m), depth below it (m), max |du| per m (1 / narrowest road)
    uniform float4 dnPass;   // material slot, opacity map bound (> 0.5), normal map strength (0: none), debug view
    uniform float4 dnTint;   // material colour factor (rgb), opacity factor (x colour factor alpha)
    uniform float4 dnMat;    // metallic, gloss (sky reflection weight), unused, unused
    uniform float4 dnSun;    // direction to the sun (xyz), ambient share
    uniform float4 dnGround; // ground albedo under the roads (linear rgb), colour map is sRGB (> 0.5)
    uniform float4 dnUV;     // swap u / v (> 0.5), flip u, flip v, max |dv| per m (1 / shortest texture length)
    uniform float4 dnLook;   // min ground normal z, window edge fade (m), relief (relight) strength, alpha gain
    // vehicle footprints (no road on them): centre xy, half length, half width; forward xy in
    // dnVehD (two per register); lowest point z in dnVehZ (four per register); count in dnVehN.x
    uniform float4 dnVehN;
    uniform float4 dnVeh0;
    uniform float4 dnVeh1;
    uniform float4 dnVeh2;
    uniform float4 dnVeh3;
    uniform float4 dnVeh4;
    uniform float4 dnVeh5;
    uniform float4 dnVeh6;
    uniform float4 dnVeh7;
    uniform float4 dnVehD0;
    uniform float4 dnVehD1;
    uniform float4 dnVehD2;
    uniform float4 dnVehD3;
    uniform float4 dnVehZ0;
    uniform float4 dnVehZ1;
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif


float wrap1(float d)
{
    return d - round(d);
}

// 1 where the pixel belongs to a vehicle: inside its footprint and above its lowest point
// (+ 0.15 m: the ground under a sunk tyre stays road)
#define VEH(i, D, Z)                                                                    \
    if (i < nv) {                                                                       \
        float2 c = wp.xy - dnVeh##i.xy;                                                 \
        float2 f = D;                                                                   \
        float2 q = float2(abs(dot(c, f)), abs(dot(c, float2(-f.y, f.x))));              \
        if (q.x < dnVeh##i.z && q.y < dnVeh##i.w && wp.z > Z + 0.15) on = 1.0;           \
    }
float onVehicle(float3 wp)
{
    int nv = (int)dnVehN.x;
    float on = 0.0;
    VEH(0, dnVehD0.xy, dnVehZ0.x) VEH(1, dnVehD0.zw, dnVehZ0.y) VEH(2, dnVehD1.xy, dnVehZ0.z)
    VEH(3, dnVehD1.zw, dnVehZ0.w) VEH(4, dnVehD2.xy, dnVehZ1.x) VEH(5, dnVehD2.zw, dnVehZ1.y)
    VEH(6, dnVehD3.xy, dnVehZ1.z) VEH(7, dnVehD3.zw, dnVehZ1.w)
    return on;
}

// sky colour for reflections: mean of a few points near the top of the screen that show sky
// (far depth); w = how many did
float4 skyColour()
{
    float4 acc = 0;
    [unroll] for (int i = 0; i < 4; i++) {
        float2 su = float2(0.12 + 0.25 * i, 0.04 + 0.02 * (i & 1));
        float d = tex2Dlod(depthTex, float4(su, 0, 0)).r;
        float l = realToEyeLinearDepth(ndcToRealDepth(d, projParams.zw), projParams);
        if (l >= 0.99999) acc += float4(tex2Dlod(sceneTex, float4(su, 0, 0)).rgb, 1);
    }
    return acc.w > 0.0 ? float4(acc.rgb / acc.w, acc.w) : float4(0, 0, 0, 0);
}

// one layer of the road map at muv (layer 0: top road, 1: the road under it; side by side)
struct Lay
{
    float u, v, zr, id, fade;
};
Lay readLayer(float2 muv, int layer)
{
    int W = (int)dnWin.w;
    int2 ti = clamp((int2)floor(muv * dnWin.w), 0, W - 1);
    float4 rp = roadMapTex.Load(int3(ti.x + layer * W, ti.y, 0));
    // filtered sample inside the layer's half (clamped half a texel from its edges)
    float hx = 0.5 / dnWin.w;
    float2 fu = float2((clamp(muv.x, hx, 1.0 - hx) + layer) * 0.5, muv.y);
    float4 r = tex2Dlod(roadMap, float4(fu, 0, 0));
    // filtered values next to another road (or empty texels) or across the wrap of v are no
    // valid position: point values there
    Lay l;
    l.v = abs(r.r - rp.r) > 0.25 ? rp.r : r.r;
    l.u = abs(r.b - rp.b) > 0.25 ? rp.b : r.b;
    // height: point value (the filtered one blends with empty texels' 0 at a road's edge and
    // dropped pixels there in thin lines; the ground slope over one texel is small)
    l.zr = rp.g;
    l.id = floor(rp.a + 0.01);
    l.fade = saturate((rp.a - l.id) / 0.49);
    return l;
}

// shared per pixel
struct Px
{
    float3 wp, dpx, dpy, ng, L, light;
    float amb, slopeK, edgeK;
};

// this material's colour and alpha for one layer; alpha 0 when the layer holds another material,
// lies outside the road or off the road's height band. du, dv = screen derivatives of u, v.
float4 shadeLayer(Lay l, float2 du, float2 dv, Px X, out float dzOut)
{
    dzOut = 0.0;
    if (l.id < 0.5) return 0;
    float slot = fmod(l.id - 1.0, 8.0);
    if (abs(slot - dnPass.x) > 0.5) return 0;
    if (l.u < 0.0 || l.u > 1.0) return 0;
    // height over the road surface: ruts below it, berms a little above; kerbs and objects higher
    float dz = X.wp.z - (dnZ.x + l.zr);
    dzOut = dz;
    if (dz > dnZ.y || dz < -dnZ.z) return 0;

    float tu = l.u, tv = l.v - floor(l.v);
    float2 g0 = float2(du.x, dv.x), g1 = float2(du.y, dv.y);
    if (dnUV.y > 0.5) { tu = 1.0 - tu; g0.x = -g0.x; g1.x = -g1.x; }
    if (dnUV.z > 0.5) { tv = 1.0 - tv; g0.y = -g0.y; g1.y = -g1.y; }
    float2 tc = float2(tu, tv);
    if (dnUV.x > 0.5) { tc = tc.yx; g0 = g0.yx; g1 = g1.yx; }

    float4 col = colTexTex.SampleGrad(colTex_sampler_, tc, g0, g1);
    float3 alb = dnGround.w > 0.5 ? pow(abs(col.rgb), 2.2) : col.rgb;
    alb *= dnTint.rgb;
    float op = dnPass.y > 0.5 ? opaTexTex.SampleGrad(opaTex_sampler_, tc, g0, g1).r : col.a;
    float zK = 1.0 - smoothstep(dnZ.y * 0.6, dnZ.y, dz);
    float alpha = saturate(op * dnTint.a * dnLook.w) * l.fade * X.slopeK * X.edgeK * zK;
    if (alpha <= 0.002) return 0;

    // relief from the road's normal map, in the frame of the road (u across, v along)
    float3 nrm = X.ng;
    if (dnPass.z > 0.0) {
        float2 nm = nrmTexTex.SampleGrad(nrmTex_sampler_, tc, g0, g1).rg * 2.0 - 1.0;
        float2 gu = dnWorldGrad(du.x, du.y, X.dpx.xy, X.dpy.xy);
        float2 gv = dnWorldGrad(dv.x, dv.y, X.dpx.xy, X.dpy.xy);
        float2 Tu = gu / max(length(gu), 1e-6);
        float2 Tv = gv / max(length(gv), 1e-6);
        if (dnUV.x > 0.5) { float2 tmp = Tu; Tu = Tv; Tv = tmp; }
        float2 tilt = (nm.x * Tu + nm.y * Tv) * dnPass.z;
        nrm = normalize(X.ng + float3(tilt, 0.0) * saturate(X.ng.z));
    }
    float lit0 = X.amb + saturate(dot(X.ng, X.L));
    float lit1 = X.amb + saturate(dot(nrm, X.L));
    float ratio = lerp(1.0, clamp(lit1 / max(lit0, 1e-3), 0.4, 1.8), dnLook.z);

    // metallic share: less diffuse, a reflection (the wet mud_water decal)
    float met = saturate(dnMat.x);
    float3 outC = alb * (1.0 - met) * X.light * ratio;
    if (dnMat.y > 0.0) {
        // sky reflection, Fresnel on a softened normal (per-pixel bumps spike it)
        float3 V = normalize(eyePosWorld - X.wp);
        float3 nr = normalize(lerp(float3(0, 0, 1), nrm, 0.35));
        float F0 = 0.04 + 0.2 * met;
        float fres = F0 + (1.0 - F0) * pow(1.0 - saturate(dot(nr, V)), 5.0);
        // the sampled sky (8 texture reads) only for really glossy roads (mud_water); the
        // slight wet gloss of mud uses the estimate from the light level
        float4 sk = dnMat.y > 0.25 ? skyColour() : float4(0, 0, 0, 0);
        float3 sky = sk.w > 0.0 ? sk.rgb : dnLum(X.light) * X.amb * 1.2 * float3(0.7, 0.82, 1.0);
        outC += sky * fres * saturate(dnMat.y);
    }
    return float4(outC, alpha);
}

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float dN = tex2Dlod(depthTex, float4(IN.uv0, 0, 0)).r;
    float lin = realToEyeLinearDepth(ndcToRealDepth(dN, projParams.zw), projParams);
    Px X;
    X.wp = eyePosWorld + IN.wsEyeRay * lin;
    float2 muv = (X.wp.xy - dnWin.xy) / dnWin.z;
    Lay l0 = readLayer(muv, 0);
    Lay l1 = readLayer(muv, 1);

    // screen derivatives before any discard
    X.dpx = ddx(X.wp);
    X.dpy = ddy(X.wp);
    float2 du0 = float2(ddx(l0.u), ddy(l0.u)), dv0 = float2(wrap1(ddx(l0.v)), wrap1(ddy(l0.v)));
    float2 du1 = float2(ddx(l1.u), ddy(l1.u)), dv1 = float2(wrap1(ddx(l1.v)), wrap1(ddy(l1.v)));
    // where the point value replaces the filtered one (next to another road) the screen
    // derivatives jump and picked a blurred mip in thin stair-step lines: at most the pixel
    // footprint over the narrowest road (u) / the shortest texture length (v)
    float foot = max(length(X.dpx), length(X.dpy));
    float capU = foot * dnZ.w, capV = foot * dnUV.w;
    du0 = clamp(du0, -capU, capU); du1 = clamp(du1, -capU, capU);
    dv0 = clamp(dv0, -capV, capV); dv1 = clamp(dv1, -capV, capV);

    if (lin >= 0.99999) discard;
    if (any(muv < 0.0) || any(muv > 1.0)) discard;
    if (l0.id < 0.5 && l1.id < 0.5) discard;
    if (onVehicle(X.wp) > 0.5) discard;

    X.ng = normalize(cross(X.dpx, X.dpy));
    if (X.ng.z < 0.0) X.ng = -X.ng;
    X.slopeK = smoothstep(dnLook.x - 0.1, dnLook.x + 0.1, X.ng.z);
    // fade out near the map window's edge (no hard cut where the window ends)
    float2 dEdge = min(muv, 1.0 - muv) * dnWin.z;
    X.edgeK = saturate(min(dEdge.x, dEdge.y) / max(dnLook.y, 1e-3));
    X.L = normalize(dnSun.xyz);
    X.amb = dnSun.w;
    float3 scene = tex2Dlod(sceneTex, float4(IN.uv0, 0, 0)).rgb;
    // light on the ground: the scene colour over the ground albedo under the roads
    X.light = scene / max(dnGround.rgb, 0.02);

    int dbg = (int)(dnPass.w + 0.5);
    // debug 1: u (red), v (green), slot (blue) of the top layer
    if (dbg == 1) {
        if (abs(fmod(l0.id - 1.0, 8.0) - dnPass.x) > 0.5) discard;
        return float4(l0.u, l0.v - floor(l0.v), (fmod(l0.id - 1.0, 8.0) + 1.0) / 8.0, 1);
    }
    float dz0, dz1;
    float4 s1 = shadeLayer(l1, du1, dv1, X, dz1);
    float4 s0 = shadeLayer(l0, du0, dv0, X, dz0);
    // 2: alpha of both layers (red top, green lower); 3: height over the top road surface
    if (dbg == 2) return float4(s0.a, s1.a, 0, 1);
    if (dbg == 3) return float4(saturate(-dz0 * 4.0), saturate(dz0 * 10.0), 0, 1);
    if (s0.a <= 0.0 && s1.a <= 0.0) discard;
    float3 c = lerp(scene, s1.rgb, s1.a);
    c = lerp(c, s0.rgb, s0.a);
    return float4(c, 1);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
