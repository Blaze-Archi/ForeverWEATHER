#ifndef RP_SHELTER_H_HLSL
#define RP_SHELTER_H_HLSL

// 1.0 shelter grid (uniforms: rp_shelter_cb.h.hlsl, filled by Lua: rainSt.shelter). World-anchored 13 x 13 samples
// around the camera. Used by the falling rain (no drops under roofs) and by the ground (dry and not reflective in
// tunnels, under bridges and roofs).
//
// 1.0.1 road flicker fix. 1.0 stretched the edge samples of a 9 x 9 grid out to the horizon (so a tunnel stayed dry far
// ahead). The grid moves with the camera in 4 m steps, so every step put other samples on the edge, and any roof, lamp
// or sign there switched long bands of the far road between dry and wet several times a second while driving. Now the
// grid only counts close to the camera and fades out with the distance to the CAMERA (smooth while driving, nothing
// depends on where the grid happens to be); beyond it only a tunnel the camera is inside keeps the ground dry.

#define RP_SHELTER_N 13
#define RP_SHELTER_V 43

static float4 rpShel[RP_SHELTER_V];

// copies the grid into an indexable array once per thread (call before rpRoofZ / rpGroundCovered)
void rpShelterInit()
{
    rpShel[0] = rpShelter0;   rpShel[1] = rpShelter1;   rpShel[2] = rpShelter2;   rpShel[3] = rpShelter3;
    rpShel[4] = rpShelter4;   rpShel[5] = rpShelter5;   rpShel[6] = rpShelter6;   rpShel[7] = rpShelter7;
    rpShel[8] = rpShelter8;   rpShel[9] = rpShelter9;   rpShel[10] = rpShelter10; rpShel[11] = rpShelter11;
    rpShel[12] = rpShelter12; rpShel[13] = rpShelter13; rpShel[14] = rpShelter14; rpShel[15] = rpShelter15;
    rpShel[16] = rpShelter16; rpShel[17] = rpShelter17; rpShel[18] = rpShelter18; rpShel[19] = rpShelter19;
    rpShel[20] = rpShelter20; rpShel[21] = rpShelter21; rpShel[22] = rpShelter22; rpShel[23] = rpShelter23;
    rpShel[24] = rpShelter24; rpShel[25] = rpShelter25; rpShel[26] = rpShelter26; rpShel[27] = rpShelter27;
    rpShel[28] = rpShelter28; rpShel[29] = rpShelter29; rpShel[30] = rpShelter30; rpShel[31] = rpShelter31;
    rpShel[32] = rpShelter32; rpShel[33] = rpShelter33; rpShel[34] = rpShelter34; rpShel[35] = rpShelter35;
    rpShel[36] = rpShelter36; rpShel[37] = rpShelter37; rpShel[38] = rpShelter38; rpShel[39] = rpShelter39;
    rpShel[40] = rpShelter40; rpShel[41] = rpShelter41; rpShel[42] = rpShelter42;
}

float rpShelterAt(int idx)
{
    float4 v = rpShel[clamp(idx >> 2, 0, RP_SHELTER_V - 1)];
    int m = idx & 3;
    return (m == 0) ? v.x : ((m == 1) ? v.y : ((m == 2) ? v.z : v.w));
}

// roof height above xy (world z), -1e5 = open sky: the nearest sample; none beyond the grid
float rpRoofZ(float2 xy)
{
    if (rpShelterG.w < 0.5)
    {
        return -1e5;
    }
    const float hn = (RP_SHELTER_N - 1) * 0.5;
    float2 g = (xy - rpShelterG.xy) / max(rpShelterG.z, 0.5) + hn;
    int2 ci = int2(floor(g + 0.5));
    if (ci.x < 0 || ci.y < 0 || ci.x > RP_SHELTER_N - 1 || ci.y > RP_SHELTER_N - 1)
    {
        return -1e5;
    }
    return rpShelterAt(ci.y * RP_SHELTER_N + ci.x);
}

// How covered a ground point is: 0 open sky .. 1 under a roof at least 1.5 m above it (so a hill or the terrain right
// above the cast's start never counts). Bilinear over the 4 samples around it, so the edge of a bridge or a tunnel
// mouth is soft. Faded out with the distance to the camera (rpShelterF.zw); further away only a tunnel the camera is
// in counts (rpShelterF.x), for ground at about the camera's own floor level.
float rpGroundCovered(float3 w)
{
    if (rpShelterG.w < 0.5)
    {
        return 0.0;
    }
    float dc = length(w.xy - rpCam.xy);
    float nearK = 1.0 - smoothstep(rpShelterF.z, rpShelterF.w, dc);
    float grid = 0.0;
    if (nearK > 0.001)
    {
        const float hn = (RP_SHELTER_N - 1) * 0.5;
        float2 g = clamp((w.xy - rpShelterG.xy) / max(rpShelterG.z, 0.5) + hn, 0.0, RP_SHELTER_N - 1.0);
        int2 c0 = min(int2(floor(g)), int2(RP_SHELTER_N - 2, RP_SHELTER_N - 2));
        float2 f = smoothstep(0.0, 1.0, g - float2(c0));
        float lim = w.z + 1.5;
        int i0 = c0.y * RP_SHELTER_N + c0.x;
        float k00 = step(lim, rpShelterAt(i0));
        float k10 = step(lim, rpShelterAt(i0 + 1));
        float k01 = step(lim, rpShelterAt(i0 + RP_SHELTER_N));
        float k11 = step(lim, rpShelterAt(i0 + RP_SHELTER_N + 1));
        grid = lerp(lerp(k00, k10, f.x), lerp(k01, k11, f.x), f.y);
    }
    float farK = saturate(rpShelterF.x) * (1.0 - smoothstep(2.5, 5.0, abs(w.z - rpShelterF.y)));
    return lerp(farK, grid, nearK);
}

#endif
