// STAND-IN for BeamNG.drive's own shaders/common/gbuffer.hlsl (not shipped, not the engine's code): just enough of its
// interface, as the mod's shaders use it, for tools/ci/check_shaders.sh to check syntax and types. The game
// compiles the shaders against its real headers.
#ifndef STUB_GBUFFER_HLSL
#define STUB_GBUFFER_HLSL
float ndcToRealDepth(float ndc, float4 pp) { return pp.z / max(ndc - pp.w, 1e-6); }
float ndcToRealDepth(float ndc, float2 pp) { return pp.x / max(ndc - pp.y, 1e-6); }
float realToEyeLinearDepth(float d, float4 pp) { return d / max(abs(pp.y), 1e-6); }
struct ColorSH9 { float3 c[9]; };
ColorSH9 getColorSH9(float4 sh[9]) { ColorSH9 r; [unroll] for (int i = 0; i < 9; i++) r.c[i] = sh[i].xyz; return r; }
float3 evalSHIrradiance(ColorSH9 sh, float3 d) { return sh.c[0] + sh.c[1] * d.y + sh.c[2] * d.z + sh.c[3] * d.x; }
float4 decodeGBuffer(Texture2D<float4> dT, SamplerState dS, Texture2D<float4> pT, SamplerState pS, float2 uv, float4 pp)
{
    float d = dT.SampleLevel(dS, uv, 0).r;
    float4 n = pT.SampleLevel(pS, uv, 0);
    return float4(normalize(n.xyz * 2.0 - 1.0), ndcToRealDepth(d, pp));
}
#endif
