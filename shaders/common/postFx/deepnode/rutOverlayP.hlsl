// DeepNode rut overlay: tyre prints on the ground where the rut map (#deepnode_rut, see
// rutStampP.hlsl) holds them. Runs after the opaque scene is lit (PFXBeforeBin
// ObjTranslucentBin) and rewrites the scene colour (read from $backBuffer):
//  * a universal print relief (no tread pattern, so it suits any wheel, small or big): smear
//    streaks along the track, irregular stick-slip ripples across it and a lip of mud squeezed
//    up at the edges, filtered by the pixel footprint; granular crumbs on the berms beside it
//    and in the print; all relit with the sun:
//    ratio of (ambient + sun x shadow x N.L) for the new and the G-buffer normal; the
//    engine's screen shadow mask (#sunShadowMask) keeps shadowed ground flat;
//  * surface colour per kind, worked on the lit scene colour (the renderer is light
//    pre-pass: the G-buffer holds no base colour, #prepass[RT1] is not albedo): churned wet
//    mud darker and more saturated, damp sand, mud and sand dust carried onto hard ground by
//    coated tyres as a tinted streaky stain (breaking up as the coat runs out);
//  * tracks on hard terrain: flattened grass, compacted dirt / gravel (no deformation there);
//  * wet tracks of tyres that came out of water: dark and glossy, drying out over time;
//  * mud splats thrown by spinning wheels (MudRunner's terrain mud decals): lumpy wet blobs
//    on whatever ground they land on;
//  * a wet sheen: sun highlight on the wet mud, its light level estimated from the scene;
//  * puddles (MudRunner-style water pooling in ruts): the map stores the undisturbed ground
//    height, so the shader knows how deep a pixel lies in the rut; below a patchy water level
//    the mud floor turns into flat murky water with a sky sheen, sun glint and ripples.
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
    uniform float4 dnTread;   // phase per metre (along-track coordinate), streak share, press depth (m), lip height (x press)
    uniform float4 dnLook;    // strength, fade start (m), fade length (m), sun highlight strength
    uniform float4 dnMask;    // z tolerance (m), min ground normal z, debug mode, texels per side
    uniform float4 dnOpt;     // use shadow mask, ground albedo guess (sun highlight level), groove darkening, berm z tolerance (m)
    uniform float4 dnMud;     // wet darkening, saturation gain, wetness, berm crumb density
    uniform float4 dnSand;    // same for sand
    uniform float4 dnCarry;   // mud carried onto hard ground: tint colour (rgb), opacity
    uniform float4 dnDust;    // sand dust on hard ground: tint colour (rgb), opacity
    uniform float4 dnCarryG;  // brightness gain of the mud stain, of the dust, of the splats, unused
    uniform float4 dnSplat;   // mud splats: tint colour (rgb), opacity
    uniform float4 dnTime;    // time (s, mod 64), drying time of wet tracks (s), wet darkening, unused
    uniform float4 dnPress;   // tracks on hard terrain: grass darkening, grass desaturation, dirt darkening, relief (x mud)
    uniform float4 dnGrain;   // crumb size (m), crumb height (x size), print crumb density, churn noise size (m)
    uniform float4 dnKindX;   // sand relief (x mud), sand crumb height (x mud), crumb lift mud, crumb lift sand
    uniform float4 dnWater;   // puddle amount (0..1), depth where water starts (m), murk, deepest rut (m)
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

// universal print relief, the same for any tyre: groove amount 0..1 (1 = pressed deepest) at
// `along` m along the track (periodic over `per` m, the phase wrap) and `lat` across (-1..1).
// Streaks: grooves along the track at irregular spacing and depth (rubber sliding, sidewall
// ribs); ripples: soft transverse bands at irregular spacing (stick-slip). fs, fr fade each
// with the pixel footprint (pre-filter: no aliased lines at a distance).
float printGroove(float along, float lat, float per, float fs, float fr)
{
    float st = dnNoiseWrap(float2(along * 1.5, lat * 5.0 + 3.1), per * 1.5) * 0.6
             + dnNoiseWrap(float2(along * 3.0 + 5.0, lat * 11.0), per * 3.0) * 0.4;
    float streak = smoothstep(0.38, 0.72, st);
    float warp = dnNoiseWrap(float2(along * 0.75, lat * 0.7 + 9.0), per * 0.75);
    float rip = 0.5 + 0.5 * sin((along * 4.0 + warp * 2.5) * 6.2831853);
    rip *= dnNoiseWrap(float2(along * 1.25 + 2.0, lat * 1.3), per * 1.25);
    float s = dnTread.y;
    return lerp(0.5, streak, fs) * s + lerp(0.25, rip, fr) * (1.0 - s);
}

// sky colour for reflections: mean of a few points near the top of the screen that show
// sky (far depth); w = how many did (0: no sky in view)
float4 skyColour()
{
    float4 acc = 0;
    [unroll] for (int i = 0; i < 4; i++) {
        float2 u = float2(0.12 + 0.25 * i, 0.04 + 0.02 * (i & 1));
        float4 gs = decodeGBuffer(TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), u, projParams);
        if (gs.w >= 0.99999) acc += float4(tex2Dlod(sceneTex, float4(u, 0, 0)).rgb, 1);
    }
    return acc.w > 0.0 ? float4(acc.rgb / acc.w, acc.w) : float4(0, 0, 0, 0);
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
    // interpolated lateral position; where texels of other kinds blend in, the interpolated
    // channel is no valid position (the kind is packed on top): the point value there
    float latB = r.a - 4.0 * kindF;
    float lat = clamp(abs(latB) > 2.0 ? rp.a - 4.0 * kindF : latB, -2.0, 2.0);
    // phase: interpolated, except next to the wrap seam (point value there)
    float phase = abs(wrapDiff(r.g - rp.g)) > 1.0 ? rp.g : r.g;
    float per = PHASE_WRAP / max(dnTread.x, 1e-3); // m before the along coordinate wraps
    float along = phase / max(dnTread.x, 1e-3);

    // screen derivatives, taken before any branch or discard
    float3 dpx = ddx(wp);
    float3 dpy = ddy(wp);
    float dax = wrapDiff(ddx(phase)) / max(dnTread.x, 1e-3);
    float day = wrapDiff(ddy(phase)) / max(dnTread.x, 1e-3);
    float dlx = ddx(lat);
    float dly = ddy(lat);
    // footprint filters: streak cells across (11 per half width) and ripples along (4 per m)
    float fs = 1.0 - smoothstep(0.35, 0.8, length(float2(dlx, dly)) * 11.0);
    float fr = 1.0 - smoothstep(0.35, 0.8, length(float2(dax, day)) * 4.0);
    float al = abs(lat);
    float inside = 1.0 - smoothstep(0.8, 1.0, al);
    float groove = printGroove(along, lat, per, fs, fr) * inside;
    float lip = smoothstep(0.7, 1.0, al) * (1.0 - smoothstep(1.0, 1.5, al));
    // relief height (m): pressed grooves, raised lip (carried stains: see below)
    float relief = (-groove + lip * dnTread.w) * dnTread.z;
    float drx = ddx(relief);
    float dry = ddy(relief);

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
    bool carried = kind == 2 || kind == 3;
    bool splat = kind == 4;
    bool pressed = kind == 5 || kind == 6; // 5 grass, 6 dirt / gravel
    bool wetT = kind == 7;
    // depth below the undisturbed ground: pixels well above it belong to something else
    // (vehicles; berms stand a little higher), ruts go down to dnWater.w
    float dz = wp.z - (dnWin.w + rp.b);
    if (dz < -dnWater.w || dz > (berm ? dnOpt.w : dnMask.x)) discard;
    // geometric ground slope from the depth buffer (the G-buffer normal carries the
    // material's normal map: its bumps punched holes into the prints): fade, no cut
    float3 ng = normalize(cross(dpx, dpy));
    if (ng.z < 0.0) ng = -ng;
    float slopeK = smoothstep(dnMask.y - 0.1, dnMask.y + 0.1, ng.z);

    float str = saturate(r.r);
    // debug 9: depth below the undisturbed ground (red: 0..0.25 m, green: above it)
    if (dbg == 9) return float4(saturate(-dz * 4.0), saturate(dz * 10.0), 0, 1);
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

    // --- print relief: world gradient from the screen derivatives -----------------------
    float edgeFade = inside;
    // carried mud is a thin stain on hard ground: no pressed relief
    float2 grad = (carried || splat || wetT) ? float2(0, 0) : dnWorldGrad(drx, dry, dpx.xy, dpy.xy);
    // splat blob cover (shaped in the stamp pass, rutStampP.hlsl splatCover)
    float splatC = splat ? str : 0.0;
    float reliefK = kind == 1 ? dnKindX.x : (pressed ? dnPress.w : 1.0); // sand, hard ground: softer
    grad *= reliefK;
    // debug 6: print terms (red groove, green lip, blue streak / ripple filters)
    if (dbg == 6) return float4(groove, lip, fs * fr, 1);

    // --- granular crumbs (berms, print edges; fine grains in sand) -------------------
    float cs = dnGrain.x * (kind == 1 ? 0.6 : 1.0);
    float crumbK = 0.0;
    float crumbSh = 0.0; // share of the sun a lump next to the pixel blocks (its cast shadow)
    if (!carried && !pressed && !wetT) {
        float bermW = berm ? saturate(2.0 - abs(lat)) * saturate((abs(lat) - 1.0) * 6.0) : 0.0;
        float dens = berm ? K.w * bermW : dnGrain.z * (0.4 + 0.6 * smoothstep(0.5, 1.0, abs(lat)));
        if (splat) dens = 0.65 * splatC;
        float cf = 1.0 - smoothstep(0.25, 0.7, pixM / cs);
        if (dens > 0.0 && cf > 0.0) {
            float3 c1 = dnCrumbs(wf / cs, dens);
            float3 c2 = dnCrumbs(wf / (cs * 0.5) + 31.7, dens * 0.8);
            float hc = dnGrain.y * (kind == 1 ? dnKindX.y : 1.0);
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
    // grooves (deepest pressed parts) darker: the print reads whatever side the sun is on
    float ao = (carried || splat || wetT) ? 1.0 : 1.0 - dnOpt.z * groove * reliefK;

    // --- surface colour (on the scene colour) ------------------------------------------
    float churn = dnNoise(wf / dnGrain.w) * 0.65 + dnNoise(wf / dnGrain.w * 2.7 + 7.1) * 0.35;
    float3 C2 = scene;
    float wet = 0.0;
    if (splat) {
        // thrown wet mud: tinted stain over whatever it landed on, wet
        float3 tint = dnSplat.rgb / max(dnLum(dnSplat.rgb), 1e-3);
        C2 = scene * lerp(float3(1, 1, 1), tint * dnCarryG.z, dnSplat.a * splatC);
        C2 *= 1.0 + dnKindX.z * crumbK;
        wet = 0.8 * K.z * splatC;
        // the whole effect (relief, crumbs, colour) fades with the blob: no rim at its edge
        k = saturate(dnLook.x * fade * slopeK) * smoothstep(0.0, 0.35, splatC);
    } else if (wetT) {
        // wet tyre track: darker and glossy, drying from the edges (patchy) over dnTime.y s
        float age = dnTime.x - phase;
        age -= 64.0 * floor(age / 64.0);
        float dryK = saturate(1.0 - age / max(dnTime.y, 1.0));
        float patchW = dnNoise(wf * 6.0 + 2.1);
        float w = saturate(str * 1.2) * saturate(sqrt(dryK) * 1.4 - (1.0 - patchW) * (1.0 - dryK) * 1.2) * edgeFade;
        C2 = scene * (1.0 - dnTime.z * w);
        wet = w;
        k = saturate(dnLook.x * fade * slopeK) * smoothstep(0.0, 0.15, w);
    } else if (pressed) {
        // grass flattened by the tyre: darker, paler, a little yellower (crushed blades), a faint
        // sheen; dirt / gravel compacted: a little darker and smoother
        if (kind == 5) {
            C2 = scene * (1.0 - dnPress.x * (0.7 + 0.3 * groove));
            C2 = lerp(dnLum(C2).xxx, C2, 1.0 - dnPress.y) * float3(1.04, 1.0, 0.9);
            wet = 0.12;
        } else {
            C2 = scene * (1.0 - dnPress.z * (0.6 + 0.4 * groove));
        }
    } else if (!carried) {
        // wet churned soil: wetter in the print centre and the grooves, patchy; darker and
        // more saturated
        float inPrint = berm ? 0.75 * saturate(2.2 - abs(lat)) : 1.0;
        wet = K.z * inPrint * (0.55 + 0.45 * churn) * (0.8 + 0.4 * groove);
        C2 = scene * (1.0 - K.x * wet);
        C2 = max(lerp(dnLum(C2).xxx, C2, 1.0 + K.y * wet), 0.0);
        // fresh crumbs a little drier than the wet floor under them
        C2 *= 1.0 + (kind == 1 ? dnKindX.w : dnKindX.z) * crumbK * (berm ? 1.0 : 0.5);
    } else {
        // streaky stain of the tyre's coat, breaking up as it runs out
        float4 Cc = kind == 2 ? dnCarry : dnDust;
        float gain = kind == 2 ? dnCarryG.x : dnCarryG.y;
        float brk = dnNoise(wf * 14.0) * 0.6 + dnNoise(wf * 41.0) * 0.4;
        float smear = printGroove(along, lat, per, 1.0, 0.0);
        float cover = saturate((str * 1.25 - brk) * 5.0) * (0.45 + 0.55 * smear) * edgeFade;
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

    // --- puddles: water pooled in the deepest parts of mud ruts ---------------------------
    if (kind == 0 && !berm && dnWater.x > 0.0) {
        // water level below the undisturbed ground: patchy (some ruts dry, some full)
        float patch = dnNoise(wf * 0.35 + 3.3) * 0.7 + dnNoise(wf * 1.1 + 8.1) * 0.3;
        float level = -dnWater.y - (1.0 - dnWater.x) * 0.25 - (1.0 - patch) * 0.12;
        float depthW = level - dz;  // water depth over this pixel (m)
        float wk = smoothstep(0.0, 0.015, depthW) * inside;
        if (wk > 0.0) {
            // flat water: ripples (slow, animated), murky brown body, sky sheen, sun glint
            float t = accumTime * 0.6;
            float2 rp1 = float2(dnNoise(wf * 6.0 + t), dnNoise(wf * 6.0 + 17.0 - t)) - 0.5;
            float3 nw = normalize(float3(rp1 * 0.08, 1.0));
            float3 Vw = normalize(eyePosWorld - wp);
            float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(nw, Vw)), 5.0);
            float murk = saturate(dnWater.z * (0.5 + depthW * 6.0));
            float3 body = C2 * ratio * lerp(0.75, 0.35, murk) * float3(0.95, 0.9, 0.8);
            float sunW = clamp(dnLum(scene) / max(dnOpt.y, 0.02) / max(lit0, 0.05), 0.0, 8.0);
            float4 skyS = skyColour();
            float3 sky = skyS.w > 0.0 ? skyS.rgb * 0.85 : sunW * (amb * 1.2) * float3(0.7, 0.82, 1.0);
            float3 Hw = normalize(L + Vw);
            float glint = pow(saturate(dot(nw, Hw)), 400.0) * 40.0 * sh;
            float3 water = lerp(body, sky, fres) + sunW * glint * float3(1.0, 0.97, 0.9) * 0.05;
            outC = lerp(outC, water, wk);
        }
    }
    return float4(lerp(scene, outC, k), 1);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
