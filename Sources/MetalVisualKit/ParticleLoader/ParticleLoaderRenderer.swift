//
//  ParticleLoaderRenderer.swift
//  MetalVisualKit
//
//  MTKView delegate for the particle loader: compute pass (physics) then a
//  single point draw call, additive blended onto a transparent drawable.
//

import Metal
import MetalKit
import QuartzCore
import simd

// MARK: - Uniform mirrors
//
// These must match ParticleShaders.metal field for field. Swift lays out
// `SIMD2<Float>` at 8-byte alignment exactly as MSL lays out `float2`, so a
// straight field-order mirror is layout-correct. PipelineTests pins the stride.

/// stride 48, align 8
struct LoaderUniforms {
    var resolution: SIMD2<Float> = .zero
    var touch: SIMD2<Float> = .zero
    var time: Float = 0
    var dt: Float = 0
    var progress: Float = 0
    var touchActive: Float = 0
    var burst: Float = 0
    var motionScale: Float = 1
    var surfaceIsLight: Float = 0
}

/// stride 32, align 8
struct LoaderParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var phase: Float
    var variation: Float
    var size: Float
    var energy: Float
}

// MARK: - Renderer

final class ParticleLoaderRenderer: NSObject, MTKViewDelegate {

    static let initialRadiusFraction: Float = 0.40
    static let particleSizeRange: ClosedRange<Float> = 2.5...5

    /// Shader function names, kept in one place so the tests can assert on them.
    enum Function {
        static let update = "updateParticles"
        static let vertex = "particleVertex"
        static let fragment = "particleFragment"
    }

    // Driven from SwiftUI
    var progress: Float = 0
    var touch: CGPoint?              // drawable-space pixels
    var motionScale: Float = 1       // 0 when Reduce Motion is enabled
    var surfaceIsLight = false

    let particleCount: Int

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let additiveRenderPipeline: MTLRenderPipelineState
    private let sourceOverRenderPipeline: MTLRenderPipelineState
    private let threadgroupWidth: Int

    private let particleBuffer: MTLBuffer
    private var hasSeededParticles = false
    private var isActive = true

    private var lastFrameTime = CACurrentMediaTime()
    /// Frame-delta clock that excludes time spent in the background.
    private var simulationTime: Double = 0
    private var lastProgress: Float = 0
    private var burst: Float = 0

    init(view: MTKView, particleCount: Int = 1_400) throws {
        let particleBufferLength = try Self.particleBufferLength(for: particleCount)
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalVisualError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MetalVisualError.commandQueueUnavailable
        }

        let library = try ShaderLibrary.make(device: device)
        let computeFunction = try ShaderLibrary.function(Function.update, in: library)

        self.device = device
        self.queue = queue
        self.particleCount = particleCount
        self.computePipeline = try device.makeComputePipelineState(function: computeFunction)
        self.threadgroupWidth = min(computePipeline.maxTotalThreadsPerThreadgroup, 256)
        guard let particleBuffer = device.makeBuffer(
            length: particleBufferLength,
            options: .storageModeShared
        ) else {
            throw MetalVisualError.particleBufferUnavailable
        }
        self.particleBuffer = particleBuffer
        self.particleBuffer.label = "MetalVisualKit.Particles"

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MetalVisualKit.ParticleLoader"
        descriptor.vertexFunction = try ShaderLibrary.function(Function.vertex, in: library)
        descriptor.fragmentFunction = try ShaderLibrary.function(Function.fragment, in: library)
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        // Additive blending — overlapping sprites accumulate into a glow.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        self.additiveRenderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        descriptor.label = "MetalVisualKit.ParticleLoader.LightSurface"
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.sourceOverRenderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        super.init()

        view.device = device
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // 60 FPS is the default quality/energy trade-off. Particle integration
        // is timestep-independent.
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
    }

    static func validateParticleCount(_ particleCount: Int) throws {
        _ = try particleBufferLength(for: particleCount)
    }

    private static func particleBufferLength(for particleCount: Int) throws -> Int {
        guard particleCount > 0 else {
            throw MetalVisualError.invalidParticleCount(particleCount)
        }
        let (length, overflow) = MemoryLayout<LoaderParticle>.stride
            .multipliedReportingOverflow(by: particleCount)
        guard !overflow else {
            throw MetalVisualError.particleCountTooLarge(particleCount)
        }
        return length
    }

    // MARK: - Seeding

    static func makeSeedParticles(particleCount: Int, size: CGSize) -> [LoaderParticle] {
        guard particleCount > 0, size.width > 0, size.height > 0 else { return [] }
        let center = SIMD2<Float>(Float(size.width) * 0.5, Float(size.height) * 0.5)
        let radius = Float(min(size.width, size.height)) * Self.initialRadiusFraction

        var particles: [LoaderParticle] = []
        particles.reserveCapacity(particleCount)
        for index in 0..<particleCount {
            let phase = (Float(index) / Float(particleCount)) * 2 * .pi
            particles.append(
                LoaderParticle(
                    position: center + SIMD2(cos(phase), sin(phase)) * radius,
                    velocity: .zero,
                    phase: phase,
                    variation: Float(index) / Float(particleCount),
                    size: Float.random(in: Self.particleSizeRange),
                    energy: 0.5
                )
            )
        }
        return particles
    }

    private func seedParticles(size: CGSize) {
        let particles = Self.makeSeedParticles(particleCount: particleCount, size: size)
        guard !particles.isEmpty else { return }

        particles.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            particleBuffer.contents().copyMemory(from: source, byteCount: bytes.count)
        }
        hasSeededParticles = true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Preserve particle state across SwiftUI's intermediate resize frames.
        if !hasSeededParticles {
            seedParticles(size: size)
        }
    }

    /// Changes rendering activity without resetting timing on repeated updates.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            // Discard the gap accumulated while inactive; it would otherwise
            // arrive as one enormous dt and fling every particle off screen.
            lastFrameTime = CACurrentMediaTime()
        } else {
            touch = nil
        }
    }

    func draw(in view: MTKView) {
        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        if !hasSeededParticles {
            seedParticles(size: drawableSize)
        }
        guard
            let drawable = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer()
        else { return }

        var uniforms = makeUniforms(drawableSize: drawableSize)
        let uniformSize = MemoryLayout<LoaderUniforms>.stride

        let computeSignpost = MetalVisualLog.signposter.beginInterval("Particle compute encode")
        if let compute = commandBuffer.makeComputeCommandEncoder() {
            compute.label = "Particle physics"
            compute.setComputePipelineState(computePipeline)
            compute.setBuffer(particleBuffer, offset: 0, index: 0)
            compute.setBytes(&uniforms, length: uniformSize, index: 1)
            compute.dispatchThreads(
                MTLSize(width: particleCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: threadgroupWidth, height: 1, depth: 1)
            )
            compute.endEncoding()
        }
        MetalVisualLog.signposter.endInterval("Particle compute encode", computeSignpost)

        let renderSignpost = MetalVisualLog.signposter.beginInterval("Particle render encode")
        if let render = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            render.label = "Particle render"
            render.setRenderPipelineState(
                surfaceIsLight ? sourceOverRenderPipeline : additiveRenderPipeline
            )
            render.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            render.setVertexBytes(&uniforms, length: uniformSize, index: 1)
            render.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            render.endEncoding()
        }
        MetalVisualLog.signposter.endInterval("Particle render encode", renderSignpost)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(drawableSize: CGSize) -> LoaderUniforms {
        let now = CACurrentMediaTime()
        let delta = Float(min(now - lastFrameTime, 1.0 / 30.0))
        lastFrameTime = now

        simulationTime += Double(delta)

        // Decay first, then trigger, so a burst starting this frame leaves at
        // full amplitude instead of already-damped 0.9. The envelope decays per
        // second, matching the shader's own timestep-independent damping — a
        // per-frame `*= 0.90` would empty the burst twice as fast at 120 Hz.
        burst *= pow(0.94, delta * 60)
        if progress >= 1, lastProgress < 1 { burst = 1 }
        lastProgress = progress

        var uniforms = LoaderUniforms()
        uniforms.resolution = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        uniforms.time = Float(simulationTime)
        uniforms.dt = delta
        uniforms.progress = min(max(progress, 0), 1)
        uniforms.burst = burst
        uniforms.motionScale = motionScale
        uniforms.surfaceIsLight = surfaceIsLight ? 1 : 0
        if let touch {
            uniforms.touch = SIMD2(Float(touch.x), Float(touch.y))
            uniforms.touchActive = 1
        }
        return uniforms
    }
}
