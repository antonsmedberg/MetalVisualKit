//
//  ARFrameTextures.swift
//  MetalVisualKit
//
//  Turns the Core Video buffers hanging off an ARFrame into Metal textures.
//
//  Three buffers, three shapes:
//
//    depthMap       256x192   r32Float   non-planar
//    confidenceMap  256x192   r8Uint     non-planar
//    capturedImage  1920x1440 bi-planar  plane 0 luma r8Unorm,
//                                        plane 1 chroma rg8Unorm at half size
//
//  The plane accessors return 0 for a non-planar buffer, so plane index and
//  planarity have to be handled together rather than assumed. Getting that wrong
//  produces a zero-sized texture request and a frame that silently never draws.
//

import ARKit
import CoreVideo
import Metal

// MARK: - Bindings

/// A Metal texture together with the Core Video wrapper that owns its backing
/// IOSurface.
///
/// The wrapper must stay alive while Metal reads that surface, which is why it
/// travels with the texture instead of being discarded at the call site.
struct TextureBinding {
    let cvTexture: CVMetalTexture
    let texture: MTLTexture
}

/// The camera image as the two planes Metal can read.
struct CameraImageBinding {
    let luma: TextureBinding
    let chroma: TextureBinding

    var retainedTextures: [CVMetalTexture] { [luma.cvTexture, chroma.cvTexture] }
}

/// Confidence input paired with the wrapper that must outlive the render pass.
/// The fallback texture is owned by ``ARFrameTextures``, so it has nothing to
/// retain per frame.
struct ConfidenceBinding {
    let texture: MTLTexture
    let retainedTexture: CVMetalTexture?
}

// MARK: - Texture source

/// Owns the Core Video texture cache and every conversion from an ARKit pixel
/// buffer to an `MTLTexture`.
final class ARFrameTextures {

    /// ARKit documents `capturedImage` as full-range bi-planar YCbCr. Any other
    /// format would need a different conversion matrix in the shader, so it is
    /// rejected rather than reinterpreted.
    static let cameraPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    private let device: MTLDevice
    private let cache: CVMetalTextureCache
    private var cachedFallbackConfidence: MTLTexture?

    init(device: MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw MetalVisualError.textureCacheUnavailable(status: status)
        }
        self.device = device
        self.cache = cache
    }

    /// Drops cached texture mappings Core Video no longer needs.
    ///
    /// ARKit recycles a small pool of pixel buffers, and the cache keeps one
    /// mapping per buffer it has seen. Without a periodic flush those mappings
    /// accumulate for the lifetime of the session. Call this once per frame,
    /// after the command buffer is committed.
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }

    // MARK: Depth and confidence

    func depth(from depthData: ARDepthData) -> TextureBinding? {
        guard metalFormat(for: depthData.depthMap) == .r32Float else {
            MetalVisualLog.renderer.error("Unsupported depth pixel format; frame skipped.")
            return nil
        }
        return makeBinding(depthData.depthMap, format: .r32Float, planeIndex: 0)
    }

    func confidence(
        from depthData: ARDepthData,
        matching depthTexture: MTLTexture
    ) -> ConfidenceBinding? {
        guard let confidenceMap = depthData.confidenceMap else {
            guard let fallback = fallbackConfidenceTexture(
                width: depthTexture.width,
                height: depthTexture.height
            ) else { return nil }
            return ConfidenceBinding(texture: fallback, retainedTexture: nil)
        }

        guard metalFormat(for: confidenceMap) == .r8Uint,
              let binding = makeBinding(confidenceMap, format: .r8Uint, planeIndex: 0)
        else {
            MetalVisualLog.renderer.error("Unsupported confidence format; frame skipped.")
            return nil
        }
        guard binding.texture.width == depthTexture.width,
              binding.texture.height == depthTexture.height
        else {
            MetalVisualLog.renderer.error("Depth and confidence dimensions disagree.")
            return nil
        }
        return ConfidenceBinding(texture: binding.texture, retainedTexture: binding.cvTexture)
    }

    // MARK: Camera image

    /// Splits `ARFrame.capturedImage` into luma and chroma textures.
    ///
    /// Returns nil rather than throwing: a frame whose camera image cannot be
    /// bound is still a perfectly good depth frame, so the renderer falls back
    /// to the depth palette instead of dropping it.
    func cameraImage(_ pixelBuffer: CVPixelBuffer) -> CameraImageBinding? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == Self.cameraPixelFormat,
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 2
        else {
            MetalVisualLog.renderer.error("Camera image is not full-range bi-planar YCbCr.")
            return nil
        }
        guard let luma = makeBinding(pixelBuffer, format: .r8Unorm, planeIndex: 0),
              let chroma = makeBinding(pixelBuffer, format: .rg8Unorm, planeIndex: 1)
        else { return nil }
        return CameraImageBinding(luma: luma, chroma: chroma)
    }

    // MARK: Conversion

    private func makeBinding(
        _ pixelBuffer: CVPixelBuffer,
        format: MTLPixelFormat,
        planeIndex: Int
    ) -> TextureBinding? {
        let size = Self.size(of: pixelBuffer, planeIndex: planeIndex)
        guard size.width > 0, size.height > 0 else {
            MetalVisualLog.renderer.error("Pixel buffer plane \(planeIndex) has no size.")
            return nil
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, format,
            size.width, size.height, planeIndex, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            MetalVisualLog.renderer.error(
                "Texture creation failed for plane \(planeIndex) (CVReturn \(status))."
            )
            return nil
        }
        return TextureBinding(cvTexture: cvTexture, texture: texture)
    }

    /// Size of one plane, or of the whole buffer when it is not planar.
    ///
    /// `CVPixelBufferGetWidthOfPlane` is documented to return 0 for a non-planar
    /// buffer, which the depth and confidence maps are.
    static func size(of pixelBuffer: CVPixelBuffer, planeIndex: Int) -> (width: Int, height: Int) {
        guard CVPixelBufferIsPlanar(pixelBuffer) else {
            return (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        }
        return (
            CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        )
    }

    /// Metal format for a Core Video buffer, or nil if ARKit handed us something
    /// this renderer does not know how to interpret. Guessing here would mean
    /// reinterpreting bytes and rendering plausible garbage.
    func metalFormat(for pixelBuffer: CVPixelBuffer) -> MTLPixelFormat? {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_OneComponent32Float:
            return .r32Float
        case kCVPixelFormatType_OneComponent8:
            return .r8Uint
        default:
            return nil
        }
    }

    /// Stand-in confidence texture for the case `confidenceMap` documents, where
    /// ARKit supplies depth without confidence. Every texel reads as high, so
    /// depth still renders instead of the view going blank.
    private func fallbackConfidenceTexture(width: Int, height: Int) -> MTLTexture? {
        if let cached = cachedFallbackConfidence,
           cached.width == width, cached.height == height {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytes = [UInt8](repeating: 2, count: width * height)   // ARConfidenceLevel.high
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: width
            )
        }
        cachedFallbackConfidence = texture
        return texture
    }
}
