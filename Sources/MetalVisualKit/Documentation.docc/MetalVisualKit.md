# ``MetalVisualKit``

Metal-backed SwiftUI components for iOS. Particle integration and point-cloud
unprojection run on the GPU while Swift coordinates lifecycle and compact state.

## Overview

MetalVisualKit contains two components whose per-particle and per-point work runs
on the GPU, wrapped in SwiftUI views that behave like any other view in a layout.

``ParticleProgressView`` drives 1,400 particles through a Metal compute shader
each frame — curl-noise drift, spring targeting toward a ring swept by the bound
progress value, touch repulsion, and a completion burst — then renders them as
additive point sprites in a single draw call. No SwiftUI view is created per
particle; the CPU writes one 40-byte uniform struct per frame and nothing else.

``LiDARPointCloudView`` binds the ARKit `sceneDepth` map as a texture to the
*vertex* shader. Each of roughly 49,000 vertices samples its own depth pixel,
unprojects through the inverse camera intrinsics, transforms to world space with
the camera pose, and colours itself by depth. Point data never touches the CPU.

### Accessibility

Both components honour **Reduce Motion**: drift, rotation and the completion
burst are scaled to zero rather than the view being replaced, so a progress value
still reads correctly. Both expose an accessibility label and value.

### A note on struct layouts

The uniform structs shared with the shaders are declared twice — once in Swift,
once in Metal Shading Language — with nothing in the compiler linking them.
Drift between the two produces a visual glitch rather than a build failure, so it
is checked two ways: `Scripts/check-struct-parity.py` compares the declarations
directly, and `PipelineTests` pins the resulting strides.

## Topics

### Progress and loading

- ``ParticleProgressView``
- ``ParticleSpinnerView``

### Depth visualisation

- ``LiDARPointCloudView``
