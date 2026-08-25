//
//  PointCloudRenderer+Metal.swift
//  MetalVisualKit
//
//  Metal device, MTKView and pipeline configuration for PointCloudRenderer.
//

import Metal
import MetalKit

extension PointCloudRenderer {

    // MARK: - Device

    static func resolveDevice(for view: MTKView) throws -> MTLDevice {
        if let device = view.device { return device }

        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalVisualError.noMetalDevice }

        return device
    }

    // MARK: - Source

    static func resolvedSource(_ source: PointCloudSource) -> PointCloudSource {
        guard source == .live else { return .demo }

        return isLiDARAvailable ? .live : .demo
    }

    // MARK: - View Configuration

    static func configure(_ view: MTKView, device: MTLDevice, source: PointCloudSource) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = clearColor(for: source)
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
    }

    private static func clearColor(for source: PointCloudSource) -> MTLClearColor {
        switch source {
        case .demo: return MTLClearColor(red: 0.005, green: 0.007, blue: 0.014, alpha: 1)

        case .live: return MTLClearColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)
        }
    }

    // MARK: - Render Pipeline

    static func makePipeline(
        device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat,
        depthStencilPixelFormat: MTLPixelFormat, source: PointCloudSource
    ) throws -> MTLRenderPipelineState {
        let vertexName = source == .live ? Function.liveVertex : Function.demoVertex

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MetalVisualKit.PointCloud"

        descriptor.vertexFunction = try ShaderLibrary.function(vertexName, in: library)

        descriptor.fragmentFunction = try ShaderLibrary.function(Function.fragment, in: library)

        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        descriptor.depthAttachmentPixelFormat = depthStencilPixelFormat

        configureBlending(descriptor.colorAttachments[0])

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func configureBlending(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add

        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    // MARK: - Depth State

    static func makeDepthState(device: MTLDevice) throws -> MTLDepthStencilState {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true

        guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
            throw MetalVisualError.depthStateUnavailable
        }

        return state
    }
}
