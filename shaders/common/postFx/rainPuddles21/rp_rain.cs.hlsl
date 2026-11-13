#define PFX_COMPUTE 1

#include "rp_rain.h.hlsl"
#include "shaders/common/postFx/postFxCompute.h.hlsl"

// Falling rain (1.0). Replaces BeamNG's Precipitation particles, whose thousands of CPU-simulated drops cost a lot of
// frame time. Every pixel walks its view ray through two grids of cells that fall with the rain (0.5 m cells up to 5 m
// from the camera, 1.25 m cells beyond): each cell holds at most one drop, so the rain has real depth and parallax,
// never swims with the camera and is hidden behind anything closer (depth buffer). A drop is drawn as the streak it
// makes relative to the camera during a 1/60 s exposure: straight down when parked, rushing at the windshield when
// driving, slanted by the wind. No drops under roofs, bridges and in tunnels (9 x 9 upward ray casts from Lua) or inside
// the player's car. Cost: at most 18 + 24 cells per pixel.
// 1.0 look: a raindrop is a tiny ball lens. It shows the scene around it bent and upside down (refraction) and a little
// of the sky: 80 % refracted scene, 20 % sky, desaturated (it never amplifies the colours behind it). So most drops are
// a faint ripple in what lies behind them rather than white lines; near drops are out of focus (soft, never sharp) and
// the ends of a streak fade out.

static const int RP_NEAR_STEPS = 18;
static const int RP_FAR_STEPS = 24;
static const float RP_NEAR_END = 5.0;

bool rpInPlayerCar(float3 w)
{
    if (rpRainF.w < 0.5)
    {
        return false;
    }
    float3 d = w - rpRainF.xyz;
    return abs(dot(d, rpRainG.xyz)) < rpRainG.w && abs(dot(d, rpRainH.xyz)) < rpRainH.w && abs(dot(d, rpRainI.xyz)) < rpRainI.w;
}

// One grid of falling drops: walks the cells the view ray crosses between tA and tB (Amanatides-Woo), front to back.
// q0 = camera in the grid's falling frame, cs = cell size, fadeEnd = distance where the drops have faded out.
// accA = coverage so far (front to back); accO = coverage-weighted sums of the refraction offset (xy, pixels), of how
// much of it came from drops smaller than a pixel (z) and of their distance (w). ex / ey: world directions of +x / +y on
// screen (unit), pixAng: radians per pixel.
void rpRainGrid(float3 q0, float3 rd, float cs, float tA, float tB, float fadeEnd, float sceneT, float pixAng, int maxSteps,
                float3 streak, float dropR, float prob, float vis, float3 ex, float3 ey, inout float accA, inout float4 accO)
{
    if (tB <= tA)
    {
        return;
    }
    // the streak (head -> tail) has to fit in its cell, so no drop crosses into a cell the ray does not test
    const float margin = 0.02;
    float lmax = max(max(abs(streak.x), abs(streak.y)), abs(streak.z));
    float3 L = streak * min(1.0, (cs - 2.0 * margin) * 0.95 / max(lmax, 1e-5));
    float lenL = length(L);
    float3 rdS = float3(abs(rd.x) < 1e-6 ? 1e-6 : rd.x, abs(rd.y) < 1e-6 ? 1e-6 : rd.y, abs(rd.z) < 1e-6 ? 1e-6 : rd.z);
    int3 stp = int3(rdS.x > 0.0 ? 1 : -1, rdS.y > 0.0 ? 1 : -1, rdS.z > 0.0 ? 1 : -1);
    float3 p = q0 + rd * tA;
    int3 cell = int3(floor(p / cs));
    float3 up = float3(stp.x > 0 ? 1.0 : 0.0, stp.y > 0 ? 1.0 : 0.0, stp.z > 0 ? 1.0 : 0.0);
    float3 tNext = tA + ((float3(cell) + up) * cs - p) / rdS;
    float3 tDelta = cs / abs(rdS);
    float t = tA;
    [loop]
    for (int i = 0; i < maxSteps; i++)
    {
        if (t > tB || accA > 0.98)
        {
            break;
        }
        uint h = rpHash3(cell & 1023);                          // periodic over 1024 cells, so the wrapped camera is seamless
        if (rpRand(h) < prob)
        {
            uint h1 = rpPcg(h ^ 0x1B873593u);
            uint h2 = rpPcg(h1 ^ 0xE6546B64u);
            float3 r = float3(float(h1 & 0xFFFFu), float(h1 >> 16), float(h2 & 0xFFFFu)) / 65535.0;
            float rs = float(h2 >> 16) / 65535.0;
            float3 lo = float3(cell) * cs + margin - min(L, 0.0);
            float3 hi = float3(cell + 1) * cs - margin - max(L, 0.0);
            float3 head = lo + (hi - lo) * r;
            // closest approach of the view ray and the streak segment
            float3 w0 = q0 - head;
            float b = dot(rd, L);
            float c2 = dot(L, L);
            float d = dot(rd, w0);
            float e = dot(L, w0);
            float den = c2 - b * b;
            float s = (den > 1e-9) ? saturate((e - b * d) / den) : 0.0;
            float tt = b * s - d;
            if (tt > 0.3 && tt < sceneT)
            {
                float3 dv = w0 + rd * tt - L * s;                 // from the drop's axis to the view ray
                float dist = length(dv);
                float rD = dropR * lerp(0.55, 1.45, rs);
                // near drops are out of focus (eyes and cameras focus farther away): wider and fainter, never sharp;
                // at least about a pixel wide, fainter instead
                float defoc = 0.0022 * saturate(1.0 - tt / 6.0);
                float wE = max(max(rD, defoc), tt * pixAng);
                float cov = 1.0 - smoothstep(0.0, 1.25 * wE, dist);
                cov = cov * cov * 1.4 * (rD / wE);
                if (cov > 0.002)
                {
                    float3 wp = rpCam.xyz + rd * tt;
                    if (wp.z > rpRoofZ(wp.xy) && !rpInPlayerCar(wp))
                    {
                        // a long streak is a fast drop smeared over the exposure: fainter, and its ends fade out
                        float blur = lerp(0.35, 1.0, saturate(24.0 * rD / (2.0 * rD + lenL)));
                        float longK = saturate(lenL / (lenL + 8.0 * rD));
                        float taper = lerp(1.0, 0.3 + 0.7 * sin(3.14159 * s), longK);
                        float fade = smoothstep(0.3, 0.9, tt) * (1.0 - smoothstep(fadeEnd * 0.7, fadeEnd, tt));
                        float a = saturate(vis * cov * blur * taper * fade);
                        // ball lens (n = 1.33): a ray through the drop at b (0 centre .. 1 rim) is bent by
                        // 2 (asin b - asin(b / n)) and comes from the other side (the image is upside down)
                        float bq = saturate(dist / max(rD, 1e-6));
                        float dev = 2.0 * (asin(bq) - asin(bq * 0.75));
                        float3 dn = dv / max(dist, 1e-7);
                        // (the full bend would show what lies far off screen; kept to a short, on-screen offset)
                        float2 off = clamp(-float2(dot(dn, ex), dot(dn, ey)) * (0.15 * dev / pixAng), -120.0, 120.0);
                        float sub = saturate(wE / max(rD, 1e-6) - 1.0);
                        float wgt = (1.0 - accA) * a;
                        accO += wgt * float4(off, sub, tt);
                        accA += wgt;
                    }
                }
            }
        }
        if (tNext.x < tNext.y && tNext.x < tNext.z)
        {
            t = tNext.x;
            tNext.x += tDelta.x;
            cell.x += stp.x;
        }
        else if (tNext.y < tNext.z)
        {
            t = tNext.y;
            tNext.y += tDelta.y;
            cell.y += stp.y;
        }
        else
        {
            t = tNext.z;
            tNext.z += tDelta.z;
            cell.z += stp.z;
        }
    }
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
    if (rpRainA.y < 0.001)
    {
        pfxOut[storePos] = src;
        return;
    }

    PFXVertToPix IN = processPostFxCompute(dispatchThreadID);
    PFXVertToPix INx = processPostFxCompute(dispatchThreadID + uint3(1, 0, 0));
    PFXVertToPix INy = processPostFxCompute(dispatchThreadID + uint3(0, 1, 0));
    const float3 ray0 = IN.wsEyeRay;
    const float3 rd = normalize(ray0);
    float3 camFwd = normalize(cross(INx.wsEyeRay - ray0, INy.wsEyeRay - ray0));
    camFwd = (dot(camFwd, ray0) < 0.0) ? -camFwd : camFwd;
    const float pixAng = max(length(normalize(INx.wsEyeRay) - rd), 1e-6);   // radians per pixel

    // how far the view ray gets before it meets the scene (depth sampled by uv: render scaling / upscaling)
    float sceneT = 1e5;
    float3 N = float3(0.0, 0.0, 0.0);
    if (rpDepthLoad(p) < 0.99999)
    {
        const float4 gb = decodeGBuffer(TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), IN.uv0, projParams);
        N = gb.xyz / max(length(gb.xyz), 1e-4);
        sceneT = length(rpReconstruct(ray0, camFwd, gb.w, rpMode.y, rpMode.z));
    }

    float accA = 0.0;
    float4 accO = float4(0.0, 0.0, 0.0, 0.0);
    const float3 dRx = INx.wsEyeRay - ray0;                 // eye ray change per pixel (linear across the screen)
    const float3 dRy = INy.wsEyeRay - ray0;
    const float3 ex = normalize(dRx - rd * dot(dRx, rd));
    const float3 ey = normalize(dRy - rd * dot(dRy, rd));
    const float dropR = rpRainA.z * 0.5;
    const float maxD = rpRainA.w;
    // night: the tone mapping crushes small differences in the dark, so the drops are covered a little more
    const float3 skyC = rpSkyColor(float3(0.0, 0.0, 1.0)) * 0.318 * 1.3;           // the sky above (what a drop shows most)
    const float3 hzC = rpSkyColor(normalize(float3(rd.xy, 0.0) + float3(0.0, 0.0, 0.4))) * 0.318 * 1.15;
    float3 avgC = float3(0.0, 0.0, 0.0);
    float3 maxC = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int gy = 0; gy < 3; gy++)
    {
        [unroll]
        for (int gx = 0; gx < 4; gx++)
        {
            float3 tap = rpRainLoad(int2(dispatchRect.xy + float2((gx + 0.5) / 4.0, (gy + 0.5) / 3.0) * dispatchRect.zw));
            avgC += tap;
            maxC = (rpLuma(tap) > rpLuma(maxC)) ? tap : maxC;
        }
    }
    avgC /= 12.0;
    const float nightK = saturate(1.0 - 2.0 * rpLuma(skyC) / max(rpLuma(avgC), 1e-5));
    const float visN = rpRainA.x * (1.0 + 0.6 * nightK);
    rpRainGrid(rpRainC.xyz, rd, rpRainC.w, 0.3, min(RP_NEAR_END, sceneT), 1e5, sceneT, pixAng, RP_NEAR_STEPS,
               rpRainB.xyz, dropR, rpRainA.y, visN, ex, ey, accA, accO);
    rpRainGrid(rpRainD.xyz, rd, rpRainD.w, RP_NEAR_END, min(maxD, sceneT), maxD, sceneT, pixAng, RP_FAR_STEPS,
               rpRainB.xyz, dropR, rpRainA.y * 0.8, visN, ex, ey, accA, accO);

    float3 col = src.rgb;
    if (accA > 1e-4)
    {
        // what the drops show: the scene behind them, bent (refraction, one tap at the mean offset; at the screen edge
        // the edge pixel). Something in front of the drop (e.g. the dashboard around the windshield) cannot be seen
        // through it: then just what lies behind the drop.
        const float2 off = accO.xy / accA;
        const float dropT = accO.w / accA;
        const int2 q = rpClampPix(p + int2(round(off)));
        float3 behind = rpRainLoad(q);
        if (rpDepthLoad(q) < 0.99999)
        {
            const float2 dq = float2(q - p);
            const float2 uvq = IN.uv0 + (INx.uv0 - IN.uv0) * dq.x + (INy.uv0 - IN.uv0) * dq.y;
            const float4 gq = decodeGBuffer(TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), uvq, projParams);
            const float tq = length(rpReconstruct(ray0 + dRx * dq.x + dRy * dq.y, camFwd, gq.w, rpMode.y, rpMode.z));
            behind = (tq < dropT) ? src.rgb : behind;
        }
        // 80 % refracted scene, 20 % sky
        float3 dropC = lerp(behind, lerp(skyC, hzC, 0.5), 0.2);
        // at night the sky gives almost nothing: the drops also catch the lamps and headlights of the scene, toward the
        // frame's lit parts and up to 2.5x its average, so they still show in the dark (by day only a faint floor)
        const float3 lampC = lerp(avgC, maxC, 0.45 * nightK) * (0.45 + 2.05 * nightK);
        dropC = max(dropC, lampC);
        // clear water: colours blur together in the drop, it never makes them more saturated than the scene
        dropC = lerp(rpLuma(dropC).xxx, dropC, 0.5) * rpRainB.w;
        col = lerp(src.rgb, dropC, accA);
    }

    // Debug 19: the falling rain alone (white streaks) on black
    if (rpMode.x > 18.5 && rpMode.x < 19.5)
    {
        col = float3(0.02, 0.02, 0.03) + float3(1.0, 1.0, 1.0) * saturate(accA * 3.0);
        col *= max(rpMode.w, 0.05);
    }

    pfxOut[storePos] = float4(col, src.a);
}
