// STAND-IN for BeamNG.drive's own shaders/common/postFx/postFx.h.hlsl (not shipped, not the engine's code): just enough of its
// interface, as the mod's shaders use it, for tools/ci/check_shaders.sh to check syntax and types. The game
// compiles the shaders against its real headers.
#ifndef STUB_POSTFX_H
#define STUB_POSTFX_H
// stub of the engine header, modelled on how the mod uses it
#define uniform_sampler2D(name, reg) Texture2D<float4> name##Tex : register(t##reg); SamplerState name##_sampler_ : register(s##reg);
#define TEX_SAMPLER(name) name##Tex, name##_sampler_
#define POSTFX_UNIFORMS \
    float4 rtParams0; float4 rtParams1; float4 rtParams2; float4 rtParams3; float4 rtParams4; \
    float4 projParams; float4 dispatchRect; float4x4 matScreenToWorld; float3 eyePosWorld; float pad0;
#endif
