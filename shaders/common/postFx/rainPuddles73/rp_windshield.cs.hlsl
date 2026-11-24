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
// * 1.6.1 two layers: the wiped glass gathers fresh drops, which then give way, cell by cell, to the very beads of the
//   glass the blades never reach, so a wiped arc left alone merges back into the glass around it with no seam.
// * Drops move like the body droplets (1.0): beads stick until the force on them (gravity, airflow, the car's
//   acceleration; rpWindN from Lua) beats their adhesion - big ones go first, small ones stay; running drops on two
//   grids that translate along the glass (rpWindO, integrated in Lua, so there is no cut-off at any speed) streak into
//   teardrops and leave wet trails.

static const float RP_TILE_IN = 112.0 / 128.0;
float3 rpWindLoad(int2 q)
{
    return colorTexTex.Load(int3(clamp(q, int2(dispatchRect.xy), int2(dispatchRect.xy + dispatchRect.zw) - 1), 0)).rgb;
}

float3 rpWindBlur(int2 q, int r)
{
    return rpWindLoad(q) * 0.28
         + (rpWindLoad(q + int2(r, 0)) + rpWindLoad(q - int2(r, 0)) + rpWindLoad(q + int2(0, r)) + rpWindLoad(q - int2(0, r))) * 0.18;
}

// 1.3: the frame seen through a drop, bilinear (colour buffer through the atlas' linear clamp sampler), as the body drops
float3 rpWindTap(float2 pos, float2 invSize)
{
    float2 lo = dispatchRect.xy + 1.0;
    float2 hi = dispatchRect.xy + dispatchRect.zw - 2.0;
    return colorTexTex.SampleLevel(dropTex_sampler_, (clamp(pos, lo, hi) + 0.5) * invSize, 0).rgb;
}

// 1.3: depth-buffer value at screen pixel q, through the depth slot's own uv (render scaling / upscaling)
float rpWindDepthAt(int2 q)
{
    float2 uv = (float2(q) + 0.5 - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
    return windDepthTex.SampleLevel(windDepth_sampler_, viewportCoordToRenderTarget(uv, rtParams1), 0).r;
}

// 1.3 (as the body drops): sky visible along the top of the screen, 8 probes at the same addresses for every pixel:
// its average for reflections that leave the screen, plus the brightest direction (sun side) and colour for the glints.
float3 rpWindVisibleSky(int2 p, float3 ray0, float3 dxr, float3 dyr, out float conf, out float3 keyDir, out float3 keyCol)
{
    float3 sum = float3(0.0, 0.0, 0.0);
    float3 kd = float3(0.0, 0.0, 0.0);
    float n = 0.0;
    float bestL = 0.0;
    keyCol = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 8; i++)
    {
        int2 q = rpClampPix(int2(dispatchRect.xy + float2((float(i) + 0.5) / 8.0, 0.05) * dispatchRect.zw));
        if (rpIsSkyDepth(rpWindDepthAt(q)))
        {
            float3 c = rpWindLoad(q);
            float L = rpLuma(c);
            float3 dir = normalize(ray0 + dxr * float(q.x - p.x) + dyr * float(q.y - p.y));
            sum += c;
            n += 1.0;
            kd += dir * (L * L);
            if (L > bestL)
            {
                bestL = L;
                keyCol = c;
            }
        }
    }
    conf = saturate(n / 2.0);
    keyDir = (dot(kd, kd) > 1e-12) ? normalize(kd) : float3(0.0, 0.0, 1.0);
    keyDir = normalize(float3(keyDir.xy, max(keyDir.z, 0.15)));
    return sum / max(n, 1.0);
}

// 1.3 (as the body drops): the reflection along R read from the frame (far field), else the visible / ambient sky
float3 rpWindEnvRefl(float3 R, int2 p, float3 prk, float3 pra, float3 prb, float3 skyFill, float skyConf)
{
    float3 res = lerp(rpSkyColor(R) * 0.318, skyFill, skyConf);
    float2 off = float2(0.0, 0.0);
    if (rpProjectFast(prk, pra, prb, R, off))
    {
        int2 q = int2(round(float2(p) + off));
        float2 rel = (float2(q) - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
        float conf = smoothstep(0.0, 0.08, rel.x) * (1.0 - smoothstep(0.92, 1.0, rel.x))
                   * smoothstep(0.0, 0.08, rel.y) * (1.0 - smoothstep(0.92, 1.0, rel.y));
        if (conf > 0.001)
        {
            float3 c = rpWindLoad(q) * 0.5
                     + (rpWindLoad(q + int2(2, 0)) + rpWindLoad(q - int2(2, 0))
                      + rpWindLoad(q + int2(0, 2)) + rpWindLoad(q - int2(0, 2))) * 0.125;
            res = lerp(res, c, conf * 0.85);
        }
    }
    return res;
}

// 1.3: strength of a drop drawn at radV although it is only rawRad big. From the seat it fades (no sparkle from
// sub-pixel drops). From outside only every (radV / rawRad)^2-th drop is drawn, at full strength: the glass keeps its
// real wet coverage as distinct specks a viewer can see (enlarging them all made the glass one pale haze).
float rpWindDropAlpha(float rawRad, float radV, uint h, bool outside)
{
    float k = saturate(rawRad / max(radV, 1e-6));
    if (!outside)
    {
        return k;
    }
    return step(rpRand(rpPcg(h ^ 0x051ED27Fu)), k * k);
}

bool rpAtlasValid()
{
    float4 m = dropTexTex.SampleLevel(dropTex_sampler_, RP_ATLAS_CAL_UV, 0.0);
    float4 d = abs(m - float4(0.251, 0.749, 0.502, 1.0));
    return max(max(d.x, d.y), max(d.z, d.w)) < 0.06;
}

// Droplet shape at q (tile space, |q| <= 1) from the shared droplet atlas: normal xy, thickness, coverage.
// Tiles 0-7 round beads, 8-11 teardrops (head toward +y), 12-14 flat merged drops (1.2: 4 x 8 atlas, rp_lib.h.hlsl).
float4 rpWindShape(float2 q, float tile, float lod, bool atlas)
{
    float4 s = float4(0.0, 0.0, 0.0, 0.0);
    float inside = step(max(abs(q.x), abs(q.y)), 0.999);
    if (atlas)
    {
        float2 uv = rpAtlasUV(q, tile);
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

// Tangential force (m/s^2) a drop of radius rad resists on glass, as the body droplets: small drops hold on longest.
float rpWindAdhesion(float rad, float baseRad)
{
    return 3.75 * pow(baseRad / max(rad, 1e-5), 1.2);
}

// 1.6.1 how much rain (rain-clock units) landed on a point of the glass since a blade last passed it, age seconds ago
// (1e5 and more: never). From the pane's own rain clock, stamped by Lua when each wiper cycle began, with the clock's rate
// then (rpWindX): a pass is part of the sweep at the start of its cycle, a second or so, so the clock at the pass is the
// stamp plus that rate times the seconds into the cycle. That stays fixed once the pass is done, so the rain since it
// counts on exactly with the clock - also when the rain or the speed changes. The clock stops under a roof (1.0 tunnels:
// no rain lands there; the drops that landed before stay until a blade wipes them). (Up to 1.6.0 it was the rain rate
// now times the time since the pass less the time under a roof, so fresh drops came and went when the car sped up or
// slowed down.)
float rpRainSince(float age, float tc, float sweepT)
{
    if (!(age < 1e5))
    {
        return 1e4;
    }
    float r;
    if (age <= tc)
    {
        r = rpWindX.x - rpWindX.y * clamp(tc - age, 0.0, sweepT);           // a pass of the current cycle
    }
    else
    {
        r = rpWindX.z - rpWindX.w * clamp(rpWindY.x - age, 0.0, sweepT);    // a pass of the cycle before
    }
    return isfinite(r) ? max(r, 0.0) : 1e4;
}

// 1.6.1 rpWipeAll for the beads, plus which pass that was: all the passes over q so far, counted so that a pass of the
// cycle before is the last of that cycle (every blade that reaches q passes it twice a cycle). The drops a pass leaves
// keep their identity until the next pass, also when a new cycle begins before a blade is back at q. (Up to 1.6.0 they
// changed at every cycle start, so the drops ahead of the blades swapped places just before they were wiped.)
void rpWipeLast(float2 q, int nb, float4 bq[4], float2 brr[4], float4 bph, float4 tl, float cycles, out float wipeAge,
                out float passId, out float wiped)
{
    wipeAge = 1e6;
    wiped = 0.0;
    float passSum = 0.0;
    float nReach = 0.0;
    [unroll]
    for (int bj = 0; bj < 4; bj++)
    {
        if (bj < nb)
        {
            float psJ = 0.0, rcJ = 0.0;
            const float agJ = rpWipeAge(q, bq[bj], brr[bj], bph[bj], tl.x, tl.y, tl.z, tl.w, psJ, rcJ);
            wipeAge = min(wipeAge, agJ);
            wiped = max(wiped, rcJ);
            passSum += psJ;
            nReach += rcJ;
        }
    }
    passId = max(cycles - 1.0, 0.0) * 2.0 * nReach + passSum;
}

// 1.5 glass water (rp_glass.cs.hlsl) at glass point q (pc units): x the water there (0 dry / just wiped .. 1 beaded all
// over; more: a line the blades pushed together), y the film a blade left
float2 rpGlassWater(float2 q, float aspectP)
{
    const float m = max(rpWindU.z, 1.0);
    const float2 r = glassTexTex.SampleLevel(glassTex_sampler_, float2(q.x / aspectP, q.y) / (2.0 * m) + 0.5, 0).rg;
    return float2(isfinite(r.x) ? max(r.x, 0.0) : 0.0, isfinite(r.y) ? saturate(r.y) : 0.0);
}

// 1.6 the mist on the glass at glass point q (pc units), from the same field (z): 0 clear .. 1.5 fogged over
float rpGlassFog(float2 q, float aspectP)
{
    const float m = max(rpWindU.z, 1.0);
    const float f = glassTexTex.SampleLevel(glassTex_sampler_, float2(q.x / aspectP, q.y) / (2.0 * m) + 0.5, 0).b;
    return isfinite(f) ? clamp(f, 0.0, 1.5) : 0.0;
}

// 1.5.1: how far the running drops travelled in the last T seconds (glass units; rpWindV: every 0.5 s back to 4 s,
// linear between; longer ago at the speed they have now)
float2 rpTravel(float T)
{
    const float s = clamp(T, 0.0, 4.0) * 2.0;
    float2 d = rpWindV0.xy * saturate(s);
    d += (rpWindV0.zw - rpWindV0.xy) * saturate(s - 1.0);
    d += (rpWindV1.xy - rpWindV0.zw) * saturate(s - 2.0);
    d += (rpWindV1.zw - rpWindV1.xy) * saturate(s - 3.0);
    d += (rpWindV2.xy - rpWindV1.zw) * saturate(s - 4.0);
    d += (rpWindV2.zw - rpWindV2.xy) * saturate(s - 5.0);
    d += (rpWindV3.xy - rpWindV2.zw) * saturate(s - 6.0);
    d += (rpWindV3.zw - rpWindV3.xy) * saturate(s - 7.0);
    d += rpWindO.zw * max(T - 4.0, 0.0);
    return isfinite(d.x + d.y) ? d : float2(0.0, 0.0);
}

// 1.5.1 water lines, per set of drops (0 the ones that stay on the line, 1..3 runners): travel x the running drops'
// when they creep (big drops slide much faster than the small running ones; in a strong airflow everything is fast and
// the factor drops toward 1), seconds before they let go, cell length and radius range (x the base drop radius), share
// of cells with a drop
static const float RP_LINE_M[4] = { 0.0, 1.5, 3.0, 5.0 };
static const float RP_LINE_TAU[4] = { 0.0, 0.4, 0.2, 0.06 };
static const float RP_LINE_CELL[4] = { 5.0, 6.0, 7.0, 8.0 };
static const float RP_LINE_RLO[4] = { 0.7, 0.9, 1.1, 1.3 };
static const float RP_LINE_RHI[4] = { 1.6, 1.8, 2.0, 2.3 };
static const float RP_LINE_WANT[4] = { 0.45, 0.2, 0.16, 0.12 };

// Drop k of set cls in the line blade b left at end e (generation gen): where along the blade (rho, pc units from its
// pivot), how far beyond its arc (off), its radius and whether it is there. The blade brings more water toward its tip,
// where it swept a longer arc (wCol: how wet that arc was).
void rpLineDrop(int k, float gen, int b, int e, int cls, float cell, float lw, float r0, float density, float2 rr,
                float rngAbs, float wCol, out float rho, out float off, out float rad, out float pres, out uint h)
{
    h = rpHash3(int3(k, int(gen) * 8 + b * 2 + e, 6007 + cls * 131));
    const float r1 = rpRand(h);
    const float r2 = rpRand(rpPcg(h ^ 0x1B873593u));
    const float r3 = rpRand(rpPcg(h ^ 0xE6546B64u));
    const float r4 = rpRand(rpPcg(h ^ 0x85EBCA6Bu));
    rho = (float(k) + 0.2 + 0.6 * r2) * cell;
    off = lw * (0.15 + 0.7 * r3);
    const float loadN = saturate(wCol * rho * rngAbs / 1.1);
    rad = r0 * lerp(RP_LINE_RLO[cls], RP_LINE_RHI[cls], r4 * r4) * (0.75 + 0.35 * sqrt(loadN));
    const float want = RP_LINE_WANT[cls] * saturate(density * 1.4) * smoothstep(0.03, 0.4, loadN);
    pres = (rho > rr.x && rho < rr.y + 0.01) ? saturate((want - r1) / 0.05) : 0.0;
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
    float aperture = rpPaneAperture(uv, halfW, halfH);
    // 1.5 glass water: from outside, the body right beside the glass gets the water the blades push or the airflow
    // blows off it (the water field reaches rpWindU.z half sizes out)
    const bool useState = rpWindU.y > 0.5;
    const bool pillarZone = useState && outside && abs(uv.x) < rpWindU.z && abs(uv.y) < rpWindU.z;
    // 1.0: nothing of this pane at this pixel: done before the depth is read (most of the screen; debug views go on)
    if (aperture < 0.001 && !pillarZone && !(rpMode.x > 7.5 && rpMode.x < 8.5) && !(rpMode.x > 15.5 && rpMode.x < 17.5))
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
    if (!rpIsSkyDepth(ndc))   // 1.3: was ndc < 0.99999, which let the reversed-Z sky (0) through as an infinite depth
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
    // 1.5: the body strip beside the glass (outside views): its surface sits at the glass plane, within a few cm
    const float onBody = pillarZone ? (1.0 - aperture) * (1.0 - smoothstep(0.03, 0.08, abs(sceneDist - t))) : 0.0;
    const float glassD = max(glass, onBody);                     // where drops may be drawn
    const bool dbgWipers = (rpMode.x > 16.5 && rpMode.x < 17.5);
    if (glassD < 0.001 && !(rpMode.x > 7.5 && rpMode.x < 8.5) && !(dbgWipers && aperture > 0.001) && !(rpMode.x > 22.5 && rpMode.x < 23.5))
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
    // 1.3: from outside (chase and showcase views) a drop is drawn at least 2 px wide (see rpWindDropAlpha): at a few
    // metres real drops are a pixel or less and vanished, although wet glass reads clearly speckled
    const float minPx = outside ? 2.0 : 1.2;
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
    const float gen0 = rpWindI.x;                                // wiper cycles begun so far (this one included)
    const bool atlasOK = rpAtlasValid();
    const float4 tl4 = float4(tc, sweepT, period, flags);
    // 1.6.1 the same timeline for how long ago a blade passed a point, with the cycle before as it really was (rpWindY.x:
    // seconds since it began - also a single wipe, or the last cycle before the wipers were switched off and on again),
    // so a point the blades have not reached yet in this cycle still knows when it was wiped last. (Up to 1.6.0 only a
    // repeating run knew; elsewhere such a point counted as never wiped until the blade came.)
    const bool prevK = rpWindY.x < 99999.0;
    const float flagsW = flags - 2.0 * fmod(floor(flags / 2.0), 2.0) - 4.0 * fmod(floor(flags / 4.0), 2.0)
                       + (prevK ? 6.0 : 0.0);
    const float4 tlW = float4(tc, sweepT, prevK ? max(rpWindY.x - tc, sweepT) : period, flagsW);

    // Wiper blades (rp_pane.h.hlsl): the car's own, or the procedural tandem pair mirrored for RHD; none on the rear /
    // hatch glass without a wiper
    float4 bq[4];
    float2 brr[4];
    float4 bph;
    int nb = rpBladeSetup(aspectP, bq, brr, bph);

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
                float xB = rpWrapPi(atan2(dB.y, dB.x + 1e-9) - bq[bd].z) / rngB;
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
            float agI = rpWipeAge(pc, bq[bi], brr[bi], bph[bi], tlW.x, tlW.y, tlW.z, tlW.w, psI, rcI);
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
    float bestLensK = 1.0;                                       // 1.5.1: x the lens size (flat line water: less)
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
                float reachR = max(r0 * 2.6, (minPx + 0.1) * mppU);   // biggest bead (1.85 r0) plus its creep
                if (dot(dq0, dq0) < reachR * reachR)
                {
                    // 1.6.1 two layers, one pattern. Layer 1 is the glass where no blade comes by: each cell holds one
                    // bead at a time, which lands, stays and gives way to the next one on a slow turnover cycle of the
                    // cell's own (25 rain-clock units, staggered per cell). Layer 2 is what a blade leaves: a fresh set
                    // of drops lands on the wiped glass, each at its own moment (sooner in heavy rain and when driving
                    // into it), and grows. When the cell's cycle turns over, the fresh drop gives way like any other and
                    // the bead that follows is layer 1's own, so a wiped arc left alone becomes the glass around it
                    // again, cell by cell, with no seam and no jump; the next pass starts layer 2 over. (Up to 1.6.0
                    // every pass gave the arc a set of drops of its own for good: it never became the glass around it.)
                    float wipeAge = 1e6, passId = 0.0, wiped = 0.0;
                    rpWipeLast(cen, nb, bq, brr, bph, tlW, gen0, wipeAge, passId, wiped);
                    const float tv = rainClock / 25.0 + rpRand(rpPcg(hs ^ 0x68E31DA4u));
                    const float cyc = frac(tv) * 25.0;                       // rain clock into the cell's cycle
                    const float rainW = rpRainSince(wipeAge, tc, sweepT);    // rain since a blade last passed here
                    // layer 2 while the last pass came after the cell's cycle began, layer 1 from its next turnover on
                    const bool fresh = (wiped > 0.5) && (rainW < cyc);
                    const float genId = fresh ? passId : (-1000.0 - floor(tv));
                    const float landed = fresh ? rainW : cyc;               // rain clock since these drops began to land
                    const float fadeOut = 1.0 - smoothstep(22.0, 25.0, cyc); // the turnover: the bead gives way
                    uint hg = rpPcg(hs + uint(int(genId) + 1048576) * 0x9E3779B1u);
                    float r1 = rpRand(hg);
                    float r4 = rpRand(rpPcg(hg ^ 0x85EBCA6Bu));
                    float r5 = rpRand(rpPcg(hg ^ 0x27D4EB2Fu));
                    float r6 = rpRand(rpPcg(hg ^ 0x165667B1u));
                    float since = landed - r5 * 2.2;                   // rain-clock units since this bead landed
                    float grow = smoothstep(0.0, 0.25, since) * fadeOut;
                    // many small beads, a few big merged drops; 1.6.1: a drop lands small and grows as the rain landing
                    // after it joins it (a big merged drop takes longest)
                    float rawRad = r0 * (0.40 + 1.45 * r4 * r4)
                                 * lerp(0.6, 1.0, smoothstep(0.0, (r4 > 0.82) ? 3.0 : 1.2, since));
                    // 1.5 glass water: on wiped glass the water there now decides which of the pass's drops show - rain
                    // landing, water running in with gravity and the airflow - instead of each drop's own landing time
                    // (1.6.1: layer 1's beads land on their own clock, as without glass water). Where a blade is pushing
                    // the water together right now (above 1, inside its sweep) the drops are big and merged.
                    // (1.5.1: the line it leaves beyond the end of its sweep is drawn below as water lines whose drops
                    // run off; up to 1.5.0 it was big beads here that only ever faded in place.)
                    float wat = 1.0;
                    if (useState)
                    {
                        wat = rpGlassWater(cen, aspectP).x;
                        grow = fresh ? fadeOut : grow;
                        rawRad *= 1.0 + 0.7 * saturate(wat - 1.0) * wiped;
                    }
                    float adh = rpWindAdhesion(rawRad, r0);
                    float mob = saturate((Fmag - adh) / (adh * 1.5)); // 1 = torn off by the force
                    float present = saturate((density * (1.0 - 0.9 * mob) * min(wat, 1.0) - r1) / 0.06);
                    if (wat > 1.2 && wiped > 0.5)
                    {
                        present = max(present, saturate((wat - 1.2) * 2.0) * step(r1, 0.9));
                    }
                    float radV = max(rawRad, minPx * mppU);
                    float a = grow * present * rpWindDropAlpha(rawRad, radV, hg, outside);
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
                            bestLensK = 1.0;
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
            float radMax = max(rS * 1.6, minPx * mppU);
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
                    float radV = max(rawRad, minPx * mppU);
                    float a = presence * lifeW * rpWindDropAlpha(rawRad, radV, hc, outside);
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
                            if (useState)
                            {
                                // 1.5: a running drop lives where there is water on the glass now (glass water field)
                                a *= smoothstep(0.15 + 0.5 * r5, 0.45 + 0.5 * r5, rpGlassWater(cen, aspectP).x);
                            }
                            else
                            {
                                float wipeAge = 1e6, passSum = 0.0, wiped = 0.0;
                                rpWipeAll(cen, nb, bq, brr, bph, tlW, wipeAge, passSum, wiped);
                                if (wiped > 0.5)
                                {
                                    // wiped glass: the drop has to land after the last pass where it is now (1.6.1: the
                                    // rain that really landed since, so a change of speed no longer makes it come and go)
                                    float del = r5 * 1.5;
                                    a *= smoothstep(del, del + 0.25, rpRainSince(wipeAge, tc, sweepT));
                                }
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
                                        bestLensK = 1.0;
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
                                        bestLensK = 1.0;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- 1.5.1 water lines. Where a blade turns or parks it leaves the water it pushed along as a line of big drops just
    // beyond its sweep (more toward its tip, where it swept a longer arc). Up to 1.5.0 they stayed there as beads; now
    // the biggest let go first and run off with gravity, the airflow and the car's inertia along the path the running
    // drops really took (rpTravel), each leaving a wet trail, while the small ones stay on the line until the blade comes
    // back (at speed most of it is blown away). Per line: the drops that stay, three sets of runners (bigger = earlier
    // and faster) and the runners of the line before, still on their way.
    float lineA = 0.0;                                            // (debug 23)
    if (useState && nb > 0 && fmod(flags, 2.0) > 0.5)
    {
        const float lw = 0.012 / halfH;                           // as wide as the band the blade leaves it in
        const float lifeR = min(2.0 * period, 6.0);               // runners are gone before two lines later
        const bool prevOK = fmod(floor(flags / 2.0), 2.0) > 0.5 && fmod(floor(flags / 4.0), 2.0) > 0.5;
        const float blown = smoothstep(0.03, 0.2, length(rpTravel(1.0)));   // strong airflow: the line does not stay
        [loop]
        for (int bL = 0; bL < nb; bL++)
        {
            const float4 blL = bq[bL];
            const float2 rrL = brr[bL];
            const float rngL = (blL.w >= 0.0) ? max(blL.w, 1e-3) : min(blL.w, -1e-3);
            [loop]
            for (int eL = 0; eL < 2; eL++)
            {
                float genL = 0.0;
                const float ageL = rpLineAge(float(eL), bph[bL], tc, sweepT, period, flags, gen0, genL);
                const float thL = blL.z + float(eL) * rngL;
                const float2 uL = float2(cos(thL), sin(thL));                     // along the blade, out from its pivot
                const float2 nL = float2(-uL.y, uL.x) * (sign(rngL) * ((eL == 1) ? 1.0 : -1.0));   // away from its arc
                // how wet the arc was that it swept: the rain since it last passed there (the pause before the out sweep)
                const float wCol = 1.0 - exp(-0.45 * rainRate * ((eL == 1) ? (period - 0.5 * sweepT) : 0.5 * sweepT));
                // can any drop of this line reach this pixel? (the fastest runners, of this line and the one before)
                const float2 relL = pc - blL.xy;
                const float alL = clamp(dot(relL, uL), rrL.x, rrL.y);
                const float reachL = RP_LINE_M[3] * max(length(rpTravel(ageL)), length(rpTravel(ageL + period)))
                                   + lw + 14.0 * r0;
                if (ageL < 1e5 && length(relL - alL * uL) < reachL)
                {
                    [loop]
                    for (int sL = 0; sL < 7; sL++)
                    {
                        const int cls = (sL <= 3) ? sL : sL - 3;
                        const bool prevL = (sL >= 4);
                        const float ageC = ageL + (prevL ? period : 0.0);
                        const float genC = genL - (prevL ? 2.0 : 0.0);
                        const float fadeC = (cls == 0) ? (1.0 - smoothstep(8.0, 20.0, ageC)) * (1.0 - 0.8 * blown)
                                                       : 1.0 - smoothstep(0.55 * lifeR, lifeR, ageC);
                        if (fadeC > 0.001 && (!prevL || prevOK))
                        {
                            const float cellC = r0 * RP_LINE_CELL[cls];
                            const float runT = (cls > 0) ? max(ageC - RP_LINE_TAU[cls], 0.0) : 0.0;   // running for (s)
                            const float2 dRef = rpTravel(runT);
                            const float vAvg = length(dRef) * halfH / max(runT, 0.05);             // m/s over the run
                            const float mC = (cls > 0) ? 1.0 + (RP_LINE_M[cls] - 1.0) / (1.0 + vAvg / 0.15) : 0.0;
                            const float2 dC = mC * dRef;
                            const float dLen = length(dC);
                            // a runner slides head first with a short tail, drawn out more the faster it goes
                            const float stretchC = (cls > 0) ? 1.0 + (0.6 + 1.6 * (1.0 - exp(-mC * vmag * 2.0))) * smoothstep(0.0, 0.25, runT) : 1.0;
                            const float radHi = r0 * RP_LINE_RHI[cls] * 1.2;
                            const float tailC = 2.46 * radHi * stretchC * 1.2;
                            const float2 relC = pc - dC - blL.xy;
                            const float alC = dot(relC, uL);
                            const float acC = dot(relC, nL);
                            const float extC = tailC + radHi * 1.3;
                            if (acC > -extC && acC < lw + extC && alC > rrL.x - extC && alC < rrL.y + 0.01 + extC)
                            {
                                const float extA = abs(dot(mdir, uL)) * tailC + radHi * 1.3;   // reach along the line
                                const int kLo = int(floor((alC - extA) / cellC));
                                const int kHi = min(int(floor((alC + extA) / cellC)), kLo + 4);
                                [loop]
                                for (int kC = kLo; kC <= kHi; kC++)
                                {
                                    float rhoK = 0.0, offK = 0.0, radK = r0, presK = 0.0;
                                    uint hK = 0u;
                                    rpLineDrop(kC, genC, bL, eL, cls, cellC, lw, r0, density, rrL, abs(rngL), wCol,
                                               rhoK, offK, radK, presK, hK);
                                    float radV = max(radK, minPx * mppU);
                                    float a = presK * fadeC * rpWindDropAlpha(radK, radV, hK, outside);
                                    if (a > 0.001)
                                    {
                                        float r5 = rpRand(rpPcg(hK ^ 0x27D4EB2Fu));
                                        float r6 = rpRand(rpPcg(hK ^ 0x165667B1u));
                                        float2 cen = blL.xy + rhoK * uL + offK * nL + dC;
                                        // a runner meanders a little across its path
                                        float2 sideD = (dLen > 1e-5) ? float2(-dC.y, dC.x) / dLen : nL;
                                        cen += sideD * (sin(dLen / (radK * 3.0) + r5 * 6.2831853) * 0.25 * radK * saturate(dLen / radK));
                                        float2 dd = pc - cen;
                                        if (runT > 0.0 && dLen > 1e-5)
                                        {
                                            float along = dot(dd, mdir);
                                            float across = dot(dd, mside);
                                            float stC = stretchC * (0.8 + 0.4 * r6);              // each its own length
                                            if (along < radV * 1.11 * stC && along > -2.46 * radV * stC && abs(across) < radV * 1.3)
                                            {
                                                // gone where a blade swept it (it was already there when the blade passed)
                                                float wA = 1e6, wP = 0.0, wR = 0.0;
                                                rpWipeAll(cen, nb, bq, brr, bph, tl4, wA, wP, wR);
                                                if (wA < ageC && length(mC * rpTravel(min(wA, runT))) < radV * 1.5)
                                                {
                                                    a = 0.0;
                                                }
                                                // the wet trail right behind it
                                                float tl = radK * (2.0 + 4.0 * (stC - 1.0));
                                                float tpar = saturate(-along / max(tl, 1e-5));
                                                trail = max(trail, step(along, 0.0) * step(-along, tl) * (1.0 - tpar) * a
                                                                   * (1.0 - smoothstep(0.6, 1.0, abs(across) / (radK * 0.45))));
                                                if (frac(r5 * 7.31) < 0.6 + 0.35 * smoothstep(1.8, 3.0, stC))
                                                {
                                                    // a slim line swelling into a round head (tiles 16-19, as the body droplet
                                                    // streams): the head 0.7 x the radius, the tile drawn out by stC / 2.7
                                                    float Se = stC / 2.7;
                                                    float sE = 0.7 * radV / 0.18;
                                                    float2 q = float2(across / sE, along / (sE * Se) + 0.70);
                                                    float2 hq = float2(q.x, q.y - 0.70) / 0.18;
                                                    float tT = saturate((q.y + 0.95) / 1.65);
                                                    float wT = 0.012 + 0.168 * tT * sqrt(tT);
                                                    float inTail = step(-0.95, q.y) * step(q.y, 0.70) * step(abs(q.x), wT);
                                                    float score = max(1.0 - dot(hq, hq), 0.25 * inTail) * a;
                                                    if (max(abs(q.x), abs(q.y)) < 1.0 && score > bestScore)
                                                    {
                                                        bestScore = score;
                                                        bestQ = q;
                                                        bestAx = mside;
                                                        bestAy = mdir;
                                                        bestR = sE;
                                                        bestA = a;
                                                        bestStretch = Se;
                                                        bestTile = 16.0 + floor(r5 * 3.999);
                                                        bestLensK = min(1.0, 1.1 * r0 / radV);
                                                        lineA = max(lineA, a);
                                                    }
                                                }
                                                else
                                                {
                                                    // teardrop tile: head toward the motion, tail behind (as the running drops)
                                                    float sT = radV / 0.56;
                                                    float2 q = float2(across / sT, along / (sT * stC) + 0.38);
                                                    float2 hq = float2(q.x, q.y - 0.38) / 0.56;
                                                    float inTail = step(-0.97, q.y) * step(q.y, 0.38) * step(abs(q.x), 0.56 * saturate((q.y + 0.97) / 1.35));
                                                    float score = max(1.0 - dot(hq, hq), 0.25 * inTail) * a;
                                                    if (max(abs(q.x), abs(q.y)) < 1.0 && score > bestScore)
                                                    {
                                                        bestScore = score;
                                                        bestQ = q;
                                                        bestAx = mside;
                                                        bestAy = mdir;
                                                        bestR = sT;
                                                        bestA = a;
                                                        bestStretch = stC;
                                                        bestTile = 8.0 + floor(r5 * 3.999);
                                                        bestLensK = min(1.0, 1.1 * r0 / radV);
                                                        lineA = max(lineA, a);
                                                    }
                                                }
                                            }
                                        }
                                        else
                                        {
                                            // still on the line: a merged drop, drawn out a little along it
                                            float asp = 1.15 + 0.6 * r6;
                                            float2 q = float2(dot(dd, nL) / radV, dot(dd, uL) / (radV * asp));
                                            q = rpDropWarp(q, rpRand4(rpPcg(hK ^ 0x3C6EF372u)), 0.6);
                                            float rr = dot(q, q);
                                            float score = (1.0 - rr) * a;
                                            if (rr < 1.0 && score > bestScore)
                                            {
                                                float wA = 1e6, wP = 0.0, wR = 0.0;
                                                rpWipeAll(cen, nb, bq, brr, bph, tl4, wA, wP, wR);
                                                if (wA >= ageC)
                                                {
                                                    bestScore = score;
                                                    bestQ = q;
                                                    bestAx = nL;
                                                    bestAy = uL;
                                                    bestR = radV;
                                                    bestA = a;
                                                    bestStretch = asp;
                                                    bestTile = 12.0 + floor(r6 * 2.999);
                                                    bestLensK = min(1.0, 1.1 * r0 / radV);     // flat water
                                                    lineA = max(lineA, a);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // the wet trail a runner leaves: back along this set's travel to the line, whose drop ran here
                            if (cls > 0 && dLen > 2.0 * r0)
                            {
                                const float2 relT = pc - blL.xy - (0.5 * lw) * nL;
                                const float det = uL.x * dC.y - uL.y * dC.x;
                                if (abs(det) > 0.35 * dLen)
                                {
                                    const float rho0 = (relT.x * dC.y - relT.y * dC.x) / det;
                                    const float lam = (uL.x * relT.y - uL.y * relT.x) / det;
                                    if (lam > 0.0 && lam < 1.0)
                                    {
                                        float rhoT = 0.0, offT = 0.0, radT = r0, presT = 0.0;
                                        uint hT = 0u;
                                        rpLineDrop(int(floor(rho0 / cellC)), genC, bL, eL, cls, cellC, lw, r0, density, rrL,
                                                   abs(rngL), wCol, rhoT, offT, radT, presT, hT);
                                        // laid when the drop passed here; wiped if a blade passed this pixel since
                                        if (presT > 0.001 && ageP > runT * (1.0 - lam))
                                        {
                                            float wT = 1.0 - smoothstep(0.25, 0.45, abs(rho0 - rhoT) / radT);
                                            trail = max(trail, presT * fadeC * wT * (0.3 + 0.7 * lam));
                                        }
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

    // ---- 1.6 glass fog -------------------------------------------------------------------------------------------------
    // A fine mist on the outside of the glass (drizzle and fog drops too small to bead, condensation on glass the airflow
    // cools). Where the glass water is simulated it comes from that field: the blades wipe it off, it comes back, running
    // water cuts clear channels through it. Else it comes back since a blade last passed this point (rpWindW.y), or (side
    // windows, no wipers) it is the pane's own level. Fogged glass blurs and softens what is seen through it - shapes stay,
    // contrast goes, lights bloom into halos - and lays a milky veil of the light it scatters over it. The drops drawn
    // further down stay clear in it, as real beads take the mist around them in.
    float fogF = 0.0;
    if (rpWindW.w > 0.0005)
    {
        if (useState)
        {
            fogF = rpGlassFog(pc, aspectP);
        }
        else if (nb > 0 && fmod(flags, 2.0) > 0.5)
        {
            fogF = rpWindW.x * (1.0 - exp(-min(ageP, 1e4) / max(rpWindW.y, 0.1)));
        }
        else
        {
            fogF = rpWindW.x;
        }
        // condensation is uneven: a slow mottle, a little more toward the frame (cooler glass, less airflow)
        const float mott = 0.6 * rpValueNoise(pc * 2.3 + 17.0) + 0.4 * rpValueNoise(pc * 7.9 + 3.0);
        const float edgeK = 1.0 + 0.3 * smoothstep(0.6, 1.0, max(abs(uv.x), abs(uv.y)));
        fogF = saturate(fogF * rpWindW.w * edgeK * (0.75 + 0.5 * mott));
        // the trails running drops leave are clear of it: the drop took the mist along
        fogF *= 1.0 - 0.8 * saturate(trail * 1.5);
    }
    if (fogF * glass > 0.002)
    {
        // the blurred view: the Kawase chain when it ran this frame (divided by its cabin weight), else a small local blur
        float3 blurC = rpWindBlur(p, 6);
        if (rpWindW.z > 0.5)
        {
            const float2 vpB = (float2(p) + 0.5 - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
            float4 bt = fogBlurTex.SampleLevel(fogBlur_sampler_, viewportCoordToRenderTarget(vpB, rtParams2), 0);
            bt = rpWaveRaw(bt, abs(fogBlurTex.Load(int3(0, 0, 0)).r - 0.5) > 0.1);
            if (bt.a > 0.02 && !rpBad3(bt.rgb))
            {
                blurC = max(bt.rgb / bt.a, 0.0);
            }
        }
        // soft focus: even a light mist takes the edges and the contrast, a heavy one leaves only shapes and halos
        float3 fogged = lerp(col, blurC, smoothstep(0.0, 0.6, fogF));
        // the veil: light the mist scatters toward the eye. The mist is lit from outside (the sky over the glass); from
        // the seat mostly the view's own light comes through it, from outside the window turns milky (the dark cabin
        // behind it no longer shows)
        const float3 amb = rpSkyColor(rpWindB.xyz) * 0.318;
        const float3 veilC = lerp(rpLuma(blurC).xxx, amb, outside ? 0.55 : 0.2) * 1.03;
        fogged = lerp(fogged, veilC, (outside ? 0.5 : 0.3) * fogF * fogF);
        col = lerp(col, fogged, glass);
    }

    // Thin water haze that builds up between wipes (slightly softens what is seen through the glass).
    float haze = saturate(rpRainSince(ageP, tc, sweepT) / 18.0) * 0.10 * saturate(rpWindF.z) * glass;
    // Smear right behind the blade: a water film that drains within a fraction of a second.
    float smearT = 0.12 + 0.45 * saturate(rpWindF.x);
    float ruP = saturate(length(pc - pivP) / rOutP);
    float trailG = wiperTexTex.SampleLevel(wiperTex_sampler_, float2(ruP, saturate(ageP / smearT)), 0).g;
    float smear = (1.0 - saturate(ageP / smearT)) * (0.35 + 0.65 * trailG) * glass;
    // 1.5 glass water: the film the blades really left (streaky; a hazy smear that clears in about a second) and the
    // water line they pushed to the ends of their sweep (a thin sheet that drains with it: softens the view along it)
    float2 gw = float2(0.0, 0.0);
    if (useState)
    {
        gw = rpGlassWater(pc, aspectP);
        smear = gw.y * glass;
        trail = max(trail, 0.6 * saturate((gw.x - 1.2) * 0.5));
    }
    if (haze + smear > 0.002)
    {
        int br = useState ? clamp(int(3.0 + 9.0 * smear), 3, 10) : clamp(int(2.0 + 6.0 * smear), 2, 8);
        float3 soft = rpWindBlur(p, br);
        // the film scatters the light coming through it: a milky veil over the blur, brighter where the view is bright
        float3 veil = soft * (1.0 + 0.08 * smear) + ((useState ? 0.10 : 0.04) * smear * rpLuma(soft)).xxx;
        col = lerp(col, veil, saturate(haze + smear * (useState ? 0.95 : 0.55)));
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
        float cover = saturate(sh.w * bestA) * glassD;
        if (cover > 0.001)
        {
            // ---- 1.3: the body droplets' optics, 1:1 (rp_droplets.cs.hlsl): refraction, Fresnel, light catch ----------
            // (1.2 drew a fixed white highlight at the upper left of every drop, a milky sky veil over all of it and a
            // wide dark ring, and moved the image behind a drop by 1.6 radii at most: the drops read as bubbles by day and
            // showed nothing at night.)
            // 1.5.2 clearer big drops (the user's request). Gravity flattens a real drop much bigger than ~3 mm: flat on
            // top and curved only around its rim, and a flat top neither bends nor flips the view behind it. So a big
            // round drop keeps its slope only in its rim (the outer 1.1 r0 of it), its middle shows what is behind it
            // (a weak lens), and how far a round drop bends the view stops growing past the size of a 1.1 r0 drop. Up
            // to 1.5.1 both grew with the drop: big drops showed a far-off patch of sky and read as white blobs.
            // (Running teardrops and the slim line drops keep their shape and lens.)
            const bool roundT = (bestTile < 7.5) || (bestTile > 11.5 && bestTile < 14.5);
            float flatK = 1.0;
            if (roundT)
            {
                const float rimW = saturate(1.1 * r0 / max(bestR, 1e-6));
                const float nmag = length(sh.xy);
                const float nNew = 0.12 * nmag + 0.88 * saturate((nmag - (1.0 - rimW)) / max(rimW, 0.05));
                flatK = (rimW < 0.999) ? saturate(nNew / max(nmag, 1e-4)) : 1.0;
                sh.xy *= flatK;
            }
            float2 nt = sh.xy * float2(1.0, 1.0 / bestStretch);
            float2 nn = nt.x * bestAx + nt.y * bestAy;                    // slope in glass axes (right, up)
            float nz = sqrt(saturate(1.0 - dot(nn, nn)));
            float3 tang = rpWindC.xyz * nn.x + rpWindD.xyz * nn.y;
            float3 nd = normalize(rpWindB.xyz * max(nz, 0.05) + tang);    // drop surface normal, out of the car
            float thick = saturate(sh.z);
            const float3 V = -rd;                                          // toward the eye
            const float3 dxr = INx.wsEyeRay - ray0;
            const float3 dyr = INy.wsEyeRay - ray0;
            float3 prk = float3(0.0, 0.0, 0.0);
            float3 pra = float3(0.0, 0.0, 0.0);
            float3 prb = float3(0.0, 0.0, 0.0);
            rpMakeProj(ray0, dxr, dyr, prk, pra, prb);

            // Refraction: a drop is a strong little lens. What it shows comes from several drop radii away and upside
            // down, most of all toward its rim: the slope x the drop's size projected to the screen (from the seat and
            // from outside alike), read bilinear with a little dispersion.
            float3 offW = Pw - ro;
            float2 o0 = float2(0.0, 0.0);
            float2 o1 = float2(0.0, 0.0);
            bool okA = rpProjectFast(prk, pra, prb, offW, o0);
            float lensR = ((bestTile > 15.5) ? bestR * (0.18 / 0.56) : bestR) * bestLensK;
            float lensScale = (roundT ? min(lensR, 1.1 * r0) : lensR) * halfH;                     // metres, as the body
            bool okB = rpProjectFast(prk, pra, prb, offW + tang * lensScale, o1);
            float lensK = rpWindF.w * (2.0 + 2.6 * thick);
            float2 rOff = (okA && okB) ? -(o1 - o0) * lensK : float2(0.0, 0.0);
            float rMax = 96.0 * max(dispatchRect.w / 1080.0, 0.5);
            rOff = clamp(rOff, float2(-rMax, -rMax), float2(rMax, rMax));
            uint tw, th;
            colorTexTex.GetDimensions(tw, th);
            float2 invSize = 1.0 / float2(max(tw, 1u), max(th, 1u));
            float2 pp = float2(p);
            float3 refr = float3(0.0, 0.0, 0.0);
            refr.r = rpWindTap(pp + rOff * 1.05, invSize).r;
            refr.g = rpWindTap(pp + rOff, invSize).g;
            refr.b = rpWindTap(pp + rOff * 0.95, invSize).b;

            float skyConf = 0.0;
            float3 keyDir = float3(0.0, 0.0, 1.0);
            float3 keyCol = float3(0.0, 0.0, 0.0);
            float3 skyFill = rpWindVisibleSky(p, ray0, dxr, dyr, skyConf, keyDir, keyCol);
            float3 dOut = float3(0.0, 0.0, 0.0);                          // seat view: the ray leaving the drop
            float fresPhys = 0.0;
            float3 env = float3(0.0, 0.0, 0.0);
            if (outside)
            {
                // the drop's curved surface faces the camera: Fresnel of water, mirroring the world (as on the paint)
                fresPhys = rpFresnel(0.02, saturate(dot(nd, V)));
                env = rpWindEnvRefl(reflect(rd, nd), p, prk, pra, prb, skyFill, skyConf);
            }
            else
            {
                // From the seat the drop is seen from inside the water: its curved surface mirrors the dim cabin (total
                // internal reflection toward the rim), and the ray that leaves it bends toward the drop's axis.
                float3 rdw = refract(rd, -rpWindB.xyz, 0.7519);
                float cosW = dot(rdw, nd);
                fresPhys = (cosW > 0.0) ? rpFresnelWaterIn(cosW) : 0.0;
                dOut = refract(rdw, -nd, 1.33);
                env = min(col, rpSkyColor(-rpWindB.xyz) * 0.318) * 0.35;
                // That ray leaves the car through the glass: where the shifted pixel shows the cabin itself (roof liner,
                // pillar, dashboard: nearer than the glass) or lies off screen, the drop shows the sky / the ground along
                // that direction instead.
                float2 qs = pp + rOff;
                float3 rayS = ray0 + dxr * rOff.x + dyr * rOff.y;
                // how far (px) beyond the frame's edge: blended in over 12 px, so a drop does not pop at the edge
                float2 outLo = dispatchRect.xy - qs;
                float2 outHi = qs - (dispatchRect.xy + dispatchRect.zw - 1.0);
                float wOff = saturate(max(max(outLo.x, outLo.y), max(outHi.x, outHi.y)) / 12.0);
                bool offScr = wOff >= 1.0;
                bool cabin = false;
                float ndcS = rpWindDepthAt(int2(round(qs)));
                if (!offScr && !rpIsSkyDepth(ndcS))
                {
                    float linS = abs(ndcToRealDepth(ndcS, projParams)) / max(abs(projParams.y), 1e-6);
                    cabin = length(rpReconstruct(rayS, camFwd, linS, rpMode.y, rpMode.z)) < t + 0.18;
                }
                float wFb = cabin ? 1.0 : wOff;
                if (wFb > 0.0)
                {
                    float3 dirS = normalize(rayS);
                    refr = lerp(refr, lerp(rpSkyColor(dirS) * 0.318, skyFill, skyConf * saturate(dirS.z * 4.0)), wFb);
                }
            }

            // Light catch (rpWindU.x, as the beads' 'Light catch'): the rim mirrors more where what it mirrors is much
            // brighter than what is seen through the glass around the drop (the sky over the dark cabin from outside),
            // colour-neutral; elsewhere the drop keeps the plain 'Fresnel' and stays clear water.
            const float fresBaseK = max(rpWindF.y, 0.0);
            const float catchK = max(rpWindU.x, 0.0);
            float lumEnv = max(env.r, max(env.g, env.b));
            // (the cabin behind the glass is always dark: a floor under it, and the rim never mirrors more than water)
            float lumBack = max(max(col.r, max(col.g, col.b)), 0.05);
            float gateL = smoothstep(4.0, 8.0, lumEnv / lumBack) * saturate(catchK * 4.0);
            float fresTopK = max(outside ? catchK : min(catchK, 1.0), fresBaseK);
            float fresB = saturate(fresPhys * fresBaseK);
            float fres = saturate(fresPhys * lerp(fresBaseK, fresTopK, gateL));
            float3 envNeutral = lerp(rpLuma(env).xxx, env, 0.25);
            float3 envMix = (env * fresB + envNeutral * max(fres - fresB, 0.0)) / max(fres, 1e-5);

            float darkRim = 1.0 - smoothstep(0.0, 0.25, thick);           // the thin dark edge that outlines a real drop
            // caustic: light from the sky focuses on the down-slope side of the drop
            float2 up2 = float2(rpWindC.z, rpWindD.z);
            float2 upT = float2(dot(up2, bestAx), dot(up2, bestAy));
            float caustic = pow(saturate(-dot(bestQ, upT / max(length(upT), 1e-3))), 2.0) * saturate(thick * 1.5) * 0.40;
            caustic *= flatK;                                              // 1.5.2: a flat middle focuses no light
            // glint: the brightest visible sky (sun side), mirrored from outside, seen through the drop from the seat
            float glint = 0.0;
            float soft = 0.0;
            if (outside)
            {
                float3 Hk = normalize(keyDir + V);
                glint = pow(saturate(dot(nd, Hk)), 420.0) * skyConf;
                soft = pow(saturate(dot(nd, Hk)), 40.0) * skyConf * saturate(thick * 2.0);
            }
            else
            {
                float cK = saturate(dot(dOut, keyDir));
                glint = pow(cK, 900.0) * skyConf;
                soft = pow(cK, 60.0) * skyConf * saturate(thick * 2.0) * 0.5;
            }

            glint *= flatK;                                                // 1.5.2: the flat middle shows the sun as
            soft *= flatK;                                                 // the glass does, without a second glint
            float3 dcol = refr * float3(0.97, 0.985, 0.99);
            dcol *= 1.0 - (0.35 + 0.12 * saturate(catchK)) * darkRim;
            dcol += refr * caustic;
            dcol = dcol * (1.0 - fres) + envMix * fres;
            dcol += keyCol * (glint * 5.0 + soft * 0.35);

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
    if (rpMode.x > 22.5 && rpMode.x < 23.5)
    {
        // Debug 23 (1.5 glass water): blue = water on the glass (dark = dry / just wiped), white = the lines the blades
        // pushed together, yellow = the film behind them, green = the body strip beside the glass; red = no glass water;
        // 1.5.1 magenta = the drops of those lines (staying and running off)
        float B = max(rpLuma(src.rgb), 0.05) * 2.0 * rpMode.w;
        float2 g23 = useState ? rpGlassWater(pc, aspectP) : float2(0.0, 0.0);
        col = float3(0.06, 0.06, 0.06) * B;
        col = lerp(col, float3(0.15, 0.45, 1.0) * B, saturate(g23.x) * max(aperture, 0.25));
        col = lerp(col, float3(1.0, 1.0, 1.0) * B, saturate((g23.x - 1.2) * 1.5));
        col = lerp(col, float3(1.0, 0.85, 0.1) * B, saturate(g23.y * 1.5));
        col = lerp(col, float3(0.1, 1.0, 0.3) * B, 0.35 * onBody);
        col = lerp(col, float3(1.0, 0.2, 0.9) * B, saturate(lineA * 1.5));
        if (!useState)
        {
            col = lerp(col, float3(1.0, 0.1, 0.1) * B, 0.5 * aperture);
        }
    }
    if (rpMode.x > 23.5 && rpMode.x < 24.5)
    {
        // Debug 24 (1.6 glass fog): orange = mist on the glass (brighter = thicker), dark = clear; a cyan tint = the
        // Kawase blur did not run this frame (the small local blur stands in)
        float B = max(rpLuma(src.rgb), 0.05) * 2.0 * rpMode.w;
        float3 c24 = lerp(float3(0.06, 0.06, 0.06) * B, float3(1.0, 0.55, 0.1) * B, saturate(fogF));
        if (rpWindW.z < 0.5)
        {
            c24 = lerp(c24, float3(0.1, 0.8, 1.0) * B, 0.25);
        }
        col = lerp(src.rgb, c24, glass);
    }

    pfxOut[storePos] = float4(rpSafe(col, src.rgb), src.a);
}
