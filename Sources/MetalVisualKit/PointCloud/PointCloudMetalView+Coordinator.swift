//
//  PointCloudMetalView+Coordinator.swift
//  MetalVisualKit
//
//  UIKit interaction and accessibility coordinator for PointCloudMetalView.
//

import MetalKit
import UIKit

extension PointCloudMetalView {

    @MainActor final class Coordinator: NSObject {
        var renderer: PointCloudRenderer?
        var failedSource: PointCloudSource?

        weak var view: MTKView?
        weak var orbitGestureRecognizer: UIPanGestureRecognizer?
        weak var zoomGestureRecognizer: UIPinchGestureRecognizer?

        var onSessionStatusChange: (PointCloudSessionMonitor.Status) -> Void = { _ in }

        @discardableResult private func updateOrbit(translation: SIMD2<Float>) -> Bool {
            guard let renderer, let view else { return false }

            renderer.updateDemoOrbit(translation: translation)

            requestDrawIfNeeded(on: view)

            return true
        }

        @discardableResult private func updateZoom(scale: Float) -> Bool {
            guard let renderer, let view else { return false }

            renderer.updateDemoZoom(pinchScale: scale)

            requestDrawIfNeeded(on: view)

            return true
        }

        private func requestDrawIfNeeded(on view: MTKView) {
            guard view.isPaused else { return }

            view.setNeedsDisplay()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed, let view = gesture.view as? MTKView else {
                return
            }

            let translation = gesture.translation(in: view)

            gesture.setTranslation(.zero, in: view)

            _ = updateOrbit(translation: SIMD2(Float(translation.x), Float(translation.y)))
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed else { return }

            _ = updateZoom(scale: Float(gesture.scale))

            gesture.scale = 1
        }

        @objc func rotateLeft() -> Bool {
            updateOrbit(translation: PointCloudMetalView.accessibilityTranslation(for: .left))
        }

        @objc func rotateRight() -> Bool {
            updateOrbit(translation: PointCloudMetalView.accessibilityTranslation(for: .right))
        }

        @objc func rotateUp() -> Bool {
            updateOrbit(translation: PointCloudMetalView.accessibilityTranslation(for: .up))
        }

        @objc func rotateDown() -> Bool {
            updateOrbit(translation: PointCloudMetalView.accessibilityTranslation(for: .down))
        }

        @objc func zoomIn() -> Bool { updateZoom(scale: 1.15) }

        @objc func zoomOut() -> Bool { updateZoom(scale: 0.87) }

        var accessibilityActions: [UIAccessibilityCustomAction] {
            [
                makeAccessibilityAction(name: "Rotate left", selector: #selector(rotateLeft)),
                makeAccessibilityAction(name: "Rotate right", selector: #selector(rotateRight)),
                makeAccessibilityAction(name: "Rotate up", selector: #selector(rotateUp)),
                makeAccessibilityAction(name: "Rotate down", selector: #selector(rotateDown)),
                makeAccessibilityAction(name: "Zoom in", selector: #selector(zoomIn)),
                makeAccessibilityAction(name: "Zoom out", selector: #selector(zoomOut))
            ]
        }

        private func makeAccessibilityAction(name: String, selector: Selector) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name, target: self, selector: selector)
        }
    }
}
