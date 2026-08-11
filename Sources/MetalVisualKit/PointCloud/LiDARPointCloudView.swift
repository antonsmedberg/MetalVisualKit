//
//  LiDARPointCloudView.swift
//  MetalVisualKit
//
//  SwiftUI layer for the point cloud renderer.
//

import ARKit
import MetalKit
import SwiftUI
import UIKit

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - UIViewRepresentable bridge

struct PointCloudMetalView: UIViewRepresentable {
    /// Clamped by the caller before it reaches the renderer.
    static let depthRange: ClosedRange<Float> = 0.5...5

    var source: PointCloudSource
    var maxDepth: Float
    var reduceMotion: Bool
    var isActive: Bool

    static func shouldRenderContinuously(
        source: PointCloudSource,
        isActive: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isActive && !(source == .demo && reduceMotion)
    }

    final class Coordinator: NSObject {
        var renderer: PointCloudRenderer?

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed,
                  let view = gesture.view as? MTKView
            else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            renderer?.updateDemoOrbit(
                translation: SIMD2(Float(delta.x), Float(delta.y))
            )
            if view.isPaused {
                view.setNeedsDisplay()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.addGestureRecognizer(
            UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        )
        attachRenderer(to: view, coordinator: context.coordinator)
        return view
    }

    private func configureDrawingMode(_ view: MTKView, source: PointCloudSource) {
        let continuous = Self.shouldRenderContinuously(
            source: source,
            isActive: isActive,
            reduceMotion: reduceMotion
        )
        view.enableSetNeedsDisplay = !continuous
        view.isPaused = !continuous
        view.gestureRecognizers?.forEach { $0.isEnabled = source == .demo }
        if isActive && !continuous {
            view.setNeedsDisplay()
        }
    }

    /// Builds a renderer for the current source and attaches it, tearing down
    /// any previous one first.
    private func attachRenderer(to view: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.setActive(false)
        view.delegate = nil
        coordinator.renderer = nil
        do {
            let renderer = try PointCloudRenderer(view: view, source: source)
            // Apply lifecycle state before the delegate is attached, so no
            // frame is drawn — and no AR session started — for a scene that is
            // not active yet.
            renderer.maxDepth = maxDepth.clamped(to: PointCloudMetalView.depthRange)
            renderer.motionScale = reduceMotion ? 0 : 1
            renderer.setActive(isActive)
            view.delegate = renderer
            coordinator.renderer = renderer
            configureDrawingMode(view, source: renderer.source)
        } catch {
            MetalVisualLog.renderer.error(
                "PointCloudRenderer failed to initialise: \(String(describing: error), privacy: .public)"
            )
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // SwiftUI reuses the same MTKView across updates and does not call
        // makeUIView again, but `source` is fixed at renderer construction. When
        // camera permission is granted or revoked the resolved source flips, so
        // the renderer has to be rebuilt or the view stays stuck on the old one
        // — demo forever after permission is granted, or a live session running
        // after it is revoked.
        if context.coordinator.renderer?.source != source {
            attachRenderer(to: uiView, coordinator: context.coordinator)
            return
        }

        let renderer = context.coordinator.renderer
        renderer?.maxDepth = maxDepth.clamped(to: PointCloudMetalView.depthRange)
        renderer?.motionScale = reduceMotion ? 0 : 1
        if let orientation = uiView.window?.windowScene?.interfaceOrientation {
            renderer?.interfaceOrientation = orientation
        }

        // Releasing the camera when the scene leaves the foreground is not
        // optional for an ARSession — it keeps running otherwise. setActive is
        // idempotent, so this does nothing on an ordinary state change.
        renderer?.setActive(isActive)
        configureDrawingMode(uiView, source: renderer?.source ?? source)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.pause()
        uiView.isPaused = true
        uiView.delegate = nil
    }
}

// MARK: - Public component

struct CameraTaskKey: Equatable {
    let mode: LiDARPointCloudView.DisplayMode
    let phase: ScenePhase
}

/// A live 3D visualisation of the LiDAR depth map.
///
/// Every point is unprojected on the GPU: the ARKit depth map is bound as a
/// texture to the vertex shader, so roughly 49,000 points are placed in world
/// space without any per-point CPU work.
///
/// ```swift
/// LiDARPointCloudView(displayMode: .live)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var maxDepth: Float = 5

    /// LiDAR on iPhone and iPad resolves reliably to roughly five metres. A
    /// 1-10 m slider let the colormap normalise against a range the sensor
    /// never fills, washing out the near field for no benefit.
    @State private var cameraState: CameraAccess.State = CameraAccess.current

    /// - Parameters:
    ///   - displayMode: Source to draw from. Defaults to ``DisplayMode/live``.
    ///   - showsControls: Whether to overlay the depth-range slider.
    public init(displayMode: DisplayMode = .live, showsControls: Bool = true) {
        self.displayMode = displayMode
        self.showsControls = showsControls
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
                reduceMotion: reduceMotion,
                isActive: scenePhase == .active
            )

            if showsControls {
                controls
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(isLive ? "Live depth point cloud" : "Demo point cloud"))
        .task(id: CameraTaskKey(mode: displayMode, phase: scenePhase)) {
            // Re-checked on every foreground: the user may have changed the
            // setting in Settings and come back.
            guard displayMode == .live, scenePhase == .active else { return }
            let requestedState = await CameraAccess.request()
            guard !Task.isCancelled else { return }
            cameraState = requestedState
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let fallbackReason {
                VStack(spacing: 5) {
                    Label(fallbackReason, systemImage: "info.circle")
                    Label("Drag to orbit", systemImage: "hand.draw")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            }

            if isLive {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.and.right")
                    Slider(value: $maxDepth, in: PointCloudMetalView.depthRange)
                        .accessibilityLabel(Text("Maximum scan depth"))
                        .accessibilityValue(Text(String(format: "%.1f metres", maxDepth)))
                    Text(String(format: "%.1f m", maxDepth))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
                .tint(.cyan)
                .foregroundStyle(.white)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - Previews

#Preview("Point cloud — demo source") {
    LiDARPointCloudView(displayMode: .demo)
        .preferredColorScheme(.dark)
}

#Preview("Point cloud — live (device only)") {
    LiDARPointCloudView(displayMode: .live)
        .preferredColorScheme(.dark)
}
