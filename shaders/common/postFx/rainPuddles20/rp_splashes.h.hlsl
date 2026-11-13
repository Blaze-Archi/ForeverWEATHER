#ifndef RP_SPLASHES_H_HLSL
#define RP_SPLASHES_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.hlsl"

// 1.0: depth on slot 1 (point sampler), as in the puddle / droplet passes; on slot 3 (linear) it read as empty
Texture2D<float4> colorTex : register(t0);
Texture2D<float> prepassDepthTex : register(t1);
SamplerState rpDepthSampler : register(s1);   // point clamp (state block slot 1)
Texture2D<float4> maskTexA : register(t2);
Texture2D<float4> maskTexB : register(t3);

cbuffer perDraw : register(b0)
{
    uniform float4 rpCam;      // xyz camera, w time
    uniform float4 rpMode;     // x debug, y depth mode, z depth scale, w brightness
    uniform float4 rpSplashA;  // x intensity, y size, z speed threshold (m/s), w ground wetness
    uniform float4 rpSplashB;  // x puddle coverage, y softness, z tile, w only-on-puddles (0 = any wet road)
    uniform float4 rpSplashC;  // x puddle water level, y max distance, z puddle size, w current rain

    // 0.9: up to 8 tyres (player first, then traffic). A = contact point (world) + half tread width,
    // B = travel direction xy + ground speed + tread speed (spin), C = radius, active, spray clock, seed.
    uniform float4 rpTyreA0; uniform float4 rpTyreB0; uniform float4 rpTyreC0;
    uniform float4 rpTyreA1; uniform float4 rpTyreB1; uniform float4 rpTyreC1;
    uniform float4 rpTyreA2; uniform float4 rpTyreB2; uniform float4 rpTyreC2;
    uniform float4 rpTyreA3; uniform float4 rpTyreB3; uniform float4 rpTyreC3;
    uniform float4 rpTyreA4; uniform float4 rpTyreB4; uniform float4 rpTyreC4;
    uniform float4 rpTyreA5; uniform float4 rpTyreB5; uniform float4 rpTyreC5;
    uniform float4 rpTyreA6; uniform float4 rpTyreB6; uniform float4 rpTyreC6;
    uniform float4 rpTyreA7; uniform float4 rpTyreB7; uniform float4 rpTyreC7;

    // 1.0: lighting globals the engine binds by name (as in the windshield / droplet headers): the spray mist is lit by
    // the sky, not by whatever happens to be behind it
    uniform float4 ambientSH9[9];
    uniform float3 ambientColor;
    uniform float3 fogColor;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

// Light a drop of spray mist scatters toward the eye: the sky's (ambient SH, from above and the sides) as a diffuse
// scatterer, i.e. irradiance / pi.
float3 rpSprayAmbient()
{
    ColorSH9 sh = getColorSH9(ambientSH9);
    float3 up = max(0.0, evalSHIrradiance(sh, float3(0.0, 0.0, 1.0)));
    float3 side = max(0.0, evalSHIrradiance(sh, normalize(float3(0.7, 0.7, 0.25))));
    float3 irr = up * 0.6 + side * 0.4;
    if (rpLuma(irr) < 1e-5)
    {
        irr = max(ambientColor, 0.0) * 0.35 + max(fogColor, 0.0) * 0.15;
    }
    return irr * 0.318;
}

#endif
