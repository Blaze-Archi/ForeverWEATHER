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
    uniform float4 rpLensB;    // x clear-centre radius (screen heights), y smoothed speed 0..1, z stretch of the half toward the
                               // centre (1.2: a slight teardrop), w rain
    uniform float4 rpLensC;    // 1.2: x progress of the current epoch of the life clock (0..1), y its index (mod 2^20), z unused, w aspect
    uniform float4 rpLensD;    // 1.2: x how much the half toward the centre narrows (the hint of a tip), yz unused, w active
    uniform float4 rpLensE;    // 1.2: flow (log radius) since the start of the current epoch (x) and of the 11 before it (x..w of
    uniform float4 rpLensF;    //      E, F, G = epochs 0..11 back): every drop of an epoch has moved outward by exp(this)
    uniform float4 rpLensG;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

#endif
