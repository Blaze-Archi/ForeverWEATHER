// STAND-IN for BeamNG.drive's own shaders/common/postFx/postFxCompute.h.hlsl (not shipped, not the engine's code): just enough of its
// interface, as the mod's shaders use it, for tools/ci/check_shaders.sh to check syntax and types. The game
// compiles the shaders against its real headers.
#ifndef STUB_POSTFXCOMPUTE_H
#define STUB_POSTFXCOMPUTE_H
RWTexture2D<float4> pfxOut : register(u0);
#define PFX_NUMTHREADS [numthreads(8, 8, 1)]
bool postFxComputeThread(uint3 id, out uint2 storePos)
{
    storePos = id.xy + uint2(dispatchRect.xy);
    return all(float2(id.xy) < dispatchRect.zw);
}
PFXVertToPix processPostFxCompute(uint3 id)
{
    PFXVertToPix o;
    float2 uv = (float2(id.xy) + 0.5) / max(dispatchRect.zw, float2(1.0, 1.0));
    o.hpos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    o.uv0 = viewportCoordToRenderTarget(uv, rtParams0);
    o.uv1 = viewportCoordToRenderTarget(uv, rtParams1);
    o.uv2 = viewportCoordToRenderTarget(uv, rtParams2);
    o.uv3 = viewportCoordToRenderTarget(uv, rtParams3);
    o.wsEyeRay = mul(matScreenToWorld, float4(o.hpos.xy, 1.0, 1.0)).xyz;
    return o;
}
#endif
