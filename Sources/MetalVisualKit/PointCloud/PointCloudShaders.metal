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
    float    minConfidence;       // raw ARConfidenceLevel: 0 low, 1 medium, 2 high
};

/// stride 96, align 16 — see PipelineTests.testDemoUniformsStride
struct DemoUniforms {
    float4x4 viewProjection;
    float3   cameraPosition;
    float    time;
    float    pointCount;
    float    pointSize;
    float    motionScale;         // 1 normally, 0 when Reduce Motion is on
};

struct CloudVSOut {
    float4 position  [[position]];
    float  pointSize [[point_size]];
    float4 colour;
};

// MARK: - Depth palette

/// Project-specific near-to-far gradient: deep blue → cyan → violet → coral.
/// Kept small and explicit to avoid an external colour-map dependency.
static float3 depthPalette(float x) {
    x = clamp(x, 0.0, 1.0);
    const float3 nearColour = float3(0.02, 0.06, 0.18);
    const float3 midColour = float3(0.00, 0.86, 1.00);
    const float3 farColour = float3(0.72, 0.24, 0.96);
    const float3 edgeColour = float3(1.00, 0.38, 0.18);

    float3 colour = mix(nearColour, midColour, smoothstep(0.00, 0.38, x));
    colour = mix(colour, farColour, smoothstep(0.32, 0.72, x));
    return mix(colour, edgeColour, smoothstep(0.68, 1.00, x));
}

static float confidenceOpacity(uint level) {
    return level == 0 ? 0.25 : (level == 1 ? 0.55 : 1.0);
}

static float hash11(float x) {
    return fract(sin(x * 127.1) * 43758.5453);
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
        out.colour    = float4(0.0);
        return out;
    }

    // Unproject: depth-map pixel → camera space → world space
    float2 pixel      = uv * u.cameraResolution;
    float3 localPoint = u.intrinsicsInv * float3(pixel, 1.0) * depth;
    float4 world      = u.localToWorld * float4(localPoint, 1.0);

    out.position = u.viewProjection * world;
    float projectedSize = u.pointSize / max(out.position.w, 0.1);
    out.pointSize = clamp(projectedSize, u.pointSize * 0.1875, u.pointSize * 1.5);

    float t = clamp(depth / u.maxDepth, 0.0, 1.0);
    out.colour = float4(depthPalette(t), 0.95 * confidenceOpacity(conf));
    return out;
}

// MARK: - Demo vertex shader (simulator, previews, non-LiDAR devices)

vertex CloudVSOut demoCloudVertex(uint vid                 [[vertex_id]],
                                  constant DemoUniforms &u [[buffer(0)]])
{
    float i = float(vid);
    float n = max(u.pointCount, 1.0);

    // Fibonacci sphere with tiny angular and radial perturbations. They break
    // lattice-to-pixel-grid moiré without changing the visible silhouette.
    float phi    = acos(1.0 - 2.0 * (i + 0.5) / n);
    float golden = M_PI_F * (3.0 - sqrt(5.0));
    float theta  = golden * i;
    phi += (hash11(i * 1.37 + 17.0) - 0.5) * 0.012;
    theta += (hash11(i * 2.17 + 43.0) - 0.5) * 0.020;
    float3 p = float3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta));
    p *= 1.0 + (hash11(i * 0.618033988) - 0.5) * 0.01;

    float angle = u.time * 0.32 * u.motionScale;
    float ca = cos(angle);
    float sa = sin(angle);
    p = float3(ca * p.x + sa * p.z, p.y, -sa * p.x + ca * p.z);
    float3 normal = normalize(p);

    float wave = sin(u.time * 1.4 + p.y * 5.0 + p.x * 3.0);
    float3 world = p * (1.0 + 0.025 * wave * u.motionScale);
    float3 toCamera = normalize(u.cameraPosition - world);
    float facing = clamp(dot(normal, toCamera), 0.0, 1.0);

    const float3 lightDirection = normalize(float3(0.35, 0.55, 0.75));
    float lambert = max(dot(normal, lightDirection), 0.0);
    float rim = pow(1.0 - facing, 3.0);
    float shade = 0.20 + 0.68 * lambert;

    CloudVSOut out;
    out.position = u.viewProjection * float4(world, 1.0);
    float sizeVariance = 0.86 + 0.28 * hash11(i * 7.31);
    out.pointSize = clamp(
        (u.pointSize / max(out.position.w, 0.1)) * sizeVariance * (0.76 + 0.34 * facing),
        1.0,
        48.0
    );

    float cameraDistance = length(u.cameraPosition);
    float pointDistance = distance(world, u.cameraPosition);
    float depth = clamp((pointDistance - (cameraDistance - 1.15)) / 2.30, 0.0, 1.0);
    float3 colour = depthPalette(depth) * shade;
    colour += float3(0.55, 0.80, 1.00) * rim * 0.32;
    out.colour = float4(colour, 0.24 + 0.72 * facing);
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
    float alpha = 1.0 - smoothstep(0.55, 1.0, d);
    return float4(in.colour.rgb, in.colour.a * alpha);
}
