//
//  PointCloudSessionMonitor.swift
//  MetalVisualKit
//
//  Maps ARKit tracking and lifecycle events to the compact state consumed by
//  the point-cloud presentation layer.
//

import ARKit
import Foundation

@MainActor final class PointCloudSessionMonitor: NSObject {

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case tracking
        case preparing(String)
        case limited(String)
        case interrupted
        case failed(String)

        static let starting = Status.preparing("Starting the camera…")

        var message: String? {
            switch self {
            case .tracking: return nil

            case .preparing(let guidance): return guidance

            case .limited(let guidance): return guidance

            case .interrupted: return "Camera paused — another app is using it."

            case .failed(let reason): return reason
            }
        }

        var isPreparing: Bool {
            if case .preparing = self { return true }

            return false
        }
    }

    // MARK: - State

    private(set) var status: Status = .starting

    var onChange: ((Status) -> Void)?

    var configurationForRestart: (() -> ARConfiguration)?

    // MARK: - Lifecycle

    func prepareForStart() { publish(.starting, force: true) }

    private func publish(_ newStatus: Status, force: Bool = false) {
        guard force || newStatus != status else { return }

        status = newStatus
        onChange?(newStatus)
    }

    // MARK: - Mapping

    nonisolated static func status(for trackingState: ARCamera.TrackingState) -> Status {
        switch trackingState {
        case .normal: return .tracking

        case .notAvailable: return .starting

        case .limited(.initializing): return .preparing("Move the device slowly to start tracking.")

        case .limited(.excessiveMotion): return .limited("Slow down — the device is moving too fast.")

        case .limited(.insufficientFeatures): return .limited("Point at a surface with more detail.")

        case .limited(.relocalizing): return .preparing("Re-establishing tracking…")

        case .limited: return .limited("Tracking is limited.")
        }
    }

    nonisolated static func message(for error: Error) -> String {
        guard let arError = error as? ARError else { return "The AR session stopped unexpectedly." }

        switch arError.code {
        case .cameraUnauthorized: return "Camera access is off — enable it in Settings."

        case .sensorUnavailable, .sensorFailed: return "A sensor this session needs is unavailable."

        case .unsupportedConfiguration: return "This device does not support the requested AR configuration."

        case .worldTrackingFailed: return "World tracking failed. Restarting may help."

        default: return "The AR session stopped unexpectedly."
        }
    }
}

// MARK: - ARSessionDelegate

extension PointCloudSessionMonitor: @preconcurrency ARSessionDelegate {

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        publish(Self.status(for: camera.trackingState))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let failureMessage = Self.message(for: error)

        MetalVisualLog.renderer.error("ARSession failed: \(String(describing: error), privacy: .public)")

        publish(.failed(failureMessage))
    }

    func sessionWasInterrupted(_ session: ARSession) { publish(.interrupted) }

    func sessionInterruptionEnded(_ session: ARSession) {
        if let configuration = configurationForRestart?() {
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }

        publish(.preparing("Move the device to re-establish tracking."))
    }
}
