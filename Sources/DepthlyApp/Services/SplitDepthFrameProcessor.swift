import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

actor SplitDepthFrameProcessor {
    private let foregroundMaskProvider: ForegroundMaskProviding
    private let renderer: SplitDepthRenderer
    private let stabilizer = ForegroundMaskStabilizer()
    private let timeline: ForegroundMaskTimeline
    private var lastAnalyzedTime: Double = -.infinity

    init(
        foregroundMaskProvider: ForegroundMaskProviding = HumanForegroundMaskProvider(),
        timeline: ForegroundMaskTimeline = ForegroundMaskTimeline(),
        renderer: SplitDepthRenderer = SplitDepthRenderer()
    ) {
        self.foregroundMaskProvider = foregroundMaskProvider
        self.timeline = timeline
        self.renderer = renderer
    }

    func reset() {
        stabilizer.reset()
        lastAnalyzedTime = -.infinity
    }

    func shouldAnalyzeFrame(at timestamp: CMTime, interval: TimeInterval) -> Bool {
        let seconds = timestamp.seconds
        guard seconds.isFinite else { return true }
        guard lastAnalyzedTime.isFinite else { return true }
        return seconds - lastAnalyzedTime >= max(0.0, interval)
    }

    func processFrame(
        frameBuffer: CVPixelBuffer,
        timestamp: CMTime,
        settings: EffectSettings
    ) async throws -> CGImage {
        var foregroundMask = try await timeline.mask(at: timestamp, maxGap: max(settings.analysisInterval * 2.5, 0.25))

        if foregroundMask == nil, shouldAnalyzeFrame(at: timestamp, interval: settings.analysisInterval) {
            let rawMask = try await foregroundMaskProvider.makeForegroundMask(from: frameBuffer, timestamp: timestamp)
            let stabilizedMask = try stabilize(mask: rawMask, settings: settings)
            foregroundMask = stabilizedMask
        }

        return try renderer.renderOverlay(
            frameBuffer: frameBuffer,
            foregroundMask: foregroundMask?.pixelBuffer,
            settings: settings
        )
    }

    private func stabilize(mask: ForegroundMask, settings: EffectSettings) throws -> ForegroundMask {
        let outputMask = try stabilizer.stabilize(mask: mask, settings: settings)
        lastAnalyzedTime = mask.timestamp.seconds
        return outputMask
    }
}
