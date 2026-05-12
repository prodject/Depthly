import CoreMedia
import CoreVideo
import Foundation

final class MaskFusion {
    func fuse(
        depthMap: DepthMap?,
        foregroundMask: ForegroundMask?,
        cutoff: Double,
        effectStrength: Double
    ) throws -> ForegroundMask? {
        switch (depthMap, foregroundMask) {
        case let (depth?, foreground?):
            let depthThreshold = try threshold(depth.pixelBuffer, cutoff: cutoff)
            let result = try blend(depthThreshold, foreground.pixelBuffer, weight: effectStrength)
            return ForegroundMask(
                pixelBuffer: result,
                confidence: max(depth.confidence, foreground.confidence),
                timestamp: max(depth.timestamp, foreground.timestamp)
            )
        case let (depth?, nil):
            let depthThreshold = try threshold(depth.pixelBuffer, cutoff: cutoff)
            return ForegroundMask(
                pixelBuffer: depthThreshold,
                confidence: depth.confidence,
                timestamp: depth.timestamp
            )
        case let (nil, foreground?):
            return foreground
        case (nil, nil):
            return nil
        }
    }

    private func threshold(_ source: CVPixelBuffer, cutoff: Double) throws -> CVPixelBuffer {
        let result = try makePixelBufferLike(source)
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard
            let sourceBase = CVPixelBufferGetBaseAddress(source),
            let resultBase = CVPixelBufferGetBaseAddress(result)
        else {
            throw DepthEstimatorError.modelUnavailable
        }

        let sourcePointer = sourceBase.assumingMemoryBound(to: UInt8.self)
        let resultPointer = resultBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let thresholdValue = UInt8(clamping: Int(max(0.0, min(1.0, cutoff)) * 255.0))

        for y in 0..<height {
            for x in 0..<width {
                let value = sourcePointer[y * bytesPerRow + x]
                resultPointer[y * bytesPerRow + x] = value >= thresholdValue ? 255 : 0
            }
        }

        return result
    }

    private func blend(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer, weight: Double) throws -> CVPixelBuffer {
        let result = try makePixelBufferLike(lhs)

        CVPixelBufferLockBaseAddress(lhs, .readOnly)
        CVPixelBufferLockBaseAddress(rhs, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
            CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
            CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
        }

        guard
            let lhsBase = CVPixelBufferGetBaseAddress(lhs),
            let rhsBase = CVPixelBufferGetBaseAddress(rhs),
            let resultBase = CVPixelBufferGetBaseAddress(result)
        else {
            throw DepthEstimatorError.modelUnavailable
        }

        let lhsPointer = lhsBase.assumingMemoryBound(to: UInt8.self)
        let rhsPointer = rhsBase.assumingMemoryBound(to: UInt8.self)
        let resultPointer = resultBase.assumingMemoryBound(to: UInt8.self)

        let width = CVPixelBufferGetWidth(result)
        let height = CVPixelBufferGetHeight(result)
        let lhsWidth = CVPixelBufferGetWidth(lhs)
        let lhsHeight = CVPixelBufferGetHeight(lhs)
        let rhsWidth = CVPixelBufferGetWidth(rhs)
        let rhsHeight = CVPixelBufferGetHeight(rhs)
        let lhsBytesPerRow = CVPixelBufferGetBytesPerRow(lhs)
        let rhsBytesPerRow = CVPixelBufferGetBytesPerRow(rhs)
        let resultBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let alpha = max(0.0, min(1.0, weight))

        for y in 0..<height {
            let lhsY = min(lhsHeight - 1, Int(Double(y) * Double(lhsHeight) / Double(max(height, 1))))
            let rhsY = min(rhsHeight - 1, Int(Double(y) * Double(rhsHeight) / Double(max(height, 1))))

            for x in 0..<width {
                let lhsX = min(lhsWidth - 1, Int(Double(x) * Double(lhsWidth) / Double(max(width, 1))))
                let rhsX = min(rhsWidth - 1, Int(Double(x) * Double(rhsWidth) / Double(max(width, 1))))

                let lhsValue = Double(lhsPointer[lhsY * lhsBytesPerRow + lhsX]) / 255.0
                let rhsValue = Double(rhsPointer[rhsY * rhsBytesPerRow + rhsX]) / 255.0
                let mixed = lhsValue * alpha + rhsValue * (1.0 - alpha)
                resultPointer[y * resultBytesPerRow + x] = UInt8(clamping: Int(mixed * 255.0))
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
