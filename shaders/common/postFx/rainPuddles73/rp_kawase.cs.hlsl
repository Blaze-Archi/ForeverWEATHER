#define PFX_COMPUTE 1

#include "rp_kawase.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// 1.6 Dual Kawase blur for the fogged glass (Bjorge, "Bandwidth-Efficient Rendering", SIGGRAPH 2015).
//   downsample: the centre (x4) and four diagonal taps one input texel out. Each bilinear tap averages a 2 x 2 block,
//               so one output texel gathers a 4 x 4 footprint of the level above it.
//   upsample:   four taps one input texel out along the axes (x1) and four half a texel out on the diagonals (x2): a
//               tent that hides the blocky smaller levels.
// Three levels down and two up give a wide, smooth blur (about 30 px at full resolution with the default offset) from
// five tiny passes whose cost falls with every level: the frame is read once, at half resolution. Lua skips all five
// whenever no glass is fogged.
//
// Every level is stored premultiplied: rgb = colour x weight, a = weight. The first pass weighs the frame by where its
// scene lies: from the driver's seat the cabin in front of the glass (dashboard, pillars, roof liner, steering wheel)
// weighs 0.03, everything beyond the glass 1, so the blur stays a blur of what is seen THROUGH the glass and never smears
// the dark interior into it. The glass passes divide by a (normalised convolution).
//
// The engine may keep a named target as 8-bit fixed point read through an sRGB view (see rp_lib.h.hlsl): texel (0, 0)
// of every level holds the calibration value, and a level that reads back converted is put back (rpWaveRaw).

// weight of the scene at viewport uv vp (first pass): ~0 for the player's own cabin seen from its seat, else 1
float rpKawWeight(float2 vp, float3 ray0, float3 camFwd)
{
    if (rpKawA.w < 0.5)
    {
        return 1.0;
    }
    const float ndc = kawDepthTex.SampleLevel(kawDepth_sampler_, viewportCoordToRenderTarget(vp, rtParams1), 0).r;
    if (rpIsSkyDepth(ndc))
    {
        return 1.0;
    }
    const float lin = abs(ndcToRealDepth(ndc, projParams)) / max(abs(projParams.y), 1e-6);
    const float3 P = rpCam.xyz + rpReconstruct(ray0, camFwd, lin, rpMode.y, rpMode.z);
    float3 lp = float3(0.0, 0.0, 0.0);
    const float inner = rpBoxInner(P, rpKawB, rpKawC, rpKawD, float4(rpKawE.xyz, 0.0), lp);
    float cabin = smoothstep(-0.02, 0.06, inner);
    // the hood seen through the windshield lies inside the car's box too, but beyond the glass: it is no cabin
    if (rpKawF.w > 0.5)
    {
        cabin *= 1.0 - smoothstep(0.0, 0.06, dot(P - rpKawF.xyz, rpKawG.xyz));
    }
    return lerp(1.0, 0.03, cabin);
}

// one tap at viewport uv vp: (colour x weight, weight)
float4 rpKawTap(float2 vp, float2 lo, float2 hi, bool first, bool srgb, float3 ray0, float3 camFwd)
{
    vp = clamp(vp, lo, hi);
    float4 c = kawInTex.SampleLevel(kawIn_sampler_, viewportCoordToRenderTarget(vp, rtParams0), 0);
    if (first)
    {
        const float w = rpKawWeight(vp, ray0, camFwd);
        const float3 rgb = rpSafe(c.rgb, float3(0.0, 0.0, 0.0));
        return float4(rgb * w, w);
    }
    c = rpWaveRaw(c, srgb);
    return float4(rpSafe(c.rgb, float3(0.0, 0.0, 0.0)), rpBadF(c.a) ? 0.0 : saturate(c.a));
}

PFX_NUMTHREADS
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 storePos;
    if (!postFxComputeThread(dispatchThreadID, storePos))
    {
        return;
    }
    const int2 t = int2(storePos) - int2(dispatchRect.xy);
    if (all(t == int2(0, 0)))
    {
        pfxOut[storePos] = RP_WAVE_CAL;   // the calibration texel (see rpWaveRaw)
        return;
    }
    const bool first = rpKawA.z > 0.5;
    const float2 vp = (float2(t) + 0.5) / max(dispatchRect.zw, float2(1.0, 1.0));   // this texel, viewport uv

    // one input texel in viewport uv (the input may be larger than its viewport: render scaling / upscalers)
    uint tw, th;
    kawInTex.GetDimensions(tw, th);
    const float2 a0 = viewportCoordToRenderTarget(float2(0.0, 0.0), rtParams0);
    const float2 a1 = viewportCoordToRenderTarget(float2(1.0, 1.0), rtParams0);
    const float2 span = max(abs(a1 - a0), float2(1e-6, 1e-6));
    const float2 texel = (1.0 / float2(max(tw, 1u), max(th, 1u))) / span;
    const float2 lo = 0.5 * texel;                    // taps stay inside the viewport: nothing from beyond it bleeds in
    const float2 hi = 1.0 - 0.5 * texel;
    const bool srgb = !first && abs(kawInTex.Load(int3(0, 0, 0)).r - 0.5) > 0.1;

    float3 ray0 = float3(0.0, 1.0, 0.0);
    float3 camFwd = float3(0.0, 1.0, 0.0);
    if (first && rpKawA.w > 0.5)
    {
        // (the eye ray of this texel serves all five taps: they lie within two pixels of it)
        PFXVertToPix IN = processPostFxCompute(dispatchThreadID);
        PFXVertToPix INx = processPostFxCompute(dispatchThreadID + uint3(1, 0, 0));
        PFXVertToPix INy = processPostFxCompute(dispatchThreadID + uint3(0, 1, 0));
        ray0 = IN.wsEyeRay;
        camFwd = cross(INx.wsEyeRay - ray0, INy.wsEyeRay - ray0);
        camFwd /= max(length(camFwd), 1e-12);
        camFwd = (dot(camFwd, ray0) < 0.0) ? -camFwd : camFwd;
    }

    const float o = clamp(rpKawA.y, 0.25, 4.0);
    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    if (rpKawA.x < 0.5)
    {
        const float2 d = texel * o;
        sum  = rpKawTap(vp, lo, hi, first, srgb, ray0, camFwd) * 4.0;
        sum += rpKawTap(vp + float2(-d.x, -d.y), lo, hi, first, srgb, ray0, camFwd);
        sum += rpKawTap(vp + float2( d.x, -d.y), lo, hi, first, srgb, ray0, camFwd);
        sum += rpKawTap(vp + float2(-d.x,  d.y), lo, hi, first, srgb, ray0, camFwd);
        sum += rpKawTap(vp + float2( d.x,  d.y), lo, hi, first, srgb, ray0, camFwd);
        sum *= 1.0 / 8.0;
    }
    else
    {
        const float2 d = texel * o;
        const float2 h = d * 0.5;
        sum  = rpKawTap(vp + float2(-d.x, 0.0), lo, hi, false, srgb, ray0, camFwd);
        sum += rpKawTap(vp + float2( d.x, 0.0), lo, hi, false, srgb, ray0, camFwd);
        sum += rpKawTap(vp + float2(0.0, -d.y), lo, hi, false, srgb, ray0, camFwd);
        sum += rpKawTap(vp + float2(0.0,  d.y), lo, hi, false, srgb, ray0, camFwd);
        sum += rpKawTap(vp + float2(-h.x, -h.y), lo, hi, false, srgb, ray0, camFwd) * 2.0;
        sum += rpKawTap(vp + float2( h.x, -h.y), lo, hi, false, srgb, ray0, camFwd) * 2.0;
        sum += rpKawTap(vp + float2(-h.x,  h.y), lo, hi, false, srgb, ray0, camFwd) * 2.0;
        sum += rpKawTap(vp + float2( h.x,  h.y), lo, hi, false, srgb, ray0, camFwd) * 2.0;
        sum *= 1.0 / 12.0;
    }
    pfxOut[storePos] = float4(rpSafe(sum.rgb, float3(0.0, 0.0, 0.0)), rpBadF(sum.a) ? 0.0 : saturate(sum.a));
}
