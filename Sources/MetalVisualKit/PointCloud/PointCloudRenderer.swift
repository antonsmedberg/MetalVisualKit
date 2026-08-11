//
//  PointCloudRenderer.swift
//  MetalVisualKit
//
//  Live mode samples ARKit's sceneDepth map inside the vertex shader and
//  unprojects to world space on the GPU. Demo mode draws a procedural cloud so
//  the component still shows something in previews and on non-LiDAR hardware.
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

    enum Function {
        static let liveVertex = "pointCloudVertex"
        static let demoVertex = "demoCloudVertex"
        static let fragment = "cloudFragment"
    }

    /// Whether this device can deliver LiDAR depth frames.
    static var isLiDARAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    let source: PointCloudSource
    var maxDepth: Float = 5
    /// Sprite size in points at one metre. The shader divides by clip-space w
    /// and caps at 12 px — a large value here just pins every point to the cap
    /// and buys nothing but fragment overdraw.
    var pointSize: Float = 8
    var motionScale: Float = 1
    /// Pushed in from the SwiftUI layer, which reads it on the main actor.
    /// The renderer must not touch `UIApplication` from the draw callback.
    var interfaceOrientation: UIInterfaceOrientation = .portrait

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var textureCache: CVMetalTextureCache?

    private(set) var session: ARSession?
    private var viewportSize: CGSize = .zero
    private var viewportPointSize: CGSize = .zero
    private let demoPointCount = 24_000
    private var cachedFallbackConfidence: MTLTexture?
    private var lastRenderedFrameTimestamp: TimeInterval = -1
    private var isActive = false
    private var lastFrameTime = CACurrentMediaTime()
    /// Advanced by rendered frame deltas, not wall clock, so time does not jump
    /// by the length of a backgrounded interval on the first frame back.
    private var simulationTime: Double = 0

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

        super.init()

        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        // A renderer without a texture cache can never produce a depth texture.
        // Failing here beats existing in a state that silently renders nothing.
        guard cacheStatus == kCVReturnSuccess, textureCache != nil else {
            throw MetalVisualError.textureCacheUnavailable(status: cacheStatus)
        }
        // Deliberately does not start an AR session here. The camera must not
        // open until the view is actually active; setActive(true) starts it.
    }

    deinit {
        session?.pause()
    }

    // MARK: - AR session

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics =
            ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
            ? .smoothedSceneDepth
            : .sceneDepth
        return configuration
    }

    private func startSession() {
        let session = self.session ?? ARSession()
        session.run(makeConfiguration())
        self.session = session
        MetalVisualLog.renderer.info("ARSession started with scene depth.")
    }

    func pause() {
        setActive(false)
    }

    /// Idempotent. SwiftUI's `updateUIView` runs on every state change — moving
    /// the depth slider, a progress tick — and re-running an AR configuration
    /// each time restarts tracking for no reason. Only a real transition acts.
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

    // MARK: - Texture helpers

    /// A Metal texture together with the Core Video wrapper that owns its
    /// backing IOSurface.
    ///
    /// `CVMetalTextureCacheCreateTextureFromImage` documents that a strong
    /// reference to the image buffer or the Core Video texture must be held
    /// until Metal rendering completes, and suggests a command-buffer handler
    /// for the purpose. Dropping the `CVMetalTexture` at the end of the
    /// creating function — which is what this renderer used to do — lets the
    /// surface be recycled while the GPU is still reading it. The failure is
    /// intermittent and device-specific, which is the worst kind.
    private struct TextureBinding {
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
    }

    private func makeBinding(
        _ pixelBuffer: CVPixelBuffer,
        format: MTLPixelFormat
    ) -> TextureBinding? {
        guard let textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, format, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            MetalVisualLog.renderer.error("Depth texture creation failed (CVReturn \(status)).")
            return nil
        }
        return TextureBinding(cvTexture: cvTexture, texture: texture)
    }

    /// Metal format for a Core Video buffer, or `nil` if ARKit handed us
    /// something this renderer does not know how to interpret. Guessing here
    /// would mean reinterpreting bytes and rendering plausible garbage.
    private func metalFormat(for pixelBuffer: CVPixelBuffer) -> MTLPixelFormat? {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_OneComponent32Float:
            return .r32Float
        case kCVPixelFormatType_OneComponent8:
            return .r8Uint
        default:
            return nil
        }
    }

    /// Stand-in confidence texture used when ARKit supplies depth without a
    /// confidence map, which `confidenceMap` documents as possible. Every texel
    /// reads as high confidence, so depth still renders instead of the view
    /// going blank.
    private func fallbackConfidenceTexture(width: Int, height: Int) -> MTLTexture? {
        if let cached = cachedFallbackConfidence,
           cached.width == width, cached.height == height {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytes = [UInt8](repeating: 2, count: width * height)   // ARConfidenceLevel.high
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: width
            )
        }
        cachedFallbackConfidence = texture
        return texture
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size
        // ARKit's projectionMatrix(for:viewportSize:...) documents its viewport
        // in points, not render pixels. The aspect ratio happens to match, but
        // passing the documented unit costs nothing and removes the trap.
        viewportPointSize = view.bounds.size
        // A rotation can change the drawable without SwiftUI re-running
        // updateUIView, so the projection would otherwise use a stale orientation.
        if let scene = view.window?.windowScene {
            interfaceOrientation = scene.interfaceOrientation
        }
    }

    func draw(in view: MTKView) {
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
            guard let prepared = prepareLiveFrame() else { return }
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
            encodeLive(encoder: encoder, frame: liveFrame, time: time)
            // Hold the Core Video wrappers until the GPU is finished with them.
            // withExtendedLifetime is what keeps ARC from releasing the binding
            // at the end of this scope; waitUntilCompleted would also work and
            // would also stall the CPU on every frame, so it is not used.
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
        let vertexCount: Int
        let retainedTextures: [CVMetalTexture]
    }

    /// Confidence input paired with the Core Video wrapper that must stay alive
    /// until rendering completes. The fallback texture is owned by the renderer,
    /// so it has no wrapper to retain per frame.
    private struct ConfidenceBinding {
        let texture: MTLTexture
        let retainedTexture: CVMetalTexture?
    }

    private func prepareConfidence(
        from depthData: ARDepthData,
        matching depthTexture: MTLTexture
    ) -> ConfidenceBinding? {
        guard let confidenceMap = depthData.confidenceMap else {
            guard let fallback = fallbackConfidenceTexture(
                width: depthTexture.width,
                height: depthTexture.height
            ) else { return nil }
            return ConfidenceBinding(texture: fallback, retainedTexture: nil)
        }

        guard let confidenceFormat = metalFormat(for: confidenceMap),
              confidenceFormat == .r8Uint,
              let binding = makeBinding(confidenceMap, format: .r8Uint)
        else {
            MetalVisualLog.renderer.error("Unsupported confidence format; frame skipped.")
            return nil
        }
        guard binding.texture.width == depthTexture.width,
              binding.texture.height == depthTexture.height
        else {
            MetalVisualLog.renderer.error("Depth and confidence dimensions disagree.")
            return nil
        }
        return ConfidenceBinding(texture: binding.texture, retainedTexture: binding.cvTexture)
    }

    /// Validates the current AR frame and builds its GPU inputs, or returns nil
    /// if there is nothing new or nothing usable to draw.
    private func prepareLiveFrame() -> LiveFrame? {
        guard
            let frame = session?.currentFrame,
            let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        else { return nil }

        // MTKView can tick faster than ARKit delivers depth. Re-rendering the
        // same frame is pure waste, so skip it.
        guard frame.timestamp != lastRenderedFrameTimestamp else { return nil }

        guard let depthFormat = metalFormat(for: depthData.depthMap), depthFormat == .r32Float
        else {
            MetalVisualLog.renderer.error("Unsupported depth pixel format; frame skipped.")
            return nil
        }
        guard let depthBinding = makeBinding(depthData.depthMap, format: .r32Float) else {
            return nil
        }

        guard let confidence = prepareConfidence(from: depthData, matching: depthBinding.texture)
        else { return nil }
        var retained = [depthBinding.cvTexture]
        if let retainedTexture = confidence.retainedTexture {
            retained.append(retainedTexture)
        }

        let orientation = interfaceOrientation
        let camera = frame.camera
        let projection = camera.projectionMatrix(
            for: orientation,
            viewportSize: viewportPointSize == .zero ? viewportSize : viewportPointSize,
            zNear: 0.05,
            zFar: 20
        )

        var uniforms = CloudUniforms()
        uniforms.viewProjection = projection * camera.viewMatrix(for: orientation)
        uniforms.localToWorld = camera.transform * Self.rotateToARCamera(for: orientation)
        uniforms.intrinsicsInv = camera.intrinsics.inverse
        uniforms.cameraResolution = SIMD2(
            Float(camera.imageResolution.width),
            Float(camera.imageResolution.height)
        )
        uniforms.gridResolution = SIMD2(
            Float(depthBinding.texture.width),
            Float(depthBinding.texture.height)
        )
        uniforms.pointSize = pointSize
        uniforms.maxDepth = maxDepth
        uniforms.time = Float(simulationTime)

        return LiveFrame(
            timestamp: frame.timestamp,
            uniforms: uniforms,
            depthTexture: depthBinding.texture,
            confidenceTexture: confidence.texture,
            vertexCount: depthBinding.texture.width * depthBinding.texture.height,
            retainedTextures: retained
        )
    }

    private func encodeLive(
        encoder: MTLRenderCommandEncoder,
        frame: LiveFrame,
        time: Float
    ) {
        var uniforms = frame.uniforms
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        encoder.setVertexTexture(frame.depthTexture, index: 0)
        encoder.setVertexTexture(frame.confidenceTexture, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.vertexCount)
    }

    private func encodeDemo(encoder: MTLRenderCommandEncoder, time: Float) {
        let aspect = Float(max(viewportSize.width, 1) / max(viewportSize.height, 1))
        let projection = Self.perspective(fovY: .pi / 3.2, aspect: aspect, near: 0.05, far: 50)
        let view = Self.lookAt(eye: SIMD3(0, 0.35, 2.9), center: .zero, up: SIMD3(0, 1, 0))

        var uniforms = DemoUniforms()
        uniforms.viewProjection = projection * view
        uniforms.time = time
        uniforms.pointCount = Float(demoPointCount)
        uniforms.pointSize = 60
        uniforms.motionScale = motionScale

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DemoUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: demoPointCount)
    }
}
