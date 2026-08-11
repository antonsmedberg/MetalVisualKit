//
//  MetalVisualError.swift
//  MetalVisualKit
//

import CoreVideo
import Foundation
import os

/// Failures that can occur while standing up a renderer.
///
/// These are surfaced rather than silently swallowed: a component that renders
/// nothing and logs nothing is the hardest kind of graphics bug to diagnose.
enum MetalVisualError: Swift.Error, CustomStringConvertible {
    case noMetalDevice
    case commandQueueUnavailable
    case depthStateUnavailable
    case textureCacheUnavailable(status: CVReturn)

    var description: String {
        switch self {
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
    static let renderer = Logger(subsystem: "eu.smedberg.MetalVisualKit", category: "renderer")
}
