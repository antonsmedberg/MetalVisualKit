//
//  PointCloudTypes.swift
//  MetalVisualKit
//
//  GPU-shared structs for the point cloud, plus the source and colour selectors.
//

import Metal
import simd

// MARK: - Uniform mirrors
//
// Mirrored by hand against PointCloudShaders.metal. `simd_float3x3` occupies
// 48 bytes (three 16-byte-aligned columns) in both languages, which is what
// makes the straight field-order mirror correct. PipelineTests pins the strides
// and Scripts/check-struct-parity.py compares the two declarations directly.

/// stride 208, align 16
struct CloudUniforms {
    var viewProjection: simd_float4x4 = matrix_identity_float4x4
    var localToWorld: simd_float4x4 = matrix_identity_float4x4
    var intrinsicsInv: simd_float3x3 = matrix_identity_float3x3
    var cameraResolution: SIMD2<Float> = .zero
    var gridResolution: SIMD2<Float> = .zero
    var pointSize: Float = 8
    var maxDepth: Float = 5
    /// Raw `ARConfidenceLevel`. 1 keeps medium and high, discarding low.
    var minConfidence: Float = 1
    /// `PointCloudColorMode.shaderValue`. Carried as a float so the struct keeps
    /// one scalar type and the parity script keeps one layout table.
    var colorMode: Float = PointCloudColorMode.camera.shaderValue
}

/// stride 96, align 16
struct DemoUniforms {
    var viewProjection: simd_float4x4 = matrix_identity_float4x4
    var cameraPosition: SIMD3<Float> = SIMD3(0, 0, 3)
    var time: Float = 0
    var pointCount: Float = 24_000
    var pointSize: Float = 60
    var motionScale: Float = 1
}

// MARK: - Source

/// Which source the point cloud renders from.
enum PointCloudSource {
    /// ARKit `sceneDepth`. Requires a device with a LiDAR scanner.
    case live
    /// Procedural cloud. Works everywhere, including previews and the simulator.
    case demo
}

// MARK: - Colour mode

/// How each LiDAR point picks its colour.
public enum PointCloudColorMode: String, CaseIterable, Identifiable, Sendable {
    /// Real colour sampled from the camera image.
    case camera
    /// Near-to-far gradient across the current depth range.
    case depth
    /// ARKit's per-pixel confidence: amber medium and green high. The renderer's
    /// default confidence floor hides low-confidence samples.
    case confidence

    public var id: String { rawValue }

    /// Short label for a picker or segmented control.
    public var title: String {
        switch self {
        case .camera: return "Camera"
        case .depth: return "Depth"
        case .confidence: return "Confidence"
        }
    }

    /// SF Symbol matching ``title``.
    public var symbolName: String {
        switch self {
        case .camera: return "camera"
        case .depth: return "ruler"
        case .confidence: return "checkerboard.shield"
        }
    }

    /// Value written into `CloudUniforms.colorMode`. The shader compares against
    /// midpoints, so these must stay whole numbers one apart.
    var shaderValue: Float {
        switch self {
        case .camera: return 0
        case .depth: return 1
        case .confidence: return 2
        }
    }
}
