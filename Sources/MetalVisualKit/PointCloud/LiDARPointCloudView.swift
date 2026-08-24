//
//  LiDARPointCloudView.swift
//  MetalVisualKit
//
//  SwiftUI entry point for the LiDAR point-cloud renderer.
//  The renderer owns ARKit and Metal work while this view handles permission,
//  lifecycle state, fallback presentation and optional controls.
//

import ARKit
import Foundation
import SwiftUI

struct CameraTaskKey: Equatable {
    let mode: LiDARPointCloudView.DisplayMode
    let phase: ScenePhase
    let isActive: Bool
}

/// Displays a live LiDAR point cloud when the device supports scene depth.
///
/// The default initializer keeps its controls and rendering state together.
/// Use the binding-based initializer when a parent view provides its own
/// controls or HUD.
public struct LiDARPointCloudView: View {
    public enum DisplayMode: Equatable, Sendable {
        case live
        case demo
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let displayMode: DisplayMode
    private let showsControls: Bool
    private let allowsOrbitInteraction: Bool
    private let isActive: Bool
    private let onPhaseChange: (LiDARPointCloudPhase) -> Void

    private let externalColorMode: Binding<PointCloudColorMode>?
    private let externalMinimumConfidence: Binding<PointCloudConfidenceFloor>?
    private let externalMaxDepth: Binding<Float>?

    @State private var internalColorMode: PointCloudColorMode
    @State private var internalMinimumConfidence: PointCloudConfidenceFloor
    @State private var internalMaxDepth: Float
    @State private var cameraState = CameraAccess.current
    @State private var sessionStatus: PointCloudSessionMonitor.Status = .starting

    /// Range used by both the built-in controls and host-provided controls.
    public static let depthRange: ClosedRange<Float> = 0.5...5

    /// Returns whether the current device supports the LiDAR configuration
    /// used by the point-cloud renderer.
    public static var isLiDARAvailable: Bool {
        PointCloudRenderer.isLiDARAvailable
    }

    private var colorMode: Binding<PointCloudColorMode> {
        externalColorMode ?? $internalColorMode
    }

    private var minimumConfidence: Binding<PointCloudConfidenceFloor> {
        externalMinimumConfidence ?? $internalMinimumConfidence
    }

    private var maxDepth: Binding<Float> {
        let base = externalMaxDepth ?? $internalMaxDepth

        return Binding(
            get: {
                Self.clampedDepth(base.wrappedValue)
            },
            set: { value in
                base.wrappedValue = Self.clampedDepth(value)
            }
        )
    }

    /// Creates a point-cloud view that owns its control state.
    public init(
        displayMode: DisplayMode = .live,
        colorMode: PointCloudColorMode = .camera,
        minimumConfidence: PointCloudConfidenceFloor = .balanced,
        maxDepth: Float = 5,
        showsControls: Bool = true,
        allowsOrbitInteraction: Bool = false,
        isActive: Bool = true,
        onPhaseChange: @escaping (LiDARPointCloudPhase) -> Void = { _ in }
    ) {
        self.displayMode = displayMode
        self.showsControls = showsControls
        self.allowsOrbitInteraction = allowsOrbitInteraction
        self.isActive = isActive
        self.onPhaseChange = onPhaseChange

        self.externalColorMode = nil
        self.externalMinimumConfidence = nil
        self.externalMaxDepth = nil

        _internalColorMode = State(initialValue: colorMode)
        _internalMinimumConfidence = State(initialValue: minimumConfidence)
        _internalMaxDepth = State(initialValue: Self.clampedDepth(maxDepth))
    }

    /// Creates a point-cloud view whose controls are owned by the host.
    ///
    /// This is useful when the point cloud is part of a larger scanning
    /// interface with its own control deck.
    public init(
        displayMode: DisplayMode = .live,
        colorMode: Binding<PointCloudColorMode>,
        minimumConfidence: Binding<PointCloudConfidenceFloor>,
        maxDepth: Binding<Float>,
        showsControls: Bool = false,
        allowsOrbitInteraction: Bool = false,
        isActive: Bool = true,
        onPhaseChange: @escaping (LiDARPointCloudPhase) -> Void = { _ in }
    ) {
        self.displayMode = displayMode
        self.showsControls = showsControls
        self.allowsOrbitInteraction = allowsOrbitInteraction
        self.isActive = isActive
        self.onPhaseChange = onPhaseChange

        self.externalColorMode = colorMode
        self.externalMinimumConfidence = minimumConfidence
        self.externalMaxDepth = maxDepth

        _internalColorMode = State(initialValue: colorMode.wrappedValue)
        _internalMinimumConfidence = State(initialValue: minimumConfidence.wrappedValue)
        _internalMaxDepth = State(initialValue: Self.clampedDepth(maxDepth.wrappedValue))
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            pointCloud

            sessionOverlay

            if showsControls {
                controls
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: currentPhase, initial: true) { _, phase in
            onPhaseChange(phase)
        }
        .task(id: cameraTaskKey) {
            await requestCameraAccessIfNeeded()
        }
    }

    // MARK: - Rendering

    private var pointCloud: some View {
        PointCloudMetalView(
            source: source,
            maxDepth: maxDepth.wrappedValue,
            colorMode: colorMode.wrappedValue,
            minimumConfidence: minimumConfidence.wrappedValue,
            reduceMotion: reduceMotion,
            isActive: captureIsActive,
            allowsOrbitInteraction: allowsOrbitInteraction,
            onSessionStatusChange: { status in
                sessionStatus = status
            }
        )
    }

    @ViewBuilder
    private var controls: some View {
        if isLive {
            DefaultPointCloudControls(
                colorMode: colorMode,
                minimumConfidence: minimumConfidence,
                maxDepth: maxDepth
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        } else if let fallbackReason {
            PointCloudFallbackNotice(
                message: fallbackReason,
                showsOrbitHint: allowsOrbitInteraction
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var sessionOverlay: some View {
        if captureIsActive,
           isLive,
           let message = sessionStatus.message {
            if sessionStatus.isPreparing {
                PointCloudPreparingOverlay(message: message)
            } else {
                PointCloudStatusBanner(message: message)
            }
        }
    }

    // MARK: - State

    private var isLive: Bool {
        displayMode == .live
        && Self.isLiDARAvailable
        && cameraState == .granted
    }

    private var source: PointCloudSource {
        isLive ? .live : .demo
    }

    private var captureIsActive: Bool {
        isActive && scenePhase == .active
    }

    private var currentPhase: LiDARPointCloudPhase {
        Self.phase(
            isActive: captureIsActive,
            fallbackReason: fallbackReason,
            status: sessionStatus
        )
    }

    private var cameraTaskKey: CameraTaskKey {
        CameraTaskKey(
            mode: displayMode,
            phase: scenePhase,
            isActive: isActive
        )
    }

    private var fallbackReason: String? {
        guard displayMode == .live, !isLive else {
            return nil
        }

        guard Self.isLiDARAvailable else {
            return "No LiDAR scanner. Showing the demo cloud."
        }

        switch cameraState {
        case .usageDescriptionMissing:
            return "Add NSCameraUsageDescription to enable live depth."

        case .denied:
            return "Camera access is off — enable it in Settings for live depth."

        case .notDetermined:
            return "Waiting for camera permission…"

        case .granted:
            return nil
        }
    }

    // MARK: - Camera Access

    private func requestCameraAccessIfNeeded() async {
        guard displayMode == .live,
              isActive,
              scenePhase == .active else {
            return
        }

        let requestedState = await CameraAccess.request()

        guard !Task.isCancelled else {
            return
        }

        cameraState = requestedState
    }

    // MARK: - Phase Mapping

    static func phase(
        isActive: Bool,
        fallbackReason: String?,
        status: PointCloudSessionMonitor.Status
    ) -> LiDARPointCloudPhase {
        guard isActive else {
            return .idle
        }

        if let fallbackReason {
            return .fallback(fallbackReason)
        }

        switch status {
        case .tracking:
            return .tracking

        case .preparing(let message):
            return .preparing(message)

        case .limited(let message):
            return .limited(message)

        case .interrupted:
            return .interrupted

        case .failed(let message):
            return .failed(message)
        }
    }

    // MARK: - Depth

    private static func clampedDepth(_ value: Float) -> Float {
        min(max(value, depthRange.lowerBound), depthRange.upperBound)
    }
}

#Preview("Point cloud — demo") {
    LiDARPointCloudView(
        displayMode: .demo,
        allowsOrbitInteraction: true
    )
    .preferredColorScheme(.dark)
}

#Preview("Point cloud — live device") {
    LiDARPointCloudView(
        displayMode: .live,
        colorMode: .camera
    )
    .preferredColorScheme(.dark)
}
