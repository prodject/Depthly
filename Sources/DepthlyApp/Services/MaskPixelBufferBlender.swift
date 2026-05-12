import CoreVideo
import Foundation

enum MaskPixelBufferBlender {
    static func blend(_ from: CVPixelBuffer, _ to: CVPixelBuffer, alpha: Double) throws -> CVPixelBuffer {
        let result = try makePixelBufferLike(to)

        CVPixelBufferLockBaseAddress(from, .readOnly)
        CVPixelBufferLockBaseAddress(to, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
            CVPixelBufferUnlockBaseAddress(to, .readOnly)
            CVPixelBufferUnlockBaseAddress(from, .readOnly)
        }

        guard
            let fromBase = CVPixelBufferGetBaseAddress(from),
            let toBase = CVPixelBufferGetBaseAddress(to),
            let resultBase = CVPixelBufferGetBaseAddress(result)
        else {
            throw DepthEstimatorError.modelUnavailable
        }

        let fromWidth = CVPixelBufferGetWidth(from)
        let fromHeight = CVPixelBufferGetHeight(from)
        let toWidth = CVPixelBufferGetWidth(to)
        let toHeight = CVPixelBufferGetHeight(to)
        guard fromWidth == toWidth, fromHeight == toHeight else {
            throw DepthEstimatorError.unsupportedModelShape
        }

        let fromPointer = fromBase.assumingMemoryBound(to: UInt8.self)
        let toPointer = toBase.assumingMemoryBound(to: UInt8.self)
        let resultPointer = resultBase.assumingMemoryBound(to: UInt8.self)
        let fromBytesPerRow = CVPixelBufferGetBytesPerRow(from)
        let toBytesPerRow = CVPixelBufferGetBytesPerRow(to)
        let resultBytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let clampedAlpha = max(0.0, min(1.0, alpha))

        for y in 0..<toHeight {
            for x in 0..<toWidth {
                let fromValue = Double(fromPointer[y * fromBytesPerRow + x])
                let toValue = Double(toPointer[y * toBytesPerRow + x])
                let blended = fromValue * (1.0 - clampedAlpha) + toValue * clampedAlpha
                resultPointer[y * resultBytesPerRow + x] = UInt8(clamping: Int(blended.rounded()))
            }
        }

        return result
    }

    static func makePixelBufferLike(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
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
