// STAND-IN for BeamNG.drive's own shaders/common/postFx/postFx.hlsl (not shipped, not the engine's code): just enough of its
// interface, as the mod's shaders use it, for tools/ci/check_shaders.sh to check syntax and types. The game
// compiles the shaders against its real headers.
#ifndef STUB_POSTFX_HLSL
#define STUB_POSTFX_HLSL
struct PFXVertToPix { float4 hpos; float2 uv0; float2 uv1; float2 uv2; float2 uv3; float3 wsEyeRay; };
float2 viewportCoordToRenderTarget(float2 uv, float4 rtParams) { return uv * rtParams.zw + rtParams.xy; }
#endif
