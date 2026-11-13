#ifndef RP_LENS_H_HLSL
#define RP_LENS_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.hlsl"

// Camera lens droplets (v0.6). Inputs: 0 = back buffer, 1 = puddle mask A (unused, keeps the slot layout
// identical to the other passes), 2 = droplet atlas through the state block's linear clamp sampler.
Texture2D<float4> colorTex : register(t0);
Texture2D<float4> maskTexA : register(t1);
uniform_sampler2D(dropTex, 2);

cbuffer perDraw : register(b0)
{
    uniform float4 rpCam;      // xyz camera, w time
    uniform float4 rpMode;     // x debug, y depth mode, z depth scale, w brightness
    uniform float4 rpLensA;    // x intensity, y density (rain, speed and shelter already applied), z radius (screen heights), w refraction
    uniform float4 rpLensB;    // x clear-centre radius (screen heights), y smoothed speed 0..1, z streak stretch, w rain
    uniform float4 rpLensC;    // xyz fractional outward scroll per layer (cells), w aspect
    uniform float4 rpLensD;    // xyz integer outward scroll per layer (cells, mod 2^20), w active

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

#endif
