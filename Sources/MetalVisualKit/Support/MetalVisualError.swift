//
//  MetalVisualError.swift
//  MetalVisualKit
//

import CoreVideo
import Foundation
import os

/// Failures that can occur while standing up a renderer.
enum MetalVisualError: Swift.Error, CustomStringConvertible {
    case invalidParticleCount(Int)
    case particleCountTooLarge(Int)
    case particleBufferUnavailable
    case noMetalDevice
    case commandQueueUnavailable
    case depthStateUnavailable
    case textureCacheUnavailable(status: CVReturn)

    var description: String {
        switch self {
        case .invalidParticleCount(let count):
            return "Particle count must be positive (received \(count))."
        case .particleCountTooLarge(let count):
            return "Particle count is too large to allocate safely (received \(count))."
        case .particleBufferUnavailable:
            return "The Metal device could not allocate the particle buffer."
        case .noMetalDevice:
            return "No Metal device is available on this host."
        case .commandQueueUnavailable:
            return "The Metal device refused to create a command queue."
        case .depthStateUnavailable:
            return "The Metal device refused to create a depth stencil state."
        case .textureCacheUnavailable(let status):
            return "Core Video refused to create a Metal texture cache (CVReturn \(status))."
        }
    }
}

/// Subsystem logger. Filter in Console.app with `subsystem:eu.smedberg.MetalVisualKit`.
enum MetalVisualLog {
    static let subsystem = "eu.smedberg.MetalVisualKit"
    static let renderer = Logger(subsystem: subsystem, category: "renderer")
    static let signposter = OSSignposter(subsystem: subsystem, category: "rendering")
}
