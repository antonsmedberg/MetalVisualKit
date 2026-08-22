//
//  PointCloudMetalView.swift
//  MetalVisualKit
//
//  UIViewRepresentable bridge between SwiftUI and PointCloudRenderer. Owns the
//  MTKView lifecycle, the orbit gesture and the accessibility surface; owns no
//  rendering.
//

import ARKit
import MetalKit
import SwiftUI
import UIKit

struct PointCloudMetalView: UIViewRepresentable {
    /// Clamped by the caller before it reaches the renderer.
    static let depthRange: ClosedRange<Float> = 0.5...5

    var source: PointCloudSource
    var maxDepth: Float
    var colorMode: PointCloudColorMode
    var reduceMotion: Bool
    var isActive: Bool
    var allowsOrbitInteraction: Bool
    var onSessionStatusChange: (PointCloudSessionMonitor.Status) -> Void = { _ in }
    var rendererFactory: @MainActor (MTKView, PointCloudSource) throws -> PointCloudRenderer = {
        try PointCloudRenderer(view: $0, source: $1)
    }

    enum OrbitAccessibilityDirection {
        case left
        case right
        case up
        case down
    }

    static func shouldRenderContinuously(
        source: PointCloudSource,
        isActive: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isActive && !(source == .demo && reduceMotion)
    }

    static func shouldEnableOrbit(
        source: PointCloudSource,
        allowsOrbitInteraction: Bool
    ) -> Bool {
        source == .demo && allowsOrbitInteraction
    }

    static func accessibilityTranslation(
        for direction: OrbitAccessibilityDirection
    ) -> SIMD2<Float> {
        switch direction {
        case .left: return SIMD2(-48, 0)
        case .right: return SIMD2(48, 0)
        case .up: return SIMD2(0, -48)
        case .down: return SIMD2(0, 48)
        }
    }

    @MainActor
    static func makeOrbitGestureRecognizer(
        target: AnyObject?,
        action: Selector?
    ) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer(target: target, action: action)
        recognizer.isEnabled = false
        return recognizer
    }

    @MainActor
    static func configureOrbitGesture(
        _ recognizer: UIPanGestureRecognizer?,
        source: PointCloudSource,
        allowsOrbitInteraction: Bool
    ) {
        recognizer?.isEnabled = shouldEnableOrbit(
            source: source,
            allowsOrbitInteraction: allowsOrbitInteraction
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var renderer: PointCloudRenderer?
        var failedSource: PointCloudSource?
        weak var view: MTKView?
        weak var orbitGestureRecognizer: UIPanGestureRecognizer?
        /// Reassigned on every SwiftUI update so the renderer always reports
        /// into the current view's state rather than a captured stale copy.
        var onSessionStatusChange: (PointCloudSessionMonitor.Status) -> Void = { _ in }

        @discardableResult
        private func updateOrbit(translation: SIMD2<Float>) -> Bool {
            guard let renderer, let view else { return false }
            renderer.updateDemoOrbit(translation: translation)
            if view.isPaused {
                view.setNeedsDisplay()
            }
            return true
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed,
                  let view = gesture.view as? MTKView
            else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            updateOrbit(
                translation: SIMD2(Float(delta.x), Float(delta.y))
            )
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

        var accessibilityActions: [UIAccessibilityCustomAction] {
            [
                UIAccessibilityCustomAction(
                    name: "Rotate left",
                    target: self,
                    selector: #selector(rotateLeft)
                ),
                UIAccessibilityCustomAction(
                    name: "Rotate right",
                    target: self,
                    selector: #selector(rotateRight)
                ),
                UIAccessibilityCustomAction(
                    name: "Rotate up",
                    target: self,
                    selector: #selector(rotateUp)
                ),
                UIAccessibilityCustomAction(
                    name: "Rotate down",
                    target: self,
                    selector: #selector(rotateDown)
                )
            ]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.view = view
        context.coordinator.onSessionStatusChange = onSessionStatusChange
        let orbitGestureRecognizer = Self.makeOrbitGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan)
        )
        context.coordinator.orbitGestureRecognizer = orbitGestureRecognizer
        view.addGestureRecognizer(orbitGestureRecognizer)
        attachRenderer(to: view, coordinator: context.coordinator)
        return view
    }

    func configureDrawingMode(
        _ view: MTKView,
        source: PointCloudSource,
        coordinator: Coordinator
    ) {
        let continuous = Self.shouldRenderContinuously(
            source: source,
            isActive: isActive,
            reduceMotion: reduceMotion
        )
        view.enableSetNeedsDisplay = !continuous
        view.isPaused = !continuous
        let orbitEnabled = Self.shouldEnableOrbit(
            source: source,
            allowsOrbitInteraction: allowsOrbitInteraction
        )
        Self.configureOrbitGesture(
            coordinator.orbitGestureRecognizer,
            source: source,
            allowsOrbitInteraction: allowsOrbitInteraction
        )
        view.isAccessibilityElement = true
        view.accessibilityLabel = source == .live
            ? "Live depth point cloud, coloured by \(colorMode.title.lowercased())"
            : "Demo point cloud"
        view.accessibilityHint = orbitEnabled
            ? "Use the custom actions to rotate the cloud."
            : nil
        view.accessibilityCustomActions = orbitEnabled ? coordinator.accessibilityActions : nil
        if isActive && !continuous {
            view.setNeedsDisplay()
        }
    }

    /// Builds a renderer for the current source and attaches it, tearing down
    /// any previous one first.
    private func attachRenderer(to view: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.setActive(false)
        view.delegate = nil
        coordinator.renderer = nil
        Self.configureOrbitGesture(
            coordinator.orbitGestureRecognizer,
            source: source,
            allowsOrbitInteraction: false
        )
        view.accessibilityHint = nil
        view.accessibilityCustomActions = nil
        do {
            let renderer = try rendererFactory(view, source)
            // Apply lifecycle state before the delegate is attached, so no
            // frame is drawn — and no AR session started — for a scene that is
            // not active yet.
            renderer.maxDepth = maxDepth.clamped(to: PointCloudMetalView.depthRange)
            renderer.colorMode = colorMode
            renderer.motionScale = reduceMotion ? 0 : 1
            renderer.onSessionStatusChange = { [weak coordinator] status in
                coordinator?.onSessionStatusChange(status)
            }
            renderer.setActive(isActive)
            view.delegate = renderer
            coordinator.renderer = renderer
            coordinator.failedSource = nil
            configureDrawingMode(view, source: renderer.source, coordinator: coordinator)
        } catch {
            Self.configureOrbitGesture(
                coordinator.orbitGestureRecognizer,
                source: source,
                allowsOrbitInteraction: false
            )
            coordinator.failedSource = source
            coordinator.onSessionStatusChange(.failed("Metal renderer unavailable."))
            MetalVisualLog.renderer.error(
                "PointCloudRenderer failed to initialise: \(String(describing: error), privacy: .public)"
            )
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onSessionStatusChange = onSessionStatusChange

        // SwiftUI reuses the same MTKView across updates and does not call
        // makeUIView again, but `source` is fixed at renderer construction. When
        // camera permission is granted or revoked the resolved source flips, so
        // the renderer has to be rebuilt or the view stays stuck on the old one
        // — demo forever after permission is granted, or a live session running
        // after it is revoked.
        if context.coordinator.renderer?.source != source {
            if context.coordinator.failedSource != source {
                attachRenderer(to: uiView, coordinator: context.coordinator)
            }
            return
        }

        let renderer = context.coordinator.renderer
        renderer?.maxDepth = maxDepth.clamped(to: PointCloudMetalView.depthRange)
        renderer?.colorMode = colorMode
        renderer?.motionScale = reduceMotion ? 0 : 1
        if let orientation = uiView.window?.windowScene?.interfaceOrientation {
            renderer?.interfaceOrientation = orientation
        }

        // Releasing the camera when the scene leaves the foreground is not
        // optional for an ARSession — it keeps running otherwise. setActive is
        // idempotent, so this does nothing on an ordinary state change.
        renderer?.setActive(isActive)
        configureDrawingMode(
            uiView,
            source: renderer?.source ?? source,
            coordinator: context.coordinator
        )
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.onSessionStatusChange = nil
        coordinator.renderer?.pause()
        coordinator.orbitGestureRecognizer?.isEnabled = false
        coordinator.orbitGestureRecognizer = nil
        coordinator.view = nil
        uiView.isPaused = true
        uiView.delegate = nil
        uiView.accessibilityCustomActions = nil
    }
}
