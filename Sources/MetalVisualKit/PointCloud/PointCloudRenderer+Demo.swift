//
//  PointCloudRenderer+Demo.swift
//  MetalVisualKit
//
//  Builds the camera and uniforms for the procedural cloud used in previews
//  and on devices without LiDAR.
//

import Metal
import simd

extension PointCloudRenderer {
    func encodeDemo(encoder: MTLRenderCommandEncoder, time: Float) {
        let camera = makeDemoCamera()

        var uniforms = DemoUniforms()
        uniforms.viewProjection = camera.projection * camera.view
        uniforms.cameraPosition = camera.eye
        uniforms.time = time
        uniforms.pointCount = Float(demoPointCount)
        uniforms.pointSize = demoSpriteSize * camera.distance
        uniforms.motionScale = motionScale

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DemoUniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: demoPointCount)
    }

    private func makeDemoCamera() -> PointCloudDemoCamera {
        let aspect = Float(max(viewportSize.width, 1) / max(viewportSize.height, 1))

        let fieldOfView: Float = .pi / 3.2

        let projection = Self.perspective(fovY: fieldOfView, aspect: aspect, near: 0.05, far: 50)

        let distance =
            Self.demoCameraDistance(aspect: aspect, fovY: fieldOfView, sphereRadius: 1.15, margin: 1.30) * demoZoom

        let cosElevation = cos(demoOrbit.elevation)

        let eye = SIMD3<Float>(
            sin(demoOrbit.azimuth) * cosElevation * distance, sin(demoOrbit.elevation) * distance,
            cos(demoOrbit.azimuth) * cosElevation * distance)

        let view = Self.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))

        return PointCloudDemoCamera(projection: projection, view: view, eye: eye, distance: distance)
    }

    private var demoSpriteSize: Float {
        Self.drawablePointSize(demoPointSize, drawableSize: viewportSize, viewportPointSize: viewportPointSize)
    }
}

private struct PointCloudDemoCamera {
    let projection: simd_float4x4
    let view: simd_float4x4
    let eye: SIMD3<Float>
    let distance: Float
}
