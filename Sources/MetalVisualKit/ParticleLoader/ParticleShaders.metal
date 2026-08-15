//
//  ParticleShaders.metal
//  MetalVisualKit
//
//  GPU particle progress loader.
//
//  One compute pass updates the particles, then one draw call renders them as
//  premultiplied point sprites. The renderer chooses additive blending for dark
//  surfaces and source-over for light ones. Shared layouts mirror Swift.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types (mirrored in ParticleLoaderRenderer.swift)

struct Particle {
    float2 position;   // pixels, drawable space
    float2 velocity;   // pixels per second
    float  phase;      // fixed angular slot on the ring, 0..2π
    float  variation;  // stable per-particle seed, 0..1
    float  size;       // base point size in pixels
    float  energy;     // brightness, driven by fill state
};

/// stride 48, align 8
struct LoaderUniforms {
    float2 resolution;
    float2 touch;
    float  time;
    float  dt;
    float  progress;
    float  touchActive;
    float  burst;
    float  motionScale;
    float  surfaceIsLight;
};

constant float kRingRadiusFraction = 0.40;
constant float kIdleRadiusFactor = 0.94;
constant float kSpringStiffness = 90.0;
constant float kGlobalRotation = 0.22;
constant float kAngularWobble = 0.05;
constant float kRadialWobble = 0.07;
constant float kTouchAcceleration = 1.08e6;
constant float kTouchCeiling = 40000.0;
constant float kBurstAcceleration = 12000.0;

// MARK: - Noise

static float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Central differences over a small fraction of one noise cell.
static float2 curl(float2 p) {
    const float e = 0.05;
    float dx = (vnoise(p + float2(e, 0.0)) - vnoise(p - float2(e, 0.0))) / (2.0 * e);
    float dy = (vnoise(p + float2(0.0, e)) - vnoise(p - float2(0.0, e))) / (2.0 * e);
    return float2(dy, -dx);
}

// MARK: - Compute: physics

kernel void updateParticles(device Particle *particles     [[buffer(0)]],
                            constant LoaderUniforms &u     [[buffer(1)]],
                            uint id                        [[thread_position_in_grid]])
{
    Particle p = particles[id];

    float2 center = u.resolution * 0.5;
    float ring = min(u.resolution.x, u.resolution.y) * kRingRadiusFraction;
    float progress = clamp(u.progress, 0.0, 1.0);
    float sweep = progress * 2.0 * M_PI_F;

    float fill = 0.0;
    if (progress >= 1.0) {
        fill = 1.0;
    } else if (progress > 0.0) {
        fill = 1.0 - smoothstep(sweep - 0.08, sweep + 0.08, p.phase);
    }

    // Coherent waves provide the ring structure. The hashed stable variation
    // keeps curl secondary and prevents neighbouring slots sharing a noise cell.
    float seed = hash21(float2(p.variation * 997.0, p.variation * 313.0)) * 53.0;
    float2 flow = curl(float2(seed * 0.11 + u.time * 0.05,
                              seed * 0.07 - u.time * 0.04));
    float angle = p.phase + u.time * kGlobalRotation * u.motionScale;
    float angularWave = sin(p.phase * 3.0 + u.time * 0.35) * 0.5;
    angle += (angularWave + flow.x * 0.35) * kAngularWobble * u.motionScale;

    float radius = mix(ring * kIdleRadiusFactor, ring, fill);
    float radialNoise = sin(p.phase * 2.0 - u.time * 0.45) * 0.5 + flow.y * 0.35;
    radius *= 1.0 + radialNoise * kRadialWobble * u.motionScale;

    float2 target = center + float2(cos(angle), sin(angle)) * radius;
    if (u.motionScale <= 0.0) {
        p.position = target;
        p.velocity = float2(0.0);
        p.energy = fill;
        particles[id] = p;
        return;
    }

    float damping = 2.0 * sqrt(kSpringStiffness);
    float2 accel = (target - p.position) * kSpringStiffness - p.velocity * damping;

    // Magnetic touch repulsion
    if (u.touchActive > 0.5) {
        float2 d = p.position - u.touch;
        float dist = max(length(d), 1.0);
        accel += (d / dist) * min(kTouchAcceleration / dist, kTouchCeiling);
    }

    // Completion burst — radial fling, amplitude decayed CPU-side
    if (u.burst > 0.001) {
        float2 outward = p.position - center;
        float lengthFromCenter = max(length(outward), 1.0);
        accel += (outward / lengthFromCenter) * u.burst * kBurstAcceleration * u.motionScale;
    }

    // Semi-implicit Euler is stable for the clamped timestep used by the renderer.
    p.velocity += accel * u.dt;
    p.position += p.velocity * u.dt;
    p.energy = fill;

    particles[id] = p;
}

// MARK: - Palette

constant float3 kIdleColour = float3(0.34, 0.46, 0.82);
constant float3 kTailColour = float3(0.18, 0.26, 0.62);
constant float3 kMidColour = float3(0.20, 0.72, 0.94);
constant float3 kHeadColour = float3(0.88, 0.96, 1.00);
constant float3 kGlowColour = float3(1.00, 0.86, 0.62);
constant float3 kLightIdleColour = float3(0.12, 0.18, 0.46);
constant float3 kLightTailColour = float3(0.08, 0.12, 0.38);
constant float3 kLightMidColour = float3(0.00, 0.42, 0.68);
constant float3 kLightHeadColour = float3(0.05, 0.12, 0.30);
constant float3 kLightGlowColour = float3(0.76, 0.38, 0.08);

static float3 arcColour(float t) {
    return t < 0.5 ? mix(kTailColour, kMidColour, t * 2.0)
                   : mix(kMidColour, kHeadColour, (t - 0.5) * 2.0);
}

static float3 lightArcColour(float t) {
    return t < 0.5 ? mix(kLightTailColour, kLightMidColour, t * 2.0)
                   : mix(kLightMidColour, kLightHeadColour, (t - 0.5) * 2.0);
}

// MARK: - Render

struct ParticleVSOut {
    float4 position  [[position]];
    float  pointSize [[point_size]];
    float4 colour;
};

vertex ParticleVSOut particleVertex(const device Particle *particles [[buffer(0)]],
                                    constant LoaderUniforms &u       [[buffer(1)]],
                                    uint vid                         [[vertex_id]])
{
    Particle p = particles[vid];

    float2 ndc = (p.position / u.resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    ParticleVSOut out;
    out.position = float4(ndc, 0.0, 1.0);

    float sweep = clamp(u.progress, 0.0, 1.0) * 2.0 * M_PI_F;
    float angularDistance = atan2(sin(p.phase - sweep), cos(p.phase - sweep));
    float toHead = angularDistance * 5.0;
    float head = exp(-toHead * toHead) * p.energy * step(0.001, u.progress);
    float along = clamp(p.phase / max(sweep, 1e-3), 0.0, 1.0);
    float lightSurface = step(0.5, u.surfaceIsLight);
    float3 darkRGB = mix(kIdleColour, arcColour(along), p.energy);
    darkRGB = saturate(darkRGB + kGlowColour * head * 0.9);
    float3 lightRGB = mix(kLightIdleColour, lightArcColour(along), p.energy);
    lightRGB = saturate(lightRGB + kLightGlowColour * head * 0.35);
    float3 rgb = mix(darkRGB, lightRGB, lightSurface);

    float stretch = 1.0 + min(length(p.velocity) / 900.0, 0.8);
    out.pointSize = p.size * stretch * (0.95 + 0.55 * p.energy + 0.9 * head);
    float darkOpacity = saturate(0.58 + 0.32 * p.energy + 0.10 * head);
    float lightOpacity = saturate(0.72 + 0.23 * p.energy + 0.05 * head);
    float opacity = mix(darkOpacity, lightOpacity, lightSurface);
    out.colour = float4(rgb, opacity);
    return out;
}

fragment float4 particleFragment(ParticleVSOut in [[stage_in]],
                                 float2 pc        [[point_coord]])
{
    float d = length(pc - 0.5) * 2.0;
    float core = 1.0 - smoothstep(0.25, 1.0, d);
    float halo = (1.0 - smoothstep(0.0, 1.0, d)) * 0.35;
    float coverage = saturate(core * core + halo);
    float alpha = saturate(in.colour.a) * coverage;
    return float4(saturate(in.colour.rgb) * alpha, alpha);
}
