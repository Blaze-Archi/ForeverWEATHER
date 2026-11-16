#define PFX_COMPUTE 1

#include "rp_lens.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// Camera lens droplets, 1.2.
//
// Rain lands all over the lens. Every drop belongs to the EPOCH (one unit of the life clock, rpLensC; the clock runs
// faster at speed) in which it landed, and every epoch has its own two jittered grids in LANDING space: big drops and
// small ones. Since an epoch began, the airflow has moved all of its drops outward from the screen centre by the same
// factor exp(dF) (dF = flow since then, Lua: rpLensE..G). That is how water is blown off a lens: speed ~ distance from
// the centre, so drops in the middle hardly move and drops near the edges leave the screen. Without any per-drop state:
//   * a pixel maps itself back into each epoch's landing space (one multiply) and tests the one cell it falls in: a drop
//     stays inside the middle half of its cell (centre jittered in 0.25..0.75, extent at most a quarter cell);
//   * a drop appears at its own moment within its epoch, spreads as it lands, and fades and shrinks as it dries
//     (4-11 clock units); 12 epochs are kept, so every drop has gone before its epoch drops out;
//   * landing is uniform, and scaling about the centre keeps it uniform: no clear ring, no crowding at the edges.
// Shape: a round drop (atlas tiles 0-7) whose half toward the centre is a little longer and narrower: a hint of a teardrop.
// (Until 1.1.1 the drops lived on a log-polar grid that started outside a clear centre and swept out much faster.)

static const float RP_TILE_IN = 112.0 / 128.0;

float3 rpLensLoad(int2 q)
{
    return colorTex.Load(int3(rpClampPix(q), 0)).rgb;
}

bool rpAtlasValid()
{
    float4 m = dropTexTex.SampleLevel(dropTex_sampler_, RP_ATLAS_CAL_UV, 0.0);
    float4 d = abs(m - float4(0.251, 0.749, 0.502, 1.0));
    return max(max(d.x, d.y), max(d.z, d.w)) < 0.06;
}

float4 rpLensShape(float2 q, float tile, float lod, bool atlas)
{
    float4 s = float4(0.0, 0.0, 0.0, 0.0);
    float inside = step(max(abs(q.x), abs(q.y)), 0.999);
    if (atlas)
    {
        float4 a = dropTexTex.SampleLevel(dropTex_sampler_, rpAtlasUV(q, tile), lod);
        s = float4(a.xy * 2.0 - 1.0, a.z, a.w);
    }
    else
    {
        float rr = dot(q, q);
        s = float4(q * 0.9, sqrt(saturate(1.0 - rr)), saturate((1.0 - sqrt(rr)) * 5.0));
    }
    return s * inside;
}

PFX_NUMTHREADS
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 storePos;
    if (!postFxComputeThread(dispatchThreadID, storePos))
    {
        return;
    }
    const int2 p = int2(storePos);
    const float4 src = colorTex.Load(int3(p, 0));

    if (rpLensD.w < 0.5 || rpLensA.y < 0.001 || rpLensA.x < 0.001)
    {
        pfxOut[storePos] = src;
        return;
    }

    const float Hpx = max(dispatchRect.w, 1.0);
    const float2 sp = (float2(p) + 0.5 - (dispatchRect.xy + 0.5 * dispatchRect.zw)) / Hpx;  // screen heights, y down
    const float clearR = max(rpLensB.x, 0.0);
    const float tailK = max(rpLensB.z, 1.0);
    const float pinch = saturate(rpLensD.x);
    const float R0 = max(rpLensA.z, 0.002);
    const float frac0 = saturate(rpLensC.x);
    const int ep0 = int(rpLensC.y + 0.5);
    const bool atlasOK = rpAtlasValid();

    float dF[12] = { rpLensE.x, rpLensE.y, rpLensE.z, rpLensE.w, rpLensF.x, rpLensF.y, rpLensF.z, rpLensF.w,
                     rpLensG.x, rpLensG.y, rpLensG.z, rpLensG.w };

    float  bestScore = 0.0;
    float2 bestQ = float2(0.0, 0.0);
    float  bestRadPx = 1.0;
    float  bestA = 0.0;
    float  bestTile = 0.0;
    float  bestSy = 1.0;
    float2 bestRadial = float2(0.0, 1.0);

    [unroll]
    for (int k = 0; k < 12; k++)
    {
        const float sc = exp(-max(dF[k], 0.0));     // landing space = screen x exp(-flow since the epoch began)
        const float2 xl = sp * sc;
        const int ep = ep0 - k;
        [unroll]
        for (int gi = 0; gi < 2; gi++)
        {
            // cell = 4 x the largest extent of its drops (big: 1.6 R0 x tail 1.45; small: 0.8 R0 x 1.45)
            const float cs = R0 * ((gi == 0) ? 9.5 : 4.8);
            int2 c = int2(floor(xl / cs));
            uint h = rpHash3(int3(c.x, c.y, ep * 2 + gi + 7001));
            float r1 = rpRand(h);
            float pres = saturate((rpLensA.y * ((gi == 0) ? 0.30 : 0.55) - r1) / 0.04);
            if (pres > 0.001)
            {
                float r2 = rpRand(rpPcg(h ^ 0x1B873593u));
                float r3 = rpRand(rpPcg(h ^ 0xE6546B64u));
                float age = float(k) + frac0 - r2;                     // clock units since it landed
                float life = lerp(4.0, 11.0, r3);
                if (age > 0.0 && age < life)
                {
                    float r4 = rpRand(rpPcg(h ^ 0x85EBCA6Bu));
                    float r5 = rpRand(rpPcg(h ^ 0x27D4EB2Fu));
                    float r6 = rpRand(rpPcg(h ^ 0x165667B1u));
                    float2 cl = (float2(c) + 0.25 + 0.5 * float2(r4, r5)) * cs;    // where it landed
                    float keep = (clearR > 0.001) ? smoothstep(clearR * 0.75, clearR, length(cl)) : 1.0;
                    float2 cen = cl / sc;                                          // where the airflow has moved it
                    float rc = length(cen);
                    float2 radial = (rc > 0.01) ? cen / rc : float2(0.0, 1.0);
                    float2 tangential = float2(-radial.y, radial.x);

                    float R = R0 * ((gi == 0) ? (1.0 + 0.6 * r6) : (0.35 + 0.45 * r6));
                    R *= lerp(0.55, 1.0, smoothstep(0.0, 0.12, age));                 // spreads as it lands
                    R *= lerp(1.0, 0.72, smoothstep(0.72 * life, life, age));         // shrinks as it dries
                    float a = pres * keep * (1.0 - smoothstep(0.78 * life, life, age));

                    float2 d = sp - cen;
                    float dr = dot(d, radial);
                    float sy = (dr < 0.0) ? tailK : 1.0;                     // the half toward the centre is longer...
                    float qy = dr / (R * sy);
                    float qx = dot(d, tangential) / R;
                    qx /= max(1.0 - pinch * saturate(-qy), 0.4);            // ...and narrows a little: a hint of a tip
                    float2 q = float2(qx, qy);
                    float rr = dot(q, q);
                    float score = (1.0 - rr) * a;
                    if (rr < 1.0 && a > 0.001 && score > bestScore)
                    {
                        bestScore = score;
                        bestQ = q;
                        bestRadPx = max(R * Hpx, 1.0);
                        bestA = a;
                        bestTile = floor(frac(r6 * 13.7) * 7.999);
                        bestSy = sy;
                        bestRadial = radial;
                    }
                }
            }
        }
    }

    float3 col = src.rgb;
    if (bestA > 0.001)
    {
        // out of focus: sample the shape a little blurred
        float lod = clamp(log2(max(56.0 / bestRadPx, 1.0)) + 1.5, 0.0, 3.0);
        float4 sh = rpLensShape(bestQ, bestTile, lod, atlasOK);
        float cover = saturate(sh.w * bestA * rpLensA.x);
        if (cover > 0.001)
        {
            float2 radial = bestRadial;
            float2 tangential = float2(-radial.y, radial.x);
            float2 nn = sh.xy;
            float2 nScr = nn.x * tangential + (nn.y / bestSy) * radial;

            // A drop on the lens is a small ball lens: it shows a displaced, inverted, defocused view of the scene.
            float2 o = -nScr * bestRadPx * 2.0 * rpLensA.w;
            o = clamp(o, float2(-96.0, -96.0), float2(96.0, 96.0));
            int b = clamp(int(bestRadPx * 0.22), 1, 10);
            int2 q0 = p + int2(round(o));
            float3 refr = rpLensLoad(q0) * 0.28
                        + (rpLensLoad(q0 + int2(b, 0)) + rpLensLoad(q0 - int2(b, 0))
                         + rpLensLoad(q0 + int2(0, b)) + rpLensLoad(q0 - int2(0, b))) * 0.18;

            float thick = saturate(sh.z);
            float rim = 1.0 - smoothstep(0.0, 0.5, thick);
            float2 upT = float2(dot(float2(0.0, -1.0), tangential), dot(float2(0.0, -1.0), radial));
            float hl = pow(saturate(dot(nn, upT) * 1.2), 6.0) * thick;

            float3 dcol = refr * (1.0 - 0.50 * rim);
            dcol += hl * (0.08 + 0.6 * rpLuma(refr));
            col = lerp(col, dcol, cover);
        }
    }

    pfxOut[storePos] = float4(col, src.a);
}
