// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MetalVisualKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MetalVisualKit",
            targets: [
                "MetalVisualKit"
            ]
        )
    ],
    targets: [
        .target(
            name: "MetalVisualKit",
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MetalVisualKitTests",
            dependencies: [
                "MetalVisualKit"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
