#ifndef RP_DROPLETS_H_HLSL
#define RP_DROPLETS_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.h.hlsl"

uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
Texture2D<float4> colorTex : register(t2);
Texture2D<float4> maskTexA : register(t3);
Texture2D<float4> maskTexB : register(t4);
uniform_sampler2D(dropTex, 5);   // 0.6 droplet atlas (art/rainPuddles/droplet_atlas.data.png), linear clamp sampler

cbuffer perDraw : register(b0)
{
    uniform float4 rpCam;      // xyz camera, w time
    uniform float4 rpMode;     // x debug, y depth mode, z depth scale, w brightness
    uniform float4 rpDropA;    // x density, y radius (m), z refraction, w life speed (already folded into rpVehH.x)
    uniform float4 rpDropB;    // x shell thickness, y sheen, z max distance, w rain
    uniform float4 rpDropC;    // x gravity slide, y aero, z wind influence, w inertia strength
    uniform float4 rpDropD;    // x run-off amount, y trail amount, zw unused

    uniform float4 rpVehA0; uniform float4 rpVehB0; uniform float4 rpVehC0; uniform float4 rpVehD0;
    uniform float4 rpVehA1; uniform float4 rpVehB1; uniform float4 rpVehC1; uniform float4 rpVehD1;
    uniform float4 rpVehA2; uniform float4 rpVehB2; uniform float4 rpVehC2; uniform float4 rpVehD2;
    uniform float4 rpVehA3; uniform float4 rpVehB3; uniform float4 rpVehC3; uniform float4 rpVehD3;
    uniform float4 rpVehA4; uniform float4 rpVehB4; uniform float4 rpVehC4; uniform float4 rpVehD4;
    uniform float4 rpVehA5; uniform float4 rpVehB5; uniform float4 rpVehC5; uniform float4 rpVehD5;

    uniform float4 rpVehE0; uniform float4 rpVehF0;
    uniform float4 rpVehE1; uniform float4 rpVehF1;
    uniform float4 rpVehE2; uniform float4 rpVehF2;
    uniform float4 rpVehE3; uniform float4 rpVehF3;
    uniform float4 rpVehE4; uniform float4 rpVehF4;
    uniform float4 rpVehE5; uniform float4 rpVehF5;
    uniform float4 rpVehG0; uniform float4 rpVehG1; uniform float4 rpVehG2;
    uniform float4 rpVehG3; uniform float4 rpVehG4; uniform float4 rpVehG5; // xyz smoothed acceleration (m/s^2)
    uniform float4 rpVehH0; uniform float4 rpVehH1; uniform float4 rpVehH2;
    uniform float4 rpVehH3; uniform float4 rpVehH4; uniform float4 rpVehH5; // x droplet flow clock, y relative airspeed
    // 1.0 roof line: highest point of the car in 16 slices along its length (box-local height), x < -50 = unknown
    uniform float4 rpVehPA0; uniform float4 rpVehPB0; uniform float4 rpVehPC0; uniform float4 rpVehPD0;
    uniform float4 rpVehPA1; uniform float4 rpVehPB1; uniform float4 rpVehPC1; uniform float4 rpVehPD1;
    uniform float4 rpVehPA2; uniform float4 rpVehPB2; uniform float4 rpVehPC2; uniform float4 rpVehPD2;
    uniform float4 rpVehPA3; uniform float4 rpVehPB3; uniform float4 rpVehPC3; uniform float4 rpVehPD3;
    uniform float4 rpVehPA4; uniform float4 rpVehPB4; uniform float4 rpVehPC4; uniform float4 rpVehPD4;
    uniform float4 rpVehPA5; uniform float4 rpVehPB5; uniform float4 rpVehPC5; uniform float4 rpVehPD5;

    uniform float4 ambientSH9[9];
    uniform float3 ambientColor;
    uniform float3 fogColor;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

// 1.0: depth at screen pixel q, sampled through the depth slot's own uv (rtParams1). With render scaling / upscaling
// (XeSS, DLSS, FSR) the depth target is smaller than the frame, so Load(q) read the depth of another spot.
float rpDepthLoad(int2 q)
{
    float2 uv = (float2(q) + 0.5 - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
    return prepassDepthTexTex.SampleLevel(prepassDepthTex_sampler_, viewportCoordToRenderTarget(uv, rtParams1), 0).r;
}
float3 rpSkyColor(float3 dir)
{
    ColorSH9 sh = getColorSH9(ambientSH9);
    float3 irr = max(0.0, evalSHIrradiance(sh, dir));
    if (rpLuma(irr) < 1e-5)
    {
        irr = max(ambientColor, 0.0) * 0.35 + max(fogColor, 0.0) * 0.15;
    }
    float horizon = 1.0 - rpSaturate(abs(dir.z));
    return lerp(irr, max(fogColor, 0.0), 0.12 * horizon);
}

#endif
