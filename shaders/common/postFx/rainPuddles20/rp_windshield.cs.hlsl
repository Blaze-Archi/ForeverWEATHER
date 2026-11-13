#define PFX_COMPUTE 1

#include "rp_windshield.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// Windshield rain + wipers.
//
// * The view ray is intersected with the car's real glass (jbeam windshield frame: outline polygon + bulge), from the
//   driver's seat and (1.0) from outside the car: rpWindG.w says which side of the glass the camera is on.
// * Glass mask from DEPTH: glass is not in the depth buffer, so drops are drawn only where the scene seen at a pixel
//   lies beyond the glass (the world through it from the seat, the cabin through it from outside). Dashboard, pillars,
//   mirror, hood and anything else in front of or at the glass never get drops.
// * Wipers: timeline from Lua (rpWindE). For every point of the glass the shader knows how many seconds ago a blade
//   last passed; a drop that landed before that pass is gone, so the glass clears exactly where the car's own blades
//   (measured from its wiper mesh) sweep, at the wiper speed in use. No blades are drawn.
// * Drops move like the body droplets (1.0): beads stick until the force on them (gravity, airflow, the car's
//   acceleration; rpWindN from Lua) beats their adhesion - big ones go first, small ones stay; running drops on two
//   grids that translate along the glass (rpWindO, integrated in Lua, so there is no cut-off at any speed) streak into
//   teardrops and leave wet trails.

static const float RP_TILE_IN = 112.0 / 128.0;
static const float2 RP_PIVOT0 = float2(-0.30, -1.06);  // procedural tandem wipers: x in half widths, y in half heights
static const float2 RP_PIVOT1 = float2( 0.55, -1.06);
static const float RP_BLADE_R0 = 0.16;                  // blade span along the arm (glass half heights)
static const float RP_BLADE_R1 = 1.72;

float3 rpWindLoad(int2 q)
{
    return colorTexTex.Load(int3(clamp(q, int2(dispatchRect.xy), int2(dispatchRect.xy + dispatchRect.zw) - 1), 0)).rgb;
}

float3 rpWindBlur(int2 q, int r)
{
    return rpWindLoad(q) * 0.28
         + (rpWindLoad(q + int2(r, 0)) + rpWindLoad(q - int2(r, 0)) + rpWindLoad(q + int2(0, r)) + rpWindLoad(q - int2(0, r))) * 0.18;
}

bool rpAtlasValid()
{
    float4 m = dropTexTex.SampleLevel(dropTex_sampler_, float2(0.875, 0.875), 0.0);
    float4 d = abs(m - float4(0.251, 0.749, 0.502, 1.0));
    return max(max(d.x, d.y), max(d.z, d.w)) < 0.06;
}

// Droplet shape at q (tile space, |q| <= 1) from the shared droplet atlas: normal xy, thickness, coverage.
// Tiles 0-7 round beads, 8-11 teardrops (head toward +y), 12-14 flat merged drops.
float4 rpWindShape(float2 q, float tile, float lod, bool atlas)
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
        s = float4(q * 0.9, sqrt(saturate(1.0 - rr)), saturate((1.0 - sqrt(rr)) * 6.0));
    }
    return s * inside;
}

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
    float x = rpWrapPi(atan2(d.y, d.x) - bl.z) / rng;
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

// Tangential force (m/s^2) a drop of radius rad resists on glass, as the body droplets: small drops hold on longest.
float rpWindAdhesion(float rad, float baseRad)
{
    return 3.75 * pow(baseRad / max(rad, 1e-5), 1.2);
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

// 1.0 tunnels: of the time since a blade last passed (age, s), how long rain could land: the time the car spent under
// a roof does not count (rpWindI.y = it went under one this long ago, rpWindN.w = came out this long ago, 0 = still /
// never). Drops that landed before the roof stay until a blade wipes them.
float rpLandAge(float age)
{
    float a = min(age, 1e4);
    return max(a - max(0.0, min(a, rpWindI.y) - rpWindN.w), 0.0);
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
    const float4 src = colorTexTex.Load(int3(p, 0));

    if (rpWindG.y < 0.5)
    {
        pfxOut[storePos] = src;
        return;
    }

    PFXVertToPix IN = processPostFxCompute(dispatchThreadID);
    PFXVertToPix INx = processPostFxCompute(dispatchThreadID + uint3(1, 0, 0));
    PFXVertToPix INy = processPostFxCompute(dispatchThreadID + uint3(0, 1, 0));
    const float3 ray0 = IN.wsEyeRay;
    float3 camFwd = normalize(cross(INx.wsEyeRay - ray0, INy.wsEyeRay - ray0));
    camFwd = (dot(camFwd, ray0) < 0.0) ? -camFwd : camFwd;

    // 1.0: the camera sits either in the cockpit (behind the glass) or outside the car (in front of it)
    const bool outside = rpWindG.w > 0.5;

    // ---- ray / glass intersection -----------------------------------------------------------------------------------
    const float3 ro = rpCam.xyz;
    const float3 rd = normalize(ray0);
    const float denom = dot(rd, rpWindB.xyz);
    // the ray has to head for the glass: out of the car from the seat, into it from outside
    if ((outside ? -denom : denom) < 1e-4)
    {
        pfxOut[storePos] = src;
        return;
    }
    float t = dot(rpWindA.xyz - ro, rpWindB.xyz) / denom;
    // Curved glass (jbeam frame): move the plane by the glass bulge at the hit point and intersect again; two steps
    // converge, so drops sit on the real curved windshield and the depth test compares against it. The bulge is only
    // known ON the glass, so it is evaluated at the nearest point of the glass and limited to +-15 cm.
    if (rpWindI.z > 1.5 && dot(rpWindM, rpWindM) > 0.0)
    {
        const float hwC = max(rpWindA.w, 0.1);
        const float hhC = max(rpWindB.w, 0.1);
        [unroll]
        for (int it = 0; it < 2; it++)
        {
            float3 relC = ro + rd * t - rpWindA.xyz;
            float ga = clamp(dot(relC, rpWindC.xyz), -hwC, hwC);
            float gb = clamp(dot(relC, rpWindD.xyz), -hhC, hhC);
            float hC = clamp(rpWindM.x + rpWindM.y * gb + (rpWindM.z + rpWindM.w * gb) * ga * ga, -0.15, 0.15);
            t = dot(rpWindA.xyz + rpWindB.xyz * hC - ro, rpWindB.xyz) / denom;
        }
    }
    if (t < (outside ? 0.25 : 0.08) || t > (outside ? 60.0 : 4.0))
    {
        pfxOut[storePos] = src;
        return;
    }
    const float3 Pw = ro + rd * t;
    const float3 rel = Pw - rpWindA.xyz;
    const float halfW = max(rpWindA.w, 0.1);
    const float halfH = max(rpWindB.w, 0.1);
    const float2 uv = float2(dot(rel, rpWindC.xyz) / halfW, dot(rel, rpWindD.xyz) / halfH);

    // Glass outline. From the car's jbeam windshield frame (rpWindI.z = 2): the real outline of the glass. Ray-probed
    // glass (1): its measured size plus a small margin. Estimated plane (0, cockpit only): generous. The depth test
    // below trims all of them to the opening that is really visible.
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
    // 1.0: nothing of this pane at this pixel: done before the depth is read (most of the screen; debug views go on)
    if (aperture < 0.001 && !(rpMode.x > 7.5 && rpMode.x < 8.5) && !(rpMode.x > 15.5 && rpMode.x < 17.5))
    {
        pfxOut[storePos] = src;
        return;
    }
    // Glass mask: the scene at this pixel must lie clearly beyond the glass. Car glass is drawn after the G-buffer, so
    // the depth buffer holds what is behind it. From the seat that is the hood / road / world, while the dashboard,
    // pillars, mirror, roof liner and steering wheel sit in front of or at the glass. From outside it is the cabin, while
    // the hood, wipers, pillars and roof sit in front of or at the glass. Sampled by this slot's own uv (render scaling /
    // upscaling), eye-linear depth along the far-plane eye ray exactly like the puddle pass.
    float ndc = windDepthTex.SampleLevel(windDepth_sampler_, IN.uv1, 0).r;
    float beyond = 1.0;
    float sceneDist = 1e5;
    if (ndc < 0.99999)
    {
        float lin = abs(ndcToRealDepth(ndc, projParams)) / max(abs(projParams.y), 1e-6);
        sceneDist = length(rpReconstruct(ray0, camFwd, lin, rpMode.y, rpMode.z));
        beyond = outside ? smoothstep(t + 0.04, t + 0.12, sceneDist) : smoothstep(t + 0.05, t + 0.18, sceneDist);
    }
    // Debug 16: what the glass depth test sees. Blue = no depth (sky / empty), red = surface in front of the glass,
    // yellow = at the glass (+-), green = beyond the glass; darker outside the glass outline.
    if (rpMode.x > 15.5 && rpMode.x < 16.5)
    {
        float3 dc = float3(0.1, 0.3, 1.0);
        if (ndc < 0.99999)
        {
            dc = (sceneDist < t - 0.02) ? float3(1.0, 0.1, 0.1) : ((sceneDist < t + 0.18) ? float3(1.0, 0.9, 0.1) : float3(0.1, 1.0, 0.2));
        }
        float B16 = max(rpLuma(src.rgb), 0.05) * 2.0 * rpMode.w;
        pfxOut[storePos] = float4(dc * B16 * (0.35 + 0.65 * aperture), src.a);
        return;
    }
    const float glass = aperture * beyond;
    const bool dbgWipers = (rpMode.x > 16.5 && rpMode.x < 17.5);
    if (glass < 0.001 && !(rpMode.x > 7.5 && rpMode.x < 8.5) && !(dbgWipers && aperture > 0.001))
    {
        pfxOut[storePos] = src;
        return;
    }

    const float aspectP = halfW / halfH;
    const float2 pc = float2(uv.x * aspectP, uv.y);              // isotropic glass space (half-height units)
    // right-hand drive (rpWindI.w, from the game's driver data) mirrors the procedural wipers
    const float wSide = (rpWindI.w > 0.5) ? -1.0 : 1.0;

    // 1.0: size of a screen pixel on the glass. Drops smaller than a pixel fade instead of sparkling (outside views),
    // and the lens offset of a drop is scaled by its real size on screen.
    const float angPix = max(length(normalize(INx.wsEyeRay) - rd), 1e-6);
    const float pxIso = t * angPix / halfH;                                   // glass units per pixel, facing the eye
    const float mppU = pxIso / sqrt(max(abs(denom), 0.2));                    // ... averaged over the slant of the glass
    const float3 scrX = normalize(INx.wsEyeRay - ray0);                       // world direction of +x on screen
    const float3 scrY = normalize(INy.wsEyeRay - ray0);                       // world direction of +y (down) on screen

    const float tc = rpWindE.x;
    const float sweepT = max(rpWindE.y, 0.05);
    const float period = max(rpWindE.z, sweepT);
    const float flags = rpWindE.w;
    const float park = rpWindH.x;
    const float range = rpWindH.y;
    const float rainClock = rpWindH.z;
    const float rainRate = max(rpWindH.w, 0.05);
    const float gen0 = rpWindI.x;                                // passes completed before this cycle (x2 per cycle)
    const bool atlasOK = rpAtlasValid();
    const float4 tl4 = float4(tc, sweepT, period, flags);

    // Wiper blades: the car's own blades (rpWindQ / rpWindS, measured from its wiper mesh in Lua: any count, pivot,
    // length, parked angle and sweep direction); otherwise the procedural tandem pair, mirrored for RHD.
    // 1.0: rpWindL.y = -1: this pane has no wipers at all (the rear / hatch glass pass)
    int nb = (rpWindL.y < -0.5) ? 0 : int(rpWindL.y + 0.5);
    float4 bq[4];
    float2 brr[4];
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
        float pk = (wSide > 0.0) ? park : 3.14159265 - park;
        bq[0] = float4(RP_PIVOT0.x * aspectP * wSide, RP_PIVOT0.y, pk, range * wSide);
        bq[1] = float4(RP_PIVOT1.x * aspectP * wSide, RP_PIVOT1.y, pk, range * wSide);
        bq[2] = float4(0.0, -10.0, 0.0, 1.0);
        bq[3] = bq[2];
        brr[0] = float2(RP_BLADE_R0, RP_BLADE_R1);
        brr[1] = brr[0];
        brr[2] = float2(0.0, 0.0);
        brr[3] = brr[2];
    }
    // wiper model: where each blade rests on its arc (0 for the procedural pair)
    const float4 bph = (rpWindL.y > 0.5) ? rpWindT : float4(0.0, 0.0, 0.0, 0.0);

    // Debug 17 (wiper model): each blade's swept sector in its own colour (cyan, yellow, green, magenta; white where two
    // overlap), red stripes = glass no blade ever reaches, white line = where the blade is now, white dot = its pivot.
    if (dbgWipers)
    {
        const float B17 = max(rpLuma(src.rgb), 0.06) * 2.0 * rpMode.w;
        const float3 tint[4] = { float3(0.1, 0.9, 1.0), float3(1.0, 0.85, 0.1), float3(0.2, 1.0, 0.3), float3(1.0, 0.2, 0.9) };
        float3 acc = float3(0.0, 0.0, 0.0);
        float hits = 0.0;
        float marks = 0.0;
        const float cosEase = (fmod(floor(flags / 8.0), 2.0) > 0.5) ? 1.0 : 0.0;
        [unroll]
        for (int bd = 0; bd < 4; bd++)
        {
            if (bd < nb)
            {
                float2 dB = pc - bq[bd].xy;
                float rhoB = length(dB);
                float rngB = (bq[bd].w >= 0.0) ? max(bq[bd].w, 1e-3) : min(bq[bd].w, -1e-3);
                float xB = rpWrapPi(atan2(dB.y, dB.x) - bq[bd].z) / rngB;
                bool inR = (rhoB > brr[bd].x && rhoB < brr[bd].y);
                if (inR && xB >= 0.0 && xB <= 1.0)
                {
                    acc += tint[bd];
                    hits += 1.0;
                }
                // the blade now: easing(ph + half sweeps into the cycle), parked after the sweep
                float tau = (tc < sweepT) ? (2.0 * tc / sweepT) : 0.0;
                float eArg = frac((tau + bph[bd]) * 0.5) * 2.0;
                float eTri = (eArg <= 1.0) ? eArg : 2.0 - eArg;
                float eNow = (cosEase > 0.5) ? 0.5 - 0.5 * cos(3.14159265 * eTri) : eTri * eTri * (3.0 - 2.0 * eTri);
                float offNow = abs(xB - eNow) * abs(rngB) * rhoB;                 // distance to the blade line
                marks = max(marks, inR ? (1.0 - smoothstep(0.004, 0.012, offNow)) : 0.0);
                marks = max(marks, 1.0 - smoothstep(0.012, 0.022, rhoB));        // pivot
            }
        }
        float3 c17 = float3(0.10, 0.10, 0.10);
        if (hits > 0.5)
        {
            c17 = (hits > 1.5) ? float3(1.0, 1.0, 1.0) * 0.85 : acc;
        }
        else
        {
            c17 = (frac((pc.x + pc.y) * 14.0) < 0.5) ? float3(1.0, 0.12, 0.08) : float3(0.35, 0.04, 0.03);
        }
        c17 = lerp(c17, float3(1.0, 1.0, 1.0), marks);
        // inside the outline only; glass hidden behind bodywork is dimmed, not dropped
        float3 o17 = lerp(src.rgb, c17 * B17 * (0.35 + 0.65 * beyond), max(aperture, marks * step(0.5, float(nb))) * 0.85);
        pfxOut[storePos] = float4(o17, src.a);
        return;
    }

    // How long ago a blade passed over THIS pixel (smear, haze) -----------------------------------------------------
    float ageP = 1e6;
    float2 pivP = bq[0].xy;
    float rOutP = max(brr[0].y, 0.1);
    [unroll]
    for (int bi = 0; bi < 4; bi++)
    {
        if (bi < nb)
        {
            float psI = 0.0, rcI = 0.0;
            float agI = rpWipeAge(pc, bq[bi], brr[bi], bph[bi], tc, sweepT, period, flags, psI, rcI);
            if (agI < ageP)
            {
                ageP = agI;
                pivP = bq[bi].xy;
                rOutP = max(brr[bi].y, 0.1);
            }
        }
    }

    // ---- forces and motion on the glass (Lua, glass axes: x right, y up the glass) ------------------------------------
    const float r0 = max(rpWindD.w / halfH, 0.0012);             // base radius in glass units (1.0: 'Rain droplet size')
    const float density = saturate(rpWindC.w);
    const float2 F2 = rpWindN.xy;                                // gravity + airflow + inertia, m/s^2
    const float Fmag = length(F2);
    const float2 fdir = (Fmag > 1e-4) ? F2 / Fmag : float2(0.0, -1.0);
    const float lifeClk = rpWindN.z;                             // droplet life clock (faster in the airflow)
    const float2 offs = rpWindO.xy;                              // how far the running drops have travelled
    const float2 vel2 = rpWindO.zw;                              // their speed now (glass units / s)
    const float vlen = length(vel2);
    const float vmag = vlen * halfH;                             // m/s
    const float2 mdir = (vlen > 1e-6) ? vel2 / vlen : float2(0.0, -1.0);
    const float2 mside = float2(-mdir.y, mdir.x);

    float bestScore = 0.0;
    float2 bestQ = float2(0.0, 0.0);
    float2 bestAx = float2(1.0, 0.0);
    float2 bestAy = float2(0.0, 1.0);
    float bestR = r0;
    float bestA = 0.0;
    float bestTile = 0.0;
    float bestStretch = 1.0;
    float trail = 0.0;

    // ---- beads: land, stick, creep toward the force, let go once it beats their adhesion -----------------------------
    {
        const float cs = r0 * 4.8;
        const int2 c0 = int2(floor(pc / cs));
        [unroll]
        for (int j = -1; j <= 1; j++)
        {
            [unroll]
            for (int k = -1; k <= 1; k++)
            {
                int2 c = c0 + int2(k, j);
                uint hs = rpHash3(int3(c.x, c.y, 811));
                float r2 = rpRand(rpPcg(hs ^ 0x1B873593u));
                float r3 = rpRand(rpPcg(hs ^ 0xE6546B64u));
                float2 cen = (float2(c) + 0.15 + 0.70 * float2(r2, r3)) * cs;
                float2 dq0 = pc - cen;
                float reachR = max(r0 * 2.6, 1.3 * mppU);   // biggest bead (1.85 r0) plus its creep
                if (dot(dq0, dq0) < reachR * reachR)
                {
                    // when did a blade last pass this bead -> which generation of drops lives there now
                    float wipeAge = 1e6, passSum = 0.0, wiped = 0.0;
                    rpWipeAll(cen, nb, bq, brr, bph, tl4, wipeAge, passSum, wiped);
                    float landed = rainRate * rpLandAge(wipeAge);      // rain clock elapsed since the last wipe here
                    float genId = gen0 * 8.0 + passSum;               // changes on every pass of any blade
                    float fadeOut = 1.0;
                    if (wiped < 0.5)
                    {
                        // never wiped: slow natural turnover, staggered per cell
                        float tv = rainClock / 25.0 + rpRand(rpPcg(hs ^ 0x68E31DA4u));
                        genId = -1000.0 - floor(tv);
                        landed = frac(tv) * 25.0;
                        fadeOut = 1.0 - smoothstep(22.0, 25.0, landed);
                    }
                    uint hg = rpPcg(hs + uint(int(genId) + 1048576) * 0x9E3779B1u);
                    float r1 = rpRand(hg);
                    float r4 = rpRand(rpPcg(hg ^ 0x85EBCA6Bu));
                    float r5 = rpRand(rpPcg(hg ^ 0x27D4EB2Fu));
                    float r6 = rpRand(rpPcg(hg ^ 0x165667B1u));
                    float since = landed - r5 * 2.2;                   // rain-clock units since this bead landed
                    float grow = smoothstep(0.0, 0.25, since) * fadeOut;
                    float rawRad = r0 * (0.40 + 1.45 * r4 * r4);      // many small beads, a few big merged drops
                    float adh = rpWindAdhesion(rawRad, r0);
                    float mob = saturate((Fmag - adh) / (adh * 1.5)); // 1 = torn off by the force
                    float present = saturate((density * (1.0 - 0.9 * mob) - r1) / 0.06);
                    float radV = max(rawRad, 1.2 * mppU);
                    float a = grow * present * saturate(rawRad / radV);
                    if (a > 0.001)
                    {
                        float2 cc = cen + fdir * (rawRad * 0.35 * saturate(Fmag / adh) * saturate(since * 0.5));
                        float ang = r6 * 6.2831853;
                        float2 ax = float2(cos(ang), sin(ang));
                        float2 ay = float2(-ax.y, ax.x);
                        float2 d = (pc - cc) / radV;
                        float2 q = float2(dot(d, ax), dot(d, ay));
                        // 1.0 every bead its own outline: stretched and lumpy (merged flat drops a little less)
                        q = rpDropWarp(q, rpRand4(rpPcg(hg ^ 0x3C6EF372u)), (r4 > 0.82) ? 0.6 : 1.0);
                        float rr = dot(q, q);
                        float score = (1.0 - rr) * a;
                        if (rr < 1.0 && score > bestScore)
                        {
                            bestScore = score;
                            bestQ = q;
                            bestAx = ax;
                            bestAy = ay;
                            bestR = radV;
                            bestA = a;
                            bestStretch = 1.0;
                            bestTile = (r4 > 0.82) ? (12.0 + floor(r6 * 2.999)) : floor(frac(r6 * 13.7) * 7.999);
                        }
                    }
                }
            }
        }
    }

    // ---- running drops: two grids translated along the glass, like the body droplet streams ---------------------------
    const float runAmt = saturate(rpWindL.z);
    if (runAmt > 0.001)
    {
        [unroll]
        for (int layerS = 0; layerS < 2; layerS++)
        {
            float kS = (layerS == 0) ? 1.0 : 0.62;                  // the second layer runs slower
            float rS = r0 * ((layerS == 0) ? 1.05 : 0.75);
            float csS = rS * 6.0;
            float2 shift = offs * kS;                               // how far this layer has travelled
            float stretchMax = (layerS == 0) ? 4.0 : 2.5;
            float stretchS = 1.0 + stretchMax * (1.0 - exp(-vmag * kS * 3.0 / stretchMax));
            // every cell whose drop can reach this pixel: head, teardrop tail and wet trail (bounded cost)
            float radMax = max(rS * 1.6, 1.2 * mppU);
            float tailLen = max(2.46 * radMax * stretchS, rS * 1.6 * (2.0 + 4.0 * (stretchS - 1.0)));
            float headLen = 1.11 * radMax * stretchS;
            float2 gS = (pc - shift) / csS;
            float2 eA = mdir * (-headLen);
            float2 eB = mdir * tailLen;
            float2 ext = abs(mside) * (radMax * 1.3);
            int2 cLo = int2(floor(gS + (min(eA, eB) - ext) / csS - 0.85));
            int2 cHi = int2(floor(gS + (max(eA, eB) + ext) / csS - 0.15));
            cHi = min(cHi, cLo + int2(7, 7));
            if (rS * 1.6 < 0.25 * mppU)
            {
                cHi = cLo - int2(1, 1);                             // far away the drops are sub-pixel: skip the layer
            }
            [loop]
            for (int cyS = cLo.y; cyS <= cHi.y; cyS++)
            {
                [loop]
                for (int cxS = cLo.x; cxS <= cHi.x; cxS++)
                {
                    int2 c = int2(cxS, cyS);
                    uint hs = rpHash3(int3(c.x, c.y, 7919 + layerS * 131));
                    float L = lerp(1.6, 4.0, rpRand(hs));            // life-clock units per appearance
                    float tt = lifeClk / L + rpRand(rpPcg(hs ^ 0xB5297A4Du));
                    float win = floor(tt);
                    float ph = tt - win;
                    uint hc = rpPcg(hs + uint(win) * 0x9E3779B1u);
                    float r1 = rpRand(hc);
                    float r2 = rpRand(rpPcg(hc ^ 0x1B873593u));
                    float r3 = rpRand(rpPcg(hc ^ 0xE6546B64u));
                    float r4 = rpRand(rpPcg(hc ^ 0x85EBCA6Bu));
                    float r5 = rpRand(rpPcg(hc ^ 0x27D4EB2Fu));
                    float rawRad = rS * (0.55 + 1.05 * r3 * r3);
                    float adh = rpWindAdhesion(rawRad, r0);
                    float mob = saturate((Fmag - adh) / (adh * 1.5));
                    // more running drops where the force can move them, a few even when it is calm
                    float want = density * runAmt * lerp(0.25, 1.0, smoothstep(0.0, 0.4, mob));
                    float presence = saturate((want - r1) / 0.06);
                    float lifeW = smoothstep(0.0, 0.10, ph) * (1.0 - smoothstep(0.80, 1.0, ph));
                    float radV = max(rawRad, 1.2 * mppU);
                    float a = presence * lifeW * saturate(rawRad / radV);
                    if (a > 0.001)
                    {
                        float2 cen = (float2(c) + 0.15 + 0.70 * float2(r2, r4)) * csS + shift;
                        cen += mside * (sin(ph * 7.0 + r5 * 6.2831853) * 0.30 * rawRad);   // wobble across the motion
                        float2 dd = pc - cen;
                        float along = dot(dd, mdir);
                        float across = dot(dd, mside);
                        float stretchD = lerp(1.0, stretchS, smoothstep(0.0, 0.3, mob + 0.2));
                        float tlen = rawRad * (2.0 + 4.0 * (stretchD - 1.0));
                        // only a drop whose head, tail or trail can cover this pixel goes on to the (costly) wiper test
                        if (along < radV * 1.11 * stretchD && along > -max(tlen, 2.46 * radV * stretchD)
                            && abs(across) < radV * 1.3)
                        {
                            float wipeAge = 1e6, passSum = 0.0, wiped = 0.0;
                            rpWipeAll(cen, nb, bq, brr, bph, tl4, wipeAge, passSum, wiped);
                            if (wiped > 0.5)
                            {
                                // wiped glass: the drop has to land after the last pass where it is now
                                float del = r5 * 1.5;
                                a *= smoothstep(del, del + 0.25, rainRate * rpLandAge(wipeAge));
                            }
                            if (a > 0.001)
                            {
                                // wet trail behind the drop
                                float tpar = saturate(-along / max(tlen, 1e-5));
                                float tw = step(along, 0.0) * step(-along, tlen)
                                         * (1.0 - smoothstep(0.6, 1.0, abs(across) / (rawRad * 0.45))) * (1.0 - tpar);
                                trail = max(trail, tw * a);
                                if (stretchD > 1.35)
                                {
                                    // teardrop tile: head (radius 0.56 at q.y = +0.38) toward the motion, tail behind
                                    float s = radV / 0.56;
                                    float2 q = float2(across / s, along / (s * stretchD) + 0.38);
                                    float2 hq = float2(q.x, q.y - 0.38) / 0.56;
                                    float inTail = step(-0.97, q.y) * step(q.y, 0.38) * step(abs(q.x), 0.56 * saturate((q.y + 0.97) / 1.35));
                                    float score = max(1.0 - dot(hq, hq), 0.25 * inTail) * a;
                                    if (max(abs(q.x), abs(q.y)) < 1.0 && score > bestScore)
                                    {
                                        bestScore = score;
                                        bestQ = q;
                                        bestAx = mside;
                                        bestAy = mdir;
                                        bestR = s;
                                        bestA = a;
                                        bestStretch = stretchD;
                                        bestTile = 8.0 + floor(r5 * 3.999);
                                    }
                                }
                                else
                                {
                                    float sy = (along < 0.0) ? stretchD : 1.0;
                                    float2 q = float2(across / radV, along / (radV * sy));
                                    float rr = dot(q, q);
                                    float score = (1.0 - rr) * a;
                                    if (rr < 1.0 && score > bestScore)
                                    {
                                        bestScore = score;
                                        bestQ = q;
                                        bestAx = mside;
                                        bestAy = mdir;
                                        bestR = radV;
                                        bestA = a;
                                        bestStretch = sy;
                                        bestTile = floor(frac(r5 * 13.7) * 7.999);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    float3 col = src.rgb;

    // Thin water haze that builds up between wipes (slightly softens what is seen through the glass).
    float haze = saturate(rainRate * min(rpLandAge(ageP), 60.0) / 18.0) * 0.10 * saturate(rpWindF.z) * glass;
    // Smear right behind the blade: a water film that drains within a fraction of a second.
    float smearT = 0.12 + 0.45 * saturate(rpWindF.x);
    float ruP = saturate(length(pc - pivP) / rOutP);
    float trailG = wiperTexTex.SampleLevel(wiperTex_sampler_, float2(ruP, saturate(ageP / smearT)), 0).g;
    float smear = (1.0 - saturate(ageP / smearT)) * (0.35 + 0.65 * trailG) * glass;
    if (haze + smear > 0.002)
    {
        int br = clamp(int(2.0 + 6.0 * smear), 2, 8);
        float3 soft = rpWindBlur(p, br);
        col = lerp(col, soft * (1.0 + 0.04 * smear), saturate(haze + smear * 0.55));
    }

    // Wet trails left by running drops: a thin film that softens the view a little.
    float trailW = saturate(trail * saturate(rpWindL.w)) * glass;
    if (trailW > 0.002)
    {
        col = lerp(col, rpWindBlur(p, 2) * 0.97, trailW * 0.5);
    }

    if (bestA > 0.001)
    {
        float radPx = clamp(bestR / max(pxIso, 1e-6), 1.0, 160.0);
        // close to the eye a drop is a little out of focus; from outside it is sharp
        float lod = clamp(log2(max(56.0 / radPx, 1.0)) + (outside ? 0.0 : 1.0), 0.0, 3.0);
        float4 sh = rpWindShape(bestQ, bestTile, lod, atlasOK);
        float cover = saturate(sh.w * bestA) * glass;
        if (cover > 0.001)
        {
            float2 nt = sh.xy * float2(1.0, 1.0 / bestStretch);
            float2 nn = nt.x * bestAx + nt.y * bestAy;                    // slope in glass axes (right, up)
            float3 tang = rpWindC.xyz * nn.x + rpWindD.xyz * nn.y;
            // A drop on the glass is a small lens: it shows a displaced, inverted, blurred view of what lies behind it.
            // The slope is projected to the screen, so this holds from the seat and from outside (mirrored axes).
            float2 o = -float2(dot(tang, scrX), dot(tang, scrY)) * radPx * 1.6 * rpWindF.w;
            o = clamp(o, float2(-96.0, -96.0), float2(96.0, 96.0));
            int b = clamp(int(radPx * 0.18), 1, 8);
            int2 q0 = p + int2(round(o));
            float3 through = rpWindBlur(q0, b);
            float thick = saturate(sh.z);
            float rim = 1.0 - smoothstep(0.0, 0.5, thick);
            float3 nd = normalize(rpWindB.xyz * max(sqrt(saturate(1.0 - dot(nn, nn))), 0.05) + tang);
            float3 V = normalize(ro - Pw);
            float F = rpFresnel(0.02, saturate(dot(nd, V)));
            float3 skyRefl = rpSkyColor(reflect(-V, nd)) * 0.318;
            float hl = pow(saturate(dot(nn, float2(-0.35, 0.85)) * 1.1), 8.0) * thick;
            float3 dcol = through * (1.0 - 0.60 * rim);
            dcol += skyRefl * (0.08 + 0.6 * F);
            dcol += hl * (0.06 + 0.5 * rpLuma(through));
            col = lerp(col, dcol, cover);
        }
    }

    // No wiper blades are drawn: the car's own 3D wipers stay as they are, and the glass simply clears where the car's
    // real blades sweep (wipe ages above).

    if (rpMode.x > 7.5 && rpMode.x < 8.5)
    {
        // Debug 8: cyan = glass (beyond-the-glass mask), yellow = freshly wiped, white = drops
        float B = max(rpLuma(src.rgb), 0.05) * 2.0 * rpMode.w;
        col = float3(0.12, 0.12, 0.12) * B;
        col = lerp(col, float3(0.1, 0.8, 1.0) * B, glass);
        col = lerp(col, float3(1.0, 0.8, 0.05) * B, glass * (1.0 - saturate(ageP / 2.0)));
        col = lerp(col, float3(1.0, 1.0, 1.0) * B, saturate(bestA * 2.0) * glass);
    }

    pfxOut[storePos] = float4(col, src.a);
}
