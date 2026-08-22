//
//  PointCloudMath.swift
//  MetalVisualKit
//
//  Projection and orientation maths for the point cloud, kept separate from the
//  renderer so it can be tested without a Metal device or an AR session.
//
//  Metal clip space runs z in [0, 1], unlike OpenGL's [-1, 1]. Getting that
//  wrong makes the entire cloud disappear, which is why PipelineTests pins both
//  the near and far plane mappings.
//

import ARKit
import simd
import UIKit

extension PointCloudRenderer {

    struct DemoOrbit: Equatable {
        var azimuth: Float
        var elevation: Float
    }

    static let demoElevationLimit: Float = .pi / 3
    static let demoZoomRange: ClosedRange<Float> = 0.65...1.8

    static func updatedDemoOrbit(
        _ orbit: DemoOrbit,
        translation: SIMD2<Float>,
        sensitivity: Float = 0.005
    ) -> DemoOrbit {
        DemoOrbit(
            azimuth: orbit.azimuth + translation.x * sensitivity,
            elevation: min(
                max(orbit.elevation - translation.y * sensitivity, -demoElevationLimit),
                demoElevationLimit
            )
        )
    }

    static func updatedDemoZoom(_ zoom: Float, pinchScale: Float) -> Float {
        guard pinchScale.isFinite, pinchScale > 0 else { return zoom }
        return (zoom / pinchScale).clamped(to: demoZoomRange)
    }

    /// Camera distance that fits a sphere against whichever projection cone is
    /// tighter. Portrait layouts are constrained horizontally; fitting only the
    /// vertical field of view clips both sides of the procedural cloud.
    static func demoCameraDistance(
        aspect: Float,
        fovY: Float,
        sphereRadius: Float,
        margin: Float
    ) -> Float {
        let safeAspect = max(aspect, 0.01)
        let halfY = fovY * 0.5
        let halfX = atan(tan(halfY) * safeAspect)
        let limitingHalfFOV = max(min(halfY, halfX), 0.01)
        return sphereRadius / sin(limitingHalfFOV) * margin
    }

    /// Converts a caller-facing size in layout points to Metal drawable pixels.
    /// Deriving scale from both viewport dimensions avoids assuming that UIKit's
    /// `contentScaleFactor` still matches a dynamically resized drawable.
    static func drawablePointSize(
        _ sizeInPoints: Float,
        drawableSize: CGSize,
        viewportPointSize: CGSize
    ) -> Float {
        guard drawableSize.width > 0, drawableSize.height > 0,
              viewportPointSize.width > 0, viewportPointSize.height > 0
        else { return sizeInPoints }
        let scaleX = drawableSize.width / viewportPointSize.width
        let scaleY = drawableSize.height / viewportPointSize.height
        return sizeInPoints * Float(min(scaleX, scaleY))
    }

    static func confidenceOpacity(level: UInt8, minimum: UInt8) -> Float {
        guard level >= minimum else { return 0 }
        switch level {
        case 0: return 0.25
        case 1: return 0.55
        default: return 1
        }
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let zAxis = simd_normalize(eye - center)
        let xAxis = simd_normalize(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        return simd_float4x4(
            SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0),
            SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
            SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
            SIMD4<Float>(
                -simd_dot(xAxis, eye), -simd_dot(yAxis, eye), -simd_dot(zAxis, eye), 1
            )
        )
    }

    /// Rotates depth-camera space into ARKit camera space for the given
    /// interface orientation.
    ///
    /// The cases follow the orientation derivation from Apple's *Visualizing a
    /// Point Cloud Using Scene Depth* sample. The project owner's first hardware
    /// pass exposed the surrounding `localToWorld` defect; all orientations still
    /// need a fresh device regression pass. See `THIRD_PARTY_NOTICES.md`.
    static func rotateToARCamera(for orientation: UIInterfaceOrientation) -> simd_float4x4 {
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

    /// Transforms depth-camera coordinates into world space for the oriented
    /// camera view. ARKit's `viewMatrix(for:)` already contains the interface
    /// orientation, so its inverse—not the raw camera transform—must anchor the
    /// unprojected points.
    static func localToWorld(
        viewMatrix: simd_float4x4,
        orientation: UIInterfaceOrientation
    ) -> simd_float4x4 {
        viewMatrix.inverse * rotateToARCamera(for: orientation)
    }
}
