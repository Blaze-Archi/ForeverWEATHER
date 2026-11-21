#ifndef RP_WAVES_H_HLSL
#define RP_WAVES_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

// 1.5 simulated ripples: the water surface around the camera as a height field. The engine keeps these targets as 8-bit
// fixed point read through an sRGB view, alpha lost (all found in game), so each texel holds only a height, as 16-bit
// fixed point in red + green (rpPack16, rpWaveRaw), and the time stepping needs no velocity (Verlet: the height now and
// one step ago). Three passes per frame cycle three named targets with fixed bindings: A <- (C, B), B <- (A, C),
// C <- (B, A); the newest water is always in #rpWaveC when the puddle pass reads it.
Texture2D<float4> waveCur : register(t0);    // the water one step ago
Texture2D<float4> wavePrev : register(t1);   // the water two steps ago

cbuffer perDraw : register(b0)
{
    uniform float4 rpMode;    // x debug, y depth mode, z depth scale, w brightness (declared for rp_lib.h.hlsl)
    uniform float4 rpWaveA;   // x cell size (m), y time step (s), z wave speed^2 (m^2/s^2), w damping (1/s)
    uniform float4 rpWaveB;   // xy whole cells the grid moved since waveCur was written, zw since wavePrev was written
    uniform float4 rpWaveC;   // xy world cell index of cell (0, 0), z step counter, w 1 = simulate (0 = still water)
    uniform float4 rpWaveD;   // x tyre push (m/s per m/s of ground speed), y frame time (s), z viscosity (m^2/s),
                              // w impact depth (m)
    uniform float4 rpWaveE;   // x raindrops per cell and step, yzw unused

    // tyres (same layout as the spray and puddle passes): A = contact point + half tread width, B = direction xy +
    // ground speed + tread speed, C = radius, active (0.5 + 0.5 x road wetness), spray clock, seed
    uniform float4 rpTyreA0; uniform float4 rpTyreB0; uniform float4 rpTyreC0;
    uniform float4 rpTyreA1; uniform float4 rpTyreB1; uniform float4 rpTyreC1;
    uniform float4 rpTyreA2; uniform float4 rpTyreB2; uniform float4 rpTyreC2;
    uniform float4 rpTyreA3; uniform float4 rpTyreB3; uniform float4 rpTyreC3;
    uniform float4 rpTyreA4; uniform float4 rpTyreB4; uniform float4 rpTyreC4;
    uniform float4 rpTyreA5; uniform float4 rpTyreB5; uniform float4 rpTyreC5;
    uniform float4 rpTyreA6; uniform float4 rpTyreB6; uniform float4 rpTyreC6;
    uniform float4 rpTyreA7; uniform float4 rpTyreB7; uniform float4 rpTyreC7;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"

#endif
