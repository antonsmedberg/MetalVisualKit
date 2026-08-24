//
//  SpatialScanInfoView.swift
//  MetalVisualKitDemo
//

import SwiftUI

struct SpatialScanInfoView: View {
    var body: some View {
        NavigationStack {
            List {
                Label(
                    "LiDAR measures distance and creates the 3D points.",
                    systemImage:
                        "sensor.tag.radiowaves.forward"
                )

                Label(
                    "The rear camera supplies colour for those LiDAR points.",
                    systemImage:
                        "camera.fill"
                )

                Label(
                    "Depth and Confidence are diagnostic views of the same geometry.",
                    systemImage:
                        "ruler"
                )
            }
            .navigationTitle(
                "Camera + LiDAR"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
        }
    }
}
