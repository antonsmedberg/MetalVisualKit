//
//  PointCloudTypes.swift
//  MetalVisualKit
//
//  GPU-shared structs for the point cloud, and the source selector.
//

import Metal
import simd

// MARK: - Uniform mirrors
//
// Mirrored by hand against PointCloudShaders.metal. `simd_float3x3` occupies
// 48 bytes (three 16-byte-aligned columns) in both languages, which is what
// makes the straight field-order mirror correct. PipelineTests pins the strides.

/// stride 208, align 16
struct CloudUniforms {
    var viewProjection: simd_float4x4 = matrix_identity_float4x4
    var localToWorld: simd_float4x4 = matrix_identity_float4x4
    var intrinsicsInv: simd_float3x3 = matrix_identity_float3x3
    var cameraResolution: SIMD2<Float> = .zero
    var gridResolution: SIMD2<Float> = .zero
    var pointSize: Float = 8
    var maxDepth: Float = 5
    var time: Float = 0
    /// Raw `ARConfidenceLevel`. 1 keeps medium and high, discarding low.
    var minConfidence: Float = 1
}

/// stride 80, align 16
struct DemoUniforms {
    var viewProjection: simd_float4x4 = matrix_identity_float4x4
    var time: Float = 0
    var pointCount: Float = 24_000
    var pointSize: Float = 60
    var motionScale: Float = 1
}

/// Which source the point cloud renders from.
enum PointCloudSource {
    /// ARKit `sceneDepth`. Requires a device with a LiDAR scanner.
    case live
    /// Procedural cloud. Works everywhere, including previews and the simulator.
    case demo
}
