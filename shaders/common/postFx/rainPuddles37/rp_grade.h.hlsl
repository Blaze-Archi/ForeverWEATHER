#ifndef RP_GRADE_H_HLSL
#define RP_GRADE_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.hlsl"

// 1.0.1 'Midnight' grade (rp_grade.cs.hlsl). Same slot layout as the falling rain pass (rp_rain.h.hlsl).
uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
Texture2D<float4> colorTex : register(t2);

cbuffer perDraw : register(b0)
{
    uniform float4 rpCam;      // xyz camera, w time (s)
    uniform float4 rpMode;     // x debug, y depth mode, z depth scale, w brightness
    uniform float4 rpGradeA;   // x strength (0 = off .. 1.5), y haze, z vignette, w glow around lights
    uniform float4 rpGradeB;   // x shadows -> teal, y 1.1.1: lights' own colour, stronger (was: highlights -> sodium orange),
                               // z contrast, w saturation of the surroundings
    uniform float4 rpGradeC;   // x lift of the shadows (share of the frame average), y exposure (EV), z how much the haze is
                               // cooled toward night blue, w unused
    uniform float4 rpGradeD;   // 1.1: x lamp halos (light scattered by the night air), y mean lamp intensity, z city glow on the
                               // sky, w 1.1.1: extinction of the haze (1/m: far halos dim)
    uniform float4 rpGradeE;   // 1.1: rgb colour of the shadow lift (milky teal-grey blacks of night film), w unused
    uniform float4 rpGradeF;   // 1.1.1: rgb mean colour of the listed lamps (luma 1), w unused
    uniform float4 rpLightA0; uniform float4 rpLightB0; uniform float4 rpLightC0;
    uniform float4 rpLightA1; uniform float4 rpLightB1; uniform float4 rpLightC1;
    uniform float4 rpLightA2; uniform float4 rpLightB2; uniform float4 rpLightC2;
    uniform float4 rpLightA3; uniform float4 rpLightB3; uniform float4 rpLightC3;
    uniform float4 rpLightA4; uniform float4 rpLightB4; uniform float4 rpLightC4;
    uniform float4 rpLightA5; uniform float4 rpLightB5; uniform float4 rpLightC5;
    uniform float4 rpLightA6; uniform float4 rpLightB6; uniform float4 rpLightC6;
    uniform float4 rpLightA7; uniform float4 rpLightB7; uniform float4 rpLightC7;
    uniform float4 rpLightA8; uniform float4 rpLightB8; uniform float4 rpLightC8;
    uniform float4 rpLightA9; uniform float4 rpLightB9; uniform float4 rpLightC9;
    uniform float4 rpLightA10; uniform float4 rpLightB10; uniform float4 rpLightC10;
    uniform float4 rpLightA11; uniform float4 rpLightB11; uniform float4 rpLightC11;
    uniform float4 rpLightA12; uniform float4 rpLightB12; uniform float4 rpLightC12;
    uniform float4 rpLightA13; uniform float4 rpLightB13; uniform float4 rpLightC13;
    uniform float4 rpLightA14; uniform float4 rpLightB14; uniform float4 rpLightC14;
    uniform float4 rpLightA15; uniform float4 rpLightB15; uniform float4 rpLightC15;
    uniform float4 rpLightA16; uniform float4 rpLightB16; uniform float4 rpLightC16;
    uniform float4 rpLightA17; uniform float4 rpLightB17; uniform float4 rpLightC17;
    uniform float4 rpLightA18; uniform float4 rpLightB18; uniform float4 rpLightC18;
    uniform float4 rpLightA19; uniform float4 rpLightB19; uniform float4 rpLightC19;
    uniform float4 rpLightA20; uniform float4 rpLightB20; uniform float4 rpLightC20;
    uniform float4 rpLightA21; uniform float4 rpLightB21; uniform float4 rpLightC21;
    uniform float4 rpLightA22; uniform float4 rpLightB22; uniform float4 rpLightC22;
    uniform float4 rpLightA23; uniform float4 rpLightB23; uniform float4 rpLightC23;
    uniform float4 rpLightK;   // x gain, y lights in use, z unused, w night factor

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

// depth at screen pixel q, sampled through the depth slot's own uv (render scaling / upscaling, as rp_rain.h.hlsl)
float rpDepthLoad(int2 q)
{
    float2 uv = (float2(q) + 0.5 - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
    return prepassDepthTexTex.SampleLevel(prepassDepthTex_sampler_, viewportCoordToRenderTarget(uv, rtParams1), 0).r;
}

float3 rpGradeLoad(int2 q)
{
    return colorTex.Load(int3(rpClampPix(q), 0)).rgb;
}

// atan, max error ~0.005 rad (24 lamps x 2 per pixel)
float rpAtanFast(float x)
{
    float ax = abs(x);
    float t = (ax > 1.0) ? 1.0 / ax : ax;
    float a = t * (0.9724 - 0.1919 * t * t);
    a = (ax > 1.0) ? 1.5707963 - a : a;
    return (x < 0.0) ? -a : a;
}

// 1.1: light of one lamp scattered toward the camera by the wet night air along the view ray (single scattering,
// analytic): the integral of 1/d^2 along the ray inside the lamp's range, minus the 1/range^2 floor so the halo fades to
// nothing at the range, and only up to the surface the ray meets. A spot light counts where the ray crosses its cone
// (three points around the ray's closest approach). Forward scattering: brighter looking toward the lamp. 1.1.1: the light
// on its way back through the haze dims with the distance (ext, 1/m).
float3 rpLampHalo(float3 cam, float3 rd, float tMax, float4 A, float4 B, float4 C, float ext)
{
    if (B.w <= 0.0)
    {
        return float3(0.0, 0.0, 0.0);
    }
    float3 m = A.xyz - cam;
    float tc = dot(m, rd);
    float R = max(A.w, 0.5);
    float h2 = max(dot(m, m) - tc * tc, 0.0025);
    if (h2 >= R * R)
    {
        return float3(0.0, 0.0, 0.0);
    }
    float h = sqrt(h2);
    float halfC = sqrt(R * R - h2);
    float ta = max(tc - halfC, 0.0);
    float tb = min(tc + halfC, tMax);
    if (tb <= ta)
    {
        return float3(0.0, 0.0, 0.0);
    }
    float J = (rpAtanFast((tb - tc) / h) - rpAtanFast((ta - tc) / h)) / h - (tb - ta) / (R * R);
    if (J <= 0.0)
    {
        return float3(0.0, 0.0, 0.0);
    }
    float spot = 1.0;
    if (B.w < 1.5)
    {
        float t0 = clamp(tc, ta, tb);
        float3 q0 = rd * t0 - m;
        float3 q1 = rd * clamp(t0 - 0.8 * h, ta, tb) - m;
        float3 q2 = rd * clamp(t0 + 0.8 * h, ta, tb) - m;
        float den = max(B.w - C.w, 1e-3);
        float s0 = saturate((dot(q0, C.xyz) / max(length(q0), 1e-3) - C.w) / den);
        float s1 = saturate((dot(q1, C.xyz) / max(length(q1), 1e-3) - C.w) / den);
        float s2 = saturate((dot(q2, C.xyz) / max(length(q2), 1e-3) - C.w) / den);
        spot = s0 * 0.5 + (s1 + s2) * 0.25;
    }
    float cphi = saturate(tc / max(length(m), 1e-3));
    float phase = 0.55 + 1.6 * pow(cphi, 6.0);
    return B.rgb * (J * spot * phase * exp(-ext * max(tc, 0.0)));
}

#endif
