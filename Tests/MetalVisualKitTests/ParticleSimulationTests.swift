//
//  ParticleSimulationTests.swift
//  MetalVisualKitTests
//
//  Deterministic particle initialization and shader simulation.
//

import Metal
import XCTest
import simd

@testable import MetalVisualKit

final class ParticleSimulationTests: XCTestCase {

    private struct ComputeContext {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
    }

    private func makeComputeContext() throws -> ComputeContext {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host.")
        }

        let library = try ShaderLibrary.make(device: device)

        let function = try ShaderLibrary.function(ParticleLoaderRenderer.Function.update, in: library)

        let pipeline = try device.makeComputePipelineState(function: function)

        guard let queue = device.makeCommandQueue() else { throw MetalVisualError.commandQueueUnavailable }

        return ComputeContext(device: device, queue: queue, pipeline: pipeline)
    }

    private func updateParticle(
        _ input: LoaderParticle, uniforms inputUniforms: LoaderUniforms
    ) throws -> LoaderParticle {
        let context = try makeComputeContext()

        var particle = input
        var uniforms = inputUniforms

        guard
            let particleBuffer = context.device.makeBuffer(
                bytes: &particle, length: MemoryLayout<LoaderParticle>.stride, options: .storageModeShared)
        else { throw MetalVisualError.particleBufferUnavailable }

        guard let commandBuffer = context.queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { throw MetalVisualError.commandQueueUnavailable }

        encoder.setComputePipelineState(context.pipeline)

        encoder.setBuffer(particleBuffer, offset: 0, index: 0)

        encoder.setBytes(&uniforms, length: MemoryLayout<LoaderUniforms>.stride, index: 1)

        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error { throw error }

        return particleBuffer.contents().bindMemory(to: LoaderParticle.self, capacity: 1).pointee
    }

    func testParticleSeedMatchesStructuredRingDefaults() {
        XCTAssertEqual(ParticleLoaderRenderer.initialRadiusFraction, 0.40)

        XCTAssertEqual(ParticleLoaderRenderer.particleSizeRange.lowerBound, 2.5)

        XCTAssertEqual(ParticleLoaderRenderer.particleSizeRange.upperBound, 5)
    }

    func testParticlesSeedExactlyOnTargetRing() {
        let size = CGSize(width: 320, height: 400)

        let particles = ParticleLoaderRenderer.makeSeedParticles(particleCount: 64, size: size)

        let center = SIMD2<Float>(160, 200)

        let radius: Float = 320 * ParticleLoaderRenderer.initialRadiusFraction

        XCTAssertEqual(particles.count, 64)

        for particle in particles {
            XCTAssertEqual(simd_distance(particle.position, center), radius, accuracy: 1e-4)

            XCTAssertTrue(ParticleLoaderRenderer.particleSizeRange.contains(particle.size))
        }
    }

    func testParticleCountMustBePositive() {
        XCTAssertNoThrow(try ParticleLoaderRenderer.validateParticleCount(1))

        XCTAssertThrowsError(try ParticleLoaderRenderer.validateParticleCount(0))

        XCTAssertThrowsError(try ParticleLoaderRenderer.validateParticleCount(-1))

        XCTAssertThrowsError(try ParticleLoaderRenderer.validateParticleCount(.max))
    }

    func testParticleEnergyIsExactAtProgressEndpoints() throws {
        let particle = LoaderParticle(
            position: SIMD2(160, 160), velocity: .zero, phase: 0, variation: 0, size: 4, energy: 0.5)

        var uniforms = LoaderUniforms()

        uniforms.resolution = SIMD2(320, 320)

        uniforms.motionScale = 1
        uniforms.progress = 0

        XCTAssertEqual(try updateParticle(particle, uniforms: uniforms).energy, 0)

        uniforms.progress = 1

        XCTAssertEqual(try updateParticle(particle, uniforms: uniforms).energy, 1)
    }

    func testReduceMotionClearsVelocityAndProducesStaticTarget() throws {
        let particle = LoaderParticle(
            position: SIMD2(30, 40), velocity: SIMD2(500, -300), phase: 0.7, variation: 0.3, size: 4, energy: 0)

        var uniforms = LoaderUniforms()

        uniforms.resolution = SIMD2(320, 320)

        uniforms.touch = SIMD2(30, 40)

        uniforms.time = 1
        uniforms.dt = 1 / 30
        uniforms.progress = 0.5
        uniforms.touchActive = 1
        uniforms.burst = 1
        uniforms.motionScale = 0

        let first = try updateParticle(particle, uniforms: uniforms)

        uniforms.time = 100

        let second = try updateParticle(first, uniforms: uniforms)

        XCTAssertEqual(first.velocity, .zero)

        XCTAssertEqual(second.velocity, .zero)

        XCTAssertEqual(first.position, second.position)

        XCTAssertEqual(first.energy, second.energy)
    }
}
