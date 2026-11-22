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

// 1.1: is this depth-buffer value the sky? BeamNG 0.40 stores depth reversed (the sky is 0); the older convention (1) counts
// too. (Found in 1.1: the sky tests of 1.0 only knew 1, so the drops and the Midnight grade never saw the sky.)
bool rpIsSkyDepth(float ndc)
{
    return ndc <= 0.000001 || ndc >= 0.99999;
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

// 1.2 droplet atlas (art/rainPuddles/droplet_atlas2.data.png): 4 tiles wide, 8 high, 128 px each (8 px padding).
// Tiles 0-7 round beads, 8-11 teardrops, 12-14 flat merged drops, 15 calibration colour, 16-19 elongated teardrops
// (a slim line swelling into a small round head, radius 0.18 at q.y = +0.70, toward +q.y like the teardrops' heads),
// 20-31 empty. q = tile space, |q| <= 1.
float2 rpAtlasUV(float2 q, float tile)
{
    float2 t = float2(fmod(tile, 4.0), floor(tile * 0.25));
    return (t + 0.0625 + (q * 0.5 + 0.5) * (112.0 / 128.0)) * float2(0.25, 0.125);
}

// centre of the calibration tile 15 (column 3, row 3)
static const float2 RP_ATLAS_CAL_UV = float2(0.875, 0.4375);

// 1.3: a NaN or infinite colour (or a negative one) never leaves a pass. The engine's temporal AA / upscaler spreads a
// single bad pixel into black blocks that flicker. The bit test survives fast-math compilers that drop isnan().
bool rpBadF(float x)
{
    return (asuint(x) & 0x7F800000u) == 0x7F800000u;
}
bool rpBad3(float3 c)
{
    return rpBadF(c.r) || rpBadF(c.g) || rpBadF(c.b);
}
float3 rpSafe(float3 c, float3 fallback)
{
    if (rpBad3(c))
    {
        c = rpBad3(fallback) ? float3(0.0, 0.0, 0.0) : fallback;
    }
    return max(c, 0.0);
}

// 1.5 simulated ripples: the engine stores the simulation's targets as 0..1 fixed point (whatever format is asked for),
// so a signed value is kept as 16-bit fixed point in two channels: the upper and lower 8 bits of (x / range + 0.5).
// The upper half is rounded back to its 8-bit step on reading, which also survives 10-bit channels.
static const float RP_WAVE_HMAX = 0.02;   // height range: +-2 cm
static const float RP_WAVE_VMAX = 1.0;    // vertical velocity range: +-1 m/s
float2 rpPack16(float x, float range)
{
    float u = saturate(x / range * 0.5 + 0.5) * 255.0;
    float hi = min(floor(u), 254.0);
    return float2(hi / 255.0, saturate(u - hi));
}
float rpUnpack16(float2 p, float range)
{
    return ((round(p.x * 255.0) + saturate(p.y)) / 255.0 - 0.5) * 2.0 * range;
}
// height and vertical velocity of a packed water texel
float2 rpWaveDecode(float4 t)
{
    return float2(rpUnpack16(t.rg, RP_WAVE_HMAX), rpUnpack16(t.ba, RP_WAVE_VMAX));
}
// The engine reads its 8-bit targets through an sRGB view while the compute pass writes raw values (found in game: a
// raw 0.5 read back as 0.21). Cell (0, 0) always holds a raw 0.5: if it reads back far from 0.5, the colour channels
// are put back through linear -> sRGB, which returns the stored byte exactly (alpha is never converted).
float rpLinToSrgb1(float c)
{
    c = saturate(c);
    return (c <= 0.0031308) ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
float4 rpWaveRaw(float4 t, bool srgbRead)
{
    if (srgbRead)
    {
        t.rgb = float3(rpLinToSrgb1(t.r), rpLinToSrgb1(t.g), rpLinToSrgb1(t.b));
    }
    return t;
}
static const float4 RP_WAVE_CAL = float4(0.5, 0.5, 0.5, 0.5);
float4 rpWaveEncode(float h, float v)
{
    return float4(rpPack16(h, RP_WAVE_HMAX), rpPack16(v, RP_WAVE_VMAX));
}

// 1.5 simulated mist (rp_mist.cs.hlsl, drawn by the spray pass): the air above the road in three layers, each a
// 128 x 128 grid; in the state targets the layers lie side by side, plane A (u, density upper half) then plane B (v,
// density lower half). The density is kept as sqrt(d / DMAX) in 16-bit fixed point: fine steps where the mist is thin.
static const int RP_MIST_N = 128;
static const int RP_MIST_LAYERS = 3;
static const float RP_MIST_VMAX = 40.0;    // air speed range: +-40 m/s
static const float RP_MIST_DMAX = 4.0;     // mist density range
static const float RP_MIST_PMAX = 96.0;    // pressure range (m^2/s)
static const float RP_MIST_QMAX = 128.0;   // divergence range (1/s)
// the layers' heights above the road (m)
float2 rpMistLayerZ(int l)
{
    return (l == 0) ? float2(0.0, 0.5) : ((l == 1) ? float2(0.5, 1.0) : float2(1.0, 2.0));
}
// 0..1 as 16-bit fixed point in two channels (rpPack16 without the sign)
float2 rpPackU16(float x)
{
    const float u = saturate(x) * 255.0;
    const float hi = min(floor(u), 254.0);
    return float2(hi / 255.0, saturate(u - hi));
}
float rpUnpackU16(float2 p)
{
    return (round(p.x * 255.0) + saturate(p.y)) / 255.0;
}

// 1.3: Fresnel of a water surface seen from INSIDE the water (the windshield drops from the cabin: the ray leaves the
// drop through its curved surface). cosI = cosine between the ray in the water and the surface normal. Schlick on the
// air side; total internal reflection beyond the critical angle (48.8 deg for water).
float rpFresnelWaterIn(float cosI)
{
    float s2 = 1.7689 * saturate(1.0 - cosI * cosI);
    if (s2 >= 1.0)
    {
        return 1.0;
    }
    return rpFresnel(0.02, sqrt(1.0 - s2));
}

#endif
