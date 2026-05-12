import CoreMedia
import CoreVideo
import Foundation

final class ForegroundMaskStabilizer {
    private let temporalSmoother = TemporalMaskSmoother()
    private var previousThresholdMask: CVPixelBuffer?

    func reset() {
        temporalSmoother.reset()
        previousThresholdMask = nil
    }

    func stabilize(mask: ForegroundMask, settings: EffectSettings) throws -> ForegroundMask {
        let depthMask = DepthMask(pixelBuffer: mask.pixelBuffer, confidence: mask.confidence, timestamp: mask.timestamp)
        let smoothed = try temporalSmoother.smooth(depthMask, factor: settings.temporalSmoothing)
        let thresholded = try threshold(
            smoothed.pixelBuffer,
            cutoff: settings.depthCutoff,
            previousMask: previousThresholdMask,
            temporalSmoothing: settings.temporalSmoothing,
            edgeSoftness: settings.edgeSoftness
        )
        let repaired = try repair(
            thresholded,
            previousMask: previousThresholdMask,
            temporalSmoothing: settings.temporalSmoothing,
            edgeSoftness: settings.edgeSoftness
        )
        previousThresholdMask = repaired
        return ForegroundMask(pixelBuffer: repaired, confidence: smoothed.confidence, timestamp: mask.timestamp)
    }

    private func threshold(
        _ mask: CVPixelBuffer,
        cutoff: Double,
        previousMask: CVPixelBuffer?,
        temporalSmoothing: Double,
        edgeSoftness: Double
    ) throws -> CVPixelBuffer {
        let result = try MaskPixelBufferBlender.makePixelBufferLike(mask)

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        if let previousMask {
            CVPixelBufferLockBaseAddress(previousMask, .readOnly)
        }
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(result, [])
            if let previousMask {
                CVPixelBufferUnlockBaseAddress(previousMask, .readOnly)
            }
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
        let previousPointer = previousMask.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let previousBytesPerRow = previousMask.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let cutoffValue = max(0.0, min(1.0, cutoff))
        let hysteresis = max(0.03, min(0.12, 0.04 + (1.0 - max(0.0, min(1.0, temporalSmoothing))) * 0.06 + max(0.0, min(1.0, edgeSoftness)) * 0.04))
        let lowerThreshold = UInt8(clamping: Int(max(0.0, cutoffValue - hysteresis) * 255.0))
        let upperThreshold = UInt8(clamping: Int(min(1.0, cutoffValue + hysteresis) * 255.0))
        let hardThreshold = UInt8(clamping: Int(cutoffValue * 255.0))

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let value = sourcePointer[row + x]
                if value >= upperThreshold {
                    resultPointer[row + x] = 255
                } else if value <= lowerThreshold {
                    resultPointer[row + x] = 0
                } else if let previousPointer {
                    resultPointer[row + x] = previousPointer[y * previousBytesPerRow + x]
                } else {
                    resultPointer[row + x] = value >= hardThreshold ? 255 : 0
                }
            }
        }

        return result
    }

    private func repair(
        _ mask: CVPixelBuffer,
        previousMask: CVPixelBuffer?,
        temporalSmoothing: Double,
        edgeSoftness: Double
    ) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let radius = max(1, min(4, Int((edgeSoftness * 12.0).rounded()) + 1))
        let speckRadius = 1

        let source = try readMask(mask)
        let closed = erode(dilate(source, width: width, height: height, radius: radius), width: width, height: height, radius: radius)
        let opened = dilate(erode(closed, width: width, height: height, radius: speckRadius), width: width, height: height, radius: speckRadius)

        let stabilized: [UInt8]
        if let previousMask {
            let previous = try readMask(previousMask)
            let holdThreshold = max(1, min(5, Int((temporalSmoothing * 5.0).rounded())))
            stabilized = temporalRepair(
                current: opened,
                previous: previous,
                width: width,
                height: height,
                supportThreshold: holdThreshold
            )
        } else {
            stabilized = opened
        }

        return try writeMask(stabilized, like: mask)
    }

    private func temporalRepair(
        current: [UInt8],
        previous: [UInt8],
        width: Int,
        height: Int,
        supportThreshold: Int
    ) -> [UInt8] {
        var output = current

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard current[index] == 0, previous[index] > 0 else { continue }

                var support = 0
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        if current[ny * width + nx] > 0 {
                            support += 1
                        }
                    }
                }

                if support >= supportThreshold {
                    output[index] = 255
                }
            }
        }

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard current[index] > 0, previous[index] == 0 else { continue }

                var support = 0
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        if previous[ny * width + nx] > 0 {
                            support += 1
                        }
                    }
                }

                if support == 0 {
                    output[index] = 0
                }
            }
        }

        return output
    }

    private func dilate(_ input: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return input }
        var output = Array(repeating: UInt8(0), count: input.count)

        for y in 0..<height {
            for x in 0..<width {
                var value: UInt8 = 0
                search: for ny in max(0, y - radius)...min(height - 1, y + radius) {
                    for nx in max(0, x - radius)...min(width - 1, x + radius) {
                        if input[ny * width + nx] > 0 {
                            value = 255
                            break search
                        }
                    }
                }
                output[y * width + x] = value
            }
        }

        return output
    }

    private func erode(_ input: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return input }
        var output = Array(repeating: UInt8(0), count: input.count)

        for y in 0..<height {
            for x in 0..<width {
                var value: UInt8 = 255
                search: for ny in max(0, y - radius)...min(height - 1, y + radius) {
                    for nx in max(0, x - radius)...min(width - 1, x + radius) {
                        if input[ny * width + nx] == 0 {
                            value = 0
                            break search
                        }
                    }
                }
                output[y * width + x] = value
            }
        }

        return output
    }

    private func readMask(_ mask: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
            throw DepthEstimatorError.modelUnavailable
        }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var values = Array(repeating: UInt8(0), count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = pointer[y * bytesPerRow + x] >= 48 ? 255 : 0
            }
        }

        return values
    }

    private func writeMask(_ values: [UInt8], like source: CVPixelBuffer) throws -> CVPixelBuffer {
        let buffer = try MaskPixelBufferBlender.makePixelBufferLike(source)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw DepthEstimatorError.modelUnavailable
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                pointer[y * bytesPerRow + x] = values[y * width + x]
            }
        }

        return buffer
    }
}
