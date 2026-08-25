//
//  AccessibilityTests.swift
//  MetalVisualKitTests
//
//  Accessibility and interaction behaviour for the point-cloud SwiftUI bridge.
//

import MetalKit
import SwiftUI
import UIKit
import XCTest
import simd

@testable import MetalVisualKit

final class AccessibilityTests: XCTestCase {

    private enum ExpectedRendererFailure: Error { case rendererUnavailable }

    @MainActor private struct MountedBridge {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let metalView: MTKView
    }

    // MARK: - Renderer Failure

    @MainActor func testRendererFailureLeavesGesturesDisabledAndActionsCleared() throws {
        var statuses: [PointCloudSessionMonitor.Status] = []

        let bridge = PointCloudMetalView(
            source: .demo, maxDepth: 5, colorMode: .camera, reduceMotion: false, isActive: true,
            allowsOrbitInteraction: true, onSessionStatusChange: { statuses.append($0) },
            rendererFactory: { _, _ in throw ExpectedRendererFailure.rendererUnavailable })

        let mounted = try mount(bridge)

        defer { mounted.window.isHidden = true }

        let pan = try XCTUnwrap(panRecognizers(in: mounted.metalView).first)

        let pinch = try XCTUnwrap(pinchRecognizers(in: mounted.metalView).first)

        XCTAssertFalse(pan.isEnabled)

        XCTAssertFalse(pinch.isEnabled)

        XCTAssertNil(mounted.metalView.accessibilityCustomActions)

        XCTAssertEqual(statuses, [.failed("Metal renderer unavailable.")])
    }

    // MARK: - Demo Interaction

    @MainActor func testDemoBridgeEnablesOrbitAndZoomWhenOptedIn() throws {
        let bridge = PointCloudMetalView(
            source: .demo, maxDepth: 5, colorMode: .camera, reduceMotion: false, isActive: true,
            allowsOrbitInteraction: true)

        let mounted = try mount(bridge)

        defer { mounted.window.isHidden = true }

        let pan = try XCTUnwrap(panRecognizers(in: mounted.metalView).first)

        let pinch = try XCTUnwrap(pinchRecognizers(in: mounted.metalView).first)

        XCTAssertTrue(pan.isEnabled)

        XCTAssertTrue(pinch.isEnabled)

        XCTAssertEqual(mounted.metalView.accessibilityCustomActions?.count, 6)

        XCTAssertNotNil(mounted.metalView.accessibilityHint)
    }

    @MainActor func testDemoBridgeKeepsGesturesDisabledWithoutOptIn() throws {
        let bridge = PointCloudMetalView(
            source: .demo, maxDepth: 5, colorMode: .camera, reduceMotion: false, isActive: true,
            allowsOrbitInteraction: false)

        let mounted = try mount(bridge)

        defer { mounted.window.isHidden = true }

        let pan = try XCTUnwrap(panRecognizers(in: mounted.metalView).first)

        let pinch = try XCTUnwrap(pinchRecognizers(in: mounted.metalView).first)

        XCTAssertFalse(pan.isEnabled)

        XCTAssertFalse(pinch.isEnabled)

        XCTAssertNil(mounted.metalView.accessibilityCustomActions)

        XCTAssertNil(mounted.metalView.accessibilityHint)
    }

    // MARK: - Renderer Configuration

    @MainActor func testBridgeAppliesConfidenceFloorToRenderer() throws {
        var capturedRenderer: PointCloudRenderer?

        let bridge = PointCloudMetalView(
            source: .demo, maxDepth: 5, colorMode: .camera, minimumConfidence: .precise, reduceMotion: false,
            isActive: true, allowsOrbitInteraction: false,
            rendererFactory: { view, source in
                let renderer = try PointCloudRenderer(view: view, source: source)

                capturedRenderer = renderer

                return renderer
            })

        let mounted = try mount(bridge)

        defer { mounted.window.isHidden = true }

        let renderer = try XCTUnwrap(capturedRenderer)

        XCTAssertEqual(renderer.minimumConfidence, .precise)
    }

    // MARK: - Teardown

    @MainActor func testDismantleDisablesOwnedGesturesAndClearsActions() {
        let view = MTKView()
        let coordinator = PointCloudMetalView.Coordinator()

        let pan = UIPanGestureRecognizer(
            target: coordinator, action: #selector(PointCloudMetalView.Coordinator.handlePan))

        let pinch = UIPinchGestureRecognizer(
            target: coordinator, action: #selector(PointCloudMetalView.Coordinator.handlePinch))

        pan.isEnabled = true
        pinch.isEnabled = true

        coordinator.view = view
        coordinator.orbitGestureRecognizer = pan
        coordinator.zoomGestureRecognizer = pinch

        view.addGestureRecognizer(pan)

        view.addGestureRecognizer(pinch)

        view.accessibilityCustomActions = coordinator.accessibilityActions

        PointCloudMetalView.dismantleUIView(view, coordinator: coordinator)

        XCTAssertFalse(pan.isEnabled)

        XCTAssertFalse(pinch.isEnabled)

        XCTAssertNil(coordinator.orbitGestureRecognizer)

        XCTAssertNil(coordinator.zoomGestureRecognizer)

        XCTAssertNil(view.accessibilityCustomActions)
    }

    // MARK: - Pure Interaction Policy

    func testDemoOrbitRequiresExplicitOptIn() {
        XCTAssertFalse(PointCloudMetalView.shouldEnableOrbit(source: .demo, allowsOrbitInteraction: false))

        XCTAssertTrue(PointCloudMetalView.shouldEnableOrbit(source: .demo, allowsOrbitInteraction: true))

        XCTAssertFalse(PointCloudMetalView.shouldEnableOrbit(source: .live, allowsOrbitInteraction: true))
    }

    func testAccessibleOrbitDirectionsMapToPanTranslations() {
        XCTAssertEqual(PointCloudMetalView.accessibilityTranslation(for: .left), SIMD2<Float>(-48, 0))

        XCTAssertEqual(PointCloudMetalView.accessibilityTranslation(for: .right), SIMD2<Float>(48, 0))

        XCTAssertEqual(PointCloudMetalView.accessibilityTranslation(for: .up), SIMD2<Float>(0, -48))

        XCTAssertEqual(PointCloudMetalView.accessibilityTranslation(for: .down), SIMD2<Float>(0, 48))
    }

    // MARK: - Hosting

    @MainActor private func mount(_ bridge: PointCloudMetalView) throws -> MountedBridge {
        let host = UIHostingController(rootView: AnyView(bridge.frame(width: 240, height: 240)))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 240))

        window.rootViewController = host

        window.makeKeyAndVisible()

        host.view.layoutIfNeeded()

        let metalView = try XCTUnwrap(findMetalView(in: host.view))

        return MountedBridge(host: host, window: window, metalView: metalView)
    }

    @MainActor private func findMetalView(in view: UIView) -> MTKView? {
        if let metalView = view as? MTKView { return metalView }

        for subview in view.subviews { if let metalView = findMetalView(in: subview) { return metalView } }

        return nil
    }

    @MainActor private func panRecognizers(in view: MTKView) -> [UIPanGestureRecognizer] {
        view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
    }

    @MainActor private func pinchRecognizers(in view: MTKView) -> [UIPinchGestureRecognizer] {
        view.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer } ?? []
    }
}
