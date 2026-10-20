#include <metal_stdlib>
using namespace metal;

struct CubeVertex { float4 position; float4 normal; };
struct CubeUniforms {
    float4x4 clipFromOrigin[2];
    float4x4 originFromTable;
};
struct CubeVaryings {
    float4 position [[position]];
    float3 normal;
};

vertex CubeVaryings cubeVertex(uint vertexID [[vertex_id]],
                               ushort eye [[amplification_id]],
                               const device CubeVertex *vertices [[buffer(0)]],
                               constant CubeUniforms &uniforms [[buffer(1)]]) {
    CubeVertex v = vertices[vertexID];
    CubeVaryings out;
    out.position = uniforms.clipFromOrigin[eye] * uniforms.originFromTable * v.position;
    out.normal = (uniforms.originFromTable * float4(v.normal.xyz, 0)).xyz;
    return out;
}

fragment float4 cubeFragment(CubeVaryings in [[stage_in]]) {
    float light = 0.25 + 0.75 * max(0.0, dot(normalize(in.normal), normalize(float3(0.3, 1, 0.5))));
    return float4(float3(0.18, 0.65, 0.85) * light, 1);
}
