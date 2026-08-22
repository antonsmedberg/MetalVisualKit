//
//  PointCloudRenderer.swift
//  MetalVisualKit
//
//  Live mode samples ARKit's sceneDepth map inside the vertex shader, unprojects
//  to world space on the GPU, and colours each point from the camera image of
//  the same frame. Demo mode draws a procedural cloud so the component still
//  shows something in previews and on non-LiDAR hardware.
//
//  Texture conversion lives in ARFrameTextures, session state in
//  PointCloudSessionMonitor. What stays here is the draw loop.
//

import ARKit
import CoreVideo
import Metal
import MetalKit
import UIKit
import QuartzCore
import simd

// MARK: - Renderer

final class PointCloudRenderer: NSObject, MTKViewDelegate {

    static let defaultLivePointSize: Float = 3

    enum Function {
        static let liveVertex = "pointCloudVertex"
        static let demoVertex = "demoCloudVertex"
        static let fragment = "cloudFragment"
    }

    /// Whether this device can deliver LiDAR depth frames.
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
    /// Requested colouring. Falls back to ``PointCloudColorMode/depth`` for any
    /// frame whose camera image cannot be bound.
    var colorMode: PointCloudColorMode = .camera
    var minimumConfidence: PointCloudConfidenceFloor = .balanced
    /// Live sprite size in layout points at one metre. More distant samples
    /// shrink with perspective in the vertex shader.
    var livePointSize: Float = defaultLivePointSize
    var motionScale: Float = 1
    /// Pushed in from the SwiftUI layer, which reads it on the main actor.
    /// The renderer must not touch `UIApplication` from the draw callback.
    var interfaceOrientation: UIInterfaceOrientation = .portrait
    /// Forwarded from the session monitor. Set by the SwiftUI bridge.
    var onSessionStatusChange: ((PointCloudSessionMonitor.Status) -> Void)? {
        get { sessionMonitor.onChange }
        set { sessionMonitor.onChange = newValue }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let textures: ARFrameTextures?
    private let sessionMonitor = PointCloudSessionMonitor()

    private(set) var session: ARSession?
    private var viewportSize: CGSize = .zero
    private var viewportPointSize: CGSize = .zero
    private let demoPointCount = 24_000
    private let demoPointSize: Float = 2.6
    private var lastRenderedFrameTimestamp: TimeInterval = -1
    private var isActive = false
    private var lastFrameTime = CACurrentMediaTime()
    /// Advanced by rendered frame deltas, not wall clock, so time does not jump
    /// by the length of a backgrounded interval on the first frame back.
    private var simulationTime: Double = 0
    private var demoOrbit = DemoOrbit(azimuth: 0, elevation: atan(0.12))
    private var demoZoom: Float = 1

    init(view: MTKView, source: PointCloudSource) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalVisualError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MetalVisualError.commandQueueUnavailable
        }

        // Fall back to demo if live was requested on hardware that cannot serve it.
        let resolved: PointCloudSource = (source == .live && Self.isLiDARAvailable) ? .live : .demo

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)
        view.preferredFramesPerSecond = 60

        let library = try ShaderLibrary.make(device: device)
        let vertexName = resolved == .live ? Function.liveVertex : Function.demoVertex

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MetalVisualKit.PointCloud"
        descriptor.vertexFunction = try ShaderLibrary.function(vertexName, in: library)
        descriptor.fragmentFunction = try ShaderLibrary.function(Function.fragment, in: library)
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw MetalVisualError.depthStateUnavailable
        }

        self.source = resolved
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.depthState = depthState
        self.textures = Self.requiresTextureCache(for: resolved)
            ? try ARFrameTextures(device: device)
            : nil

        super.init()

        sessionMonitor.configurationForRestart = { [weak self] in
            self?.makeConfiguration() ?? ARWorldTrackingConfiguration()
        }
        // setActive(true) starts the camera only when the view is active.
    }

    deinit {
        session?.pause()
    }

    // MARK: - AR session

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        let combinedDepth: ARConfiguration.FrameSemantics = [
            .sceneDepth,
            .smoothedSceneDepth
        ]
        configuration.frameSemantics = Self.frameSemantics(
            supportsCombinedDepth:
            ARWorldTrackingConfiguration.supportsFrameSemantics(combinedDepth)
        )
        // Left at ARKit's default video format on purpose. Depth and camera
        // textures are sampled against one another by this renderer.
        return configuration
    }

    private func startSession() {
        let session = self.session ?? ARSession()
        // delegateQueue stays nil, so ARKit calls the monitor on the main queue.
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
        demoOrbit = Self.updatedDemoOrbit(demoOrbit, translation: translation)
    }

    func updateDemoZoom(pinchScale: Float) {
        guard source == .demo else { return }
        demoZoom = Self.updatedDemoZoom(demoZoom, pinchScale: pinchScale)
    }

    /// Starts or pauses live capture only when activity changes.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard source == .live else { return }
        if active {
            startSession()
            // Drop the frame consumed before backgrounding so the first frame
            // back is not rejected as a duplicate.
            lastRenderedFrameTimestamp = -1
            lastFrameTime = CACurrentMediaTime()
        } else {
            session?.pause()
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size
        // A rotation can change the drawable without SwiftUI re-running
        // updateUIView, so the projection would otherwise use a stale orientation.
        if let scene = view.window?.windowScene {
            interfaceOrientation = scene.interfaceOrientation
        }
    }

    func draw(in view: MTKView) {
        // During a rotation the drawable can change before bounds settle. Read
        // both here so ARKit projection never uses a viewport one frame stale.
        viewportSize = view.drawableSize
        viewportPointSize = view.bounds.size

        // Nothing useful can be encoded into a zero-sized drawable, and SwiftUI
        // produces those routinely during transitions and navigation.
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        let now = CACurrentMediaTime()
        simulationTime += min(now - lastFrameTime, 1.0 / 30.0)
        lastFrameTime = now
        let time = Float(simulationTime)

        // Prepare the frame's inputs *before* touching the drawable. Acquiring a
        // drawable commits to presenting one; doing it first means a frame with
        // no new depth data still costs a present.
        var liveFrame: LiveFrame?
        if source == .live {
            guard let prepared = prepareSignpostedLiveFrame() else { return }
            liveFrame = prepared
        }

        guard
            let drawable = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.label = "Point cloud"
        encoder.setDepthStencilState(depthState)
        encoder.setRenderPipelineState(pipeline)

        if let liveFrame {
            encodeLive(encoder: encoder, frame: liveFrame)
            // Keep the Core Video wrappers alive until GPU completion.
            let retained = liveFrame.retainedTextures
            commandBuffer.addCompletedHandler { _ in
                withExtendedLifetime(retained) {}
            }

        } else {
            encodeDemo(encoder: encoder, time: time)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Marked consumed only once the buffer is actually submitted. Recording
        // it during preparation would permanently skip a frame whose drawable
        // or encoder creation had failed.
        if let liveFrame {
            lastRenderedFrameTimestamp = liveFrame.timestamp
        }
    }

    /// Everything a single live frame needs, validated up front.
    private struct LiveFrame {
        let timestamp: TimeInterval
        let uniforms: CloudUniforms
        let depthTexture: MTLTexture
        let confidenceTexture: MTLTexture
        let cameraLumaTexture: MTLTexture?
        let cameraChromaTexture: MTLTexture?
        let vertexCount: Int
        let retainedTextures: [CVMetalTexture]
    }

    /// Validates the current AR frame and builds its GPU inputs, or returns nil
    /// if there is nothing new or nothing usable to draw.
    private func prepareSignpostedLiveFrame() -> LiveFrame? {
        let signpost = MetalVisualLog.signposter.beginInterval("AR frame preparation")
        defer { MetalVisualLog.signposter.endInterval("AR frame preparation", signpost) }
        return prepareLiveFrame()
    }

    private func prepareLiveFrame() -> LiveFrame? {
        guard
            let textures,
            let frame = session?.currentFrame,
            let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        else { return nil }

        // MTKView can tick faster than ARKit delivers depth. Re-rendering the
        // same frame is pure waste, so skip it.
        guard frame.timestamp != lastRenderedFrameTimestamp else { return nil }

        guard let depthBinding = textures.depth(from: depthData) else { return nil }
        guard let confidence = textures.confidence(
            from: depthData,
            matching: depthBinding.texture
        ) else { return nil }
        var retained = [depthBinding.cvTexture]
        if let retainedTexture = confidence.retainedTexture {
            retained.append(retainedTexture)
        }

        // Camera colour is optional. A frame whose image cannot be bound still
        // renders in the depth palette rather than being dropped.
        var cameraImage: CameraImageBinding?
        if colorMode == .camera {
            cameraImage = textures.cameraImage(frame.capturedImage)
            if let cameraImage {
                retained.append(contentsOf: cameraImage.retainedTextures)
            }
        }
        let resolvedColorMode: PointCloudColorMode =
            (colorMode == .camera && cameraImage == nil) ? .depth : colorMode

        let uniforms = makeLiveUniforms(
            camera: frame.camera,
            depthTexture: depthBinding.texture,
            colorMode: resolvedColorMode,
            orientation: interfaceOrientation
        )

        return LiveFrame(
            timestamp: frame.timestamp,
            uniforms: uniforms,
            depthTexture: depthBinding.texture,
            confidenceTexture: confidence.texture,
            cameraLumaTexture: cameraImage?.luma.texture,
            cameraChromaTexture: cameraImage?.chroma.texture,
            vertexCount: depthBinding.texture.width * depthBinding.texture.height,
            retainedTextures: retained
        )
    }

    private func makeLiveUniforms(
        camera: ARCamera,
        depthTexture: MTLTexture,
        colorMode: PointCloudColorMode,
        orientation: UIInterfaceOrientation
    ) -> CloudUniforms {
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projection = camera.projectionMatrix(
            for: orientation,
            viewportSize: viewportPointSize == .zero ? viewportSize : viewportPointSize,
            zNear: 0.05,
            zFar: 20
        )

        var uniforms = CloudUniforms()
        uniforms.viewProjection = projection * viewMatrix
        uniforms.localToWorld = Self.localToWorld(
            viewMatrix: viewMatrix,
            orientation: orientation
        )
        uniforms.intrinsicsInv = camera.intrinsics.inverse
        uniforms.cameraResolution = SIMD2(
            Float(camera.imageResolution.width),
            Float(camera.imageResolution.height)
        )
        uniforms.gridResolution = SIMD2(
            Float(depthTexture.width),
            Float(depthTexture.height)
        )
        uniforms.pointSize = Self.drawablePointSize(
            livePointSize,
            drawableSize: viewportSize,
            viewportPointSize: viewportPointSize
        )
        uniforms.maxDepth = maxDepth
        uniforms.minConfidence = minimumConfidence.rawValue
        uniforms.colorMode = colorMode.shaderValue
        return uniforms
    }

    private func encodeLive(
        encoder: MTLRenderCommandEncoder,
        frame: LiveFrame
    ) {
        let signpost = MetalVisualLog.signposter.beginInterval("Point cloud render encode")
        defer { MetalVisualLog.signposter.endInterval("Point cloud render encode", signpost) }

        var uniforms = frame.uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        encoder.setVertexTexture(frame.depthTexture, index: 0)
        encoder.setVertexTexture(frame.confidenceTexture, index: 1)
        // These remain unbound outside camera mode; the shader branches before
        // sampling them and the uniform is resolved away from camera when nil.
        encoder.setVertexTexture(frame.cameraLumaTexture, index: 2)
        encoder.setVertexTexture(frame.cameraChromaTexture, index: 3)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.vertexCount)
    }

    private func encodeDemo(encoder: MTLRenderCommandEncoder, time: Float) {
        let aspect = Float(max(viewportSize.width, 1) / max(viewportSize.height, 1))
        let fovY: Float = .pi / 3.2
        let projection = Self.perspective(fovY: fovY, aspect: aspect, near: 0.05, far: 50)
        let distance = Self.demoCameraDistance(
            aspect: aspect,
            fovY: fovY,
            sphereRadius: 1.15,
            margin: 1.18
        ) * demoZoom
        let cosElevation = cos(demoOrbit.elevation)
        let eye = SIMD3<Float>(
            sin(demoOrbit.azimuth) * cosElevation * distance,
            sin(demoOrbit.elevation) * distance,
            cos(demoOrbit.azimuth) * cosElevation * distance
        )
        let view = Self.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let spritePixels = Self.drawablePointSize(
            demoPointSize,
            drawableSize: viewportSize,
            viewportPointSize: viewportPointSize
        )

        var uniforms = DemoUniforms()
        uniforms.viewProjection = projection * view
        uniforms.cameraPosition = eye
        uniforms.time = time
        uniforms.pointCount = Float(demoPointCount)
        // The shader divides by clip-space w. Pre-multiplying by the fitted
        // camera distance preserves the intended on-screen point size.
        uniforms.pointSize = spritePixels * distance
        uniforms.motionScale = motionScale

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DemoUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: demoPointCount)
    }
}
