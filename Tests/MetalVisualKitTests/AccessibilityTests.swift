import XCTest
import simd
@testable import MetalVisualKit

final class AccessibilityTests: XCTestCase {
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
}
