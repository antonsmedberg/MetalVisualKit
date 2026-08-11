//
//  PipelineTests.swift
//  MetalVisualKitTests
//
//  These verify the things that actually break in a Swift + Metal package: the
//  packaged metallib resolving, every shader function existing under the name
//  the Swift side asks for, pipeline states compiling, and — the one most likely
//  to catch a real regression — the hand-mirrored uniform struct layouts staying
//  in sync between Swift and MSL.
//
//  GPU output is not asserted. Rendering correctness is judged on device, and a
//  suite that pretends otherwise is worse than an honest small one.
//

import Metal
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
        // 2 × float2 (16) + 6 × float (24) = 40
        XCTAssertEqual(MemoryLayout<LoaderUniforms>.stride, 40)
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
        // float4x4 (64) + 4 × float (16) = 80
        XCTAssertEqual(MemoryLayout<DemoUniforms>.stride, 80)
        XCTAssertEqual(MemoryLayout<DemoUniforms>.alignment, 16)
    }

    func testSIMDPrimitivesMatchMSLExpectations() {
        // If any of these ever changes, every stride above is wrong too.
        XCTAssertEqual(MemoryLayout<SIMD2<Float>>.stride, 8)
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
}
