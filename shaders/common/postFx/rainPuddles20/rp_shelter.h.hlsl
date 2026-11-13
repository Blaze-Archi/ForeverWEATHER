#ifndef RP_SHELTER_H_HLSL
#define RP_SHELTER_H_HLSL

// 1.0 shelter grid (uniforms: rp_shelter_cb.h.hlsl, filled by Lua: rainSt.shelter). World-anchored 9 x 9 samples around
// the camera. Used by the falling rain (no drops under roofs) and by the ground (dry and not reflective in tunnels,
// under bridges and roofs).

float rpShelterAt(int idx)
{
    int k = idx >> 2;
    float4 v = rpShelter0;
    v = (k == 1) ? rpShelter1 : v;
    v = (k == 2) ? rpShelter2 : v;
    v = (k == 3) ? rpShelter3 : v;
    v = (k == 4) ? rpShelter4 : v;
    v = (k == 5) ? rpShelter5 : v;
    v = (k == 6) ? rpShelter6 : v;
    v = (k == 7) ? rpShelter7 : v;
    v = (k == 8) ? rpShelter8 : v;
    v = (k == 9) ? rpShelter9 : v;
    v = (k == 10) ? rpShelter10 : v;
    v = (k == 11) ? rpShelter11 : v;
    v = (k == 12) ? rpShelter12 : v;
    v = (k == 13) ? rpShelter13 : v;
    v = (k == 14) ? rpShelter14 : v;
    v = (k == 15) ? rpShelter15 : v;
    v = (k == 16) ? rpShelter16 : v;
    v = (k == 17) ? rpShelter17 : v;
    v = (k == 18) ? rpShelter18 : v;
    v = (k == 19) ? rpShelter19 : v;
    v = (k == 20) ? rpShelter20 : v;
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
    float2 g = (xy - rpShelterG.xy) / max(rpShelterG.z, 0.5) + 4.0;
    int2 ci = int2(floor(g + 0.5));
    if (ci.x < 0 || ci.y < 0 || ci.x > 8 || ci.y > 8)
    {
        return -1e5;
    }
    return rpShelterAt(ci.y * 9 + ci.x);
}

// How covered a ground point is: 0 open sky .. 1 under a roof at least 1.5 m above it (so a hill or the terrain right
// above the cast's start never counts). Bilinear over the 4 samples around it, so the edge of a bridge or a tunnel
// mouth is soft; beyond the grid the nearest edge sample carries on (a tunnel stays dry far ahead).
float rpGroundCovered(float3 w)
{
    if (rpShelterG.w < 0.5)
    {
        return 0.0;
    }
    float2 g = clamp((w.xy - rpShelterG.xy) / max(rpShelterG.z, 0.5) + 4.0, 0.0, 8.0);
    int2 c0 = min(int2(floor(g)), int2(7, 7));
    float2 f = smoothstep(0.0, 1.0, g - float2(c0));
    float lim = w.z + 1.5;
    float k00 = step(lim, rpShelterAt(c0.y * 9 + c0.x));
    float k10 = step(lim, rpShelterAt(c0.y * 9 + c0.x + 1));
    float k01 = step(lim, rpShelterAt((c0.y + 1) * 9 + c0.x));
    float k11 = step(lim, rpShelterAt((c0.y + 1) * 9 + c0.x + 1));
    return lerp(lerp(k00, k10, f.x), lerp(k01, k11, f.x), f.y);
}

#endif
