import UIKit
import XCTest
import simd
@testable import MetalVisualKit

final class PointCloudMathTests: XCTestCase {
    func testPerspectiveMapsNearPlaneToZeroDepth() {
        let projection = PointCloudRenderer.perspective(
            fovY: .pi / 3, aspect: 1, near: 0.1, far: 100
        )
        let nearPoint = projection * SIMD4<Float>(0, 0, -0.1, 1)
        XCTAssertEqual(nearPoint.z / nearPoint.w, 0, accuracy: 1e-4)
    }

    func testPerspectiveMapsFarPlaneToOneDepth() {
        let projection = PointCloudRenderer.perspective(
            fovY: .pi / 3, aspect: 1, near: 0.1, far: 100
        )
        let farPoint = projection * SIMD4<Float>(0, 0, -100, 1)
        XCTAssertEqual(farPoint.z / farPoint.w, 1, accuracy: 1e-3)
    }

    func testRotateToARCameraIsOrthonormal() {
        for orientation in [UIInterfaceOrientation.portrait, .landscapeLeft,
                            .landscapeRight, .portraitUpsideDown] {
            let matrix = PointCloudRenderer.rotateToARCamera(for: orientation)
            let upper = simd_float3x3(
                SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
            )
            XCTAssertEqual(
                abs(simd_determinant(upper)),
                1,
                accuracy: 1e-5,
                "Orientation \(orientation.rawValue) is not a rigid transform."
            )
        }
    }

    func testLocalToWorldCancelsTheOrientedViewMatrix() {
        let viewMatrix = PointCloudRenderer.lookAt(
            eye: SIMD3<Float>(1.4, 0.7, 2.8),
            center: SIMD3<Float>(0.2, -0.1, 0),
            up: SIMD3<Float>(0, 1, 0)
        )

        for orientation in [UIInterfaceOrientation.portrait, .landscapeLeft,
                            .landscapeRight, .portraitUpsideDown] {
            let localToWorld = PointCloudRenderer.localToWorld(
                viewMatrix: viewMatrix,
                orientation: orientation
            )
            let composed = viewMatrix * localToWorld
            let expected = PointCloudRenderer.rotateToARCamera(for: orientation)

            for column in 0..<4 {
                XCTAssertEqual(
                    simd_length(composed[column] - expected[column]),
                    0,
                    accuracy: 1e-5
                )
            }
        }
    }

    func testLookAtPlacesEyeAtOrigin() {
        let view = PointCloudRenderer.lookAt(
            eye: SIMD3(0, 0, 3), center: .zero, up: SIMD3(0, 1, 0)
        )
        let transformed = view * SIMD4<Float>(0, 0, 3, 1)
        let position = SIMD3(transformed.x, transformed.y, transformed.z)
        XCTAssertEqual(simd_length(position), 0, accuracy: 1e-5)
    }

    func testDemoCameraDistanceFitsTheNarrowerFieldOfView() {
        let fovY: Float = .pi / 3.2
        let radius: Float = 1.15
        let margin: Float = 1.30
        let portraitDistance = PointCloudRenderer.demoCameraDistance(
            aspect: 0.46,
            fovY: fovY,
            sphereRadius: radius,
            margin: margin
        )
        let landscapeDistance = PointCloudRenderer.demoCameraDistance(
            aspect: 2.17,
            fovY: fovY,
            sphereRadius: radius,
            margin: margin
        )
        let portraitHalfX = atan(tan(fovY * 0.5) * 0.46)

        XCTAssertGreaterThan(portraitDistance, landscapeDistance)
        XCTAssertGreaterThanOrEqual(
            portraitDistance * sin(portraitHalfX),
            radius * margin - 1e-5
        )
    }

    func testPointSizeConvertsFromLayoutPointsToDrawablePixels() {
        XCTAssertEqual(
            PointCloudRenderer.drawablePointSize(
                8,
                drawableSize: CGSize(width: 1_206, height: 2_622),
                viewportPointSize: CGSize(width: 402, height: 874)
            ),
            24,
            accuracy: 1e-5
        )
        XCTAssertEqual(
            PointCloudRenderer.drawablePointSize(
                8,
                drawableSize: .zero,
                viewportPointSize: .zero
            ),
            8
        )
    }

    func testLivePointSizeMatchesACompactThreeTimesDisplayFootprint() {
        XCTAssertEqual(PointCloudRenderer.defaultLivePointSize, 3)
        XCTAssertEqual(
            PointCloudRenderer.drawablePointSize(
                PointCloudRenderer.defaultLivePointSize,
                drawableSize: CGSize(width: 1_206, height: 2_622),
                viewportPointSize: CGSize(width: 402, height: 874)
            ),
            9,
            accuracy: 1e-5
        )
    }

    func testConfidenceOpacityPreservesMediumConfidenceAsAVisualCue() {
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 0, minimum: 1), 0)
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 1, minimum: 1), 0.55)
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 2, minimum: 1), 1)
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 2, minimum: 2), 1)
    }

    func testDemoOrbitRespondsToDragAndClampsElevation() {
        let initial = PointCloudRenderer.DemoOrbit(azimuth: 0, elevation: 0)
        let moved = PointCloudRenderer.updatedDemoOrbit(
            initial,
            translation: SIMD2<Float>(100, -10_000)
        )

        XCTAssertNotEqual(moved.azimuth, initial.azimuth)
        XCTAssertEqual(moved.elevation, PointCloudRenderer.demoElevationLimit, accuracy: 1e-5)
    }

    func testDemoZoomRespondsToPinchAndStaysBounded() {
        XCTAssertEqual(PointCloudRenderer.updatedDemoZoom(1, pinchScale: 2), 0.65)
        XCTAssertEqual(PointCloudRenderer.updatedDemoZoom(1, pinchScale: 0.5), 1.8)
        XCTAssertEqual(PointCloudRenderer.updatedDemoZoom(1, pinchScale: 1.25), 0.8)
    }

    func testIdleCloudStartsAtAComfortableViewingDistance() {
        XCTAssertEqual(PointCloudRenderer.defaultDemoZoom, 1.4)
    }
}
