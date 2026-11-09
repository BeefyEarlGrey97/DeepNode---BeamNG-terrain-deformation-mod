// DeepNode wet and muddy tyres: screen-space look of up to 32 wheels (deepnode/overlay.lua sends
// the wheels nearest the camera that are wet or coated). A pixel belongs to a wheel when its
// world position (depth buffer) lies in the wheel's tyre volume (between rim and tread,
// within the tyre width) and its normal faces out of the tyre (tread or sidewall), so the
// ground under a sunk tyre is left alone. Per pixel, in the wheel frame that turns with the
// wheel (e1 = the tread node direction from the hub):
//  * wet: rubber and mud darker, glossy sun highlight with streaks that turn with the tyre;
//  * coat (overlay.tyreCoat): the mud of the wheel's 32 perimeter arcs (wheelMud W.bins: each
//    arc picks mud up as it sweeps through the contact patch, so a tyre rolling into mud
//    gets a coat that starts at the ground and creeps round as it turns, thicker per pass).
//    The arcs are interpolated round the tyre (smooth front); a stick order (tread first,
//    shoulders, blotches down the sidewalls) turns the coat into coverage with ragged edges.
//    Thickness grows with the coat: thin film = translucent stain over the rubber, then an
//    opaque layer, then a cake that fills the tread (the lug relief fades) with its own lumps
//    and a lip at its edge. Fresh mud (arcs that picked mud up in the last tyreMudDry s) is
//    wet: darker, glossy, smeared round a fast tyre; it dries lighter and thick dry cake
//    cracks. Coloured like the ground it came from (no meshes, no material flushes).
// Lighting: the mud is lit as the engine lights a material (BNG_COCONUT: albedo / PI x (diffuse
// light + sky SH9 x AO)) from the engine's light pack in slot 4 (#deepnode_roadLit, roadLitP.hlsl:
// light pre-pass diffuse light + screen AO), its sun part following N.L of the mud's own normal.
// The rubber under it is never used as a light probe (tyre albedo and AO maps differ per
// asset: the Ural's dark rubber made the mud 5x too dark). Without the pack (dnLit.x 0) the
// old estimate (scene / tyreAlbedo) remains.
// Runs after the rut overlay, before fog and translucent objects.
#include "../postFx.h.hlsl"
#include "shaders/common/hlsl.h"
#include "shaders/common/sh.h.hlsl"
#include "dnCommon.h.hlsl"

uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(shadowTex, 3);
uniform_sampler2D(litTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float accumTime;
    uniform float3 sunDirection;
    uniform float4 ambientSH9[9];
    uniform float4 dnLit;     // light pack bound (> 0.5), unused x3
    POSTFX_UNIFORMS
    uniform float4 dnSun;     // direction to the sun (xyz), ambient share (w)
    uniform float4 dnTy;      // wheel count, wet darkening, wet highlight strength, debug (1 tyre pixels, 2 coat)
    uniform float4 dnTyOpt;   // use shadow mask, albedo guess (light level from the scene), coat on, coat lump size (m)
    uniform float4 dnTyCoat;  // coat per arc step (coatMax / 127), fresh mud wetness, dried albedo factor, cracks
    // per wheel: a = hub centre, tyre radius; b = axle, half width; c = e1 (turns with the
    // wheel), rim radius; d = wetness, sink share + tread speed packed, coat colour packed (see overlay.lua),
    // seed; p a..d = the 32 perimeter arcs, two a float (see overlay.lua sendBins)
#define WHEEL(i) uniform float4 dnWa##i; uniform float4 dnWb##i; uniform float4 dnWc##i; uniform float4 dnWd##i; \
    uniform float4 dnWp##i##a; uniform float4 dnWp##i##b; uniform float4 dnWp##i##c; uniform float4 dnWp##i##d;
    WHEEL(0) WHEEL(1) WHEEL(2) WHEEL(3) WHEEL(4) WHEEL(5) WHEEL(6) WHEEL(7)
    WHEEL(8) WHEEL(9) WHEEL(10) WHEEL(11) WHEEL(12) WHEEL(13) WHEEL(14) WHEEL(15)
    WHEEL(16) WHEEL(17) WHEEL(18) WHEEL(19) WHEEL(20) WHEEL(21) WHEEL(22) WHEEL(23)
    WHEEL(24) WHEEL(25) WHEEL(26) WHEEL(27) WHEEL(28) WHEEL(29) WHEEL(30) WHEEL(31)
#undef WHEEL
};

#include "../postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

static const float TAU = 6.28318531;

// colour packed as three 0..1 channels in steps of 1/64 (r + g x 64 + b x 4096, each 0..63)
float3 unpackColor(float v)
{
    float b = floor(v / 4096.0);
    float g = floor((v - b * 4096.0) / 64.0);
    float r = v - b * 4096.0 - g * 64.0;
    return float3(r, g, b) / 63.0;
}

// arc j (any int, wraps at 32): x = coat steps 0..127, y = freshness 0..1
float2 arcAt(float4 pb[4], int j)
{
    j = j & 31;
    int k = j >> 1;
    float v = pb[k >> 2][k & 3];
    float hi = floor(v / 2048.0);
    float a = (j & 1) ? hi : v - hi * 2048.0;
    float f = floor(a / 128.0);
    return float2(a - f * 128.0, f / 15.0);
}

// coat (coat units) and freshness at a01 (0..1 round the tyre; arc j spans j/32..(j+1)/32):
// Catmull-Rom through the arc centres, held between the two neighbours (no ringing)
float2 profileAt(float4 pb[4], float a01, float cs)
{
    float t = a01 * 32.0 - 0.5;
    float i0 = floor(t);
    float f = t - i0;
    int j = (int)i0 + 32;
    float2 p0 = arcAt(pb, j - 1);
    float2 p1 = arcAt(pb, j);
    float2 p2 = arcAt(pb, j + 1);
    float2 p3 = arcAt(pb, j + 2);
    float f2 = f * f;
    float f3 = f2 * f;
    float c = 0.5 * (2.0 * p1.x + (p2.x - p0.x) * f + (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * f2
            + (3.0 * p1.x - p0.x - 3.0 * p2.x + p3.x) * f3);
    c = clamp(c, min(p1.x, p2.x), max(p1.x, p2.x));
    return float2(c * cs, lerp(p1.y, p2.y, f));
}

// how far the coat at a point reaches past its stick order (> 0 = covered); the order puts
// the tread first, then the shoulders, then blotches down the sidewalls to the rim. Noise
// cells wrap round the tyre (no seam). The coat counts as coat^0.5: one pass through mud
// (coat ~0.15) already stains most of the tread, so the front that creeps round the tyre
// shows from the first turn. fresh: freshness of the coat there; thick: the linear reach
// (cake thickness).
float coatReach(float4 pb[4], float a01, float across, float radK, float R, float seed, float cs, float imm,
    out float fresh, out float thick)
{
    float nxA = max(8.0, round(TAU * R / 0.1));
    // ragged front: the arc lookup wanders +-1.5 arcs with the position across the tyre
    float jit = (dnNoiseWrap(float2(a01 * nxA, across * 5.0 + radK * 6.0 + seed * 5.3), nxA) - 0.5) * (3.0 / 32.0);
    float2 pr = profileAt(pb, frac(a01 + jit + 1.0), cs);
    fresh = pr.y;
    float nxB = max(16.0, round(TAU * R / 0.035));
    float nA = dnNoiseWrap(float2(a01 * nxA, across * 2.5 + radK * 3.0 + seed), nxA);
    float nB = dnNoiseWrap(float2(a01 * nxB, across * 7.0 + radK * 9.0 + seed * 3.1), nxB);
    float side = saturate(abs(across) * 1.1 - 0.35);
    // the sidewall band that sank below the mud (imm: sink depth / sidewall height) takes mud
    // like the tread, with a ragged mud line
    float band = saturate(((imm - (1.0 - radK)) * 4.0) + 0.5 + (nA - 0.5) * 0.8);
    float orderLow = (1.0 - radK) * (1.0 - 0.8 * band) + 0.3 * side * (1.0 - 0.6 * band) + 0.5 * nA;
    float order = orderLow + 0.15 * nB;
    // the cake's thickness follows the coarse order only (fine noise there drew worm-like ridges)
    thick = saturate((pr.x - 0.25 - 0.5 * orderLow) / 1.5);
    // linear in the coat: sqrt(coat) x 1.3 covered the whole tread at coat 0.4 (~30 m of mud,
    // user: "built up too fast", 2026-11-09); now the tread fills around coat 1.5
    return pr.x * 0.6 - order;
}

// cake height (m) over the tyre for a reach and thickness: a wide ramp (a steep one drew a
// ridge along every iso-line of the order noise)
float cakeHeight(float D, float th)
{
    return smoothstep(-0.05, 0.45, D) * (0.002 + 0.022 * th);
}

// cake surface (m-free, 0..1): two octaves of value noise, columns wrapping round the tyre
float cakeBlob(float2 q, float nx)
{
    return 0.65 * dnNoiseWrap(q, nx) + 0.35 * dnNoiseWrap(q * 2.7 + 11.3, nx * 2.7);
}

// crumbs (dnCrumbs) with the cell column wrapping every nx cells (the arc coordinate)
float3 crumbsWrap(float2 p, float density, float nx)
{
    float n = max(1.0, round(nx));
    float2 i = floor(p);
    float2 f = p - i;
    float h = 0.0;
    float2 g = 0.0;
    [unroll] for (int y = -1; y <= 1; y++) {
        [unroll] for (int x = -1; x <= 1; x++) {
            float2 c = float2(x, y);
            float2 ic = i + c;
            ic.x -= n * floor(ic.x / n);
            float2 r = dnHash22(ic);
            float pres = dnHash12(ic + 17.31);
            float rad = 0.25 + 0.3 * frac(pres * 7.13);
            float2 cp = c + 0.2 + 0.6 * r - f;
            float d2 = dot(cp, cp);
            float rr = rad * rad;
            if (pres < density && d2 < rr) {
                float q = 1.0 - d2 / rr;
                float hh = rad * q * q;
                if (hh > h) {
                    h = hh;
                    g = cp * (4.0 * rad * q / rr);
                }
            }
        }
    }
    return float3(h, g);
}

// dried mud cracks: distance to the nearest edge between Voronoi cells (F2 - F1, in cells),
// the cell column wrapping every nx cells
float crackEdge(float2 p, float nx)
{
    float n = max(1.0, round(nx));
    float2 i = floor(p);
    float2 f = p - i;
    float d1 = 8.0, d2 = 8.0;
    [unroll] for (int y = -1; y <= 1; y++) {
        [unroll] for (int x = -1; x <= 1; x++) {
            float2 c = float2(x, y);
            float2 ic = i + c;
            ic.x -= n * floor(ic.x / n);
            float d = length(c + dnHash22(ic + 3.7) - f);
            if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
        }
    }
    return d2 - d1;
}

#define TEST(i)                                                                         \
    if (hit < 0 && i < cnt) {                                                           \
        float3 rel = wp - dnWa##i.xyz;                                                  \
        float ax = dot(rel, dnWb##i.xyz);                                               \
        float3 rad = rel - dnWb##i.xyz * ax;                                            \
        float rr = length(rad);                                                         \
        if (abs(ax) < dnWb##i.w * 1.1 && rr < dnWa##i.w * 1.12 && rr > dnWc##i.w * 0.9) { \
            float3 nr = rad / max(rr, 1e-4);                                            \
            if (dot(n, nr) > 0.15 || abs(dot(n, dnWb##i.xyz)) > 0.55) {                 \
                hit = i; wa = dnWa##i; wb = dnWb##i; wc = dnWc##i; wd = dnWd##i;        \
                pb[0] = dnWp##i##a; pb[1] = dnWp##i##b; pb[2] = dnWp##i##c; pb[3] = dnWp##i##d; \
                axW = ax; rrW = rr; nrW = nr;                                           \
            }                                                                           \
        }                                                                               \
    }

float4 mainP(PFXVertToPix IN) : SV_Target
{
    if (accumTime < -1.0e9 || rtParams0.x < -1.0e9) discard;
    float4 g = decodeGBuffer(TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), IN.uv0, projParams);
    if (g.w >= 0.99999) discard;
    float3 wp = eyePosWorld + IN.wsEyeRay * g.w;
    float3 n = g.xyz;
    int cnt = (int)dnTy.x;
    int hit = -1;
    float4 wa = 0, wb = 0, wc = 0, wd = 0;
    float4 pb[4] = { float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0), float4(0, 0, 0, 0) };
    float axW = 0, rrW = 0;
    float3 nrW = 0;
    TEST(0) TEST(1) TEST(2) TEST(3) TEST(4) TEST(5) TEST(6) TEST(7)
    TEST(8) TEST(9) TEST(10) TEST(11) TEST(12) TEST(13) TEST(14) TEST(15)
    TEST(16) TEST(17) TEST(18) TEST(19) TEST(20) TEST(21) TEST(22) TEST(23)
    TEST(24) TEST(25) TEST(26) TEST(27) TEST(28) TEST(29) TEST(30) TEST(31)
    if (hit < 0) discard;

    float3 scene = tex2Dlod(sceneTex, float4(IN.uv0, 0, 0)).rgb;
    if (dnTy.w > 0.5 && dnTy.w < 1.5) return float4(scene * float3(0.4, 0.6, 1.6), 1); // debug: tyre pixels in blue

    float3 axle = wb.xyz;
    float hw = wb.w;
    float R = wa.w;
    float rimR = wc.w;
    float3 e1 = wc.xyz;
    float3 e2 = cross(axle, e1);
    // tyre coordinates: angle (turns with the wheel), across (-1..1), radius share rim..tread
    float ang = atan2(dot(nrW, e2), dot(nrW, e1));
    float a01 = frac(ang / TAU);
    float across = axW / max(hw, 1e-3);
    float radK = saturate((rrW - rimR) / max(R - rimR, 1e-3));
    float arc = ang * R; // m along the tread
    float2 tc = float2(arc, axW);
    // surface frame: along the tread (direction of turning), and the second tangent: across
    // the tread, or outwards on a sidewall pixel
    bool sidePx = abs(dot(n, axle)) > 0.6;
    float3 tAng = cross(axle, nrW);
    float3 tSide = sidePx ? nrW : axle;
    float3 nBase = sidePx ? axle * sign(dot(n, axle)) : nrW;

    float sh = 1.0;
    if (dnTyOpt.x > 0.5) {
        uint mw, mh;
        shadowTexTex.GetDimensions(mw, mh);
        int2 mp = clamp((int2)(IN.uv0 * float2(mw, mh)), int2(0, 0), int2(mw, mh) - 1);
        sh = saturate(shadowTexTex.Load(int3(mp, 0)).r);
    }
    float3 L = normalize(dnSun.xyz);
    float amb = dnSun.w;
    // light level at the pixel: scene / albedo guess (the light pre-pass G-buffer has no
    // base colour)
    float light = dnLum(scene) / max(dnTyOpt.y, 0.01);
    float seed = wd.w;
    float waterWet = saturate(wd.x);
    // wd.y: sink share x 1024 (6 bits) + tread speed x 16 (see overlay.lua sendTyres)
    float imm = floor(wd.y / 1024.0);
    float surf = (wd.y - imm * 1024.0) / 16.0;
    imm /= 63.0;
    // engine light at the pixel (see the header)
    bool engLit = dnLit.x > 0.5;
    float4 lp = engLit ? tex2Dlod(litTex, float4(IN.uv0, 0, 0)) : float4(0, 0, 0, 1);
    float aoS = lp.a < 0.0 ? -lp.a - 1.0 : lp.a;
    ColorSH9 shc = getColorSH9(ambientSH9);
    float ndl0 = saturate(dot(n, sunDirection));
    float3 sunE = lp.rgb / max(ndl0, 0.1); // light on a surface facing the sun, at this pixel

    // --- coat (screen-space mud on the tyre) ---------------------------------------
    float3 C2 = scene;
    float3 nt = n;
    float cover = 0, thick = 0, fresh = 0, mudWet = 0;
    if (dnTyOpt.z > 0.5) {
        float cs = dnTyCoat.x;
        float D = coatReach(pb, a01, across, radK, R, seed, cs, imm, fresh, thick);
        cover = smoothstep(0.0, 0.1, D);
        // cake relief: height differences 1 cm along the tread and across / outwards
        // (the step at the cake's edge, thicker where more coat reached)
        float dl = 0.01;
        float fr2, th2;
        float hA = cakeHeight(D, thick);
        float DT = coatReach(pb, frac(a01 + dl / (TAU * max(rrW, 0.05))), across, radK, R, seed, cs, imm, fr2, th2);
        float hT = cakeHeight(DT, th2);
        float DS = sidePx
            ? coatReach(pb, a01, across, saturate(radK + dl / max(R - rimR, 0.02)), R, seed, cs, imm, fr2, th2)
            : coatReach(pb, a01, across + dl / max(hw, 0.02), radK, R, seed, cs, imm, fr2, th2);
        float hS = cakeHeight(DS, th2);
        float2 gEdge = float2(hT - hA, hS - hA) / dl;
        // contact shadow on the rubber just outside a cake
        float ao = 1.0 - 0.3 * (1.0 - cover) * saturate(1.0 + D * 5.0) * saturate(max(hT, hS) * 150.0);

        if (cover > 0.001 || ao < 0.999) {
            // the cake fills the tread: the tyre's lug relief fades under it
            float fill = cover * smoothstep(0.05, 0.5, thick);
            float3 nFill = normalize(lerp(n, nBase, fill));
            // lumps grow with the cake; wet fresh mud smears round a fast tyre
            float smear = 1.0 + 0.1 * surf * fresh;
            float lump = dnTyOpt.w * (0.7 + 1.6 * thick);
            float2 q = float2(a01 * TAU * R / smear, sidePx ? rrW : axW) / lump;
            float3 cr = crumbsWrap(q + seed, 0.25, TAU * R / (smear * lump));
            float2 gL = cr.yz * (0.3 + 0.5 * thick) * cover * 0.3;
            gL.x /= smear;
            // blobby cake surface: height (m) grows with the cake; slope by finite differences
            float bc = 0.06 * (0.8 + 0.6 * thick);
            float nxB2 = max(8.0, round(TAU * R / (smear * bc)));
            float2 qb = float2(a01 * nxB2, (sidePx ? rrW : axW) / bc + seed * 0.7);
            float hb0 = cakeBlob(qb, nxB2);
            float hbA = cakeBlob(qb + float2(0.15, 0.0), nxB2);
            float hbS = cakeBlob(qb + float2(0.0, 0.15), nxB2);
            float ampB = cover * (0.002 + 0.012 * thick);
            float2 gB = float2((hbA - hb0) / (0.15 * bc * smear), (hbS - hb0) / (0.15 * bc)) * ampB;
            float2 gr = gEdge * 0.6 + gL + gB;
            gr *= min(1.0, 1.5 / max(length(gr), 1e-4));
            nt = normalize(nFill - (gr.x * tAng + gr.y * tSide));

            // albedo: the ground colour (as wet ground), mottled; drying lifts it and greys
            // it a little, thick dried cake cracks
            mudWet = fresh * dnTyCoat.y;
            float dry = (1.0 - fresh) * (1.0 - waterWet);
            float3 alb = unpackColor(wd.z);
            float nxM = max(8.0, round(TAU * R / 0.05));
            float mot = dnNoiseWrap(float2(a01 * nxM, (sidePx ? rrW : axW) * 20.0 + seed * 1.3), nxM);
            alb *= 0.84 + 0.32 * mot;
            // occlusion between the lumps of a cake (material AO)
            float matAO = lerp(1.0, 0.7 + 0.3 * saturate(hb0 * 1.6 - 0.3 + cr.x * 1.5), saturate(thick * 2.0));
            // fresh mud is wetter than the ground it came from: darker; dried mud lighter
            alb *= lerp(1.0, 0.62, fresh * (1.0 - waterWet)) * lerp(1.0, dnTyCoat.z, dry);
            alb = lerp(alb, dnLum(alb).xxx, 0.25 * dry);
            float nxC = max(16.0, round(TAU * R / 0.07));
            float ce = crackEdge(float2(a01 * nxC, (sidePx ? rrW : axW) / 0.07 + seed * 2.7), nxC);
            float crack = (1.0 - smoothstep(0.03, 0.09, ce)) * dry * dry * smoothstep(0.5, 0.9, thick);
            alb *= 1.0 - 0.6 * crack * dnTyCoat.w;
            // thin film = stain over the rubber, opaque once it has some body
            float op = cover * saturate(0.55 + thick * 3.0);
            float3 mudC;
            if (engLit) {
                float ndl1 = saturate(dot(nt, sunDirection));
                float sr = ndl0 > 0.02 ? clamp(ndl1 / ndl0, 0.0, 3.0) : 1.0;
                mudC = alb / PI * (lp.rgb * sr * (0.6 + 0.4 * matAO) + evalSHIrradiance(shc, nt) * aoS * matAO);
            } else {
                float lit0 = amb + sh * saturate(dot(n, L));
                float lit1 = amb + sh * saturate(dot(nt, L));
                mudC = alb * matAO * light * clamp(lit1 / max(lit0, 1e-3), 0.3, 2.0);
            }
            C2 = lerp(scene * ao, mudC, op);
            if (dnTy.w > 2.5) return float4(op, dnLum(lp.rgb) * 4.0, dnLum(alb) * 4.0, 1); // debug: opacity, light x 4, albedo x 4
        }
        if (dnTy.w > 1.5) return float4(cover, thick, fresh, 1); // debug: coverage, thickness, freshness
    }

    // --- wet ---------------------------------------------------------------------------
    float wet = max(waterWet, mudWet * cover);
    float streak = dnNoise(float2(ang * 20.0 / 6.2832 * 6.0, across * 2.5) + seed * 1.7);
    // water runs off in streaks; fresh mud is evenly wet
    float w = wet * (0.6 + 0.4 * lerp(streak, 1.0, cover));
    // the coat colour is already wet ground: fresh mud darkens half as much as wet rubber
    C2 *= 1.0 - dnTy.y * w * (1.0 - 0.5 * cover);

    // wet highlight (sun) and grazing sheen (a water film mirrors the sky: Schlick, water F0
    // 0.02) on the coat's normal
    float3 V = normalize(eyePosWorld - wp);
    float3 H = normalize(L + V);
    float specP = lerp(20.0, 110.0, w);
    float spec = pow(saturate(dot(nt, H)), specP) * (specP + 8.0) / 25.0;
    float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(nt, V)), 5.0);
    float3 specAdd;
    if (engLit) {
        float3 sky = evalSHIrradiance(shc, reflect(-V, nt)) / PI * aoS;
        specAdd = (sunE / PI * spec * dnTy.z * 0.04 + sky * fres) * w;
    } else {
        float lit0 = amb + sh * saturate(dot(n, L));
        float sunLight = clamp(light / max(lit0, 0.05), 0.0, 4.0);
        specAdd = sunLight * (sh * spec * dnTy.z * 0.04 + 0.5 * amb * fres) * w * float3(0.95, 0.98, 1.05);
    }
    return float4(C2 + specAdd, 1);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
