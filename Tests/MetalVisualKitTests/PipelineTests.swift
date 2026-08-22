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

    // MARK: - Projection helpers
    //
    // Metal clip space runs z ∈ [0, 1], unlike OpenGL's [-1, 1]. Getting this
    // wrong makes the whole cloud vanish, so it is worth pinning.

    func testPerspectiveMapsNearPlaneToZeroDepth() {
        let projection = PointCloudRenderer.perspective(
            fovY: .pi / 3, aspect: 1, near: 0.1, far: 100
        )
        let nearPoint = projection * SIMD4<Float>(0, 0, -0.1, 1)
        XCTAssertEqual(nearPoint.z / nearPoint.w, 0, accuracy: 1e-4)
    }

    func testPerspectiveMapsFarPlaneToOneDepth() {
        let projection = PointCloudRenderer.perspective(
            fovY: .pi / 3, aspect: 1, near: 0.1, far: 100
        )
        let farPoint = projection * SIMD4<Float>(0, 0, -100, 1)
        XCTAssertEqual(farPoint.z / farPoint.w, 1, accuracy: 1e-3)
    }

    func testRotateToARCameraIsOrthonormal() {
        // A non-orthonormal transform here would skew or scale the whole cloud.
        for orientation in [UIInterfaceOrientation.portrait, .landscapeLeft,
                            .landscapeRight, .portraitUpsideDown] {
            let matrix = PointCloudRenderer.rotateToARCamera(for: orientation)
            let upper = simd_float3x3(
                SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
            )
            XCTAssertEqual(abs(simd_determinant(upper)), 1, accuracy: 1e-5,
                           "Orientation \(orientation.rawValue) is not a rigid transform.")
        }
    }

    func testLookAtPlacesEyeAtOrigin() {
        let view = PointCloudRenderer.lookAt(
            eye: SIMD3(0, 0, 3), center: .zero, up: SIMD3(0, 1, 0)
        )
        let transformed = view * SIMD4<Float>(0, 0, 3, 1)
        let position = SIMD3(transformed.x, transformed.y, transformed.z)
        XCTAssertEqual(simd_length(position), 0, accuracy: 1e-5)
    }

    func testDemoCameraDistanceFitsTheNarrowerFieldOfView() {
        let fovY: Float = .pi / 3.2
        let radius: Float = 1.15
        let margin: Float = 1.18
        let portraitDistance = PointCloudRenderer.demoCameraDistance(
            aspect: 0.46,
            fovY: fovY,
            sphereRadius: radius,
            margin: margin
        )
        let landscapeDistance = PointCloudRenderer.demoCameraDistance(
            aspect: 2.17,
            fovY: fovY,
            sphereRadius: radius,
            margin: margin
        )
        let portraitHalfX = atan(tan(fovY * 0.5) * 0.46)

        XCTAssertGreaterThan(portraitDistance, landscapeDistance)
        XCTAssertGreaterThanOrEqual(
            portraitDistance * sin(portraitHalfX),
            radius * margin - 1e-5
        )
    }

    func testPointSizeConvertsFromLayoutPointsToDrawablePixels() {
        XCTAssertEqual(
            PointCloudRenderer.drawablePointSize(
                8,
                drawableSize: CGSize(width: 1_206, height: 2_622),
                viewportPointSize: CGSize(width: 402, height: 874)
            ),
            24,
            accuracy: 1e-5
        )
        XCTAssertEqual(
            PointCloudRenderer.drawablePointSize(
                8,
                drawableSize: .zero,
                viewportPointSize: .zero
            ),
            8
        )
    }

    func testConfidenceOpacityPreservesMediumConfidenceAsAVisualCue() {
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 0, minimum: 1), 0)
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 1, minimum: 1), 0.55)
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 2, minimum: 1), 1)
        XCTAssertEqual(PointCloudRenderer.confidenceOpacity(level: 2, minimum: 2), 1)
    }

    func testDemoOrbitRespondsToDragAndClampsElevation() {
        let initial = PointCloudRenderer.DemoOrbit(azimuth: 0, elevation: 0)
        let moved = PointCloudRenderer.updatedDemoOrbit(
            initial,
            translation: SIMD2<Float>(100, -10_000)
        )

        XCTAssertNotEqual(moved.azimuth, initial.azimuth)
        XCTAssertEqual(moved.elevation, PointCloudRenderer.demoElevationLimit, accuracy: 1e-5)
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
    }

    func testCameraTaskIdentityChangesWithDisplayMode() {
        let demo = CameraTaskKey(mode: .demo, phase: .active)
        let live = CameraTaskKey(mode: .live, phase: .active)

        XCTAssertNotEqual(demo, live)
    }

    func testDemoSourceDoesNotRequireCoreVideoTextureCache() {
        XCTAssertFalse(PointCloudRenderer.requiresTextureCache(for: .demo))
        XCTAssertTrue(PointCloudRenderer.requiresTextureCache(for: .live))
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
