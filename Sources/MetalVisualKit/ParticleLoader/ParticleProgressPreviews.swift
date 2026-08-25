//
//  ParticleProgressPreviews.swift
//  MetalVisualKit
//

import SwiftUI

#Preview("Particle progress") {
    ParticleProgressView(progress: 0.68, title: "Exporting").frame(width: 320, height: 320).preferredColorScheme(.dark)
}

#Preview("Particle spinner") { ParticleSpinnerView().frame(width: 280, height: 280).preferredColorScheme(.dark) }
