import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

final class MockForegroundMaskProvider: ForegroundMaskProviding {
    private let longSide: Int

    init(longSide: Int = 256) {
        self.longSide = max(64, longSide)
    }

    func makeForegroundMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> ForegroundMask {
        let size = outputSize(for: pixelBuffer)
        let mask = try makePixelBuffer(width: size.width, height: size.height)
        let phase = (timestamp.seconds.isFinite ? timestamp.seconds : 0) * 0.9

        let centerX = 0.5 + 0.12 * sin(phase * 0.7)
        let centerY = 0.54 + 0.05 * cos(phase * 0.8)
        let headRadius = 0.11
        let bodyWidth = 0.28
        let bodyHeight = 0.34
        let shoulderWidth = 0.42
        let shoulderHeight = 0.14

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

                let head = blob(
                    x: normalizedX,
                    y: normalizedY,
                    centerX: centerX,
                    centerY: centerY - 0.18,
                    radiusX: headRadius,
                    radiusY: headRadius * 1.05,
                    falloff: 2.2
                )

                let torso = roundedRect(
                    x: normalizedX,
                    y: normalizedY,
                    centerX: centerX,
                    centerY: centerY + 0.02,
                    width: bodyWidth,
                    height: bodyHeight,
                    cornerRadius: 0.08
                )

                let shoulders = roundedRect(
                    x: normalizedX,
                    y: normalizedY,
                    centerX: centerX,
                    centerY: centerY - 0.03,
                    width: shoulderWidth,
                    height: shoulderHeight,
                    cornerRadius: 0.10
                )

                let legs = roundedRect(
                    x: normalizedX,
                    y: normalizedY,
                    centerX: centerX,
                    centerY: centerY + 0.24,
                    width: bodyWidth * 0.72,
                    height: bodyHeight * 0.65,
                    cornerRadius: 0.06
                )

                let motionBreathing = 0.88 + 0.12 * sin(phase * 2.1 + normalizedY * 8.0)
                let maskValue = min(1.0, max(head, max(torso, max(shoulders, legs)))) * motionBreathing
                pointer[y * bytesPerRow + x] = UInt8(clamping: Int(maskValue * 255.0))
            }
        }

        return ForegroundMask(pixelBuffer: mask, confidence: 0.95, timestamp: timestamp)
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

    private func blob(x: Double, y: Double, centerX: Double, centerY: Double, radiusX: Double, radiusY: Double, falloff: Double) -> Double {
        let dx = (x - centerX) / radiusX
        let dy = (y - centerY) / radiusY
        let distance = sqrt(dx * dx + dy * dy)
        return max(0.0, 1.0 - pow(distance, falloff))
    }

    private func roundedRect(x: Double, y: Double, centerX: Double, centerY: Double, width: Double, height: Double, cornerRadius: Double) -> Double {
        let halfWidth = width * 0.5
        let halfHeight = height * 0.5
        let dx = max(abs(x - centerX) - halfWidth + cornerRadius, 0.0)
        let dy = max(abs(y - centerY) - halfHeight + cornerRadius, 0.0)
        let outside = sqrt(dx * dx + dy * dy) - cornerRadius
        return max(0.0, 1.0 - max(outside, 0.0) * 12.0)
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
