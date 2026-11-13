#ifndef RP_LIB_H_HLSL
#define RP_LIB_H_HLSL

// Shared helpers for the Rain Puddles mod. This file is included after each
// pass's cbuffer and texture declarations, so dispatchRect and the mask
// samplers are visible here.

uint rpPcg(uint v)
{
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rpRand(uint h)
{
    return float(h & 0x00FFFFFFu) / 16777216.0;
}

uint rpHash3(int3 p)
{
    return rpPcg(rpPcg(rpPcg(uint(p.x) + 0x9E3779B9u) ^ uint(p.y)) + uint(p.z));
}

float rpSaturate(float v)
{
    return clamp(v, 0.0, 1.0);
}

float rpLuma(float3 c)
{
    return dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722));
}

// Bilinear, wrapping sample of a mask texture with a screen-footprint-driven
// mip level. This keeps world-anchored fields from crawling as they recede.
float rpSampleFieldMip(Texture2D<float4> tex, float2 uv, uint mip)
{
    uint w, h, levels;
    tex.GetDimensions(mip, w, h, levels);
    int2 sz = max(int2(w, h), int2(1, 1));
    float2 p = frac(uv) * float2(sz) - 0.5;
    int2 i0 = int2(floor(p));
    float2 f = p - float2(i0);
    int2 a = ((i0 % sz) + sz) % sz;
    int2 b = (((i0 + 1) % sz) + sz) % sz;
    float v00 = tex.Load(int3(a.x, a.y, int(mip))).r;
    float v10 = tex.Load(int3(b.x, a.y, int(mip))).r;
    float v01 = tex.Load(int3(a.x, b.y, int(mip))).r;
    float v11 = tex.Load(int3(b.x, b.y, int(mip))).r;
    return lerp(lerp(v00, v10, f.x), lerp(v01, v11, f.x), f.y);
}

// Value-noise replacement for the mask textures. Used when 'Procedural masks' is on, so the mod does
// not depend on BeamNG's texture cooker having finished converting the .data.png files.
float rpValueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    int2 c = int2(i);
    float a = rpRand(rpHash3(int3(c.x,     c.y,     101)));
    float b = rpRand(rpHash3(int3(c.x + 1, c.y,     101)));
    float d = rpRand(rpHash3(int3(c.x,     c.y + 1, 101)));
    float e = rpRand(rpHash3(int3(c.x + 1, c.y + 1, 101)));
    return lerp(lerp(a, b, u.x), lerp(d, e, u.x), u.y);
}

float rpProcField(float2 uv, float footprint)
{
    float sum = 0.0;
    float norm = 0.0;
    float amp = 0.5;
    float fr = 3.0;
    [unroll]
    for (int o = 0; o < 4; o++)
    {
        // octaves finer than a pixel fade to their mean instead of aliasing
        float fade = 1.0 - smoothstep(0.25, 0.70, footprint * fr);
        sum += amp * lerp(0.5, rpValueNoise(uv * fr + float(o) * 17.31), fade);
        norm += amp;
        amp *= 0.5;
        fr *= 2.0;
    }
    float v = sum / norm;
    return saturate(0.5 + (v - 0.5) * 1.9);
}

float rpSampleField(Texture2D<float4> tex, float2 uv, float footprint)
{
    if (rpMode.z < 0.0)
    {
        return rpProcField(uv, footprint);
    }
    uint w, h, levels;
    tex.GetDimensions(0, w, h, levels);
    float texelsPerPixel = max(footprint * float(max(w, h)), 1.0);
    float lod = clamp(log2(texelsPerPixel), 0.0, float(max(int(levels) - 1, 0)));
    uint mip0 = (uint)floor(lod);
    uint mip1 = min(mip0 + 1, max(levels, 1u) - 1u);
    float v0 = rpSampleFieldMip(tex, uv, mip0);
    if (mip1 == mip0) return v0;
    return lerp(v0, rpSampleFieldMip(tex, uv, mip1), frac(lod));
}

int2 rpClampPix(int2 q)
{
    return clamp(q, int2(dispatchRect.xy), int2(dispatchRect.xy + dispatchRect.zw) - 1);
}

// Offset from the camera to the surface point.
//  mode 0: ray * depth                (far-plane eye ray + 0..1 depth)
//  mode 1: ray * depth / (ray . fwd)  (depth is metres along the view axis)
//  mode 2: normalize(ray) * depth     (depth is metres along the ray)
float3 rpReconstruct(float3 ray, float3 fwd, float depth, float mode, float scale)
{
    scale = abs(scale);   // a negative depth scale is only the 'procedural masks' flag (see rpSampleField)
    if (mode < 0.5)
    {
        return ray * (depth * scale);
    }
    if (mode < 1.5)
    {
        return ray * (depth * scale / max(abs(dot(ray, fwd)), 1e-6));
    }
    return normalize(ray) * (depth * scale);
}

// Finds the pixel offset (a, b) from the current pixel whose eye ray points
// along R. r0 = eye ray of this pixel, dx/dy = change of the eye ray per pixel.
bool rpProjectDir(float3 r0, float3 dx, float3 dy, float3 R, out float2 pixOff)
{
    float3 c3 = -R;
    float3 c2xc3 = cross(dy, c3);
    float D = dot(dx, c2xc3);
    pixOff = float2(0.0, 0.0);
    if (abs(D) < 1e-20)
    {
        return false;
    }
    float3 rhs = -r0;
    float a = dot(rhs, c2xc3) / D;
    float b = dot(dx, cross(rhs, c3)) / D;
    float s = dot(dx, cross(dy, rhs)) / D;
    pixOff = float2(a, b);
    return s > 0.0;
}

// Fast replacement for rpProjectDir inside loops. The basis [r0 dx dy] of a pixel is inverted ONCE; a world vector
// R (from the camera) then maps to (k, k*a, k*b) = M^-1 R, i.e. R = k * (r0 + a*dx + b*dy). Same solution as
// rpProjectDir, but 3 dots + 1 divide per call (no cross products, no normalize).
// Portability: plain float3 parameters (no struct/bool members) and no early returns, so strict HLSL front ends
// (Wine/vkd3d-shader, DXC -> SPIR-V for Vulkan) have nothing unusual to reject.
void rpMakeProj(float3 r0, float3 dx, float3 dy, out float3 rk, out float3 ra, out float3 rb)
{
    float3 cxy = cross(dx, dy);
    float det = dot(r0, cxy);
    float inv = (abs(det) > 1e-20) ? (1.0 / det) : 0.0;
    rk = cxy * inv;
    ra = cross(dy, r0) * inv;
    rb = cross(r0, dx) * inv;
}

bool rpProjectFast(float3 rk, float3 ra, float3 rb, float3 R, out float2 pixOff)
{
    float k = dot(rk, R);
    bool ok = (k > 1e-6);
    float invk = ok ? (1.0 / k) : 0.0;
    pixOff = float2(dot(ra, R), dot(rb, R)) * invk;
    return ok;
}

// Oriented box test. a = (center, half extent along axis0), b = (axis0, half
// axis1), c = (axis1, half axis2), d = (axis2, seed). Returns the distance to
// the nearest face (positive inside) and the local coordinates of P.
float rpBoxInner(float3 P, float4 a, float4 b, float4 c, float4 d, out float3 lp)
{
    float3 dp = P - a.xyz;
    lp = float3(dot(dp, b.xyz), dot(dp, c.xyz), dot(dp, d.xyz));
    float3 q = float3(a.w, b.w, c.w) - abs(lp);
    return min(q.x, min(q.y, q.z));
}

// Expanding rain rings. Returns a world-XY slope vector.
float2 rpRipples(float2 p, float t)
{
    float2 g = float2(0.0, 0.0);
    const float cellSize = 0.45;                       // 1.0: smaller, denser rings (was 0.6 m cells, 0.35 m rings)
    int2 cell = int2(floor(p / cellSize));
    [unroll]
    for (int j = -1; j <= 1; j++)
    {
        [unroll]
        for (int i = -1; i <= 1; i++)
        {
            int2 c = cell + int2(i, j);
            uint h = rpHash3(int3(c.x, c.y, 17));
            float2 o = float2(rpRand(h), rpRand(rpPcg(h ^ 0x68E31DA4u)));
            float period = 1.2 + 1.6 * rpRand(rpPcg(h ^ 0xB5297A4Du));
            float ph = frac(t / period + rpRand(rpPcg(h ^ 0x1B873593u)));
            float2 center = (float2(c) + o) * cellSize;
            float2 d = p - center;
            float r = length(d);
            float radius = ph * 0.24;
            float e = (r - radius) / 0.028;
            float w = exp(-e * e) * (1.0 - ph);
            g += (d / max(r, 1e-4)) * w * sin((r - radius) * 110.0);
        }
    }
    return g;
}

float rpFresnel(float f0, float cosTheta)
{
    float m = 1.0 - rpSaturate(cosTheta);
    float m2 = m * m;
    return f0 + (1.0 - f0) * m2 * m2 * m;
}

float2 rpOctWrap(float2 v)
{
    return (1.0 - abs(v.yx)) * float2(v.x >= 0.0 ? 1.0 : -1.0, v.y >= 0.0 ? 1.0 : -1.0);
}

float3 rpDecodeNormal(float2 encN)
{
    encN = encN * 2.0 - 1.0;
    float3 n;
    n.z = 1.0 - abs(encN.x) - abs(encN.y);
    n.xy = n.z >= 0.0 ? encN.xy : rpOctWrap(encN.xy);
    return normalize(n);
}

// 1.0 drop outline variety. q = position in units of the drop radius (drop frame); returns the position in the unit
// circle of the atlas tile, so a round bead becomes stretched (area kept) and a little lumpy, different for every drop.
// rnd = four random values 0..1 (stretch, three lobe phases), amount 0 = round.
float2 rpDropWarp(float2 q, float4 rnd, float amount)
{
    float asp = lerp(1.0, lerp(0.70, 1.35, rnd.x), amount);
    float sa = sqrt(asp);
    q = float2(q.x * sa, q.y / sa);
    float th = atan2(q.y, q.x);
    float k = 1.0 + amount * (0.10 * cos(2.0 * th + 6.2831853 * rnd.y) + 0.07 * cos(3.0 * th + 6.2831853 * rnd.z)
                            + 0.04 * cos(5.0 * th + 6.2831853 * rnd.w));
    return q / k;
}

float4 rpRand4(uint h)
{
    return float4(float(h & 255u), float((h >> 8) & 255u), float((h >> 16) & 255u), float(h >> 24)) / 255.0;
}

#endif
