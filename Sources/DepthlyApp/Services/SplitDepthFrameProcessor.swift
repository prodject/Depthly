import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

actor SplitDepthFrameProcessor {
    private let foregroundMaskProvider: ForegroundMaskProviding
    private let renderer: SplitDepthRenderer
    private let temporalSmoother = TemporalMaskSmoother()
    private var lastAnalyzedTime: Double = -.infinity

    init(
        foregroundMaskProvider: ForegroundMaskProviding = AdaptiveForegroundMaskProvider(),
        renderer: SplitDepthRenderer = SplitDepthRenderer()
    ) {
        self.foregroundMaskProvider = foregroundMaskProvider
        self.renderer = renderer
    }

    func reset() {
        temporalSmoother.reset()
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
        let rawMask = try await foregroundMaskProvider.makeForegroundMask(from: frameBuffer, timestamp: timestamp)
        let stabilizedMask = try stabilize(mask: rawMask, settings: settings)
        return try renderer.renderOverlay(
            frameBuffer: frameBuffer,
            foregroundMask: stabilizedMask.pixelBuffer,
            settings: settings
        )
    }

    private func stabilize(mask: ForegroundMask, settings: EffectSettings) throws -> ForegroundMask {
        let depthMask = DepthMask(pixelBuffer: mask.pixelBuffer, confidence: mask.confidence, timestamp: mask.timestamp)
        let smoothed = try temporalSmoother.smooth(depthMask, factor: settings.temporalSmoothing)
        let thresholded = try threshold(smoothed.pixelBuffer, cutoff: settings.depthCutoff)
        let outputMask = ForegroundMask(pixelBuffer: thresholded, confidence: smoothed.confidence, timestamp: mask.timestamp)

        lastAnalyzedTime = mask.timestamp.seconds
        return outputMask
    }

    private func threshold(_ mask: CVPixelBuffer, cutoff: Double) throws -> CVPixelBuffer {
        let result = try makePixelBufferLike(mask)

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
            CVPixelBufferUnlockBaseAddress(mask, .readOnly)
        }

        guard
            let sourceBase = CVPixelBufferGetBaseAddress(mask),
            let resultBase = CVPixelBufferGetBaseAddress(result)
        else {
            throw DepthEstimatorError.modelUnavailable
        }

        let sourcePointer = sourceBase.assumingMemoryBound(to: UInt8.self)
        let resultPointer = resultBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let thresholdValue = UInt8(clamping: Int(max(0.0, min(1.0, cutoff)) * 255.0))

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let value = sourcePointer[row + x]
                resultPointer[row + x] = value >= thresholdValue ? 255 : 0
            }
        }

        return result
    }

    private func makePixelBufferLike(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw DepthEstimatorError.modelUnavailable
        }
        return buffer
    }
}
