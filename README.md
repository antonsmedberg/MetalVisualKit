# MetalVisualKit

MetalVisualKit is an MIT-licensed Swift package exploring GPU-first UI on iOS:
SwiftUI owns the view lifecycle while Metal handles the per-particle and
per-point work. It contains a particle progress renderer and a LiDAR point cloud,
both exposed as SwiftUI views.

[![Build](https://github.com/antonsmedberg/MetalVisualKit/actions/workflows/build.yml/badge.svg)](https://github.com/antonsmedberg/MetalVisualKit/actions/workflows/build.yml)
![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-6.0%20tools-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

> **Pre-release.** Xcode 26.6 builds the package, the current test suite, the
> example app and its DocC archive. The loader below ran in an iOS 26.5 simulator.
> Live capture has not run on physical LiDAR hardware, so the camera-colour path
> is not yet verified end to end. Nothing is tagged; see [CHANGELOG](CHANGELOG.md).

<p align="center">
  <img src="Media/loader-simulator.png" width="320" alt="MetalVisualKit particle loader running in the iOS simulator">
</p>
<p align="center"><sub>Verified simulator build; the image is not a LiDAR hardware claim.</sub></p>

<!-- Media/particle-loader.gif and Media/point-cloud.gif go here once recorded
     on device. See Media/README.md. Broken image links are worse than none. -->

## Why I built it

I wanted to see how much frame-by-frame work could stay on the GPU without
turning the public API into a Metal project. The first loader pass looked busy
but wrong: its velocity had moved to pixels per second while the styling curve
still assumed per-frame values, so every sprite hit the size cap. Fixing that
made the timing and visual structure much easier to reason about.

The point cloud started as a depth-only gradient. It now samples the camera image
from the same AR frame, so each point can use the room's own colour while depth
and confidence views remain available for diagnostics.

## Open in Xcode

This repository contains two related products:

| Item | Purpose | Location |
|---|---|---|
| `MetalVisualKit` | Reusable Swift Package Manager library | `Sources/MetalVisualKit` |
| `MetalVisualKitDemo` | Example iOS app that consumes the local package | `Examples/MetalVisualKitDemo` |

For development, open the committed workspace rather than opening
`Package.swift` and the demo project in separate Xcode windows:

```sh
git clone https://github.com/antonsmedberg/MetalVisualKit.git
cd MetalVisualKit
xed Examples/MetalVisualKit.xcworkspace
```

Select the **MetalVisualKitDemo** scheme and an iOS simulator. Xcode shows the
library under **Package Dependencies → MetalVisualKit** because the app consumes
the local package at `../..`. Its source remains in `Sources/MetalVisualKit`.

For SwiftUI previews, keep **MetalVisualKitDemo** active. Selecting SwiftPM's
library-only `MetalVisualKit` scheme while viewing a demo source file produces
"Active scheme does not build this file" because that scheme intentionally does
not contain the example app.

## Verify on a LiDAR device

The simulator shows the procedural fallback only. To verify the live path, run
the demo on a LiDAR-capable iPhone or iPad and grant camera permission. Start in
**Depth**, move around a room, and rotate through portrait and both landscape
orientations. Then switch to **Camera** and inspect edges while moving; colour
that drifts away from geometry indicates a registration or orientation issue.

Use an Xcode release that supports the device's installed iOS version. Keep the
existing depth path as the baseline before diagnosing camera colour.

## Install

In Xcode, choose **File → Add Package Dependencies**:

```
https://github.com/antonsmedberg/MetalVisualKit
```

No version is tagged yet, so select the `main` branch in Xcode, or:

```swift
.package(url: "https://github.com/antonsmedberg/MetalVisualKit", branch: "main")
```

Once v0.1.0 exists, `from: "0.1.0"` will be the right form.

## Usage

```swift
import MetalVisualKit

// Determinate: pass any progress value
ParticleProgressView(progress: exportProgress, title: "Exporting")
    .frame(width: 320, height: 320)

// Explicit styling when a custom surface differs from the system colour scheme
ParticleProgressView(
    progress: exportProgress,
    surfaceStyle: .light,
    labelColor: .black
)

// Indeterminate
ParticleSpinnerView()
    .frame(width: 240, height: 240)

// Live depth in camera colour, with automatic fallback
LiDARPointCloudView(displayMode: .live, colorMode: .camera)

// Diagnostic colouring, with demo orbit explicitly enabled
LiDARPointCloudView(
    displayMode: .live,
    colorMode: .confidence,
    allowsOrbitInteraction: true
)
```

`colorMode` sets the initial colour source. When controls are visible, the
segmented control can switch between camera, depth and confidence at runtime.

| Mode | Shows | Useful for |
|---|---|---|
| `.camera` | Camera colour sampled per point | Reading the reconstructed room |
| `.depth` | Near-to-far gradient | Checking range and geometry |
| `.confidence` | Amber medium and green high; low samples are hidden | Checking sensor quality |

The loader draws on a transparent drawable. Dark surfaces use additive glow;
light surfaces use premultiplied source-over compositing so particles retain
contrast over bright content. `.automatic` follows the system colour scheme. Use
`.light` or `.dark` when the host surface differs, and optionally set `labelColor`
for the centre text.

## Architecture

**Particle loader.** One compute pass updates 1,400 particles around a
spring-controlled ring. Coherent travelling waves lead the motion while curl
noise adds restrained variation; touch can repel the particles, and completion
triggers a short radial release. One
`drawPrimitives(.point)` call renders the result. Swift prepares a compact uniform
struct and encodes the compute and render passes; it does not loop over particles.

**Point cloud.** The ARKit `sceneDepth` map is bound as a texture to the
*vertex* shader rather than read back. A 256×192 map produces roughly 49,000
vertices. Each vertex samples its depth pixel, unprojects through the inverse
camera intrinsics and transforms to world space with the camera pose. Invalid,
out-of-range and low-confidence samples are culled behind the near plane.

**Camera colour.** `ARFrame.capturedImage` from the same frame is bound as luma
and chroma textures. The vertex shader converts full-range YCbCr to RGB and uses
the depth coordinate to sample camera colour. If the camera planes cannot be
bound, that frame falls back to the depth palette instead of disappearing.

The point-cloud implementation is split by responsibility:

| File | Responsibility |
|---|---|
| `LiDARPointCloudView.swift` | Public SwiftUI API, permission and controls |
| `PointCloudMetalView.swift` | `UIViewRepresentable`, lifecycle and gestures |
| `PointCloudRenderer.swift` | Draw loop and uniform assembly |
| `ARFrameTextures.swift` | Core Video to Metal texture binding |
| `PointCloudSessionMonitor.swift` | AR session state and user guidance |
| `PointCloudShaders.metal` | Unprojection, colour modes and sprite rendering |

`PointCloudSessionMonitor` distinguishes normal tracking, limited tracking,
interruptions and failures so an empty surface is not the only error signal.

## Accessibility

Both components respect **Reduce Motion**. It freezes decorative particle motion
and procedural cloud animation while leaving progress and camera-driven geometry
intact. Settled particle and procedural demo views switch to on-demand drawing
instead of redrawing static frames. Both components expose accessibility labels;
the loader also publishes its percentage to VoiceOver. When procedural orbit is
enabled, the cloud exposes named VoiceOver actions for rotating left, right, up
and down. The live cloud's accessibility label also identifies its colour mode.

## Current rendering defaults

| Knob | Where | Default |
|---|---|---|
| Particle count | `ParticleLoaderRenderer(view:particleCount:)` | 1,400 |
| Frame rate | `MTKView.preferredFramesPerSecond` | 60 |
| Ring radius | `ParticleShaders.metal` | 40% of the shorter side |
| Particle surface | `ParticleSurfaceStyle` | automatic, with explicit light/dark overrides |
| Particle palette | `particleVertex` | surface-aware indigo/cyan arc and sweep head |
| Colour mode | `LiDARPointCloudView(colorMode:)` | `.camera` |
| Max scan depth | `LiDARPointCloudView` slider / `maxDepth` | 5 m |
| Confidence floor | `CloudUniforms.minConfidence` | 1 (raw `ARConfidenceLevel`, drops *low*) |
| Point size | `CloudUniforms.pointSize` | 8 layout points, scaled to drawable pixels |
| Depth colour map | `depthPalette()` in `PointCloudShaders.metal` | blue → cyan → violet → coral |
| Camera conversion | `cameraColour()` in `PointCloudShaders.metal` | full-range BT.601 → RGB |

## Requirements

- **iOS 17+** deployment target and Swift tools 6.0.
- The package currently builds with the iOS 26 SDK because the control surface
  uses `glassEffect` behind an iOS 26 availability check.
- CI currently builds with Xcode 26.6 and the iOS 26 SDK. Older compatible Xcode
  versions are not part of the tested matrix.
- Swift 5 language mode by default. See *Swift 6 migration* below.
- Live depth requires a device with a LiDAR scanner. Without one, and in the
  simulator, `LiDARPointCloudView` falls back to a procedural Fibonacci-sphere
  cloud, so previews and the demo app still show something real.
- Procedural orbit is opt-in through `allowsOrbitInteraction` so automatic
  fallback does not compete with gestures owned by a host view.
- The host app must declare `NSCameraUsageDescription` for live mode.

## Swift 6 migration

The package uses the Swift 6 toolchain with Swift 5 language mode configured.
The remaining migration work sits around framework callbacks such as
`MTKViewDelegate` and Metal command-buffer completion handlers.

CI runs a non-blocking lane that rewrites `.swiftLanguageMode(.v5)` to `.v6` in
its disposable checkout, then builds with `SWIFT_STRICT_CONCURRENCY=complete`.
`make swift6` performs the same build in a disposable local copy, leaving the
working manifest untouched.
When the advisory build has no concurrency diagnostics, change
`.swiftLanguageMode(.v5)` to `.v6` in `Package.swift`.

## Known limitations

- **No physical LiDAR validation yet.** Only the portrait path has been worked
  through carefully, and no orientation has been confirmed on hardware. Depth
  registration, camera permission recovery, thermal behaviour and GPU frame time
  still need device testing. The orientation derivation follows Apple's
  *Visualizing a Point Cloud Using Scene Depth* sample.
- **Camera colour is unverified on hardware.** Pixel formats and the conversion
  matrix follow Apple's documentation, but colour cast, orientation and
  camera-to-depth registration still need a real-device pass.
- **Uniform struct layouts are mirrored by hand** between Swift and MSL. Editing
  one side without the other produces a visual glitch rather than a crash.
  `Scripts/check-struct-parity.py` compares the two declarations directly and
  `PipelineTests` pins the resulting strides; both run in CI.
- The point cloud accumulates nothing between frames. It visualises the current
  depth frame, it does not build a persistent scan.
- No adaptive quality policy. Point density, sprite size and frame rate are
  fixed until device profiling provides data for a useful policy.

## Development

```
make build     # build for the iOS simulator
make test      # pipeline, layout, lifecycle, projection and compute tests
make parity    # layouts + shaders + media + simulator/workspace checks
make demo      # build the committed workspace and example app
make project   # regenerate the project after editing project.yml
make icon      # regenerate the opaque example-app icon
make lint      # SwiftLint
make docs      # DocC archive
```

The example app lives in [`Examples/MetalVisualKitDemo`](Examples/MetalVisualKitDemo) and
depends on the package by relative path, so it always builds against the working
copy.

Use the demo app for the Xcode Metal Debugger. SwiftPM generates the package
`default.metallib`, and command-line `swift test` may not resolve that bundle on
hosts without a GPU-backed Apple toolchain. CI runs the tests with `xcodebuild`
against an installed simulator.

The `rendering` signpost category records particle compute encoding, particle
render encoding, AR-frame preparation and point-cloud render encoding. Inspect
these intervals in Instruments before making performance claims.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the Xcode
setup, rendering invariants, verification commands and pull-request expectations.
Use the structured issue forms for reproducible bugs and focused proposals, and
discuss larger API or renderer changes before implementation.

Please report vulnerabilities privately according to
[SECURITY.md](SECURITY.md). Participation is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Privacy

The package collects nothing, tracks nobody, performs no networking and uses no
required-reason APIs. Camera frames become Metal textures for rendering; they are
not copied to the CPU, written to disk or sent anywhere.
`Sources/MetalVisualKit/PrivacyInfo.xcprivacy` declares this. Camera permission
stays the host app's responsibility.

## Attribution

The camera-orientation transform follows Apple's *Visualizing a Point Cloud
Using Scene Depth* sample. The YCbCr conversion uses the coefficients documented
for full-range camera capture. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for details.

## License

MIT. See [LICENSE](LICENSE).
