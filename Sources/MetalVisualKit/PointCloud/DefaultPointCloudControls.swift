//
//  DefaultPointCloudControls.swift
//  MetalVisualKit
//
//  Optional package-owned controls for hosts that do not provide their own HUD.
//

import Foundation
import SwiftUI

struct DefaultPointCloudControls: View {
    @Binding var colorMode: PointCloudColorMode
    @Binding var minimumConfidence: PointCloudConfidenceFloor
    @Binding var maxDepth: Float

    var body: some View {
        VStack(spacing: 11) {
            colorModePicker
            confidencePicker
            depthControl
        }
        .padding(14)
        .foregroundStyle(.white)
        .pointCloudGlass(cornerRadius: 22)
    }

    private var colorModePicker: some View {
        Picker(
            "Point colour",
            selection: $colorMode
        ) {
            ForEach(PointCloudColorMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Point colour source")
    }

    private var confidencePicker: some View {
        Picker(
            "Point quality",
            selection: $minimumConfidence
        ) {
            ForEach(PointCloudConfidenceFloor.allCases) { floor in
                Text(floor.title)
                    .tag(floor)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Minimum point confidence")
    }

    private var depthControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.and.right")
                .font(.caption)
                .accessibilityHidden(true)

            Slider(
                value: $maxDepth,
                in: LiDARPointCloudView.depthRange
            )
            .accessibilityLabel("Maximum scan depth")
            .accessibilityValue(
                String(format: "%.1f metres", maxDepth)
            )

            Text(String(format: "%.1f m", maxDepth))
                .font(.caption.monospacedDigit())
                .frame(
                    width: 46,
                    alignment: .trailing
                )
                .accessibilityHidden(true)
        }
        .tint(.cyan)
    }
}
