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

/// stride 40, align 8
struct LoaderUniforms {
    var resolution: SIMD2<Float> = .zero
    var touch: SIMD2<Float> = .zero
    var time: Float = 0
    var dt: Float = 0
    var progress: Float = 0
    var touchActive: Float = 0
    var burst: Float = 0
    var motionScale: Float = 1
}

/// stride 32, align 8
struct LoaderParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var phase: Float
    var hue: Float
    var size: Float
    var energy: Float
}

// MARK: - Renderer

final class ParticleLoaderRenderer: NSObject, MTKViewDelegate {

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

    let particleCount: Int

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private let threadgroupWidth: Int

    private var particleBuffer: MTLBuffer?
    private var isActive = true

    private var lastFrameTime = CACurrentMediaTime()
    /// Accumulated from rendered frame deltas rather than read off the wall
    /// clock. Wall-clock time keeps running while the app is backgrounded, so
    /// returning after 20 seconds would advance the noise field by 20 seconds
    /// in a single frame and snap the whole ring.
    private var simulationTime: Double = 0
    private var lastProgress: Float = 0
    private var burst: Float = 0

    init(view: MTKView, particleCount: Int = 1_400) throws {
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
        self.renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        super.init()

        view.device = device
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // 60, not 120. A progress indicator does not earn double the GPU
        // submissions, memory bandwidth and battery on a ProMotion display;
        // the physics is timestep-independent so it looks the same either way.
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
    }

    // MARK: - Seeding

    private func seedParticles(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let center = SIMD2<Float>(Float(size.width) * 0.5, Float(size.height) * 0.5)
        let radius = Float(min(size.width, size.height)) * 0.32

        var particles: [LoaderParticle] = []
        particles.reserveCapacity(particleCount)
        for index in 0..<particleCount {
            let phase = (Float(index) / Float(particleCount)) * 2 * .pi
            let ringRadius = radius * Float.random(in: 0.9...1.1)
            particles.append(
                LoaderParticle(
                    position: center + SIMD2(cos(phase), sin(phase)) * ringRadius,
                    velocity: .zero,
                    phase: phase,
                    hue: Float(index) / Float(particleCount),
                    size: Float.random(in: 3...9),
                    energy: 0.5
                )
            )
        }

        particleBuffer = device.makeBuffer(
            bytes: particles,
            length: MemoryLayout<LoaderParticle>.stride * particleCount,
            options: .storageModeShared
        )
        particleBuffer?.label = "MetalVisualKit.Particles"
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Deliberately does *not* reseed. SwiftUI emits a stream of intermediate
        // sizes while animating a frame, and rebuilding 1,400 particles on each
        // one both churns allocations and visibly resets the effect. The shader
        // reads the new resolution from the uniforms and the existing particles
        // spring toward the new ring, which is cheaper and looks better.
        if particleBuffer == nil {
            seedParticles(size: size)
        }
    }

    /// Idempotent by design: SwiftUI's `updateUIView` runs on every progress
    /// change, and resetting the frame clock there would corrupt `dt` on every
    /// tick. Only a genuine inactive → active transition restarts the clock.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            // Discard the gap accumulated while inactive; it would otherwise
            // arrive as one enormous dt and fling every particle off screen.
            lastFrameTime = CACurrentMediaTime()
        }
    }

    func draw(in view: MTKView) {
        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        if particleBuffer == nil {
            seedParticles(size: drawableSize)
        }

        guard
            let particleBuffer,
            let drawable = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer()
        else { return }

        var uniforms = makeUniforms(drawableSize: drawableSize)
        let uniformSize = MemoryLayout<LoaderUniforms>.stride

        // 1. Physics
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

        // 2. One draw call for every particle
        if let render = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            render.label = "Particle render"
            render.setRenderPipelineState(renderPipeline)
            render.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            render.setVertexBytes(&uniforms, length: uniformSize, index: 1)
            render.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            render.endEncoding()
        }

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
        burst *= pow(0.90, delta * 60)
        if progress >= 1, lastProgress < 1 { burst = 1 }
        lastProgress = progress

        var uniforms = LoaderUniforms()
        uniforms.resolution = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        uniforms.time = Float(simulationTime)
        uniforms.dt = delta
        uniforms.progress = min(max(progress, 0), 1)
        uniforms.burst = burst
        uniforms.motionScale = motionScale
        if let touch {
            uniforms.touch = SIMD2(Float(touch.x), Float(touch.y))
            uniforms.touchActive = 1
        }
        return uniforms
    }
}
