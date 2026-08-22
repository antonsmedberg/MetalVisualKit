//
//  PipelineTests.swift
//  MetalVisualKitTests
//
//  GPU output is validated separately. These tests cover deterministic package,
//  pipeline, layout, lifecycle and projection invariants.
//

import AVFoundation
import Metal
import SwiftUI
import UIKit
import XCTest
import simd
@testable import MetalVisualKit

final class PipelineTests: XCTestCase {

    // MARK: - Fixtures

    /// Skips the calling test when the host has no Metal device, which is the
    /// case for `swift test` on a machine without a GPU-backed toolchain.
    private func requireDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host.")
        }
        return device
    }

    private func requireLibrary() throws -> (device: MTLDevice, library: MTLLibrary) {
        let device = try requireDevice()
        return (device, try ShaderLibrary.make(device: device))
    }

    private func updateParticle(
        _ input: LoaderParticle,
        uniforms inputUniforms: LoaderUniforms
    ) throws -> LoaderParticle {
        let context = try requireLibrary()
        let function = try ShaderLibrary.function(
            ParticleLoaderRenderer.Function.update, in: context.library
        )
        let pipeline = try context.device.makeComputePipelineState(function: function)
        guard let queue = context.device.makeCommandQueue() else {
            throw MetalVisualError.commandQueueUnavailable
        }

        var particle = input
        var uniforms = inputUniforms
        guard let particleBuffer = context.device.makeBuffer(
            bytes: &particle,
            length: MemoryLayout<LoaderParticle>.stride,
            options: .storageModeShared
        ), let commandBuffer = queue.makeCommandBuffer(),
           let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalVisualError.particleBufferUnavailable
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<LoaderUniforms>.stride,
            index: 1
        )
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return particleBuffer.contents()
            .bindMemory(to: LoaderParticle.self, capacity: 1)
            .pointee
    }

    // MARK: - Shader library

    func testPackagedMetallibLoads() throws {
        let library = try requireLibrary().library
        XCTAssertFalse(
            library.functionNames.isEmpty,
            "default.metallib loaded but contains no functions."
        )
    }

    func testAllExpectedShaderFunctionsExist() throws {
        let library = try requireLibrary().library
        let expected = [
            ParticleLoaderRenderer.Function.update,
            ParticleLoaderRenderer.Function.vertex,
            ParticleLoaderRenderer.Function.fragment,
            PointCloudRenderer.Function.liveVertex,
            PointCloudRenderer.Function.demoVertex,
            PointCloudRenderer.Function.fragment
        ]
        for name in expected {
            XCTAssertNoThrow(
                try ShaderLibrary.function(name, in: library),
                "Missing shader function '\(name)'."
            )
        }
    }

    func testMissingFunctionThrowsDescriptiveError() throws {
        let library = try requireLibrary().library
        XCTAssertThrowsError(try ShaderLibrary.function("noSuchFunction", in: library)) { error in
            XCTAssertTrue(
                String(describing: error).contains("noSuchFunction"),
                "The error should name the function that was not found."
            )
        }
    }

    // MARK: - Pipeline construction

    func testParticleComputePipelineCompiles() throws {
        let context = try requireLibrary()
        let function = try ShaderLibrary.function(
            ParticleLoaderRenderer.Function.update, in: context.library
        )
        XCTAssertNoThrow(try context.device.makeComputePipelineState(function: function))
    }

    func testParticleRenderPipelineCompiles() throws {
        let context = try requireLibrary()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try ShaderLibrary.function(
            ParticleLoaderRenderer.Function.vertex, in: context.library
        )
        descriptor.fragmentFunction = try ShaderLibrary.function(
            ParticleLoaderRenderer.Function.fragment, in: context.library
        )
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        XCTAssertNoThrow(try context.device.makeRenderPipelineState(descriptor: descriptor))
    }

    func testPointCloudPipelinesCompile() throws {
        let context = try requireLibrary()
        let vertexNames = [
            PointCloudRenderer.Function.liveVertex,
            PointCloudRenderer.Function.demoVertex
        ]
        for vertexName in vertexNames {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try ShaderLibrary.function(vertexName, in: context.library)
            descriptor.fragmentFunction = try ShaderLibrary.function(
                PointCloudRenderer.Function.fragment, in: context.library
            )
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            XCTAssertNoThrow(
                try context.device.makeRenderPipelineState(descriptor: descriptor),
                "Pipeline '\(vertexName)' failed to compile."
            )
        }
    }

    // MARK: - Struct layout parity
    //
    // Swift and MSL layouts are mirrored by hand. If one side is edited without
    // the other, the GPU reads misaligned fields and the symptom is a visual
    // glitch, not a crash. Pinning the strides makes that fail here instead.
    //
    // Expected values follow MSL's layout rules, which Swift's SIMD types match:
    //   float   4 bytes,  align 4        float2    8 bytes,  align 8
    //   float3x3  48 bytes, align 16     float4x4  64 bytes, align 16
    //   (float3x3 is three 16-byte-aligned columns, not 36 bytes)

    func testLoaderUniformsStride() {
        // 2 × float2 (16) + 7 × float (28), rounded to 8-byte alignment = 48
        XCTAssertEqual(MemoryLayout<LoaderUniforms>.stride, 48)
        XCTAssertEqual(MemoryLayout<LoaderUniforms>.alignment, 8)
    }

    func testLoaderParticleStride() {
        // 2 × float2 (16) + 4 × float (16) = 32
        XCTAssertEqual(MemoryLayout<LoaderParticle>.stride, 32)
        XCTAssertEqual(MemoryLayout<LoaderParticle>.alignment, 8)
    }

    func testCloudUniformsStride() {
        // 2 × float4x4 (128) + float3x3 (48) + 2 × float2 (16) + 4 × float (16) = 208
        XCTAssertEqual(MemoryLayout<CloudUniforms>.stride, 208)
        XCTAssertEqual(MemoryLayout<CloudUniforms>.alignment, 16)
    }

    func testDemoUniformsStride() {
        // float4x4 (64) + float3 (16) + 4 × float (16) = 96
        XCTAssertEqual(MemoryLayout<DemoUniforms>.stride, 96)
        XCTAssertEqual(MemoryLayout<DemoUniforms>.alignment, 16)
    }

    func testSIMDPrimitivesMatchMSLExpectations() {
        // If any of these ever changes, every stride above is wrong too.
        XCTAssertEqual(MemoryLayout<SIMD2<Float>>.stride, 8)
        XCTAssertEqual(MemoryLayout<SIMD3<Float>>.stride, 16)
        XCTAssertEqual(MemoryLayout<simd_float3x3>.stride, 48)
        XCTAssertEqual(MemoryLayout<simd_float4x4>.stride, 64)
    }

    // MARK: - Lifecycle and accessibility

    func testCameraAccessStateMapping() {
        XCTAssertEqual(
            CameraAccess.state(hasUsageDescription: false, authorizationStatus: .authorized),
            .usageDescriptionMissing
        )
        XCTAssertEqual(
            CameraAccess.state(hasUsageDescription: true, authorizationStatus: .authorized),
            .granted
        )
        XCTAssertEqual(
            CameraAccess.state(hasUsageDescription: true, authorizationStatus: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            CameraAccess.state(hasUsageDescription: true, authorizationStatus: .restricted),
            .denied
        )
    }

    func testDepthValuesClampToSupportedRange() {
        let range = PointCloudMetalView.depthRange
        XCTAssertEqual(Float(-1).clamped(to: range), range.lowerBound)
        XCTAssertEqual(Float(2.75).clamped(to: range), 2.75)
        XCTAssertEqual(Float(20).clamped(to: range), range.upperBound)
    }

    func testParticleViewUsesOnDemandDrawingForReduceMotion() {
        XCTAssertTrue(
            ParticleLoaderMetalView.shouldRenderContinuously(isActive: true, reduceMotion: false)
        )
        XCTAssertFalse(
            ParticleLoaderMetalView.shouldRenderContinuously(isActive: true, reduceMotion: true)
        )
        XCTAssertFalse(
            ParticleLoaderMetalView.shouldRenderContinuously(isActive: false, reduceMotion: false)
        )
    }

    func testParticleSurfaceStyleResolvesAutomaticAndExplicitModes() {
        XCTAssertTrue(ParticleSurfaceStyle.automatic.usesLightPalette(in: .light))
        XCTAssertFalse(ParticleSurfaceStyle.automatic.usesLightPalette(in: .dark))
        XCTAssertFalse(ParticleSurfaceStyle.dark.usesLightPalette(in: .light))
        XCTAssertTrue(ParticleSurfaceStyle.light.usesLightPalette(in: .dark))
    }

    func testParticleProgressBindingInitializerRemainsSourceCompatible() {
        let view = ParticleProgressView(
            progress: .constant(0.5),
            surfaceStyle: .light,
            labelColor: .black
        )

        _ = view
    }

    func testStaticDemoCloudUsesOnDemandDrawingForReduceMotion() {
        XCTAssertFalse(
            PointCloudMetalView.shouldRenderContinuously(
                source: .demo,
                isActive: true,
                reduceMotion: true
            )
        )
        XCTAssertTrue(
            PointCloudMetalView.shouldRenderContinuously(
                source: .live,
                isActive: true,
                reduceMotion: true
            )
        )
        XCTAssertTrue(
            PointCloudMetalView.shouldRequestOnDemandDraw(
                source: .demo,
                isActive: false,
                reduceMotion: false
            )
        )
    }

    func testCameraTaskIdentityChangesWithDisplayMode() {
        let demo = CameraTaskKey(mode: .demo, phase: .active, isActive: true)
        let live = CameraTaskKey(mode: .live, phase: .active, isActive: true)

        XCTAssertNotEqual(demo, live)
    }

    func testCameraTaskIdentityChangesWhenCaptureResumes() {
        let paused = CameraTaskKey(mode: .live, phase: .active, isActive: false)
        let resumed = CameraTaskKey(mode: .live, phase: .active, isActive: true)

        XCTAssertNotEqual(paused, resumed)
    }

    func testDemoSourceDoesNotRequireCoreVideoTextureCache() {
        XCTAssertFalse(PointCloudRenderer.requiresTextureCache(for: .demo))
        XCTAssertTrue(PointCloudRenderer.requiresTextureCache(for: .live))
    }

    func testLiveSessionRequestsRawAndSmoothedDepthWhenAvailable() {
        XCTAssertEqual(
            PointCloudRenderer.frameSemantics(supportsCombinedDepth: true),
            [.sceneDepth, .smoothedSceneDepth]
        )
        XCTAssertEqual(
            PointCloudRenderer.frameSemantics(supportsCombinedDepth: false),
            .sceneDepth
        )
    }

    func testParticleSeedMatchesStructuredRingDefaults() {
        XCTAssertEqual(ParticleLoaderRenderer.initialRadiusFraction, 0.40)
        XCTAssertEqual(ParticleLoaderRenderer.particleSizeRange.lowerBound, 2.5)
        XCTAssertEqual(ParticleLoaderRenderer.particleSizeRange.upperBound, 5)
    }

    func testParticlesSeedExactlyOnTheirTargetRing() {
        let size = CGSize(width: 320, height: 400)
        let particles = ParticleLoaderRenderer.makeSeedParticles(
            particleCount: 64,
            size: size
        )
        let centre = SIMD2<Float>(160, 200)
        let expectedRadius: Float = 320 * ParticleLoaderRenderer.initialRadiusFraction

        XCTAssertEqual(particles.count, 64)
        for particle in particles {
            XCTAssertEqual(simd_distance(particle.position, centre), expectedRadius, accuracy: 1e-4)
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
            position: SIMD2(160, 160),
            velocity: .zero,
            phase: 0,
            variation: 0,
            size: 4,
            energy: 0.5
        )
        var uniforms = LoaderUniforms()
        uniforms.resolution = SIMD2(320, 320)
        uniforms.motionScale = 1

        uniforms.progress = 0
        XCTAssertEqual(try updateParticle(particle, uniforms: uniforms).energy, 0)

        uniforms.progress = 1
        XCTAssertEqual(try updateParticle(particle, uniforms: uniforms).energy, 1)
    }

    func testReduceMotionClearsParticleVelocityAndProducesStaticTarget() throws {
        let particle = LoaderParticle(
            position: SIMD2(30, 40),
            velocity: SIMD2(500, -300),
            phase: 0.7,
            variation: 0.3,
            size: 4,
            energy: 0
        )
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
