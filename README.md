# MetalVisualKit

Metal-backed SwiftUI components for iOS. Particle integration and point-cloud
unprojection run on the GPU; Swift coordinates lifecycle, resources and compact
per-frame state.

[![Build](https://github.com/antonsmedberg/MetalVisualKit/actions/workflows/build.yml/badge.svg)](https://github.com/antonsmedberg/MetalVisualKit/actions/workflows/build.yml)
![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-6.0%20tools-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

> **Pre-release.** Xcode 26.6 builds the package, all 15 tests, the example app
> and its DocC archive. The loader below ran in an iOS 26.5 simulator. Live
> capture has not run on physical LiDAR hardware. Nothing is tagged; see
> [CHANGELOG](CHANGELOG.md).

<p align="center">
  <img src="Media/loader-simulator.png" width="320" alt="MetalVisualKit particle loader running in the iOS simulator">
</p>
<p align="center"><sub>Verified simulator build; the image is not a LiDAR hardware claim.</sub></p>

<!-- Media/particle-loader.gif and Media/point-cloud.gif go here once recorded
     on device. See Media/README.md. Broken image links are worse than none. -->

## Install

Swift Package Manager — in Xcode, **File → Add Package Dependencies**:

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

// Determinate — pass any progress value
ParticleProgressView(progress: exportProgress, title: "Exporting")
    .frame(width: 320, height: 320)

// Indeterminate
ParticleSpinnerView()
    .frame(width: 240, height: 240)

// Live depth, with automatic fallback to the demo cloud
LiDARPointCloudView(displayMode: .live)
```

The loader draws on a transparent drawable, so it composites over video
thumbnails, blurred surfaces or anything else beneath it.

## How it works

**Particle loader.** One compute pass per frame updates 1,400 particles: each is
sprung toward a ring swept by the bound progress value, drifts on curl noise, is
repelled by touch, and bursts at completion. A single `drawPrimitives(.point)`
call then renders them as additive point sprites. Per frame the CPU fills one
40-byte uniform struct and encodes the two passes — there is no per-particle
work on the CPU, and particle state lives in a buffer the shader owns and never
leaves.

**Point cloud.** The ARKit `sceneDepth` map is bound as a texture to the
*vertex* shader rather than read back. Its dimensions are read from the texture
at runtime rather than assumed, so a future device reporting a different depth
resolution needs no change here — on current hardware that is 256×192, giving
roughly 49,000 vertices. Each vertex samples its own depth pixel, unprojects
through the inverse camera intrinsics, transforms to world space with the camera
pose, and colours itself with a project-specific depth palette. Invalid,
out-of-range and low-confidence samples are
culled by writing them behind the near plane, where the rasteriser discards them
for free. There is no readback and no per-point unprojection on the CPU; the
only CPU cost is validating the ARKit frame and binding two textures.

## Accessibility

Both components respect **Reduce Motion**. When it is enabled, curl-noise drift,
rotation, the completion burst and the demo cloud's animation are suppressed — a
`motionScale` uniform is set to zero rather than the view being swapped out, so
progress still reads correctly. Both expose an accessibility label and value, and
the loader publishes its percentage to VoiceOver.

## Tuning

| Knob | Where | Default |
|---|---|---|
| Particle count | `ParticleLoaderRenderer(view:particleCount:)` | 1,400 |
| Frame rate | `MTKView.preferredFramesPerSecond` | 60 |
| Ring radius | `ParticleShaders.metal` → `radius` | 32% of the shorter side |
| Colour drift | `particleVertex` → saturation / hue drift | 0.72 / 0.02 |
| Max scan depth | `LiDARPointCloudView` slider / `maxDepth` | 5 m |
| Confidence floor | `CloudUniforms.minConfidence` | 1 — raw `ARConfidenceLevel`, drops *low* |
| Point size | `CloudUniforms.pointSize` | 8 (shader caps at 12 px) |
| Colormap | `depthPalette()` in `PointCloudShaders.metal` | blue → cyan → violet → coral |

## Requirements

- **Deployment target iOS 17+**, targeting the iOS 26 SDK. Nothing here needs a
  newer API, so raising the floor would only shrink the audience.
- **Xcode 26 or later** (tools version 6.0). Since 28 April 2026 the App Store
  requires submissions built with Xcode 26 and the iOS 26 SDK, so this costs no
  real compatibility.
- Swift 5 language mode by default. See *Swift 6 migration* below.
- Live depth requires a device with a LiDAR scanner. Without one — and in the
  simulator — `LiDARPointCloudView` falls back to a procedural fibonacci-sphere
  cloud, so previews and the demo app still show something real.
- The host app must declare `NSCameraUsageDescription` for live mode.

## Swift 6 migration

The package ships in Swift 5 language mode. That is a deliberate, temporary
position, not an oversight: `MTKViewDelegate`, `ARSessionDelegate` and Metal
command-buffer completion handlers all sit on actor-isolation boundaries that
need deciding individually, and flipping the flag without resolving them
properly produces `@unchecked Sendable` sprinkled over a graphics codebase —
which is precisely where incorrect `Sendable` claims do the most damage.

CI runs a non-blocking lane that rewrites `.swiftLanguageMode(.v5)` to `.v6` in
its own disposable checkout, then builds with `SWIFT_STRICT_CONCURRENCY=complete`
— a manifest language mode overrides the xcodebuild `SWIFT_VERSION` flag, so the
flag alone would report nothing. `make swift6` does the same thing locally.
When that list is empty, change `.swiftLanguageMode(.v5)` to `.v6` in
`Package.swift`.

## Known limitations

These are real and worth knowing before you adopt the package.

- **Live mode is validated in portrait only.** The depth-to-camera rotation is
  selected per `UIInterfaceOrientation`, but only the portrait path has been
  confirmed on device. The derivation follows Apple's *Visualizing a Point Cloud
  Using Scene Depth* sample.
- **Uniform struct layouts are mirrored by hand** between Swift and MSL. Editing
  one side without the other produces a visual glitch rather than a crash.
  `Scripts/check-struct-parity.py` compares the two declarations directly and
  `PipelineTests` pins the resulting strides; both run in CI.
- **Shader debugging works from the demo app, not the package.** SwiftPM
  generates `default.metallib` itself and it cannot be replaced by a
  custom-compiled one, so the Xcode Metal Debugger needs the app target.
- **`swift test` on the command line may not resolve the packaged metallib.**
  This is a long-standing SwiftPM quirk; the tests skip cleanly when no Metal
  device is present, and CI runs them through `xcodebuild` against a simulator.
- A cold simulator launch can pause while Metal compiles pipeline state. Local
  verification reached the rendered loader after that first-launch delay;
  subsequent launches reused the compiled pipelines.
- The point cloud accumulates nothing between frames — it visualises the current
  depth frame, it does not build a persistent scan.
- Live depth requires camera permission and an `NSCameraUsageDescription` in the
  host app. Without either, the view falls back to the demo cloud and explains
  why on screen — it does not silently show an empty surface.
- **Nothing here has run on a physical LiDAR device yet.** Depth-to-camera
  registration, orientation correctness, thermal behaviour and GPU frame time
  are unverified. Treat the performance discussion above as reasoning about the
  design, not as measurement.
- No adaptive quality policy. Point density, sprite size and frame rate are
  fixed; there is no thermal or Low Power Mode adaptation. That is deliberate
  until there is profiling data to design it against.

## Development

```
make build     # build for the iOS simulator
make test      # pipeline, layout and projection tests
make parity    # Swift ↔ MSL struct parity + simulator selector checks
make demo      # build the committed example app project
make project   # regenerate the project after editing project.yml
make lint      # SwiftLint
make docs      # DocC archive
```

The example app lives in [`Examples/MetalVisualKitDemo`](Examples/MetalVisualKitDemo) and
depends on the package by relative path, so it always builds against the working
copy.

## Privacy

The package collects nothing, tracks nobody, performs no networking and uses no
required-reason APIs. `Sources/MetalVisualKit/PrivacyInfo.xcprivacy` declares this.
Camera permission stays the host app's responsibility.

## Attribution

The camera-orientation transform follows Apple's *Visualizing a Point Cloud
Using Scene Depth* sample. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
for its copyright and permission notice.

## License

MIT. See [LICENSE](LICENSE).
