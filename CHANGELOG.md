# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing is tagged yet. Xcode 26.6 builds the package, all 15 tests, the example
app and the DocC archive; the loader also renders in an iOS 26.5 simulator.
Live capture has not run on physical LiDAR hardware, so there is no release to
claim yet.

### Fixed

- Core Video texture lifetime: `CVMetalTexture` wrappers are now retained until
  the command buffer completes. Previously they were released at the end of the
  creating function while the GPU was still reading the underlying IOSurface.
- LiDAR confidence is read as raw `ARConfidenceLevel` from an `r8Uint` texture
  instead of being sampled as normalised colour.
- Point sprite size reduced from 900 to 8 with a 12 px cap. The old value put
  every one of ~49,000 points at the previous 22 px ceiling, which made the
  setting meaningless and generated a large amount of fragment overdraw.
- Particle physics integrates in pixels per second with exponential damping, so
  motion is identical at 30, 60 and 120 Hz. Damping was previously per-frame.
- Depth frames are validated before a drawable is acquired, duplicate ARKit
  frames are skipped by timestamp, unexpected pixel formats are rejected rather
  than reinterpreted, and a missing confidence map falls back to a generated
  texture instead of blanking the view.
- Particles are no longer reseeded on every drawable resize.
- Renderer activation is idempotent, so SwiftUI's frequent `updateUIView` calls
  no longer reset the frame clock and distort `dt`.
- NaN and out-of-range progress values are clamped before reaching the GPU.
- Touch coordinates use independent X and Y drawable scaling.

### Fixed (second audit pass)

- Completion-burst envelope decayed once per rendered frame, so it emptied twice
  as fast at 120 Hz. Now decays per second, and a burst triggered this frame
  starts at full amplitude instead of already-damped.
- Sprite styling still read velocity on the old per-frame scale after the
  physics moved to pixels per second, saturating the speed-stretch term and
  inflating every particle. Converted back to a 60 Hz-equivalent for styling
  only; the physics stays in real units.
- `updateUIView` re-ran the ARKit configuration on every SwiftUI state change,
  so moving the depth slider restarted tracking. Activation is now a state
  transition.
- Camera authorization and `NSCameraUsageDescription` are checked before live
  mode starts, with an on-screen reason when falling back. Authorization is
  re-read on foreground so a change made in Settings takes effect.
- A failed `CVMetalTextureCacheCreate` now throws instead of leaving a renderer
  that can never produce a depth texture.
- ARKit's `projectionMatrix(for:viewportSize:...)` takes a viewport in points;
  drawable pixels were being passed.
- An AR frame was marked consumed during preparation, so a frame whose drawable
  acquisition failed was skipped permanently. Recorded after commit now.
- Animation time came from the wall clock and jumped by the full backgrounded
  interval on return. Both renderers now accumulate their own simulation time.
- Reduce Motion left the spinner's SwiftUI loop running 30 times a second to
  drive an animation the shader was suppressing.
- The package applied `.ignoresSafeArea()` to `LiDARPointCloudView`, imposing a
  layout policy on host apps. Removed; the example app opts in.

### Fixed (third audit pass)

- The point cloud kept its original renderer when the resolved source changed.
  SwiftUI reuses the view and calls `updateUIView` rather than `makeUIView`, so
  granting camera permission left the demo cloud running forever, and revoking
  it left a live session attached. The renderer is now rebuilt on that change.
- `PointCloudRenderer.init` started an AR session eagerly, so a view constructed
  while the scene was inactive briefly opened the camera before `setActive(false)`
  arrived. The session is now started lazily by `setActive(true)`.
- The particle bridge applied configuration before attaching its delegate but not
  lifecycle state, so a view built while inactive could draw one frame first.
- The spinner's `.task` was keyed only on Reduce Motion while reading
  `scenePhase` from the value captured at task creation, which could go stale.
  Keyed on both now, which also removed a 200 ms polling loop.
- The depth slider offered 1-10 m against a sensor that resolves to about five,
  so the colormap normalised over a range never filled. Now 0.5-5 m, and the
  value is clamped before it reaches the renderer regardless of the caller.
- The consumed-frame timestamp is recorded after `commit()` rather than before,
  matching the invariant the comment already claimed.
- `make swift6` had the same defect the CI lane did: a manifest
  `swiftLanguageMode` overrides `SWIFT_VERSION`, so the target was never
  actually built in Swift 6 mode. It now patches the manifest and restores it
  via a shell trap, so an interrupted or failed build cannot leave it modified.

### Added

- `ParticleProgressView` and `ParticleSpinnerView` — 1,400 particles updated in a
  Metal compute shader and drawn as additive point sprites in a single draw call,
  with curl-noise drift, touch repulsion and a completion burst.
- `LiDARPointCloudView` — ARKit `sceneDepth` bound as a texture to the vertex
  shader, unprojecting ~49,000 points to world space entirely on the GPU, with a
  custom depth palette and confidence culling. Falls back to a procedural cloud
  on hardware without a LiDAR scanner.
- Reduce Motion support and VoiceOver labels on both components.
- `PipelineTests` covering metallib resolution, shader function presence,
  pipeline compilation, uniform struct strides and the projection helpers.
- `Scripts/check-struct-parity.py`, which compares the Swift and MSL declarations
  of every shared struct and runs in CI.
- Example app under `Examples/MetalVisualKitDemo`, including a compact committed
  Xcode project for zero-setup clean clones and `project.yml` for regeneration.
- Value-based `ParticleProgressView(progress:)` alongside the `Binding` form; a
  read-only indicator should not require a writable binding.
- `isInteractive` on the loader, defaulting to off for `ParticleSpinnerView`, so
  a decorative spinner does not swallow touches meant for the controls beneath.
- `Scripts/select-ios-simulator.py` and its tests, so CI targets a simulator
  that exists on the runner rather than a hard-coded model name.
- Advisory CI lane building with Swift 6 language mode and complete strict
  concurrency. It rewrites the manifest's language mode in the disposable
  checkout, because a manifest `swiftLanguageMode` overrides the xcodebuild
  `SWIFT_VERSION` flag and the flag alone would have measured nothing.
- `PrivacyInfo.xcprivacy` declaring no tracking, no collected data and no
  required-reason APIs.
- Dependabot for GitHub Actions; workflow permissions reduced to `contents:
  read`, `persist-credentials: false`, per-job timeouts and `workflow_dispatch`.
- Apple CI jobs run on `macos-26`, the Apple-silicon image carrying the iOS 26
  SDK. `actions/checkout` is pinned to the immutable commit for v6.0.2.
- The example app targets iPhone and iPad and declares every supported
  orientation, so the per-orientation depth-to-camera rotation can be tested.
- Renamed the package to `MetalVisualKit` before publication to avoid collision
  with an existing repository and confusion with Apple's MetalFX framework.
- Replaced third-party Turbo polynomial coefficients with a project-specific
  depth palette and documented the Apple sample-code attribution separately.
- Added a custom particle-orbit app icon and a verified simulator screenshot.
