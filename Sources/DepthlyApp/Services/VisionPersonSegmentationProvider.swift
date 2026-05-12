import CoreMedia
import CoreVideo
import Foundation
import Vision

final class VisionPersonSegmentationProvider {
    private let request: VNGeneratePersonSegmentationRequest

    init() {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func makeMask(from pixelBuffer: CVPixelBuffer) async throws -> DepthMask {
        try await withCheckedThrowingContinuation { continuation in
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first as? VNPixelBufferObservation else {
                    continuation.resume(throwing: DepthEstimatorError.modelUnavailable)
                    return
                }
                continuation.resume(
                    returning: DepthMask(
                        pixelBuffer: observation.pixelBuffer,
                        confidence: 0.7,
                        timestamp: CMTime.zero
                    )
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
