//
//  DemoGlass.swift
//  MetalVisualKitDemo
//
//  Demo-only presentation helpers. Liquid Glass stays on small interactive
//  surfaces while the instrument deck remains deliberately quieter.
//

import SwiftUI

extension View {
    @ViewBuilder
    func demoGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular,
                in: Capsule()
            )
        } else {
            background(
                .ultraThinMaterial,
                in: Capsule()
            )
        }
    }

    @ViewBuilder
    func demoInstrumentPanel(
        cornerRadius: CGFloat
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        if #available(iOS 26.0, *) {
            background(
                .black.opacity(0.36),
                in: shape
            )
            .overlay {
                shape.stroke(
                    .white.opacity(0.10),
                    lineWidth: 0.5
                )
            }
        } else {
            background(
                .ultraThinMaterial,
                in: shape
            )
            .overlay {
                shape.stroke(
                    .white.opacity(0.10),
                    lineWidth: 0.5
                )
            }
        }
    }
}
