//
//  GPUDataLayoutTests.swift
//  MetalVisualKitTests
//
//  Verifies Swift memory layouts mirrored by Metal shader structures.
//

import XCTest
import simd

@testable import MetalVisualKit

final class GPUDataLayoutTests: XCTestCase {

    func testLoaderUniformsStride() {
        XCTAssertEqual(MemoryLayout<LoaderUniforms>.stride, 48)

        XCTAssertEqual(MemoryLayout<LoaderUniforms>.alignment, 8)
    }

    func testLoaderParticleStride() {
        XCTAssertEqual(MemoryLayout<LoaderParticle>.stride, 32)

        XCTAssertEqual(MemoryLayout<LoaderParticle>.alignment, 8)
    }

    func testCloudUniformsStride() {
        XCTAssertEqual(MemoryLayout<CloudUniforms>.stride, 208)

        XCTAssertEqual(MemoryLayout<CloudUniforms>.alignment, 16)
    }

    func testDemoUniformsStride() {
        XCTAssertEqual(MemoryLayout<DemoUniforms>.stride, 96)

        XCTAssertEqual(MemoryLayout<DemoUniforms>.alignment, 16)
    }

    func testSIMDPrimitivesMatchMetalLayout() {
        XCTAssertEqual(MemoryLayout<SIMD2<Float>>.stride, 8)

        XCTAssertEqual(MemoryLayout<SIMD3<Float>>.stride, 16)

        XCTAssertEqual(MemoryLayout<simd_float3x3>.stride, 48)

        XCTAssertEqual(MemoryLayout<simd_float4x4>.stride, 64)
    }
}
