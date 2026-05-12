import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

final class MockDepthEstimator: DepthEstimating {
    private let longSide: Int

    init(longSide: Int = 256) {
        self.longSide = max(64, longSide)
    }

    func estimateDepth(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> DepthMap {
        let size = outputSize(for: pixelBuffer)
        let mask = try makePixelBuffer(width: size.width, height: size.height)
        let phase = (timestamp.seconds.isFinite ? timestamp.seconds : 0) * 0.8
        let centerX = 0.5 + 0.10 * sin(phase)
        let centerY = 0.54 + 0.06 * cos(phase * 0.7)
        let rx = 0.22
        let ry = 0.30

        CVPixelBufferLockBaseAddress(mask, [])
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }

        guard let base = CVPixelBufferGetBaseAddress(mask) else {
            throw DepthEstimatorError.modelUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let normalizedY = Double(y) / Double(max(height - 1, 1))
            for x in 0..<width {
                let normalizedX = Double(x) / Double(max(width - 1, 1))
                let dx = (normalizedX - centerX) / rx
                let dy = (normalizedY - centerY) / ry
                let distance = sqrt(dx * dx + dy * dy)
                let value = max(0.0, 1.0 - distance)
                let softened = pow(value, 1.8)
                pointer[y * bytesPerRow + x] = UInt8(clamping: Int(softened * 255.0))
            }
        }

        return DepthMap(pixelBuffer: mask, confidence: 0.65, timestamp: timestamp, source: .synthetic)
    }

    private func outputSize(for sourcePixelBuffer: CVPixelBuffer) -> (width: Int, height: Int) {
        let sourceWidth = max(CVPixelBufferGetWidth(sourcePixelBuffer), 1)
        let sourceHeight = max(CVPixelBufferGetHeight(sourcePixelBuffer), 1)
        let aspectRatio = Double(sourceWidth) / Double(sourceHeight)

        if aspectRatio >= 1.0 {
            let width = longSide
            let height = max(1, Int((Double(longSide) / aspectRatio).rounded()))
            return (width, height)
        } else {
            let height = longSide
            let width = max(1, Int((Double(longSide) * aspectRatio).rounded()))
            return (width, height)
        }
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
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
