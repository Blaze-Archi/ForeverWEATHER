#define PFX_COMPUTE 1

#include "rp_grade.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// 1.0.1 'Midnight': the night street-racer look (inspired by the wet night city of modern street-racing games). Runs
// after the upscaler at full resolution, on the linear HDR image before the game's tone mapping, so every step is
// relative to the frame's own average brightness (it works the same at any exposure):
//   1. night air: depth haze in the colour of the city's light, thicker with distance, and a soft glow around bright
//      lights (street lamps, headlights, neon) that grows in the haze;
//   2. split toning: shadows toward teal / blue (1.1.1: the highlights keep their own hue, see 3.);
//   3. more contrast (log-luminance around the frame average) and calmer colours in the surroundings, while the lights
//      keep their colour, a little stronger (1.1.1: warm lights warmer, cool lights cooler, white light stays white);
//   4. a hint of blue in the deepest shadows and a vignette.
// 1.1 (night film, after a frame study of the 2015-era street-racing night city): the light of the nearest street lamps
// scattered by the wet air (soft halos, cones under the lamps), the overcast sky lit by the city, milky teal-grey blacks
// and calmer colours (the 'Tone' slider: 0 night film, 1 the first warm-film look).
// Lua sends the strengths (rpGradeA / rpGradeB); strength 0 is skipped (the pass is not even drawn then).

PFX_NUMTHREADS
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 storePos;
    if (!postFxComputeThread(dispatchThreadID, storePos))
    {
        return;
    }
    const int2 p = int2(storePos);
    const float4 src = colorTex.Load(int3(p, 0));
    const float k = rpGradeA.x;
    if (k < 0.001)
    {
        pfxOut[storePos] = src;
        return;
    }

    // frame statistics: 12 taps spread over the screen (as the falling rain pass)
    float3 avgC = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int gy = 0; gy < 3; gy++)
    {
        [unroll]
        for (int gx = 0; gx < 4; gx++)
        {
            avgC += rpGradeLoad(int2(dispatchRect.xy + float2((gx + 0.5) / 4.0, (gy + 0.5) / 3.0) * dispatchRect.zw));
        }
    }
    avgC /= 12.0;
    const float aL = max(rpLuma(avgC), 1e-4);

    // exposure: night scenes stay readable (dark, but the mid-tones are not crushed)
    float3 x = max(src.rgb, 0.0) * exp2(rpGradeC.y * saturate(k));
    const float2 sc = float2(p) - dispatchRect.xy;
    const float2 uv = sc / max(dispatchRect.zw, float2(1.0, 1.0));

    // ---- 1. night air ------------------------------------------------------------------------------------------------
    const float ndc = rpDepthLoad(p);
    const bool sky = rpIsSkyDepth(ndc);
    const float zEye = sky ? 1e4 : abs(ndcToRealDepth(ndc, projParams));
    // 1.1: the view ray in the world, and how far it gets before it meets the scene
    PFXVertToPix IN = processPostFxCompute(dispatchThreadID);
    PFXVertToPix INx = processPostFxCompute(dispatchThreadID + uint3(1, 0, 0));
    PFXVertToPix INy = processPostFxCompute(dispatchThreadID + uint3(0, 1, 0));
    const float3 ray0 = IN.wsEyeRay;
    const float3 rd = normalize(ray0);
    float3 camFwd = normalize(cross(INx.wsEyeRay - ray0, INy.wsEyeRay - ray0));
    camFwd = (dot(camFwd, ray0) < 0.0) ? -camFwd : camFwd;
    const float sceneT = sky ? 1e4 : zEye / max(dot(rd, camFwd), 0.05);
    const float haze = saturate(rpGradeA.y);
    float hz = haze * (1.0 - exp(-zEye * 0.0045)) * (sky ? 0.55 : 1.0);
    // glow: the local light around the pixel (two rings of 8 taps), above the frame's average
    const float r1 = dispatchRect.w * 0.012;
    const float r2 = dispatchRect.w * 0.035;
    float3 ring1 = float3(0.0, 0.0, 0.0);
    float3 ring2 = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 8; i++)
    {
        float a = 0.7853982 * float(i) + 0.3926991;
        float2 d = float2(cos(a), sin(a));
        ring1 += rpGradeLoad(p + int2(round(d * r1)));
        ring2 += rpGradeLoad(p + int2(round(d * r2 * float2(1.0, 0.8))));
    }
    const float3 local = ring1 * (0.6 / 8.0) + ring2 * (0.4 / 8.0);
    const float3 glow = max(local - avgC * 1.4, 0.0);
    // the haze takes the colour of the city's light: the frame average, cooled toward night blue
    const float3 hazeC = lerp(avgC, aL * float3(0.58, 0.82, 1.08), saturate(rpGradeC.z)) * 1.15;
    x = lerp(x, hazeC, hz * 0.5 * saturate(k));
    x += glow * saturate(rpGradeA.w) * (0.10 + 0.55 * hz) * saturate(k);

    // 1.1 lamp halos: the light of the nearest street lamps in the wet night air
    if (rpGradeD.x > 0.0 && rpLightK.y > 0.5)
    {
        float3 hl = float3(0.0, 0.0, 0.0);
        const int nL = int(rpLightK.y + 0.5);
        const float ext = max(rpGradeD.w, 0.0);
        if (nL > 0) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA0, rpLightB0, rpLightC0, ext);
        if (nL > 1) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA1, rpLightB1, rpLightC1, ext);
        if (nL > 2) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA2, rpLightB2, rpLightC2, ext);
        if (nL > 3) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA3, rpLightB3, rpLightC3, ext);
        if (nL > 4) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA4, rpLightB4, rpLightC4, ext);
        if (nL > 5) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA5, rpLightB5, rpLightC5, ext);
        if (nL > 6) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA6, rpLightB6, rpLightC6, ext);
        if (nL > 7) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA7, rpLightB7, rpLightC7, ext);
        if (nL > 8) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA8, rpLightB8, rpLightC8, ext);
        if (nL > 9) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA9, rpLightB9, rpLightC9, ext);
        if (nL > 10) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA10, rpLightB10, rpLightC10, ext);
        if (nL > 11) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA11, rpLightB11, rpLightC11, ext);
        if (nL > 12) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA12, rpLightB12, rpLightC12, ext);
        if (nL > 13) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA13, rpLightB13, rpLightC13, ext);
        if (nL > 14) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA14, rpLightB14, rpLightC14, ext);
        if (nL > 15) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA15, rpLightB15, rpLightC15, ext);
        if (nL > 16) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA16, rpLightB16, rpLightC16, ext);
        if (nL > 17) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA17, rpLightB17, rpLightC17, ext);
        if (nL > 18) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA18, rpLightB18, rpLightC18, ext);
        if (nL > 19) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA19, rpLightB19, rpLightC19, ext);
        if (nL > 20) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA20, rpLightB20, rpLightC20, ext);
        if (nL > 21) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA21, rpLightB21, rpLightC21, ext);
        if (nL > 22) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA22, rpLightB22, rpLightC22, ext);
        if (nL > 23) hl += rpLampHalo(rpCam.xyz, rd, sceneT, rpLightA23, rpLightB23, rpLightC23, ext);
        // the wet air scatters every colour alike: the halo is the lamp's colour, paler (warm-white under sodium)
        hl = lerp(rpLuma(hl).xxx, hl, 0.55);
        x += hl * (aL * rpGradeD.x / max(rpGradeD.y, 1e-4)) * saturate(k);
    }
    // 1.1 the overcast night sky glows with the city's light: low down the colour of the lamps (1.1.1: their mean colour,
    // warm under sodium lamps, cool under white ones), teal-grey higher up
    if (sky && rpGradeD.z > 0.0)
    {
        const float el = saturate(rd.z);
        float3 lowC = lerp(float3(1.0, 1.0, 1.0), max(rpGradeF.rgb, 0.0), 0.25);
        lowC *= 0.85 / max(rpLuma(lowC), 1e-4);
        const float3 glowC = lerp(lowC, float3(0.52, 0.70, 0.82), smoothstep(0.02, 0.45, el));
        x += aL * rpGradeD.z * glowC * (1.0 - 0.65 * smoothstep(0.0, 0.6, el)) * saturate(k);
    }

    // ---- 2. split toning ---------------------------------------------------------------------------------------------
    float L = max(rpLuma(x), 1e-6);
    const float t = smoothstep(-2.2, 2.0, log2(L / aL));            // 0 shadows .. 1 highlights
    // 1.1.1: no fixed sodium push in the highlights (it turned a cool lamp's light orange)
    float3 tShadow = lerp(float3(1.0, 1.0, 1.0), float3(0.77, 0.99, 1.15), saturate(rpGradeB.x));
    float3 tint = lerp(tShadow, float3(1.0, 1.0, 1.0), t);
    tint /= max(rpLuma(tint), 1e-4);                                 // hue only, the brightness stays
    x *= lerp(float3(1.0, 1.0, 1.0), tint, saturate(k));

    // ---- 3. contrast and colour --------------------------------------------------------------------------------------
    L = max(rpLuma(x), 1e-6);
    const float c = max(1.0 + rpGradeB.z * k, 0.2);      // 1.3: never 0 or negative (pow -> inf)
    const float Lc = aL * pow(L / aL, c);
    x *= Lc / L;
    L = Lc;
    const float mx = max(x.r, max(x.g, x.b));
    const float mn = min(x.r, min(x.g, x.b));
    const float sat = (mx - mn) / max(mx, 1e-6);
    // calmer surroundings (saturation toward rpGradeB.w). 1.1.1: lights and the pools of light under them keep their own
    // hue, a little stronger (rpGradeB.y): sodium more orange, a cool white lamp cooler; white light stays white
    const float own = smoothstep(0.5, 2.0, L / aL) * smoothstep(0.03, 0.15, sat);
    const float s = lerp(lerp(1.0, rpGradeB.w, saturate(k)), 1.0 + max(rpGradeB.y, 0.0) * saturate(k), own);
    x = max(lerp(L.xxx, x, s), 0.0);

    // ---- 4. blue night shadows and vignette -----------------------------------------------------------------------
    x += aL * rpGradeC.x * saturate(k) * (1.0 - t) * max(rpGradeE.rgb, 0.0);
    const float2 vc = (uv - 0.5) * float2(dispatchRect.z / max(dispatchRect.w, 1.0), 1.0);
    const float vr = dot(vc, vc) / (0.25 * (1.0 + (dispatchRect.z * dispatchRect.z) / max(dispatchRect.w * dispatchRect.w, 1.0)));
    x *= 1.0 - saturate(rpGradeA.z) * saturate(k) * 0.55 * smoothstep(0.25, 1.0, vr);

    pfxOut[storePos] = float4(rpSafe(x, src.rgb), src.a);
}
