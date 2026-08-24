//
//  SpatialScanTab.swift
//  MetalVisualKitDemo
//
//  The demo owns presentation and capture intent. MetalVisualKit owns ARKit,
//  Metal rendering and sensor state.
//

import MetalVisualKit
import SwiftUI

struct SpatialScanTab: View {
    @State private var captureMode:
    SpatialCaptureMode = .idle

    @State private var pointCloudPhase:
    LiDARPointCloudPhase = .idle

    @State private var colorMode:
    PointCloudColorMode = .camera

    @State private var confidenceFloor:
    PointCloudConfidenceFloor = .balanced

    @State private var maxDepth: Float = 5

    @State private var showsInfo = false

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @Environment(\.verticalSizeClass)
    private var verticalSizeClass

    private var isCapturing: Bool {
        captureMode == .live
    }

    private var status: SpatialScanStatus {
        if captureMode == .paused {
            return SpatialScanStatus(
                title: "Paused",
                symbol: "pause.fill"
            )
        }

        return SpatialScanStatus(
            title: pointCloudPhase.title,
            symbol:
                pointCloudPhase.symbolName
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                content(
                    heroHeight:
                        heroHeight(
                            for: geometry.size
                        )
                )
            }
            .toolbar {
                ToolbarItem(
                    placement: .principal
                ) {
                    Text("Spatial Scan")
                        .font(
                            .headline
                                .weight(.semibold)
                        )
                }

                ToolbarItem(
                    placement: .topBarTrailing
                ) {
                    Button {
                        showsInfo = true
                    } label: {
                        Image(
                            systemName:
                                "info.circle"
                        )
                    }
                    .accessibilityLabel(
                        "About Spatial Scan"
                    )
                }
            }
            .sheet(
                isPresented: $showsInfo
            ) {
                SpatialScanInfoView()
                    .presentationDetents(
                        [.medium]
                    )
            }
        }
    }

    private func content(
        heroHeight: CGFloat
    ) -> some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            renderer(
                heroHeight: heroHeight
            )
        }
        .overlay(alignment: .top) {
            if captureMode == .idle {
                VStack(
                    spacing:
                        verticalSizeClass
                    == .compact
                    ? 12
                    : 22
                ) {
                    SpatialScanIntro()

                    SpatialScanControlDeck(
                        mode: .idle,
                        colorMode: $colorMode,
                        confidenceFloor:
                            $confidenceFloor,
                        maxDepth: $maxDepth,
                        onStart: startCapture,
                        onPause: {},
                        onResume: {},
                        onEnd: {}
                    )
                }
                .padding(
                    .top,
                    heroHeight
                    + (
                        verticalSizeClass
                        == .compact
                        ? 8
                        : 18
                    )
                )
                .transition(.opacity)
            }
        }
        .safeAreaInset(
            edge: .top,
            spacing: 6
        ) {
            HStack {
                Spacer()

                SpatialStatusChip(
                    status: status
                )
            }
            .padding(.horizontal, 20)
        }
        .safeAreaInset(
            edge: .bottom,
            spacing: 20
        ) {
            if captureMode != .idle {
                SpatialScanControlDeck(
                    mode: captureMode,
                    colorMode: $colorMode,
                    confidenceFloor:
                        $confidenceFloor,
                    maxDepth: $maxDepth,
                    onStart: startCapture,
                    onPause: pauseCapture,
                    onResume: resumeCapture,
                    onEnd: endCapture
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .animation(
            reduceMotion
            ? nil
            : .smooth(duration: 0.28),
            value: captureMode
        )
    }

    @ViewBuilder
    private func renderer(
        heroHeight: CGFloat
    ) -> some View {
        if captureMode == .idle {
            pointCloud
                .frame(
                    maxWidth: .infinity
                )
                .frame(
                    height: heroHeight
                )
                .frame(
                    maxHeight: .infinity,
                    alignment: .top
                )
                .padding(.top, 4)
                .clipped()
        } else {
            pointCloud
                .ignoresSafeArea(
                    edges: [
                        .top,
                        .horizontal
                    ]
                )
        }
    }

    private var pointCloud: some View {
        LiDARPointCloudView(
            displayMode:
                captureMode == .idle
            ? .demo
            : .live,

            colorMode:
                $colorMode,

            minimumConfidence:
                $confidenceFloor,

            maxDepth:
                $maxDepth,

            showsControls: false,

            allowsOrbitInteraction:
                captureMode == .idle,

            isActive:
                isCapturing,

            onPhaseChange:
                handlePhaseChange
        )
    }

    private func heroHeight(
        for size: CGSize
    ) -> CGFloat {
        if verticalSizeClass == .compact {
            return min(
                max(
                    size.height * 0.42,
                    145
                ),
                185
            )
        }

        return min(
            max(
                size.height * 0.34,
                225
            ),
            285
        )
    }

    private func handlePhaseChange(
        _ phase: LiDARPointCloudPhase
    ) {
        pointCloudPhase = phase
    }

    private func startCapture() {
        captureMode = .live
    }

    private func pauseCapture() {
        captureMode = .paused
    }

    private func resumeCapture() {
        captureMode = .live
    }

    private func endCapture() {
        captureMode = .idle
        pointCloudPhase = .idle
    }
}

#Preview("Spatial Scan") {
    SpatialScanTab()
        .preferredColorScheme(.dark)
}
