    //
    //  PointCloudShaders.metal
    //  MetalVisualKit
    //
    //  Live LiDAR point-cloud rendering and the procedural spatial scanning orb.
    //
    //  Live depth points are unprojected entirely on the GPU. Camera colour,
    //  confidence and depth information remain aligned to the same AR frame.
    //
    //  Struct layouts are mirrored by hand in PointCloudTypes.swift and validated
    //  by GPUDataLayoutTests plus Scripts/check-struct-parity.py.
    //

#include <metal_stdlib>
using namespace metal;

    // MARK: - Shared Types

    /// stride 208, align 16
struct CloudUniforms {
    float4x4 viewProjection;
    float4x4 localToWorld;
    float3x3 intrinsicsInv;
    float2 cameraResolution;
    float2 gridResolution;
    float pointSize;
    float maxDepth;
    float minConfidence;
    float colorMode;
};

    /// stride 96, align 16
struct DemoUniforms {
    float4x4 viewProjection;
    float3 cameraPosition;
    float time;
    float pointCount;
    float pointSize;
    float motionScale;
};

struct CloudVSOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 colour;
};

    // MARK: - Constants

constant float kColorModeCamera = 0.0;
constant float kColorModeDepth = 1.0;

    // MARK: - Hash

static float hash11(float x) {
    return fract(
                 sin(x * 127.1)
                 * 43758.5453
                 );
}

    // MARK: - Live Palettes

    /// Live near-to-far diagnostic gradient.
    ///
    /// The stronger violet/coral endpoint remains useful for depth inspection and
    /// intentionally stays separate from the calmer showcase demo palette.
static float3 depthPalette(float x) {
    x = clamp(
              x,
              0.0,
              1.0
              );

    const float3 nearColour =
    float3(
           0.02,
           0.06,
           0.18
           );

    const float3 midColour =
    float3(
           0.00,
           0.86,
           1.00
           );

    const float3 farColour =
    float3(
           0.72,
           0.24,
           0.96
           );

    const float3 edgeColour =
    float3(
           1.00,
           0.38,
           0.18
           );

    float3 colour = mix(
                        nearColour,
                        midColour,
                        smoothstep(
                                   0.00,
                                   0.38,
                                   x
                                   )
                        );

    colour = mix(
                 colour,
                 farColour,
                 smoothstep(
                            0.32,
                            0.72,
                            x
                            )
                 );

    return mix(
               colour,
               edgeColour,
               smoothstep(
                          0.68,
                          1.00,
                          x
                          )
               );
}

    /// Traffic-light reading of ARKit confidence levels.
static float3 confidencePalette(uint level) {
    if (level == 0u) {
        return float3(
                      0.95,
                      0.26,
                      0.22
                      );
    }

    if (level == 1u) {
        return float3(
                      0.98,
                      0.72,
                      0.18
                      );
    }

    return float3(
                  0.20,
                  0.85,
                  0.45
                  );
}

static float confidenceOpacity(uint level) {
    if (level == 0u) {
        return 0.25;
    }

    if (level == 1u) {
        return 0.55;
    }

    return 1.0;
}

    // MARK: - Spatial Demo Palette

    /// Calmer showcase palette used only by the procedural demo.
    ///
    /// Deep navy → electric blue → cyan → restrained violet keeps the preview
    /// spatial and technical without turning it into a diagnostic heat map.
static float3 demoPalette(float x) {
    x = saturate(x);

    const float3 deep =
    float3(
           0.025,
           0.055,
           0.145
           );

    const float3 blue =
    float3(
           0.070,
           0.350,
           0.980
           );

    const float3 cyan =
    float3(
           0.080,
           0.790,
           0.960
           );

    const float3 violet =
    float3(
           0.430,
           0.280,
           0.900
           );

    float3 colour = mix(
                        deep,
                        blue,
                        smoothstep(
                                   0.00,
                                   0.34,
                                   x
                                   )
                        );

    colour = mix(
                 colour,
                 cyan,
                 smoothstep(
                            0.28,
                            0.66,
                            x
                            )
                 );

    return mix(
               colour,
               violet,
               smoothstep(
                          0.72,
                          1.00,
                          x
                          )
               );
}

    // MARK: - Camera Colour

    /// Full-range YCbCr to RGB.
    ///
    /// ARKit captures full-range ITU-R BT.601 values, so video-range scaling must
    /// not be applied here.
static float3 cameraColour(
                           texture2d<float, access::sample> luma,
                           texture2d<float, access::sample> chroma,
                           float2 uv
                           ) {
    constexpr sampler cameraSampler(
                                    filter::linear,
                                    address::clamp_to_edge
                                    );

    const float4x4 ycbcrToRGB =
    float4x4(
             float4(
                    +1.0000,
                    +1.0000,
                    +1.0000,
                    +0.0000
                    ),
             float4(
                    +0.0000,
                    -0.3441,
                    +1.7720,
                    +0.0000
                    ),
             float4(
                    +1.4020,
                    -0.7141,
                    +0.0000,
                    +0.0000
                    ),
             float4(
                    -0.7010,
                    +0.5291,
                    -0.8860,
                    +1.0000
                    )
             );

    float4 ycbcr =
    float4(
           luma.sample(
                       cameraSampler,
                       uv
                       ).r,
           chroma.sample(
                         cameraSampler,
                         uv
                         ).rg,
           1.0
           );

    return saturate(
                    (
                     ycbcrToRGB
                     * ycbcr
                     ).rgb
                    );
}

    // MARK: - Live LiDAR Vertex Shader

vertex CloudVSOut pointCloudVertex(
                                   uint vid [[vertex_id]],
                                   constant CloudUniforms &u [[buffer(0)]],
                                   texture2d<float, access::read> depthTex [[texture(0)]],
                                   texture2d<uint, access::read> confTex [[texture(1)]],
                                   texture2d<float, access::sample> cameraY [[texture(2)]],
                                   texture2d<float, access::sample> cameraCbCr [[texture(3)]]
                                   ) {
    uint gridWidth =
    uint(
         u.gridResolution.x
         );

    uint2 coord =
    uint2(
          vid % gridWidth,
          vid / gridWidth
          );

    float2 uv =
    (
     float2(coord)
     + 0.5
     )
    / u.gridResolution;

    float depth =
    depthTex
        .read(coord)
        .r;

    uint conf =
    confTex
        .read(coord)
        .r;

    CloudVSOut out;

    if (
        !isfinite(depth)
        || depth < 0.05
        || depth > u.maxDepth
        || conf < uint(u.minConfidence)
        ) {
            out.position =
            float4(
                   0.0,
                   0.0,
                   -2.0,
                   1.0
                   );

            out.pointSize = 0.0;
            out.colour = float4(0.0);

            return out;
        }

        // Depth-map pixel -> camera space -> world space.
    float2 pixel =
    uv
    * u.cameraResolution;

    float3 localPoint =
    u.intrinsicsInv
    * float3(
             pixel,
             1.0
             )
    * depth;

    float4 world =
    u.localToWorld
    * float4(
             localPoint,
             1.0
             );

    out.position =
    u.viewProjection
    * world;

    float projectedSize =
    u.pointSize
    / max(
          out.position.w,
          0.1
          );

    out.pointSize =
    clamp(
          projectedSize,
          u.pointSize * 0.1875,
          u.pointSize * 1.5
          );

    float3 colour;

    if (
        u.colorMode
        < kColorModeCamera + 0.5
        ) {
            colour =
            cameraColour(
                         cameraY,
                         cameraCbCr,
                         uv
                         );
        } else if (
                   u.colorMode
                   < kColorModeDepth + 0.5
                   ) {
                       colour =
                       depthPalette(
                                    clamp(
                                          depth / u.maxDepth,
                                          0.0,
                                          1.0
                                          )
                                    );
                   } else {
                       colour =
                       confidencePalette(
                                         conf
                                         );
                   }

    out.colour =
    float4(
           colour,
           0.95
           * confidenceOpacity(
                               conf
                               )
           );

    return out;
}

    // MARK: - Spatial Scanning Orb

vertex CloudVSOut demoCloudVertex(
                                  uint vid [[vertex_id]],
                                  constant DemoUniforms &u [[buffer(0)]]
                                  ) {
    float i =
    float(vid);

    float n =
    max(
        u.pointCount,
        1.0
        );

        // Fibonacci sphere -------------------------------------------------------
        //
        // The distribution remains deterministic and uniform. Small independent
        // angular perturbations suppress visible raster/grid moiré while
        // preserving the spherical silhouette.

    float normalizedIndex =
    (
     i + 0.5
     )
    / n;

    float phi =
    acos(
         1.0
         - 2.0
         * normalizedIndex
         );

    const float goldenAngle =
    M_PI_F
    * (
       3.0
       - sqrt(5.0)
       );

    float theta =
    goldenAngle
    * i;

    phi +=
    (
     hash11(
            i * 1.37
            + 17.0
            )
     - 0.5
     )
    * 0.011;

    theta +=
    (
     hash11(
            i * 2.17
            + 43.0
            )
     - 0.5
     )
    * 0.018;

    float3 p =
    float3(
           sin(phi) * cos(theta),
           cos(phi),
           sin(phi) * sin(theta)
           );

        // Tiny shell variation gives the cloud physical depth rather than a
        // perfectly mathematical surface.
    float shellVariation =
    (
     hash11(
            i * 0.618033988
            + 11.0
            )
     - 0.5
     )
    * 0.012;

    p *=
    1.0
    + shellVariation;

        // Slow global rotation --------------------------------------------------

    float rotationAngle =
    u.time
    * 0.24
    * u.motionScale;

    float ca =
    cos(
        rotationAngle
        );

    float sa =
    sin(
        rotationAngle
        );

    p =
    float3(
           ca * p.x
           + sa * p.z,
           p.y,
           -sa * p.x
           + ca * p.z
           );

        // Organic spatial surface -----------------------------------------------
        //
        // Two low-amplitude harmonics avoid the repetitive "breathing sphere"
        // appearance of a single sine wave while keeping the silhouette stable.

    float primaryWave =
    sin(
        u.time * 1.05
        + p.y * 4.8
        + p.x * 2.7
        );

    float secondaryWave =
    sin(
        u.time * 0.67
        - p.z * 6.1
        + p.y * 2.2
        );

    float displacement =
    primaryWave * 0.017
    + secondaryWave * 0.007;

    float3 world =
    p
    * (
       1.0
       + displacement
       * u.motionScale
       );

    float3 normal =
    normalize(world);

        // Spatial scan band ------------------------------------------------------
        //
        // A restrained horizontal band communicates scanning without introducing
        // a hard neon laser line.

    float scanPhase =
    u.time
    * 0.52
    * u.motionScale;

    float scanPosition =
    sin(
        scanPhase
        )
    * 0.62;

    float scanDistance =
    abs(
        world.y
        - scanPosition
        );

    float scanBand =
    exp(
        -scanDistance
        * scanDistance
        * 92.0
        );

        // Lighting ---------------------------------------------------------------

    float3 toCamera =
    normalize(
              u.cameraPosition
              - world
              );

    float facing =
    saturate(
             dot(
                 normal,
                 toCamera
                 )
             );

    const float3 lightDirection =
    normalize(
              float3(
                     0.30,
                     0.58,
                     0.76
                     )
              );

    float lambert =
    max(
        dot(
            normal,
            lightDirection
            ),
        0.0
        );

    float rim =
    pow(
        1.0 - facing,
        2.6
        );

    float shade =
    0.22
    + 0.66
    * lambert;

        // Projection -------------------------------------------------------------

    CloudVSOut out;

    out.position =
    u.viewProjection
    * float4(
             world,
             1.0
             );

        // Point-size variation keeps the surface from reading as a repeated grid.
    float sizeVariance =
    0.84
    + 0.30
    * hash11(
             i * 7.31
             + 3.0
             );

    float scanSizeBoost =
    1.0
    + scanBand
    * 0.14;

    float perspectivePointSize =
    (
     u.pointSize
     / max(
           out.position.w,
           0.1
           )
     )
    * sizeVariance
    * (
       0.78
       + 0.30
       * facing
       )
    * scanSizeBoost;

    out.pointSize =
    clamp(
          perspectivePointSize,
          1.0,
          42.0
          );

        // Demo colour ------------------------------------------------------------

    float cameraDistance =
    length(
           u.cameraPosition
           );

    float pointDistance =
    distance(
             world,
             u.cameraPosition
             );

    float depth =
    clamp(
          (
           pointDistance
           - (
              cameraDistance
              - 1.15
              )
           )
          / 2.30,
          0.0,
          1.0
          );

    float3 colour =
    demoPalette(depth)
    * shade;

        // Soft blue rim gives the sphere separation from the dark background.
    colour +=
    float3(
           0.28,
           0.66,
           1.00
           )
    * rim
    * 0.20;

        // Scan-band highlight.
    colour +=
    float3(
           0.20,
           0.88,
           1.00
           )
    * scanBand
    * 0.18;

        // A very sparse set of slightly brighter points prevents the shell from
        // looking perfectly uniform without adding random temporal flicker.
    float sparkle =
    smoothstep(
               0.972,
               1.0,
               hash11(
                      i * 11.93
                      + 19.0
                      )
               );

    colour +=
    float3(
           0.32,
           0.72,
           1.00
           )
    * sparkle
    * 0.10;

    float alpha =
    clamp(
          0.20
          + 0.70
          * facing
          + 0.06
          * scanBand,
          0.18,
          0.96
          );

    out.colour =
    float4(
           colour,
           alpha
           );

    return out;
}

    // MARK: - Shared Point Sprite

fragment float4 cloudFragment(
                              CloudVSOut in [[stage_in]],
                              float2 pointCoordinate [[point_coord]]
                              ) {
    float2 centered =
    pointCoordinate
    - 0.5;

    float radius =
    length(centered)
    * 2.0;

        // Soft circular body.
    float body =
    1.0
    - smoothstep(
                 0.54,
                 1.0,
                 radius
                 );

        // Small bright centre gives each point a more precise scan/sensor quality
        // without requiring a bloom pass or additional render target.
    float core =
    1.0
    - smoothstep(
                 0.0,
                 0.30,
                 radius
                 );

    float alpha =
    in.colour.a
    * body;

        // Blending is enabled while the depth buffer still writes. Invisible
        // fragments therefore need to be discarded rather than merely given zero
        // alpha, otherwise they could occlude particles behind them.
    if (alpha < 0.02) {
        discard_fragment();
    }

    float coreBrightness =
    1.0
    + core
    * 0.14;

    float3 colour =
    saturate(
             in.colour.rgb
             * coreBrightness
             );

    return float4(
                  colour,
                  alpha
                  );
}
