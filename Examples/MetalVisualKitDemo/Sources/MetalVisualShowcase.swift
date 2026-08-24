//
//  MetalVisualShowcase.swift
//  MetalVisualKitDemo
//
//  Root shell for the demo app. Feature-specific presentation lives in its
//  own files so this view only owns tab selection and loader appearance.
//

import Foundation
import SwiftUI

struct MetalVisualShowcase: View {
    private enum Tab: Hashable {
        case loader
        case spatialScan
    }

    @State private var selectedTab: Tab
    @State private var usesLightSurface: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        _selectedTab = State(
            initialValue: arguments.contains("--demo-cloud")
            ? .spatialScan
            : .loader
        )

        _usesLightSurface = State(
            initialValue: arguments.contains("--demo-light")
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LoaderTab(
                usesLightSurface: $usesLightSurface
            )
            .tabItem {
                Label(
                    "Loader",
                    systemImage: "circle.dotted.circle"
                )
            }
            .tag(Tab.loader)

            SpatialScanTab()
                .tabItem {
                    Label(
                        "LiDAR",
                        systemImage: "cube.transparent"
                    )
                }
                .tag(Tab.spatialScan)
        }
        .preferredColorScheme(
            selectedTab == .loader && usesLightSurface
            ? .light
            : .dark
        )
    }
}

#Preview("Showcase") {
    MetalVisualShowcase(
        arguments: ["--demo-cloud"]
    )
}
