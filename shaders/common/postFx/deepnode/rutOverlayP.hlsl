// DeepNode rut overlay: tyre prints on the ground where the rut map (#deepnode_rut, see
// rutStampP.hlsl) holds them. Runs after the opaque scene is lit (PFXBeforeBin
// ObjTranslucentBin) and rewrites the scene colour (read from $backBuffer):
//  * tread relief pressed into the print (lug height field, filtered by the pixel footprint)
//    and granular crumbs on the berms beside it and in the print, relit with the sun:
//    ratio of (ambient + sun x shadow x N.L) for the new and the G-buffer normal; the
//    engine's screen shadow mask (#sunShadowMask) keeps shadowed ground flat;
//  * surface colour per kind, worked on the lit scene colour (the renderer is light
//    pre-pass: the G-buffer holds no base colour, #prepass[RT1] is not albedo): churned wet
//    mud darker and more saturated, damp sand, mud and sand dust carried onto hard ground by
//    coated tyres as a tinted stain (tread-shaped, breaking up as the coat runs out);
//  * a wet sheen: sun highlight on the wet mud, its light level estimated from the scene.
// Fog and translucent objects draw over it afterwards.
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"
#include "dnCommon.h.hlsl"

// scene colour ($backBuffer) in slot 0, as in the engine's own post effects
uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(rutMap, 3);
uniform_sampler2D(shadowTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnWin;     // x0, y0, span, baseZ
    uniform float4 dnSun;     // direction to the sun (xyz), ambient share (w)
    uniform float4 dnTread;   // lugs per metre, chevron, press depth (m), lug width (0..1)
    uniform float4 dnLook;    // strength, fade start (m), fade length (m), sun highlight strength
    uniform float4 dnMask;    // z tolerance (m), min ground normal z, debug mode, texels per side
    uniform float4 dnOpt;     // use shadow mask, ground albedo guess (sun highlight level), groove darkening, berm z tolerance (m)
    uniform float4 dnMud;     // wet darkening, saturation gain, wetness, berm crumb density
    uniform float4 dnSand;    // same for sand
    uniform float4 dnCarry;   // mud carried onto hard ground: tint colour (rgb), opacity
    uniform float4 dnDust;    // sand dust on hard ground: tint colour (rgb), opacity
    uniform float4 dnCarryG;  // brightness gain of the mud stain, of the dust, unused, unused
    uniform float4 dnGrain;   // crumb size (m), crumb height (x size), print crumb density, churn noise size (m)
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

#define PHASE_WRAP 64.0

// phase difference across the PHASE_WRAP seam
float wrapDiff(float d)
{
    return d - PHASE_WRAP * round(d / PHASE_WRAP);
}

// lug profile along the tread: 1 on a lug, 0 in a groove; flanks soften with the pixel
// footprint (a pre-filter: no thin aliased lines at a distance)
float lugP(float s, float soft)
{
    float f = frac(s);
    float w = dnTread.w;
    return smoothstep(0.0, soft, f) * (1.0 - smoothstep(w, w + soft, f));
}

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float4 g = decodeGBuffer(TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), IN.uv0, projParams);
    float3 wp = eyePosWorld + IN.wsEyeRay * g.w;
    float2 uv = (wp.xy - dnWin.xy) / dnWin.z;
    float4 r = tex2Dlod(rutMap, float4(uv, 0, 0));
    int2 ti = clamp((int2)floor(uv * dnMask.w), 0, (int)dnMask.w - 1);
    float4 rp = rutMapTex.Load(int3(ti, 0));
    float kindF = round(rp.a / 4.0);
    float lat = clamp(r.a - 4.0 * kindF, -2.0, 2.0);
    // phase: interpolated, except next to the wrap seam (point value there)
    float phase = abs(wrapDiff(r.g - rp.g)) > 1.0 ? rp.g : r.g;
    // chevron lugs: the phase shifts with the distance from the tyre centre line
    float s = phase + abs(lat) * dnTread.y;

    // screen derivatives, taken before any branch or discard
    float3 dpx = ddx(wp);
    float3 dpy = ddy(wp);
    float dsx = wrapDiff(ddx(s));
    float dsy = wrapDiff(ddy(s));

    if (g.w >= 0.99999) discard;
    float3 scene = tex2Dlod(sceneTex, float4(IN.uv0, 0, 0)).rgb;
    float3 n = g.xyz;
    float3 L = normalize(dnSun.xyz);
    float amb = dnSun.w;
    float sh = 1.0;
    if (dnOpt.x > 0.5) {
        uint mw, mh;
        shadowTexTex.GetDimensions(mw, mh);
        int2 mp = clamp((int2)(IN.uv0 * float2(mw, mh)), int2(0, 0), int2(mw, mh) - 1);
        sh = saturate(shadowTexTex.Load(int3(mp, 0)).r);
    }
    int dbg = (int)(dnMask.z + 0.5);
    // debug 1: sun term of the G-buffer normal over the whole screen (checks dnSun)
    if (dbg == 1) return float4(scene * (amb + sh * saturate(dot(n, L))) / (amb + 1.0), 1);
    // debug 3: screen shadow mask
    if (dbg == 3) return float4(sh.xxx, 1);

    if (any(uv < 0.0) || any(uv > 1.0)) discard;
    if (rp.r <= 0.0 && r.r < 0.01) discard;
    int kind = (int)kindF;
    bool berm = abs(lat) > 1.0;
    bool carried = kind >= 2;
    // pixels far from the print height belong to something else (vehicles); berms stand
    // above the tyre bottom by the rut depth
    float dz = wp.z - (dnWin.w + rp.b);
    if (dz < -dnMask.x || dz > (berm ? dnOpt.w : dnMask.x)) discard;
    // geometric ground slope from the depth buffer (the G-buffer normal carries the
    // material's normal map: its bumps punched holes into the prints): fade, no cut
    float3 ng = normalize(cross(dpx, dpy));
    if (ng.z < 0.0) ng = -ng;
    float slopeK = smoothstep(dnMask.y - 0.1, dnMask.y + 0.1, ng.z);

    float str = saturate(r.r);
    // debug 2: coverage (red print, blue berm, green carried)
    if (dbg == 2) {
        float3 c = berm ? float3(0.4, 0.4, 1.6) : (carried ? float3(0.4, 1.6, 0.4) : float3(1.6, 0.4, 0.4));
        return float4(scene * lerp(1.0, c, str * slopeK), 1);
    }

    float dist = length(wp - eyePosWorld);
    float fade = 1.0 - saturate((dist - dnLook.y) / max(dnLook.z, 1e-3));
    float k = saturate(str * dnLook.x * fade * slopeK);
    if (k <= 0.002) discard;

    float pixM = max(length(dpx), length(dpy));
    float2 wf = dnFold(wp.xy);
    float4 K = kind == 1 || kind == 3 ? dnSand : dnMud;

    // --- tread height field (inside the print) --------------------------------------
    float fp = length(float2(dsx, dsy));            // lug phase per pixel
    float2 gs = dnWorldGrad(dsx, dsy, dpx.xy, dpy.xy); // lug phase per metre
    float soft = clamp(fp * 1.5, 0.08, 0.45);
    float tf = berm ? 0.0 : 1.0 - smoothstep(0.3, 0.7, fp);
    float edgeFade = 1.0 - smoothstep(0.75, 1.0, abs(lat));
    float lug = lugP(s, soft);
    float e = 0.03;
    float dlug = (lugP(s + e, soft) - lugP(s - e, soft)) / (2.0 * e);
    // carried mud sits on top of the hard ground (thin, raised); prints are pressed in
    float press = carried ? -0.004 : dnTread.z;
    float2 grad = -press * dlug * tf * edgeFade * gs;
    // debug 6: tread terms (red lug x filter, green filter, blue |lat| / 2)
    if (dbg == 6) return float4(lug * tf, tf, abs(lat) * 0.5, 1);

    // --- granular crumbs (berms, print edges; fine grains in sand) -------------------
    float cs = dnGrain.x * (kind == 1 ? 0.6 : 1.0);
    float crumbK = 0.0;
    float crumbSh = 0.0; // share of the sun a lump next to the pixel blocks (its cast shadow)
    if (!carried) {
        float bermW = berm ? saturate(2.0 - abs(lat)) * saturate((abs(lat) - 1.0) * 6.0) : 0.0;
        float dens = berm ? K.w * bermW : dnGrain.z * (0.4 + 0.6 * smoothstep(0.5, 1.0, abs(lat)));
        float cf = 1.0 - smoothstep(0.25, 0.7, pixM / cs);
        if (dens > 0.0 && cf > 0.0) {
            float3 c1 = dnCrumbs(wf / cs, dens);
            float3 c2 = dnCrumbs(wf / (cs * 0.5) + 31.7, dens * 0.8);
            float hc = dnGrain.y;
            grad += (c1.yz * hc + c2.yz * hc * 0.7) * cf;
            crumbK = saturate((c1.x + c2.x) * 2.0) * cf;
            // cast shadow: a taller lump a little towards the sun; longer when the sun is low
            float2 ls = L.xy / max(length(L.xy), 1e-3);
            float reach = clamp(hc * 0.3 / max(L.z, 0.15), 0.1, 0.6);
            float3 c3 = dnCrumbs(wf / cs + ls * reach, dens);
            crumbSh = saturate((c3.x - c1.x - 0.04) * 8.0) * cf;
        }
    }

    // debug 7: crumbs (red height, green cast shadow, blue berm)
    if (dbg == 7) return float4(crumbK, crumbSh, berm ? 0.5 : 0.0, 1);

    // --- relight -----------------------------------------------------------------------
    float3 nt = normalize(n + float3(-grad.x, -grad.y, 0.0) * saturate(n.z));
    float lit0 = amb + sh * saturate(dot(n, L));
    float lit1 = amb + sh * (1.0 - 0.8 * crumbSh) * saturate(dot(nt, L));
    float ratio = clamp(lit1 / max(lit0, 1e-3), 0.3, 2.0);
    // grooves (deepest pressed parts) darker, lug edges darker still: the print reads
    // whatever side the sun comes from
    float flank = saturate(abs(dlug) * soft * 0.6);
    float ao = carried ? 1.0 : 1.0 - dnOpt.z * (lug * 0.7 + flank * 0.6) * tf * edgeFade;

    // --- surface colour (on the scene colour) ------------------------------------------
    float churn = dnNoise(wf / dnGrain.w) * 0.65 + dnNoise(wf / dnGrain.w * 2.7 + 7.1) * 0.35;
    float3 C2 = scene;
    float wet = 0.0;
    if (!carried) {
        // wet churned soil: wetter in the print centre and the grooves, patchy; darker and
        // more saturated
        float inPrint = berm ? 0.75 * saturate(2.2 - abs(lat)) : 1.0;
        wet = K.z * inPrint * (0.55 + 0.45 * churn) * (0.85 + 0.3 * lug * tf);
        C2 = scene * (1.0 - K.x * wet);
        C2 = max(lerp(dnLum(C2).xxx, C2, 1.0 + K.y * wet), 0.0);
        // fresh crumbs a little drier than the wet floor under them
        C2 *= 1.0 + 0.12 * crumbK * (berm ? 1.0 : 0.5);
    } else {
        // tread-shaped stain of the tyre's coat, breaking up as it runs out
        float4 Cc = kind == 2 ? dnCarry : dnDust;
        float gain = kind == 2 ? dnCarryG.x : dnCarryG.y;
        float brk = dnNoise(wf * 14.0) * 0.6 + dnNoise(wf * 41.0) * 0.4;
        float cover = saturate((str * 1.25 - brk) * 5.0) * lerp(1.0, lug, tf * 0.85) * edgeFade;
        float3 tint = Cc.rgb / max(dnLum(Cc.rgb), 1e-3);
        C2 = scene * lerp(float3(1, 1, 1), tint * gain, Cc.a * cover);
        wet = kind == 2 ? 0.5 * cover * K.z : 0.0;
        k = saturate(dnLook.x * fade * slopeK); // the coverage carries the strength
    }

    // --- wet sheen: sun highlight, light level from the scene and a ground albedo guess -----
    float3 V = normalize(eyePosWorld - wp);
    float3 H = normalize(L + V);
    float specP = lerp(24.0, 160.0, saturate(wet));
    float spec = pow(saturate(dot(nt, H)), specP) * (specP + 8.0) / 25.0;
    float sunLight = clamp(dnLum(scene) / max(dnOpt.y, 0.02) / max(lit0, 0.05), 0.0, 8.0);
    float3 specAdd = sunLight * (sh * spec * wet * dnLook.w * 0.04) * float3(1.0, 0.97, 0.92);

    float3 outC = C2 * ratio * ao + specAdd;
    return float4(lerp(scene, outC, k), 1);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
