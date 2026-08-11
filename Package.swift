// swift-tools-version: 6.0
import PackageDescription

// Tools version 6.0 requires Xcode 16 or later to consume the package. Since
// 28 April 2026 the App Store has required submissions to be built with
// Xcode 26 and the iOS 26 SDK, so that floor costs no real-world compatibility.
//
// The deployment target stays at iOS 17. "iOS 26 ready" means built and tested
// against the iOS 26 SDK — not iOS 26 only. Nothing in this package needs a
// newer API, and raising the floor would only shrink the audience.
let package = Package(
    name: "MetalVisualKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MetalVisualKit", targets: ["MetalVisualKit"])
    ],
    targets: [
        .target(
            name: "MetalVisualKit",
            // Only the privacy manifest is a resource. The .metal files are
            // *sources*: SwiftPM compiles every .metal file in the target into a
            // default.metallib inside the package bundle. Listing them under
            // resources: would ship them as unread data instead.
            resources: [.process("PrivacyInfo.xcprivacy")],
            // No `resources:` entry for the .metal files — SwiftPM compiles every
            // .metal source in this target into a default.metallib placed in the
            // package's own resource bundle. See Support/ShaderLibrary.swift.
            swiftSettings: [
                // Swift 5 language mode is the shipped default so that data-race
                // diagnostics arrive as warnings rather than hard errors.
                //
                // The Swift 6 migration is a real piece of work on this codebase,
                // not a flag flip: MTKViewDelegate, ARSessionDelegate and Metal
                // command-buffer completion handlers all sit on isolation
                // boundaries that need deciding case by case. CI builds a
                // non-blocking `-swift-version 6` lane so the compiler produces
                // that list. Once it is empty, add: .swiftLanguageMode(.v6)
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "MetalVisualKitTests",
            dependencies: ["MetalVisualKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
