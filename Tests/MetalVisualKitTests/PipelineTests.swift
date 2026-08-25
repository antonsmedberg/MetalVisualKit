//
//  PipelineTests.swift
//  MetalVisualKitTests
//
//  Shader-library and Metal pipeline validation.
//

import Metal
import XCTest

@testable import MetalVisualKit

final class PipelineTests: XCTestCase {

    private func requireDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host.")
        }

        return device
    }

    private func requireLibrary() throws -> (device: MTLDevice, library: MTLLibrary) {
        let device = try requireDevice()

        let library = try ShaderLibrary.make(device: device)

        return (device, library)
    }

    func testPackagedMetallibLoads() throws {
        let library = try requireLibrary().library

        XCTAssertFalse(library.functionNames.isEmpty, "default.metallib contains no functions.")
    }

    func testAllExpectedShaderFunctionsExist() throws {
        let library = try requireLibrary().library

        let expected = [
            ParticleLoaderRenderer.Function.update, ParticleLoaderRenderer.Function.vertex,
            ParticleLoaderRenderer.Function.fragment, PointCloudRenderer.Function.liveVertex,
            PointCloudRenderer.Function.demoVertex, PointCloudRenderer.Function.fragment
        ]

        for name in expected {
            XCTAssertNoThrow(try ShaderLibrary.function(name, in: library), "Missing shader function '\(name)'.")
        }
    }

    func testMissingFunctionThrowsDescriptiveError() throws {
        let library = try requireLibrary().library

        XCTAssertThrowsError(try ShaderLibrary.function("noSuchFunction", in: library)) { error in
            XCTAssertTrue(String(describing: error).contains("noSuchFunction"))
        }
    }

    func testParticleComputePipelineCompiles() throws {
        let context = try requireLibrary()

        let function = try ShaderLibrary.function(ParticleLoaderRenderer.Function.update, in: context.library)

        XCTAssertNoThrow(try context.device.makeComputePipelineState(function: function))
    }

    func testParticleRenderPipelineCompiles() throws {
        let context = try requireLibrary()

        let descriptor = MTLRenderPipelineDescriptor()

        descriptor.vertexFunction = try ShaderLibrary.function(
            ParticleLoaderRenderer.Function.vertex, in: context.library)

        descriptor.fragmentFunction = try ShaderLibrary.function(
            ParticleLoaderRenderer.Function.fragment, in: context.library)

        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        XCTAssertNoThrow(try context.device.makeRenderPipelineState(descriptor: descriptor))
    }

    func testPointCloudPipelinesCompile() throws {
        let context = try requireLibrary()

        let vertices = [PointCloudRenderer.Function.liveVertex, PointCloudRenderer.Function.demoVertex]

        for vertexName in vertices {
            let descriptor = MTLRenderPipelineDescriptor()

            descriptor.vertexFunction = try ShaderLibrary.function(vertexName, in: context.library)

            descriptor.fragmentFunction = try ShaderLibrary.function(
                PointCloudRenderer.Function.fragment, in: context.library)

            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            descriptor.depthAttachmentPixelFormat = .depth32Float

            XCTAssertNoThrow(
                try context.device.makeRenderPipelineState(descriptor: descriptor), "Pipeline '\(vertexName)' failed.")
        }
    }
}
