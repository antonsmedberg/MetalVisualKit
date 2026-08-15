//
//  CameraAccess.swift
//  MetalVisualKit
//
//  Live depth needs the camera. ARKit fails a session with `cameraUnauthorized`
//  when the host app has no `NSCameraUsageDescription` or the user has denied
//  access — and the visible result is an empty render surface, which looks
//  exactly like a bug in the renderer. Deciding before starting the session
//  lets the component fall back to the demo cloud and say why.
//

import AVFoundation
import Foundation

enum CameraAccess {

    enum State: Equatable {
        case granted
        case notDetermined
        case denied
        /// The host app's Info.plist has no `NSCameraUsageDescription`.
        /// Requesting access in this state terminates the app, so never do.
        case usageDescriptionMissing
    }

    /// True when the consuming app declares a camera usage string. Without it,
    /// requesting access is fatal rather than merely unsuccessful.
    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    static func state(
        hasUsageDescription: Bool,
        authorizationStatus: AVAuthorizationStatus
    ) -> State {
        guard hasUsageDescription else { return .usageDescriptionMissing }
        switch authorizationStatus {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Read fresh every time. A cached value goes stale the moment the user
    /// changes the setting in Settings and comes back.
    static var current: State {
        state(
            hasUsageDescription: hasUsageDescription,
            authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    /// Prompts once if the user has not been asked yet. Safe to call
    /// repeatedly: any state other than `.notDetermined` returns unchanged.
    static func request() async -> State {
        guard current == .notDetermined else { return current }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return current
    }
}
