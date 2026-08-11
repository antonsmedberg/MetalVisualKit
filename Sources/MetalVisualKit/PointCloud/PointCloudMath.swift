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
    /// Live mode is validated in portrait; the other cases follow the same
    /// orientation derivation as Apple's *Visualizing a Point Cloud Using Scene
    /// Depth* sample. See `THIRD_PARTY_NOTICES.md` for attribution and license.
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
}
