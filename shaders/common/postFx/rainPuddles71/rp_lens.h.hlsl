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
    uniform float4 rpLensE;    // 1.5.2: how the drops of each epoch have moved since it began (x..w of E, F, G = epochs 0..11
    uniform float4 rpLensF;    //        back, 0 = the current one): x = exp(this) * x_landed + (shift), in screen heights
    uniform float4 rpLensG;    //        from the screen's middle, y down: they spread out from the point the lens moves toward
    uniform float4 rpLensH;    // 1.5.2: ... and the shift, x (H, I, J = epochs 0..11)
    uniform float4 rpLensI;
    uniform float4 rpLensJ;
    uniform float4 rpLensK;    // 1.5.2: ... and y (K, L, M = epochs 0..11): down the lens with gravity, most when slow
    uniform float4 rpLensL;
    uniform float4 rpLensM;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

#endif
