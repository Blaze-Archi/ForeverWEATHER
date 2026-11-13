#ifndef RP_RAIN_H_HLSL
#define RP_RAIN_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.hlsl"

// 1.0 falling rain (rp_rain.cs.hlsl)
uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
Texture2D<float4> colorTex : register(t2);

cbuffer perDraw : register(b0)
{
    uniform float4 rpCam;      // xyz camera, w time (s)
    uniform float4 rpMode;     // x debug, y depth mode, z depth scale, w brightness
    uniform float4 rpRainA;    // x visibility, y chance of a drop per cell (0 = no rain), z drop diameter (m), w distance (m)
    uniform float4 rpRainB;    // xyz streak from a drop's head to its tail (m, world axes), w brightness
    uniform float4 rpRainC;    // xyz camera in the falling frame of the near grid (wrapped), w near cell size (m)
    uniform float4 rpRainD;    // xyz camera in the falling frame of the far grid (wrapped), w far cell size (m)
    uniform float4 rpRainF;    // player car box: xyz centre, w 1 = valid
    uniform float4 rpRainG;    //                 xyz axis 0, w half extent
    uniform float4 rpRainH;    //                 xyz axis 1, w half extent
    uniform float4 rpRainI;    //                 xyz axis 2, w half extent
#include "rp_shelter_cb.h.hlsl"

    // Lighting globals the engine binds BY NAME (see rp_windshield.h.hlsl)
    uniform float4 ambientSH9[9];
    uniform float3 ambientColor;
    uniform float3 fogColor;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"
#include "rp_shelter.h.hlsl"

// depth at screen pixel q, sampled through the depth slot's own uv (render scaling / upscaling, as rp_puddles.h.hlsl)
float rpDepthLoad(int2 q)
{
    float2 uv = (float2(q) + 0.5 - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
    return prepassDepthTexTex.SampleLevel(prepassDepthTex_sampler_, viewportCoordToRenderTarget(uv, rtParams1), 0).r;
}

float3 rpRainLoad(int2 q)
{
    return colorTex.Load(int3(rpClampPix(q), 0)).rgb;
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
