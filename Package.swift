// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalVisualKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MetalVisualKit", targets: ["MetalVisualKit"])
    ],
    targets: [
        .target(
            name: "MetalVisualKit",
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: [
                // Swift 5 language mode remains the package default while
                // strict-concurrency diagnostics are resolved. CI also builds
                // a temporary Swift 6 manifest.
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
