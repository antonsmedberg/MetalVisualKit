# MetalVisualKitDemo

The example app exercises both package components and records the README media.
It is part of the same repository as the `MetalVisualKit` Swift package.

## Open and build

From the repository root:

```sh
xed Examples/MetalVisualKit.xcworkspace
```

Select the **MetalVisualKitDemo** scheme and an iOS simulator, then build or run.
Do not open `Package.swift` and `MetalVisualKitDemo.xcodeproj` as separate Xcode
windows for normal development; that makes it easy to leave the library scheme
active while editing a demo file.

The app depends on the package by relative path (`../..`). Xcode therefore shows
`MetalVisualKit` under **Package Dependencies** and compiles the source in
`Sources/MetalVisualKit` without copying it into the app target.

## Demo states

The loader tab exposes determinate and indeterminate variants plus explicit
light- and dark-surface previews. The LiDAR tab uses live scene depth when the
hardware and permission are available, otherwise it presents the orbitable
procedural cloud with an on-screen reason. The demo opts in to orbit explicitly;
the package default leaves fallback gestures disabled for safe embedding.

The demo accepts deterministic launch arguments for screenshot and regression
work: `--demo-progress=0.68`, `--demo-spinner`, `--demo-light`, and
`--demo-cloud`. These affect only the example app, not the package API.

## SwiftUI previews

Keep **MetalVisualKitDemo** as the active scheme when previewing
`MetalVisualShowcase.swift` or package views from this workspace. If Xcode says
"Active scheme does not build this file," switch from the library-only
`MetalVisualKit` scheme to `MetalVisualKitDemo` and resume the canvas.

## Project generation

The compact Xcode project, shared demo scheme and generated `Info.plist` are
committed so a clean clone opens without setup. `project.yml` remains the source
of truth. After changing it, run `make project` from the repository root and
commit the regenerated files.

## Troubleshooting

1. Confirm the active document is `MetalVisualKit.xcworkspace` and the scheme is
   `MetalVisualKitDemo`.
2. Run `make parity` to validate the workspace, shared scheme and package paths.
3. Run `xcodebuild -downloadComponent MetalToolchain` if Xcode asks to download
   Metal Toolchain support, then restart Xcode and reopen the workspace.
4. Use **File → Packages → Reset Package Caches** only if the local package still
   does not resolve; the package has no external dependencies.

Live LiDAR mode requires a LiDAR-capable device. In the simulator and on devices
without LiDAR, the point-cloud view uses its procedural demo source and explains
the fallback on screen.
