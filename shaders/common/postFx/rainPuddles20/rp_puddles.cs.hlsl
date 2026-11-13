#define PFX_COMPUTE 1

#include "rp_puddles.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

#define RP_SSR_MAX_STEPS 48

float3 rpLoadColor(int2 q)
{
    return colorTex.Load(int3(rpClampPix(q), 0)).rgb;
}

float3 rpBlurColor(int2 q, int radius)
{
    int r = max(radius, 0);
    float3 c = rpLoadColor(q) * 0.36;
    c += rpLoadColor(q + int2(r, 0)) * 0.16;
    c += rpLoadColor(q - int2(r, 0)) * 0.16;
    c += rpLoadColor(q + int2(0, r)) * 0.16;
    c += rpLoadColor(q - int2(0, r)) * 0.16;
    return c;
}

// Light streak (0.8): reflection sample stretched along the screen vertical (7 taps, Gaussian), plus a small horizontal
// spread. Wet asphalt turns the reflection of every light into a vertical streak.
float3 rpStreakColor(int2 q, float lenPx)
{
    float3 c = float3(0.0, 0.0, 0.0);
    float wsum = 0.0;
    [unroll]
    for (int k = -3; k <= 3; k++)
    {
        float w = exp(-0.5 * float(k * k) / 2.25);
        c += rpLoadColor(q + int2(0, int(round(float(k) * lenPx / 3.0)))) * w;
        wsum += w;
    }
    c = c / wsum;
    return c * 0.8 + (rpLoadColor(q + int2(2, 0)) + rpLoadColor(q - int2(2, 0))) * 0.1;
}

float rpSceneMetres(int2 q)
{
    float ndc = rpDepthLoad(rpClampPix(q));
    return ndcToRealDepth(ndc, projParams);
}

// Blur radius (pixels) of the reflection reconstruction. 0 for a mirror, so water stays razor sharp.
int rpBlurRadius(float rough, float blurAmount)
{
    return clamp((int)floor(14.0 * rough * blurAmount + 0.15), 0, 12);
}

// Screen-edge confidence of a pixel inside the dispatch rectangle.
float rpEdgeConf(int2 q)
{
    float2 rel = (float2(q) - dispatchRect.xy) / max(dispatchRect.zw, float2(1, 1));
    float ex = smoothstep(0.0, 0.055, rel.x) * (1.0 - smoothstep(0.945, 1.0, rel.x));
    float ey = smoothstep(0.0, 0.055, rel.y) * (1.0 - smoothstep(0.945, 1.0, rel.y));
    return ex * ey;
}

// Reflection of the far field (sky, clouds, sun, distant terrain) read from the colour buffer along the
// exact reflection direction. At infinity the parallax between the receiver and the camera vanishes, so the
// pixel that shows direction R IS the correct reflected radiance. A pixel that holds the far-plane clear value
// (sky) or geometry beyond the march range is accepted; anything nearer was already handled by the march.
bool rpSkyLookup(float3 R, int2 p, float3 prk, float3 pra, float3 prb, float maxDist, float depthK, int blurPx,
                 float streakPx, out float3 reflected, out float confidence)
{
    reflected = float3(0.0, 0.0, 0.0);
    confidence = 0.0;
    bool found = false;

    if (R.z >= 0.015)                                    // below the horizon: cannot see the sky
    {
        int2 lo = int2(dispatchRect.xy) + 2;
        int2 hi = int2(dispatchRect.xy + dispatchRect.zw) - 3;
        float2 off = float2(0.0, 0.0);
        if (rpProjectFast(prk, pra, prb, R, off))
        {
            int2 q = int2(round(float2(p) + off));
            if (q.x >= lo.x && q.y >= lo.y && q.x <= hi.x && q.y <= hi.y)
            {
                float ndc = rpDepthLoad(q);
                bool far = (ndc >= 0.99999);
                if (!far)
                {
                    far = (abs(ndcToRealDepth(ndc, projParams)) * depthK >= maxDist * 0.9);
                }
                if (far)
                {
                    reflected = (streakPx > 1.5) ? rpStreakColor(q, streakPx) : ((blurPx > 0) ? rpBlurColor(q, blurPx) : rpLoadColor(q));
                    confidence = saturate(rpEdgeConf(q));
                    found = (confidence > 0.001);
                }
            }
        }
    }
    return found;
}

// Screen-space sky probe (0.6.2). 16 fixed points in the upper part of the screen; the ones that show the far plane
// (sky) are averaged, weighted by how close their view direction is to R. This is the sky that is actually visible
// right now (colour, brightness, clouds, sunset, night), so escaped reflections match it. Every pixel reads the
// same 16 addresses (cache friendly). conf = 0 when no sky is visible (tunnels, looking down, city canyons).
float3 rpScreenSky(float3 R, int2 p, float3 ray0, float3 dxr, float3 dyr, out float conf)
{
    float3 sumW = float3(0.0, 0.0, 0.0);
    float3 sumP = float3(0.0, 0.0, 0.0);
    float wsum = 0.0;
    float n = 0.0;
    [unroll]
    for (int j = 0; j < 2; j++)
    {
        [unroll]
        for (int i = 0; i < 8; i++)
        {
            float2 f = float2((float(i) + 0.5) / 8.0, (j == 0) ? 0.04 : 0.17);
            int2 q = rpClampPix(int2(dispatchRect.xy + f * dispatchRect.zw));
            if (rpDepthLoad(q) >= 0.99999)
            {
                float3 c = rpLoadColor(q);
                float3 dir = normalize(ray0 + dxr * float(q.x - p.x) + dyr * float(q.y - p.y));
                float w = exp(6.0 * (dot(dir, R) - 1.0));
                sumW += c * w;
                wsum += w;
                sumP += c;
                n += 1.0;
            }
        }
    }
    conf = saturate(n / 3.0);
    return (wsum > 1e-4) ? sumW / wsum : sumP / max(n, 1.0);
}

// Surroundings capture (1.0, 'dynamic reflections' fallback). Lua renders the real scene above the camera into a small
// square texture (an upward-looking render view: sky, clouds, tree crowns, bridges, tunnel roofs, tall buildings). A ray
// that the screen-space trace lost is looked up there by direction. The capture has no depth, so parallax is corrected
// with a proxy sphere around the capture point (exact for things about that far away, close enough for the rest).
// Returns rgb = radiance, a = confidence (0 outside the captured cone or when the capture is not available).
float4 rpEnvSample(float3 P, float3 R, float blurTexels)
{
    float4 res = float4(0.0, 0.0, 0.0, 0.0);
    if (rpEnvA.w > 0.5)
    {
        float3 o = P - rpEnvA.xyz;
        float rad = max(rpEnvD.w, 1.0);
        float b = dot(o, R);
        float c = dot(o, o) - rad * rad;
        float3 d = R;
        if (c < 0.0)
        {
            d = normalize(o + R * (-b + sqrt(max(b * b - c, 0.0))));
        }
        float zf = dot(d, rpEnvD.xyz);
        if (zf > 0.05)
        {
            float tanH = max(rpEnvB.w, 0.1);
            float2 s = float2(dot(d, rpEnvB.xyz), dot(d, rpEnvC.xyz)) / (zf * tanH);
            float edge = max(abs(s.x), abs(s.y));
            if (edge < 1.0)
            {
                float2 uv = float2(0.5 + 0.5 * s.x, 0.5 - 0.5 * s.y);
                float4 win = (rtParams5.z > 1e-5 && rtParams5.w > 1e-5) ? rtParams5 : float4(0.0, 0.0, 1.0, 1.0);
                uint tw, th;
                envTexTex.GetDimensions(tw, th);
                float2 px = blurTexels / max(float2(tw, th), float2(1.0, 1.0));
                float2 lo = float2(0.004, 0.004);
                float2 hi = float2(0.996, 0.996);
                float3 acc = envTexTex.SampleLevel(envTex_sampler_, viewportCoordToRenderTarget(clamp(uv, lo, hi), win), 0).rgb * 0.36;
                acc += envTexTex.SampleLevel(envTex_sampler_, viewportCoordToRenderTarget(clamp(uv + float2(px.x, 0.0), lo, hi), win), 0).rgb * 0.16;
                acc += envTexTex.SampleLevel(envTex_sampler_, viewportCoordToRenderTarget(clamp(uv - float2(px.x, 0.0), lo, hi), win), 0).rgb * 0.16;
                acc += envTexTex.SampleLevel(envTex_sampler_, viewportCoordToRenderTarget(clamp(uv + float2(0.0, px.y), lo, hi), win), 0).rgb * 0.16;
                acc += envTexTex.SampleLevel(envTex_sampler_, viewportCoordToRenderTarget(clamp(uv - float2(0.0, px.y), lo, hi), win), 0).rgb * 0.16;
                res = float4(max(acc, 0.0) * rpEnvC.w, 1.0 - smoothstep(0.78, 0.98, edge));
            }
        }
    }
    return res;
}

// Depth-aware screen-space trace: world-space exponential march against the prepass depth, per-pixel jitter,
// thickness that grows with the step length (coarse far steps do not tunnel through thin objects), binary
// refinement of the crossing, edge/distance confidence, then an exact far-field lookup when the ray leaves the
// scene without a hit. On a miss it also reports what the ray last saw on screen (escCol/escConf: the sky pixel it
// crossed, the screen-border pixel where it left, or the far geometry it ran out of steps in front of), so the caller
// can extend the reflection with real scene colour instead of a flat ambient colour (0.6.2).
// Single-exit structure: every path leaves the loop with `break` and the function returns once at the end.
bool rpTraceReflection(
    float3 S,
    float3 R,
    int2 p,
    float3 prk,
    float3 pra,
    float3 prb,
    float3 camFwd,
    int steps,
    float maxDist,
    float thickness,
    float rough,
    float blurAmount,
    float depthK,
    float streakPx,
    out float3 reflected,
    out float confidence,
    out float3 escCol,
    out float escConf,
    out float4 dbgInfo)
{
    reflected = float3(0.0, 0.0, 0.0);
    confidence = 0.0;
    escCol = float3(0.0, 0.0, 0.0);
    escConf = 0.0;
    dbgInfo = float4(0.0, 0.0, 0.0, 0.0);
    int2 lastQ = p;
    bool haveLast = false;
    bool result = false;
    float why = 8.0;            // diagnostics: why the march ended (see debug view 13)
    float dbgRay = 0.0;
    float dbgScene = 0.0;

    int2 lo = int2(dispatchRect.xy) + 2;
    int2 hi = int2(dispatchRect.xy + dispatchRect.zw) - 3;
    int blurPx = rpBlurRadius(rough, blurAmount);

    bool tryFar = (hi.x > lo.x) && (hi.y > lo.y);   // true while an escaped ray may still see the far field

    // Step growth chosen so that 'steps' samples reach ~maxDist (a fixed 15% growth reached only ~10 m with 18 steps,
    // so reflections of buildings 20-40 m away ran out of steps and fell back to the sky colour).
    float stepGrow = clamp(pow(max(maxDist, 1.0) / 0.3, 1.0 / max((float)steps, 1.0)) - 1.0, 0.10, 0.45);

    // 1.0: start offset from interleaved gradient noise that changes every frame (rpPuddleL.z = frame counter), so the
    // game's temporal AA / upscaler averages it out. A fixed random offset per pixel left a frozen salt-and-pepper
    // pattern wherever neighbouring rays hit or missed thin things (the car's own mirror image on the wet road).
    float2 pj = float2(p) + 5.588238 * fmod(rpPuddleL.z, 64.0);
    float ign = frac(52.9829189 * frac(dot(pj, float2(0.06711056, 0.00583715))));
    float t = 0.10 + 0.22 * ign;
    float prevT = t;

    [loop]
    for (int i = 0; i < RP_SSR_MAX_STEPS; i++)
    {
        if (!tryFar || i >= steps) break;

        float dt = 0.06 + t * stepGrow;
        t += dt;
        if (t > maxDist) { why = 3.0; break; }           // escaped: far-field lookup below

        float3 rel = S + R * t - rpCam.xyz;
        float rayZ = dot(rel, camFwd);
        float2 off = float2(0.0, 0.0);
        if (rayZ <= 0.10 || !rpProjectFast(prk, pra, prb, rel, off))
        {
            tryFar = false;                              // behind the camera: miss
            why = 4.0;
            break;
        }
        int2 q = int2(round(float2(p) + off));
        if (q.x < lo.x || q.y < lo.y || q.x > hi.x || q.y > hi.y)
        {
            // Left the screen. Edge extension: the border pixel where it left is the nearest thing to what lies
            // beyond (sky above the top edge in most views); trusted more when it is sky.
            int2 qb = clamp(q, lo, hi);
            bool skyB = (rpDepthLoad(qb) >= 0.99999);
            escCol = rpBlurColor(qb, max(blurPx, 4));
            escConf = skyB ? 0.9 : 0.45;
            tryFar = false;
            why = 5.0;
            break;
        }

        float ndc = rpDepthLoad(q);
        if (ndc >= 0.99999)
        {
            // Crossed a sky pixel: that sky is what the reflection sees (unless the exact far lookup below does better).
            escCol = rpBlurColor(q, max(blurPx, 2));
            escConf = 0.9 * rpEdgeConf(q) + 0.1;
            why = 6.0;
            break;
        }

        float sceneZ = abs(ndcToRealDepth(ndc, projParams)) * depthK;
        if (i == 3) { dbgRay = rayZ; dbgScene = sceneZ; }
        if (sceneZ <= 0.02)
        {
            tryFar = false;
            why = 7.0;
            break;
        }

        float bias = 0.025 + sceneZ * 0.0015;
        float thin = max(max(0.20, thickness * (1.0 + sceneZ * 0.014)), min(dt * 0.6, 1.2));

        if (rayZ > sceneZ + bias && rayZ < sceneZ + thin)
        {
            // Binary refinement of the crossing, in camera depth.
            float loT = prevT;
            float hiT = t;
            int2 bestQ = q;
            [unroll]
            for (int k = 0; k < 5; k++)
            {
                float midT = (loT + hiT) * 0.5;
                float3 midRel = S + R * midT - rpCam.xyz;
                float2 midOff = float2(0.0, 0.0);
                if (rpProjectFast(prk, pra, prb, midRel, midOff))
                {
                    int2 midQ = clamp(int2(round(float2(p) + midOff)), lo, hi);
                    float midScene = abs(ndcToRealDepth(rpDepthLoad(midQ), projParams)) * depthK;
                    if (dot(midRel, camFwd) > midScene + 0.01)
                    {
                        hiT = midT;
                        bestQ = midQ;
                    }
                    else
                    {
                        loT = midT;
                    }
                }
            }

            reflected = (streakPx > 1.5) ? rpStreakColor(bestQ, streakPx) : ((blurPx > 0) ? rpBlurColor(bestQ, blurPx) : rpLoadColor(bestQ));
            float distFade = 1.0 - smoothstep(maxDist * 0.72, maxDist, hiT);
            confidence = saturate(rpEdgeConf(bestQ) * distFade);
            result = (confidence > 0.001);
            why = 1.0;
            tryFar = false;
            break;
        }

        lastQ = q;
        haveLast = true;
        prevT = t;
    }

    // Ran out of distance (3) or steps (8) in front of far geometry: that geometry is the best guess.
    if ((why > 2.5 && why < 3.5) || why > 7.5)
    {
        if (haveLast)
        {
            escCol = rpBlurColor(lastQ, max(blurPx, 2));
            escConf = 0.55;
        }
    }

    if (tryFar)
    {
        result = rpSkyLookup(R, p, prk, pra, prb, maxDist, depthK, blurPx, streakPx, reflected, confidence);
        if (result) { why = 2.0; }
    }
    dbgInfo = float4(why, dbgRay, dbgScene, depthK);
    return result;
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

    // Standard far-plane clear pixels are not road receivers; preserve them exactly.
    // Do not invert depth: 0 is near and 1 is the far-plane clear value.
    const float sceneNdc = rpDepthLoad(rpClampPix(p));
    if (sceneNdc >= 0.99999)
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
    // Camera forward (view axis). cross(dyr, dxr) = down x right = BACKWARD for a right-handed world, which made every
    // SSR sample's view depth negative so the trace bailed out on its first step (flat sky-only puddles). The sign
    // is now taken from the pixel's own eye ray, which always points forward, so it is correct on any backend.
    float3 camFwd = normalize(cross(dxr, dyr));
    camFwd = (dot(camFwd, ray0) < 0.0) ? -camFwd : camFwd;

    float3 N = gb.xyz / max(length(gb.xyz), 1e-4);
    const float depth = gb.w;
    const float roughness = max(packedPrepass.z, 0.02);
    const float3 off = rpReconstruct(ray0, camFwd, depth, rpMode.y, rpMode.z);
    const float3 offX = rpReconstruct(ray0 + dxr, camFwd, depth, rpMode.y, rpMode.z);
    const float3 offY = rpReconstruct(ray0 + dyr, camFwd, depth, rpMode.y, rpMode.z);
    const float2 dPdx = (offX - off).xy;
    const float2 dPdy = (offY - off).xy;
    const float dist = length(off);
    const float3 P = rpCam.xyz + off;

    const float dbgMode = rpMode.x;
    const float dbgBright = max(rpLuma(col), 0.05) * 2.0 * rpMode.w;

    // ---- surface eligibility -------------------------------------------------------------
    // Do not use the input roughness to decide whether a surface can get wet:
    // the wet film is specifically allowed to override a road's roughness map.
    float flatness = smoothstep(0.60, 0.91, N.z);
    float3 cpos = max(col, 0.0);
    float mx = max(cpos.r, max(cpos.g, cpos.b));
    float green = saturate((cpos.g - max(cpos.r, cpos.b)) / max(mx, 1e-4) * 3.0);
    float vegetationGate = 1.0 - saturate(green * rpPuddleB.w);
    // 1.0: under a roof, a bridge or in a tunnel no rain falls: the ground there stays dry (no film, no puddles, no
    // reflections). Shelter grid from Lua (9 x 9 upward casts around the camera, rp_shelter.h.hlsl).
    const float covered = rpGroundCovered(P);
    float surfBase = flatness * vegetationGate * (1.0 - covered);
    // 0.7: wet ground and puddles are independent layers with their own on/off switch and distance.
    float fadeP = (1.0 - smoothstep(rpPuddleB.z * 0.55, rpPuddleB.z, dist)) * step(0.5, rpPuddleI.y);   // puddles
    float fadeR = (1.0 - smoothstep(rpPuddleI.w * 0.55, rpPuddleI.w, dist)) * step(0.5, rpPuddleI.x);   // wet ground
    float surf = surfBase * max(fadeP, fadeR);

    const float rain   = saturate(rpPuddleD.w);
    // Exact gate at zero. Strength still ramps continuously with rain below.
    const float rainOn = step(1e-6, rain);

    // Exact early-out: with zero surface weight (or no rain) every term below evaluates to the source colour,
    // so skipping the vehicle loop, ripples, SSR and composite is lossless. Debug views still run in full.
    if (dbgMode < 0.5 && (surf <= 0.002 || rainOn <= 0.0))
    {
        pfxOut[storePos] = src;
        return;
    }

    // Reject vehicle bodywork, but keep the ground under the car: a car's
    // shadow must not delete a puddle that is physically underneath it.
    float4 vA[12] = { rpVehA0, rpVehA1, rpVehA2, rpVehA3, rpVehA4, rpVehA5, rpVehA6, rpVehA7, rpVehA8, rpVehA9, rpVehA10, rpVehA11 };
    float4 vB[12] = { rpVehB0, rpVehB1, rpVehB2, rpVehB3, rpVehB4, rpVehB5, rpVehB6, rpVehB7, rpVehB8, rpVehB9, rpVehB10, rpVehB11 };
    float4 vC[12] = { rpVehC0, rpVehC1, rpVehC2, rpVehC3, rpVehC4, rpVehC5, rpVehC6, rpVehC7, rpVehC8, rpVehC9, rpVehC10, rpVehC11 };
    float4 vD[12] = { rpVehD0, rpVehD1, rpVehD2, rpVehD3, rpVehD4, rpVehD5, rpVehD6, rpVehD7, rpVehD8, rpVehD9, rpVehD10, rpVehD11 };
    float4 vG[12] = { rpVehG0, rpVehG1, rpVehG2, rpVehG3, rpVehG4, rpVehG5, rpVehG6, rpVehG7, rpVehG8, rpVehG9, rpVehG10, rpVehG11 };
    float onVehicle = 0.0;
    float dbgIn = 0.0;
    float dbgH  = -9.0;
    float dbgLowH = 0.0;
    [unroll]
    for (int i = 0; i < 12; i++)
    {
        float3 lp = float3(0.0, 0.0, 0.0);
        float inner = rpBoxInner(P, vA[i], vB[i], vC[i], vD[i], lp);
        if (inner > -0.20)
        {
            // Height above the vehicle's GROUND PLANE, evaluated per pixel in world space. Lua supplies the
            // plane every frame: height at the box centre (w) and slope dz/dx, dz/dy (xy), derived from the
            // lower face of the box (moves with the car, same space as the box) and nudged by a validated,
            // bounded ray cast. A single scalar ground height (the old code) was stale and slope-blind, which
            // marked the road inside the moving box as bodywork = the dry rectangle.
            float planeZ = vG[i].w + vG[i].x * (P.x - vA[i].x) + vG[i].y * (P.y - vA[i].y);
            float hAbove = (P.z - planeZ) * rsqrt(1.0 + vG[i].x * vG[i].x + vG[i].y * vG[i].y);
            // 0.7: the ground plane is accurate now (0.5 dry-box fix), so the car starts much lower: anything more
            // than 'Vehicle mask height' (rpPuddleJ.x, default 0.15 m) above the road inside the box is the car,
            // whatever its roughness (matte bumpers, diffusers, splitters, skirts were treated as road below 0.5 m).
            // Just below that, smooth (paint, glass) or non-flat surfaces are the car too; flat rough asphalt is not.
            float hm = max(rpPuddleJ.x, 0.03);
            float bodyLow  = smoothstep(hm * 0.45, hm, hAbove)
                           * max(1.0 - smoothstep(0.40, 0.58, roughness), 1.0 - smoothstep(0.55, 0.85, N.z));
            float bodyHigh = smoothstep(hm, hm + 0.10, hAbove);
            // 1.0: inside a car. Well inside its footprint (0.45 m in from the box sides) the road lies under the body
            // and cannot be seen, so a surface there that is clearly above the road is the car: its floor, seats and
            // dashboard, seen from the seat or through the glass (a low floor pan got puddles). With the camera in this
            // box (in-car views, vG.z from Lua) every surface inside the box is the car.
            float insetH = min(vA[i].w - abs(lp.x), vB[i].w - abs(lp.y));
            float lift = smoothstep(0.02, 0.06, hAbove);
            float bodyDeep = smoothstep(0.25, 0.45, insetH) * lift;
            float bodyCam = vG[i].z * step(0.0, inner) * lift;
            dbgIn = 1.0;
            dbgH  = max(dbgH, hAbove);
            dbgLowH = max(dbgLowH, bodyLow);
            onVehicle = max(onVehicle, max(max(bodyLow, bodyHigh), max(bodyDeep, bodyCam)));
        }
    }
    onVehicle *= step(0.5, rpPuddleE.z);   // 'Vehicle mask' diagnostic switch (Lua; default on)
    surf *= 1.0 - onVehicle;
    const float surfP = surfBase * fadeP * (1.0 - onVehicle);   // where puddles may form
    const float surfR = surfBase * fadeR * (1.0 - onVehicle);   // where the ground gets wet

    // ---- puddle mask + global asphalt film -------------------------------------------------------------------
    // Asphalt classifier: flat, low-chroma surfaces, excluding vegetation-like colors.
    float mn      = min(cpos.r, min(cpos.g, cpos.b));
    float chroma  = (mx - mn) / max(mx, 1e-4);
    float asphalt = (1.0 - smoothstep(0.22, 0.45, chroma)) * (1.0 - green);
    float globalW = surfR * asphalt * rainOn;

    // ---- roads only (0.8): puddles stay inside the lanes of the level's AI road network (width + height), so never on
    //      sand, grass, kerbs off the road, trees or a bridge above. rpPuddleK.z: 0 off, 1 road network (segment count
    //      in .w; 0 = no road here), 2 no road network on this level -> low-chroma, non-green surfaces only.
    float roadMask = 1.0;
    float roadsMode = rpPuddleK.z;
    if (roadsMode > 0.5 && surfP > 0.002)
    {
        if (roadsMode > 1.5)
        {
            roadMask = asphalt;
        }
        else
        {
            roadMask = 0.0;
            float4 rA[48] = { rpRoadA0, rpRoadA1, rpRoadA2, rpRoadA3, rpRoadA4, rpRoadA5, rpRoadA6, rpRoadA7, rpRoadA8, rpRoadA9, rpRoadA10, rpRoadA11, rpRoadA12, rpRoadA13, rpRoadA14, rpRoadA15, rpRoadA16, rpRoadA17, rpRoadA18, rpRoadA19, rpRoadA20, rpRoadA21, rpRoadA22, rpRoadA23, rpRoadA24, rpRoadA25, rpRoadA26, rpRoadA27, rpRoadA28, rpRoadA29, rpRoadA30, rpRoadA31, rpRoadA32, rpRoadA33, rpRoadA34, rpRoadA35, rpRoadA36, rpRoadA37, rpRoadA38, rpRoadA39, rpRoadA40, rpRoadA41, rpRoadA42, rpRoadA43, rpRoadA44, rpRoadA45, rpRoadA46, rpRoadA47 };
            float4 rB[48] = { rpRoadB0, rpRoadB1, rpRoadB2, rpRoadB3, rpRoadB4, rpRoadB5, rpRoadB6, rpRoadB7, rpRoadB8, rpRoadB9, rpRoadB10, rpRoadB11, rpRoadB12, rpRoadB13, rpRoadB14, rpRoadB15, rpRoadB16, rpRoadB17, rpRoadB18, rpRoadB19, rpRoadB20, rpRoadB21, rpRoadB22, rpRoadB23, rpRoadB24, rpRoadB25, rpRoadB26, rpRoadB27, rpRoadB28, rpRoadB29, rpRoadB30, rpRoadB31, rpRoadB32, rpRoadB33, rpRoadB34, rpRoadB35, rpRoadB36, rpRoadB37, rpRoadB38, rpRoadB39, rpRoadB40, rpRoadB41, rpRoadB42, rpRoadB43, rpRoadB44, rpRoadB45, rpRoadB46, rpRoadB47 };
            int count = int(rpPuddleK.w + 0.5);
            [unroll]
            for (int si = 0; si < 48; si++)
            {
                if (si < count)
                {
                    float2 ab = rB[si].xy - rA[si].xy;
                    float tS = saturate(dot(P.xy - rA[si].xy, ab) / max(dot(ab, ab), 1e-4));
                    float dS = length(P.xy - (rA[si].xy + ab * tS));
                    float rS = lerp(rA[si].w, rB[si].w, tS);                 // half width of the road here
                    float zS = lerp(rA[si].z, rB[si].z, tS);                 // road height here
                    float m = (1.0 - smoothstep(rS - 0.25, rS + 0.35, dS)) * (1.0 - smoothstep(1.0, 2.2, abs(P.z - zS)));
                    roadMask = max(roadMask, m);
                }
            }
        }
    }
    const float surfPR = surfP * roadMask;   // where puddles may form

    float  shape = 0.5, puddle = 0.0, damp = 0.0, depthP = 0.0;
    float2 rip = float2(0, 0);
    float2 grad = float2(0, 0);

    if (surfPR > 0.002 && rainOn > 0.0)
    {
        float tile = max(rpPuddleA.w, 2.0);
        float fp   = max(length(dPdx), length(dPdy)) / tile;
        float2 uvA = P.xy / tile;
        float2 uvB = float2(P.x * 0.8660254 - P.y * 0.5, P.x * 0.5 + P.y * 0.8660254) / (tile * 0.57) + float2(0.37, 0.61);

        float nA = rpSampleField(maskTexA, uvA, fp);
        float nB = rpSampleField(maskTexB, uvB, fp * 1.75);

        float cov      = saturate(rpPuddleA.x);
        float sizeWarp = lerp(0.58, 1.34, saturate(rpPuddleC.y));
        shape          = saturate(0.5 + (nA - 0.5) / max(sizeWarp, 0.1));
        float cut      = (1.0 - cov) + (nB - 0.5) * 0.32 * min(cov * 4.0, 1.0);
        float soft     = max(rpPuddleB.x, 0.004);
        puddle = smoothstep(cut, cut + soft, shape);
        damp   = smoothstep(cut - 0.14, cut, shape) * 0.55;
        depthP = smoothstep(cut, cut + 0.22, shape);   // 0.8 water depth proxy: shallow rim, deep centre

        // Rain ripples, the 0.3 look: rings over all standing water, faded by distance only, limited to the puddle
        // mask (0.7), and only while it actually rains (0.8: rpPuddleK.y = current rain; puddles stay after the rain).
        float pwR = puddle * surfPR;
        if (pwR > 0.01)
        {
            float inPuddle = smoothstep(0.02, 0.35, pwR);
            float rainNow = saturate(rpPuddleK.y);
            if (rpPuddleB.y > 0.001 && rainNow > 0.001)
            {
                float rf = (1.0 - smoothstep(20.0, 85.0, dist)) * inPuddle * smoothstep(0.0, 0.15, rainNow) * (0.45 + 0.55 * rainNow);
                rip = rpRipples(P.xy, rpCam.w) * rpPuddleB.y * rf;
            }
            // 0.3 puddle-field slope: the rim of each puddle bends the reflection like a real water edge.
            float eps = max(0.035, tile * 0.0028);
            float nXp = rpSampleField(maskTexA, uvA + float2(eps / tile, 0.0), fp);
            float nYp = rpSampleField(maskTexA, uvA + float2(0.0, eps / tile), fp);
            grad = float2(nXp - nA, nYp - nA) * 0.26 * inPuddle;
        }
    }

    // ---- tyre wakes (0.9) ----------------------------------------------------------------------------------------
    // Every tyre (rpTyreA/B/C, also traffic) disturbs the water it rolls through, in the tyre's own frame like a boat's
    // wake: a churned band as wide as the tyre behind the contact patch (tread + spin), two diverging bow waves from
    // the tyre shoulders (narrower as the speed rises), rings around a spinning tyre (burnout / wheelspin), and a short
    // trough where the tyre pushed the water aside. The slopes join the rain ripples, so they bend the reflection,
    // shimmer the bed and catch light the same way - but only where there is standing water.
    float trackDry = 0.0;
    float2 wakeSlope = float2(0.0, 0.0);
    if (rpPuddleM.x > 0.001 && rpPuddleM.y > 0.5 && (puddle * surfPR > 0.005 || globalW > 0.005))
    {
        float4 tA[8] = { rpTyreA0, rpTyreA1, rpTyreA2, rpTyreA3, rpTyreA4, rpTyreA5, rpTyreA6, rpTyreA7 };
        float4 tB[8] = { rpTyreB0, rpTyreB1, rpTyreB2, rpTyreB3, rpTyreB4, rpTyreB5, rpTyreB6, rpTyreB7 };
        float4 tC[8] = { rpTyreC0, rpTyreC1, rpTyreC2, rpTyreC3, rpTyreC4, rpTyreC5, rpTyreC6, rpTyreC7 };
        const float tNow = rpCam.w;
        [unroll]
        for (int ti = 0; ti < 8; ti++)
        {
            if (tC[ti].y > 0.5)
            {
                float2 dT = P.xy - tA[ti].xy;
                float reachW = 2.0 + tB[ti].z * 0.35;
                if (dot(dT, dT) < reachW * reachW && abs(P.z - tA[ti].z) < 0.45)
                {
                    float2 dirT = tB[ti].xy;
                    float2 sideT = float2(-dirT.y, dirT.x);
                    float sT = -dot(dT, dirT);                     // metres behind the contact patch
                    float wT = dot(dT, sideT);                     // metres to the side
                    float awT = abs(wT);
                    float hwT = tA[ti].w;
                    float gT = tB[ti].z;                           // ground speed
                    float trT = tB[ti].w;                          // tread speed
                    float spinK = saturate(abs(trT - gT) / 5.0);   // wheelspin / sliding
                    float moveK = saturate(gT / 6.0);
                    float sP = max(sT, 0.0);
                    // 1. churned band behind the tyre, as wide as the tread
                    float band = (1.0 - smoothstep(hwT * 0.8, hwT * 1.3, awT)) * smoothstep(-0.25, 0.02, sT)
                               * exp(-sP / (0.5 + 0.10 * gT));
                    // turbulent chop: gradient of two octaves of value noise, scrolled by the tread
                    float chop = 0.0;
                    float2 chopG = float2(0.0, 0.0);
                    if (band > 0.002)
                    {
                        float2 pn = float2(sT * 9.0 + tNow * (1.5 + trT * 0.9), wT * 9.0 + float(ti) * 7.3);
                        float n0 = rpValueNoise(pn) + 0.5 * rpValueNoise(pn * 2.3 + 5.1);
                        float nx = rpValueNoise(pn + float2(0.25, 0.0)) + 0.5 * rpValueNoise((pn + float2(0.25, 0.0)) * 2.3 + 5.1);
                        float ny = rpValueNoise(pn + float2(0.0, 0.25)) + 0.5 * rpValueNoise((pn + float2(0.0, 0.25)) * 2.3 + 5.1);
                        chopG = float2(nx - n0, ny - n0) * 6.0;              // in (behind, side)
                        chop = 1.0;
                    }
                    float2 chopW = (-dirT * chopG.x + sideT * chopG.y) * chop;
                    // 2. diverging bow waves from both shoulders
                    float ta = lerp(0.55, 0.16, saturate(gT / 25.0));
                    float qT = awT - hwT - sP * ta;                // lateral distance to the crest line
                    float envT = exp(-qT * qT / (0.012 + 0.006 * sP)) * smoothstep(-0.1, 0.15, sT) * exp(-sP / (1.2 + 0.12 * gT));
                    float crest = sin(qT * 55.0 - tNow * 5.0) * envT * moveK;
                    float2 nW = normalize(float2(-ta, 1.0));       // crest normal in (behind, side)
                    // 3. rings around a spinning tyre
                    float rT = length(dT);
                    float ring = sin(rT * 42.0 - tNow * (7.0 + trT)) * exp(-rT / 0.45) * spinK;
                    wakeSlope += chopW * (band * (0.35 * moveK + 0.6 * spinK))
                               + (-dirT * nW.x + sideT * (nW.y * ((wT >= 0.0) ? 1.0 : -1.0))) * (crest * 0.9)
                               + (dT / max(rT, 1e-3)) * (ring * 0.7);
                    // 4. trough: right behind the tyre the water is pushed aside
                    trackDry = max(trackDry, band * saturate(0.35 + 0.5 * moveK) * exp(-sP / (0.35 + 0.05 * gT)));
                }
            }
        }
        wakeSlope *= rpPuddleM.x;
        trackDry = saturate(trackDry * rpPuddleM.x);
        rip += wakeSlope * smoothstep(0.02, 0.35, puddle * surfPR);   // waves only where there is standing water
        puddle *= 1.0 - 0.8 * trackDry;
        damp *= 1.0 - 0.5 * trackDry;
    }

    // Layers. GROUND (rpPuddleE.x strength, rpPuddleF roughness/darkening/normal/wetness, rpPuddleG/H trace) and
    // PUDDLES (rpPuddleA/B/C/D) have their own settings. 0.8: the ground also gets more puddle-like as it gets wetter:
    // 'flood' (rpPuddleK.x, from Lua: 0 = wet asphalt .. 1 at full rain = exactly the puddle settings). Every per-layer
    // value below is blended by 'pe' = how puddle-like this pixel is (1 in puddles, flood on the wet open road).
    float puddleW   = puddle * surfPR;
    float puddleWet = max(puddle, damp) * surfPR;                    // standing water + its damp rim
    float roadRefK  = saturate(rpPuddleE.x);                         // ground 'Reflection strength'
    float flood     = saturate(rpPuddleK.x);
    float filmBase  = globalW * pow(rain, 0.6) * saturate(rpPuddleF.w);
    // Ground patchiness has its OWN pattern and scale (0.7): puddle coverage / size / pattern do not change it.
    float shapeR = 0.5;
    if (filmBase > 0.002 && rpPuddleG.x > 0.001)
    {
        float tileR = max(rpPuddleI.z, 2.0);
        float fpR = max(length(dPdx), length(dPdy)) / tileR;
        float2 uvR = float2(P.x * 0.6 + P.y * 0.8, P.y * 0.6 - P.x * 0.8) / tileR + float2(0.71, 0.13);
        shapeR = rpSampleField(maskTexB, uvR, fpR);
    }
    float film      = filmBase * lerp(1.0, lerp(0.55, 1.0, shapeR), saturate(rpPuddleG.x) * (1.0 - flood))
                    * (1.0 - 0.5 * trackDry);                        // tyres squeeze the film out of their track
    float wet       = max(puddleWet, film);
    float fieldDbg  = shape;
    // rpPuddleE.w = 1 when the engine's own PBR/SSR path carries the wet-road film (road materials made smoother by
    // rainPuddlesWet.lua). The shader then does not draw a second road reflection - except as the ground floods:
    // the puddle-like reflection of a flooded road is drawn here, so ground and puddles match 1:1 at full rain.
    float nativeFilm = saturate(rpPuddleE.w);
    float filmOwn    = film * max(1.0 - nativeFilm, flood);
    float pe         = max(smoothstep(0.0, 0.8, puddleW), flood * smoothstep(0.05, 0.6, film));

    // Puddle bed seen through rippling water (0.8): the ripple slope shifts what lies under the water.
    if (dot(rip, rip) > 1e-7)
    {
        int2 qb = p + int2(round(rip * float2(1.0, -1.0) * (28.0 * saturate(depthP * 1.5))));
        col = lerp(col, colorTex.Load(int3(rpClampPix(qb), 0)).rgb, saturate(puddleW * 1.2));
    }

    // Roughness. Wet road: the pixel's dry roughness scaled by 'Roughness when wet' (the same fraction the native path
    // writes into the road materials), going to the water roughness as it floods. With the native film the G-buffer
    // already holds the wet value, so it is not scaled twice. Deep water is a flat mirror, the shallow rim keeps some
    // texture. Tyre-mark gloss: 1 = use each pixel's own roughness, 0 = treat all asphalt as one typical roughness.
    float roughIn     = lerp(0.75, saturate(roughness), saturate(rpPuddleE.y));
    float waterFloor  = saturate(rpPuddleC.x) * 0.5;
    float roadWet     = lerp(max(roughIn * clamp(rpPuddleF.x, 0.05, 1.0), 0.03), waterFloor, flood);
    float surfRough   = lerp(roughIn, roadWet, saturate(filmOwn));
    float puddleRough = saturate(lerp(surfRough, waterFloor, smoothstep(0.0, 0.8, puddleW) * lerp(0.6, 1.0, depthP)));

    // Normal detail: how much of the road's own normal map shows through (ground 0.55, puddles 0.08 by default).
    float3 Nflat = normalize(lerp(N, float3(0, 0, 1), saturate(flatness)));
    float  keep  = clamp(lerp(rpPuddleF.z, rpPuddleC.w, pe) * 1.8, 0.0, 3.6);
    float3 Nb    = normalize(Nflat + (N - Nflat) * keep);
    float3 T = normalize(cross(float3(0, 0, 1), Nb) + float3(1e-5, 0, 0));
    float3 B = normalize(cross(Nb, T));
    float3 Np = normalize(Nb + (T * rip.x + B * rip.y) * 0.055 + (T * grad.x + B * grad.y) * 0.055);

    float3 V     = normalize(P - rpCam.xyz);
    float  NdotV = saturate(dot(Np, -V));
    float  F     = rpFresnel(0.02, NdotV);
    float3 R     = reflect(V, Np);

    // Per-layer trace / fallback settings, blended by pe.
    float skyK   = lerp(rpPuddleG.y, rpPuddleC.z, pe);
    float blurK  = lerp(rpPuddleG.z, rpPuddleD.x, pe);
    float thickK = lerp(rpPuddleG.w, rpPuddleD.z, pe);

    // Reflectance. Water is a dielectric (F0 = 0.02): seen from above a puddle mostly shows its dark bed and only
    // becomes a mirror toward grazing angles; 'Reflectivity' boosts it toward a mirror (1 = mirror). The ground uses its
    // own 'Reflection strength' and turns into exactly the puddle reflectance as it floods.
    float rm         = saturate(rpPuddleA.z);
    float puddleRefl = lerp(F, 0.97, rm * rm * rm * rm);
    // 1.0: wet asphalt reflects mostly toward grazing angles (water F0 = 0.02) with only a faint sheen straight down; the
    // old 4-16 % reflectance at every angle washed out the asphalt right in front of the car.
    float roadRefl   = (lerp(0.012, 0.05, roadRefK) + lerp(0.85, 1.15, roadRefK) * F) * saturate(roadRefK * 4.0) * 0.92;
    float groundRefl = lerp(roadRefl, puddleRefl, flood);
    // (The asphalt's own look comes through the per-pixel roughness from the G-buffer, i.e. the road's roughness map, and
    // the normal detail. A luminance-contrast trick tried here read the image that already holds the game's reflection
    // and turned its noise into speckles, so it is gone.)
    float reflW      = saturate(lerp(groundRefl * filmOwn, puddleRefl, puddleW) * (1.0 - 0.35 * puddleRough));

    // Experimental stochastic glossy reflections (0.8, rpPuddleL.y): one GGX-sampled ray per pixel and frame instead of
    // a blur. This pass runs before BeamNG's temporal upscaler / AA, which averages the noise over frames (the same
    // idea as the engine's stochastic SSR, without its dedicated denoiser).
    float3 Rt = R;
    float blurT = blurK;
    if (rpPuddleL.y > 0.5 && puddleRough > 0.06 && reflW > 0.02)
    {
        uint hS = rpHash3(int3(p.x, p.y, int(rpPuddleL.z) + 977));
        float u1 = rpRand(hS);
        float u2 = rpRand(rpPcg(hS ^ 0x68E31DA4u));
        float a = puddleRough * puddleRough;
        float th = atan(a * sqrt(u1 / max(1.0 - u1, 1e-4)));
        float ph = 6.2831853 * u2;
        float3 Hm = normalize(T * (sin(th) * cos(ph)) + B * (sin(th) * sin(ph)) + Np * cos(th));
        float3 Rs = reflect(V, Hm);
        if (dot(Rs, Np) > 0.01)
        {
            Rt = Rs;
            blurT = 0.0;
        }
    }

    // Light streaks (0.8, rpPuddleL.x): wet asphalt stretches the reflections of lights vertically (anisotropic
    // microfacets seen at a grazing angle). Longer on rough ground and at grazing views, short on deep flat water.
    float streakPx = rpPuddleL.x * 70.0 * saturate(puddleRough * 2.2) * (1.0 - NdotV) * (dispatchRect.w / 1080.0);

    // ---- what a reflection shows when the trace misses (0.6.2) ----------------------------------------------------
    // Query direction clamped above the horizon so exiting rays never sample the dark ground lobe of the ambient.
    float3 Rsky = normalize(float3(Rt.xy, max(Rt.z, 0.05)));
    // Ambient sky: evalSHIrradiance is a cosine-weighted (diffuse) value; a mirror sees radiance along R, which for a
    // smooth sky is about irradiance / pi. 0.6.1 used it unscaled -> flat white puddles in daylight.
    float3 skyAmb = rpSkyColor(Rsky) * 0.318;
    // Visible-sky probe, only where a reflection is actually drawn (and for debug view 7).
    float probeConf = 0.0;
    float3 skyScr = skyAmb;
    if (reflW > 0.01 || (dbgMode > 6.5 && dbgMode < 7.5))
    {
        skyScr = rpScreenSky(Rsky, p, ray0, dxr, dyr, probeConf);
    }
    // Fallback mode per layer (ground rpPuddleH.y, puddles rpPuddleH.z): 0 visible sky + scene edges, 1 ambient sky,
    // 2 none (only real hits reflect).
    float fbMode = lerp(rpPuddleH.y, rpPuddleH.z, pe);
    float wScr   = saturate(1.0 - fbMode);
    float wAmb   = saturate(1.0 - abs(fbMode - 1.0));
    float wNone  = saturate(fbMode - 1.0);
    float3 sky   = (lerp(skyAmb, skyScr, probeConf) * wScr + skyAmb * wAmb) * skyK;

    // Depth-unit calibration. The scene depth used by the trace comes from ndcToRealDepth(); the pixel's own true
    // eye depth is known from the reconstruction (the same one that anchors the puddle mask). If the two disagree by
    // more than 12% (e.g. the helper returns a normalised value, not metres) the ratio is applied to every sample.
    float depthK = dot(off, camFwd) / max(abs(ndcToRealDepth(sceneNdc, projParams)), 1e-4);
    depthK = (abs(depthK - 1.0) < 0.12) ? 1.0 : clamp(depthK, 0.001, 10000.0);

    float3 ssrCol  = float3(0, 0, 0);
    float  ssrConf = 0.0;
    float  ssrW    = 0.0;
    float3 escCol  = float3(0, 0, 0);
    float  escConf = 0.0;
    float4 dbgInfo = float4(0.0, 0.0, 0.0, 0.0);
    if (reflW > 0.02)
    {
        // Puddles use the puddle step budget, the open road the ground-film budget; distant pixels need fewer steps.
        float layerDist = lerp(rpPuddleI.w, rpPuddleB.z, pe);        // ground / puddle effect distance
        float distK = 1.0 - 0.35 * saturate(dist / max(layerDist, 1.0));
        int steps = (int)clamp(lerp(rpPuddleH.x, rpPuddleD.y, saturate(max(puddleW * 2.0, pe))) * distK, 8.0, 48.0);
        float3 Sx = P + Np * 0.025;
        float3 prk = float3(0.0, 0.0, 0.0);
        float3 pra = float3(0.0, 0.0, 0.0);
        float3 prb = float3(0.0, 0.0, 0.0);
        rpMakeProj(ray0, dxr, dyr, prk, pra, prb);
        if (rpTraceReflection(Sx, Rt, p, prk, pra, prb, camFwd, steps,
                              min(layerDist, 90.0), thickK, puddleRough, blurT, depthK, streakPx,
                              ssrCol, ssrConf, escCol, escConf, dbgInfo))
        {
            ssrW = saturate(ssrConf);
        }
    }
    ssrW *= 1.0 - smoothstep(0.55, 0.90, puddleRough);   // rough lobe -> stable sky only
    ssrW  = ssrW * ssrW * (3.0 - 2.0 * ssrW);            // smooth handoff, no edge pop
    // Miss: extend with what the ray last saw on screen (mode 0 only), else the sky estimate.
    float3 fallback = lerp(sky, escCol * skyK, saturate(escConf) * wScr);
    // 1.0 'Surroundings' fallback: where the capture of the real scene above the camera covers the ray, it replaces the
    // sky estimate (tree crowns, bridges, tunnel roofs and buildings instead of open sky); outside it the above stays.
    float envW = saturate(lerp(rpPuddleN.x, rpPuddleN.y, pe));
    float4 envS = float4(0.0, 0.0, 0.0, 0.0);
    if (envW > 0.01 && (reflW > 0.01 || (dbgMode > 17.5 && dbgMode < 18.5)))
    {
        envS = rpEnvSample(P + Np * 0.025, Rt, rpPuddleN.z * (1.0 + 6.0 * puddleRough * blurT));
        fallback = lerp(fallback, envS.rgb * skyK, envS.a * envW);
    }
    float3 refl = lerp(fallback, ssrCol, ssrW);
    // Mode 2: a miss reflects nothing (the puddle just shows its wet bed).
    float reflVis = lerp(1.0 - wNone, 1.0, ssrW);
    reflW *= reflVis;

    // Composite: darkening first, reflection after, so shadows cannot erase the sheen. Darkening and the cool water
    // tint come from each layer's own slider (puddles rpPuddleA.y, ground rpPuddleF.y -> the puddle value as it floods);
    // deep water is a little darker than the rim. The ground darkening also applies when the native film reflects.
    float darkGround = lerp(saturate(rpPuddleF.y), saturate(rpPuddleA.y), flood);
    float darkP = saturate(rpPuddleA.y) * puddleWet * lerp(0.85, 1.15, depthP);
    float darkR = darkGround * film;
    float dark  = max(darkP, darkR);
    float tintW = max(puddleWet * saturate(rpPuddleA.y * 3.0), film * saturate(darkGround * 3.0));
    col *= 1.0 - 0.42 * saturate(dark);
    col  = lerp(col, col * float3(0.80, 0.86, 0.90), saturate(tintW * 0.65));
    col *= 1.0 - 0.10 * reflW;
    col  = lerp(col, refl, reflW);
    col += refl * (0.055 * max(puddleWet, filmOwn * lerp(saturate(roadRefK * 2.5), 1.0, flood)) * saturate(skyK) * reflVis);
    if (reflW > 0.01)
    {
        float sheen = pow(saturate(dot(R, normalize(float3(0.2, 0.35, 0.8)))), 24.0);
        col += sky * (0.02 * sheen * wet * (1.0 - wNone));
    }
    // Ripple rings catch a little light even when the puddle reflects a plain sky (puddles only; 1.0: near the camera
    // only, further away the bright outlines read as rings painted on the road).
    float ringK = saturate(length(rip) * 5.0) * smoothstep(0.02, 0.35, puddleW) * (1.0 - smoothstep(8.0, 25.0, dist));
    col += lerp(refl, sky, 0.3) * (ringK * 0.08 * reflVis);

    // ---- debug views ---------------------------------------------------------------------
    if (dbgMode > 0.5)
    {
        if (dbgMode < 1.5)
        {
            float2 g1 = abs(frac(P.xy) - 0.5);
            float2 g10 = abs(frac(P.xy / 10.0) - 0.5);
            float l1 = step(0.47, max(g1.x, g1.y));
            float l10 = step(0.495, max(g10.x, g10.y));
            float on = step(0.8, N.z) * step(dist, 120.0);
            col = lerp(col, float3(1.0, 0.0, 1.0) * dbgBright, l1 * on);
            col = lerp(col, float3(0.0, 1.0, 1.0) * dbgBright, l10 * on);
        }
        else if (dbgMode < 2.5)
        {
            col = (N * 0.5 + 0.5) * dbgBright;
        }
        else if (dbgMode < 3.5)
        {
            col = float3(fieldDbg, fieldDbg, fieldDbg) * dbgBright * (0.3 + 0.7 * surfP);
        }
        else if (dbgMode < 4.5)
        {
            float ring = frac(dist / 5.0);
            col = float3(ring, 1.0 - ring, step(0.5, ring)) * dbgBright;
        }
        else if (dbgMode > 5.5 && dbgMode < 6.5)
        {
            col = lerp(float3(0, 0, 0), ssrCol, saturate(ssrConf)) * dbgBright;
        }
        else if (dbgMode > 6.5 && dbgMode < 7.5)
        {
            col = fallback * dbgBright;   // what a missed reflection shows (sky probe / edge / ambient)
        }
        else if (dbgMode > 17.5 && dbgMode < 18.5)
        {
            // Surroundings capture as the reflections read it: the captured scene where a ray is covered, dark red
            // where the capture has no coverage (too low an angle) or is switched off.
            col = lerp(float3(0.25, 0.02, 0.02) * dbgBright, envS.rgb, envS.a);
        }
        else if (dbgMode > 12.5 && dbgMode < 13.5)
        {
            // Why each SSR ray ended:  GREEN hit | CYAN escaped to far field and found sky | RED behind camera / projection
            // failed | MAGENTA left the screen | YELLOW crossed a sky pixel, far lookup failed | ORANGE scene depth <= 0
            // BLUE escaped past max distance, far lookup failed | WHITE ran out of steps | dark grey = SSR not run here.
            float w = dbgInfo.x;
            if (w > 0.5)
            {
                float3 tint = (w < 1.5) ? float3(0.0, 1.0, 0.0)
                            : (w < 2.5) ? float3(0.0, 1.0, 1.0)
                            : (w < 3.5) ? float3(0.0, 0.2, 1.0)
                            : (w < 4.5) ? float3(1.0, 0.0, 0.0)
                            : (w < 5.5) ? float3(1.0, 0.0, 1.0)
                            : (w < 6.5) ? float3(1.0, 1.0, 0.0)
                            : (w < 7.5) ? float3(1.0, 0.5, 0.0)
                            :             float3(1.0, 1.0, 1.0);
                col = tint * 1.2;
            }
        }
        else if (dbgMode > 13.5 && dbgMode < 14.5)
        {
            // Depth units at march step 3: R = ray depth/100 m, G = scene depth/100 m, B = calibration factor/10.
            // A healthy trace has R and G of similar size where the ray is near the surface it is about to meet.
            if (dbgInfo.x > 0.5)
            {
                col = float3(saturate(dbgInfo.y * 0.01), saturate(dbgInfo.z * 0.01), saturate(dbgInfo.w * 0.1)) * 1.5;
            }
        }
        else if (dbgMode > 11.5 && dbgMode < 12.5)
        {
            // Per-pixel numbers behind the mask, inside a vehicle box (+20 cm) only:
            //   R = height above the ground plane (full red = 0.6 m or more)   -> high on road = P.z / plane error
            //   G = roughness from the G-buffer                                -> low on road = smooth-surface cue fooled
            //   B = N.z (surface up-ness)
            // Road should read: R ~ 0 (dark), G high (>0.6), B high. Anything else names the culprit.
            if (dbgIn > 0.5)
            {
                col = float3(saturate(dbgH / 0.6), saturate(roughness), saturate(N.z)) * 1.5;
            }
        }
        else if (dbgMode > 10.5 && dbgMode < 11.5)
        {
            // Mask truth view: only pixels inside a vehicle box (+20 cm) are tinted by their height above the
            // vehicle ground plane. blue = below plane, GREEN = road (correct), yellow = just below the mask height,
            // RED = treated as the car (at or above 'Vehicle mask height').
            // Road that is yellow/red = ground plane too low (dry box). Bodywork that is green = plane too high.
            if (dbgIn > 0.5)
            {
                float hmD = max(rpPuddleJ.x, 0.03);
                float3 tint = (dbgH < -0.05)      ? float3(0.0, 0.3, 2.0)
                            : (dbgH < hmD * 0.45) ? float3(0.0, 2.0, 0.2)
                            : (dbgH < hmD)        ? float3(2.0, 1.6, 0.0)
                            :                       float3(2.0, 0.0, 0.0);
                col = lerp(col, tint * max(rpLuma(col), 0.08), 0.75);
            }
        }
        else if (dbgMode > 9.5 && dbgMode < 10.5)
        {
            // Build check: magenta/cyan stripes along the top mean THIS shader version is running.
            // Lower band: red = surface treated as vehicle bodywork, green = road.
            if (p.y < 64)
            {
                col = (((p.x / 32) % 2) == 0) ? float3(2.0, 0.0, 2.0) : float3(0.0, 2.0, 2.0);
            }
            else
            {
                col = lerp(float3(0.0, 0.6, 0.1), float3(1.5, 0.0, 0.0), saturate(onVehicle)) * (0.25 + 0.75 * saturate(dbgBright));
            }
        }
    }

    pfxOut[storePos] = float4(col, src.a);
}
