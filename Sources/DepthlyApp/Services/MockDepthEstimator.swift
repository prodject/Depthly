import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

final class MockDepthEstimator: DepthEstimating {
    private let outputWidth: Int
    private let outputHeight: Int

    init(outputWidth: Int = 256, outputHeight: Int = 256) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    func estimateDepth(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> DepthMap {
        let depth = try makePixelBuffer(width: outputWidth, height: outputHeight)
        let phase = (timestamp.seconds.isFinite ? timestamp.seconds : 0) * 0.8
        let centerX = 0.5 + 0.10 * sin(phase)
        let centerY = 0.54 + 0.06 * cos(phase * 0.7)
        let rx = 0.22
        let ry = 0.30

        CVPixelBufferLockBaseAddress(depth, [])
        defer { CVPixelBufferUnlockBaseAddress(depth, []) }

        guard let base = CVPixelBufferGetBaseAddress(depth) else {
            throw DepthEstimatorError.modelUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depth)
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let normalizedY = Double(y) / Double(max(height - 1, 1))
            for x in 0..<width {
                let normalizedX = Double(x) / Double(max(width - 1, 1))
                let dx = (normalizedX - centerX) / rx
                let dy = (normalizedY - centerY) / ry
                let distance = sqrt(dx * dx + dy * dy)
                let nearBlob = max(0.0, 1.0 - distance)
                let backgroundGradient = max(0.0, min(1.0, normalizedY * 0.8 + normalizedX * 0.15))
                let depthValue = max(backgroundGradient, pow(nearBlob, 1.8))
                pointer[y * bytesPerRow + x] = UInt8(clamping: Int(depthValue * 255.0))
            }
        }

        return DepthMap(pixelBuffer: depth, confidence: 0.65, timestamp: timestamp, source: .synthetic)
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
