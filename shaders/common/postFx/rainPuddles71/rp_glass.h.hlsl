#ifndef RP_GLASS_H_HLSL
#define RP_GLASS_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

// 1.5 glass water (rp_glass.cs.hlsl): the water on the windshield as a field over the pane and a margin around it, in
// glass coordinates (it moves with the car). Targets #rpGlassA / #rpGlassB, 256 x 128 half floats: x water (0 dry ..
// 1 beaded all over; more = a line the blades pushed together, up to 4), y the film a blade left (0..1).
Texture2D<float4> glassPrev : register(t0);   // the step: #rpGlassB (last frame); the copy: #rpGlassA (this step)

cbuffer perDraw : register(b0)
{
    uniform float4 rpMode;      // x debug, y depth mode, z depth scale, w brightness (declared for rp_lib.h.hlsl)
    uniform float4 rpGlassA;    // x frame time (s), y kind (0 step, 1 copy), z 1 = simulate (0 = dry glass),
                                // w how far the field reaches (glass half sizes; the pane is -1..1)
    uniform float4 rpGlassB;    // x film a blade leaves, y 1 = rain lands (0 under a roof), z evaporation (1/s), w unused

    // the windshield's own constants (glassConsts in Lua sets them by name, as for the windshield pass)
    uniform float4 rpWindA;     // xyz plane centre, w half width (m)
    uniform float4 rpWindB;     // xyz plane normal, w half height (m)
    uniform float4 rpWindD;     // xyz plane up, w droplet radius (m)
    uniform float4 rpWindE;     // x seconds into the wiper cycle, y sweep time, z cycle period, w flags
    uniform float4 rpWindG;     // x vehicle speed, y active, z screen aspect, w camera outside
    uniform float4 rpWindH;     // x blade park angle, y sweep range, z rain clock, w rain clock rate (per second)
    uniform float4 rpWindI;     // x wiper passes before this cycle, y under a roof since, z glass source, w right-hand drive
    uniform float4 rpWindJ;     // glass outline quad: bottom-left, bottom-right (glass uv)
    uniform float4 rpWindK;     //                     top-right, top-left
    uniform float4 rpWindL;     // x outline corners, y the car's own blades (0 = procedural pair, -1 = none)
    uniform float4 rpWindN;     // xy force on the drops along the glass (m/s^2, x right, y up the glass)
    uniform float4 rpWindQ0; uniform float4 rpWindQ1; uniform float4 rpWindQ2; uniform float4 rpWindQ3;
    uniform float4 rpWindS0;
    uniform float4 rpWindS1;
    uniform float4 rpWindT;
    uniform float4 rpWindP0; uniform float4 rpWindP1; uniform float4 rpWindP2;
    uniform float4 rpWindP3; uniform float4 rpWindP4; uniform float4 rpWindP5;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"
#include "rp_pane.h.hlsl"

#endif
