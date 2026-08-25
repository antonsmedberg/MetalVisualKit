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
    var pointSize: Float = 3
    var maxDepth: Float = 5
    /// Raw `ARConfidenceLevel`. The default keeps medium and high.
    var minConfidence: Float = PointCloudConfidenceFloor.balanced.rawValue
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

// MARK: - Confidence floor

/// Minimum ARKit confidence level the renderer accepts as geometry.
public enum PointCloudConfidenceFloor: Float, CaseIterable, Identifiable, Sendable {
    /// Include low, medium and high confidence samples.
    case all = 0
    /// Include medium and high confidence samples.
    case balanced = 1
    /// Include only high confidence samples.
    case precise = 2

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: return "All"
        case .balanced: return "Balanced"
        case .precise: return "Precise"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: return "circle.grid.3x3"
        case .balanced: return "circle.grid.2x2"
        case .precise: return "scope"
        }
    }
}

// MARK: - Capture phase

/// Resolved state of a ``LiDARPointCloudView`` capture request.
public enum LiDARPointCloudPhase: Equatable, Sendable {
    case idle
    case preparing(String)
    case tracking
    case limited(String)
    case interrupted
    case fallback(String)
    case failed(String)

    public var title: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing"
        case .tracking: return "Live"
        case .limited: return "Limited"
        case .interrupted: return "Interrupted"
        case .fallback: return "Demo"
        case .failed: return "Failed"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: return "circle.dashed"
        case .preparing: return "viewfinder"
        case .tracking: return "sensor.tag.radiowaves.forward"
        case .limited: return "exclamationmark.triangle"
        case .interrupted: return "pause.fill"
        case .fallback: return "cube.transparent"
        case .failed: return "xmark.octagon"
        }
    }
}

// MARK: - Source

/// Which source the point cloud renders from.
enum PointCloudSource: Equatable, Sendable {
    case live
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
