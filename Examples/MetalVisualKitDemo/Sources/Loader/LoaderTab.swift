//
//  LoaderTab.swift
//  MetalVisualKitDemo
//

import Foundation
import MetalVisualKit
import SwiftUI

struct LoaderTab: View {
    private enum LoaderMode: String, CaseIterable, Identifiable {
        case progress = "Progress"
        case spinner = "Spinner"

        var id: Self { self }
    }

    @Binding private var usesLightSurface: Bool

    @State private var progress: Double
    @State private var isRunning = false
    @State private var mode: LoaderMode

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    init(
        usesLightSurface: Binding<Bool>,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        let progressArgument = arguments.first {
            $0.hasPrefix("--demo-progress=")
        }

        let initialProgress = progressArgument
            .flatMap {
                Double(
                    $0.replacingOccurrences(
                        of: "--demo-progress=",
                        with: ""
                    )
                )
            }
            .map {
                min(max($0, 0), 1)
            } ?? 0

        _usesLightSurface = usesLightSurface
        _progress = State(initialValue: initialProgress)

        _mode = State(
            initialValue: arguments.contains("--demo-spinner")
            ? .spinner
            : .progress
        )
    }

    private var background: Color {
        usesLightSurface
        ? Color(white: 0.96)
        : Color(
            red: 0.015,
            green: 0.02,
            blue: 0.055
        )
    }

    private var labelColor: Color {
        usesLightSurface ? .black : .white
    }

    private var surfaceStyle: ParticleSurfaceStyle {
        usesLightSurface ? .light : .dark
    }

    private var loaderSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize
        ? 240
        : 310
    }

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            GeometryReader { geometry in
                ViewThatFits(in: .vertical) {
                    content
                        .padding(.horizontal, 24)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height
                        )

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
        .animation(
            .smooth(duration: 0.30),
            value: usesLightSurface
        )
        .task(id: isRunning) {
            await runSimulation()
        }
        .onChange(of: mode) {
            stopSimulation()
        }
    }

    private var content: some View {
        VStack(
            spacing: dynamicTypeSize.isAccessibilitySize
            ? 12
            : 22
        ) {
            VStack(spacing: 6) {
                Text("Particle loader")
                    .font(.title2.weight(.semibold))

                Text("Determinate and indeterminate states")
                    .font(.subheadline)
                    .foregroundStyle(
                        labelColor.opacity(0.55)
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
            }
            .foregroundStyle(labelColor)

            Picker(
                "Loader mode",
                selection: $mode
            ) {
                ForEach(LoaderMode.allCases) { mode in
                    Text(mode.rawValue)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            loaderGraphic
                .frame(
                    width: loaderSize,
                    height: loaderSize
                )

            Text(
                mode == .progress
                ? "Drag across the ring to disturb the particles."
                : "Use the spinner when duration is unknown."
            )
            .font(.footnote)
            .foregroundStyle(
                labelColor.opacity(0.55)
            )
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(
                horizontal: false,
                vertical: true
            )

            actions
        }
    }

    @ViewBuilder
    private var loaderGraphic: some View {
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

    @ViewBuilder
    private var actions: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    simulationButton
                        .buttonStyle(.glassProminent)

                    surfaceButton
                        .buttonStyle(.glass)
                }
            }
        } else {
            HStack(spacing: 12) {
                simulationButton
                    .buttonStyle(.borderedProminent)

                surfaceButton
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var simulationButton: some View {
        if mode == .progress {
            Button(
                isRunning
                ? "Running…"
                : "Simulate export",
                action: startSimulation
            )
            .tint(
                usesLightSurface
                ? .indigo
                : .cyan
            )
            .disabled(isRunning)
        }
    }

    private var surfaceButton: some View {
        Button {
            usesLightSurface.toggle()
        } label: {
            Label(
                usesLightSurface
                ? "Dark surface"
                : "Light surface",
                systemImage: usesLightSurface
                ? "moon.fill"
                : "sun.max.fill"
            )
            .labelStyle(.iconOnly)
        }
        .tint(labelColor.opacity(0.8))
        .accessibilityLabel(
            usesLightSurface
            ? "Use dark surface"
            : "Use light surface"
        )
    }

    private func startSimulation() {
        guard !isRunning else {
            return
        }

        progress = 0
        isRunning = true
    }

    private func stopSimulation() {
        isRunning = false
        progress = 0
    }

    private func runSimulation() async {
        guard isRunning else {
            return
        }

        while progress < 1 {
            do {
                try await Task.sleep(
                    for: .milliseconds(45)
                )
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                isRunning
            else {
                return
            }

            progress = min(
                progress
                + Double.random(
                    in: 0.004...0.02
                ),
                1
            )
        }

        do {
            try await Task.sleep(
                for: .seconds(1.2)
            )
        } catch {
            return
        }

        guard !Task.isCancelled else {
            return
        }

        isRunning = false
        progress = 0
    }
}

#Preview("Loader") {
    @Previewable @State var light = false

    LoaderTab(
        usesLightSurface: $light,
        arguments: [
            "--demo-progress=0.68"
        ]
    )
}
