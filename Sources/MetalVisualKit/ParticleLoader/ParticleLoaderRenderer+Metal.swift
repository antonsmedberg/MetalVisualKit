//
//  ParticleLoaderRenderer+Metal.swift
//  MetalVisualKit
//
//  Metal device, MTKView and render-pipeline configuration for the particle
//  loader.
//

import Metal
import MetalKit

private enum ParticleBlendMode {
    case additive
    case sourceOver

    var label: String {
        switch self {
        case .additive: return "MetalVisualKit.ParticleLoader"

        case .sourceOver: return "MetalVisualKit.ParticleLoader.LightSurface"
        }
    }

    var destinationRGBBlendFactor: MTLBlendFactor {
        switch self {
        case .additive: return .one

        case .sourceOver: return .oneMinusSourceAlpha
        }
    }

    var destinationAlphaBlendFactor: MTLBlendFactor {
        switch self {
        case .additive: return .one

        case .sourceOver: return .oneMinusSourceAlpha
        }
    }
}

extension ParticleLoaderRenderer {

    // MARK: - Device

    static func resolveDevice(for view: MTKView) throws -> MTLDevice {
        if let device = view.device { return device }

        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalVisualError.noMetalDevice }

        return device
    }

    // MARK: - View Configuration

    static func configure(_ view: MTKView, device: MTLDevice) {
        view.device = device
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
    }

    // MARK: - Pipelines

    static func makeRenderPipelines(
        device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat
    ) throws -> (additive: MTLRenderPipelineState, sourceOver: MTLRenderPipelineState) {
        let vertexFunction = try ShaderLibrary.function(Function.vertex, in: library)

        let fragmentFunction = try ShaderLibrary.function(Function.fragment, in: library)

        let additiveDescriptor = makeRenderDescriptor(
            vertexFunction: vertexFunction, fragmentFunction: fragmentFunction, colorPixelFormat: colorPixelFormat,
            blendMode: .additive)

        let sourceOverDescriptor = makeRenderDescriptor(
            vertexFunction: vertexFunction, fragmentFunction: fragmentFunction, colorPixelFormat: colorPixelFormat,
            blendMode: .sourceOver)

        return (
            additive: try device.makeRenderPipelineState(descriptor: additiveDescriptor),
            sourceOver: try device.makeRenderPipelineState(descriptor: sourceOverDescriptor)
        )
    }

    private static func makeRenderDescriptor(
        vertexFunction: MTLFunction, fragmentFunction: MTLFunction, colorPixelFormat: MTLPixelFormat,
        blendMode: ParticleBlendMode
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()

        descriptor.label = blendMode.label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        let attachment = descriptor.colorAttachments[0]

        attachment?.pixelFormat = colorPixelFormat
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.destinationRGBBlendFactor = blendMode.destinationRGBBlendFactor
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationAlphaBlendFactor = blendMode.destinationAlphaBlendFactor

        return descriptor
    }
}
