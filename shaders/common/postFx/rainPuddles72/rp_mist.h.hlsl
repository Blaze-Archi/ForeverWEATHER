#ifndef RP_MIST_H_HLSL
#define RP_MIST_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

// 1.5 simulated mist: the air above the road in three layers, each a 128 x 128 grid that follows the camera. One shader
// for all the passes of a step (rpMistA.z): 0 advection + forces, 1 divergence, 2 one pressure (Jacobi) iteration,
// 3 projection. Targets (named, fixed size, they keep their contents between frames):
//   #rpMistSA / #rpMistSB  768 x 128: the state. Plane A (x 0..383) holds u and the density's upper half, plane B
//                          (x 384..767) v and its lower half; in each plane the three layers side by side.
//   #rpMistD               384 x 128: divergence
//   #rpMistP1 .. P14       384 x 128: pressure, one target per Jacobi iteration (a named target takes only one writer);
//                          the first iteration starts from the last frame's P14
// Every value is 16-bit fixed point in two colour channels and texel (0, 0) holds the calibration value, as in the
// water's targets (rp_lib.h.hlsl): the engine may keep these targets as 8-bit fixed point read through an sRGB view.
Texture2D<float4> mistIn0 : register(t0);   // advection: #rpMistSB; divergence and projection: #rpMistSA; pressure: P
Texture2D<float4> mistIn1 : register(t1);   // pressure: #rpMistD; projection: the final pressure

cbuffer perDraw : register(b0)
{
    uniform float4 rpMode;    // x debug, y depth mode, z depth scale, w brightness (declared for rp_lib.h.hlsl)
    uniform float4 rpMistA;   // x cell size (m), y time step (s), z kind of pass, w 1 = simulate (0 = calm air, no mist)
    uniform float4 rpMistB;   // xy whole cells the grid moved since input 0 was written, z vorticity confinement,
                              // w how fast the mist evaporates (1/s)
    uniform float4 rpMistC;   // xy world cell index of cell (0, 0), z mist amount (setting), w ground wetness
    uniform float4 rpMistD;   // xy wind (m/s), z exchange between the layers (1/s), w drag toward the wind (1/s)
    uniform float4 rpMistE;   // x spray intensity, y spray speed threshold (m/s), z spray size, w eddy viscosity (m^2/s)
    uniform float4 rpMistF;   // x turbulent diffusion of the mist (m^2/s), y spray thrown per second (density / s at
                              // full strength), z share of a car's speed the air around it takes, w strength of the
                              // pressure step (1 = fully incompressible layers)
    uniform float4 rpMistG;   // 1.6 stability: x share of the last frame's pressure the first Jacobi iteration starts
                              // from, y fastest tyre (ground or tread, m/s) the forcing believes, z fallout of dense mist
                              // (1/s per unit of density), w air speed (m/s) below which vorticity confinement fades out
    uniform float4 rpMistH;   // 1.6 x frame number (seeds the stochastic rounding of the stored air speed)

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
