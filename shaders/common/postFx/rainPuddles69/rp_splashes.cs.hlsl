#define PFX_COMPUTE 1

#include "rp_splashes.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// Tyre spray, v0.9 rewrite: a WORLD-SPACE plume per tyre made of soft particles.
//
// Each tyre (rpTyreA/B/C, up to 8: the player's car first, then traffic) sheds puffs that leave the tread backward,
// rise and spread out; in a puddle two side sheets are thrown out as well. For every pixel the view ray is tested
// against each puff (closest approach -> Gaussian density) and against the depth buffer AT THE PUFF'S OWN DISTANCE
// (soft particles). So the spray shows over the road behind the car (0.8 hid exactly that: it compared every pixel with
// the tyre's contact depth), is hidden by the bodywork where it is behind it, shows against the sky and grows with
// perspective - no Lua-side projection or FOV assumption any more.
// Strength = water at the contact point (puddle field or wet road) x tread speed (spin) / ground speed; wheelspin and
// sliding add more. Positions follow per-tyre spray clocks from Lua, so speed changes never make the puffs jump.
// 1.1: no more popping. Each puff carries the water of the spot where it LEFT the tyre (the contact point as it was when
// the puff was thrown: the tyre has moved on since), so entering a puddle grows the plume backward from the tyre and
// leaving one lets it detach and drift away; before, the whole plume switched with the water right under the tyre. Lua
// fades the cover under the tyre (roofs, tunnels), traffic tyres coming and going, and the 10 Hz tread speed. The spray
// keeps building a little with speed, and puffs differ in strength (gusty).

float rpSprayNoise(float2 p)
{
    int2 i = int2(floor(p));
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = rpRand(rpHash3(int3(i.x,     i.y,     5)));
    float b = rpRand(rpHash3(int3(i.x + 1, i.y,     5)));
    float c = rpRand(rpHash3(int3(i.x,     i.y + 1, 5)));
    float d = rpRand(rpHash3(int3(i.x + 1, i.y + 1, 5)));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float rpSprayFbm(float2 p)
{
    return 0.55 * rpSprayNoise(p) + 0.30 * rpSprayNoise(p * 2.07 + 11.3) + 0.15 * rpSprayNoise(p * 4.1 + 3.7);
}

// Puddle at a world position: the same field the puddle pass uses.
float rpSprayPuddle(float2 w)
{
    float tile = max(rpSplashB.z, 2.0);
    float2 uvA = w / tile;
    float2 uvB = float2(w.x * 0.8660254 - w.y * 0.5, w.x * 0.5 + w.y * 0.8660254) / (tile * 0.57) + float2(0.37, 0.61);
    float nA = rpSampleField(maskTexA, uvA, 0.010);
    float nB = rpSampleField(maskTexB, uvB, 0.0175);
    float cov   = saturate(rpSplashB.x);
    float shape = saturate(0.5 + (nA - 0.5) / max(lerp(0.58, 1.34, saturate(rpSplashC.z)), 0.1));
    float cut   = (1.0 - cov) + (nB - 0.5) * 0.32 * min(cov * 4.0, 1.0);
    return smoothstep(cut, cut + max(rpSplashB.y, 0.004), shape);
}

// 1.5 simulated mist (rp_mist.cs.hlsl) --------------------------------------------------------------------------------
// Mist density in layer l at g (grid cells from the corner; cell i spans i..i+1). Through the linear sampler: the upper
// half of the stored sqrt(density) is plenty to look at. Fades out over the grid's last cells.
float rpMistDensity(int l, float2 g, bool srgb)
{
    const float2 gc = clamp(g, 0.5, float(RP_MIST_N) - 0.5);
    const float2 uv = float2((float(l * RP_MIST_N) + gc.x) / float(2 * RP_MIST_LAYERS * RP_MIST_N), gc.y / float(RP_MIST_N));
    float e = mistTex.SampleLevel(rpMistSampler, uv, 0).b;
    e = srgb ? rpLinToSrgb1(e) : e;
    const float2 edge = min(g, float(RP_MIST_N) - g);
    return e * e * RP_MIST_DMAX * smoothstep(1.5, 6.0, min(edge.x, edge.y));
}

// Mist density at height h above the road: the layers hold it at their middles (0.25, 0.75 and 1.5 m), in between it
// is blended, above the top layer's middle it thins out to nothing at 2.4 m (slab edges drew hard horizontal bands where
// rays ran flat through a layer).
float rpMistDensityH(float2 g, float h, bool srgb)
{
    if (h < 0.0 || h > 2.4)
    {
        return 0.0;
    }
    if (h <= 0.25)
    {
        return rpMistDensity(0, g, srgb);
    }
    if (h <= 0.75)
    {
        return lerp(rpMistDensity(0, g, srgb), rpMistDensity(1, g, srgb), (h - 0.25) / 0.5);
    }
    if (h <= 1.5)
    {
        return lerp(rpMistDensity(1, g, srgb), rpMistDensity(2, g, srgb), (h - 0.75) / 0.75);
    }
    return rpMistDensity(2, g, srgb) * (1.0 - (h - 1.5) / 0.9);
}

// Fine structure of the mist at world point w: it is billows and wisps, not a smooth haze. Value noise in world space
// (two octaves, the height shifts it so the billows are not columns), slowly churning; 1 on average.
float rpMistDetail(float3 w)
{
    const float t = rpCam.w;
    const float2 p = w.xy * 1.3 + float2(w.z * 0.9, -w.z * 0.7) + float2(t * 0.11, t * 0.07);
    const float n = 0.6 * rpSprayNoise(p) + 0.4 * rpSprayNoise(p * 2.3 + float2(5.1 - t * 0.19, 1.7 + t * 0.13));
    return 0.2 + 1.6 * n;
}

// How much mist the ray from the camera passes through before it reaches the scene (density x metres): the part of the
// ray over the grid and below 2.4 m above the road, sampled (more samples where it runs flat), jittered per pixel,
// faded in over the first 2.5 m past rpMistQ.w (the camera is often right above its own car's fresh trail).
float rpMistDepth(float3 rd, float tMax, float jit, bool srgb)
{
    const float n = float(RP_MIST_N);
    const float2 g0 = (rpCam.xy - rpMistP.xy) / rpMistP.z;
    const float2 gd = rd.xy / rpMistP.z;
    float t0 = rpMistQ.w;
    float t1 = min(tMax, 90.0);
    [unroll]
    for (int a = 0; a < 2; a++)
    {
        if (abs(gd[a]) < 1e-7)
        {
            if (g0[a] < 0.0 || g0[a] > n)
            {
                return 0.0;
            }
        }
        else
        {
            const float ta = (0.0 - g0[a]) / gd[a];
            const float tb = (n - g0[a]) / gd[a];
            t0 = max(t0, min(ta, tb));
            t1 = min(t1, max(ta, tb));
        }
    }
    if (t1 <= t0)
    {
        return 0.0;
    }
    // height above the road plane along the ray: h0 + hs t; the part of the ray between 0 and 2.4 m
    const float h0 = rpCam.z - (rpMistP.w + dot(rpMistQ.xy, rpCam.xy - rpMistP.xy));
    const float hs = rd.z - dot(rpMistQ.xy, rd.xy);
    if (abs(hs) < 1e-5)
    {
        if (h0 < 0.0 || h0 > 2.4)
        {
            return 0.0;
        }
    }
    else
    {
        const float u0 = (0.0 - h0) / hs;
        const float u1 = (2.4 - h0) / hs;
        t0 = max(t0, min(u0, u1));
        t1 = min(t1, max(u0, u1));
    }
    if (t1 <= t0)
    {
        return 0.0;
    }
    const float len = t1 - t0;
    const int ns = clamp(int(ceil(len / 0.7)), 3, 12);
    const float st = len / float(ns);
    float sum = 0.0;
    [loop]
    for (int k = 0; k < ns; k++)
    {
        const float t = t0 + (float(k) + jit) * st;
        const float dn = rpMistDensityH(g0 + gd * t, h0 + hs * t, srgb);
        if (dn > 1e-4)
        {
            sum += dn * rpMistDetail(rpCam.xyz + rd * t) * saturate((t - rpMistQ.w) / 2.5);
        }
    }
    return sum * st;
}

// The light the mist sends toward the eye: as the plume's (the sky's by day, at least the brightness behind it; at
// night the light behind it, the brightest light around it and a capped glow), without the plume's per-tyre taps.
float3 rpMistLight(float3 src, int2 p)
{
    const float3 amb = rpSprayAmbient();
    const float mistL = max(rpLuma(amb) * 1.15, max(rpLuma(src) * 0.9, 0.06));
    float3 mist = float3(0.82, 0.87, 0.93) * mistL;
    const float night = saturate(rpSplashD.x);
    if (night > 0.01)
    {
        float3 mistN = amb * 1.15;
        const float3 srcN = src * 0.9;
        if (rpLuma(srcN) > rpLuma(mistN))
        {
            mistN = srcN;
        }
        float3 glowC = float3(0.0, 0.0, 0.0);
        float bestG = 0.0;
        const float rs = dispatchRect.w / 1080.0;
        float frameL = 0.0;
        [unroll]
        for (int gi = 0; gi < 8; gi++)
        {
            const float ang = float(gi) * 0.7853982 + (((gi & 1) == 1) ? 0.3927 : 0.0);
            const float rr = (((gi & 1) == 1) ? 52.0 : 22.0) * rs;
            const int2 qg = p + int2(round(float2(cos(ang), sin(ang)) * rr));
            const float3 cg = colorTex.Load(int3(rpClampPix(qg), 0)).rgb;
            const float lg = rpLuma(cg);
            if (lg > bestG)
            {
                bestG = lg;
                glowC = cg;
            }
            const float2 fu = float2((float(gi & 3) + 0.5) / 4.0, (float(gi >> 2) + 0.5) / 2.0);
            frameL += rpLuma(colorTex.Load(int3(rpClampPix(int2(dispatchRect.xy + fu * dispatchRect.zw)), 0)).rgb);
        }
        frameL /= 8.0;
        mistN += glowC * 0.35;
        mistN = lerp(mistN, rpLuma(mistN).xxx, 0.2);
        mistN *= min(1.0, (14.0 * frameL + 1e-4) / max(rpLuma(mistN), 1e-6));
        mist = lerp(mist, mistN, night);
    }
    return mist;
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
    float3 col = src.rgb;

    if (rpSplashA.w < 0.01 || rpSplashA.x < 0.001)
    {
        pfxOut[storePos] = src;
        return;
    }

    PFXVertToPix IN = processPostFxCompute(dispatchThreadID);
    PFXVertToPix INx = processPostFxCompute(dispatchThreadID + uint3(1, 0, 0));
    PFXVertToPix INy = processPostFxCompute(dispatchThreadID + uint3(0, 1, 0));
    const float3 ray0 = IN.wsEyeRay;
    const float3 dxr = INx.wsEyeRay - ray0;
    const float3 dyr = INy.wsEyeRay - ray0;
    float3 camFwd = normalize(cross(dxr, dyr));
    camFwd = (dot(camFwd, ray0) < 0.0) ? -camFwd : camFwd;
    const float3 rd = normalize(ray0);

    // distance to the scene along this pixel's ray (sky = far away)
    // 1.0: sampled by this slot's own uv (render scaling / upscaling can give the depth a different size than the frame)
    const float sceneNdc = prepassDepthTex.SampleLevel(rpDepthSampler, IN.uv1, 0).r;
    // 1.0: same reconstruction as the puddle pass (eye-linear depth along the far-plane eye ray)
    const float sceneDist = rpIsSkyDepth(sceneNdc) ? 1e5   // 1.3: the reversed-Z sky (0) too
        : length(rpReconstruct(ray0, camFwd, abs(ndcToRealDepth(sceneNdc, projParams)) / max(abs(projParams.y), 1e-6), rpMode.y, rpMode.z));

    float4 tA[8] = { rpTyreA0, rpTyreA1, rpTyreA2, rpTyreA3, rpTyreA4, rpTyreA5, rpTyreA6, rpTyreA7 };
    float4 tB[8] = { rpTyreB0, rpTyreB1, rpTyreB2, rpTyreB3, rpTyreB4, rpTyreB5, rpTyreB6, rpTyreB7 };
    float4 tC[8] = { rpTyreC0, rpTyreC1, rpTyreC2, rpTyreC3, rpTyreC4, rpTyreC5, rpTyreC6, rpTyreC7 };

    float3 prk = float3(0.0, 0.0, 0.0);
    float3 pra = float3(0.0, 0.0, 0.0);
    float3 prb = float3(0.0, 0.0, 0.0);
    rpMakeProj(ray0, dxr, dyr, prk, pra, prb);

    float dbgGate = 0.0;
    float dbgDens = 0.0;
    const float sz = max(rpSplashA.y, 0.25);

    [unroll]
    for (int ti = 0; ti < 8; ti++)
    {
        if (tC[ti].y > 0.5)
        {
            const float3 c0 = tA[ti].xyz;                 // contact point on the ground
            const float hw = tA[ti].w;
            const float2 dir2 = tB[ti].xy;
            const float g = tB[ti].z;                     // ground speed
            const float tread = clamp(tB[ti].w, 0.0, 80.0); // tread speed (spin); 1.5: clamped (a car's physics once
                                                            // reported 9e8 m/s for a parked car's wheels)
            const float v = max(g, tread);
            const float slip = saturate(abs(tread - g) / 6.0);
            // 1.1: from half the threshold speed up, full a little above it, then still a little more up to ~120 km/h
            const float speedK = smoothstep(rpSplashA.z * 0.4, rpSplashA.z + 7.0, v) * (0.8 + 0.2 * smoothstep(12.0, 34.0, v));

            // water at the contact: puddle, or the wet road ('Only on puddles' 1 = puddles only)
            const float pud = rpSprayPuddle(c0.xy);
            const float roadWater = 0.6 * pow(saturate(rpSplashA.w), 0.6);
            const float water = lerp(max(pud, roadWater), pud, saturate(rpSplashB.w));
            const float distFade = 1.0 - smoothstep(rpSplashC.y * 0.55, rpSplashC.y, length(c0 - rpCam.xyz));
            const float roadWet = saturate((tC[ti].y - 0.5) * 2.0);       // 1.0: 0 under a roof / in a tunnel (1.1: faded in Lua)
            // 1.1: the tyre's part of the strength; the water comes per puff (where it was thrown)
            const float tyreK = rpSplashA.x * speedK * (1.0 + slip) * distFade * roadWet;
            const float strength = tyreK * water * (1.0 + 0.6 * pud);
            // seconds a puff lives: Lua runs the spray clock at 0.9 + 0.075 x speed per second
            const float lifeS = 1.0 / max(0.9 + 0.075 * v, 0.1);
            const float roadOnly = saturate(rpSplashB.w);

            if (tyreK * 1.6 > 0.003)
            {
                const float L = (0.6 + v * 0.11) * sz;     // plume length behind the tyre (m)
                const float Hh = (0.18 + v * 0.022) * sz;  // plume rise (m)
                const float3 back = -float3(dir2, 0.0);
                const float3 side = float3(-dir2.y, dir2.x, 0.0);
                const float3 up = float3(0.0, 0.0, 1.0);

                // bounding sphere of the whole plume: most pixels stop here
                const float3 cb = c0 + back * (L * 0.5) + up * (Hh * 0.6);
                const float rb = L * 0.5 + Hh + hw + 0.6;
                const float3 relB = cb - rpCam.xyz;
                const float tcb = dot(relB, rd);
                const float3 perpB = relB - rd * tcb;
                if (dot(perpB, perpB) < rb * rb && tcb > -rb && sceneDist > tcb - rb)
                {
                    dbgGate = max(dbgGate, water * speedK);
                    float sMax = 0.0;
                    const float clk = tC[ti].z;
                    const float seedT = tC[ti].w;
                    float dens = 0.0;
                    [unroll]
                    for (int k = 0; k < 10; k++)
                    {
                        // puffs 0-5: rear plume. 6-9: side sheets thrown out of a puddle (left / right)
                        float sideK = (k < 6) ? 0.0 : ((k < 8) ? -1.0 : 1.0);
                        float rate = (k < 6) ? 1.0 : 1.35;
                        float tt = clk * rate + float(k) * 0.618 + seedT;
                        float a = frac(tt);                                   // age of this puff
                        uint hk = rpHash3(int3(k, int(floor(tt)), int(seedT * 997.0) + ti * 131));
                        float jr = rpRand(hk) - 0.5;
                        float jr2 = rpRand(rpPcg(hk ^ 0x1B873593u)) - 0.5;
                        float ea = 1.0 - (1.0 - a) * (1.0 - a);               // thrown fast, slowed by the air
                        // 1.1: the water where this puff left the tyre (age in seconds x ground speed behind the tyre now)
                        float ageS = a * lifeS / rate;
                        float pudK = rpSprayPuddle(c0.xy - dir2 * (g * ageS));
                        float waterK = lerp(max(pudK, roadWater), pudK, roadOnly) * (1.0 + 0.6 * pudK);
                        float gust = 0.7 + 0.6 * rpRand(rpPcg(hk ^ 0xE6546B64u));   // puffs differ: a gusty plume
                        sMax = max(sMax, waterK);
                        float3 c;
                        float r;
                        float w;
                        if (sideK == 0.0)
                        {
                            c = c0 + back * (L * ea) + up * (Hh * (0.25 + 0.75 * a) * (0.6 + 0.4 * ea) + jr2 * 0.06 * sz)
                              + side * (jr * (hw * 1.4 + 0.35 * a * L));
                            r = (0.10 + 0.35 * a) * sz * (0.5 + 0.06 * v) + hw * 0.6;
                            w = smoothstep(0.0, 0.12, a) * pow(1.0 - a, 1.4) * waterK * gust;
                        }
                        else
                        {
                            c = c0 + side * (sideK * (hw + 0.15 + 0.55 * ea * (0.4 + 0.05 * v) * sz)) + back * (L * 0.35 * ea)
                              + up * (Hh * 0.8 * sin(3.1416 * a) + jr2 * 0.04 * sz);
                            r = (0.08 + 0.22 * a) * sz * (0.5 + 0.05 * v);
                            w = smoothstep(0.0, 0.10, a) * pow(1.0 - a, 1.6) * smoothstep(0.15, 0.5, pudK) * waterK * gust;
                        }
                        float3 rc = c - rpCam.xyz;
                        float tc = dot(rc, rd);
                        if (tc > 0.05 && w > 0.001)
                        {
                            float3 pp = rc - rd * tc;
                            float d2 = dot(pp, pp) / (r * r);
                            // soft particle: fades out where the scene surface is in front of this puff
                            float occl = saturate((sceneDist - (tc - r)) / (2.0 * r));
                            dens += exp(-d2 * 1.6) * w * occl;
                        }
                    }

                    if (dens > 0.0005)
                    {
                        // billowing: noise in the plume's own frame at the ray's closest approach, drifting backward
                        float3 X = rpCam.xyz + rd * max(tcb, 0.05) - c0;
                        float2 np2 = float2(dot(X, back) * 2.2 - clk * 1.5, (dot(X, side) + dot(X, up)) * 3.1 + seedT * 40.0);
                        float n = rpSprayFbm(np2);
                        dens *= 0.35 + 0.9 * smoothstep(0.12, 0.85, n);

                        // droplet sparkles near the tyre in strong spray
                        float2 sg = float2(dot(X, back), dot(X, up)) * 16.0 + float2(-clk * 9.0, 0.0);
                        uint hsp = rpHash3(int3(int(floor(sg.x)), int(floor(sg.y)), ti * 17 + 3));
                        float2 fsp = frac(sg) - 0.5;
                        float spark = step(0.965, rpRand(hsp)) * (1.0 - smoothstep(0.05, 0.18, length(fsp)))
                                    * exp(-max(dot(X, back), 0.0) / max(L * 0.5, 0.1)) * saturate(dens * 3.0) * saturate(sMax);

                        // light (1.0): the mist scatters the sky's light (ambient SH) and the light of the lit road
                        // beside the tyre. 0.9 took its brightness from the screen right around the tyre, which behind
                        // a dark car is the dark body: the plume turned into dark smoke over a bright wet road.
                        float2 o = float2(0.0, 0.0);
                        float envL = 0.0;
                        float3 roadC = float3(0.0, 0.0, 0.0);
                        if (rpProjectFast(prk, pra, prb, c0 + up * 0.05 - rpCam.xyz, o))
                        {
                            o = clamp(o, float2(-4096.0, -4096.0), float2(4096.0, 4096.0));   // 1.3: no int overflow
                            int2 q = p + int2(round(o));
                            // the road below and beside the tyre (well outside the body), brightest of three
                            float3 t0 = colorTex.Load(int3(rpClampPix(q + int2(0, 14)), 0)).rgb;
                            float3 t1 = colorTex.Load(int3(rpClampPix(q + int2(-48, 8)), 0)).rgb;
                            float3 t2 = colorTex.Load(int3(rpClampPix(q + int2(48, 8)), 0)).rgb;
                            float l0 = rpLuma(t0);
                            float l1 = rpLuma(t1);
                            float l2 = rpLuma(t2);
                            envL = max(l0, max(l1, l2));
                            // 1.3 (night): the middle one, in colour: a lane marking, the body or a light in one tap
                            // does not count
                            float lm = l0 + l1 + l2 - envL - min(l0, min(l1, l2));
                            roadC = (abs(l0 - lm) < 1e-6) ? t0 : ((abs(l1 - lm) < 1e-6) ? t1 : t2);
                        }
                        float3 amb = rpSprayAmbient();
                        float mistL = max(max(rpLuma(amb) * 1.15, envL * 0.9), max(rpLuma(src.rgb) * 0.9, 0.06));
                        float3 mist = float3(0.82, 0.87, 0.93) * mistL;
                        // 1.3 night: the mist is lit by whatever lights the road under it, in that light's colour
                        // (street lamps, the car's own tail and brake lights, headlights): wet asphalt returns about a
                        // fifth of the light falling on it, a cloud of water drops nearly all of it. And it glows around
                        // bright lights right next to the plume (it scatters their light forward, toward the eye). By
                        // day the sky outshines all that and the mist stays as it was. (Up to 1.3.0 the night mist was
                        // the road's grey brightness with a fixed floor: a faint grey haze, never in the lights' colour.)
                        const float night = saturate(rpSplashD.x);
                        if (night > 0.01)
                        {
                            float3 mistN = amb * 1.15;
                            float3 roadN = roadC * 4.5;
                            if (rpLuma(roadN) > rpLuma(mistN))
                            {
                                mistN = roadN;
                            }
                            float3 srcN = src.rgb * 0.9;
                            if (rpLuma(srcN) > rpLuma(mistN))
                            {
                                mistN = srcN;
                            }
                            // The car's own tail lights: a rear tyre's plume starts right under them. Their colour is read
                            // on screen where they should be (about 0.75 m up and 0.45 m behind the tyre; brightest of a
                            // 3 x 3 patch, lights are thin), and they light the mist near them, fading over about a metre.
                            // Brake lights read brighter, so the spray flares up red when the car brakes. For a front
                            // tyre that spot is the car's side: dark at night, nothing added.
                            const float3 tailP = c0 + up * 0.75 + back * 0.45;
                            float2 ot = float2(0.0, 0.0);
                            float2 os = float2(0.0, 0.0);
                            float3 tailC = float3(0.0, 0.0, 0.0);
                            if (rpProjectFast(prk, pra, prb, tailP - rpCam.xyz, ot)
                                && rpProjectFast(prk, pra, prb, tailP + side * 0.3 - rpCam.xyz, os))
                            {
                                ot = clamp(ot, float2(-4096.0, -4096.0), float2(4096.0, 4096.0));
                                float sp = clamp(length(os - ot) * 0.5, 2.0, 12.0);
                                float bestT = 0.0;
                                [unroll]
                                for (int ty = -1; ty <= 1; ty++)
                                {
                                    [unroll]
                                    for (int tx = -1; tx <= 1; tx++)
                                    {
                                        int2 qt = p + int2(round(ot + float2(float(tx), float(ty)) * sp));
                                        float3 ct = colorTex.Load(int3(rpClampPix(qt), 0)).rgb;
                                        float lt = rpLuma(ct);
                                        if (lt > bestT)
                                        {
                                            bestT = lt;
                                            tailC = ct;
                                        }
                                    }
                                }
                            }
                            const float3 Xw = rpCam.xyz + rd * max(tcb, 0.05);
                            const float3 dT = Xw - tailP;
                            mistN += tailC * (0.6 * exp(-dot(dT, dT) / 0.8));
                            // the brightest light within ~2-5 % of the screen height around this pixel (8 taps), and
                            // the frame's average brightness (8 fixed taps) for the cap below
                            float3 glowC = float3(0.0, 0.0, 0.0);
                            float bestG = 0.0;
                            float rs = dispatchRect.w / 1080.0;
                            float frameL = 0.0;
                            [unroll]
                            for (int gi = 0; gi < 8; gi++)
                            {
                                float ang = float(gi) * 0.7853982 + (((gi & 1) == 1) ? 0.3927 : 0.0);
                                float rr = (((gi & 1) == 1) ? 52.0 : 22.0) * rs;
                                int2 qg = p + int2(round(float2(cos(ang), sin(ang)) * rr));
                                float3 cg = colorTex.Load(int3(rpClampPix(qg), 0)).rgb;
                                float lg = rpLuma(cg);
                                if (lg > bestG)
                                {
                                    bestG = lg;
                                    glowC = cg;
                                }
                                float2 fu = float2((float(gi & 3) + 0.5) / 4.0, (float(gi >> 2) + 0.5) / 2.0);
                                frameL += rpLuma(colorTex.Load(int3(rpClampPix(int2(dispatchRect.xy + fu * dispatchRect.zw)), 0)).rgb);
                            }
                            frameL /= 8.0;
                            mistN += glowC * 0.35;
                            // water scatters all colours alike: a little toward white; and never a blown-out halo
                            mistN = lerp(mistN, rpLuma(mistN).xxx, 0.2);
                            mistN *= min(1.0, (14.0 * frameL + 1e-4) / max(rpLuma(mistN), 1e-6));
                            mist = lerp(mist, mistN, night);
                            mistL = lerp(mistL, rpLuma(mistN), night);
                        }
                        // 1.0: a light mist (in-game feedback, twice: too thick): thin and never more than 28 % opaque
                        // 1.1: the water is already in each puff's weight (dens), the tyre's part scales it
                        float alpha = saturate((1.0 - exp(-dens * 0.5)) * tyreK);
                        col = lerp(col, mist, min(alpha, 0.28));
                        col += mist * (0.03 * alpha) + float3(1.0, 1.0, 1.0) * (spark * mistL * 0.8 * saturate(tyreK * sMax));
                        dbgDens = max(dbgDens, alpha);
                    }
                }
            }
        }
    }

    // 1.5 simulated mist: the spray the air carried off, swirled and left hanging behind the cars, along this pixel's ray
    // up to the scene (the mist passes run after this pass: it is the mist of the last frame, in the last frame's grid)
    float mistA = 0.0;
    float mistCal = -1.0;
    if (rpMistQ.z > 0.0)
    {
        mistCal = mistTex.Load(int3(0, 0, 0)).r;   // the calibration texel: 0.5 read raw, 0.216 through an sRGB view
        if (abs(mistCal - 0.5) < 0.03 || abs(mistCal - 0.2158) < 0.03)
        {
            const float mistJit = frac(52.9829189 * frac(dot(float2(p), float2(0.06711056, 0.00583715))));
            const float tau = rpMistDepth(rd, sceneDist, mistJit, abs(mistCal - 0.5) > 0.1) * rpMistQ.z;
            mistA = min(1.0 - exp(-tau), 0.45);
            if (mistA > 0.002)
            {
                col = lerp(col, rpMistLight(src.rgb, p), mistA);
            }
        }
    }

    if (rpMode.x > 21.5 && rpMode.x < 22.5)
    {
        // Debug 22: simulated mist. Orange = the mist on screen. Bottom left (two screen pixels per cell, north up): the
        // three layers from above, low to high (red = air speed east-west, green = north-south, up to 15 m/s; white =
        // mist). Top left square: green = the mist's targets read raw, magenta = through an sRGB view, red =
        // unreadable, grey = the mist is off or not running yet.
        const float B = max(rpLuma(src.rgb), 0.05) * 2.0 * rpMode.w;
        col = float3(0.05, 0.05, 0.05) * B;
        col = lerp(col, float3(1.0, 0.55, 0.08) * B, saturate(mistA * 2.5));
        const int2 lp = p - int2(dispatchRect.xy);
        const int2 ip = int2(lp.x, int(dispatchRect.w) - 1 - lp.y) / 2;
        const bool calOk = abs(mistCal - 0.5) < 0.03 || abs(mistCal - 0.2158) < 0.03;
        if (calOk && ip.x < RP_MIST_LAYERS * RP_MIST_N && ip.y < RP_MIST_N)
        {
            const bool sr = abs(mistCal - 0.5) > 0.1;
            const float4 ta = rpWaveRaw(mistTex.Load(int3(ip, 0)), sr);
            const float4 tb = rpWaveRaw(mistTex.Load(int3(ip + int2(RP_MIST_LAYERS * RP_MIST_N, 0), 0)), sr);
            const float e = rpUnpackU16(float2(ta.b, tb.b));
            col = float3(saturate(abs(rpUnpack16(ta.rg, RP_MIST_VMAX)) / 15.0), saturate(abs(rpUnpack16(tb.rg, RP_MIST_VMAX)) / 15.0), 0.0) * 0.8
                + saturate(e * e * RP_MIST_DMAX * 3.0).xxx;
            if (ip.x % RP_MIST_N == 0)
            {
                col = float3(0.3, 0.3, 0.3);
            }
        }
        if (all(lp < int2(24, 24)))
        {
            col = (rpMistQ.z <= 0.0 || mistCal < -0.5) ? float3(0.4, 0.4, 0.4)
                : (abs(mistCal - 0.5) < 0.03 ? float3(0.1, 0.9, 0.1)
                : (abs(mistCal - 0.2158) < 0.03 ? float3(0.9, 0.1, 0.9) : float3(0.9, 0.1, 0.1)));
        }
    }

    if (rpMode.x > 8.5 && rpMode.x < 9.5)
    {
        // Debug 9: cyan = water x speed at a tyre (spray allowed), orange = spray density on screen
        float B = max(rpLuma(src.rgb), 0.05) * 2.0 * rpMode.w;
        col = float3(0.05, 0.05, 0.05) * B;
        col = lerp(col, float3(0.1, 0.8, 1.0) * B, saturate(dbgGate) * 0.35);
        col = lerp(col, float3(1.0, 0.55, 0.08) * B, saturate(dbgDens * 2.0));
    }

    pfxOut[storePos] = float4(rpSafe(col, src.rgb), src.a);
}
