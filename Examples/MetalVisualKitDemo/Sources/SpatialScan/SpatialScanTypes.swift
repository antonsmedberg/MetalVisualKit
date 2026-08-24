//
//  SpatialScanTypes.swift
//  MetalVisualKitDemo
//

import Foundation

/// User intent for the demo capture lifecycle.
///
/// This is deliberately separate from `LiDARPointCloudPhase`.
/// Capture mode says what the person requested; the point-cloud phase
/// describes what ARKit is currently able to deliver.
enum SpatialCaptureMode: Equatable {
    case idle
    case live
    case paused
}

struct SpatialScanStatus: Equatable {
    let title: String
    let symbol: String
}
