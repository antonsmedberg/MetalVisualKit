//
//  ParticleShaders.metal
//  MetalVisualKit
//
//  GPU particle progress loader.
//
//  One compute pass updates every particle, one draw call renders them all as
//  additive point sprites. The CPU writes a single uniform struct per frame and
//  never touches particle data.
//
//  Struct layouts here are mirrored by hand in ParticleLoaderRenderer.swift.
//  If you edit one side, edit the other — PipelineTests pins the strides.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types (mirrored in ParticleLoaderRenderer.swift)

struct Particle {
    float2 position;   // pixels, drawable space
    float2 velocity;
    float  phase;      // fixed angular slot on the ring, 0..2π
    float  hue;        // 0..1
    float  size;       // base point size in pixels
    float  energy;     // brightness, driven by fill state
};

/// stride 40, align 8 — see PipelineTests.testLoaderUniformsStride
struct LoaderUniforms {
    float2 resolution;   // drawable size in pixels
    float2 touch;        // touch position in pixels
    float  time;         // seconds since renderer start
    float  dt;           // clamped frame delta, seconds
    float  progress;     // 0..1
    float  touchActive;  // 0 or 1
    float  burst;        // 1 → 0 decay after completion
    float  motionScale;  // 1 normally, 0 when Reduce Motion is on
};

// MARK: - Noise

static float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash22(i).x;
    float b = hash22(i + float2(1.0, 0.0)).x;
    float c = hash22(i + float2(0.0, 1.0)).x;
    float d = hash22(i + float2(1.0, 1.0)).x;
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Divergence-free curl of the noise field — swirling motion with no sources
/// or sinks, which is what makes the drift read as organic rather than random.
static float2 curl(float2 p) {
    const float e = 0.75;
    float n1 = vnoise(p + float2(0.0, e));
    float n2 = vnoise(p - float2(0.0, e));
    float n3 = vnoise(p + float2(e, 0.0));
    float n4 = vnoise(p - float2(e, 0.0));
    return normalize(float2(n1 - n2, -(n3 - n4)) + 1e-5);
}

static float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

// MARK: - Compute: physics

kernel void updateParticles(device Particle *particles     [[buffer(0)]],
                            constant LoaderUniforms &u     [[buffer(1)]],
                            uint id                        [[thread_position_in_grid]])
{
    Particle p = particles[id];

    float2 center = u.resolution * 0.5;
    float  radius = min(u.resolution.x, u.resolution.y) * 0.32;

    // Particles whose angular slot falls behind the progress sweep move to the
    // bright outer ring; the rest orbit a dimmer inner one. That difference is
    // the whole "fill" effect — no geometry is added or removed.
    float sweep  = clamp(u.progress, 0.0, 1.0) * 2.0 * M_PI_F;
    float onRing = step(p.phase, sweep);

    float angle        = p.phase + u.time * 0.6 * u.motionScale;
    float targetRadius = mix(radius * 0.55, radius, onRing);
    float2 target      = center + float2(cos(angle), sin(angle)) * targetRadius;

    // Everything below integrates in pixels per second, so the motion is
    // identical at 30, 60 and 120 Hz. Constants are the original 60 Hz values
    // multiplied by 60 to convert "per frame" into "per second".

    // Spring toward the slot
    p.velocity += (target - p.position) * (u.dt * 360.0);

    // Curl-noise drift
    p.velocity += curl(p.position * 0.008 + u.time * 0.15) * (u.dt * 21600.0 * u.motionScale);

    // Magnetic touch repulsion
    if (u.touchActive > 0.5) {
        float2 d    = p.position - u.touch;
        float  dist = length(d) + 1e-3;
        float  f    = clamp(140.0 / dist, 0.0, 8.0);
        p.velocity += (d / dist) * f * (u.dt * 14400.0);
    }

    // Completion burst — radial fling, amplitude decayed CPU-side
    if (u.burst > 0.001) {
        float2 jitter = hash22(float2(float(id), p.hue)) - 0.5;
        float2 dir    = normalize(p.position - center + jitter);
        p.velocity   += dir * u.burst * u.dt * 54000.0 * u.motionScale;
    }

    // Exponential damping expressed per second. A plain `*= 0.90` would decay
    // twice as fast at 120 Hz as at 60 Hz, which is what made the original
    // version look different on ProMotion displays.
    p.velocity *= pow(0.90, u.dt * 60.0);
    p.position += p.velocity * u.dt;
    p.energy    = mix(0.35, 1.0, onRing);

    particles[id] = p;
}

// MARK: - Render: point sprites

struct ParticleVSOut {
    float4 position  [[position]];
    float  pointSize [[point_size]];
    float4 color;
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

    // Velocity is in pixels per second now, roughly 60x its old per-frame
    // magnitude. Feeding it straight into the styling curve would saturate the
    // stretch term almost permanently and inflate every sprite, so convert back
    // to a 60 Hz-equivalent scale here. The physics stays in real units.
    float speedAt60Hz = length(p.velocity) / 60.0;
    out.pointSize = p.size * (1.0 + min(speedAt60Hz * 0.03, 1.2)) * (0.6 + p.energy) * 1.6;

    float3 rgb = hsv2rgb(float3(fract(p.hue + u.time * 0.02 * u.motionScale), 0.72, 1.0));
    out.color  = float4(rgb, 0.9 * p.energy);
    return out;
}

fragment float4 particleFragment(ParticleVSOut in [[stage_in]],
                                 float2 pc        [[point_coord]])
{
    float d     = length(pc - 0.5) * 2.0;
    float alpha = smoothstep(1.0, 0.0, d);
    alpha *= alpha;                       // squared falloff reads softer
    return float4(in.color.rgb * alpha, in.color.a * alpha);
}
