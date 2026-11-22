#ifndef RP_WINDSHIELD_H_HLSL
#define RP_WINDSHIELD_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.hlsl"

uniform_sampler2D(colorTex, 0);
uniform_sampler2D(windDepth, 1);   // prepass depth: where the view really passes through the glass (1.0: slot 1, point
                                   // sampler, as in the puddle / droplet passes - on slot 4 it read as empty)
uniform_sampler2D(maskTexA, 2);
uniform_sampler2D(glassTex, 3);    // 1.5 glass water on the windshield (#rpGlassB, rp_glass.cs.hlsl): x water, y film
                                   // (another pane: any texture, not read; this slot held an unused puddle mask)
uniform_sampler2D(wiperTex, 4);
uniform_sampler2D(dropTex, 5);     // 0.7: droplet atlas (art/rainPuddles/droplet_atlas.data.png)

cbuffer perDraw : register(b0)
{
    uniform float4 rpCam;      // xyz camera, w time
    uniform float4 rpMode;     // x debug, y depth mode, z depth scale, w brightness
    uniform float4 rpWindA;    // xyz plane centre, w half width (m)
    uniform float4 rpWindB;    // xyz plane normal (pointing out of the car), w half height (m)
    uniform float4 rpWindC;    // xyz plane right, w droplet density
    uniform float4 rpWindD;    // xyz plane up (along the glass), w droplet radius (m)
    uniform float4 rpWindE;    // x seconds since the current wiper cycle started, y sweep time, z cycle period,
                               // w flags: 1 = has wiped, 2 = repeating, 4 = a previous cycle exists
    uniform float4 rpWindF;    // x smear width, y Fresnel of the glass drops (1.2), z rain, w refraction of the glass drops
    uniform float4 rpWindG;    // x vehicle speed, y active, z screen aspect, w 1 = camera outside the car (1.0)
    uniform float4 rpWindH;    // x blade park angle, y sweep range (rad), z rain clock, w rain clock rate (per second)
    uniform float4 rpWindI;    // x wiper passes before the current cycle (generation counter), y unused,
                               // z glass source: 0 estimated plane, 1 ray probe, 2 jbeam windshield frame (1.0),
                               // w 1 = right-hand drive (1.0)
    uniform float4 rpWindJ;    // 1.0 glass outline (jbeam frame), glass uv: xy bottom-left corner, zw bottom-right
    uniform float4 rpWindK;    //     xy top-right corner, zw top-left
    uniform float4 rpWindL;    // 1.0 x number of outline corners in rpWindP0..5 (0 = use the quad),
                               //     y number of the car's own wiper blades in rpWindQ0..3 (0 = procedural tandem),
                               //     z running drops amount, w wet trails amount (the body droplet settings)
    uniform float4 rpWindN;    // 1.0 xy force on the drops along the glass (m/s^2, x right, y up the glass),
                               //     z droplet life clock
    uniform float4 rpWindO;    // 1.0 xy distance the running drops have travelled, zw their velocity (glass units, /s)
    uniform float4 rpWindQ0; uniform float4 rpWindQ1; uniform float4 rpWindQ2; uniform float4 rpWindQ3;
                               // 1.0 blade: xy pivot (glass pc units), z parked angle, w signed sweep (rad)
    uniform float4 rpWindS0;   // 1.0 inner / outer radius of blades 0, 1 (pc units)
    uniform float4 rpWindS1;   //     inner / outer radius of blades 2, 3
    uniform float4 rpWindT;    // 1.0 wiper model: phase of blades 0..3 in half sweeps (0 = parked at the start of its arc,
                               //     0.5 = parked mid-arc, e.g. a centre-parked single wiper)
    uniform float4 rpWindM;    // 1.0 glass bulge along the normal (m): k0 + k1*b + (k2 + k3*b)*a^2, a/b glass metres
    uniform float4 rpWindP0; uniform float4 rpWindP1; uniform float4 rpWindP2;   // outline corners, 2 per float4,
    uniform float4 rpWindP3; uniform float4 rpWindP4; uniform float4 rpWindP5;   // glass uv, counter-clockwise
    uniform float4 rpWindU;    // 1.3 x light catch of the glass drops (as the beads' rpDropD.w); 1.5 y 1 = glass water
                               // in glassTex, z how far it reaches (glass half sizes, beyond the pane's +-1), w unused
    uniform float4 rpWindV0;   // 1.5.1 how far the running drops travelled (glass units, x right, y up the glass) in the
    uniform float4 rpWindV1;   //       last 0.5 s (V0.xy), 1 s (V0.zw), 1.5 s (V1.xy) .. 4 s (V3.zw): the water lines
    uniform float4 rpWindV2;   //       the blades leave run off along the same path
    uniform float4 rpWindV3;

    // Lighting globals the engine binds BY NAME. The Vulkan shader path does not declare them for us (the working
    // droplets header declares them for the same reason); without them rpSkyColor() fails to compile and the whole
    // effect is silently disabled. Verified against a real Vulkan beamng.log (0.40.1): "undeclared identifier 'ambientSH9'".
    uniform float4 ambientSH9[9];
    uniform float3 ambientColor;
    uniform float3 fogColor;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"
#include "rp_lib.h.hlsl"
#include "rp_pane.h.hlsl"

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
