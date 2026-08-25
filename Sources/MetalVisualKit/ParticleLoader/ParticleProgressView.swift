//
//  ParticleProgressView.swift
//  MetalVisualKit
//
//  Determinate GPU particle progress indicator.
//

import SwiftUI

public struct ParticleProgressView: View {
    private let progress: Double
    private let title: String
    private let isInteractive: Bool
    private let surfaceStyle: ParticleSurfaceStyle
    private let labelColor: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.colorScheme) private var colourScheme

    @Environment(\.scenePhase) private var scenePhase

    public init(
        progress: Double, title: String = "Loading", isInteractive: Bool = true,
        surfaceStyle: ParticleSurfaceStyle = .automatic, labelColor: Color? = nil
    ) {
        self.progress = progress
        self.title = title
        self.isInteractive = isInteractive
        self.surfaceStyle = surfaceStyle
        self.labelColor = labelColor
    }

    public init(
        progress: Binding<Double>, title: String = "Loading", isInteractive: Bool = true,
        surfaceStyle: ParticleSurfaceStyle = .automatic, labelColor: Color? = nil
    ) {
        self.init(
            progress: progress.wrappedValue, title: title, isInteractive: isInteractive, surfaceStyle: surfaceStyle,
            labelColor: labelColor)
    }

    private var clampedProgress: Double {
        guard progress.isFinite else { return 0 }

        return min(max(progress, 0), 1)
    }

    private var isComplete: Bool { clampedProgress >= 1 }

    private var percentage: Int { Int(clampedProgress * 100) }

    private var accessibilityValue: String { isComplete ? "Complete" : "\(percentage) percent" }

    public var body: some View {
        ZStack {
            ParticleLoaderMetalView(
                progress: clampedProgress, reduceMotion: reduceMotion,
                surfaceIsLight: surfaceStyle.usesLightPalette(in: colourScheme), isInteractive: isInteractive,
                isActive: scenePhase == .active)

            progressLabel
        }.accessibilityElement(children: .ignore).accessibilityLabel(Text(title)).accessibilityValue(
            Text(accessibilityValue))
    }

    private var progressLabel: some View {
        VStack(spacing: 6) {
            Group {
                if isComplete {
                    Image(systemName: "checkmark").font(.system(size: 38, weight: .semibold)).transition(
                        .scale(scale: 0.92).combined(with: .opacity))
                } else {
                    Text("\(percentage)").font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }.foregroundStyle(labelColor ?? Color.primary)

            Text(isComplete ? "Done" : title).font(.footnote.weight(.medium)).foregroundStyle(
                labelColor?.opacity(0.55) ?? Color.secondary
            ).textCase(.uppercase).kerning(1.5).lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: 160).animation(reduceMotion ? nil : .smooth(duration: 0.40), value: isComplete)
            .allowsHitTesting(false)
    }
}
