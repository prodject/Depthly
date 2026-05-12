import CoreVideo
import Foundation

final class MaskFusion {
    func fuse(depthMask: DepthMask?, visionMask: DepthMask?, cutoff: Double, effectStrength: Double) throws -> DepthMask? {
        switch (depthMask, visionMask) {
        case let (depth?, vision?):
            let fused = try combine(depth.pixelBuffer, vision.pixelBuffer, depthWeight: effectStrength)
            return DepthMask(
                pixelBuffer: fused,
                confidence: max(depth.confidence, vision.confidence),
                timestamp: depth.timestamp
            )
        case let (depth?, nil):
            return depth
        case let (nil, vision?):
            return vision
        case (nil, nil):
            return nil
        }
    }

    func applyDepthCutoff(_ mask: DepthMask, cutoff: Double) throws -> DepthMask {
        let thresholded = try threshold(mask.pixelBuffer, cutoff: cutoff)
        return DepthMask(pixelBuffer: thresholded, confidence: mask.confidence, timestamp: mask.timestamp)
    }

    private func combine(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer, depthWeight: Double) throws -> CVPixelBuffer {
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
            let leftBase = CVPixelBufferGetBaseAddress(lhs),
            let rightBase = CVPixelBufferGetBaseAddress(rhs),
            let resultBase = CVPixelBufferGetBaseAddress(result)
        else {
            throw DepthEstimatorError.modelUnavailable
        }

        let leftPointer = leftBase.assumingMemoryBound(to: UInt8.self)
        let rightPointer = rightBase.assumingMemoryBound(to: UInt8.self)
        let resultPointer = resultBase.assumingMemoryBound(to: UInt8.self)

        let width = min(CVPixelBufferGetWidth(lhs), CVPixelBufferGetWidth(rhs))
        let height = min(CVPixelBufferGetHeight(lhs), CVPixelBufferGetHeight(rhs))
        let leftBytesPerRow = CVPixelBufferGetBytesPerRow(lhs)
        let rightBytesPerRow = CVPixelBufferGetBytesPerRow(rhs)
        let resultBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let alpha = max(0.0, min(1.0, depthWeight))

        for y in 0..<height {
            for x in 0..<width {
                let leftValue = Double(leftPointer[y * leftBytesPerRow + x]) / 255.0
                let rightValue = Double(rightPointer[y * rightBytesPerRow + x]) / 255.0
                let mixed = leftValue * alpha + rightValue * (1.0 - alpha)
                resultPointer[y * resultBytesPerRow + x] = UInt8(clamping: Int(mixed * 255.0))
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
            for x in 0..<width {
                let value = sourcePointer[y * bytesPerRow + x]
                resultPointer[y * bytesPerRow + x] = value >= thresholdValue ? 255 : 0
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
