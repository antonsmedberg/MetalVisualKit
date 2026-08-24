//
//  PointCloudRenderer.swift
//  MetalVisualKit
//
//  Owns the Metal render loop and AR session lifecycle for the point cloud.
//  Live-frame preparation and demo rendering are kept in separate extensions
//  so this file stays focused on the renderer itself.
//

import ARKit
import Metal
import MetalKit
import QuartzCore
import simd
import UIKit

// MARK: - Renderer

final class PointCloudRenderer: NSObject, MTKViewDelegate {
    static let defaultLivePointSize: Float = 3
    static let defaultDemoZoom: Float = 1.4

    enum Function {
        static let liveVertex = "pointCloudVertex"
        static let demoVertex = "demoCloudVertex"
        static let fragment = "cloudFragment"
    }

    /// Whether this device can provide LiDAR scene-depth frames.
    static var isLiDARAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    static func requiresTextureCache(for source: PointCloudSource) -> Bool {
        source == .live
    }

    static func frameSemantics(
        supportsCombinedDepth: Bool
    ) -> ARConfiguration.FrameSemantics {
        supportsCombinedDepth
        ? [.sceneDepth, .smoothedSceneDepth]
        : .sceneDepth
    }

    let source: PointCloudSource

    var maxDepth: Float = 5

    /// Requested colour mode. Frames without camera textures fall back to depth.
    var colorMode: PointCloudColorMode = .camera

    var minimumConfidence: PointCloudConfidenceFloor = .balanced

    /// Live sprite size in layout points at one metre.
    var livePointSize: Float = defaultLivePointSize

    var motionScale: Float = 1

    /// Updated by the SwiftUI layer so the render callback never reads UIApplication.
    var interfaceOrientation: UIInterfaceOrientation = .portrait

    /// Forwarded from the AR session monitor to the SwiftUI bridge.
    var onSessionStatusChange: ((PointCloudSessionMonitor.Status) -> Void)? {
        get { sessionMonitor.onChange }
        set { sessionMonitor.onChange = newValue }
    }

    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let textures: ARFrameTextures?

    let sessionMonitor = PointCloudSessionMonitor()

    private(set) var session: ARSession?

    var viewportSize: CGSize = .zero
    var viewportPointSize: CGSize = .zero

    let demoPointCount = 24_000
    let demoPointSize: Float = 2.2

    var lastRenderedFrameTimestamp: TimeInterval = -1
    private var isActive = false
    private var lastFrameTime = CACurrentMediaTime()

    /// Advances only while frames render, avoiding a time jump after backgrounding.
    var simulationTime: Double = 0

    var demoOrbit = DemoOrbit(
        azimuth: 0,
        elevation: atan(0.12)
    )

    var demoZoom: Float = defaultDemoZoom

    // MARK: - Initialization

    init(view: MTKView, source: PointCloudSource) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalVisualError.noMetalDevice
        }

        guard let queue = device.makeCommandQueue() else {
            throw MetalVisualError.commandQueueUnavailable
        }

        let resolvedSource = Self.resolvedSource(source)

        Self.configure(
            view,
            device: device,
            source: resolvedSource
        )

        let library = try ShaderLibrary.make(device: device)

        self.source = resolvedSource
        self.queue = queue
        self.pipeline = try Self.makePipeline(
            device: device,
            library: library,
            view: view,
            source: resolvedSource
        )
        self.depthState = try Self.makeDepthState(device: device)
        self.textures = Self.requiresTextureCache(for: resolvedSource)
        ? try ARFrameTextures(device: device)
        : nil

        super.init()

        sessionMonitor.configurationForRestart = { [weak self] in
            self?.makeConfiguration() ?? ARWorldTrackingConfiguration()
        }
    }

    deinit {
        session?.pause()
    }

    // MARK: - Metal setup

    private static func resolvedSource(
        _ source: PointCloudSource
    ) -> PointCloudSource {
        source == .live && isLiDARAvailable ? .live : .demo
    }

    private static func configure(
        _ view: MTKView,
        device: MTLDevice,
        source: PointCloudSource
    ) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = clearColor(for: source)
        view.preferredFramesPerSecond = 60
    }

    private static func clearColor(
        for source: PointCloudSource
    ) -> MTLClearColor {
        if source == .demo {
            return MTLClearColor(
                red: 0.005,
                green: 0.007,
                blue: 0.014,
                alpha: 1
            )
        }

        return MTLClearColor(
            red: 0.02,
            green: 0.02,
            blue: 0.05,
            alpha: 1
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        view: MTKView,
        source: PointCloudSource
    ) throws -> MTLRenderPipelineState {
        let vertexName = source == .live
        ? Function.liveVertex
        : Function.demoVertex

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MetalVisualKit.PointCloud"
        descriptor.vertexFunction = try ShaderLibrary.function(
            vertexName,
            in: library
        )
        descriptor.fragmentFunction = try ShaderLibrary.function(
            Function.fragment,
            in: library
        )
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        configureBlending(descriptor.colorAttachments[0])

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func configureBlending(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private static func makeDepthState(
        device: MTLDevice
    ) throws -> MTLDepthStencilState {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true

        guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
            throw MetalVisualError.depthStateUnavailable
        }

        return state
    }

    // MARK: - AR session

    func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()

        let combinedDepth: ARConfiguration.FrameSemantics = [
            .sceneDepth,
            .smoothedSceneDepth
        ]

        configuration.frameSemantics = Self.frameSemantics(
            supportsCombinedDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(
                combinedDepth
            )
        )

        // Keep ARKit's default video format. Depth and camera textures come
        // from the same frame and are sampled together by the renderer.
        return configuration
    }

    private func startSession() {
        let session = self.session ?? ARSession()

        // The monitor stays on ARKit's default delegate queue.
        session.delegate = sessionMonitor
        sessionMonitor.prepareForStart()
        session.run(makeConfiguration())

        self.session = session

        MetalVisualLog.renderer.info("ARSession started with scene depth.")
    }

    func pause() {
        setActive(false)
    }

    func updateDemoOrbit(translation: SIMD2<Float>) {
        guard source == .demo else { return }

        demoOrbit = Self.updatedDemoOrbit(
            demoOrbit,
            translation: translation
        )
    }

    func updateDemoZoom(pinchScale: Float) {
        guard source == .demo else { return }

        demoZoom = Self.updatedDemoZoom(
            demoZoom,
            pinchScale: pinchScale
        )
    }

    /// Starts or pauses live capture only when the requested activity changes.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }

        isActive = active

        guard source == .live else { return }

        if active {
            startSession()

            // Do not reject the first frame back as one we rendered earlier.
            lastRenderedFrameTimestamp = -1
            lastFrameTime = CACurrentMediaTime()
        } else {
            session?.pause()
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
        viewportSize = size

        // Rotation can resize the drawable before SwiftUI updates the bridge.
        if let scene = view.window?.windowScene {
            interfaceOrientation = scene.interfaceOrientation
        }
    }

    func draw(in view: MTKView) {
        viewportSize = view.drawableSize
        viewportPointSize = view.bounds.size

        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return
        }

        updateSimulationTime()

        var liveFrame: PointCloudLiveFrame?

        if source == .live {
            guard let preparedFrame = prepareSignpostedLiveFrame() else {
                return
            }

            liveFrame = preparedFrame
        }

        guard
            let drawable = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: passDescriptor
            )
        else {
            return
        }

        encodeFrame(
            encoder: encoder,
            commandBuffer: commandBuffer,
            liveFrame: liveFrame
        )

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if let liveFrame {
            lastRenderedFrameTimestamp = liveFrame.timestamp
        }
    }

    private func updateSimulationTime() {
        let now = CACurrentMediaTime()
        simulationTime += min(now - lastFrameTime, 1.0 / 30.0)
        lastFrameTime = now
    }

    private func encodeFrame(
        encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        liveFrame: PointCloudLiveFrame?
    ) {
        encoder.label = "Point cloud"
        encoder.setDepthStencilState(depthState)
        encoder.setRenderPipelineState(pipeline)

        if let liveFrame {
            encodeLive(
                encoder: encoder,
                frame: liveFrame
            )

            let retainedTextures = liveFrame.retainedTextures

            commandBuffer.addCompletedHandler { _ in
                withExtendedLifetime(retainedTextures) {}
            }
        } else {
            encodeDemo(
                encoder: encoder,
                time: Float(simulationTime)
            )
        }
    }
}
