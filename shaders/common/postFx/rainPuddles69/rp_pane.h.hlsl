#ifndef RP_PANE_H_HLSL
#define RP_PANE_H_HLSL

// A glass pane and its wiper blades, shared by the windshield pass (rp_windshield.cs.hlsl) and the glass water
// simulation (rp_glass.cs.hlsl, 1.5): the glass outline, the blades, how long ago a blade passed a point of the glass,
// and where each blade is now. Included after a cbuffer that declares rpWindE, H, I, J, K, L, P0..5, Q0..3, S0..1, T.

static const float2 RP_PIVOT0 = float2(-0.30, -1.06);  // procedural tandem wipers: x in half widths, y in half heights
static const float2 RP_PIVOT1 = float2( 0.55, -1.06);
static const float RP_BLADE_R0 = 0.16;                  // blade span along the arm (glass half heights)
static const float RP_BLADE_R1 = 1.72;

float rpWrapPi(float x)
{
    return x - 6.2831853 * floor((x + 3.14159265) / 6.2831853);
}

// Seconds since blade bl (xy pivot, z parked angle, w signed sweep) last passed over q (1e6 = never / out of reach);
// rr = inner / outer radius of the wiped band. passes = blade passes over q in the current cycle (0..2), used to give
// each wiped spot a fresh set of drops.
// ph = the blade's phase in half sweeps (wiper model): it rests at easing(ph) of its arc and passes q at (tri - ph) and
// (2 - tri - ph) half sweeps into the cycle (0 = parked at the start of the arc: out at tri, back at 2 - tri).
float rpWipeAge(float2 q, float4 bl, float2 rr, float ph, float tc, float sweepT, float period, float flags,
                out float passes, out float reach)
{
    float age = 1e6;
    passes = 0.0;
    float2 d = q - bl.xy;
    float rho = length(d);
    float rng = (bl.w >= 0.0) ? max(bl.w, 1e-3) : min(bl.w, -1e-3);
    float x = rpWrapPi(atan2(d.y, d.x + 1e-9) - bl.z) / rng;   // 1.3: never atan2(0, 0)
    reach = (rho > rr.x && rho < rr.y && x >= 0.0 && x <= 1.0) ? 1.0 : 0.0;
    if (reach > 0.5 && fmod(flags, 2.0) > 0.5)
    {
        // inverse of the blade easing: smoothstep (own wipers) or cosine (flag 8: the Animated Wipers mod's blades)
        float tri = (fmod(floor(flags / 8.0), 2.0) > 0.5)
            ? acos(clamp(1.0 - 2.0 * x, -1.0, 1.0)) / 3.14159265
            : 0.5 - sin(asin(clamp(1.0 - 2.0 * x, -1.0, 1.0)) / 3.0);
        float tA = frac((tri - ph) * 0.5 + 1.0) * sweepT;
        float tB = (1.0 - frac((tri + ph) * 0.5)) * sweepT;
        float tOut = min(tA, tB);
        float tBack = max(tA, tB);
        if (tc >= tBack)
        {
            age = tc - tBack;
            passes = 2.0;
        }
        else if (tc >= tOut)
        {
            age = tc - tOut;
            passes = 1.0;
        }
        else if (fmod(floor(flags / 2.0), 2.0) > 0.5 && fmod(floor(flags / 4.0), 2.0) > 0.5)
        {
            age = tc + period - tBack;                    // back pass of the previous cycle
        }
    }
    return age;
}

// All blades at once: the most recent pass over q, the passes of this cycle, and whether any blade reaches q.
void rpWipeAll(float2 q, int nb, float4 bq[4], float2 brr[4], float4 bph, float4 tl, out float wipeAge, out float passSum,
               out float wiped)
{
    wipeAge = 1e6;
    passSum = 0.0;
    wiped = 0.0;
    [unroll]
    for (int bj = 0; bj < 4; bj++)
    {
        if (bj < nb)
        {
            float psJ = 0.0, rcJ = 0.0;
            float agJ = rpWipeAge(q, bq[bj], brr[bj], bph[bj], tl.x, tl.y, tl.z, tl.w, psJ, rcJ);
            wipeAge = min(wipeAge, agJ);
            wiped = max(wiped, rcJ);
            passSum += psJ;
        }
    }
}

// 1.0: inside the glass outline (convex quad a, b, c, d counter-clockwise, glass metres), soft edge +-soft metres.
float rpQuadMask(float2 q, float2 a, float2 b, float2 c, float2 d, float soft)
{
    float2 v[4] = { a, b, c, d };
    float m = 1.0;
    [unroll]
    for (int i = 0; i < 4; i++)
    {
        float2 p0 = v[i];
        float2 e = v[(i + 1) & 3] - p0;
        float s = (e.x * (q.y - p0.y) - e.y * (q.x - p0.x)) / max(length(e), 1e-4);   // + = inside
        m *= smoothstep(-soft, soft, s);
    }
    return m;
}

// 1.0: inside the glass outline from the jbeam frame nodes (up to 12 corners in rpWindP0..5, glass uv, counter-
// clockwise). q and the soft edge are in glass metres, sc converts uv to metres.
float rpPolyMask(float2 q, float2 sc, int n, float soft)
{
    float2 v[12] = { rpWindP0.xy, rpWindP0.zw, rpWindP1.xy, rpWindP1.zw, rpWindP2.xy, rpWindP2.zw,
                     rpWindP3.xy, rpWindP3.zw, rpWindP4.xy, rpWindP4.zw, rpWindP5.xy, rpWindP5.zw };
    float m = 1.0;
    [unroll]
    for (int i = 0; i < 12; i++)
    {
        if (i < n)
        {
            float2 p0 = v[i] * sc;
            float2 p1 = ((i + 1 < n) ? v[(i + 1) % 12] : v[0]) * sc;
            float2 e = p1 - p0;
            float s = (e.x * (q.y - p0.y) - e.y * (q.x - p0.x)) / max(length(e), 1e-4);   // + = inside
            m *= smoothstep(-soft, soft, s);
        }
    }
    return m;
}

// 1.0: how much of glass point uv (half sizes, -1..1 across the pane) is glass: the car's jbeam frame outline
// (rpWindI.z = 2), the ray-probed size plus a small margin (1) or, from an estimated plane (0, cockpit only), generous
float rpPaneAperture(float2 uv, float halfW, float halfH)
{
    float aperture = 0.0;
    if (rpWindI.z > 1.5)
    {
        float2 sc = float2(halfW, halfH);
        aperture = (rpWindL.x > 2.5)
            ? rpPolyMask(uv * sc, sc, int(rpWindL.x + 0.5), 0.02)
            : rpQuadMask(uv * sc, rpWindJ.xy * sc, rpWindJ.zw * sc, rpWindK.xy * sc, rpWindK.zw * sc, 0.02);
    }
    else if (rpWindI.z > 0.5)
    {
        aperture = (1.0 - smoothstep(0.97, 1.06, abs(uv.x))) * smoothstep(-1.06, -0.97, uv.y) * (1.0 - smoothstep(0.97, 1.06, uv.y));
    }
    else
    {
        aperture = (1.0 - smoothstep(1.05, 1.18, abs(uv.x))) * smoothstep(-1.14, -1.00, uv.y) * (1.0 - smoothstep(0.98, 1.10, uv.y));
    }
    return aperture;
}

// The pane's wiper blades: the car's own (rpWindQ / S, measured from its wiper mesh in Lua: any count, pivot, length,
// parked angle and sweep direction; rpWindT: where each rests on its arc) or the procedural tandem pair, mirrored for
// right-hand drive. rpWindL.y = -1: no wipers on this pane (the rear / hatch glass without one). Returns the count.
int rpBladeSetup(float aspectP, out float4 bq[4], out float2 brr[4], out float4 bph)
{
    int nb = (rpWindL.y < -0.5) ? 0 : int(rpWindL.y + 0.5);
    [unroll]
    for (int bz = 0; bz < 4; bz++)
    {
        bq[bz] = float4(0.0, -10.0, 0.0, 1.0);
        brr[bz] = float2(0.0, 0.0);
    }
    if (nb > 0)
    {
        bq[0] = rpWindQ0; bq[1] = rpWindQ1; bq[2] = rpWindQ2; bq[3] = rpWindQ3;
        brr[0] = rpWindS0.xy; brr[1] = rpWindS0.zw; brr[2] = rpWindS1.xy; brr[3] = rpWindS1.zw;
    }
    else if (rpWindL.y > -0.5)
    {
        nb = 2;
        const float wSide = (rpWindI.w > 0.5) ? -1.0 : 1.0;
        const float pk = (wSide > 0.0) ? rpWindH.x : 3.14159265 - rpWindH.x;
        bq[0] = float4(RP_PIVOT0.x * aspectP * wSide, RP_PIVOT0.y, pk, rpWindH.y * wSide);
        bq[1] = float4(RP_PIVOT1.x * aspectP * wSide, RP_PIVOT1.y, pk, rpWindH.y * wSide);
        brr[0] = float2(RP_BLADE_R0, RP_BLADE_R1);
        brr[1] = brr[0];
    }
    bph = (rpWindL.y > 0.5) ? rpWindT : float4(0.0, 0.0, 0.0, 0.0);
    return nb;
}

// 1.5: where a blade is along its arc (0 = the start of its sweep .. 1 = the far end) at time tc of the wiper cycle:
// easing(phase + half sweeps into the cycle), parked after the sweep - the inverse of what rpWipeAge solves for.
float rpBladeX(float tc, float sweepT, float ph, bool cosEase)
{
    const float tau = (tc < sweepT) ? (2.0 * max(tc, 0.0) / sweepT) : 0.0;
    const float eArg = frac((tau + ph) * 0.5) * 2.0;
    const float tri = (eArg <= 1.0) ? eArg : 2.0 - eArg;
    return cosEase ? 0.5 - 0.5 * cos(3.14159265 * tri) : tri * tri * (3.0 - 2.0 * tri);
}

// 1.5.1: seconds since a blade (phase ph) last came in to end e of its arc (0 = its start, where it parks; 1 = the far
// end) and turned or parked there, leaving the water it had pushed along as a line; gen tells those lines apart (gen0 =
// the passes before this cycle, two per cycle). 1e6 = no line yet.
float rpLineAge(float e, float ph, float tc, float sweepT, float period, float flags, float gen0, out float gen)
{
    gen = 0.0;
    if (fmod(flags, 2.0) < 0.5)
    {
        return 1e6;
    }
    // the moments it is at tri = e (rpWipeAge's two solutions: one at the far end; at the parked end the start and the
    // end of the cycle): it comes in at the later one
    const float tA = frac((e - ph) * 0.5 + 1.0) * sweepT;
    const float tB = (1.0 - frac((e + ph) * 0.5)) * sweepT;
    const float tL = max(tA, tB);
    if (tc >= tL)
    {
        gen = gen0 + e;
        return tc - tL;
    }
    if (fmod(floor(flags / 2.0), 2.0) > 0.5 && fmod(floor(flags / 4.0), 2.0) > 0.5)
    {
        gen = gen0 - 2.0 + e;                                         // the line of the previous cycle
        return tc + period - tL;
    }
    return 1e6;
}

#endif
