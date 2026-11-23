#define PFX_COMPUTE 1

#include "rp_glass.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// 1.5 glass water. Up to 1.4 a wiper simply hid the drops wherever a blade had passed, and new ones appeared there one by
// one as rain landed: a clean arc that stayed clean. Here the water on the windshield is a field that lives on:
//   * rain lands on the glass and beads it up again after every wipe - a new set of drops over the wiped arc;
//   * the water runs with gravity, the airflow and the car's acceleration once those beat its hold on the glass (as the
//     windshield pass's beads), so a wiped arc also refills from its edges and the old water moves off;
//   * every blade takes along what it sweeps and piles it up right ahead of itself: the water rides with the blade and
//     stays as a line of big drops where it turns and along its parked position, until it runs off;
//   * behind the blade stays a thin, streaky film (a worn rubber leaves some lines wetter than others) that beads up and
//     dries in about a second: the hazy smear after a wipe;
//   * water pushed or blown past the edge of the glass sits a while on the body beside it.
// Glass coordinates (the field moves with the car); a step into #rpGlassA and a copy back into #rpGlassB each frame.

// (water, film, 1.6 fog) of texel t; dry and clear outside the field (water that leaves it has run off the car)
float3 rpGlassLoad(int2 t, int2 n)
{
    if (any(t < 0) || any(t >= n))
    {
        return float3(0.0, 0.0, 0.0);
    }
    const float4 v = glassPrev.Load(int3(t + int2(dispatchRect.xy), 0));
    return float3(isfinite(v.x) ? clamp(v.x, 0.0, 4.0) : 0.0, isfinite(v.y) ? saturate(v.y) : 0.0,
                  isfinite(v.z) ? clamp(v.z, 0.0, 1.5) : 0.0);
}

// the same between texels (bilinear); s in field texture units (0..1)
float3 rpGlassAt(float2 s, int2 n)
{
    const float2 g = s * float2(n) - 0.5;
    const float2 g0 = floor(g);
    const float2 f = g - g0;
    const int2 i0 = int2(g0);
    return lerp(lerp(rpGlassLoad(i0, n), rpGlassLoad(i0 + int2(1, 0), n), f.x),
                lerp(rpGlassLoad(i0 + int2(0, 1), n), rpGlassLoad(i0 + int2(1, 1), n), f.x), f.y);
}

// field texture coordinates of glass point q (pc units: half heights, the same in x and y)
float2 rpGlassTexOf(float2 q, float aspectP, float m)
{
    return float2(q.x / aspectP, q.y) / (2.0 * m) + 0.5;
}

// how wet blade b leaves the glass at radius rho: a worn rubber leaves some lines wetter than others (streaks ~4 mm)
float rpGlassStreak(float rho, int b)
{
    const float u = rho * 90.0;
    const float i = floor(u);
    float f = u - i;
    f = f * f * (3.0 - 2.0 * f);
    const float a = rpRand(rpHash3(int3(int(i), b, 4242)));
    const float c = rpRand(rpHash3(int3(int(i) + 1, b, 4242)));
    const float s = lerp(a, c, f);
    return s * s;
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
    const int2 n = int2(dispatchRect.zw);
    if (rpGlassA.y > 0.5)
    {
        // the copy back into #rpGlassB
        pfxOut[storePos] = float4(rpGlassLoad(t, n), 1.0);
        return;
    }
    if (rpGlassA.z < 0.5)
    {
        pfxOut[storePos] = float4(0.0, 0.0, 0.0, 1.0);               // a new pane starts dry
        return;
    }
    const float dt = rpGlassA.x;
    const float m = max(rpGlassA.w, 1.0);
    const float halfW = max(rpWindA.w, 0.1);
    const float halfH = max(rpWindB.w, 0.1);
    const float aspectP = halfW / halfH;
    const float2 uvG = ((float2(t) + 0.5) / float2(n) * 2.0 - 1.0) * m;  // glass uv (the pane is -1..1)
    const float2 pc = float2(uvG.x * aspectP, uvG.y);
    const float onGlass = rpPaneAperture(uvG, halfW, halfH);
    const float3 old = rpGlassLoad(t, n);

    // ---- the water runs once the force on it (gravity, airflow, acceleration) beats its hold on the glass; the lines the
    // blades pushed together (big drops) go first
    const float2 F = rpWindN.xy;
    const float Fm = length(F);
    const float adh = 3.75;                                          // a base-size bead (rpWindAdhesion)
    const float mob = saturate((Fm - 0.7 * adh) / (1.5 * adh));
    const float mobW = saturate(mob + 0.6 * saturate(old.x - 1.0));
    const float vms = mobW * min(0.04 + 0.015 * Fm, 0.6);             // m/s along the glass
    const float2 vel = (Fm > 1e-4) ? F / Fm * (vms / halfH) : float2(0.0, 0.0);   // pc units per second
    float W = (vms > 1e-4) ? rpGlassAt(rpGlassTexOf(pc - vel * dt, aspectP, m), n).x : old.x;
    float S = old.y;

    // ---- rain lands on the glass, not under a roof (the body beside it is the body droplets' business)
    const float rate = max(rpWindH.w, 0.0) * 0.45;                   // beaded all over after ~2 rain-clock units
    W += rate * dt * rpGlassB.y * onGlass * max(1.0 - W, 0.0);

    // ---- it evaporates (slowly); on the body strip it runs off quicker
    W *= exp(-dt * (rpGlassB.z + 0.35 * (1.0 - onGlass)));

    // ---- 1.6 glass fog: a fine mist on the outside of the glass (drizzle and fog drops too small to bead, condensation
    // on glass cooled by the air rushing over it). It forms toward how fogged the glass gets in this air (rpGlassC.x, from
    // Lua: humidity, rain, the clock, speed) and clears slowly when the air dries. Water that moves washes it off - a drop
    // running down or up the glass cuts a clear channel, the lines the blades leave take the mist around them in - while a
    // still film of beads only thins it. Left alone long enough, the mist grows into beads of its own, which join the
    // water (and run once the force on them beats their hold). The blades clear it below.
    float Fg = old.z;
    {
        const float tgt = max(rpGlassC.x, 0.0) * onGlass;
        const float kF = (tgt > Fg) ? max(rpGlassC.y, 0.0) : max(rpGlassC.z, 0.0);
        Fg += (tgt - Fg) * (1.0 - exp(-dt * kF));
        const float washK = max(rpGlassC.w, 0.0) * saturate(W) * (0.12 + 2.5 * mobW) + 0.8 * saturate(W - 1.0);
        Fg *= exp(-dt * washK);
        const float grow = 0.035 * saturate((Fg - 0.55) / 0.45) * onGlass;     // fogged over: beads condense out of it
        W += grow * dt * max(1.0 - W, 0.0) * 1.5;
        Fg = clamp(Fg - grow * dt * 0.5, 0.0, 1.5);
    }

    // ---- the blades: what one swept this frame is gone, with a film left behind, and piles up right ahead of it
    const float flags = rpWindE.w;
    float inSweep = 0.0;                                             // 1.5.1: some blade's arc covers this texel
    if (fmod(flags, 2.0) > 0.5)
    {
        float4 bq[4];
        float2 brr[4];
        float4 bph;
        const int nb = rpBladeSetup(aspectP, bq, brr, bph);
        const float tc = rpWindE.x;
        const float sweepT = max(rpWindE.y, 0.05);
        const bool cosE = fmod(floor(flags / 8.0), 2.0) > 0.5;
        const float wBefore = W;
        float swept = 0.0;
        float gain = 0.0;
        [unroll]
        for (int b = 0; b < 4; b++)
        {
            if (b < nb)
            {
                const float4 bl = bq[b];
                const float2 d = pc - bl.xy;
                const float rho = length(d);
                const float rng = (bl.w >= 0.0) ? max(bl.w, 1e-3) : min(bl.w, -1e-3);
                const float x = rpWrapPi(atan2(d.y, d.x + 1e-9) - bl.z) / rng;
                const float xNow = rpBladeX(tc, sweepT, bph[b], cosE);
                const float xPrev = rpBladeX(tc - dt, sweepT, bph[b], cosE);
                const float lo = min(xPrev, xNow);
                const float hi = max(xPrev, xNow);
                inSweep = max(inSweep, (rho > brr[b].x && rho < brr[b].y && x >= 0.0 && x <= 1.0) ? 1.0 : 0.0);
                if (hi - lo > 1e-5)
                {
                    if (rho > brr[b].x && rho < brr[b].y && x >= lo && x <= hi)
                    {
                        // swept this frame: the blade took the water along; a streaky film stays behind it
                        swept = 1.0;
                        S = max(S, rpGlassB.x * (0.3 + 0.7 * rpGlassStreak(rho, b)) * saturate(wBefore * 1.3 + 0.15));
                    }
                    else if (rho > brr[b].x - 0.03 && rho < brr[b].y + 0.02)
                    {
                        // just ahead of the blade: what it swept at this radius this frame lands here, in a band as
                        // wide as its motion this frame (so the next frame's sweep picks it all up again) and at least
                        // 1.2 cm (where the blade slows down to turn, the water is left as a line that wide)
                        const float zoneX = max((0.012 / halfH) / max(abs(rng) * rho, 1e-3), hi - lo);
                        const float ahead = (x - xNow) * sign(xNow - xPrev);
                        if (ahead > 0.0 && ahead < zoneX)
                        {
                            float sum = 0.0;
                            [unroll]
                            for (int k = 0; k < 8; k++)
                            {
                                const float xs = lerp(xPrev, xNow, (float(k) + 0.5) / 8.0);
                                const float an = bl.z + xs * rng;
                                sum += rpGlassAt(rpGlassTexOf(bl.xy + rho * float2(cos(an), sin(an)), aspectP, m), n).x;
                            }
                            gain += 0.9 * (sum / 8.0) * (hi - lo) / zoneX;     // a little goes into the film and spray
                        }
                    }
                }
            }
        }
        W = (swept > 0.5) ? 0.0 : W + gain;
        Fg = (swept > 0.5) ? 0.0 : Fg;                                    // 1.6: the blade wipes the mist off too
    }

    // ---- 1.5.1: the water a blade pushed into a line beyond the end of its sweep runs off (the windshield pass draws its
    // drops letting go and running away): it no longer piles up there sweep after sweep. (Inside the sweep, water above
    // 1 is the bulge a blade is carrying: the blade takes it along.)
    W = (W > 1.0 && inSweep < 0.5) ? 1.0 + (W - 1.0) * exp(-dt * (0.8 + 2.5 * mob)) : W;

    // ---- the film beads up and dries in about a second (quicker in the airflow)
    S *= exp(-dt * (1.0 + rpWindG.x / 25.0) / 1.2);

    pfxOut[storePos] = float4(clamp(W, 0.0, 4.0), saturate(S), clamp(Fg, 0.0, 1.5), 1.0);
}
