//
//  PointCloudRenderer.swift
//  MetalVisualKit
//
//  Owns the point-cloud render loop and AR session lifecycle.
//  Metal setup, live-frame preparation and demo encoding live in extensions.
//

import ARKit
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import UIKit
import simd

// MARK: - GPU Resource Lifetime

/// Keeps Core Video texture wrappers alive until Metal has finished consuming
/// textures backed by them.
///
/// The references are immutable after initialization. The command-buffer
/// completion handler only extends their lifetime and never reads or mutates
/// the underlying image data.
private final class RetainedCVMetalTextures: @unchecked Sendable {
    private let textures: [CVMetalTexture]

    init(_ textures: [CVMetalTexture]) { self.textures = textures }

    func keepAlive() { withExtendedLifetime(textures) {} }
}

// MARK: - Renderer

@MainActor final class PointCloudRenderer: NSObject, MTKViewDelegate {

    // MARK: - Constants

    nonisolated static let defaultLivePointSize: Float = 3
    nonisolated static let defaultDemoZoom: Float = 1.4

    enum Function {
        static let liveVertex = "pointCloudVertex"
        static let demoVertex = "demoCloudVertex"
        static let fragment = "cloudFragment"
    }

    // MARK: - Capabilities

    nonisolated static var isLiDARAvailable: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    nonisolated static func requiresTextureCache(for source: PointCloudSource) -> Bool { source == .live }

    nonisolated static func frameSemantics(supportsCombinedDepth: Bool) -> ARConfiguration.FrameSemantics {
        supportsCombinedDepth ? [.sceneDepth, .smoothedSceneDepth] : .sceneDepth
    }

    /// Determines whether a renderer is allowed to encode a frame.
    ///
    /// Live rendering is tied to active capture. The procedural demo remains
    /// drawable while inactive so previews and showcase heroes can render an
    /// on-demand frame without starting an AR session.
    nonisolated static func shouldDraw(source: PointCloudSource, isActive: Bool) -> Bool { source == .demo || isActive }

    // MARK: - Configuration

    let source: PointCloudSource

    var maxDepth: Float = 5

    var colorMode: PointCloudColorMode = .camera

    var minimumConfidence: PointCloudConfidenceFloor = .balanced

    /// Live point-sprite diameter expressed in UIKit layout points at one metre.
    var livePointSize: Float = defaultLivePointSize

    /// 1 during normal animation and 0 when Reduce Motion is enabled.
    var motionScale: Float = 1

    /// Updated by the SwiftUI bridge so rendering never needs to query
    /// UIApplication directly.
    var interfaceOrientation: UIInterfaceOrientation = .portrait

    var onSessionStatusChange: ((PointCloudSessionMonitor.Status) -> Void)? {
        get { sessionMonitor.onChange }
        set { sessionMonitor.onChange = newValue }
    }

    // MARK: - Metal State

    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let textures: ARFrameTextures?

    // MARK: - AR Session

    let sessionMonitor = PointCloudSessionMonitor()

    private(set) var session: ARSession?

    // MARK: - Viewport

    var viewportSize: CGSize = .zero
    var viewportPointSize: CGSize = .zero

    // MARK: - Demo

    /// The demo remains deliberately lightweight enough for previews and the
    /// simulator while still producing a dense spatial point cloud.
    let demoPointCount = 24_000

    let demoPointSize: Float = 2.2

    var demoOrbit = DemoOrbit(azimuth: 0, elevation: atan(0.12))

    var demoZoom: Float = defaultDemoZoom

    // MARK: - Frame State

    var lastRenderedFrameTimestamp: TimeInterval = -1
    var simulationTime: Double = 0

    private var isActive = false
    private var lastFrameTime = CACurrentMediaTime()

    // MARK: - Initialization

    init(view: MTKView, source: PointCloudSource) throws {
        let device = try Self.resolveDevice(for: view)

        let resolvedSource = Self.resolvedSource(source)

        Self.configure(view, device: device, source: resolvedSource)

        guard let queue = device.makeCommandQueue() else { throw MetalVisualError.commandQueueUnavailable }

        let library = try ShaderLibrary.make(device: device)

        let pipeline = try Self.makePipeline(
            device: device, library: library, colorPixelFormat: view.colorPixelFormat,
            depthStencilPixelFormat: view.depthStencilPixelFormat, source: resolvedSource)

        let depthState = try Self.makeDepthState(device: device)

        let textures: ARFrameTextures?

        if Self.requiresTextureCache(for: resolvedSource) {
            textures = try ARFrameTextures(device: device)
        } else {
            textures = nil
        }

        self.source = resolvedSource
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        self.textures = textures

        super.init()

        sessionMonitor.configurationForRestart = { [weak self] in
            guard let self else { return ARWorldTrackingConfiguration() }

            return self.makeConfiguration()
        }
    }

    // MARK: - AR Session

    func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()

        let combinedDepth: ARConfiguration.FrameSemantics = [.sceneDepth, .smoothedSceneDepth]

        let supportsCombinedDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(combinedDepth)

        configuration.frameSemantics = Self.frameSemantics(supportsCombinedDepth: supportsCombinedDepth)

        return configuration
    }

    private func startSession() {
        guard source == .live else { return }

        let activeSession: ARSession

        if let session {
            activeSession = session
        } else {
            let newSession = ARSession()

            // PointCloudSessionMonitor is MainActor-isolated. Explicitly
            // deliver ARSessionDelegate callbacks on the main queue so the
            // runtime contract matches the Swift concurrency model.
            newSession.delegateQueue = .main
            newSession.delegate = sessionMonitor

            session = newSession
            activeSession = newSession
        }

        sessionMonitor.prepareForStart()

        activeSession.run(makeConfiguration())

        MetalVisualLog.renderer.info("ARSession started with scene depth.")
    }

    // MARK: - Lifecycle

    func setActive(_ active: Bool) {
        guard active != isActive else { return }

        isActive = active

        // Demo rendering has no camera or AR lifecycle. Active demo views may
        // animate continuously; inactive demo views are still allowed to draw
        // static/on-demand frames.
        if source == .demo {
            if active { resetFrameClock() }

            return
        }

        if active {
            lastRenderedFrameTimestamp = -1
            resetFrameClock()
            startSession()
        } else {
            session?.pause()
        }
    }

    func pause() { setActive(false) }

    /// Final teardown for a renderer that will not be attached again.
    func shutdown() {
        isActive = false

        session?.pause()
        session?.delegate = nil
        session = nil

        sessionMonitor.onChange = nil
        sessionMonitor.configurationForRestart = nil

        lastRenderedFrameTimestamp = -1
    }

    // MARK: - Demo Interaction

    func updateDemoOrbit(translation: SIMD2<Float>) {
        guard source == .demo else { return }

        demoOrbit = Self.updatedDemoOrbit(demoOrbit, translation: translation)
    }

    func updateDemoZoom(pinchScale: Float) {
        guard source == .demo else { return }

        demoZoom = Self.updatedDemoZoom(demoZoom, pinchScale: pinchScale)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size

        if let scene = view.window?.windowScene { interfaceOrientation = scene.interfaceOrientation }
    }

    func draw(in view: MTKView) {
        guard Self.shouldDraw(source: source, isActive: isActive) else { return }

        viewportSize = view.drawableSize
        viewportPointSize = view.bounds.size

        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        // An inactive demo should remain visually stable. Orbit and zoom may
        // request new frames, but those frames should not advance procedural
        // animation merely because the user changed the camera.
        if isActive { updateSimulationTime() }

        let liveFrame: PointCloudLiveFrame?

        if source == .live {
            guard let preparedFrame = prepareSignpostedLiveFrame() else { return }

            liveFrame = preparedFrame
        } else {
            liveFrame = nil
        }

        encodeAndPresent(in: view, liveFrame: liveFrame)
    }

    // MARK: - Frame Timing

    private func resetFrameClock() { lastFrameTime = CACurrentMediaTime() }

    private func updateSimulationTime() {
        let now = CACurrentMediaTime()

        let delta = min(max(now - lastFrameTime, 0), 1.0 / 30.0)

        lastFrameTime = now
        simulationTime += delta
    }

    // MARK: - Frame Encoding

    private func encodeAndPresent(in view: MTKView, liveFrame: PointCloudLiveFrame?) {
        guard let passDescriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encodeFrame(encoder: encoder, commandBuffer: commandBuffer, liveFrame: liveFrame)

        encoder.endEncoding()

        commandBuffer.present(drawable)

        commandBuffer.commit()

        if let liveFrame { lastRenderedFrameTimestamp = liveFrame.timestamp }
    }

    private func encodeFrame(
        encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer, liveFrame: PointCloudLiveFrame?
    ) {
        encoder.label = "Point cloud"

        encoder.setDepthStencilState(depthState)

        encoder.setRenderPipelineState(pipeline)

        if let liveFrame {
            encodeLive(encoder: encoder, frame: liveFrame)

            retainTextures(liveFrame.retainedTextures, untilCompletedBy: commandBuffer)
        } else {
            encodeDemo(encoder: encoder, time: Float(simulationTime))
        }
    }

    private func retainTextures(_ textures: [CVMetalTexture], untilCompletedBy commandBuffer: MTLCommandBuffer) {
        guard !textures.isEmpty else { return }

        let retainedTextures = RetainedCVMetalTextures(textures)

        commandBuffer.addCompletedHandler { _ in retainedTextures.keepAlive() }
    }
}
