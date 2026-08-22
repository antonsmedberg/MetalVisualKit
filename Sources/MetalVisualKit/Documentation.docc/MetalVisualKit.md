# ``MetalVisualKit``

Metal-backed SwiftUI components for iOS. Particle integration and point-cloud
unprojection run on the GPU while Swift coordinates lifecycle and compact state.

## Overview

MetalVisualKit contains two components whose per-particle and per-point work runs
on the GPU, wrapped in SwiftUI views that behave like any other view in a layout.

``ParticleProgressView`` drives 1,400 particles through a Metal compute shader.
The shader updates a spring-controlled ring with coherent travelling waves,
restrained curl variation, touch repulsion and a short completion release, then
renders it in one draw call. Swift
prepares compact uniform state and encodes the passes. There is no per-particle
CPU update loop.

The transparent renderer uses additive blending on dark surfaces and
premultiplied source-over compositing on light surfaces. ``ParticleSurfaceStyle``
follows the system colour scheme by default and also offers explicit light and
dark palettes for custom host surfaces.

``LiDARPointCloudView`` binds the ARKit `sceneDepth` map as a texture to the
*vertex* shader. Each of roughly 49,000 vertices samples its own depth pixel,
unprojects through the inverse camera intrinsics and transforms to world space
with the camera pose. Swift validates the AR frame, prepares camera matrices and
binds the textures. It does not read back or individually unproject depth pixels
on the CPU. Procedural orbit is disabled by default so fallback does not take
gestures from a host view; callers can opt in to pan and named VoiceOver rotation
actions.

``PointCloudColorMode`` decides where each point's colour comes from. In the
default `camera` mode the vertex shader also samples `ARFrame.capturedImage` from
the same frame — bound as separate luma and chroma textures, since ARKit delivers
bi-planar YCbCr rather than RGB — and converts to RGB on the GPU. The `depth` and
`confidence` modes keep diagnostic views available when validating the sensor.

### Accessibility

Both components honour **Reduce Motion**. The particle ring uses a static target
without touch repulsion or a completion release, and the demo cloud stops
rotating. Settled particle and demo views draw on demand, while progress and
camera-driven geometry still update. Both views expose an accessibility label;
the loader also publishes its percentage as an accessibility value. An orbitable
demo cloud provides named VoiceOver actions for four rotation directions.

### A note on struct layouts

The uniform structs shared with the shaders are declared once in Swift and once
in Metal Shading Language, with nothing in the compiler linking them.
Drift between the two produces a visual glitch rather than a build failure, so it
is checked two ways: `Scripts/check-struct-parity.py` compares the declarations
directly, and `PipelineTests` pins the resulting strides.

## Topics

### Progress and loading

- ``ParticleProgressView``
- ``ParticleSpinnerView``
- ``ParticleSurfaceStyle``

### Depth visualisation

- ``LiDARPointCloudView``
- ``PointCloudColorMode``
