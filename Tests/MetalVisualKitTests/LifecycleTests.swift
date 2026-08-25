//
//  LifecycleTests.swift
//  MetalVisualKitTests
//
//  Lifecycle, configuration and render-policy invariants.
//

import AVFoundation
import SwiftUI
import XCTest

@testable import MetalVisualKit

final class LifecycleTests: XCTestCase {

    // MARK: - Camera Access

    func testCameraAccessStateMapping() {
        XCTAssertEqual(
            CameraAccess.state(hasUsageDescription: false, authorizationStatus: .authorized), .usageDescriptionMissing)

        XCTAssertEqual(CameraAccess.state(hasUsageDescription: true, authorizationStatus: .authorized), .granted)

        XCTAssertEqual(
            CameraAccess.state(hasUsageDescription: true, authorizationStatus: .notDetermined), .notDetermined)

        XCTAssertEqual(CameraAccess.state(hasUsageDescription: true, authorizationStatus: .restricted), .denied)

        XCTAssertEqual(CameraAccess.state(hasUsageDescription: true, authorizationStatus: .denied), .denied)
    }

    // MARK: - Depth

    func testDepthValuesClampToSupportedRange() {
        let range = LiDARPointCloudView.depthRange

        XCTAssertEqual(Float(-1).clamped(to: range), range.lowerBound)

        XCTAssertEqual(Float(2.75).clamped(to: range), 2.75)

        XCTAssertEqual(Float(20).clamped(to: range), range.upperBound)
    }

    // MARK: - Particle Rendering

    func testParticleViewUsesContinuousRenderingWhenActive() {
        XCTAssertTrue(ParticleLoaderMetalView.shouldRenderContinuously(isActive: true, reduceMotion: false))
    }

    func testParticleViewUsesOnDemandRenderingForReduceMotion() {
        XCTAssertFalse(ParticleLoaderMetalView.shouldRenderContinuously(isActive: true, reduceMotion: true))
    }

    func testInactiveParticleViewDoesNotRenderContinuously() {
        XCTAssertFalse(ParticleLoaderMetalView.shouldRenderContinuously(isActive: false, reduceMotion: false))
    }

    // MARK: - Particle Surface Style

    func testAutomaticParticleSurfaceTracksColorScheme() {
        XCTAssertTrue(ParticleSurfaceStyle.automatic.usesLightPalette(in: .light))

        XCTAssertFalse(ParticleSurfaceStyle.automatic.usesLightPalette(in: .dark))
    }

    func testExplicitParticleSurfaceOverridesColorScheme() {
        XCTAssertFalse(ParticleSurfaceStyle.dark.usesLightPalette(in: .light))

        XCTAssertTrue(ParticleSurfaceStyle.light.usesLightPalette(in: .dark))
    }

    @MainActor func testParticleProgressBindingInitializerRemainsCompatible() {
        let view = ParticleProgressView(progress: .constant(0.5), surfaceStyle: .light, labelColor: .black)

        _ = view
    }

    // MARK: - Point Cloud Continuous Rendering

    func testActiveDemoRendersContinuouslyWithoutReduceMotion() {
        XCTAssertTrue(PointCloudMetalView.shouldRenderContinuously(source: .demo, isActive: true, reduceMotion: false))
    }

    func testActiveDemoUsesOnDemandRenderingWithReduceMotion() {
        XCTAssertFalse(PointCloudMetalView.shouldRenderContinuously(source: .demo, isActive: true, reduceMotion: true))

        XCTAssertTrue(PointCloudMetalView.shouldRequestOnDemandDraw(source: .demo, isActive: true, reduceMotion: true))
    }

    func testInactiveDemoRequestsStaticOnDemandFrame() {
        XCTAssertFalse(
            PointCloudMetalView.shouldRenderContinuously(source: .demo, isActive: false, reduceMotion: false))

        XCTAssertTrue(
            PointCloudMetalView.shouldRequestOnDemandDraw(source: .demo, isActive: false, reduceMotion: false))
    }

    func testActiveLiveCloudRemainsContinuousWithReduceMotion() {
        XCTAssertTrue(PointCloudMetalView.shouldRenderContinuously(source: .live, isActive: true, reduceMotion: true))

        XCTAssertFalse(PointCloudMetalView.shouldRequestOnDemandDraw(source: .live, isActive: true, reduceMotion: true))
    }

    func testInactiveLiveCloudDoesNotRequestFrame() {
        XCTAssertFalse(
            PointCloudMetalView.shouldRenderContinuously(source: .live, isActive: false, reduceMotion: false))

        XCTAssertFalse(
            PointCloudMetalView.shouldRequestOnDemandDraw(source: .live, isActive: false, reduceMotion: false))
    }

    // MARK: - Renderer Draw Policy

    func testInactiveDemoCanDraw() { XCTAssertTrue(PointCloudRenderer.shouldDraw(source: .demo, isActive: false)) }

    func testActiveDemoCanDraw() { XCTAssertTrue(PointCloudRenderer.shouldDraw(source: .demo, isActive: true)) }

    func testInactiveLiveSourceCannotDraw() {
        XCTAssertFalse(PointCloudRenderer.shouldDraw(source: .live, isActive: false))
    }

    func testActiveLiveSourceCanDraw() { XCTAssertTrue(PointCloudRenderer.shouldDraw(source: .live, isActive: true)) }

    // MARK: - Camera Task Identity

    func testCameraTaskIdentityChangesWithDisplayMode() {
        let demo = CameraTaskKey(mode: .demo, phase: .active, isActive: true)

        let live = CameraTaskKey(mode: .live, phase: .active, isActive: true)

        XCTAssertNotEqual(demo, live)
    }

    func testCameraTaskIdentityChangesWhenCaptureResumes() {
        let paused = CameraTaskKey(mode: .live, phase: .active, isActive: false)

        let resumed = CameraTaskKey(mode: .live, phase: .active, isActive: true)

        XCTAssertNotEqual(paused, resumed)
    }

    // MARK: - GPU Resource Policy

    func testDemoSourceDoesNotRequireTextureCache() {
        XCTAssertFalse(PointCloudRenderer.requiresTextureCache(for: .demo))

        XCTAssertTrue(PointCloudRenderer.requiresTextureCache(for: .live))
    }

    // MARK: - AR Frame Semantics

    func testLiveSessionRequestsCombinedDepthWhenAvailable() {
        XCTAssertEqual(
            PointCloudRenderer.frameSemantics(supportsCombinedDepth: true), [.sceneDepth, .smoothedSceneDepth])
    }

    func testLiveSessionFallsBackToSceneDepth() {
        XCTAssertEqual(PointCloudRenderer.frameSemantics(supportsCombinedDepth: false), .sceneDepth)
    }
}
