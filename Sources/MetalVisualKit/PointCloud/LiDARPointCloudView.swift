//
//  LiDARPointCloudView.swift
//  MetalVisualKit
//
//  The public component: camera permission, colour mode, depth range, session
//  status. Rendering is in PointCloudRenderer, the UIKit bridge in
//  PointCloudMetalView.
//

import ARKit
import SwiftUI

/// Identity for the permission task, so it restarts when either input changes.
struct CameraTaskKey: Equatable {
    let mode: LiDARPointCloudView.DisplayMode
    let phase: ScenePhase
}

/// A live 3D visualisation of the LiDAR depth map.
///
/// Every point is unprojected on the GPU: the ARKit depth map is bound as a
/// texture to the vertex shader, so roughly 49,000 points are placed in world
/// space without any per-point CPU work. In the default
/// ``PointCloudColorMode/camera`` mode each point also samples the camera image
/// from the same frame, so the cloud shows the room in its own colours rather
/// than a false-colour gradient.
///
/// ```swift
/// LiDARPointCloudView(displayMode: .live, colorMode: .camera)
/// ```
///
/// On hardware without a LiDAR scanner — and in the simulator and in previews —
/// the view falls back to a procedural cloud so it always renders something.
///
/// The host app must declare `NSCameraUsageDescription` for live mode. Without
/// it, or without camera permission, the view falls back to the demo cloud and
/// explains why rather than showing an empty surface.
///
/// The view does not apply `.ignoresSafeArea()` itself — that is the host's
/// decision. Add it at the call site for a full-bleed presentation.
public struct LiDARPointCloudView: View {

    /// Which source the view should draw from.
    public enum DisplayMode: Equatable, Sendable {
        /// Live LiDAR depth, falling back to ``demo`` when unavailable.
        case live
        /// Procedural cloud. Always available.
        case demo
    }

    /// Whether this device can deliver LiDAR depth frames.
    public static var isLiDARAvailable: Bool { PointCloudRenderer.isLiDARAvailable }

    private let displayMode: DisplayMode
    private let showsControls: Bool
    private let allowsOrbitInteraction: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// LiDAR on iPhone and iPad resolves reliably to roughly five metres. A
    /// 1-10 m slider let the colormap normalise against a range the sensor
    /// never fills, washing out the near field for no benefit.
    @State private var maxDepth: Float = 5
    @State private var colorMode: PointCloudColorMode
    @State private var cameraState: CameraAccess.State = CameraAccess.current
    @State private var sessionStatus: PointCloudSessionMonitor.Status = .starting

    /// - Parameters:
    ///   - displayMode: Source to draw from. Defaults to ``DisplayMode/live``.
    ///   - colorMode: Initial colouring. Defaults to
    ///     ``PointCloudColorMode/camera``; the controls can change it afterwards.
    ///   - showsControls: Whether to overlay the colour picker and depth slider.
    ///   - allowsOrbitInteraction: Whether the procedural cloud accepts pan and
    ///     VoiceOver rotation actions. Defaults to `false` so fallback does not
    ///     compete with gestures owned by a host view.
    public init(
        displayMode: DisplayMode = .live,
        colorMode: PointCloudColorMode = .camera,
        showsControls: Bool = true,
        allowsOrbitInteraction: Bool = false
    ) {
        self.displayMode = displayMode
        self.showsControls = showsControls
        self.allowsOrbitInteraction = allowsOrbitInteraction
        _colorMode = State(initialValue: colorMode)
    }

    private var isLive: Bool {
        // Authorization is re-read rather than trusted from state, so a
        // permission revoked in Settings cannot briefly restart the session.
        displayMode == .live && Self.isLiDARAvailable && CameraAccess.current == .granted
    }

    private var fallbackReason: String? {
        guard displayMode == .live, !isLive else { return nil }
        if !Self.isLiDARAvailable {
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

    private var source: PointCloudSource {
        isLive ? .live : .demo
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            PointCloudMetalView(
                source: source,
                maxDepth: maxDepth,
                colorMode: colorMode,
                reduceMotion: reduceMotion,
                isActive: scenePhase == .active,
                allowsOrbitInteraction: allowsOrbitInteraction,
                onSessionStatusChange: { sessionStatus = $0 }
            )

            if isLive, let message = sessionStatus.message {
                statusBanner(message)
            }

            if showsControls {
                controls
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: CameraTaskKey(mode: displayMode, phase: scenePhase)) {
            // Re-checked on every foreground: the user may have changed the
            // setting in Settings and come back.
            guard displayMode == .live, scenePhase == .active else { return }
            let requestedState = await CameraAccess.request()
            guard !Task.isCancelled else { return }
            cameraState = requestedState
        }
    }

    // MARK: - Overlays

    private func statusBanner(_ message: String) -> some View {
        VStack {
            Label(message, systemImage: "viewfinder")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .controlSurface(cornerRadius: 16)
                .padding(.top, 12)
                .transition(.opacity)
            Spacer()
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 12) {
            if let fallbackReason {
                VStack(spacing: 5) {
                    Label(fallbackReason, systemImage: "info.circle")
                    if allowsOrbitInteraction {
                        Label("Drag to orbit", systemImage: "hand.draw")
                            .accessibilityHidden(true)
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            }

            if isLive {
                Picker("Point colour", selection: $colorMode) {
                    ForEach(PointCloudColorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Point colour source"))

                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.and.right")
                        .accessibilityHidden(true)
                    Slider(value: $maxDepth, in: PointCloudMetalView.depthRange)
                        .accessibilityLabel(Text("Maximum scan depth"))
                        .accessibilityValue(Text(String(format: "%.1f metres", maxDepth)))
                    Text(String(format: "%.1f m", maxDepth))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .tint(.cyan)
                .foregroundStyle(.white)
            }
        }
        .padding(14)
        .controlSurface(cornerRadius: 22)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

private extension View {
    @ViewBuilder
    func controlSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

#Preview("Point cloud — demo source") {
    LiDARPointCloudView(displayMode: .demo)
        .preferredColorScheme(.dark)
}

#Preview("Point cloud — live device") {
    LiDARPointCloudView(displayMode: .live, colorMode: .camera)
        .preferredColorScheme(.dark)
}
