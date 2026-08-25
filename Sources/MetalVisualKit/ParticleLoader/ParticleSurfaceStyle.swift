//
//  ParticleSurfaceStyle.swift
//  MetalVisualKit
//
//  Surface-aware palette selection for particle progress indicators.
//

import SwiftUI

public enum ParticleSurfaceStyle: Sendable {
    case automatic
    case dark
    case light

    func usesLightPalette(in colourScheme: ColorScheme) -> Bool {
        switch self {
        case .automatic: return colourScheme == .light

        case .dark: return false

        case .light: return true
        }
    }
}
