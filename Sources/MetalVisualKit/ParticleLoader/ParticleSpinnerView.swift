//
//  ParticleSpinnerView.swift
//  MetalVisualKit
//
//  Indeterminate GPU particle progress indicator.
//

import SwiftUI

private struct SpinnerTaskKey: Equatable {
    let reduceMotion: Bool
    let phase: ScenePhase
}

public struct ParticleSpinnerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.colorScheme) private var colourScheme

    @Environment(\.scenePhase) private var scenePhase

    @State private var progress: Double = 0

    private let label: String
    private let surfaceStyle: ParticleSurfaceStyle

    public init(label: String = "Loading", surfaceStyle: ParticleSurfaceStyle = .automatic) {
        self.label = label
        self.surfaceStyle = surfaceStyle
    }

    public var body: some View {
        ParticleLoaderMetalView(
            progress: progress, reduceMotion: reduceMotion,
            surfaceIsLight: surfaceStyle.usesLightPalette(in: colourScheme), isInteractive: false,
            isActive: scenePhase == .active
        ).task(id: SpinnerTaskKey(reduceMotion: reduceMotion, phase: scenePhase)) { await runSpinner() }
            .accessibilityElement(children: .ignore).accessibilityLabel(Text(label)).accessibilityAddTraits(
                .updatesFrequently)
    }

    private func runSpinner() async {
        guard !reduceMotion else {
            progress = 0.5
            return
        }

        guard scenePhase == .active else { return }

        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }

            progress = progress >= 1.25 ? 0 : progress + 0.007
        }
    }
}
