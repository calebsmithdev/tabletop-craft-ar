#include <metal_stdlib>
using namespace metal;

constant bool PACKED [[function_constant(0)]];
constant bool SOLID [[function_constant(1)]];
constant bool FOG [[function_constant(2)]];
constant bool CLIP_PLANES [[function_constant(3)]]; // Reserved for M4; specialized false.
constant bool DAYLIGHT [[function_constant(4)]]; // Reserved for M7; specialized false.
constant bool TRANSPARENT [[function_constant(5)]];

struct BatchUniforms { float4x4 clipFromOrigin[2]; float4x4 originFromTable; };
struct ObjectUniforms { float4 transform; int4 cellOrigin; };
struct MaterialUniforms { float4 eye; float4 fogColor; float4 fog; float4 options; };
struct BatchVaryings {
    float4 position [[position]];
    float4 color;
    float3 uv;
    float3 cell;
    uint table [[flat]];
    int3 cellOrigin [[flat]];
    float3 fogPosition [[function_constant(FOG)]];
    float blockSize [[flat, function_constant(FOG)]];
};
float3 linearRGB(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, float3(2.4f)), c / 12.92f, c <= 0.04045f);
}
uint tabletopHash(int3 c) {
    uint h = uint(c.x)*0x8da6b343u ^ uint(c.y)*0xd8163841u ^ uint(c.z)*0xcb1ab31fu;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    return h;
}
vertex BatchVaryings batchVertex(uint id [[vertex_id]], ushort eye [[amplification_id]],
                                 const device uchar *bytes [[buffer(0)]],
                                 constant BatchUniforms &u [[buffer(1)]],
                                 constant ObjectUniforms &object [[buffer(2)]],
                                 constant MaterialUniforms &material [[buffer(3)]]) {
    BatchVaryings out;
    float3 p, n, uv; float4 color; uint table;
    if (PACKED) {
        const device uchar *v = bytes + id*20;
        const device short *s = reinterpret_cast<const device short *>(v);
        p = float3(s[0],s[1],s[2])/64.0f;
        uint dir = ushort(s[3]) >> 8;
        n = float3(0);
        if (dir < 6) n[dir/2] = (dir & 1) ? -1.0f : 1.0f;
        color = float4(v[8],v[9],v[10],v[11])/255.0f;
        uv = float3(float(s[6])/1024.0f,float(s[7])/1024.0f,float(s[8]));
        table = ushort(s[9]);
    } else {
        const device uchar *v = bytes + id*32;
        const device float *f = reinterpret_cast<const device float *>(v);
        const device char *normal = reinterpret_cast<const device char *>(v+12);
        p = float3(f[0],f[1],f[2]); n = max(float3(-1),float3(normal[0],normal[1],normal[2])/127.0f);
        color = float4(v[16],v[17],v[18],v[19])/255.0f;
        float3 a = abs(n);
        float shade = a.y > 0.9f ? (n.y > 0 ? 1.0f : 0.5f) : (a.z > 0.9f ? 0.8f : (a.x > 0.9f ? 0.6f : 1.0f));
        color.rgb *= shade;
        uv = float3(f[5],f[6],f[7]);
        table = uv.z < 0 ? 0u : uint(floor((uv.z+0.5f)/4096.0f));
        uv.z -= float(table)*4096.0f;
    }
    float3 position = p*object.transform.w + object.transform.xyz;
    out.position = u.clipFromOrigin[eye] * u.originFromTable * float4(position,1);
    // M3a colors already include tint, noon light (min_light/brightness), and AO.
    out.color = float4(linearRGB(color.rgb),color.a);
    out.uv = uv; out.table = table;
    // Swift meshes retain tabletop handedness: no Unity Z undo here.
    out.cell = p - n*0.5f;
    out.cellOrigin = object.cellOrigin.xyz;
    if (FOG) { out.fogPosition = position; out.blockSize = object.transform.w; }
    return out;
}
fragment float4 batchFragment(BatchVaryings in [[stage_in]],
                               texture2d_array<float> blocks [[texture(0)]], sampler sampling [[sampler(0)]],
                               constant MaterialUniforms &m [[buffer(0)]],
                               const device float4 *tables [[buffer(1)]]) {
    // Continuous derivatives must be evaluated before rotation branches/discard.
    float2 dx = dfdx(in.uv.xy), dy = dfdy(in.uv.xy), st = in.uv.xy;
    int layer = int(round(in.uv.z));
    if (in.table == 64) {
        float2 q = floor(fract(in.uv.xy*0.5f)*2.0f);
        layer += int(q.x + 2.0f*(1.0f-q.y));
    } else if (in.table > 0 && in.table < 64) {
        float4 t = tables[in.table];
        uint k = tabletopHash(int3(floor(in.cell)) + in.cellOrigin) % uint(max(1.0f,t.x));
        uint codes = uint(k < 8 ? t.y : t.z), code = (codes >> (3u*(k & 7u))) & 7u;
        float2 f = fract(st)-0.5f;
        if (code & 1u) f = f.yx;
        if (code & 2u) f.x = -f.x;
        if (code & 4u) f.y = -f.y;
        st = floor(st)+f+0.5f;
    }
    float4 c = in.color;
    if (m.options.y > 0.5f && layer >= 0 && layer < int(blocks.get_array_size())) {
        float size = m.options.x;
        if (max(dot(dx,dx),dot(dy,dy))*size*size < 1.0f) st = (floor(st*size)+0.5f)/size;
        if (m.options.z > 0.5f) c *= blocks.sample(sampling,st,uint(layer),gradient2d(dx,dy));
        else c *= blocks.sample(sampling,st,uint(layer),level(0.0f));
    }
    // SOLID specialization contains no discard, preserving early depth rejection.
    if (!SOLID) { if (c.a < (TRANSPARENT ? 0.01f : 0.3f)) discard_fragment(); }
    if (!TRANSPARENT) c.a = 1;
    if (FOG) {
        float blocksAway = distance(in.fogPosition,m.eye.xyz)/max(in.blockSize,1e-6f);
        float strength = saturate((blocksAway-m.fog.x)*m.fog.y)*m.fog.z;
        c.rgb = mix(c.rgb,linearRGB(m.fogColor.rgb),strength);
    }
    return c;
}

struct OverlayVaryings { float4 position [[position]]; };
constant float3 corners[8] = { {-1,-1,-1},{1,-1,-1},{1,1,-1},{-1,1,-1},
                                  {-1,-1,1},{1,-1,1},{1,1,1},{-1,1,1} };
constant ushort indices[36] = { 0,2,1,0,3,2, 4,5,6,4,6,7, 0,1,5,0,5,4,
                                    3,7,6,3,6,2, 0,4,7,0,7,3, 1,2,6,1,6,5 };

vertex OverlayVaryings eyeOverlayVertex(uint id [[vertex_id]],ushort eye [[amplification_id]],
                                        constant BatchUniforms &u [[buffer(1)]],constant float4 &head [[buffer(2)]]) {
    OverlayVaryings out;
    out.position = u.clipFromOrigin[eye]*u.originFromTable*float4(head.xyz+corners[indices[id]],1);
    return out;
}
fragment float4 eyeOverlayFragment(constant float4 &tint [[buffer(0)]]) {
    return float4(linearRGB(tint.rgb)*tint.a,tint.a);
}

kernel void blendAnimation(texture2d_array<float,access::read> current [[texture(0)]],
                           texture2d_array<float,access::read> next [[texture(1)]],
                           texture2d_array<float,access::write> output [[texture(2)]],
                           constant uint4 &info [[buffer(0)]],uint2 at [[thread_position_in_grid]]) {
    uint4 c = uint4(round(current.read(at,info.x,info.w)*255.0f));
    uint4 n = uint4(round(next.read(at,info.y,info.w)*255.0f));
    uint3 rgb = (c.rgb*(255u-info.z)+n.rgb*info.z)/255u;
    output.write(float4(float3(rgb)/255.0f,float(c.a)/255.0f),at,0,info.w);
}
