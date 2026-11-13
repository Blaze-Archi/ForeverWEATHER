#define PFX_COMPUTE 1

#include "rp_lens.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// Camera lens droplets.
//
// Droplets live on a LOG-POLAR grid around the screen centre: x = angle, y = log(radius). Moving outward is a pure
// translation in y, so the whole grid scrolls outward by the flow value Lua integrates from the smoothed vehicle
// speed (rpLensC/D). Consequences, all without any per-droplet state:
//   * every droplet travels away from the centre, accelerating as it goes (speed ~ radius), like water blown off;
//   * the scroll rate (and therefore how often a droplet crosses its spawn radius = spawn rate) follows the speed;
//   * a droplet that passes the screen edge is simply off screen - nothing accumulates;
//   * droplets only become visible beyond their own spawn radius, which is never inside the clear central zone.
// Log-polar is conformal, so distances are measured in grid cells (cheap, no trig per droplet). Three layers with
// 28 / 44 / 70 angular cells give big-rare, medium and small-many droplets. 3 x 12 cells per pixel.

static const float RP_TILE_IN = 112.0 / 128.0;
static const float RP_TWO_PI = 6.2831853;

float3 rpLensLoad(int2 q)
{
    return colorTex.Load(int3(rpClampPix(q), 0)).rgb;
}

bool rpAtlasValid()
{
    float4 m = dropTexTex.SampleLevel(dropTex_sampler_, float2(0.875, 0.875), 0.0);
    float4 d = abs(m - float4(0.251, 0.749, 0.502, 1.0));
    return max(max(d.x, d.y), max(d.z, d.w)) < 0.06;
}

float4 rpLensShape(float2 q, float tile, float lod, bool atlas)
{
    float4 s = float4(0.0, 0.0, 0.0, 0.0);
    float inside = step(max(abs(q.x), abs(q.y)), 0.999);
    if (atlas)
    {
        float2 t = float2(fmod(tile, 4.0), floor(tile * 0.25));
        float2 uv = (t + 0.0625 + (q * 0.5 + 0.5) * RP_TILE_IN) * 0.25;
        float4 a = dropTexTex.SampleLevel(dropTex_sampler_, uv, lod);
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
    const float r = length(sp);
    const float clearR = max(rpLensB.x, 0.0);
    // Nothing can reach this far in: droplets appear beyond clearR and their inward tails stay short of 0.55 * clearR.
    if (r < clearR * 0.55)
    {
        pfxOut[storePos] = src;
        return;
    }

    const float theta = atan2(sp.y, sp.x);
    const float rho = log(max(r, 1e-4));
    const float stretch = max(rpLensB.z, 1.0);
    const bool atlasOK = rpAtlasValid();

    float scrollF[3] = { rpLensC.x, rpLensC.y, rpLensC.z };
    float scrollI[3] = { rpLensD.x, rpLensD.y, rpLensD.z };
    float cellsL[3] = { 28.0, 44.0, 70.0 };      // must match LENS_CELLS in rainPuddles.lua
    float densL[3] = { 0.35, 0.60, 0.90 };
    float sizeL[3] = { 1.55, 1.00, 0.62 };

    float  bestScore = 0.0;
    float2 bestQ = float2(0.0, 0.0);
    float  bestRadPx = 1.0;
    float  bestA = 0.0;
    float  bestTile = 0.0;
    float  bestSy = 1.0;

    [unroll]
    for (int l = 0; l < 3; l++)
    {
        float dA = RP_TWO_PI / cellsL[l];
        int Ni = int(cellsL[l] + 0.5);
        int iShift = int(scrollI[l] + 0.5);
        float2 g = float2(theta / dA + 0.37 * float(l), rho / dA - scrollF[l]);
        int2 c0 = int2(floor(g));

        [unroll]
        for (int ky = -1; ky <= 2; ky++)          // +2: inward tails of droplets further out
        {
            [unroll]
            for (int kx = -1; kx <= 1; kx++)
            {
                int2 c = c0 + int2(kx, ky);
                int cx = ((c.x % Ni) + Ni) % Ni;   // angle wraps around the full circle
                int cy = c.y - iShift;             // global radial cell: fixed to the droplet while it scrolls out
                uint h = rpHash3(int3(cx, cy, 977 + l * 131));
                float r1 = rpRand(h);
                float pres = saturate((rpLensA.y * densL[l] - r1) / 0.08);
                if (pres > 0.001)
                {
                    float r2 = rpRand(rpPcg(h ^ 0x1B873593u));
                    float r3 = rpRand(rpPcg(h ^ 0xE6546B64u));
                    float r4 = rpRand(rpPcg(h ^ 0x85EBCA6Bu));
                    float r5 = rpRand(rpPcg(h ^ 0x27D4EB2Fu));
                    float r6 = rpRand(rpPcg(h ^ 0x165667B1u));

                    float2 cen = float2(c) + 0.2 + 0.6 * float2(r2, r3);
                    float rc = exp((cen.y + scrollF[l]) * dA);           // droplet's screen radius from the centre

                    // Spawn beyond the clear zone (biased outward); some evaporate before the edge, most leave it.
                    float spawnR = clearR + 0.05 + 0.50 * r4 * r4;
                    float endR = lerp(0.85, 1.6, r5);
                    float life = smoothstep(spawnR, spawnR + 0.05, rc) * (1.0 - smoothstep(endR, endR + 0.15, rc));

                    float radS = rpLensA.z * sizeL[l] * (0.6 + 0.8 * r6) * sqrt(clamp(rc, 0.2, 1.3));
                    radS *= lerp(0.55, 1.0, smoothstep(spawnR, spawnR + 0.08, rc));     // spreads as it lands
                    float radC = min(radS / max(rc * dA, 1e-5), 0.42);                  // radius in cells

                    float2 d = g - cen;
                    float sy = (d.y < 0.0) ? stretch : 1.0;                  // tail toward the centre at speed
                    float2 q = float2(d.x / radC, d.y / (radC * sy));
                    float rr = dot(q, q);
                    float a = pres * life;
                    float score = (1.0 - rr) * a;
                    if (rr < 1.0 && a > 0.001 && score > bestScore)
                    {
                        bestScore = score;
                        bestQ = q;
                        bestRadPx = max(radC * rc * dA * Hpx, 1.0);
                        bestA = a;
                        bestTile = floor(r6 * 7.999);
                        bestSy = sy;
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
            float2 radial = sp / max(r, 1e-4);
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
