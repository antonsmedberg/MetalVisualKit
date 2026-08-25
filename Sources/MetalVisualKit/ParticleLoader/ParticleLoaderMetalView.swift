//
//  ParticleLoaderMetalView.swift
//  MetalVisualKit
//
//  SwiftUI-to-Metal bridge for the particle loader.
//

import MetalKit
import SwiftUI
import UIKit

@MainActor final class TouchMTKView: MTKView {
    var onTouch: ((CGPoint?) -> Void)?

    private func report(_ touches: Set<UITouch>) {
        guard let touch = touches.first, bounds.width > 0, bounds.height > 0 else { return }

        let point = touch.location(in: self)
        let scaleX = drawableSize.width / bounds.width
        let scaleY = drawableSize.height / bounds.height

        onTouch?(CGPoint(x: point.x * scaleX, y: point.y * scaleY))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onTouch?(nil) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onTouch?(nil) }
}

@MainActor struct ParticleLoaderMetalView: UIViewRepresentable {
    typealias UIViewType = TouchMTKView

    var progress: Double
    var reduceMotion: Bool
    var surfaceIsLight: Bool
    var isInteractive: Bool
    var isActive: Bool

    nonisolated static func shouldRenderContinuously(isActive: Bool, reduceMotion: Bool) -> Bool {
        isActive && !reduceMotion
    }

    @MainActor final class Coordinator { var renderer: ParticleLoaderRenderer? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TouchMTKView {
        let view = TouchMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())

        view.isUserInteractionEnabled = isInteractive

        do {
            let renderer = try ParticleLoaderRenderer(view: view)

            applyConfiguration(to: renderer)

            renderer.setActive(isActive)

            view.delegate = renderer

            view.onTouch = { [weak renderer] point in renderer?.touch = point }

            context.coordinator.renderer = renderer

            configureDrawingMode(view)
        } catch {
            MetalVisualLog.renderer.error(
                "ParticleLoaderRenderer failed to initialise: \(String(describing: error), privacy: .public)")

            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }

        return view
    }

    func updateUIView(_ uiView: TouchMTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }

        applyConfiguration(to: renderer)

        renderer.setActive(isActive)

        if !isInteractive || !isActive { renderer.touch = nil }

        uiView.isUserInteractionEnabled = isInteractive

        configureDrawingMode(uiView)
    }

    static func dismantleUIView(_ uiView: TouchMTKView, coordinator: Coordinator) {
        coordinator.renderer?.setActive(false)
        coordinator.renderer?.touch = nil
        coordinator.renderer = nil

        uiView.isPaused = true
        uiView.delegate = nil
        uiView.onTouch = nil
    }

    private func applyConfiguration(to renderer: ParticleLoaderRenderer) {
        renderer.progress = Float(progress)
        renderer.motionScale = reduceMotion ? 0 : 1
        renderer.surfaceIsLight = surfaceIsLight
    }

    private func configureDrawingMode(_ view: MTKView) {
        let continuous = Self.shouldRenderContinuously(isActive: isActive, reduceMotion: reduceMotion)

        view.enableSetNeedsDisplay = !continuous
        view.isPaused = !continuous

        if isActive && !continuous { view.setNeedsDisplay() }
    }
}
