# MetalVisualKitDemo

The example app used to exercise both components and to record the README media.

```
open MetalVisualKitDemo.xcodeproj
```

The compact Xcode project and generated `Info.plist` are committed so a clean
clone opens without setup. `project.yml` remains the source of truth for project
configuration. After changing it, run `make project` from the repository root
and commit the regenerated files.

The app depends on the package by relative path (`../..`), so it always builds
against the working copy rather than a published tag.

Live LiDAR mode requires a device with a LiDAR scanner. On any other device, and
in the simulator, the point cloud view falls back to its procedural demo cloud
and says so on screen.

## Package project

The library also opens directly as a Swift package:

```
open Package.swift
```

That gives a working Xcode project for MetalVisualKit with both components' SwiftUI
previews. Only the packaged demo app needs the generator.
