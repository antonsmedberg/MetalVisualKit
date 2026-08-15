//
//  MetalVisualShowcase.swift
//  MetalVisualKitDemo
//
//  Exercises both components and is what the README media is recorded from.
//  It lives in the example app rather than the library — a package should not
//  link a demo screen into every app that depends on it.
//

import Foundation
import MetalVisualKit
import SwiftUI

struct MetalVisualShowcase: View {
    private enum Tab: Hashable {
        case loader
        case cloud
    }

    @State private var selectedTab: Tab
    @State private var usesLightSurface: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        _selectedTab = State(initialValue: arguments.contains("--demo-cloud") ? .cloud : .loader)
        _usesLightSurface = State(initialValue: arguments.contains("--demo-light"))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LoaderTab(usesLightSurface: $usesLightSurface)
                .tabItem { Label("Loader", systemImage: "circle.dotted.circle") }
                .tag(Tab.loader)

            CloudTab()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }
                .tag(Tab.cloud)
        }
        .preferredColorScheme(selectedTab == .loader && usesLightSurface ? .light : .dark)
    }
}

// MARK: - Loader

private struct LoaderTab: View {
    private enum LoaderMode: String, CaseIterable, Identifiable {
        case progress = "Progress"
        case spinner = "Spinner"

        var id: Self { self }
    }

    @State private var progress: Double
    @State private var isRunning = false
    @State private var mode: LoaderMode
    @Binding private var usesLightSurface: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        usesLightSurface: Binding<Bool>,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        let progressArgument = arguments.first { $0.hasPrefix("--demo-progress=") }
        let progress = progressArgument
            .flatMap { Double($0.replacingOccurrences(of: "--demo-progress=", with: "")) }
            .map { min(max($0, 0), 1) } ?? 0
        _progress = State(initialValue: progress)
        _mode = State(initialValue: arguments.contains("--demo-spinner") ? .spinner : .progress)
        _usesLightSurface = usesLightSurface
    }

    private var background: Color {
        usesLightSurface ? Color(white: 0.96) : Color(red: 0.015, green: 0.02, blue: 0.055)
    }

    private var labelColor: Color { usesLightSurface ? .black : .white }

    private var surfaceStyle: ParticleSurfaceStyle {
        usesLightSurface ? .light : .dark
    }

    private var loaderSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 240 : 310
    }

    private var content: some View {
        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 12 : 22) {
            VStack(spacing: 6) {
                Text("Particle loader")
                    .font(.title2.weight(.semibold))
                Text("Determinate and indeterminate states")
                    .font(.subheadline)
                    .foregroundStyle(labelColor.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(labelColor)

            Picker("Loader mode", selection: $mode) {
                ForEach(LoaderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Group {
                if mode == .progress {
                    ParticleProgressView(
                        progress: progress,
                        title: "Exporting",
                        isInteractive: true,
                        surfaceStyle: surfaceStyle,
                        labelColor: labelColor
                    )
                } else {
                    ParticleSpinnerView(
                        label: "Preparing export",
                        surfaceStyle: surfaceStyle
                    )
                }
            }
            .frame(width: loaderSize, height: loaderSize)

            Text(mode == .progress
                 ? "Drag across the ring to disturb the particles."
                 : "Use the spinner when duration is unknown.")
                .font(.footnote)
                .foregroundStyle(labelColor.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if mode == .progress {
                    Button(isRunning ? "Running…" : "Simulate export") {
                        isRunning = true
                        progress = 0
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(usesLightSurface ? .indigo : .white.opacity(0.16))
                    .disabled(isRunning)
                }

                Button {
                    usesLightSurface.toggle()
                } label: {
                    Label(
                        usesLightSurface ? "Dark surface" : "Light surface",
                        systemImage: usesLightSurface ? "moon.fill" : "sun.max.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .tint(labelColor.opacity(0.8))
            }
        }
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            GeometryReader { geometry in
                ViewThatFits(in: .vertical) {
                    content
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)

                    ScrollView {
                        content
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .animation(.smooth(duration: 0.30), value: usesLightSurface)
        .task(id: isRunning) {
            guard isRunning else { return }
            while progress < 1 {
                do {
                    try await Task.sleep(for: .milliseconds(45))
                } catch {
                    return
                }
                progress = min(progress + Double.random(in: 0.004...0.02), 1)
            }
            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }
            isRunning = false
            progress = 0
        }
        .onChange(of: mode) {
            isRunning = false
            progress = 0
        }
    }
}

// MARK: - Point cloud

private struct CloudTab: View {
    var body: some View {
        LiDARPointCloudView(displayMode: .live, allowsOrbitInteraction: true)
            .ignoresSafeArea(edges: [.top, .horizontal])
    }
}

#Preview("Showcase") {
    MetalVisualShowcase()
}
