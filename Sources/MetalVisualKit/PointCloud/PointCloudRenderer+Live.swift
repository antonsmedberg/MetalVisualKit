//
//  PointCloudRenderer+Live.swift
//  MetalVisualKit
//
//  Prepares ARKit scene-depth frames and binds the textures used by the live
//  point-cloud pipeline.
//

import ARKit
import CoreVideo
import Metal
import UIKit

struct PointCloudLiveFrame {
    let timestamp: TimeInterval
    let uniforms: CloudUniforms
    let depthTexture: MTLTexture
    let confidenceTexture: MTLTexture
    let cameraLumaTexture: MTLTexture?
    let cameraChromaTexture: MTLTexture?
    let vertexCount: Int
    let retainedTextures: [CVMetalTexture]
}

extension PointCloudRenderer {
    func prepareSignpostedLiveFrame() -> PointCloudLiveFrame? {
        let signpost = MetalVisualLog.signposter.beginInterval("AR frame preparation")

        defer { MetalVisualLog.signposter.endInterval("AR frame preparation", signpost) }

        return prepareLiveFrame()
    }

    private func prepareLiveFrame() -> PointCloudLiveFrame? {
        guard let textures, let frame = session?.currentFrame,
            let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        else { return nil }

        // MTKView often ticks faster than ARKit produces depth frames.
        guard frame.timestamp != lastRenderedFrameTimestamp else { return nil }

        guard let depthBinding = textures.depth(from: depthData) else { return nil }

        guard let confidence = textures.confidence(from: depthData, matching: depthBinding.texture) else { return nil }

        let cameraBinding = makeCameraBinding(frame: frame, textures: textures)

        var retainedTextures = [depthBinding.cvTexture]

        if let retainedTexture = confidence.retainedTexture { retainedTextures.append(retainedTexture) }

        retainedTextures.append(contentsOf: cameraBinding.retainedTextures)

        let uniforms = makeLiveUniforms(
            camera: frame.camera, depthTexture: depthBinding.texture, colorMode: cameraBinding.colorMode,
            orientation: interfaceOrientation)

        return PointCloudLiveFrame(
            timestamp: frame.timestamp, uniforms: uniforms, depthTexture: depthBinding.texture,
            confidenceTexture: confidence.texture, cameraLumaTexture: cameraBinding.image?.luma.texture,
            cameraChromaTexture: cameraBinding.image?.chroma.texture,
            vertexCount: depthBinding.texture.width * depthBinding.texture.height, retainedTextures: retainedTextures)
    }

    private func makeCameraBinding(frame: ARFrame, textures: ARFrameTextures) -> PointCloudCameraBinding {
        guard colorMode == .camera else {
            return PointCloudCameraBinding(image: nil, colorMode: colorMode, retainedTextures: [])
        }

        guard let image = textures.cameraImage(frame.capturedImage) else {
            return PointCloudCameraBinding(image: nil, colorMode: .depth, retainedTextures: [])
        }

        return PointCloudCameraBinding(image: image, colorMode: .camera, retainedTextures: image.retainedTextures)
    }

    private func makeLiveUniforms(
        camera: ARCamera, depthTexture: MTLTexture, colorMode: PointCloudColorMode, orientation: UIInterfaceOrientation
    ) -> CloudUniforms {
        let viewMatrix = camera.viewMatrix(for: orientation)

        let projection = camera.projectionMatrix(
            for: orientation, viewportSize: projectionViewportSize, zNear: 0.05, zFar: 20)

        var uniforms = CloudUniforms()

        uniforms.viewProjection = projection * viewMatrix
        uniforms.localToWorld = Self.localToWorld(viewMatrix: viewMatrix, orientation: orientation)
        uniforms.intrinsicsInv = camera.intrinsics.inverse
        uniforms.cameraResolution = SIMD2(Float(camera.imageResolution.width), Float(camera.imageResolution.height))
        uniforms.gridResolution = SIMD2(Float(depthTexture.width), Float(depthTexture.height))
        uniforms.pointSize = Self.drawablePointSize(
            livePointSize, drawableSize: viewportSize, viewportPointSize: viewportPointSize)
        uniforms.maxDepth = maxDepth
        uniforms.minConfidence = minimumConfidence.rawValue
        uniforms.colorMode = colorMode.shaderValue

        return uniforms
    }

    private var projectionViewportSize: CGSize { viewportPointSize == .zero ? viewportSize : viewportPointSize }

    func encodeLive(encoder: MTLRenderCommandEncoder, frame: PointCloudLiveFrame) {
        let signpost = MetalVisualLog.signposter.beginInterval("Point cloud render encode")

        defer { MetalVisualLog.signposter.endInterval("Point cloud render encode", signpost) }

        var uniforms = frame.uniforms

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        encoder.setVertexTexture(frame.depthTexture, index: 0)
        encoder.setVertexTexture(frame.confidenceTexture, index: 1)

        // Camera textures stay unbound when the frame uses the depth palette.
        encoder.setVertexTexture(frame.cameraLumaTexture, index: 2)
        encoder.setVertexTexture(frame.cameraChromaTexture, index: 3)

        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.vertexCount)
    }
}

private struct PointCloudCameraBinding {
    let image: CameraImageBinding?
    let colorMode: PointCloudColorMode
    let retainedTextures: [CVMetalTexture]
}
