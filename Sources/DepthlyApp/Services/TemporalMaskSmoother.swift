import CoreMedia
import CoreVideo
import Foundation

final class TemporalMaskSmoother {
    private var previousMask: ForegroundMask?

    func reset() {
        previousMask = nil
    }

    func smooth(_ mask: ForegroundMask, factor: Double) throws -> ForegroundMask {
        defer { previousMask = mask }

        guard let previousMask else {
            return mask
        }

        guard
            CVPixelBufferGetWidth(previousMask.pixelBuffer) == CVPixelBufferGetWidth(mask.pixelBuffer),
            CVPixelBufferGetHeight(previousMask.pixelBuffer) == CVPixelBufferGetHeight(mask.pixelBuffer)
        else {
            return mask
        }

        let result = try makePixelBufferLike(mask.pixelBuffer)
        CVPixelBufferLockBaseAddress(previousMask.pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(mask.pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
            CVPixelBufferUnlockBaseAddress(mask.pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(previousMask.pixelBuffer, .readOnly)
        }

        guard
            let previousBase = CVPixelBufferGetBaseAddress(previousMask.pixelBuffer),
            let currentBase = CVPixelBufferGetBaseAddress(mask.pixelBuffer),
            let resultBase = CVPixelBufferGetBaseAddress(result)
        else {
            throw DepthEstimatorError.modelUnavailable
        }

        let previousPointer = previousBase.assumingMemoryBound(to: UInt8.self)
        let currentPointer = currentBase.assumingMemoryBound(to: UInt8.self)
        let resultPointer = resultBase.assumingMemoryBound(to: UInt8.self)

        let width = CVPixelBufferGetWidth(mask.pixelBuffer)
        let height = CVPixelBufferGetHeight(mask.pixelBuffer)
        let previousBytesPerRow = CVPixelBufferGetBytesPerRow(previousMask.pixelBuffer)
        let currentBytesPerRow = CVPixelBufferGetBytesPerRow(mask.pixelBuffer)
        let resultBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let alpha = max(0.0, min(1.0, factor))

        for y in 0..<height {
            for x in 0..<width {
                let previousValue = Double(previousPointer[y * previousBytesPerRow + x]) / 255.0
                let currentValue = Double(currentPointer[y * currentBytesPerRow + x]) / 255.0
                let smoothed = previousValue * alpha + currentValue * (1.0 - alpha)
                resultPointer[y * resultBytesPerRow + x] = UInt8(clamping: Int(smoothed * 255.0))
            }
        }

        return ForegroundMask(
            pixelBuffer: result,
            confidence: max(previousMask.confidence, mask.confidence),
            timestamp: mask.timestamp
        )
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
