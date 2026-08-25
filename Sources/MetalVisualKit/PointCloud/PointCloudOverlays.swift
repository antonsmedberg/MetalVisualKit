//
//  PointCloudOverlays.swift
//  MetalVisualKit
//
//  Session feedback stays deliberately small so the live sensor output remains
//  visible while ARKit initialises or temporarily reports limited tracking.
//

import SwiftUI

struct PointCloudPreparingOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ParticleSpinnerView(label: message, surfaceStyle: .dark).frame(width: 58, height: 58).accessibilityHidden(
                true)

            Text(message).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.92)).multilineTextAlignment(
                .center
            ).frame(maxWidth: 230).shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }.padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false).transition(
            .opacity
        ).accessibilityElement(children: .combine)
    }
}

struct PointCloudStatusBanner: View {
    let message: String

    var body: some View {
        VStack {
            Label(message, systemImage: "viewfinder").font(.footnote.weight(.medium)).foregroundStyle(.white).padding(
                .horizontal, 12
            ).padding(.vertical, 8).pointCloudGlass(cornerRadius: 14).padding(.top, 12)

            Spacer()
        }.allowsHitTesting(false).transition(.opacity)
    }
}

struct PointCloudFallbackNotice: View {
    let message: String
    let showsOrbitHint: Bool

    var body: some View {
        VStack(spacing: 5) {
            Label(message, systemImage: "info.circle")

            if showsOrbitHint { Label("Drag to orbit", systemImage: "hand.draw").accessibilityHidden(true) }
        }.font(.caption).foregroundStyle(.white.opacity(0.76)).multilineTextAlignment(.center).padding(.horizontal, 14)
            .padding(.vertical, 10).pointCloudGlass(cornerRadius: 16)
    }
}

extension View {
    @ViewBuilder func pointCloudGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
