# Spatial scanning roadmap

MetalVisualKit currently visualizes the latest ARKit depth frame. It does not yet accumulate, persist or export a room scan. This roadmap keeps live Metal rendering separate from structural capture so each claim can be verified at the right evidence level.

## Phase 1 — stable live LiDAR

Current branch scope:

- use the inverse orientation-aware ARKit view matrix for depth-to-world placement;
- request raw and smoothed scene depth where the device supports both;
- reduce live point-sprite overdraw while preserving depth-grid density;
- expose camera, depth and confidence colour modes;
- expose All, Balanced and Precise confidence floors;
- add explicit Start, Pause, Resume and End demo states;
- show particle-based preparation feedback and actionable tracking guidance;
- support bounded drag orbit and pinch zoom for the procedural fallback;
- keep camera permission and frame data on device.

Acceptance requires a fresh physical-device pass in portrait and both landscapes, plus Instruments captures for frame time, memory and thermal behavior. Simulator builds cannot verify LiDAR registration.

## Phase 2 — RoomPlan capture and export

RoomPlan is the preferred first persistent-scan implementation because Apple already combines camera input, LiDAR and trained models to produce parametric room data.

Planned vertical slice:

1. Start and stop a `RoomCaptureSession` from explicit user actions.
2. Display Apple-provided movement and lighting instructions in the Spatial Scan UI.
3. Persist `CapturedRoomData` and the processed `CapturedRoom` locally.
4. Summarize detected walls, floors, doors, windows, openings and supported object categories.
5. Export a USDZ file to an app-owned location.
6. Preview and share the exported USDZ through system UI.
7. Preserve confidence and source metadata beside the export.

This phase provides a practical room model, but it does not claim survey-grade measurements, IFC output or BIM compliance.

## Phase 3 — custom reconstructed mesh

Use `ARWorldTrackingConfiguration.sceneReconstruction` and `ARMeshAnchor` when the product needs lower-level geometry than RoomPlan exposes.

Planned work:

- ingest mesh-anchor updates into bounded app-owned buffers;
- retain ARKit face classifications for wall, floor, ceiling, door, window, table and seat surfaces;
- render classified mesh geometry with a dedicated Metal pipeline;
- add deterministic mesh-buffer validation and export tests;
- provide post-scan orbit, pinch zoom, reset camera and section visibility;
- evaluate mesh decimation only after captured-device measurements.

RoomPlan and scene reconstruction can coexist: RoomPlan supplies parametric structure while ARKit mesh anchors supply denser display geometry.

An anisotropic surfel renderer is a separate live-visualization phase rather than
a substitute for RoomPlan or mesh reconstruction. Its reviewed integration and
measurement gates are defined in [SURFEL-MVP.md](SURFEL-MVP.md).

## ML policy

No external model is bundled today.

LiDAR already supplies metric depth, and RoomPlan already uses Apple-trained models for room understanding. A monocular model should be considered only for a measured gap such as edge refinement on unsupported hardware. Before adding one, verify:

- model and weight licenses independently from this repository's MIT license;
- Core ML conversion and numerical parity;
- package size, memory, latency and thermal cost;
- alignment between relative monocular depth and metric LiDAR depth;
- an explicit fallback when inference is unavailable.

Monocular inference must never be presented as pixel-perfect metric depth or BIM-grade geometry without external validation.

## Performance gates

Do not introduce an automatic quality policy before device measurements exist. Capture:

- time to first raw and first smoothed depth frame;
- CPU time for frame preparation;
- GPU time for point and mesh passes;
- drawable misses and command-buffer duration;
- memory after 1, 5 and 10 minutes;
- thermal state transitions;
- point-sprite overdraw at each supported quality level.

Any adaptive policy must be deterministic, bounded, documented and covered by pure state tests.

## Release gate

A first tag remains blocked until:

- package, tests, example app and DocC build from a clean clone;
- live LiDAR orientation and camera registration pass on physical hardware;
- README media shows the current device UI without overstating hardware accuracy;
- privacy, attribution and model-license reviews match the shipped code;
- limitations describe what is current-frame visualization, RoomPlan output and custom mesh reconstruction.
