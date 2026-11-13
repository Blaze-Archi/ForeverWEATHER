#define PFX_COMPUTE 1

#include "rp_droplets.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// Vehicle body droplets, v0.7.
//
// Populations on the painted / glass shell of every tracked vehicle:
//   BEADS    rain hits that stick. Size-dependent adhesion (big beads leave first when the force grows), a wide size
//            spread including merged flat drops; static apart from a slight creep toward the force.
//   STREAMS  two layers of running drops on grids that TRANSLATE along the body: backward with the airflow over the
//            hood, roof, glass and doors, and down the doors and the rear with gravity. The offsets are integrated in
//            Lua per vehicle (rpVehH.y / .w, metres), so the travel is unbounded (no cut-off at a certain speed) and a
//            change of speed changes how fast the drops move, never where they are. Every drop fades in and out on
//            its own clock, the layers move at different speeds and drops wobble sideways: no rigid moving mask.
//   MIST     tiny static beads on upward surfaces, blown off as the airflow rises.
// Not drawn: the car the camera sits in (cockpit / interior views), and the cabin seen through the glass: up-facing
// surfaces below the car's roof line (headrests, dashboard, parcel shelf, boot floor) and anything that is not an outer
// panel (1.0). Vehicle boxes arrive already moved to where the car is drawn (1.0, see rainPuddles.lua readBox).
// Shapes come from the droplet atlas (normal + thickness + coverage); if it is not loaded, analytic domes are used.

static const float RP_TILE_IN = 112.0 / 128.0;   // usable part of a 128 px atlas tile (8 px padding each side)

float3 rpDropLoad(int2 q)
{
    return colorTex.Load(int3(rpClampPix(q), 0)).rgb;
}

// Tile 15 of the atlas is a flat calibration colour. Anything else (missing texture, sRGB decode) => analytic shapes.
bool rpAtlasValid()
{
    float4 m = dropTexTex.SampleLevel(dropTex_sampler_, float2(0.875, 0.875), 0.0);
    float4 d = abs(m - float4(0.251, 0.749, 0.502, 1.0));
    return max(max(d.x, d.y), max(d.z, d.w)) < 0.06;
}

// Droplet shape at local coordinate q (tile space, |q| <= 1). Returns normal xy (droplet frame), thickness, coverage.
float4 rpDropShape(float2 q, float tile, float lod, bool atlas)
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
        s = float4(q * 0.9, sqrt(saturate(1.0 - rr)), saturate((1.0 - sqrt(rr)) * 12.0));
    }
    return s * inside;
}

// Sky visible along the top of the screen (8 probes, same addresses for every pixel): average colour for reflections
// that leave the screen, plus the brightest direction (sun side) and its colour for the glints on the drops.
float3 rpVisibleSky(int2 p, float3 ray0, float3 dxr, float3 dyr, out float conf, out float3 keyDir, out float3 keyCol)
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
        if (rpDepthLoad(q) >= 0.99999)
        {
            float3 c = rpDropLoad(q);
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

// Reflection along R read from the colour buffer (far-field approximation, as the puddle sky lookup): exact for sky
// and distant lights (street lamps at night), plausible for the tiny, strongly curved mirrors a droplet forms.
// Off screen: the visible sky when there is some, else the ambient as radiance (irradiance / pi).
float3 rpEnvRefl(float3 R, int2 p, float3 prk, float3 pra, float3 prb, float3 skyFill, float skyConf)
{
    float3 sky = lerp(rpSkyColor(R) * 0.318, skyFill, skyConf);
    float3 res = sky;
    float2 off = float2(0.0, 0.0);
    if (rpProjectFast(prk, pra, prb, R, off))
    {
        int2 q = int2(round(float2(p) + off));
        float2 rel = (float2(q) - dispatchRect.xy) / max(dispatchRect.zw, float2(1.0, 1.0));
        float conf = smoothstep(0.0, 0.08, rel.x) * (1.0 - smoothstep(0.92, 1.0, rel.x))
                   * smoothstep(0.0, 0.08, rel.y) * (1.0 - smoothstep(0.92, 1.0, rel.y));
        if (conf > 0.001)
        {
            float3 c = rpDropLoad(q) * 0.5
                     + (rpDropLoad(q + int2(2, 0)) + rpDropLoad(q - int2(2, 0))
                      + rpDropLoad(q + int2(0, 2)) + rpDropLoad(q - int2(0, 2))) * 0.125;
            res = lerp(sky, c, conf * 0.85);
        }
    }
    return res;
}

// Adhesion threshold (m/s^2) of a droplet: small beads cling, big ones slide. Glass is a little slipperier.
float rpAdhesion(float rawRad, float baseRadius, float glass)
{
    return 5.0 * pow(baseRadius / max(rawRad, 1e-5), 1.2) * lerp(1.0, 0.75, glass);
}

// 1.0 roof line: 16 heights in 4 float4 (slice i of the car's length).
float rpProfileGet(float4 a, float4 b, float4 c, float4 d, int i)
{
    float4 q = (i < 4) ? a : ((i < 8) ? b : ((i < 12) ? c : d));
    int k = i & 3;
    return (k == 0) ? q.x : ((k == 1) ? q.y : ((k == 2) ? q.z : q.w));
}

// Height of the roof line at u along the box length (0 = one end, 1 = the other), linear between slice centres.
float rpProfileAt(float4 a, float4 b, float4 c, float4 d, float u)
{
    float s = clamp(u * 16.0 - 0.5, 0.0, 15.0);
    int i0 = int(floor(s));
    int i1 = min(i0 + 1, 15);
    return lerp(rpProfileGet(a, b, c, d, i0), rpProfileGet(a, b, c, d, i1), s - float(i0));
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

    if (rpDropB.w < 0.001 || rpDropA.x < 0.001)
    {
        pfxOut[storePos] = src;
        return;
    }

    PFXVertToPix IN = processPostFxCompute(dispatchThreadID);
    PFXVertToPix INx = processPostFxCompute(dispatchThreadID + uint3(1, 0, 0));
    PFXVertToPix INy = processPostFxCompute(dispatchThreadID + uint3(0, 1, 0));

    const float4 packedPrepass = prepassTexTex.SampleLevel(prepassTex_sampler_, IN.uv0, 0);
    const float4 gb = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv0,
        projParams
    );

    const float3 ray0 = IN.wsEyeRay;
    const float3 dxr = INx.wsEyeRay - ray0;
    const float3 dyr = INy.wsEyeRay - ray0;
    float3 camFwd = normalize(cross(dxr, dyr));
    camFwd = (dot(camFwd, ray0) < 0.0) ? -camFwd : camFwd;

    const float3 N = gb.xyz / max(length(gb.xyz), 1e-4);
    const float3 off = rpReconstruct(ray0, camFwd, gb.w, rpMode.y, rpMode.z);
    const float dist = length(off);
    const float3 P = rpCam.xyz + off;
    float3 col = src.rgb;

    if (dist > rpDropB.z || dist < 0.05)
    {
        pfxOut[storePos] = src;
        return;
    }

    float4 vA[6] = { rpVehA0, rpVehA1, rpVehA2, rpVehA3, rpVehA4, rpVehA5 };
    float4 vB[6] = { rpVehB0, rpVehB1, rpVehB2, rpVehB3, rpVehB4, rpVehB5 };
    float4 vC[6] = { rpVehC0, rpVehC1, rpVehC2, rpVehC3, rpVehC4, rpVehC5 };
    float4 vD[6] = { rpVehD0, rpVehD1, rpVehD2, rpVehD3, rpVehD4, rpVehD5 };
    float4 vE[6] = { rpVehE0, rpVehE1, rpVehE2, rpVehE3, rpVehE4, rpVehE5 };
    float4 vF[6] = { rpVehF0, rpVehF1, rpVehF2, rpVehF3, rpVehF4, rpVehF5 };
    float4 vG[6] = { rpVehG0, rpVehG1, rpVehG2, rpVehG3, rpVehG4, rpVehG5 };
    float4 vH[6] = { rpVehH0, rpVehH1, rpVehH2, rpVehH3, rpVehH4, rpVehH5 };
    float4 vPA[6] = { rpVehPA0, rpVehPA1, rpVehPA2, rpVehPA3, rpVehPA4, rpVehPA5 };
    float4 vPB[6] = { rpVehPB0, rpVehPB1, rpVehPB2, rpVehPB3, rpVehPB4, rpVehPB5 };
    float4 vPC[6] = { rpVehPC0, rpVehPC1, rpVehPC2, rpVehPC3, rpVehPC4, rpVehPC5 };
    float4 vPD[6] = { rpVehPD0, rpVehPD1, rpVehPD2, rpVehPD3, rpVehPD4, rpVehPD5 };
    float4 prA = float4(-100.0, -100.0, -100.0, -100.0);
    float4 prB = prA;
    float4 prC = prA;
    float4 prD = prA;

    // ---- find the vehicle shell this pixel belongs to ------------------------------------
    bool found = false;
    float3 lp = float3(0.0, 0.0, 0.0);
    float3 ax0 = float3(1.0, 0.0, 0.0);
    float3 ax1 = float3(0.0, 1.0, 0.0);
    float3 ax2 = float3(0.0, 0.0, 1.0);
    float3 halfExt = float3(1.0, 1.0, 1.0);
    float innerD = 0.0;
    float seed = 0.0;
    float wake = 0.0;
    float flowClk = 0.0;
    float sAir = 0.0;
    float sGrav = 0.0;
    float camInside = 0.0;
    float wetV = 1.0;
    float3 wind = float3(0.0, 0.0, 0.0);
    float3 accel = float3(0.0, 0.0, 0.0);
    float3 vehicleVel = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 6; i++)
    {
        if (!found)
        {
            float3 lpi = float3(0.0, 0.0, 0.0);
            float inner = rpBoxInner(P, vA[i], vB[i], vC[i], vD[i], lpi);
            float lowZ = vA[i].z - (abs(vB[i].z) * vA[i].w + abs(vC[i].z) * vB[i].w + abs(vD[i].z) * vC[i].w);
            float outward = dot(N, P - vA[i].xyz);
            if (inner > -0.14 && inner < rpDropB.x && (P.z - max(vG[i].w, lowZ)) > 0.20 && packedPrepass.z < 0.65 && outward > 0.0)
            {
                found = true;
                lp = lpi;
                ax0 = vB[i].xyz;
                ax1 = vC[i].xyz;
                ax2 = vD[i].xyz;
                halfExt = float3(vA[i].w, vB[i].w, vC[i].w);
                innerD = inner;
                seed = vD[i].w;
                vehicleVel = vE[i].xyz;
                wetV = saturate(vE[i].w);                     // 1.0: how wet the body still is (tunnels, Lua)
                wind = vF[i].xyz;
                wake = vF[i].w;
                accel = vG[i].xyz;
                flowClk = vH[i].x;
                sAir = vH[i].y;
                camInside = vH[i].z;
                sGrav = vH[i].w;
                prA = vPA[i];
                prB = vPB[i];
                prC = vPC[i];
                prD = vPD[i];
            }
        }
    }

    // The car the camera sits in has no body droplets: from inside you would only see its interior through the glass.
    if (!found || camInside > 0.5)
    {
        pfxOut[storePos] = src;
        return;
    }

    // Interior rejection (1.0). Car glass is drawn after the G-buffer, so through a window this pass sees the cabin,
    // never the glass: before 1.0 headrests, dashboards and parcel shelves seen through the windows got droplets.
    //  * up-facing surfaces get beads only where nothing of the car is above them: the roof line from Lua (highest
    //    node per slice of the car's length) - roof, hood, boot lid, bed rails, an open convertible's headrests;
    //  * everything else must be an outer panel: near the box face it looks out of (doors, fenders, bumpers, tailgate).
    // Without a roof line (first frame of a new car) the old cabin-band rule is used.
    {
        bool upF = dot(N, ax2) > 0.55;
        float3 dFace = halfExt - abs(lp);
        float3 outN = ax2 * ((lp.z >= 0.0) ? 1.0 : -1.0);
        bool topNearest = true;
        if (dFace.x <= dFace.y && dFace.x <= dFace.z)
        {
            outN = ax0 * ((lp.x >= 0.0) ? 1.0 : -1.0);
            topNearest = false;
        }
        else if (dFace.y <= dFace.z)
        {
            outN = ax1 * ((lp.y >= 0.0) ? 1.0 : -1.0);
            topNearest = false;
        }
        bool panel = (innerD < 0.22) && (dot(N, outN) > 0.25 || innerD < 0.06);
        bool keep = false;
        if (prA.x > -50.0)
        {
            float zTop = rpProfileAt(prA, prB, prC, prD, lp.y / max(halfExt.y, 0.1) * 0.5 + 0.5);
            bool atRoofLine = lp.z > zTop - 0.14;
            // up-facing: only on the roof line; near the top face (rounded roof edges, headrest tops): only on the roof
            // line too; near a side / front / back face: an outer panel (doors, fenders, bumpers, tailgate)
            keep = (upF || topNearest) ? (atRoofLine && (upF || panel)) : panel;
        }
        else
        {
            float lenFrac = (halfExt.y >= halfExt.x) ? abs(lp.y) / max(halfExt.y, 0.1) : abs(lp.x) / max(halfExt.x, 0.1);
            keep = panel || (upF && lenFrac > 0.45);
        }
        if (!keep)
        {
            pfxOut[storePos] = src;
            return;
        }
    }

    if (rpMode.x > 4.5 && rpMode.x < 5.5)
    {
        // Debug 5: surfaces that can get droplets. Green = classified with the car's roof line (1.0), yellow = the
        // fallback rule (roof line not known yet).
        float L = max(dot(max(col, 0.0), float3(0.3333, 0.3333, 0.3333)), 0.05) * 2.0 * rpMode.w;
        float3 tint = (prA.x > -50.0) ? float3(0.0, 1.0, 0.2) : float3(1.0, 0.85, 0.0);
        float canWet = smoothstep(-0.45, -0.10, N.z);           // undersides never get beads (see 'underside')
        pfxOut[storePos] = float4(lerp(col, tint * L, 0.6 * canWet), src.a);
        return;
    }

    // ---- triplanar coordinates in the vehicle frame --------------------------------------
    float3 ln = float3(dot(N, ax0), dot(N, ax1), dot(N, ax2));
    float3 an = abs(ln);
    int axis = (an.x > an.y && an.x > an.z) ? 0 : ((an.y > an.z) ? 1 : 2);
    float2 pc = float2(0.0, 0.0);
    float3 Uw = float3(1.0, 0.0, 0.0);
    float3 Vw = float3(0.0, 1.0, 0.0);
    float signN = 1.0;
    if (axis == 0)      { pc = lp.yz; Uw = ax1; Vw = ax2; signN = ln.x; }   // sides:      x = backward, y = up
    else if (axis == 1) { pc = lp.xz; Uw = ax0; Vw = ax2; signN = ln.y; }   // front/back: y = up
    else                { pc = lp.xy; Uw = ax0; Vw = ax1; signN = ln.z; }   // top:        y = backward

    const int seedKey = axis * 2 + ((signN > 0.0) ? 1 : 0) + int(seed * 1000.0) * 7;

    const float rain = saturate(rpDropB.w);
    const float mpp = length(dxr) * dist / max(length(ray0), 1e-5);
    const float roughness = max(packedPrepass.z, 0.02);
    const float smoothGlass = 1.0 - smoothstep(0.12, 0.42, roughness);
    const float3 V = normalize(rpCam.xyz - P);
    const float distFade = 1.0 - smoothstep(rpDropB.z * 0.75, rpDropB.z, dist);
    const float underside = smoothstep(-0.45, -0.10, N.z);    // water drips off undersides: no beads there
    const float topK = smoothstep(0.35, 0.85, N.z);           // hood, roof, boot lid
    const bool atlasOK = rpAtlasValid();

    float3 prk = float3(0.0, 0.0, 0.0);
    float3 pra = float3(0.0, 0.0, 0.0);
    float3 prb = float3(0.0, 0.0, 0.0);
    rpMakeProj(ray0, dxr, dyr, prk, pra, prb);
    float skyConf = 0.0;
    float3 keyDir = float3(0.0, 0.0, 1.0);
    float3 keyCol = float3(0.0, 0.0, 0.0);
    float3 skyFill = rpVisibleSky(p, ray0, dxr, dyr, skyConf, keyDir, keyCol);

    // ---- tangential force on the surface (m/s^2) ------------------------------------------------------------------
    // gravity + quadratic airflow drag (stronger on surfaces facing the relative wind) + inertia of the car's
    // acceleration. The engine's real slipstream is physics-side (core_interAero); this is the visual estimate.
    float3 air = (wind - vehicleVel) * (1.0 - wake * 0.65);
    float airSpd = length(air);
    float facing = saturate(-dot(N, air) / max(airSpd, 1e-3));
    float3 Fw = float3(0.0, 0.0, -9.81) * rpDropC.x
              + air * (airSpd * 0.018 * rpDropC.y * (0.35 + 0.65 * facing))
              - accel * rpDropC.w;
    float3 Ft = Fw - N * dot(Fw, N);
    float2 F2 = float2(dot(Ft, Uw), dot(Ft, Vw));
    float Fmag = length(F2);
    float2 fdir = (Fmag > 1e-4) ? F2 / Fmag : float2(0.0, -1.0);

    // ---- stream motion of this face (pc units = metres), same rates Lua integrates into sAir / sGrav ---------------
    float vAir = max(dot(air, ax1) - 7.0, 0.0) * 0.05 * rpDropC.y;    // backward along the body above ~25 km/h
    float vGrav = 0.03 * rpDropC.x;                                    // slow run-off down vertical panels
    float2 offs = (axis == 0) ? float2(sAir, -sGrav) : ((axis == 1) ? float2(0.0, -sGrav) : float2(0.0, sAir));
    float2 vel2 = (axis == 0) ? float2(vAir, -vGrav) : ((axis == 1) ? float2(0.0, -vGrav) : float2(0.0, vAir));
    float vmag = length(vel2);
    float2 mdir = (vmag > 1e-4) ? vel2 / vmag : float2(0.0, -1.0);
    float2 mside = float2(-mdir.y, mdir.x);

    // ---- distribution -----------------------------------------------------------------------------------------
    float nB = rpSampleField(maskTexB, pc * 1.05 + float2(seed * 3.7, seed * 1.3 + float(axis) * 0.31), mpp);
    float nA = rpSampleField(maskTexA, pc * 0.37 + float2(seed * 1.9, float(axis) * 0.53), mpp * 0.37);
    float cluster = lerp(0.18, 1.85, nB) * lerp(0.65, 1.30, nA);
    float density = saturate(rpDropA.x * (0.35 + 0.65 * rain) * cluster * lerp(0.55, 1.0, topK)
                             * lerp(1.0, 1.25, smoothGlass) * (1.0 - wake * 0.35)) * underside * wetV;

    const float baseRadius = max(rpDropA.y * lerp(0.85, 1.25, smoothGlass), 0.0008);   // 1.0: scaled by 'Rain droplet size'

    // winner (one droplet is shaded per pixel)
    float  bestScore = 0.0;
    float2 bestQ = float2(0.0, 0.0);
    float2 bestAx = float2(1.0, 0.0);
    float2 bestAy = float2(0.0, 1.0);
    float  bestScale = baseRadius;
    float  bestA = 0.0;
    float  bestTile = 0.0;
    float  bestStretch = 1.0;
    float  nearRing = 0.0;     // contact shadow just outside a bead
    float  trail = 0.0;        // wet trail behind running drops

    // ---- layer 1: beads (3x3 cells) ----------------------------------------------------------------------------------
    const float cs = baseRadius * 4.6;
    int2 cell0 = int2(floor(pc / cs));
    [unroll]
    for (int j = -1; j <= 1; j++)
    {
        [unroll]
        for (int k = -1; k <= 1; k++)
        {
            int2 c = cell0 + int2(k, j);
            uint hs = rpHash3(int3(c.x, c.y, seedKey));
            float life = lerp(7.0, 20.0, rpRand(hs));
            float tt = flowClk / life + rpRand(rpPcg(hs ^ 0xB5297A4Du));
            float cyc = floor(tt);
            float ph = tt - cyc;
            uint hc = rpPcg(hs + uint(cyc) * 0x9E3779B1u);
            float r1 = rpRand(hc);
            float r2 = rpRand(rpPcg(hc ^ 0x1B873593u));
            float r3 = rpRand(rpPcg(hc ^ 0xE6546B64u));
            float r4 = rpRand(rpPcg(hc ^ 0x85EBCA6Bu));
            float r5 = rpRand(rpPcg(hc ^ 0x27D4EB2Fu));

            // wide size spread: many small beads, a few big merged drops
            float rawRad = baseRadius * (0.35 + 1.6 * pow(r3, 2.5));
            float adh = rpAdhesion(rawRad, baseRadius, smoothGlass);
            float mob = saturate((Fmag - adh) / (adh * 1.5));
            float presence = saturate((density * (1.0 - 0.9 * mob) - r1) / 0.06);
            float grow = smoothstep(0.0, 0.06, ph) * (1.0 - smoothstep(0.80, 1.0, ph));
            float rad = rawRad * lerp(0.6, 1.0, smoothstep(0.0, 0.35, ph)) * lerp(1.0, 0.75, smoothstep(0.7, 1.0, ph));
            float radV = max(rad, 1.35 * mpp);
            float strength = saturate(rad / max(radV, 1e-5));
            float a = presence * grow * strength;

            float2 center = (float2(c) + 0.18 + 0.64 * float2(r2, r4)) * cs;
            center += fdir * (rawRad * 0.35 * saturate(Fmag / adh) * smoothstep(0.2, 1.0, ph));   // creep while pinned

            float ang = r5 * 6.2831853;
            float2 ax = float2(cos(ang), sin(ang));
            float2 ay = float2(-ax.y, ax.x);
            float2 d = (pc - center) / radV;
            float2 q = float2(dot(d, ax), dot(d, ay));
            // 1.0 every bead its own outline: stretched and lumpy (merged flat drops a little less)
            q = rpDropWarp(q, rpRand4(rpPcg(hc ^ 0x165667B1u)), (r3 > 0.78) ? 0.6 : 1.0);
            float rr = dot(q, q);
            if (a > 0.001)
            {
                nearRing = max(nearRing, a * (1.0 - smoothstep(1.0, 1.35, sqrt(rr))) * step(1.0, rr));
                float score = (1.0 - rr) * a;
                if (rr < 1.0 && score > bestScore)
                {
                    bestScore = score;
                    bestQ = q;
                    bestAx = ax;
                    bestAy = ay;
                    bestScale = radV;
                    bestA = a;
                    bestStretch = 1.0;
                    // big drops (and much of the glass) are flat merged shapes, the rest round beads
                    bestTile = ((r3 > 0.78) || (smoothGlass > 0.5 && r2 < 0.45)) ? (12.0 + floor(r4 * 2.999)) : floor(frac(r5 * 13.7) * 7.999);
                }
            }
        }
    }

    // ---- layers 2 + 3: streams (translated grids, unbounded travel) ----------------------------------------------
    const float runAmt = saturate(rpDropD.x);
    if (runAmt > 0.001)
    {
        [unroll]
        for (int layerS = 0; layerS < 2; layerS++)
        {
            float kS = (layerS == 0) ? 1.0 : 0.62;                  // the second layer runs slower
            float rS = baseRadius * ((layerS == 0) ? 1.0 : 0.72);
            float csS = rS * 6.0;
            float2 shift = offs * kS;                               // how far this layer has travelled (m)
            // 1.0: the streak length approaches its limit smoothly (it used to stop growing abruptly at one speed)
            float stretchMax = (layerS == 0) ? 4.0 : 2.5;
            float stretchS = 1.0 + stretchMax * (1.0 - exp(-vmag * kS * 3.0 / stretchMax));
            // 1.0: search every cell whose drop can reach this pixel - head, teardrop tail and wet trail. The old fixed
            // 4x4 / 3x3 window was smaller than a stretched drop, so fast streaks were cut off at a certain speed.
            float radMax = max(rS * 1.6, 1.35 * mpp);
            float tailLen = max(2.46 * radMax * stretchS, rS * 1.6 * (2.0 + 4.0 * (stretchS - 1.0)));
            float headLen = 1.11 * radMax * stretchS;
            float2 gS = (pc - shift) / csS;
            float2 eA = mdir * (-headLen);
            float2 eB = mdir * tailLen;
            float2 ext = abs(mside) * (radMax * 1.3);
            int2 cLo = int2(floor(gS + (min(eA, eB) - ext) / csS - 0.85));
            int2 cHi = int2(floor(gS + (max(eA, eB) + ext) / csS - 0.15));
            cHi = min(cHi, cLo + int2(9, 9));                       // bounded cost (10 x 10 cells at most)
            if (rS * 1.6 < 0.2 * mpp)
            {
                cHi = cLo - int2(1, 1);                             // far away the drops are sub-pixel: skip the layer
            }
            [loop]
            for (int cyS = cLo.y; cyS <= cHi.y; cyS++)
            {
                [loop]
                for (int cxS = cLo.x; cxS <= cHi.x; cxS++)
                {
                    {
                        int2 c = int2(cxS, cyS);
                        uint hs = rpHash3(int3(c.x, c.y, seedKey + 7919 + layerS * 131));
                        float L = lerp(1.6, 4.0, rpRand(hs));            // flow-clock units per appearance
                        float tt = flowClk / L + rpRand(rpPcg(hs ^ 0xB5297A4Du));
                        float win = floor(tt);
                        float ph = tt - win;
                        uint hc = rpPcg(hs + uint(win) * 0x9E3779B1u);
                        float r1 = rpRand(hc);
                        float r2 = rpRand(rpPcg(hc ^ 0x1B873593u));
                        float r3 = rpRand(rpPcg(hc ^ 0xE6546B64u));
                        float r4 = rpRand(rpPcg(hc ^ 0x85EBCA6Bu));
                        float r5 = rpRand(rpPcg(hc ^ 0x27D4EB2Fu));

                        float rawRad = rS * (0.55 + 1.05 * r3 * r3);
                        float adh = rpAdhesion(rawRad, baseRadius, smoothGlass);
                        float mob = saturate((Fmag - adh) / (adh * 1.5));
                        // more running drops where the force can move them, a few even on calm flat panels
                        float want = density * runAmt * lerp(0.25, 1.0, smoothstep(0.0, 0.4, mob));
                        float presence = saturate((want - r1) / 0.06);
                        float lifeW = smoothstep(0.0, 0.10, ph) * (1.0 - smoothstep(0.80, 1.0, ph));
                        float radV = max(rawRad, 1.35 * mpp);
                        float strength = saturate(rawRad / max(radV, 1e-5));
                        float a = presence * lifeW * strength;
                        if (a > 0.001)
                        {
                            float2 cen = (float2(c) + 0.15 + 0.70 * float2(r2, r4)) * csS + shift;
                            cen += mside * (sin(ph * 7.0 + r5 * 6.2831853) * 0.30 * rawRad);   // wobble across the motion
                            float2 dd = pc - cen;
                            float along = dot(dd, mdir);
                            float across = dot(dd, mside);
                            float stretchD = lerp(1.0, stretchS, smoothstep(0.0, 0.3, mob + 0.2));

                            // wet trail behind the drop
                            float tl = rawRad * (2.0 + 4.0 * (stretchD - 1.0));
                            float tpar = saturate(-along / max(tl, 1e-5));
                            float tw = step(along, 0.0) * step(-along, tl) * (1.0 - smoothstep(0.6, 1.0, abs(across) / (rawRad * 0.45))) * (1.0 - tpar);
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
                                    bestScale = s;
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
                                    bestScale = radV;
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

    // ---- layer 4: mist (single cell, upward surfaces, blown off by the airflow) -------------------------------
    float mist = 0.0;
    float mistRR = 1.0;
    if (topK > 0.01)
    {
        float csM = baseRadius * 1.6;
        int2 mc = int2(floor(pc / csM));
        uint hm = rpHash3(int3(mc.x, mc.y, seedKey + 104729));
        float tt = flowClk / lerp(4.0, 10.0, rpRand(hm)) + rpRand(rpPcg(hm ^ 0xB5297A4Du));
        uint hc = rpPcg(hm + uint(floor(tt)) * 0x9E3779B1u);
        float m1 = rpRand(hc);
        float m2 = rpRand(rpPcg(hc ^ 0x1B873593u));
        float m3 = rpRand(rpPcg(hc ^ 0xE6546B64u));
        float ph = frac(tt);
        float2 mcen = (float2(mc) + 0.3 + 0.4 * float2(m2, m3)) * csM;
        float mr = csM * (0.12 + 0.12 * m3);
        float mrV = max(mr, 1.2 * mpp);
        float2 dq = (pc - mcen) / mrV;
        mistRR = dot(dq, dq);
        float mp = saturate((density * 0.8 * topK * (1.0 - saturate(Fmag / 12.0)) - m1) / 0.08);
        mist = (1.0 - smoothstep(0.6, 1.0, mistRR)) * mp * saturate(mr / mrV)
             * smoothstep(0.0, 0.1, ph) * (1.0 - smoothstep(0.85, 1.0, ph));
    }

    // ---- shading ------------------------------------------------------------------------------------------------
    // Wet paint / glass: slightly darker, plus a thin water-layer reflection on top of the clear coat.
    float3 envN = rpEnvRefl(reflect(-V, N), p, prk, pra, prb, skyFill, skyConf);
    float fresN = rpFresnel(0.04, saturate(dot(N, V)));
    float sheen = saturate(rpDropB.y) * rain;
    col *= 1.0 - 0.10 * sheen;
    col += envN * (fresN * 0.22 * sheen);

    float trailW = saturate(trail * saturate(rpDropD.y)) * distFade;
    col = lerp(col, col * 0.84 + envN * (0.08 + 0.5 * fresN), trailW * 0.65);

    float mistW = mist * distFade;
    col *= 1.0 - 0.18 * mistW * smoothstep(0.3, 1.0, mistRR);
    col += envN * (0.25 * mistW * pow(saturate(1.0 - mistRR), 4.0));

    col *= 1.0 - 0.12 * nearRing * distFade;

    if (bestA > 0.001)
    {
        float lodTex = clamp(log2(max(56.0 * mpp / max(bestScale, 1e-5), 1.0)), 0.0, 3.0);
        float4 sh = rpDropShape(bestQ, bestTile, lodTex, atlasOK);
        float cover = saturate(sh.w * bestA * distFade);
        if (cover > 0.001)
        {
            float2 nt = sh.xy * float2(1.0, 1.0 / bestStretch);
            float2 n2 = nt.x * bestAx + nt.y * bestAy;                 // in surface (pc) coordinates
            float nz = sqrt(saturate(1.0 - dot(nt, nt)));
            float3 tang = Uw * n2.x + Vw * n2.y;
            float3 nd = normalize(N * max(nz, 0.05) + tang);
            float thick = saturate(sh.z);
            float ndv = saturate(dot(nd, V));
            float fres = rpFresnel(0.02, ndv);

            // Refraction: the slope of the drop, projected to the screen, displaces what is seen through it.
            float2 o0 = float2(0.0, 0.0);
            float2 o1 = float2(0.0, 0.0);
            bool okA = rpProjectFast(prk, pra, prb, off, o0);
            bool okB = rpProjectFast(prk, pra, prb, off + tang * bestScale, o1);
            float2 rOff = (okA && okB) ? -(o1 - o0) * rpDropA.z * (0.6 + 0.6 * thick) : float2(0.0, 0.0);
            rOff = clamp(rOff, float2(-64.0, -64.0), float2(64.0, 64.0));
            float3 refr = float3(0.0, 0.0, 0.0);
            refr.r = rpDropLoad(p + int2(round(rOff * 1.06))).r;
            refr.g = rpDropLoad(p + int2(round(rOff))).g;
            refr.b = rpDropLoad(p + int2(round(rOff * 0.92))).b;

            float3 env = rpEnvRefl(reflect(-V, nd), p, prk, pra, prb, skyFill, skyConf);
            float darkRim = 1.0 - smoothstep(0.0, 0.45, thick);       // total internal reflection at the thin edge
            // caustic: light from the sky focuses on the down-slope side of the drop
            float2 up2 = float2(Uw.z, Vw.z);
            float2 upT = float2(dot(up2, bestAx), dot(up2, bestAy));
            float caustic = saturate(-dot(bestQ, upT / max(length(upT), 1e-3))) * saturate(thick * 1.5) * 0.30;
            // glint: the brightest visible sky (sun side) mirrored in the curved surface of the drop
            float3 Hk = normalize(keyDir + V);
            float glint = pow(saturate(dot(nd, Hk)), 180.0) * skyConf;

            float3 dcol = refr * lerp(float3(0.93, 0.95, 0.97), float3(0.86, 0.93, 1.0), smoothGlass * 0.4);
            dcol *= 1.0 - 0.60 * darkRim;
            dcol += refr * caustic;
            dcol += env * ((0.05 + 0.95 * fres) * (0.55 + 0.45 * saturate(rpDropB.y)));
            dcol += keyCol * (glint * 2.5);
            col = lerp(col, dcol, cover);
        }
    }

    // Debug 15: droplet force field. Hue = direction in the surface frame, brightness = force (15 m/s^2 = full).
    if (rpMode.x > 14.5 && rpMode.x < 15.5)
    {
        float L = max(rpLuma(src.rgb), 0.05) * 2.0 * rpMode.w;
        col = float3(fdir * 0.5 + 0.5, saturate(Fmag / 15.0)) * L;
    }

    pfxOut[storePos] = float4(col, src.a);
}
