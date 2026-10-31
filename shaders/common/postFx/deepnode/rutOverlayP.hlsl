// DeepNode rut overlay: tread relief and wet darkening on the ground where the rut map
// (#deepnode_rut, see rutStampP.hlsl) holds tyre prints. Runs after the opaque scene is lit
// (PFXBeforeBin ObjTranslucentBin) and scales the scene colour (read from $backBuffer), so it
// relights by itself: ratio of sun + ambient terms with the tread normal and with the
// G-buffer normal. Fog and translucent objects draw over it afterwards.
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"

// scene colour ($backBuffer) in slot 0, as in the engine's own post effects
uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(rutMap, 3);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    POSTFX_UNIFORMS
    uniform float4 dnWin;     // x0, y0, span, baseZ
    uniform float4 dnSun;     // direction to the sun (xyz), ambient share (w)
    uniform float4 dnTread;   // lugs per metre, chevron, relief, lug width (0..1)
    uniform float4 dnLook;    // wet darkening, strength, fade start (m), fade length (m)
    uniform float4 dnMask;    // z tolerance (m), min normal z, debug mode, texels per side
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

#define PHASE_WRAP 64.0

// lug profile along the tread: 1 on a lug, 0 in a groove, soft flanks
float lug(float s)
{
    float f = frac(s);
    float w = dnTread.w;
    return smoothstep(0.0, 0.12, f) * (1.0 - smoothstep(w, w + 0.12, f));
}

// phase difference across the PHASE_WRAP seam
float wrapDiff(float d)
{
    return d - PHASE_WRAP * round(d / PHASE_WRAP);
}

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float4 g = decodeGBuffer(TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), IN.uv0, projParams);
    if (g.w >= 0.99999) discard;
    float3 n = g.xyz;
    float3 L = normalize(dnSun.xyz);
    float amb = dnSun.w;
    float3 scene = tex2Dlod(sceneTex, float4(IN.uv0, 0, 0)).rgb;

    // debug 1: sun term of the G-buffer normal over the whole screen (checks dnSun)
    if (dnMask.z > 0.5 && dnMask.z < 1.5) {
        float m = (amb + saturate(dot(n, L))) / (amb + 1.0);
        return float4(scene * m, 1);
    }

    float3 wp = eyePosWorld + IN.wsEyeRay * g.w;
    float2 uv = (wp.xy - dnWin.xy) / dnWin.z;
    if (any(uv < 0.0) || any(uv > 1.0)) discard;
    float4 r = tex2Dlod(rutMap, float4(uv, 0, 0));
    if (r.r < 0.02) discard;
    if (abs(wp.z - (dnWin.w + r.b)) > dnMask.x || n.z < dnMask.y) discard;

    // debug 2: print coverage in red
    if (dnMask.z > 1.5) return float4(scene * float3(1.0 + r.r, 1.0 - 0.6 * r.r, 1.0 - 0.6 * r.r), 1);

    float dist = length(wp - eyePosWorld);
    float fade = 1.0 - saturate((dist - dnLook.z) / max(dnLook.w, 1e-3));
    if (fade <= 0.0) discard;

    // phase: interpolated, except next to the wrap seam (point value there)
    float texel = 1.0 / dnMask.w;
    float4 rp = rutMapTex.Load(int3((int2)(uv * dnMask.w), 0));
    float phase = abs(wrapDiff(r.g - rp.g)) > 1.0 ? rp.g : r.g;
    // travel direction from the phase gradient (the phase grows along the track)
    float gx = wrapDiff(tex2Dlod(rutMap, float4(uv + float2(texel, 0), 0, 0)).g
                      - tex2Dlod(rutMap, float4(uv - float2(texel, 0), 0, 0)).g);
    float gy = wrapDiff(tex2Dlod(rutMap, float4(uv + float2(0, texel), 0, 0)).g
                      - tex2Dlod(rutMap, float4(uv - float2(0, texel), 0, 0)).g);
    float2 grad = float2(gx, gy);
    float gl = length(grad);
    if (gl < 1e-4) discard;
    float2 fw = grad / gl;
    float2 sd = float2(-fw.y, fw.x);
    float lat = r.a;

    // chevron lugs: phase shifts with the distance from the tyre centre line
    float s = phase + abs(lat) * dnTread.y;
    float e = 0.02;
    float dh = (lug(s + e) - lug(s)) / e;           // d(lug)/d(phase)
    float edgeFade = (1.0 - smoothstep(0.8, 1.0, abs(lat))) * r.r;
    float relief = dnTread.z * edgeFade;
    // prints are pressed in: the lug leaves a groove, so the slope is negated
    float2 slope = -relief * dh * (fw * dnTread.x + sd * (dnTread.y * sign(lat) / 0.15));
    float3 nt = normalize(n - float3(slope.x, slope.y, 0.0) * saturate(n.z));

    float lit0 = amb + saturate(dot(n, L));
    float lit1 = amb + saturate(dot(nt, L));
    float ratio = clamp(lit1 / max(lit0, 1e-3), 0.4, 1.8);
    float wet = 1.0 - dnLook.x * r.r;
    float k = saturate(r.r * dnLook.y * fade);
    float m = lerp(1.0, ratio * wet, k);
    return float4(scene * m, 1);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
