//
//  ParticleProgressView.swift
//  MetalVisualKit
//
//  SwiftUI layer for the GPU particle loader.
//

import MetalKit
import SwiftUI
import UIKit

// MARK: - Touch-aware MTKView

/// Reports touches in *drawable* pixels, which is the space the shader works in.
final class TouchMTKView: MTKView {
    var onTouch: ((CGPoint?) -> Void)?

    private func report(_ touches: Set<UITouch>) {
        guard let touch = touches.first, bounds.width > 0, bounds.height > 0 else { return }
        let point = touch.location(in: self)
        // Derive the scale from the drawable rather than contentScaleFactor:
        // the two axes can differ, and the shader works in drawable pixels.
        let scaleX = drawableSize.width / bounds.width
        let scaleY = drawableSize.height / bounds.height
        onTouch?(CGPoint(x: point.x * scaleX, y: point.y * scaleY))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onTouch?(nil) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onTouch?(nil) }
}

// MARK: - UIViewRepresentable bridge

struct ParticleLoaderMetalView: UIViewRepresentable {
    var progress: Double
    var reduceMotion: Bool
    var isInteractive: Bool
    var isActive: Bool

    final class Coordinator {
        var renderer: ParticleLoaderRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TouchMTKView {
        let view = TouchMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isUserInteractionEnabled = isInteractive
        do {
            let renderer = try ParticleLoaderRenderer(view: view)
            // Install configuration before the first draw, so frame one already
            // reflects the caller's values rather than flashing the defaults.
            renderer.progress = Float(progress)
            renderer.motionScale = reduceMotion ? 0 : 1
            renderer.setActive(isActive)
            view.isPaused = !isActive
            view.delegate = renderer
            view.onTouch = { [weak renderer] point in renderer?.touch = point }
            context.coordinator.renderer = renderer
        } catch {
            MetalVisualLog.renderer.error(
                "ParticleLoaderRenderer failed to initialise: \(String(describing: error), privacy: .public)"
            )
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
        return view
    }

    func updateUIView(_ uiView: TouchMTKView, context: Context) {
        let renderer = context.coordinator.renderer
        renderer?.progress = Float(progress)
        renderer?.motionScale = reduceMotion ? 0 : 1
        renderer?.setActive(isActive)
        uiView.isUserInteractionEnabled = isInteractive
        uiView.isPaused = !isActive
    }

    static func dismantleUIView(_ uiView: TouchMTKView, coordinator: Coordinator) {
        uiView.isPaused = true
        uiView.delegate = nil
        uiView.onTouch = nil
    }
}

// MARK: - Determinate progress

/// A determinate progress indicator drawn as a GPU particle ring.
///
/// The ring fills as `progress` moves from `0` to `1`, particles drift on curl
/// noise, dragging across the view repels them, and completion triggers a burst.
///
/// ```swift
/// ParticleProgressView(progress: $exportProgress, title: "Exporting")
///     .frame(width: 320, height: 320)
/// ```
///
/// When *Reduce Motion* is enabled the particle drift and burst are suppressed
/// and the ring settles into a static fill.
public struct ParticleProgressView: View {

    private let progress: Double
    private let title: String
    private let isInteractive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameters:
    ///   - progress: Completion in `0...1`. Values outside the range, and NaN,
    ///     are clamped.
    ///   - title: Caption shown beneath the percentage.
    ///   - isInteractive: Whether dragging scatters the particles. Pass `false`
    ///     when the loader sits above controls that need the touches.
    public init(progress: Double, title: String = "Loading", isInteractive: Bool = true) {
        self.progress = progress
        self.title = title
        self.isInteractive = isInteractive
    }

    /// Convenience for call sites that already hold a `Binding`. The view only
    /// reads the value; it never writes back.
    public init(
        progress: Binding<Double>,
        title: String = "Loading",
        isInteractive: Bool = true
    ) {
        self.init(progress: progress.wrappedValue, title: title, isInteractive: isInteractive)
    }

    /// NaN would otherwise propagate into the uniform buffer and take the whole
    /// simulation with it.
    private var clamped: Double { progress.isFinite ? min(max(progress, 0), 1) : 0 }
    private var isComplete: Bool { clamped >= 1 }

    public var body: some View {
        ZStack {
            ParticleLoaderMetalView(
                progress: clamped,
                reduceMotion: reduceMotion,
                isInteractive: isInteractive,
                isActive: scenePhase == .active
            )

            VStack(spacing: 6) {
                Group {
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 40, weight: .bold))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("\(Int(clamped * 100))")
                            .font(.system(size: 46, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(.white)

                Text(isComplete ? "Done" : title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)
                    .kerning(1.5)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.45), value: isComplete)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isComplete ? "Complete" : "\(Int(clamped * 100)) percent"))
    }
}

// MARK: - Indeterminate

/// Task identity for the spinner loop. Equatable so SwiftUI restarts the task
/// whenever either input changes.
private struct SpinnerTaskKey: Equatable {
    let reduceMotion: Bool
    let phase: ScenePhase
}

/// An indeterminate variant of ``ParticleProgressView``.
///
/// The internal sweep loops continuously, so the ring repeatedly fills and
/// bursts. Use it for work whose duration is not known in advance.
public struct ParticleSpinnerView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var progress: Double = 0

    private let label: String

    /// - Parameter label: Accessibility label for the spinner.
    public init(label: String = "Loading") {
        self.label = label
    }

    public var body: some View {
        ParticleLoaderMetalView(
            progress: progress,
            reduceMotion: reduceMotion,
            // A spinner is decoration; it must not swallow touches meant for
            // whatever it is covering.
            isInteractive: false,
            isActive: scenePhase == .active
        )
            // Keyed on both inputs: a `.task` captures the view value it was
            // created with, so reading scenePhase inside a task keyed only on
            // reduceMotion would see the phase as it was at creation. Keying on
            // both restarts the task, which also removes the polling loop.
            .task(id: SpinnerTaskKey(reduceMotion: reduceMotion, phase: scenePhase)) {
                // Under Reduce Motion the shader suppresses the animation, so
                // ticking SwiftUI state 30 times a second would burn CPU to
                // produce nothing. Settle on a static half-filled ring instead.
                guard !reduceMotion else {
                    progress = 0.5
                    return
                }
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    progress = progress >= 1.25 ? 0 : progress + 0.007
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Previews

#Preview("Particle progress — animated sweep") {
    struct PreviewHost: View {
        @State private var progress: Double = 0

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                ParticleProgressView(progress: progress, title: "Exporting")
                    .frame(width: 320, height: 320)
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(40))
                    progress = progress >= 1.4 ? 0 : progress + 0.006
                }
            }
        }
    }
    return PreviewHost()
}

#Preview("Particle spinner") {
    ZStack {
        Color.black.ignoresSafeArea()
        ParticleSpinnerView()
            .frame(width: 280, height: 280)
    }
}
