//
//  PointCloudMath.swift
//  MetalVisualKit
//
//  Pure projection, orientation and interaction maths for the point-cloud
//  renderer. These helpers do not touch renderer state and deliberately remain
//  nonisolated so they can be used and tested outside MainActor.
//

import UIKit
import simd

extension PointCloudRenderer {

    // MARK: - Demo Camera

    struct DemoOrbit: Equatable, Sendable {
        var azimuth: Float
        var elevation: Float
    }

    nonisolated static let demoElevationLimit: Float = .pi / 3
    nonisolated static let demoZoomRange: ClosedRange<Float> = 0.65...1.8

    nonisolated static func updatedDemoOrbit(
        _ orbit: DemoOrbit, translation: SIMD2<Float>, sensitivity: Float = 0.005
    ) -> DemoOrbit {
        let azimuth = orbit.azimuth + translation.x * sensitivity

        let elevation = min(max(orbit.elevation - translation.y * sensitivity, -demoElevationLimit), demoElevationLimit)

        return DemoOrbit(azimuth: azimuth, elevation: elevation)
    }

    nonisolated static func updatedDemoZoom(_ zoom: Float, pinchScale: Float) -> Float {
        guard pinchScale.isFinite, pinchScale > 0 else { return zoom }

        return (zoom / pinchScale).clamped(to: demoZoomRange)
    }

    /// Returns the camera distance required to fit a sphere inside whichever
    /// projection axis is more restrictive.
    nonisolated static func demoCameraDistance(aspect: Float, fovY: Float, sphereRadius: Float, margin: Float) -> Float
    {
        let safeAspect = max(aspect, 0.01)

        let halfY = fovY * 0.5

        let halfX = atan(tan(halfY) * safeAspect)

        let limitingHalfFOV = max(min(halfY, halfX), 0.01)

        return sphereRadius / sin(limitingHalfFOV) * margin
    }

    // MARK: - Point Sizing

    /// Converts a size expressed in UIKit layout points to Metal drawable
    /// pixels without assuming that contentScaleFactor matches the drawable.
    nonisolated static func drawablePointSize(
        _ sizeInPoints: Float, drawableSize: CGSize, viewportPointSize: CGSize
    ) -> Float {
        guard drawableSize.width > 0, drawableSize.height > 0, viewportPointSize.width > 0, viewportPointSize.height > 0
        else { return sizeInPoints }

        let scaleX = drawableSize.width / viewportPointSize.width

        let scaleY = drawableSize.height / viewportPointSize.height

        return sizeInPoints * Float(min(scaleX, scaleY))
    }

    // MARK: - Confidence

    nonisolated static func confidenceOpacity(level: UInt8, minimum: UInt8) -> Float {
        guard level >= minimum else { return 0 }

        switch level {
        case 0: return 0.25

        case 1: return 0.55

        default: return 1
        }
    }

    // MARK: - Projection

    /// Creates a right-handed Metal projection matrix whose clip-space depth
    /// range is [0, 1].
    nonisolated static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)

        let x = y / aspect
        let z = far / (near - far)

        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0), SIMD4<Float>(0, y, 0, 0), SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0))
    }

    // MARK: - View Matrices

    nonisolated static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let zAxis = simd_normalize(eye - center)

        let xAxis = simd_normalize(simd_cross(up, zAxis))

        let yAxis = simd_cross(zAxis, xAxis)

        return simd_float4x4(
            SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0), SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
            SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
            SIMD4<Float>(-simd_dot(xAxis, eye), -simd_dot(yAxis, eye), -simd_dot(zAxis, eye), 1))
    }

    /// Rotates depth-camera coordinates into ARKit camera coordinates for the
    /// current interface orientation.
    nonisolated static func rotateToARCamera(for orientation: UIInterfaceOrientation) -> simd_float4x4 {
        let flipYZ = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))

        let angle: Float

        switch orientation {
        case .landscapeLeft: angle = .pi

        case .landscapeRight: angle = 0

        case .portraitUpsideDown: angle = -.pi / 2

        default: angle = .pi / 2
        }

        let rotation = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1)))

        return flipYZ * rotation
    }

    /// Converts oriented depth-camera coordinates into world coordinates.
    nonisolated static func localToWorld(
        viewMatrix: simd_float4x4, orientation: UIInterfaceOrientation
    ) -> simd_float4x4 { viewMatrix.inverse * rotateToARCamera(for: orientation) }
}
