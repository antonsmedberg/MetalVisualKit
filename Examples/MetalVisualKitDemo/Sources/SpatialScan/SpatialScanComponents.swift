//
//  SpatialScanComponents.swift
//  MetalVisualKitDemo
//

import SwiftUI

struct SpatialScanIntro: View {
    @Environment(\.verticalSizeClass)
    private var verticalSizeClass

    var body: some View {
        if verticalSizeClass == .compact {
            HStack(spacing: 10) {
                icon

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {
                    title
                    description
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .accessibilityElement(
                children: .combine
            )
        } else {
            VStack(spacing: 8) {
                icon
                title

                description
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .padding(.horizontal, 24)
            .accessibilityElement(
                children: .combine
            )
        }
    }

    private var icon: some View {
        Image(
            systemName: "cube.transparent"
        )
        .font(
            .system(
                size: 23,
                weight: .medium
            )
        )
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.cyan)
    }

    private var title: some View {
        Text("LiDAR + Camera")
            .font(
                .subheadline.weight(.semibold)
            )
            .foregroundStyle(.primary)
    }

    private var description: some View {
        Text(
            "Scan live depth with real-world camera colour."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
}

struct SpatialStatusChip: View {
    let status: SpatialScanStatus

    var body: some View {
        Label(
            status.title,
            systemImage: status.symbol
        )
        .font(
            .caption.weight(.semibold)
        )
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .demoGlassCapsule()
        .accessibilityElement(
            children: .combine
        )
    }
}
