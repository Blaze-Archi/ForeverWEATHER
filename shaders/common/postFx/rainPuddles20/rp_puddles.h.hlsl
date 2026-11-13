#ifndef RP_PUDDLES_H_HLSL
#define RP_PUDDLES_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"
#include "shaders/common/gbuffer.hlsl"

uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
Texture2D<float4> colorTex : register(t2);
Texture2D<float4> maskTexA : register(t3);
Texture2D<float4> maskTexB : register(t4);
uniform_sampler2D(envTex, 5);      // 1.0 surroundings capture (an upward render view of the real scene), linear sampler

cbuffer perDraw : register(b0)
{
    uniform float4 rpPuddleN;  // 1.0 surroundings as the miss fallback: x on the wet ground, y in puddles, z blur (texels), w unused
    uniform float4 rpEnvA;     // 1.0 surroundings capture: xyz where it was taken (world), w 1 = available
    uniform float4 rpEnvB;     //     xyz image right (world), w tan(half field of view)
    uniform float4 rpEnvC;     //     xyz image up (world), w brightness gain
    uniform float4 rpEnvD;     //     xyz view axis (world), w radius (m) of the proxy sphere used for parallax
    uniform float4 rtParams5;  //     render-target uv window of slot 5 (bound by the engine)
    uniform float4 rpCam;      // xyz camera position, w time (s)
    uniform float4 rpMode;     // x debug mode, y depth mode, z depth scale, w debug brightness
    uniform float4 rpPuddleA;  // x coverage, y wet darkening, z reflection strength, w tile size (m)
    uniform float4 rpPuddleB;  // x edge softness, y ripples, z max distance (m), w vegetation filter
    uniform float4 rpPuddleC;  // x virtual roughness, y puddle size, z sky fallback, w normal strength
    uniform float4 rpPuddleD;  // x reflection blur, y SSR steps, z SSR thickness, w rain
    uniform float4 rpPuddleE;  // x road film reflection intensity, y tyre-mark gloss, z vehicle mask on, w native film active
    uniform float4 rpPuddleF;  // 0.6 global wet road: x wet roughness (fraction of dry), y darkening, z normal detail, w wetness
    uniform float4 rpPuddleG;  // global wet road: x film variation, y sky fallback, z reflection blur, w trace thickness (0.6.1)
    uniform float4 rpPuddleH;  // x ground trace steps (0.6.1), y ground miss fallback, z puddle miss fallback (0.6.2), w unused
    uniform float4 rpPuddleI;  // 0.7: x wet ground on, y puddles on, z ground pattern size (m), w ground distance (m)
    uniform float4 rpPuddleJ;  // 0.7: x vehicle mask height (m above the road), yzw unused
    uniform float4 rpPuddleK;  // 0.8: x ground flood (0 wet asphalt .. 1 = puddle), y current rain, z roads-only mode, w road segment count
    uniform float4 rpPuddleL;  // 0.8: x light streaks, y stochastic glossy reflections on, z frame index, w unused
    uniform float4 rpPuddleM;  // 0.9: x tyre wake strength, y number of tyres, zw unused
    // 0.9 tyres (same layout as the spray pass): A = contact point + half tread width, B = direction xy + ground speed + tread
    // speed, C = radius, active, spray clock, seed
    uniform float4 rpTyreA0; uniform float4 rpTyreB0; uniform float4 rpTyreC0;
    uniform float4 rpTyreA1; uniform float4 rpTyreB1; uniform float4 rpTyreC1;
    uniform float4 rpTyreA2; uniform float4 rpTyreB2; uniform float4 rpTyreC2;
    uniform float4 rpTyreA3; uniform float4 rpTyreB3; uniform float4 rpTyreC3;
    uniform float4 rpTyreA4; uniform float4 rpTyreB4; uniform float4 rpTyreC4;
    uniform float4 rpTyreA5; uniform float4 rpTyreB5; uniform float4 rpTyreC5;
    uniform float4 rpTyreA6; uniform float4 rpTyreB6; uniform float4 rpTyreC6;
    uniform float4 rpTyreA7; uniform float4 rpTyreB7; uniform float4 rpTyreC7;
    // 0.8 roads only: nearest AI-road segments, A/B = (x, y, z, half width) of both ends, world space
    uniform float4 rpRoadA0; uniform float4 rpRoadB0;
    uniform float4 rpRoadA1; uniform float4 rpRoadB1;
    uniform float4 rpRoadA2; uniform float4 rpRoadB2;
    uniform float4 rpRoadA3; uniform float4 rpRoadB3;
    uniform float4 rpRoadA4; uniform float4 rpRoadB4;
    uniform float4 rpRoadA5; uniform float4 rpRoadB5;
    uniform float4 rpRoadA6; uniform float4 rpRoadB6;
    uniform float4 rpRoadA7; uniform float4 rpRoadB7;
    uniform float4 rpRoadA8; uniform float4 rpRoadB8;
    uniform float4 rpRoadA9; uniform float4 rpRoadB9;
    uniform float4 rpRoadA10; uniform float4 rpRoadB10;
    uniform float4 rpRoadA11; uniform float4 rpRoadB11;
    uniform float4 rpRoadA12; uniform float4 rpRoadB12;
    uniform float4 rpRoadA13; uniform float4 rpRoadB13;
    uniform float4 rpRoadA14; uniform float4 rpRoadB14;
    uniform float4 rpRoadA15; uniform float4 rpRoadB15;
    uniform float4 rpRoadA16; uniform float4 rpRoadB16;
    uniform float4 rpRoadA17; uniform float4 rpRoadB17;
    uniform float4 rpRoadA18; uniform float4 rpRoadB18;
    uniform float4 rpRoadA19; uniform float4 rpRoadB19;
    uniform float4 rpRoadA20; uniform float4 rpRoadB20;
    uniform float4 rpRoadA21; uniform float4 rpRoadB21;
    uniform float4 rpRoadA22; uniform float4 rpRoadB22;
    uniform float4 rpRoadA23; uniform float4 rpRoadB23;
    uniform float4 rpRoadA24; uniform float4 rpRoadB24;
    uniform float4 rpRoadA25; uniform float4 rpRoadB25;
    uniform float4 rpRoadA26; uniform float4 rpRoadB26;
    uniform float4 rpRoadA27; uniform float4 rpRoadB27;
    uniform float4 rpRoadA28; uniform float4 rpRoadB28;
    uniform float4 rpRoadA29; uniform float4 rpRoadB29;
    uniform float4 rpRoadA30; uniform float4 rpRoadB30;
    uniform float4 rpRoadA31; uniform float4 rpRoadB31;
    uniform float4 rpRoadA32; uniform float4 rpRoadB32;
    uniform float4 rpRoadA33; uniform float4 rpRoadB33;
    uniform float4 rpRoadA34; uniform float4 rpRoadB34;
    uniform float4 rpRoadA35; uniform float4 rpRoadB35;
    uniform float4 rpRoadA36; uniform float4 rpRoadB36;
    uniform float4 rpRoadA37; uniform float4 rpRoadB37;
    uniform float4 rpRoadA38; uniform float4 rpRoadB38;
    uniform float4 rpRoadA39; uniform float4 rpRoadB39;
    uniform float4 rpRoadA40; uniform float4 rpRoadB40;
    uniform float4 rpRoadA41; uniform float4 rpRoadB41;
    uniform float4 rpRoadA42; uniform float4 rpRoadB42;
    uniform float4 rpRoadA43; uniform float4 rpRoadB43;
    uniform float4 rpRoadA44; uniform float4 rpRoadB44;
    uniform float4 rpRoadA45; uniform float4 rpRoadB45;
    uniform float4 rpRoadA46; uniform float4 rpRoadB46;
    uniform float4 rpRoadA47; uniform float4 rpRoadB47;
    uniform float4 rpVehG0; uniform float4 rpVehG1; uniform float4 rpVehG2;
    uniform float4 rpVehG3; uniform float4 rpVehG4; uniform float4 rpVehG5; // w = ground height under the vehicle
    uniform float4 rpVehG6; uniform float4 rpVehG7; uniform float4 rpVehG8;
    uniform float4 rpVehG9; uniform float4 rpVehG10; uniform float4 rpVehG11;

    // 1.0: 12 vehicles (was 6), so parked cars and traffic beyond the nearest six stay free of puddles too
    uniform float4 rpVehA0; uniform float4 rpVehB0; uniform float4 rpVehC0; uniform float4 rpVehD0;
    uniform float4 rpVehA1; uniform float4 rpVehB1; uniform float4 rpVehC1; uniform float4 rpVehD1;
    uniform float4 rpVehA2; uniform float4 rpVehB2; uniform float4 rpVehC2; uniform float4 rpVehD2;
    uniform float4 rpVehA3; uniform float4 rpVehB3; uniform float4 rpVehC3; uniform float4 rpVehD3;
    uniform float4 rpVehA4; uniform float4 rpVehB4; uniform float4 rpVehC4; uniform float4 rpVehD4;
    uniform float4 rpVehA5; uniform float4 rpVehB5; uniform float4 rpVehC5; uniform float4 rpVehD5;
    uniform float4 rpVehA6; uniform float4 rpVehB6; uniform float4 rpVehC6; uniform float4 rpVehD6;
    uniform float4 rpVehA7; uniform float4 rpVehB7; uniform float4 rpVehC7; uniform float4 rpVehD7;
    uniform float4 rpVehA8; uniform float4 rpVehB8; uniform float4 rpVehC8; uniform float4 rpVehD8;
    uniform float4 rpVehA9; uniform float4 rpVehB9; uniform float4 rpVehC9; uniform float4 rpVehD9;
    uniform float4 rpVehA10; uniform float4 rpVehB10; uniform float4 rpVehC10; uniform float4 rpVehD10;
    uniform float4 rpVehA11; uniform float4 rpVehB11; uniform float4 rpVehC11; uniform float4 rpVehD11;

#include "rp_shelter_cb.h.hlsl"

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
#include "rp_shelter.h.hlsl"

// 1.0: depth at screen pixel q, sampled through the depth slot's own uv (rtParams1). With render scaling / upscaling
// (XeSS, DLSS, FSR) the depth target is smaller than the frame, so Load(q) read the depth of another spot.
float rpDepthLoad(int2 q)
{
    float2 uv = (float2(q) + 0.5 - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
    return prepassDepthTexTex.SampleLevel(prepassDepthTex_sampler_, viewportCoordToRenderTarget(uv, rtParams1), 0).r;
}
// The level cubemap and native SSR are not exposed as a documented PostFX
// input. The stable fallback is the engine's directional SH9 sky ambient, which
// is native, shadow-independent and already used for material IBL.
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
