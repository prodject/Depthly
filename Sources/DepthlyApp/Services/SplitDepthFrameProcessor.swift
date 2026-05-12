import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

actor SplitDepthFrameProcessor {
    private let foregroundMaskProvider: ForegroundMaskProviding
    private let renderer: SplitDepthRenderer
    private var previousMask: ForegroundMask?
    private var lastAnalyzedTime: Double = -.infinity

    init(
        foregroundMaskProvider: ForegroundMaskProviding = AdaptiveForegroundMaskProvider(),
        renderer: SplitDepthRenderer = SplitDepthRenderer()
    ) {
        self.foregroundMaskProvider = foregroundMaskProvider
        self.renderer = renderer
    }

    func reset() {
        previousMask = nil
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
        let thresholded = try threshold(mask.pixelBuffer, cutoff: settings.depthCutoff)
        let currentMask = ForegroundMask(pixelBuffer: thresholded, confidence: mask.confidence, timestamp: mask.timestamp)

        let outputMask: ForegroundMask
        if let previousMask, buffersMatch(previousMask.pixelBuffer, currentMask.pixelBuffer) {
            let blended = try blend(
                previousMask.pixelBuffer,
                currentMask.pixelBuffer,
                smoothing: settings.temporalSmoothing
            )
            outputMask = ForegroundMask(
                pixelBuffer: blended,
                confidence: max(previousMask.confidence, currentMask.confidence),
                timestamp: mask.timestamp
            )
        } else {
            outputMask = currentMask
        }

        previousMask = outputMask
        lastAnalyzedTime = mask.timestamp.seconds
        return outputMask
    }

    private func buffersMatch(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(lhs) == CVPixelBufferGetWidth(rhs) &&
        CVPixelBufferGetHeight(lhs) == CVPixelBufferGetHeight(rhs)
    }

    private func blend(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer, smoothing: Double) throws -> CVPixelBuffer {
        let result = try makePixelBufferLike(rhs)

        CVPixelBufferLockBaseAddress(lhs, .readOnly)
        CVPixelBufferLockBaseAddress(rhs, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
            CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
            CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
        }

        guard
            let leftBase = CVPixelBufferGetBaseAddress(lhs),
            let rightBase = CVPixelBufferGetBaseAddress(rhs),
            let resultBase = CVPixelBufferGetBaseAddress(result)
        else {
            throw DepthEstimatorError.modelUnavailable
        }

        let leftPointer = leftBase.assumingMemoryBound(to: UInt8.self)
        let rightPointer = rightBase.assumingMemoryBound(to: UInt8.self)
        let resultPointer = resultBase.assumingMemoryBound(to: UInt8.self)

        let width = CVPixelBufferGetWidth(rhs)
        let height = CVPixelBufferGetHeight(rhs)
        let leftBytesPerRow = CVPixelBufferGetBytesPerRow(lhs)
        let rightBytesPerRow = CVPixelBufferGetBytesPerRow(rhs)
        let resultBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let alpha = max(0.0, min(1.0, smoothing))

        for y in 0..<height {
            let leftRow = y * leftBytesPerRow
            let rightRow = y * rightBytesPerRow
            let resultRow = y * resultBytesPerRow
            for x in 0..<width {
                let previousValue = Double(leftPointer[leftRow + x]) / 255.0
                let currentValue = Double(rightPointer[rightRow + x]) / 255.0
                let smoothed = previousValue * alpha + currentValue * (1.0 - alpha)
                resultPointer[resultRow + x] = UInt8(clamping: Int(smoothed * 255.0))
            }
        }

        return result
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
