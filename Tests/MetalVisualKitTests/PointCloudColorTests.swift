//
//  PointCloudColorTests.swift
//  MetalVisualKitTests
//
//  Covers the camera-colour path: the plane geometry the texture binder depends
//  on, the colour-mode encoding the shader decodes, and the session-state
//  mapping the view shows.
//

import ARKit
import CoreVideo
import XCTest
@testable import MetalVisualKit

final class PointCloudColorTests: XCTestCase {

    // MARK: - Fixtures

    private func makePixelBuffer(
        width: Int,
        height: Int,
        format: OSType
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("Pixel buffer creation failed (CVReturn \(status)).")
        }
        return buffer
    }

    // MARK: - Plane geometry
    //
    // CVPixelBufferGetWidthOfPlane returns 0 for a non-planar buffer, and the
    // depth and confidence maps are non-planar while the camera image is not.
    // Asking for a plane size unconditionally therefore produces a zero-sized
    // texture request and a frame that silently never draws.

    func testNonPlanarDepthBufferReportsFullSize() throws {
        let buffer = try makePixelBuffer(
            width: 256, height: 192, format: kCVPixelFormatType_DepthFloat32
        )
        let size = ARFrameTextures.size(of: buffer, planeIndex: 0)
        XCTAssertEqual(size.width, 256)
        XCTAssertEqual(size.height, 192)
    }

    func testCameraBufferReportsPerPlaneSizes() throws {
        let buffer = try makePixelBuffer(
            width: 1920, height: 1440, format: ARFrameTextures.cameraPixelFormat
        )
        XCTAssertTrue(CVPixelBufferIsPlanar(buffer))
        XCTAssertGreaterThanOrEqual(CVPixelBufferGetPlaneCount(buffer), 2)

        let luma = ARFrameTextures.size(of: buffer, planeIndex: 0)
        XCTAssertEqual(luma.width, 1920)
        XCTAssertEqual(luma.height, 1440)

        // 4:2:0 chroma is subsampled by two in both directions.
        let chroma = ARFrameTextures.size(of: buffer, planeIndex: 1)
        XCTAssertEqual(chroma.width, 960)
        XCTAssertEqual(chroma.height, 720)
    }

    // MARK: - Colour mode encoding
    //
    // The shader selects a branch by comparing colorMode against midpoints, so
    // the values must be distinct whole numbers exactly one apart.

    func testColorModeShaderValuesAreConsecutiveWholeNumbers() {
        let values = PointCloudColorMode.allCases.map(\.shaderValue).sorted()
        XCTAssertEqual(values, [0, 1, 2])
        for value in values {
            XCTAssertEqual(value, value.rounded(), "colorMode \(value) must be a whole number.")
        }
    }

    func testCloudUniformsDefaultToCameraColour() {
        XCTAssertEqual(CloudUniforms().colorMode, PointCloudColorMode.camera.shaderValue)
    }

    func testEveryColorModeHasDistinctLabelAndSymbol() {
        let titles = Set(PointCloudColorMode.allCases.map(\.title))
        let symbols = Set(PointCloudColorMode.allCases.map(\.symbolName))
        XCTAssertEqual(titles.count, PointCloudColorMode.allCases.count)
        XCTAssertEqual(symbols.count, PointCloudColorMode.allCases.count)
    }

    func testConfidenceFloorsMapToRawARKitLevels() {
        XCTAssertEqual(PointCloudConfidenceFloor.all.rawValue, 0)
        XCTAssertEqual(PointCloudConfidenceFloor.balanced.rawValue, 1)
        XCTAssertEqual(PointCloudConfidenceFloor.precise.rawValue, 2)
        XCTAssertEqual(CloudUniforms().minConfidence, PointCloudConfidenceFloor.balanced.rawValue)
    }

    // MARK: - Session status

    func testNormalTrackingShowsNothing() {
        XCTAssertNil(PointCloudSessionMonitor.status(for: .normal).message)
    }

    func testPreparingStatesAreDistinctFromActionableTrackingLimits() {
        XCTAssertTrue(PointCloudSessionMonitor.Status.starting.isPreparing)
        XCTAssertTrue(
            PointCloudSessionMonitor.status(for: .limited(.initializing)).isPreparing
        )
        XCTAssertTrue(
            PointCloudSessionMonitor.status(for: .limited(.relocalizing)).isPreparing
        )
        XCTAssertFalse(
            PointCloudSessionMonitor.status(for: .limited(.excessiveMotion)).isPreparing
        )
    }

    func testPublicPhaseDistinguishesIntentFromResolvedCaptureState() {
        XCTAssertEqual(
            LiDARPointCloudView.phase(
                isActive: false,
                fallbackReason: nil,
                status: .tracking
            ),
            .idle
        )
        XCTAssertEqual(
            LiDARPointCloudView.phase(
                isActive: true,
                fallbackReason: "No LiDAR scanner.",
                status: .tracking
            ),
            .fallback("No LiDAR scanner.")
        )
        XCTAssertEqual(
            LiDARPointCloudView.phase(
                isActive: true,
                fallbackReason: nil,
                status: .preparing("Starting…")
            ),
            .preparing("Starting…")
        )
        XCTAssertEqual(
            LiDARPointCloudView.phase(
                isActive: true,
                fallbackReason: nil,
                status: .tracking
            ),
            .tracking
        )
    }

    func testPausedCaptureSuppressesStaleSessionOverlay() {
        XCTAssertFalse(
            LiDARPointCloudView.shouldShowSessionOverlay(
                captureIsActive: false,
                isLive: true,
                message: "Starting the camera…"
            )
        )
        XCTAssertTrue(
            LiDARPointCloudView.shouldShowSessionOverlay(
                captureIsActive: true,
                isLive: true,
                message: "Starting the camera…"
            )
        )
    }

    func testEveryLimitedReasonProducesGuidance() {
        let reasons: [ARCamera.TrackingState.Reason] = [
            .initializing, .excessiveMotion, .insufficientFeatures, .relocalizing
        ]
        var messages: Set<String> = []
        for reason in reasons {
            guard let message = PointCloudSessionMonitor.status(for: .limited(reason)).message else {
                XCTFail("No guidance for \(reason).")
                continue
            }
            messages.insert(message)
        }
        // Different causes need different advice, or the banner tells the user
        // nothing they can act on.
        XCTAssertEqual(messages.count, reasons.count)
    }

    func testUnauthorizedCameraIsReportedAsAPermissionProblem() {
        // Built as an NSError in ARKit's domain, which is what ARKit itself
        // hands the delegate; ARError bridges from it.
        let error = NSError(
            domain: ARErrorDomain,
            code: ARError.Code.cameraUnauthorized.rawValue
        )
        let message = PointCloudSessionMonitor.message(for: error)
        XCTAssertTrue(message.contains("Settings"), "Got: \(message)")
    }

    func testNonARErrorFallsBackToAGenericMessage() {
        let error = NSError(domain: "test", code: 1)
        XCTAssertFalse(PointCloudSessionMonitor.message(for: error).isEmpty)
    }

    func testInterruptedStatusExplainsItself() {
        XCTAssertNotNil(PointCloudSessionMonitor.Status.interrupted.message)
    }

    func testSessionStartRepublishesPreparingState() {
        let monitor = PointCloudSessionMonitor()
        var reported: [PointCloudSessionMonitor.Status] = []
        monitor.onChange = { reported.append($0) }

        monitor.prepareForStart()

        XCTAssertEqual(reported, [.starting])
    }
}
