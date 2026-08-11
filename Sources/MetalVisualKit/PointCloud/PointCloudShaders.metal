//
//  PointCloudShaders.metal
//  MetalVisualKit
//
//  LiDAR point cloud.
//
//  The depth map is bound as a *texture to the vertex shader*, so each vertex
//  samples its own depth pixel and unprojects itself. No depth or point data is
//  ever read back to the CPU.
//
//  Struct layouts here are mirrored by hand in PointCloudRenderer.swift.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types (mirrored in PointCloudRenderer.swift)

/// stride 208, align 16 — see PipelineTests.testCloudUniformsStride
struct CloudUniforms {
    float4x4 viewProjection;
    float4x4 localToWorld;        // camera transform × rotate-to-ARKit-camera
    float3x3 intrinsicsInv;       // inverse camera intrinsics
    float2   cameraResolution;    // captured image resolution (intrinsics space)
    float2   gridResolution;      // depth map size, e.g. 256×192
    float    pointSize;
    float    maxDepth;            // metres
    float    time;
    float    minConfidence;       // raw ARConfidenceLevel: 0 low, 1 medium, 2 high
};

/// stride 80, align 16 — see PipelineTests.testDemoUniformsStride
struct DemoUniforms {
    float4x4 viewProjection;
    float    time;
    float    pointCount;
    float    pointSize;
    float    motionScale;         // 1 normally, 0 when Reduce Motion is on
};

struct CloudVSOut {
    float4 position  [[position]];
    float  pointSize [[point_size]];
    float4 color;
};

// MARK: - Depth palette

/// Project-specific near-to-far gradient: deep blue → cyan → violet → coral.
/// It is intentionally small and explicit rather than importing an external
/// colormap implementation with unclear provenance.
static float3 depthPalette(float x) {
    x = clamp(x, 0.0, 1.0);
    const float3 nearColor = float3(0.02, 0.06, 0.18);
    const float3 midColor = float3(0.00, 0.86, 1.00);
    const float3 farColor = float3(0.72, 0.24, 0.96);
    const float3 edgeColor = float3(1.00, 0.38, 0.18);

    float3 color = mix(nearColor, midColor, smoothstep(0.00, 0.38, x));
    color = mix(color, farColor, smoothstep(0.32, 0.72, x));
    return mix(color, edgeColor, smoothstep(0.68, 1.00, x));
}

// MARK: - Live LiDAR vertex shader

vertex CloudVSOut pointCloudVertex(uint vid                                [[vertex_id]],
                                   constant CloudUniforms &u               [[buffer(0)]],
                                   texture2d<float, access::read> depthTex [[texture(0)]],
                                   texture2d<uint,  access::read> confTex  [[texture(1)]])
{
    uint gridWidth = uint(u.gridResolution.x);
    uint2 coord = uint2(vid % gridWidth, vid / gridWidth);
    float2 uv = (float2(coord) + 0.5) / u.gridResolution;

    // Both maps are read at integer coordinates. ARKit's confidence map holds
    // raw ARConfidenceLevel values (0/1/2) in an r8Uint texture, so it must not
    // be sampled as normalised colour or filtered.
    float depth = depthTex.read(coord).r;
    uint  conf  = confTex.read(coord).r;

    CloudVSOut out;

    // Cull invalid, out-of-range and low-confidence samples by pushing them
    // behind the near plane, where the rasteriser discards them for free.
    // isfinite() rejects the NaN and Inf that appear in unreturned LiDAR pixels.
    if (!isfinite(depth) || depth < 0.05 || depth > u.maxDepth
        || conf < uint(u.minConfidence)) {
        out.position  = float4(0.0, 0.0, -2.0, 1.0);
        out.pointSize = 0.0;
        out.color     = float4(0.0);
        return out;
    }

    // Unproject: depth-map pixel → camera space → world space
    float2 pixel      = uv * u.cameraResolution;
    float3 localPoint = u.intrinsicsInv * float3(pixel, 1.0) * depth;
    float4 world      = u.localToWorld * float4(localPoint, 1.0);

    out.position  = u.viewProjection * world;
    out.pointSize = clamp(u.pointSize / max(out.position.w, 0.1), 1.5, 12.0);

    float t       = clamp(depth / u.maxDepth, 0.0, 1.0);
    float shimmer = 0.85 + 0.15 * sin(u.time * 3.0 + depth * 8.0);
    out.color     = float4(depthPalette(t) * shimmer, 0.95);
    return out;
}

// MARK: - Demo vertex shader (simulator, previews, non-LiDAR devices)

vertex CloudVSOut demoCloudVertex(uint vid                 [[vertex_id]],
                                  constant DemoUniforms &u [[buffer(0)]])
{
    float i = float(vid);
    float n = max(u.pointCount, 1.0);

    // Fibonacci sphere — even distribution without clustering at the poles
    float phi    = acos(1.0 - 2.0 * (i + 0.5) / n);
    float golden = M_PI_F * (3.0 - sqrt(5.0));
    float theta  = golden * i;

    float3 p = float3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta));

    float wave = sin(u.time * 1.4 + p.y * 5.0 + p.x * 3.0);
    p *= 1.0 + 0.12 * wave * u.motionScale;

    float angle = u.time * 0.4 * u.motionScale;
    float ca = cos(angle);
    float sa = sin(angle);
    p = float3(ca * p.x + sa * p.z, p.y, -sa * p.x + ca * p.z);

    CloudVSOut out;
    out.position  = u.viewProjection * float4(p, 1.0);
    out.pointSize = clamp(u.pointSize / max(out.position.w, 0.1), 1.5, 14.0);
    out.color     = float4(depthPalette(p.y * 0.5 + 0.5), 0.95);
    return out;
}

// MARK: - Shared fragment shader

fragment float4 cloudFragment(CloudVSOut in [[stage_in]],
                              float2 pc     [[point_coord]])
{
    float d = length(pc - 0.5) * 2.0;
    if (d > 1.0) {
        discard_fragment();
    }
    float alpha = smoothstep(1.0, 0.55, d);
    return float4(in.color.rgb, in.color.a * alpha);
}
