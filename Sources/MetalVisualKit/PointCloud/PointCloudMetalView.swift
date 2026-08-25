//
//  PointCloudMetalView.swift
//  MetalVisualKit
//
//  SwiftUI bridge for PointCloudRenderer.
//
//  The bridge owns MTKView lifecycle, interaction, redraw policy and
//  accessibility. Rendering and ARKit state remain inside the renderer.
//

import MetalKit
import SwiftUI
import UIKit

@MainActor struct PointCloudMetalView: UIViewRepresentable {
    typealias UIViewType = MTKView

    var source: PointCloudSource
    var maxDepth: Float
    var colorMode: PointCloudColorMode
    var minimumConfidence: PointCloudConfidenceFloor = .balanced
    var reduceMotion: Bool
    var isActive: Bool
    var allowsOrbitInteraction: Bool

    var onSessionStatusChange: (PointCloudSessionMonitor.Status) -> Void = { _ in }

    var rendererFactory: @MainActor (MTKView, PointCloudSource) throws -> PointCloudRenderer = {
        try PointCloudRenderer(view: $0, source: $1)
    }

    enum OrbitAccessibilityDirection: Sendable {
        case left
        case right
        case up
        case down
    }

    // MARK: - Pure Render Policy

    /// Continuous rendering is reserved for an active source.
    ///
    /// Demo rendering respects Reduce Motion by falling back to on-demand
    /// frames. Live capture remains continuous while active because its visual
    /// content is driven by incoming AR frames rather than procedural motion.
    nonisolated static func shouldRenderContinuously(
        source: PointCloudSource, isActive: Bool, reduceMotion: Bool
    ) -> Bool {
        guard isActive else { return false }

        if source == .demo { return !reduceMotion }

        return true
    }

    /// An inactive demo still needs one on-demand frame so previews and
    /// showcase heroes do not become blank.
    ///
    /// Live capture never requests an inactive frame because no ARSession
    /// should be running in that state.
    nonisolated static func shouldRequestOnDemandDraw(
        source: PointCloudSource, isActive: Bool, reduceMotion: Bool
    ) -> Bool {
        guard source == .demo else { return false }

        return !shouldRenderContinuously(source: source, isActive: isActive, reduceMotion: reduceMotion)
    }

    nonisolated static func shouldEnableOrbit(source: PointCloudSource, allowsOrbitInteraction: Bool) -> Bool {
        source == .demo && allowsOrbitInteraction
    }

    nonisolated static func accessibilityTranslation(for direction: OrbitAccessibilityDirection) -> SIMD2<Float> {
        switch direction {
        case .left: return SIMD2(-48, 0)

        case .right: return SIMD2(48, 0)

        case .up: return SIMD2(0, -48)

        case .down: return SIMD2(0, 48)
        }
    }

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())

        let coordinator = context.coordinator

        coordinator.view = view
        coordinator.onSessionStatusChange = onSessionStatusChange

        installGestures(on: view, coordinator: coordinator)

        attachRenderer(to: view, coordinator: coordinator)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let coordinator = context.coordinator

        coordinator.onSessionStatusChange = onSessionStatusChange

        guard coordinator.renderer?.source == source else {
            rebuildRendererIfNeeded(in: uiView, coordinator: coordinator)

            return
        }

        guard let renderer = coordinator.renderer else { return }

        applyConfiguration(to: renderer)

        updateOrientation(of: renderer, from: uiView)

        renderer.setActive(isActive)

        configureDrawingMode(uiView, source: renderer.source, coordinator: coordinator)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.shutdown()

        if let orbit = coordinator.orbitGestureRecognizer {
            orbit.isEnabled = false
            uiView.removeGestureRecognizer(orbit)
        }

        if let zoom = coordinator.zoomGestureRecognizer {
            zoom.isEnabled = false
            uiView.removeGestureRecognizer(zoom)
        }

        uiView.delegate = nil
        uiView.isPaused = true

        uiView.isAccessibilityElement = false
        uiView.accessibilityLabel = nil
        uiView.accessibilityValue = nil
        uiView.accessibilityHint = nil
        uiView.accessibilityCustomActions = nil

        coordinator.orbitGestureRecognizer = nil
        coordinator.zoomGestureRecognizer = nil
        coordinator.renderer = nil
        coordinator.view = nil
    }

    // MARK: - Gestures

    private func installGestures(on view: MTKView, coordinator: Coordinator) {
        let orbit = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan))

        orbit.isEnabled = false
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        orbit.cancelsTouchesInView = false
        orbit.delaysTouchesBegan = false
        orbit.delaysTouchesEnded = false

        let zoom = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch))

        zoom.isEnabled = false
        zoom.cancelsTouchesInView = false
        zoom.delaysTouchesBegan = false
        zoom.delaysTouchesEnded = false

        coordinator.orbitGestureRecognizer = orbit

        coordinator.zoomGestureRecognizer = zoom

        view.addGestureRecognizer(orbit)

        view.addGestureRecognizer(zoom)
    }

    private func configureGestures(coordinator: Coordinator, source: PointCloudSource) {
        let enabled = Self.shouldEnableOrbit(source: source, allowsOrbitInteraction: allowsOrbitInteraction)

        coordinator.orbitGestureRecognizer?.isEnabled = enabled

        coordinator.zoomGestureRecognizer?.isEnabled = enabled
    }

    // MARK: - Drawing

    private func configureDrawingMode(_ view: MTKView, source: PointCloudSource, coordinator: Coordinator) {
        let continuous = Self.shouldRenderContinuously(source: source, isActive: isActive, reduceMotion: reduceMotion)

        view.enableSetNeedsDisplay = !continuous

        view.isPaused = !continuous

        configureGestures(coordinator: coordinator, source: source)

        configureAccessibility(on: view, source: source, coordinator: coordinator)

        if Self.shouldRequestOnDemandDraw(source: source, isActive: isActive, reduceMotion: reduceMotion) {
            view.setNeedsDisplay()
        }
    }

    // MARK: - Accessibility

    private func configureAccessibility(on view: MTKView, source: PointCloudSource, coordinator: Coordinator) {
        let interactionEnabled = Self.shouldEnableOrbit(source: source, allowsOrbitInteraction: allowsOrbitInteraction)

        view.isAccessibilityElement = true

        view.accessibilityLabel = accessibilityLabel(for: source)

        view.accessibilityValue = accessibilityValue(for: source, interactionEnabled: interactionEnabled)

        if interactionEnabled {
            view.accessibilityHint = "Use the custom actions to rotate or zoom the point cloud."

            view.accessibilityCustomActions = coordinator.accessibilityActions
        } else {
            view.accessibilityHint = nil
            view.accessibilityCustomActions = nil
        }
    }

    private func accessibilityLabel(for source: PointCloudSource) -> String {
        switch source {
        case .live: return "Live depth point cloud"

        case .demo: return "Spatial point cloud preview"
        }
    }

    private func accessibilityValue(for source: PointCloudSource, interactionEnabled: Bool) -> String {
        switch source {
        case .live: return "Coloured by \(colorMode.title.lowercased())"

        case .demo: return interactionEnabled ? "Interactive preview" : "Preview"
        }
    }

    // MARK: - Renderer Lifecycle

    private func rebuildRendererIfNeeded(in view: MTKView, coordinator: Coordinator) {
        guard coordinator.failedSource != source else { return }

        attachRenderer(to: view, coordinator: coordinator)
    }

    private func attachRenderer(to view: MTKView, coordinator: Coordinator) {
        detachRenderer(from: view, coordinator: coordinator)

        do {
            let renderer = try rendererFactory(view, source)

            applyConfiguration(to: renderer)

            renderer.onSessionStatusChange = { [weak coordinator] status in

                coordinator?.onSessionStatusChange(status)
            }

            coordinator.renderer = renderer

            coordinator.failedSource = nil

            view.delegate = renderer

            // Establish renderer lifecycle before unpausing or requesting an
            // on-demand frame. This prevents an active live MTKView from racing
            // ahead of ARSession startup.
            renderer.setActive(isActive)

            configureDrawingMode(view, source: renderer.source, coordinator: coordinator)
        } catch { reportRendererFailure(error, view: view, coordinator: coordinator) }
    }

    private func detachRenderer(from view: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.shutdown()

        view.delegate = nil

        coordinator.renderer = nil

        coordinator.orbitGestureRecognizer?.isEnabled = false

        coordinator.zoomGestureRecognizer?.isEnabled = false

        view.accessibilityHint = nil
        view.accessibilityValue = nil
        view.accessibilityCustomActions = nil
    }

    private func applyConfiguration(to renderer: PointCloudRenderer) {
        renderer.maxDepth = maxDepth.clamped(to: LiDARPointCloudView.depthRange)

        renderer.colorMode = colorMode

        renderer.minimumConfidence = minimumConfidence

        renderer.motionScale = reduceMotion ? 0 : 1
    }

    private func updateOrientation(of renderer: PointCloudRenderer, from view: MTKView) {
        guard let orientation = view.window?.windowScene?.interfaceOrientation else { return }

        renderer.interfaceOrientation = orientation
    }

    private func reportRendererFailure(_ error: Error, view: MTKView, coordinator: Coordinator) {
        coordinator.failedSource = source

        coordinator.onSessionStatusChange(.failed("Metal renderer unavailable."))

        MetalVisualLog.renderer.error(
            "PointCloudRenderer failed to initialise: \(String(describing: error), privacy: .public)")

        coordinator.orbitGestureRecognizer?.isEnabled = false

        coordinator.zoomGestureRecognizer?.isEnabled = false

        view.delegate = nil
        view.isPaused = true
        view.enableSetNeedsDisplay = true

        view.isAccessibilityElement = true
        view.accessibilityLabel = "Point cloud unavailable"

        view.accessibilityValue = nil
        view.accessibilityHint = nil
        view.accessibilityCustomActions = nil
    }
}
