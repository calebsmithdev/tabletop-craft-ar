#include <metal_stdlib>
using namespace metal;

struct BatchVertex { float4 position; float4 color; };
struct BatchUniforms {
    float4x4 clipFromOrigin[2];
    float4x4 originFromTable;
};
struct BatchVaryings {
    float4 position [[position]];
    float4 color;
};

vertex BatchVaryings batchVertex(uint vertexID [[vertex_id]],
                                 ushort eye [[amplification_id]],
                                 const device BatchVertex *vertices [[buffer(0)]],
                                 constant BatchUniforms &uniforms [[buffer(1)]]) {
    BatchVaryings out;
    out.position = uniforms.clipFromOrigin[eye] * uniforms.originFromTable * vertices[vertexID].position;
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 batchFragment(BatchVaryings in [[stage_in]]) {
    // Color32 and the vanilla face multipliers are in sRGB. The sRGB render
    // target encodes linear output, so decode here to avoid encoding twice.
    float3 c = in.color.rgb;
    float3 linear = select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
    return float4(linear, in.color.a);
}
