#define PFX_COMPUTE 1

#include "rp_mist.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// 1.5 simulated mist. The fine spray tyres throw up on a wet road hangs in the air and goes where the air goes, so the
// air is simulated: three thin layers above the road (0-0.5 m, 0.5-1 m, 1-2 m), each a 128 x 128 grid of 31 cm cells
// (40 m) that follows the camera in whole cells, each an incompressible 2D fluid - Navier-Stokes solved the stable-fluids
// way (Stam 1999, in the GPU form of Harris 2004), one step per frame, one pass per stage:
//   advection   every cell takes the air (velocity and mist) found where that air was a time step ago (semi-Lagrangian,
//               midpoint back-trace, bilinear)
//   forces      cars drag the air along where they drive (their wake, the swirls at their sides), tyres throw spray,
//               vorticity confinement gives back the swirls the coarse grid smears out, an eddy viscosity damps the
//               smallest ones (and the storage's noise), the layers mix (the mist spreads up), the air calms toward the
//               wind, the mist evaporates
//   divergence  how much air each cell would gain or lose
//   pressure    14 Jacobi iterations, one pass each, starting from the last frame's pressure
//   projection  the pressure gradient is taken off the velocity: the air flows around instead of piling up
// Outside the grid: the free stream (the wind, no mist) and no pressure (an open boundary).

// raw texel t of a packed target (the colour channels put back to the stored values when it reads through an sRGB view)
float4 rpMistTexel(Texture2D<float4> tex, int2 t, bool srgb)
{
    return rpWaveRaw(tex.Load(int3(t + int2(dispatchRect.xy), 0)), srgb);
}

// a cell that holds air: inside the grid, and not cell (0, 0) of the bottom layer (the calibration texel)
bool rpMistCell(int l, int2 q)
{
    return all(q >= 0) && all(q < RP_MIST_N) && !(l == 0 && all(q == int2(0, 0)));
}

// the wind in layer l (slower near the road)
float2 rpMistWind(int l)
{
    return rpMistD.xy * ((l == 0) ? 0.55 : ((l == 1) ? 0.8 : 1.0));
}

// velocity (m/s) and mist density of cell q of layer l in a state target
float3 rpMistState(Texture2D<float4> tex, int l, int2 q, bool srgb)
{
    if (!rpMistCell(l, q))
    {
        return float3(rpMistWind(l), 0.0);
    }
    const int2 ta = int2(l * RP_MIST_N + q.x, q.y);
    const float4 a = rpMistTexel(tex, ta, srgb);
    const float4 b = rpMistTexel(tex, ta + int2(RP_MIST_LAYERS * RP_MIST_N, 0), srgb);
    const float e = rpUnpackU16(float2(a.b, b.b));
    return float3(rpUnpack16(a.rg, RP_MIST_VMAX), rpUnpack16(b.rg, RP_MIST_VMAX), e * e * RP_MIST_DMAX);
}

// the same between cells (bilinear); g in cells, cell centres at whole numbers
float3 rpMistStateAt(Texture2D<float4> tex, int l, float2 g, bool srgb)
{
    const float2 g0 = floor(g);
    const float2 f = g - g0;
    const int2 i0 = int2(g0);
    const float3 s00 = rpMistState(tex, l, i0, srgb);
    const float3 s10 = rpMistState(tex, l, i0 + int2(1, 0), srgb);
    const float3 s01 = rpMistState(tex, l, i0 + int2(0, 1), srgb);
    const float3 s11 = rpMistState(tex, l, i0 + int2(1, 1), srgb);
    return lerp(lerp(s00, s10, f.x), lerp(s01, s11, f.x), f.y);
}

// pressure or divergence of cell q of layer l (0 outside the grid)
float rpMistScalar(Texture2D<float4> tex, int l, int2 q, bool srgb, float range)
{
    if (!rpMistCell(l, q))
    {
        return 0.0;
    }
    return rpUnpack16(rpMistTexel(tex, int2(l * RP_MIST_N + q.x, q.y), srgb).rg, range);
}

// curl of the air at cell q (1/s; positive = turning anticlockwise seen from above)
float rpMistCurl(Texture2D<float4> tex, int l, int2 q, bool srgb, float dx)
{
    const float vR = rpMistState(tex, l, q + int2(1, 0), srgb).y;
    const float vL = rpMistState(tex, l, q - int2(1, 0), srgb).y;
    const float uU = rpMistState(tex, l, q + int2(0, 1), srgb).x;
    const float uD = rpMistState(tex, l, q - int2(0, 1), srgb).x;
    return ((vR - vL) - (uU - uD)) / (2.0 * dx);
}

// 1.6: the air's speed is capped as a vector before it is stored. The packing clips each component on its own, which
// turns the flow at the range limit, and a turned flow is a false swirl the confinement then feeds on (the runaway seen
// after a reset). A broken value (NaN / inf) becomes the calm air of its layer.
float2 rpMistCapVel(float2 v, float2 calm)
{
    if (rpBadF(v.x) || rpBadF(v.y))
    {
        return calm;
    }
    const float m = length(v);
    const float cap = RP_MIST_VMAX * 0.9;
    return (m > cap) ? v * (cap / m) : v;
}

// the state's texel in plane A (u, density upper half) or plane B (v, density lower half)
// (1.6: the air speed rounded stochastically, rpPack16D; dither 0.5 = plain rounding)
float4 rpMistPackState(float3 s, int plane, float dither)
{
    const float2 e = rpPackU16(sqrt(saturate(s.z / RP_MIST_DMAX)));
    return (plane == 0) ? float4(rpPack16D(s.x, RP_MIST_VMAX, dither), e.x, 1.0)
                        : float4(rpPack16D(s.y, RP_MIST_VMAX, dither), e.y, 1.0);
}

// 1.6: the dither of texel t in pass kind this frame (independent per texel, pass and frame)
float rpMistDither(int2 t, int kind)
{
    return rpRand(rpHash3(int3(t.x, t.y, (int(rpMistH.x) & 0xFFFFFF) * 4 + kind)));
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
    const int kind = int(round(rpMistA.z));
    const int planeW = RP_MIST_LAYERS * RP_MIST_N;
    const int plane = (t.x >= planeW) ? 1 : 0;           // (the 384-wide targets have plane A only)
    const int xl = t.x - plane * planeW;
    const int l = min(xl / RP_MIST_N, RP_MIST_LAYERS - 1);
    const int2 c = int2(xl - l * RP_MIST_N, t.y);
    const float dx = rpMistA.x;
    const float dt = rpMistA.y;

    if (rpMistA.w < 0.5)
    {
        // the first frames after a start or a reset: calm air, no mist, no pressure
        pfxOut[storePos] = (kind == 0 || kind == 3) ? rpMistPackState(float3(rpMistWind(l), 0.0), plane, 0.5)
                                                     : float4(rpPack16(0.0, 1.0), 0.5, 1.0);
        return;
    }
    // how each input reads (its own calibration texel), and where this cell lay in the grid input 0 was written in
    const bool srgb0 = abs(mistIn0.Load(int3(int2(dispatchRect.xy), 0)).r - 0.5) > 0.1;
    const bool srgb1 = abs(mistIn1.Load(int3(int2(dispatchRect.xy), 0)).r - 0.5) > 0.1;
    const int2 q = c + int2(round(rpMistB.xy));

    if (kind == 1)
    {
        // divergence of the advected air
        const float uR = rpMistState(mistIn0, l, c + int2(1, 0), srgb0).x;
        const float uL = rpMistState(mistIn0, l, c - int2(1, 0), srgb0).x;
        const float vU = rpMistState(mistIn0, l, c + int2(0, 1), srgb0).y;
        const float vD = rpMistState(mistIn0, l, c - int2(0, 1), srgb0).y;
        const float div = ((uR - uL) + (vU - vD)) / (2.0 * dx);
        pfxOut[storePos] = float4(rpPack16(div, RP_MIST_QMAX), 0.5, 1.0);
        return;
    }
    if (kind == 2)
    {
        // 1.6: paused (no time step): the pressure stays as it is, so the air does not drift while the game waits
        if (dt <= 0.0)
        {
            pfxOut[storePos] = float4(rpPack16(rpMistScalar(mistIn0, l, q, srgb0, RP_MIST_PMAX), RP_MIST_PMAX), 0.5, 1.0);
            return;
        }
        // one Jacobi iteration of lap(p) = div (the first one reads the last frame's pressure, moved with the grid).
        // 1.6: that warm start is damped (rpMistG.x, < 1 only in the first iteration). 14 iterations barely touch the
        // pressure's widest patterns, so an undamped warm start kept pushing the air for seconds after the wake that
        // made it was gone (a slow slosh around a parked car), and a pressure saturated by a reset stayed for good.
        const float pL = rpMistScalar(mistIn0, l, q - int2(1, 0), srgb0, RP_MIST_PMAX);
        const float pR = rpMistScalar(mistIn0, l, q + int2(1, 0), srgb0, RP_MIST_PMAX);
        const float pD = rpMistScalar(mistIn0, l, q - int2(0, 1), srgb0, RP_MIST_PMAX);
        const float pU = rpMistScalar(mistIn0, l, q + int2(0, 1), srgb0, RP_MIST_PMAX);
        const float div = rpMistScalar(mistIn1, l, c, srgb1, RP_MIST_QMAX);
        const float pK = saturate(rpMistG.x);
        float p = (pK * (pL + pR + pD + pU) - dx * dx * div) * 0.25;
        p = rpBadF(p) ? 0.0 : clamp(p, -RP_MIST_PMAX, RP_MIST_PMAX);
        pfxOut[storePos] = float4(rpPack16(p, RP_MIST_PMAX), 0.5, 1.0);
        return;
    }
    if (kind == 3)
    {
        // projection: the pressure gradient off the velocity
        float3 s = rpMistState(mistIn0, l, c, srgb0);
        if (dt > 0.0)
        {
            const float pL = rpMistScalar(mistIn1, l, c - int2(1, 0), srgb1, RP_MIST_PMAX);
            const float pR = rpMistScalar(mistIn1, l, c + int2(1, 0), srgb1, RP_MIST_PMAX);
            const float pD = rpMistScalar(mistIn1, l, c - int2(0, 1), srgb1, RP_MIST_PMAX);
            const float pU = rpMistScalar(mistIn1, l, c + int2(0, 1), srgb1, RP_MIST_PMAX);
            // (rpMistF.w < 1: part of the air a car pushes goes over it in the real, 3D flow; fully incompressible
            // layers pushed it all aside, and the mist with it)
            s.xy -= rpMistF.w * float2(pR - pL, pU - pD) / (2.0 * dx);
        }
        s.xy = rpMistCapVel(s.xy, rpMistWind(l));
        pfxOut[storePos] = rpMistPackState(s, plane, rpMistDither(t, kind));
        return;
    }

    // advection: back along the air's path to where it was a step ago (midpoint), and take what was there
    const float k = dt / dx;
    const float3 s0 = rpMistState(mistIn0, l, q, srgb0);
    const float3 sm = rpMistStateAt(mistIn0, l, float2(q) - 0.5 * k * s0.xy, srgb0);
    float3 s = rpMistStateAt(mistIn0, l, float2(q) - k * sm.xy, srgb0);

    // eddy viscosity: smooths the smallest swirls the grid holds within a fraction of a second and barely touches the
    // wake's big ones (it damps as the square of the wavenumber). Without it the confinement below fed on the noise of
    // the 16-bit storage in still air - which semi-Lagrangian advection does not damp - until all of it moved at the range
    // limit (seen in game).
    {
        const float2 nL = rpMistState(mistIn0, l, q - int2(1, 0), srgb0).xy;
        const float2 nR = rpMistState(mistIn0, l, q + int2(1, 0), srgb0).xy;
        const float2 nD = rpMistState(mistIn0, l, q - int2(0, 1), srgb0).xy;
        const float2 nU = rpMistState(mistIn0, l, q + int2(0, 1), srgb0).xy;
        s.xy += (rpMistE.w * dt / (dx * dx)) * (nL + nR + nD + nU - 4.0 * s0.xy);
    }

    // turbulent spreading of the mist (the wake's eddies smaller than a cell): a trail widens to about a metre in a
    // couple of seconds instead of staying as thin as the tyre that threw it
    {
        const float dL = rpMistState(mistIn0, l, q - int2(1, 0), srgb0).z;
        const float dR = rpMistState(mistIn0, l, q + int2(1, 0), srgb0).z;
        const float dD = rpMistState(mistIn0, l, q - int2(0, 1), srgb0).z;
        const float dU = rpMistState(mistIn0, l, q + int2(0, 1), srgb0).z;
        s.z += min(rpMistF.x * dt / (dx * dx), 0.2) * (dL + dR + dD + dU - 4.0 * s0.z);
    }

    // vorticity confinement: a push around each swirl's centre, toward where the curl is stronger (Fedkiw et al. 2001);
    // only on real swirls (above 1-4 turns per 2 pi seconds), not on noise.
    // 1.6: and only where the air really moves against the wind (rpMistG.w). Confinement gives back swirls a moving flow
    // loses to the coarse grid; in nearly still air - a parked car, the seconds after a reset - there is nothing to give
    // back, and its push only fed on what was left of the last wake until that air ran at the range limit.
    const float calmK = smoothstep(rpMistG.w * 0.25, max(rpMistG.w, 0.05), length(s0.xy - rpMistWind(l)));
    if (rpMistB.z > 0.0 && calmK > 0.0)
    {
        const float w = rpMistCurl(mistIn0, l, q, srgb0, dx);
        const float wR = abs(rpMistCurl(mistIn0, l, q + int2(1, 0), srgb0, dx));
        const float wL = abs(rpMistCurl(mistIn0, l, q - int2(1, 0), srgb0, dx));
        const float wU = abs(rpMistCurl(mistIn0, l, q + int2(0, 1), srgb0, dx));
        const float wD = abs(rpMistCurl(mistIn0, l, q - int2(0, 1), srgb0, dx));
        float2 nG = float2(wR - wL, wU - wD);
        nG /= (length(nG) + 1e-4);
        s.xy += dt * rpMistB.z * dx * w * smoothstep(1.0, 4.0, abs(w)) * calmK * float2(nG.y, -nG.x);
    }

    // the layers mix: the mist spreads up and down, each layer drags a little on the ones next to it
    {
        float3 nb = float3(0.0, 0.0, 0.0);
        float nw = 0.0;
        if (l > 0)
        {
            nb += rpMistState(mistIn0, l - 1, q, srgb0);
            nw += 1.0;
        }
        if (l < RP_MIST_LAYERS - 1)
        {
            nb += rpMistState(mistIn0, l + 1, q, srgb0);
            nw += 1.0;
        }
        nb /= max(nw, 1.0);
        const float ex = (1.0 - exp(-dt * rpMistD.z)) * 0.5 * nw;
        s.z += (nb.z - s.z) * ex;
        s.xy += (nb.xy - s.xy) * ex * 0.5;
    }

    // the air calms toward the wind, the mist evaporates.
    // 1.6: dense mist also falls out (rpMistG.z): in a thick cloud the fine drops meet and grow until they rain back onto
    // the road. Thin trails keep their ~1.5 s; a cloud fed in one place (a wheelspin standing still) levels off at about
    // half the density it reached before, instead of piling up to the range limit.
    s.xy = lerp(s.xy, rpMistWind(l), 1.0 - exp(-dt * rpMistD.w));
    s.z *= exp(-dt * (rpMistB.w + max(rpMistG.z, 0.0) * max(s.z, 0.0)));

    // cars and tyres
    const float2 Pw = (rpMistC.xy + float2(c) + 0.5) * dx;          // this cell's centre in the world
    const float bodyK = (l == 0) ? 1.0 : ((l == 1) ? 0.85 : 0.15);    // a car is about 1.4 m tall
    const float water = 0.6 * pow(saturate(rpMistC.w), 0.6);          // the wet road's water (as the spray pass)
    float4 tA[8] = { rpTyreA0, rpTyreA1, rpTyreA2, rpTyreA3, rpTyreA4, rpTyreA5, rpTyreA6, rpTyreA7 };
    float4 tB[8] = { rpTyreB0, rpTyreB1, rpTyreB2, rpTyreB3, rpTyreB4, rpTyreB5, rpTyreB6, rpTyreB7 };
    float4 tC[8] = { rpTyreC0, rpTyreC1, rpTyreC2, rpTyreC3, rpTyreC4, rpTyreC5, rpTyreC6, rpTyreC7 };
    // 1.6: the fastest tyre the forcing believes. Lua already drops impossible readings and holds a car's tyres for a
    // moment after a reset or teleport; this is the shader's own guard, so one bad frame can never fill the grid.
    const float vCap = clamp(rpMistG.y, 1.0, 120.0);
    [unroll]
    for (int ti = 0; ti < 8; ti++)
    {
        if (tC[ti].y > 0.5)
        {
            const float2 dir2 = tB[ti].xy;
            const float g = clamp(tB[ti].z, 0.0, vCap);                 // ground speed
            const float tread = clamp(tB[ti].w, 0.0, min(vCap, 80.0));  // tread speed (spin; never more than a real tyre)
            const float v = max(g, tread);
            const float2 d = Pw - tA[ti].xy;
            if (v > 0.5 && dot(d, d) < 36.0 && dot(dir2, dir2) > 0.25)
            {
                const float hw = max(tA[ti].w, 0.05);
                const float along = dot(d, dir2);
                // the wheel and the body beside it drag the air along (at a share of the car's speed: the air slips
                // past the bodywork), over the path covered this frame (a cell it passed through is not skipped): the
                // projection then pushes the air aside in front, draws it in behind (the wake) and sheds swirls at the
                // sides. (1.6: that path is at most 1.2 m, whatever the frame time and the reading)
                const float aB = clamp(along, -0.5 - min(g * dt, 1.2), 0.7);
                const float2 eB = d - dir2 * aB;
                const float wB = hw + 0.45;
                const float kB = exp(-2.0 * dot(eB, eB) / (wB * wB)) * bodyK * (1.0 - exp(-dt * 30.0));
                s.xy = lerp(s.xy, dir2 * min(g * rpMistF.z, RP_MIST_VMAX * 0.8), kB);

                // spray: thrown up behind the tyre on a wet road (strength as the spray pass's plume), mostly low,
                // higher up the faster the car
                const float roadWet = saturate((tC[ti].y - 0.5) * 2.0);
                const float speedK = smoothstep(rpMistE.y * 0.4, rpMistE.y + 7.0, v) * (0.8 + 0.2 * smoothstep(12.0, 34.0, v));
                const float slip = saturate(abs(tread - g) / 6.0);
                // 1.6: the share of the spray that turns into mist hanging in the air needs air rushing past the tyre to
                // tear the water sheet into fine drops. A tyre spinning on the spot throws mostly big drops that fall
                // straight back: standing still, a third of what the same tread speed gives on the move.
                const float atom = 0.3 + 0.7 * smoothstep(2.0, 12.0, g);
                const float tyreK = rpMistE.x * speedK * (1.0 + slip) * roadWet * atom;
                const float Ls = (0.3 + 0.05 * v) * max(rpMistE.z, 0.25);
                const float wS = hw + 0.25 + 0.02 * v;                        // the spray fans out behind the tyre
                if (tyreK > 0.001)
                {
                    const float aS = clamp(along, -Ls - min(g * dt, 1.2), 0.0);
                    const float2 eS = d - dir2 * aS;
                    const float share = (l == 0) ? 1.0
                        : ((l == 1) ? 0.15 + 0.5 * smoothstep(8.0, 30.0, v) : 0.25 * smoothstep(14.0, 35.0, v));
                    s.z += rpMistC.z * tyreK * water * rpMistF.y * share * exp(-2.0 * dot(eS, eS) / (wS * wS)) * dt;
                }
                // 1.6: the water a spinning tread throws back drags the air behind the tyre with it (a few m/s at most),
                // so the mist of a wheelspin streams away behind the car instead of piling up around a car that does not
                // move (it had no air motion at all to carry it before)
                const float slipV = max(tread - g, 0.0);
                if (slipV > 1.0 && l < 2)
                {
                    const float aJ = clamp(along, -Ls, -0.3);
                    const float2 eJ = d - dir2 * aJ;
                    const float kJ = exp(-2.0 * dot(eJ, eJ) / (wS * wS)) * smoothstep(-0.1, -0.5, along)
                                   * ((l == 0) ? 1.0 : 0.4) * roadWet * (1.0 - exp(-dt * 4.0));
                    s.xy = lerp(s.xy, -dir2 * min(0.15 * slipV, 3.0), kJ);
                }
            }
        }
    }
    s.xy = rpMistCapVel(s.xy, rpMistWind(l));
    s.z = rpBadF(s.z) ? 0.0 : clamp(s.z, 0.0, RP_MIST_DMAX);
    pfxOut[storePos] = rpMistPackState(s, plane, rpMistDither(t, kind));
}
