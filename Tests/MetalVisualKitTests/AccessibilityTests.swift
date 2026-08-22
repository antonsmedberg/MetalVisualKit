import MetalKit
import SwiftUI
import XCTest
import simd
@testable import MetalVisualKit

final class AccessibilityTests: XCTestCase {
    private enum ExpectedRendererFailure: Error {
        case rendererUnavailable
    }

    @MainActor
    func testRendererFailureLeavesInstalledOrbitDisabledAndActionsCleared() throws {
        var reportedStatuses: [PointCloudSessionMonitor.Status] = []
        let bridge = PointCloudMetalView(
            source: .demo,
            maxDepth: 5,
            colorMode: .camera,
            reduceMotion: false,
            isActive: true,
            allowsOrbitInteraction: true,
            onSessionStatusChange: { reportedStatuses.append($0) },
            rendererFactory: { _, _ in throw ExpectedRendererFailure.rendererUnavailable }
        )
        let host = UIHostingController(rootView: bridge.frame(width: 240, height: 240))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 240))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        let metalView = try XCTUnwrap(findMetalView(in: host.view))
        let panRecognizers = metalView.gestureRecognizers?.compactMap { recognizer in
            recognizer as? UIPanGestureRecognizer
        } ?? []

        XCTAssertEqual(panRecognizers.count, 1)
        let installedRecognizer: UIPanGestureRecognizer = try XCTUnwrap(panRecognizers.first)
        XCTAssertFalse(installedRecognizer.isEnabled)
        XCTAssertNil(metalView.accessibilityCustomActions)
        XCTAssertEqual(reportedStatuses, [.failed("Metal renderer unavailable.")])
    }

    @MainActor
    func testDrawingModeChangesOnlyTheOwnedOrbitRecognizer() {
        let bridge = PointCloudMetalView(
            source: .demo,
            maxDepth: 5,
            colorMode: .camera,
            reduceMotion: false,
            isActive: true,
            allowsOrbitInteraction: true
        )
        let view = MTKView()
        let coordinator = bridge.makeCoordinator()
        let ownedRecognizer = PointCloudMetalView.makeOrbitGestureRecognizer(
            target: coordinator,
            action: #selector(PointCloudMetalView.Coordinator.handlePan)
        )
        let hostRecognizer = UIPanGestureRecognizer()
        hostRecognizer.isEnabled = false
        coordinator.orbitGestureRecognizer = ownedRecognizer
        view.addGestureRecognizer(ownedRecognizer)
        view.addGestureRecognizer(hostRecognizer)

        bridge.configureDrawingMode(
            view,
            source: .demo,
            coordinator: coordinator
        )

        XCTAssertTrue(ownedRecognizer.isEnabled)
        XCTAssertFalse(hostRecognizer.isEnabled)
    }

    @MainActor
    func testDemoZoomRecognizerRequiresExplicitOrbitOptIn() {
        let coordinator = PointCloudMetalView.Coordinator()
        let recognizer = PointCloudMetalView.makeZoomGestureRecognizer(
            target: coordinator,
            action: #selector(PointCloudMetalView.Coordinator.handlePinch)
        )

        PointCloudMetalView.configureZoomGesture(
            recognizer,
            source: .demo,
            allowsOrbitInteraction: false
        )
        XCTAssertFalse(recognizer.isEnabled)

        PointCloudMetalView.configureZoomGesture(
            recognizer,
            source: .demo,
            allowsOrbitInteraction: true
        )
        XCTAssertTrue(recognizer.isEnabled)
    }

    @MainActor
    func testBridgeAppliesConfidenceFloorToRenderer() throws {
        let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        let renderer = try PointCloudRenderer(view: metalView, source: .demo)
        let bridge = PointCloudMetalView(
            source: .demo,
            maxDepth: 5,
            colorMode: .camera,
            minimumConfidence: .precise,
            reduceMotion: false,
            isActive: true,
            allowsOrbitInteraction: false,
            rendererFactory: { _, _ in renderer }
        )
        let host = UIHostingController(rootView: bridge.frame(width: 240, height: 240))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 240))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()

        XCTAssertEqual(renderer.minimumConfidence, .precise)
    }

    @MainActor
    func testDismantleDisablesOwnedOrbitAndClearsActions() {
        let view = MTKView()
        let coordinator = PointCloudMetalView.Coordinator()
        let ownedRecognizer = PointCloudMetalView.makeOrbitGestureRecognizer(
            target: coordinator,
            action: #selector(PointCloudMetalView.Coordinator.handlePan)
        )
        ownedRecognizer.isEnabled = true
        coordinator.orbitGestureRecognizer = ownedRecognizer
        view.addGestureRecognizer(ownedRecognizer)
        view.accessibilityCustomActions = coordinator.accessibilityActions

        PointCloudMetalView.dismantleUIView(view, coordinator: coordinator)

        XCTAssertFalse(ownedRecognizer.isEnabled)
        XCTAssertNil(coordinator.orbitGestureRecognizer)
        XCTAssertNil(view.accessibilityCustomActions)
    }

    func testDemoOrbitRequiresExplicitOptIn() {
        XCTAssertFalse(
            PointCloudMetalView.shouldEnableOrbit(source: .demo, allowsOrbitInteraction: false)
        )
        XCTAssertTrue(
            PointCloudMetalView.shouldEnableOrbit(source: .demo, allowsOrbitInteraction: true)
        )
        XCTAssertFalse(
            PointCloudMetalView.shouldEnableOrbit(source: .live, allowsOrbitInteraction: true)
        )
    }

    func testAccessibleOrbitDirectionsMapToPanTranslations() {
        XCTAssertEqual(
            PointCloudMetalView.accessibilityTranslation(for: .left),
            SIMD2<Float>(-48, 0)
        )
        XCTAssertEqual(
            PointCloudMetalView.accessibilityTranslation(for: .right),
            SIMD2<Float>(48, 0)
        )
        XCTAssertEqual(
            PointCloudMetalView.accessibilityTranslation(for: .up),
            SIMD2<Float>(0, -48)
        )
        XCTAssertEqual(
            PointCloudMetalView.accessibilityTranslation(for: .down),
            SIMD2<Float>(0, 48)
        )
    }

    @MainActor
    private func findMetalView(in view: UIView) -> MTKView? {
        if let metalView = view as? MTKView {
            return metalView
        }
        for subview in view.subviews {
            if let metalView = findMetalView(in: subview) {
                return metalView
            }
        }
        return nil
    }
}
