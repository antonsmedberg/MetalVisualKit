//
//  MetalVisualShowcase.swift
//  MetalVisualKitDemo
//
//  Exercises both components and is what the README media is recorded from.
//  It lives in the example app rather than the library — a package should not
//  link a demo screen into every app that depends on it.
//

import MetalVisualKit
import SwiftUI

struct MetalVisualShowcase: View {
    var body: some View {
        TabView {
            LoaderTab()
                .tabItem { Label("Loader", systemImage: "circle.dotted.circle") }

            CloudTab()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Loader

private struct LoaderTab: View {
    @State private var progress: Double = 0
    @State private var isRunning = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                ParticleProgressView(progress: progress, title: "Exporting")
                    .frame(width: 320, height: 320)

                Text("Drag across the particles to scatter them")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))

                Button(isRunning ? "Running…" : "Simulate export") {
                    simulateExport()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.15))
                .disabled(isRunning)
            }
        }
    }

    /// A deliberately uneven ramp — a linear one looks fake next to real work.
    private func simulateExport() {
        isRunning = true
        progress = 0
        Task {
            while progress < 1 {
                try? await Task.sleep(for: .milliseconds(45))
                progress = min(progress + Double.random(in: 0.004...0.02), 1)
            }
            try? await Task.sleep(for: .seconds(1.5))
            isRunning = false
            progress = 0
        }
    }
}

// MARK: - Point cloud

private struct CloudTab: View {
    var body: some View {
        ZStack(alignment: .top) {
            LiDARPointCloudView(displayMode: .live)
                .ignoresSafeArea()

            if !LiDARPointCloudView.isLiDARAvailable {
                Text("Demo cloud — no LiDAR scanner on this device")
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }
}

#Preview("Showcase") {
    MetalVisualShowcase()
}
