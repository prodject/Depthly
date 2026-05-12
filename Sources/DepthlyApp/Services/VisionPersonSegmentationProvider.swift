import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Vision

final class VisionPersonSegmentationProvider: ForegroundMaskProviding {
    init() {
    }

    func makeForegroundMask(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) async throws -> ForegroundMask {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        request.usesCPUOnly = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            throw DepthEstimatorError.modelUnavailable
        }

        return ForegroundMask(
            pixelBuffer: observation.pixelBuffer,
            confidence: 0.78,
            timestamp: timestamp
        )
    }
}
