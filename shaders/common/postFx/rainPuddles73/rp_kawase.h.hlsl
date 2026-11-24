#ifndef RP_KAWASE_H_HLSL
#define RP_KAWASE_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.hlsl"

// 1.6 glass fog: the frame blurred by a Dual Kawase chain (Bjorge 2015) for the fogged glass. Five passes, each a named
// target of its own (a named target takes only one writer), sized relative to its input (targetScale):
//   #rpFogD1 (1/2) <- frame, #rpFogD2 (1/4) <- D1, #rpFogD3 (1/8) <- D2, #rpFogU2 (1/4) <- D3, #rpFogU1 (1/2) <- U2
// The glass passes read #rpFogU1 in their slot 2 (linear sampler). Every texel holds the colour premultiplied by a
// weight in alpha: from the driver's seat the cabin itself (dashboard, pillars, roof liner) weighs almost nothing, so the
// blur never smears the dark interior into the view through the glass (the light that reaches the eye through fogged
// glass only ever came through the glass). The glass passes divide by alpha.
uniform_sampler2D(kawIn, 0);       // the level before (the frame for the first pass), linear sampler
uniform_sampler2D(kawDepth, 1);    // prepass depth (first pass only), point sampler

cbuffer perDraw : register(b0)
{
    uniform float4 rpCam;      // xyz camera, w time
    uniform float4 rpMode;     // x debug, y depth mode, z depth scale, w brightness
    uniform float4 rpKawA;     // x 0 = downsample, 1 = upsample; y tap offset (input texels); z 1 = first pass (reads
                               // the frame and the depth); w 1 = mask the player's cabin (in-car views)
    uniform float4 rpKawB;     // the player's car box: xyz centre, w half extent along axis 0
    uniform float4 rpKawC;     //                       xyz axis 0, w half extent along axis 1
    uniform float4 rpKawD;     //                       xyz axis 1, w half extent along axis 2
    uniform float4 rpKawE;     //                       xyz axis 2, w unused
    uniform float4 rpKawF;     // the windshield: xyz centre, w 1 = known (the hood beyond it is not cabin)
    uniform float4 rpKawG;     //                 xyz normal, out of the car

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

#endif
