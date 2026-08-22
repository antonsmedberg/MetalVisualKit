//
//  PointCloudSessionMonitor.swift
//  MetalVisualKit
//
//  An ARSession that is initialising, relocalising or has failed outright looks
//  the same from the outside: an empty render surface. ARKit already knows which
//  of those it is, so this reports it instead of leaving the user to guess.
//

import ARKit
import Foundation

/// Watches an `ARSession` and turns its tracking state into one short line.
///
/// ARKit calls delegate methods on `ARSession.delegateQueue`, which the renderer
/// leaves nil — so every callback here arrives on the main queue, and so does
/// every ``onChange`` call.
final class PointCloudSessionMonitor: NSObject, ARSessionDelegate {

    /// What the session is currently doing, phrased for display.
    enum Status: Equatable {
        /// Running and tracking normally. Nothing to show.
        case tracking
        /// ARKit is building or restoring the world-tracking state.
        case preparing(String)
        /// Usable but degraded, with guidance the user can act on.
        case limited(String)
        /// The camera was taken away — a call, another app, backgrounding.
        case interrupted
        /// The session stopped and will not recover on its own.
        case failed(String)

        /// Where a monitor sits before ARKit has reported anything. Named so
        /// the view's initial state cannot drift from the monitor's.
        static let starting = Status.preparing("Starting the camera…")

        /// The line to show, or nil when there is nothing worth saying.
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

    private(set) var status: Status = .starting {
        didSet {
            guard status != oldValue else { return }
            onChange?(status)
        }
    }

    /// Called on the main queue whenever ``status`` changes.
    var onChange: ((Status) -> Void)?

    /// Configuration to re-run after an interruption ends.
    var configurationForRestart: (() -> ARConfiguration)?

    /// Publishes a fresh preparing state whenever capture starts or resumes,
    /// even when the prior session had already reached normal tracking.
    func prepareForStart() {
        if status == .starting {
            onChange?(.starting)
        } else {
            status = .starting
        }
    }

    // MARK: - ARSessionObserver

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        status = Self.status(for: camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        MetalVisualLog.renderer.error(
            "ARSession failed: \(String(describing: error), privacy: .public)"
        )
        status = .failed(Self.message(for: error))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        status = .interrupted
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Apple's guidance for a resumed session: the world map from before the
        // interruption is no longer trustworthy, so start tracking over rather
        // than drifting against stale anchors.
        if let configuration = configurationForRestart?() {
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
        status = .preparing("Move the device to re-establish tracking.")
    }

    // MARK: - Mapping

    /// Guidance text for a tracking state, kept static so it can be tested
    /// without an AR session.
    static func status(for trackingState: ARCamera.TrackingState) -> Status {
        switch trackingState {
        case .normal:
            return .tracking
        case .notAvailable:
            return .starting
        case .limited(.initializing):
            return .preparing("Move the device slowly to start tracking.")
        case .limited(.excessiveMotion):
            return .limited("Slow down — the device is moving too fast.")
        case .limited(.insufficientFeatures):
            return .limited("Point at a surface with more detail.")
        case .limited(.relocalizing):
            return .preparing("Re-establishing tracking…")
        case .limited:
            return .limited("Tracking is limited.")
        }
    }

    /// Turns the errors a world-tracking session can actually raise into
    /// something the person holding the phone can act on.
    static func message(for error: Error) -> String {
        guard let arError = error as? ARError else {
            return "The AR session stopped unexpectedly."
        }
        switch arError.code {
        case .cameraUnauthorized:
            return "Camera access is off — enable it in Settings."
        case .sensorUnavailable, .sensorFailed:
            return "A sensor this session needs is unavailable."
        case .unsupportedConfiguration:
            return "This device does not support the requested AR configuration."
        case .worldTrackingFailed:
            return "World tracking failed. Restarting may help."
        default:
            return "The AR session stopped unexpectedly."
        }
    }
}
