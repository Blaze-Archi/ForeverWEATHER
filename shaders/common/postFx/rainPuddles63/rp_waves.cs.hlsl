#define PFX_COMPUTE 1

#include "rp_waves.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// 1.5 simulated ripples. The water in the puddles is simulated instead of drawn: a damped wave equation on a grid of 3 cm
// cells around the camera - the shallow-water form of Navier-Stokes for small waves (the water's height carries it all),
// with its viscous term. Every raindrop that lands makes a small crater with a raised rim, every tyre that rolls through
// pushes the water aside, and the rings spread at the speed of real ripples (~0.3 m/s), cross, reflect and fade on their
// own. The grid moves with the camera in whole cells, so the water keeps its place in the world.
//
// Time stepping (Verlet, no velocity stored): h' = h + k (h - h_prev) + (c dt / dx)^2 lap(h) + (nu dt / dx^2) lap(h - h_prev)
// - the first two terms carry the motion on (k = the damping over one step), the third is the pull of the height
// differences, the fourth the viscosity: it damps short waves far faster than long ones (as k^2), so the grid-scale noise
// a crater stirs up dies within a few steps while the rings travel on. Stable here: c dt / dx is below 0.1.

// height of cell q in a packed water texture; still water outside the grid and in the calibration cell (0, 0)
float rpWaveHt(Texture2D<float4> tex, int2 q, int n, bool srgbRead)
{
    if (any(q < 0) || any(q >= n) || all(q == int2(0, 0)))
    {
        return 0.0;
    }
    float4 t = rpWaveRaw(tex.Load(int3(q + int2(dispatchRect.xy), 0)), srgbRead);
    return rpUnpack16(t.rg, RP_WAVE_HMAX);
}

PFX_NUMTHREADS
void main(uint3 dispatchThreadID : SV_DispatchThreadID)
{
    uint2 storePos;
    if (!postFxComputeThread(dispatchThreadID, storePos))
    {
        return;
    }
    const int2 c = int2(storePos) - int2(dispatchRect.xy);
    const int n = int(dispatchRect.z);
    if (all(c == int2(0, 0)))
    {
        pfxOut[storePos] = RP_WAVE_CAL;   // the calibration texel (see rpWaveRaw)
        return;
    }
    if (rpWaveC.w < 0.5)
    {
        pfxOut[storePos] = float4(rpPack16(0.0, RP_WAVE_HMAX), 0.5, 1.0);   // still water
        return;
    }
    // how each input texture reads (its own calibration texel)
    const bool srgbC = abs(waveCur.Load(int3(int2(dispatchRect.xy), 0)).r - 0.5) > 0.1;
    const bool srgbP = abs(wavePrev.Load(int3(int2(dispatchRect.xy), 0)).r - 0.5) > 0.1;

    // where this cell's water was in the grids the two inputs were written in (the grid follows the camera)
    const int2 qc = c + int2(round(rpWaveB.xy));
    const int2 qp = c + int2(round(rpWaveB.zw));
    const float h  = rpWaveHt(waveCur, qc, n, srgbC);
    const float hp = rpWaveHt(wavePrev, qp, n, srgbP);
    const float hL = rpWaveHt(waveCur, qc - int2(1, 0), n, srgbC);
    const float hR = rpWaveHt(waveCur, qc + int2(1, 0), n, srgbC);
    const float hD = rpWaveHt(waveCur, qc - int2(0, 1), n, srgbC);
    const float hU = rpWaveHt(waveCur, qc + int2(0, 1), n, srgbC);
    const float pL = rpWaveHt(wavePrev, qp - int2(1, 0), n, srgbP);
    const float pR = rpWaveHt(wavePrev, qp + int2(1, 0), n, srgbP);
    const float pD = rpWaveHt(wavePrev, qp - int2(0, 1), n, srgbP);
    const float pU = rpWaveHt(wavePrev, qp + int2(0, 1), n, srgbP);
    const float lapH = hL + hR + hD + hU - 4.0 * h;
    const float lapV = (hL - pL) + (hR - pR) + (hD - pD) + (hU - pU) - 4.0 * (h - hp);

    const float dx = rpWaveA.x;
    const float dt = rpWaveA.y;
    const float k = exp(-dt * rpWaveA.w);
    float hn = h + k * (h - hp) + (rpWaveA.z * dt * dt / (dx * dx)) * lapH + (rpWaveD.z * dt / (dx * dx)) * lapV;

    // raindrops: every cell of the world gets one now and then (a stable random number per cell and step, so a drop
    // lands at one place). A drop makes a crater about 5 cm wide with the water it pushed out raised around it: no water
    // is lost (a plain dent lowered the whole surface, which then sloped toward the still water at the grid's edges).
    const int2 wc = int2(round(rpWaveC.xy)) + c;
    const int stepI = int(round(rpWaveC.z)) & 0xFFFFFF;
    if (rpWaveE.x > 0.0)
    {
        float dent = 0.0;
        [unroll]
        for (int j = -1; j <= 1; j++)
        {
            [unroll]
            for (int i = -1; i <= 1; i++)
            {
                uint hh = rpHash3(int3(wc.x + i, wc.y + j, stepI));
                if (rpRand(hh) < rpWaveE.x)
                {
                    float2 o = float2(rpRand(rpPcg(hh ^ 0x68E31DA4u)), rpRand(rpPcg(hh ^ 0x1B873593u))) - 0.5;
                    float2 d = float2(float(i), float(j)) + o;
                    // drops differ in size: a few big ones make most of the rings
                    float big = 0.4 + 1.6 * rpRand(rpPcg(hh ^ 0xB5297A4Du));
                    dent += (exp(-dot(d, d) / 0.9) - 0.306) * big;   // 0.306: the dent's mean over its 3 x 3 cells
                }
            }
        }
        hn -= dent * rpWaveD.w;
    }

    // tyres rolling through: the tread pushes the water down and aside over the path it covered this frame (a capsule
    // from where the contact patch was to where it is), down under the tread, up in a ring around it (as much water as it
    // pushed away: a bow wave)
    const float2 Pw = (float2(wc) + 0.5) * dx;
    float4 tA[8] = { rpTyreA0, rpTyreA1, rpTyreA2, rpTyreA3, rpTyreA4, rpTyreA5, rpTyreA6, rpTyreA7 };
    float4 tB[8] = { rpTyreB0, rpTyreB1, rpTyreB2, rpTyreB3, rpTyreB4, rpTyreB5, rpTyreB6, rpTyreB7 };
    float4 tC[8] = { rpTyreC0, rpTyreC1, rpTyreC2, rpTyreC3, rpTyreC4, rpTyreC5, rpTyreC6, rpTyreC7 };
    [unroll]
    for (int ti = 0; ti < 8; ti++)
    {
        if (tC[ti].y > 0.75 && rpWaveD.x > 0.0)
        {
            const float spd = max(tB[ti].z, 0.0);
            if (spd > 0.2)
            {
                const float2 dir2 = tB[ti].xy;
                const float hw = max(tA[ti].w, 0.05);
                const float L = min(spd * rpWaveD.y, 2.0);
                const float2 d = Pw - tA[ti].xy;
                const float along = clamp(dot(d, dir2), -L, 0.0);
                const float2 e = d - dir2 * along;
                const float r2 = dot(e, e) / (hw * hw);
                if (r2 < 16.0)
                {
                    hn -= rpWaveD.x * min(spd, 15.0) * dt * (exp(-r2 * 1.5) - 0.267 * exp(-r2 * 0.4));
                }
            }
        }
    }

    // and the surface slowly settles back to level
    hn *= exp(-dt * 0.4);
    pfxOut[storePos] = float4(rpPack16(hn, RP_WAVE_HMAX), 0.5, 1.0);
}
