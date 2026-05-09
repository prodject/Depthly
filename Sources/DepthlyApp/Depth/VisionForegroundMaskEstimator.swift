import CoreImage
import CoreVideo
import Foundation
import Vision

enum VisionForegroundMaskEstimatorError: Error {
    case missingObservation
}

final class VisionForegroundMaskEstimator: ForegroundMaskEstimating, @unchecked Sendable {
    func estimateForegroundMask(for pixelBuffer: CVPixelBuffer) async throws -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw VisionForegroundMaskEstimatorError.missingObservation
        }

        let maskBuffer = observation.pixelBuffer
        return CIImage(cvPixelBuffer: maskBuffer)
    }
}
