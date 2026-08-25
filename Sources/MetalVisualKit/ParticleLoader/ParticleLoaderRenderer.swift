//
//  ParticleLoaderRenderer.swift
//  MetalVisualKit
//
//  Runs the particle loader's compute pass and renders the resulting particles
//  into a transparent Metal drawable.
//

import Metal
import MetalKit
import QuartzCore
import simd

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

struct LoaderParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var phase: Float
    var variation: Float
    var size: Float
    var energy: Float
}

@MainActor final class ParticleLoaderRenderer: NSObject, MTKViewDelegate {

    nonisolated static let initialRadiusFraction: Float = 0.40
    nonisolated static let particleSizeRange: ClosedRange<Float> = 2.5...5

    enum Function {
        static let update = "updateParticles"
        static let vertex = "particleVertex"
        static let fragment = "particleFragment"
    }

    var progress: Float = 0
    var touch: CGPoint?
    var motionScale: Float = 1
    var surfaceIsLight = false

    let particleCount: Int

    private let queue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let additiveRenderPipeline: MTLRenderPipelineState
    private let sourceOverRenderPipeline: MTLRenderPipelineState
    private let threadgroupWidth: Int
    private let particleBuffer: MTLBuffer

    private var hasSeededParticles = false
    private var isActive = false
    private var lastFrameTime = CACurrentMediaTime()
    private var simulationTime: Double = 0
    private var lastProgress: Float = 0
    private var burst: Float = 0

    init(view: MTKView, particleCount: Int = 1_400) throws {
        let particleBufferLength = try Self.particleBufferLength(for: particleCount)

        let device = try Self.resolveDevice(for: view)

        guard let queue = device.makeCommandQueue() else { throw MetalVisualError.commandQueueUnavailable }

        let library = try ShaderLibrary.make(device: device)
        let computeFunction = try ShaderLibrary.function(Function.update, in: library)
        let computePipeline = try device.makeComputePipelineState(function: computeFunction)

        let renderPipelines = try Self.makeRenderPipelines(
            device: device, library: library, colorPixelFormat: view.colorPixelFormat)

        guard let particleBuffer = device.makeBuffer(length: particleBufferLength, options: .storageModeShared) else {
            throw MetalVisualError.particleBufferUnavailable
        }

        particleBuffer.label = "MetalVisualKit.Particles"

        self.queue = queue
        self.particleCount = particleCount
        self.computePipeline = computePipeline
        self.threadgroupWidth = min(computePipeline.maxTotalThreadsPerThreadgroup, 256)
        self.particleBuffer = particleBuffer
        self.additiveRenderPipeline = renderPipelines.additive
        self.sourceOverRenderPipeline = renderPipelines.sourceOver

        super.init()

        Self.configure(view, device: device)
    }

    // MARK: - Validation

    nonisolated static func validateParticleCount(_ particleCount: Int) throws {
        _ = try particleBufferLength(for: particleCount)
    }

    private nonisolated static func particleBufferLength(for particleCount: Int) throws -> Int {
        guard particleCount > 0 else { throw MetalVisualError.invalidParticleCount(particleCount) }

        let (length, overflow) = MemoryLayout<LoaderParticle>.stride.multipliedReportingOverflow(by: particleCount)

        guard !overflow else { throw MetalVisualError.particleCountTooLarge(particleCount) }

        return length
    }

    // MARK: - Seeding

    nonisolated static func makeSeedParticles(particleCount: Int, size: CGSize) -> [LoaderParticle] {
        guard particleCount > 0, size.width > 0, size.height > 0 else { return [] }

        let center = SIMD2<Float>(Float(size.width) * 0.5, Float(size.height) * 0.5)

        let radius = Float(min(size.width, size.height)) * initialRadiusFraction

        var particles: [LoaderParticle] = []
        particles.reserveCapacity(particleCount)

        for index in 0..<particleCount {
            let fraction = Float(index) / Float(particleCount)
            let phase = fraction * 2 * Float.pi
            let direction = SIMD2<Float>(cos(phase), sin(phase))

            particles.append(
                LoaderParticle(
                    position: center + direction * radius, velocity: .zero, phase: phase, variation: fraction,
                    size: Float.random(in: particleSizeRange), energy: 0.5))
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

    // MARK: - Activity

    func setActive(_ active: Bool) {
        guard active != isActive else { return }

        isActive = active

        if active { lastFrameTime = CACurrentMediaTime() } else { touch = nil }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard isActive, !hasSeededParticles else { return }

        seedParticles(size: size)
    }

    func draw(in view: MTKView) {
        guard isActive else { return }

        let drawableSize = view.drawableSize

        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        if !hasSeededParticles { seedParticles(size: drawableSize) }

        guard let passDescriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let commandBuffer = queue.makeCommandBuffer()
        else { return }

        var uniforms = makeUniforms(drawableSize: drawableSize)

        encodeCompute(commandBuffer: commandBuffer, uniforms: &uniforms)

        encodeRender(commandBuffer: commandBuffer, passDescriptor: passDescriptor, uniforms: &uniforms)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Encoding

    private func encodeCompute(commandBuffer: MTLCommandBuffer, uniforms: inout LoaderUniforms) {
        let signpost = MetalVisualLog.signposter.beginInterval("Particle compute encode")

        defer { MetalVisualLog.signposter.endInterval("Particle compute encode", signpost) }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.label = "Particle physics"
        encoder.setComputePipelineState(computePipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<LoaderUniforms>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: particleCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadgroupWidth, height: 1, depth: 1))
        encoder.endEncoding()
    }

    private func encodeRender(
        commandBuffer: MTLCommandBuffer, passDescriptor: MTLRenderPassDescriptor, uniforms: inout LoaderUniforms
    ) {
        let signpost = MetalVisualLog.signposter.beginInterval("Particle render encode")

        defer { MetalVisualLog.signposter.endInterval("Particle render encode", signpost) }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        let renderPipeline = surfaceIsLight ? sourceOverRenderPipeline : additiveRenderPipeline

        encoder.label = "Particle render"
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LoaderUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        encoder.endEncoding()
    }

    // MARK: - Uniforms

    private func makeUniforms(drawableSize: CGSize) -> LoaderUniforms {
        let now = CACurrentMediaTime()

        let delta = Float(min(max(now - lastFrameTime, 0), 1.0 / 30.0))

        lastFrameTime = now
        simulationTime += Double(delta)

        burst *= pow(0.94, delta * 60)

        let clampedProgress = min(max(progress, 0), 1)

        if clampedProgress >= 1, lastProgress < 1 { burst = 1 }

        lastProgress = clampedProgress

        var uniforms = LoaderUniforms()

        uniforms.resolution = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        uniforms.time = Float(simulationTime)
        uniforms.dt = delta
        uniforms.progress = clampedProgress
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
