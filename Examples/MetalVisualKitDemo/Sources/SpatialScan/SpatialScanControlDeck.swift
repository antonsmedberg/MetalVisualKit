//
//  SpatialScanControlDeck.swift
//  MetalVisualKitDemo
//
//  One compact instrument surface owns the live controls. Small actions use
//  native Liquid Glass on iOS 26+, while the larger panel stays visually quiet
//  over the continuously rendered Metal content.
//

import Foundation
import MetalVisualKit
import SwiftUI

struct SpatialScanControlDeck: View {
    let mode: SpatialCaptureMode

    @Binding var colorMode:
    PointCloudColorMode

    @Binding var confidenceFloor:
    PointCloudConfidenceFloor

    @Binding var maxDepth: Float

    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void

    @Environment(\.verticalSizeClass)
    private var verticalSizeClass

    var body: some View {
        switch mode {
            case .idle:
                startButton

            case .live, .paused:
                liveDeck
        }
    }

    @ViewBuilder
    private var liveDeck: some View {
        if verticalSizeClass == .compact {
            compactDeck
        } else {
            regularDeck
        }
    }

    private var regularDeck: some View {
        VStack(spacing: 11) {
            colorPicker
            rangeRow
            footerRow
        }
        .padding(12)
        .demoInstrumentPanel(
            cornerRadius: 22
        )
    }

    private var compactDeck: some View {
        HStack(spacing: 12) {
            VStack(spacing: 9) {
                colorPicker
                rangeRow
            }

            actionButtons
        }
        .padding(11)
        .demoInstrumentPanel(
            cornerRadius: 20
        )
    }

    private var colorPicker: some View {
        Picker(
            "Point colour",
            selection: $colorMode
        ) {
            ForEach(
                PointCloudColorMode.allCases
            ) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(
            "Point colour source"
        )
    }

    private var rangeRow: some View {
        HStack(spacing: 9) {
            Image(
                systemName: "ruler"
            )
            .font(
                .caption.weight(.medium)
            )
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            Slider(
                value: $maxDepth,
                in: LiDARPointCloudView
                    .depthRange
            )
            .tint(.cyan)
            .accessibilityLabel(
                "Maximum scan depth"
            )
            .accessibilityValue(
                String(
                    format: "%.1f metres",
                    maxDepth
                )
            )

            Text(
                String(
                    format: "%.1f m",
                    maxDepth
                )
            )
            .font(
                .caption.monospacedDigit()
            )
            .foregroundStyle(.secondary)
            .frame(
                width: 46,
                alignment: .trailing
            )
            .accessibilityHidden(true)
        }
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            confidenceMenu

            Spacer(minLength: 8)

            actionButtons
        }
    }

    private var confidenceMenu: some View {
        Menu {
            ForEach(
                PointCloudConfidenceFloor
                    .allCases
            ) { floor in
                Button {
                    confidenceFloor = floor
                } label: {
                    if floor == confidenceFloor {
                        Label(
                            floor.title,
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(floor.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Quality")
                    .foregroundStyle(.secondary)

                Text(confidenceFloor.title)
                    .foregroundStyle(.primary)

                Image(
                    systemName:
                        "chevron.up.chevron.down"
                )
                .font(
                    .caption2.weight(.semibold)
                )
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .font(
                .caption.weight(.medium)
            )
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            "Point confidence"
        )
        .accessibilityValue(
            confidenceFloor.title
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            scanActionButton
            endButton
        }
    }

    @ViewBuilder
    private var scanActionButton: some View {
        let symbol =
        mode == .paused
        ? "play.fill"
        : "pause.fill"

        let label =
        mode == .paused
        ? "Resume LiDAR"
        : "Pause LiDAR"

        let action =
        mode == .paused
        ? onResume
        : onPause

        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(
                        .body.weight(.semibold)
                    )
                    .frame(
                        width: 48,
                        height: 48
                    )
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(
                        .body.weight(.semibold)
                    )
                    .frame(
                        width: 48,
                        height: 48
                    )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private var endButton: some View {
        if #available(iOS 26.0, *) {
            Button(
                role: .destructive,
                action: onEnd
            ) {
                Image(
                    systemName: "xmark"
                )
                .font(
                    .body.weight(.semibold)
                )
                .frame(
                    width: 48,
                    height: 48
                )
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(
                "End LiDAR"
            )
        } else {
            Button(
                role: .destructive,
                action: onEnd
            ) {
                Image(
                    systemName: "xmark"
                )
                .font(
                    .body.weight(.semibold)
                )
                .frame(
                    width: 48,
                    height: 48
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(
                "End LiDAR"
            )
        }
    }

    @ViewBuilder
    private var startButton: some View {
        if #available(iOS 26.0, *) {
            Button(
                action: onStart
            ) {
                Label(
                    "Start scan",
                    systemImage: "viewfinder"
                )
                .font(
                    .headline.weight(.medium)
                )
                .padding(.horizontal, 3)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        } else {
            Button(
                action: onStart
            ) {
                Label(
                    "Start scan",
                    systemImage: "viewfinder"
                )
                .font(
                    .headline.weight(.medium)
                )
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }
}
